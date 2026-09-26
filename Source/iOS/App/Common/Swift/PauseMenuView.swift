// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController
import SwiftUI

#if os(iOS)
#endif

internal enum PlatformKind { case ios, tvos }

/// Pure decision logic for the iOS pause menu's raw `GCController` handler
/// (`PauseMenuView.setupPauseControllerNav`): whether a `buttonA` reading
/// should be treated as a fresh activate edge, given whether a child sheet
/// (Save States, Shaders, Continuity, Controllers, Settings) currently owns
/// the controller via `ControllerFocusCoordinator`.
///
/// The raw handler is never torn down while a child sheet merely covers this
/// view -- SwiftUI does not reliably fire `onDisappear` on a descendant that
/// is only covered, not removed (see `PauseMenuView.isPauseMenuChildPresented`)
/// -- so it keeps receiving every gamepad callback and must self-gate instead
/// of relying on teardown/reinstall timing, exactly like `TVLibraryView`'s own
/// `extendedGamepad.valueChangedHandler` gates on
/// `ControllerFocusCoordinator.isActiveScope`.
///
/// `buttonA` is latch-and-rearm, mirroring `RemapControllerNav`: one activate
/// per physical press, re-armed only once the button reports released. This
/// also covers the reclaim race -- if a child sheet claims the controller
/// while A is held (e.g. the same press that opened it) and the claim is
/// released again before A comes back up, that held press does not replay as
/// a fresh activate the instant this menu regains the controller; it is
/// swallowed until an actual release is observed.
internal struct PauseMenuInputGate: Equatable {
  private var aLatched = false

  /// Call on every raw `valueChangedHandler` callback with the CURRENT claim
  /// state and the live `buttonA.isPressed` reading -- valid regardless of
  /// which element actually triggered the callback, since `GCExtendedGamepad`
  /// exposes a live snapshot of every button. Returns whether this call
  /// should be treated as a fresh `buttonA` down-edge that the caller should
  /// act on (e.g. by activating the focused row).
  @discardableResult
  internal mutating func consumeButtonA(claimed: Bool, isPressed: Bool) -> Bool {
    guard !claimed else {
      // While a child owns the controller, just track physical state so a
      // press held across the claim boundary doesn't fire once we're
      // unclaimed again.
      aLatched = isPressed
      return false
    }
    guard isPressed else {
      aLatched = false
      return false
    }
    guard !aLatched else { return false }
    aLatched = true
    return true
  }
}

internal struct PauseMenuView: View {
  @Binding var selectedSlot: Int
  let onClose: () -> Void
  let onShowSettings: () -> Void
  let platform: PlatformKind
  let game: TVGameItem

  @FocusState private var focused: FocusField?
  internal enum FocusField: Hashable {
    case resume, openSaves, cheats, mapping, settings, shaders, continuity
    case exit, back, slot(Int), save, load, mute, fastForward
    /// D10: the tvOS saves pane's "View All States" button, into the redesigned
    /// grid (`SaveStateFilmstripView`) -- previously iOS-only.
    case filmstrip
    /// D14: rows in the tvOS fast-forward speed chooser (`tvFastForwardSpeedMenu`).
    case fastForwardOff, fastForwardChoice(Int)
  }
  private enum Pane { case main, saves, cheats, controllers, fastForwardSpeed }
  @State private var pane: Pane = .main
  @State private var showExitDialog: Bool = false
  @State private var showResetDialog: Bool = false
  @State private var showShaders: Bool = false
  @State private var showSettingsSheet: Bool = false
  @State private var showControllersSheet: Bool = false
  /// Wii titles get the Wii Remote rows first, then the GameCube ports many of them also
  /// accept; GameCube titles get the ports only. Read from the running core, not from
  /// `ControllerManager.isWiiSystem`, which nothing kept up to date (the menu was GameCube-only
  /// for every game).
  private static var controllerSetupSystem: ControllerSetupSystem {
    let isWii = TVEmulationBridge.isRunning() ? TVEmulationBridge.isCurrentSystemWii() : ControllerManager.shared.isWiiSystem
    return isWii ? .wiiAndGameCube : .gamecube
  }

  @State private var showFilmstripSheet: Bool = false
  /// WS-4: "continue this game on another device".
  @State private var showContinuitySheet: Bool = false

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
  // cutscene). Kept as plain toggles on the main pane rather than a settings
  // trip. UserDefaults key remembers the pre-mute volume so unmute restores it
  // instead of guessing a level.
  @State private var isMuted: Bool = false
  @State private var fastForwardEnabled: Bool = false
  private static let volumeBeforeMuteKey = "icube_pause_menu_volume_before_mute"
  /// D14: drives the iOS speed picker (`.confirmationDialog`). Declared unconditionally,
  /// like `showControllersSheet`/`showSettingsSheet` above, because `iosMenuItems` is
  /// compiled for both platforms even though it is only presented on iOS.
  @State private var showFastForwardSpeedPicker: Bool = false
  /// Same UserDefaults key `TVEmulationBridge` reads when fast-forward is turned on
  /// (also written by the Settings > General fast-forward speed picker) — kept as one
  /// named constant here rather than a literal at each pause-menu call site.
  private static let fastForwardSpeedPercentKey = "fast_forward_speed_percent"
  /// The choices offered from the pause menu specifically (1.5x/2x/3x/Unlimited).
  /// Settings > General offers a wider range for the same UserDefaults key.
  private static let fastForwardSpeedChoices: [Int] = [150, 200, 300, 0]

  /// D15: "N active" badge on the Cheats item. Refreshed on appear and whenever the
  /// pane returns to `.main` (including from the Cheats pane itself), so toggling a
  /// cheat and backing out updates the count without needing a manual refresh.
  @State private var activeCheatCount: Int = 0
  private func refreshActiveCheatCount() {
    activeCheatCount = CheatsMenuView.activeCheatCount(forGameId: game.gameID, revision: game.revision)
  }
  private var cheatsSubtitle: String {
    activeCheatCount > 0 ? String(format: L("%d active"), activeCheatCount) : L("Game enhancement codes")
  }

  /// iOS controller-driven focus index into `iosMenuItems`. iOS has no focus
  /// engine here, so navigation is driven manually from GCController input,
  /// mirroring the main library view. Unused on tvOS (native focus).
  @State private var iosFocusIndex: Int = 0
  /// When false, no row shows the controller-navigation ring (touch-only use).
  @State private var pauseMenuControllerNavActive: Bool = false
  @State private var lastPauseNavMoveTime: TimeInterval = 0
  #if !os(tvOS)
  /// Saved pre-existing gamepad handlers, restored on teardown so the emulation
  /// input path is left exactly as it was.
  @State private var prevPauseEGPHandlers: [ObjectIdentifier: (GCExtendedGamepad, GCControllerElement) -> Void] = [:]
  /// This menu's controller-ownership scope (`ControllerFocusCoordinator`).
  /// Claimed while the iOS row list is on screen so any of this menu's own
  /// child sheets (Save States, Shaders, Continuity, Controllers, Settings)
  /// that call `.claimsController()` silence `setupPauseControllerNav`'s raw
  /// handler below instead of fighting it for the shared `valueChangedHandler`
  /// slot.
  @State private var pauseMenuScopeID = UUID()
  /// Edge/latch state for `buttonA`, including the reclaim case described on
  /// `PauseMenuInputGate`.
  @State private var pauseNavGate = PauseMenuInputGate()
  #endif

  /// A single iOS pause-menu entry, modeled so the grid can be indexed for
  /// controller focus while keeping each row's action with its presentation.
  private struct IOSMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let role: ButtonRole?
    let action: () -> Void
  }

  private var iosMenuItems: [IOSMenuItem] {
    var items: [IOSMenuItem] = [
      IOSMenuItem(title: L("Resume Game"), subtitle: L("Return to gameplay"), icon: "play.fill", tint: .blue, role: nil) {
        TVEmulationBridge.resume()
        onClose()
      },
      IOSMenuItem(
        title: isMuted ? L("Unmute") : L("Mute"),
        subtitle: isMuted ? L("Restore audio volume") : L("Silence audio"),
        icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
        tint: .cyan, role: nil
      ) { toggleMute() },
      IOSMenuItem(
        title: L("Fast Forward"),
        subtitle: fastForwardSubtitle,
        icon: fastForwardEnabled ? "forward.fill" : "forward",
        tint: .cyan, role: nil
      ) { showFastForwardSpeedPicker = true },
      IOSMenuItem(title: L("Save States"), subtitle: L("Manage game saves"), icon: "square.stack.3d.up", tint: .purple, role: nil) { pane = .saves },
      IOSMenuItem(title: L("Cheats"), subtitle: cheatsSubtitle, icon: "star.circle", tint: .yellow, role: nil) { pane = .cheats },
      IOSMenuItem(title: L("Controllers"), subtitle: L("Input configuration"), icon: "gamecontroller", tint: .green, role: nil) {
        #if os(iOS)
        showControllersSheet = true
        #else
        pane = .controllers
        #endif
      },
      IOSMenuItem(title: L("Shaders"), subtitle: L("Post-processing"), icon: "wand.and.stars", tint: .orange, role: nil) { showShaders = true },
      IOSMenuItem(title: L("Continue Elsewhere"), subtitle: L("Hand this game to a nearby device"), icon: "arrow.triangle.branch", tint: .teal, role: nil) { showContinuitySheet = true },
    ]
    #if os(iOS)
    items.append(IOSMenuItem(title: L("Settings"), subtitle: L("Game & system options"), icon: "gearshape", tint: .gray, role: nil) { showSettingsSheet = true })
    #endif
    items.append(IOSMenuItem(title: L("Reset System"), subtitle: L("Restart the game from power-on"), icon: "arrow.counterclockwise.circle", tint: .orange, role: nil) { showResetDialog = true })
    items.append(IOSMenuItem(title: L("Exit Game"), subtitle: L("Return to library"), icon: "xmark.circle", tint: .red, role: .destructive) { showExitDialog = true })
    return items
  }

  /// Mutes by zeroing the volume, remembering the prior level so unmute restores it
  /// instead of guessing. Mirrors the pattern of other Config-backed toggles: read
  /// through the bridge rather than trusting `@State` to stay in sync elsewhere.
  private func toggleMute() {
    let current = DOLConfigBridge.audioVolume()
    if current > 0 {
      UserDefaults.standard.set(current, forKey: Self.volumeBeforeMuteKey)
      DOLConfigBridge.setAudioVolume(0)
      isMuted = true
    } else {
      let stored = UserDefaults.standard.object(forKey: Self.volumeBeforeMuteKey) as? Int ?? 100
      DOLConfigBridge.setAudioVolume(stored > 0 ? stored : 100)
      isMuted = false
    }
  }

  /// Currently configured fast-forward speed, read from the same UserDefaults key
  /// `TVEmulationBridge.setFastForwardSpeedPercent(_:)` writes. Falls back to the
  /// bridge's own default (300 = 3x) before anything has been picked.
  private var configuredFastForwardPercent: Int {
    (UserDefaults.standard.object(forKey: Self.fastForwardSpeedPercentKey) as? Int) ?? 300
  }

  private static func fastForwardSpeedLabel(percent: Int) -> String {
    if percent == 0 { return L("Unlimited") }
    let multiplier = Double(percent) / 100.0
    return multiplier.truncatingRemainder(dividingBy: 1) == 0
      ? "\(Int(multiplier))x"
      : String(format: "%.1fx", multiplier)
  }

  private var fastForwardSubtitle: String {
    guard fastForwardEnabled else { return L("Off — choose a speed to start") }
    return String(format: L("On at %@ — choose to change"), Self.fastForwardSpeedLabel(percent: configuredFastForwardPercent))
  }

  /// Persists `percent`, turns fast-forward on if it wasn't already (a mid-flight
  /// speed change re-applies live via `setFastForwardSpeedPercent(_:)` without a
  /// toggle-off/on blip), then leaves the pause menu immediately so the game runs
  /// at the new speed right away.
  private func selectFastForwardSpeed(_ percent: Int) {
    TVEmulationBridge.setFastForwardSpeedPercent(percent)
    if !TVEmulationBridge.isFastForwardEnabled() {
      _ = TVEmulationBridge.toggleFastForward()
    }
    fastForwardEnabled = true
    TVEmulationBridge.resume()
    onClose()
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
        NavigationStack {
          ControllerSetupView(system: Self.controllerSetupSystem)
            .toolbar {
              ToolbarItem(placement: .navigationBarLeading) { Button(L("Back")) { pane = .main } }
            }
        }
        .onExitCommand { pane = .main }
        .onAppear { NSLog("[PAUSE] Controller setup menu appeared") }
      case .fastForwardSpeed:
        tvFastForwardSpeedMenu
          .onAppear { NSLog("[PAUSE] Fast forward speed menu appeared") }
      #else
      case .controllers:
        mainMenu
      case .fastForwardSpeed:
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
      TVEmulationBridge.pause()
      isMuted = DOLConfigBridge.audioVolume() <= 0
      fastForwardEnabled = TVEmulationBridge.isFastForwardEnabled()
      refreshActiveCheatCount()
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
      if TVEmulationBridge.isRunning() && TVEmulationBridge.isPaused() { TVEmulationBridge.resume() }
    }
    #if os(tvOS)
    .focusSection()
    #endif
    .onChange(of: pane) { p in
      DispatchQueue.main.async {
        switch p {
        case .main:
          focused = .resume
          // D15: covers backing out of Cheats (toggled codes should update the
          // badge) as well as the other panes, which is a harmless extra read.
          refreshActiveCheatCount()
        case .saves:
          focused = .back
        case .cheats:
          focused = .back
        case .controllers:
          focused = .back
        case .fastForwardSpeed:
          focused = .back
        }
      }
    }
    #if os(tvOS)
    .onExitCommand {
      if pane == .main {
        onClose()
      } else {
        pane = .main
      }
    }
    #endif
    .modifier(DefaultFocusCompat(focused: $focused, value: .resume))
    // D16: the pause menu gets the quick-preview picker (tap a card to apply,
    // long-press or its gear button for parameters) rather than the full
    // Settings-style `ShaderSettingsView` list — that view (and its debug tools)
    // is still reachable from Settings > Shaders and the in-game FX sheet.
    .sheet(isPresented: $showShaders) {
      NavigationStack {
        ShaderQuickPickerView()
      }
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
      .claimsController()
    }
    .sheet(isPresented: $showControllersSheet) {
      NavigationStack {
        ControllerSetupView(system: Self.controllerSetupSystem)
          .navigationTitle(L("Controllers"))
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Close")) { showControllersSheet = false } } }
      }
      .claimsController()
    }
    #endif
    // WS-4 sender surface. Unconditional (not #if os(iOS)): tvOS has no system
    // Handoff, so the in-app offer is the ONLY way an Apple TV can hand a game
    // to another device.
    .sheet(isPresented: $showContinuitySheet) {
      ContinuityHandoffSheet(game: game)
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

  @ViewBuilder
  private var mainMenu: some View {
    if platform == .ios {
      iosMainMenu
    } else {
      tvMainMenu
    }
  }

  // iOS: compact layout with adaptive grid and safe-area background
  private var iosMainMenu: some View {
    let backgroundView = ZStack {
      // Use cover image for iOS (better aspect ratio fit)
      Image(uiImage: game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 24)
        .opacity(0.5)
        .ignoresSafeArea()
      LinearGradient(
        colors: [
          Color.black.opacity(0.85),
          Color.black.opacity(0.35),
          Color.black.opacity(0.85)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    }

    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Button(action: { onClose() }) {
            Text(L("Close"))
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(.white)
              .padding(.horizontal, 18)
              .padding(.vertical, 10)
              .background(
                Capsule(style: .continuous)
                  .fill(.ultraThinMaterial)
              )
              .overlay(
                Capsule(style: .continuous)
                  .stroke(Color.white.opacity(0.08), lineWidth: 1)
              )
          }
          .buttonStyle(.plain)
          Spacer()
        }

        HStack(alignment: .top, spacing: 12) {
          Image(uiImage: game.coverImage)
            .resizable()
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(width: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          VStack(alignment: .leading, spacing: 4) {
            Text(game.title)
              .font(.headline)
              .foregroundStyle(.white)
            Text(game.gameID)
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.7))
          }
          Spacer(minLength: 0)
        }

        // Adaptive grid: 1 column portrait, 2+ landscape based on width automatically
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
          ForEach(Array(iosMenuItems.enumerated()), id: \.offset) { idx, item in
            menuButtonIOS(
              title: item.title,
              subtitle: item.subtitle,
              icon: item.icon,
              tint: item.tint,
              role: item.role,
              focused: pauseMenuControllerNavActive && iosFocusIndex == idx,
              action: item.action
            )
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(backgroundView)
    #if !os(tvOS)
    // Claims controller ownership for as long as this row list is around,
    // including while covered by one of this menu's own child sheets (which
    // never sends a real `onDisappear` here -- see the doc on
    // `pauseMenuScopeID`). `setupPauseControllerNav`'s handler self-gates on
    // `ControllerFocusCoordinator.isActiveScope(pauseMenuScopeID)`.
    .controllerScope(pauseMenuScopeID)
    #endif
    .onDisappear {
      #if !os(tvOS)
      teardownPauseControllerNav()
      pauseMenuControllerNavActive = false
      #endif
    }
    #if os(iOS)
    .onAppear {
      refreshPauseMenuControllerNav()
    }
    .onReceive(ControllerManager.shared.controllerConnectedPublisher) { _ in
      refreshPauseMenuControllerNav()
    }
    .onReceive(ControllerManager.shared.controllerDisconnectedPublisher) { _ in
      refreshPauseMenuControllerNav()
    }
    #endif
    .alert(L("Reset System"), isPresented: $showResetDialog) {
      Button(L("Cancel"), role: .cancel) { showResetDialog = false }
      Button(L("Reset"), role: .destructive) {
        // Same as the console's reset button. It does not reload the auto-resume state, so it is also
        // the way out of a game that resumed into a bad save.
        TVEmulationBridge.resetSystem()
        onClose()
      }
    } message: {
      Text(L("Restart the game as if the console's reset button was pressed? Unsaved progress will be lost."))
    }
    .alert(L("Exit Game"), isPresented: $showExitDialog) {
      Button(L("Cancel"), role: .cancel) { showExitDialog = false }
      Button(L("Quit"), role: .destructive) {
        TVEmulationBridge.stop()
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      }
      Button(L("Save & Quit")) {
        SaveStateService.saveSlot(selectedSlot)
        TVEmulationBridge.stop()
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      }
    } message: {
      Text(L("Do you want to quit the game? Unsaved progress will be lost."))
    }
    // D14: picking a speed here both starts fast-forward and leaves the pause menu
    // right away, so the game visibly speeds up instead of leaving the user to guess
    // whether the tap registered.
    .confirmationDialog(L("Fast Forward Speed"), isPresented: $showFastForwardSpeedPicker, titleVisibility: .visible) {
      if fastForwardEnabled {
        Button(L("Turn Off")) { turnOffFastForward() }
      }
      ForEach(Self.fastForwardSpeedChoices, id: \.self) { percent in
        Button(Self.fastForwardSpeedLabel(percent: percent)) { selectFastForwardSpeed(percent) }
      }
      Button(L("Cancel"), role: .cancel) {}
    } message: {
      Text(L("Starts fast-forward at this speed and closes the pause menu."))
    }
  }

  /// Styled iOS pause menu row with icon and subtitle
  @ViewBuilder
  private func menuRowIOS(title: String, subtitle: String, icon: String, tint: Color) -> some View {
    HStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(tint.opacity(0.15))
          .frame(width: 44, height: 44)
        Image(systemName: icon)
          .font(.system(size: 18, weight: .semibold))
          .foregroundColor(tint)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.white)
        Text(subtitle)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(.white.opacity(0.7))
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white.opacity(0.5))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  /// Reusable iOS menu button applying consistent styling. `focused` draws the
  /// controller-navigation indicator (iOS has no focus engine in this menu).
  @ViewBuilder
  private func menuButtonIOS(title: String, subtitle: String, icon: String, tint: Color, role: ButtonRole? = nil, focused: Bool = false, action: @escaping () -> Void) -> some View {
    Button(role: role, action: action) {
      menuRowIOS(title: title, subtitle: subtitle, icon: icon, tint: tint)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(focused ? Color.accentColor : Color.clear, lineWidth: 3)
        )
    }
    .buttonStyle(.plain)
  }

  /// tvOS pause-menu row for an in-place toggle (mute, fast-forward) rather than a
  /// pane change — same visual shape as the other rows in `tvMainMenu` so it reads
  /// as part of the same list, without duplicating that ~25-line HStack per toggle.
  @ViewBuilder
  private func tvMenuToggleRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 20) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.1))
            .frame(width: 48, height: 48)
          Image(systemName: icon)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(.white)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)
          Text(subtitle)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
        }
        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(.white.opacity(0.05))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  /// D14: one focusable row per fast-forward speed choice (or the "Turn Off" row),
  /// styled like `tvFastForwardSpeedMenu`'s other rows. `selected` shows a checkmark
  /// for the speed currently configured while fast-forward is on.
  @ViewBuilder
  private func tvFastForwardChoiceRow(icon: String, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 20) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.1))
            .frame(width: 48, height: 48)
          Image(systemName: selected ? "checkmark.circle.fill" : icon)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(selected ? .green : .white)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)
          Text(subtitle)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
        }
        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(.white.opacity(0.05))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  /// D14: tvOS focusable speed chooser for Fast Forward, opened by navigating to
  /// `Pane.fastForwardSpeed` instead of the old in-place toggle (picking a speed
  /// here also starts FF and leaves the pause menu, which a plain toggle can't do).
  private var tvFastForwardSpeedMenu: some View {
    ZStack {
      Image(uiImage: game.bannerImage ?? game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 25)
        .opacity(0.8)
        .ignoresSafeArea()

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

      VStack(spacing: 32) {
        HStack {
          Button(action: { pane = .main }) {
            HStack(spacing: 12) {
              Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
              Text(L("Back"))
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

          Text(L("Fast Forward Speed"))
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(.white)

          Spacer()
        }

        VStack(spacing: 12) {
          if fastForwardEnabled {
            tvFastForwardChoiceRow(
              icon: "forward.slash",
              title: L("Turn Off"),
              subtitle: L("Return to normal speed"),
              selected: false
            ) {
              turnOffFastForward()
              pane = .main
            }
            .focused($focused, equals: .fastForwardOff)
          }
          ForEach(Self.fastForwardSpeedChoices, id: \.self) { percent in
            tvFastForwardChoiceRow(
              icon: "forward.fill",
              title: Self.fastForwardSpeedLabel(percent: percent),
              subtitle: L("Start fast-forward and resume"),
              selected: fastForwardEnabled && configuredFastForwardPercent == percent
            ) {
              selectFastForwardSpeed(percent)
            }
            .focused($focused, equals: .fastForwardChoice(percent))
          }
        }
        .frame(maxWidth: 480)
      }
      .padding(60)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .zIndex(100)
    }
    #if os(tvOS)
    .onExitCommand { pane = .main }
    #endif
  }

  #if !os(tvOS)
  /// True when at least one connected controller can drive pause-menu navigation.
  private static func hasPauseMenuNavController() -> Bool {
    GCController.controllers().contains { $0.extendedGamepad != nil }
  }

  private func refreshPauseMenuControllerNav() {
    teardownPauseControllerNav()
    let active = Self.hasPauseMenuNavController()
    pauseMenuControllerNavActive = active
    if active {
      iosFocusIndex = min(iosFocusIndex, max(0, iosMenuItems.count - 1))
      setupPauseControllerNav()
    }
  }

  /// Throttled focus move through `iosMenuItems`, mirroring the library's repeat
  /// guard so a held d-pad doesn't skip rows.
  private func movePauseFocus(_ delta: Int) {
    guard pauseMenuControllerNavActive else { return }
    let now = Date().timeIntervalSince1970
    if now - lastPauseNavMoveTime < 0.18 { return }
    lastPauseNavMoveTime = now
    let count = iosMenuItems.count
    guard count > 0 else { return }
    DispatchQueue.main.async {
      iosFocusIndex = max(0, min(iosFocusIndex + delta, count - 1))
    }
  }

  private func activatePauseFocus() {
    let items = iosMenuItems
    guard items.indices.contains(iosFocusIndex) else { return }
    DispatchQueue.main.async { items[iosFocusIndex].action() }
  }

  private func setupPauseControllerNav() {
    GCController.shouldMonitorBackgroundEvents = false
    let scope = pauseMenuScopeID
    for c in GCController.controllers() {
      guard let egp = c.extendedGamepad else { continue }
      let cid = ObjectIdentifier(c)
      if prevPauseEGPHandlers[cid] == nil { prevPauseEGPHandlers[cid] = egp.valueChangedHandler }
      egp.valueChangedHandler = { gamepad, element in
        // A child sheet (Save States, Shaders, Continuity, Controllers,
        // Settings) claims the controller via `.claimsController()` while it
        // is up. This handler is never torn down while merely covered, so it
        // must self-gate here rather than rely on onAppear/onDisappear -- the
        // same pattern `TVLibraryView.setupControllerNavigation` uses.
        let claimed = !ControllerFocusCoordinator.isActiveScope(scope)
        // Feed the gate every callback (regardless of `element`) so its latch
        // tracks buttonA's live state and the reclaim case is handled even
        // when the callback that flips `claimed` isn't the buttonA one.
        let activateA = pauseNavGate.consumeButtonA(claimed: claimed, isPressed: gamepad.buttonA.isPressed)
        guard !claimed else { return }
        let dpad = gamepad.dpad
        if element == dpad.up, dpad.up.isPressed { movePauseFocus(-1) }
        if element == dpad.down, dpad.down.isPressed { movePauseFocus(1) }
        if element == dpad.left, dpad.left.isPressed { movePauseFocus(-1) }
        if element == dpad.right, dpad.right.isPressed { movePauseFocus(1) }
        if element == gamepad.leftThumbstick {
          let vy = gamepad.leftThumbstick.yAxis.value
          if vy > 0.6 { movePauseFocus(-1) }
          if vy < -0.6 { movePauseFocus(1) }
        }
        if activateA { activatePauseFocus() }
      }
    }
  }

  private func teardownPauseControllerNav() {
    for c in GCController.controllers() {
      let cid = ObjectIdentifier(c)
      if let egp = c.extendedGamepad {
        if let prev = prevPauseEGPHandlers[cid] {
          egp.valueChangedHandler = prev
        } else {
          egp.valueChangedHandler = nil
        }
      }
      prevPauseEGPHandlers.removeValue(forKey: cid)
    }
    // Reset latch state so a stale held-button reading from before teardown
    // (e.g. a controller reconnect mid-press) doesn't leak into the next
    // setup cycle.
    pauseNavGate = PauseMenuInputGate()
  }
  #endif

  // Platform-specific Settings button row
  @ViewBuilder
  private var settingsButtonRow: some View {
    #if os(tvOS)
    PauseMenuRow(
      icon: "gearshape",
      title: L("Settings"),
      subtitle: L("Game & system options"),
      action: { onShowSettings() }
    )
    .focused($focused, equals: .settings)
    #else
    EmptyView()
    #endif
  }

  // tvOS: original layout preserved
  private var tvMainMenu: some View {
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

      // Netflix-style content overlay
      HStack(spacing: 80) {
        // Left side - Game cover and info
        VStack(alignment: .leading, spacing: 16) {
          Image(uiImage: game.coverImage)
            .resizable()
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(width: 180, height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)

          VStack(alignment: .leading, spacing: 6) {
            Text(game.title)
              .font(.system(size: 24, weight: .bold))
              .foregroundColor(.white)
              .lineLimit(2)

            Text(game.gameID)
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(.white.opacity(0.7))
          }
        }
        .frame(width: 180)

        // Right side - Menu options
        VStack(alignment: .leading, spacing: 24) {
          // Hero resume button
          Button(action: { TVEmulationBridge.resume()
            onClose()
          }) {
            HStack(spacing: 16) {
              Text(L("Resume Game"))
                .font(.system(size: 20, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .background(
              LinearGradient(
                colors: [Color(.dolphinTint), Color.purple],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .blue.opacity(0.5), radius: 12, x: 0, y: 6)
          }
          .buttonStyle(.plain)
          .focused($focused, equals: .resume)

          // Menu items with SettingsMenuRow styling. Wrapped in a ScrollView (rather
          // than a bare VStack) so this list scrolls instead of overflowing off the
          // bottom of the screen as more cards land here (quick actions above, WS-4's
          // continuity hand-off card, etc.) — a fixed-height HStack with no scroll
          // container is exactly how a growing menu silently goes unreachable on tvOS.
          ScrollView(showsIndicators: false) {
          VStack(spacing: 12) {
            // Save States
            Button(action: { pane = .saves }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Save States"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text("Manage game saves")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.white.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.white.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .openSaves)

            // Quick actions: same row shape as the rest of the list. Mute toggles in
            // place (mid-call mute without leaving the pause menu); Fast Forward opens
            // the speed chooser (D14) since picking a speed also starts FF and leaves
            // the menu right away, which needs its own pane rather than an in-place flip.
            tvMenuToggleRow(
              icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
              title: isMuted ? L("Unmute") : L("Mute"),
              subtitle: isMuted ? L("Restore audio volume") : L("Silence audio"),
              action: { toggleMute() }
            )
            .focused($focused, equals: .mute)

            tvMenuToggleRow(
              icon: fastForwardEnabled ? "forward.fill" : "forward",
              title: L("Fast Forward"),
              subtitle: fastForwardSubtitle,
              action: { pane = .fastForwardSpeed }
            )
            .focused($focused, equals: .fastForward)

            // Cheats
            Button(action: { pane = .cheats }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "star.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Cheats"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text(cheatsSubtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.white.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.white.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .cheats)

            // Controllers
            Button(action: { pane = .controllers }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "gamecontroller")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Controllers"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text("Input configuration")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.white.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.white.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .mapping)

            // Shaders
            Button(action: { showShaders = true }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "wand.and.stars")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Shaders"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text(L("Post-processing"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.white.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.white.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .shaders)

            // Continue Elsewhere (WS-4). Its own Button, and therefore its own
            // focus target — the surrounding VStack of Buttons is what makes
            // that work on tvOS, unlike a List row holding several controls.
            Button(action: { showContinuitySheet = true }) {
              HStack(spacing: 20) {
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Continue Elsewhere"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text(L("Hand this game to a nearby device"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.white.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.white.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .continuity)

            // Settings
            settingsButtonRow

            // Reset System
            Button(action: { showResetDialog = true }) {
              HStack(spacing: 20) {
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.orange.opacity(0.15))
                    .frame(width: 48, height: 48)

                  Image(systemName: "arrow.counterclockwise.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Reset System"))
                    .font(.system(size: 18, weight: .semibold))

                  Text(L("Restart the game from power-on"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.secondary)
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.orange.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            // Exit Game
            Button(action: { showExitDialog = true }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.red.opacity(0.15))
                    .frame(width: 48, height: 48)

                  Image(systemName: "xmark.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.red)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Exit Game"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.red)

                  Text(L("Return to library"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.red.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.red.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.red.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .exit)
          }
          }
        }
        .frame(width: 480)
      }
      .padding(60)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .zIndex(100)
      .alert(L("Reset System"), isPresented: $showResetDialog) {
        Button(L("Cancel"), role: .cancel) { showResetDialog = false }
        Button(L("Reset"), role: .destructive) {
          // Same as the console's reset button. It does not reload the auto-resume state, so it is also
          // the way out of a game that resumed into a bad save.
          TVEmulationBridge.resetSystem()
          onClose()
        }
      } message: {
        Text(L("Restart the game as if the console's reset button was pressed? Unsaved progress will be lost."))
      }
      .alert(L("Exit Game"), isPresented: $showExitDialog) {
        Button(L("Cancel"), role: .cancel) { showExitDialog = false }
        Button(L("Quit"), role: .destructive) {
          TVEmulationBridge.stop()
          NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
        }
        Button(L("Save & Quit")) {
          SaveStateService.saveSlot(selectedSlot)
          TVEmulationBridge.stop()
          NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
        }
      } message: {
        Text(L("Do you want to quit the game? Unsaved progress will be lost."))
      }
    }
    .animation(.easeInOut(duration: 0.3), value: focused)
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
            // This pushes the grid's scope onto ControllerFocusCoordinator.
            // setupPauseControllerNav() below (this file's OWN raw GCController
            // dpad handler for iOS pause-menu nav) gates on
            // ControllerFocusCoordinator.isActiveScope(pauseMenuScopeID), so
            // dpad/A input no longer drives the pause menu behind this sheet.
            NavigationStack { SaveStateFilmstripView(gameID: game.gameID) }
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
            .claimsController()
        }
      }
    }
  }
}

/// Card container used in the tvOS pause overlay
private struct TvOSCard<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title).font(.headline)
        Spacer()
      }
      content
    }
    .padding(16)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

#if DEBUG
import UIKit

private func makePreviewGame() -> TVGameItem {
  let clsName = "TVGameItem"
  if let cls = NSClassFromString(clsName) as? NSObject.Type {
    let obj = cls.init()
    let img = UIImage(systemName: "gamecontroller")?.withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage()
    obj.setValue("Preview Game", forKey: "title")
    obj.setValue("RMCP01", forKey: "gameID")
    obj.setValue(img, forKey: "coverImage")
    return unsafeBitCast(obj, to: TVGameItem.self)
  }
  fatalError("TVGameItem class not found for preview")
}

#Preview("iPhone Portrait") {
  PauseMenuView(
    selectedSlot: .constant(1),
    onClose: {},
    onShowSettings: {},
    platform: .ios,
    game: makePreviewGame()
  )
}

#Preview("iPhone Landscape") {
  PauseMenuView(
    selectedSlot: .constant(1),
    onClose: {},
    onShowSettings: {},
    platform: .ios,
    game: makePreviewGame()
  )
  .previewInterfaceOrientation(.landscapeLeft)
}
#endif

private struct DefaultFocusCompat<Value: Hashable>: ViewModifier {
  var focused: FocusState<Value?>.Binding
  let value: Value
  func body(content: Content) -> some View {
    if #available(iOS 17, tvOS 17, *) {
      content.defaultFocus(focused, value)
    } else {
      content
    }
  }
}
