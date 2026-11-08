"""Offline decisions and immutable retry tests; no GitHub or native build needed."""

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("ci_release", SCRIPTS / "ci-release.py")
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)
ORIGINAL_RELEASE_TAGS = ci.release_tags

SHA = "a" * 40
BEFORE = "b" * 40
REPO = "TimHerder/notch-companion"
BASE = {"version": "2026.10.28-r1", "build": 2}


class CIReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.addCleanup(patch.stopall)
        patch.object(ci.release, "ROOT", self.root).start()
        patch("sys.stdout", new=io.StringIO()).start()
        patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
                              "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": ""}).start()
        (self.root / "app").mkdir()
        (self.root / "app/version.json").write_text(json.dumps(BASE))
        self.event = {"ref": "refs/heads/main", "before": BEFORE, "after": SHA}
        self.context = patch.object(ci, "context", side_effect=lambda: (self.event, REPO, SHA, "123")).start()
        self.pr = {"number": 42, "merged_at": "2026-10-28T23:55:00Z", "merge_commit_sha": SHA,
                   "base": {"ref": "main", "repo": {"full_name": REPO}}}
        self.api = patch.object(ci, "api", side_effect=self.native_api).start()
        patch.object(ci, "is_ancestor", return_value=False).start()
        patch.object(ci, "release_tags", return_value=[]).start()
        patch.object(ci, "git", return_value="Sources/NotchCompanion/Feature.swift\0").start()

    def native_api(self, path, pages=False):
        if path.endswith("/pulls"):
            return [self.pr]
        return {"id": 123, "head_sha": SHA, "event": "push", "created_at": "2026-10-28T23:55:00Z"}

    def eligible_plan(self):
        with patch.object(ci, "is_ancestor", return_value=True):
            return ci.make_plan()

    def test_only_exact_merged_app_change_push_allocates_a_release(self):
        with patch.object(ci, "is_ancestor", return_value=True), patch.object(ci, "git", return_value="docs/guide.md\0Tests/Release/test_ci_release.py\0") as git:
            self.assertEqual(ci.make_plan()["mode"], "check")
            git.assert_called_once_with("diff", "--name-only", "--no-renames", "-z", BEFORE, SHA)
        self.pr["merge_commit_sha"] = BEFORE
        self.assertEqual(self.eligible_plan()["mode"], "check")
        self.pr["merge_commit_sha"] = SHA
        plan = self.eligible_plan()
        self.assertEqual(plan["mode"], "release")
        self.assertEqual(plan["metadata"], {"version": "2026.10.29-r1", "build": 3})
        self.assertEqual(plan["annotation"]["created_at"], "2026-10-28T23:55:00Z")
        for name in ["workflow_dispatch", "pull_request_target"]:
            with patch.dict(os.environ, {"GITHUB_EVENT_NAME": name}):
                self.assertEqual(ci.make_plan()["mode"], "check")

    def test_preview_uses_pr_head_label_but_checked_merge_commit(self):
        self.event = {"number": 9, "pull_request": {"author_association": "COLLABORATOR",
                      "head": {"sha": "c" * 40, "repo": {"full_name": REPO}},
                      "base": {"repo": {"full_name": REPO}}}}
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "pull_request"}):
            plan = ci.make_plan()
            self.assertEqual(plan["commit"], SHA)
            self.assertEqual(plan["metadata"]["preview"], "pr-9-cccccccccccc")
            self.assertEqual(plan["mode"], "preview")
            self.api.assert_not_called()
            self.event["pull_request"]["head"]["repo"]["full_name"] = "someone/notch-companion"
            self.assertEqual(ci.make_plan()["mode"], "check")
            self.event["pull_request"]["head"]["repo"]["full_name"] = REPO
            self.event["pull_request"]["author_association"] = "CONTRIBUTOR"
            self.assertEqual(ci.make_plan()["mode"], "check")

    def test_version_counts_legacy_drafts_auto_tags_and_preserves_retry(self):
        annotation = ci.allocate_version([], BASE, SHA, "2026-10-28T23:55:00Z", REPO, "123", 42)
        tags = [{"tag": "v2026.10.29-r4", "commit": BEFORE, "metadata": {"version": "2026.10.29-r4", "build": 8}, "annotation": None},
                {"tag": "v2026.10.29-r1", "commit": SHA, "metadata": {"version": annotation["version"], "build": annotation["build"]}, "annotation": annotation}]
        self.assertEqual(ci.allocate_version(tags, BASE, SHA, "2026-11-01T12:00:00Z", REPO, "123", 42), annotation)
        later = ci.allocate_version(tags, BASE, "c" * 40, "2026-10-28T23:55:00Z", REPO, "124", 43)
        self.assertEqual((later["version"], later["build"]), ("2026.10.29-r5", 9))
        with patch.object(ci, "is_ancestor", return_value=True):
            self.assertIsNone(ci.allocate_version(tags, BASE, BEFORE, "2026-10-29T12:00:00Z", REPO, "125", 44))
        with self.assertRaisesRegex(ValueError, "Multiple automated"):
            ci.allocate_version(tags + [tags[1]], BASE, SHA, "2026-10-29T12:00:00Z", REPO, "123", 42)

    def test_legacy_tag_must_match_its_source_version_and_never_be_a_preview(self):
        # Use the real inventory reader, with Git object contents supplied offline.
        for info in [{**BASE, "version": "2026.10.28-r2"}, {**BASE, "preview": "pr-1-abcdef123456"}]:
            with self.subTest(info=info), patch.object(ci, "git", side_effect=["v2026.10.28-r1", SHA, "commit", json.dumps(info)]):
                # setUp mocks the reader for plan tests; call the original saved function.
                with self.assertRaisesRegex(ValueError, "Legacy tag"):
                    ORIGINAL_RELEASE_TAGS()
        with patch.object(ci, "git", side_effect=["v2026.10.28-r1", SHA, "commit", json.dumps(BASE)]):
            self.assertEqual(ORIGINAL_RELEASE_TAGS()[0]["metadata"], BASE)

    def test_generated_plan_ignores_missing_override_and_is_consistent(self):
        (self.root / "build").mkdir()
        with patch.dict(os.environ, {"NOTCH_VERSION_FILE": "build/not-yet-created.json"}), patch.object(ci, "is_ancestor", return_value=True):
            ci.write_plan()
        plan = ci.load_plan()
        self.assertEqual(plan["metadata"]["build"], 3)
        (self.root / "build/ci-version.json").write_text(json.dumps(BASE))
        with self.assertRaisesRegex(ValueError, "disagree"):
            ci.load_plan()

    def test_previews_and_direct_pushes_cannot_publish(self):
        plan = self.eligible_plan()
        plan["mode"] = "preview"
        plan["metadata"]["preview"] = "pr-42-cccccccccccc"
        with patch.object(ci, "load_plan", return_value=plan), patch.object(ci, "authenticated_git") as git:
            with self.assertRaisesRegex(ValueError, "previews can never"):
                ci.publish()
            git.assert_not_called()

    def test_tag_collision_is_never_overwritten(self):
        plan = self.eligible_plan()
        collision = {"tag": plan["tag"], "commit": BEFORE, "annotation": plan["annotation"]}
        with patch.object(ci, "release_tags", return_value=[collision]), patch.object(ci, "authenticated_git") as git:
            with self.assertRaisesRegex(ValueError, "already exists"):
                ci.ensure_tag(plan)
            git.assert_not_called()

    def test_retry_verifies_existing_bytes_and_only_uploads_missing_assets(self):
        paths = [self.root / name for name in ("app.zip", "release.json", "SHA256SUMS")]
        for path in paths:
            path.write_bytes(b"verified bytes")
        remote = {"id": 7, "prerelease": False, "draft": True, "html_url": "https://example.invalid/release"}
        uploaded = [{"id": 1, "name": "app.zip", "size": paths[0].stat().st_size}]

        def download(args, **kwargs):
            kwargs["stdout"].write(b"verified bytes")
            return subprocess.CompletedProcess(args, 0)

        with patch.object(ci, "api", return_value=uploaded), patch.object(ci.subprocess, "run", side_effect=download):
            self.assertEqual(ci.verify_assets(REPO, remote, paths), paths[1:])
            paths[0].write_bytes(b"different same")
            with self.assertRaisesRegex(ValueError, "asset differs"):
                ci.verify_assets(REPO, remote, paths)
        plan = self.eligible_plan()
        with patch.object(ci, "load_plan", return_value=plan), patch.object(ci, "make_plan", return_value=plan), \
             patch.object(ci, "authenticated_git"), patch.object(ci, "ensure_tag"), \
             patch.object(ci.release, "verify_package", return_value=paths), \
             patch.object(ci, "existing_release", side_effect=[remote, {**remote, "draft": False}]), \
             patch.object(ci, "verify_assets", side_effect=[paths[1:], []]), patch.object(ci.release, "run") as run:
            ci.publish()
            commands = [call.args for call in run.call_args_list]
            self.assertEqual(len(commands), 3)
            self.assertTrue(all("--clobber" not in command for command in commands))
            self.assertNotIn(str(paths[0]), str(commands))
            self.assertIn("--draft=false", commands[-1])
            self.assertIn("--latest", commands[-1])

    def test_new_release_is_a_full_release_without_beta_wording(self):
        plan = self.eligible_plan()
        draft = {"id": 7, "prerelease": False, "draft": True, "html_url": "https://example.invalid/release"}
        with patch.object(ci, "load_plan", return_value=plan), patch.object(ci, "make_plan", return_value=plan), \
             patch.object(ci, "authenticated_git"), patch.object(ci, "ensure_tag"), \
             patch.object(ci.release, "verify_package", return_value=[]), \
             patch.object(ci, "existing_release", side_effect=[None, draft, {**draft, "draft": False}]), \
             patch.object(ci, "verify_assets", return_value=[]), patch.object(ci.release, "run") as run:
            ci.publish()
            create = run.call_args_list[0].args
            self.assertNotIn("--prerelease", create)
            self.assertEqual(create[create.index("--title") + 1], f"Notch Companion {plan['metadata']['version']}")
        with patch.object(ci, "load_plan", return_value=plan), patch.object(ci, "make_plan", return_value=plan), \
             patch.object(ci, "authenticated_git"), patch.object(ci, "ensure_tag"), \
             patch.object(ci.release, "verify_package", return_value=[]), \
             patch.object(ci, "existing_release", return_value={**draft, "prerelease": True}), \
             patch.object(ci.release, "run") as run:
            with self.assertRaisesRegex(ValueError, "full release"):
                ci.publish()
            run.assert_not_called()

    def test_publish_waits_for_github_to_list_its_own_writes(self):
        # GitHub's release list lagged a new draft once (2026.11.8-r1); waiting must never create twice.
        plan = self.eligible_plan()
        paths = [self.root / "app.zip"]
        draft = {"id": 7, "prerelease": False, "draft": True, "html_url": "https://example.invalid/release"}
        with patch.object(ci, "load_plan", return_value=plan), patch.object(ci, "make_plan", return_value=plan), \
             patch.object(ci, "authenticated_git"), patch.object(ci, "ensure_tag"), \
             patch.object(ci.release, "verify_package", return_value=paths), \
             patch.object(ci, "existing_release", side_effect=[None, None, None, draft, draft, {**draft, "draft": False}]), \
             patch.object(ci, "verify_assets", side_effect=[paths, paths, []]), \
             patch.object(ci.time, "sleep") as sleep, patch.object(ci.release, "run") as run:
            ci.publish()
            commands = [call.args for call in run.call_args_list]
            self.assertEqual([command[:3] for command in commands],
                             [("gh", "release", "create"), ("gh", "release", "upload"), ("gh", "release", "edit")])
            self.assertEqual(sleep.call_count, 4)
        with patch.object(ci, "load_plan", return_value=plan), patch.object(ci, "make_plan", return_value=plan), \
             patch.object(ci, "authenticated_git"), patch.object(ci, "ensure_tag"), \
             patch.object(ci.release, "verify_package", return_value=[]), \
             patch.object(ci, "existing_release", return_value=None) as lookup, \
             patch.object(ci.time, "sleep"), patch.object(ci.release, "run") as run:
            with self.assertRaisesRegex(ValueError, "full release"):
                ci.publish()
            self.assertEqual(run.call_count, 1, "Created once, never again while waiting")
            self.assertEqual(lookup.call_count, 11)
        with patch.object(ci, "load_plan", return_value=plan), patch.object(ci, "make_plan", return_value=plan), \
             patch.object(ci, "authenticated_git"), patch.object(ci, "ensure_tag"), \
             patch.object(ci.release, "verify_package", return_value=[]), \
             patch.object(ci, "existing_release", side_effect=[{**draft, "draft": False}] + [{**draft, "id": 8, "draft": False}] * 10) as lookup, \
             patch.object(ci, "verify_assets", return_value=[]), \
             patch.object(ci.time, "sleep"), patch.object(ci.release, "run"):
            with self.assertRaisesRegex(ValueError, "not confirmed"):
                ci.publish()
            self.assertEqual(lookup.call_count, 11, "Another release under the tag never counts as this one")

    def test_published_retry_is_noop_and_never_repairs_changed_or_missing_assets(self):
        plan = self.eligible_plan()
        remote = {"id": 7, "prerelease": False, "draft": False, "html_url": "https://example.invalid/release"}
        with patch.object(ci, "load_plan", return_value=plan), patch.object(ci, "make_plan", return_value=plan), \
             patch.object(ci, "authenticated_git"), patch.object(ci, "ensure_tag"), \
             patch.object(ci.release, "verify_package", return_value=[]), \
             patch.object(ci, "existing_release", return_value=remote), \
             patch.object(ci, "verify_assets", return_value=[]) as verify, patch.object(ci.release, "run") as run:
            ci.publish()
            run.assert_not_called()
            verify.return_value = [self.root / "missing.zip"]
            with self.assertRaisesRegex(ValueError, "cannot be modified"):
                ci.publish()
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
