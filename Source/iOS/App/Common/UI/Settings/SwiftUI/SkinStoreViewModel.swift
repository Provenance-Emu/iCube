// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation
import SkinCatalogKit
import SkinKitManager

/// One shelf of the store as shown: the section and its visible entries, in policy order, grouped into variant families
/// (a family of one for a lone skin).
struct SkinStoreShelf: Identifiable {
  let section: SkinStoreSection
  let families: [SkinFamily]

  var entries: [SkinCatalogEntry] { families.flatMap(\.members) }

  var id: String { section.id }

  /// Cards a collapsed shelf shows; the rest wait behind "Show all" so a big shelf (NES has about 200) does
  /// not push the ones after it off the screen.
  static let collapsedFamilyLimit = 6

  /// Whether the shelf has more families than it shows collapsed.
  var isCollapsible: Bool { families.count > Self.collapsedFamilyLimit }

  func visibleFamilies(expanded: Bool) -> [SkinFamily] {
    expanded ? families : Array(families.prefix(Self.collapsedFamilyLimit))
  }
}

/// What the store screen can show.
enum SkinStoreLoadState: Equatable {
  /// First load, nothing cached to paint yet.
  case loading
  /// A catalog is on screen (fresh, or a cached copy; see `SkinStoreViewModel.offlineMessage`).
  case loaded
  /// The download failed and there is no cached catalog.
  case failed(message: String)
}

/// Loads the skin catalog for `SkinStoreView` and groups it into shelves. A cached catalog paints
/// first so the screen is never blank while the feed downloads; when the download fails but a cache
/// exists, the cache stays on screen and `offlineMessage` says so.
@MainActor
final class SkinStoreViewModel: ObservableObject {
  @Published private(set) var shelves: [SkinStoreShelf] = []
  @Published private(set) var loadState: SkinStoreLoadState = .loading
  @Published private(set) var isRefreshing = false
  /// Set while a cached catalog stands in for a failed download.
  @Published private(set) var offlineMessage: String?

  let installer: SkinStoreInstaller
  private let service: SkinCatalogService
  private let library: SkinLibrary
  let policy: SkinStorePolicy
  private var hasLoaded = false

  init(service: SkinCatalogService = .shared, installer: SkinStoreInstaller = .shared, library: SkinLibrary = .shared,
       policy: SkinStorePolicy = .iCube) {
    self.service = service
    self.installer = installer
    self.library = library
    self.policy = policy
  }

  /// First appearance: cache first, then the network if the cache is stale.
  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    if let cached = await service.cachedCatalog() { apply(cached) }
    await load(forceRefresh: false)
  }

  /// Pull-to-refresh and the Refresh button: always asks the network.
  func refresh() async {
    await load(forceRefresh: true)
  }

  /// Drops "Installed" marks for skins the player has since deleted in the picker.
  func reconcileInstalled() {
    installer.reconcileInstalled(with: Set(library.skins.map(\.id)))
  }

  private func load(forceRefresh: Bool) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let result = try await service.load(forceRefresh: forceRefresh)
      apply(result.catalog)
      // The error itself, so the banner is in the player's language; the text is the fallback.
      offlineMessage = result.error.map(SkinStoreMessages.describe) ?? result.networkError
    } catch {
      if loadState == .loaded {
        offlineMessage = SkinStoreMessages.describe(error)
      } else {
        loadState = .failed(message: SkinStoreMessages.describe(error))
      }
    }
  }

  private func apply(_ catalog: SkinCatalog) {
    // Labels come from the whole catalog, so hiding entries never renames a variant; the installer records each
    // install's family (store-families.json) with the same labels.
    let index = catalog.familyIndex
    installer.familyIndex = index
    shelves = policy.familySections(for: catalog.skins, index: index).map { SkinStoreShelf(section: $0.section, families: $0.families) }
    loadState = .loaded
  }
}
#endif
