#!/bin/sh
# Run the actual production signature gate without building the emulator/app.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Sources/CloudKitGate" "$tmp/Tests/CloudKitGateTests"
cp "$root/Source/iOS/App/Common/Services/SignedCloudKitEntitlements.swift" "$tmp/Sources/CloudKitGate/"
cp "$root/Source/iOS/App/DolphiniOSTests/SignedCloudKitEntitlementsTests.swift" "$tmp/Tests/CloudKitGateTests/"
cat > "$tmp/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CloudKitGate", platforms: [.macOS(.v13)], targets: [
    .target(name: "CloudKitGate"), .testTarget(name: "CloudKitGateTests", dependencies: ["CloudKitGate"])
])
SWIFT
xcrun swift test --package-path "$tmp" --jobs 2
