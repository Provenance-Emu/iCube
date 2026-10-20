// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import iCube

final class LibraryMetadataServiceTests: XCTestCase {
  func testSyntheticHomebrewIDsCannotClaimDiscIdentity() {
    for id in ["", "<unknown>", " <UNKNOWN> ", "ID-SameName", "id-another.dol"] {
      XCTAssertNil(LibraryMetadataStore.Identity.game(gameID: id, discNumber: 0, revision: 0), id)
    }
  }

  #if canImport(UIKit)
  /// A real game-model object with an injected getter, leaving production
  /// initializers/ivars untouched. Its bytes are real files, not hash doubles.
  private final class LocalGame: TVGameItem {
    var localPath = ""
    override var filePath: String { localPath }
  }

  @MainActor private func game(path: URL, gameID: String = "<unknown>", platform: Int = 4) -> TVGameItem {
    let item = LocalGame(demoTitle: "Unit Test Homebrew", gameID: gameID, platform: platform,
                         maker: "Unit Test", countryName: "USA", fileSize: 3, accentHue: 0.1)
    item.localPath = path.path
    return item
  }

  @MainActor private func withFolder(_ operation: @MainActor (URL) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataService-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let key = "icube.libraryMetadata.contentIdentities"
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
      try? FileManager.default.removeItem(at: folder)
      if let saved { UserDefaults.standard.set(saved, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    try await operation(folder)
  }

  @MainActor
  func testUnknownItemUsesContentHashAndSameSizePreservedMtimeReplacementInvalidatesIt() async throws {
    try await withFolder { folder in
      let file = folder.appendingPathComponent("same-name.dol")
      try Data("abc".utf8).write(to: file)
      let item = game(path: file)
      XCTAssertNil(LibraryMetadataService.identity(for: item))
      let initial = try await LibraryMetadataService.resolveIdentity(for: item)
      XCTAssertEqual(initial, LibraryMetadataStore.Identity.contentHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
      let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
      let handle = try FileHandle(forWritingTo: file)
      try handle.write(contentsOf: Data("xyz".utf8)); try handle.close()
      try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
      XCTAssertNil(LibraryMetadataService.identity(for: item), "A replacement must not inherit another ROM's edits")
      let replacement = try await LibraryMetadataService.resolveIdentity(for: item)
      XCTAssertNotEqual(replacement, initial)
      XCTAssertEqual(replacement, LibraryMetadataStore.Identity.contentHash("3608bca1e44ea6c4d268eb6db02260269892c0b42b86bbf1e77a6fa16c3c9282"))
    }
  }

  @MainActor
  func testElfWithPlausibleHeaderIDStillRequiresContentIdentity() throws {
    let item = game(path: URL(fileURLWithPath: "/missing-unit-test-file.dol"), gameID: "GFAKE1", platform: 4)
    XCTAssertNil(LibraryMetadataService.identity(for: item))
    let disc = game(path: URL(fileURLWithPath: "/missing-unit-test-disc.iso"), gameID: " gsre01 ", platform: 0)
    XCTAssertEqual(LibraryMetadataService.identity(for: disc), .game(gameID: "GSRE01", discNumber: 0, revision: 0))
  }

  @MainActor
  func testRenamedUnknownFileResolvesToTheSameContentIdentity() async throws {
    try await withFolder { folder in
      let original = folder.appendingPathComponent("old.dol")
      let renamed = folder.appendingPathComponent("new.dol")
      try Data("abc".utf8).write(to: original)
      let before = try await LibraryMetadataService.resolveIdentity(for: game(path: original))
      try FileManager.default.moveItem(at: original, to: renamed)
      let after = try await LibraryMetadataService.resolveIdentity(for: game(path: renamed))
      XCTAssertEqual(before, after)
    }
  }

  @MainActor
  func testCancelledIdentityResolutionDoesNotPublishAReceipt() async throws {
    try await withFolder { folder in
      let file = folder.appendingPathComponent("cancel.dol")
      try Data(repeating: 7, count: 4 * 1024 * 1024).write(to: file)
      let item = game(path: file, gameID: "")
      let task = Task { try await LibraryMetadataService.resolveIdentity(for: item) }
      task.cancel()
      do { _ = try await task.value; XCTFail("Cancelled hashing must fail") }
      catch { XCTAssertTrue(error is CancellationError) }
      XCTAssertNil(LibraryMetadataService.identity(for: item))
    }
  }

  private func largeImageData() throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1; format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 1536), format: format)
    let image = renderer.image { context in
      UIColor.orange.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
    }
    return try XCTUnwrap(image.pngData())
  }

  func testSyncedCoverProjectionBoundsDecodedPixels() throws {
    let data = try largeImageData()
    XCTAssertLessThanOrEqual(data.count, LibraryMetadataStore.maxCoverBytes)
    let image = try XCTUnwrap(LibraryMetadataService.coverImage(data))
    let pixels = try XCTUnwrap(image.cgImage)
    XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 1024)
    XCTAssertGreaterThan(pixels.width, 0)
    XCTAssertGreaterThan(pixels.height, 0)
  }

  func testCoverPreparationProducesBoundedDecodableJPEG() throws {
    let prepared = try LibraryMetadataService.prepareCover(largeImageData())
    XCTAssertLessThanOrEqual(prepared.count, LibraryMetadataStore.maxCoverBytes)
    XCTAssertNotNil(LibraryMetadataService.coverImage(prepared))
  }

  func testCorruptAndOversizedCoverInputsFail() {
    XCTAssertNil(LibraryMetadataService.coverImage(Data("not an image".utf8)))
    XCTAssertNil(LibraryMetadataService.coverImage(Data(repeating: 0, count: LibraryMetadataStore.maxCoverBytes + 1)))
    XCTAssertThrowsError(try LibraryMetadataService.prepareCover(Data("not an image".utf8)))
    XCTAssertThrowsError(try LibraryMetadataService.prepareCover(Data(repeating: 0, count: 12 * 1024 * 1024 + 1)))
  }
  #endif
}
