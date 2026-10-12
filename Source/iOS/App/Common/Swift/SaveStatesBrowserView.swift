import SwiftUI

struct SaveStatesBrowserView: View {
  @StateObject private var vm = SaveStatesViewModel()

  #if os(tvOS)
  private static let sectionSpacing = ICubeDesign.Spacing.l.rawValue
  private static let cardSpacing = ICubeDesign.Spacing.l.rawValue
  #else
  private static let sectionSpacing: CGFloat = 24
  private static let cardSpacing: CGFloat = 16
  #endif

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: Self.sectionSpacing) {
        ForEach(vm.grouped, id: \.gameID) { group in
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              #if os(tvOS)
              Text(group.gameID)
                .icubeText(.body)
                .fontWeight(.semibold)
                .foregroundStyle(ICubeDesign.color(.textPrimary))
              Text("\(group.states.count)")
                .icubeText(.detail)
                .foregroundStyle(ICubeDesign.color(.textSecondary))
              #else
              Text(group.gameID)
                .font(.title2.weight(.semibold))
              Text("\(group.states.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
              #endif
              Spacer()
              NavigationLink("View All") {
                SaveStateFilmstripView(gameID: group.gameID)
              }
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
              LazyHStack(spacing: Self.cardSpacing) {
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
