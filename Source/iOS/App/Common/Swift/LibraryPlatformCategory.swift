// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Library filter buckets for GameCube, Wii disc, and WiiWare (WAD).
enum LibraryPlatformCategory: String, CaseIterable, Identifiable, Codable {
  case all
  case gameCube
  case wii
  case wiiWare

  var id: String { rawValue }

  /// Segmented-control label (localized).
  var displayName: String {
    switch self {
    case .all: return L("All")
    case .gameCube: return L("GameCube")
    case .wii: return L("Wii")
    case .wiiWare: return L("WiiWare")
    }
  }

  var systemImage: String {
    switch self {
    case .all: return "square.grid.2x2"
    case .gameCube: return "gamecontroller"
    case .wii: return "wii.remote"
    case .wiiWare: return "app.badge"
    }
  }

  /// Categories shown in the filter bar (excludes `.all`).
  static var filterCases: [LibraryPlatformCategory] {
    [.gameCube, .wii, .wiiWare]
  }
}

/// DiscIO::Platform raw values from Source/Core/DiscIO/Enums.h.
private enum DiscIOPlatform: Int {
  case gameCubeDisc = 0
  case triforce = 1
  case wiiDisc = 2
  case wiiWAD = 3
  case elfOrDOL = 4
}

/// Persists per-file platform overrides set via multi-select.
enum LibraryPlatformOverrideStore {
  private static let key = "library_platform_overrides"

  static func load() -> [String: LibraryPlatformCategory] {
    guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return [:] }
    var result: [String: LibraryPlatformCategory] = [:]
    for (path, value) in raw {
      if let cat = LibraryPlatformCategory(rawValue: value), cat != .all {
        result[path] = cat
      }
    }
    return result
  }

  static func save(_ overrides: [String: LibraryPlatformCategory]) {
    var raw: [String: String] = [:]
    for (path, cat) in overrides where cat != .all {
      raw[path] = cat.rawValue
    }
    UserDefaults.standard.set(raw, forKey: key)
  }

  static func setOverride(_ category: LibraryPlatformCategory?, forFilePath path: String) {
    var map = load()
    if let category, category != .all {
      map[path] = category
    } else {
      map.removeValue(forKey: path)
    }
    save(map)
  }

  static func batchSetOverride(_ category: LibraryPlatformCategory?, forFilePaths paths: [String]) {
    var map = load()
    for path in paths {
      if let category, category != .all {
        map[path] = category
      } else {
        map.removeValue(forKey: path)
      }
    }
    save(map)
  }
}

enum LibraryPlatformMapper {
  /// Maps a game to its library filter category, honoring an optional user override.
  static func category(for item: TVGameItem, override: LibraryPlatformCategory? = nil) -> LibraryPlatformCategory {
    if let override, override != .all { return override }
    return detectedCategory(for: item)
  }

  /// Detected category from DiscIO platform and file extension.
  static func detectedCategory(for item: TVGameItem) -> LibraryPlatformCategory {
    if let platform = DiscIOPlatform(rawValue: Int(item.platform)) {
      switch platform {
      case .gameCubeDisc, .triforce, .elfOrDOL:
        return .gameCube
      case .wiiDisc:
        return .wii
      case .wiiWAD:
        return .wiiWare
      }
    }
    if fileExtension(for: item) == "wad" { return .wiiWare }
    return .gameCube
  }

  /// Categories present in the library (excluding `.all`). Used to decide tab visibility.
  static func availableCategories(in games: [TVGameItem], overrides: [String: LibraryPlatformCategory] = LibraryPlatformOverrideStore.load()) -> Set<LibraryPlatformCategory> {
    var set = Set<LibraryPlatformCategory>()
    for item in games {
      let override = overrides[item.filePath]
      set.insert(category(for: item, override: override))
    }
    return set
  }

  static func count(in games: [TVGameItem], for filter: LibraryPlatformCategory, overrides: [String: LibraryPlatformCategory] = LibraryPlatformOverrideStore.load()) -> Int {
    if filter == .all { return games.count }
    return games.filter { category(for: $0, override: overrides[$0.filePath]) == filter }.count
  }

  private static func fileExtension(for item: TVGameItem) -> String {
    if let url = URL(string: item.filePath), !url.pathExtension.isEmpty {
      return url.pathExtension.lowercased()
    }
    return (item.filePath as NSString).pathExtension.lowercased()
  }
}

/// Cover-template system used by GameGridItem placeholders.
enum LibraryGameSystem {
  case gameCube
  case wii

  static func from(item: TVGameItem) -> LibraryGameSystem {
    switch LibraryPlatformMapper.category(for: item, override: LibraryPlatformOverrideStore.load()[item.filePath]) {
    case .wii, .wiiWare:
      return .wii
    case .all, .gameCube:
      return .gameCube
    }
  }

  var templateImageName: String {
    switch self {
    #if APPSTORE
    case .gameCube: return "GCCoverTemplate-NoLogo"
    case .wii: return "WiiCoverTemplate-NoLogo"
    #else
    case .gameCube: return "GCCoverTemplate"
    case .wii: return "WiiCoverTemplate"
    #endif
    }
  }
}

// MARK: - Platform filter tab bar

/// Floating segmented filter above the search field; hidden when only one platform exists.
struct LibraryPlatformFilterBar: View {
  @Binding var selection: LibraryPlatformCategory
  let games: [TVGameItem]
  let overrides: [String: LibraryPlatformCategory]
  var onSelectionChange: (() -> Void)?

  private var visibleCategories: [LibraryPlatformCategory] {
    let available = LibraryPlatformMapper.availableCategories(in: games, overrides: overrides)
    return [.all] + LibraryPlatformCategory.filterCases.filter { available.contains($0) }
  }

  var body: some View {
    if LibraryPlatformMapper.availableCategories(in: games, overrides: overrides).count > 1 {
      HStack(spacing: 4) {
        ForEach(visibleCategories) { cat in
          filterButton(for: cat)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 5)
      .background { filterBarBackground }
      .clipShape(Capsule(style: .continuous))
      .padding(.horizontal, 16)
      .padding(.bottom, 4)
    }
  }

  @ViewBuilder
  private var filterBarBackground: some View {
    if #available(iOS 26.0, tvOS 26.0, *) {
      Capsule(style: .continuous)
        .fill(.clear)
        .glassEffect()
    } else {
      Capsule(style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          Capsule(style: .continuous)
            .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
  }

  private func compactTitle(for cat: LibraryPlatformCategory) -> String {
    switch cat {
    case .all: return L("All")
    case .gameCube: return L("GameCube")
    case .wii: return L("Wii")
    case .wiiWare: return L("WiiWare")
    }
  }

  @ViewBuilder
  private func filterButton(for cat: LibraryPlatformCategory) -> some View {
    let count = LibraryPlatformMapper.count(in: games, for: cat, overrides: overrides)
    let isSelected = selection == cat

    Button {
      selection = cat
      #if os(iOS)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      #endif
      onSelectionChange?()
    } label: {
      HStack(spacing: 3) {
        Text(compactTitle(for: cat))
          .font(.caption.weight(isSelected ? .semibold : .regular))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        if count > 0 {
          Text("\(count)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .fixedSize(horizontal: true, vertical: false)
      .background {
        if isSelected {
          Capsule(style: .continuous)
            .fill(Color.accentColor.opacity(0.18))
        }
      }
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(cat.displayName), \(count) \(L("games"))")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

// MARK: - Multi-select action bar

struct LibrarySelectionActionBar: View {
  let selectedCount: Int
  let onDelete: () -> Void
  let onFavorite: () -> Void
  let onUnfavorite: () -> Void
  let onPlatformOverride: (LibraryPlatformCategory?) -> Void
  let onControllerOverride: (TouchControllerOverride) -> Void
  let onSelectAll: () -> Void
  let onDeselectAll: () -> Void
  var onProperties: (() -> Void)?
  let onDone: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Text("\(selectedCount) \(L("selected"))")
          .font(.caption.weight(.semibold))
          .monospacedDigit()
        Spacer()
        Button(L("Done"), action: onDone)
          .font(.caption.weight(.semibold))
      }
      .padding(.horizontal, 4)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          actionButton(L("Delete"), systemImage: "trash", role: .destructive, action: onDelete)
          actionButton(L("Favorite"), systemImage: "star", action: onFavorite)
          actionButton(L("Unfavorite"), systemImage: "star.slash", action: onUnfavorite)
          if selectedCount == 1, let onProperties {
            actionButton(L("Properties"), systemImage: "info.circle", action: onProperties)
          }
          platformMenu
          controllerMenu
          actionButton(L("Select All"), systemImage: "checkmark.circle", action: onSelectAll)
          actionButton(L("Deselect All"), systemImage: "circle", action: onDeselectAll)
        }
        .padding(.horizontal, 4)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background { selectionBarBackground }
    .padding(.horizontal, 12)
    .padding(.bottom, 4)
  }

  @ViewBuilder
  private var selectionBarBackground: some View {
    if #available(iOS 26.0, tvOS 26.0, *) {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(.clear)
        .glassEffect()
    } else {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
  }

  private var platformMenu: some View {
    Menu {
      Button(L("Platform: Auto")) { onPlatformOverride(nil) }
      Divider()
      ForEach(LibraryPlatformCategory.filterCases) { cat in
        Button(cat.displayName) { onPlatformOverride(cat) }
      }
    } label: {
      actionLabel(L("Platform"), systemImage: "arrow.left.arrow.right")
    }
  }

  private var controllerMenu: some View {
    Menu {
      Button(L("Controller: Auto")) { onControllerOverride(.systemAuto) }
      Button(L("Force GameCube Pad")) { onControllerOverride(.forceGameCube) }
      Button(L("Force Wii Pad")) { onControllerOverride(.forceWii) }
    } label: {
      actionLabel(L("Controller"), systemImage: "gamecontroller")
    }
  }

  private func actionButton(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
    Button(role: role, action: action) {
      actionLabel(title, systemImage: systemImage)
    }
    #if os(tvOS)
    .buttonStyle(.bordered)
    #endif
  }

  private func actionLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.caption2.weight(.medium))
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
  }
}
