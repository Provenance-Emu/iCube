// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The shared drop box (`EcosystemHandoff`): what iCube writes must be what a
/// sibling app expects to find, and what iCube takes in must land in the
/// library folder and nowhere else. A temporary directory stands in for the
/// App Group container.
final class EcosystemHandoffTests: XCTestCase {
  private var sandbox: URL!
  private var root: URL { sandbox.appendingPathComponent("Ecosystem") }
  private var source: URL { sandbox.appendingPathComponent("Source") }
  private var library: URL { sandbox.appendingPathComponent("Software") }
  private let fm = FileManager.default

  override func setUpWithError() throws {
    sandbox = fm.temporaryDirectory.appendingPathComponent("ecosystem-handoff-\(UUID().uuidString)")
    try fm.createDirectory(at: library, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? fm.removeItem(at: sandbox)
  }

  // MARK: - Helpers

  @discardableResult
  private func seed(_ relativePath: String, in base: URL? = nil, _ contents: String = "x") throws -> URL {
    let url = (base ?? source).appendingPathComponent(relativePath)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
  }

  private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

  private func names(in directory: URL) -> Set<String> {
    Set((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
  }

  private func inbox(_ scheme: String) -> URL { root.appendingPathComponent("Handoff/\(scheme)") }

  @discardableResult
  private func stage(_ files: [URL], to peer: String = "provenance", from sender: String = "dolphinios",
                     id: String = "H1", now: Date = Date(),
                     fileManager: FileManager = .default) throws -> EcosystemHandoffManifest {
    try EcosystemHandoffStager.stage(
      files: files, to: peer, from: sender, title: "Game", system: "gamecube", md5: "ABCDEF",
      root: root, id: id, now: now, fileManager: fileManager
    )
  }

  private func rewrite(_ manifest: EcosystemHandoffManifest, in scheme: String = "dolphinios") throws {
    try EcosystemHandoffManifest.encoder().encode(manifest)
      .write(to: inbox(scheme).appendingPathComponent("\(manifest.id)/manifest.json"))
  }

  private func json(at url: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  private func writePresence(scheme: String = "provenance", handoff: Int = 1, accepts: [String] = ["game"],
                             systems: [String] = []) throws {
    var presence = EcosystemPresence.own()
    presence.scheme = scheme
    presence.handoff = handoff
    presence.accepts = accepts
    presence.systems = systems
    try presence.write(root: root)
  }

  /// Runs `onCopy` just before each file is copied, so a test can look at
  /// the drop box while a send is half done.
  private final class ObservingFileManager: FileManager {
    var onCopy: () -> Void = {}

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
      onCopy()
      try super.copyItem(at: srcURL, to: dstURL)
    }
  }

  // MARK: - Layout

  func test_wakeURLAndPaths() {
    XCTAssertEqual(
      EcosystemHandoff.wakeURL(to: "provenance", id: "H1")?.absoluteString,
      "provenance://handoff?id=H1&from=dolphinios"
    )
    XCTAssertEqual(
      EcosystemHandoff.inbox(for: "Provenance", root: root).path,
      root.appendingPathComponent("Handoff/provenance").path
    )
    XCTAssertEqual(
      EcosystemHandoff.presenceURL(for: "DolphiniOS", root: root).path,
      root.appendingPathComponent("Apps/dolphinios.json").path
    )
  }

  func test_systemIDs() {
    XCTAssertEqual(EcosystemHandoff.systemID(for: .gamecube), "gamecube")
    XCTAssertEqual(EcosystemHandoff.systemID(for: .wii), "wii")
    XCTAssertEqual(EcosystemHandoff.systemID(for: .wiiware), "wii")
    XCTAssertNil(EcosystemHandoff.systemID(for: .triforce))
    XCTAssertNil(EcosystemHandoff.systemID(for: .unknown))
  }

  func test_handoffURLParses() throws {
    let url = try XCTUnwrap(EcosystemHandoff.wakeURL(to: "dolphinios", id: "H1", from: "provenance"))
    XCTAssertEqual(EcosystemBridge.parse(url), .handoff)
    XCTAssertEqual(EcosystemBridge.parse(try XCTUnwrap(URL(string: "dolphinios://HandOff"))), .handoff)
    XCTAssertNil(EcosystemBridge.parse(try XCTUnwrap(URL(string: "provenance://handoff?id=H1"))))
  }

  // MARK: - Sending

  func test_stageWritesTheContractLayout() throws {
    let iso = try seed("Games/Melee.iso", "disc")
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    let manifest = try stage([iso], now: created)

    let handoff = inbox("provenance").appendingPathComponent("H1")
    XCTAssertEqual(try String(contentsOf: handoff.appendingPathComponent("files/Melee.iso"), encoding: .utf8), "disc")
    XCTAssertEqual(manifest.files, [.init(path: "Melee.iso", role: "primary", size: 4)])
    XCTAssertEqual(manifest.md5, "abcdef")
    // The source is untouched: a send is a copy.
    XCTAssertTrue(exists(iso))
    // Nothing is left under a staging name.
    XCTAssertEqual(names(in: inbox("provenance")), ["H1"])

    // The bytes on disk are the wire format the other apps read.
    let wire = try json(at: handoff.appendingPathComponent("manifest.json"))
    XCTAssertEqual(Set(wire.keys), ["version", "id", "from", "to", "created", "kind", "title", "system", "md5", "files"])
    XCTAssertEqual(wire["version"] as? Int, 1)
    XCTAssertEqual(wire["id"] as? String, "H1")
    XCTAssertEqual(wire["from"] as? String, "dolphinios")
    XCTAssertEqual(wire["to"] as? String, "provenance")
    XCTAssertEqual(wire["kind"] as? String, "game")
    XCTAssertEqual(wire["system"] as? String, "gamecube")
    XCTAssertEqual(wire["created"] as? String, "2027-01-15T08:00:00Z")
    let file = try XCTUnwrap((wire["files"] as? [[String: Any]])?.first)
    XCTAssertEqual(Set(file.keys), ["path", "role", "size"])
  }

  func test_stageOmitsAbsentOptionalFields() throws {
    let iso = try seed("a.iso")
    _ = try EcosystemHandoffStager.stage(
      files: [iso], to: "provenance", title: "Game", system: nil, md5: nil, root: root, id: "H1"
    )
    let wire = try json(at: inbox("provenance").appendingPathComponent("H1/manifest.json"))
    XCTAssertNil(wire["system"])
    XCTAssertNil(wire["md5"])
  }

  func test_stageKeepsNestedLayoutAndRoles() throws {
    let disc1 = try seed("Set/disc1.rvz")
    let notes = try seed("Set/extras/notes.txt")
    let disc2 = try seed("Elsewhere/disc2.rvz")

    let manifest = try stage([disc1, notes, disc2])

    XCTAssertEqual(manifest.files.map(\.path), ["disc1.rvz", "extras/notes.txt", "disc2.rvz"])
    XCTAssertEqual(manifest.files.map(\.role), ["primary", "companion", "primary"])
    XCTAssertTrue(exists(inbox("provenance").appendingPathComponent("H1/files/extras/notes.txt")))
  }

  func test_handoffIsInvisibleUntilItIsComplete() throws {
    let iso = try seed("a.iso")
    let observer = ObservingFileManager()
    var during: Set<String> = []
    var pendingDuring = -1
    observer.onCopy = { [self] in
      during = names(in: inbox("dolphinios"))
      pendingDuring = EcosystemHandoffInbox.pending(root: root).count
    }

    try stage([iso], to: "dolphinios", from: "provenance", fileManager: observer)

    XCTAssertEqual(during, [".H1.staging"])
    XCTAssertEqual(pendingDuring, 0)
    XCTAssertEqual(names(in: inbox("dolphinios")), ["H1"])
    XCTAssertEqual(EcosystemHandoffInbox.pending(root: root).map(\.manifest.id), ["H1"])
  }

  func test_stageWithNoFilesThrowsAndLeavesNothing() {
    XCTAssertThrowsError(try stage([])) { error in
      XCTAssertEqual(error as? EcosystemHandoffStager.StageError, .noFiles)
    }
    XCTAssertFalse(exists(inbox("provenance")))
  }

  func test_failedStageRemovesItsStagingDirectory() throws {
    let iso = try seed("a.iso")
    let missing = source.appendingPathComponent("gone.iso")

    XCTAssertThrowsError(try stage([iso, missing]))

    XCTAssertEqual(names(in: inbox("provenance")), [])
  }

  // MARK: - Presence

  func test_ownPresenceIsTheContractEntry() throws {
    let presence = EcosystemPresence.own(now: Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(presence.scheme, "dolphinios")
    XCTAssertEqual(presence.handoff, 1)
    XCTAssertEqual(presence.accepts, ["game"])
    XCTAssertEqual(presence.systems, ["gamecube", "wii"])

    try presence.write(root: root)

    let wire = try json(at: root.appendingPathComponent("Apps/dolphinios.json"))
    XCTAssertEqual(
      Set(wire.keys),
      ["version", "scheme", "bundleID", "appVersion", "build", "handoff", "accepts", "systems", "updated"]
    )
    XCTAssertEqual(wire["version"] as? Int, 1)
    XCTAssertEqual(wire["updated"] as? String, "2027-01-15T08:00:00Z")
    XCTAssertEqual(EcosystemPresence.read(scheme: "DolphiniOS", root: root), presence)
  }

  func test_presenceHonoursKindSystemsAndVersion() {
    var presence = EcosystemPresence.own()
    XCTAssertTrue(presence.accepts(kind: "game", system: "wii"))
    XCTAssertFalse(presence.accepts(kind: "game", system: "dreamcast"))
    XCTAssertTrue(presence.accepts(kind: "game", system: nil))
    XCTAssertFalse(presence.accepts(kind: "saves", system: "wii"))
    presence.systems = []
    XCTAssertTrue(presence.accepts(kind: "game", system: "dreamcast"))
    presence.handoff = 0
    XCTAssertFalse(presence.accepts(kind: "game", system: "wii"))
  }

  func test_directRouteNeedsAnInstalledPeerThatTakesTheGame() throws {
    func direct(installed: Bool = true, system: String? = "gamecube") -> Bool {
      EcosystemShareCenter.takesDirectHandoff(
        peer: "provenance", system: system, root: root, installed: installed
      )
    }
    // An older Provenance never wrote a presence entry.
    XCTAssertFalse(direct())

    try writePresence()
    XCTAssertTrue(direct())
    // The entry outlives the app that wrote it.
    XCTAssertFalse(direct(installed: false))

    try writePresence(handoff: 0)
    XCTAssertFalse(direct())

    try writePresence(accepts: ["saves"])
    XCTAssertFalse(direct())

    try writePresence(systems: ["dreamcast"])
    XCTAssertFalse(direct())
    XCTAssertFalse(direct(system: "wii"))

    try writePresence(systems: ["gamecube", "wii"])
    XCTAssertTrue(direct())
    XCTAssertTrue(direct(system: "wii"))

    // Another app's entry says nothing about Provenance.
    try fm.removeItem(at: root.appendingPathComponent("Apps/provenance.json"))
    try writePresence(scheme: "ifly")
    XCTAssertFalse(direct())
  }

  // MARK: - Receiving

  func test_pendingSeesOnlyCompleteHandoffsForThisApp() throws {
    let iso = try seed("a.iso")
    let now = Date()
    try stage([iso], to: "dolphinios", from: "provenance", id: "NEWER", now: now)
    try stage([iso], to: "dolphinios", from: "provenance", id: "OLDER", now: now.addingTimeInterval(-60))
    try stage([iso], to: "provenance", id: "THEIRS")
    // A send still in progress.
    try seed("Handoff/dolphinios/.HALF.staging/manifest.json", in: root, "{}")
    // A manifest from a newer protocol.
    var future = try stage([iso], to: "dolphinios", from: "provenance", id: "FUTURE")
    future.version = 99
    try rewrite(future)
    // A kind this build does not know.
    var saves = try stage([iso], to: "dolphinios", from: "provenance", id: "SAVES")
    saves.kind = "saves"
    try rewrite(saves)
    // Addressed to somebody else, but sitting in this inbox.
    var misfiled = try stage([iso], to: "dolphinios", from: "provenance", id: "MISFILED")
    misfiled.to = "ifly"
    try rewrite(misfiled)
    // Not a manifest at all, and a directory with none.
    try seed("Handoff/dolphinios/BROKEN/manifest.json", in: root, "not json")
    try seed("Handoff/dolphinios/EMPTY/files/a.iso", in: root)

    let pending = EcosystemHandoffInbox.pending(root: root)

    XCTAssertEqual(pending.map(\.manifest.id), ["OLDER", "NEWER"])
  }

  func test_receiveMovesTheGameIntoTheLibraryAndDeletesTheHandoff() throws {
    let iso = try seed("Melee.iso", "disc")
    try stage([iso], to: "dolphinios", from: "provenance")

    let received = EcosystemHandoffImporter.receive(root: root, into: library)

    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first?.manifest.from, "provenance")
    XCTAssertEqual(received.first?.placement.placed.map(\.lastPathComponent), ["Melee.iso"])
    XCTAssertEqual(received.first?.placement.primaries.map(\.lastPathComponent), ["Melee.iso"])
    XCTAssertEqual(received.first?.placement.rejected, [])
    XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("Melee.iso"), encoding: .utf8), "disc")
    // The library never sees the importer's staging name.
    XCTAssertEqual(names(in: library), ["Melee.iso"])
    XCTAssertEqual(names(in: inbox("dolphinios")), [])
    XCTAssertNil(EcosystemHandoffImporter.problemMessage(for: try XCTUnwrap(received.first)))
    // A second look finds nothing.
    XCTAssertEqual(EcosystemHandoffImporter.receive(root: root, into: library), [])
  }

  func test_receiveLeavesTheSameFileThatIsAlreadyInTheLibrary() throws {
    let iso = try seed("Melee.iso", "disc")
    try seed("Melee.iso", in: library, "disc")
    try stage([iso], to: "dolphinios", from: "provenance")

    let received = try XCTUnwrap(EcosystemHandoffImporter.receive(root: root, into: library).first)

    XCTAssertEqual(names(in: library), ["Melee.iso"])
    XCTAssertEqual(received.placement.placed, [])
    XCTAssertEqual(received.placement.alreadyPresent.count, 1)
    XCTAssertEqual(received.placement.primaries.map(\.lastPathComponent), ["Melee.iso"])
    XCTAssertNil(EcosystemHandoffImporter.problemMessage(for: received))
    XCTAssertEqual(names(in: inbox("dolphinios")), [])
  }

  func test_receiveKeepsADifferentGameThatHasTheSameFileName() throws {
    // Same length as the library's file: every full GameCube image is the same size.
    let sameSize = try seed("One/game.iso", "new")
    let otherSize = try seed("Two/game.iso", "longer")
    try seed("game.iso", in: library, "old")
    try stage([sameSize], to: "dolphinios", from: "provenance", id: "A", now: Date().addingTimeInterval(-60))
    try stage([otherSize], to: "dolphinios", from: "provenance", id: "B")

    let received = EcosystemHandoffImporter.receive(root: root, into: library)

    XCTAssertEqual(received.map { $0.placement.placed.map(\.lastPathComponent) }, [["game (2).iso"], ["game (3).iso"]])
    XCTAssertEqual(received.map { $0.placement.primaries.map(\.lastPathComponent) }, [["game (2).iso"], ["game (3).iso"]])
    XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("game.iso"), encoding: .utf8), "old")
    XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("game (2).iso"), encoding: .utf8), "new")
    XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("game (3).iso"), encoding: .utf8), "longer")
    XCTAssertEqual(names(in: inbox("dolphinios")), [])
  }

  func test_aFailedMoveKeepsTheHandoffForAnotherTry() throws {
    struct DiskFull: Error {}
    let disc1 = try seed("disc1.iso", "one")
    let disc2 = try seed("disc2.iso", "two")
    try stage([disc1, disc2], to: "dolphinios", from: "provenance")
    let pending = try XCTUnwrap(EcosystemHandoffInbox.pending(root: root).first)
    let extensions = ImportableFileTypes.softwareExtensions

    // The second file cannot be written this time.
    let first = EcosystemHandoffInbox.place(pending, into: library, allowedExtensions: extensions) { source, destination in
      if source.lastPathComponent == "disc2.iso" { throw DiskFull() }
      try EcosystemHandoffInbox.stagedMove(source, destination)
    }

    XCTAssertEqual(first.placed.map(\.lastPathComponent), ["disc1.iso"])
    XCTAssertEqual(first.failed, ["disc2.iso"])
    XCTAssertEqual(first.rejected, [])
    XCTAssertEqual(names(in: library), ["disc1.iso"])
    // The hand-off and the file that did not make it are still there.
    XCTAssertTrue(exists(pending.directory.appendingPathComponent("files/disc2.iso")))
    XCTAssertEqual(EcosystemHandoffInbox.pending(root: root).map(\.manifest.id), ["H1"])
    let message = try XCTUnwrap(
      EcosystemHandoffImporter.problemMessage(for: .init(manifest: pending.manifest, placement: first))
    )
    XCTAssertTrue(message.contains("try again"), message)
    XCTAssertFalse(message.contains("format"), message)

    // The next pass finishes the job and does not import the first file twice.
    let second = try XCTUnwrap(EcosystemHandoffImporter.receive(root: root, into: library).first)

    XCTAssertEqual(second.placement.placed.map(\.lastPathComponent), ["disc2.iso"])
    XCTAssertEqual(second.placement.alreadyPresent.map(\.lastPathComponent), ["disc1.iso"])
    XCTAssertEqual(second.placement.failed, [])
    XCTAssertEqual(names(in: library), ["disc1.iso", "disc2.iso"])
    XCTAssertEqual(names(in: inbox("dolphinios")), [])
    XCTAssertNil(EcosystemHandoffImporter.problemMessage(for: second))
  }

  func test_receiveRefusesUnsafePathsAndTypesItDoesNotImport() throws {
    let iso = try seed("game.iso")
    var manifest = try stage([iso], to: "dolphinios", from: "provenance")
    let directory = inbox("dolphinios").appendingPathComponent("H1")
    for path in ["../escape.iso", "/abs.iso", "sub/../../up.iso", ".hidden.iso", "notes.txt", "missing.iso"] {
      manifest.files.append(.init(path: path, role: "primary", size: 1))
    }
    try seed("files/notes.txt", in: directory)
    try seed("files/.hidden.iso", in: directory)
    // What "../escape.iso" would reach if it were followed.
    let escape = try seed("escape.iso", in: directory)
    try rewrite(manifest)

    let received = try XCTUnwrap(EcosystemHandoffImporter.receive(root: root, into: library).first)

    XCTAssertEqual(
      received.placement.rejected,
      ["../escape.iso", "/abs.iso", "sub/../../up.iso", ".hidden.iso", "notes.txt", "missing.iso"]
    )
    XCTAssertEqual(received.placement.placed.map(\.lastPathComponent), ["game.iso"])
    XCTAssertEqual(names(in: library), ["game.iso"])
    XCTAssertEqual(names(in: sandbox), ["Ecosystem", "Source", "Software"])
    // The hand-off is deleted whole, refused files included.
    XCTAssertFalse(exists(escape))
  }

  func test_receiveRefusesASymbolicLink() throws {
    let iso = try seed("game.iso")
    let outside = try seed("private.iso", in: sandbox.appendingPathComponent("Outside"), "secret")
    var manifest = try stage([iso], to: "dolphinios", from: "provenance")
    manifest.files = [.init(path: "link.iso", role: "primary", size: 6)]
    let directory = inbox("dolphinios").appendingPathComponent("H1")
    try fm.createSymbolicLink(at: directory.appendingPathComponent("files/link.iso"), withDestinationURL: outside)
    try rewrite(manifest)

    let received = try XCTUnwrap(EcosystemHandoffImporter.receive(root: root, into: library).first)

    XCTAssertEqual(received.placement.rejected, ["link.iso"])
    XCTAssertEqual(names(in: library), [])
    XCTAssertTrue(exists(outside))
    XCTAssertNotNil(EcosystemHandoffImporter.problemMessage(for: received))
  }

  func test_unsupportedFormatMessageNamesTheSenderAndTheGame() throws {
    let txt = try seed("notes.txt")
    try stage([txt], to: "dolphinios", from: "provenance")

    let received = try XCTUnwrap(EcosystemHandoffImporter.receive(root: root, into: library).first)

    let message = try XCTUnwrap(EcosystemHandoffImporter.problemMessage(for: received))
    XCTAssertTrue(message.contains("Provenance"), message)
    XCTAssertTrue(message.contains("Game"), message)
    XCTAssertEqual(names(in: inbox("dolphinios")), [])
  }

  func test_safeRelativePath() {
    XCTAssertTrue(EcosystemHandoffInbox.isSafeRelativePath("game.iso"))
    XCTAssertTrue(EcosystemHandoffInbox.isSafeRelativePath("Set/disc 1.rvz"))
    for bad in ["", "/abs.iso", "../up.iso", "a/../b.iso", "a//b.iso", "a\\b.iso", ".hidden.iso", "a/./b.iso",
                "a/.b/c.iso", "a/", "a\0b.iso"] {
      XCTAssertFalse(EcosystemHandoffInbox.isSafeRelativePath(bad), bad)
    }
  }

  // MARK: - Clean-up

  func test_garbageCollectionRemovesOnlyThisAppsStaleLeftovers() throws {
    let iso = try seed("a.iso")
    let now = Date()
    let old = now.addingTimeInterval(-EcosystemHandoff.staleAfter - 60)
    try stage([iso], id: "FRESH", now: now)
    try stage([iso], id: "STALE", now: old)
    try stage([iso], to: "dolphinios", from: "provenance", id: "THEIRS", now: old)
    let deadStaging = try seed("Handoff/provenance/.DEAD.staging/files/a.iso", in: root)
      .deletingLastPathComponent().deletingLastPathComponent()
    try fm.setAttributes(
      [.modificationDate: now.addingTimeInterval(-EcosystemHandoff.stagingStaleAfter - 60)],
      ofItemAtPath: deadStaging.path
    )
    try seed("Handoff/provenance/.LIVE.staging/files/a.iso", in: root)

    let removed = EcosystemHandoffStager.collectGarbage(root: root, now: now)

    XCTAssertEqual(removed, 2)
    XCTAssertEqual(names(in: inbox("provenance")), ["FRESH", ".LIVE.staging"])
    // Another app's hand-off is its sender's to remove, however old.
    XCTAssertEqual(names(in: inbox("dolphinios")), ["THEIRS"])
  }

  func test_garbageCollectionWithNoDropBoxDoesNothing() {
    XCTAssertEqual(EcosystemHandoffStager.collectGarbage(root: root), 0)
  }
}
