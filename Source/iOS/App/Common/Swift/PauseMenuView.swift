// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if os(iOS)
#endif

internal enum PlatformKind { case ios, tvos }

internal struct PauseMenuView: View {
  @Binding var selectedSlot: Int
  let onClose: () -> Void
  let onShowSettings: () -> Void
  /// Opens Settings straight on a leaf (a tile's long-press or the Performance tile); wired by `EmulationScreen`.
  var onShowSettingsLeaf: (String) -> Void = { _ in }
  var onShowPerfOverlay: () -> Void = {}
  let platform: PlatformKind
  let game: TVGameItem

  @FocusState private var focused: FocusField?
  internal enum FocusField: Hashable {
    case back, slot(Int), save, load
    /// D10: the tvOS saves pane's "View All States" button, into the redesigned
    /// grid (`SaveStateFilmstripView`) -- previously iOS-only.
    case filmstrip
  }
  private enum Pane { case main, saves, cheats, controllers }
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
  #endif
  @State private var showExitDialog: Bool = false
  @State private var showResetDialog: Bool = false
  @State private var showShaders: Bool = false
  @State private var showSettingsSheet: Bool = false
  /// The leaf the iOS Settings sheet opens on; nil opens the root.
  @State private var settingsSheetLeafID: String?
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
  @State private var audioVolume: Int = 100
  /// The Performance tile badge and the cover-column chip: the engine actually running.
  @State private var engineShortName: String = ""
  @State private var jitAcquired: Bool = false
  @Environment(\.verticalSizeClass) private var verticalSizeClass

  /// True while any sheet, full-screen cover, or non-main pane owned by this menu is
  /// up. Gates the resume-on-disappear below (B1): every one of these presentations
  /// can report an onDisappear on the outer ZStack while it is on screen, and none of
  /// them should resume the game underneath.
  private var isPauseMenuChildPresented: Bool {
    if pane != .main { return true }
    if showShaders || showContinuitySheet || showFilmstripSheet { return true }
    #if os(iOS)
    if showSettingsSheet || showControllersSheet { return true }
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
  }

  private func refreshLiveSettings() {
    internalResolution = TVEmulationBridge.internalResolution()
    audioVolume = TVEmulationBridge.audioVolumePercent()
    refreshEngineState()
  }

  private func refreshActiveCheatCount() {
    activeCheatCount = CheatsMenuView.activeCheatCount(forGameId: game.gameID, revision: game.revision)
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
      case .saves:
        savesMenu
          .onAppear { NSLog("[PAUSE] Saves menu appeared") }
      case .cheats:
        CheatsMenuView(game: game, onBack: { pane = .main })
          .onAppear { NSLog("[PAUSE] Cheats menu appeared") }
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
        default: break
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
        }
      }
    }
    .onChange(of: showShaders) { _, shown in
      if !shown { refreshShaderState() }
    }
    #if os(tvOS)
    .onExitCommand {
      // At .main the tile grid's own onBack closes (coalesced), and the confirm overlays handle theirs.
      if pane != .main { pane = .main }
    }
    // Spec §5.3: Play/Pause on the remote resumes, from any pane.
    .onPlayPauseCommand {
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
    .sheet(isPresented: $showSettingsSheet) {
      NavigationStack {
        SettingsRootView(initialLeafID: settingsSheetLeafID)
          .navigationTitle(L("Settings"))
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Close")) { showSettingsSheet = false } } }
      }
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

  #endif

  // Add pull-down to dismiss for iOS
  #if os(iOS)
  init(selectedSlot: Binding<Int>, onClose: @escaping () -> Void, onShowSettings: @escaping () -> Void, onShowSettingsLeaf: @escaping (String) -> Void = { _ in }, onShowPerfOverlay: @escaping () -> Void = {}, platform: PlatformKind, game: TVGameItem) {
    self._selectedSlot = selectedSlot
    self.onClose = onClose
    self.onShowSettings = onShowSettings
    self.onShowSettingsLeaf = onShowSettingsLeaf
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
      TVPauseGridView(model: PauseMenuModelBuilder.tvLayout(pauseMenuModel), lastFocusID: $tvLastFocusID, onBack: {
        guard BackCoalescer.shouldHonor(openedAt: openedAt, now: Date()) else { return }
        onClose()
      }) {
        coverColumn
      }
      EmulationToastOverlay(barHeight: 0, barVisible: false)
    }
    .environment(\.colorScheme, .dark)
    // The system dialog, as iFly's Quit and Hard Restart: the focus engine owns it, and Menu cancels it.
    .confirmationDialog(L("Exit Game"), isPresented: $showExitDialog, titleVisibility: .visible) {
      Button(L("Save & Quit")) { saveAndQuit() }
      Button(L("Quit"), role: .destructive) { quitGame() }
      Button(L("Cancel"), role: .cancel) {}
    } message: {
      Text(L("Do you want to quit the game? Unsaved progress will be lost."))
    }
    .confirmationDialog(L("Reset System"), isPresented: $showResetDialog, titleVisibility: .visible) {
      Button(L("Reset"), role: .destructive) { resetGame() }
      Button(L("Cancel"), role: .cancel) {}
    } message: {
      Text(L("Restart the game as if the console's reset button was pressed? Unsaved progress will be lost."))
    }
  }
  #endif

  private var touchMainMenu: some View {
    GeometryReader { proxy in
      let compactHeight = isCompactHeight
      let columns = PauseTileLayout.columns(forWidth: proxy.size.width, isTV: false, isCompactHeight: compactHeight)
      ZStack {
        VStack(alignment: .leading, spacing: 8) {
          compactHeader(isCompactHeight: compactHeight).padding(compactHeight ? 12 : 16)
          tiles(columns: columns, compact: compactHeight)
        }
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
        EmulationToastOverlay(barHeight: 0, barVisible: false)
      }
      // A background, not a ZStack sibling: the scaledToFill backdrop would otherwise widen the ZStack to the
      // image's fill size and push the tile grid several windows wide.
      .frame(width: proxy.size.width, height: proxy.size.height)
      .background { backdrop }
    }
    // `MenuScreen` row text takes no explicit color; pin the dark-mode values so titles stay legible over the
    // always-dark backdrop whatever the system appearance. `.environment`, not `.preferredColorScheme`, so the
    // Settings/Controllers/Shaders sheets opened from here are unaffected.
    .environment(\.colorScheme, .dark)
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
    let confirmUp = showResetDialog || showExitDialog
    return MenuScreen(model: pauseMenuModel, style: .tiles(columns: columns, compact: compact), onBack: {
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

  private var backdrop: some View {
    ZStack {
      Image(uiImage: game.bannerImage ?? game.coverImage)
        .resizable().scaledToFill().blur(radius: 24).opacity(0.5).ignoresSafeArea().clipped()
      LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
  }

  /// tvOS hero (iFly layout, iCube tokens): cover, PAUSED in accent, the game title in the display face, its ID.
  private var coverColumn: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.m.rawValue) {
      heroArt
        .shadow(color: .black.opacity(0.5), radius: ICubeDesign.TVPause.heroArtShadowRadius, x: 0, y: ICubeDesign.TVPause.heroArtShadowY)
        .padding(.bottom, ICubeDesign.Spacing.xs.rawValue)
      Label(L("Paused"), systemImage: "pause.fill")
        .icubeText(.nav)
        .tracking(ICubeDesign.TVPause.pausedTracking)
        .foregroundStyle(platformAccent)
      Text(game.title)
        // Before `icubeText`: the role's own `textCase(nil)` would otherwise sit closer to the text and win.
        .textCase(.uppercase)
        .icubeText(.title)
        .foregroundStyle(LinearGradient(colors: [ICubeDesign.color(.textPrimary), platformAccent], startPoint: .top, endPoint: .bottom))
        .lineLimit(3)
        .minimumScaleFactor(0.6)
        .fixedSize(horizontal: false, vertical: true)
      Text(game.gameID)
        .icubeText(.tag)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
      engineChip
    }
  }

  /// Hero cover width; the art is always 2:3 (a GameCube/Wii case).
  private static let heroArtWidth = ICubeDesign.TVPause.heroArtWidth

  /// The cover, filled into a 2:3 case and clipped; without one, the platform's case template on its accent,
  /// never a stretched placeholder glyph. The title is not repeated: it sits right below.
  private var heroArt: some View {
    let shape = RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
    return ZStack {
      if game.hasCoverArt {
        Image(uiImage: game.coverImage).resizable().scaledToFill()
      } else {
        shape.fill(platformAccent.opacity(ICubeDesign.IconBadge.tintOpacity))
        Image(LibraryGameSystem.from(item: game).templateImageName)
          .resizable().scaledToFill()
          .opacity(0.5)
      }
    }
    .frame(width: Self.heroArtWidth, height: Self.heroArtWidth * 3 / 2)
    .clipShape(shape)
    .overlay(shape.stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue))
  }

  /// "JIT ON" while the JIT is acquired, otherwise the engine that is running (INT, CIR, CIR-IR).
  private var engineChip: some View {
    Text(jitAcquired ? L("JIT ON") : engineShortName)
      .icubeText(.tag)
      .foregroundStyle(ICubeDesign.color(.textPrimary))
      .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
      .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
      .background(Capsule().fill(jitAcquired ? ICubeDesign.color(.selectedFill) : ICubeDesign.color(.rowSurface)))
  }

  @ViewBuilder
  private func compactHeader(isCompactHeight: Bool) -> some View {
    HStack(alignment: .center, spacing: 12) {
      if !isCompactHeight {
        Image(uiImage: game.coverImage)
          .resizable().aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 56)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      if isCompactHeight {
        Text(game.title).font(.headline).foregroundStyle(.white).lineLimit(1)
        Text(game.gameID).font(.caption).foregroundStyle(.white.opacity(0.7))
        engineChip
      } else {
        VStack(alignment: .leading, spacing: 2) {
          Text(game.title).font(.headline).foregroundStyle(.white).lineLimit(1)
          HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
            Text(game.gameID).font(.caption).foregroundStyle(.white.opacity(0.7))
            engineChip
          }
        }
      }
      Spacer()
      Button(L("Close")) { onClose() }
        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, isCompactHeight ? 4 : 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .buttonStyle(.plain)
    }
  }

  private var isTV: Bool { platform == .tvos }

  private func confirmOverlay(title: String, message: String, model: MenuModel, onBack: @escaping () -> Void) -> some View {
    ICubeConfirmPanel(title: title, message: message, model: model, isTV: isTV, onBack: onBack)
  }

  private var savesMenu: some View {
    Group {
      if platform == .ios {
        NavigationStack {
          List {
            Section(header: Text(L("Quick Slots"))) {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                  ForEach(Self.saveSlots, id: \.self) { i in
                    Button(action: { selectedSlot = i }) {
                      Label(String(format: L("Slot %d"), i), systemImage: selectedSlot == i ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.bordered)
                  }
                }
                .padding(.vertical, 4)
              }
            }
            Section(header: Text(L("Actions"))) {
              Button { SaveStateService.saveSlot(selectedSlot)
                NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Saved to Slot %d"), selectedSlot)])
              } label: {
                HStack { Image(systemName: ControllerGlyphs.glyphName(for: "confirm", set: ControllerStyleManager.shared.current()))
                  Text(String(format: L("Save to Slot %d"), selectedSlot))
                }
              }
              Button { TVEmulationBridge.loadState(fromSlot: selectedSlot)
                NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Loaded Slot %d"), selectedSlot)])
              } label: {
                HStack { Image(systemName: "arrow.down.circle")
                  Text(String(format: L("Load Slot %d"), selectedSlot))
                }
              }
              Button { showFilmstripSheet = true } label: {
                HStack { Image(systemName: "film")
                  Text(L("Open Filmstrip"))
                }
              }
            }
          }
          .navigationTitle(L("Save States"))
          .toolbar(content: {
            ToolbarItem(placement: .navigationBarLeading) {
              Button(L("Back")) { pane = .main }
            }
          })
          .sheet(isPresented: $showFilmstripSheet) {
            // `.claimsController()` pushes this sheet's own scope onto
            // `ControllerFocusCoordinator` while it is up. Nothing underneath
            // needs to gate on it explicitly here: `pane == .saves` already
            // means the root pane's own `MenuScreen` (D18) was torn down when
            // `pane` left `.main`, so there is no raw handler left to fight
            // over dpad/A -- this sheet's claim only matters for anything
            // else that might still be listening (e.g. a future D18
            // migration of this very list, design doc §6 step 5).
            NavigationStack { SaveStateFilmstripView(gameID: game.gameID) }
              .pauseClaim("filmstrip")
              .claimsController()
          }
        }
      } else {
        tvHeroLayout {
          TVSaveSlotsPane(game: game, selectedSlot: $selectedSlot, initialFocus: debugSavesFocus,
                          onViewAll: { showFilmstripSheet = true })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.icubePlatformAccent, platformAccent)
        .sheet(isPresented: $showFilmstripSheet) {
          NavigationStack { SaveStateFilmstripView(gameID: game.gameID) }
            .pauseClaim("filmstrip")
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
      audioVolume: Binding(
        get: { AnyHashable(audioVolume) },
        set: { value in
          guard let percent = value as? Int else { return }
          TVEmulationBridge.setAudioVolumePercent(percent)
          audioVolume = percent
        }),
      recording: Binding(get: { recorder.isRecording }, set: { RecordingToggle.set($0) }))
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
      audioVolume: audioVolume,
      engineShortName: engineShortName,
      jitAcquired: jitAcquired)
    let actions = PauseMenuActions(
      resume: { PauseArbiter.shared.userResume(); onClose() },
      quickSave: { _ = QuickSlot.save(slot: selectedSlot) },
      quickLoad: { QuickSlot.load(slot: selectedSlot) },
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
        #if os(iOS)
        settingsSheetLeafID = nil
        showSettingsSheet = true
        #else
        onShowSettings()
        #endif
      },
      openSettingsLeaf: { id in
        #if os(iOS)
        settingsSheetLeafID = id
        showSettingsSheet = true
        #else
        onShowSettingsLeaf(id)
        #endif
      },
      openPerfOverlay: { onClose(); onShowPerfOverlay() },
      requestReset: { showResetDialog = true },
      requestExit: { showExitDialog = true },
      recenterPointer: {
        #if os(iOS)
        TCDeviceMotion.requestPointerRecenter()
        PauseArbiter.shared.userResume()
        onClose()
        #endif
      })
    return PauseMenuModelBuilder.make(state: state, bindings: pauseMenuBindings, actions: actions)
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

  private func quitGame() {
    TVEmulationBridge.stop()
    NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
  }

  /// Saves to the quick slot, then quits.
  private func saveAndQuit() {
    SaveStateService.saveSlot(selectedSlot)
    quitGame()
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
  var audioVolume: Int = 100
  /// The engine actually running ("INT", "CIR", "CIR-IR", "JIT"), and whether the JIT was acquired.
  var engineShortName: String = ""
  var jitAcquired: Bool = false
}

/// Live bindings for the in-place tiles. Writing one applies immediately; the host rebuilds the model.
struct PauseMenuBindings {
  var mute: Binding<Bool>
  var fastForward: Binding<AnyHashable>
  var quickSlot: Binding<AnyHashable>
  var shader: Binding<AnyHashable>
  var internalResolution: Binding<AnyHashable> = .constant(AnyHashable(1))
  var audioVolume: Binding<AnyHashable> = .constant(AnyHashable(100))
  /// Screen recording on/off (`RecordingManager`); the Record tile toggles it.
  var recording: Binding<Bool> = .constant(false)
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
  /// Opens Settings on the leaf with this id (`SettingsRootView(initialLeafID:)`).
  var openSettingsLeaf: (String) -> Void = { _ in }
  var openPerfOverlay: () -> Void
  var requestReset: () -> Void
  var requestExit: () -> Void
  var recenterPointer: () -> Void
}

/// Unified menu UX spec §5: Quick / Game / System. Shared by iOS and tvOS.
enum PauseMenuModelBuilder {
  /// The tvOS session row, in order (iFly layout): big tiles above the Options grid.
  static let tvPrimaryIDs = ["resume", "save-states", "reset", "exit"]

  /// tvOS regroup of `make`'s tiles: one headerless primary row, then every other tile, in order, under Options.
  /// A headerless section is what `MenuScreen` draws as the tall primary row.
  static func tvLayout(_ model: MenuModel) -> MenuModel {
    let all = model.sections.flatMap(\.items)
    let primary = tvPrimaryIDs.compactMap { id in all.first { $0.id == id } }
    let options = all.filter { !tvPrimaryIDs.contains($0.id) }
    return MenuModel(sections: [
      MenuSection(id: "primary", items: primary),
      MenuSection(id: "options", header: L("Options"), items: options),
    ])
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
    let slotBadge = String(format: L("Slot %d"), state.quickSlot)
    let slotPicker = MenuLongPress.options(title: L("Quick Slot"), options: slotOptions, selection: bindings.quickSlot)

    let quick = MenuSection(id: "quick", header: L("Quick"), items: [
      MenuItem(id: "resume", title: L("Resume"), icon: "play.fill", tint: .blue, role: .action(actions.resume),
               description: L("Return to the game.")),
      MenuItem(id: "quick-save", title: L("Quick Save"), icon: "square.and.arrow.down", tint: .green, role: .action(actions.quickSave),
               badge: slotBadge, description: L("Save to the quick slot. Long-press to choose the slot."), longPress: slotPicker),
      MenuItem(id: "quick-load", title: L("Quick Load"), icon: "square.and.arrow.up", tint: .green, role: .action(actions.quickLoad),
               badge: slotBadge, description: L("Load the quick slot. Long-press to choose the slot."), longPress: slotPicker),
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
               description: L("Save, load and browse every slot.")),
      MenuItem(id: "perf-hud", title: L("Performance HUD"), icon: "speedometer", tint: .cyan, role: .action(actions.openPerfOverlay),
               description: L("Frame rate, CPU and GPU timing drawn over the game.")),
      MenuItem(id: "upscaling", title: L("Upscaling"), icon: "arrow.up.left.and.arrow.down.right", tint: .indigo,
               role: .cycle(options: upscalingOptions(including: state.internalResolution), selection: bindings.internalResolution),
               description: L("Internal resolution. Takes effect immediately."),
               longPress: .action { actions.openSettingsLeaf("graphics-enhancements") }),
      MenuItem(id: "audio", title: L("Audio"), icon: "speaker.wave.2", tint: .cyan,
               role: .cycle(options: audioVolumeOptions(including: state.audioVolume), selection: bindings.audioVolume),
               description: L("Game volume. Long-press for audio settings."),
               longPress: .action { actions.openSettingsLeaf("audio") }),
      MenuItem(id: "performance", title: L("Performance"), icon: "gauge.with.dots.needle.67percent", tint: .orange,
               role: .action { actions.openSettingsLeaf("performance-tuning") },
               badge: state.engineShortName.isEmpty ? nil : state.engineShortName,
               description: L("CPU engine and speed tuning.")),
      MenuItem(id: "cheats", title: L("Cheats"), icon: "star.circle", tint: .yellow, role: .action(actions.openCheats),
               badge: state.activeCheatCount > 0 ? "\(state.activeCheatCount)" : nil,
               description: L("Enable Gecko and Action Replay codes for this game.")),
      shadersItem(state: state, bindings: bindings, actions: actions),
      MenuItem(id: "controllers", title: L("Controllers"), icon: "gamecontroller", tint: .green, role: .action(actions.openControllers),
               description: L("Players, devices and what each one plays as.")),
      MenuItem(id: "continuity", title: L("Continue Elsewhere"), icon: "arrow.triangle.branch", tint: .teal, role: .action(actions.openContinuity),
               description: L("Hand this game to a nearby device.")),
    ]
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
/// (`QuickMute`, `QuickSlot`, `QuickScreenshot`, the fast-forward bridge) so both menus always agree.
@MainActor
enum QuickMenuHost {
  static func bindings(selectedSlot: Binding<Int>) -> PauseMenuBindings {
    PauseMenuBindings(
      mute: Binding(get: { QuickMute.isMuted }, set: { _ in _ = QuickMute.toggle() }),
      fastForward: Binding(get: { fastForwardState().selection }, set: { value in
        var state = fastForwardState()
        applyFastForward(state.select(value))
      }),
      quickSlot: Binding(get: { AnyHashable(selectedSlot.wrappedValue) }, set: { if let slot = $0 as? Int { selectedSlot.wrappedValue = slot } }),
      shader: .constant(ShaderQuickApply.noneValue),
      recording: Binding(get: { RecordingManager.shared.isRecording }, set: { RecordingToggle.set($0) }))
  }

  static func actions(selectedSlot: Binding<Int>, openPerfOverlay: @escaping () -> Void) -> PauseMenuActions {
    PauseMenuActions(
      resume: {},
      quickSave: { _ = QuickSlot.save(slot: selectedSlot.wrappedValue) },
      quickLoad: { QuickSlot.load(slot: selectedSlot.wrappedValue) },
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
    onShowSettings: {},
    platform: .ios,
    game: PauseMenuView.previewGame()
  )
}

#Preview("iPhone Landscape") {
  PauseMenuView(
    selectedSlot: .constant(1),
    onClose: {},
    onShowSettings: {},
    platform: .ios,
    game: PauseMenuView.previewGame()
  )
  .previewInterfaceOrientation(.landscapeLeft)
}
#endif
