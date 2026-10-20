// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit
import ImageIO
import PVContinuity
import UIKit

/// Projects durable custom library fields into the existing Objective-C game model.
@objc(LibraryMetadataService)
final class LibraryMetadataService: NSObject {
  private static let contentIdentityKey = "icube.libraryMetadata.contentIdentities"
  private struct ContentIdentity: Codable {
    let sha256: String
    let fingerprint: ContinuityFileDigestCache.Fingerprint
  }
  private final class State: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var store: LibraryMetadataStore?
    var contentIdentities: [String: ContentIdentity] = [:]
    var warmingTask: Task<Void, Never>?
    var warmingGateInstalled = false
    var warmingRetryRequested = false
    var latestItems: [TVGameItem] = []
    var warmingObservers: [NSObjectProtocol] = []
    let covers = NSCache<NSString, UIImage>()
    init() {
      covers.totalCostLimit = 32 * 1024 * 1024
      covers.countLimit = 32
      if let data = UserDefaults.standard.data(forKey: contentIdentityKey),
         let saved = try? JSONDecoder().decode([String: ContentIdentity].self, from: data) {
        contentIdentities = saved
      }
    }
  }
  private static let state = State()

  static func store() throws -> LibraryMetadataStore {
    state.lock.lock()
    defer { state.lock.unlock() }
    if let store = state.store { return store }
    let directory = URL(fileURLWithPath: UserFolderUtil.getUserFolder(), isDirectory: true)
      .appendingPathComponent("Profiles/LibraryMetadata", isDirectory: true)
    let store = try LibraryMetadataStore(directoryURL: directory, withFileAccess: { operation in
      try LibraryStateStore.withFileAccess(operation)
    })
    state.store = store
    return store
  }

  static func identity(for item: TVGameItem) -> LibraryMetadataStore.Identity? {
    if let identity = discIdentity(for: item) {
      return identity
    }
    state.lock.lock()
    let receipt = state.contentIdentities[item.filePath]
    state.lock.unlock()
    guard let receipt, item.filePath.hasPrefix("/"),
          let current = try? ContinuityFileDigestCache.fingerprint(at: URL(fileURLWithPath: item.filePath)),
          current == receipt.fingerprint else { return nil }
    return LibraryMetadataStore.Identity.contentHash(receipt.sha256)
  }

  static func discIdentity(for item: TVGameItem) -> LibraryMetadataStore.Identity? {
    // DiscIO::Platform::ELFOrDOL is 4. Its ID-<basename> and <unknown> values
    // identify filenames/placeholders, never the actual executable contents.
    guard item.platform != 4 else { return nil }
    return LibraryMetadataStore.Identity.game(gameID: item.gameID, discNumber: item.discNumber, revision: item.revision)
  }

  /// Hash only an explicitly edited unidentified file, off the main actor.
  /// The content identity survives a rename and never aliases equal filenames.
  static func resolveIdentity(for item: TVGameItem) async throws -> LibraryMetadataStore.Identity {
    if let identity = identity(for: item) { return identity }
    let path = item.filePath
    guard path.hasPrefix("/") else { throw CocoaError(.fileReadUnsupportedScheme) }
    let before = try ContinuityFileDigestCache.fingerprint(at: URL(fileURLWithPath: path))
    let hashTask = Task.detached(priority: .utility) {
      let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      defer { try? file.close() }
      var digest = SHA256()
      while true {
        try Task.checkCancellation()
        guard let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
        digest.update(data: chunk)
      }
      return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    let hash = try await withTaskCancellationHandler { try await hashTask.value } onCancel: { hashTask.cancel() }
    try Task.checkCancellation()
    let after = try ContinuityFileDigestCache.fingerprint(at: URL(fileURLWithPath: path))
    guard before == after else {
      throw CocoaError(.fileReadUnknown)
    }
    guard let identity = LibraryMetadataStore.Identity.contentHash(hash) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    rememberContentIdentity(ContentIdentity(sha256: hash, fingerprint: after), path: path)
    return identity
  }

  private static func rememberContentIdentity(_ identity: ContentIdentity, path: String) {
    state.lock.lock()
    state.contentIdentities[path] = identity
    if let data = try? JSONEncoder().encode(state.contentIdentities) {
      UserDefaults.standard.set(data, forKey: contentIdentityKey)
    }
    state.lock.unlock()
  }

  /// Resolve small unidentified/homebrew entries after a library scan, never in
  /// a title getter. Larger unidentified files are hashed on explicit editing.
  @MainActor static func resumeContentIdentityWarming() {
    warmContentIdentities(for: state.latestItems)
  }

  @MainActor static func warmContentIdentities(for items: [TVGameItem]) {
    state.latestItems = items
    if !state.warmingGateInstalled {
      state.warmingGateInstalled = true
      EmulationState.shared.addTransitionHandler { active in
        if active { state.warmingTask?.cancel() }
        else { resumeContentIdentityWarming() }
      }
      let center = NotificationCenter.default
      state.warmingObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { state.warmingTask?.cancel() }
      })
      state.warmingObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { resumeContentIdentityWarming() }
      })
    }
    guard UIApplication.shared.applicationState == .active,
          !EmulationState.shared.isActive, !SyncLocalIOGate.shared.isEmulating else { return }
    let missing = items.filter {
      discIdentity(for: $0) == nil && identity(for: $0) == nil && $0.fileSize <= 64 * 1024 * 1024
        && $0.filePath.hasPrefix("/")
    }
    guard !missing.isEmpty else { return }
    guard state.warmingTask == nil else {
      // An accepted foreground/drain event can arrive before the cancelled
      // hasher unwinds. Preserve that single retry until its task exits.
      if state.warmingTask?.isCancelled == true { state.warmingRetryRequested = true }
      return
    }
    state.warmingTask = Task { @MainActor in
      var changed = false
      for item in missing {
        guard !Task.isCancelled, UIApplication.shared.applicationState == .active,
              !EmulationState.shared.isActive, !SyncLocalIOGate.shared.isEmulating else { break }
        if (try? await resolveIdentity(for: item)) != nil { changed = true }
      }
      state.warmingTask = nil
      let retry = state.warmingRetryRequested
      state.warmingRetryRequested = false
      if changed { didChange() }
      if retry { resumeContentIdentityWarming() }
    }
  }

  @objc static func customTitle(for item: TVGameItem) -> String? {
    guard let identity = identity(for: item) else { return nil }
    return (try? store().summary(for: identity))?.title
  }

  @objc static func customCover(for item: TVGameItem) -> UIImage? {
    guard let identity = identity(for: item) else { return nil }
    if let cached = state.covers.object(forKey: identity.rawValue as NSString) { return cached }
    guard let data = (try? store().draft(for: identity))?.coverData, let image = coverImage(data) else { return nil }
    let decodedCost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
    state.covers.setObject(image, forKey: identity.rawValue as NSString, cost: decodedCost)
    return image
  }

  /// Apply the same bounded ImageIO decode to synced covers as to local images.
  static func coverImage(_ data: Data) -> UIImage? {
    guard data.count <= LibraryMetadataStore.maxCoverBytes,
          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
          ] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
  }

  @objc static func tags(for item: TVGameItem) -> [String] {
    guard let identity = identity(for: item) else { return [] }
    return (try? store().summary(for: identity))?.tags ?? []
  }

  static func reloadAfterSync() {
    // The store preserves the prior valid projection if a downloaded shard is malformed.
    try? store().reload()
    didChange()
  }

  static func didChange() {
    state.covers.removeAllObjects()
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: Notification.Name("GameFileMetadataUpdated"), object: nil)
    }
  }

  /// Decode to a bounded thumbnail before rendering/compression, including large photos.
  static func prepareCover(_ data: Data) throws -> Data {
    guard data.count <= 12 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    for pixels in [1024, 640, 400] {
      let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
      for quality in [0.8, 0.6, 0.4] {
        if let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: CGFloat(quality)), jpeg.count <= LibraryMetadataStore.maxCoverBytes {
          return jpeg
        }
      }
    }
    throw CocoaError(.fileReadCorruptFile)
  }
}
