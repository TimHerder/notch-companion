#!/usr/bin/env python3
"""Build a local release ZIP; optionally upload that exact ZIP as a draft.

Edit app/version.json and commit first. Uploads require the matching tag to
already exist on origin. Nothing here publishes a release or replaces an asset.
"""

import argparse
from datetime import date
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Notch Companion.app"


def run(*args, capture=False):
    result = subprocess.run(args, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def validate_version(info):
    match = re.fullmatch(r"(\d{4})\.([1-9]\d?)\.([1-9]\d?)-r([1-9]\d*)", info["version"])
    if not match:
        raise ValueError("Version must be YYYY.M.D-rN without leading zeroes (for example 2026.10.27-r1).")
    date(*map(int, match.groups()[:3]))
    if type(info["build"]) is not int or not 1 <= info["build"] <= 9999:
        raise ValueError("Build must be an increasing integer from 1 through 9999.")
    if set(info) - {"version", "build", "preview"}:
        raise ValueError("Unexpected version metadata fields.")
    if "preview" in info and not re.fullmatch(r"pr-[1-9]\d*-[0-9a-f]{12}", info["preview"]):
        raise ValueError("Preview must identify the pull request and its 12-character head revision.")
    return info


def version_info(path=None):
    # Explicit overrides are generated artifacts, never edits to tracked source.
    selected = (ROOT / path).resolve() if path else ROOT / "app/version.json"
    if path and (ROOT / "build").resolve() not in selected.parents:
        raise ValueError("NOTCH_VERSION_FILE must be inside this checkout's ignored build directory.")
    return validate_version(json.loads(selected.read_text()))


def version_fields(info):
    fields = {
        "CFBundleShortVersionString": info["version"].split("-r")[0],
        "CFBundleVersion": str(info["build"]),
        "NotchCompanionReleaseVersion": info["version"],
    }
    if "preview" in info:
        fields["NotchCompanionPreview"] = info["preview"]
    return fields


def stamp(plist_path, info):
    with plist_path.open("rb") as file:
        plist = plistlib.load(file)
    plist.pop("NotchCompanionPreview", None)
    plist.update(version_fields(info))
    with plist_path.open("wb") as file:
        plistlib.dump(plist, file, sort_keys=False)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(app, info):
    with (app / "Contents/Info.plist").open("rb") as file:
        plist = plistlib.load(file)
    for key, value in version_fields(info).items():
        if plist.get(key) != value:
            raise ValueError(f"{app}: {key} does not match the selected version metadata.")
    if "preview" not in info and "NotchCompanionPreview" in plist:
        raise ValueError("A preview bundle cannot be verified or published as a release.")
    executable = app / "Contents/MacOS/NotchCompanion"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f"Missing executable: {executable}")
    if os.fsencode(ROOT) in executable.read_bytes():
        raise ValueError("Release executable contains the local checkout path. Remove debug paths and absolute resource fallbacks before packaging.")
    resources = app / "Contents/Resources"
    license_path = resources / "LICENSE"
    if not license_path.is_file() or digest(license_path) != digest(ROOT / "LICENSE"):
        raise ValueError("Missing or changed packaged license.")
    if digest(resources / "AppIcon.icns") != digest(ROOT / "app/AppIcon.icns"):
        raise ValueError("Packaged icon does not match the source icon.")
    bundles = list(resources.glob("*.bundle"))
    for source in (ROOT / "Sources/NotchCompanion/Resources").rglob("*"):
        if not source.is_file() or source.name.startswith(".") or "__pycache__" in source.parts:
            continue
        matches = [path for bundle in bundles for path in bundle.rglob(source.name) if path.is_file()]
        if not any(digest(path) == digest(source) for path in matches):
            raise ValueError(f"Missing or changed packaged resource: {source.name}")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    print(f"Verified bundle, resources and version: {app}")


def clean_commit():
    revision = run("git", "rev-parse", "--verify", "HEAD", capture=True)
    if run("git", "status", "--porcelain", "--untracked-files=all", capture=True):
        raise ValueError("Release requires a clean, committed checkout. Commit source and version changes first.")
    return revision


def configured_repo():
    origin = run("git", "remote", "get-url", "origin", capture=True)
    match = re.fullmatch(r"(?:git@github\.com:|https://github\.com/)([\w.-]+/notch-companion)(?:\.git)?", origin)
    if not match:
        raise ValueError("Draft releases require origin to point to the new GitHub notch-companion repository.")
    return match[1]


def release_repo(tag, revision):
    repo = configured_repo()
    refs = run("git", "ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}", capture=True)
    refs = dict(line.split()[::-1] for line in refs.splitlines())
    tag_commit = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
    if tag_commit != revision:
        raise ValueError(f"Push tag {tag} at the current commit to origin before requesting --draft. Existing tags must never be moved.")
    return repo


def archive_name(info):
    label = "preview-" + info["preview"] if "preview" in info else info["version"]
    return f"Notch-Companion-{label}-arm64.zip"


def verify_package(folder, info, revision):
    manifest = json.loads((folder / "release.json").read_text())
    expected_archive = archive_name(info)
    if manifest != {**info, "commit": revision, "architecture": "arm64", "archive": expected_archive}:
        raise ValueError("Existing package belongs to another commit, version or architecture. Use a new release version.")
    expected = "".join(f"{digest(folder / name)}  {name}\n" for name in [expected_archive, "release.json"])
    if (folder / "SHA256SUMS").read_text() != expected:
        raise ValueError("Release package checksum mismatch; refusing upload.")
    with tempfile.TemporaryDirectory(prefix="notch-release-verify-") as temporary:
        run("/usr/bin/ditto", "-x", "-k", str(folder / expected_archive), temporary)
        app = Path(temporary) / APP_NAME
        verify(app, info)
        if run("/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/NotchCompanion"), capture=True) != "arm64":
            raise ValueError("Initial release packages must contain an Apple Silicon (arm64) binary.")
    return [folder / expected_archive, folder / "SHA256SUMS", folder / "release.json"]


def package_checked(info, revision, folder):
    """Package an already checked bundle. Only CI bypasses the local check run."""
    if sys.platform != "darwin":
        raise ValueError("Release packaging requires macOS.")
    if clean_commit() != revision:
        raise ValueError("Packaging requires the exact clean commit that was checked.")
    if folder.exists():
        return verify_package(folder, info, revision)
    app = ROOT / "build" / APP_NAME
    verify(app, info)
    folder.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".release-", dir=folder.parent) as temporary:
        stage = Path(temporary)
        archive = stage / archive_name(info)
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
        manifest = {**info, "commit": revision, "architecture": "arm64", "archive": archive.name}
        (stage / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (stage / "SHA256SUMS").write_text("".join(
            f"{digest(path)}  {path.name}\n" for path in [archive, stage / "release.json"]))
        verify_package(stage, info, revision)
        if clean_commit() != revision:
            raise ValueError("Source changed while packaging.")
        stage.rename(folder)
    return [folder / name for name in [archive.name, "SHA256SUMS", "release.json"]]


def package(info, draft):
    if sys.platform != "darwin":
        raise ValueError("Release packaging requires macOS.")
    revision = clean_commit()
    if draft and "preview" in info:
        raise ValueError("Preview packages can never be uploaded as releases.")
    tag = "v" + info["version"]
    repo = release_repo(tag, revision) if draft else None
    folder = ROOT / "build/releases" / (info.get("preview") or tag)
    if folder.exists() and not draft:
        raise ValueError(f"Release output already exists: {folder}. Use --draft to upload the verified package, or choose a new version.")
    if not folder.exists():
        run(str(ROOT / "scripts/check.sh"))
        if clean_commit() != revision:
            raise ValueError("Source changed during checks. Start again from a clean committed checkout.")
        package_checked(info, revision, folder)
    assets = verify_package(folder, info, revision)
    if clean_commit() != revision:
        raise ValueError("Source changed while packaging. Refusing draft upload.")
    if draft:
        release_repo(tag, revision)
        # --verify-tag and the absence of --clobber prevent tag/asset replacement.
        run("gh", "release", "create", tag, *map(str, assets), "--repo", repo,
            "--verify-tag", "--draft", "--prerelease", "--generate-notes",
            "--title", f"Notch Companion {info['version']}")
        print("Draft prerelease created. Test the downloaded ZIP before publishing it manually.")
    print(f"Release package: {folder}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", nargs="?", choices=["package", "stamp", "verify"], default="package")
    parser.add_argument("path", nargs="?", type=Path, help="Info.plist for stamp; .app bundle for verify")
    parser.add_argument("--draft", action="store_true", help="create a draft prerelease; requires an existing matching origin tag")
    args = parser.parse_args()
    if (args.action != "package" and (args.path is None or args.draft)) or (args.action == "package" and args.path):
        parser.error("stamp/verify require a path; --draft is only supported for package")
    try:
        info = version_info(os.environ.get("NOTCH_VERSION_FILE"))
        if args.action == "stamp":
            stamp(args.path, info)
        elif args.action == "verify":
            verify(args.path, info)
        else:
            package(info, args.draft)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"Release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
