import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_policy import check_pr, check_workflow, validate_issue_targets, Loader
from project_setup import issue_marker, plan


class PolicyTests(unittest.TestCase):
    def event(self, title="fix(diff): preserve tabs", body="Closes #42"):
        return {"pull_request": {"title": title, "body": body, "user": {"login": "contributor"}}}

    def test_pr_tracks_a_real_requirement_not_a_template_comment(self):
        self.assertEqual(check_pr(self.event()), [42])
        self.assertEqual(check_pr(self.event(body="Refs #17\nCloses #42")), [17, 42])
        with self.assertRaises(ValueError):
            check_pr(self.event(body="<!-- Closes #42 -->"))
        with self.assertRaises(ValueError):
            check_pr(self.event(body="Closes #"))

    def test_invalid_titles_and_zero_issue_are_rejected(self):
        for event in [self.event(title="change stuff"), self.event(body="Closes #0")]:
            with self.assertRaises(ValueError):
                check_pr(event)

    def test_dependabot_is_the_only_bot_exemption(self):
        event = self.event(title="chore(deps): update action", body="Automated dependency update")
        event["pull_request"]["user"]["login"] = "dependabot[bot]"
        self.assertEqual(check_pr(event), [])
        event["pull_request"]["user"]["login"] = "fake-dependabot"
        with self.assertRaises(ValueError):
            check_pr(event)

    def test_issue_targets_must_include_open_issue_not_pr(self):
        validate_issue_targets([42], lambda _: {"state": "open"})
        for issue in [{"state": "closed"}, {"state": "open", "pull_request": {}}]:
            with self.assertRaises(ValueError):
                validate_issue_targets([42], lambda _: issue)

    def workflow(self):
        return {"on": {"pull_request": {}}, "permissions": {"contents": "read"},
                "concurrency": "ci-pr", "jobs": {"check": {"runs-on": "ubuntu-24.04", "timeout-minutes": 10,
                "steps": [{"uses": "actions/checkout@" + "a" * 40, "with": {"persist-credentials": False}}]}}}

    def test_pr_never_reaches_self_hosted_or_privileged_trigger(self):
        for mutate in [lambda w: w["on"].update({"pull_request_target": {}}),
                       lambda w: w["jobs"]["check"].update({"runs-on": ["self-hosted"]})]:
            workflow = self.workflow()
            mutate(workflow)
            with self.assertRaises(ValueError):
                check_workflow(workflow, "verify.yml")

    def test_mutable_action_and_inline_input_are_rejected(self):
        for step in [{"uses": "actions/checkout@v7"}, {"run": "echo ${{ inputs.tag }}"},
                     {"run": "false", "continue-on-error": True}]:
            workflow = self.workflow()
            workflow["jobs"]["check"]["steps"] = [step]
            with self.assertRaises(ValueError):
                check_workflow(workflow, "verify.yml")

    def test_only_release_publish_job_may_write_contents(self):
        workflow = self.workflow()
        workflow["jobs"]["check"]["permissions"] = {"contents": "write"}
        with self.assertRaises(ValueError):
            check_workflow(workflow, "verify.yml")
        check_workflow(self.workflow(), "verify.yml")

    def test_pages_privilege_cannot_move_to_a_build_or_another_workflow(self):
        workflow = self.workflow()
        workflow["jobs"]["check"]["permissions"] = {"pages": "write", "id-token": "write"}
        with self.assertRaises(ValueError):
            check_workflow(workflow, "verify.yml")

    def test_pages_deploy_rejects_prs_and_repository_code_with_write_permission(self):
        import copy
        import yaml
        path = Path(__file__).resolve().parents[3] / ".github/workflows/pages.yml"
        source = yaml.load(path.read_text(), Loader=Loader)
        check_workflow(source, "pages.yml")
        for mutation in [lambda job: job.update({"if": "true"}),
                         lambda job: job.update({"needs": []}),
                         lambda job: job["steps"].append({"run": "python3 untrusted.py"})]:
            workflow = copy.deepcopy(source)
            mutation(workflow["jobs"]["deploy"])
            with self.assertRaises(ValueError):
                check_workflow(workflow, "pages.yml")

    def test_backlog_setup_is_idempotent_and_preserves_closed_work(self):
        label = {"name": "bug", "color": "d73a4a", "description": "A bug"}
        milestone = {"title": "V1.0", "description": "Release"}
        issue = {"key": "ui", "title": "Native UI"}
        first = plan([label], [milestone], [issue], [], [], [])
        self.assertEqual([op[0] for op in first], ["create-label", "create-milestone", "create-issue"])
        existing = {"body": issue_marker("ui") + "\nHuman edits", "state": "closed"}
        self.assertEqual(plan([label], [milestone], [issue], [label], [milestone], [existing]), [])

class GitIsolationTests(unittest.TestCase):
    def test_private_global_config_remains_writable_for_checkout_cleanup(self):
        import os
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "environment"
            environment = dict(os.environ, RUNNER_TEMP=str(root), GITHUB_ENV=str(output))
            script = Path(__file__).resolve().parents[1] / "isolate-git.sh"
            subprocess.run(["bash", str(script)], env=environment, check=True)
            isolated = dict(line.split("=", 1) for line in output.read_text().splitlines())
            config = Path(isolated["GIT_CONFIG_GLOBAL"])
            self.assertEqual(config.parent, root)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            subprocess.run(["git", "config", "--global", "--add", "safe.directory", "/fixture"],
                           env=environment | isolated, check=True)
            self.assertIn("/fixture", config.read_text())
            self.assertEqual(isolated["GIT_CONFIG_SYSTEM"], "/dev/null")


if __name__ == "__main__":
    unittest.main()
