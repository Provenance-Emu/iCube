import SwiftUI
import PVHelp

/// The pause-menu "Save States" screen (`PauseMenuView`'s `showFilmstripSheet`).
///
/// tvOS focus model (see `icube-tvos-swiftui-focus`): a `.contextMenu` (the
/// previous design) is a long-press gesture that a TV remote cannot reliably
/// drive, and stacking a second `Button` inside the same card would collapse
/// to one focus target and strand the rest -- so every card here is exactly
/// ONE focusable control. Tapping/selecting a card opens a `confirmationDialog`
/// with the card's actions (Load, Save Here, Rename, Delete); that dialog is a
/// plain button-list, which both `Menu` and `Picker` are not (see the focus
/// note for why those two are avoided everywhere in this codebase). Delete
/// requires a second, explicit confirmation alert before it touches disk.
struct SaveStateFilmstripView: View {
  let gameID: String
  @StateObject private var vm = SaveStatesViewModel()
  @State private var actionTarget: SaveStateInfo?
  @State private var renameTarget: SaveStateInfo?
  #if !os(tvOS)
  // Only iOS drives rename through an `.alert` with an embedded TextField;
  // tvOS uses `RenameStateSheet` below, which owns its own text state
  // (UIAlertController text fields aren't supported on tvOS).
  @State private var renameText: String = ""
  #endif
  @State private var deleteTarget: SaveStateInfo?
  /// Explains why an incompatible save state can't be safely loaded. Reachable
  /// from every card's action menu below (not just the iOS-only badge tap in
  /// `SaveStateCardView`), so tvOS -- which can't have a second focusable
  /// control per card -- has a way to see it too.
  @State private var showIncompatibleHelp = false
  // Set when Load is chosen for this gameID while it is NOT the running title
  // (i.e. this browser was reached from the library, not the pause menu of an
  // already-booted game). There is no running core to hot-swap into in that
  // case, so this view boots the game itself and lands directly on that state.
  @State private var bootTarget: TVGameItem?

  #if os(tvOS)
  private static let columnMinWidth: CGFloat = 480
  #else
  private static let columnMinWidth: CGFloat = 300
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(L("Save States"))
          .font(.largeTitle.weight(.bold))
        Spacer()
        Text(gameID)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal)

      if vm.states.isEmpty {
        emptyState
      } else {
        // A grid, not a filmstrip: cards are a consistent size regardless of
        // how many states exist, so selecting a specific card is unambiguous
        // even for a game with a dozen slots.
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.columnMinWidth), spacing: 20)], spacing: 20) {
            ForEach(vm.states) { state in
              Button {
                actionTarget = state
              } label: {
                SaveStateCardView(state: state, thumbnail: vm.thumbnails[state.id])
              }
              #if os(tvOS)
              .buttonStyle(.card)
              #else
              .buttonStyle(.plain)
              #endif
            }
          }
          .padding(.horizontal)
          .padding(.bottom, 16)
        }
      }
    }
    // Per-card action menu. One dialog, driven by whichever card was selected,
    // rather than per-card state -- keeps the "one focus target per card"
    // contract intact on tvOS while still offering every action.
    .confirmationDialog(
      actionTarget?.displayName ?? "",
      isPresented: Binding(
        get: { actionTarget != nil },
        set: { if !$0 { actionTarget = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let target = actionTarget {
        Button(L("Load")) {
          loadOrBoot(target)
          actionTarget = nil
        }
        // Only offered when THIS game is the one actually running: SaveStateService.saveSlot
        // calls straight into TVEmulationBridge.saveState, which is a silent no-op with no
        // running core to save from (e.g. reached from the library's "View Save States" on a
        // game that isn't booted, or the cross-game SaveStatesBrowserView).
        if let slot = target.slot, isThisGameRunning {
          Button(String(format: L("Save Here (Slot %d)"), slot)) {
            _ = SaveStateService.saveSlot(slot)
            actionTarget = nil
            Task { await vm.load(gameID: gameID) }
          }
        }
        Button(L("Rename")) {
          #if !os(tvOS)
          renameText = target.displayName
          #endif
          renameTarget = target
          actionTarget = nil
        }
        Button(L("Delete"), role: .destructive) {
          deleteTarget = target
          actionTarget = nil
        }
        if !target.isCompatible {
          Button(L("Why Incompatible?")) {
            actionTarget = nil
            showIncompatibleHelp = true
          }
        }
        Button(L("Cancel"), role: .cancel) { actionTarget = nil }
      }
    }
    .sheet(isPresented: $showIncompatibleHelp) {
      NavigationStack {
        WikiPageView(path: WikiConstants.Paths.saveStateCompatibility, title: L("Save State Compatibility"))
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(L("Close")) { showIncompatibleHelp = false }
            }
          }
      }
    }
    // Delete is destructive and irreversible, so it gets its own explicit
    // confirmation step separate from the action dialog above.
    .alert(
      L("Delete Save State"),
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }
      )
    ) {
      Button(L("Cancel"), role: .cancel) { deleteTarget = nil }
      Button(L("Delete"), role: .destructive) {
        if let target = deleteTarget {
          vm.delete(state: target, inGameID: gameID)
        }
        deleteTarget = nil
      }
    } message: {
      Text(L("This save state will be permanently deleted. This cannot be undone."))
    }
    // tvOS note: `UIAlertController`/`.alert` does not support an embedded
    // text field on tvOS (only iOS/macOS do), so a TextField-in-alert is a
    // silent dead end there. tvOS instead gets a plain sheet with a `Form` --
    // an ordinary focusable `TextField` that tvOS's on-screen keyboard can
    // drive -- while iOS keeps the lighter-weight alert it already had.
    #if os(tvOS)
    .sheet(item: $renameTarget) { target in
      RenameStateSheet(initialTitle: target.displayName) { newTitle in
        Task { await vm.rename(state: target, to: newTitle, inGameID: gameID) }
        renameTarget = nil
      } onCancel: {
        renameTarget = nil
      }
    }
    #else
    .alert(L("Rename Save"), isPresented: Binding(
      get: { renameTarget != nil },
      set: { if !$0 { renameTarget = nil } }
    )) {
      TextField(L("Title"), text: $renameText)
      Button(L("Cancel"), role: .cancel) { renameTarget = nil }
      Button(L("Save")) {
        if let target = renameTarget {
          let newTitle = renameText
          Task { await vm.rename(state: target, to: newTitle, inGameID: gameID) }
        }
        renameTarget = nil
      }
    }
    #endif
    .fullScreenCover(item: $bootTarget) { item in
      EmulationScreen(game: item)
    }
    .task {
      await vm.load(gameID: gameID)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "tray")
        .font(.system(size: 40, weight: .regular))
        .foregroundStyle(.secondary)
      Text(L("No Save States"))
        .font(.title3.weight(.semibold))
      Text(L("Save states for this game will appear here."))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  /// This view is reached two ways: from the pause menu of an already-running
  /// game (hot-swap the state into the live core, as before), and from the
  /// library's "View Save States" context-menu item on a game that is NOT
  /// running. Loading a slot in the second case previously called straight into
  /// `TVEmulationBridge.loadState(fromSlot:)`, which queues a host job for a CPU
  /// thread that does not exist yet -- a silent no-op with no running game to load
  /// into. Boot the game fresh instead and land directly on the requested state.
  private func loadOrBoot(_ state: SaveStateInfo) {
    if isThisGameRunning {
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

  /// True when the running core's game matches `gameID` -- i.e. this screen
  /// can hot-swap into the live core (load or overwrite a slot) rather than
  /// only being able to boot into a state or read a legacy file on disk.
  private var isThisGameRunning: Bool {
    TVEmulationBridge.isRunning() && SaveStateService.currentGameID == gameID
  }
}

#if os(tvOS)
/// tvOS-only rename entry point: an ordinary `Form` + `TextField` in a sheet,
/// which tvOS's on-screen keyboard can drive when the field takes focus.
/// `.alert` cannot host a text field on tvOS (only iOS/macOS support that),
/// so this is the tvOS substitute for the iOS alert-with-TextField above.
private struct RenameStateSheet: View {
  let initialTitle: String
  let onSave: (String) -> Void
  let onCancel: () -> Void
  @State private var text: String = ""

  var body: some View {
    NavigationStack {
      Form {
        TextField(L("Title"), text: $text)
      }
      .navigationTitle(L("Rename Save"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L("Cancel"), action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L("Save")) { onSave(text) }
        }
      }
    }
    .onAppear { text = initialTitle }
  }
}
#endif
