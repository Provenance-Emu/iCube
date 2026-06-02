import SwiftUI

struct SaveStatesBrowserView: View {
  @StateObject private var vm = SaveStatesViewModel()

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        ForEach(vm.grouped, id: \.gameID) { group in
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text(group.gameID)
                .font(.title2.weight(.semibold))
              Text("\(group.states.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
              Spacer()
              NavigationLink("View All") {
                SaveStateFilmstripView(gameID: group.gameID)
              }
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
              LazyHStack(spacing: 16) {
                ForEach(group.states.prefix(10)) { state in
                  SaveStateCardView(state: state, thumbnail: vm.thumbnails[state.id])
                }
              }
              .padding(.horizontal)
            }
          }
        }
      }
      .padding(.vertical, 16)
    }
    .navigationTitle("Save States")
    .task { await vm.loadAll() }
  }
}
