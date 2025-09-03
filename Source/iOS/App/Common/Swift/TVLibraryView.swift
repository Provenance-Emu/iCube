import SwiftUI
import UIKit
import GameController
import UniformTypeIdentifiers

#if os(iOS) || targetEnvironment(macCatalyst)
import UniformTypeIdentifiers
#if canImport(TipKit)
import TipKit
#endif
private struct KeyCommandHostView: UIViewRepresentable {
  let onLeft: () -> Void
  let onRight: () -> Void
  let onUp: () -> Void
  let onDown: () -> Void
  let onEnter: () -> Void
  let onSpace: () -> Void
  func makeUIView(context: Context) -> KeyInputView {
    let v = KeyInputView()
    v.onLeft = onLeft
    v.onRight = onRight
    v.onUp = onUp
    v.onDown = onDown
    v.onEnter = onEnter
    v.onSpace = onSpace
    DispatchQueue.main.async { _ = v.becomeFirstResponder() }
    return v
  }
  func updateUIView(_ uiView: KeyInputView, context: Context) { }
}

private final class KeyInputView: UIView {
  var onLeft: (() -> Void)?
  var onRight: (() -> Void)?
  var onUp: (() -> Void)?
  var onDown: (() -> Void)?
  var onEnter: (() -> Void)?
  var onSpace: (() -> Void)?
  override var canBecomeFirstResponder: Bool { true }
  override var keyCommands: [UIKeyCommand]? {
    return [
      UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)),
      UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight)),
      UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUp)),
      UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDown)),
      UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleEnter)),
      UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleSpace))
    ]
  }
  @objc private func handleLeft() { onLeft?() }
  @objc private func handleRight() { onRight?() }
  @objc private func handleUp() { onUp?() }
  @objc private func handleDown() { onDown?() }
  @objc private func handleEnter() { onEnter?() }
  @objc private func handleSpace() { onSpace?() }
}
#endif

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

    // Trigger refresh of remote sources first - they will update the cache when ready
    NotificationCenter.default.post(name: NSNotification.Name("RefreshRemoteSources"), object: nil)

    // For refresh, don't clear remote cache immediately - let WebDAV results drive updates
    // Only rescan local files to update metadata
    TVLibraryBridge.rescanLocalAndFetchMetadata { [weak self] in
      DispatchQueue.main.async {
        self?.isRescanning = false
        // Remote sources will trigger additional reloads as they complete
        self?.load()
        NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Library refreshed")])
      }
    }
  }

  /// Triggers metadata fetch on first appearance to populate artwork
  func kickoffInitialMetadataIfNeeded() {
    guard !didKickoffInitialMetadata, !isRescanning else { return }
    didKickoffInitialMetadata = true
    // On boot, preserve remote URLs while WebDAV sources are starting up
    TVLibraryBridge.rescanLocalAndFetchMetadata { [weak self] in
      DispatchQueue.main.async {
        self?.load()
      }
    }
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

    // Sort games alphabetically using fallback to filename when title is empty
    games = representatives.sorted { (a: TVGameItem, b: TVGameItem) -> Bool in
      let at: String = {
        if !a.title.isEmpty { return a.title }
        if let url = URL(string: a.filePath) { return url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent }
        return a.filePath
      }()
      let bt: String = {
        if !b.title.isEmpty { return b.title }
        if let url = URL(string: b.filePath) { return url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent }
        return b.filePath
      }()
      return at.localizedCaseInsensitiveCompare(bt) == .orderedAscending
    }
    print("TVLibraryViewModel.groupAndDedup(): final games count: \(games.count)")
  }

  func sources(for item: TVGameItem) -> [TVGameItem] {
    groupsByKey[key(for: item)] ?? [item]
  }
}

struct TVLibraryView: View {

  @Environment(\.tipsService) private var tipsService

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
  /// UIKit cheats editors
  @State private var showGeckoEditorFor: TVGameItem?
  @State private var showAREditorFor: TVGameItem?

  /// Currently focused game's file path to drive zIndex and animations
  @State private var focusedFilePath: String?

  @State private var showSources = false
  /// Source picker modal state
  @State private var sourcePickerItems: [TVGameItem]? = nil
  /// Auto pre-cache progress state
  @State private var autoPreCacheProgress: [String: Double] = [:]
  @State private var autoPreCacheActive: Set<String> = []

  /// Storage alerts
  @State private var storageAlertMessage = ""
  @State private var itemPendingLaunch: TVGameItem?

  // Navigation to Save States views
  private struct GameIDRoute: Identifiable, Hashable { let id: String }
  @State private var navigateToSaveStates: GameIDRoute?
  @State private var showSaveStatesBrowser: Bool = false

  /// Separate alert states (SwiftUI works better with simple booleans)
  @State private var showStorageErrorAlert = false
  @State private var showLowStorageWarning = false
  @State private var showCacheInfoFor: TVGameItem?
  @State private var blockingPrecacheItem: TVGameItem?
  @State private var blockingPrecacheProgress: Double = 0

  /// Search text for library filtering
  @State private var searchText: String = ""
  @State private var favoritesVersion: Int = 0

  /// Whether emulation is currently running (disables library input)
  @State private var emulationRunning = false

  /// iOS document pickers
#if os(iOS) || targetEnvironment(macCatalyst)
  @State private var showImportSoftwarePicker = false
  @State private var showImportNANDPicker = false
  /// Navigate to settings as a push on iOS
  @State private var navigateToSettings = false
  /// Controller navigation repeat throttle
  @State private var lastNavMoveTime: TimeInterval = 0
  @State private var navRepeatInterval: TimeInterval = 0.12
  @State private var emuStartObs: NSObjectProtocol?
  @State private var emuEndObs: NSObjectProtocol?
  /// Previous controller handlers to restore on teardown
  @State private var prevEGPHandlers: [ObjectIdentifier: (GCExtendedGamepad, GCControllerElement) -> Void] = [:]
  @State private var prevMGPHandlers: [ObjectIdentifier: (GCMicroGamepad, GCControllerElement) -> Void] = [:]
  /// Current grid columns (kept in state for reuse)
  @State private var gridColumnCount: Int = 3
  @State private var dropTargeted: Bool = false
  @State private var dropPreviewCount: Int = 0
#endif

  /// Storage space management
  static let STORAGE_BUFFER_MB: Int64 = 100 * 1024 * 1024 // 100MB buffer
  static let LOW_STORAGE_THRESHOLD_MB: Int64 = 100 * 1024 * 1024 // 100MB warning threshold

  /// Check available storage space
  static func getAvailableStorageSpace() -> Int64 {
    guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return 0
    }

    do {
      let resourceValues = try cachesURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
      return Int64(resourceValues.volumeAvailableCapacity ?? 0)
    } catch {
      print("Error getting storage space: \(error)")
      return 0
    }
  }

  /// Check if there's enough space for pre-caching (file size + 100MB buffer)
  static func hasEnoughSpaceForPreCache(fileSize: Int64) -> Bool {
    let availableSpace = getAvailableStorageSpace()
    let requiredSpace = fileSize + STORAGE_BUFFER_MB
    return availableSpace >= requiredSpace
  }

  /// Check if storage is critically low (< 100MB)
  static func isStorageCriticallyLow() -> Bool {
    return getAvailableStorageSpace() < LOW_STORAGE_THRESHOLD_MB
  }

  /// Format storage space for user display
  static func formatStorageSpace(_ bytes: Int64) -> String {
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

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
    static let gridVerticalSpacing: CGFloat = {
#if os(tvOS)
      return 32
#else
      return 16
#endif
    }()
    static let gridHorizontalSpacing: CGFloat = {
#if os(tvOS)
      return 48
#else
      return 12
#endif
    }()
#if os(tvOS)
    static let gridNumberOfColumns = 6
#else
    static let gridNumberOfColumns = 3
#endif
    static let gridHorizontalPadding: CGFloat = {
#if os(tvOS)
      return 64
#else
      return 24
#endif
    }()
    static let gridVerticalPadding: CGFloat = {
#if os(tvOS)
      return 80
#else
      return 24
#endif
    }()  // Increased for focus scale effect
    static var columns: [GridItem] {
      return Array(repeating: GridItem(.flexible(), spacing: gridHorizontalSpacing), count: gridNumberOfColumns)
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
    .task {
      #if canImport(TipKit)
      if #available(iOS 17, tvOS 17, *), !didReloadOnce {
        // Wait for first load to complete before showing tips
        // Simple debounce: small delay after initial load to allow UI to settle
        try? await Task.sleep(nanoseconds: 300_000_000)
      }
      #endif
    }
  }

  @ViewBuilder
  private var libraryView: some View {
    let _ = favoritesVersion
    // Shared filtered view of games for both platforms
    let displayGames: [TVGameItem] = {
      let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !q.isEmpty else { return model.games }
      let needle = q.lowercased()
      func filenameLower(_ path: String) -> String {
        if let url = URL(string: path) {
          return (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent).lowercased()
        }
        return path.lowercased()
      }
      return model.games.filter { item in
        let title = item.title.lowercased()
        if title.contains(needle) { return true }
        if filenameLower(item.filePath).contains(needle) { return true }
        if item.gameID.lowercased().contains(needle) { return true }
        if item.makerLong.lowercased().contains(needle) { return true }
        if item.countryName.lowercased().contains(needle) { return true }
        if item.gametdbID.lowercased().contains(needle) { return true }
        if item.filePath.lowercased().contains(needle) { return true }
        return false
      }
    }()
    let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

#if os(iOS) || targetEnvironment(macCatalyst)
    GeometryReader { proxy in
      let paddingH = Constants.gridHorizontalPadding
      let spacingH = Constants.gridHorizontalSpacing
      let cardW = Layout.cardSize.width
      let available = max(0, proxy.size.width - (paddingH * 2))
      let count = max(2, Int((available + spacingH) / (cardW + spacingH)))
      let columns = Array(repeating: GridItem(.flexible(), spacing: spacingH), count: count)
      ScrollViewReader { scr in
        ScrollView {
          if !isSearching, let favs = favorites(), !favs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: spacingH) {
                ForEach(favs, id: \.filePath) { fav in
                  GameGridItem(
                    item: fav,
                    select: selectGame,
                    focusedFilePath: $focusedFilePath,
                    showProperties: { showPropertiesFor = $0 },
                    showCheatList: { showCheatListFor = $0 },
                    downloadGeckoAction: { downloadGecko(for: $0) },
                    presentCheatGecko: { showGeckoEditorFor = $0 },
                    presentCheatAR: { showAREditorFor = $0 },
                    requestDelete: { itemPendingDelete = $0 },
                    showFavoriteToggle: { toggleFavorite(for: $0) },
                    showStorageAlert: { message in
                      storageAlertMessage = message
                      showStorageErrorAlert = true
                    },
                    showCacheInfo: { item in
                      showCacheInfoFor = item
                    },
                    showSaveStates: { item in
                      let gid = item.gameID
                      if !gid.isEmpty {
                        navigateToSaveStates = GameIDRoute(id: gid)
                      }
                    },
                    autoPreCacheProgress: autoPreCacheProgress[fav.filePath] ?? 0.0,
                    isAutoPreCaching: autoPreCacheActive.contains(fav.filePath)
                  )
                }
              }
              .padding(.horizontal, paddingH)
              .padding(.vertical, Constants.gridVerticalSpacing)
            }
          }
          LazyVGrid(columns: columns, spacing: Constants.gridVerticalSpacing) {
            ForEach(displayGames, id: \.filePath) { item in
              GameGridItem(
                item: item,
                select: selectGame,
                focusedFilePath: $focusedFilePath,
                showProperties: { showPropertiesFor = $0 },
                showCheatList: { showCheatListFor = $0 },
                downloadGeckoAction: { downloadGecko(for: $0) },
                presentCheatGecko: { showGeckoEditorFor = $0 },
                presentCheatAR: { showAREditorFor = $0 },
                requestDelete: { itemPendingDelete = $0 },
                showFavoriteToggle: { toggleFavorite(for: $0) },
                showStorageAlert: { message in
                  storageAlertMessage = message
                  showStorageErrorAlert = true
                },
                showCacheInfo: { item in
                  showCacheInfoFor = item
                },
                showSaveStates: { item in
                  let gid = item.gameID
                  if !gid.isEmpty {
                    navigateToSaveStates = GameIDRoute(id: gid)
                  }
                },
                autoPreCacheProgress: autoPreCacheProgress[item.filePath] ?? 0.0,
                isAutoPreCaching: autoPreCacheActive.contains(item.filePath)
              )
              .id(item.filePath)
              .overlay(
                RoundedRectangle(cornerRadius: 14)
                  .stroke(focusedFilePath == item.filePath ? Color.accentColor : Color.clear, lineWidth: 3)
              )
              .onChange(of: focusedFilePath) { _, newVal in
                if newVal == item.filePath {
                  let gen = UIImpactFeedbackGenerator(style: .light)
                  gen.impactOccurred()
                  // Auto-scroll to follow focus
                  DispatchQueue.main.async {
                    scr.scrollTo(item.filePath, anchor: .center)
                  }
                }
              }
            }
          }
          .padding(.horizontal, paddingH)
          .padding(.vertical, Constants.gridVerticalSpacing)
        }
        .background((!emulationRunning) ? AnyView(KeyCommandHostView(
          onLeft: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = max(0, idx - 1)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.first?.filePath)
          },
          onRight: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = min(displayGames.count - 1, idx + 1)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.last?.filePath)
          },
          onUp: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = max(0, idx - count)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.first?.filePath)
          },
          onDown: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = min(displayGames.count - 1, idx + count)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.last?.filePath)
          },
          onEnter: {
            if let fp = focusedFilePath, let item = displayGames.first(where: { $0.filePath == fp }) { selectGame(item) }
          },
          onSpace: {
            showSources = true
          }
        )) : AnyView(EmptyView()))
        .onAppear {
          setupControllerNavigation(columns: count)
          emuStartObs = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main) { _ in
            emulationRunning = true
            teardownControllerNavigation()
          }
          emuEndObs = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidEndNotification"), object: nil, queue: .main) { _ in emulationRunning = false }
        }
        .onReceive(ControllerManager.shared.controllerConnectedPublisher) { _ in
          ControllerStyleManager.shared.refreshDetection()
          ControllerStyleManager.shared.applyPresetDefaults()
          if !emulationRunning { setupControllerNavigation(columns: count) }
        }
        .onReceive(ControllerManager.shared.controllerDisconnectedPublisher) { _ in
          ControllerStyleManager.shared.refreshDetection()
          if !emulationRunning { setupControllerNavigation(columns: count) }
        }
        .onChange(of: displayGames.count) { _, newCount in
          if newCount > 0 && focusedFilePath == nil {
            DispatchQueue.main.async { focusedFilePath = displayGames.first?.filePath }
          }
        }
        .onDisappear {
          if let t = emuStartObs { NotificationCenter.default.removeObserver(t); emuStartObs = nil }
          if let t = emuEndObs { NotificationCenter.default.removeObserver(t); emuEndObs = nil }
          teardownControllerNavigation()
        }
        .task { gridColumnCount = count }
        .onChange(of: count) { _, newVal in gridColumnCount = newVal }
      }
    }
#else
    ScrollView {
      if !isSearching, let favs = favorites(), !favs.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Constants.gridHorizontalSpacing) {
            ForEach(favs, id: \.filePath) { fav in
              GameGridItem(
                item: fav,
                select: selectGame,
                focusedFilePath: $focusedFilePath,
                showProperties: { showPropertiesFor = $0 },
                showCheatList: { showCheatListFor = $0 },
                downloadGeckoAction: { downloadGecko(for: $0) },
                presentCheatGecko: { showGeckoEditorFor = $0 },
                presentCheatAR: { showAREditorFor = $0 },
                requestDelete: { itemPendingDelete = $0 },
                showFavoriteToggle: { toggleFavorite(for: $0) },
                showStorageAlert: { message in
                  storageAlertMessage = message
                  showStorageErrorAlert = true
                },
                showCacheInfo: { item in
                  showCacheInfoFor = item
                },
                showSaveStates: { item in
                  let gid = item.gameID
                  if !gid.isEmpty {
                    navigateToSaveStates = GameIDRoute(id: gid)
                  }
                },
                autoPreCacheProgress: autoPreCacheProgress[fav.filePath] ?? 0.0,
                isAutoPreCaching: autoPreCacheActive.contains(fav.filePath)
              )
            }
          }
        }
      }
      LazyVGrid(columns: Constants.columns, spacing: Constants.gridVerticalSpacing) {
        ForEach(displayGames, id: \.filePath) { item in
          GameGridItem(
            item: item,
            select: selectGame,
            focusedFilePath: $focusedFilePath,
            showProperties: { showPropertiesFor = $0 },
            showCheatList: { showCheatListFor = $0 },
            downloadGeckoAction: { downloadGecko(for: $0) },
            presentCheatGecko: { showGeckoEditorFor = $0 },
            presentCheatAR: { showAREditorFor = $0 },
            requestDelete: { itemPendingDelete = $0 },
            showFavoriteToggle: { toggleFavorite(for: $0) },
            showStorageAlert: { message in
              storageAlertMessage = message
              showStorageErrorAlert = true
            },
            showCacheInfo: { item in
              showCacheInfoFor = item
            },
            showSaveStates: { item in
              let gid = item.gameID
              if !gid.isEmpty {
                navigateToSaveStates = GameIDRoute(id: gid)
              }
            },
            autoPreCacheProgress: autoPreCacheProgress[item.filePath] ?? 0.0,
            isAutoPreCaching: autoPreCacheActive.contains(item.filePath)
          )
        }
      }
      .padding(.horizontal, Constants.gridHorizontalPadding)
      .padding(.vertical, Constants.gridVerticalPadding)
    }
#endif
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
      let store = RemoteSourcesStore.shared
      if store.isScanning {
        HStack(spacing: 6) {
          ProgressView(value: store.scanningProgress).frame(width: 80)
          Text("Refreshing…")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      Button(action: { model.rescan() }) {
        if model.isRescanning { ProgressView() } else { Label("", systemImage: "arrow.clockwise") }
      }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      Button(action: { showSearchSheet = true }) { Image(systemName: "magnifyingglass") }
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
        Button(L("Import BootMii NAND Backup…")) {
#if os(iOS) || targetEnvironment(macCatalyst)
          showImportNANDPicker = true
#endif
        }
        Button(L("Sources")) { showSources = true }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      #if canImport(TipKit)
      .modifier(AttachTipModifier.tip(.importGame))
      #endif
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      let store = RemoteSourcesStore.shared
      if store.isScanning {
        Button(action: { showSources = true }) {
          HStack(spacing: 6) {
            ProgressView(value: store.scanningProgress).frame(width: 60)
            Text("\(Int(store.scanningProgress * 100))%")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.ultraThinMaterial, in: Capsule())
        }
      }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      Button(action: { model.rescan() }) {
        if model.isRescanning { ProgressView() } else { Label(L("Rescan"), systemImage: "arrow.clockwise") }
      }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      Button(action: {
#if os(iOS) || targetEnvironment(macCatalyst)
        showImportSoftwarePicker = true
#endif
      }) {
        Image(systemName: "plus")
      }
      #if canImport(TipKit)
      .modifier(AttachTipModifier.tip(.importGame))
      #endif
      .help(L("Import Game"))
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      Button(action: {
#if os(iOS) || targetEnvironment(macCatalyst)
        navigateToSettings = true
#endif
      }) { Image(systemName: "gearshape") }
    }
#endif
  }

  var body: some View {
    NavigationStack {
      mainContent
#if os(iOS) || targetEnvironment(macCatalyst)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
          handleDrop(providers: providers)
          return true
        }
#endif
        .navigationDestination(item: $navigateToSaveStates) { route in
          SaveStateFilmstripView(gameID: route.id)
        }
        .navigationDestination(item: $navigateTo) { item in
          EmulationScreen(game: item)
            .onAppear { NSLog("[INPUT] NavigationDestination -> EmulationScreen for game: %@", item.title) }
        }
        .navigationTitle("DolphiniOS Library")
        .toolbar { libraryToolbar }
#if os(iOS) || targetEnvironment(macCatalyst)
        .navigationDestination(isPresented: $navigateToSettings) {
          TVSettingsPage()
            .navigationBarTitleDisplayMode(.inline)
        }
        .toolbar { ToolbarItem(placement: .bottomBar) { RemoteScanProgressView() } }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
#endif
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FavoritesChanged"))) { _ in
          favoritesVersion &+= 1
        }
    }
    .sheet(isPresented: $showSaveStatesBrowser) {
      NavigationStack { SaveStatesBrowserView() }
    }
    .onAppear {
      // Tips setup
      if #available(iOS 17, tvOS 17, *) {
        _ = (Environment(\.tipsService).wrappedValue).configure()
      }
      // Initialize shared remote sources store to start querying immediately
      print("TVLibraryView: initializing RemoteSourcesStore.shared")
      let store = RemoteSourcesStore.shared
      print("TVLibraryView: RemoteSourcesStore has \(store.sources.count) sources")

      // Store hydration already starts sources; avoid redundant boot-time refresh triggers

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

      // Deep link from Spotlight: launch by GameID
      NotificationCenter.default.addObserver(
        forName: NSNotification.Name("DOLLaunchGameByGameID"),
        object: nil,
        queue: .main
      ) { note in
        guard let gameID = note.userInfo?["gameID"] as? String else { return }
        spotlightLaunchByGameID(gameID, attempts: 10)
      }

      // Quick actions
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DOLShowImportGame"), object: nil, queue: .main) { _ in
#if os(iOS) || targetEnvironment(macCatalyst)
        showImportSoftwarePicker = true
#endif
      }
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DOLShowSettings"), object: nil, queue: .main) { _ in
#if os(iOS) || targetEnvironment(macCatalyst)
        navigateToSettings = true
#endif
      }
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DOLShowSnackbar"), object: nil, queue: .main) { note in
        if let text = note.userInfo?["text"] as? String { snackbarText = text; withAnimation { snackbarVisible = true };
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { snackbarVisible = false } }
        }
      }
      // First-run onboarding
      if !UserDefaults.standard.bool(forKey: "onboarding_seen_v1") {
        withAnimation { showOnboarding = true }
      }
    }
    .onDisappear {
      NotificationCenter.default.removeObserver(self, name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
      NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil)
      NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLShowImportGame"), object: nil)
      NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLShowSettings"), object: nil)
      NotificationCenter.default.removeObserver(self, name: NSNotification.Name("GameFileMetadataUpdated"), object: nil)
      NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLShowSnackbar"), object: nil)
    }
#if os(tvOS)
    .fullScreenCover(isPresented: $showSettings) { TVSettingsPage().interactiveDismissDisabled(true) }
    .sheet(isPresented: $showSearchSheet) {
      NavigationStack {
        Form {
          Section(header: Text(L("Search Games"))) {
            TextField(L("Search by title, maker, ID, filename…"), text: $searchText)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
          }
          if !searchText.isEmpty {
            Text(String(format: L("%1 results"), model.games.filter { item in
              let q = searchText.lowercased()
              let title = item.title.lowercased()
              let maker = item.makerLong.lowercased()
              let gid = item.gameID.lowercased()
              let gtdb = item.gametdbID.lowercased()
              let country = item.countryName.lowercased()
              let filename: String = {
                if let url = URL(string: item.filePath) {
                  return (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent).lowercased()
                }
                return item.filePath.lowercased()
              }()
              return title.contains(q) || maker.contains(q) || gid.contains(q) || gtdb.contains(q) || country.contains(q) || filename.contains(q) || item.filePath.lowercased().contains(q)
            }.count))
            .foregroundStyle(.secondary)
          }
        }
        .navigationTitle(L("Search"))
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { showSearchSheet = false } } }
      }
    }
#endif
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
#if os(iOS) || targetEnvironment(macCatalyst)
    // iOS Document Pickers
      .sheet(isPresented: $showImportSoftwarePicker) {
        NavigationStack {
          DocumentPickerView(
            contentTypes: DocumentPickerView.softwareContentTypes,
            onPick: { url in
              ImportFileManager.shared().importFile(at: url)
            }
          )
          .navigationTitle(L("Import Game"))
        }
      }
      .sheet(isPresented: $showImportNANDPicker) {
        NavigationStack {
          DocumentPickerView(
            contentTypes: [DocumentPickerView.binType],
            onPick: { url in
              NANDImportManager.importNAND(from: url)
            }
          )
          .navigationTitle(L("Import BootMii NAND Backup"))
        }
      }
#endif
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
    // Storage error alert
      .alert(L("Storage Error"), isPresented: $showStorageErrorAlert) {
        Button(L("OK")) {}
      } message: { Text(storageAlertMessage) }
    // Low storage warning - using confirmationDialog instead of alert to avoid conflicts
      .confirmationDialog(L("Low Storage Warning"), isPresented: $showLowStorageWarning, titleVisibility: .visible) {
        Button(L("Continue Anyway")) {
          if let item = itemPendingLaunch {
            proceedWithGameLaunch(item)
          }
        }
        Button(L("Cancel"), role: .cancel) {}
      } message: { Text(storageAlertMessage) }
      .sheet(item: $showCacheInfoFor) { item in
        CacheInfoView(item: item)
      }
      .overlay(blockingPrecacheOverlay)
      .overlay(offlineBanner)
      #if os(iOS) || targetEnvironment(macCatalyst)
      .overlay(dropHighlight)
      #endif
      .overlay(searchHintBanner)
      .overlay(snackbar)
      .overlay(onboardingOverlay)
      #if os(iOS)
      .sheet(isPresented: Binding(get: { showGeckoEditorFor != nil }, set: { if !$0 { showGeckoEditorFor = nil } })) {
        if let item = showGeckoEditorFor { GeckoCodesModal(item: item) }
      }
      .sheet(isPresented: Binding(get: { showAREditorFor != nil }, set: { if !$0 { showAREditorFor = nil } })) {
        if let item = showAREditorFor { ActionReplayCodesModal(item: item) }
      }
      #endif
  }

  @State private var snackbarText: String = ""
  @State private var snackbarVisible: Bool = false
  @State private var showOnboarding: Bool = false
  @StateObject private var storeForBanner = RemoteSourcesStore.shared
  @State private var offlineBannerDismissed: Bool = false
  #if os(tvOS)
  @State private var showSearchSheet: Bool = false
  #endif

  @ViewBuilder private var snackbar: some View {
    if snackbarVisible {
      VStack {
        Spacer()
        HStack {
          Text(snackbarText).foregroundStyle(.white).font(.subheadline)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.8))
        .clipShape(Capsule())
        .padding(.bottom, 16)
      }
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  @ViewBuilder private var offlineBanner: some View {
    let anyOffline = storeForBanner.sources.contains { (src) -> Bool in
      (src as? WebDAVSource)?.isOnline == false
    }
    if anyOffline && !offlineBannerDismissed {
      VStack {
        // Leave safe area at top for the navigation bar; place banner below it
        Spacer().frame(height: 8)
        HStack(spacing: 10) {
          Image(systemName: "wifi.slash").foregroundStyle(.white)
          Text(L("Some remote sources are offline. Retrying…")).foregroundStyle(.white)
            .lineLimit(2)
          Spacer(minLength: 8)
          Button(action: { offlineBannerDismissed = true }) {
            Image(systemName: "xmark").foregroundStyle(.white)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        Spacer()
      }
      .transition(.move(edge: .top).combined(with: .opacity))
    } else if !anyOffline && offlineBannerDismissed {
      EmptyView()
        .onAppear { offlineBannerDismissed = false }
    } else {
      EmptyView()
    }
  }

  @ViewBuilder private var searchHintBanner: some View {
    #if os(tvOS)
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !q.isEmpty {
      let needle = q.lowercased()
      let filenameLower: (String) -> String = { path in
        if let url = URL(string: path) {
          return (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent).lowercased()
        }
        return path.lowercased()
      }
      let hasMatches = model.games.contains { item in
        let title = item.title.lowercased()
        if title.contains(needle) { return true }
        if filenameLower(item.filePath).contains(needle) { return true }
        if item.gameID.lowercased().contains(needle) { return true }
        if item.makerLong.lowercased().contains(needle) { return true }
        if item.countryName.lowercased().contains(needle) { return true }
        if item.gametdbID.lowercased().contains(needle) { return true }
        if item.filePath.lowercased().contains(needle) { return true }
        return false
      }
      if !hasMatches {
        VStack {
          Spacer().frame(height: 8)
          HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white)
            Text(L("No results. Try title, maker, Game ID, or filename."))
              .foregroundStyle(.white)
              .lineLimit(2)
            Spacer(minLength: 8)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(Color.gray.opacity(0.85))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .padding(.horizontal, 12)
          .padding(.top, 8)
          Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      } else { EmptyView() }
    } else { EmptyView() }
    #else
    EmptyView()
    #endif
  }

  @ViewBuilder
  private var blockingPrecacheOverlay: some View {
    if let current = blockingPrecacheItem {
      ZStack {
        Color.black.opacity(0.6).ignoresSafeArea()
        VStack(spacing: 14) {
          Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)

          Text(L("Preparing cache"))
            .font(.title3).fontWeight(.semibold)
            .foregroundStyle(.white)

          Text(current.title)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: 280)

          ZStack {
            Circle()
              .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 8))
              .frame(width: 64, height: 64)
            Circle()
              .trim(from: 0, to: CGFloat(blockingPrecacheProgress))
              .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
              .rotationEffect(.degrees(-90))
              .frame(width: 64, height: 64)
              .animation(.easeInOut(duration: 0.2), value: blockingPrecacheProgress)
          }
          .padding(.top, 6)

          Text("\(Int(blockingPrecacheProgress * 100))%")
            .font(.footnote).fontWeight(.semibold)
            .foregroundStyle(.white)
            .monospacedDigit()

          HStack(spacing: 12) {
            Button(role: .cancel) {
              if let url = URL(string: current.filePath), let source = getMatchingWebDAVSource(for: url) {
                let remoteItem = RemoteLibraryItem(url: url, name: current.title, size: Int64(current.fileSize))
                Task { await source.cancelPreCache(remoteItem) }
              }
              blockingPrecacheItem = nil
              blockingPrecacheProgress = 0
              emulationRunning = false
              // Restore controller navigation if we were in library
#if os(iOS) || targetEnvironment(macCatalyst)
              Task { @MainActor in
                // Re-setup navigation using the last known grid column count
                setupControllerNavigation(columns: max(2, gridColumnCount))
              }
#endif
            } label: {
              Text(L("Cancel"))
                .font(.callout).fontWeight(.semibold)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.white.opacity(0.15), in: Capsule())
            }
          }
          .padding(.top, 4)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
      }
      .transition(.opacity)
      .zIndex(10)
    }
  }

  @ViewBuilder private var onboardingOverlay: some View {
    if showOnboarding {
      ZStack {
        Color.black.opacity(0.5).ignoresSafeArea()
        VStack(spacing: 20) {
          // Header icon and title
          VStack(spacing: 10) {
            ZStack {
              Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 64, height: 64)
              Image(systemName: "gamecontroller.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
            }
            Text(L("Welcome to DolphiniOS"))
              .font(.title2).fontWeight(.bold)
              .foregroundStyle(.white)
          }

          // Subtitle
          Text(L("Get started by importing a game or adding a remote source."))
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)

          // Primary actions
          HStack(spacing: 12) {
            Button(action: {
#if os(iOS) || targetEnvironment(macCatalyst)
              showImportSoftwarePicker = true
#endif
              UserDefaults.standard.set(true, forKey: "onboarding_seen_v1")
              withAnimation { showOnboarding = false }
            }) {
              HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                Text(L("Import Game"))
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Button(action: {
              showSources = true
              UserDefaults.standard.set(true, forKey: "onboarding_seen_v1")
              withAnimation { showOnboarding = false }
            }) {
              HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.plus")
                Text(L("Add Remote Source"))
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
          }

          // Secondary action
          Button(L("Maybe Later")) {
            UserDefaults.standard.set(true, forKey: "onboarding_seen_v1")
            withAnimation { showOnboarding = false }
          }
          .buttonStyle(.bordered)
          .tint(.white)
        }
        .padding(22)
        .background(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 24)
      }
      .transition(.opacity)
    }
  }

  private func downloadGecko(for item: TVGameItem) {
    TVCheatsBridge.downloadGeckoCodes(forGameId: item.gameID, revision: item.revision, gametdbId: item.gametdbID) { success, _, _ in
      if !success { showCheatError = L("Failed to download Gecko codes.") }
    }
  }

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
    emulationRunning = true
    teardownControllerNavigation()
    launchGame(item)
  }

  private func launchGame(_ item: TVGameItem) {
    // Check for critically low storage before launching any game
    if TVLibraryView.isStorageCriticallyLow() {
      let availableSpace = TVLibraryView.getAvailableStorageSpace()
      itemPendingLaunch = item
      storageAlertMessage = """
            Warning: Low Storage Space

            Available space: \(TVLibraryView.formatStorageSpace(availableSpace))

            The emulator may act erratically with low storage space. Consider freeing up some space before playing.

            Do you want to continue anyway?
            """
      showLowStorageWarning = true
      return
    }

    // If remote and auto-precache enabled, ensure cache exists before launch
    if let url = URL(string: item.filePath), Self.isRemoteURL(item.filePath) {
      for source in RemoteSourcesStore.shared.sources {
        if let webdav = source as? WebDAVSource, webdav.isPreCachingEnabled {
          let remoteItem = RemoteLibraryItem(url: url, displayName: item.title, sizeBytes: Int64(item.fileSize), etag: nil, lastModified: nil)
          if !webdav.isCached(remoteItem) {
            blockingPrecacheItem = item
            blockingPrecacheProgress = 0
            Task {
              do {
                let _ = try await webdav.preCacheItem(remoteItem) { progress in
                  DispatchQueue.main.async { blockingPrecacheProgress = progress }
                }
                DispatchQueue.main.async {
                  blockingPrecacheItem = nil
                  proceedWithGameLaunch(item)
                }
              } catch {
                DispatchQueue.main.async {
                  blockingPrecacheItem = nil
                  proceedWithGameLaunch(item) // fallback
                }
              }
            }
            return
          }
          break
        }
      }
    }

    proceedWithGameLaunch(item)
  }

  /// Actually launch the game (called after low storage warning is dismissed)
  private func proceedWithGameLaunch(_ item: TVGameItem) {
    GameProfiles.shared.applyProfileIfAvailable(for: item)
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

                // Skip auto pre-cache if insufficient storage space
                if !TVLibraryView.hasEnoughSpaceForPreCache(fileSize: fileSize) {
                  let availableSpace = TVLibraryView.getAvailableStorageSpace()
                  print("Auto pre-cache skipped for \(item.title): insufficient space. Available: \(TVLibraryView.formatStorageSpace(availableSpace)), Required: \(TVLibraryView.formatStorageSpace(fileSize + TVLibraryView.STORAGE_BUFFER_MB))")
                  DispatchQueue.main.async {
                    autoPreCacheActive.remove(gameKey)
                    autoPreCacheProgress.removeValue(forKey: gameKey)
                  }
                  return
                }

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

  private func spotlightLaunchByGameID(_ gameID: String, attempts: Int) {
    let match = model.games.first { $0.gameID == gameID }
    ?? TVLibraryBridge.currentGames().first { $0.gameID == gameID }
    guard let item = match else {
      if attempts > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          spotlightLaunchByGameID(gameID, attempts: attempts - 1)
        }
      }
      return
    }
    GameProfiles.shared.applyProfileIfAvailable(for: item)
    if let url = URL(string: item.filePath), Self.isRemoteURL(item.filePath) {
      if let webdav = getMatchingWebDAVSource(for: url), webdav.isPreCachingEnabled {
        let remoteItem = RemoteLibraryItem(url: url, displayName: item.title, sizeBytes: Int64(item.fileSize), etag: nil, lastModified: nil)
        if !webdav.isCached(remoteItem) {
          blockingPrecacheItem = item
          blockingPrecacheProgress = 0
          Task {
            do {
              let _ = try await webdav.preCacheItem(remoteItem) { progress in
                DispatchQueue.main.async { blockingPrecacheProgress = progress }
              }
              DispatchQueue.main.async {
                blockingPrecacheItem = nil
                navigateTo = item
              }
            } catch {
              DispatchQueue.main.async {
                blockingPrecacheItem = nil
                navigateTo = item // fallback to stream
              }
            }
          }
          return
        }
      }
    }
    navigateTo = item
  }

  private func setupControllerNavigation(columns: Int) {
#if !os(tvOS)
    GCController.shouldMonitorBackgroundEvents = false
    for c in GCController.controllers() {
      c.controllerPausedHandler = { _ in /* swallow to avoid Game Center */ }
      if let egp = c.extendedGamepad {
        let cid = ObjectIdentifier(c)
        if prevEGPHandlers[cid] == nil { prevEGPHandlers[cid] = egp.valueChangedHandler }
        egp.valueChangedHandler = { (gamepad: GCExtendedGamepad, element: GCControllerElement) in
          if emulationRunning { return }
          guard !model.games.isEmpty else { return }
          let index: Int = {
            if let current = focusedFilePath, let idx = model.games.firstIndex(where: { $0.filePath == current }) { return idx }
            return 0
          }()
          func move(_ delta: Int, dir: String) {
            let now = Date().timeIntervalSince1970
            if now - lastNavMoveTime < navRepeatInterval { return }
            lastNavMoveTime = now
            let newIndex = max(0, min(index + delta, model.games.count - 1))
            DispatchQueue.main.async { focusedFilePath = model.games[newIndex].filePath }
          }
          let dpad = gamepad.dpad
          if element == dpad.up, dpad.up.isPressed { move(-columns, dir: "up") }
          if element == dpad.down, dpad.down.isPressed { move(columns, dir: "down") }
          if element == dpad.left, dpad.left.isPressed { move(-1, dir: "left") }
          if element == dpad.right, dpad.right.isPressed { move(1, dir: "right") }
          if element == dpad {
            let vx = dpad.xAxis.value
            let vy = dpad.yAxis.value
            if vy > 0.5 { move(-columns, dir: "up") }
            if vy < -0.5 { move(columns, dir: "down") }
            if vx < -0.5 { move(-1, dir: "left") }
            if vx > 0.5 { move(1, dir: "right") }
          }
          // Left thumbstick support
          let lx = gamepad.leftThumbstick.xAxis.value
          let ly = gamepad.leftThumbstick.yAxis.value
          if element == gamepad.leftThumbstick {
            if ly > 0.6 { move(-columns, dir: "up") }
            if ly < -0.6 { move(columns, dir: "down") }
            if lx < -0.6 { move(-1, dir: "left") }
            if lx > 0.6 { move(1, dir: "right") }
          }
          if element == gamepad.buttonA, gamepad.buttonA.isPressed {
            if let fp = focusedFilePath, let item = model.games.first(where: { $0.filePath == fp }) { DispatchQueue.main.async { selectGame(item) } }
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred()
          }
        }
      }
      if let mgp = c.microGamepad {
        mgp.reportsAbsoluteDpadValues = true
        mgp.allowsRotation = true
        let cid = ObjectIdentifier(c)
        if prevMGPHandlers[cid] == nil { prevMGPHandlers[cid] = mgp.valueChangedHandler }
        mgp.valueChangedHandler = {(gamepad: GCMicroGamepad, element: GCControllerElement) in
          if emulationRunning { return }
          guard !model.games.isEmpty else { return }
          let index: Int = {
            if let current = focusedFilePath, let idx = model.games.firstIndex(where: { $0.filePath == current }) { return idx }
            return 0
          }()
          func move(_ delta: Int, dir: String) {
            let now = Date().timeIntervalSince1970
            if now - lastNavMoveTime < navRepeatInterval { return }
            lastNavMoveTime = now
            let newIndex = max(0, min(index + delta, model.games.count - 1))
            DispatchQueue.main.async { focusedFilePath = model.games[newIndex].filePath }
          }
          if element == gamepad.dpad {
            let vx = gamepad.dpad.xAxis.value, vy = gamepad.dpad.yAxis.value
            if vy > 0.5 { move(-columns, dir: "up") }
            if vy < -0.5 { move(columns, dir: "down") }
            if vx < -0.5 { move(-1, dir: "left") }
            if vx > 0.5 { move(1, dir: "right") }
          }
          if element == gamepad.buttonA, gamepad.buttonA.isPressed {
            if let fp = focusedFilePath, let item = model.games.first(where: { $0.filePath == fp }) { DispatchQueue.main.async { selectGame(item) } }
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred()
          }
        }
      }
    }
#endif
  }

  private func teardownControllerNavigation() {
#if !os(tvOS)
    for c in GCController.controllers() {
      let cid = ObjectIdentifier(c)
      if let egp = c.extendedGamepad {
        if let prev = prevEGPHandlers[cid] {
          egp.valueChangedHandler = prev
        } else {
          egp.valueChangedHandler = nil
        }
      }
      if let mgp = c.microGamepad {
        if let prev = prevMGPHandlers[cid] {
          mgp.valueChangedHandler = prev
        } else {
          mgp.valueChangedHandler = nil
        }
      }
      c.controllerPausedHandler = nil
      prevEGPHandlers.removeValue(forKey: cid)
      prevMGPHandlers.removeValue(forKey: cid)
    }
#endif
  }

  private func favorites() -> [TVGameItem]? {
    let favDict = UserDefaults.standard.dictionary(forKey: "favorites_by_gameid") as? [String: Any] ?? [:]
    let set = Set(favDict.compactMap { (k, v) in (v as? Bool) == true ? k : nil })
    guard !set.isEmpty else { return [] }
    return model.games.filter { set.contains($0.gameID) }
  }

  private func toggleFavorite(for item: TVGameItem) {
    item.isFavorite = !item.isFavorite
    // Nudge UI to update favorites row
    // Reload lightweight by touching state
  }
}

// MARK: - Game Grid Item with Focus Management

private enum Layout {
  static var cardSize: CGSize {
#if os(tvOS)
    return CGSize(width: 260, height: 390)
#else
    return CGSize(width: 140, height: 210)
#endif
  }
}

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
  let showFavoriteToggle: (TVGameItem) -> Void
  let showStorageAlert: (String) -> Void
  let showCacheInfo: (TVGameItem) -> Void
  let showSaveStates: (TVGameItem) -> Void
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
          .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
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
            .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
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

        // Region flag badge (top-left), styled like the cloud indicator
        if !item.countryName.isEmpty {
          Text(RegionFlagMapper.compactFlag(for: item.countryName))
            .font(.system(size: 18))
            .padding(8)
            .background(.ultraThinMaterial, in: Circle())
            .padding(8)
            .frame(width: Layout.cardSize.width, height: Layout.cardSize.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .font(.headline)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .foregroundColor(.primary)

        HStack {
          // Game ID only (flag moved to artwork overlay)
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
    .frame(width: Layout.cardSize.width)
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
      //            Button(L("View Save States")) { showSaveStates(item) }
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
            Button(action: { showCacheInfo(item) }) {
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
      Button(item.isFavorite ? L("Unfavorite") : L("Favorite")) { showFavoriteToggle(item) }
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
            .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
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

          // Game ID only (flag moved to artwork overlay)
          Text(item.gameID)
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .frame(width: Layout.cardSize.width)
    }
    .buttonStyle(.plain)
    .contextMenu {
      // Align with tvOS context menu
      Button(L("Properties")) { showProperties(item) }
      //            Button(L("View Save States")) { showSaveStates(item) }
      Menu(L("Cheats")) {
        Button(L("Manage...")) { showCheatList(item) }
        Button(L("Download Codes")) { downloadGeckoAction(item) }
        Divider()
        Menu(L("Gecko")) { Button(L("Add...")) { presentCheatGecko(item) } }
        Menu(L("Action Replay")) { Button(L("Add...")) { presentCheatAR(item) } }
      }
      if isRemoteGame {
        if let _ = getWebDAVSource() {
          if isCached {
            Button(action: { removeCachedFile() }) {
              Label(L("Remove from Cache"), systemImage: "trash")
            }
            Button(action: { showCacheInfo(item) }) {
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
      Button(item.isFavorite ? L("Unfavorite") : L("Favorite")) { showFavoriteToggle(item) }
      Button(role: .destructive) { requestDelete(item) } label: { Text(L("Delete")) }
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

        // Check if we have enough storage space (file size + 100MB buffer)
        if !TVLibraryView.hasEnoughSpaceForPreCache(fileSize: fileSize) {
          let availableSpace = TVLibraryView.getAvailableStorageSpace()
          let requiredSpace = fileSize + TVLibraryView.STORAGE_BUFFER_MB

          DispatchQueue.main.async {
            self.isPreCaching = false
            self.showPreCacheProgress = false
            let message = """
                        Not enough storage space to download \(self.item.title).

                        Available: \(TVLibraryView.formatStorageSpace(availableSpace))
                        Required: \(TVLibraryView.formatStorageSpace(requiredSpace))

                        Please free up some space and try again.
                        """
            self.showStorageAlert(message)
          }
          return
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

          // Show user-friendly error message
          let message: String
          if let nsError = error as NSError?, nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
            message = """
                        Download failed: Not enough storage space.

                        The device ran out of space while downloading \(self.item.title).
                        Please free up some space and try again.
                        """
          } else {
            message = """
                        Download failed: \(error.localizedDescription)

                        Unable to download \(self.item.title) to cache.
                        """
          }
          self.showStorageAlert(message)
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

  private func presentCheatGecko(_ item: TVGameItem) {
    Task { @MainActor in
      showCheatList(item)
    }
  }

  private func presentCheatAR(_ item: TVGameItem) {
    Task { @MainActor in
      showCheatList(item)
    }
  }
}

// MARK: - Source Picker

@MainActor
private func getMatchingWebDAVSource(for url: URL) -> WebDAVSource? {
  func defaultPort(for scheme: String?) -> Int { (scheme?.lowercased() == "https" || scheme?.lowercased() == "webdavs") ? 443 : 80 }
  guard let urlHost = url.host?.lowercased() else { return nil }
  let urlPort = url.port ?? defaultPort(for: url.scheme)
  for source in RemoteSourcesStore.shared.sources {
    guard let w = source as? WebDAVSource else { continue }
    let base = w.baseURL
    guard let baseHost = base.host?.lowercased() else { continue }
    let basePort = base.port ?? defaultPort(for: base.scheme)
    if baseHost == urlHost && basePort == urlPort { return w }
  }
  return nil
}


private struct SourcePickerView: View {
  let items: [TVGameItem]
  let onPick: (TVGameItem) -> Void
  @Environment(\.dismiss) private var dismiss

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
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(L("Cancel"), role: .cancel) {
            dismiss()
          }
        }
      }
    }
  }
}


// MARK: - Unified Game Card
// Both iOS and tvOS now use the same clean implementation in GameGridItem

/// View showing cache information for a remote game
private struct CacheInfoView: View {
  let item: TVGameItem
  @Environment(\.dismiss) private var dismiss
  @State private var cacheInfo: CacheInfo?
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var isWorking = false
  @State private var redownloadProgress: Double = 0
  @State private var showCopiedToast: Bool = false
  @State private var shareURL: URL?
  @State private var toastText: String?
  @State private var showAlert = false
  @State private var alertTitle = ""
  @State private var alertMessage = ""

  private struct CacheInfo {
    let localPath: String
    let fileSize: Int64
    let cachedDate: Date
    let originalURL: String
    let etag: String?
    let lastModified: Date?
  }

  var body: some View {
    NavigationView {
      GeometryReader { proxy in
        let w = max(320.0, min(proxy.size.width - 32.0, 680.0))
        ZStack {
          /// Blurred artwork background for visual depth
          Image(uiImage: item.coverImage)
            .resizable()
            .scaledToFill()
            .blur(radius: 20)
            .opacity(0.35)
            .ignoresSafeArea()

          if isLoading {
            VStack(spacing: 12) {
              ProgressView()
              Text("Loading cache information...")
                .foregroundColor(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
          } else if let errorMessage = errorMessage {
            VStack(spacing: 14) {
              Image(systemName: "icloud.slash")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.orange)
              Text(errorMessage)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
          } else if let info = cacheInfo {
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                /// Header card with cover and basic details
                HStack(alignment: .top, spacing: 16) {
                  Image(uiImage: item.coverImage)
                    .resizable()
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .frame(width: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 6)
                  VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                      .font(.title3).fontWeight(.semibold)
                      .lineLimit(2)
                    Text(item.gameID)
                      .font(.footnote)
                      .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                      Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                      Text("Cached \(DateFormatter.localizedString(from: info.cachedDate, dateStyle: .medium, timeStyle: .short))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    }
                  }
                  Spacer(minLength: 0)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))

                /// Details card
                VStack(spacing: 10) {
                  KVRow(icon: "externaldrive", label: "Original URL", value: info.originalURL)
                  KVRow(icon: "internaldrive", label: "Local Path", value: info.localPath, monospaced: true)
                  KVRow(icon: "externaldrive.badge.person.crop", label: "ETag", value: info.etag ?? "-")
                  KVRow(icon: "clock", label: "Last Modified", value: info.lastModified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "-")
                  KVRow(icon: "archivebox", label: "File Size", value: TVLibraryView.formatStorageSpace(info.fileSize))
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))

                // Actions grid (fits better than toolbar on small widths)
                let gridCols: [GridItem] = {
                  if proxy.size.width < 370 { return [GridItem(.flexible(), spacing: 12)] }
                  if proxy.size.width < 700 { return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)] }
                  return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                }()
                if let info = cacheInfo {
                  LazyVGrid(columns: gridCols, spacing: 12) {
                    Button(role: .destructive) { performRemove() } label: {
                      HStack { Image(systemName: "trash"); Text(L("Remove")) }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isWorking)

                    Button { performRedownload() } label: {
                      if isWorking && redownloadProgress > 0 {
                        HStack(spacing: 6) { ProgressView(value: redownloadProgress); Text("\(Int(redownloadProgress * 100))%") }
                          .frame(maxWidth: .infinity)
                      } else {
                        HStack { Image(systemName: "arrow.down.circle"); Text(L("Re-download")) }
                          .frame(maxWidth: .infinity)
                      }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)

                    Button { copyToPasteboard(info.originalURL) } label: {
                      HStack { Image(systemName: "doc.on.doc"); Text(L("Copy URL")) }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button { copyToPasteboard(info.localPath) } label: {
                      HStack { Image(systemName: "folder"); Text(L("Copy Path")) }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    #if os(iOS)
                    if FileManager.default.fileExists(atPath: info.localPath) {
                      Button { shareFile(path: info.localPath) } label: {
                        HStack { Image(systemName: "square.and.arrow.up"); Text(L("Share")) }
                          .frame(maxWidth: .infinity)
                      }
                      .buttonStyle(.bordered)
                    }
                    #endif
                  }
                  .padding(.top, 8)
                }
              }
              .frame(maxWidth: w)
              .padding(.horizontal, 16)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 16)

            }
          } else {
            VStack(spacing: 12) {
              Image(systemName: "questionmark.circle")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.secondary)
              Text("No cache information available")
                .foregroundColor(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
          }
        }
      }
      .navigationTitle("Cache Info")
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
      .onAppear {
        loadCacheInfo()
      }
    #if os(iOS)
      .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
        Group {
          if let url = shareURL {
            ShareSheet(activityItems: [url])
              .ignoresSafeArea()
          } else {
            EmptyView()
          }
        }
      }
    #endif
      .overlay(
        Group {
          if let toast = toastText {
            VStack {
              Spacer()
              Text(toast)
                .font(.footnote)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 20)
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: toastText)
          }
        }
      )
      .alert(alertTitle, isPresented: $showAlert) {
        Button(L("OK"), role: .cancel) {}
      } message: {
        Text(alertMessage)
      }
    }
  }

  private func loadCacheInfo() {
    // Find the WebDAV source for this item
    guard let url = URL(string: item.filePath) else {
      errorMessage = "Invalid file path"
      isLoading = false
      return
    }

    if let source = getMatchingWebDAVSource(for: url) {
      let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: Int64(item.fileSize))
      // Check if cached and get info
      Task {
        let info = await getCacheInfo(from: source, for: remoteItem)
        await MainActor.run {
          self.cacheInfo = info
          self.isLoading = false
          self.errorMessage = info == nil ? "This game is not currently cached" : nil
        }
      }
    } else {
      errorMessage = "No WebDAV source found for this game"
      isLoading = false
      cacheInfo = nil
    }
  }

  private func getCacheInfo(from source: WebDAVSource, for item: RemoteLibraryItem) async -> CacheInfo? {
    // Get actual cache information from the WebDAV source
    guard let cachedFileInfo = source.getCacheInfo(for: item) else {
      return nil
    }

    return CacheInfo(
      localPath: cachedFileInfo.localPath,
      fileSize: cachedFileInfo.fileSize,
      cachedDate: cachedFileInfo.cachedDate,
      originalURL: cachedFileInfo.originalURL,
      etag: cachedFileInfo.etag,
      lastModified: cachedFileInfo.lastModified
    )
  }

  private func performRemove() {
    guard let url = URL(string: item.filePath), let source = getMatchingWebDAVSource(for: url) else { return }
    let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: Int64(item.fileSize))
    isWorking = true
    Task {
      do {
        try await source.removeCachedItem(remoteItem)
        await MainActor.run {
          isWorking = false
          // Optimistically clear current info
          self.cacheInfo = nil
          self.errorMessage = "This game is not currently cached"
          loadCacheInfo()
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Removed from cache")])
          toastText = L("Removed from cache")
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { toastText = nil }
          alertTitle = L("Removed")
          alertMessage = L("The cached file was removed.")
          showAlert = true
        }
      } catch {
        await MainActor.run { isWorking = false }
      }
    }
  }

  private func performRedownload() {
    guard let url = URL(string: item.filePath), let source = getMatchingWebDAVSource(for: url) else { return }
    let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: Int64(item.fileSize))
    isWorking = true
    redownloadProgress = 0
    Task {
      do {
        let _ = try await source.forcePreCacheItem(remoteItem) { progress in
          DispatchQueue.main.async { self.redownloadProgress = progress }
        }
        await MainActor.run {
          isWorking = false
          loadCacheInfo()
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Downloaded to cache")])
          toastText = L("Downloaded to cache")
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { toastText = nil }
          alertTitle = L("Downloaded")
          alertMessage = L("The file has been downloaded to cache.")
          showAlert = true
        }
      } catch {
        await MainActor.run { isWorking = false }
      }
    }
  }

  private func copyToPasteboard(_ text: String) {
#if os(iOS)
    UIPasteboard.general.string = text
    showCopiedToast = true
    toastText = L("Copied")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { showCopiedToast = false; toastText = nil }
    alertTitle = L("Copied")
    alertMessage = text
    showAlert = true
#endif
  }

  #if os(iOS)
  private func shareFile(path: String) {
    let url = URL(fileURLWithPath: path)
    shareURL = url
  }
  #endif
}


/// Labeled row with SF Symbol and value, used in cache details card
private struct KVRow: View {
  let icon: String
  let label: String
  let value: String
  var monospaced: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .frame(width: 18)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.caption)
          .foregroundColor(.secondary)
          .textCase(.uppercase)
        #if os(tvOS)
        if monospaced {
          Text(value).font(.callout).monospaced().lineLimit(nil)
        } else {
          Text(value).font(.callout).lineLimit(nil)
        }
        #else
        if monospaced {
          Text(value).font(.callout).textSelection(.enabled).monospaced().lineLimit(nil)
        } else {
          Text(value).font(.callout).textSelection(.enabled).lineLimit(nil)
        }
        #endif
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#if os(iOS)
/// Minimal share sheet wrapper
private struct ShareSheet: UIViewControllerRepresentable {
  let activityItems: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }
  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Remote scan progress view (toolbar)
private struct RemoteScanProgressView: View {
  @StateObject private var store = RemoteSourcesStore.shared
  var body: some View {
    if store.isScanning {
      ProgressView(value: store.scanningProgress)
        .progressViewStyle(.linear)
        .frame(maxWidth: .infinity)
    }
  }
}

// MARK: - Safe index helper
private extension Array {
  subscript(safe index: Int) -> Element? {
    return indices.contains(index) ? self[index] : nil
  }
}

#if os(iOS)
private struct GeckoCodesModal: UIViewControllerRepresentable {
  let item: TVGameItem
  func makeUIViewController(context: Context) -> UIViewController {
    let sb = UIStoryboard(name: "Gecko", bundle: nil)
    let vc = sb.instantiateInitialViewController()!
    let list: UIViewController = (vc as? UINavigationController)?.topViewController ?? vc
    // Bridge C++ property types
    if let gcv = list as? NSObject {
      // gameId std::string
      let gid = item.gameID as NSString
      if gcv.responds(to: Selector(("setGameIdString:"))) { gcv.perform(Selector(("setGameIdString:")), with: gid) } else { gcv.setValue(gid, forKey: "gameId") }
      // gametdbId std::string
      let gtdb = item.gametdbID as NSString
      if gcv.responds(to: Selector(("setGametdbIdString:"))) { gcv.perform(Selector(("setGametdbIdString:")), with: gtdb) } else { gcv.setValue(gtdb, forKey: "gametdbId") }
      // revision u16
      let rev = NSNumber(value: Int(item.revision))
      if gcv.responds(to: Selector(("setRevisionNumber:"))) { gcv.perform(Selector(("setRevisionNumber:")), with: rev) } else { gcv.setValue(rev, forKey: "revision") }
    }
    let nav = (vc as? UINavigationController) ?? UINavigationController(rootViewController: list)
    list.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: context.coordinator, action: #selector(Coordinator.close))
    return nav
  }
  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator() }
  final class Coordinator: NSObject { @objc func close() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let root = scene.keyWindow?.rootViewController { root.dismiss(animated: true) } } }
}

private struct ActionReplayCodesModal: UIViewControllerRepresentable {
  let item: TVGameItem
  func makeUIViewController(context: Context) -> UIViewController {
    let sb = UIStoryboard(name: "ActionReplay", bundle: nil)
    let vc = sb.instantiateInitialViewController()!
    let list: UIViewController = (vc as? UINavigationController)?.topViewController ?? vc
    if let ar = list as? NSObject {
      // gameId std::string
      let gid = item.gameID as NSString
      if ar.responds(to: Selector(("setGameIdString:"))) { ar.perform(Selector(("setGameIdString:")), with: gid) } else { ar.setValue(gid, forKey: "gameId") }
      // revision u16
      let rev = NSNumber(value: Int(item.revision))
      if ar.responds(to: Selector(("setRevisionNumber:"))) { ar.perform(Selector(("setRevisionNumber:")), with: rev) } else { ar.setValue(rev, forKey: "revision") }
    }
    let nav = (vc as? UINavigationController) ?? UINavigationController(rootViewController: list)
    list.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: context.coordinator, action: #selector(Coordinator.close))
    return nav
  }
  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator() }
  final class Coordinator: NSObject { @objc func close() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let root = scene.keyWindow?.rootViewController { root.dismiss(animated: true) } } }
}
#endif

#if os(iOS) || targetEnvironment(macCatalyst)
extension TVLibraryView {
  private var dropHighlight: some View {
    if dropTargeted {
      return AnyView(
        VStack {
          Spacer().frame(height: 8)
          HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down").foregroundStyle(.white)
            if dropPreviewCount > 0 {
              Text(String(format: L("Drop %1 files to import"), dropPreviewCount))
                .foregroundStyle(.white)
            } else {
              Text(L("Drop files to import")).foregroundStyle(.white)
            }
            Spacer(minLength: 8)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(Color.accentColor.opacity(0.9))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .padding(.horizontal, 12)
          .padding(.top, 8)
          Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      )
    }
    return AnyView(EmptyView())
  }

  private func handleDrop(providers: [NSItemProvider]) {
    let wanted = UTType.fileURL.identifier
    var pendingURLs: [URL] = []
    let group = DispatchGroup()
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(wanted) {
        group.enter()
        provider.loadItem(forTypeIdentifier: wanted, options: nil) { (item, error) in
          defer { group.leave() }
          if let nsURL = item as? NSURL, let url = nsURL as URL? {
            pendingURLs.append(url)
          }
        }
      }
    }
    group.notify(queue: .main) {
      dropPreviewCount = pendingURLs.count
      let files = expandAndFilterImportURLs(pendingURLs)
      guard !files.isEmpty else {
        NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("No supported files to import")])
        return
      }
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Importing %1 files…"), files.count)])
      for u in files { ImportFileManager.shared().importFile(at: u) }
    }
  }

  private func expandAndFilterImportURLs(_ urls: [URL]) -> [URL] {
    let allowed: Set<String> = ["iso","gcm","wbfs","gcz","ciso","rvz","wad","dol","elf"]
    var results: [URL] = []
    let fm = FileManager.default
    for url in urls {
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
        // Recurse directory
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
          for case let f as URL in e {
            if allowed.contains(f.pathExtension.lowercased()) { results.append(f) }
          }
        }
      } else {
        let ext = url.pathExtension.lowercased()
        if allowed.contains(ext) {
          results.append(url)
        } else if ext == "zip" {
          // Pass zip to importer; if importer unzips, it will handle contents
          results.append(url)
        }
      }
    }
    return results
  }
}
#endif

#if canImport(TipKit)
import TipKit
@available(iOS 17, tvOS 17, *)
private struct AttachTipModifier: ViewModifier {
  enum Kind { case importGame, addSource, search }
  let kind: Kind
  static func tip(_ kind: Kind) -> AttachTipModifier { AttachTipModifier(kind: kind) }
  func body(content: Content) -> some View {
    switch kind {
    case .importGame:
      content.popoverTip(ImportGameTip())
    case .addSource:
      content.popoverTip(AddRemoteSourceTip())
    case .search:
      content.popoverTip(SearchLibraryTip())
    }
  }
}
#endif
