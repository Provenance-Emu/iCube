// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// GameBanana's v11 API is a PHP backend: ids are Ints almost everywhere and Strings in the
// profile credits, empty maps arrive as `[]`, and any field may be missing. Every model here
// therefore decodes by hand and treats anything absent or oddly shaped as "not provided".

private extension KeyedDecodingContainer {
  func flexibleInt(_ key: Key) -> Int? {
    if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
    if let text = try? decodeIfPresent(String.self, forKey: key) { return Int(text) }
    return nil
  }

  func text(_ key: Key) -> String? {
    try? decodeIfPresent(String.self, forKey: key)
  }

  func url(_ key: Key) -> URL? {
    guard let text = text(key), !text.isEmpty else { return nil }
    return URL(string: text)
  }

  func flag(_ key: Key) -> Bool {
    (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
  }

  func list<Element: Decodable>(_ key: Key) -> [Element] {
    (try? decodeIfPresent([Element].self, forKey: key)) ?? []
  }

  func object<Value: Decodable>(_ key: Key) -> Value? {
    try? decodeIfPresent(Value.self, forKey: key)
  }
}

private struct StringKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }

  init(_ stringValue: String) { self.stringValue = stringValue }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

/// One page of a GameBanana listing.
struct GameBananaPage<Record: Decodable>: Decodable {
  let records: [Record]
  let recordCount: Int
  /// False when more pages follow. Search pages hold fewer records than `perPage` while still
  /// incomplete, so this flag, not the record count, decides whether to keep paging.
  let isComplete: Bool

  init(records: [Record], recordCount: Int, isComplete: Bool) {
    self.records = records
    self.recordCount = recordCount
    self.isComplete = isComplete
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: StringKey.self)
    records = (try? container.decodeIfPresent([Record].self, forKey: StringKey("_aRecords"))) ?? []
    let metadata = try? container.nestedContainer(keyedBy: StringKey.self, forKey: StringKey("_aMetadata"))
    recordCount = metadata?.flexibleInt(StringKey("_nRecordCount")) ?? records.count
    isComplete = metadata.map { $0.flag(StringKey("_bIsComplete")) } ?? true
  }
}

struct GameBananaGame: Decodable, Hashable {
  let id: Int
  let name: String
  let profileURL: URL?
  let iconURL: URL?

  init(id: Int, name: String, profileURL: URL? = nil, iconURL: URL? = nil) {
    self.id = id
    self.name = name
    self.profileURL = profileURL
    self.iconURL = iconURL
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    guard let id = c.flexibleInt(StringKey("_idRow")) else {
      throw DecodingError.keyNotFound(StringKey("_idRow"), .init(codingPath: c.codingPath, debugDescription: "game id"))
    }
    self.id = id
    name = c.text(StringKey("_sName")) ?? ""
    profileURL = c.url(StringKey("_sProfileUrl"))
    iconURL = c.url(StringKey("_sIconUrl"))
  }
}

struct GameBananaMember: Decodable, Hashable {
  let name: String
  let profileURL: URL?
  let avatarURL: URL?
  /// Credit role ("Primary Mod Creator"); only present in a profile's credit groups.
  let role: String?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    name = c.text(StringKey("_sName")) ?? ""
    profileURL = c.url(StringKey("_sProfileUrl"))
    avatarURL = c.url(StringKey("_sAvatarUrl"))
    role = c.text(StringKey("_sRole"))
  }
}

struct GameBananaImage: Decodable, Hashable {
  let baseURL: String
  let file: String
  /// Width-keyed thumbnails the server made for this image. Not every image has every size.
  let thumbnails: [Int: String]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    baseURL = c.text(StringKey("_sBaseUrl")) ?? ""
    file = c.text(StringKey("_sFile")) ?? ""
    var found: [Int: String] = [:]
    for width in Self.thumbnailWidths {
      if let name = c.text(StringKey("_sFile\(width)")), !name.isEmpty { found[width] = name }
    }
    thumbnails = found
  }

  private static let thumbnailWidths = [100, 220, 530, 800]

  /// The smallest thumbnail at least `width` points wide, else the largest, else the original.
  func url(minimumWidth width: Int) -> URL? {
    let name = thumbnails.keys.sorted().first { $0 >= width }.flatMap { thumbnails[$0] }
      ?? thumbnails.keys.max().flatMap { thumbnails[$0] }
      ?? file
    guard !baseURL.isEmpty, !name.isEmpty else { return nil }
    return URL(string: baseURL)?.appendingPathComponent(name)
  }
}

struct GameBananaModSummary: Decodable, Hashable, Identifiable {
  let id: Int
  let name: String
  let profileURL: URL?
  let dateAdded: Date?
  let dateUpdated: Date?
  let hasFiles: Bool
  let isObsolete: Bool
  let version: String
  let likeCount: Int?
  let viewCount: Int?
  let submitter: GameBananaMember?
  let game: GameBananaGame?
  let categoryName: String?
  let subcategoryName: String?
  let images: [GameBananaImage]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    guard let id = c.flexibleInt(StringKey("_idRow")) else {
      throw DecodingError.keyNotFound(StringKey("_idRow"), .init(codingPath: c.codingPath, debugDescription: "mod id"))
    }
    self.id = id
    name = c.text(StringKey("_sName")) ?? ""
    profileURL = c.url(StringKey("_sProfileUrl"))
    dateAdded = c.flexibleInt(StringKey("_tsDateAdded")).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    dateUpdated = (c.flexibleInt(StringKey("_tsDateUpdated")) ?? c.flexibleInt(StringKey("_tsDateModified")))
      .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    hasFiles = c.flag(StringKey("_bHasFiles"))
    isObsolete = c.flag(StringKey("_bIsObsolete"))
    version = c.text(StringKey("_sVersion")) ?? ""
    likeCount = c.flexibleInt(StringKey("_nLikeCount"))
    viewCount = c.flexibleInt(StringKey("_nViewCount"))
    submitter = c.object(StringKey("_aSubmitter"))
    game = c.object(StringKey("_aGame"))
    let root: GameBananaNamed? = c.object(StringKey("_aRootCategory")) ?? c.object(StringKey("_aCategory"))
    categoryName = root?.name
    subcategoryName = (c.object(StringKey("_aSubCategory")) as GameBananaNamed?)?.name
    let media: GameBananaMedia? = c.object(StringKey("_aPreviewMedia"))
    images = media?.images ?? []
  }
}

private struct GameBananaNamed: Decodable {
  let name: String?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    name = c.text(StringKey("_sName"))
  }
}

private struct GameBananaMedia: Decodable {
  let images: [GameBananaImage]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    images = c.list(StringKey("_aImages"))
  }
}

struct GameBananaCategory: Decodable, Hashable, Identifiable {
  let id: Int
  let name: String
  let itemCount: Int

  init(id: Int, name: String, itemCount: Int) {
    self.id = id
    self.name = name
    self.itemCount = itemCount
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    guard let id = c.flexibleInt(StringKey("_idRow")) else {
      throw DecodingError.keyNotFound(StringKey("_idRow"), .init(codingPath: c.codingPath, debugDescription: "category id"))
    }
    self.id = id
    name = c.text(StringKey("_sName")) ?? ""
    itemCount = c.flexibleInt(StringKey("_nItemCount")) ?? 0
  }
}

struct GameBananaFile: Decodable, Hashable, Identifiable {
  let id: Int
  /// The uploaded file name. Its extension picks the archive extractor, so it is kept verbatim.
  let fileName: String
  let size: Int64
  let downloadURL: URL?
  let md5: String?
  let downloadCount: Int
  /// "clean" when GameBanana's virus scan passed; anything else is shown to the user as-is.
  let virusScanResult: String?
  let analysisSummary: String?
  /// Analysis findings keyed by kind (`contains_exe`), each with the offending paths.
  let analysisWarnings: [String: [String]]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    guard let id = c.flexibleInt(StringKey("_idRow")) else {
      throw DecodingError.keyNotFound(StringKey("_idRow"), .init(codingPath: c.codingPath, debugDescription: "file id"))
    }
    self.id = id
    fileName = c.text(StringKey("_sFile")) ?? ""
    size = Int64(c.flexibleInt(StringKey("_nFilesize")) ?? 0)
    downloadURL = c.url(StringKey("_sDownloadUrl"))
    md5 = c.text(StringKey("_sMd5Checksum")).flatMap { $0.isEmpty ? nil : $0.lowercased() }
    downloadCount = c.flexibleInt(StringKey("_nDownloadCount")) ?? 0
    virusScanResult = c.text(StringKey("_sAvResult"))
    analysisSummary = c.text(StringKey("_sAnalysisResultVerbose"))
    // An empty warnings map is encoded as `[]`, which fails to decode as a dictionary.
    analysisWarnings = c.object(StringKey("_aAnalysisWarnings")) ?? [:]
  }
}

struct GameBananaLicenseChecklist: Decodable, Hashable {
  let allowed: [String]
  let askFirst: [String]
  let forbidden: [String]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    allowed = c.list(StringKey("yes"))
    askFirst = c.list(StringKey("ask"))
    forbidden = c.list(StringKey("no"))
  }

  static let empty = GameBananaLicenseChecklist(allowed: [], askFirst: [], forbidden: [])

  private init(allowed: [String], askFirst: [String], forbidden: [String]) {
    self.allowed = allowed
    self.askFirst = askFirst
    self.forbidden = forbidden
  }
}

struct GameBananaCreditGroup: Decodable, Hashable {
  let name: String
  let members: [GameBananaMember]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    name = c.text(StringKey("_sGroupName")) ?? ""
    members = c.list(StringKey("_aAuthors"))
  }
}

struct GameBananaModDetail: Decodable, Hashable {
  let summary: GameBananaModSummary
  /// The long description as the HTML GameBanana stores it. Run it through `HTMLPlainText`.
  let descriptionHTML: String
  let licenseHTML: String
  let licenseChecklist: GameBananaLicenseChecklist
  let files: [GameBananaFile]
  let credits: [GameBananaCreditGroup]
  let downloadCount: Int

  init(from decoder: Decoder) throws {
    summary = try GameBananaModSummary(from: decoder)
    let c = try decoder.container(keyedBy: StringKey.self)
    descriptionHTML = c.text(StringKey("_sText")) ?? ""
    licenseHTML = c.text(StringKey("_sLicense")) ?? ""
    licenseChecklist = c.object(StringKey("_aLicenseChecklist")) ?? .empty
    files = c.list(StringKey("_aFiles"))
    credits = c.list(StringKey("_aCredits"))
    downloadCount = c.flexibleInt(StringKey("_nDownloadCount")) ?? 0
  }
}

/// Failure body GameBanana returns with HTTP 200 for a rejected query.
struct GameBananaAPIError: Decodable, Error, LocalizedError {
  let code: String

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: StringKey.self)
    guard let code = c.text(StringKey("_sErrorCode")) else {
      throw DecodingError.keyNotFound(StringKey("_sErrorCode"), .init(codingPath: c.codingPath, debugDescription: "error code"))
    }
    self.code = code
  }

  var errorDescription: String? { String(format: L("GameBanana rejected the request (%@)."), code) }
}
