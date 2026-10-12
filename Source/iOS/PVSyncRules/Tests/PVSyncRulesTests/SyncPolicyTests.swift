// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVSyncRules

final class SyncPolicyTests: XCTestCase {

    func testDefaultAllowsEveryAlwaysOnCategoryAndNoOptInOne() {
        let policy = SyncPolicy.default
        for type in SyncableFileType.allCases {
            XCTAssertEqual(policy.allows(type), !type.isOptIn, "\(type)")
        }
        XCTAssertTrue(policy.largeFilesOverWiFiOnly)
    }

    func testFirmwareSwitchOnlyAffectsFirmware() {
        let policy = SyncPolicy(firmwareEnabled: true)
        XCTAssertTrue(policy.allows(.firmware))
        XCTAssertFalse(policy.allows(.wiiChannel))
        XCTAssertFalse(policy.allows(.wiiSystem))
    }

    func testChannelsSwitchDoesNotImplyNAND() {
        let policy = SyncPolicy(wiiChannelsEnabled: true)
        XCTAssertTrue(policy.allows(.wiiChannel))
        XCTAssertFalse(policy.allows(.wiiSystem))
    }

    func testNANDSwitchImpliesChannels() {
        let policy = SyncPolicy(fullWiiNANDEnabled: true)
        XCTAssertTrue(policy.effectiveWiiChannelsEnabled)
        XCTAssertTrue(policy.allows(.wiiChannel))
        XCTAssertTrue(policy.allows(.wiiSystem))
        XCTAssertFalse(policy.allows(.firmware))
    }

    func testWiFiRuleAppliesToLargeCategoriesOnly() {
        let on = SyncPolicy(firmwareEnabled: true, fullWiiNANDEnabled: true, largeFilesOverWiFiOnly: true)
        XCTAssertTrue(on.requiresUnconstrainedNetwork(for: .wiiSystem))
        XCTAssertTrue(on.requiresUnconstrainedNetwork(for: .firmware))
        XCTAssertFalse(on.requiresUnconstrainedNetwork(for: .saveState))
        XCTAssertFalse(on.requiresUnconstrainedNetwork(for: .skin))

        let off = SyncPolicy(fullWiiNANDEnabled: true, largeFilesOverWiFiOnly: false)
        XCTAssertFalse(off.requiresUnconstrainedNetwork(for: .wiiSystem))
    }

    func testCodableRoundTrip() throws {
        let policy = SyncPolicy(firmwareEnabled: true, wiiChannelsEnabled: false,
                                fullWiiNANDEnabled: true, largeFilesOverWiFiOnly: false)
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(SyncPolicy.self, from: data), policy)
    }

    /// Classification never consults policy; only the combined helper does.
    func testClassifierIgnoresPolicyButCombinedHelperHonoursIt() {
        let path = "GC/USA/IPL.bin"
        XCTAssertEqual(SyncClassifier.classify(relativePath: path), .firmware)
        XCTAssertNil(SyncClassifier.syncableType(relativePath: path, sizeBytes: 1024, policy: .default))
        XCTAssertEqual(
            SyncClassifier.syncableType(relativePath: path, sizeBytes: 1024, policy: SyncPolicy(firmwareEnabled: true)),
            .firmware)
    }

    func testPolicyAwareDescentPrunesTicketAndShared1WhenOff() {
        XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Wii/shared1", policy: .default))
        XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Wii/ticket/00000001", policy: .default))
        XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Wii/ticket/00010001", policy: .default))
        XCTAssertTrue(SyncClassifier.shouldDescend(
            intoDirectoryRelativePath: "Wii/ticket/00010001", policy: SyncPolicy(wiiChannelsEnabled: true)))
        XCTAssertTrue(SyncClassifier.shouldDescend(
            intoDirectoryRelativePath: "Wii/shared1", policy: SyncPolicy(fullWiiNANDEnabled: true)))
    }

    /// The `title/` tree holds save data for every title, so it is never
    /// pruned by policy — only `classify` decides per file.
    func testPolicyAwareDescentKeepsTitleTree() {
        XCTAssertTrue(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Wii/title/00000001", policy: .default))
        XCTAssertTrue(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Wii/title/00010001/48414441", policy: .default))
        XCTAssertTrue(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "StateSaves", policy: .default))
        XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Cache", policy: .default))
    }
}
