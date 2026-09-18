#!/usr/bin/env python3
"""Local, read-only quality gates. Standard library only; setup is explicit."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
PINS = json.loads((ROOT / "scripts/checks-toolchain.json").read_text())
SWIFTLINT = ROOT / ".build/check-tools" / PINS["swiftlint_version"] / "swiftlint"


class CheckFailure(Exception):
    pass


def capture(command, cwd=ROOT):
    result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise CheckFailure(f"{' '.join(map(str, command))}\n{result.stdout}{result.stderr}")
    return result.stdout.strip()


def require_version(label, actual, expected):
    if actual != expected:
        raise CheckFailure(f"{label}: expected {expected}, found {actual}. "
                           "Use the pinned tool; change pins only as an explicit upgrade.")


def check_xcode():
    expected = f"Xcode {PINS['xcode_version']}\nBuild version {PINS['xcode_build']}"
    require_version("Xcode (select with DEVELOPER_DIR)", capture(["xcodebuild", "-version"]), expected)
    swift = capture(["xcrun", "swift", "--version"])
    match = re.search(r"Apple Swift version ([\d.]+)", swift)
    require_version("Swift", match.group(1) if match else swift, PINS["swift_version"])
    # The formatter is pinned by Xcode; enforcing formatting is task 01C.
    capture(["xcrun", "--find", "swift-format"])


def check_swiftlint(binary=SWIFTLINT):
    if not binary.is_file():
        raise CheckFailure("Pinned SwiftLint is missing. Run ./scripts/check.sh setup first.")
    require_version("SwiftLint", capture([str(binary), "version"]), PINS["swiftlint_version"])


def find_tuist():
    candidates = []
    if shutil.which("tuist"):
        candidates.append(shutil.which("tuist"))
    if shutil.which("mise"):
        result = subprocess.run(["mise", "where", f"tuist@{PINS['tuist_version']}"],
                                cwd=ROOT, text=True, capture_output=True, check=False)
        if result.returncode == 0:
            candidates.append(str(Path(result.stdout.strip()) / "bin/tuist"))
    for candidate in dict.fromkeys(candidates):
        result = subprocess.run([candidate, "version"], cwd=ROOT, text=True,
                                capture_output=True, check=False)
        if result.returncode == 0 and result.stdout.strip() == PINS["tuist_version"]:
            return candidate
    raise CheckFailure(f"Tuist {PINS['tuist_version']} is required. Install explicitly with "
                       f"mise install tuist@{PINS['tuist_version']} (or the official release).")


def select_simulator(inventory, requested=None):
    devices = [d for d in inventory.get("devices", {}).get(PINS["simulator_runtime"], [])
               if d.get("isAvailable")]
    matches = [d for d in devices if (d["udid"] == requested if requested
                                     else d["name"] == PINS["simulator_name"])]
    if len(matches) != 1:
        raise CheckFailure(
            f"Expected one available {requested or PINS['simulator_name']} on "
            f"{PINS['simulator_runtime']}; found {len(matches)}. Install/create it in Xcode, "
            "or pass --simulator UDID for a device on that same runtime. No OS=latest fallback.")
    return matches[0]["udid"]


def setup():
    if SWIFTLINT.is_file():
        check_swiftlint()
        print(f"SwiftLint {PINS['swiftlint_version']} is already available at {SWIFTLINT}")
        return
    SWIFTLINT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="download-", dir=SWIFTLINT.parent) as temporary:
        archive = Path(temporary) / "swiftlint.zip"
        print(f"Downloading pinned SwiftLint {PINS['swiftlint_version']}…", flush=True)
        capture(["curl", "--fail", "--location", "--silent", "--show-error",
                 "--max-time", "120", PINS["swiftlint_url"], "--output", str(archive)])
        if hashlib.sha256(archive.read_bytes()).hexdigest() != PINS["swiftlint_sha256"]:
            raise CheckFailure("SwiftLint archive checksum mismatch; nothing installed.")
        # Extract only the named binary and license, never archive-controlled paths.
        with zipfile.ZipFile(archive) as bundle:
            staged = Path(temporary) / "swiftlint"
            staged.write_bytes(bundle.read("swiftlint"))
            staged.chmod(0o755)
            check_swiftlint(staged)
            (SWIFTLINT.parent / "LICENSE").write_bytes(bundle.read("LICENSE"))
            staged.replace(SWIFTLINT)
    print(f"Installed SwiftLint only in {SWIFTLINT.parent}")
    print(f"Other prerequisites: Xcode {PINS['xcode_version']} ({PINS['xcode_build']}), "
          f"Tuist {PINS['tuist_version']}, and the pinned iOS simulator. See README.")


def validate_inputs(root):
    for folder in ("Sources", "Tests", "Widgets"):
        if not any(path.is_file() for path in (root / folder).rglob("*.swift")):
            raise CheckFailure(f"No intended Swift files found under {folder}.")
    for name in ("Package.swift", "Project.swift", ".swiftlint.yml",
                 ".swiftlint-metrics.yml", ".swiftlint-baseline.json"):
        if not (root / name).is_file():
            raise CheckFailure(f"Missing required check input: {name}")


def lint_pass(root, binary, config, output, strict=False):
    command = [str(binary), "lint", "--no-cache", "--quiet", "--config", config,
               "--reporter", "json"]
    if strict:
        command.append("--strict")
    result = subprocess.run(command, cwd=root, text=True, capture_output=True, check=False)
    output.write_text(result.stdout)
    output.with_suffix(".stderr.log").write_text(result.stderr)
    # SwiftLint can warn about unknown rule identifiers and still exit successfully.
    if result.stderr.strip() or result.returncode not in (0, 2):
        raise CheckFailure(f"SwiftLint could not run cleanly: {result.stderr or result.stdout}")
    try:
        findings = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise CheckFailure(f"SwiftLint did not emit a JSON report: {output}") from error
    if not isinstance(findings, list) or any(not isinstance(r, dict) or "rule_id" not in r
                                             for r in findings):
        raise CheckFailure(f"Unexpected SwiftLint report: {output}")
    if result.returncode and not findings:
        raise CheckFailure("SwiftLint failed without reporting violations.")
    return findings


def finding_text(row, root):
    try:
        path = Path(row["file"]).relative_to(root)
    except ValueError:
        path = Path(row["file"])
    return f"{path}:{row['line']}: {row['rule_id']}: {row['reason']}"


def lint(root, binary, reports):
    validate_inputs(root)
    reports.mkdir(parents=True, exist_ok=True)
    gate = lint_pass(root, binary, ".swiftlint.yml", reports / "lint.json", strict=True)
    metrics = lint_pass(root, binary, ".swiftlint-metrics.yml", reports / "metrics.json")
    ordered = sorted(metrics, key=lambda r: (r["file"], r["line"], r["rule_id"]))
    summary = ["Advisory metrics (unfiltered; existing debt remains visible):"]
    summary.extend(f"  {rule}: {count}" for rule, count in sorted(
        Counter(r["rule_id"] for r in metrics).items()))
    summary.extend(finding_text(r, root) for r in ordered if r["rule_id"] == "cyclomatic_complexity")
    (reports / "metrics.txt").write_text("\n".join(summary) + "\n")
    print("\n".join(summary), flush=True)
    if gate:
        raise CheckFailure("New/unapproved lint violations:\n" + "\n".join(
            finding_text(r, root) for r in sorted(gate, key=lambda r: (r["file"], r["line"]))))
    print("Lint gate passed (committed baseline applied).", flush=True)


def fingerprint_inputs():
    names = capture(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]).split("\0")
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
            if (ROOT / name).is_file() else "missing" for name in names if name}


def run_step(label, command, reports):
    log = reports / f"{label}.log"
    print(f"{label}… (log: {log.relative_to(ROOT)})", flush=True)
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=False)
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-45:]), file=sys.stderr)
        raise CheckFailure(f"{label} failed (exit {result.returncode}); see {log}")
    print(f"{label} passed.", flush=True)


def run_checks(mode, requested_simulator):
    check_xcode()
    if mode in ("all", "lint"):
        check_swiftlint()
    tuist = find_tuist() if mode in ("all", "test", "build") else None
    simulator = None
    if mode in ("all", "test"):
        simulator = select_simulator(json.loads(capture(
            ["xcrun", "simctl", "list", "devices", "available", "--json"])), requested_simulator)
    validate_inputs(ROOT)
    output_root = ROOT / ".build/checks"
    output_root.mkdir(parents=True, exist_ok=True)
    reports = Path(tempfile.mkdtemp(prefix="run-", dir=output_root))
    (reports / "toolchain.json").write_text(json.dumps(PINS, indent=2) + "\n")
    before = fingerprint_inputs()
    try:
        if mode in ("all", "lint"):
            lint(ROOT, SWIFTLINT, reports)
        if mode == "all":
            run_step("check-runner-tests", [sys.executable, "-B", "-m", "unittest", "discover",
                                           "-s", "scripts/tests", "-v"], reports)
        if tuist:
            run_step("generate", [tuist, "generate", "--no-open", "--cache-profile", "none"], reports)
        if mode in ("all", "test"):
            run_step("macos-tests", ["xcrun", "swift", "test", "--scratch-path",
                                     str(output_root / "swiftpm")], reports)
        common = ["xcodebuild", "-workspace", "Larmindon.xcworkspace", "-configuration", "Debug",
                  "-derivedDataPath", str(output_root / "DerivedData"), "CODE_SIGNING_ALLOWED=NO"]
        if simulator:
            run_step("ios-tests", common + ["-scheme", "CoreTests", "-destination",
                     f"platform=iOS Simulator,id={simulator}", "-parallel-testing-enabled", "NO",
                     "-resultBundlePath", str(reports / "ios-tests.xcresult"), "test"], reports)
        if mode in ("all", "build"):
            run_step("macos-app", common + ["-scheme", "Larmindon-macOS", "-destination",
                     f"platform=macOS,arch={platform.machine()}", "build"], reports)
            run_step("ios-app-and-widget", common + ["-scheme", "Larmindon", "-destination",
                     "generic/platform=iOS Simulator", "build"], reports)
    finally:
        after = fingerprint_inputs()
        changed = sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))
        if changed:
            raise CheckFailure("Check inputs changed during the run (not reverted):\n" + "\n".join(changed))
    print(f"PASS: {mode}. Reports: {reports.relative_to(ROOT)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=("all", "lint", "test", "build", "setup"), default="all",
                        help="all (default), fast lint, both test suites, app builds, or explicit SwiftLint setup")
    parser.add_argument("--simulator", metavar="UDID", help="use a specific device on the pinned iOS runtime")
    args = parser.parse_args()
    if args.simulator and args.mode not in ("all", "test"):
        parser.error("--simulator is only used by all/test")
    if sys.version_info < (3, 9):
        parser.error("Python 3.9+ is required")
    if platform.system() != "Darwin":
        parser.error("Local checks require macOS and Xcode")
    # Select Xcode's own compiler without changing the user's global toolchain.
    os.environ["TOOLCHAINS"] = "com.apple.dt.toolchain.XcodeDefault"
    try:
        if args.mode == "setup":
            setup()
        else:
            run_checks(args.mode, args.simulator)
    except (CheckFailure, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
