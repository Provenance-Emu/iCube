import SwiftUI

struct SaveStateFilmstripView: View {
  let gameID: String
  @StateObject private var vm = SaveStatesViewModel()

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
                Button("Load") { /* wire load */ }
                if state.slot != nil { Button("Overwrite") { /* wire overwrite */ } }
                Button("Rename") { /* wire rename */ }
                Button(role: .destructive) { vm.delete(state: state, inGameID: gameID) } label: { Text("Delete") }
                Button("Export") { /* wire export */ }
              }
          }
        }
        .padding(.horizontal)
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
