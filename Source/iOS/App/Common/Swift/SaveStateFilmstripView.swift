import SwiftUI

struct SaveStateFilmstripView: View {
  let gameID: String
  @StateObject private var vm = SaveStatesViewModel()
  @State private var renameTarget: SaveStateInfo?
  @State private var renameText: String = ""

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
                  Button("Load") { TVEmulationBridge.loadState(fromSlot: slot) }
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
    .task {
      await vm.load(gameID: gameID)
    }
  }
}

private struct SaveStateCard: View {
  let state: SaveStateInfo
  let thumbnail: UIImage?
  var body: some View { SaveStateCardView(state: state, thumbnail: thumbnail) }
}
