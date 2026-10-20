// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

/// App-owned custom library fields. This file is separate from emulator profiles,
/// so resetting per-game emulation settings cannot remove library edits.
final class LibraryMetadataStore {
  struct Identity: Hashable, Sendable {
    let rawValue: String
    fileprivate init(_ rawValue: String) { self.rawValue = rawValue }
    var fileName: String {
      SHA256.hash(data: Data(rawValue.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    static func game(gameID: String, discNumber: Int, revision: Int) -> Identity? {
      let id = gameID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      guard !id.isEmpty, id != "<UNKNOWN>", !id.hasPrefix("ID-"),
            discNumber >= 0, revision >= 0 else { return nil }
      return Identity("game:" + Data(id.utf8).base64EncodedString() + ":\(discNumber):\(revision)")
    }

    /// Unknown/homebrew entries require a content identity supplied by the caller.
    /// Display names and filesystem paths must never alias unrelated homebrew.
    static func contentHash(_ sha256: String) -> Identity? {
      let normalized = sha256.lowercased()
      guard normalized.utf8.count == 64,
        normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
      return Identity("sha256:" + normalized)
    }
  }

  struct Draft: Equatable, Sendable {
    var title: String?
    var coverData: Data?
    var tags: [String]
    init(title: String? = nil, coverData: Data? = nil, tags: [String] = []) {
      self.title = title; self.coverData = coverData; self.tags = tags
    }
  }

  /// The gate must synchronously execute its operation once. The app injects the
  /// same short lock used by its sync scanner; no lock spans a network operation.
  typealias FileAccess = (_ operation: () throws -> Void) throws -> Void
  typealias Writer = (_ data: Data, _ url: URL) throws -> Void
  static let maxTitleLength = 200
  static let maxTagCount = 32
  static let maxTagLength = 40
  static let maxCoverBytes = 256 * 1024
  static let maxDocumentBytes = 1024 * 1024

  enum StoreError: LocalizedError {
    case invalidDocument, invalidRecord(String), invalidTransaction, identityMismatch
    case titleTooLong, tooManyTags, tagTooLong, coverTooLarge, documentTooLarge, invalidTimestamp

    var errorDescription: String? {
      switch self {
      case .invalidDocument: return "Library metadata is not a valid JSON object."
      case .invalidRecord(let field): return "Invalid library metadata field: \(field)."
      case .identityMismatch: return "Library metadata identity does not match its shard filename."
      case .invalidTransaction: return "Library metadata transaction did not execute."
      case .titleTooLong: return "Custom titles must be 200 characters or fewer."
      case .tooManyTags: return "A game can have at most 32 classification tags."
      case .tagTooLong: return "Classification tags must be 40 characters or fewer."
      case .coverTooLarge: return "Custom covers must be 256 KiB or smaller."
      case .documentTooLarge: return "Library metadata exceeds the 1 MiB per-game document limit."
      case .invalidTimestamp: return "Library metadata edit has an invalid timestamp."
      }
    }
  }

  private let directoryURL: URL
  private let fileAccess: FileAccess
  private let write: Writer
  private var documents: [Identity: [String: Any]] = [:]
  // Draft is a value type; Data/Array use copy-on-write. Repeated title, tag and
  // sort lookups share the decoded cover instead of allocating it per getter.
  private var projections: [Identity: Draft] = [:]
  private var stale = Set<Identity>()

  init(directoryURL: URL, withFileAccess: FileAccess? = nil,
       write: @escaping Writer = { try $0.write(to: $1, options: .atomic) }) throws {
    self.directoryURL = directoryURL
    let lock = NSRecursiveLock()
    self.fileAccess = withFileAccess ?? { operation in
      lock.lock(); defer { lock.unlock() }; try operation()
    }
    self.write = write
  }

  /// Lazily reads only this game's shard. Reload invalidates cached projections.
  /// A failed refresh throws once while retaining the previous valid cache.
  func draft(for identity: Identity) throws -> Draft {
    try withAccess {
      if let cached = projections[identity], !stale.contains(identity) { return cached }
      defer { stale.remove(identity) }
      let latest = try readDocument(for: identity)
      let projection = try Self.project(latest, for: identity)
      documents[identity] = latest
      projections[identity] = projection
      return projection
    }
  }

  /// Only fields changed against the sheet's captured baseline are edited. Reading
  /// latest disk bytes under the shared gate preserves concurrent unrelated edits.
  /// Blank title, nil cover and an empty tag list mean clear, with retained stamps.
  @discardableResult
  func commit(_ draft: Draft, baseline: Draft, for identity: Identity, at date: Date = Date()) throws -> Draft {
    let edited = try Self.normalized(draft)
    let baseline = try Self.normalized(baseline)
    let now = date.timeIntervalSinceReferenceDate
    guard now.isFinite else { throw StoreError.invalidTimestamp }
    return try withAccess {
      var candidate = try readDocument(for: identity)
      let fileURL = directoryURL.appendingPathComponent(identity.fileName)
      // Reject a malformed current record rather than replacing evidence of it.
      _ = try Self.project(candidate, for: identity)
      var changed = false
      func update(_ field: String, value: Any) throws {
        let key = identity.rawValue + ":" + field
        var record = candidate[key] as? [String: Any] ?? [:]
        let previous = Self.timestamp(record["updatedAt"])
        let stamp = max(now, previous.isFinite ? previous.nextUp : now)
        guard stamp.isFinite else { throw StoreError.invalidTimestamp }
        record["updatedAt"] = stamp
        record["value"] = value
        candidate[key] = record
        changed = true
      }
      if edited.title != baseline.title {
        try update("title", value: edited.title.map { $0 as Any } ?? NSNull())
      }
      if edited.coverData != baseline.coverData {
        try update("cover", value: edited.coverData.map { $0.base64EncodedString() as Any } ?? NSNull())
      }
      if edited.tags != baseline.tags {
        try update("tags", value: edited.tags.isEmpty ? NSNull() : edited.tags)
      }
      let projection = try Self.project(candidate, for: identity)
      if changed {
        let bytes = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
        guard bytes.count <= Self.maxDocumentBytes else { throw StoreError.documentTooLarge }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(bytes, fileURL)
      }
      // Publish only after durable success. Failure keeps the previous valid cache.
      documents[identity] = candidate
      projections[identity] = projection
      stale.remove(identity)
      return projection
    }
  }

  func reload() throws {
    try withAccess { stale.formUnion(documents.keys) }
  }

  private func withAccess<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    try fileAccess { result = Result { try body() } }
    guard let result else { throw StoreError.invalidTransaction }
    return try result.get()
  }

  private func readDocument(for identity: Identity) throws -> [String: Any] {
    let fileURL = directoryURL.appendingPathComponent(identity.fileName)
    let bytes: Data
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      if let size = attributes[.size] as? NSNumber, size.int64Value > Self.maxDocumentBytes {
        throw StoreError.documentTooLarge
      }
      bytes = try Data(contentsOf: fileURL)
    }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // Missing files are not a metadata clear: explicit clears are timestamped
      // null records. Retain this session's last durable fields after a purge.
      return documents[identity] ?? [:]
    }
    return try Self.decodeDocument(bytes, filename: identity.fileName)
  }

  /// Validate untrusted cloud bytes before the sync scanner promotes them. Unknown
  /// record/field keys remain opaque so a newer schema can round-trip safely.
  static func validateDocument(data: Data, filename: String? = nil) throws {
    _ = try decodeDocument(data, filename: filename)
  }

  static func isValidShardFilename(_ filename: String) -> Bool {
    guard filename.hasSuffix(".json") else { return false }
    let hash = filename.dropLast(5)
    return hash.utf8.count == 64 && hash.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func decodeDocument(_ bytes: Data, filename: String?) throws -> [String: Any] {
    guard bytes.count <= maxDocumentBytes else { throw StoreError.documentTooLarge }
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw StoreError.invalidDocument
    }
    var identities = Set<Identity>()
    for key in object.keys where key.hasPrefix("game:") || key.hasPrefix("sha256:") {
      for field in ["title", "cover", "tags"] where key.hasSuffix(":" + field) {
        identities.insert(Identity(String(key.dropLast(field.count + 1))))
      }
    }
    if let filename, !isValidShardFilename(filename) { throw StoreError.identityMismatch }
    for identity in identities {
      if let filename, identity.fileName != filename { throw StoreError.identityMismatch }
      _ = try project(object, for: identity)
    }
    return object
  }

  private static func project(_ object: [String: Any], for identity: Identity) throws -> Draft {
    func value(_ field: String) throws -> Any? {
      guard let raw = object[identity.rawValue + ":" + field] else { return nil }
      guard let record = raw as? [String: Any], let value = record["value"] else {
        throw StoreError.invalidRecord(field)
      }
      return value is NSNull ? nil : value
    }
    var result = Draft()
    if let title = try value("title") {
      guard let title = title as? String else { throw StoreError.invalidRecord("title") }
      result.title = title
    }
    if let cover = try value("cover") {
      // Bound the encoded form before allocating decoded bytes from remote JSON.
      guard let encoded = cover as? String, encoded.utf8.count <= ((maxCoverBytes + 2) / 3) * 4,
            let data = Data(base64Encoded: encoded) else { throw StoreError.invalidRecord("cover") }
      result.coverData = data
    }
    if let tags = try value("tags") {
      guard let tags = tags as? [String] else { throw StoreError.invalidRecord("tags") }
      result.tags = tags
    }
    return try normalized(result)
  }

  private static func normalized(_ draft: Draft) throws -> Draft {
    let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (title?.count ?? 0) <= maxTitleLength else { throw StoreError.titleTooLong }
    guard (draft.coverData?.count ?? 0) <= maxCoverBytes else { throw StoreError.coverTooLarge }
    var seen = Set<String>()
    var tags: [String] = []
    for raw in draft.tags {
      let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard tag.count <= maxTagLength else { throw StoreError.tagTooLong }
      if !tag.isEmpty, seen.insert(tag.lowercased()).inserted { tags.append(tag) }
    }
    guard tags.count <= maxTagCount else { throw StoreError.tooManyTags }
    return Draft(title: title?.isEmpty == false ? title : nil, coverData: draft.coverData, tags: tags)
  }

  /// Same timestamp forms understood by the pinned opaque-record merger. New
  /// writes use numeric reference-date seconds, preserving subsecond ordering.
  private static func timestamp(_ value: Any?) -> Double {
    if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
    if let string = value as? String {
      if let date = ISO8601DateFormatter().date(from: string) { return date.timeIntervalSinceReferenceDate }
      if let number = Double(string), number.isFinite { return number }
    }
    return -.infinity
  }
}
