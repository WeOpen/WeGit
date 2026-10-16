#!/usr/bin/env python3
"""Exercise the actual scanner so provenance exceptions cannot hide credentials."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gitleaks", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    review = json.loads((root / "docs/acceptance/2026-10-16/application-integration/secret-scan-review.json").read_text())
    source, digests = next(iter(review["bindings"].items()))
    digest = digests[0]
    unknown = hashlib.sha256(b"unreviewed scanner behavior fixture").hexdigest()
    fixtures = {
        "docs/acceptance/fixture/reviewed.json": {source: digest},
        "docs/acceptance/fixture/new-digest.json": {source: unknown},
        "scripts/outside-receipts.json": {source: digest},
        "docs/acceptance/fixture/credential-field.json": {"api_key": digest},
        "docs/acceptance/fixture/mixed.json": {source: digest, "api_key": unknown},
    }
    expected = set(fixtures) - {"docs/acceptance/fixture/reviewed.json"}
    with tempfile.TemporaryDirectory(prefix="WeGitSecretPolicy-") as folder:
        temporary = Path(folder)
        scan = temporary / "tree"
        for name, value in fixtures.items():
            target = scan / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(value, indent=2) + "\n")
        report = temporary / "result.json"
        result = subprocess.run([
            str(args.gitleaks.resolve()), "dir", "--config", str(root / ".gitleaks.toml"),
            "--no-banner", "--redact=100", "--report-format=json", "--report-path", str(report), str(scan),
        ], capture_output=True, text=True)
        if result.returncode != 1 or not report.is_file():
            raise SystemExit("Secret policy fixture scan did not report the expected detections.")
        findings = json.loads(report.read_text())
        actual = {str(Path(item["File"]).relative_to(scan)) for item in findings}
        if actual != expected or len(findings) != len(expected):
            raise SystemExit("Secret policy changed: reviewed digest exception or credential detection failed.")
    print("Secret policy: reviewed provenance accepted; new digests, other paths and credential fields detected (5 cases).")


if __name__ == "__main__":
    main()
