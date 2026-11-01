#!/usr/bin/env python3
"""Compatibility entry point; website implementation lives in site/scripts/build.py."""
from pathlib import Path
import runpy

if __name__ == "__main__":
    runpy.run_path(str(Path(__file__).resolve().parents[1] / "site/scripts/build.py"), run_name="__main__")
