import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from change_scope import changed_paths, classify, scope_for_event
from check_ci_results import required_results
from check_policy import Loader
import yaml


class ChangeScopeTests(unittest.TestCase):
    def test_site_and_its_compatibility_entries_skip_unrelated_checks(self):
        for paths in [["site/src/routes/index.tsx"], ["site/package-lock.json", "site/tests/new.test.mjs"],
                      ["scripts/build_website.py"], ["scripts/ci/tests/test_website.py"],
                      ["site/README.md", "HANDOFF.MD"], ["site/目录/换行\n名.svg"]]:
            with self.subTest(paths=paths):
                self.assertTrue(classify(paths)["site_only"])
                self.assertTrue(classify(paths)["site_changed"])

    def test_full_scope_remains_for_application_shared_infrastructure_and_doc_only(self):
        for paths in [[], ["HANDOFF.MD"], ["AGENTS.md"], ["WeGit/App/AppState.swift"],
                      ["site/README.md", "WeGitCore/GitCore/RepositoryService.swift"],
                      ["site/README.md", ".github/workflows/verify.yml"],
                      ["design/brand/source/git-symbol.svg"], ["site2/src/index.tsx"]]:
            with self.subTest(paths=paths):
                self.assertFalse(classify(paths)["site_only"])
        self.assertTrue(classify(["design/brand/source/git-symbol.svg"])["site_changed"])
        self.assertTrue(classify([".github/workflows/verify.yml"])["site_changed"])

    def test_invalid_path_lists_cannot_skip_full_checks(self):
        for path in ["/site/file", "site/../WeGit/file", "site//file", "site/./file", "site/file\0", None]:
            with self.subTest(path=path):
                self.assertEqual(classify([path]), {"site_only": False, "site_changed": True, "changed_file_count": 1})

    def test_unknown_manual_and_initial_push_ranges_run_full_validation(self):
        events = [("workflow_dispatch", {}), ("push", {"before":"0" * 40,"after":"a" * 40}),
                  ("pull_request", {"pull_request":{"base":{"sha":"--help"},"head":{"sha":"a" * 40}}})]
        for name, event in events:
            self.assertFalse(scope_for_event(Path.cwd(), event, name)["site_only"])
            self.assertFalse(scope_for_event(Path.cwd(), event, name)["range_verified"])


class GitRangeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="wegit-ci-scope-")
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_SYSTEM=os.devnull, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0",
                        GIT_AUTHOR_NAME="Scope fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Scope fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        self.git("init", "--initial-branch=main")
        self.write("WeGitCore/source.swift", "base\n")
        self.write("site/README.md", "site base\n")
        self.base = self.commit("base")

    def git(self, *args):
        return subprocess.check_output(["git","-C",str(self.root),*args], env=self.env,
                                       stderr=subprocess.DEVNULL, text=True).strip()

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message):
        self.git("add", "--all")
        self.git("-c", "commit.gpgsign=false", "commit", "-m", message)
        return self.git("rev-parse", "HEAD")

    def pr(self, base, head):
        return {"pull_request":{"base":{"sha":base},"head":{"sha":head}}}

    def test_native_to_site_rename_includes_both_paths(self):
        self.git("mv", "WeGitCore/source.swift", "site/source.swift")
        head = self.commit("move")
        paths = changed_paths(self.root, self.pr(self.base, head), "pull_request")
        self.assertEqual(set(paths), {"WeGitCore/source.swift", "site/source.swift"})
        self.assertFalse(classify(paths)["site_only"])

    def test_deleted_native_file_cannot_be_hidden_by_a_site_change(self):
        (self.root / "WeGitCore/source.swift").unlink()
        self.write("site/README.md", "site changed\n")
        head = self.commit("delete")
        self.assertFalse(scope_for_event(self.root, self.pr(self.base, head), "pull_request")["site_only"])

    def test_pr_three_dot_excludes_changes_that_only_happened_on_base(self):
        self.git("switch", "-c", "feature")
        self.write("site/README.md", "feature\n")
        head = self.commit("site feature")
        self.git("switch", "main")
        self.write("WeGitCore/source.swift", "new main content\n")
        base = self.commit("main advances")
        paths = changed_paths(self.root, self.pr(base, head), "pull_request")
        self.assertEqual(paths, ["site/README.md"])
        self.assertTrue(classify(paths)["site_only"])

    def test_push_range_covers_all_commits(self):
        self.write("WeGitCore/source.swift", "native change\n")
        self.commit("native")
        self.write("site/README.md", "site change\n")
        head = self.commit("site")
        scope = scope_for_event(self.root, {"before":self.base,"after":head}, "push")
        self.assertFalse(scope["site_only"])
        self.assertEqual(scope["changed_file_count"], 2)

    def test_unavailable_commit_does_not_skip_native(self):
        scope = scope_for_event(self.root, self.pr("a" * 40, self.base), "pull_request")
        self.assertFalse(scope["site_only"])
        self.assertFalse(scope["range_verified"])


class RequiredResultTests(unittest.TestCase):
    def needs(self, site_only=False, site_changed=True):
        return {"changes":{"result":"success","outputs":{"site_only":str(site_only).lower(),
                    "site_changed":str(site_changed).lower()}},
                "policy":{"result":"skipped" if site_only else "success"},
                "native":{"result":"skipped" if site_only else "success"},
                "site":{"result":"success" if site_changed else "skipped"}}

    def test_site_only_requires_only_site(self):
        self.assertEqual(required_results(self.needs(site_only=True)), ["site"])

    def test_full_and_mixed_scopes_require_their_real_results(self):
        self.assertEqual(required_results(self.needs(site_changed=False)), ["policy", "native"])
        self.assertEqual(required_results(self.needs()), ["policy", "native", "site"])

    def test_failure_cancellation_skip_and_missing_required_results_block_merging(self):
        for only_site in [True, False]:
            keys = ["site"] if only_site else ["policy", "native", "site"]
            for key in keys:
                for result in ["failure", "cancelled", "skipped", None]:
                    needs = self.needs(site_only=only_site)
                    needs[key]["result"] = result
                    with self.subTest(site_only=only_site, key=key, result=result), self.assertRaises(ValueError):
                        required_results(needs)

    def test_missing_failed_or_inconsistent_scope_never_passes(self):
        for mutation in [lambda n:n.pop("changes"), lambda n:n["changes"].update(result="failure"),
                         lambda n:n["changes"].update(result="skipped"),
                         lambda n:n["changes"].update(outputs={}),
                         lambda n:n["changes"]["outputs"].update(site_only=True),
                         lambda n:n["changes"]["outputs"].update(site_only="true", site_changed="false")]:
            needs = self.needs()
            mutation(needs)
            with self.assertRaises(ValueError):
                required_results(needs)


class WorkflowRoutingTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[3]
        self.ci = yaml.load((self.root / ".github/workflows/verify.yml").read_text(), Loader=Loader)

    def test_required_name_and_always_gate_remain_with_all_applicable_jobs(self):
        gate = self.ci["jobs"]["required"]
        self.assertEqual(gate["name"], "Repository policy")
        self.assertEqual(gate["if"], "always()")
        self.assertEqual(set(gate["needs"]), {"changes", "policy", "native", "site"})
        self.assertEqual(self.ci["jobs"]["policy"]["name"], "Repository validation")
        self.assertEqual(self.ci["jobs"]["native"]["runs-on"], "xcode-27")

    def test_site_scope_controls_all_unrelated_validation_jobs(self):
        for name in ["policy", "native"]:
            self.assertEqual(self.ci["jobs"][name]["if"], "needs.changes.outputs.site_only != 'true'")
        pr = yaml.load((self.root / ".github/workflows/pr-policy.yml").read_text(), Loader=Loader)
        self.assertEqual(pr["jobs"]["pr-policy"]["if"], "needs.changes.outputs.site_only != 'true'")
        self.assertEqual(self.ci["jobs"]["site"]["if"], "needs.changes.outputs.site_changed == 'true'")

    def test_site_pr_validation_is_not_duplicated_in_deployment_workflows(self):
        for name in ["pages.yml", "workers.yml"]:
            workflow = yaml.load((self.root / ".github/workflows" / name).read_text(), Loader=Loader)
            self.assertNotIn("pull_request", workflow["on"])
            self.assertIn("push", workflow["on"])
        site_steps = self.ci["jobs"]["site"]["steps"]
        scripts = "\n".join(step.get("run", "") for step in site_steps)
        self.assertIn("npm run check:budget", scripts)
        self.assertIn("npx wrangler deploy --dry-run", scripts)
        self.assertIn("npm run test:worker", scripts)
        self.assertIn("scripts.ci.tests.test_website", scripts)


if __name__ == "__main__":
    unittest.main()
