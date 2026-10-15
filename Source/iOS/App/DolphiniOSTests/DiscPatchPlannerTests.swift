// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The planning half of the disc patching flow: refusals, cache keys, where each mode writes, how much
/// room a run needs, which game a patch is for, and which boots count as modded. All plain values.
final class DiscPatchPlannerTests: XCTestCase {
  private let gib: UInt64 = 1 << 30
  private let directories = DiscPatchDirectories(
    user: URL(fileURLWithPath: "/data/User", isDirectory: true),
    software: URL(fileURLWithPath: "/data/Software", isDirectory: true))

  private func image(container: DiscContainer = .plain, platform: DiscPlatform = .gameCube, nkit: Bool = false,
                     plain: UInt64 = 1_459_978_240, fileSize: UInt64? = nil) -> DiscPatchImage {
    DiscPatchImage(gameID: "GALE01", container: container, platform: platform, isNKit: nkit,
                   plainSize: plain, plainSizeIsExact: true, fileSize: fileSize ?? plain)
  }

  // MARK: - Refusals

  func test_refusesNKitWadExecutableAndUnreadableContainers() {
    XCTAssertEqual(DiscPatchPlanner.refusal(for: image(nkit: true)), .nKit)
    XCTAssertEqual(DiscPatchPlanner.refusal(for: image(platform: .wiiWAD)), .wad)
    XCTAssertEqual(DiscPatchPlanner.refusal(for: image(platform: .executable)), .executable)
    XCTAssertEqual(DiscPatchPlanner.refusal(for: image(platform: .unknown)), .notADisc)
    XCTAssertEqual(DiscPatchPlanner.refusal(for: image(container: .other)), .unsupportedContainer)
  }

  func test_acceptsEveryPatchableDisc() {
    for container in [DiscContainer.plain, .rvz, .wia, .gcz, .wbfs, .ciso] {
      for platform in [DiscPlatform.gameCube, .wii, .triforce] {
        XCTAssertNil(DiscPatchPlanner.refusal(for: image(container: container, platform: platform)))
      }
    }
  }

  // MARK: - Cache key

  private func key(path: String = "/a/game.iso", size: UInt64 = 10, modified: TimeInterval = 100,
                   patchSize: UInt64 = 5, digest: String = "abc", ignore: Bool = false) -> String {
    DiscPatchPlanner.cacheKey(sourcePath: path, sourceSize: size, sourceModified: modified,
                              patchSize: patchSize, patchDigest: digest, ignoreSourceChecksum: ignore)
  }

  func test_cacheKeyIsStable() {
    XCTAssertEqual(key(), key())
    XCTAssertEqual(key().count, 16)
  }

  func test_cacheKeyChangesWithEveryInput() {
    let base = key()
    XCTAssertNotEqual(base, key(path: "/b/game.iso"))
    XCTAssertNotEqual(base, key(size: 11))
    XCTAssertNotEqual(base, key(modified: 101))
    XCTAssertNotEqual(base, key(patchSize: 6))
    XCTAssertNotEqual(base, key(digest: "abd"))
    XCTAssertNotEqual(base, key(ignore: true))
  }

  func test_cacheKeyIgnoresSubSecondModificationJitter() {
    XCTAssertEqual(key(modified: 100.2), key(modified: 100.9))
  }

  // MARK: - Output planning

  private func makePlan(_ mode: DiscPatchMode, format: DiscPatchCopyFormat = .rvz, container: DiscContainer = .plain,
                    source: String = "/data/Software/Game.iso", taken: Set<String> = []) -> DiscPatchOutputPlan {
    DiscPatchPlanner.outputPlan(mode: mode, copyFormat: format, source: URL(fileURLWithPath: source),
                                sourceContainer: container, cacheKey: "k1", copyName: "Game (Hack)",
                                workID: "w1", directories: directories, exists: { taken.contains($0.path) })
  }

  func test_thisRunWritesTheCachedCopy() {
    let plan = makePlan(.thisRun)
    XCTAssertEqual(plan.destination.path, "/data/User/Cache/PatchedDiscs/k1/Patched.iso")
    XCTAssertEqual(plan.patchedImage, plan.destination)
    XCTAssertNil(plan.convertedImage)
    XCTAssertFalse(plan.replacesOriginal)
  }

  func test_saveCopyAsISOWritesStraightToTheLibrary() {
    let plan = makePlan(.saveCopy, format: .iso)
    XCTAssertEqual(plan.destination.path, "/data/Software/Patched/Game (Hack).iso")
    XCTAssertEqual(plan.patchedImage, plan.destination)
    XCTAssertNil(plan.convertedImage)
  }

  func test_saveCopyAsRVZPatchesInWorkThenStagesTheCompressedFile() {
    let plan = makePlan(.saveCopy, format: .rvz)
    XCTAssertEqual(plan.patchedImage.path, "/data/User/Cache/PatchWork/w1.iso")
    XCTAssertEqual(plan.convertedImage?.path, "/data/Software/Patched/Game (Hack).rvz.importing")
    XCTAssertEqual(plan.destination.path, "/data/Software/Patched/Game (Hack).rvz")
  }

  func test_saveCopyNeverOverwritesAnExistingCopy() {
    let taken: Set<String> = ["/data/Software/Patched/Game (Hack).iso", "/data/Software/Patched/Game (Hack) 2.iso"]
    XCTAssertEqual(makePlan(.saveCopy, format: .iso, taken: taken).destination.path, "/data/Software/Patched/Game (Hack) 3.iso")
  }

  func test_replacingAPlainOriginalKeepsItsNameAndFormat() {
    let plan = makePlan(.replaceOriginal)
    XCTAssertTrue(plan.replacesOriginal)
    XCTAssertEqual(plan.destination.path, "/data/Software/Game.iso")
    XCTAssertEqual(plan.patchedImage.path, "/data/User/Cache/PatchWork/w1.iso")
    XCTAssertNil(plan.convertedImage)
    XCTAssertNil(plan.originalToRemove)
  }

  func test_replacingAnRVZKeepsTheRVZ() {
    let plan = makePlan(.replaceOriginal, container: .rvz, source: "/data/Software/Game.rvz")
    XCTAssertEqual(plan.destination.path, "/data/Software/Game.rvz")
    XCTAssertEqual(plan.convertedImage?.path, "/data/User/Cache/PatchWork/w1.rvz")
    XCTAssertNil(plan.originalToRemove)
  }

  func test_replacingOtherCompressedFormatsBecomesAnRVZBesideTheOriginal() {
    for (container, ext) in [(DiscContainer.gcz, "gcz"), (.wia, "wia"), (.wbfs, "wbfs"), (.ciso, "ciso")] {
      let source = "/data/Software/Game.\(ext)"
      let plan = makePlan(.replaceOriginal, container: container, source: source)
      XCTAssertEqual(plan.destination.path, "/data/Software/Game.rvz", ext)
      XCTAssertEqual(plan.originalToRemove?.path, source, ext)
    }
  }

  func test_replacementRefusesToOverwriteAnotherRVZ() {
    let plan = makePlan(.replaceOriginal, container: .gcz, source: "/data/Software/Game.gcz")
    XCTAssertNotNil(DiscPatchPlanner.replacementBlocker(plan: plan, exists: { $0.path == "/data/Software/Game.rvz" }))
    XCTAssertNil(DiscPatchPlanner.replacementBlocker(plan: plan, exists: { _ in false }))
  }

  func test_fileNamesAreMadeSafe() {
    XCTAssertEqual(DiscPatchPlanner.sanitizedFileName("A/B:C*D"), "A B C D")
    XCTAssertEqual(DiscPatchPlanner.sanitizedFileName("  ..  "), "Patched")
    XCTAssertEqual(DiscPatchPlanner.sanitizedFileName("Metroid Prime 2: Echoes"), "Metroid Prime 2 Echoes")
  }

  // MARK: - Free space

  func test_plainSourceThisRunNeedsOnlyThePatchedImage() {
    let needed = DiscPatchPlanner.requiredFreeSpace(image: image(plain: 2 * gib), targetSize: nil, mode: .thisRun, copyFormat: .rvz)
    XCTAssertEqual(needed, 2 * gib + DiscPatchPlanner.freeSpaceMargin)
  }

  func test_compressedSourceNeedsThePlainCopyAndThePatchedImageTogether() {
    let rvz = image(container: .rvz, plain: 4 * gib, fileSize: 2 * gib)
    let needed = DiscPatchPlanner.requiredFreeSpace(image: rvz, targetSize: nil, mode: .thisRun, copyFormat: .rvz)
    XCTAssertEqual(needed, 8 * gib + DiscPatchPlanner.freeSpaceMargin)
  }

  func test_aLargerPatchedTargetRaisesTheRequirement() {
    let needed = DiscPatchPlanner.requiredFreeSpace(image: image(plain: 2 * gib), targetSize: 3 * gib, mode: .saveCopy, copyFormat: .iso)
    XCTAssertEqual(needed, 3 * gib + DiscPatchPlanner.freeSpaceMargin)
  }

  func test_rvzOutputDoesNotAddToThePlainCopyPeak() {
    let rvz = image(container: .rvz, plain: 4 * gib, fileSize: 2 * gib)
    // Patching holds 4 + 4 GiB; compressing holds 4 + 2 GiB. The larger moment decides.
    let needed = DiscPatchPlanner.requiredFreeSpace(image: rvz, targetSize: nil, mode: .saveCopy, copyFormat: .rvz)
    XCTAssertEqual(needed, 8 * gib + DiscPatchPlanner.freeSpaceMargin)
  }

  func test_plainToRVZCompressionIsEstimatedAtHalf() {
    XCTAssertEqual(DiscPatchPlanner.estimatedRVZSize(of: image(plain: 4 * gib)), 2 * gib)
    XCTAssertEqual(DiscPatchPlanner.estimatedRVZSize(of: image(container: .rvz, plain: 4 * gib, fileSize: gib)), gib)
  }

  func test_replacingAnRVZWritesRVZButAPlainOriginalDoesNot() {
    XCTAssertTrue(DiscPatchPlanner.writesRVZ(mode: .replaceOriginal, copyFormat: .iso, container: .gcz))
    XCTAssertFalse(DiscPatchPlanner.writesRVZ(mode: .replaceOriginal, copyFormat: .rvz, container: .plain))
    XCTAssertTrue(DiscPatchPlanner.writesRVZ(mode: .saveCopy, copyFormat: .rvz, container: .plain))
    XCTAssertFalse(DiscPatchPlanner.writesRVZ(mode: .thisRun, copyFormat: .rvz, container: .rvz))
  }

  func test_shortfallMessageStatesBothNumbers() {
    XCTAssertNil(DiscPatchPlanner.freeSpaceShortfall(required: gib, available: gib))
    let message = DiscPatchPlanner.freeSpaceShortfall(required: 3 * gib, available: gib)
    XCTAssertTrue(message?.contains(DiscPatchPlanner.byteString(3 * gib)) == true)
    XCTAssertTrue(message?.contains(DiscPatchPlanner.byteString(gib)) == true)
  }

  // MARK: - Which game is the patch for

  private func candidate(_ id: String, gameID: String, size: UInt64, exact: Bool = true) -> DiscPatchCandidate {
    DiscPatchCandidate(id: id, title: id, gameID: gameID, plainSize: size, plainSizeIsExact: exact)
  }

  func test_aDeclaredSourceSizeBeatsEverythingElse() {
    let games = [candidate("a", gameID: "AAAA01", size: 100), candidate("b", gameID: "BBBB01", size: 200)]
    let ranked = DiscPatchPlanner.rankTargets(games, declaredSourceSize: 200, minimumSourceSize: nil, suggestedGameID: "AAAA01")
    XCTAssertEqual(ranked.map(\.id), ["b", "a"])
  }

  func test_aSuggestedGameComesBeforeUnrelatedOnes() {
    let games = [candidate("a", gameID: "AAAA01", size: 100), candidate("b", gameID: "BBBB01", size: 100)]
    let ranked = DiscPatchPlanner.rankTargets(games, declaredSourceSize: nil, minimumSourceSize: nil, suggestedGameID: "BBBB01")
    XCTAssertEqual(ranked.map(\.id), ["b", "a"])
  }

  func test_aSizeThatIsNotExactNeverCountsAsAMatch() {
    let games = [candidate("a", gameID: "AAAA01", size: 100), candidate("b", gameID: "BBBB01", size: 200, exact: false)]
    let ranked = DiscPatchPlanner.rankTargets(games, declaredSourceSize: 200, minimumSourceSize: nil, suggestedGameID: nil)
    XCTAssertEqual(ranked.map(\.id), ["a", "b"])
  }

  func test_anXdeltaLowerBoundOnlyDemotesDiscsThatAreTooSmall() {
    let games = [candidate("small", gameID: "AAAA01", size: 100), candidate("big", gameID: "BBBB01", size: 300)]
    let ranked = DiscPatchPlanner.rankTargets(games, declaredSourceSize: nil, minimumSourceSize: 250, suggestedGameID: nil)
    XCTAssertEqual(ranked.map(\.id), ["big", "small"])
  }

  func test_equalScoresKeepTheLibraryOrder() {
    let games = ["c", "a", "b"].map { candidate($0, gameID: $0, size: 1) }
    let ranked = DiscPatchPlanner.rankTargets(games, declaredSourceSize: nil, minimumSourceSize: nil, suggestedGameID: nil)
    XCTAssertEqual(ranked.map(\.id), ["c", "a", "b"])
  }

  // MARK: - xdelta compression

  func test_xdeltaWithoutSecondaryCompressionIsSupported() {
    XCTAssertFalse(DiscPatchPlanner.xdeltaNeedsUnsupportedCompression(header: [0xD6, 0xC3, 0xC4, 0x00, 0x00, 0x00]))
  }

  func test_xdeltaDJWAndFGKAreSupported() {
    XCTAssertFalse(DiscPatchPlanner.xdeltaNeedsUnsupportedCompression(header: [0xD6, 0xC3, 0xC4, 0x00, 0x05, 0x01]))
    XCTAssertFalse(DiscPatchPlanner.xdeltaNeedsUnsupportedCompression(header: [0xD6, 0xC3, 0xC4, 0x00, 0x05, 0x10]))
  }

  func test_xdeltaLZMAIsNotSupported() {
    XCTAssertTrue(DiscPatchPlanner.xdeltaNeedsUnsupportedCompression(header: [0xD6, 0xC3, 0xC4, 0x00, 0x05, 0x20]))
  }

  func test_aShortHeaderIsNotJudged() {
    XCTAssertFalse(DiscPatchPlanner.xdeltaNeedsUnsupportedCompression(header: [0xD6, 0xC3]))
    XCTAssertFalse(DiscPatchPlanner.xdeltaNeedsUnsupportedCompression(header: [0xD6, 0xC3, 0xC4, 0x00, 0x05]))
  }

  // MARK: - Patch files

  func test_recognisesPatchExtensionsCaseInsensitively() {
    for name in ["a.xdelta", "a.VCDIFF", "a.bps", "a.ips", "a.UPS", "a.ppf", "a.xdelta3"] {
      XCTAssertTrue(DiscPatchPlanner.isPatchFile(URL(fileURLWithPath: "/tmp/\(name)")), name)
    }
    for name in ["a.iso", "a.zip", "a.rvz", "a"] {
      XCTAssertFalse(DiscPatchPlanner.isPatchFile(URL(fileURLWithPath: "/tmp/\(name)")), name)
    }
  }
}

/// Which boots must not touch the vanilla game's auto-resume state.
final class ModdedBootTests: XCTestCase {
  private let discs = "/data/User/Cache/PatchedDiscs"
  private let copies = "/data/Software/Patched"

  private func modded(_ path: String) -> Bool {
    ModdedBoot.isModded(path: path, patchedDiscsDirectory: discs, patchedSoftwareDirectory: copies)
  }

  func test_cachedAndSavedPatchedDiscsAreModded() {
    XCTAssertTrue(modded("/data/User/Cache/PatchedDiscs/abc123/Patched.iso"))
    XCTAssertTrue(modded("/data/Software/Patched/Game (Hack).rvz"))
    XCTAssertTrue(modded("/data/Software/Patched/Sub/Game.iso"))
  }

  func test_aModDescriptorIsModdedWhereverItLives() {
    XCTAssertTrue(modded("/data/Software/NSMBW Newer.json"))
    XCTAssertTrue(modded("/elsewhere/Mod.JSON"))
  }

  func test_aPristineGameIsNot() {
    XCTAssertFalse(modded("/data/Software/Game.iso"))
    XCTAssertFalse(modded("/data/Software/Game.rvz"))
  }

  func test_foldersMatchWholeComponentsOnly() {
    XCTAssertFalse(modded("/data/Software/PatchedX/Game.iso"))
    XCTAssertFalse(modded("/data/Software/Patched.iso"))
    XCTAssertFalse(modded("/data/User/Cache/PatchedDiscsOld/Game.iso"))
  }

  func test_theFolderItselfIsNotAGame() {
    XCTAssertFalse(modded("/data/Software/Patched"))
  }

  func test_privateAndPlainPrefixesAreTheSameFolder() {
    XCTAssertTrue(ModdedBoot.isModded(path: "/private/var/mobile/Documents/Software/Patched/G.iso",
                                      patchedDiscsDirectory: "/var/mobile/Documents/User/Cache/PatchedDiscs",
                                      patchedSoftwareDirectory: "/var/mobile/Documents/Software/Patched"))
  }

  func test_aSymlinkIntoAPatchedFolderIsModded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ModdedBootTests-\(UUID().uuidString)")
    let real = root.appendingPathComponent("Software/Patched", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: real.appendingPathComponent("G.iso").path, contents: Data()))
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    XCTAssertTrue(ModdedBoot.isModded(path: link.appendingPathComponent("G.iso").path,
                                      patchedDiscsDirectory: root.appendingPathComponent("Cache/PatchedDiscs").path,
                                      patchedSoftwareDirectory: real.path))
  }
}
