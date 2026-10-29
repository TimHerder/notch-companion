#!/usr/bin/env python3
"""Plan, package checked CI output, and publish immutable main-merge betas."""

import argparse
import base64
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from zoneinfo import ZoneInfo

import release

TAG_PATTERN = re.compile(r"v(\d{4}\.[1-9]\d?\.[1-9]\d?-r[1-9]\d*)")
APP_FILES = {"Package.swift", "Package.resolved", "LICENSE", "scripts/build-app.sh",
             "scripts/release.py", "scripts/ci-release.py"}


def git(*args):
    return release.run("git", *args, capture=True)


def api(path, pages=False):
    args = ["gh", "api", path]
    if pages:
        args += ["--paginate", "--slurp"]
    value = json.loads(release.run(*args, capture=True))
    return [item for page in value for item in page] if pages else value


def context():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise ValueError("CI helpers require a GitHub Actions event; use release.py for local releases.")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    repo = os.environ["GITHUB_REPOSITORY"]
    sha = os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or release.clean_commit() != sha:
        raise ValueError("CI must check out the exact clean GITHUB_SHA.")
    if event.get("repository", {}).get("full_name") != repo or release.configured_repo() != repo:
        raise ValueError("GitHub event, workflow repository and origin must identify the same repository.")
    run_id = os.environ["GITHUB_RUN_ID"]
    if not run_id.isdigit():
        raise ValueError("Invalid workflow run identity.")
    return event, repo, sha, run_id


def affects_app(paths):
    return any(path.startswith(("Sources/", "app/")) or path in APP_FILES for path in paths)


def is_ancestor(older, newer):
    result = subprocess.run(["git", "merge-base", "--is-ancestor", older, newer], cwd=release.ROOT)
    if result.returncode not in (0, 1):
        raise ValueError("Cannot establish release ancestry; fetch complete history and tags.")
    return result.returncode == 0


def release_tags():
    """Every version tag counts, including tags whose GitHub release is a draft."""
    result = []
    for tag in git("tag", "--list", "v*").splitlines():
        match = TAG_PATTERN.fullmatch(tag)
        if not match:
            continue
        commit = git("rev-parse", f"{tag}^{{commit}}")
        annotation = None
        if git("cat-file", "-t", f"refs/tags/{tag}") == "tag":
            try:
                annotation = json.loads(git("for-each-ref", "--format=%(contents)", f"refs/tags/{tag}"))
            except ValueError:
                pass  # Legacy manually annotated tags use a human-readable title.
        if isinstance(annotation, dict) and "notch_release" in annotation:
            fields = {"notch_release", "version", "build", "commit", "repository", "run_id", "created_at", "pull_request"}
            if (set(annotation) != fields or annotation["notch_release"] != 1
                    or annotation.get("commit") != commit or annotation.get("version") != match[1]):
                raise ValueError(f"Invalid automated release annotation: {tag}")
            info = release.validate_version({key: annotation[key] for key in ("version", "build")})
        else:
            annotation = None
            info = release.validate_version(json.loads(git("show", f"{tag}:app/version.json")))
            if info["version"] != match[1] or "preview" in info:
                raise ValueError(f"Legacy tag and source version disagree, or identify a preview: {tag}")
        result.append({"tag": tag, "commit": commit, "metadata": info, "annotation": annotation})
    return result


def allocate_version(tags, base, sha, created_at, repo, run_id, pull_request):
    automated = [tag for tag in tags if tag["annotation"] is not None]
    if any(tag["annotation"].get("repository") != repo for tag in automated):
        raise ValueError("Automated release tags belong to a different repository.")
    if any(tag["commit"] != sha and is_ancestor(sha, tag["commit"]) for tag in automated):
        return None  # A newer checked commit won the serialized release queue.
    same = [tag for tag in automated if tag["commit"] == sha]
    if len(same) > 1:
        raise ValueError("Multiple automated release tags identify this commit; refusing ambiguous retry.")
    if same:
        return same[0]["annotation"]
    day = datetime.fromisoformat(created_at.replace("Z", "+00:00")).astimezone(ZoneInfo("Europe/Berlin"))
    prefix = f"{day.year}.{day.month}.{day.day}-r"
    revision = 1 + max([int(tag["tag"][1:].split("-r")[1]) for tag in tags
                        if tag["tag"][1:].startswith(prefix)] or [0])
    build = 1 + max([base["build"]] + [tag["metadata"]["build"] for tag in tags])
    info = release.validate_version({"version": prefix + str(revision), "build": build})
    return {"notch_release": 1, **info, "commit": sha, "repository": repo,
            "run_id": run_id, "created_at": created_at, "pull_request": pull_request}


def make_plan():
    event, repo, sha, run_id = context()
    kind = os.environ["GITHUB_EVENT_NAME"]
    base = release.version_info()  # Never read an inherited, not-yet-generated override.
    if "preview" in base:
        raise ValueError("Preview metadata belongs in build/ci-version.json, never app/version.json.")
    plan = {"mode": "check", "reason": "not a merged app-changing main push", "event": kind,
            "repository": repo, "commit": sha, "run_id": run_id, "metadata": base}
    if kind == "pull_request":
        pr = event["pull_request"]
        if (pr.get("head", {}).get("repo", {}).get("full_name") != repo
                or pr.get("base", {}).get("repo", {}).get("full_name") != repo
                or pr.get("author_association") not in {"OWNER", "MEMBER", "COLLABORATOR"}):
            plan["reason"] = "previews are restricted to collaborators in this repository"
            return plan
        head = pr["head"]["sha"]
        number = event["number"]
        if not re.fullmatch(r"[0-9a-f]{40}", head) or type(number) is not int or number < 1:
            raise ValueError("Invalid preview pull request identity.")
        plan.update(mode="preview", reason="collaborator pull request", preview_head=head,
                    metadata=release.validate_version({**base, "preview": f"pr-{number}-{head[:12]}"}))
        return plan
    if (kind != "push" or os.environ.get("GITHUB_REF") != "refs/heads/main"
            or event.get("ref") != "refs/heads/main" or event.get("after") != sha or event.get("deleted")):
        return plan
    before = event.get("before", "")
    if not re.fullmatch(r"[0-9a-f]{40}", before) or before == "0" * 40 or not is_ancestor(before, sha):
        plan["reason"] = "a normal main fast-forward push is required"
        return plan
    prs = api(f"repos/{repo}/commits/{sha}/pulls", pages=True)
    merged = [pr for pr in prs if pr.get("merged_at") and pr.get("merge_commit_sha") == sha
              and pr.get("base", {}).get("ref") == "main"
              and pr.get("base", {}).get("repo", {}).get("full_name") == repo]
    if not merged:
        return plan
    # Treat renames as removal + addition so moving an app file out of Sources
    # cannot hide its removal behind a documentation-only destination path.
    if not affects_app(git("diff", "--name-only", "--no-renames", "-z", before, sha).split("\0")):
        plan["reason"] = "documentation and test changes do not create an app release"
        return plan
    run = api(f"repos/{repo}/actions/runs/{run_id}")
    if str(run.get("id")) != run_id or run.get("head_sha") != sha or run.get("event") != "push":
        raise ValueError("Workflow run metadata does not match this main push.")
    annotation = allocate_version(release_tags(), base, sha, run["created_at"], repo, run_id, merged[0]["number"])
    if annotation is None:
        plan["reason"] = "newer-release"
        return plan
    plan.update(mode="release", reason="merged app-changing pull request", before=before,
                metadata={key: annotation[key] for key in ("version", "build")}, annotation=annotation,
                tag="v" + annotation["version"])
    return plan


def write_plan():
    plan = make_plan()
    build = release.ROOT / "build"
    build.mkdir(exist_ok=True)
    (build / "ci-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    (build / "ci-version.json").write_text(json.dumps(plan["metadata"], indent=2) + "\n")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
    if not attempt.isdigit():
        raise ValueError("Invalid workflow attempt.")
    label = "preview-" + plan["metadata"]["preview"] if plan["mode"] == "preview" else plan["metadata"]["version"]
    outputs = {"mode": plan["mode"], "eligible": str(plan["mode"] == "release").lower(),
               "version": plan["metadata"]["version"], "build": str(plan["metadata"]["build"]),
               "artifact_name": f"notch-companion-{label}-attempt{attempt}",
               "version_file": "build/ci-version.json", "plan_path": "build/ci-plan.json",
               "package_path": "build/ci-package"}
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as file:
            file.writelines(f"{key}={value}\n" for key, value in outputs.items())
    print(json.dumps(outputs))
    print(plan["reason"])


def load_plan():
    _, repo, sha, run_id = context()
    plan = json.loads((release.ROOT / "build/ci-plan.json").read_text())
    if (plan.get("repository"), plan.get("commit"), plan.get("run_id"), plan.get("event")) != (repo, sha, run_id, os.environ["GITHUB_EVENT_NAME"]):
        raise ValueError("Artifact plan does not match this workflow, event and checked commit.")
    if release.version_info("build/ci-version.json") != plan.get("metadata"):
        raise ValueError("Artifact plan and generated version file disagree.")
    return plan


def package_checked():
    plan = load_plan()
    if plan["mode"] not in {"release", "preview"}:
        raise ValueError("Check-only runs do not create downloadable packages.")
    if plan != make_plan():
        raise ValueError("Release allocation or eligibility changed after checking. Rerun this workflow.")
    release.package_checked(plan["metadata"], plan["commit"], release.ROOT / "build/ci-package")


def authenticated_git(*args, capture=False, env=None):
    # A process-only header keeps credentials out of arguments and persisted Git config.
    settings = dict(os.environ) if env is None else dict(env)
    token = settings.get("GH_TOKEN", "")
    if not token:
        raise ValueError("The trusted publisher requires its workflow token.")
    count = int(settings.get("GIT_CONFIG_COUNT", "0"))
    settings.update({"GIT_CONFIG_COUNT": str(count + 1),
                     f"GIT_CONFIG_KEY_{count}": "http.https://github.com/.extraheader",
                     f"GIT_CONFIG_VALUE_{count}": "AUTHORIZATION: basic " + base64.b64encode(("x-access-token:" + token).encode()).decode()})
    result = subprocess.run(["git", *args], cwd=release.ROOT, env=settings, check=True,
                            text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def ensure_tag(plan):
    tag, sha, annotation = plan["tag"], plan["commit"], plan["annotation"]
    existing = next((item for item in release_tags() if item["tag"] == tag), None)
    if existing and (existing["commit"] != sha or existing["annotation"] != annotation):
        raise ValueError("Release tag already exists with different source or metadata.")
    if not existing:
        settings = dict(os.environ, GIT_COMMITTER_DATE=annotation["created_at"])
        subprocess.run(["git", "-c", "user.name=github-actions[bot]", "-c",
                        "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                        "tag", "-a", tag, sha, "-m", json.dumps(annotation, sort_keys=True)],
                       cwd=release.ROOT, env=settings, check=True)
    authenticated_git("push", "origin", f"refs/tags/{tag}")
    remote = authenticated_git("ls-remote", "origin", f"refs/tags/{tag}", capture=True)
    if not remote or remote.split()[0] != git("rev-parse", f"refs/tags/{tag}"):
        raise ValueError("Remote tag does not match the immutable annotated release tag.")


def existing_release(repo, tag):
    matches = [item for item in api(f"repos/{repo}/releases", pages=True) if item["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError("Multiple releases identify this tag.")
    return matches[0] if matches else None


def verify_assets(repo, remote, assets):
    expected = {path.name: path for path in assets}
    uploaded = api(f"repos/{repo}/releases/{remote['id']}/assets", pages=True)
    names = [item["name"] for item in uploaded]
    if len(set(names)) != len(names) or set(names) - set(expected):
        raise ValueError("Existing release has unexpected or duplicate assets; refusing replacement.")
    for item in uploaded:
        local = expected[item["name"]]
        if item["size"] != local.stat().st_size:
            raise ValueError(f"Existing release asset differs: {local.name}")
        with tempfile.TemporaryDirectory(prefix="notch-ci-download-") as directory:
            downloaded = Path(directory) / local.name
            with downloaded.open("wb") as file:
                subprocess.run(["gh", "api", f"repos/{repo}/releases/assets/{item['id']}",
                                "-H", "Accept: application/octet-stream"], cwd=release.ROOT, stdout=file, check=True)
            if release.digest(downloaded) != release.digest(local):
                raise ValueError(f"Existing release asset differs: {local.name}")
    return [path for name, path in expected.items() if name not in names]


def publish():
    plan = load_plan()
    if (os.environ["GITHUB_EVENT_NAME"] != "push" or os.environ.get("GITHUB_REF") != "refs/heads/main"
            or plan["mode"] != "release" or "preview" in plan["metadata"]):
        raise ValueError("Only a checked, eligible main push can publish; previews can never publish.")
    authenticated_git("fetch", "--tags", "origin")
    fresh = make_plan()
    if fresh["reason"] == "newer-release":
        print("Skipping older source: a descendant already has an automated release tag.")
        return
    if fresh != plan:
        raise ValueError("Publication plan changed or no longer matches the exact merged PR; rerun checks.")
    assets = release.verify_package(release.ROOT / "build/ci-package", plan["metadata"], plan["commit"])
    ensure_tag(plan)
    repo, tag = plan["repository"], plan["tag"]
    remote = existing_release(repo, tag)
    if remote is None:
        release.run("gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--draft", "--prerelease",
                    "--generate-notes", "--title", f"Notch Companion {plan['metadata']['version']} Beta")
        remote = existing_release(repo, tag)
    if remote is None or not remote["prerelease"]:
        raise ValueError("Expected an existing beta release for the verified tag.")
    missing = verify_assets(repo, remote, assets)
    if missing and not remote["draft"]:
        raise ValueError("A published release is missing expected assets; it cannot be modified.")
    for asset in missing:
        release.run("gh", "release", "upload", tag, str(asset), "--repo", repo)
    if missing and verify_assets(repo, remote, assets):
        raise ValueError("Release upload is incomplete; retry with this same artifact.")
    if remote["draft"]:
        release.run("gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--prerelease")
    final = existing_release(repo, tag)
    if final is None or final["draft"] or not final["prerelease"]:
        raise ValueError("GitHub has not confirmed beta publication.")
    print(f"Verified beta release: {final['html_url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "package", "publish"))
    args = parser.parse_args()
    try:
        {"plan": write_plan, "package": package_checked, "publish": publish}[args.action]()
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"CI release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
