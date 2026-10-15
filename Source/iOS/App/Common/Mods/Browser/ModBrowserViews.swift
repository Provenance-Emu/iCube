// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

enum ModBrowserRoute: Hashable {
  case game(ModGameTable.Entry)
  case mod(GameBananaModSummary, ModGameTable.Entry)
}

/// The mod browser: a catalogue of GameBanana mods for the GC/Wii games iCube knows about.
///
/// Built from plain `List` rows and `NavigationLink`s: `Menu` and `Picker` have no usable
/// presentation on tvOS, and a list row is already one focus target there.
struct ModBrowserRoot: View {
  let request: ModBrowserRequest
  let libraryGames: [ModLibraryGame]
  let handler: any ModInstallHandling

  @ObservedObject private var presenter = ModBrowserPresenter.shared
  @Environment(\.dismiss) private var dismiss
  @State private var path: [ModBrowserRoute]

  init(request: ModBrowserRequest, libraryGames: [ModLibraryGame], handler: any ModInstallHandling) {
    self.request = request
    self.libraryGames = libraryGames
    self.handler = handler
    let start = request.game.flatMap { ModGameTable.bundled.entry(forGameID: $0.gameID) }
    _path = State(initialValue: start.map { [.game($0)] } ?? [])
  }

  var body: some View {
    NavigationStack(path: $path) {
      ModGameListView(libraryGames: libraryGames)
        .navigationTitle(L("Mod Browser"))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } }
        }
        .navigationDestination(for: ModBrowserRoute.self) { route in
          switch route {
          case .game(let entry):
            ModListView(entry: entry, ownedGame: ownedGame(for: entry))
          case .mod(let summary, let entry):
            ModDetailView(summary: summary, entry: entry, ownedGame: ownedGame(for: entry), handler: handler)
          }
        }
    }
    .task { ModDownloadManager.shared.sweepStaleDownloads() }
    .alert(L("Mod Browser"), isPresented: Binding(get: { presenter.notice != nil }, set: { if !$0 { presenter.notice = nil } })) {
      Button(L("OK"), role: .cancel) {}
    } message: {
      Text(presenter.notice ?? "")
    }
  }

  /// The library game the browser acts on for a catalogue entry: the one the user opened it from,
  /// else the first library game of that title.
  private func ownedGame(for entry: ModGameTable.Entry) -> ModLibraryGame? {
    if let requested = request.game, ModGameTable.bundled.entry(forGameID: requested.gameID) == entry { return requested }
    return libraryGames.first { ModGameTable.bundled.entry(forGameID: $0.gameID) == entry }
  }
}

/// Every attribution line the screens share.
struct ModBrowserAttribution: View {
  var body: some View {
    Text(ModBrowser.attribution)
      .font(.footnote)
      .foregroundColor(.secondary)
  }
}

// MARK: - Games

struct ModGameListView: View {
  let libraryGames: [ModLibraryGame]

  private var ownedEntries: [ModGameTable.Entry] {
    ModGameTable.bundled.entries.filter { entry in
      libraryGames.contains { ModGameTable.bundled.entry(forGameID: $0.gameID) == entry }
    }
  }

  private var otherEntries: [ModGameTable.Entry] {
    let owned = Set(ownedEntries)
    return ModGameTable.bundled.entries.filter { !owned.contains($0) }
  }

  var body: some View {
    List {
      if !ownedEntries.isEmpty {
        Section(L("Your Games")) {
          ForEach(ownedEntries) { gameRow($0) }
        }
      }
      Section(ownedEntries.isEmpty ? L("Games") : L("More Games")) {
        ForEach(otherEntries) { gameRow($0) }
      }
      Section { ModBrowserAttribution() }
    }
  }

  private func gameRow(_ entry: ModGameTable.Entry) -> some View {
    NavigationLink(value: ModBrowserRoute.game(entry)) {
      HStack(spacing: 12) {
        AsyncImage(url: entry.iconURL) { image in
          image.resizable().scaledToFit()
        } placeholder: {
          Image(systemName: "gamecontroller").foregroundColor(.secondary)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
        Text(entry.name)
      }
    }
  }
}

// MARK: - Mods of one game

@MainActor
final class ModListModel: ObservableObject {
  @Published private(set) var mods: [GameBananaModSummary] = []
  @Published private(set) var isLoading = false
  @Published private(set) var isComplete = true
  @Published private(set) var errorMessage: String?
  @Published private(set) var categories: [GameBananaCategory] = []
  @Published var sort: GameBananaSort = .mostLiked
  @Published var category: GameBananaCategory?
  @Published var searchText = ""

  let entry: ModGameTable.Entry
  private var page = 0
  private var generation = 0
  private var activeQuery = ""

  init(entry: ModGameTable.Entry) {
    self.entry = entry
  }

  func loadIfNeeded() async {
    if mods.isEmpty && !isLoading && errorMessage == nil { await reload() }
    if categories.isEmpty, let loaded = try? await GameBananaClient.shared.categories(gameID: entry.bananaID) {
      categories = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
  }

  func reload() async {
    generation += 1
    mods = []
    page = 0
    isComplete = false
    errorMessage = nil
    activeQuery = searchText.trimmingCharacters(in: .whitespaces)
    await loadNextPage()
  }

  func loadMore() async {
    if !isLoading && !isComplete { await loadNextPage() }
  }

  private func loadNextPage() async {
    let current = generation
    isLoading = true
    defer { if current == generation { isLoading = false } }
    do {
      let next = page + 1
      let result: GameBananaPage<GameBananaModSummary>
      if activeQuery.isEmpty {
        result = try await GameBananaClient.shared.mods(gameID: entry.bananaID, categoryID: category?.id, sort: sort, page: next)
      } else {
        result = try await GameBananaClient.shared.searchMods(gameID: entry.bananaID, query: activeQuery, page: next)
      }
      guard current == generation else { return }
      page = next
      let known = Set(mods.map(\.id))
      mods += result.records.filter { !known.contains($0.id) && !$0.isObsolete }
      // An empty page ends the list even if the server still claims more.
      isComplete = result.isComplete || result.records.isEmpty
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      errorMessage = error.localizedDescription
      isComplete = true
    }
  }
}

struct ModListView: View {
  let ownedGame: ModLibraryGame?
  @StateObject private var model: ModListModel

  init(entry: ModGameTable.Entry, ownedGame: ModLibraryGame?) {
    self.ownedGame = ownedGame
    _model = StateObject(wrappedValue: ModListModel(entry: entry))
  }

  var body: some View {
    List {
      if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
        filterSection
      }
      Section {
        ForEach(model.mods) { mod in
          NavigationLink(value: ModBrowserRoute.mod(mod, model.entry)) { ModSummaryRow(mod: mod) }
            .onAppear { if mod.id == model.mods.last?.id { Task { await model.loadMore() } } }
        }
        if model.isLoading {
          HStack { Spacer(); ProgressView(); Spacer() }
        }
        if let message = model.errorMessage {
          Text(message).foregroundColor(.secondary)
          Button(L("Try Again")) { Task { await model.reload() } }
        } else if model.mods.isEmpty && !model.isLoading {
          Text(L("No mods found.")).foregroundColor(.secondary)
        }
      }
      Section { ModBrowserAttribution() }
    }
    .navigationTitle(model.entry.name)
    .searchable(text: $model.searchText)
    .onSubmit(of: .search) { Task { await model.reload() } }
    .onChange(of: model.searchText) { _, text in
      if text.isEmpty { Task { await model.reload() } }
    }
    .task { await model.loadIfNeeded() }
  }

  private var filterSection: some View {
    Section {
      NavigationLink {
        ModChoiceList(
          title: L("Category"),
          choices: [ModChoice(id: "", title: L("All Categories"))]
            + model.categories.map { ModChoice(id: String($0.id), title: "\($0.name) (\($0.itemCount))") },
          selectedID: model.category.map { String($0.id) } ?? ""
        ) { choice in
          model.category = model.categories.first { String($0.id) == choice.id }
          Task { await model.reload() }
        }
      } label: {
        filterLabel(L("Category"), model.category?.name ?? L("All Categories"))
      }
      NavigationLink {
        ModChoiceList(
          title: L("Sort By"),
          choices: GameBananaSort.allCases.map { ModChoice(id: $0.rawValue, title: $0.title) },
          selectedID: model.sort.rawValue
        ) { choice in
          model.sort = GameBananaSort(rawValue: choice.id) ?? .mostLiked
          Task { await model.reload() }
        }
      } label: {
        filterLabel(L("Sort By"), model.sort.title)
      }
    }
  }

  private func filterLabel(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).foregroundColor(.secondary)
    }
  }
}

struct ModChoice: Identifiable, Hashable {
  let id: String
  let title: String
}

/// A pick-one list that pops itself when a row is chosen; the tvOS-safe stand-in for a Picker.
struct ModChoiceList: View {
  let title: String
  let choices: [ModChoice]
  let selectedID: String
  let onSelect: (ModChoice) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List(choices) { choice in
      Button {
        onSelect(choice)
        dismiss()
      } label: {
        HStack {
          Text(choice.title)
          Spacer()
          if choice.id == selectedID { Image(systemName: "checkmark").accessibilityLabel(L("Selected")) }
        }
      }
    }
    .navigationTitle(title)
  }
}

struct ModSummaryRow: View {
  let mod: GameBananaModSummary

  private static let thumbnailSize: CGFloat = 64

  var body: some View {
    HStack(spacing: 12) {
      AsyncImage(url: mod.images.first?.url(minimumWidth: 100)) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Rectangle().fill(Color.secondary.opacity(0.2))
      }
      .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(mod.name).lineLimit(2)
        Text(subtitle).font(.footnote).foregroundColor(.secondary).lineLimit(1)
      }
    }
  }

  private var subtitle: String {
    var parts: [String] = []
    if let category = mod.categoryName { parts.append(category) }
    if let submitter = mod.submitter?.name, !submitter.isEmpty { parts.append(submitter) }
    if let likes = mod.likeCount { parts.append("\(likes) ♥") }
    return parts.joined(separator: " · ")
  }
}
