#!/usr/bin/env python3
"""Compare the documented measurements with the actual Foundry test output."""

import argparse
import difflib
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="replace the measured table in the document")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(
        ["forge", "test", "--match-test", "testPrintInflationTable", "-vv", "--color", "never"],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        sys.stderr.write(result.stdout + result.stderr)
        return result.returncode
    rows = [line.strip() for line in result.stdout.splitlines() if line.strip().startswith("| ")]
    if len(rows) != 26:
        sys.stderr.write(f"Expected two header lines and 24 measurements, got {len(rows)} lines.\n")
        sys.stderr.write(result.stdout + result.stderr)
        return 1
    measured = "\n" + "\n".join(rows) + "\n"
    document = root / "docs" / "inflation.md"
    content = document.read_text()
    begin = "<!-- BEGIN MEASURED TABLE -->"
    end = "<!-- END MEASURED TABLE -->"
    before, tail = content.split(begin)
    recorded, after = tail.split(end)
    if args.write:
        document.write_text(before + begin + measured + end + after)
        print("Updated docs/inflation.md from 24 executed attack scenarios.")
        return 0
    if recorded != measured:
        sys.stderr.writelines(
            difflib.unified_diff(recorded.splitlines(True), measured.splitlines(True), "documented", "measured")
        )
        return 1
    print("All 24 documented rows match the executed attack scenarios.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
