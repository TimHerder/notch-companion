#!/usr/bin/env python3
"""One Intel retry per stage, only after GitHub confirms an ARM allocation failure."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ARM = "macos-26"
INTEL = "macos-26-intel"
STAGES = {
    "check": ("Offline tests and app build", "Select check runner"),
    "publish": ("Publish beta release", "Select publication runner"),
}
ALLOCATION_ERROR = "The job was not acquired by Runner of type hosted even after multiple attempts"


def api(path, *, pages=False, method="GET"):
    args = ["gh", "api", "--method", method, path]
    if pages:
        args += ["--paginate", "--slurp"]
    output = subprocess.check_output(args, text=True)
    return json.loads(output) if output.strip() else None


def jobs_for(repo, run_id, attempt):
    pages = api(f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100", pages=True)
    return [job for page in pages for job in page["jobs"]]


def allocation_failed(repo, job):
    if (job.get("status") != "completed" or job.get("conclusion") not in {"cancelled", "failure"}
            or job.get("labels") != [ARM] or job.get("steps") != []
            or job.get("runner_id") != 0 or job.get("runner_name") != ""):
        return False
    prefix = f"https://api.github.com/repos/{repo}/check-runs/"
    url = job.get("check_run_url", "")
    if not url.startswith(prefix) or not url[len(prefix):].isdigit():
        return False
    pages = api(f"repos/{repo}/check-runs/{url[len(prefix):]}/annotations?per_page=100", pages=True)
    # A capacity notice alone also appears on successful jobs; require the error.
    return any(item.get("annotation_level") == "failure" and item.get("message") == ALLOCATION_ERROR
               for page in pages for item in page)


def recovery_stage(repo, run_id, attempt, stage):
    """Return the successful selector to rerun, or None. Older attempts bound retries."""
    name, selector = STAGES[stage]
    jobs = jobs_for(repo, run_id, attempt)
    failed = [job for job in jobs if job["name"] == f"{name} ({ARM})"]
    selectors = [job for job in jobs if job["name"] == selector and job.get("conclusion") == "success"]
    if len(failed) != 1 or len(selectors) != 1 or not allocation_failed(repo, failed[0]):
        return None
    for previous in range(1, attempt + 1):
        history = jobs if previous == attempt else jobs_for(repo, run_id, previous)
        if any(job["name"] == f"{name} ({INTEL})" for job in history):
            return None
    return selectors[0]


def select(repo, run_id, attempt, stage):
    runner = ARM
    if attempt > 1 and recovery_stage(repo, run_id, attempt - 1, stage):
        runner = INTEL
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"runner={runner}\n")
    report(f"{stage}: {runner}. " + (
        "Confirmed ARM allocation failure; using the single Intel recovery attempt. "
        "Intel tests do not establish native ARM execution; the packaged app remains arm64."
        if runner == INTEL else "Native ARM remains the preferred path."))


def current_source(repo, run):
    if run.get("head_repository", {}).get("full_name") != repo:
        return False
    if run.get("event") == "push":
        return run.get("head_branch") == "main"
    if run.get("event") != "pull_request" or len(run.get("pull_requests", [])) != 1:
        return False
    number = run["pull_requests"][0]["number"]
    if type(number) is not int or number < 1:
        return False
    pr = api(f"repos/{repo}/pulls/{number}")
    return (pr.get("state") == "open" and pr.get("head", {}).get("sha") == run.get("head_sha")
            and pr.get("head", {}).get("repo", {}).get("full_name") == repo
            and pr.get("base", {}).get("repo", {}).get("full_name") == repo
            and pr.get("base", {}).get("ref") == "main"
            and pr.get("author_association") in {"OWNER", "MEMBER", "COLLABORATOR"})


def recover(repo, event):
    source = event["workflow_run"]
    run_id, attempt = source["id"], source["run_attempt"]
    if type(run_id) is not int or run_id < 1 or type(attempt) is not int or not 1 <= attempt < 50:
        raise ValueError("Invalid source run or attempt.")
    path = f"repos/{repo}/actions/runs/{run_id}"
    run = api(path)
    if (run.get("id") != run_id or run.get("run_attempt") != attempt
            or run.get("status") != "completed" or run.get("conclusion") not in {"cancelled", "failure"}
            or run.get("path") != ".github/workflows/ci.yml" or run.get("name") != "CI"
            or run.get("head_sha") != source.get("head_sha") or not current_source(repo, run)):
        report("No recovery: run is ineligible, already retried, or superseded.")
        return
    for stage in STAGES:
        selector = recovery_stage(repo, run_id, attempt, stage)
        if selector is None:
            continue
        # Refresh after inspection so duplicate events or a manual retry cannot race us.
        fresh = api(path)
        if fresh.get("run_attempt") != attempt or fresh.get("status") != "completed" or not current_source(repo, fresh):
            report("No recovery: run or source changed during inspection.")
            return
        job_id = selector["id"]
        if type(job_id) is not int or job_id < 1:
            raise ValueError("Invalid selector job ID.")
        api(f"repos/{repo}/actions/jobs/{job_id}/rerun", method="POST")
        report(f"Requested Intel recovery for {stage} in run {run_id}. "
               "Only its selector and dependent jobs are rerun; successful prerequisites are retained.")
        return
    report("No recovery: no confirmed ARM allocation failure, or Intel recovery was already attempted.")


def report(message):
    print(message)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(message + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["select", "recover"])
    parser.add_argument("stage", nargs="?", choices=STAGES)
    args = parser.parse_args()
    repo = os.environ["GITHUB_REPOSITORY"]
    if os.environ.get("GITHUB_ACTIONS") != "true" or repo != "TimHerder/notch-companion":
        raise ValueError("Recovery is restricted to this repository's hosted Actions workflows.")
    if args.action == "select":
        run_id, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
        if not re.fullmatch(r"[1-9][0-9]*", run_id) or not attempt.isdigit() or not 1 <= int(attempt) <= 50 or not args.stage:
            raise ValueError("Selection requires a valid run, attempt and stage.")
        select(repo, run_id, int(attempt), args.stage)
    else:
        if os.environ.get("GITHUB_EVENT_NAME") != "workflow_run" or args.stage:
            raise ValueError("Recovery requires a workflow_run event and no stage argument.")
        recover(repo, json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()))


if __name__ == "__main__":
    main()
