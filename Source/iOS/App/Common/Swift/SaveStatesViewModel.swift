import Foundation
import UIKit

@MainActor
final class SaveStatesViewModel: ObservableObject {
  @Published var states: [SaveStateInfo] = []
  @Published var grouped: [(gameID: String, states: [SaveStateInfo])] = []
  @Published var thumbnails: [UUID: UIImage] = [:]

  private let provider: SaveStateProviding

  init(provider: SaveStateProviding? = FilesystemSaveStateProvider()) {
    self.provider = provider ?? FilesystemSaveStateProvider()
  }

  func load(gameID: String) async {
    let items = await provider.states(for: gameID)
    states = items
    await preloadThumbnails(for: items)
  }

  func loadAll() async {
    let dict = await provider.statesGroupedByGame()
    // Sort groups by most recent state date
    let sorted = dict.map { key, value in (key, value) }.sorted { a, b in
      let ad = a.1.first?.modifiedAt ?? a.1.first?.createdAt ?? .distantPast
      let bd = b.1.first?.modifiedAt ?? b.1.first?.createdAt ?? .distantPast
      return ad > bd
    }
    grouped = sorted
    // Optionally preload a few thumbnails from each group
    let top = sorted.flatMap { $0.1.prefix(3) }
    await preloadThumbnails(for: Array(top))
  }

  func delete(state: SaveStateInfo, inGameID: String? = nil) {
    do {
      try provider.delete(state: state)
      // Update single-game list if applicable
      if let gid = inGameID {
        states.removeAll { $0.id == state.id }
        thumbnails[state.id] = nil
        // Also update grouped cache for that game if it exists
        if let idx = grouped.firstIndex(where: { $0.gameID == gid }) {
          var arr = grouped[idx].states
          arr.removeAll { $0.id == state.id }
          grouped[idx].states = arr
        }
      } else {
        // Update grouped list
        for i in grouped.indices {
          grouped[i].states.removeAll { $0.id == state.id }
        }
      }
    } catch {
      // TODO: surface error to UI if needed
    }
  }

  func rename(state: SaveStateInfo, to title: String, inGameID gameID: String?) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try provider.rename(state: state, to: trimmed)
    } catch {
      return
    }
    // Reload so the new label is reflected (SaveStateInfo fields are immutable).
    if let gameID {
      await load(gameID: gameID)
    } else {
      await loadAll()
    }
  }

  private func preloadThumbnails(for items: [SaveStateInfo]) async {
    for item in items {
      if let image = await provider.thumbnail(for: item) {
        thumbnails[item.id] = image
      }
    }
  }
}
