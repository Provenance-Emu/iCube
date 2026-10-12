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
            "archive.zip", "archive.7z", "archive.rar",
            // The game library itself, whatever is in it.
            "Software/GALE01.iso", "Software/Zelda/game.rvz", "Software/notes.txt",
            "Software/StateSaves/GALE01.s01",
            // An installer package that wandered into the NAND tree.
            "Wii/title/00010001/48414441/content/channel.wad",
            // A skin still in archive form.
            "Skins/cool.zip"
        ]
        for path in romPaths {
            XCTAssertNil(SyncClassifier.classify(relativePath: path),
                         "ROM-shaped path must never classify: \(path)")
        }
        for type in SyncableFileType.allCases {
            XCTAssertFalse(type.rawValue.lowercased().contains("rom"),
                           "no category may describe a ROM: \(type)")
        }
    }

    /// A GameCube IPL dump classifies as opt-in firmware: the user's own copy
    /// to the user's own database, off until they say otherwise.
    func testIPLIsOptInFirmware() {
        for path in ["GC/USA/IPL.bin", "GC/IPL.bin", "GC/EUR/ipl.bin", "GC/JAP/IPL.bin"] {
            XCTAssertEqual(SyncClassifier.classify(relativePath: path), .firmware, path)
            XCTAssertNil(SyncClassifier.syncableType(relativePath: path, sizeBytes: 2_097_152, policy: .default),
                         "firmware must be off by default: \(path)")
        }
        XCTAssertTrue(SyncableFileType.firmware.isOptIn)
        // Not where firmware lives.
        XCTAssertNil(SyncClassifier.classify(relativePath: "ipl.bin"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "GC/USA/Deep/IPL.bin"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "StateSaves/IPL.bin"))
    }

    func testGBASaves() {
        XCTAssertEqual(SyncClassifier.classify(relativePath: "GBA/Saves/ZELDA.sav"), .gbaSave)
        XCTAssertNil(SyncClassifier.classify(relativePath: "GBA/gba_bios.bin"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "GBA/Saves"))
    }

    func testICubeProfileStores() {
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Profiles/game_profiles.json"), .gameProfile)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Profiles/library_state.json"), .libraryState)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Profiles/touch_overlay_layout_v2.json"), .touchOverlayLayout)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Profiles/touch_overlay_layout.json"), .touchOverlayLayout)
        XCTAssertNil(SyncClassifier.classify(relativePath: "Profiles/unknown.json"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "Profiles/game_profiles.json.bak"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "Profiles/Sub/game_profiles.json"))
    }

    func testSkins() {
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Skins/selection.json"), .skin)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Skins/com.example.pad/info.json"), .skin)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Skins/com.example.pad/iphone/portrait.pdf"), .skin)
        XCTAssertNil(SyncClassifier.classify(relativePath: "Skins/stray.png"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "Skins"))
    }

    func testWiiChannelsAndDLCAreOptIn() {
        let channel = [
            "Wii/title/00010001/48414441/content/00000000.app",
            "Wii/title/00010001/48414441/content/title.tmd",
            "Wii/title/00010004/52534245/content/00000001.app",
            "Wii/title/00010005/73563154/content/00000003.app",
            "Wii/title/00010008/48414b45/content/00000000.app",
            "Wii/ticket/00010001/48414441.tik",
            "Wii/ticket/00010005/73563154.tik",
            "Wii/shared1/00000000.app",
            "Wii/shared1/content.map"
        ]
        for path in channel {
            XCTAssertEqual(SyncClassifier.classify(relativePath: path), .wiiChannel, path)
            XCTAssertNil(SyncClassifier.syncableType(relativePath: path, sizeBytes: 1024, policy: .default), path)
            XCTAssertEqual(
                SyncClassifier.syncableType(relativePath: path, sizeBytes: 1024,
                                            policy: SyncPolicy(wiiChannelsEnabled: true)),
                .wiiChannel, path)
        }
        // A channel's own save data is a save, always on.
        XCTAssertEqual(
            SyncClassifier.classify(relativePath: "Wii/title/00010001/48414441/data/save.bin"), .wiiSave)
    }

    func testRestOfNANDIsOptInSystem() {
        let system = [
            "Wii/title/00000001/00000002/content/00000000.app",
            "Wii/title/00000001/00000002/content/title.tmd",
            "Wii/title/00000001/00000039/content/00000010.app",
            "Wii/title/00010000/524d4345/content/title.tmd",
            "Wii/ticket/00000001/00000002.tik",
            "Wii/ticket/00010000/524d4345.tik",
            "Wii/shared2/menu/FaceLib/RFL_DB.dat",
            "Wii/shared2/wc24/nwc24msg.cfg",
            "Wii/sys/uid.sys",
            "Wii/meta/00000001/00000002/title.met"
        ]
        for path in system {
            XCTAssertEqual(SyncClassifier.classify(relativePath: path), .wiiSystem, path)
            XCTAssertNil(SyncClassifier.syncableType(relativePath: path, sizeBytes: 1024, policy: .default), path)
            XCTAssertNil(SyncClassifier.syncableType(relativePath: path, sizeBytes: 1024,
                                                     policy: SyncPolicy(wiiChannelsEnabled: true)), path)
            XCTAssertEqual(
                SyncClassifier.syncableType(relativePath: path, sizeBytes: 1024,
                                            policy: SyncPolicy(fullWiiNANDEnabled: true)),
                .wiiSystem, path)
        }
        // Scratch space never syncs, whatever the switches.
        for path in ["Wii/tmp/foo.bin", "Wii/import/00010001/48414441/content/00000000.app"] {
            XCTAssertNil(SyncClassifier.classify(relativePath: path), path)
            XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: (path as NSString).deletingLastPathComponent))
        }
        // Too shallow to be a file Dolphin writes.
        XCTAssertNil(SyncClassifier.classify(relativePath: "Wii/sys"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "Wii/title/00000001"))
    }

    func testOptInCategoriesAreExactlyTheLargeOnes() {
        for type in SyncableFileType.allCases {
            XCTAssertEqual(type.isOptIn, type.isLarge, "\(type)")
        }
        XCTAssertEqual(Set(SyncableFileType.allCases.filter(\.isOptIn)), [.firmware, .wiiChannel, .wiiSystem])
    }

    func testMergedDocumentsNeverPropagateDeletes() {
        for type in SyncableFileType.allCases {
            XCTAssertEqual(type.propagatesDeletes, type.mergeKind == .wholeFile, "\(type)")
        }
        XCTAssertEqual(SyncableFileType.gameProfile.mergeKind, .document)
        XCTAssertEqual(SyncableFileType.libraryState.mergeKind, .document)
        XCTAssertEqual(SyncableFileType.touchOverlayLayout.mergeKind, .wholeFile)
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

    /// Save data is always on; the rest of the NAND is a different, opt-in
    /// category so the default switches still move only saves.
    func testWiiSavesAreAlwaysOnAndSeparateFromTheNAND() {
        XCTAssertEqual(
            SyncClassifier.classify(relativePath: "Wii/title/00010000/524d4345/data/banner.bin"),
            .wiiSave)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Wii/shared2/sys/SYSCONF"), .wiiSave)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Wii/sys/SYSCONF"), .wiiSave)
        XCTAssertFalse(SyncableFileType.wiiSave.isOptIn)
        XCTAssertNotEqual(
            SyncClassifier.classify(relativePath: "Wii/title/00000001/00000002/content/00000000.app"), .wiiSave)
        XCTAssertNotEqual(SyncClassifier.classify(relativePath: "Wii/shared1/00000000.app"), .wiiSave)
    }

    func testConfigAndPerGameSettings() {
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Config/Dolphin.ini"), .config)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Config/GCPadNew.ini"), .config)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "Config/WiimoteNew.ini"), .config)
        XCTAssertEqual(SyncClassifier.classify(relativePath: "GameSettings/GALE01.ini"), .gameSettings)
        XCTAssertNil(SyncClassifier.classify(relativePath: "Config/portable.txt"))
        XCTAssertNil(SyncClassifier.classify(relativePath: "Config/Profiles/GCPad/mine.ini"))
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

    /// Each category has its own ceiling: a channel may be far larger than a
    /// save state, firmware far smaller.
    func testSizeCapIsPerCategory() {
        let channel = "Wii/title/00010001/48414441/content/00000000.app"
        XCTAssertEqual(SyncClassifier.syncableType(relativePath: channel, sizeBytes: 200 * 1024 * 1024), .wiiChannel)
        XCTAssertNil(SyncClassifier.syncableType(relativePath: channel, sizeBytes: 257 * 1024 * 1024))

        let ipl = "GC/USA/IPL.bin"
        XCTAssertEqual(SyncClassifier.syncableType(relativePath: ipl, sizeBytes: 2 * 1024 * 1024), .firmware)
        XCTAssertNil(SyncClassifier.syncableType(relativePath: ipl, sizeBytes: 5 * 1024 * 1024))

        XCTAssertNil(SyncClassifier.syncableType(relativePath: "StateSaves/GALE01.s01", sizeBytes: 100 * 1024 * 1024))
        for type in SyncableFileType.allCases {
            XCTAssertGreaterThan(type.maxFileSizeBytes, 0, "\(type)")
        }
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

    // MARK: - Directory pruning (WS-5 scanner optimisation)

    func testShouldDescendSkipsExcludedTrees() {
        XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Cache"))
        XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Cache/GameCovers"))
        XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Load/Textures/GALE01"))
        XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "dump/frames"))
        XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Logs"))
    }

    func testShouldDescendAllowsSyncableTrees() {
        XCTAssertTrue(SyncClassifier.shouldDescend(intoDirectoryRelativePath: ""))
        XCTAssertTrue(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "StateSaves"))
        XCTAssertTrue(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "Wii/title/00010000"))
        XCTAssertTrue(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "GC/USA"))
        XCTAssertTrue(SyncClassifier.shouldDescend(intoDirectoryRelativePath: "GameSettings"))
    }

    /// Pruning is an optimisation, never a policy change: anything under a
    /// pruned directory must already have been rejected by `classify`.
    func testPruningNeverHidesASyncableFile() {
        let probes = [
            "Cache/GameCovers/GALE01.png",
            "Load/Textures/GALE01/tex1.png",
            "Dump/Frames/dff.dff",
            "Logs/dolphin.log",
            "Shaders/foo.glsl"
        ]
        for path in probes {
            let directory = (path as NSString).deletingLastPathComponent
            XCTAssertFalse(SyncClassifier.shouldDescend(intoDirectoryRelativePath: directory),
                           "\(directory) should be pruned")
            XCTAssertNil(SyncClassifier.classify(relativePath: path),
                         "\(path) must be rejected by classify regardless of pruning")
        }
    }
}
