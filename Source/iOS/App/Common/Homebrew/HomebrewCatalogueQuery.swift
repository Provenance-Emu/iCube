// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum HomebrewSort: String, CaseIterable, Identifiable {
  case name
  case mostDownloaded
  case recentlyUpdated

  var id: String { rawValue }

  var title: String {
    switch self {
    case .name: return L("Name")
    case .mostDownloaded: return L("Most Downloaded")
    case .recentlyUpdated: return L("Recently Updated")
    }
  }
}

/// Search, sort and grouping over a loaded catalogue. The catalogue is small (under a hundred
/// titles), so all of it happens on the device and the service is never asked twice.
enum HomebrewCatalogueQuery {
  struct Section: Identifiable {
    let category: HomebrewCategory
    let count: Int
    let preview: [HomebrewTitle]

    var id: String { category.id }
  }

  /// One section per category, each previewing its most downloaded titles.
  static func sections(_ catalogue: HomebrewCatalogue, previewCount: Int) -> [Section] {
    catalogue.categories.map { category in
      let all = titles(in: category, of: catalogue, sort: .mostDownloaded)
      return Section(category: category, count: all.count, preview: Array(all.prefix(max(0, previewCount))))
    }
  }

  static func titles(in category: HomebrewCategory, of catalogue: HomebrewCatalogue, sort: HomebrewSort) -> [HomebrewTitle] {
    sorted(catalogue.titles.filter { $0.category == category }, by: sort)
  }

  /// Titles whose name, author or short description contains every word of `query`, by name.
  static func search(_ query: String, in catalogue: HomebrewCatalogue) -> [HomebrewTitle] {
    let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    guard !words.isEmpty else { return [] }
    let matches = catalogue.titles.filter { title in
      let haystack = fold([title.name, title.author, title.summary].joined(separator: "\n"))
      return words.allSatisfy(haystack.contains)
    }
    return sorted(matches, by: .name)
  }

  private static func sorted(_ titles: [HomebrewTitle], by sort: HomebrewSort) -> [HomebrewTitle] {
    titles.sorted { a, b in
      switch sort {
      case .name:
        break
      case .mostDownloaded:
        if a.downloads != b.downloads { return a.downloads > b.downloads }
      case .recentlyUpdated:
        let (left, right) = (a.updatedAt ?? .distantPast, b.updatedAt ?? .distantPast)
        if left != right { return left > right }
      }
      let order = a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive])
      return order == .orderedSame ? a.slug < b.slug : order == .orderedAscending
    }
  }

  private static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}
