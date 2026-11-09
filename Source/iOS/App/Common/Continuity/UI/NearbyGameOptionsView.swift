// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import PVContinuity
import SwiftUI

struct NearbyCopyOptions {
  let catalog: NearbySaveWire.Catalog?
  let states: [NearbySaveWire.State]
}

/// A real choice before sending any bytes: saving games and starting them are
/// independent actions. Save catalogs are requested only on explicit selection.
struct NearbyGameOptionsView: View {
  let entry: ContinuityLibraryEntry
  let peer: NearbyLibrariesModel.Peer
  let isOwned: Bool
  let onCopy: (NearbyCopyOptions) -> Void
  let onBoot: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var mode = SaveChoice.none
  @State private var catalog: NearbySaveWire.Catalog?
  @State private var selected = Set<String>()
  @State private var requesting = false
  @State private var error: String?
  @State private var requestTask: Task<Void, Never>?

  enum SaveChoice: CaseIterable {
    case none, latest, specific, all
    var title: String {
      switch self {
      case .none: return L("No Save States")
      case .latest: return L("Latest Save State")
      case .specific: return L("Choose Save States")
      case .all: return L("All Save States")
      }
    }
  }

  var body: some View {
    NavigationStack {
      ScrollViewReader { scroller in
        List {
          if isOwned {
            Section {
              Button(L("Play Local Copy…")) { onBoot() }
            }
          }
          if peer.advertisement != nil {
            Section(header: Text(L("Copy Save States")), footer: Text(L("Save states are imported as new copies. Your existing saves, memory cards and Wii saves are not replaced."))) {
              ForEach(SaveChoice.allCases, id: \.self) { choice in
                Button {
                  mode = choice
                  if choice != .none, catalog == nil, !requesting { requestCatalog() }
                } label: {
                  HStack {
                    Text(choice.title)
                    Spacer()
                    if mode == choice { Image(systemName: "checkmark") }
                  }
                }
              }
            }
            if requesting {
              Section {
                Text(String(format: L("Asking %@ to share save states…"), peer.name))
                  .id("save-sharing-status")
                ProgressView()
              }
            }
            if let error { Section { Text(error)
              Button(L("Try Again")) { requestCatalog() }
            } }
            if let catalog, mode != .none {
              Section(header: Text(L("Save States"))) {
                if catalog.states.isEmpty { Text(L("No save states are available on this device.")) }
                if mode == .specific {
                  ForEach(catalog.states) { state in
                    Button {
                      if selected.contains(state.id) { selected.remove(state.id) } else { selected.insert(state.id) }
                    } label: {
                      HStack {
                        VStack(alignment: .leading) {
                          Text(state.title)
                          Text(state.savedAt, style: .date).font(.caption)
                        }
                        Spacer()
                        if selected.contains(state.id) { Image(systemName: "checkmark") }
                      }
                    }
                  }
                }
              }
            }
          }
          Section {
            if !isOwned || peer.advertisement != nil {
              Button(isOwned ? L("Copy Save States") : L("Download")) { confirm() }
                .disabled(!canCopy)
            }
            Button(L("Cancel"), role: .cancel) { dismiss() }
          }
          if peer.advertisement != nil { Section { ContinuitySecurityNotice() } }
        }
        .onChange(of: requesting) { _, active in
          if active {
            withAnimation { scroller.scrollTo("save-sharing-status", anchor: .center) }
          }
        }
        .navigationTitle(entry.game.displayName)
      }
    }
    .onDisappear { requestTask?.cancel() }
  }

  private var chosenStates: [NearbySaveWire.State] {
    let states = (catalog?.states ?? []).sorted { $0.savedAt > $1.savedAt }
    switch mode {
    case .none: return []
    case .latest: return Array(states.prefix(1))
    case .all: return states
    case .specific: return states.filter { selected.contains($0.id) }
    }
  }

  private var canCopy: Bool {
    guard !requesting else { return false }
    if mode == .none { return !isOwned }
    return !requesting && error == nil && !chosenStates.isEmpty
  }

  private func confirm() {
    onCopy(.init(catalog: mode == .none ? nil : catalog, states: chosenStates))
  }

  private func requestCatalog() {
    guard let advertisement = peer.advertisement else { return }
    requestTask?.cancel()
    requesting = true
    error = nil
    requestTask = Task {
      do {
        let result = try await NearbySaveClient(identity: ContinuityManager.shared.identity)
          .catalog(from: advertisement, entry: entry)
        try Task.checkCancellation()
        catalog = result
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
      if !Task.isCancelled { requesting = false }
    }
  }
}

struct NearbyBootOptionsView: View {
  let game: TVGameItem
  let onBoot: (URL?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var states: [SaveStateInfo] = []
  @State private var loading = true
  var body: some View {
    NavigationStack {
      List {
        Section {
          Button(L("Start Without a Save State")) { onBoot(nil) }
          if loading { ProgressView() }
          if let latest = states.first(where: \.isCompatible) {
            Button(L("Resume Latest Save State")) { onBoot(latest.path) }
          }
        }
        Section(header: Text(L("Choose a Save State"))) {
          ForEach(states) { state in
            Button { onBoot(state.path) } label: {
              VStack(alignment: .leading) {
                Text(state.displayName)
                if let date = state.modifiedAt { Text(date, style: .date).font(.caption) }
                if !state.isCompatible { Text(L("Incompatible Save State")).font(.caption) }
              }
            }
            .disabled(!state.isCompatible)
          }
        }
        Section { Button(L("Not Now"), role: .cancel) { dismiss() } }
      }
      .navigationTitle(game.title)
    }
    .task {
      states = await FilesystemSaveStateProvider().states(for: game.gameID)
      loading = false
    }
  }
}
