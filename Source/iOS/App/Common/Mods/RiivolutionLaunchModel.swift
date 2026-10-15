// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// State behind the "Play with Mods" sheet: the packs valid for one game, the user's choices, and the descriptors
/// that boot or save them. UI-free so the rules (when Play is allowed, what a descriptor is called) are testable.
@MainActor
final class RiivolutionLaunchModel: ObservableObject {
  /// The disc the packs apply to.
  struct Game: Equatable {
    let title: String
    let gameID: String
    let revision: Int
    let discNumber: Int
    let filePath: String
  }

  /// Reads the packs valid for a game. Parses XML files, so it runs off the main thread.
  typealias PackLoader = @Sendable (Game, URL) -> [RiivolutionPack]

  let game: Game
  @Published private(set) var packs: [RiivolutionPack] = []
  @Published private(set) var isLoading = true
  /// What the user typed for the library entry's name; empty means "use the suggestion".
  @Published var customLibraryName = ""

  private let sdRoot: URL
  private let softwareFolder: String
  private let userFolder: String
  private let loadPacks: PackLoader
  private let saveSelections: ([RiivolutionPack], String) -> Bool

  init(
    game: Game,
    sdRoot: URL = RiivolutionLocation.installRoot(),
    softwareFolder: String = UserFolderUtil.getSoftwareFolder(),
    userFolder: String = UserFolderUtil.getUserFolder(),
    loadPacks: @escaping PackLoader = { RiivolutionBridgeAccess.packs(for: $0, in: $1) },
    saveSelections: @escaping ([RiivolutionPack], String) -> Bool = { RiivolutionBridgeAccess.saveSelections(of: $0, gameID: $1) }
  ) {
    self.game = game
    self.sdRoot = sdRoot
    self.softwareFolder = softwareFolder
    self.userFolder = userFolder
    self.loadPacks = loadPacks
    self.saveSelections = saveSelections
  }

  /// Parses the installed packs off the main thread.
  func load() async {
    let game = game
    let sdRoot = sdRoot
    let loadPacks = loadPacks
    packs = await Task.detached(priority: .userInitiated) { loadPacks(game, sdRoot) }.value
    isLoading = false
  }

  /// "Game — Pack" for the one pack with a choice selected, or just the game's title.
  var suggestedLibraryName: String {
    let active = packs.filter(\.hasSelection)
    guard active.count == 1, let pack = active.first else { return game.title }
    return "\(game.title) — \(pack.title)"
  }

  var libraryName: String {
    let typed = customLibraryName.trimmingCharacters(in: .whitespacesAndNewlines)
    return typed.isEmpty ? suggestedLibraryName : typed
  }

  /// Play and Add to Library need at least one choice: with none, the game would boot unmodified.
  var canLaunch: Bool {
    packs.contains(where: \.hasSelection)
  }

  func select(choice: Int, option optionIndex: Int, inPack packIndex: Int) {
    guard packs.indices.contains(packIndex), packs[packIndex].options.indices.contains(optionIndex) else { return }
    let option = packs[packIndex].options[optionIndex]
    guard (0...option.choices.count).contains(choice) else { return }
    packs[packIndex].options[optionIndex].selectedChoice = choice
  }

  /// Saves the choices as Riivolution does and writes a descriptor for one play. Nil if nothing is selected or writing failed.
  func writeRunDescriptor() -> URL? {
    guard canLaunch else { return nil }
    _ = saveSelections(packs, game.gameID)
    let url = ModDescriptorStore.newRunURL(userFolder: userFolder)
    return write(to: url, displayName: suggestedLibraryName)
  }

  /// Saves the choices and writes a descriptor into the library's Mods folder, which the library scan lists as a game.
  func writeLibraryDescriptor() -> URL? {
    guard canLaunch else { return nil }
    _ = saveSelections(packs, game.gameID)
    let url = ModDescriptorStore.uniqueURL(in: ModDescriptorStore.libraryFolder(softwareFolder: softwareFolder), name: libraryName)
    return write(to: url, displayName: libraryName)
  }

  private func write(to url: URL, displayName: String) -> URL? {
    let selected = packs.filter(\.hasSelection)
    do {
      try ModDescriptorStore.write(baseFile: game.filePath, displayName: displayName, packs: selected, to: url)
      return url
    } catch {
      return nil
    }
  }
}

/// The core's Riivolution parser and config writer, as the launch model's defaults.
enum RiivolutionBridgeAccess {
  static func packs(for game: RiivolutionLaunchModel.Game, in sdRoot: URL) -> [RiivolutionPack] {
    RiivolutionBridge.packs(forGameID: game.gameID, revision: game.revision, discNumber: game.discNumber, sdRoot: sdRoot.path)
      .map(RiivolutionPack.init(info:))
  }

  static func saveSelections(of packs: [RiivolutionPack], gameID: String) -> Bool {
    RiivolutionBridge.saveSelections(ofPacks: packs.map(\.bridgeInfo), gameID: gameID)
  }
}
