// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVSyncRules

final class SyncClassifierTests: XCTestCase {

    // MARK: - The guarantee that matters

    /// WS-5 acceptance: "No ROM ever leaves the device. Assert this in a test
    /// against the classifier."
    func testNoROMIsEverSyncable() {
        let romPaths = [
            "GALE01.iso", "StateSaves/GALE01.iso", "GC/GALE01.gcm",
            "Games/Zelda.rvz", "RVZ/game.rvz", "game.wbfs", "game.gcz",
            "game.ciso", "game.wia", "channel.wad", "homebrew.dol",
            "homebrew.elf", "Disc.nkit.iso", "multi.m3u", "dump.img",
            "archive.zip", "archive.7z", "archive.rar"
        ]
        for path in romPaths {
            XCTAssertNil(SyncClassifier.classify(relativePath: path),
                         "ROM-shaped path must never classify: \(path)")
        }
    }

    /// A GameCube IPL dump is copyrighted console firmware.
    func testBIOSIsNeverSyncable() {
        for path in ["GC/USA/IPL.bin", "GC/IPL.bin", "ipl.bin", "GC/EUR/ipl.bin"] {
            XCTAssertNil(SyncClassifier.classify(relativePath: path),
                         "BIOS/IPL must never classify: \(path)")
        }
    }

    /// Artwork is a cache, re-derivable, and deliberately out of scope.
    func testArtworkIsNotSynced() {
        XCTAssertNil(SyncClassifier.classify(relativePath: "Cache/GameCovers/GALE01.png"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "Cache/Redump/list.dat"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "Cache/Shaders/blob.bin"))
    }

    /// Unknown paths fail closed, not open.
    func testUnknownPathsDefaultToNotSyncing() {
        for path in ["mystery.dat", "Whatever/thing.xyz", "StateSaves/notes.txt", ""] {
            XCTAssertNil(SyncClassifier.classify(relativePath: path))
        }
    }

    // MARK: - Allow-list

    func testSaveStateSlots() {
        XCTAssertEqual(SyncClassifier.classify(relativePath: "StateSaves/GALE01.s01"), .saveState)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "StateSaves/RMCE01.s99"), .saveState)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "StateSaves/GALE01.s00"), .saveState)
        // Not a slot: wrong shape.
        XCTAssertNil(SyncClassifier.classify(relativePath: "StateSaves/GALE01.s1"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "StateSaves/GALE01.sAB"))
    }

    func testResumeStateAndSiblings() {
        XCTAssertEqual(SyncClassifier.classify(relativePath: "StateSaves/GALE01.auto"), .resumeState)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "StateSaves/GALE01.s01.json"), .saveStateMetadata)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "StateSaves/GALE01.s01.png"), .saveStateThumbnail)
    }

    func testGameCubeMemoryCards() {
        XCTAssertEqual(SyncClassifier.classify(relativePath: "GC/MemoryCardA.raw"), .gameCubeMemoryCard)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "GC/USA/MemoryCardB.raw"), .gameCubeMemoryCard)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "GC/USA/Card/01-GALE-save.gci"), .gameCubeMemoryCard)
    }

    /// Only the save subtree, never the whole NAND.
    func testWiiSavesButNotTheWholeNAND() {
        XCTAssertEqual(
            SyncClassifier.classify(relativePath: "Wii/title/00010000/524d4345/data/banner.bin"),
            .wiiSave)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Wii/sys/SYSCONF"), .wiiSave)
        // System titles and IOS are not ours to copy.
        XCTAssertNil(SyncClassifier.classify(relativePath: "Wii/title/00000001/00000002/content/00000000.app"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "Wii/shared1/00000000.app"))
    }

    func testConfigAndPerGameSettings() {
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Config/Dolphin.ini"), .config)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "GameSettings/GALE01.ini"), .gameSettings)
        XCTAssertNil(SyncClassifier.classify(relativePath: "Config/portable.txt"))
    }

    // MARK: - Size cap

    func testSizeCapRejectsOversizeEvenWhenPathIsAllowed() {
        let path = "StateSaves/GALE01.s01"
        XCTAssertEqual(SyncClassifier.syncableType(relativePath: path, sizeBytes: 1024), .saveState)
        XCTAssertEqual(SyncClassifier.syncableType(relativePath: path,
                                                   sizeBytes: SyncClassifier.maxFileSizeBytes), .saveState)
        XCTAssertNil(SyncClassifier.syncableType(relativePath: path,
                                                 sizeBytes: SyncClassifier.maxFileSizeBytes + 1))
        XCTAssertNil(SyncClassifier.syncableType(relativePath: path, sizeBytes: -1))
    }

    /// The cap must not rescue a disallowed path.
    func testSizeCapDoesNotWidenTheAllowList() {
        XCTAssertNil(SyncClassifier.syncableType(relativePath: "GALE01.iso", sizeBytes: 10))
    }

    // MARK: - Path handling

    func testPathNormalization() {
        XCTAssertEqual(SyncClassifier.classify(relativePath: "/StateSaves/GALE01.s01"), .saveState)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "statesaves/gale01.s01"), .saveState)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "STATESAVES/GALE01.S01"), .saveState)
    }

    // MARK: - Continuity ordering

    /// Smallest and most essential first, so a failed transfer leaves the most
    /// usable partial payload.
    func testPullPriorityIsTotalAndPutsMetadataFirst() {
        let priorities = SyncableFileType.allCases.map(\.pullPriority)
        XCTAssertEqual(Set(priorities).count, SyncableFileType.allCases.count,
                       "pullPriority must be a total order with no ties")
        XCTAssertEqual(SyncableFileType.allCases.min(by: { $0.pullPriority < $1.pullPriority }),
                       .saveStateMetadata)
        XCTAssertEqual(SyncableFileType.allCases.max(by: { $0.pullPriority < $1.pullPriority }),
                       .saveStateThumbnail)
    }

    func testOnlyStatesAreRequiredToResume() {
        XCTAssertTrue(SyncableFileType.saveState.isRequiredToResume)
        XCTAssertTrue(SyncableFileType.resumeState.isRequiredToResume)
        XCTAssertFalse(SyncableFileType.saveStateThumbnail.isRequiredToResume)
        XCTAssertFalse(SyncableFileType.wiiSave.isRequiredToResume)
    }
}
