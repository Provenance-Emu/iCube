// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Names that come from the catalogue and end up in a path or a URL.
enum HomebrewName {
  /// A single plain path component: no separators, not hidden, not `.` or `..`.
  static func isSafe(_ name: String) -> Bool {
    guard !name.isEmpty, !name.hasPrefix("."), name == (name as NSString).lastPathComponent else { return false }
    return !name.contains { $0 == "/" || $0 == "\\" || $0 == "\0" }
  }
}

struct HomebrewCategory: Hashable, Identifiable, Sendable {
  let name: String
  let displayName: String
  let sortOrder: Int

  var id: String { name }
}

struct HomebrewVersion: Hashable, Sendable {
  let version: String
  /// Dolphin Depot's own comparison key for a version; two versions are the same when it matches.
  let versionSlug: String
  let size: Int64
  let fileName: String
  let releaseDate: Date?
  let changelog: String?
}

struct HomebrewLicence: Hashable, Sendable {
  let spdx: String?
  let url: URL?
  let notes: String?
}

struct HomebrewLink: Hashable, Sendable {
  let label: String
  let url: URL
}

/// One title of the Dolphin Depot catalogue.
struct HomebrewTitle: Hashable, Identifiable, Sendable {
  let slug: String
  let name: String
  let author: String
  let summary: String
  let details: String
  let category: HomebrewCategory?
  let bannerPath: String?
  let heroPath: String?
  let screenshotPaths: [String]
  let downloads: Int
  let likes: Int
  let updatedAt: Date?
  /// The newest published package, or nil when the title has none iCube can fetch.
  let latest: HomebrewVersion?
  let licence: HomebrewLicence?
  let links: [HomebrewLink]
  let hardware: [String]
  let platforms: [String]

  var id: String { slug }

  /// The image used as the library cover. The banner is a 96x32 GameCube banner, so it comes last.
  var coverPath: String? { screenshotPaths.first ?? heroPath ?? bannerPath }

  /// Emulators and media players look for their files on an SD card, which iCube does not provide.
  var needsSDCard: Bool {
    guard let name = category?.name else { return false }
    return Self.sdCardCategories.contains(name)
  }

  private static let sdCardCategories: Set<String> = ["emulators", "media"]
}

struct HomebrewCatalogue: Sendable {
  let titles: [HomebrewTitle]

  /// The categories that have titles, in the catalogue's own order.
  var categories: [HomebrewCategory] {
    Set(titles.compactMap(\.category)).sorted {
      ($0.sortOrder, $0.displayName) < ($1.sortOrder, $1.displayName)
    }
  }

  /// Decodes the `/apps` response. A row that cannot be read is skipped, never the whole list.
  static func decode(_ data: Data) throws -> HomebrewCatalogue {
    let rows = try JSONDecoder().decode([Lossy<HomebrewTitle>].self, from: data)
    return HomebrewCatalogue(titles: rows.compactMap(\.value))
  }
}

/// Wraps an array element so its decoding error stays its own.
private struct Lossy<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}

extension HomebrewTitle: Decodable {
  private enum CodingKeys: String, CodingKey {
    case slug, name, author
    case summary = "description_short"
    case details = "description_long"
    case category = "categories"
    case bannerPath = "banner_path"
    case heroPath = "hero_path"
    case screenshotPaths = "screenshot_paths"
    case downloads = "downloads_count"
    case likes = "likes_count"
    case updatedAt = "updated_at"
    case versions = "app_versions"
    case licence = "app_licenses"
    case links = "app_external_resources"
    case hardware = "app_peripherals"
    case platforms = "app_platforms"
  }

  private struct Named: Decodable {
    let displayName: String?
    let name: String?

    private enum CodingKeys: String, CodingKey {
      case displayName = "display_name"
      case name
    }

    var label: String? { [displayName, name].compactMap { $0 }.first { !$0.isEmpty } }
  }

  private struct Peripheral: Decodable { let peripherals: Named? }
  private struct Platform: Decodable { let platforms: Named? }

  private struct Link: Decodable {
    let label: String?
    let url: String?
    let sortOrder: Int?

    private enum CodingKeys: String, CodingKey {
      case label, url
      case sortOrder = "sort_order"
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let slug = try container.decode(String.self, forKey: .slug)
    let name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
    guard HomebrewName.isSafe(slug), !name.isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .slug, in: container, debugDescription: "unusable title")
    }
    func optional<Value: Decodable>(_ type: Value.Type, _ key: CodingKeys) -> Value? {
      try? container.decodeIfPresent(Value.self, forKey: key)
    }
    self.slug = slug
    self.name = name
    author = optional(String.self, .author) ?? ""
    summary = optional(String.self, .summary) ?? ""
    details = optional(String.self, .details) ?? ""
    category = optional(HomebrewCategory.self, .category)
    bannerPath = optional(String.self, .bannerPath)
    heroPath = optional(String.self, .heroPath)
    screenshotPaths = optional([String].self, .screenshotPaths) ?? []
    downloads = optional(Int.self, .downloads) ?? 0
    likes = optional(Int.self, .likes) ?? 0
    updatedAt = optional(String.self, .updatedAt).flatMap(HomebrewDate.parse)
    latest = (optional([Lossy<HomebrewVersion>].self, .versions) ?? []).compactMap(\.value).first
    licence = optional(HomebrewLicence.self, .licence)
    links = (optional([Lossy<Link>].self, .links) ?? []).compactMap(\.value)
      .sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
      .compactMap { link in
        guard let url = link.url.flatMap(URL.init(string:)), url.scheme == "https" || url.scheme == "http" else { return nil }
        let label = link.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HomebrewLink(label: label.isEmpty ? (url.host ?? url.absoluteString) : label, url: url)
      }
    hardware = (optional([Lossy<Peripheral>].self, .hardware) ?? []).compactMap { $0.value?.peripherals?.label }
    platforms = (optional([Lossy<Platform>].self, .platforms) ?? []).compactMap { $0.value?.platforms?.label }
  }
}

extension HomebrewCategory: Decodable {
  private enum CodingKeys: String, CodingKey {
    case name
    case displayName = "display_name"
    case sortOrder = "sort_order"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? name.capitalized
    sortOrder = (try? container.decodeIfPresent(Int.self, forKey: .sortOrder)) ?? Int.max
  }
}

extension HomebrewVersion: Decodable {
  private enum CodingKeys: String, CodingKey {
    case version, size, changelog
    case versionSlug = "version_slug"
    case releaseDate = "release_date"
    case assets = "app_version_assets"
  }

  private struct Asset: Decodable {
    let fileName: String

    private enum CodingKeys: String, CodingKey {
      case fileName = "file_name"
    }
  }

  /// A version is usable only with a package iCube can fetch and open: a plainly named zip.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(String.self, forKey: .version)
    versionSlug = try container.decode(String.self, forKey: .versionSlug)
    size = try container.decode(Int64.self, forKey: .size)
    let assets = try container.decode([Lossy<Asset>].self, forKey: .assets).compactMap(\.value)
    guard size > 0, let asset = assets.first(where: {
      HomebrewName.isSafe($0.fileName) && $0.fileName.lowercased().hasSuffix(".zip")
    }) else {
      throw DecodingError.dataCorruptedError(forKey: .assets, in: container, debugDescription: "no usable package")
    }
    fileName = asset.fileName
    releaseDate = (try? container.decodeIfPresent(String.self, forKey: .releaseDate)).flatMap(HomebrewDate.parse)
    changelog = try? container.decodeIfPresent(String.self, forKey: .changelog)
  }
}

extension HomebrewLicence: Decodable {
  private enum CodingKeys: String, CodingKey {
    case spdx, url, notes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func text(_ key: CodingKeys) -> String? {
      let value = (try? container.decodeIfPresent(String.self, forKey: key))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return value?.isEmpty == false ? value : nil
    }
    spdx = text(.spdx)
    url = text(.url).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
    notes = text(.notes)
  }
}

/// The API's timestamps: ISO 8601, with or without fractional seconds.
enum HomebrewDate {
  static func parse(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}
