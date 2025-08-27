import SwiftUI
import UIKit

// MARK: - Retro UI Helpers

extension TVGameItem: Identifiable {}

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
    /// Grouped items by deduplication key
    @Published var groupsByKey: [String: [TVGameItem]] = [:]

    /// Loads the current game list from the bridge
    func load() {
        let items = TVLibraryBridge.currentGames()
        print("TVLibraryViewModel.load(): got \(items.count) items from bridge")
        for (index, item) in items.enumerated() {
            let isRemote = TVLibraryView.isRemoteURL(item.filePath)
            print("  [\(index)]: \(item.title) - \(isRemote ? "REMOTE" : "LOCAL") - \(item.filePath)")
        }
        groupAndDedup(items: items)
        print("TVLibraryViewModel.load(): after dedup, showing \(games.count) games")
    }

    /// Initiates a rescan and metadata fetch, then reloads the list
    func rescan() {
        guard !isRescanning else { return }
        isRescanning = true

        // Trigger refresh of remote sources first
        NotificationCenter.default.post(name: NSNotification.Name("RefreshRemoteSources"), object: nil)

        // Perform local rescan and fetch metadata
        TVLibraryBridge.rescanAndFetchMetadata { [weak self] in
            DispatchQueue.main.async {
                self?.isRescanning = false
                // Reload after both local and remote sources are updated
                self?.load()
            }
        }
    }

    /// Triggers metadata fetch on first appearance to populate artwork
    func kickoffInitialMetadataIfNeeded() {
        guard !didKickoffInitialMetadata, !isRescanning else { return }
        didKickoffInitialMetadata = true
        rescan()
    }

    func loadGameCubeMainMenu() {
        TVLibraryBridge.loadGameCubeMainMenu()
    }

    func performOnlineSystemUpdate() {
        TVLibraryBridge.performOnlineSystemUpdate()
    }

    private func isLocal(_ item: TVGameItem) -> Bool {
        if let scheme = URL(string: item.filePath)?.scheme?.lowercased() { return scheme == "file" }
        return item.filePath.hasPrefix("/")
    }

    private func key(for item: TVGameItem) -> String {
        // Use filePath as fallback when gameID is empty (common for remote games still being processed)
        let gameID = item.gameID.isEmpty ? item.filePath : item.gameID
        return "\(gameID)|\(item.discNumber)|\(item.revision)"
    }

    private func groupAndDedup(items: [TVGameItem]) {
        print("TVLibraryViewModel.groupAndDedup(): processing \(items.count) items")
        var grouped: [String: [TVGameItem]] = [:]
        for it in items {
            let itemKey = key(for: it)
            let isRemote = !isLocal(it)
            print("  Item: '\(it.title)' -> Key: '\(itemKey)' (gameID: '\(it.gameID)', discNumber: \(it.discNumber), revision: \(it.revision), isRemote: \(isRemote), titleEmpty: \(it.title.isEmpty))")
            grouped[itemKey, default: []].append(it)
        }
        print("TVLibraryViewModel.groupAndDedup(): created \(grouped.count) groups")
        groupsByKey = grouped
        var representatives: [TVGameItem] = []
        for (groupKey, group) in grouped {
            print("  Group '\(groupKey)': \(group.count) items")
            for (idx, item) in group.enumerated() {
                print("    [\(idx)]: '\(item.title)' (isLocal: \(isLocal(item)), titleEmpty: \(item.title.isEmpty))")
            }
            if let local = group.first(where: { isLocal($0) }) {
                print("    -> Using local representative: '\(local.title)'")
                representatives.append(local)
            } else if let any = group.first {
                print("    -> Using first representative: '\(any.title)' (titleEmpty: \(any.title.isEmpty))")
                representatives.append(any)
            } else {
                print("    -> No representative found (empty group)")
            }
        }
        print("TVLibraryViewModel.groupAndDedup(): found \(representatives.count) representatives")

        // Filter out items with empty titles before sorting
        let validRepresentatives = representatives.filter { !$0.title.isEmpty }
        print("TVLibraryViewModel.groupAndDedup(): after filtering empty titles: \(validRepresentatives.count) valid representatives")

        // Sort games alphabetically by title
        games = validRepresentatives.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        print("TVLibraryViewModel.groupAndDedup(): final games count: \(games.count)")
    }

    func sources(for item: TVGameItem) -> [TVGameItem] {
        groupsByKey[key(for: item)] ?? [item]
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
    @State private var showSources = false
    /// Source picker modal state
    @State private var sourcePickerItems: [TVGameItem]? = nil
    /// Auto pre-cache progress state
    @State private var autoPreCacheProgress: [String: Double] = [:]
    @State private var autoPreCacheActive: Set<String> = []

    private enum CheatType { case gecko, ar }

    /// Helper function to check if a URL is a remote URL (HTTP/HTTPS/WebDAV)
    static func isRemoteURL(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.hasPrefix("http://") ||
               lower.hasPrefix("https://") ||
               lower.hasPrefix("webdav://") ||
               lower.hasPrefix("webdavs://")
    }

    private enum Constants {
        static let gridVerticalSpacing: CGFloat = 32
        static let gridHorizontalSpacing: CGFloat = 48
        static let gridNumberOfColumns = 6
        static let gridHorizontalPadding: CGFloat = 64
        static let gridVerticalPadding: CGFloat = 80  // Increased for focus scale effect
        static var columns: [GridItem] {
            let count = gridNumberOfColumns
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
                    GameGridItem(
                        item: item,
                        select: selectGame,
                        focusedFilePath: $focusedFilePath,
                        showProperties: { showPropertiesFor = $0 },
                        showCheatList: { showCheatListFor = $0 },
                        downloadGeckoAction: { downloadGecko(for: $0) },
                        presentCheatGecko: { presentCheatInput(for: $0, type: .gecko) },
                        presentCheatAR: { presentCheatInput(for: $0, type: .ar) },
                        requestDelete: { itemPendingDelete = $0 },
                        autoPreCacheProgress: autoPreCacheProgress[item.filePath] ?? 0.0,
                        isAutoPreCaching: autoPreCacheActive.contains(item.filePath)
                    )
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
                if model.isRescanning { ProgressView() } else { Label("", systemImage: "arrow.clockwise") }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showSources = true }) { Image(systemName: "externaldrive.badge.plus") }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showSettings = true }) { Image(systemName: "gearshape") }
        }
        #else
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button(L("Load GameCube Main Menu")) { model.loadGameCubeMainMenu() }
                Button(L("Perform Online System Update")) { model.performOnlineSystemUpdate() }
                Button(L("Sources")) { showSources = true }
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
                .onAppear { NSLog("[INPUT] NavigationDestination -> EmulationScreen for game: %@", item.title) }
            }
            .navigationTitle("DolphiniOS Library")
            .toolbar { libraryToolbar }
        }
        .onAppear {
            // Initialize shared remote sources store to start querying immediately
            print("TVLibraryView: initializing RemoteSourcesStore.shared")
            let store = RemoteSourcesStore.shared
            print("TVLibraryView: RemoteSourcesStore has \(store.sources.count) sources")

            // Force a refresh of remote sources to ensure they start
            print("TVLibraryView: posting RefreshRemoteSources notification")
            NotificationCenter.default.post(name: NSNotification.Name("RefreshRemoteSources"), object: nil)

            model.load()
            model.kickoffInitialMetadataIfNeeded()
            if !didReloadOnce {
                didReloadOnce = true
                DispatchQueue.main.async { model.load() }
            }

            // Listen for remote library updates
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("RemoteLibraryUpdated"),
                object: nil,
                queue: .main
            ) { _ in
                print("TVLibraryView: received RemoteLibraryUpdated notification, reloading library")
                model.load()
                print("TVLibraryView: after reload, library has \(model.games.count) games")
            }
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
        }
        .fullScreenCover(isPresented: $showSettings) { TVSettingsPage().interactiveDismissDisabled(true) }
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
            Button(L("Continue Current Game"), role: .cancel) { if let current = model.currentGame { navigateTo = current } }
            Button(L("Cancel")) { }
        } message: { Text(L("Do you want to stop the current game and launch the new one?")) }
        .sheet(item: $showPropertiesFor) { TVSoftwarePropertiesView(item: $0) }
        .sheet(item: $showCheatListFor) { TVCheatListView(item: $0) }
        .sheet(isPresented: Binding(get: { sourcePickerItems != nil }, set: { if !$0 { sourcePickerItems = nil } })) {
            if let items = sourcePickerItems {
                SourcePickerView(items: items) { chosen in
                    sourcePickerItems = nil
                    launchGame(chosen)
                }
            }
        }
        // Sources sheet
        .sheet(isPresented: $showSources) { SourcesView() }
        /// Delete confirmation and action
        .alert(L("Delete Game?"), isPresented: Binding(get: { itemPendingDelete != nil }, set: { if !$0 { itemPendingDelete = nil } })) {
            Button(L("Delete"), role: .destructive) {
                if let toDelete = itemPendingDelete {
                    try? FileManager.default.removeItem(atPath: toDelete.filePath)
                    itemPendingDelete = nil
                    model.rescan()
                }
            }
            Button(L("Cancel"), role: .cancel) { itemPendingDelete = nil }
        } message: { if let item = itemPendingDelete { Text(L("This will delete \(item.title). This action cannot be undone.")) } }
    }

    #if os(tvOS)
    private func downloadGecko(for item: TVGameItem) {
        TVCheatsBridge.downloadGeckoCodes(forGameId: item.gameID, revision: item.revision, gametdbId: item.gametdbID) { success, _, _ in
            if !success { showCheatError = L("Failed to download Gecko codes.") }
        }
    }
    #endif

    private func presentCheatInput(for item: TVGameItem, type: CheatType) {
        cheatName = ""; cheatCreator = ""; cheatBody = ""; cheatNotes = ""
        cheatInputFor = (item, type); showCheatError = nil
    }

    private func saveCheat(_ ctx: (item: TVGameItem, type: CheatType)) {
        #if os(tvOS)
        if ctx.type == .gecko {
            if !TVCheatsBridge.addGeckoCode(forGameId: ctx.item.gameID, revision: ctx.item.revision, name: cheatName, creator: cheatCreator, codeText: cheatBody, notesText: cheatNotes) { showCheatError = L("Failed to add Gecko code"); return }
        } else {
            if !TVCheatsBridge.addActionReplayCode(forGameId: ctx.item.gameID, revision: ctx.item.revision, name: cheatName, codeText: cheatBody) { showCheatError = L("Failed to add AR code"); return }
        }
        cheatInputFor = nil
        #endif
    }

    private func selectGame(_ item: TVGameItem) {
        let sources = model.sources(for: item)
        if sources.count > 1 {
            sourcePickerItems = sources
            return
        }
        launchGame(item)
    }

    private func launchGame(_ item: TVGameItem) {
        if TVEmulationBridge.isRunning() {
            model.pendingSelection = item
            model.showReplaceAlert = true
        } else {
            NSLog("[INPUT] TVLibraryView selecting game: %@", item.title)

            // Auto pre-cache if enabled and not already cached
            if let url = URL(string: item.filePath),
               Self.isRemoteURL(item.filePath) {
                // This is a remote game - check for auto pre-caching
                for source in RemoteSourcesStore.shared.sources {
                    if let webdavSource = source as? WebDAVSource,
                       webdavSource.isPreCachingEnabled {
                        // Start background pre-caching with progress tracking
                        let gameKey = item.filePath
                        autoPreCacheActive.insert(gameKey)
                        autoPreCacheProgress[gameKey] = 0.0

                        Task {
                            do {
                                // Use the file size from TVGameItem (which comes from WebDAV PROPFIND)
                                let fileSize = Int64(item.fileSize)
                                let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: fileSize)

                                // Check if already cached with correct size
                                if !webdavSource.isCached(remoteItem) {
                                    let _ = try await webdavSource.preCacheItem(remoteItem) { progress in
                                        DispatchQueue.main.async {
                                            autoPreCacheProgress[gameKey] = progress
                                        }
                                    }
                                }
                                DispatchQueue.main.async {
                                    autoPreCacheActive.remove(gameKey)
                                    autoPreCacheProgress.removeValue(forKey: gameKey)
                                }
                            } catch {
                                print("Auto pre-cache failed: \(error)")
                                DispatchQueue.main.async {
                                    autoPreCacheActive.remove(gameKey)
                                    autoPreCacheProgress.removeValue(forKey: gameKey)
                                }
                            }
                        }
                        break
                    }
                }
            }

            model.currentGame = item
            navigateTo = item
        }
    }
}

// MARK: - Game Grid Item with Focus Management

private struct GameGridItem: View {
    let item: TVGameItem
    let select: (TVGameItem) -> Void
    @Binding var focusedFilePath: String?

    // Context menu action closures provided by parent view
    let showProperties: (TVGameItem) -> Void
    let showCheatList: (TVGameItem) -> Void
    let downloadGeckoAction: (TVGameItem) -> Void
    let presentCheatGecko: (TVGameItem) -> Void
    let presentCheatAR: (TVGameItem) -> Void
    let requestDelete: (TVGameItem) -> Void
    let autoPreCacheProgress: Double
    let isAutoPreCaching: Bool

    @State private var showPreCacheProgress = false
    @State private var preCacheProgress: Double = 0.0
    @State private var isPreCaching = false

    #if os(tvOS)
    @State private var isFocused: Bool = false
    #endif

    /// Determines remote source type and appropriate icon
    private var remoteIconName: String? {
        guard let url = URL(string: item.filePath), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "webdav", "webdavs": return "externaldrive"
        case "http", "https": return "cloud"
        default: return nil
        }
    }

    /// Check if this is a remote game
    private var isRemoteGame: Bool {
        let result = remoteIconName != nil
        print("DEBUG: isRemoteGame for '\(item.title)' (path: '\(item.filePath)') = \(result)")
        return result
    }

    /// Get the WebDAV source for this game (if any)
    private func getWebDAVSource() -> WebDAVSource? {
        guard isRemoteGame, let url = URL(string: item.filePath) else {
            print("DEBUG: getWebDAVSource early return - isRemoteGame: \(isRemoteGame), url valid: \(URL(string: item.filePath) != nil)")
            return nil
        }

        func defaultPort(for scheme: String?) -> Int {
            switch (scheme?.lowercased()) {
            case "https", "webdavs": return 443
            default: return 80
            }
        }

        guard let urlHost = url.host?.lowercased() else {
            print("DEBUG: getWebDAVSource no host for URL: \(url)")
            return nil
        }
        let urlPort = url.port ?? defaultPort(for: url.scheme)
        let urlPath = url.path

        print("DEBUG: Looking for WebDAV source matching host: \(urlHost), port: \(urlPort), path: \(urlPath)")
        print("DEBUG: Available sources: \(RemoteSourcesStore.shared.sources.count)")

        var bestMatch: (source: WebDAVSource, score: Int)? = nil

        for (index, source) in RemoteSourcesStore.shared.sources.enumerated() {
            print("DEBUG: Source \(index): \(type(of: source))")
            guard let webdavSource = source as? WebDAVSource else { continue }
            let base = webdavSource.baseURL
            print("DEBUG: WebDAV source base URL: \(base)")
            guard let baseHost = base.host?.lowercased() else { continue }
            let basePort = base.port ?? defaultPort(for: base.scheme)
            print("DEBUG: Comparing - base host: \(baseHost), port: \(basePort) vs url host: \(urlHost), port: \(urlPort)")
            guard urlHost == baseHost && urlPort == basePort else { continue }

            // Prefer the source with the longest base path prefix match
            let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
            let score: Int
            if basePath == "/" { score = 1 }
            else if urlPath.hasPrefix(basePath) { score = max(2, basePath.count) }
            else { score = 1 } // host/port match only

            print("DEBUG: Found matching source with score \(score), basePath: '\(basePath)', isPreCachingEnabled: \(webdavSource.isPreCachingEnabled)")
            if bestMatch == nil || score > bestMatch!.score {
                bestMatch = (webdavSource, score)
            }
        }

        let result = bestMatch?.source
        print("DEBUG: getWebDAVSource result: \(result != nil ? "found" : "nil"), final isPreCachingEnabled: \(result?.isPreCachingEnabled ?? false)")
        return result
    }

    /// Check if this remote game is cached locally
    private var isCached: Bool {
        guard let source = getWebDAVSource(),
              let url = URL(string: item.filePath) else { return false }

        let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: 0)
        return source.isCached(remoteItem)
    }

    var body: some View {
        #if os(tvOS)
        // Clean, simple approach for tvOS
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: item.coverImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 260, height: 390)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
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

                if isFocused {
                    VStack { LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center); Spacer() }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(width: 260, height: 390)
                        .allowsHitTesting(false)
                }

                if let icon = remoteIconName {
                    ZStack {
                        if isPreCaching {
                            // Show manual pre-cache progress indicator
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 2)
                                .frame(width: 24, height: 24)

                            Circle()
                                .trim(from: 0, to: preCacheProgress)
                                .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .frame(width: 24, height: 24)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.2), value: preCacheProgress)

                            Image(systemName: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)

                            // Show checkmark if cached
                            if isCached {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.green)
                                    .background(Color.white, in: Circle())
                                    .offset(x: 8, y: -8)
                            }
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundColor(.primary)

                HStack {
                    Text(item.gameID)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    // Auto pre-cache progress indicator
                    if isAutoPreCaching {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("\(Int(autoPreCacheProgress * 100))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .frame(width: 260)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isFocused)
        .focusable(true) { focused in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isFocused = focused
                if focused { focusedFilePath = item.filePath } else if focusedFilePath == item.filePath { focusedFilePath = nil }
            }
        }
        .onTapGesture { select(item) }
        .onPlayPauseCommand { select(item) }
        .contextMenu {
            Button(L("Properties")) { showProperties(item) }
            Menu(L("Cheats")) {
                Button(L("Manage...")) { showCheatList(item) }
                Button(L("Download Codes")) { downloadGeckoAction(item) }
                Divider()
                Menu(L("Gecko")) { Button(L("Add...")) { presentCheatGecko(item) } }
                Menu(L("Action Replay")) { Button(L("Add...")) { presentCheatAR(item) } }
            }
            if isRemoteGame {
                if let source = getWebDAVSource() {
                    if isCached {
                        Button(action: { removeCachedFile() }) {
                            Label(L("Remove from Cache"), systemImage: "trash")
                        }
                        Button(action: { /* Show cache info */ }) {
                            Label(L("Cache Info"), systemImage: "info.circle")
                        }
                    } else {
                        Button(action: { startPreCache() }) {
                            Label(L("Download to Cache"), systemImage: "arrow.down.circle")
                        }
                        .disabled(isPreCaching)

                        if isPreCaching {
                            Button(action: { cancelPreCache() }) {
                                Label(L("Cancel Download"), systemImage: "xmark.circle")
                            }
                        }
                    }
                } else {
                    Label(L("Remote Source Unavailable"), systemImage: "icloud.slash").disabled(true)
                }
            }
            Button(role: .destructive) { requestDelete(item) } label: { Text(L("Delete")) }
        }
        .zIndex(isFocused ? 1 : 0)
        #else
        Button(action: { select(item) }) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: item.coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 260, height: 390)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if let icon = remoteIconName {
                        ZStack {
                            if isPreCaching {
                                // Show progress indicator
                                Circle()
                                    .stroke(Color.white.opacity(0.3), lineWidth: 2)
                                    .frame(width: 20, height: 20)

                                Circle()
                                    .trim(from: 0, to: preCacheProgress)
                                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .frame(width: 20, height: 20)
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.2), value: preCacheProgress)

                                Image(systemName: "arrow.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white)
                            } else {
                                Image(systemName: icon)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)

                                // Show checkmark if cached
                                if isCached {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.green)
                                        .background(Color.white, in: Circle())
                                        .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(8)
                    }
                }

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
        .contextMenu {
            if isRemoteGame, let source = getWebDAVSource(), source.isPreCachingEnabled {
                Button(action: { startPreCache() }) {
                    Label("Download to Cache", systemImage: "arrow.down.circle")
                }
                .disabled(isPreCaching)

                if isPreCaching {
                    Button(action: { cancelPreCache() }) {
                        Label("Cancel Download", systemImage: "xmark.circle")
                    }
                }
            }
        }
        #endif
    }

    // MARK: - Pre-cache Methods

    private func startPreCache() {
        guard let source = getWebDAVSource(),
              let url = URL(string: item.filePath) else { return }

        isPreCaching = true
        preCacheProgress = 0.0
        showPreCacheProgress = true

        Task {
            do {
                // Use the file size from TVGameItem (which comes from WebDAV PROPFIND)
                let fileSize = Int64(item.fileSize)
                print("Using cached file size for \(item.title): \(fileSize) bytes")
                print("DEBUG: TVGameItem.fileSize = \(item.fileSize)")

                // Check available storage space
                let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let resourceValues = try cachesURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                let availableSpace = resourceValues.volumeAvailableCapacity ?? 0

                print("DEBUG: Available storage space: \(availableSpace) bytes")
                print("DEBUG: Required space: \(fileSize) bytes")

                if availableSpace < fileSize {
                    throw NSError(domain: "WebDAVSource", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Not enough storage space. Available: \(ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)), Required: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))"])
                }

                // Create RemoteLibraryItem with correct size
                let remoteItem = RemoteLibraryItem(
                    url: url,
                    name: item.title,
                    size: fileSize
                )

                let _ = try await source.preCacheItem(remoteItem) { progress in
                    DispatchQueue.main.async {
                        self.preCacheProgress = progress
                    }
                }

                DispatchQueue.main.async {
                    self.isPreCaching = false
                    self.showPreCacheProgress = false
                    print("Pre-cache completed for: \(self.item.title)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isPreCaching = false
                    self.showPreCacheProgress = false
                    print("Pre-cache failed for \(self.item.title): \(error)")
                }
            }
        }
    }

    private func cancelPreCache() {
        guard let source = getWebDAVSource(),
              let url = URL(string: item.filePath) else { return }

        let remoteItem = RemoteLibraryItem(
            url: url,
            name: item.title,
            size: 0
        )

        Task {
            await source.cancelPreCache(remoteItem)
            DispatchQueue.main.async {
                self.isPreCaching = false
                self.showPreCacheProgress = false
            }
        }
    }

    private func removeCachedFile() {
        guard let source = getWebDAVSource(),
              let url = URL(string: item.filePath) else { return }

        let remoteItem = RemoteLibraryItem(
            url: url,
            name: item.title,
            size: 0
        )

        Task {
          do {
            try await source.removeCachedItem(remoteItem)
            // The UI will automatically update when isCached changes
          } catch {
            print("Error: \(error.localizedDescription)")
          }
        }
    }
}

// MARK: - Source Picker

private struct SourcePickerView: View {
    let items: [TVGameItem]
    let onPick: (TVGameItem) -> Void

    private func label(for item: TVGameItem) -> String {
        if let scheme = URL(string: item.filePath)?.scheme?.lowercased() {
            switch scheme {
            case "file": return L("Local")
            case "webdav", "webdavs":
                let host = URL(string: item.filePath)?.host ?? "WebDAV"
                return "WebDAV — \(host)"
            case "http", "https":
                let host = URL(string: item.filePath)?.host ?? "HTTP"
                return "HTTP — \(host)"
            default:
                return scheme.uppercased()
            }
        }
        return L("Local")
    }

    var body: some View {
        NavigationStack {
            List {
                Section(L("Choose Source")) {
                    ForEach(items, id: \.filePath) { item in
                        Button(action: { onPick(item) }) {
                            HStack {
                                Text(label(for: item))
                                Spacer()
                                Text(URL(string: item.filePath)?.lastPathComponent ?? "")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Select Source"))
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(L("Cancel")) { onPick(items[0]) } } }
        }
    }
}

// MARK: - Unified Game Card
// Both iOS and tvOS now use the same clean implementation in GameGridItem
