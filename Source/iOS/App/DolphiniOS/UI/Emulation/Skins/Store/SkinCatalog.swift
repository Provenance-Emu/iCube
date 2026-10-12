// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// The provenance-emu.com skin catalog (`/skins/catalog.json`, schema version 2).
///
/// Decodes the feed as it really is: nearly every field is nullable, and one malformed entry must
/// never cost the player the other 1,357. `skins` therefore decodes lossily: an entry that fails
/// is counted in `droppedEntryCount` and skipped. Decodable only: the service caches the server's
/// bytes verbatim, so there is no second, re-encoded schema to keep in step with the feed.
struct SkinCatalog: Decodable, Sendable {
  var version: Int?
  var lastUpdated: Date?
  var totalSkins: Int?
  var skins: [SkinCatalogEntry]
  /// Entries present in the feed that could not be decoded.
  var droppedEntryCount: Int

  init(version: Int? = nil, lastUpdated: Date? = nil, totalSkins: Int? = nil, skins: [SkinCatalogEntry], droppedEntryCount: Int = 0) {
    self.version = version
    self.lastUpdated = lastUpdated
    self.totalSkins = totalSkins
    self.skins = skins
    self.droppedEntryCount = droppedEntryCount
  }

  private enum CodingKeys: String, CodingKey {
    case version, lastUpdated, totalSkins, skins
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try? container.decodeIfPresent(Int.self, forKey: .version)
    lastUpdated = SkinCatalogDates.parse(try? container.decodeIfPresent(String.self, forKey: .lastUpdated))
    totalSkins = try? container.decodeIfPresent(Int.self, forKey: .totalSkins)
    let lossy = try container.decodeIfPresent([LossyEntry].self, forKey: .skins) ?? []
    skins = lossy.compactMap(\.entry)
    droppedEntryCount = lossy.count - skins.count
  }

  /// Decodes feed bytes. Shared by the network and disk paths so both apply the same lossy rules.
  static func decode(_ data: Data) throws -> SkinCatalog {
    do {
      return try JSONDecoder().decode(SkinCatalog.self, from: data)
    } catch {
      throw SkinCatalogError.decoding(error.localizedDescription)
    }
  }

  /// Swallows one entry's decode failure so the array as a whole survives.
  private struct LossyEntry: Decodable {
    let entry: SkinCatalogEntry?

    init(from decoder: Decoder) throws {
      entry = try? SkinCatalogEntry(from: decoder)
    }
  }
}

/// Date parsing for the feed, which mixes full ISO 8601 (`2026-10-04T05:11:24Z`) at the root and
/// in `submittedAt` with bare dates (`2025-09-23`) in per-skin `lastUpdated`. Anything unparseable
/// becomes nil instead of failing the entry.
enum SkinCatalogDates {
  static func parse(_ string: String?) -> Date? {
    guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if let full = try? Date.ISO8601FormatStyle().parse(raw) { return full }
    if let fractional = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) { return fractional }
    return try? Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().parse(raw)
  }
}

/// Why the catalog could not be produced (the network and every cache failed).
enum SkinCatalogError: LocalizedError {
  case httpStatus(Int)
  case network(String)
  case decoding(String)

  var errorDescription: String? {
    switch self {
    case .httpStatus(let code): return String(format: L("The skin catalog server answered with HTTP %d."), code)
    case .network(let message): return String(format: L("The skin catalog could not be downloaded: %@"), message)
    case .decoding(let message): return String(format: L("The skin catalog could not be read: %@"), message)
    }
  }
}
#endif
