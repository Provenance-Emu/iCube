// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct DiscChangeCandidate: Equatable {
  var title: String
  var path: String
  var platform: Int
  var discNumber: Int = 0
  var isDemo: Bool = false
}

enum DiscChangePolicy {
  static func localPath(_ path: String) -> String? {
    if path.hasPrefix("/") { return path }
    guard let url = URL(string: path), url.isFileURL,
          url.host == nil || url.host == "" || url.host == "localhost",
          url.path.hasPrefix("/") else { return nil }
    return url.path
  }

  static func isAvailableFile(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
      && !directory.boolValue && FileManager.default.isReadableFile(atPath: path)
  }

  static func eligible(_ candidates: [DiscChangeCandidate], isWii: Bool,
                       available: (String) -> Bool = isAvailableFile) -> [DiscChangeCandidate] {
    var seen = Set<String>()
    return candidates.compactMap { candidate in
      guard !candidate.isDemo, candidate.platform == (isWii ? 2 : 0),
            let path = localPath(candidate.path), available(path), seen.insert(path).inserted else { return nil }
      var local = candidate
      local.path = path
      return local
    }
  }
}
