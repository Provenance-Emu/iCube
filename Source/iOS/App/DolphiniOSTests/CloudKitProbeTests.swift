// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
import XCTest
@testable import iCube

/// Build policy must short-circuit the signed entitlement gate before any
/// provider can construct a container.
final class CloudKitProbeTests: XCTestCase {
  func testBuildReasonWinsAndTheSignedCheckNeverRuns() {
    var checked = false
    let reason = CloudSyncCoordinator.installUnavailableReason(
      buildReason: .containerNotProvisioned,
      signedEntitlementsAllowCloudKit: { checked = true
        return true
      })
    XCTAssertEqual(reason, .containerNotProvisioned)
    // Simulator/build policy short-circuits even the signed entitlement read.
    XCTAssertFalse(checked)
  }

  func testInvalidSignedEntitlementsDisableCloudKit() {
    let reason = CloudSyncCoordinator.installUnavailableReason(buildReason: nil, signedEntitlementsAllowCloudKit: { false })
    XCTAssertEqual(reason, .entitlementMissing)
  }

  func testValidSignedEntitlementsLeaveCloudKitOn() {
    XCTAssertNil(CloudSyncCoordinator.installUnavailableReason(buildReason: nil, signedEntitlementsAllowCloudKit: { true }))
  }

  func testTheDisabledPathRecordsTheKindAnInertProviderReports() {
    XCTAssertEqual(InertSyncProvider(reason: .entitlementMissing).kind, CloudSyncCoordinator.providerKind)
  }
}
