#!/usr/bin/env python3
"""Run production continuity controllers on macOS, without app/core builds.

Pass the candidate SourcePackages/checkouts directory. Dependencies are linked
read-only into an isolated package; only UIKit/ObjC app bridges are substituted.
"""
import argparse
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("checkouts", type=pathlib.Path)
parser.add_argument("--scratch", type=pathlib.Path)
parser.add_argument("--include-package-tests", action="store_true")
args = parser.parse_args()
app = pathlib.Path(__file__).resolve().parents[2]
scratch = args.scratch or pathlib.Path(tempfile.mkdtemp(prefix="icube-continuity-controllers-"))
scratch.mkdir(parents=True, exist_ok=True)
sources = scratch / "Sources"
sources.mkdir(exist_ok=True)
for name in ("PVSyncRules", "PVWebServer", "PVContinuity"):
    target = sources / name
    if not target.exists():
        target.symlink_to(args.checkouts.resolve() / name / "Sources" / name, target_is_directory=True)
host = sources / "Host"
host.mkdir(exist_ok=True)
for name in ("ContinuityLibraryBrowseController.swift", "ContinuityReceiveController.swift", "ContinuityPaths.swift", "ICubeContinuityFileProvider.swift"):
    # Combine is implicitly available through the application target's imports.
    (host / name).write_text("import Combine\n" + (app / "Common/Continuity" / name).read_text())
manager = (app / "Common/Continuity/ContinuityManager.swift").read_text()
prompts = manager[manager.index("    struct PendingPairingPrompt"):manager.index("    // MARK: - Owned components")]
methods = []
for name in ("awaitPairingApproval", "awaitLibraryPullApproval"):
    start = manager.index("    fileprivate func " + name)
    end = manager.index("\n    }", start) + len("\n    }")
    methods.append(manager[start:end].replace("fileprivate func", "func"))
(host / "ApprovalManager.swift").write_text('''import Foundation
import PVContinuity
@MainActor final class HostApprovalManager {
    var pendingPairing: PendingPairingPrompt?
    var pendingLibraryPull: PendingLibraryPullPrompt?
    func refreshLibraryGrants() async {}
''' + prompts + "\n".join(methods) + "\n}\n")
for name in ("ContinuityApprovalRequest.swift", "ICubeContinuityTransport.swift", "ContinuityTransferGate.swift", "PeerBoundContinuityTransport.swift", "ContinuityFileDigestCache.swift", "ContinuityVerifiedFileReceipt.swift"):
    path = app / "Common/Continuity" / name
    if path.exists():
        (host / name).write_text(path.read_text())
fixtures = app / "Project/Tests/ContinuityControllers"
(host / "Bridges.swift").write_text((fixtures / "Bridges.swift").read_text())
tests = scratch / "Tests"
tests.mkdir(exist_ok=True)
(tests / "ContinuityControllerTests.swift").write_text((fixtures / "ContinuityControllerTests.swift").read_text())
extra_targets = ""
if args.include_package_tests:
    for relative, source in (
        ("Sources/PVContinuityTesting", "Sources/PVContinuityTesting"),
        ("PackageTests", "Tests/PVContinuityTests"),
    ):
        target = scratch / relative
        if not target.exists():
            target.symlink_to(args.checkouts.resolve() / "PVContinuity" / source, target_is_directory=True)
    extra_targets = ''',
    .target(name: "PVContinuityTesting", dependencies: ["PVContinuity", "PVWebServer"]),
    .testTarget(name: "PVContinuityTests", dependencies: ["PVContinuity", "PVContinuityTesting", "PVWebServer"], path: "PackageTests")
'''
(scratch / "Package.swift").write_text('''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "ContinuityControllerHarness", platforms: [.macOS(.v14)], targets: [
    .target(name: "PVSyncRules"),
    .target(name: "PVWebServer", resources: [.process("Resources")]),
    .target(name: "PVContinuity", dependencies: ["PVSyncRules", "PVWebServer"]),
    .target(name: "Host", dependencies: ["PVContinuity", "PVSyncRules"]),
    .testTarget(name: "ControllerTests", dependencies: ["Host", "PVContinuity"], path: "Tests")
''' + extra_targets + "])\n")
print(f"Harness: {scratch}", flush=True)
raise SystemExit(subprocess.call(["xcrun", "swift", "test", "--package-path", str(scratch), "--jobs", "4"]))
