// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Reads and writes `SaveStateMetadata` JSON sidecars that live next to each
/// Dolphin state file.
///
/// The sidecar name APPENDS `.json` to the full state filename
/// (`GALE01.s01` -> `GALE01.s01.json`) so it stays per-slot. Note: using
/// `deletingPathExtension()` would treat `.s01` as the extension and collapse
/// every slot onto `GALE01.json`, so we deliberately append instead.
public enum SaveStateMetadataStore {
  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  /// `GALE01.s01` -> `GALE01.s01.json`
  public static func sidecarURL(forStateFile stateURL: URL) -> URL {
    return stateURL.appendingPathExtension("json")
  }

  @discardableResult
  public static func write(_ metadata: SaveStateMetadata, forStateFile stateURL: URL) -> Bool {
    do {
      let data = try encoder.encode(metadata)
      try data.write(to: sidecarURL(forStateFile: stateURL), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  public static func read(forStateFile stateURL: URL) -> SaveStateMetadata? {
    let url = sidecarURL(forStateFile: stateURL)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? decoder.decode(SaveStateMetadata.self, from: data)
  }

  /// Update just the user-facing title, preserving everything else.
  /// Returns false if no sidecar exists yet.
  @discardableResult
  public static func rename(forStateFile stateURL: URL, to title: String) -> Bool {
    guard var meta = read(forStateFile: stateURL) else { return false }
    meta.title = title
    return write(meta, forStateFile: stateURL)
  }

  public static func delete(forStateFile stateURL: URL) {
    try? FileManager.default.removeItem(at: sidecarURL(forStateFile: stateURL))
  }
}
