"""Gate regression tests run against disposable source copies, never the checkout."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("local_checks", Path(__file__).parents[1] / "check.py")
checks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checks)


class GateTests(unittest.TestCase):
    def setUp(self):
        # Missing tooling must fail, not silently skip the gate's regression tests.
        checks.check_swiftlint()
        self.temporary = tempfile.TemporaryDirectory(prefix="larmindon-gate-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("Sources", "Tests", "Widgets"):
            shutil.copytree(checks.ROOT / name, self.root / name)
        for name in ("Package.swift", "Project.swift", ".swiftlint.yml",
                     ".swiftlint-metrics.yml", ".swiftlint-baseline.json"):
            shutil.copy2(checks.ROOT / name, self.root / name)
        self.reports = self.root / "reports"

    def lint(self):
        with contextlib.redirect_stdout(io.StringIO()):
            checks.lint(self.root, checks.SWIFTLINT, self.reports)

    def test_baseline_is_portable_and_checks_do_not_rewrite_inputs(self):
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.lint()
        self.assertEqual(json.loads((self.reports / "lint.json").read_text()), [])
        metrics = json.loads((self.reports / "metrics.json").read_text())
        # Derive expected exceptions from the committed baseline so paying down debt
        # does not require freezing the original hotspot count in this test.
        baseline = json.loads((self.root / ".swiftlint-baseline.json").read_text())
        complexity = [r for r in metrics if r["rule_id"] == "cyclomatic_complexity"]
        self.assertGreaterEqual(len(complexity), len(baseline))
        for name, content in before.items():
            self.assertEqual((self.root / name).read_bytes(), content, str(name))

    def test_new_force_cast_fails(self):
        (self.root / "Sources/GateProbe.swift").write_text("func probe(_ value: Any) -> Int { value as! Int }\n")
        with self.assertRaisesRegex(checks.CheckFailure, "force_cast"):
            self.lint()

    def test_new_complex_function_fails(self):
        branches = "\n".join(f"    if value == {n} {{ print(value) }}" for n in range(11))
        (self.root / "Sources/GateProbe.swift").write_text(f"func probe(_ value: Int) {{\n{branches}\n}}\n")
        with self.assertRaisesRegex(checks.CheckFailure, "cyclomatic_complexity"):
            self.lint()

    def test_advisory_file_length_does_not_fail_gate(self):
        (self.root / "Sources/GateProbe.swift").write_text("// Long-file advisory fixture.\n" * 1001)
        self.lint()
        findings = json.loads((self.reports / "metrics.json").read_text())
        self.assertTrue(any(r["file"].endswith("GateProbe.swift") and r["rule_id"] == "file_length"
                            for r in findings))

    def test_unknown_rule_is_an_error_even_if_swiftlint_exits_zero(self):
        config = self.root / ".swiftlint.yml"
        config.write_text(config.read_text().replace("  - force_cast", "  - rule_that_does_not_exist"))
        with self.assertRaisesRegex(checks.CheckFailure, "not a valid rule"):
            self.lint()

    def test_empty_source_selection_fails(self):
        shutil.rmtree(self.root / "Sources")
        with self.assertRaisesRegex(checks.CheckFailure, "No intended Swift files"):
            self.lint()

    def test_missing_baseline_fails(self):
        (self.root / ".swiftlint-baseline.json").unlink()
        with self.assertRaisesRegex(checks.CheckFailure, "Missing required check input"):
            self.lint()


class RunnerTests(unittest.TestCase):
    def test_wrong_tool_version_fails(self):
        with self.assertRaisesRegex(checks.CheckFailure, "expected 0.65.1, found 0.64.0"):
            checks.require_version("SwiftLint", "0.64.0", "0.65.1")

    def test_missing_swiftlint_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(checks.CheckFailure, "setup"):
                checks.check_swiftlint(Path(temporary) / "missing")

    def test_simulator_selection_never_falls_back_to_another_runtime(self):
        inventory = {"devices": {"different-runtime": [
            {"name": checks.PINS["simulator_name"], "udid": "wrong", "isAvailable": True}]}}
        with self.assertRaisesRegex(checks.CheckFailure, "No OS=latest fallback"):
            checks.select_simulator(inventory)

    def test_duplicate_names_require_explicit_udid(self):
        devices = [{"name": checks.PINS["simulator_name"], "udid": value, "isAvailable": True}
                   for value in ("first", "second")]
        inventory = {"devices": {checks.PINS["simulator_runtime"]: devices}}
        with self.assertRaisesRegex(checks.CheckFailure, "found 2"):
            checks.select_simulator(inventory)
        self.assertEqual(checks.select_simulator(inventory, "second"), "second")

    def test_failed_build_command_propagates_and_preserves_log(self):
        with tempfile.TemporaryDirectory(dir=checks.ROOT / ".build") as temporary:
            reports = Path(temporary)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaisesRegex(checks.CheckFailure, "exit 7"):
                    checks.run_step("failed-build", [sys.executable, "-c", "print('build failed'); exit(7)"], reports)
            self.assertIn("build failed", (reports / "failed-build.log").read_text())


if __name__ == "__main__":
    unittest.main()
