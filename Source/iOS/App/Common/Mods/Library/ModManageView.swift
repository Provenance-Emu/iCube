// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// "Manage…": lists a game's patched copies, saved mod presets and installed Riivolution packs, with delete.
///
/// Rows are `Button`s in a `List`: swipe actions, `Menu` and `Picker` have no usable presentation on tvOS.
struct ModManageView: View {
  @StateObject private var model: ModManageModel
  @Environment(\.dismiss) private var dismiss
  @State private var pendingCopy: ModManageModel.Entry?
  @State private var pendingPack: RiivolutionPack?

  init(item: TVGameItem, variants: [TVGameItem], onChanged: @escaping () -> Void) {
    let game = RiivolutionLaunchModel.Game(
      title: item.title, gameID: item.gameID, revision: item.revision, discNumber: item.discNumber, filePath: item.filePath
    )
    _model = StateObject(wrappedValue: ModManageModel(
      game: game, entries: variants.compactMap { ModManageModel.Entry(entry: $0) }, onChanged: onChanged
    ))
  }

  var body: some View {
    NavigationStack {
      List {
        if model.isLoadingPacks {
          HStack {
            ProgressView()
            Text(L("Looking for Riivolution packs…")).foregroundStyle(.secondary)
          }
        } else if model.isEmpty {
          Section {
            Text(L("This game has no patched copies, saved mods or Riivolution packs."))
          }
        }
        entrySection(title: L("Patched Copies"), entries: model.patchedCopies)
        entrySection(title: L("Saved Mods"), entries: model.presets)
        packSection
        Section {
          Text(String(format: L("%@ itself is never deleted here."), model.game.title))
        }
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        TVStorageNoteSection()
      }
      .navigationTitle(L("Manage Patches & Mods"))
      #if !os(tvOS)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
      }
      #endif
      .alert(
        L("Delete this patched game?"),
        isPresented: Binding(get: { pendingCopy != nil }, set: { if !$0 { pendingCopy = nil } }),
        presenting: pendingCopy
      ) { entry in
        Button(L("Delete"), role: .destructive) { Task { await model.delete(entry) } }
        Button(L("Cancel"), role: .cancel) {}
      } message: { entry in
        Text(String(format: L("%@ is removed from this device. Your original game is not touched."), entry.name))
      }
      .alert(
        L("Remove this pack?"),
        isPresented: Binding(get: { pendingPack != nil }, set: { if !$0 { pendingPack = nil } }),
        presenting: pendingPack
      ) { pack in
        Button(L("Remove"), role: .destructive) { Task { await model.remove(pack) } }
        Button(L("Cancel"), role: .cancel) {}
      } message: { pack in
        Text(String(format: L("%@ no longer shows up in Play with Mods. Files it shares with other packs stay."), pack.title))
      }
      .alert(L("Couldn't Delete"), isPresented: Binding(get: { model.failureMessage != nil }, set: { if !$0 { model.failureMessage = nil } })) {
        Button(L("OK"), role: .cancel) {}
      } message: {
        Text(model.failureMessage ?? "")
      }
    }
    .task { await model.load() }
  }

  @ViewBuilder
  private func entrySection(title: String, entries: [ModManageModel.Entry]) -> some View {
    if !entries.isEmpty {
      Section(title) {
        ForEach(entries) { entry in
          Button(role: .destructive) { pendingCopy = entry } label: {
            HStack {
              Text(entry.name)
              Spacer()
              Image(systemName: "trash")
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var packSection: some View {
    if !model.packs.isEmpty {
      Section(L("Riivolution Packs")) {
        ForEach(model.packs, id: \.id) { pack in
          Button(role: .destructive) { pendingPack = pack } label: {
            HStack {
              Text(pack.title)
              Spacer()
              Image(systemName: "trash")
            }
          }
        }
      }
    }
  }
}
