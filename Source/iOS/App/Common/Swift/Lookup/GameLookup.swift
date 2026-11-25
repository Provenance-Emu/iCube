// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import os
import PVLookup
import PVLookupTypes
import PVSystems

extension DiscIOPlatform {
  /// The shared `SystemIdentifier` (PVSystems) for a disc's platform. Triforce boards run GameCube
  /// hardware and WiiWare is a Wii title; homebrew executables belong to neither.
  var systemIdentifier: SystemIdentifier? {
    switch self {
    case .gameCubeDisc, .triforce: return .GameCube
    case .wiiDisc, .wiiWAD: return .Wii
    case .elfOrDOL: return nil
    }
  }
}

/// What PVLookup is asked for one library game: the ID printed on the disc and its system.
struct GameLookupQuery: Hashable, Sendable {
  /// Disc IDs are six characters (`GALE01`), channel and WiiWare IDs four (`HAAA`).
  static let serialLengths: Set<Int> = [4, 6]

  let serial: String
  let system: SystemIdentifier

  /// nil when the game has no ID a database could know: homebrew, or the `<unknown>` placeholder
  /// `TVGameItem` reports for a file without one.
  init?(gameID: String, platform: Int) {
    guard let system = DiscIOPlatform(rawValue: platform)?.systemIdentifier else { return nil }
    let serial = gameID.uppercased()
    guard Self.serialLengths.contains(serial.count),
          serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
    self.serial = serial
    self.system = system
  }
}

/// The facts about a game that the disc itself does not carry.
struct GameLookupInfo: Equatable, Sendable {
  var developer: String?
  var publisher: String?
  /// Ready to show: "December 2001", or the year alone.
  var released: String?
  var genres: String?

  var isEmpty: Bool { developer == nil && publisher == nil && released == nil && genres == nil }

  init(metadata: ROMMetadata, locale: Locale = .current) {
    developer = Self.cleaned(metadata.developer)
    publisher = Self.cleaned(metadata.publisher)
    released = Self.releasedText(metadata.releaseDate, locale: locale)
    genres = Self.cleaned(metadata.genres?.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces).capitalized
    }.filter { !$0.isEmpty }.joined(separator: ", "))
  }

  private static func cleaned(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  /// libretrodb gives `2001-12` or `2001`; OpenVGDB, when an app ships it, `2001/12/2`.
  static func releasedText(_ raw: String?, locale: Locale = .current) -> String? {
    guard let raw = cleaned(raw) else { return nil }
    let parts = raw.split(whereSeparator: { $0 == "-" || $0 == "/" }).map { Int($0) }
    guard let first = parts.first, let year = first, (1970 ... 2100).contains(year) else { return nil }
    guard parts.count > 1, let month = parts[1], (1 ... 12).contains(month) else { return String(year) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return String(year) }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
    return formatter.string(from: date)
  }
}

/// Looks library games up in the shared databases (PVLookup) by the ID on the disc.
///
/// iCube's own sources stay the first choice for what they cover: the disc banner and Dolphin's
/// `wiitdb` for names, GameTDB for covers, the game INIs and rc24 for cheats. This adds what none
/// of them has (developer, publisher, release date) and a second place to find a cover.
struct GameLookup: Sendable {
  typealias Search = @Sendable (GameLookupQuery) async throws -> ROMMetadata?
  typealias Artwork = @Sendable (ROMMetadata) async throws -> [URL]

  static let live = GameLookup(
    search: { try await PVLookup.shared.searchROM(bySerial: $0.serial, systemID: $0.system) },
    artwork: { try await PVLookup.shared.getArtworkURLs(forRom: $0) ?? [] }
  )

  private static let log = ICubeLog.logger("GameLookup")

  let search: Search
  let artwork: Artwork

  /// The database's record for the game, or nil when it has none or the lookup failed.
  func metadata(gameID: String, platform: Int) async -> ROMMetadata? {
    guard let query = GameLookupQuery(gameID: gameID, platform: platform) else { return nil }
    do {
      return try await search(query)
    } catch {
      Self.log.error("Lookup of \(query.serial, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  func info(gameID: String, platform: Int) async -> GameLookupInfo? {
    guard let metadata = await metadata(gameID: gameID, platform: platform) else { return nil }
    let info = GameLookupInfo(metadata: metadata)
    return info.isEmpty ? nil : info
  }

  /// Every artwork URL the databases know for the game, in the order they answered.
  func artworkURLs(for metadata: ROMMetadata) async -> [URL] {
    do {
      return try await artwork(metadata)
    } catch {
      Self.log.error("Artwork lookup for \(metadata.serial ?? metadata.gameTitle, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }
}
