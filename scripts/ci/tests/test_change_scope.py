import os
import json
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
                      ["site/src/index.tsx", "site/README.md", "HANDOFF.MD"], ["site/目录/换行\n名.svg"]]:
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
        self.assertFalse(classify([".github/workflows/verify.yml"])["site_changed"])

    def test_documentation_is_identified_before_site_prefix(self):
        for paths in [["site/README.md", "HANDOFF.MD"], ["site/guide.MD", "docs/V2_0_PLAN.md"], ["site/docs/help.txt"]]:
            scope = classify(paths)
            self.assertTrue(scope["docs_only"])
            self.assertFalse(scope["site_changed"])
            self.assertFalse(scope["backend_changed"])

    def test_drafts_and_middle_heads_wait_for_a_deliberate_batch_request(self):
        from change_scope import validation_requested
        scope = classify(["WeGitCore/GitCore/GitEngine.swift"])
        for action in ["synchronize", "reopened", "converted_to_draft", "edited", "unlabeled"]:
            event = {"action": action, "pull_request": {"draft": False, "labels": [{"name": "batch:validate"}]}}
            self.assertFalse(validation_requested(event, "pull_request", scope))
        for action in ["opened", "ready_for_review", "labeled"]:
            event = {"action": action, "label": {"name": "batch:validate"}, "pull_request": {"draft": False}}
            self.assertTrue(validation_requested(event, "pull_request", scope))
            event["pull_request"]["draft"] = True
            self.assertFalse(validation_requested(event, "pull_request", scope))
        self.assertTrue(validation_requested({"action": "synchronize"}, "pull_request", classify(["site/README.md"])))

    def test_only_backend_code_schedules_costly_backend_validation(self):
        for path in ["WeGitCore/GitCore/GitEngine.swift", "WeGitCore/Infrastructure/ProcessRunner.swift",
                     "WeGitCore/Domain/Models.swift", "WeGitAskPass/WeGitAskPass.swift", "Package.swift",
                     "WeGit/App/AppState.swift", "WeGit/App/SyncState.swift", "WeGit/Features/CloneViewModel.swift"]:
            with self.subTest(path=path):
                scope = classify([path])
                self.assertTrue(scope["backend_changed"])
                self.assertTrue(scope["policy_changed"])
                self.assertFalse(scope["frontend_changed"])

    def test_frontend_documentation_and_ci_do_not_schedule_backend(self):
        for path in ["WeGit/Features/ChangesView.swift", "WeGit/DesignSystem/AppColors.swift",
                     "WeGit/App/WeGitApp.swift", "WeGitCore/Domain/Localization.swift",
                     "WeGitCore/Resources/en.lproj/MenuTitles.strings", "WeGitUITests/LayoutTests.swift",
                     "project.yml", "WeGit.xcodeproj/project.pbxproj", "README.md", "HANDOFF.MD",
                     "docs/GITHUB_WORKFLOW.md", "AGENTS.md", "design/brand/source/git-symbol.svg",
                     ".github/workflows/verify.yml", "scripts/ci/change_scope.py", "site/src/routes/index.tsx"]:
            with self.subTest(path=path):
                self.assertFalse(classify([path])["backend_changed"])
        self.assertTrue(classify(["WeGit/Features/ChangesView.swift"])["frontend_changed"])
        self.assertTrue(classify(["README.md", "HANDOFF.MD"])["docs_only"])
        self.assertTrue(classify([".github/workflows/verify.yml"])["policy_changed"])
        self.assertFalse(classify(["README.md"])["policy_changed"])

    def test_test_sources_only_compile_without_backend_suites(self):
        scope = classify(["WeGitTests/DiskDiffTests.swift"])
        self.assertFalse(scope["backend_changed"])
        self.assertTrue(scope["core_tests_changed"])

    def test_invalid_path_lists_cannot_skip_full_checks(self):
        for path in ["/site/file", "site/../WeGit/file", "site//file", "site/./file", "site/file\0", None]:
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    classify([path])

    def test_unknown_ranges_fail_without_scheduling_costly_jobs(self):
        events = [("push", {"before":"0" * 40,"after":"a" * 40}),
                  ("pull_request", {"pull_request":{"base":{"sha":"--help"},"head":{"sha":"a" * 40}}})]
        for name, event in events:
            with self.assertRaises(ValueError):
                scope_for_event(Path.cwd(), event, name)

    def test_manual_backend_validation_requires_explicit_choice(self):
        self.assertFalse(scope_for_event(Path.cwd(), {}, "workflow_dispatch")["backend_changed"])
        self.assertTrue(scope_for_event(Path.cwd(), {}, "workflow_dispatch")["site_changed"])
        scope = scope_for_event(Path.cwd(), {"inputs":{"backend_validation":"true","site_validation":"false"}}, "workflow_dispatch")
        self.assertTrue(scope["backend_changed"])
        self.assertFalse(scope["site_changed"])


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
        self.assertTrue(classify(paths)["docs_only"])

    def test_push_range_covers_all_commits(self):
        self.write("WeGitCore/source.swift", "native change\n")
        self.commit("native")
        self.write("site/README.md", "site change\n")
        head = self.commit("site")
        scope = scope_for_event(self.root, {"before":self.base,"after":head}, "push")
        self.assertFalse(scope["site_only"])
        self.assertEqual(scope["changed_file_count"], 2)

    def test_unavailable_commit_does_not_skip_native(self):
        with self.assertRaises(ValueError):
            scope_for_event(self.root, self.pr("a" * 40, self.base), "pull_request")

    def run_doc_check(self, head):
        event = self.root / "event.json"
        event.write_text(json.dumps(self.pr(self.base, head)))
        script = Path(__file__).resolve().parents[1] / "check_docs.py"
        return subprocess.run([sys.executable, str(script), "--event", str(event)], cwd=self.root,
                              env=self.env | {"GITHUB_EVENT_NAME":"pull_request"}, capture_output=True, text=True)

    def test_documentation_links_pass_without_backend_validation(self):
        self.write("README.md", "[Guide](docs/guide.md)\n")
        self.write("docs/guide.md", "Guide\n")
        head = self.commit("docs")
        scope = scope_for_event(self.root, self.pr(self.base, head), "pull_request")
        self.assertFalse(scope["backend_changed"])
        self.assertTrue(scope["docs_only"])
        result = self.run_doc_check(head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 changed files", result.stdout)

    def test_broken_documentation_link_fails_its_own_lightweight_check(self):
        self.write("README.md", "[Missing](docs/missing.md)\n")
        head = self.commit("broken docs")
        result = self.run_doc_check(head)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing documentation link", result.stderr)


class RequiredResultTests(unittest.TestCase):
    def needs(self, backend=False, site=True, policy=False, frontend=False, tests=False, docs=False):
        values = {"backend_changed":backend, "policy_changed":backend or policy, "site_changed":site,
                  "frontend_changed":frontend, "core_tests_changed":tests, "docs_only":docs,
                  "validation_requested":True}
        return {"changes":{"result":"success","outputs":{key:str(value).lower() for key,value in values.items()}},
                "policy":{"result":"success" if backend or policy else "skipped"},
                "native":{"result":"success" if backend else "skipped"},
                "site":{"result":"success" if site else "skipped"},
                "frontend":{"result":"success" if frontend else "skipped"},
                "test_compile":{"result":"success" if tests else "skipped"},
                "docs":{"result":"success" if docs else "skipped"}}

    def test_site_only_requires_only_site(self):
        self.assertEqual(required_results(self.needs()), ["site"])

    def test_full_and_mixed_scopes_require_their_real_results(self):
        self.assertEqual(set(required_results(self.needs(backend=True, site=False))), {"policy", "native"})
        self.assertEqual(set(required_results(self.needs(backend=True))), {"policy", "native", "site"})
        self.assertEqual(required_results(self.needs(site=False, docs=True)), ["docs"])
        self.assertEqual(required_results(self.needs(site=False, frontend=True)), ["frontend"])
        self.assertEqual(required_results(self.needs(site=False, policy=True)), ["policy"])
        self.assertEqual(required_results(self.needs(site=False, tests=True)), ["test_compile"])

    def test_failure_cancellation_skip_and_missing_required_results_block_merging(self):
        for backend in [True, False]:
            keys = ["policy", "native", "site"] if backend else ["site"]
            for key in keys:
                for result in ["failure", "cancelled", "skipped", None]:
                    needs = self.needs(backend=backend)
                    needs[key]["result"] = result
                    with self.subTest(backend=backend, key=key, result=result), self.assertRaises(ValueError):
                        required_results(needs)

    def test_missing_failed_or_inconsistent_scope_never_passes(self):
        for mutation in [lambda n:n.pop("changes"), lambda n:n["changes"].update(result="failure"),
                         lambda n:n["changes"].update(result="skipped"),
                         lambda n:n["changes"].update(outputs={}),
                         lambda n:n["changes"]["outputs"].update(backend_changed=True),
                         lambda n:n["changes"]["outputs"].update(backend_changed="true", policy_changed="false")]:
            needs = self.needs()
            mutation(needs)
            with self.assertRaises(ValueError):
                required_results(needs)

    def test_deferred_backend_never_passes_by_skipping_its_required_job(self):
        needs = self.needs(backend=True)
        needs["changes"]["outputs"]["validation_requested"] = "false"
        needs["native"]["result"] = "skipped"
        with self.assertRaisesRegex(ValueError, "awaits batch validation"):
            required_results(needs)


class WorkflowRoutingTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[3]
        self.ci = yaml.load((self.root / ".github/workflows/verify.yml").read_text(), Loader=Loader)

    def test_required_name_and_always_gate_remain_with_all_applicable_jobs(self):
        gate = self.ci["jobs"]["required"]
        self.assertEqual(gate["name"], "Repository policy")
        self.assertEqual(gate["if"], "always()")
        self.assertEqual(set(gate["needs"]), {"changes", "policy", "native", "site", "frontend", "test_compile", "docs"})
        self.assertEqual(self.ci["jobs"]["policy"]["name"], "Repository validation")
        self.assertEqual(self.ci["jobs"]["native"]["runs-on"], "xcode-27")

    def test_site_scope_controls_all_unrelated_validation_jobs(self):
        self.assertEqual(self.ci["jobs"]["policy"]["if"], "needs.changes.outputs.policy_changed == 'true'")
        self.assertEqual(self.ci["jobs"]["native"]["if"], "needs.changes.outputs.backend_changed == 'true' && needs.changes.outputs.validation_requested == 'true'")
        pr = yaml.load((self.root / ".github/workflows/pr-policy.yml").read_text(), Loader=Loader)
        self.assertEqual(pr["jobs"]["pr-policy"]["if"], "needs.changes.outputs.backend_changed == 'true'")
        self.assertEqual(self.ci["jobs"]["site"]["if"], "needs.changes.outputs.site_changed == 'true' && needs.changes.outputs.validation_requested == 'true'")

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

    def test_frontend_and_test_checks_only_compile(self):
        frontend = self.ci["jobs"]["frontend"]
        scripts = "\n".join(step.get("run", "") for step in frontend["steps"])
        self.assertIn("build-for-testing", scripts)
        self.assertNotIn("test-without-building", scripts)
        self.assertNotIn("verify.sh", scripts)
        compile_steps = self.ci["jobs"]["test_compile"]["steps"]
        self.assertIn("swift build --build-tests", "\n".join(step.get("run", "") for step in compile_steps))
        self.assertFalse(self.ci["on"]["workflow_dispatch"]["inputs"]["backend_validation"]["default"])


if __name__ == "__main__":
    unittest.main()
