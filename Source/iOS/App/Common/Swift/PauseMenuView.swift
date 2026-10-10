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
  @State private var pane: Pane = .main
  @State private var showExitDialog: Bool = false
  @State private var showResetDialog: Bool = false
  @State private var showShaders: Bool = false
  @State private var showSettingsSheet: Bool = false
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
  /// When the menu first appeared; `BackCoalescer` drops the Back press that opened it.
  @State private var openedAt = Date()
  /// "None" first, then recent presets; backs the Shaders tile's cycle.
  @State private var shaderOptions: [(String, AnyHashable)] = []
  /// WS-4: "continue this game on another device".
  @State private var showContinuitySheet: Bool = false
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
    #endif
    return false
  }

  // Quick actions: the two things people actually reach for mid-game without
  // wanting to leave the pause menu (mute to take a call, fast-forward past a
  // cutscene). Mute is a toggle tile and fast-forward a cycle tile on the main
  // pane rather than a settings trip. Mute is shared with the in-game top bar
  // via `QuickMute`.
  @State private var isMuted: Bool = false
  @State private var fastForwardEnabled: Bool = false
  /// This menu's hold on the pause (spec §4.3). Adopted from the gesture tracker's pending claim when
  /// there is one, otherwise claimed here. Released only on a real teardown, see `onDisappear`.
  @State private var pauseToken: PauseArbiter.Token?
  /// Same UserDefaults key `TVEmulationBridge` reads when fast-forward is turned on
  /// (also written by the Settings > General fast-forward speed picker) — kept as one
  /// named constant here rather than a literal at each pause-menu call site.
  private static let fastForwardSpeedPercentKey = "fast_forward_speed_percent"
  /// D15: "N active" badge on the Cheats item. Refreshed on appear and whenever the
  /// pane returns to `.main` (including from the Cheats pane itself), so toggling a
  /// cheat and backing out updates the count without needing a manual refresh.
  @State private var activeCheatCount: Int = 0
  private func refreshActiveCheatCount() {
    activeCheatCount = CheatsMenuView.activeCheatCount(forGameId: game.gameID, revision: game.revision)
  }

  /// Mutes / unmutes through the helper the top bar shares, so both always agree.
  private func toggleMute() {
    isMuted = QuickMute.toggle()
  }

  /// Currently configured fast-forward speed, read from the same UserDefaults key
  /// `TVEmulationBridge.setFastForwardSpeedPercent(_:)` writes. Falls back to the
  /// bridge's own default (300 = 3x) before anything has been picked.
  private var configuredFastForwardPercent: Int {
    (UserDefaults.standard.object(forKey: Self.fastForwardSpeedPercentKey) as? Int) ?? 300
  }

  /// Turns fast-forward off without leaving the pause menu, mirroring the old
  /// in-place toggle's off behavior.
  private func turnOffFastForward() {
    if TVEmulationBridge.isFastForwardEnabled() {
      _ = TVEmulationBridge.toggleFastForward()
    }
    fastForwardEnabled = false
  }

  var body: some View {
    ZStack {
      // Full screen black background
      Color.black
        .ignoresSafeArea()

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
      fastForwardEnabled = TVEmulationBridge.isFastForwardEnabled()
      refreshActiveCheatCount()
      refreshShaderState()
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
    #endif
    .onChange(of: pane) { _, newPane in
      DispatchQueue.main.async {
        switch newPane {
        case .main:
          // D15: covers backing out of Cheats (toggled codes should update the
          // badge) as well as the other panes, which is a harmless extra read.
          refreshActiveCheatCount()
        case .saves:
          focused = .back
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
        SettingsRootView()
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

  // Add pull-down to dismiss for iOS
  #if os(iOS)
  init(selectedSlot: Binding<Int>, onClose: @escaping () -> Void, onShowSettings: @escaping () -> Void, platform: PlatformKind, game: TVGameItem) {
    self._selectedSlot = selectedSlot
    self.onClose = onClose
    self.onShowSettings = onShowSettings
    self.platform = platform
    self.game = game
  }
  #endif

  /// One tile-grid root for both platforms: cover column beside the tiles on tvOS, a compact header above them on iOS.
  @ViewBuilder
  private var mainMenu: some View {
    GeometryReader { proxy in
      let isTV = platform == .tvos
      let compactHeight = isCompactHeight
      let columns = PauseTileLayout.columns(forWidth: proxy.size.width, isTV: isTV, isCompactHeight: compactHeight)
      ZStack {
        if isTV {
          HStack(alignment: .top, spacing: 48) {
            coverColumn.frame(width: 220)
            tiles(columns: columns, compact: false)
          }
          .padding(60)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            compactHeader(isCompactHeight: compactHeight).padding(compactHeight ? 12 : 16)
            tiles(columns: columns, compact: compactHeight)
          }
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
      .background(backdrop)
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

  private var backdrop: some View {
    ZStack {
      Image(uiImage: game.bannerImage ?? game.coverImage)
        .resizable().scaledToFill().blur(radius: 24).opacity(0.5).ignoresSafeArea().clipped()
      LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
  }

  private var coverColumn: some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(uiImage: game.coverImage)
        .resizable().aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)
      Text(game.title).font(.title3.bold()).foregroundStyle(.white).lineLimit(2)
      Text(game.gameID).font(.caption).foregroundStyle(.white.opacity(0.7))
      Text(L("Paused")).font(.caption.weight(.semibold)).foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.white.opacity(0.18)))
    }
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
      } else {
        VStack(alignment: .leading, spacing: 2) {
          Text(game.title).font(.headline).foregroundStyle(.white).lineLimit(1)
          Text(game.gameID).font(.caption).foregroundStyle(.white.opacity(0.7))
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

  /// Shared wrapper for the Reset/Exit confirm overlays: a
  /// translucent scrim behind a card with an explicit title/message above
  /// the confirm/cancel row list (the model's own `MenuSection.header` is
  /// left `nil` for these models specifically so `MenuScreen`'s grid
  /// doesn't render a second, differently-styled title below this one).
  private var confirmWidth: CGFloat { platform == .tvos ? 640 : 380 }

  @ViewBuilder
  private func confirmOverlay(title: String, message: String, model: MenuModel, onBack: @escaping () -> Void) -> some View {
    ZStack {
      Color.black.opacity(0.55).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.system(size: 18, weight: .bold))
          .foregroundColor(.white)
        Text(message)
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.white.opacity(0.8))
        // `.grid`'s `ScrollView` has no natural height of its own here, so it
        // greedily fills whatever the VStack offers -- clamp using `gridCard`'s
        // actual row math (44pt icon + 12pt padding top/bottom = 68pt per
        // card, 12pt inter-row spacing, `gridBody`'s own 16pt top+bottom
        // padding = 80n + 20 for n rows) instead of letting a 2-button
        // confirm card stretch to the screen's height. `maxHeight`, not a
        // fixed `height`, so it can still shrink (and `MenuScreen.grid`
        // scroll) in landscape or under Dynamic Type, where a long
        // confirm list may not fit.
        #if os(tvOS)
        MenuScreen(model: model, style: .list, onBack: onBack)
          .frame(maxHeight: CGFloat(model.allItems.count) * 110 + 40)
          .focusSection()
        #else
        MenuScreen(model: model, style: .grid, onBack: onBack)
          .frame(maxHeight: CGFloat(model.allItems.count) * 80 + 20)
        #endif
      }
      .padding(16)
      .frame(maxWidth: confirmWidth)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(.ultraThinMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.white.opacity(0.08), lineWidth: 1)
      )
      .padding(24)
    }
    .transition(.opacity)
  }

  private var savesMenu: some View {
    Group {
      if platform == .ios {
        NavigationStack {
          List {
            Section(header: Text(L("Quick Slots"))) {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                  ForEach(1 ... 10, id: \.self) { i in
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
        ZStack {
          // Beautiful blurred background - use GameBanner if available
          Image(uiImage: game.bannerImage ?? game.coverImage)
            .resizable()
            .scaledToFill()
            .blur(radius: 25)
            .opacity(0.8)
            .ignoresSafeArea()

          // Elegant gradient overlay
          LinearGradient(
            colors: [
              Color.black.opacity(0.85),
              Color.black.opacity(0.4),
              Color.black.opacity(0.85)
            ],
            startPoint: .top,
            endPoint: .bottom
          )
          .ignoresSafeArea()

          // Content with proper layout
          VStack(spacing: 40) {
            // Header with back button and title
            HStack {
              Button(action: { pane = .main }) {
                HStack(spacing: 12) {
                  Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                  Text("Back to Menu")
                    .font(.system(size: 18, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              }
              .buttonStyle(.plain)
              .focused($focused, equals: .back)

              Spacer()

              VStack(spacing: 4) {
                Text(L("Save States"))
                  .font(.system(size: 28, weight: .bold))
                  .foregroundColor(.white)

                Text(L("Manage your game progress"))
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.7))
              }

              Spacer()
            }

            // Save slot selection
            VStack(spacing: 24) {
              Text(L("Select Save Slot"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)

              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                  ForEach(1 ... 10, id: \.self) { i in
                    Button(action: { selectedSlot = i }) {
                      VStack(spacing: 4) {
                        ZStack {
                          RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedSlot == i ? .blue.opacity(0.3) : .white.opacity(0.1))
                            .frame(width: 44, height: 44)

                          VStack(spacing: 1) {
                            if selectedSlot == i {
                              Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.blue)
                            } else {
                              Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                            }

                            Text("\(i)")
                              .font(.system(size: 10, weight: .semibold))
                              .foregroundColor(selectedSlot == i ? .blue : .white)
                          }
                        }

                        Text(L("Slot") + "\(i)")
                          .font(.system(size: 8, weight: .medium))
                          .foregroundColor(.white.opacity(0.7))
                      }
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .compositingGroup()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .focused($focused, equals: .slot(i))
                  }
                }
                .padding(.horizontal, 30)
              }
            }

            // Action buttons
            HStack(spacing: 24) {
              Button(action: { SaveStateService.saveSlot(selectedSlot) }) {
                HStack(spacing: 12) {
                  Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                  Text(L("Save to Slot") + "\(selectedSlot)")
                    .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.green.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.green.opacity(0.4), lineWidth: 1)
                )
              }
              .buttonStyle(.plain)
              .focused($focused, equals: .save)

              Button(action: { TVEmulationBridge.loadState(fromSlot: selectedSlot) }) {
                HStack(spacing: 12) {
                  Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                  Text(L("Load from Slot") + "\(selectedSlot)")
                    .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.blue.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.blue.opacity(0.4), lineWidth: 1)
                )
              }
              .buttonStyle(.plain)
              .focused($focused, equals: .load)

              // D10: tvOS previously had no way to reach the redesigned grid at
              // all -- showFilmstripSheet was only ever set from the iOS pane.
              Button(action: { showFilmstripSheet = true }) {
                HStack(spacing: 12) {
                  Image(systemName: "square.grid.2x2")
                    .font(.system(size: 16, weight: .semibold))
                  Text(L("View All States"))
                    .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
                )
              }
              .buttonStyle(.plain)
              .focused($focused, equals: .filmstrip)
            }
            .frame(maxWidth: 600)
          }
          .padding(60)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .zIndex(100)
        }
        #if os(tvOS)
        .onExitCommand { pane = .main }
        #endif
        .sheet(isPresented: $showFilmstripSheet) {
          NavigationStack { SaveStateFilmstripView(gameID: game.gameID) }
            .pauseClaim("filmstrip")
            .claimsController()
        }
      }
    }
  }

  // MARK: - Pause menu model

  /// Persists `percent` and turns fast-forward on; the game picks it up when the player resumes.
  private func selectFastForwardSpeed(_ percent: Int) {
    TVEmulationBridge.setFastForwardSpeedPercent(percent)
    if !TVEmulationBridge.isFastForwardEnabled() { _ = TVEmulationBridge.toggleFastForward() }
    fastForwardEnabled = true
  }

  private var pauseMenuBindings: PauseMenuBindings {
    PauseMenuBindings(
      mute: Binding(get: { isMuted }, set: { _ in toggleMute() }),
      fastForward: Binding(
        get: { fastForwardEnabled ? AnyHashable(configuredFastForwardPercent) : PauseMenuModelBuilder.fastForwardOff },
        set: { value in
          if let percent = value as? Int, percent >= 0 { selectFastForwardSpeed(percent) } else { turnOffFastForward() }
        }),
      quickSlot: Binding(get: { AnyHashable(selectedSlot) }, set: { if let slot = $0 as? Int { selectedSlot = slot } }),
      shader: Binding(
        get: { AnyHashable(ShaderQuickApply.currentPath ?? "") },
        set: { value in
          let path = value as? String
          ShaderQuickApply.apply(path: (path?.isEmpty ?? true) ? nil : path)
          refreshShaderState()
        }))
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
      showsRecenterPointer: Self.showsRecenterPointer)
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
        showSettingsSheet = true
        #else
        onShowSettings()
        #endif
      },
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
        // Same as the console's reset button. It does not reload the auto-resume state, so it is also
        // the way out of a game that resumed into a bad save.
        TVEmulationBridge.resetSystem()
        onClose()
      }),
    ])])
  }

  /// Confirm overlay shown for `showExitDialog` -- Cancel first, matching the
  /// original `.alert`'s order (Cancel, Quit, Save & Quit).
  private var exitConfirmModel: MenuModel {
    MenuModel(sections: [MenuSection(id: "exit-confirm", items: [
      MenuItem(id: "exit-cancel", title: L("Cancel"), icon: "xmark", role: .action { showExitDialog = false }),
      MenuItem(id: "exit-quit", title: L("Quit"), icon: "xmark.circle", tint: .red, role: .destructive {
        showExitDialog = false
        TVEmulationBridge.stop()
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      }),
      MenuItem(id: "exit-save-quit", title: L("Save & Quit"), icon: "square.and.arrow.down", tint: .blue, role: .action {
        showExitDialog = false
        SaveStateService.saveSlot(selectedSlot)
        TVEmulationBridge.stop()
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
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
}

/// Live bindings for the in-place tiles. Writing one applies immediately; the host rebuilds the model.
struct PauseMenuBindings {
  var mute: Binding<Bool>
  var fastForward: Binding<AnyHashable>
  var quickSlot: Binding<AnyHashable>
  var shader: Binding<AnyHashable>
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
  var requestReset: () -> Void
  var requestExit: () -> Void
  var recenterPointer: () -> Void
}

/// Unified menu UX spec §5: Quick / Game / System. Shared by iOS and tvOS.
enum PauseMenuModelBuilder {
  static let fastForwardOff: AnyHashable = AnyHashable(-1)
  static let fastForwardOptions: [(String, AnyHashable)] = [
    (L("Off"), fastForwardOff), ("2x", AnyHashable(200)), ("3x", AnyHashable(300)), ("4x", AnyHashable(400)), ("8x", AnyHashable(800)), (L("Unlimited"), AnyHashable(0)),
  ]
  static let slotCount = 10

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
    ])

    var game: [MenuItem] = [
      MenuItem(id: "save-states", title: L("Save States"), icon: "square.stack.3d.up", tint: .purple, role: .action(actions.openSaveStates),
               description: L("Save, load and browse every slot.")),
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

#if DEBUG
import UIKit

extension PauseMenuView {
  /// A stand-in `TVGameItem` for previews and snapshot tests.
  static func previewGame() -> TVGameItem {
    guard let cls = NSClassFromString("TVGameItem") as? NSObject.Type else {
      fatalError("TVGameItem class not found for preview")
    }
    let obj = cls.init()
    let img = UIImage(systemName: "gamecontroller")?.withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage()
    obj.setValue("Preview Game", forKey: "title")
    obj.setValue("RMCP01", forKey: "gameID")
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
