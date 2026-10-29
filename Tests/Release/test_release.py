"""Release metadata, packaging integrity and source/tag safety checks, without a build."""

import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[2] / "scripts/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.addCleanup(patch.stopall)
        # Simulated uploads must not look like real draft releases in CI logs.
        patch("sys.stdout", new=io.StringIO()).start()
        patch.object(release, "ROOT", self.root).start()
        (self.root / "app").mkdir()
        (self.root / "LICENSE").write_bytes(b"MIT fixture license")
        self.info = {"version": "2026.10.27-r2", "build": 2}
        self.write_version(self.info)

    def write_version(self, info):
        (self.root / "app/version.json").write_text(json.dumps(info))

    def test_stamp_keeps_bundle_identity_and_uses_committed_version(self):
        self.assertEqual(release.version_info(), self.info)
        path = self.root / "Info.plist"
        path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.notchcompanion.mac"}))
        release.stamp(path, self.info)
        values = plistlib.loads(path.read_bytes())
        self.assertEqual(values["CFBundleIdentifier"], "com.notchcompanion.mac")
        self.assertEqual(values["CFBundleShortVersionString"], "2026.10.27")
        self.assertEqual(values["CFBundleVersion"], "2")
        self.assertEqual(values["NotchCompanionReleaseVersion"], "2026.10.27-r2")

    def test_invalid_or_ambiguous_versions_and_builds_are_rejected(self):
        for version in ["2026.02.3-r1", "2026.2.03-r1", "2026.2.29-r1", "2026.10.27", "2026.10.27-r0", "2026.10.27-r01"]:
            with self.subTest(version=version):
                self.write_version({**self.info, "version": version})
                with self.assertRaises(ValueError):
                    release.version_info()
        for build in [0, -1, True, "2", 2.0, 10000]:
            with self.subTest(build=build):
                self.write_version({**self.info, "build": build})
                with self.assertRaises(ValueError):
                    release.version_info()
        self.write_version({**self.info, "version": "2028.2.29-r1"})
        self.assertEqual(release.version_info()["version"], "2028.2.29-r1")

    def test_generated_preview_override_is_explicit_and_cannot_become_a_release(self):
        preview = {**self.info, "preview": "pr-12-abcdef123456"}
        override = self.root / "build/ci-version.json"
        override.parent.mkdir()
        override.write_text(json.dumps(preview))
        with patch.dict(os.environ, {"NOTCH_VERSION_FILE": str(override)}):
            self.assertEqual(release.version_info(), self.info, "Pure helpers must ignore inherited CI override variables")
            self.assertEqual(release.version_info(str(override)), preview)
        with self.assertRaisesRegex(ValueError, "ignored build"):
            release.version_info(str(self.root / "app/version.json"))
        path = self.root / "Info.plist"
        path.write_bytes(plistlib.dumps({}))
        release.stamp(path, preview)
        self.assertEqual(plistlib.loads(path.read_bytes())["NotchCompanionPreview"], preview["preview"])
        self.assertIn("preview-pr-12-abcdef123456", release.archive_name(preview))
        app = self.root / release.APP_NAME
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(path.read_bytes())
        with self.assertRaisesRegex(ValueError, "preview bundle cannot"):
            release.verify(app, self.info)
        release.stamp(path, self.info)
        self.assertNotIn("NotchCompanionPreview", plistlib.loads(path.read_bytes()))
        with patch.object(release.sys, "platform", "darwin"), patch.object(release, "clean_commit", return_value="abc123"), patch.object(release, "release_repo") as repo:
            with self.assertRaisesRegex(ValueError, "Preview packages can never"):
                release.package(preview, True)
            repo.assert_not_called()

    def test_uncommitted_source_is_rejected(self):
        with patch.object(release, "run", side_effect=["abc123", " M app/version.json"]):
            with self.assertRaisesRegex(ValueError, "clean, committed"):
                release.clean_commit()
        with patch.object(release, "run", side_effect=["abc123", ""]):
            self.assertEqual(release.clean_commit(), "abc123")

    def test_draft_requires_new_repository_and_exact_remote_tag(self):
        tag = "v2026.10.27-r2"
        with patch.object(release, "run", return_value="git@github.com:TimHerder/notch-companion-private.git"):
            with self.assertRaisesRegex(ValueError, "new GitHub"):
                release.release_repo(tag, "abc123")
        for origin in ["git@github.com:TimHerder/notch-companion.git", "https://github.com/TimHerder/notch-companion.git"]:
            with self.subTest(origin=origin):
                with patch.object(release, "run", side_effect=[origin, f"tag-object\trefs/tags/{tag}\nabc123\trefs/tags/{tag}^{{}}"]):
                    self.assertEqual(release.release_repo(tag, "abc123"), "TimHerder/notch-companion")
                with patch.object(release, "run", side_effect=[origin, f"wrong-commit\trefs/tags/{tag}"]):
                    with self.assertRaisesRegex(ValueError, "must never be moved"):
                        release.release_repo(tag, "abc123")

    def test_changed_bundle_resource_is_rejected_before_signature_check(self):
        app = self.root / release.APP_NAME
        resources = app / "Contents/Resources"
        bundle = resources / "NotchCompanion_NotchCompanion.bundle"
        bundle.mkdir(parents=True)
        executable = app / "Contents/MacOS/NotchCompanion"
        executable.parent.mkdir()
        executable.write_bytes(b"executable")
        executable.chmod(0o755)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(release.version_fields(self.info)))
        (self.root / "app/AppIcon.icns").write_bytes(b"icon")
        (resources / "AppIcon.icns").write_bytes(b"icon")
        license_path = resources / "LICENSE"
        license_path.write_bytes((self.root / "LICENSE").read_bytes())
        source = self.root / "Sources/NotchCompanion/Resources/hermes_bridge.py"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"source resource")
        (bundle / source.name).write_bytes(b"changed resource")
        with patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "Missing or changed packaged resource"):
                release.verify(app, self.info)
            run.assert_not_called()
            (bundle / source.name).write_bytes(source.read_bytes())
            release.verify(app, self.info)
            run.assert_called_once_with("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
            run.reset_mock()
            license_path.unlink()
            with self.assertRaisesRegex(ValueError, "Missing or changed packaged license"):
                release.verify(app, self.info)
            license_path.write_bytes(b"changed license")
            with self.assertRaisesRegex(ValueError, "Missing or changed packaged license"):
                release.verify(app, self.info)
            run.assert_not_called()

    def test_old_commit_and_modified_zip_cannot_be_uploaded(self):
        folder = self.root / "package"
        folder.mkdir()
        archive = f"Notch-Companion-{self.info['version']}-arm64.zip"
        manifest = {**self.info, "commit": "old", "architecture": "arm64", "archive": archive}
        (folder / "release.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "another commit"):
            release.verify_package(folder, self.info, "new")
        (folder / archive).write_bytes(b"changed zip")
        (folder / "SHA256SUMS").write_text("previous checksum")
        with patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                release.verify_package(folder, self.info, "old")
            run.assert_not_called()

    def test_release_binary_must_not_embed_local_checkout_path(self):
        app = self.root / release.APP_NAME
        executable = app / "Contents/MacOS/NotchCompanion"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"binary\x00" + str(self.root).encode() + b"/Sources/Companion.swift\x00")
        executable.chmod(0o755)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(release.version_fields(self.info)))
        with patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "local checkout path"):
                release.verify(app, self.info)
            run.assert_not_called()

    def test_existing_package_is_not_overwritten_and_upload_stays_draft(self):
        folder = self.root / "build/releases" / ("v" + self.info["version"])
        folder.mkdir(parents=True)
        assets = [folder / "app.zip", folder / "SHA256SUMS", folder / "release.json"]
        with patch.object(release.sys, "platform", "darwin"), \
             patch.object(release, "clean_commit", return_value="abc123"), \
             patch.object(release, "release_repo", return_value="TimHerder/notch-companion"), \
             patch.object(release, "verify_package", return_value=assets), \
             patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "already exists"):
                release.package(self.info, False)
            run.assert_not_called()
            release.package(self.info, True)
            self.assertEqual(run.call_count, 1)
            args = run.call_args.args
            self.assertEqual(args[:4], ("gh", "release", "create", "v2026.10.27-r2"))
            self.assertIn("--draft", args)
            self.assertIn("--prerelease", args)
            self.assertIn("--verify-tag", args)
            self.assertNotIn("--clobber", args)


if __name__ == "__main__":
    unittest.main()
