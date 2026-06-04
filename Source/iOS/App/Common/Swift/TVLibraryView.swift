import SwiftUI
import UIKit
import GameController
import UniformTypeIdentifiers
#if os(iOS)
#endif
import Combine

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
#endif // os(iOS) || targetEnvironment(macCatalyst)

// MARK: - Game Grid Item with Focus Management

enum LibraryLayout {
  static var cardSize: CGSize {
#if os(tvOS)
    return CGSize(width: 260, height: 390)
#else
    return CGSize(width: 140, height: 210)
#endif
  }
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

// MARK: - Retro UI Helpers

extension TVGameItem: Identifiable {}

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

@MainActor
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

  private var cancellables = Set<AnyCancellable>()

  init() {
    LibraryCoordinator.shared.$games
      .receive(on: RunLoop.main)
      .sink { [weak self] items in
        self?.groupAndDedup(items: items)
      }
      .store(in: &cancellables)
    LibraryCoordinator.shared.start()
  }

  /// Loads the current game list from the bridge
  func load() {
    let items = LibraryCoordinator.shared.games
    groupAndDedup(items: items)
  }

  /// Initiates a rescan and metadata fetch, then reloads the list
  func rescan() {
    guard !isRescanning else { return }
    isRescanning = true
    LibraryCoordinator.shared.refreshAll { [weak self] in
      Task { @MainActor in
        self?.isRescanning = false
      }
    }
  }

  /// Triggers metadata fetch on first appearance to populate artwork
  func kickoffInitialMetadataIfNeeded() {
    guard !didKickoffInitialMetadata, !isRescanning else { return }
    didKickoffInitialMetadata = true
    LibraryCoordinator.shared.refreshLocal()
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
#if DEBUG
    print("TVLibraryViewModel.groupAndDedup(): processing \(items.count) items")
#endif
    var grouped: [String: [TVGameItem]] = [:]
    for it in items {
      let itemKey = key(for: it)
      let isRemote = !isLocal(it)
#if DEBUG
      print("  Item: '\(it.title)' -> Key: '\(itemKey)' (gameID: '\(it.gameID)', discNumber: \(it.discNumber), revision: \(it.revision), isRemote: \(isRemote), titleEmpty: \(it.title.isEmpty))")
#endif
      grouped[itemKey, default: []].append(it)
    }
#if DEBUG
    print("TVLibraryViewModel.groupAndDedup(): created \(grouped.count) groups")
#endif
    groupsByKey = grouped
    var representatives: [TVGameItem] = []
    for (groupKey, group) in grouped {
#if DEBUG
      print("  Group '\(groupKey)': \(group.count) items")
      for (idx, item) in group.enumerated() {
        print("    [\(idx)]: '\(item.title)' (isLocal: \(isLocal(item)), titleEmpty: \(item.title.isEmpty))")
      }
#endif
      if let local = group.first(where: { isLocal($0) }) {
#if DEBUG
        print("    -> Using local representative: '\(local.title)'")
#endif
        representatives.append(local)
      } else if let any = group.first {
#if DEBUG
        print("    -> Using first representative: '\(any.title)' (titleEmpty: \(any.title.isEmpty))")
#endif
        representatives.append(any)
      } else {
#if DEBUG
        print("    -> No representative found (empty group)")
#endif
      }
    }
#if DEBUG
    print("TVLibraryViewModel.groupAndDedup(): found \(representatives.count) representatives")
#endif
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
#if DEBUG
    print("TVLibraryViewModel.groupAndDedup(): final games count: \(games.count)")
#endif
  }

  func sources(for item: TVGameItem) -> [TVGameItem] {
    groupsByKey[key(for: item)] ?? [item]
  }
}

struct TVLibraryView: View {

  @Environment(\.colorScheme) private var colorScheme

  // MARK: - UI Settings

  @AppStorage("library_background_style") private var backgroundStyle: BackgroundStyle = .gradient
  @AppStorage("library_show_subtitles") private var showSubtitles: Bool = true

  enum BackgroundStyle: String, CaseIterable {
    case clean = "clean"
    case gradient = "gradient"
    case animated = "animated"

    var displayName: String {
      switch self {
      case .clean: return "Clean"
      case .gradient: return "GameCube Gradient"
      case .animated: return "Animated (Full Effects)"
      }
    }
  }

  // MARK: - Enhanced Font Properties for iOS 16.0+ compatibility

  /// Enhanced title2 font with iOS version compatibility for favorites headers
  private var enhancedTitle2BoldFont: Font {
    return .system(.title2, design: .rounded, weight: .bold)
  }

  /// Enhanced caption medium font with iOS version compatibility
  private var enhancedCaptionMediumFont: Font {
    return .system(.caption, design: .rounded, weight: .medium)
  }

  /// Enhanced large title font with iOS version compatibility for tvOS favorites
  private var enhancedLargeTitleFont: Font {
    return .system(.largeTitle, design: .rounded, weight: .bold)
  }

  /// Enhanced title3 font with iOS version compatibility for tvOS favorites
  private var enhancedTitle3Font: Font {
    return .system(.title3, design: .rounded, weight: .medium)
  }

  @Environment(\.tipsService) private var tipsService

  @StateObject private var model = TVLibraryViewModel()
  @State private var showSettings = false
  @State private var didReloadOnce = false
  @State private var navigateTo: TVGameItem?
  @State private var showMoreMenu = false
  @State private var showUpdateRegions = false
  @State private var showDSUSession = false

  // MARK: - Computed Bindings (extracted to prevent compiler timeout)

  private struct NavigationItem: Identifiable {
    let id = UUID()
  }

#if os(iOS) || targetEnvironment(macCatalyst)
  private var settingsBinding: Binding<NavigationItem?> {
    Binding(
      get: { navigateToSettings ? NavigationItem() : nil },
      set: { navigateToSettings = ($0 != nil) }
    )
  }
#endif

  // MARK: - Navigation Configuration (extracted to prevent compiler timeout)

  @ViewBuilder
  private var navigationContent: some View {
    mainContent
#if os(iOS) || targetEnvironment(macCatalyst)
      .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
        handleDrop(providers: providers)
        return true
      }
#endif
      .modifier(iOS16NavigationStyleModifier())
      .navigationDestinationItemCompat(item: $navigateToSaveStates) { route in
        SaveStateFilmstripView(gameID: route.id)
      }
      .navigationDestinationItemCompat(item: $navigateTo) { item in
        EmulationScreen(game: item)
          .onAppear { NSLog("[INPUT] NavigationDestination -> EmulationScreen for game: %@", item.title) }
      }
  }

  @ViewBuilder
  private var navigationConfiguration: some View {
    navigationContent
      .navigationTitle(storeForBanner.isScanning ? "" : "iCube Library")
      .toolbar { libraryToolbar }
#if !os(tvOS)
      .navigationBarTitleDisplayMode(.large)
#endif
#if os(iOS) || targetEnvironment(macCatalyst)
      .navigationDestinationItemCompat(item: settingsBinding) { _ in
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
  // Library GCController observers
  @State private var libGCConnectObs: NSObjectProtocol?
  @State private var libGCDisconnectObs: NSObjectProtocol?
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

  /// Customizable background based on user preference
  @ViewBuilder
  private var backgroundGradient: some View {
    switch backgroundStyle {
    case .clean:
      cleanBackground
    case .gradient:
      gradientBackground
    case .animated:
      animatedBackground
    }
  }

  @ViewBuilder
  private var cleanBackground: some View {
    Color.black
      .ignoresSafeArea()
  }

  @ViewBuilder
  private var gradientBackground: some View {
    if colorScheme == .dark {
      LinearGradient(
        colors: [
          Color(red: 0.08, green: 0.12, blue: 0.22),
          Color(red: 0.04, green: 0.06, blue: 0.15),
          Color.black
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    } else {
      LinearGradient(
        colors: [
          Color(red: 0.90, green: 0.93, blue: 0.98), // light top
          Color(red: 0.84, green: 0.89, blue: 0.98), // mid
          Color(red: 0.96, green: 0.97, blue: 1.00)  // near white
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    }
  }

  @ViewBuilder
  private var animatedBackground: some View {
    ZStack {
      // Premium gradient switches for light/dark
      if colorScheme == .dark {
        RadialGradient(
          colors: [
            Color(red: 0.12, green: 0.15, blue: 0.28),
            Color(red: 0.08, green: 0.12, blue: 0.22),
            Color(red: 0.04, green: 0.06, blue: 0.15),
            Color.black
          ],
          center: .topLeading,
          startRadius: 100,
          endRadius: 800
        )
        .ignoresSafeArea()
      } else {
        RadialGradient(
          colors: [
            Color(red: 0.92, green: 0.95, blue: 1.00),
            Color(red: 0.88, green: 0.93, blue: 1.00),
            Color(red: 0.98, green: 0.99, blue: 1.00)
          ],
          center: .topLeading,
          startRadius: 100,
          endRadius: 800
        )
        .ignoresSafeArea()
      }

      // Elegant animated orbs with GameCube/Wii theming
      ForEach(0..<5, id: \.self) { index in
        Circle()
          .fill(
            RadialGradient(
              colors: [
                (colorScheme == .dark ? (index % 2 == 0 ? Color.purple.opacity(0.06) : Color.blue.opacity(0.05))
                 : (index % 2 == 0 ? Color.purple.opacity(0.10) : Color.blue.opacity(0.10))),
                (colorScheme == .dark ? (index % 2 == 0 ? Color.purple.opacity(0.03) : Color.blue.opacity(0.025))
                 : Color.white.opacity(0.0)),
                Color.clear
              ],
              center: .center,
              startRadius: 20,
              endRadius: 180
            )
          )
          .frame(width: CGFloat.random(in: 200...400), height: CGFloat.random(in: 200...400))
          .offset(
            x: CGFloat.random(in: -150...150),
            y: CGFloat.random(in: -200...200)
          )
          .scaleEffect(0.8 + CGFloat(index) * 0.1)
          .animation(
            Animation.easeInOut(duration: Double.random(in: 10...18))
              .repeatForever(autoreverses: true)
              .delay(Double(index) * 1.5),
            value: UUID()
          )
      }

      // Subtle grid pattern
      Canvas { context, size in
        let spacing: CGFloat = 80
        let lineWidth: CGFloat = 0.5
        let gradient = Gradient(colors: [
          (colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)),
          .clear,
          (colorScheme == .dark ? .white.opacity(0.04) : .black.opacity(0.03))
        ])

        context.stroke(
          Path { path in
            for x in stride(from: 0, through: size.width, by: spacing) {
              path.move(to: CGPoint(x: x, y: 0))
              path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: spacing) {
              path.move(to: CGPoint(x: 0, y: y))
              path.addLine(to: CGPoint(x: size.width, y: y))
            }
          },
          with: .linearGradient(
            gradient,
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: size.width, y: size.height)
          ),
          lineWidth: lineWidth
        )
      }
      .ignoresSafeArea()
      .opacity(colorScheme == .dark ? 0.6 : 0.25)

      // Minor grid checks (subtle)
      Canvas { context, size in
        let spacing: CGFloat = 20
        let lineWidth: CGFloat = 0.25
        let strokeColor = (colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.02))
        context.stroke(
          Path { path in
            for x in stride(from: 0, through: size.width, by: spacing) {
              path.move(to: CGPoint(x: x, y: 0))
              path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: spacing) {
              path.move(to: CGPoint(x: 0, y: y))
              path.addLine(to: CGPoint(x: size.width, y: y))
            }
          },
          with: .color(strokeColor),
          lineWidth: lineWidth
        )
      }
      .ignoresSafeArea()
      .opacity(colorScheme == .dark ? 0.25 : 0.12)

      // Floating elements
      ForEach(0..<8, id: \.self) { index in
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                (colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.5)),
                Color.clear
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: CGFloat.random(in: 20...40), height: CGFloat.random(in: 20...40))
          .offset(x: CGFloat.random(in: -200...200), y: CGFloat.random(in: -300...300))
          .rotationEffect(.degrees(Double.random(in: 0...360)))
          .animation(Animation.linear(duration: Double.random(in: 20...30)).repeatForever(autoreverses: false).delay(Double(index) * 2), value: UUID())
      }
    }
    .clipped()
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
      return 40  // More breathing room for focus effects
#else
      return 20  // Enhanced spacing for iOS
#endif
    }()
    static let gridHorizontalSpacing: CGFloat = {
#if os(tvOS)
      return 52  // Better visual balance
#else
      return 16  // Modern iOS spacing
#endif
    }()
#if os(tvOS)
    static let gridNumberOfColumns = 5  // Better proportion for wide screens
#else
    static let gridNumberOfColumns = 3
#endif
    static let gridHorizontalPadding: CGFloat = {
#if os(tvOS)
      return 80  // More immersive padding
#else
      return 20  // Clean iOS margins
#endif
    }()
    static let gridVerticalPadding: CGFloat = {
#if os(tvOS)
      return 100  // Premium spacing for focus effects
#else
      return 28   // Modern iOS vertical rhythm
#endif
    }()
    static var columns: [GridItem] {
      return Array(repeating: GridItem(.flexible(), spacing: gridHorizontalSpacing), count: gridNumberOfColumns)
    }
  }

  @ViewBuilder
  private var mainContent: some View {
    ZStack {
      // Beautiful GameCube/Wii inspired background
      backgroundGradient

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

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
#if os(iOS) || targetEnvironment(macCatalyst)
    libraryView_iOS(displayGames)
#else
    libraryView_tvOS(displayGames)
#endif
  }

  #if os(tvOS)
  private func libraryView_tvOS(_ displayGames: [TVGameItem]) -> some View {
    ScrollView {
      libraryToolbar_tvOS_favorites
      libraryToolbar_tvOS_main(displayGames)
    }
  }

  @ViewBuilder
  private var libraryToolbar_tvOS_favorites: some View {
    if !isSearching, let favs = favorites(), !favs.isEmpty {
      VStack(alignment: .leading, spacing: 16) {
        // Stunning tvOS favorites header
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text("⭐ Favorites")
              .font(enhancedLargeTitleFont)
              .foregroundStyle(
                LinearGradient(
                  colors: [Color.primary, Color.primary.opacity(0.8)],
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )

            Text("Your championship collection")
              .font(enhancedTitle3Font)
              .foregroundColor(.secondary)
          }
          Spacer()

          // Elegant floating elements
          HStack(spacing: 8) {
            Image(systemName: "sparkles")
              .font(.system(size: 24, weight: .light))
              .foregroundColor(.yellow.opacity(0.8))
            Image("DolphinLogo")
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 32, height: 32)
              .opacity(0.7)
          }
        }
        .padding(.horizontal, Constants.gridHorizontalPadding)

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
                isAutoPreCaching: autoPreCacheActive.contains(fav.filePath),
                showSubtitles: showSubtitles
              )
            }
          }
          .background(
            // Elegant material backdrop for tvOS favorites with proper clipping
            RoundedRectangle(cornerRadius: 28, style: .continuous)
              .fill(.ultraThinMaterial.opacity(0.15))
              .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                  .stroke(.white.opacity(0.08), lineWidth: 1.5)
              )
              .padding(.horizontal, 20)
              .clipped()
          )
        }
      }
    }
  }

  @ViewBuilder
  private func libraryToolbar_tvOS_main(_ displayGames: [TVGameItem]) -> some View {
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
          isAutoPreCaching: autoPreCacheActive.contains(item.filePath),
          showSubtitles: showSubtitles
        )
      }
    }
    .padding(.horizontal, Constants.gridHorizontalPadding)
    .padding(.vertical, Constants.gridVerticalPadding)
  }
  #endif // os(tvOS)

  #if !os(tvOS)
  @ViewBuilder
  private func libraryView_iOS(_ displayGames: [TVGameItem]) -> some View {
    GeometryReader { proxy in
      let paddingH = Constants.gridHorizontalPadding
      let spacingH = Constants.gridHorizontalSpacing
      let cardW = LibraryLayout.cardSize.width
      let available = max(0, proxy.size.width - (paddingH * 2))
      let count = max(2, Int((available + spacingH) / (cardW + spacingH)))
      let columns = Array(repeating: GridItem(.flexible(), spacing: spacingH), count: count)
      ScrollViewReader { scr in
        ScrollView {
          if !isSearching, let favs = favorites(), !favs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              // Premium favorites header
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  Text("⭐ Favorites")
                    .font(enhancedTitle2BoldFont)
                    .foregroundStyle(
                      LinearGradient(
                        colors: [Color.primary, Color.primary.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                      )
                    )

                  Text("Your most-loved games")
                    .font(enhancedCaptionMediumFont)
                    .foregroundColor(.secondary)
                }
                Spacer()

                // Subtle floating sparkle
                Image(systemName: "sparkles")
                  .font(.system(size: 16, weight: .light))
                  .foregroundColor(.yellow.opacity(0.7))
                  .scaleEffect(0.9)
              }
              .padding(.horizontal, paddingH)

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
                      isAutoPreCaching: autoPreCacheActive.contains(fav.filePath),
                      showSubtitles: showSubtitles
                    )
                  }
                }
                .padding(.horizontal, paddingH)
                .padding(.vertical, Constants.gridVerticalSpacing)
              }
              .background(
                // Refined material backdrop for favorites with proper clipping
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                  .fill(.ultraThinMaterial.opacity(0.2))
                  .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                      .stroke(.white.opacity(0.1), lineWidth: 1)
                  )
                  .padding(.horizontal, 12)
                  .clipped()
              )
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
                isAutoPreCaching: autoPreCacheActive.contains(item.filePath),
                showSubtitles: showSubtitles
              )
              .id(item.filePath)
              .overlay(
                RoundedRectangle(cornerRadius: 14)
                  .stroke(focusedFilePath == item.filePath ? Color.accentColor : Color.clear, lineWidth: 3)
              )
              .onChangeCompat(of: focusedFilePath) { _, newVal in
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
            if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] DPad Left -> index=\(newIndex)") }
          },
          onRight: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = min(displayGames.count - 1, idx + 1)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.last?.filePath)
            if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] DPad Right -> index=\(newIndex)") }
          },
          onUp: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = max(0, idx - count)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.first?.filePath)
            if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] DPad Up -> index=\(newIndex)") }
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
          emulationRunning = false
          if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] onAppear: controllers=\(GCController.controllers().count)") }
          // Library should own controller handlers; stop global observers to avoid overrides
          ControllerManager.shared.stopObserving()
          GCController.shouldMonitorBackgroundEvents = false
          for c in GCController.controllers() {
            c.extendedGamepad?.valueChangedHandler = nil
            c.microGamepad?.valueChangedHandler = nil
            c.extendedGamepad?.buttonMenu.pressedChangedHandler = { _, _, _ in /* swallow to avoid Game Center */ }
            c.microGamepad?.buttonMenu.pressedChangedHandler = { _, _, _ in /* swallow to avoid Game Center */ }
            if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] cleared handlers for \(c.vendorName ?? "(nil)")") }
            // Ensure microGamepad behaves sanely for library nav
            if let mg = c.microGamepad { mg.reportsAbsoluteDpadValues = true; mg.allowsRotation = true }
          }
          if GCController.controllers().isEmpty { GCController.startWirelessControllerDiscovery(completionHandler: {}) }
          if focusedFilePath == nil, let first = displayGames.first?.filePath { focusedFilePath = first }
          setupControllerNavigation(columns: count)
          emuStartObs = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main) { _ in
            emulationRunning = true
            teardownControllerNavigation()
          }
          emuEndObs = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidEndNotification"), object: nil, queue: .main) { _ in emulationRunning = false }
        }
        .task {
          gridColumnCount = count
          if !emulationRunning { setupControllerNavigation(columns: count) }
        }
        .onChangeCompat(of: count) { _, newVal in
          gridColumnCount = newVal
          if !emulationRunning { setupControllerNavigation(columns: newVal) }
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
        .onChangeCompat(of: displayGames.count) { _, newCount in
          if newCount > 0 && focusedFilePath == nil {
            DispatchQueue.main.async { focusedFilePath = displayGames.first?.filePath }
          }
        }
        .onDisappear {
          if let t = emuStartObs { NotificationCenter.default.removeObserver(t); emuStartObs = nil }
          if let t = emuEndObs { NotificationCenter.default.removeObserver(t); emuEndObs = nil }
          if let t = libGCConnectObs { NotificationCenter.default.removeObserver(t); libGCConnectObs = nil }
          if let t = libGCDisconnectObs { NotificationCenter.default.removeObserver(t); libGCDisconnectObs = nil }
          teardownControllerNavigation()
        }
      }
    }
  }
  #endif // !os(tvOS)

  @ViewBuilder
  private var emptyLibraryView: some View {
    ZStack {
      // Ambient swimming dolphins in the background
      SwimmingDolphinsView(count: 3, direction: .leftToRight, maxSize: 120, opacity: 0.22)
      SwimmingDolphinsView(count: 2, direction: .rightToLeft, maxSize: 100, opacity: 0.16)

      // Centered friendly message
      VStack(spacing: 20) {
        DolphinErrorView(
          title: L("Library Empty"),
          message: L("No games found. Add GameCube & Wii ROMs to your library to get started with iCube! 🎮")
        )
      }
      .padding()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  #if os(tvOS)
  @ToolbarContentBuilder
  private var libraryToolbar_tvOS: some ToolbarContent {
    ToolbarItem(placement: .navigationBarTrailing) {
      Button { showMoreMenu = true } label: { Image(systemName: "ellipsis.circle") }
        .buttonStyle(.automatic)
        .focusable(true)
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      let store = RemoteSourcesStore.shared
      if store.isScanning {
        VStack(spacing: 2) {
          DolphinProgressView(
            progress: store.scanningProgress,
            width: 80,
            direction: .leftToRight
          )
          Text("Refreshing…")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      Button(action: { model.rescan() }) {
        if model.isRescanning {
          DolphinCircularSpinner(size: 20, lineWidth: 2, dolphinSize: 8)
        } else {
          Label("", systemImage: "arrow.clockwise")
        }
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
  }
  #else // iOS
  @ToolbarContentBuilder
  private var libraryToolbar_iOS: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      let store = RemoteSourcesStore.shared
      if store.isScanning {
        // Show swimming dolphin progress instead of static logo
        DolphinProgressView(
          progress: store.scanningProgress,
          width: 140,
          direction: .leftToRight
        )
      } else {
        // Show static dolphin logo when not scanning
        Image("DolphinLogo")
          .resizable()
          .scaledToFit()
      }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      if #available(tvOS 17.0, iOS 14.0, *) {
        Menu {
          Button(action: { model.loadGameCubeMainMenu() }) {
            Label(L("Load GameCube Main Menu"), systemImage: "gamecontroller")
          }
          Button(action: { model.performOnlineSystemUpdate() }) {
            Label(L("Perform Online System Update"), systemImage: "arrow.triangle.2.circlepath")
          }
#if os(iOS)
          Button(action: {
            let role = UserDefaults.standard.string(forKey: "dsu_role") ?? "sender"
            if role == "receiver" {
              NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Switch role to Sender to start DSU Controller")])
            } else {
              showDSUSession = true
            }
          }) {
            Label(L("Start DSU Controller"), systemImage: "dot.radiowaves.left.and.right")
          }
#endif
          Button(action: {
#if os(iOS) || targetEnvironment(macCatalyst)
            showImportNANDPicker = true
#endif
          }) {
            Label(L("Import BootMii NAND Backup…"), systemImage: "tray.and.arrow.down")
          }
          Button(action: { showSources = true }) {
            Label(L("Sources"), systemImage: "externaldrive.badge.plus")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .tipAttachCompat(.importGame)
      } else {
        // Fallback for tvOS 16: Show most important action directly
        Button(action: { showSources = true }) {
          Image(systemName: "externaldrive.badge.plus")
        }
        .tipAttachCompat(.importGame)
      }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      Button(action: { model.rescan() }) {
        if model.isRescanning {
          DolphinCircularSpinner(size: 22, lineWidth: 2, dolphinSize: 9)
        } else {
          Label(L("Rescan"), systemImage: "arrow.clockwise")
        }
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
      .tipAttachCompat(.importGame)
      .help(L("Import Game"))
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      Button(action: {
#if os(iOS) || targetEnvironment(macCatalyst)
        navigateToSettings = true
#endif
      }) { Image(systemName: "gearshape") }
    }

  }
  #endif

  @ToolbarContentBuilder
  private var libraryToolbar: some ToolbarContent {
    #if os(tvOS)
    libraryToolbar_tvOS
    #else
    libraryToolbar_iOS
    #endif
  }

  var body: some View {
    NavigationStack {
      navigationConfiguration
    }
    // SaveStatesBrowserView presention
    .sheet(isPresented: $showSaveStatesBrowser) {
      NavigationStack { SaveStatesBrowserView() }
    }
    // DSU controller session (iOS only)
#if os(iOS)
    .sheet(isPresented: $showDSUSession) {
      if #available(iOS 17.0, *) {
        DSUSessionView()
      } else {
        // Fallback on earlier versions
      }
    }
#endif
    .onAppear {
      // Tips setup
      if #available(iOS 17, tvOS 17, *) {
        tipsService.configure()
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
      // Rescan library when a file import completes
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DOLImportFileFinishedNotification"), object: nil, queue: .main) { _ in
        model.rescan()
      }
      // Global DSU approval toast
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DSUNewClientApproval"), object: nil, queue: .main) { note in
        if let addr = note.userInfo?["address"] as? String { approvalBannerAddr = addr }
      }
      // First-run onboarding
      if !UserDefaults.standard.bool(forKey: "onboarding_seen_v1") {
        withAnimation { showOnboarding = true }
      }
    }
    .onDisappear {
      func removeAllObservers() {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLShowImportGame"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLShowSettings"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("GameFileMetadataUpdated"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLShowSnackbar"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLImportFileFinishedNotification"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DSUNewClientApproval"), object: nil)
      }
      removeAllObservers()
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
        CacheInfoView(item: item, showSubtitles: showSubtitles)
      }
      .overlay(blockingPrecacheOverlay)
      .overlay(offlineBanner)
#if os(iOS) || targetEnvironment(macCatalyst)
      .overlay(dropHighlight)
#endif
      .overlay(searchHintBanner)
      .overlay(snackbar)
      .overlay(dsuApprovalBanner)
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
  // DSU approval banner state
  @State private var approvalBannerAddr: String? = nil
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

  @ViewBuilder private var dsuApprovalBanner: some View {
    if let addr = approvalBannerAddr {
      VStack {
        HStack(spacing: 12) {
          Image(systemName: "antenna.radiowaves.left.and.right").foregroundColor(.white)
          VStack(alignment: .leading, spacing: 2) {
            Text(L("Receiver requests input")).foregroundColor(.white).font(.subheadline)
            Text(addr).foregroundColor(.white.opacity(0.9)).font(.caption)
          }
          Spacer()
          Button(L("Always Allow")) {
            DSUServerBridge.setClient(addr, allowed: true)
            approvalBannerAddr = nil
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Always allowed %@"), addr)])
          }
          .buttonStyle(.borderedProminent)
          Button(L("Block")) {
            DSUServerBridge.setClient(addr, allowed: false)
            approvalBannerAddr = nil
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Blocked %@"), addr)])
          }
          .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 8)
        .padding(.horizontal, 12)
        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture {
        // Open DSU Controller sheet for details
#if os(iOS)
        showDSUSession = true
#endif
        // Dismiss the banner after opening
        approvalBannerAddr = nil
      }
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  @ViewBuilder private var offlineBanner: some View {
    // Only surface a source that is reachable (the host answered our probe) but returning errors —
    // e.g. bad auth, wrong path, a 5xx. A source that's simply unreachable because we're off its
    // network is NOT worth nagging about every boot, so it's excluded (serverReachable == false).
    let anyServerError = storeForBanner.sources.contains { (src) -> Bool in
      guard let w = src as? WebDAVSource else { return false }
      return w.isOnline == false && w.serverReachable
    }
    if anyServerError && !offlineBannerDismissed {
      VStack {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.icloud").foregroundStyle(.white)
          Text(L("A remote source is reachable but returning errors. Retrying…")).foregroundStyle(.white)
            .lineLimit(2)
          Spacer(minLength: 8)
          Button(action: { withAnimation { offlineBannerDismissed = true } }) {
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
        .onAppear {
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation { offlineBannerDismissed = true }
          }
        }
        Spacer()
      }
      .transition(.move(edge: .top).combined(with: .opacity))
    } else if !anyServerError && offlineBannerDismissed {
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

          DolphinCircularSpinner(
            size: 64,
            lineWidth: 8,
            dolphinSize: 20,
            progress: blockingPrecacheProgress
          )
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
            Text(L("Welcome to iCube"))
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
            .tint(Color("DolphinTint"))

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

          // Lineage / credits — iCube is a downstream fork; credit the projects it builds on.
          VStack(spacing: 4) {
            Text(L("iCube is a fork of DolphiniOS, based on the Dolphin emulator."))
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.6))
              .multilineTextAlignment(.center)
#if os(iOS) || targetEnvironment(macCatalyst)
            HStack(spacing: 16) {
              if let u = URL(string: "https://dolphinios.oatmealdome.me") {
                Link("DolphiniOS", destination: u)
              }
              if let u = URL(string: "https://dolphin-emu.org") {
                Link("Dolphin", destination: u)
              }
            }
            .font(.caption2.weight(.semibold))
            .tint(Color("DolphinTint"))
#endif
          }
          .padding(.top, 6)
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
        let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: 0)
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
      c.extendedGamepad?.buttonMenu.pressedChangedHandler = { _, _, _ in /* swallow to avoid Game Center */ }
      c.microGamepad?.buttonMenu.pressedChangedHandler = { _, _, _ in /* swallow to avoid Game Center */ }

      if let egp = c.extendedGamepad {
        let cid = ObjectIdentifier(c)
        if prevEGPHandlers[cid] == nil { prevEGPHandlers[cid] = egp.valueChangedHandler }
        egp.valueChangedHandler = { (gamepad: GCExtendedGamepad, element: GCControllerElement) in
          guard !model.games.isEmpty else { return }
          let index: Int = {
            if let current = focusedFilePath, let idx = model.games.firstIndex(where: { $0.filePath == current }) { return idx }
            return 0
          }()
          func move(_ delta: Int, dir: String) {
            let now = Date().timeIntervalSince1970
            if now - lastNavMoveTime < navRepeatInterval { return }
            lastNavMoveTime = now
            DispatchQueue.main.async {
              let newIndex = max(0, min(index + delta, model.games.count - 1))
              focusedFilePath = model.games[newIndex].filePath
            }
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
          guard !model.games.isEmpty else { return }
          let index: Int = {
            if let current = focusedFilePath, let idx = model.games.firstIndex(where: { $0.filePath == current }) { return idx }
            return 0
          }()
          func move(_ delta: Int, dir: String) {
            let now = Date().timeIntervalSince1970
            if now - lastNavMoveTime < navRepeatInterval { return }
            lastNavMoveTime = now
            DispatchQueue.main.async {
              let newIndex = max(0, min(index + delta, model.games.count - 1))
              focusedFilePath = model.games[newIndex].filePath
            }
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
      c.extendedGamepad?.buttonMenu.pressedChangedHandler = nil
      c.microGamepad?.buttonMenu.pressedChangedHandler = nil
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

// MARK: - Source Picker

@MainActor
func getMatchingWebDAVSource(for url: URL) -> WebDAVSource? {
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

#if os(iOS)
/// Minimal share sheet wrapper
struct ShareSheet: UIViewControllerRepresentable {
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
      DolphinProgressView(
        progress: store.scanningProgress,
        width: 200,
        showPercentage: true,
        direction: .leftToRight
      )
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

// MARK: - Compatibility Helpers (iOS 16)

private enum TipKind { case importGame, addSource, search }

private extension View {
  @ViewBuilder
  func onChangeCompat<T: Equatable>(of value: T, initial: Bool = false,
                                    _ handler: @escaping (_ old: T?, _ new: T) -> Void) -> some View {
    if #available(iOS 17, tvOS 17, *) {
      self.onChange(of: value, initial: initial, handler)
    } else {
      self.onChange(of: value) { new in handler(nil, new) }
    }
  }

  @ViewBuilder
  func navigationDestinationItemCompat<Item: Identifiable, Destination: View>(item: Binding<Item?>,
                                                                              @ViewBuilder destination: @escaping (Item) -> Destination) -> some View {
    self.background(
      NavigationLink(
        destination: Group {
          if let it = item.wrappedValue { destination(it) } else { EmptyView() }
        },
        isActive: Binding(get: { item.wrappedValue != nil }, set: { active in if !active { item.wrappedValue = nil } })
      ) { EmptyView() }
        .hidden()
    )
  }

  @ViewBuilder
  func tipAttachCompat(_ kind: TipKind) -> some View {
#if canImport(TipKit)
    if #available(iOS 17, tvOS 17, *) {
      let mapped: AttachTipModifier.Kind = {
        switch kind {
        case .importGame: return .importGame
        case .addSource: return .addSource
        case .search: return .search
        }
      }()
      self.modifier(AttachTipModifier.tip(mapped))
    } else {
      self
    }
#else
    self
#endif
  }
}

/// iOS 16.0+ tracking modifier for backward compatibility
struct iOS16TrackingModifier: ViewModifier {
  let tracking: CGFloat

  func body(content: Content) -> some View {
    content.tracking(tracking)
  }
}

/// iOS 16.0+ navigation styling modifier for backward compatibility
struct iOS16NavigationStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
#if !os(tvOS)
      .scrollContentBackground(.hidden)
#endif
  }
}
