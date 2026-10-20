#!/usr/bin/env python3
"""Reject stale Dolphin core artifacts that still contain adaptive-resolution code/config."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

RETIRED = (
    "AutoIRController", "AutoInternalResolution", "AutoIRTargetFPS", "AutoIRMinScale",
    "AutoIRMaxScale", "AutoIRCooldownFrames", "AutoIRHysteresisPct", "AutoIRShowOSD",
)


def check(framework):
    with (framework / "Info.plist").open("rb") as handle:
        metadata = plistlib.load(handle)
    binary = framework / metadata["CFBundleExecutable"]
    contents = binary.read_bytes()
    symbols = subprocess.run(["nm", str(binary)], check=True, capture_output=True, text=True).stdout
    if "GFX_EFB_SCALE" not in symbols:
        raise ValueError(f"{binary}: could not identify Dolphin's normal resolution setting")
    found = [name for name in RETIRED if name in symbols or name.encode() in contents]
    if found:
        raise ValueError(f"{binary}: retired adaptive resolution content: {', '.join(found)}")
    return {"binary": str(binary.resolve()), "bytes": len(contents), "sha256": hashlib.sha256(contents).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path, help="A packaged xcframework or embedded .framework")
    args = parser.parse_args()
    artifact = args.artifact
    try:
        if artifact.suffix == ".xcframework":
            with (artifact / "Info.plist").open("rb") as handle:
                libraries = plistlib.load(handle)["AvailableLibraries"]
            platforms = {(item["SupportedPlatform"], item.get("SupportedPlatformVariant")) for item in libraries}
            expected = {("ios", None), ("ios", "simulator"), ("tvos", None), ("tvos", "simulator")}
            if not expected.issubset(platforms):
                raise ValueError(f"Missing core slices: {expected - platforms}")
            results = [check(artifact / item["LibraryIdentifier"] / item["LibraryPath"]) for item in libraries]
        elif artifact.suffix == ".framework":
            results = [check(artifact)]
        else:
            raise ValueError("Expected .xcframework or .framework")
        print(json.dumps({"result": "passed", "artifacts": results}, indent=2))
        return 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
