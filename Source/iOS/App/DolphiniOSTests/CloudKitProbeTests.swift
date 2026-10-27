// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
import XCTest
@testable import iCube

/// Re-signed installs with malformed iCloud entitlements made `CKContainer` raise at
/// launch (Sentry ICUBE-HY, GY, J5). These pin the order of the checks and that the
/// raise is caught.
final class CloudKitProbeTests: XCTestCase {
  func testBuildReasonWinsAndTheProbeNeverRuns() {
    var probed = false
    let reason = CloudSyncCoordinator.installUnavailableReason(
      buildReason: .containerNotProvisioned,
      canCreateContainer: { probed = true; return true })
    XCTAssertEqual(reason, .containerNotProvisioned)
    // On the simulator creating a container traps, so the probe must not run.
    XCTAssertFalse(probed)
  }

  func testAContainerThatCannotBeCreatedMeansTheEntitlementIsMissing() {
    let reason = CloudSyncCoordinator.installUnavailableReason(buildReason: nil, canCreateContainer: { false })
    XCTAssertEqual(reason, .entitlementMissing)
  }

  func testAContainerThatCanBeCreatedLeavesCloudKitOn() {
    XCTAssertNil(CloudSyncCoordinator.installUnavailableReason(buildReason: nil, canCreateContainer: { true }))
  }

  func testTheProbeCatchesAnObjectiveCException() {
    XCTAssertFalse(DOLCloudKitProbe.succeedsWithoutException {
      NSException(name: .genericException, reason: "malformed entitlements", userInfo: nil).raise()
    })
    XCTAssertTrue(DOLCloudKitProbe.succeedsWithoutException {})
  }

  func testTheDisabledPathRecordsTheKindAnInertProviderReports() {
    XCTAssertEqual(InertSyncProvider(reason: .entitlementMissing).kind, CloudSyncCoordinator.providerKind)
  }
}
