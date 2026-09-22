// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVSyncRules
@testable import PVContinuity

// MARK: - GameIdentity

final class GameIdentityTests: XCTestCase {

    private func gc(
        _ id: String?, md5: String? = nil, disc: Int? = nil, rev: Int? = nil, name: String = "Melee"
    ) -> GameIdentity {
        GameIdentity(gameID: id, md5: md5, displayName: name, platform: "gc", discNumber: disc, revision: rev)
    }

    func testGameIDIsNormalizedToUppercase() {
        XCTAssertEqual(gc("gale01").gameID, "GALE01")
    }

    func testHashesAreNormalizedToLowercase() {
        let identity = GameIdentity(md5: "AABBCC", crc32: "DDEE", displayName: "x", platform: "gc")
        XCTAssertEqual(identity.md5, "aabbcc")
        XCTAssertEqual(identity.crc32, "ddee")
    }

    func testSameIDSameDiscSameRevisionIsExact() {
        XCTAssertEqual(gc("GALE01", disc: 0, rev: 2).match(against: gc("GALE01", disc: 0, rev: 2)), .exactGameID)
    }

    func testBothUnknownDiscAndRevisionStillCountsAsExact() {
        // nil/nil on both sides is "neither device recorded it", not a conflict.
        XCTAssertEqual(gc("GALE01").match(against: gc("GALE01")), .exactGameID)
    }

    func testNilDiscIsTreatedAsDiscZero() {
        XCTAssertEqual(gc("GALE01", disc: nil, rev: 0).match(against: gc("GALE01", disc: 0, rev: 0)), .exactGameID)
    }

    func testDifferentDiscOfTheSameTitleIsOnlyAFamilyMatch() {
        // The multi-disc case the six-character ID cannot distinguish on its own.
        XCTAssertEqual(gc("GEAE01", disc: 0).match(against: gc("GEAE01", disc: 1)), .gameIDFamily)
    }

    func testDifferentRevisionOfTheSameTitleIsOnlyAFamilyMatch() {
        XCTAssertEqual(gc("GALE01", rev: 0).match(against: gc("GALE01", rev: 2)), .gameIDFamily)
    }

    func testOneSideKnowingTheRevisionAndTheOtherNotIsAFamilyMatch() {
        XCTAssertEqual(gc("GALE01", rev: 2).match(against: gc("GALE01", rev: nil)), .gameIDFamily)
    }

    func testMatchingMD5PromotesAFamilyMatchToAContentMatch() {
        // Same ID, differing disc metadata, but provably the same bytes.
        let remote = gc("GEAE01", md5: "abc", disc: 0)
        let local = gc("GEAE01", md5: "abc", disc: 1)
        XCTAssertEqual(remote.match(against: local), .contentHash)
    }

    func testMD5MatchesAcrossDifferentGameIDs() {
        let remote = GameIdentity(gameID: "AAAAAA", md5: "abc", displayName: "x", platform: "gc")
        let local = GameIdentity(gameID: "BBBBBB", md5: "abc", displayName: "y", platform: "gc")
        XCTAssertEqual(remote.match(against: local), .contentHash)
    }

    func testCRC32AloneIsNeverAMatch() {
        // 32 bits is not enough to assert two multi-gigabyte discs are the same.
        let remote = GameIdentity(crc32: "deadbeef", displayName: "x", platform: "gc")
        let local = GameIdentity(crc32: "deadbeef", displayName: "y", platform: "gc")
        XCTAssertNil(remote.match(against: local))
    }

    func testNoSharedIdentifierIsNoMatch() {
        XCTAssertNil(gc("GALE01").match(against: gc("RMCE01")))
    }

    func testEmptyIdentifiersDoNotMatchEachOther() {
        let blank = GameIdentity(gameID: "", md5: "", displayName: "x", platform: "gc")
        XCTAssertNil(blank.match(against: blank))
        XCTAssertFalse(blank.hasAnyIdentifier)
    }

    func testHasAnyIdentifier() {
        XCTAssertTrue(gc("GALE01").hasAnyIdentifier)
        XCTAssertTrue(GameIdentity(md5: "abc", displayName: "x", platform: "gc").hasAnyIdentifier)
        XCTAssertFalse(GameIdentity(displayName: "x", platform: "gc").hasAnyIdentifier)
    }

    func testStableKeySeparatesDiscsAndRevisions() {
        XCTAssertNotEqual(gc("GEAE01", disc: 0).stableKey, gc("GEAE01", disc: 1).stableKey)
        XCTAssertNotEqual(gc("GALE01", rev: 0).stableKey, gc("GALE01", rev: 2).stableKey)
    }

    func testStableKeyFallsBackThroughMD5ThenName() {
        XCTAssertTrue(GameIdentity(md5: "abc", displayName: "x", platform: "gc").stableKey.hasPrefix("md5:"))
        XCTAssertTrue(GameIdentity(displayName: "x", platform: "gc").stableKey.hasPrefix("name:"))
    }
}

// MARK: - SaveStateDescriptor

final class SaveStateDescriptorTests: XCTestCase {

    func testSlotFileNameMatchesDolphinsMakeStateFilename() {
        // Core/State.cpp writes "{GameID}.s{NN}" with a zero-padded two-digit slot.
        XCTAssertEqual(SaveStateDescriptor.fileName(stem: "GALE01", slot: 1), "GALE01.s01")
        XCTAssertEqual(SaveStateDescriptor.fileName(stem: "GALE01", slot: 0), "GALE01.s00")
        XCTAssertEqual(SaveStateDescriptor.fileName(stem: "GALE01", slot: 10), "GALE01.s10")
    }

    func testResumeStateUsesTheAutoExtension() {
        XCTAssertEqual(SaveStateDescriptor.fileName(stem: "GALE01", slot: nil), "GALE01.auto")
    }

    func testRelativePathIsRootedAtStateSaves() {
        XCTAssertEqual(
            SaveStateDescriptor.relativePath(stem: "GALE01", slot: 3),
            "StateSaves/GALE01.s03"
        )
    }

    func testAStemIsUsedVerbatimAndNotDerivedFromAnythingElse() {
        // The stem is whatever the core reported, even when it bears no
        // resemblance to the ROM's filename or the display title. This is the
        // whole point of the stem rule.
        let odd = SaveStateDescriptor.relativePath(stem: "ZZZZ99", slot: 1)
        XCTAssertEqual(odd, "StateSaves/ZZZZ99.s01")
    }

    func testSlottedStateProducesASaveStateDescriptor() {
        let descriptor = SaveStateDescriptor(
            slot: 2, stem: "GALE01", relativePath: "StateSaves/GALE01.s02",
            sha256: "abc", size: 100
        )
        XCTAssertFalse(descriptor.isResumeState)
        XCTAssertEqual(descriptor.fileDescriptor.kind, .saveState)
        XCTAssertTrue(descriptor.fileDescriptor.required)
    }

    func testResumeStateProducesAResumeStateDescriptor() {
        let descriptor = SaveStateDescriptor(
            slot: nil, stem: "GALE01", relativePath: "StateSaves/GALE01.auto",
            sha256: "abc", size: 100
        )
        XCTAssertTrue(descriptor.isResumeState)
        XCTAssertEqual(descriptor.fileDescriptor.kind, .resumeState)
    }

    func testTheProducedPathIsClassifiedAsExpectedBySyncRules() {
        // Guards the two modules agreeing about the same filename convention.
        XCTAssertEqual(
            SyncClassifier.classify(relativePath: SaveStateDescriptor.relativePath(stem: "GALE01", slot: 1)),
            .saveState
        )
        XCTAssertEqual(
            SyncClassifier.classify(relativePath: SaveStateDescriptor.relativePath(stem: "GALE01", slot: nil)),
            .resumeState
        )
    }
}

// MARK: - ContinuityFileKind

final class ContinuityFileKindTests: XCTestCase {

    func testEverySyncableTypeHasAContinuityCounterpart() {
        for type in SyncableFileType.allCases {
            let kind = ContinuityFileKind(type)
            XCTAssertEqual(kind.syncableType, type, "round trip failed for \(type)")
        }
    }

    func testGameFileIsTheOnlyKindWithNoSyncableCounterpart() {
        let orphans = ContinuityFileKind.allCases.filter { $0.syncableType == nil }
        XCTAssertEqual(orphans, [.gameFile])
    }

    func testGameFileSortsLastSoAPartialTransferKeepsTheSaves() {
        let sorted = ContinuityFileKind.allCases.sorted { $0.pullPriority < $1.pullPriority }
        XCTAssertEqual(sorted.last, .gameFile)
    }

    func testPullPriorityDelegatesToSyncRules() {
        for type in SyncableFileType.allCases {
            XCTAssertEqual(ContinuityFileKind(type).pullPriority, type.pullPriority)
        }
    }

    func testOnlyStateKindsAreRequiredToResume() {
        let required = ContinuityFileKind.allCases.filter(\.isRequiredToResume)
        XCTAssertEqual(Set(required), [.saveState, .resumeState])
    }

    func testGameFileIsNotClassifiedAsRequiredToResume() {
        // Booting at all and resuming at a point are different questions; the
        // fallback machine tracks the former separately.
        XCTAssertFalse(ContinuityFileKind.gameFile.isRequiredToResume)
    }
}
