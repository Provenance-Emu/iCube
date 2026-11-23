// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

enum HomebrewBrowserRoute: Hashable {
  case category(HomebrewCategory)
  case title(HomebrewTitle)
}

/// Holds the catalogue and the installed index for the browser's screens.
@MainActor
final class HomebrewBrowserModel: ObservableObject {
  @Published private(set) var catalogue: HomebrewCatalogue?
  @Published private(set) var isLoading = false
  /// True when the list on screen is an earlier one because the site could not be reached.
  @Published private(set) var isShowingSavedList = false
  /// Set only when there is no list to show at all.
  @Published private(set) var errorMessage: String?
  @Published private(set) var index = HomebrewInstalledIndex()
  @Published var searchText = ""

  /// The Homebrew folder, or nil when it cannot be reached; nothing can be installed then.
  let root: URL?
  private let client: DolphinDepotClient
  private var didSweep = false

  init(client: DolphinDepotClient = .shared, root: URL?) {
    self.client = client
    self.root = root
  }

  /// The saved list straight away, then the current one.
  func load() async {
    sweepOrphansOnce()
    if catalogue == nil { catalogue = await client.saved() }
    await fetch(forceRefresh: false)
  }

  func refresh() async {
    await fetch(forceRefresh: true)
  }

  /// Re-reads the installed index, after an install or when a screen comes back.
  func reloadIndex() {
    guard let root else { return }
    index = HomebrewInstalledIndex.load(root: root)
  }

  func state(of title: HomebrewTitle) -> HomebrewInstalledIndex.State {
    guard let root else { return .notInstalled }
    return index.state(of: title, root: root)
  }

  private func fetch(forceRefresh: Bool) async {
    isLoading = true
    defer { isLoading = false }
    do {
      let loaded = try await client.catalogue(forceRefresh: forceRefresh)
      catalogue = loaded.catalogue
      isShowingSavedList = loaded.isSaved
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      if catalogue == nil {
        errorMessage = error.localizedDescription
      } else {
        isShowingSavedList = true
      }
    }
  }

  /// A game deleted from the library leaves its folder and index entry behind; clear them out.
  private func sweepOrphansOnce() {
    guard let root else { return }
    var current = HomebrewInstalledIndex.load(root: root)
    if !didSweep {
      didSweep = true
      if !current.removeOrphans(root: root).isEmpty { try? current.save(root: root) }
    }
    index = current
  }
}

/// The homebrew browser: Dolphin Depot's catalogue by category, with search.
///
/// Built from plain `List` rows and `NavigationLink`s, as the mod browser is: `Menu` and `Picker`
/// have no usable presentation on tvOS, and a list row is already one focus target there.
struct HomebrewBrowserRoot: View {
  @StateObject private var model = HomebrewBrowserModel(root: try? HomebrewPaths.root())
  @Environment(\.dismiss) private var dismiss
  @State private var path: [HomebrewBrowserRoute] = []

  var body: some View {
    NavigationStack(path: $path) {
      HomebrewRootList(model: model)
        .navigationTitle(L("Homebrew"))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } }
        }
        .navigationDestination(for: HomebrewBrowserRoute.self) { route in
          switch route {
          case .category(let category):
            HomebrewCategoryView(category: category, model: model)
          case .title(let title):
            HomebrewDetailView(title: title, browser: model)
          }
        }
    }
    .task {
      ModDownloadManager.shared.sweepStaleDownloads()
      await model.load()
    }
  }
}

/// Every attribution line the screens share.
struct HomebrewAttribution: View {
  var body: some View {
    Text(HomebrewBrowser.attribution)
      .icubeText(.detail)
      .foregroundColor(.secondary)
  }
}

private struct HomebrewRootList: View {
  @ObservedObject var model: HomebrewBrowserModel

  private var query: String { model.searchText.trimmingCharacters(in: .whitespaces) }

  var body: some View {
    List {
      if let catalogue = model.catalogue {
        if query.isEmpty {
          sections(catalogue)
        } else {
          results(HomebrewCatalogueQuery.search(query, in: catalogue))
        }
        footer
      } else if let message = model.errorMessage {
        Section {
          Text(message).foregroundColor(.secondary)
          Button(L("Try Again")) { Task { await model.refresh() } }
        }
      } else {
        Section { HStack { Spacer(); ProgressView(); Spacer() } }
      }
      Section { HomebrewAttribution() }
      TVStorageNoteSection()
    }
    .searchable(text: $model.searchText)
    #if !os(tvOS)
    .refreshable { await model.refresh() }
    #endif
    .onAppear { model.reloadIndex() }
  }

  @ViewBuilder
  private func sections(_ catalogue: HomebrewCatalogue) -> some View {
    ForEach(HomebrewCatalogueQuery.sections(catalogue, previewCount: HomebrewBrowser.rootSectionCount)) { section in
      Section("\(section.category.displayName) (\(section.count))") {
        ForEach(section.preview) { title in
          NavigationLink(value: HomebrewBrowserRoute.title(title)) {
            HomebrewTitleRow(title: title, state: model.state(of: title))
          }
        }
        if section.count > section.preview.count {
          NavigationLink(value: HomebrewBrowserRoute.category(section.category)) { Text(L("See All")) }
        }
      }
    }
  }

  @ViewBuilder
  private func results(_ titles: [HomebrewTitle]) -> some View {
    Section {
      ForEach(titles) { title in
        NavigationLink(value: HomebrewBrowserRoute.title(title)) {
          HomebrewTitleRow(title: title, state: model.state(of: title))
        }
      }
      if titles.isEmpty {
        Text(L("No homebrew found.")).foregroundColor(.secondary)
      }
    }
  }

  @ViewBuilder
  private var footer: some View {
    Section {
      if model.isShowingSavedList {
        Text(L("Showing the saved list.")).icubeText(.detail).foregroundColor(.secondary)
      }
      #if os(tvOS)
      // No pull to refresh on tvOS.
      Button(L("Refresh")) { Task { await model.refresh() } }
        .disabled(model.isLoading)
      #endif
    }
  }
}

struct HomebrewCategoryView: View {
  let category: HomebrewCategory
  @ObservedObject var model: HomebrewBrowserModel
  @State private var sort = HomebrewSort.name

  var body: some View {
    List {
      Section {
        NavigationLink {
          ModChoiceList(
            title: L("Sort By"),
            choices: HomebrewSort.allCases.map { ModChoice(id: $0.rawValue, title: $0.title) },
            selectedID: sort.rawValue
          ) { choice in
            sort = HomebrewSort(rawValue: choice.id) ?? .name
          }
        } label: {
          HStack {
            Text(L("Sort By"))
            Spacer()
            Text(sort.title).foregroundColor(.secondary)
          }
        }
      }
      Section {
        ForEach(titles) { title in
          NavigationLink(value: HomebrewBrowserRoute.title(title)) {
            HomebrewTitleRow(title: title, state: model.state(of: title))
          }
        }
      }
      Section { HomebrewAttribution() }
      TVStorageNoteSection()
    }
    .navigationTitle(category.displayName)
    .onAppear { model.reloadIndex() }
  }

  private var titles: [HomebrewTitle] {
    guard let catalogue = model.catalogue else { return [] }
    return HomebrewCatalogueQuery.titles(in: category, of: catalogue, sort: sort)
  }
}

struct HomebrewTitleRow: View {
  let title: HomebrewTitle
  let state: HomebrewInstalledIndex.State

  private static let thumbnailSize: CGFloat = 64

  var body: some View {
    HStack(spacing: 12) {
      AsyncImage(url: title.coverPath.flatMap(DolphinDepotEndpoint.image(path:))) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Rectangle().fill(Color.secondary.opacity(0.2))
      }
      .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
      .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue))
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title.name).lineLimit(2)
        if !title.author.isEmpty {
          Text(title.author).icubeText(.detail).foregroundColor(ICubeDesign.color(.textSecondary)).lineLimit(1)
        }
      }
      Spacer()
      Text(trailing).icubeText(.detail).foregroundColor(ICubeDesign.color(.textSecondary))
    }
  }

  private var trailing: String {
    switch state {
    case .installed: return L("Installed")
    case .updateAvailable: return L("Update")
    case .notInstalled: return title.latest.map { ModInstallModel.formatted($0.size) } ?? ""
    }
  }
}
