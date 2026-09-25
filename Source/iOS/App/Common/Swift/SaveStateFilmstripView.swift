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

      // A grid, not a filmstrip: cards are a consistent size regardless of how
      // many states exist, so tapping a specific card is unambiguous even for
      // a game with a dozen slots. Was previously a `ScrollView(.horizontal) {
      // LazyHStack }` with no tap target on the card at all — only a
      // long-press `.contextMenu` — and its "Load" entry only appeared
      // `if let slot = state.slot`, so an auto/"Continue" state (no slot) had
      // no way to load it whatsoever.
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 20)], spacing: 20) {
          ForEach(vm.states) { state in
            Button(action: { loadOrBoot(state) }) {
              SaveStateCard(state: state, thumbnail: vm.thumbnails[state.id])
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Load") { loadOrBoot(state) }
              if let slot = state.slot {
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
