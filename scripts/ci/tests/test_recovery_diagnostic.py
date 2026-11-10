import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import recovery_diagnostic as diagnostic


class RecoveryDiagnosticTests(unittest.TestCase):
    sha = "a" * 40
    main_sha = "b" * 40
    repository = "WeOpen/WeGit"

    def pr(self, sha=None):
        return {"state": "open", "head": {"sha": sha or self.sha, "repo": {"full_name": self.repository}},
                "base": {"ref": "main", "repo": {"full_name": self.repository}}}

    def source(self, candidate="132", expected=None, read=None):
        return diagnostic.resolve_source(self.main_sha, self.repository, expected or self.sha,
                                         candidate, read or (lambda _: self.pr()))

    def test_explicit_main_and_same_repository_candidate_are_fixed(self):
        self.assertEqual(self.source(), self.sha)
        self.assertEqual(self.source(candidate="", expected=self.main_sha), self.main_sha)

    def test_mismatching_sha_and_moved_head_are_rejected(self):
        with self.assertRaises(ValueError):
            self.source(expected="c" * 40)
        responses = iter([self.pr(), self.pr("c" * 40)])
        with self.assertRaises(ValueError):
            self.source(read=lambda _: next(responses))

    def test_closed_fork_or_nonmain_candidate_is_rejected(self):
        for field in ("closed", "fork", "base"):
            value = self.pr()
            if field == "closed":
                value["state"] = "closed"
            elif field == "fork":
                value["head"]["repo"]["full_name"] = "other/WeGit"
            else:
                value["base"]["ref"] = "feature"
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.source(read=lambda _: value)

    def test_invalid_candidate_parameters_cannot_reach_the_api(self):
        for candidate in ("0", "-1", "132;echo secret"):
            with self.subTest(candidate=candidate), self.assertRaises(ValueError):
                self.source(candidate=candidate, read=lambda _: self.fail("API must not be called"))
        with self.assertRaises(ValueError):
            self.source(expected="main")

    def repository_fixture(self, root):
        environment = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
        def git(*arguments):
            return subprocess.check_output(["/usr/bin/git", "-C", str(root), *arguments], env=environment)
        git("init", "-b", "main")
        for name, data in {"WeGitCore/Domain/Sample.swift": b"import Foundation\n",
                           "WeGitCore/Resources/en.lproj/Localizable.strings": b'"sample" = "sample";\n',
                           "WeGitAskPass/main.swift": b"import Foundation\n",
                           "Package.swift": b"fatalError(\"candidate manifest must not execute\")\n"}.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        git("add", ".")
        git("-c", "user.name=Diagnostic Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "core.hooksPath=/dev/null", "commit", "--no-gpg-sign", "-m", "fixture")
        return git, git("rev-parse", "HEAD").decode().strip()

    def test_git_blobs_are_fixed_and_candidate_package_is_not_used(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, stage = root / "repo", root / "stage"
            repo.mkdir()
            stage.mkdir()
            _, sha = self.repository_fixture(repo)
            entries = diagnostic.extract_sources(repo, sha, stage)
            self.assertEqual(len(entries), 3)
            self.assertNotIn("Package.swift", entries)
            self.assertEqual((stage / "Package.swift").read_text(), diagnostic.PACKAGE)
            self.assertEqual(diagnostic.source_fingerprint(stage, entries),
                             {name: value["sha256"] for name, value in entries.items()})
            self.assertIn('resources: [.process("Resources")]', diagnostic.PACKAGE)
            self.assertIn('swiftLanguageModes: [.v6]', diagnostic.PACKAGE)
            self.assertIn('.macOS("26.0")', diagnostic.PACKAGE)
            self.assertNotIn("testTarget", diagnostic.PACKAGE)

    def test_symlink_and_gitlink_sources_are_rejected(self):
        for mode in ("symlink", "gitlink"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                repo, stage = root / "repo", root / "stage"
                repo.mkdir()
                stage.mkdir()
                git, sha = self.repository_fixture(repo)
                if mode == "symlink":
                    (repo / "WeGitCore/redirect").symlink_to("/tmp")
                    git("add", "WeGitCore/redirect")
                else:
                    git("update-index", "--add", "--cacheinfo", "160000," + sha + ",WeGitCore/child")
                git("-c", "user.name=Diagnostic Fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "core.hooksPath=/dev/null", "commit", "--no-gpg-sign", "-m", "redirect")
                head = git("rev-parse", "HEAD").decode().strip()
                with self.assertRaises(ValueError):
                    diagnostic.extract_sources(repo, head, stage)

    def test_source_addition_byte_change_and_package_change_are_detected(self):
        for mutation in ("added", "bytes", "package"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                repo, stage = root / "repo", root / "stage"
                repo.mkdir()
                stage.mkdir()
                _, sha = self.repository_fixture(repo)
                entries = diagnostic.extract_sources(repo, sha, stage)
                target = stage / ("WeGitCore/added.swift" if mutation == "added" else
                                  "WeGitCore/Domain/Sample.swift" if mutation == "bytes" else "Package.swift")
                target.write_text("changed")
                with self.assertRaises(ValueError):
                    diagnostic.source_fingerprint(stage, entries)

    def report(self):
        report = {"format": 1, "diagnosticOnly": True, "sourceCommit": self.sha,
                  "requiredSamples": 30, "allPassed": True, "workloads": [], "processTrace": []}
        for workload in ("ordinary", "large"):
            samples = []
            files, volume = (100, 16 * 1024 * 1024) if workload == "ordinary" else (1000, 256 * 1024 * 1024)
            for iteration in range(1, 31):
                samples.append(dict(iteration=iteration, residentBytes=16 * 1024 * 1024, backupBytes=16 * 1024 * 1024,
                                    wrapperPID=100 + iteration, childPID=200 + iteration,
                                    **{field: 100 if field != "cancelMilliseconds" else 1 for field in diagnostic.SAMPLE_FIELDS}))
                phases, commands = [], []
                for index, phase in enumerate(diagnostic.PHASES):
                    start = iteration * 10000 + index * 100
                    phases.append(dict(phase=phase, startNanoseconds=start, endNanoseconds=start + 50, completed=True))
                    commands.append(dict(phase=phase, command="diff", state="exited", exitCode=0,
                                         startNanoseconds=start + 1, endNanoseconds=start + 25))
                report["processTrace"].append(dict(workload=workload, iteration=iteration, phases=phases,
                                                    commands=commands, droppedCommandEvents=0))
            report["workloads"].append(dict(name=workload, samples=samples, files=files,
                                            bytes=((volume - files * 256) // files) * files))
        return report

    def test_complete_original_samples_and_command_ranges_are_recomputed(self):
        values = diagnostic.verify_report(self.report(), self.sha)
        self.assertEqual(set(values), {"ordinary", "large"})
        self.assertTrue(all(value["measurementPassed"] for value in values.values()))
        self.assertTrue(all(value["validSamples"] == 30 for value in values.values()))

    def test_overlapping_commands_count_wall_time_once(self):
        trace = dict(phases=[dict(phase="reset", startNanoseconds=0, endNanoseconds=10_000_000)],
                     commands=[dict(phase="reset", command="diff", startNanoseconds=1_000_000, endNanoseconds=6_000_000),
                               dict(phase="reset", command="reset", startNanoseconds=4_000_000, endNanoseconds=8_000_000)])
        values = diagnostic.phase_breakdown(trace)["reset"]
        self.assertEqual(values["callMilliseconds"], 10)
        self.assertEqual(values["processWallMilliseconds"], 7)
        self.assertEqual(values["outsideProcessMilliseconds"], 3)
        self.assertEqual(sum(values["commandTotalMilliseconds"].values()), 9)

    def test_overlapping_sample_phases_are_rejected(self):
        report = self.report()
        report["processTrace"][0]["phases"][1]["startNanoseconds"] -= 100
        with self.assertRaises(ValueError):
            diagnostic.verify_report(report, self.sha)

    def test_original_reset_and_memory_budgets_cannot_be_claimed_passed(self):
        for field, value in (("resetMilliseconds", 2209), ("residentBytes", 513 * 1024 * 1024)):
            report = self.report()
            for sample in report["workloads"][1]["samples"][-2:]:
                sample[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                diagnostic.verify_report(report, self.sha)
            report["allPassed"] = False
            self.assertFalse(diagnostic.verify_report(report, self.sha)["large"]["measurementPassed"])

    def test_missing_truncated_duplicate_or_escaped_timings_are_rejected(self):
        for mutation in ("missing", "dropped", "duplicate", "escaped", "wrong-phase", "missing-phase-command"):
            report = self.report()
            if mutation == "missing":
                report.pop("processTrace")
            elif mutation == "dropped":
                report["processTrace"][0]["droppedCommandEvents"] = 1
            elif mutation == "duplicate":
                report["processTrace"][1] = copy.deepcopy(report["processTrace"][0])
            elif mutation == "escaped":
                report["processTrace"][0]["commands"][0]["endNanoseconds"] += 10000
            elif mutation == "wrong-phase":
                report["processTrace"][0]["phases"][0]["phase"] = "reset"
            else:
                report["processTrace"][0]["commands"].pop()
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                diagnostic.verify_report(report, self.sha)

    def test_partial_failed_sample_keeps_its_timings_without_inventing_counts(self):
        report = self.report()
        report.update(allPassed=False, workloads=[])
        trace = report["processTrace"][0]
        trace["phases"] = trace["phases"][:1]
        trace["phases"][0]["completed"] = False
        trace["commands"] = trace["commands"][:1]
        trace["commands"][0].update(state="cancelled", exitCode=None)
        report["processTrace"] = [trace]
        self.assertEqual(diagnostic.verify_report(report, self.sha), {})

    def test_missing_samples_source_or_nonfinite_values_are_rejected(self):
        for mutation in ("samples", "source", "nan"):
            report = self.report()
            if mutation == "samples":
                report["workloads"][0]["samples"].pop()
            elif mutation == "source":
                report["sourceCommit"] = "c" * 40
            else:
                report["workloads"][0]["samples"][0]["resetMilliseconds"] = float("nan")
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                diagnostic.verify_report(report, self.sha)

    def test_boolean_or_float_integer_fields_and_fixture_changes_are_rejected(self):
        mutations = [lambda r: r.update(format=True), lambda r: r.update(requiredSamples=30.0),
                     lambda r: r["processTrace"][0].update(iteration=True),
                     lambda r: r["processTrace"][0].update(droppedCommandEvents=False),
                     lambda r: r["processTrace"][0]["phases"][0].update(startNanoseconds=True),
                     lambda r: r["processTrace"][0]["commands"][0].update(endNanoseconds=True),
                     lambda r: r["workloads"][0].update(files=True),
                     lambda r: r["workloads"][1].update(bytes=32),
                     lambda r: r["workloads"][0]["samples"][0].update(iteration=True),
                     lambda r: r["workloads"][0]["samples"][0].update(residentBytes=16000000.0),
                     lambda r: r["workloads"][0]["samples"][0].update(backupBytes=257 * 1024 * 1024),
                     lambda r: r["workloads"][0]["samples"][0].update(wrapperPID=True)]
        for index, mutation in enumerate(mutations):
            report = self.report()
            mutation(report)
            with self.subTest(index=index), self.assertRaises(ValueError):
                diagnostic.verify_report(report, self.sha)

    def test_timeout_stops_the_owned_command_and_preserves_the_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "timeout.log"
            with self.assertRaises(subprocess.TimeoutExpired):
                diagnostic.bounded_command([sys.executable, "-u", "-c", "import time; print('started'); time.sleep(10)"],
                                           Path(temporary), dict(os.environ), log, 0.1)
            self.assertIn("started", log.read_text())

    def test_timeout_stops_separate_owned_process_group_and_preserves_unrelated_process(self):
        program = '''import json,os,signal,subprocess,sys,time
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"], preexec_fn=os.setpgrp)
def finish(number, frame):
    child.wait(timeout=5)
    raise SystemExit(0)
signal.signal(signal.SIGTERM, finish)
print(json.dumps({"parent":os.getpid(),"child":child.pid,"childGroup":os.getpgid(child.pid),"session":os.getsid(child.pid)}), flush=True)
time.sleep(20)
'''
        with tempfile.TemporaryDirectory() as temporary:
            outsider = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"], start_new_session=True)
            try:
                log = Path(temporary) / "independent-groups.log"
                with self.assertRaises(subprocess.TimeoutExpired):
                    diagnostic.bounded_command([sys.executable, "-u", "-c", program], Path(temporary),
                                               dict(os.environ), log, 0.5)
                processes = json.loads(log.read_text().splitlines()[0])
                self.assertEqual(processes["child"], processes["childGroup"])
                self.assertEqual(processes["session"], processes["parent"])
                self.assertNotEqual(processes["parent"], processes["childGroup"])
                proof = json.loads(log.with_suffix(".cleanup.json").read_text())
                self.assertEqual(proof["remainingRunningProcesses"], [])
                self.assertEqual({entry["group"] for entry in proof["signalledGroups"]},
                                 {processes["parent"], processes["childGroup"]})
                self.assertEqual({entry["session"] for entry in proof["ownedProcesses"]}, {processes["parent"]})
                for group in (processes["parent"], processes["childGroup"]):
                    with self.assertRaises(ProcessLookupError):
                        os.killpg(group, 0)
                self.assertIsNone(outsider.poll())
            finally:
                outsider.send_signal(signal.SIGTERM)
                outsider.wait(timeout=5)

    def test_runtime_environment_isolated_without_mutating_user_home(self):
        with patch.dict(os.environ, {"GH_TOKEN": "secret", "ACTIONS_RUNTIME_TOKEN": "secret", "GIT_DIR": "/private", "GITHUB_TOKEN": "secret"}):
            environment = diagnostic.isolated_environment()
        self.assertNotIn("GH_TOKEN", environment)
        self.assertNotIn("ACTIONS_RUNTIME_TOKEN", environment)
        self.assertNotIn("GITHUB_TOKEN", environment)
        self.assertNotIn("GIT_DIR", environment)
        self.assertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(environment["GIT_CONFIG_SYSTEM"], "/dev/null")
        self.assertEqual(environment.get("HOME"), os.environ.get("HOME"))

    def test_fixed_package_and_compiler_caches_stay_in_private_staging(self):
        stage = Path("/private/owned-stage")
        command = diagnostic.package_command(stage)
        for option in ("--package-path", "--scratch-path", "--cache-path", "--config-path", "--security-path"):
            self.assertTrue(Path(command[command.index(option) + 1]).is_relative_to(stage))
        self.assertIn("--disable-dependency-cache", command)
        self.assertEqual(command[command.index("--manifest-cache") + 1], "local")
        self.assertIn(str(stage / "module-cache"), command)
        self.assertNotIn("test", command)

    def test_compile_failure_retains_source_binding_and_never_writes_canonical_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            _, sha = self.repository_fixture(repo)
            output = root / "wegit-recovery-diagnostic"
            trusted = output / "trusted"
            trusted.mkdir(parents=True)
            hashes = {}
            project = Path(__file__).resolve().parents[3]
            for name in diagnostic.TRUSTED_FILES:
                data = (project / name).read_bytes()
                (trusted / Path(name).name).write_bytes(data)
                hashes[Path(name).name] = diagnostic.digest(data)
            diagnostic.write_json(output / "source-resolution.json",
                                  {"diagnosticOnly": True, "requiredValidation": False,
                                   "sourceCommit": sha, "trustedMainSHA": self.main_sha,
                                   "trustedFilesSHA256": hashes})
            def fail(command, working, environment, log, timeout):
                log.write_text("actual private compile failure\n")
                return 1
            with patch.dict(os.environ, RUNNER_TEMP=str(root), GITHUB_WORKSPACE=str(repo)), \
                    patch.object(diagnostic, "toolchain", return_value={}), \
                    patch.object(diagnostic, "bounded_command", side_effect=fail), self.assertRaises(SystemExit):
                diagnostic.run(output)
            receipt = json.loads((output / "diagnostic-receipt.json").read_text())
            self.assertEqual(receipt["outcome"], "failed")
            self.assertEqual(receipt["buildExitCode"], 1)
            self.assertEqual(receipt["sourceBeforeSHA256"], receipt["sourceAfterSHA256"])
            self.assertTrue(receipt["diagnosticOnly"])
            self.assertFalse(receipt["requiredValidation"])
            self.assertFalse(receipt["uiSmokeExecuted"])
            self.assertFalse(receipt["xctestExecuted"])
            self.assertNotIn("suite", receipt)
            self.assertNotIn("status", receipt)
            self.assertIn("actual private compile failure", (output / "build.log").read_text())

    def test_output_redirect_is_rejected_before_candidate_can_supply_any_write_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "other").mkdir()
            (root / "wegit-recovery-diagnostic").symlink_to(root / "other", target_is_directory=True)
            with patch.dict(os.environ, RUNNER_TEMP=str(root)), self.assertRaises(ValueError):
                diagnostic.output_directory()

    def test_workflow_is_main_only_trusted_and_diagnostic(self):
        workflow = (Path(__file__).resolve().parents[3] / ".github/workflows/recovery-performance.yml").read_text()
        self.assertIn("if: github.ref == 'refs/heads/main'", workflow)
        self.assertIn("if: always()", workflow)
        self.assertIn('"$RUNNER_TEMP/wegit-recovery-diagnostic/trusted/recovery_diagnostic.py" run', workflow)
        self.assertLess(workflow.index("recovery_diagnostic.py resolve"), workflow.index("ref: ${{ steps.source.outputs.sha }}"))
        self.assertNotIn("run-batch-suite", workflow)
        self.assertNotIn("swift test", workflow)
        self.assertNotIn("ui_probe", workflow)
        self.assertNotIn("batch_evidence", workflow)


if __name__ == "__main__":
    unittest.main()
