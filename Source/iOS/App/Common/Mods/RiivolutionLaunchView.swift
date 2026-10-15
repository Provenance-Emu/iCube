// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// "Play with Mods": pick Riivolution options for a game, then play once or save the combination to the library.
///
/// Choices use rows and `NavigationLink`s rather than `Menu` or `Picker`, which have no usable presentation on tvOS.
struct RiivolutionLaunchView: View {
  @StateObject private var model: RiivolutionLaunchModel
  /// Boots the descriptor written for this play. The sheet closes itself first.
  let onPlay: (URL) -> Void
  /// Called with the descriptor saved into the library, so the library can rescan.
  let onAddedToLibrary: (URL) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var failureMessage: String?

  init(item: TVGameItem, onPlay: @escaping (URL) -> Void, onAddedToLibrary: @escaping (URL) -> Void) {
    let game = RiivolutionLaunchModel.Game(
      title: item.title,
      gameID: item.gameID,
      revision: item.revision,
      discNumber: item.discNumber,
      filePath: item.filePath
    )
    _model = StateObject(wrappedValue: RiivolutionLaunchModel(game: game))
    self.onPlay = onPlay
    self.onAddedToLibrary = onAddedToLibrary
  }

  var body: some View {
    NavigationStack {
      List {
        if model.isLoading {
          HStack {
            ProgressView()
            Text(L("Looking for Riivolution packs…")).foregroundStyle(.secondary)
          }
        } else if model.packs.isEmpty {
          emptyState
        } else {
          packSections
          launchSection
          notesSection
        }
      }
      .navigationTitle(L("Play with Mods"))
      #if !os(tvOS)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L("Close")) { dismiss() }
        }
      }
      #endif
      .alert(L("Couldn't Start"), isPresented: Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })) {
        Button(L("OK"), role: .cancel) {}
      } message: {
        Text(failureMessage ?? "")
      }
    }
    .task { await model.load() }
  }

  // MARK: - Sections

  private var emptyState: some View {
    Section {
      Text(L("No installed Riivolution pack is for this game."))
      Text(L("To install a pack, import its .zip or .7z like a game (Import menu, Files, or Wi-Fi upload). It is unpacked into the Riivolution folder instead of the library."))
        .foregroundStyle(.secondary)
    }
  }

  private var packSections: some View {
    ForEach(Array(model.packs.enumerated()), id: \.element.id) { packIndex, pack in
      ForEach(Array(pack.sections.enumerated()), id: \.offset) { _, section in
        Section(header: Text(section.name.isEmpty ? pack.title : "\(pack.title) · \(section.name)")) {
          ForEach(section.optionIndices, id: \.self) { optionIndex in
            optionRow(packIndex: packIndex, optionIndex: optionIndex)
          }
        }
      }
    }
  }

  private func optionRow(packIndex: Int, optionIndex: Int) -> some View {
    let option = model.packs[packIndex].options[optionIndex]
    return NavigationLink {
      RiivolutionChoiceList(option: option) { choice in
        model.select(choice: choice, option: optionIndex, inPack: packIndex)
      }
    } label: {
      HStack {
        Text(option.name)
        Spacer()
        Text(option.selectedChoiceName ?? L("Disabled")).foregroundStyle(.secondary)
      }
    }
  }

  private var launchSection: some View {
    Section(footer: Text(model.canLaunch ? "" : L("Choose at least one option to play with mods."))) {
      Button {
        play()
      } label: {
        Label(L("Play"), systemImage: "play.fill")
      }
      .disabled(!model.canLaunch)

      TextField(model.suggestedLibraryName, text: $model.customLibraryName)
      Button {
        addToLibrary()
      } label: {
        Label(L("Add to Library"), systemImage: "plus.square.on.square")
      }
      .disabled(!model.canLaunch)
    }
  }

  private var notesSection: some View {
    Section {
      Text(L("Riivolution never changes your disc image: the mods are applied while the game loads."))
      Text(L("Save-state slots are shared with the unmodded game. Resume where you left off is not used for modded games."))
      Text(L("A mod that does not keep its own save shares the original game's save data, so it can change your existing save. Back up saves you care about."))
      Text(L("Loading-time emulation is turned off while mods are active."))
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
  }

  // MARK: - Actions

  private func play() {
    guard let url = model.writeRunDescriptor() else {
      failureMessage = L("The mod settings couldn't be saved.")
      return
    }
    dismiss()
    onPlay(url)
  }

  private func addToLibrary() {
    guard let url = model.writeLibraryDescriptor() else {
      failureMessage = L("The mod settings couldn't be saved.")
      return
    }
    dismiss()
    onAddedToLibrary(url)
  }
}

/// The choices of one option: Disabled, then each choice, with the current one checked.
private struct RiivolutionChoiceList: View {
  let option: RiivolutionOption
  let onSelect: (Int) -> Void
  @State private var selected: Int
  @Environment(\.dismiss) private var dismiss

  init(option: RiivolutionOption, onSelect: @escaping (Int) -> Void) {
    self.option = option
    self.onSelect = onSelect
    _selected = State(initialValue: option.selectedChoice)
  }

  var body: some View {
    List {
      row(title: L("Disabled"), choice: 0)
      ForEach(Array(option.choices.enumerated()), id: \.offset) { index, name in
        row(title: name, choice: index + 1)
      }
    }
    .navigationTitle(option.name)
  }

  private func row(title: String, choice: Int) -> some View {
    Button {
      selected = choice
      onSelect(choice)
      dismiss()
    } label: {
      HStack {
        Text(title)
        Spacer()
        if selected == choice { Image(systemName: "checkmark") }
      }
    }
  }
}
