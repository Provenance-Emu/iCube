#!/usr/bin/env python3
"""Reject the SwiftUI metadata import responsible for iOS 17/18 startup crashes.

Run against each app executable after building/archiving. The app supports OS
versions older than 26, where SwiftUI.TupleContent metadata does not exist.
Unlike a newer-OS launch test, this also checks release optimization output.
"""
import argparse
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path, help="Path to the app's Mach-O executable")
    args = parser.parse_args()
    result = subprocess.run(
        ["xcrun", "nm", "-u", str(args.executable)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        print(result.stderr.strip(), file=sys.stderr)
        return result.returncode
    # Account for SwiftUI/SwiftUICore symbol movement between SDK versions.
    unavailable = [line.strip() for line in result.stdout.splitlines()
                   if "TupleContent" in line and ("SwiftUI" in line or "SwiftUICore" in line)]
    if unavailable:
        print("FAIL: app imports SwiftUI.TupleContent metadata unavailable before OS 26:", file=sys.stderr)
        print("\n".join(unavailable), file=sys.stderr)
        return 1
    print("PASS: no SwiftUI.TupleContent imports in " + str(args.executable))
    return 0


if __name__ == "__main__":
    sys.exit(main())
