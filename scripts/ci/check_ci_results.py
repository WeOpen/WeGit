#!/usr/bin/env python3
"""Keep the required Repository policy check bound to the applicable results."""
import json
import os


def required_results(needs):
    if needs.get("changes", {}).get("result") != "success":
        raise ValueError("Change scope did not complete successfully")
    outputs = needs["changes"].get("outputs", {})
    flags = {"backend_changed":"native", "policy_changed":"policy", "site_changed":"site",
             "frontend_changed":"frontend", "core_tests_changed":"test_compile", "docs_only":"docs"}
    if any(outputs.get(key) not in {"true", "false"} for key in flags):
        raise ValueError("Missing or invalid change scope outputs")
    if outputs["backend_changed"] == "true" and outputs["policy_changed"] != "true":
        raise ValueError("Backend code changes must include repository validation")
    required = [job for key, job in flags.items() if outputs[key] == "true"]
    for key in required:
        if needs.get(key, {}).get("result") != "success":
            raise ValueError(f"Required {key} validation did not succeed")
    return required


def main():
    required = required_results(json.loads(os.environ["CI_NEEDS_JSON"]))
    print("Required validation passed: " + ", ".join(required))


if __name__ == "__main__":
    main()
