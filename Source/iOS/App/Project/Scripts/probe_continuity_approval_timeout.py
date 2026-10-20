#!/usr/bin/env python3
"""Exercise actual route-specific URLSession timeouts against a slow localhost peer.

Takes about 70 seconds. Does not launch or change an app, simulator or device.
"""
import argparse
import pathlib
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("checkouts", type=pathlib.Path)
args = parser.parse_args()
app = pathlib.Path(__file__).resolve().parents[2]
pinned = args.checkouts.resolve() / "PVContinuity/Sources/PVContinuity"
with tempfile.TemporaryDirectory(prefix="icube-approval-timeout-") as scratch_name:
    scratch = pathlib.Path(scratch_name)
    for relative in (
        "Client/ContinuityTransport.swift",
        "Client/URLSessionContinuityTransport.swift",
        "Model/ContinuityError.swift",
        "Server/ContinuityRoutes.swift",
    ):
        (scratch / pathlib.Path(relative).name).write_text((pinned / relative).read_text())
    (scratch / "ICubeContinuityTransport.swift").write_text(
        (app / "Common/Continuity/ICubeContinuityTransport.swift").read_text().replace("import PVContinuity", "")
    )
    probe = (app / "Project/Tests/ContinuityControllers/ApprovalTimeoutProbe.swift").read_text()
    server = (pinned / "Server/ContinuityLibraryServer.swift").read_text()
    timeout = re.search(r"public static let approvalTimeout: TimeInterval = ([0-9.]+)", server).group(1)
    probe = probe.replace("approvalTimeout: TimeInterval = 120", f"approvalTimeout: TimeInterval = {timeout}")
    (scratch / "Probe.swift").write_text(probe)
    executable = scratch / "probe"
    subprocess.run(["swiftc", "-parse-as-library", *map(str, scratch.glob("*.swift")), "-o", str(executable)], check=True)
    raise SystemExit(subprocess.call([str(executable)]))
