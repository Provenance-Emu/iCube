#!/bin/bash
# Runs against a freshly built and installed NJB Debug app on an explicit, dedicated simulator.
set -euo pipefail
AUDIT_DEVICE="${1:?Usage: run.sh <tvOS-simulator-UDID> [xcodebuild test options...]}"
shift
AUDIT_SOURCE="$(cd "$(dirname "$0")" && pwd)"
AUDIT_OUT="${ICUBE_AUDIT_OUTPUT:-$(mktemp -d /tmp/icube-tvos-audit.XXXXXX)}"
command -v xcodegen >/dev/null || { echo 'Install XcodeGen with brew install xcodegen.' >&2; exit 1; }
mkdir -p "$AUDIT_OUT/project/Tests"
cp "$AUDIT_SOURCE/project.yml" "$AUDIT_OUT/project/project.yml"
cp "$AUDIT_SOURCE"/Tests/*.swift "$AUDIT_OUT/project/Tests/"
xcrun simctl bootstatus "$AUDIT_DEVICE" -b
xcodegen generate --spec "$AUDIT_OUT/project/project.yml"
xcodebuild test -project "$AUDIT_OUT/project/ICubeTVAudit.xcodeproj" -scheme ICubeTVAudit \
  -destination "platform=tvOS Simulator,id=$AUDIT_DEVICE" -derivedDataPath "$AUDIT_OUT/derived" \
  -resultBundlePath "$AUDIT_OUT/results.xcresult" -parallel-testing-enabled NO -collect-test-diagnostics never -jobs 2 \
  CODE_SIGNING_ALLOWED=YES "$@" 2>&1 | tee "$AUDIT_OUT/tests.log"
echo "Audit results: $AUDIT_OUT"
