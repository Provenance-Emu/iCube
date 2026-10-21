// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if os(iOS)
#endif

internal enum PlatformKind { case ios, tvos }

/// The television submenu stays inside the pause session and its existing pause token.
enum PausePerfHUDRoute {
  static func open(platform: PlatformKind, openSubmenu: () -> Void,
                   closePause: () -> Void, openTouchOverlay: () -> Void) {
    switch platform {
    case .tvos: openSubmenu()
    case .ios: closePause(); openTouchOverlay()
    }
  }
}

internal struct PauseMenuView: View {
  @Binding var selectedSlot: Int
  @AppStorage("quick_save_mode") private var quickSaveMode: QuickSaveMode = .history
  let onClose: () -> Void
  var onShowPerfOverlay: () -> Void = {}
  let platform: PlatformKind
  let game: TVGameItem
  var startsInSaveBrowser = false
  @State private var initialSaveBrowserConsumed = false
  @State private var showSharedSaveBrowser = false
  @State private var openingSaveSession: UInt64?

  @FocusState private var focused: FocusField?
  internal enum FocusField: Hashable {
    case back, slot(Int), save, load
    /// D10: the tvOS saves pane's "View All States" button, into the redesigned
    /// grid (`SaveStateFilmstripView`) -- previously iOS-only.
    case filmstrip
  }
  private enum Pane { case main, saves, cheats, controllers, discs, perfHUD }
  /// The quick-slot picker's slots, numbered as the UI shows them.
  static let saveSlots = 1 ... PauseMenuModelBuilder.slotCount
  @State private var pane: Pane = .main
  #if DEBUG
  /// `-ICubePausePane <saves|cheats|controllers|reset|exit>`: open a sub-pane for simulator screenshots.
  var debugInitialPane: String?
  /// onAppear re-runs after every child sheet closes; the debug pane applies once.
  @State private var debugInitialPaneConsumed = false
  /// `-ICubePauseFocus <slot-N|view-all>`: where the Save States pane's focus lands, so a screenshot can show a
  /// focused tile (simctl cannot press the remote). Parsed by `TVSaveSlotsPane.debugFocus`.
  var debugInitialFocus: String?
  /// `-ICubePauseLongPress <tileID>`: run that tile's long-press once the menu is up (e.g. Upscaling opens Settings on
  /// its row), so a simulator screenshot shows the real sheet path.
  var debugLongPressTileID: String?
  #endif
  @State private var showExitDialog: Bool = false
  @State private var showResetDialog: Bool = false
  @State private var quitSaveFailure: UserQuitSaveFailure?
  @State private var quitRequestInFlight = false
  @State private var quitExpectedGameID = ""
  @State private var quitExpectedSessionIdentifier: UInt64 = 0
  @State private var showShaders: Bool = false
  /// Settings over the pause menu (a sheet on iOS, a cover on tvOS), opened by the Settings tile or a tile's
  /// long-press. The menu presents it itself: a second cover from `EmulationScreen` cannot show while this one is up.
  @State private var showSettings: Bool = false
  /// Where Settings opens; nil opens the root.
  @State private var settingsLink: SettingsDeepLink?
  @State private var showControllersSheet: Bool = false
  /// Recenter Pointer is offered for a running Wii title on iOS, where touch or the gyro drives it.
  private static var showsRecenterPointer: Bool {
    #if os(iOS)
    return TVEmulationBridge.isRunning() && TVEmulationBridge.isCurrentSystemWii()
    #else
    return false
    #endif
  }

  @State private var showFilmstripSheet: Bool = false
  /// tvOS: the pause tile focused last, so Back from a pane lands on the tile that opened it.
  @State private var tvLastFocusID: String?
  /// When the menu first appeared; `BackCoalescer` drops the Back press that opened it.
  @State private var openedAt = Date()
  /// "None" first, then recent presets; backs the Shaders tile's cycle.
  @State private var shaderOptions: [(String, AnyHashable)] = []
  /// WS-4: "continue this game on another device".
  @State private var showContinuitySheet: Bool = false
  /// Mirrors of the live Dolphin values behind the Upscaling and Audio tiles; the bridge is read on appear and
  /// written through the bindings, so the cycle tiles redraw without polling.
  @State private var internalResolution: Int = 1
  @State private var metalFXUpscale: Bool = false
  @State private var audioVolume: Int = 100
  /// The cover-column chip: the engine actually running.
  @State private var engineShortName: String = ""
  @State private var jitAcquired: Bool = false
  /// The Performance tile's value: the engine the next launch uses (`CpuEngine` raw value).
  @State private var nextEngine: Int = CpuEngine.cachedInterpreter.rawValue
  /// Mirror of `PerfHUDToggle.isOn` behind the Performance HUD tile.
  @State private var perfHUDOn: Bool = false
  @State private var perfHUDFlags = PerfHUDToggle.Flags()
  @Environment(\.verticalSizeClass) private var verticalSizeClass

  /// True while any sheet, full-screen cover, or non-main pane owned by this menu is
  /// up. Gates the resume-on-disappear below (B1): every one of these presentations
  /// can report an onDisappear on the outer ZStack while it is on screen, and none of
  /// them should resume the game underneath.
  private var isPauseMenuChildPresented: Bool {
    if quitSaveFailure != nil { return true }
    if pane != .main { return true }
    if showShaders || showContinuitySheet || showFilmstripSheet || showSettings { return true }
    #if os(iOS)
    if showControllersSheet { return true }
    #else
    // tvOS asks with the system confirmation dialog, which can disappear the menu under it like a sheet.
    if showExitDialog || showResetDialog { return true }
    #endif
    return false
  }

  // Quick actions: the two things people actually reach for mid-game without
  // wanting to leave the pause menu (mute to take a call, fast-forward past a
  // cutscene). Mute is a toggle tile and fast-forward a cycle tile on the main
  // pane rather than a settings trip. Mute is shared with the in-game top bar
  // via `QuickMute`.
  @State private var isMuted: Bool = false
  /// Observed so the Record tile's toggle and REC badge follow the recorder.
  @ObservedObject private var recorder = RecordingManager.shared
  @State private var fastForward = PauseFastForwardState(isEnabled: false, percent: ConfigGeneralState.storedFastForward(nil))
  /// This menu's hold on the pause (spec §4.3). Adopted from the gesture tracker's pending claim when
  /// there is one, otherwise claimed here. Released only on a real teardown, see `onDisappear`.
  @State private var pauseToken: PauseArbiter.Token?
  /// D15: "N active" badge on the Cheats item. Refreshed on appear and whenever the
  /// pane returns to `.main` (including from the Cheats pane itself), so toggling a
  /// cheat and backing out updates the count without needing a manual refresh.
  @State private var activeCheatCount: Int = 0
  private func refreshEngineState() {
    jitAcquired = JitManager.shared().acquiredJit
    engineShortName = CpuEngine.resolved(stored: CpuEngine.from(raw: DOLConfigBridge.mainCpuCore()), acquiredJit: jitAcquired).shortName
    nextEngine = CpuEngine.resolved(stored: CpuEngine.from(raw: DOLConfigBridge.mainCpuCoreBase()), acquiredJit: jitAcquired).rawValue
  }

  private func refreshLiveSettings() {
    internalResolution = TVEmulationBridge.internalResolution()
    metalFXUpscale = DOLConfigBridge.gfxMetalFXSpatialUpscale()
    audioVolume = TVEmulationBridge.audioVolumePercent()
    perfHUDFlags = PerfHUDToggle.read()
    perfHUDOn = perfHUDFlags.isOn
    refreshEngineState()
  }

  private func refreshActiveCheatCount() {
    activeCheatCount = CheatsMenuView.activeCheatCount(forGameId: game.gameID, revision: game.revision)
  }

  private var perfHUDMenuModel: MenuModel {
    // Track every flag, including changes that leave the master switch on. The binding getters
    // still read Config directly so repeated actions never capture an old snapshot.
    _ = perfHUDFlags
    return PauseMenuModelBuilder.perfHUDModel()
  }

  private func closePerfHUDSubmenu() {
    tvLastFocusID = "perf-hud"
    refreshLiveSettings()
    pane = .main
  }

  /// Mutes / unmutes through the helper the top bar shares, so both always agree.
  private func toggleMute() {
    isMuted = QuickMute.toggle()
  }

  var body: some View {
    ZStack {
      #if os(tvOS)
      // iFly's full-bleed room behind every pane, edge to edge: no black pillars at the sides.
      ICubeTVRoomBackground(art: game.bannerImage ?? (game.hasCoverArt ? game.coverImage : nil))
        .environment(\.colorScheme, .dark)
      #else
      // Full screen black background
      Color.black
        .ignoresSafeArea()
      #endif

      switch pane {
      case .main:
        mainMenu
          .onAppear { NSLog("[PAUSE] Main menu appeared") }
      case .perfHUD:
        MenuScreen(model: perfHUDMenuModel, style: .list,
                   onBack: { closePerfHUDSubmenu() },
                   tvHeader: ICubeLeafHeader(title: L("Performance HUD"), subtitle: L("Pause Menu")),
                   tvClaimsFocus: true)
          .frame(maxWidth: 1000)
      case .saves:
        savesMenu
          .onAppear { NSLog("[PAUSE] Saves menu appeared") }
      case .cheats:
        CheatsMenuView(game: game, onBack: { pane = .main })
          .onAppear { NSLog("[PAUSE] Cheats menu appeared") }
      case .discs:
        DiscChangePicker(games: TVLibraryBridge.currentGames(), isWii: TVEmulationBridge.isCurrentSystemWii(), onBack: { pane = .main })
      #if os(tvOS)
      case .controllers:
        // Menu at the hub's root returns to the pause menu (`onBack`, through MenuScreen's own
        // `.onExitCommand`); Menu on a pushed player screen pops just that screen.
        NavigationStack {
          ControllerHubView(system: .forRunningGame, onBack: { pane = .main })
        }
        .onAppear { NSLog("[PAUSE] Controllers hub appeared") }
      #else
      case .controllers:
        mainMenu
      #endif
      }
    }
    .overlay {
      if quitRequestInFlight {
        ProgressView(L("Saving…"))
          .padding(ICubeDesign.Spacing.l.rawValue)
          .icubePanel()
      }
    }
    .onAppear {
      NSLog("[PAUSE] PauseMenuView appeared")
      #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
      GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
      #endif
      // Grab the last live frame for a save thumbnail BEFORE pausing, so a save made
      // from this menu still gets a screenshot even though presenting is about to stop.
      SaveStateService.capturePausePreview()
      // onAppear runs again each time a child sheet closes: keep the token we already hold.
      if pauseToken == nil {
        pauseToken = PauseArbiter.shared.adoptPending() ?? PauseArbiter.shared.claim(PauseArbiter.Reason.pauseMenu)
        openedAt = Date()
      }
      if openingSaveSession == nil { openingSaveSession = TVEmulationBridge.currentSessionIdentifier() }
      if startsInSaveBrowser && !initialSaveBrowserConsumed {
        initialSaveBrowserConsumed = true
        openSharedSaveBrowser()
      }
      isMuted = QuickMute.isMuted
      fastForward = PauseFastForwardState(
        isEnabled: TVEmulationBridge.isFastForwardEnabled(),
        percent: ConfigGeneralState.storedFastForward(UserDefaults.standard.object(forKey: ConfigGeneralDefaultsKey.fastForwardSpeedPercent) as? Int))
      refreshActiveCheatCount()
      refreshShaderState()
      refreshLiveSettings()
      #if DEBUG
      if !debugInitialPaneConsumed {
        debugInitialPaneConsumed = true
        switch debugInitialPane {
        case "saves": pane = .saves
        case "cheats": pane = .cheats
        case "controllers": pane = .controllers
        case "reset": showResetDialog = true
        case "exit": showExitDialog = true
        case "discs": pane = .discs
        default: break
        }
        if let id = debugLongPressTileID, case .action(let run)? = pauseMenuModel.item(id: id)?.effectiveLongPress {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run() }
        }
      }
      #endif
    }
    .onDisappear {
      // `.sheet`/`.fullScreenCover` presentation (Shaders, Settings, Controllers,
      // Continuity, the save-state Filmstrip) and the tvOS Controllers/Saves/Cheats
      // panes all report an onDisappear on this outer ZStack while they are the ones
      // actually on screen — SwiftUI treats the covered presenter as "disappeared"
      // even though it is still mounted underneath. Resuming unconditionally here
      // meant opening any of those from the pause menu resumed emulation while the
      // menu (or its sheet) was still visible. Only resume when nothing else from
      // this menu is currently presented — i.e. this is a real teardown (Resume,
      // Exit, or the parent dismissing the whole menu), not a covering child.
      guard !isPauseMenuChildPresented else { return }
      openingSaveSession = nil
      if let token = pauseToken {
        PauseArbiter.shared.release(token)
        pauseToken = nil
      }
    }
    #if os(tvOS)
    .focusSection()
    .environment(\.icubePlatformAccent, platformAccent)
    #endif
    .onChange(of: pane) { _, newPane in
      DispatchQueue.main.async {
        switch newPane {
        case .main:
          // D15: covers backing out of Cheats (toggled codes should update the
          // badge) as well as the other panes, which is a harmless extra read.
          refreshActiveCheatCount()
          refreshEngineState()
        case .saves:
          // `TVSaveSlotsPane` puts focus on the quick slot itself.
          break
        case .cheats:
          focused = .back
        case .controllers:
          focused = .back
        case .discs, .perfHUD:
          break
        }
      }
    }
    #if os(tvOS)
    .onReceive(NotificationCenter.default.publisher(for: .DOLConfigChanged)) { _ in
      refreshLiveSettings()
    }
    #endif
    .onChange(of: showShaders) { _, shown in
      if !shown { refreshShaderState() }
    }
    #if os(tvOS)
    .onExitCommand {
      guard !quitRequestInFlight else { return }
      // At .main the tile grid's own onBack closes (coalesced), and the confirm overlays handle theirs.
      if pane == .perfHUD { closePerfHUDSubmenu() }
      else if pane != .main { pane = .main }
    }
    // Spec §5.3: Play/Pause on the remote resumes, from any pane.
    .onPlayPauseCommand {
      guard !quitRequestInFlight else { return }
      PauseArbiter.shared.userResume()
      onClose()
    }
    #endif
    // D16: the pause menu gets the quick-preview picker (tap a card to apply,
    // long-press or its gear button for parameters) rather than the full
    // Settings-style `ShaderSettingsView` list — that view (and its debug tools)
    // is still reachable from Settings > Shaders and the in-game FX sheet.
    .sheet(isPresented: $showShaders) {
      NavigationStack {
        ShaderQuickPickerView()
      }
      .pauseClaim("shaders")
      #if os(tvOS)
      .focusSection()
      #endif
      // Claims the controller so the pause menu's own raw handler
      // (`setupPauseControllerNav`) stops driving the row list underneath.
      .claimsController()
    }
    #if os(iOS)
    .sheet(isPresented: $showSettings, onDismiss: settingsClosed) {
      // Not wrapped in a NavigationStack: Settings owns its stack, and a second one around it left a leaf
      // opened directly (a tile's long-press) on screen with neither Back nor B able to pop it.
      SettingsRootView(initialLeafID: settingsLink?.leafID, initialRowID: settingsLink?.rowID, onClose: { showSettings = false })
        .pauseClaim("settings")
        .claimsController()
    }
    .sheet(isPresented: $showControllersSheet) {
      NavigationStack {
        ControllerHubView(system: .forRunningGame, onBack: { showControllersSheet = false })
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Close")) { showControllersSheet = false } } }
      }
      .pauseClaim("controllers")
      .claimsController()
    }
    #else
    // Menu at the sidebar closes it (`SettingsSidebarShell`); the pause menu is underneath again.
    .fullScreenCover(isPresented: $showSettings, onDismiss: settingsClosed) {
      SettingsRootView(initialLeafID: settingsLink?.leafID, initialRowID: settingsLink?.rowID)
        .pauseClaim("settings")
        .interactiveDismissDisabled(true)
    }
    #endif
    // WS-4 sender surface. Unconditional (not #if os(iOS)): tvOS has no system
    // Handoff, so the in-app offer is the ONLY way an Apple TV can hand a game
    // to another device.
    .sheet(isPresented: $showContinuitySheet) {
      ContinuityHandoffSheet(game: game)
        .pauseClaim("continuity")
        .claimsController()
    }
  }

  #if DEBUG
  func debugPane(_ pane: String?) -> PauseMenuView { var copy = self; copy.debugInitialPane = pane; return copy }
  func debugFocus(_ focus: String?) -> PauseMenuView { var copy = self; copy.debugInitialFocus = focus; return copy }
  func debugLongPress(_ tileID: String?) -> PauseMenuView { var copy = self; copy.debugLongPressTileID = tileID; return copy }

  #endif

  // Add pull-down to dismiss for iOS
  #if os(iOS)
  init(selectedSlot: Binding<Int>, onClose: @escaping () -> Void, onShowPerfOverlay: @escaping () -> Void = {}, platform: PlatformKind, game: TVGameItem) {
    self._selectedSlot = selectedSlot
    self.onClose = onClose
    self.onShowPerfOverlay = onShowPerfOverlay
    self.platform = platform
    self.game = game
  }
  #endif

  /// tvOS: iFly's pause grid (`TVPauseGridView`). iOS: a compact header above the tile grid.
  @ViewBuilder
  private var mainMenu: some View {
    #if os(tvOS)
    tvMainMenu
    #else
    touchMainMenu
    #endif
  }

  #if os(tvOS)
  private var tvMainMenu: some View {
    ZStack {
      TVPauseGridView(model: PauseMenuModelBuilder.primaryLayout(pauseMenuModel), lastFocusID: $tvLastFocusID, onBack: {
        guard !quitRequestInFlight else { return }
        guard BackCoalescer.shouldHonor(openedAt: openedAt, now: Date()) else { return }
        onClose()
      }) {
        coverColumn
      }
      EmulationToastOverlay(barHeight: 0, barVisible: false)
    }
    .environment(\.colorScheme, .dark)
    // The system dialog, as iFly's Quit and Hard Restart: the focus engine owns it, and Menu cancels it. Each action
    // clears its flag first: a flag still up when the action closes the menu holds the pause (`isPauseMenuChildPresented`).
    .confirmationDialog(L("Exit Game"), isPresented: $showExitDialog, titleVisibility: .visible) {
      Button(L("Save & Quit")) { showExitDialog = false; saveAndQuit() }
      Button(L("Quit"), role: .destructive) { showExitDialog = false; quitGame() }
      Button(L("Cancel"), role: .cancel) {}
    } message: {
      Text(L("Do you want to quit the game? Unsaved progress will be lost."))
    }
    .confirmationDialog(L("Reset System"), isPresented: $showResetDialog, titleVisibility: .visible) {
      Button(L("Reset"), role: .destructive) { showResetDialog = false; resetGame() }
      Button(L("Cancel"), role: .cancel) {}
    } message: {
      Text(L("Restart the game as if the console's reset button was pressed? Unsaved progress will be lost."))
    }
    .confirmationDialog(L("Couldn't save before quitting"), isPresented: Binding(
      get: { quitSaveFailure != nil }, set: { if !$0 { quitSaveFailure = nil } }), titleVisibility: .visible) {
      if let failure = quitSaveFailure {
        Button(L("Retry")) { quitSaveFailure = nil; retryQuit(failure) }
        Button(L("Quit Without Saving"), role: .destructive) { quitSaveFailure = nil; quitWithoutSaving() }
        Button(L("Cancel"), role: .cancel) { quitSaveFailure = nil }
      }
    } message: {
      Text(L("Retry the save or choose Quit Without Saving. Unsaved progress will be lost."))
    }
  }
  #endif

  private var touchMainMenu: some View {
    GeometryReader { proxy in
      let compactHeight = isCompactHeight
      let hero = PauseTileLayout.touchHero(width: proxy.size.width, isCompactHeight: compactHeight)
      let columns = PauseTileLayout.cardColumns(forGridWidth: proxy.size.width - hero.columnWidth - hero.gap - 2 * Touch.margin)
      ZStack {
        Group {
          if hero.columnWidth > 0 {
            HStack(alignment: .top, spacing: hero.gap) {
              VStack(alignment: .leading, spacing: ICubeDesign.Spacing.m.rawValue) {
                closeButton
                PauseHeroView(game: game, layout: compactHeight ? .textOnly : .column(artWidth: Touch.heroArtWidth),
                              engineChip: engineChipText, jitAcquired: jitAcquired)
                Spacer(minLength: 0)
              }
              .frame(width: hero.columnWidth, alignment: .leading)
              tiles(columns: columns, compact: compactHeight)
            }
          } else {
            VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
              HStack(alignment: .top, spacing: ICubeDesign.Spacing.s.rawValue) {
                PauseHeroView(game: game, layout: .banner, engineChip: engineChipText, jitAcquired: jitAcquired)
                Spacer(minLength: 0)
                closeButton
              }
              tiles(columns: columns, compact: compactHeight)
            }
          }
        }
        .padding(.horizontal, Touch.margin)
        .padding(.top, Touch.topMargin)
        // Reset/Exit are in-place `MenuScreen` overlays: each self-claims its own coordinator scope on appear,
        // so the tiles underneath stop reacting for as long as one is up, and unlike a `.sheet` this never
        // touches `isPauseMenuChildPresented`.
        if showResetDialog {
          confirmOverlay(title: L("Reset System"),
                         message: L("Restart the game as if the console's reset button was pressed? Unsaved progress will be lost."),
                         model: resetConfirmModel, onBack: { showResetDialog = false })
        }
        if showExitDialog {
          confirmOverlay(title: L("Exit Game"), message: L("Do you want to quit the game? Unsaved progress will be lost."),
                         model: exitConfirmModel, onBack: { showExitDialog = false })
        }
        if let failure = quitSaveFailure {
          confirmOverlay(title: L("Couldn't save before quitting"),
                         message: L("Retry the save or choose Quit Without Saving. Unsaved progress will be lost."),
                         model: UserQuitFailureModelBuilder.make(cancel: { quitSaveFailure = nil },
                           retry: { quitSaveFailure = nil; retryQuit(failure) },
                           quitWithoutSaving: { quitSaveFailure = nil; self.quitWithoutSaving() }),
                         onBack: { quitSaveFailure = nil })
        }
        EmulationToastOverlay(barHeight: 0, barVisible: false)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      // A background, not a ZStack sibling: the fill-scaled art would otherwise widen the ZStack past the window.
      .background { ICubeTVRoomBackground(art: game.bannerImage ?? (game.hasCoverArt ? game.coverImage : nil)) }
    }
    // `MenuScreen` row text takes no explicit color; pin the dark-mode values so titles stay legible over the
    // always-dark room whatever the system appearance. `.environment`, not `.preferredColorScheme`, so the
    // Settings/Controllers/Shaders sheets opened from here are unaffected.
    .environment(\.colorScheme, .dark)
    .environment(\.icubePlatformAccent, platformAccent)
  }

  /// iPhone/iPad pause screen geometry.
  private enum Touch {
    static let margin: CGFloat = 16
    static let topMargin: CGFloat = 8
    static let heroArtWidth: CGFloat = 180
  }

  private var closeButton: some View {
    Button(action: { if !quitRequestInFlight { onClose() } }) {
      Label(L("Close"), systemImage: "xmark")
        .labelStyle(.iconOnly)
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(ICubeDesign.color(.textPrimary))
        .frame(width: 36, height: 36)
        .background(Circle().fill(ICubeDesign.Card.surface.opacity(ICubeDesign.Card.restFillOpacity)))
        .overlay(Circle().strokeBorder(ICubeDesign.color(.accent).opacity(ICubeDesign.Card.restBorderOpacity),
                                       lineWidth: ICubeDesign.Line.hairline.rawValue))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L("Close"))
  }

  /// True for iPhone landscape; never on tvOS.
  private var isCompactHeight: Bool {
    #if os(iOS)
    return verticalSizeClass == .compact
    #else
    return false
    #endif
  }

  private func tiles(columns: Int, compact: Bool) -> some View {
    // Modal while a confirm overlay is up: on tvOS the focus engine can otherwise land back on a tile.
    let confirmUp = showResetDialog || showExitDialog || quitSaveFailure != nil || quitRequestInFlight
    return MenuScreen(model: PauseMenuModelBuilder.primaryLayout(pauseMenuModel), style: .cards(columns: columns, compact: compact), onBack: {
      guard !quitRequestInFlight else { return }
      guard BackCoalescer.shouldHonor(openedAt: openedAt, now: Date()) else { return }
      onClose()
    })
    .disabled(confirmUp)
    .allowsHitTesting(!confirmUp)
  }

  /// The running game's platform (the user's library override wins): tile badges, chips and the hero use its colour.
  private var gamePlatform: LibraryPlatformCategory {
    LibraryPlatformMapper.category(for: game, override: LibraryPlatformOverrideStore.load()[game.filePath])
  }

  private var platformAccent: Color { ICubeDesign.platformAccent(gamePlatform) }

  /// "JIT ON" while the JIT is acquired, otherwise the engine that is running (INT, CIR, CIR-IR).
  private var engineChipText: String { jitAcquired ? L("JIT ON") : engineShortName }

  /// tvOS hero (iFly layout, iCube tokens): cover, PAUSED in accent, the game title in the display face, its ID.
  private var coverColumn: some View {
    PauseHeroView(game: game, layout: .column(artWidth: ICubeDesign.TVPause.heroArtWidth),
                  engineChip: engineChipText, jitAcquired: jitAcquired)
  }

  private var isTV: Bool { platform == .tvos }

  /// Settings may have changed what the tiles show (volume, scale, the engine).
  private func settingsClosed() {
    settingsLink = nil
    refreshLiveSettings()
  }

  private func confirmOverlay(title: String, message: String, model: MenuModel, onBack: @escaping () -> Void) -> some View {
    ICubeConfirmPanel(title: title, message: message, model: model, isTV: isTV, onBack: onBack)
  }

  private func openSharedSaveBrowser() {
    showSharedSaveBrowser = true
    pane = .saves
  }

  private var quickSaveActions: QuickSaveMenuActions {
    QuickSaveMenuActions(mode: { quickSaveMode }, slot: { selectedSlot },
      session: .init(gameID: game.gameID, identifier: openingSaveSession ?? TVEmulationBridge.currentSessionIdentifier()),
      isActive: { pauseToken != nil && openingSaveSession != nil }, openBrowser: openSharedSaveBrowser,
      report: { EmulationToast.post($0.message) })
  }

  private var savesMenu: some View {
    Group {
      if platform == .ios || showSharedSaveBrowser {
        QuickSavePickerView(gameID: game.gameID, mode: $quickSaveMode, selectedSlot: $selectedSlot,
                            onDismiss: { pane = .main; showSharedSaveBrowser = false })
          .claimsController()
      } else {
        tvHeroLayout {
          TVSaveSlotsPane(game: game, selectedSlot: $selectedSlot, initialFocus: debugSavesFocus,
                          onViewAll: { showFilmstripSheet = true })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.icubePlatformAccent, platformAccent)
        .sheet(isPresented: $showFilmstripSheet) {
          QuickSavePickerView(gameID: game.gameID, mode: $quickSaveMode, selectedSlot: $selectedSlot,
                              onDismiss: { showFilmstripSheet = false })
            .pauseClaim("save-browser")
            .claimsController()
        }
      }
    }
  }

  private var debugSavesFocus: TVSaveSlotsPane.Focus? {
    #if DEBUG
    TVSaveSlotsPane.debugFocus(debugInitialFocus)
    #else
    nil
    #endif
  }

  /// tvOS Save States: the hero column (cover, PAUSED, title) beside `content`, at the pause grid's hero width and
  /// margins (`TVPauseGridView`), so opening the pane keeps the hero where it was.
  private func tvHeroLayout<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(alignment: .center, spacing: ICubeDesign.TVPause.heroGap) {
      coverColumn
        .frame(width: ICubeDesign.TVPause.heroWidth, alignment: .leading)
        // The grid's hero is centred above its footer; this pane's shelf sits in `content`, so lift the hero by
        // the footer band to keep it still when the pane opens.
        .padding(.bottom, ICubeDesign.TVPause.footerHeight + ICubeDesign.TVPause.footerGap)
      content()
    }
    .padding(.horizontal, ICubeDesign.TVPause.horizontalMargin)
    .padding(.top, ICubeDesign.TVPause.topMargin)
    .padding(.bottom, ICubeDesign.TVPause.bottomMargin)
    .ignoresSafeArea()
  }

  // MARK: - Pause menu model

  /// Carries out what a fast-forward tile selection decided; the game picks it up when the player resumes.
  private func applyFastForward(_ effect: PauseFastForwardState.Effect) {
    switch effect {
    case .setSpeed(let percent):
      TVEmulationBridge.setFastForwardSpeedPercent(percent)
      if !TVEmulationBridge.isFastForwardEnabled() { _ = TVEmulationBridge.toggleFastForward() }
    case .turnOff:
      if TVEmulationBridge.isFastForwardEnabled() { _ = TVEmulationBridge.toggleFastForward() }
    }
  }

  private var pauseMenuBindings: PauseMenuBindings {
    PauseMenuBindings(
      mute: Binding(get: { isMuted }, set: { _ in toggleMute() }),
      fastForward: Binding(get: { fastForward.selection }, set: { applyFastForward(fastForward.select($0)) }),
      quickSlot: Binding(get: { AnyHashable(selectedSlot) }, set: { if let slot = $0 as? Int { selectedSlot = slot } }),
      shader: Binding(
        get: { AnyHashable(ShaderQuickApply.currentPath ?? "") },
        set: { value in
          let path = value as? String
          ShaderQuickApply.apply(path: (path?.isEmpty ?? true) ? nil : path)
          refreshShaderState()
        }),
      internalResolution: Binding(
        get: { AnyHashable(internalResolution) },
        set: { value in
          guard let scale = value as? Int else { return }
          TVEmulationBridge.setInternalResolution(scale)
          internalResolution = scale
        }),
      metalFX: Binding(
        get: { metalFXUpscale },
        set: { DOLConfigBridge.setGfxMetalFXSpatialUpscale($0); metalFXUpscale = $0 }),
      audioVolume: Binding(
        get: { AnyHashable(audioVolume) },
        set: { value in
          guard let percent = value as? Int else { return }
          TVEmulationBridge.setAudioVolumePercent(percent)
          audioVolume = percent
        }),
      recording: Binding(get: { recorder.isRecording }, set: { RecordingToggle.set($0) }),
      perfHUD: Binding(get: { perfHUDOn }, set: { on in
        PerfHUDToggle.set(on)
        perfHUDOn = on
      }),
      cpuEngine: Binding(
        get: { AnyHashable(nextEngine) },
        set: { value in
          guard let raw = value as? Int else { return }
          DOLConfigBridge.setMainCpuCore(raw)
          nextEngine = raw
          EmulationToast.post(String(format: L("%@ from the next launch"), CpuEngine.from(raw: raw).shortName))
        }), quickSaveMode: $quickSaveMode)
  }

  private func refreshShaderState() {
    shaderOptions = ShaderQuickApply.options(
      mru: UserDefaults.standard.stringArray(forKey: ShaderQuickApply.mruKey) ?? [], current: ShaderQuickApply.currentPath)
  }

  private var pauseMenuModel: MenuModel {
    let state = PauseMenuState(
      quickSlot: selectedSlot,
      isMuted: isMuted,
      activeCheatCount: activeCheatCount,
      shaderOptions: shaderOptions,
      showsRecenterPointer: Self.showsRecenterPointer,
      internalResolution: internalResolution,
      metalFXSupported: DOLConfigBridge.gfxMetalFXSpatialUpscaleSupported(),
      audioVolume: audioVolume,
      engineShortName: engineShortName,
      jitAcquired: jitAcquired,
      nextEngine: nextEngine, quickSaveMode: quickSaveMode, isModded: ModdedBoot.isCurrentBootModded)
    let quick = quickSaveActions
    let actions = PauseMenuActions(
      resume: { PauseArbiter.shared.userResume(); onClose() },
      quickSave: quick.save,
      quickLoad: quick.load,
      screenshot: {
        switch QuickScreenshot.saveFromPausePreview() {
        case .saved: EmulationToast.post(L("Screenshot saved to ScreenShots"))
        case .pausedNoFrame: EmulationToast.post(L("No frame to save yet"))
        case .failed: EmulationToast.post(L("Screenshot failed"))
        }
      },
      openSaveStates: { pane = .saves },
      openCheats: { pane = .cheats },
      openControllers: {
        #if os(iOS)
        showControllersSheet = true
        #else
        pane = .controllers
        #endif
      },
      openShaders: { showShaders = true },
      openContinuity: { showContinuitySheet = true },
      openSettings: {
        settingsLink = nil
        showSettings = true
      },
      openSettingsLeaf: { link in
        settingsLink = link
        showSettings = true
      },
      openPerfOverlay: {
        PausePerfHUDRoute.open(platform: platform, openSubmenu: {
          tvLastFocusID = "perf-hud"
          pane = .perfHUD
        }, closePause: onClose, openTouchOverlay: onShowPerfOverlay)
      },
      requestReset: { showResetDialog = true },
      requestExit: requestExit,
      recenterPointer: {
        #if os(iOS)
        TCDeviceMotion.requestPointerRecenter()
        PauseArbiter.shared.userResume()
        onClose()
        #endif
      },
      openDiscPicker: { pane = .discs })
    var model = PauseMenuModelBuilder.make(state: state, bindings: pauseMenuBindings, actions: actions)
    if quitRequestInFlight {
      for section in model.sections.indices {
        for item in model.sections[section].items.indices { model.sections[section].items[item].isEnabled = false }
      }
    }
    return model
  }

  /// Confirm overlay shown for `showResetDialog` -- Cancel first (the safe,
  /// non-destructive default focus/first-A target, matching the original
  /// `.alert`'s button order), Reset second and `.destructive`.
  private var resetConfirmModel: MenuModel {
    MenuModel(sections: [MenuSection(id: "reset-confirm", items: [
      MenuItem(id: "reset-cancel", title: L("Cancel"), icon: "xmark", role: .action { showResetDialog = false }),
      MenuItem(id: "reset-do", title: L("Reset"), icon: "arrow.counterclockwise.circle", tint: .orange, role: .destructive {
        showResetDialog = false
        resetGame()
      }),
    ])])
  }

  /// Same as the console's reset button. It does not reload the auto-resume state, so it is also the way out of a
  /// game that resumed into a bad save.
  private func resetGame() {
    TVEmulationBridge.resetSystem()
    onClose()
  }

  private func requestExit() {
    guard !quitRequestInFlight else { return }
    UserStopRequest.handle(confirmOnStop: DOLConfigBridge.mainConfirmOnStop(),
                           confirm: { showExitDialog = true }, stop: quitGame)
  }

  private func quitGame() {
    runQuit(.finalizing(savedStatePath: nil), expectedGameID: TVEmulationBridge.currentGameID())
  }

  /// Saves to the quick slot, then quits.
  private func saveAndQuit() {
    runQuit(.numberedSlot, expectedGameID: TVEmulationBridge.currentGameID())
  }

  private func retryQuit(_ operation: UserQuitSaveFailure) {
    runQuit(operation, expectedGameID: quitExpectedGameID, expectedSessionIdentifier: quitExpectedSessionIdentifier)
  }

  private func runQuit(_ operation: UserQuitSaveFailure, expectedGameID: String, expectedSessionIdentifier: UInt64? = nil) {
    guard !quitRequestInFlight else { return }
    quitRequestInFlight = true
    quitExpectedGameID = expectedGameID
    let session = expectedSessionIdentifier ?? TVEmulationBridge.currentSessionIdentifier()
    quitExpectedSessionIdentifier = session
    quitSaveFailure = nil
    let slot = selectedSlot
    Task { @MainActor in
      let outcome: UserQuitAttemptResult
      switch operation {
      case .numberedSlot:
        outcome = await SaveStateService.saveAndStopForUserAsync(slot, expectedGameID: expectedGameID, expectedSessionIdentifier: session)
      case .finalizing(let savedPath):
        outcome = await SaveStateService.stopForUserAsync(savedStatePath: savedPath, expectedGameID: expectedGameID, expectedSessionIdentifier: session)
          ? .stopped : .failed(operation)
      }
      quitRequestInFlight = false
      switch outcome {
      case .stopped:
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      case .failed(let failure):
        if session == TVEmulationBridge.currentSessionIdentifier() { quitSaveFailure = failure }
      }
    }
  }

  private func quitWithoutSaving() {
    if TVEmulationBridge.stopWithoutSavingForUser(expectedSessionIdentifier: quitExpectedSessionIdentifier) {
      NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
    }
  }

  /// Confirm overlay shown for `showExitDialog` -- Cancel first, matching the
  /// original `.alert`'s order (Cancel, Quit, Save & Quit).
  private var exitConfirmModel: MenuModel {
    MenuModel(sections: [MenuSection(id: "exit-confirm", items: [
      MenuItem(id: "exit-cancel", title: L("Cancel"), icon: "xmark", role: .action { showExitDialog = false }),
      MenuItem(id: "exit-quit", title: L("Quit"), icon: "xmark.circle", tint: .red, role: .destructive {
        showExitDialog = false
        quitGame()
      }),
      MenuItem(id: "exit-save-quit", title: L("Save & Quit"), icon: "square.and.arrow.down", tint: .blue, role: .action {
        showExitDialog = false
        saveAndQuit()
      }),
    ])])
  }
}

/// Plain snapshot — no bridge reads inside the builder.
struct PauseMenuState {
  var quickSlot: Int
  var isMuted: Bool
  var activeCheatCount: Int
  /// "None" first, then recent presets; the Shaders tile cycles these.
  var shaderOptions: [(String, AnyHashable)]
  /// Wii title on iOS, where the pointer is driven by touch or the gyro.
  var showsRecenterPointer: Bool
  /// Dolphin's EFB scale (1 = native, 2 = 2x, ...; 0 = auto) and master volume percent, read by the host.
  var internalResolution: Int = 1
  /// The device can run MetalFX, so the MetalFX tile follows Upscaling.
  var metalFXSupported: Bool = false
  var audioVolume: Int = 100
  /// The engine actually running ("INT", "CIR", "CIR-IR", "JIT"), and whether the JIT was acquired.
  var engineShortName: String = ""
  var jitAcquired: Bool = false
  /// The engine the next launch uses (`CpuEngine` raw value): the Performance tile's value.
  var nextEngine: Int = CpuEngine.cachedInterpreter.rawValue
  var quickSaveMode: QuickSaveMode = .history
  var isModded = false
}

/// Live bindings for the in-place tiles. Writing one applies immediately; the host rebuilds the model.
struct PauseMenuBindings {
  var mute: Binding<Bool>
  var fastForward: Binding<AnyHashable>
  var quickSlot: Binding<AnyHashable>
  var shader: Binding<AnyHashable>
  var internalResolution: Binding<AnyHashable> = .constant(AnyHashable(1))
  /// MetalFX upscaling of whatever internal resolution is picked (`gfxMetalFXSpatialUpscale`).
  var metalFX: Binding<Bool> = .constant(false)
  var audioVolume: Binding<AnyHashable> = .constant(AnyHashable(100))
  /// Screen recording on/off (`RecordingManager`); the Record tile toggles it.
  var recording: Binding<Bool> = .constant(false)
  /// Dolphin's on-screen stats (`PerfHUDToggle`); the Performance HUD tile toggles them.
  var perfHUD: Binding<Bool> = .constant(false)
  /// The CPU engine for the next launch (`CpuEngine` raw value); the Performance tile cycles it.
  var cpuEngine: Binding<AnyHashable> = .constant(AnyHashable(CpuEngine.cachedInterpreter.rawValue))
  var quickSaveMode: Binding<QuickSaveMode> = .constant(.history)
}

struct PauseMenuActions {
  var resume: () -> Void
  var quickSave: () -> Void
  var quickLoad: () -> Void
  var screenshot: () -> Void
  var openSaveStates: () -> Void
  var openCheats: () -> Void
  var openControllers: () -> Void
  var openShaders: () -> Void
  var openContinuity: () -> Void
  var openSettings: () -> Void
  /// Opens Settings on a leaf, scrolled to a row (`PauseMenuModelBuilder.settingsLinks`).
  var openSettingsLeaf: (SettingsDeepLink) -> Void = { _ in }
  var openPerfOverlay: () -> Void
  var requestReset: () -> Void
  var requestExit: () -> Void
  var recenterPointer: () -> Void
  var openDiscPicker: () -> Void = {}
}

/// Unified menu UX spec §5: Quick / Game / System. Shared by iOS and tvOS.
enum PauseMenuModelBuilder {
  static func perfHUDModel(read: @escaping () -> PerfHUDToggle.Flags = PerfHUDToggle.read,
                           write: @escaping (PerfHUDToggle.Stat, Bool) -> Void = { $0.set($1) }) -> MenuModel {
    let items = PerfHUDToggle.Stat.allCases.map { stat in
      MenuItem(id: "hud-\(stat.rawValue)", title: stat.title, role: .toggle(Binding(
        get: { read()[keyPath: stat.keyPath] }, set: { write(stat, $0) })))
    }
    return MenuModel(sections: [MenuSection(id: "hud", items: items)], focusRequest: "hud-fps")
  }

  /// The session row, in order (iFly layout): big tiles above the Options grid.
  static let primaryIDs = ["resume", "save-states", "reset", "exit"]

  /// The pause screen's regroup of `make`'s tiles, on every platform: one headerless primary row, then every other
  /// tile, in order, under Options. A headerless section is what `TVPauseGridView` and `MenuStyle.cards` draw as the
  /// tall primary row.
  static func primaryLayout(_ model: MenuModel) -> MenuModel {
    let all = model.sections.flatMap(\.items)
    let primary = primaryIDs.compactMap { id in all.first { $0.id == id } }
    let options = all.filter { !primaryIDs.contains($0.id) }
    return MenuModel(sections: [
      MenuSection(id: "primary", items: primary),
      MenuSection(id: "options", header: L("Options"), items: options),
    ])
  }

  /// Tile → the Settings leaf and row its long-press opens. Every other tile acts in place or opens its own page
  /// (Save States, Cheats, Controllers, Continue Elsewhere, the shader picker); Settings opens the root.
  static let settingsLinks: [String: SettingsDeepLink] = [
    "upscaling": SettingsDeepLink(leafID: "graphics-enhancements", rowID: "efb-scale"),
    "audio": SettingsDeepLink(leafID: "audio", rowID: "volume"),
    "performance": SettingsDeepLink(leafID: "performance-tuning", rowID: "cpu-engine"),
  ]

  /// The long-press that opens `tile`'s Settings link.
  private static func settingsLongPress(_ tile: String, _ actions: PauseMenuActions) -> MenuLongPress? {
    guard let link = settingsLinks[tile] else { return nil }
    return .action { actions.openSettingsLeaf(link) }
  }

  /// The Performance tile's engines: the recommended ones for this run (the JIT only when it was acquired). The
  /// plain Interpreter stays in Settings, one step away from a slow next launch; when it is the stored engine it is
  /// listed so the badge stays honest.
  static func engineOptions(jitAcquired: Bool, including current: Int) -> [(String, AnyHashable)] {
    let ladder: [CpuEngine] = jitAcquired ? [.jitARM64, .cachedInterpreter, .cachedInterpreterIR] : [.cachedInterpreter, .cachedInterpreterIR]
    return options(ladder.map { ($0.shortName, AnyHashable($0.rawValue)) }, including: current) { CpuEngine.from(raw: $0).shortName }
  }

  static let fastForwardOff: AnyHashable = AnyHashable(-1)
  static let fastForwardOptions: [(String, AnyHashable)] = [
    (L("Off"), fastForwardOff), ("2x", AnyHashable(200)), ("3x", AnyHashable(300)), ("4x", AnyHashable(400)), ("8x", AnyHashable(800)), (L("Unlimited"), AnyHashable(0)),
  ]
  static let slotCount = 10
  static let upscalingOptions: [(String, AnyHashable)] = [
    (L("Native"), AnyHashable(1)), ("2x", AnyHashable(2)), ("3x", AnyHashable(3)), ("4x", AnyHashable(4)), ("6x", AnyHashable(6)),
  ]
  static let audioVolumeOptions: [(String, AnyHashable)] = [0, 25, 50, 75, 100].map { ("\($0) %", AnyHashable($0)) }

  /// The ladder plus the current value when a settings leaf put it off the ladder, in sorted position: the
  /// badge stays honest and a press moves one step, instead of `cycled` jumping to the first option (0 %).
  static func options(_ ladder: [(String, AnyHashable)], including current: Int, label: (Int) -> String) -> [(String, AnyHashable)] {
    guard !ladder.contains(where: { $0.1 == AnyHashable(current) }) else { return ladder }
    var result = ladder
    let index = result.firstIndex { ($0.1 as? Int ?? Int.max) > current } ?? result.count
    result.insert((label(current), AnyHashable(current)), at: index)
    return result
  }

  /// Dolphin's EFB scale 0 is Auto.
  static func upscalingOptions(including current: Int) -> [(String, AnyHashable)] {
    options(upscalingOptions, including: current) { $0 == 0 ? L("Auto") : "\($0)x" }
  }

  static func audioVolumeOptions(including current: Int) -> [(String, AnyHashable)] {
    options(audioVolumeOptions, including: current) { "\($0) %" }
  }

  /// With nothing to cycle (only "None"), the tile just opens the full picker.
  private static func shadersItem(state: PauseMenuState, bindings: PauseMenuBindings, actions: PauseMenuActions) -> MenuItem {
    if state.shaderOptions.count <= 1 {
      return MenuItem(id: "shaders", title: L("Shaders"), icon: "wand.and.stars", tint: .orange, role: .action(actions.openShaders),
                      description: L("Choose a post-processing shader."))
    }
    return MenuItem(id: "shaders", title: L("Shaders"), icon: "wand.and.stars", tint: .orange,
                    role: .cycle(options: state.shaderOptions, selection: bindings.shader),
                    description: L("Tap to cycle recent shaders. Long-press for the full picker."),
                    longPress: .action(actions.openShaders))
  }

  static func make(state: PauseMenuState, bindings: PauseMenuBindings, actions: PauseMenuActions) -> MenuModel {
    let slotOptions: [(String, AnyHashable)] = (1 ... slotCount).map { (String(format: L("Slot %d"), $0), AnyHashable($0)) }
    let classic = state.isModded || state.quickSaveMode == .slots
    let slotBadge = String(format: L("Slot %d"), state.quickSlot)
    let slotPicker: MenuLongPress? = classic ? .options(title: L("Quick Slot"), options: slotOptions, selection: bindings.quickSlot) : nil

    let quick = MenuSection(id: "quick", header: L("Quick"), items: [
      MenuItem(id: "resume", title: L("Resume"), icon: "play.fill", tint: .blue, role: .action(actions.resume),
               description: L("Return to the game.")),
      MenuItem(id: "quick-save", title: L("Quick Save"), icon: "square.and.arrow.down", tint: .green, role: .action(actions.quickSave),
               badge: classic ? slotBadge : L("Quick-save history"),
               description: classic ? L("Browse classic slots before saving; occupied slots require confirmation.") : L("Save new state"), longPress: slotPicker),
      MenuItem(id: "quick-load", title: L("Quick Load"), icon: "square.and.arrow.up", tint: .green, role: .action(actions.quickLoad),
               badge: classic ? slotBadge : L("Latest manual"),
               description: classic ? L("Load the quick slot. Long-press to choose the slot.") : L("Load the latest manual state, or automatic resume when no manual state exists."), longPress: slotPicker),
      MenuItem(id: "fast-forward", title: L("Fast Forward"), icon: "forward.fill", tint: .cyan,
               role: .cycle(options: fastForwardOptions, selection: bindings.fastForward),
               description: L("Tap to cycle the speed. Long-press to pick one. Takes effect on resume.")),
      MenuItem(id: "mute", title: L("Mute"), icon: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", tint: .cyan,
               role: .toggle(bindings.mute), description: L("Silence the game's audio.")),
      MenuItem(id: "screenshot", title: L("Screenshot"), icon: "camera", tint: .pink, role: .action(actions.screenshot),
               description: L("Save the last frame to ScreenShots.")),
      MenuItem(id: "record", title: L("Record"), icon: "record.circle", tint: ICubeDesign.color(.destructive),
               role: .toggle(bindings.recording), badge: bindings.recording.wrappedValue ? L("REC") : nil,
               description: L("Record the screen to a video in Recordings.")),
    ])

    var game: [MenuItem] = [
      MenuItem(id: "save-states", title: L("Save States"), icon: "square.stack.3d.up", tint: .purple, role: .action(actions.openSaveStates),
               description: L("Save, load and browse save states.")),
      MenuItem(id: "change-disc", title: L("Change Disc"), icon: "opticaldisc", role: .action(actions.openDiscPicker),
               description: L("Insert another local disc without restarting the game.")),
      MenuItem(id: "perf-hud", title: L("Performance HUD"), icon: "speedometer", tint: .cyan, role: .toggle(bindings.perfHUD),
               description: L("Frame rate and speed drawn over the game. Long-press for every performance control."),
               longPress: .action(actions.openPerfOverlay)),
      MenuItem(id: "upscaling", title: L("Upscaling"), icon: "arrow.up.left.and.arrow.down.right", tint: .indigo,
               role: .cycle(options: upscalingOptions(including: state.internalResolution), selection: bindings.internalResolution),
               description: L("Internal resolution. Takes effect immediately. Long-press for the graphics settings."),
               longPress: settingsLongPress("upscaling", actions)),
      MenuItem(id: "audio", title: L("Audio"), icon: "speaker.wave.2", tint: .cyan,
               role: .cycle(options: audioVolumeOptions(including: state.audioVolume), selection: bindings.audioVolume),
               description: L("Game volume. Long-press for the audio settings."),
               longPress: settingsLongPress("audio", actions)),
      MenuItem(id: "performance", title: L("CPU Engine"), icon: "gauge.with.dots.needle.67percent", tint: .orange,
               role: .cycle(options: engineOptions(jitAcquired: state.jitAcquired, including: state.nextEngine), selection: bindings.cpuEngine),
               description: L("The CPU engine from the next launch. Long-press for Performance Tuning."),
               longPress: settingsLongPress("performance", actions)),
      MenuItem(id: "cheats", title: L("Cheats"), icon: "star.circle", tint: .yellow, role: .action(actions.openCheats),
               badge: state.activeCheatCount > 0 ? "\(state.activeCheatCount)" : nil,
               description: L("Enable Gecko and Action Replay codes for this game.")),
      shadersItem(state: state, bindings: bindings, actions: actions),
      MenuItem(id: "controllers", title: L("Controllers"), icon: "gamecontroller", tint: .green, role: .action(actions.openControllers),
               description: L("Players, devices and what each one plays as.")),
      MenuItem(id: "continuity", title: L("Continue Elsewhere"), icon: "arrow.triangle.branch", tint: .teal, role: .action(actions.openContinuity),
               description: L("Hand this game to a nearby device.")),
    ]
    if state.metalFXSupported, let upscaling = game.firstIndex(where: { $0.id == "upscaling" }) {
      game.insert(
        MenuItem(id: "metalfx", title: L("MetalFX"), icon: "sparkles", tint: .indigo, role: .toggle(bindings.metalFX),
                 description: L("Sharpens the picture where it is stretched to fill the screen. Costs GPU time; raising Upscaling is often cheaper.")),
        at: upscaling + 1)
    }
    if state.showsRecenterPointer {
      game.append(MenuItem(id: "recenter-pointer", title: L("Recenter Pointer"), icon: "scope", tint: .green, role: .action(actions.recenterPointer),
                           description: L("Center the Wii pointer on how you hold the device.")))
    }

    let system = MenuSection(id: "system", header: L("System"), items: [
      MenuItem(id: "settings", title: L("Settings"), icon: "gearshape", tint: .gray, role: .action(actions.openSettings),
               description: L("Game and system options.")),
      MenuItem(id: "reset", title: L("Reset"), icon: "arrow.counterclockwise.circle", tint: .orange, role: .destructive(actions.requestReset),
               description: L("Restart the game from power-on. Unsaved progress is lost.")),
      MenuItem(id: "exit", title: L("Exit"), icon: "xmark.circle", tint: .red, role: .destructive(actions.requestExit),
               description: L("Return to the library. Unsaved progress is lost.")),
    ])
    return MenuModel(sections: [quick, MenuSection(id: "game", header: L("Game"), items: game), system])
  }
}

/// Starts or stops `RecordingManager` from a synchronous toggle binding; failures surface as a toast.
@MainActor
enum RecordingToggle {
  static func set(_ on: Bool) {
    let manager = RecordingManager.shared
    guard on != manager.isRecording, !manager.isTransitioning else { return }
    Task { @MainActor in
      do {
        if on { try await manager.start() } else { _ = try await manager.stop() }
      } catch {
        EmulationToast.post(L("Recording failed"))
      }
    }
  }
}

/// Bindings and actions for the in-game quick menu, built from the same sources the pause menu uses
/// (`QuickMute`, mode-aware quick actions, `QuickScreenshot`, the fast-forward bridge) so both menus always agree.
@MainActor
enum QuickMenuHost {
  static func bindings(selectedSlot: Binding<Int>, mode: Binding<QuickSaveMode>) -> PauseMenuBindings {
    PauseMenuBindings(
      mute: Binding(get: { QuickMute.isMuted }, set: { _ in _ = QuickMute.toggle() }),
      fastForward: Binding(get: { fastForwardState().selection }, set: { value in
        var state = fastForwardState()
        applyFastForward(state.select(value))
      }),
      quickSlot: Binding(get: { AnyHashable(selectedSlot.wrappedValue) }, set: { if let slot = $0 as? Int { selectedSlot.wrappedValue = slot } }),
      shader: .constant(ShaderQuickApply.noneValue),
      recording: Binding(get: { RecordingManager.shared.isRecording }, set: { RecordingToggle.set($0) }),
      perfHUD: Binding(get: { PerfHUDToggle.isOn }, set: { PerfHUDToggle.set($0) }), quickSaveMode: mode)
  }

  static func actions(quickActions: QuickSaveMenuActions, openPerfOverlay: @escaping () -> Void) -> PauseMenuActions {
    PauseMenuActions(
      resume: {},
      quickSave: quickActions.save,
      quickLoad: quickActions.load,
      screenshot: {
        switch QuickScreenshot.saveFromPausePreview() {
        case .saved: EmulationToast.post(L("Screenshot saved to ScreenShots"))
        case .pausedNoFrame: EmulationToast.post(L("No frame to save yet"))
        case .failed: EmulationToast.post(L("Screenshot failed"))
        }
      },
      openSaveStates: {}, openCheats: {}, openControllers: {}, openShaders: {}, openContinuity: {}, openSettings: {},
      openPerfOverlay: openPerfOverlay,
      requestReset: {}, requestExit: {}, recenterPointer: {})
  }

  private static func fastForwardState() -> PauseFastForwardState {
    PauseFastForwardState(
      isEnabled: TVEmulationBridge.isFastForwardEnabled(),
      percent: ConfigGeneralState.storedFastForward(UserDefaults.standard.object(forKey: ConfigGeneralDefaultsKey.fastForwardSpeedPercent) as? Int))
  }

  private static func applyFastForward(_ effect: PauseFastForwardState.Effect) {
    switch effect {
    case .setSpeed(let percent):
      TVEmulationBridge.setFastForwardSpeedPercent(percent)
      if !TVEmulationBridge.isFastForwardEnabled() { _ = TVEmulationBridge.toggleFastForward() }
    case .turnOff:
      if TVEmulationBridge.isFastForwardEnabled() { _ = TVEmulationBridge.toggleFastForward() }
    }
  }
}

#if DEBUG
import UIKit

extension PauseMenuView {
  /// Fictional stand-in ID for the placeholder game (no real title's ID).
  private static let placeholderGameID = "PRVW01"

  /// A stand-in `TVGameItem` for previews and snapshot tests. In `-SCREENSHOT_MODE` it is the first demo-catalogue
  /// title, so store screenshots show the same fictional title, ID and procedural cover as the library.
  static func previewGame() -> TVGameItem {
    if TVLibraryBridge.isScreenshotDemoMode(), let demo = TVLibraryBridge.currentGames().first {
      return demo
    }
    guard let cls = NSClassFromString("TVGameItem") as? NSObject.Type else {
      fatalError("TVGameItem class not found for preview")
    }
    let obj = cls.init()
    let img = UIImage(systemName: "gamecontroller")?.withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage()
    obj.setValue("Preview Game", forKey: "title")
    obj.setValue(placeholderGameID, forKey: "gameID")
    obj.setValue(img, forKey: "coverImage")
    return unsafeBitCast(obj, to: TVGameItem.self)
  }
}

#Preview("iPhone Portrait") {
  PauseMenuView(
    selectedSlot: .constant(1),
    onClose: {},
    platform: .ios,
    game: PauseMenuView.previewGame()
  )
}

#Preview("iPhone Landscape") {
  PauseMenuView(
    selectedSlot: .constant(1),
    onClose: {},
    platform: .ios,
    game: PauseMenuView.previewGame()
  )
  .previewInterfaceOrientation(.landscapeLeft)
}
#endif
