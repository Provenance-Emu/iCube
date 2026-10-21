#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
test_root="$(mktemp -d /tmp/icube-performance-tests.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
swift_root="$repo_root/Source/iOS/App/Common/Swift"
cat > "$test_root/Support.swift" <<'SWIFT'
import SwiftUI
func L(_ value: String) -> String { value }
struct PlayerHelpCaption: View { let text: String; var body: some View { Text(text) } }
SWIFT
cat > "$test_root/main.swift" <<'SWIFT'
import XCTest
let suite = PerformanceControlsTests.defaultTestSuite
suite.run()
exit(suite.testRun!.hasSucceeded ? 0 : 1)
SWIFT
developer_root="${DEVELOPER_DIR:-$(xcode-select -p)}"
test_frameworks="$developer_root/Platforms/MacOSX.platform/Developer/Library/Frameworks"
test_libraries="$developer_root/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -I "$test_libraries" -L "$test_libraries" -Xlinker -rpath -Xlinker "$test_libraries" -F "$test_frameworks" -Xlinker -rpath -Xlinker "$test_frameworks" -D PERFORMANCE_HOST_TESTS -swift-version 5 \
 "$test_root/Support.swift" "$swift_root/Menu/MenuModel.swift" \
 "$repo_root/Source/iOS/App/Common/UI/Settings/SwiftUI/Leaves/SettingsRowFactory.swift" \
 "$swift_root/Performance/PerformanceControlsState.swift" \
 "$swift_root/Performance/PerformanceControlsController.swift" \
 "$swift_root/Performance/PerformanceControlsModelBuilder.swift" \
 "$repo_root/Source/iOS/App/DolphiniOSTests/PerformanceControlsTests.swift" \
 "$test_root/main.swift" -o "$test_root/tests"
"$test_root/tests"
