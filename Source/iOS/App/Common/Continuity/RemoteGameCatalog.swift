// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import ImageIO
import PVContinuity
import UniformTypeIdentifiers

/// One page of a server's games.
struct RemoteCatalogPage: Sendable {
  let entries: [ContinuityLibraryEntry]
  let hasMore: Bool
  /// Games the server counts for this search, once every library or platform has reported; nil until then.
  let total: Int?
}

/// A server the library pages through and imports from: an Emulation Server or a RomM instance.
/// The catalog keeps its own position, so `continueCatalog` reads the page after the last one returned.
protocol RemoteGameCatalog: Actor {
  func openCatalog(search: String) async throws -> RemoteCatalogPage
  func continueCatalog() async throws -> RemoteCatalogPage
  /// The size of the whole catalog, without reading it.
  func gameCount() async throws -> Int
  func artwork(for entry: ContinuityLibraryEntry) async -> Data?
  func copy(_ entry: ContinuityLibraryEntry, progress: @escaping @Sendable (PullProgress) -> Void) async throws -> [URL]
  /// The server refused the saved login, so the user has to connect again.
  nonisolated func isAccessDenied(_ error: any Error) -> Bool
}

/// Covers from servers, downscaled and kept on disk so a grid redraws without the network. Each cover keeps
/// the server's ETag: the next read sends it back and an unchanged cover costs no body.
actor RemoteCoverCache {
  static let shared = RemoteCoverCache(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("RemoteCovers", isDirectory: true))

  struct Cover: Sendable {
    let data: Data
    let etag: String?
  }

  /// Longest side kept, in pixels: enough for a tvOS card at 2x.
  static let maximumPixelSize = 640
  private static let jpegQuality = 0.85

  private let folder: URL

  init(folder: URL) {
    self.folder = folder
  }

  func cover(for key: String) -> Cover? {
    let base = file(for: key)
    guard let data = try? Data(contentsOf: base.appendingPathExtension("img")), !data.isEmpty else { return nil }
    let etag = (try? Data(contentsOf: base.appendingPathExtension("etag"))).flatMap { String(data: $0, encoding: .utf8) }
    return Cover(data: data, etag: etag)
  }

  /// Stores the downscaled cover and returns it. Bytes that are not an image are not kept.
  func store(_ original: Data, etag: String?, for key: String) -> Data? {
    guard let data = Self.thumbnail(original) else { return nil }
    let base = file(for: key)
    let manager = FileManager.default
    try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
    try? data.write(to: base.appendingPathExtension("img"), options: .atomic)
    let tag = base.appendingPathExtension("etag")
    if let etag, !etag.isEmpty {
      try? Data(etag.utf8).write(to: tag, options: .atomic)
    } else {
      try? manager.removeItem(at: tag)
    }
    return data
  }

  private func file(for key: String) -> URL {
    let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return folder.appendingPathComponent(name)
  }

  static func thumbnail(_ data: Data, maximumPixelSize: Int = RemoteCoverCache.maximumPixelSize) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    let type = opaque ? UTType.jpeg : UTType.png
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
    let properties: [CFString: Any] = opaque ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] : [:]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }
}
