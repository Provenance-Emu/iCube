#!/usr/bin/env python3
"""Run Foundation-only library metadata production tests without Xcode/core builds.

Uses links to the repository sources and tests, so the harness cannot silently
exercise stale copies. --work-directory retains the SwiftPM package/build cache.
This is macOS model/file-operation coverage, not installed iOS/tvOS acceptance.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


APP_ROOT = Path(__file__).resolve().parents[2]
SOURCES = ("LibraryMetadataStore", "AppDocumentMergers")
PACKAGE = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LibraryMetadataAudit", platforms: [.macOS(.v14)], dependencies: [
  .package(url: "https://github.com/Provenance-Emu/PVCloudSync.git", .upToNextMajor(from: "1.1.0")),
  .package(url: "https://github.com/Provenance-Emu/PVSyncRules.git", .upToNextMajor(from: "1.0.0"))
], targets: [
  .target(name: "iCube", dependencies: [
    .product(name: "PVLibraryMetadata", package: "PVCloudSync"),
    .product(name: "PVCloudSync", package: "PVCloudSync"),
    .product(name: "PVSyncRules", package: "PVSyncRules")
  ]),
  .testTarget(name: "iCubeTests", dependencies: ["iCube",
    .product(name: "PVLibraryMetadata", package: "PVCloudSync"),
    .product(name: "PVCloudSync", package: "PVCloudSync"),
    .product(name: "PVSyncRules", package: "PVSyncRules")
  ])
])
'''


def run(folder: Path) -> int:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Package.swift").write_text(PACKAGE)
    for name in SOURCES:
        for relative, source in (
            (f"Sources/iCube/{name}.swift", APP_ROOT / f"Common/Swift/{name}.swift"),
            (f"Tests/iCubeTests/{name}Tests.swift", APP_ROOT / f"DolphiniOSTests/{name}Tests.swift"),
        ):
            link = folder / relative
            link.parent.mkdir(parents=True, exist_ok=True)
            if link.is_symlink():
                link.unlink()
            link.symlink_to(source)
    return subprocess.run(["xcrun", "swift", "test", "--package-path", str(folder), "--jobs", "2"], check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-directory", type=Path)
    args = parser.parse_args()
    if args.work_directory:
        return run(args.work_directory.resolve())
    with tempfile.TemporaryDirectory(prefix="icube-library-metadata-") as folder:
        return run(Path(folder))


if __name__ == "__main__":
    raise SystemExit(main())
