// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import XCTest
import zlib
@testable import iCube

/// Builds a zip with stored (uncompressed) entries, so tests need no archive fixtures.
enum TestZip {
  static func make(_ files: [(path: String, contents: Data)]) -> Data {
    var body = Data()
    var directory = Data()
    for file in files {
      let name = Data(file.path.utf8)
      let crc = file.contents.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
      let offset = UInt32(body.count)
      var local = Data()
      local.append(le32: 0x0403_4B50)
      local.append(le16: 20)
      local.append(le16: 0)
      local.append(le16: 0)
      local.append(le16: 0)
      local.append(le16: 0x21)
      local.append(le32: crc)
      local.append(le32: UInt32(file.contents.count))
      local.append(le32: UInt32(file.contents.count))
      local.append(le16: UInt16(name.count))
      local.append(le16: 0)
      body.append(local)
      body.append(name)
      body.append(file.contents)

      directory.append(le32: 0x0201_4B50)
      directory.append(le16: 20)
      directory.append(le16: 20)
      directory.append(le16: 0)
      directory.append(le16: 0)
      directory.append(le16: 0)
      directory.append(le16: 0x21)
      directory.append(le32: crc)
      directory.append(le32: UInt32(file.contents.count))
      directory.append(le32: UInt32(file.contents.count))
      directory.append(le16: UInt16(name.count))
      directory.append(le16: 0)
      directory.append(le16: 0)
      directory.append(le16: 0)
      directory.append(le16: 0)
      directory.append(le32: 0)
      directory.append(le32: offset)
      directory.append(name)
    }
    var end = Data()
    end.append(le32: 0x0605_4B50)
    end.append(le16: 0)
    end.append(le16: 0)
    end.append(le16: UInt16(files.count))
    end.append(le16: UInt16(files.count))
    end.append(le32: UInt32(directory.count))
    end.append(le32: UInt32(body.count))
    end.append(le16: 0)
    return body + directory + end
  }
}

private extension Data {
  mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
  mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

/// Hands back a prepared archive instead of fetching one.
final class FakeHomebrewDownloader: HomebrewDownloading, @unchecked Sendable {
  private let lock = NSLock()
  private var _calls: [(key: String, source: URL, fileName: String)] = []
  var archive = Data()
  var etag: String?
  var error: Error?
  /// When set, the download waits here until the test lets it go (or the task is cancelled).
  var hold: AsyncStream<Void>?

  var calls: [(key: String, source: URL, fileName: String)] { lock.withLock { _calls } }

  func download(key: String, from source: URL, fileName: String, expectedBytes: Int64, into directory: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> HomebrewDownload {
    lock.withLock { _calls.append((key, source, fileName)) }
    if let hold {
      for await _ in hold {}
      try Task.checkCancellation()
    }
    if let error { throw error }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(fileName)
    try archive.write(to: file)
    progress(1)
    return HomebrewDownload(file: file, etag: etag)
  }
}

final class FakeHomebrewRegistrar: HomebrewLibraryRegistering, @unchecked Sendable {
  private let lock = NSLock()
  private var _registered: [(program: URL, title: String, cover: Data?)] = []
  var bootable = true
  var existing: (title: String?, cover: Data?) = (nil, nil)
  var registerError: Error?

  var registered: [(program: URL, title: String, cover: Data?)] { lock.withLock { _registered } }

  /// Called while a registration is in progress.
  var onRegister: (@Sendable () -> Void)?

  func canBoot(_ program: URL) -> Bool { bootable }
  func metadata(of program: URL) async -> (title: String?, cover: Data?) { existing }
  @MainActor func publish(_ program: URL) {}

  func register(_ program: URL, title: String, cover: Data?) async throws {
    if let registerError { throw registerError }
    onRegister?()
    lock.withLock { _registered.append((program, title, cover)) }
  }
}

final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var value: [String] { lock.withLock { stored } }
  func set(_ new: [String]) { lock.withLock { stored = new } }
}

@MainActor
final class HomebrewInstallModelTests: XCTestCase {
  private var scratch: HomebrewScratch!
  private var root: URL!
  private var downloader: FakeHomebrewDownloader!
  private var registrar: FakeHomebrewRegistrar!
  private var coverRequests: [URL] = []
  private var coverData: Data? = Data("cover".utf8)
  private var free: Int64? = 1 << 40
  private var models: [HomebrewInstallModel] = []

  override func setUp() async throws {
    scratch = try HomebrewScratch()
    root = scratch.root.appendingPathComponent("Homebrew", isDirectory: true)
    downloader = FakeHomebrewDownloader()
    registrar = FakeHomebrewRegistrar()
    coverRequests = []
    coverData = Data("cover".utf8)
    free = 1 << 40
    models = []
  }

  override func tearDown() async throws {
    for model in models { try? FileManager.default.removeItem(at: model.workDirectory) }
    scratch = nil
  }

  private static func package(program: String = "apps/quest/default.dol", contents: String = "DOL v1") -> Data {
    TestZip.make([(program, Data(contents.utf8)), ("apps/quest/opening.bnr", Data("bnr".utf8))])
  }

  private func title(version: String = "10", archive: Data, slug: String = "quest") -> HomebrewTitle {
    HomebrewTestData.title(slug, name: "Block Quest",
                           latest: HomebrewTestData.version(version, size: Int64(archive.count), fileName: "quest_\(version)_dist.zip"),
                           screenshots: ["quest/screenshot0.png"])
  }

  private func model(_ title: HomebrewTitle) -> HomebrewInstallModel {
    let cover = coverData
    let free = free
    let model = HomebrewInstallModel(
      title: title, root: root, downloader: downloader, registrar: registrar,
      cover: { [weak self] url in
        await MainActor.run { self?.coverRequests.append(url) }
        return cover
      },
      availableBytes: { free })
    models.append(model)
    return model
  }

  /// Starts an install and waits for it to stop.
  private func run(_ model: HomebrewInstallModel, file: StaticString = #filePath, line: UInt = #line) async {
    model.requestStart()
    await settle(model, file: file, line: line)
  }

  private func settle(_ model: HomebrewInstallModel, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0 ..< 2000 {
      switch model.phase {
      case .idle, .installed, .failed: if !model.isBusy { return }
      case .downloading, .verifying, .installing: break
      }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("install did not settle: \(model.phase)", file: file, line: line)
  }

  private func install(version: String = "10", contents: String = "DOL v1") async -> HomebrewInstallModel {
    let archive = Self.package(contents: contents)
    downloader.archive = archive
    let model = model(title(version: version, archive: archive))
    await run(model)
    return model
  }

  private var entries: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
  }

  // MARK: - Installing

  func testHappyPathInstallsRegistersAndRecords() async throws {
    let model = await install()
    XCTAssertEqual(model.phase, .installed)
    XCTAssertEqual(model.state, .installed)
    XCTAssertTrue(scratch.exists("Homebrew/quest/apps/quest/quest.dol"))
    XCTAssertTrue(scratch.exists("Homebrew/quest/apps/quest/opening.bnr"))
    XCTAssertFalse(scratch.exists("Homebrew/quest/apps/quest/default.dol"))
    XCTAssertEqual(entries, ["installed.json", "quest"])

    let registered = try XCTUnwrap(registrar.registered.first)
    XCTAssertEqual(registrar.registered.count, 1)
    XCTAssertEqual(registered.program.resolvingSymlinksInPath().path, root.appendingPathComponent("quest/apps/quest/quest.dol").path)
    XCTAssertEqual(registered.title, "Block Quest")
    XCTAssertEqual(registered.cover, Data("cover".utf8))
    XCTAssertEqual(coverRequests.map(\.absoluteString), ["https://cdn.dolphindepot.org/quest/image/screenshot0.png"])

    let entry = try XCTUnwrap(HomebrewInstalledIndex.load(root: root).titles["quest"])
    XCTAssertEqual(entry.versionSlug, "10")
    XCTAssertEqual(entry.programPath, "quest/apps/quest/quest.dol")
    XCTAssertEqual(model.programURL?.lastPathComponent, "quest.dol")
    XCTAssertFalse(FileManager.default.fileExists(atPath: model.workDirectory.path))

    let call = try XCTUnwrap(downloader.calls.first)
    XCTAssertEqual(call.source.absoluteString, "https://cdn.dolphindepot.org/quest/release/quest_10_dist.zip")
    XCTAssertEqual(call.fileName, "quest_10_dist.zip")
  }

  /// Several builds in one package: the plain one is installed, and the others stay beside it.
  func testPackageWithSeveralBuildsInstallsThePlainOne() async throws {
    let archive = TestZip.make([("apps/quest-exp/default.dol", Data("experimental".utf8)),
                                ("apps/quest/default.dol", Data("plain".utf8))])
    downloader.archive = archive
    let model = model(title(archive: archive))
    await run(model)
    XCTAssertEqual(model.phase, .installed)
    let program = try XCTUnwrap(model.programURL)
    XCTAssertEqual(try String(contentsOf: program, encoding: .utf8), "plain")
    XCTAssertEqual(HomebrewInstalledIndex.load(root: root).titles["quest"]?.programPath, "quest/apps/quest/quest.dol")
  }

  func testMatchingMD5EtagInstalls() async {
    let archive = Self.package()
    downloader.archive = archive
    downloader.etag = "\"" + Insecure.MD5.hash(data: archive).map { String(format: "%02X", $0) }.joined() + "\""
    let model = model(title(archive: archive))
    await run(model)
    XCTAssertEqual(model.phase, .installed)
  }

  func testSizeMismatchFailsAndRegistersNothing() async {
    let archive = Self.package()
    downloader.archive = archive + Data([0])
    let model = model(title(archive: archive))
    await run(model)
    XCTAssertEqual(model.phase, .failed(HomebrewInstallError.sizeMismatch.localizedDescription))
    XCTAssertEqual(model.state, .notInstalled)
    XCTAssertEqual(entries, [])
    XCTAssertTrue(registrar.registered.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: model.workDirectory.path))
  }

  func testChecksumMismatchFails() async {
    let archive = Self.package()
    downloader.archive = archive
    downloader.etag = "\"00000000000000000000000000000000\""
    let model = model(title(archive: archive))
    await run(model)
    XCTAssertEqual(model.phase, .failed(HomebrewInstallError.checksumMismatch.localizedDescription))
    XCTAssertEqual(entries, [])
    XCTAssertTrue(registrar.registered.isEmpty)
  }

  func testNonMD5EtagIsIgnored() async {
    for etag in ["W/\"abc\"", "\"0123456789abcdef0123456789abcdef-2\"", ""] {
      try? FileManager.default.removeItem(at: root)
      let archive = Self.package()
      downloader.archive = archive
      downloader.etag = etag
      let model = model(title(archive: archive))
      await run(model)
      XCTAssertEqual(model.phase, .installed, etag)
    }
  }

  func testBadZipFails() async {
    let archive = Data("this is not a zip archive at all".utf8)
    downloader.archive = archive
    let model = model(title(archive: archive))
    await run(model)
    guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
    XCTAssertEqual(entries, [])
    XCTAssertTrue(registrar.registered.isEmpty)
  }

  func testPackageWithoutProgramFails() async {
    let archive = TestZip.make([("apps/quest/readme.txt", Data("hi".utf8))])
    downloader.archive = archive
    let model = model(title(archive: archive))
    await run(model)
    XCTAssertEqual(model.phase, .failed(L("This package has no program iCube can start.")))
    XCTAssertEqual(entries, [])
  }

  func testProgramTheCoreRejectsFails() async {
    registrar.bootable = false
    let model = await install()
    XCTAssertEqual(model.phase, .failed(HomebrewInstallError.cannotBoot.localizedDescription))
    XCTAssertEqual(entries, [])
    XCTAssertTrue(registrar.registered.isEmpty)
  }

  func testProgramAtTheZipRootInstalls() async {
    let archive = TestZip.make([("game.elf", Data("ELF".utf8))])
    downloader.archive = archive
    let model = model(title(archive: archive))
    await run(model)
    XCTAssertEqual(model.phase, .installed)
    XCTAssertTrue(scratch.exists("Homebrew/quest/quest.elf"))
  }

  func testTitleWithoutPackageFails() async {
    let model = model(HomebrewTestData.title("quest", latest: nil))
    await run(model)
    XCTAssertEqual(model.phase, .failed(HomebrewInstallError.noPackage.localizedDescription))
    XCTAssertTrue(downloader.calls.isEmpty)
  }

  func testNotEnoughSpaceFailsBeforeDownloading() async {
    free = 10
    let archive = Self.package()
    downloader.archive = archive
    let model = model(title(archive: archive))
    await run(model)
    guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
    XCTAssertTrue(downloader.calls.isEmpty)
  }

  func testLargeDownloadAsksFirst() async {
    let huge = HomebrewTestData.title("quest", latest: HomebrewTestData.version("10", size: ModBrowser.largeDownloadBytes + 1))
    let model = model(huge)
    model.requestStart()
    XCTAssertEqual(model.largeDownloadBytes, ModBrowser.largeDownloadBytes + 1)
    XCTAssertEqual(model.phase, .idle)
    XCTAssertTrue(downloader.calls.isEmpty)
  }

  func testDownloadErrorFailsAndLeavesNothing() async {
    downloader.error = URLError(.networkConnectionLost)
    let model = model(title(archive: Self.package()))
    await run(model)
    guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
    XCTAssertEqual(entries, [])
  }

  func testCoverFetchFailureStillInstalls() async throws {
    coverData = nil
    let model = await install()
    XCTAssertEqual(model.phase, .installed)
    XCTAssertEqual(registrar.registered.count, 1)
    XCTAssertNil(try XCTUnwrap(registrar.registered.first).cover)
  }

  func testRegistrationFailureRollsBackAFirstInstall() async {
    registrar.registerError = CocoaError(.fileReadUnknown)
    let model = await install()
    guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
    XCTAssertEqual(entries, [])
    XCTAssertEqual(model.state, .notInstalled)
  }

  // MARK: - Updating

  func testUpdateReplacesTheFolderAndRecordsTheNewVersion() async throws {
    _ = await install(version: "10", contents: "DOL v1")
    try scratch.file("Homebrew/quest/apps/quest/leftover.txt")
    let archive = Self.package(contents: "DOL v2")
    downloader.archive = archive
    let update = model(title(version: "11", archive: archive))
    XCTAssertEqual(update.state, .updateAvailable)
    await run(update)
    XCTAssertEqual(update.phase, .installed)
    XCTAssertEqual(update.state, .installed)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("quest/apps/quest/quest.dol"), encoding: .utf8), "DOL v2")
    XCTAssertFalse(scratch.exists("Homebrew/quest/apps/quest/leftover.txt"))
    XCTAssertEqual(HomebrewInstalledIndex.load(root: root).titles["quest"]?.versionSlug, "11")
    XCTAssertEqual(entries, ["installed.json", "quest"])
  }

  func testUpdateKeepsUserTitleAndCover() async throws {
    _ = await install(version: "10")
    registrar.existing = ("My Name", Data("mine".utf8))
    coverRequests = []
    let archive = Self.package(contents: "DOL v2")
    downloader.archive = archive
    let update = model(title(version: "11", archive: archive))
    await run(update)
    let registered = try XCTUnwrap(registrar.registered.last)
    XCTAssertEqual(registered.title, "My Name")
    XCTAssertEqual(registered.cover, Data("mine".utf8))
    XCTAssertEqual(coverRequests, [])
  }

  func testUpdateFillsInWhatTheOldEntryLacks() async throws {
    _ = await install(version: "10")
    registrar.existing = ("My Name", nil)
    let archive = Self.package(contents: "DOL v2")
    downloader.archive = archive
    let update = model(title(version: "11", archive: archive))
    await run(update)
    let registered = try XCTUnwrap(registrar.registered.last)
    XCTAssertEqual(registered.title, "My Name")
    XCTAssertEqual(registered.cover, Data("cover".utf8))
  }

  func testFailedUpdateKeepsOldVersion() async throws {
    _ = await install(version: "10", contents: "DOL v1")
    let archive = TestZip.make([("apps/quest/readme.txt", Data("no program".utf8))])
    downloader.archive = archive
    let update = model(title(version: "11", archive: archive))
    await run(update)
    guard case .failed = update.phase else { return XCTFail("\(update.phase)") }
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("quest/apps/quest/quest.dol"), encoding: .utf8), "DOL v1")
    XCTAssertEqual(HomebrewInstalledIndex.load(root: root).titles["quest"]?.versionSlug, "10")
    XCTAssertEqual(update.state, .updateAvailable)
    XCTAssertEqual(entries, ["installed.json", "quest"])
  }

  func testUpdateWhoseRegistrationFailsPutsTheOldVersionBack() async throws {
    _ = await install(version: "10", contents: "DOL v1")
    registrar.registerError = CocoaError(.fileReadUnknown)
    let archive = Self.package(contents: "DOL v2")
    downloader.archive = archive
    let update = model(title(version: "11", archive: archive))
    await run(update)
    guard case .failed = update.phase else { return XCTFail("\(update.phase)") }
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("quest/apps/quest/quest.dol"), encoding: .utf8), "DOL v1")
    XCTAssertEqual(HomebrewInstalledIndex.load(root: root).titles["quest"]?.versionSlug, "10")
    XCTAssertEqual(entries, ["installed.json", "quest"])
  }

  // MARK: - Cancelling and state

  func testCancelReturnsToIdleAndLeavesNothing() async {
    let (stream, gate) = AsyncStream<Void>.makeStream()
    downloader.hold = stream
    let archive = Self.package()
    downloader.archive = archive
    let model = model(title(archive: archive))
    model.requestStart()
    XCTAssertEqual(model.phase, .downloading(0))
    model.cancel()
    gate.finish()
    await settle(model)
    XCTAssertEqual(model.phase, .idle)
    XCTAssertEqual(entries, [])
    XCTAssertTrue(registrar.registered.isEmpty)
  }

  func testStartingTwiceRunsOnce() async {
    let archive = Self.package()
    downloader.archive = archive
    let model = model(title(archive: archive))
    model.requestStart()
    model.requestStart()
    await settle(model)
    XCTAssertEqual(downloader.calls.count, 1)
  }

  func testSecondModelCannotStartWhileOneInstalls() async {
    let (stream, gate) = AsyncStream<Void>.makeStream()
    downloader.hold = stream
    let archive = Self.package()
    downloader.archive = archive
    let first = model(title(archive: archive))
    first.requestStart()
    await Task.yield()
    let second = model(title(archive: archive))
    second.requestStart()
    XCTAssertFalse(second.isBusy)
    XCTAssertTrue(HomebrewInstallModel.installingSlugs.contains("quest"))
    XCTAssertTrue(HomebrewInstallModel.attach(title: title(archive: archive), root: root) === first)
    gate.finish()
    await settle(first)
    XCTAssertEqual(first.phase, .installed)
    XCTAssertEqual(downloader.calls.count, 1)
    XCTAssertFalse(HomebrewInstallModel.installingSlugs.contains("quest"))
    XCTAssertFalse(HomebrewInstallModel.attach(title: title(archive: archive), root: root) === first)
  }

  func testUpdateKeepsThePreviousVersionOutOfTheLibraryFolder() async throws {
    _ = await install(version: "10")
    let root = try XCTUnwrap(self.root)
    let seen = Seen()
    registrar.onRegister = {
      seen.set(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted())
    }
    let archive = Self.package(contents: "DOL v2")
    downloader.archive = archive
    let update = model(title(version: "11", archive: archive))
    await run(update)
    XCTAssertEqual(update.phase, .installed)
    XCTAssertEqual(seen.value, ["installed.json", "quest"])
  }

  func testDeletedProgramShowsDownloadAgain() async throws {
    _ = await install()
    try FileManager.default.removeItem(at: root.appendingPathComponent("quest/apps/quest/quest.dol"))
    let archive = Self.package()
    let again = model(title(archive: archive))
    XCTAssertEqual(again.state, .notInstalled)
    XCTAssertNil(again.programURL)
  }

  func testInstallOverALeftoverFolderWithNoEntrySucceeds() async throws {
    try scratch.file("Homebrew/quest/apps/quest/opening.bnr", "old")
    let model = await install()
    XCTAssertEqual(model.phase, .installed)
    XCTAssertTrue(scratch.exists("Homebrew/quest/apps/quest/quest.dol"))
    XCTAssertEqual(entries, ["installed.json", "quest"])
  }
}
