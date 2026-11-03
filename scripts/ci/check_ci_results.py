#!/usr/bin/env python3
"""Keep the required Repository policy check bound to the applicable results."""
import json
import os


def required_results(needs):
    if needs.get("changes", {}).get("result") != "success":
        raise ValueError("Change scope did not complete successfully")
    outputs = needs["changes"].get("outputs", {})
    if any(outputs.get(key) not in {"true", "false"} for key in ["site_only", "site_changed"]):
        raise ValueError("Missing or invalid change scope outputs")
    site_only = outputs["site_only"] == "true"
    site_changed = outputs["site_changed"] == "true"
    if site_only and not site_changed:
        raise ValueError("Site-only scope must include site validation")
    required = [] if site_only else ["policy", "native"]
    if site_changed:
        required.append("site")
    for key in required:
        if needs.get(key, {}).get("result") != "success":
            raise ValueError(f"Required {key} validation did not succeed")
    return required


def main():
    required = required_results(json.loads(os.environ["CI_NEEDS_JSON"]))
    print("Required validation passed: " + ", ".join(required))


if __name__ == "__main__":
    main()
