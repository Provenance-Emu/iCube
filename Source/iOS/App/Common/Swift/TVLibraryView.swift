import SwiftUI
import UIKit

// MARK: - Retro UI Helpers

private struct NeonGlowBorder: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.9), Color.purple.opacity(0.9)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ), lineWidth: active ? 6 : 0
                    )
                    .opacity(active ? 1.0 : 0.0)
                    .shadow(color: .cyan.opacity(active ? 0.6 : 0.0), radius: active ? 20 : 0, x: 0, y: 0)
                    .shadow(color: .purple.opacity(active ? 0.5 : 0.0), radius: active ? 28 : 0, x: 0, y: 0)
            )
    }
}

private extension View {
    func neonGlowBorder(active: Bool, cornerRadius: CGFloat = 16) -> some View {
        modifier(NeonGlowBorder(active: active, cornerRadius: cornerRadius))
    }

    func retroFocusScale(active: Bool) -> some View {
        self
            .scaleEffect(active ? 1.10 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.0), value: active)
    }
}

// MARK: - Clean Game Card Implementation
// All game card logic is now inline in GameGridItem for better control

final class TVLibraryViewModel: ObservableObject {
    /// Backing collection of games shown in the grid
    @Published var games: [TVGameItem] = []
    /// Indicates whether a metadata rescan is in progress
    @Published var isRescanning: Bool = false
    /// Ensures the initial metadata kick-off runs once
    @Published var didKickoffInitialMetadata: Bool = false
    /// Holds a pending selection when a game is already running
    @Published var pendingSelection: TVGameItem?
    /// Controls the replace-running-game confirmation dialog
    @Published var showReplaceAlert: Bool = false
    /// The currently running or most recently launched game
    @Published var currentGame: TVGameItem?

    /// Loads the current game list from the bridge
    func load() {
        games = TVLibraryBridge.currentGames()
    }

    /// Initiates a rescan and metadata fetch, then reloads the list
    func rescan() {
        guard !isRescanning else { return }
        isRescanning = true
        TVLibraryBridge.rescanAndFetchMetadata { [weak self] in
            DispatchQueue.main.async {
                self?.isRescanning = false
                self?.load()
            }
        }
    }

    /// Triggers metadata fetch on first appearance to populate artwork
    func kickoffInitialMetadataIfNeeded() {
        guard !didKickoffInitialMetadata, !isRescanning else { return }
        // Trigger metadata fetch so covers are populated on first launch
        didKickoffInitialMetadata = true
        rescan()
    }

    func loadGameCubeMainMenu() {
        TVLibraryBridge.loadGameCubeMainMenu()
    }

    func performOnlineSystemUpdate() {
        TVLibraryBridge.performOnlineSystemUpdate()
    }
}

struct TVLibraryView: View {

    @StateObject private var model = TVLibraryViewModel()
    @State private var showSettings = false
    @State private var didReloadOnce = false
    @State private var navigateTo: TVGameItem?
    @State private var showMoreMenu = false
    @State private var showUpdateRegions = false
    /// Game to present in the SwiftUI properties sheet
    @State private var showPropertiesFor: TVGameItem?
    /// Game pending deletion confirmation
    @State private var itemPendingDelete: TVGameItem?
    /// Cheat input modal state
    @State private var cheatInputFor: (item: TVGameItem, type: CheatType)?
    @State private var cheatName: String = ""
    @State private var cheatCreator: String = ""
    @State private var cheatBody: String = ""
    @State private var cheatNotes: String = ""
    @State private var showCheatError: String?
    /// Cheat list modal state
    @State private var showCheatListFor: TVGameItem?
    #if os(tvOS)
    /// Currently focused game's file path to drive zIndex and animations
    @State private var focusedFilePath: String?
    #endif

    private enum CheatType { case gecko, ar }

    private enum Constants {
        static let gridVerticalSpacing: CGFloat = 32
        static let gridHorizontalSpacing: CGFloat = 48
        static let gridNumberOfColumns = 6
        static let gridHorizontalPadding: CGFloat = 64
        static let gridVerticalPadding: CGFloat = 80  // Increased for focus scale effect
        static var columns: [GridItem] {
            let count = gridNumberOfColumns
            // Wider horizontal spacing for improved focus separation on tvOS
            return Array(repeating: GridItem(.flexible(), spacing: gridHorizontalSpacing), count: count)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            if model.games.isEmpty {
                emptyLibraryView
            } else {
                libraryView
            }
        }
    }

    @ViewBuilder
    private var libraryView: some View {
        ScrollView {
            LazyVGrid(columns: Constants.columns, spacing: Constants.gridVerticalSpacing) {
                ForEach(model.games, id: \.filePath) { item in
                    GameGridItem(item: item, select: selectGame, focusedFilePath: $focusedFilePath)
                    #if os(tvOS)
                    // Long-press context menu for tvOS
                    .contextMenu {
                        Button(L("Properties")) { showPropertiesFor = item }
                        Menu(L("Cheats")) {
                            Button(L("Manage...")) { showCheatListFor = item }
                            Button(L("Download Codes")) { downloadGecko(for: item) }
                            Divider()
                            Menu(L("Gecko")) {
                                Button(L("Add...")) { presentCheatInput(for: item, type: .gecko) }
                            }
                            Menu(L("Action Replay")) {
                                Button(L("Add...")) { presentCheatInput(for: item, type: .ar) }
                            }
                        }
                        Button(role: .destructive) { itemPendingDelete = item } label: { Text(L("Delete")) }
                    }
                    #endif
                }
            }
            .padding(.horizontal, Constants.gridHorizontalPadding)
            .padding(.vertical, Constants.gridVerticalPadding)
        }
    }

    @ViewBuilder
    private var emptyLibraryView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(L("No games found. Add ROMs to your library."))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        #if os(tvOS)
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showMoreMenu = true } label: { Image(systemName: "ellipsis.circle") }
                .buttonStyle(.automatic)
                .focusable(true)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { model.rescan() }) {
                if model.isRescanning { ProgressView() } else { Label(L("Rescan"), systemImage: "arrow.clockwise") }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showSettings = true }) { Image(systemName: "gearshape") }
        }
        #else
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button(L("Load GameCube Main Menu")) { model.loadGameCubeMainMenu() }
                Button(L("Perform Online System Update")) { model.performOnlineSystemUpdate() }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { model.rescan() }) {
                if model.isRescanning { ProgressView() } else { Label(L("Rescan"), systemImage: "arrow.clockwise") }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showSettings = true }) { Image(systemName: "gearshape") }
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            mainContent
            .navigationDestination(item: $navigateTo) { item in
                EmulationScreen(game: item)
                .onAppear {
                    NSLog("[INPUT] NavigationDestination -> EmulationScreen for game: %@", item.title)
                }
            }
            .navigationTitle("DolphiniOS Library")
            .toolbar { libraryToolbar }
        }
        .onAppear {
            model.load()
            // Ensure artwork populates on first launch without manual reload
            model.kickoffInitialMetadataIfNeeded()
            if !didReloadOnce {
                didReloadOnce = true
                // Perform a second load after the view has fully appeared
                DispatchQueue.main.async {
                    model.load()
                }
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            TVSettingsPage()
                .interactiveDismissDisabled(true)
        }
        #if os(tvOS)
        .confirmationDialog(L("More"), isPresented: $showMoreMenu, titleVisibility: .visible) {
            Button(L("Load GameCube Main Menu")) { model.loadGameCubeMainMenu() }
            Button(L("Perform Online System Update")) { showUpdateRegions = true }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("Select Region"), isPresented: $showUpdateRegions, titleVisibility: .visible) {
            Button(L("Europe")) { TVLibraryBridge.performOnlineSystemUpdate(withRegion: "EUR") }
            Button(L("Japan")) { TVLibraryBridge.performOnlineSystemUpdate(withRegion: "JPN") }
            Button(L("Korea")) { TVLibraryBridge.performOnlineSystemUpdate(withRegion: "KOR") }
            Button(L("United States")) { TVLibraryBridge.performOnlineSystemUpdate(withRegion: "USA") }
            Button(L("Cancel"), role: .cancel) {}
        }
        #endif
        .confirmationDialog(L("A game is already running."), isPresented: $model.showReplaceAlert, titleVisibility: .visible) {
            Button(L("Replace Game"), role: .destructive) {
                TVEmulationBridge.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let item = model.pendingSelection {
                        model.currentGame = item
                        navigateTo = item
                    }
                }
            }
            Button(L("Continue Current Game"), role: .cancel) {
                // Navigate back to the currently running game
                if let current = model.currentGame {
                    navigateTo = current
                }
            }
            Button(L("Cancel")) { /* do nothing; stay on library */ }
        } message: {
            Text(L("Do you want to stop the current game and launch the new one?"))
        }
        /// SwiftUI properties sheet
        .sheet(isPresented: Binding(get: { showPropertiesFor != nil }, set: { if !$0 { showPropertiesFor = nil } })) {
            if let item = showPropertiesFor {
                TVSoftwarePropertiesView(item: item)
            }
        }
        /// Cheat editor sheet (simple input)
        .sheet(isPresented: Binding(get: { cheatInputFor != nil }, set: { if !$0 { cheatInputFor = nil } })) {
            if let ctx = cheatInputFor {
                NavigationStack {
                    Form {
                        Section(L("Details")) {
                            TextField(L("Name"), text: $cheatName)
                            if ctx.type == .gecko { TextField(L("Creator"), text: $cheatCreator) }
                        }
                        Section(L("Code")) {
                            #if os(tvOS)
                            TVMultilineTextView(text: $cheatBody)
                                .frame(minHeight: 180)
                            #else
                            TextEditor(text: $cheatBody)
                                .frame(minHeight: 180)
                            #endif
                        }
                        if ctx.type == .gecko {
                            Section(L("Notes")) {
                                #if os(tvOS)
                                TVMultilineTextView(text: $cheatNotes)
                                    .frame(minHeight: 120)
                                #else
                                TextEditor(text: $cheatNotes)
                                    .frame(minHeight: 120)
                                #endif
                            }
                        }
                        if let err = showCheatError { Text(err).foregroundStyle(.red) }
                    }
                    .navigationTitle(ctx.type == .gecko ? L("Add Gecko Code") : L("Add AR Code"))
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button(L("Cancel")) { cheatInputFor = nil } }
                        ToolbarItem(placement: .topBarTrailing) { Button(L("Save")) { saveCheat(ctx) } }
                    }
                }
            }
        }
        /// Cheat list sheet
        .sheet(isPresented: Binding(get: { showCheatListFor != nil }, set: { if !$0 { showCheatListFor = nil } })) {
            if let item = showCheatListFor {
                TVCheatListView(item: item)
            }
        }
        /// Delete confirmation and action
        .alert(L("Delete Game?"), isPresented: Binding(get: { itemPendingDelete != nil }, set: { if !$0 { itemPendingDelete = nil } })) {
            Button(L("Delete"), role: .destructive) {
                if let toDelete = itemPendingDelete {
                    /// Delete the ROM and refresh cache
                    try? FileManager.default.removeItem(atPath: toDelete.filePath)
                    itemPendingDelete = nil
                    model.rescan()
                }
            }
            Button(L("Cancel"), role: .cancel) {
                itemPendingDelete = nil
            }
        } message: {
            if let item = itemPendingDelete {
                Text(L("This will delete \(item.title). This action cannot be undone."))
            }
        }
    }

    #if os(tvOS)
    private func downloadGecko(for item: TVGameItem) {
        TVCheatsBridge.downloadGeckoCodes(forGameId: item.gameID, revision: item.revision, gametdbId: item.gametdbID) { success, _, _ in
            if !success {
                showCheatError = L("Failed to download Gecko codes.")
            }
        }
    }
    #endif

    private func presentCheatInput(for item: TVGameItem, type: CheatType) {
        cheatName = ""
        cheatCreator = ""
        cheatBody = ""
        cheatNotes = ""
        cheatInputFor = (item, type)
        showCheatError = nil
    }

    private func saveCheat(_ ctx: (item: TVGameItem, type: CheatType)) {
        #if os(tvOS)
        if ctx.type == .gecko {
            if !TVCheatsBridge.addGeckoCode(forGameId: ctx.item.gameID, revision: ctx.item.revision, name: cheatName, creator: cheatCreator, codeText: cheatBody, notesText: cheatNotes) {
                showCheatError = L("Failed to add Gecko code")
                return
            }
        } else {
            if !TVCheatsBridge.addActionReplayCode(forGameId: ctx.item.gameID, revision: ctx.item.revision, name: cheatName, codeText: cheatBody) {
                showCheatError = L("Failed to add AR code")
                return
            }
        }
        cheatInputFor = nil
        #endif
    }

    private func selectGame(_ item: TVGameItem) {
        if TVEmulationBridge.isRunning() {
            model.pendingSelection = item
            model.showReplaceAlert = true
        } else {
            NSLog("[INPUT] TVLibraryView selecting game: %@", item.title)
            model.currentGame = item
            NSLog("[INPUT] TVLibraryView setting navigateTo")
            navigateTo = item
        }
    }
}

// MARK: - Game Grid Item with Focus Management

private struct GameGridItem: View {
    let item: TVGameItem
    let select: (TVGameItem) -> Void
    @Binding var focusedFilePath: String?

    #if os(tvOS)
    @State private var isFocused: Bool = false
    #endif

    var body: some View {
        #if os(tvOS)
        // Clean, simple approach for tvOS
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                // Game artwork with perfect rendering
                Image(uiImage: item.coverImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 260, height: 390)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        // Beautiful neon glow when focused
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.cyan.opacity(0.9), Color.purple.opacity(0.9)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: isFocused ? 6 : 0
                            )
                            .shadow(color: .cyan.opacity(isFocused ? 0.6 : 0), radius: isFocused ? 20 : 0)
                            .shadow(color: .purple.opacity(isFocused ? 0.5 : 0), radius: isFocused ? 28 : 0)
                    )
                    .shadow(
                        color: .black.opacity(isFocused ? 0.4 : 0.2),
                        radius: isFocused ? 20 : 8,
                        x: 0,
                        y: isFocused ? 12 : 6
                    )

                // Subtle gradient sheen
                if isFocused {
                    VStack {
                        LinearGradient(
                            colors: [Color.white.opacity(0.2), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                        Spacer()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(width: 260, height: 390)
                    .allowsHitTesting(false)
                }
            }

            // Game title and ID
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundColor(.primary)

                Text(item.gameID)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 260)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isFocused)
        .focusable(true) { focused in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isFocused = focused
                if focused {
                    focusedFilePath = item.filePath
                } else if focusedFilePath == item.filePath {
                    focusedFilePath = nil
                }
            }
        }
        .onTapGesture { select(item) }
        .onPlayPauseCommand { select(item) }
        .zIndex(isFocused ? 1 : 0)
        #else
        // Simple button for iOS
        Button(action: { select(item) }) {
            VStack(alignment: .leading, spacing: 12) {
                Image(uiImage: item.coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 260, height: 390)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(item.gameID)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 260)
        }
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Unified Game Card
// Both iOS and tvOS now use the same clean implementation in GameGridItem
