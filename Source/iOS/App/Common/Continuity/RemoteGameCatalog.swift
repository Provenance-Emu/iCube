// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import ImageIO
import PVContinuity
import PVRemoteLibrary
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
  /// The cover as the server has it now. `etag` is what the cover cache already holds, if anything;
  /// a request that fails throws, so the cache can show its copy.
  func artwork(for entry: ContinuityLibraryEntry, etag: String?) async throws -> ArtworkResult
  /// Downloads the game into `folder` without adding it to the library. Only a server that can play a
  /// game without keeping it does this.
  func copyTemporarily(
    _ entry: ContinuityLibraryEntry, into folder: URL, progress: @escaping @Sendable (PullProgress) -> Void
  ) async throws -> [URL]
  func copy(_ entry: ContinuityLibraryEntry, progress: @escaping @Sendable (PullProgress) -> Void) async throws -> [URL]
  /// The server refused the saved login, so the user has to connect again.
  nonisolated func isAccessDenied(_ error: any Error) -> Bool
  /// The server's id in the background download journal.
  nonisolated var downloadSourceID: String { get }
  /// What kind of server this is, for the shared library model.
  nonisolated var sourceKind: LibrarySourceInfo.Kind { get }
}

extension RemoteGameCatalog {
  func copyTemporarily(
    _ entry: ContinuityLibraryEntry, into folder: URL, progress: @escaping @Sendable (PullProgress) -> Void
  ) async throws -> [URL] {
    throw RemoteSourceError.importsDirectly
  }
}

/// The covers of every remote library, downscaled and kept on disk by the shared cache (PVRemoteLibrary),
/// so a grid redraws without the network. Each cover keeps its source's ETag: the next read sends it back
/// and an unchanged cover costs no body.
enum RemoteCovers {
  /// Longest side kept, in pixels: enough for a tvOS card at 2x.
  static let maximumPixelSize = RemoteCoverCache.defaultMaxPixelSize
  private static let jpegQuality = 0.85
  /// Where iCube's own cover cache kept its files before the shared one replaced it.
  private static let legacyFolderName = "RemoteCovers"

  static let shared: RemoteCoverCache = {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    try? FileManager.default.removeItem(at: caches.appendingPathComponent(legacyFolderName, isDirectory: true))
    return RemoteCoverCache(directory: caches.appendingPathComponent("RemoteLibraryCovers", isDirectory: true))
  }()

  /// A cover no larger than `maximumPixelSize`, for writing a player's cover back to a server.
  static func thumbnail(_ data: Data, maximumPixelSize: Int = RemoteCovers.maximumPixelSize) -> Data? {
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
