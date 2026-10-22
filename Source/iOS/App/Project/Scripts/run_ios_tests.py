#!/usr/bin/env python3
"""Resolve an installed simulator and finish booting it before launching XCTest."""

import argparse
import json
import os
import subprocess
import sys


def choose_device(devices, simulator="", destination=""):
    options = dict(part.split("=", 1) for part in destination.split(",") if "=" in part)
    if options.get("platform", "iOS Simulator") != "iOS Simulator":
        raise ValueError("iCubeTests requires platform=iOS Simulator")
    selector = options.get("id") or options.get("name") or simulator
    candidates = []
    for runtime, entries in devices.items():
        if ".iOS-" not in runtime:
            continue
        version = tuple(int(part) for part in runtime.split(".iOS-")[1].split("-"))
        requested_os = options.get("OS", "latest")
        if requested_os != "latest" and version != tuple(map(int, requested_os.split("."))):
            continue
        for device in entries:
            if not device.get("isAvailable", False):
                continue
            if selector and selector not in (device["udid"], device["name"]):
                continue
            candidates.append((device["state"] == "Booted", version, device["name"], device))
    if not candidates:
        raise ValueError(f"No available iOS simulator matches {destination or simulator or 'this installation'}")
    # A booted device avoids another cold boot. Always pass its UDID to Xcode:
    # a name alone silently adds OS:latest and can select an unavailable pairing.
    return max(candidates, key=lambda item: item[:3])[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", default="")
    parser.add_argument("--destination", default="")
    parser.add_argument("--boot-timeout", type=int, default=600)
    parser.add_argument("xcode_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    inventory = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], timeout=60)
    device = choose_device(json.loads(inventory)["devices"], args.sim, args.destination)
    udid = device["udid"]
    print(f"Testing on {device['name']} ({udid})", flush=True)
    if device["state"] != "Booted":
        subprocess.run(["xcrun", "simctl", "boot", udid], check=True, timeout=60)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=args.boot_timeout)
    extra = args.xcode_args
    if extra[:1] == ["--"]:
        extra = extra[1:]
    # The app embeds MoltenVK; disabling signing makes dyld reject the host.
    command = ["xcrun", "xcodebuild", "test", "-workspace", "iCube.xcworkspace",
               "-scheme", "iCube (NJB)", "-configuration", "Debug (Non-Jailbroken)",
               "-destination", f"platform=iOS Simulator,id={udid}",
               "-derivedDataPath", "build-Xcode-ios", "-parallel-testing-enabled", "NO",
               "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO",
               "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", *extra]
    os.execvp(command[0], command)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        sys.exit(f"Simulator test preflight failed: {error}")
