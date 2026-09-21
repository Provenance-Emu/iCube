import SwiftUI

struct SaveStateFilmstripView: View {
  let gameID: String
  @StateObject private var vm = SaveStatesViewModel()
  @State private var renameTarget: SaveStateInfo?
  @State private var renameText: String = ""
  // Set when Load is chosen for this gameID while it is NOT the running title
  // (i.e. this browser was reached from the library, not the pause menu of an
  // already-booted game). There is no running core to hot-swap into in that
  // case, so this view boots the game itself and lands directly on that state.
  @State private var bootTarget: TVGameItem?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Save States")
          .font(.largeTitle.weight(.bold))
        Spacer()
        Text(gameID)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal)

      ScrollView(.horizontal) {
        LazyHStack(spacing: 20) {
          ForEach(vm.states) { state in
            SaveStateCard(state: state, thumbnail: vm.thumbnails[state.id])
              .contextMenu {
                if let slot = state.slot {
                  Button("Load") { loadOrBoot(state) }
                  Button("Overwrite") {
                    _ = SaveStateService.saveSlot(slot)
                    Task { await vm.load(gameID: gameID) }
                  }
                }
                Button("Rename") {
                  renameText = state.displayName
                  renameTarget = state
                }
                Button(role: .destructive) { vm.delete(state: state, inGameID: gameID) } label: { Text("Delete") }
              }
          }
        }
        .padding(.horizontal)
      }
    }
    .alert("Rename Save", isPresented: Binding(
      get: { renameTarget != nil },
      set: { if !$0 { renameTarget = nil } }
    )) {
      TextField("Title", text: $renameText)
      Button("Cancel", role: .cancel) { renameTarget = nil }
      Button("Save") {
        if let target = renameTarget {
          let newTitle = renameText
          Task { await vm.rename(state: target, to: newTitle, inGameID: gameID) }
        }
        renameTarget = nil
      }
    }
    .fullScreenCover(item: $bootTarget) { item in
      EmulationScreen(game: item)
    }
    .task {
      await vm.load(gameID: gameID)
    }
  }

  /// This view is reached two ways: from the pause menu of an already-running
  /// game (hot-swap the state into the live core, as before), and from the
  /// library's "View Save States" context-menu item on a game that is NOT
  /// running. Loading a slot in the second case previously called straight into
  /// `TVEmulationBridge.loadState(fromSlot:)`, which queues a host job for a CPU
  /// thread that does not exist yet — a silent no-op with no running game to load
  /// into. Boot the game fresh instead and land directly on the requested state.
  private func loadOrBoot(_ state: SaveStateInfo) {
    if TVEmulationBridge.isRunning(), SaveStateService.currentGameID == gameID {
      TVEmulationBridge.loadState(fromPath: state.path.path)
      return
    }
    guard let item = TVLibraryBridge.currentGames().first(where: { $0.gameID == gameID }) else {
      NSLog("[SaveStates] Boot-into-state requested for %@ but no matching library item was found", gameID)
      return
    }
    SaveStateService.pendingBootStatePath = state.path.path
    bootTarget = item
  }
}

private struct SaveStateCard: View {
  let state: SaveStateInfo
  let thumbnail: UIImage?
  var body: some View { SaveStateCardView(state: state, thumbnail: thumbnail) }
}
