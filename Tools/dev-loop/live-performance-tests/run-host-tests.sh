#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
test_root="$(mktemp -d /tmp/icube-live-performance.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
cat > "$test_root/main.swift" <<'SWIFT'
import XCTest
let suite = LivePerformanceOwnershipTests.defaultTestSuite
suite.run()
exit(suite.testRun!.hasSucceeded ? 0 : 1)
SWIFT
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
frameworks="$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$developer_dir/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -I "$libraries" -L "$libraries" -Xlinker -rpath -Xlinker "$libraries" -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -D LIVE_PERFORMANCE_HOST_TESTS -swift-version 5 \
 "$repo_root/Source/iOS/App/Common/Swift/Performance/LivePerformanceOwnership.swift" \
 "$repo_root/Source/iOS/App/DolphiniOSTests/LivePerformanceOwnershipTests.swift" "$test_root/main.swift" -o "$test_root/tests"
"$test_root/tests"
