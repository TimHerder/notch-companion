"""Offline allocation evidence, retry limits, source identity and publication routing."""

import copy
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("ci_runner", Path(__file__).resolve().parents[2] / "scripts/ci-runner.py")
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)
REPO = "TimHerder/notch-companion"


class RunnerRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(patch.stopall)
        patch("sys.stdout", new=io.StringIO()).start()
        patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}).start()
        self.run = {"id": 123, "run_attempt": 1, "status": "completed", "conclusion": "cancelled",
                    "name": "CI", "path": ".github/workflows/ci.yml", "head_sha": "a" * 40,
                    "head_repository": {"full_name": REPO}, "event": "pull_request",
                    "pull_requests": [{"number": 3}], "head_branch": "feature"}
        self.event = {"workflow_run": copy.deepcopy(self.run)}
        self.pr = {"state": "open", "author_association": "OWNER",
                   "head": {"sha": "a" * 40, "repo": {"full_name": REPO}},
                   "base": {"ref": "main", "repo": {"full_name": REPO}}}
        self.failed = {"id": 100, "name": f"{ci.STAGES['check'][0]} ({ci.ARM})",
                       "status": "completed", "conclusion": "cancelled", "labels": [ci.ARM],
                       "steps": [], "runner_id": 0, "runner_name": "",
                       "check_run_url": f"https://api.github.com/repos/{REPO}/check-runs/200"}
        self.selector = {"id": 99, "name": ci.STAGES["check"][1], "conclusion": "success"}
        self.jobs = {1: [self.selector, self.failed]}
        self.annotations = [{"annotation_level": "failure", "message": ci.ALLOCATION_ERROR}]
        self.posts = []
        self.api = patch.object(ci, "api", side_effect=self.respond).start()

    def respond(self, path, *, pages=False, method="GET"):
        if method == "POST":
            self.posts.append(path)
            return None
        if "/attempts/" in path:
            self.assertTrue(pages)
            attempt = int(path.split("/attempts/")[1].split("/")[0])
            # Exercise pagination, including an empty page.
            return [{"jobs": []}, {"jobs": self.jobs[attempt]}]
        if "/annotations" in path:
            self.assertTrue(pages)
            return [[], self.annotations]
        if "/pulls/" in path:
            return self.pr
        self.assertEqual(path, f"repos/{REPO}/actions/runs/123")
        return self.run

    def recover(self):
        ci.recover(REPO, self.event)

    def select(self, attempt, stage="check"):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "output"
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
                ci.select(REPO, "123", attempt, stage)
            return output.read_text().strip()

    def test_first_attempt_is_arm_without_api_or_manual_override(self):
        with patch.dict(os.environ, {"NOTCH_INTEL_RECOVERY_RUN_ID": "123"}):
            self.assertEqual(self.select(1), f"runner={ci.ARM}")
        self.api.assert_not_called()

    def test_confirmed_allocation_failure_reruns_selector_and_selects_intel(self):
        self.recover()
        self.assertEqual(self.posts, [f"repos/{REPO}/actions/jobs/99/rerun"])
        self.assertEqual(self.select(2), f"runner={ci.INTEL}")

    def test_test_build_setup_or_packaging_failure_never_falls_back(self):
        for step in ["Test and build", "Package the checked app", "Set up job"]:
            with self.subTest(step=step):
                self.failed.update(conclusion="failure", steps=[{"name": step, "conclusion": "failure"}])
                self.recover()
                self.assertEqual(self.select(2), f"runner={ci.ARM}")
        self.assertEqual(self.posts, [])

    def test_assigned_runner_without_steps_never_falls_back(self):
        for changes in [{"runner_id": 42}, {"runner_name": "GitHub Actions"}, {"runner_id": None}]:
            with self.subTest(changes=changes), patch.dict(self.failed, changes):
                self.assertFalse(ci.allocation_failed(REPO, self.failed))
        self.api.assert_not_called()

    def test_manual_cancel_capacity_notice_and_unknown_error_do_not_qualify(self):
        for annotations in [[], [{"annotation_level": "notice", "message": ci.ALLOCATION_ERROR}],
                            [{"annotation_level": "failure", "message": "Cancelled by user"}]]:
            with self.subTest(annotations=annotations):
                self.annotations = annotations
                self.recover()
                self.assertEqual(self.select(2), f"runner={ci.ARM}")
        self.assertEqual(self.posts, [])

    def test_intel_failure_or_already_attempted_recovery_is_terminal(self):
        self.jobs[2] = [{**self.failed, "name": f"{ci.STAGES['check'][0]} ({ci.INTEL})", "labels": [ci.INTEL]}]
        self.run["run_attempt"] = self.event["workflow_run"]["run_attempt"] = 2
        self.recover()
        self.assertEqual(self.select(3), f"runner={ci.ARM}")
        # A later manual ARM retry does not reset the automatic recovery budget.
        self.jobs[3] = self.jobs[1]
        self.run["run_attempt"] = self.event["workflow_run"]["run_attempt"] = 3
        self.recover()
        self.assertEqual(self.select(4), f"runner={ci.ARM}")
        self.assertEqual(self.posts, [])

    def test_publisher_retries_only_its_selector_retaining_successful_check(self):
        self.run.update(event="push", head_branch="main", pull_requests=[])
        self.failed["name"] = f"{ci.STAGES['publish'][0]} ({ci.ARM})"
        self.selector.update(name=ci.STAGES["publish"][1], id=98)
        self.jobs[1].append({"id": 97, "name": f"{ci.STAGES['check'][0]} ({ci.ARM})", "conclusion": "success"})
        self.recover()
        self.assertEqual(self.posts, [f"repos/{REPO}/actions/jobs/98/rerun"])
        self.assertEqual(self.select(2, "publish"), f"runner={ci.INTEL}")

    def test_publisher_can_recover_after_check_used_its_own_intel_retry(self):
        self.jobs[2] = [
            {"id": 98, "name": ci.STAGES["publish"][1], "conclusion": "success"},
            {**self.failed, "name": f"{ci.STAGES['publish'][0]} ({ci.ARM})"},
            {"name": f"{ci.STAGES['check'][0]} ({ci.INTEL})", "conclusion": "success"},
        ]
        self.run.update(event="push", head_branch="main", run_attempt=2)
        self.event["workflow_run"]["run_attempt"] = 2
        self.recover()
        self.assertEqual(self.posts, [f"repos/{REPO}/actions/jobs/98/rerun"])
        self.assertEqual(self.select(3, "publish"), f"runner={ci.INTEL}")

    def test_stale_closed_external_or_untrusted_pr_is_not_retried(self):
        for changes in [{"state": "closed"}, {"author_association": "CONTRIBUTOR"},
                        {"head": {"sha": "b" * 40, "repo": {"full_name": REPO}}},
                        {"head": {"sha": "a" * 40, "repo": {"full_name": "other/repo"}}},
                        {"base": {"ref": "other", "repo": {"full_name": REPO}}}]:
            with self.subTest(changes=changes), patch.dict(self.pr, changes):
                self.recover()
        self.assertEqual(self.posts, [])

    def test_ineligible_or_already_retried_run_is_not_retried(self):
        for changes in [{"event": "workflow_dispatch"}, {"head_repository": {"full_name": "other/repo"}},
                        {"path": ".github/workflows/other.yml"}, {"run_attempt": 2},
                        {"status": "in_progress"}, {"conclusion": "success"},
                        {"event": "push", "head_branch": "feature"}, {"pull_requests": []}]:
            with self.subTest(changes=changes), patch.dict(self.run, changes):
                self.recover()
        self.assertEqual(self.posts, [])

    def test_retry_race_does_not_post(self):
        calls = 0
        original = self.respond

        def changed_run(path, **kwargs):
            nonlocal calls
            if path.endswith("/runs/123"):
                calls += 1
                if calls == 2:
                    return {**self.run, "run_attempt": 2, "status": "queued"}
            return original(path, **kwargs)

        self.api.side_effect = changed_run
        self.recover()
        self.assertEqual(self.posts, [])

    def test_missing_selector_ambiguous_job_and_foreign_annotation_url_fail_closed(self):
        for jobs in [[self.failed], [self.selector, self.failed, self.failed],
                     [self.selector, {**self.failed, "check_run_url": "https://example.com/200"}]]:
            with self.subTest(jobs=jobs), patch.dict(self.jobs, {1: jobs}):
                self.recover()
        self.assertEqual(self.posts, [])

    def test_api_failure_never_posts_or_selects_intel(self):
        self.api.side_effect = RuntimeError("API unavailable")
        with self.assertRaisesRegex(RuntimeError, "API unavailable"):
            self.recover()
        with self.assertRaisesRegex(RuntimeError, "API unavailable"):
            self.select(2)
        self.assertEqual(self.posts, [])


if __name__ == "__main__":
    unittest.main()
