import Combine
import GameController
import SwiftUI
import UIKit

#if os(iOS)
#endif

private struct EmulationSurfaceView: UIViewRepresentable {
  let gamePath: String
  func makeUIView(context: Context) -> UIView {
    let host = UIView()
    host.backgroundColor = .black
    TVEmulationBridge.registerMainDisplay(host)
    NSLog("[INPUT] tvOS Emulation: launching game after display registration")
    if TVEmulationBridge.isRunning() {
      NSLog("[INPUT] Core already running; skipping launch")
    } else {
      TVEmulationBridge.launchGame(atPath: gamePath)
    }
    return host
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class EmuContainerViewController: UIViewController {
  private weak var emuVC: EmuEventVC?
  private var exitObserver: NSObjectProtocol?
  var gamePath: String = ""
  #if os(tvOS)
  private var pauseShownObserver: NSObjectProtocol?
  private var pauseHiddenObserver: NSObjectProtocol?
  #endif

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
  }

  override func viewDidAppear(_ animated: Bool) {
    // iCube: keep the device awake while a game is on screen. Without this the phone auto-locks
    // mid-game when playing on a controller (no touches), suspends the app, and tears down the
    // perf test-bench listener. Released in deinit (exit to library); refcounted so exiting a
    // game does not re-arm auto-lock while the debug server still needs the device awake.
    KeepAwake.acquire(.emulation)
    super.viewDidAppear(animated)
    // Tear down any previous child to ensure a fresh setup each time
    if let existing = emuVC {
      existing.willMove(toParent: nil)
      existing.view.removeFromSuperview()
      existing.removeFromParent()
      emuVC = nil
    }
    if let token = exitObserver {
      NotificationCenter.default.removeObserver(token)
      exitObserver = nil
    }

    let vc = EmuEventVC()
    vc.controllerUserInteractionEnabled = false
    addChild(vc)
    vc.view.frame = view.bounds
    vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(vc.view)
    vc.didMove(toParent: self)
    emuVC = vc
    _ = vc.becomeFirstResponder()
    NSLog("[INPUT] EmuEventVC becomeFirstResponder attempted")

    let displayContainer = UIView(frame: vc.view.bounds)
    displayContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    displayContainer.backgroundColor = .black
    vc.view.addSubview(displayContainer)

    func launchCore() {
      DispatchQueue.main.async {
        TVEmulationBridge.registerMainDisplay(displayContainer)
        if TVEmulationBridge.isRunning() {
          NSLog("[INPUT] tvOS Container: core running, skipping relaunch; display registered")
        } else {
          NSLog("[INPUT] tvOS Container: launching game after registerMainDisplayView")
          TVEmulationBridge.launchGame(atPath: self.gamePath)
        }
      }
    }

    // JIT warning dialog only when JIT is genuinely actionable: the build can
    // acquire JIT (not App Store / TestFlight), it is not yet acquired, and the
    // user has the JITARM64 core selected (PowerPC::CPUCore.JITARM64 == 4). The
    // legacy 3 is accepted for backward compat with builds that wrote the old
    // (buggy) CpuEngine raw value. Any interpreter core suppresses the prompt;
    // when JIT is unavailable the core silently falls back to Cached Interpreter.
    let manager = JitManager.shared()
    manager.recheckIfJitIsAcquired()
    let currentCore = DOLConfigBridge.mainCpuCore()
    let isJitCoreSelected = (currentCore == 4 || currentCore == 3) // JITARM64 (4) + legacy 3
    // iCube: a remote boot (POST /api/debug/boot) pre-answers the prompt with "Use No JIT Mode".
    let skipPrompt = DebugServerManager.skipJITPromptOnce
    DebugServerManager.skipJITPromptOnce = false
    // iOS 26 TXM: CS_DEBUGGED alone is not enough — the region must be authorized by a
    // broker attached right now (or already authorized earlier in this process).
    let txmNeedsBroker = manager.deviceHasTxm && manager.acquiredJit
      && !manager.txmAuthorized && !manager.debuggerAttached
    if manager.jitSupported, !manager.acquiredJit || txmNeedsBroker, isJitCoreSelected, !skipPrompt {
      let message = txmNeedsBroker
        ? "This device uses TXM, so JIT needs StikDebug attached when a game boots. You can continue with a slower, no-JIT mode."
        : "iCube may need a remote debugger to enable JIT. You can continue with a slower, no-JIT mode."
      SentryTelemetryService.recordJitStep(
        "waiting-for-JIT prompt",
        data: [
          "txm_needs_broker": txmNeedsBroker,
          "acquired": manager.acquiredJit,
          "debugger_attached": manager.debuggerAttached,
          "handshake_blocked": manager.txmHandshakeBlocked,
        ])
      let alert = UIAlertController(title: "Waiting for JIT", message: message, preferredStyle: .alert)
      #if os(iOS)
      // iOS 26 TXM devices: offer a one-tap hand-off to StikDebug. iCube ships its own broker
      // script (icube.js) and passes it inline via the stikdebug:// URL scheme, so the user need
      // not pre-assign a script. StikDebug attaches, authorizes the JIT region, then relaunches
      // iCube — so returning to the library lets the fresh launch boot with JIT.
      if manager.jitSupported, manager.deviceHasTxm, StikDebugLauncher.isStikDebugInstalled {
        alert.addAction(UIAlertAction(title: "Enable JIT via StikDebug", style: .default, handler: { _ in
          StikDebugLauncher.enableJIT()
          NotificationCenter.default.post(name: Notification.Name("DOLEmulationDidEndNotification"), object: nil)
        }))
      }
      #endif
      alert.addAction(UIAlertAction(title: "Help", style: .default, handler: { _ in
        if let url = URL(string: "https://dolphinios.oatmealdome.me/jit-help") {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
      }))
      alert.addAction(UIAlertAction(title: "Use No JIT Mode (Slow)", style: .default, handler: { _ in
        // Continue; core fallback to Cached Interpreter is enforced per-run in EmulationCoordinator when JIT is unavailable
        launchCore()
      }))
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationDidEndNotification"), object: nil)
      }))
      present(alert, animated: true, completion: nil)
    } else {
      launchCore()
    }

    exitObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil, queue: .main) { [weak self] _ in
      self?.handleExit()
    }
    #if os(tvOS)
    // Toggle GC controller interception based on pause overlay visibility
    pauseShownObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLPauseOverlayShown"), object: nil, queue: .main) { [weak self] _ in
      guard let self = self, let evc = self.emuVC else { return }
      // Allow SwiftUI PauseMenu to receive controller navigation
      evc.controllerUserInteractionEnabled = true
      if UserDefaults.standard.bool(forKey: "input_debug") {
        NSLog("[INPUT] EmuContainer toggled GC interaction OFF for PauseMenu")
      }
    }
    pauseHiddenObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLPauseOverlayHidden"), object: nil, queue: .main) { [weak self] _ in
      guard let self = self, let evc = self.emuVC else { return }
      // Restore gameplay interception setting
      evc.controllerUserInteractionEnabled = false
      if UserDefaults.standard.bool(forKey: "input_debug") {
        NSLog("[INPUT] EmuContainer restored GC interaction to %d after PauseMenu", evc.controllerUserInteractionEnabled)
      }
    }
    #endif
  }

  private func handleExit() {
    NotificationCenter.default.post(name: Notification.Name("DOLEmulationDidEndNotification"), object: nil)
  }

  deinit {
    KeepAwake.release(.emulation)
    if let token = exitObserver {
      NotificationCenter.default.removeObserver(token)
    }
    #if os(tvOS)
    if let t = pauseShownObserver { NotificationCenter.default.removeObserver(t) }
    if let t = pauseHiddenObserver { NotificationCenter.default.removeObserver(t) }
    #endif
  }
}

private struct EmulationSurfaceController: UIViewControllerRepresentable {
  let gamePath: String
  func makeUIViewController(context: Context) -> EmuContainerViewController {
    let vc = EmuContainerViewController()
    vc.gamePath = resolveCachedPathIfAvailable(gamePath)
    return vc
  }

  func updateUIViewController(_ uiViewController: EmuContainerViewController, context: Context) {}
}

@MainActor
private func resolveCachedPathIfAvailable(_ path: String) -> String {
  guard let url = URL(string: path), let scheme = url.scheme?.lowercased(), ["http", "https", "webdav", "webdavs"].contains(scheme) else {
    return path
  }
  func defaultPort(_ scheme: String?) -> Int { (scheme?.lowercased() == "https" || scheme?.lowercased() == "webdavs") ? 443 : 80 }
  guard let host = url.host?.lowercased() else { return path }
  let port = url.port ?? defaultPort(url.scheme)
  let remoteItem = RemoteLibraryItem(url: url, displayName: url.lastPathComponent, sizeBytes: nil, etag: nil, lastModified: nil)
  for src in RemoteSourcesStore.shared.sources {
    guard let webdav = src as? WebDAVSource else { continue }
    let base = webdav.baseURL
    let baseHost = base.host?.lowercased() ?? ""
    let basePort = base.port ?? defaultPort(base.scheme)
    if baseHost == host && basePort == port {
      if let info = webdav.getCacheInfo(for: remoteItem) {
        return webdav.getCacheDirectory().appendingPathComponent(info.localPath).path
      }
    }
  }
  return path
}

private struct EmulationProgrammaticHost: UIViewControllerRepresentable {
  let gamePath: String

  func makeUIViewController(context: Context) -> UIViewController {
    if AppConsts.useSwiftUI {
      return UIViewController()
    } else {
      TVEmulationBridge.launchGame(atPath: gamePath)
      let sb = UIStoryboard(name: "Emulation", bundle: .main)
      return sb.instantiateInitialViewController()!
    }
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct EmulationScreen: View {
  let game: TVGameItem
  @Environment(\.dismiss) private var dismiss
  @State private var endObserver: NSObjectProtocol?
  @State private var resumeObserver: NSObjectProtocol?
  #if os(tvOS)
  @State private var exitObserver: NSObjectProtocol?
  @State private var tvPauseObserver: NSObjectProtocol?
  // Defect #10: these two used to be registered anonymously in onAppear and never
  // removed, so re-entering a game N times left N copies of each handler running.
  @State private var obsDidEnterBackground: NSObjectProtocol?
  @State private var obsWillEnterForeground: NSObjectProtocol?
  #endif

  // Pause menu state
  @State private var showPauseMenu = false
  @State private var selectedSlot = 1
  @State private var showSettings = false
  @AppStorage("ui_show_dsu_debug_hud") private var showDSUDebugHUD: Bool = {
    #if DEBUG
    return true
    #else
    return false
    #endif
  }()

  @State private var obsShowPause: NSObjectProtocol?

  // iOS top overlay
  #if os(iOS)

  @State var isTouchControlsActive = false
  @State var userOverrideTouchControls = false

  /// Show/auto-hide state of the top bar; see `TopBarVisibility`.
  @State var topBar = TopBarVisibility()
  /// The bar's measured height; the toast sits just under it.
  @State private var topBarHeight: CGFloat = 0
  /// True when opening controller settings is what paused the game, so closing them may resume it. A pause
  /// the user made from the bar stays.
  @State private var controllerSettingsOwnsPause = false
  var showTopBar: Bool { topBar.isVisible }
  @State private var fastForwardEnabled = false
  // iOS observer tokens to avoid leaks. Defect #10: these three used to be
  // registered anonymously in onAppear (DOLMotionSettingsChanged,
  // ControllerManager.assignmentsChanged, DOLWiiOverlayLayoutChangedNotification)
  // and never removed, so a settings change restarted CoreMotion once per
  // onAppear that had ever fired for this screen instance.
  @State private var obsMotionSettingsChanged: NSObjectProtocol?
  @State private var obsAssignmentsChanged: NSObjectProtocol?
  @State private var obsWiiOverlayLayoutChanged: NSObjectProtocol?
  @State private var showExitConfirm = false
  @State private var showShaderSheet = false
  @State private var showShaderParams = false
  @State private var showFXSheet = false
  @State private var showControllerSettings = false
  // AR stabilization
  @State var stableAR: CGFloat?
  @State var arPollTask: Task<Void, Never>?
  // Touch pad refresh coordination to avoid system detection races
  @State private var touchPadsRefreshToken = UUID()
  @State private var irModeRaw: Int = 1
  @State private var desiredTouchControls: Bool = true
  @State private var wiiOverlaySignature: Int = 0
  #endif
  // Used by both the iOS and tvOS bodies (Phase 3/4 disconnect-pause + pill),
  // so it must live outside the iOS-only block above.
  @ObservedObject private var controllerManager = ControllerManager.shared
  @State private var elapsedSeconds: Int = 0
  @State private var timer: Timer?
  // Drives the centered "Paused" HUD pill. Polled off the 1s timer and refreshed
  // on showPauseMenu changes; the pill is gated isPaused && !showPauseMenu.
  @State private var isPaused: Bool = false
  @State var isWiiSystem: Bool = false

  // Quick performance overlay
  @State private var showPerfOverlay: Bool = false
  @State private var ocEnabled: Bool = false
  @State private var ocPercent: Int = 100
  @State private var vbiEnabledQuick: Bool = false
  @State private var vbiPercentQuick: Int = 100
  @State private var showFPSQuick: Bool = false
  @State private var showVPSQuick: Bool = false
  @State private var showSpeedQuick: Bool = false
  @State private var showVBlankQuick: Bool = false
  @State private var efbScaleQuick: Int = 1
  @State private var efbMaxScaleQuick: Int = 6
  @State private var anisotropyQuick: Int = 1
  @State private var adaptiveClockQuick: Bool = false
  @State private var viSkipModeQuick: Int = 2 // TriState: 0=Off, 1=On, 2=Auto
  @State private var showGraphsQuick: Bool = false
  @State private var overlayStatsQuick: Bool = false
  @State private var stateCopied: Bool = false
  // Resolver step #3 badge: set while an auto controller (adaptive clock / Auto-IR / thermal, on
  // CurrentRun) or the running game's INI outranks the user's own Base value of the key. Loaded
  // alongside the other perf state at overlay-open; the manual control is disabled and an "Auto" /
  // "Game" badge shown while set, so the control can't author a silently-shadowed Base value.
  @State private var ocOverride: DOLConfigOverride = .none
  @State private var vbiOverride: DOLConfigOverride = .none
  @State private var efbOverride: DOLConfigOverride = .none
  @AppStorage("gfx_overscan_fullscreen") private var overscanFullscreen = false
  @State private var overscanApplicable = false

  #if os(iOS)
  @State private var showSkyMenu = false
  @State private var showSkyImporter = false
  @State private var skyPickedURL: URL? = nil
  @State private var showSkyClearPicker = false
  @State private var skyLastLoadedSlot: Int = 0
  /// The on-screen controls are being edited: `TouchOverlayLayoutEditorView` covers the game.
  @State private var isEditingLayout = false
  /// The pad being edited: the one on screen when editing began.
  @State private var layoutEditPadKind: TouchOverlayPadKind = .gameCube

  private static let topRevealStripHeight: CGFloat = 80

  /// The on-screen controller, built in one place so the game picture is placed for the same pad the player sees.
  private var touchPadsContainer: TouchPadsContainer {
    let isWiiToShow: Bool = {
      switch controllerManager.overlayMode {
      case .auto: return isWiiSystem
      case .gamecube: return false
      case .wii: return true
      }
    }()
    return TouchPadsContainer(forceVisible: true, isWii: isWiiToShow, irMode: irModeRaw)
  }

  /// The skin's Menu, Quick Save and Quick Load items: the same things the top bar does.
  private func handleSkinAction(_ action: SkinAction) {
    switch action {
    case .menu: showPauseMenu = true
    case .quickSave: QuickSlot.save(slot: selectedSlot)
    case .quickLoad: QuickSlot.load(slot: selectedSlot)
    case .control: break
    }
  }

  /// The skin's game screen area on `canvas` (the full screen, safe areas included, exactly as `SkinOverlayView`
  /// lays the skin out), when a skin is replacing the on-screen controller.
  private func skinGameArea(canvas: CGSize) -> CGRect? {
    let orientation = TouchOverlayOrientation(isPortrait: canvas.height >= canvas.width)
    // Runs on every body pass; with no skin picked anywhere, skip the pad-kind lookup (controller scan) entirely.
    guard isTouchControlsActive, SkinLibrary.shared.hasSelection(orientation: orientation) else { return nil }
    guard let skin = touchPadsContainer.activeSkin(orientation: orientation) else { return nil }
    return SkinMount.gamePictureFrame(for: skin, canvas: canvas)
  }

  /// Where the active skin puts the game picture, in `proxy`'s coordinates. `nil` keeps the default placement.
  private func skinGamePictureFrame(in proxy: GeometryProxy, gameAR: CGFloat) -> CGRect? {
    let insets = proxy.safeAreaInsets
    let canvas = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                        height: proxy.size.height + insets.top + insets.bottom)
    guard let area = skinGameArea(canvas: canvas) else { return nil }
    return SkinMount.aspectFit(aspect: gameAR, in: area.offsetBy(dx: -insets.leading, dy: -insets.top))
  }

  /// The strip along the top that reveals the hidden top bar. It sits above the on-screen controller, so with a
  /// skin it only spans the game picture's width: a skin keeps its L / R triggers in the top corners.
  private func topRevealStrip(canvas: CGSize) -> CGRect {
    let screen = CGRect(origin: .zero, size: canvas)
    var span = screen
    if let area = skinGameArea(canvas: canvas), !area.intersection(screen).isNull { span = area.intersection(screen) }
    return CGRect(x: span.minX, y: 0, width: span.width, height: Self.topRevealStripHeight)
  }
  #endif

  var body: some View {
    #if os(tvOS)
    ZStack {
      EmulationSurfaceController(gamePath: game.filePath)
        .ignoresSafeArea()
        .focusable(!showPauseMenu)
        .allowsHitTesting(!showPauseMenu)
        .navigationBarBackButtonHidden(true)

      // Centered "Paused" HUD pill (tap pill or x resumes). Hidden when the full
      // pause menu is open; the disconnect banner (zIndex 5) sits above it.
      if isPaused && !showPauseMenu && controllerManager.disconnectPause == nil {
        PausedPill(onResume: {
          TVEmulationBridge.resume()
          isPaused = false
        })
        .zIndex(3)
      }

      // Banner shown while a disconnect-induced pause is active (reconnect resumes).
      // No "Use Touch Controls" action on tvOS — there is no touchscreen overlay.
      if controllerManager.disconnectPause != nil {
        ControllerDisconnectBanner()
          .zIndex(5)
      }

      // Removed floating speed overlay toggle; moved into pause menu

      // Semi-transparent overlay with controls
      if showPerfOverlay {
        Color.black.opacity(0.35).ignoresSafeArea().zIndex(4)
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Text("Performance Controls").font(.title3).foregroundColor(.white)
            Spacer()
            Button { showPerfOverlay = false } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.white) }
              .buttonStyle(.plain)
          }
          Divider().background(.white.opacity(0.2))

          // CPU Clock
          HStack {
            Toggle("CPU Clock Override", isOn: Binding(get: { ocEnabled }, set: { v in
              ocEnabled = v
              DOLConfigBridge.setMainOverclockEnable(v)
              // Re-apply the current percent on enable: with MAIN_OVERCLOCK at 100% the factor is
              // unchanged until the stepper moves, so the toggle alone appeared to do nothing.
              if v { DOLConfigBridge.setMainOverclockPercent(ocPercent) }
            }))
            .tint(.blue)
            .foregroundColor(.white)
            // Resolver step #3: while the adaptive clock drives this key (CurrentRun), the manual
            // control is disabled; it shows the user's Base %.
            .disabled(ocOverride != .none)
            autoBadge(ocOverride)
          }
          HStack {
            Text("\(ocPercent)%").foregroundColor(.white.opacity(0.8))
            Spacer()
            TVIntStepperOverlay(value: $ocPercent.onSet { DOLConfigBridge.setMainOverclockPercent($0) }, range: 1 ... 400, step: 1)
              .disabled(!ocEnabled || ocOverride != .none)
          }

          // VBI
          HStack {
            Toggle("VBI Frequency Override", isOn: Binding(get: { vbiEnabledQuick }, set: { v in
              vbiEnabledQuick = v
              DOLConfigBridge.setMainViOverclockEnable(v)
              if v { DOLConfigBridge.setMainViOverclockPercent(vbiPercentQuick) }
            }))
            .tint(.blue)
            .foregroundColor(.white)
            .disabled(vbiOverride != .none)
            autoBadge(vbiOverride)
          }
          HStack {
            Text("\(vbiPercentQuick)%").foregroundColor(.white.opacity(0.8))
            Spacer()
            TVIntStepperOverlay(value: $vbiPercentQuick.onSet { DOLConfigBridge.setMainViOverclockPercent($0) }, range: 1 ... 400, step: 1)
              .disabled(!vbiEnabledQuick || vbiOverride != .none)
          }

          // Adaptive clock (auto) + VI-skip mode
          adaptiveControls()

          Divider().background(.white.opacity(0.2))

          // Overlays + diagnostics, as a scannable icon grid.
          overlayToggleGrid()

          // Graphics quick controls
          HStack {
            Text("Internal Resolution: \(efbScaleQuick == 0 ? "Auto" : "\(efbScaleQuick)x")").foregroundColor(.white.opacity(0.8))
            autoBadge(efbOverride)
            Spacer()
            TVIntStepperOverlay(value: efbScaleQuickBinding, range: 0 ... efbMaxScaleQuick, step: 1)
              // Resolver step #3: while Auto-IR / thermal drives GFX_EFB_SCALE (CurrentRun), the
              // manual stepper is disabled; it shows the user's Base scale.
              .disabled(efbOverride != .none)
          }
          HStack {
            Text("Anisotropic: \(anisotropyQuick)x").foregroundColor(.white.opacity(0.8))
            Spacer()
            TVIntStepperOverlay(value: $anisotropyQuick.onSet { DOLConfigBridge.setGfxEnhanceAnisotropySamples($0) }, range: 1 ... 16, step: 1)
          }
          if overscanApplicable {
            Toggle(L("Full Screen Display"), isOn: overscanFullscreenBinding)
              .tint(.blue)
              .foregroundColor(.white)
          }
        }
        .padding(20)
        .frame(maxWidth: 520)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
        .zIndex(5)
      }
    }
    // Was `.sheet(isPresented:)` over a bespoke `isPauseMenuStyle` surface (now deleted
    // from SettingsRootView.swift) whose content was clamped to a fixed ~740pt-wide
    // two-column layout on a 1920pt-wide tvOS screen, with the List's default (light)
    // background never hidden on tvOS — together the small floating panel, the
    // overlapping title/description text, and the blank white controls box. Switching
    // to `.fullScreenCover` with the plain `TVSettingsPage()` reuses the same
    // full-screen, readable presentation the library's own Settings entry already uses
    // on tvOS (TVLibraryView.swift `.fullScreenCover(isPresented: $showSettings)`),
    // including its Menu-button exit, which the deleted surface had via `.onExitCommand`
    // — added explicitly here since this cover doesn't sit inside a NavigationStack.
    .fullScreenCover(isPresented: $showSettings) {
      TVSettingsPage()
        .interactiveDismissDisabled(true)
        .onExitCommand { showSettings = false }
    }
    .fullScreenCover(isPresented: $showPauseMenu) {
      ZStack {
        PauseMenuView(
          selectedSlot: $selectedSlot,
          onClose: { showPauseMenu = false },
          onShowSettings: { showSettings = true },
          platform: .tvos,
          game: game
        )
        // Speed overlay toggle inside pause menu
        VStack {
          HStack {
            Spacer()
            Button {
              refreshPerfOverlayState()
              showPerfOverlay = true
            } label: {
              Image(systemName: "speedometer")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .padding(12)
                .background(.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable(true)
            .padding([.top, .trailing], 24)
          }
          Spacer()
        }
      }
    }
    .onAppear {
      NSLog("[INPUT] tvOS EmulationScreen onAppear. input_debug=%d", UserDefaults.standard.bool(forKey: "input_debug"))
      let initialCount = GCController.controllers().count
      NSLog("[INPUT] tvOS initial controllers count: %d", initialCount)
      GCController.shouldMonitorBackgroundEvents = true
      // One install entry point (see ControllerManager.refreshInputHandlers).
      // Re-run here because installExtraInputHandlers reads the touchpad IR mode
      // at install time and that setting can change between games.
      ControllerManager.shared.refreshInputHandlers()
      logCurrentControllers()

      // Handle pause menu events
      obsShowPause = NotificationCenter.default.addObserver(forName: Notification.Name("DOLShowPauseMenu"), object: nil, queue: .main) { _ in
        showPauseMenu = true
      }

      if initialCount == 0 {
        NSLog("[INPUT] tvOS starting wireless controller discovery")
        GCController.startWirelessControllerDiscovery(completionHandler: {
          NSLog("[INPUT] tvOS wireless controller discovery completed")
        })
      }
      // Controller connect/disconnect is handled by the app-wide ControllerManager
      // observer (started in MainDisplaySceneDelegate). Its connect path runs
      // configureControllerForCurrentPlatform (installs input + pause-gesture
      // handlers) and auto-assigns, so the previous redundant local observer here
      // (with an empty disconnect handler) has been removed.
      endObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidEndNotification"), object: nil, queue: .main) { _ in
        dismiss()
      }
      // Keep the token and register once: this observer used to be added anonymously on every
      // appearance and never removed, so launch N ran N copies of the handler. The first copy
      // consumed the one-shot "Start Fresh" skip flag and the next copy loaded the auto-state
      // anyway (and a normal launch issued N auto-resume loads). The resume/boot-into-state
      // decision itself now lives in a single app-lifetime observer
      // (`SaveStateService.installDidStartObserver()`) instead of here — a per-view observer
      // can still overlap with the next screen's during a navigation transition (the outgoing
      // screen's `onDisappear` hasn't removed it yet while the incoming one's `onAppear` already
      // registered), and two observers firing for one boot reproduces the exact bug this guard
      // was added to fix. What's left here (controller/profile setup) is idempotent, so a
      // transient overlap of those doesn't matter the same way.
      if resumeObserver == nil {
        resumeObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main) { _ in
          ControllerManager.shared.registerGCOverride(forController: 0)
          ControllerManager.shared.refreshInputHandlers()
          GameProfiles.shared.applyRuntimeOverrides(for: game)
        }
      }
      // Auto-pause when app goes to background on tvOS
      obsDidEnterBackground = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
        NSLog("[INPUT] tvOS app backgrounded - showing pause menu")
        showPauseMenu = true
      }
      obsWillEnterForeground = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
        NSLog("[INPUT] tvOS app foregrounded - keeping pause menu visible")
        // Keep pause menu visible when returning to foreground so user can choose to resume
      }
      // Load current OC/VBI state
      ocEnabled = DOLConfigBridge.mainOverclockEnableBase()
      ocPercent = DOLConfigBridge.mainOverclockPercentBase()
      vbiEnabledQuick = DOLConfigBridge.mainViOverclockEnableBase()
      vbiPercentQuick = DOLConfigBridge.mainViOverclockPercentBase()
      // Resolver step #3: does an auto controller or the running game outrank these keys?
      ocOverride = DOLConfigBridge.overclockOverride()
      vbiOverride = DOLConfigBridge.viOverclockOverride()
      efbOverride = DOLConfigBridge.efbScaleOverride()
      // Overlay toggles and quick graphics
      showFPSQuick = DOLConfigBridge.gfxShowFPS()
      showVPSQuick = DOLConfigBridge.gfxShowVPS()
      showSpeedQuick = DOLConfigBridge.gfxShowSpeed()
      showVBlankQuick = DOLConfigBridge.gfxShowVTimes()
      efbMaxScaleQuick = max(1, DOLConfigBridge.gfxEfbMaxScale())
      efbScaleQuick = DOLConfigBridge.gfxEfbScaleBase()
      anisotropyQuick = DOLConfigBridge.gfxEnhanceAnisotropySamples()
      // Adaptive clock (NSUserDefault), VI-skip mode, perf graph
      adaptiveClockQuick = UserDefaults.standard.bool(forKey: "adaptive_clock_enable")
      viSkipModeQuick = DOLConfigBridge.gfxHackViSkipMode()
      showGraphsQuick = DOLConfigBridge.gfxShowGraphs()
      overlayStatsQuick = DOLConfigBridge.gfxOverlayStats()
      refreshOverscanApplicable()
      if overscanApplicable {
        TVEmulationBridge.setOverscanFullscreenEnabled(overscanFullscreen)
      }
      // Live Activity start
      #if canImport(ActivityKit)
      GameActivityManager.start(gameId: game.gameID, title: game.title, subtitle: game.makerLong, isPaused: TVEmulationBridge.isPaused())
      #endif
      // Start elapsed timer
      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        elapsedSeconds += 1
        isPaused = TVEmulationBridge.isPaused()
        // If the game resumed via any path other than a controller reconnect
        // (pill tap, pause menu Resume, new game), clear a stale disconnect banner.
        if controllerManager.disconnectPause != nil && !TVEmulationBridge.isPaused() {
          controllerManager.clearDisconnectPause()
        }
        #if canImport(ActivityKit)
        GameActivityManager.update(isPaused: TVEmulationBridge.isPaused(), elapsedSeconds: elapsedSeconds)
        #endif
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLExternalDisplayDidChangeNotification"))) { _ in
      refreshOverscanApplicable()
    }
    .onDisappear {
      if let token = endObserver { NotificationCenter.default.removeObserver(token)
        endObserver = nil
      }
      if let token = resumeObserver { NotificationCenter.default.removeObserver(token)
        resumeObserver = nil
      }
      if let token = obsShowPause { NotificationCenter.default.removeObserver(token)
        obsShowPause = nil
      }
      #if os(tvOS)
      if let token = exitObserver { NotificationCenter.default.removeObserver(token)
        exitObserver = nil
      }
      if let token = tvPauseObserver { NotificationCenter.default.removeObserver(token)
        tvPauseObserver = nil
      }
      if let token = obsDidEnterBackground { NotificationCenter.default.removeObserver(token)
        obsDidEnterBackground = nil
      }
      if let token = obsWillEnterForeground { NotificationCenter.default.removeObserver(token)
        obsWillEnterForeground = nil
      }
      #endif
      ControllerManager.shared.unregisterGCOverride(forController: 0)
      for c in GCController.controllers() {
        c.extendedGamepad?.valueChangedHandler = nil
        c.gamepad?.valueChangedHandler = nil
        c.microGamepad?.valueChangedHandler = nil
        // Menu/Options handlers stay installed (never nil — a nil handler hands
        // the button back to tvOS/iOS). They self-gate on emulation running.
        installPauseMenuHandlers(c)
      }
      // Shoulder / shake / touchpad-IR caches are module-level and used to
      // survive into the next game.
      resetAllControllerInputState()
      #if !os(tvOS)
      arPollTask?.cancel()
      arPollTask = nil
      #endif
      // Live Activity end
      #if canImport(ActivityKit)
      GameActivityManager.end()
      #endif
      timer?.invalidate()
      timer = nil
      elapsedSeconds = 0
      // Reset inferred system to avoid carryover to the next game
      isWiiSystem = false
    }
    .onChange(of: showPauseMenu) { visible in
      NotificationCenter.default.post(name: Notification.Name(visible ? "DOLPauseOverlayShown" : "DOLPauseOverlayHidden"), object: nil)
      isPaused = TVEmulationBridge.isPaused()
      #if canImport(ActivityKit)
      GameActivityManager.update(isPaused: visible, elapsedSeconds: elapsedSeconds)
      #endif
    }
    .onExitCommand { if showPauseMenu { TVEmulationBridge.resume()
      showPauseMenu = false
    } }
    .onPlayPauseCommand {}
    .navigationBarBackButtonHidden(true)
    #else // os(iOS)
    ZStack {
      Color.black.ignoresSafeArea()
      GeometryReader { proxy in
        let isPortrait = proxy.size.height > proxy.size.width
        let gameAR = stableAR ?? (proxy.size.width / max(proxy.size.height, 1))
        if let skinFrame = skinGamePictureFrame(in: proxy, gameAR: gameAR) {
          EmulationSurfaceController(gamePath: game.filePath)
            .frame(width: skinFrame.width, height: skinFrame.height)
            .position(x: skinFrame.midX, y: skinFrame.midY)
        } else if isPortrait {
          VStack(spacing: 0) {
            let topInset = proxy.safeAreaInsets.top
            if topInset > 0 {
              Color.clear.frame(height: topInset)
            }
            let availableHeight = proxy.size.height - topInset
            let desiredHeight = min(availableHeight * 0.66, proxy.size.width / max(gameAR, 0.0001))
            EmulationSurfaceController(gamePath: game.filePath)
              .frame(width: proxy.size.width, height: desiredHeight)
              .onTapGesture { toggleTopBar() }
            Spacer()
          }
        } else {
          let targetHeight = min(proxy.size.height, proxy.size.width / max(gameAR, 0.0001))
          VStack(spacing: 0) {
            Spacer()
            EmulationSurfaceController(gamePath: game.filePath)
              .frame(width: proxy.size.width, height: targetHeight)
              .onTapGesture { toggleTopBar() }
            Spacer()
          }
        }
      }
      .onChange(of: UIDevice.current.orientation) { _ in
        TVEmulationBridge.resizeSurfaceNow()
        scheduleARPoll()
      }
      .onAppear {
        // Per-game profile overrides on boot. Resume-where-left-off / boot-into-state
        // used to be decided here too, but that decision now lives in a single
        // app-lifetime observer (`SaveStateService.installDidStartObserver()`): this
        // per-view observer can overlap with the next screen's during a navigation
        // transition (the outgoing screen's `onDisappear` hasn't fired yet while the
        // incoming one's `onAppear` already registered), and two observers both
        // calling into the one-shot "Start Fresh" flag let the second one load the
        // auto-state right after the first correctly skipped it. Register once
        // (guarded) regardless, since this still only wants to run once per screen.
        guard resumeObserver == nil else { return }
        resumeObserver = NotificationCenter.default.addObserver(
          forName: Notification.Name("DOLEmulationDidStartNotification"),
          object: nil, queue: .main) { _ in
          GameProfiles.shared.applyRuntimeOverrides(for: game)
        }
      }

      // Centered "Paused" HUD pill (tap pill or x resumes). Hidden when the full
      // pause menu is open; the disconnect banner (zIndex 5) sits above it.
      if isPaused && !showPauseMenu && controllerManager.disconnectPause == nil {
        PausedPill(onResume: {
          TVEmulationBridge.resume()
          isPaused = false
        })
        .zIndex(3)
      }

      // Banner shown while a disconnect-induced pause is active (reconnect resumes).
      if controllerManager.disconnectPause != nil {
        ControllerDisconnectBanner(
          onUseTouchControls: { controllerManager.useTouchControlsForDisconnectedSlot() }
        )
        .zIndex(5)
      }

      // Top hit area: tap near status bar to reveal overlay (active only when hidden). Gone while the
      // layout editor is up: it would swallow the touches that start in the top 80 pt.
      if !showTopBar && !isEditingLayout {
        GeometryReader { screen in
          let strip = topRevealStrip(canvas: screen.size)
          Color.clear
            .frame(width: strip.width, height: strip.height)
            .contentShape(Rectangle())
            .onTapGesture { toggleTopBar() }
            .position(x: strip.midX, y: strip.midY)
        }
        .ignoresSafeArea()
        .zIndex(1)
        .allowsHitTesting(true)
      }

      if showDSUDebugHUD {
        DSUDebugHUD()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(.top, 96)
          .zIndex(1000)
          .allowsHitTesting(true)
      }

      if showTopBar && !isEditingLayout {
        emulationTopBar
          .onPreferenceChange(TopBarHeightKey.self) { topBarHeight = $0 }
          .transition(.move(edge: .top).combined(with: .opacity))
          .zIndex(2)
      }

      // In-game toast ("Saved to Slot 3", ...): the library's snackbar renders underneath this screen.
      EmulationToastOverlay(barHeight: topBarHeight, barVisible: showTopBar)
        .zIndex(6)

      // Semi-transparent overlay with quick performance controls (iOS)
      if showPerfOverlay {
        Color.black.opacity(0.35).ignoresSafeArea().zIndex(4)
        GeometryReader { geometry in
          let isLandscape = geometry.size.width > geometry.size.height
          ScrollView {
            if isLandscape {
              // Two-column layout for landscape
              VStack(alignment: .leading, spacing: 12) {
                HStack {
                  Text("Performance Controls").font(.headline).foregroundColor(.white)
                  Spacer()
                  Button { showPerfOverlay = false } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.white).font(.title3) }
                    .buttonStyle(.plain)
                }
                Divider().background(.white.opacity(0.2))

                HStack(alignment: .top, spacing: 20) {
                  // Left column
                  VStack(alignment: .leading, spacing: 12) {
                    HStack {
                      Toggle("CPU Clock Override", isOn: Binding(get: { ocEnabled }, set: { v in
                        ocEnabled = v
                        DOLConfigBridge.setMainOverclockEnable(v)
                        // Re-apply current percent on enable (100% leaves the factor unchanged otherwise).
                        if v { DOLConfigBridge.setMainOverclockPercent(ocPercent) }
                      }))
                      .tint(.blue)
                      .foregroundColor(.white)
                      .disabled(ocOverride != .none)
                      autoBadge(ocOverride)
                    }
                    HStack {
                      Slider(value: $ocPercent.onSet { DOLConfigBridge.setMainOverclockPercent($0) }.asDouble, in: 1 ... 400)
                        .disabled(!ocEnabled || ocOverride != .none)
                      Text("\(ocPercent)%").foregroundColor(.white.opacity(0.8)).frame(width: 52, alignment: .trailing)
                    }

                    HStack {
                      Toggle("VBI Frequency Override", isOn: Binding(get: { vbiEnabledQuick }, set: { v in
                        vbiEnabledQuick = v
                        DOLConfigBridge.setMainViOverclockEnable(v)
                        if v { DOLConfigBridge.setMainViOverclockPercent(vbiPercentQuick) }
                      }))
                      .tint(.blue)
                      .foregroundColor(.white)
                      .disabled(vbiOverride != .none)
                      autoBadge(vbiOverride)
                    }
                    HStack {
                      Slider(value: $vbiPercentQuick.onSet { DOLConfigBridge.setMainViOverclockPercent($0) }.asDouble, in: 1 ... 400)
                        .disabled(!vbiEnabledQuick || vbiOverride != .none)
                      Text("\(vbiPercentQuick)%").foregroundColor(.white.opacity(0.8)).frame(width: 52, alignment: .trailing)
                    }

                    // Graphics controls
                    HStack {
                      Text(L("Internal Resolution"))
                        .foregroundColor(.white.opacity(0.8))
                        .font(.caption)
                      autoBadge(efbOverride)
                      Spacer()
                      Slider(value: efbScaleQuickBinding.asDouble, in: 0 ... Double(max(1, efbMaxScaleQuick)), step: 1)
                        .disabled(efbOverride != .none)
                      Text(efbScaleQuick == 0 ? "Auto" : "\(efbScaleQuick)x").foregroundColor(.white.opacity(0.8)).frame(width: 50, alignment: .trailing)
                    }
                    HStack {
                      Text(L("Anisotropic Filtering"))
                        .foregroundColor(.white.opacity(0.8))
                        .font(.caption)
                      Spacer()
                      Slider(value: $anisotropyQuick.onSet { DOLConfigBridge.setGfxEnhanceAnisotropySamples($0) }.asDouble, in: 1 ... 16, step: 1)
                      Text("\(anisotropyQuick)x").foregroundColor(.white.opacity(0.8)).frame(width: 50, alignment: .trailing)
                    }
                    if overscanApplicable {
                      Toggle(L("Full Screen Display"), isOn: overscanFullscreenBinding)
                        .tint(.blue)
                        .foregroundColor(.white)
                    }

                    // Adaptive clock (auto) + VI-skip mode
                    adaptiveControls()
                  }
                  .frame(maxWidth: .infinity)

                  // Right column - Overlay toggles + diagnostics grid
                  VStack(alignment: .leading, spacing: 12) {
                    Text("Display Overlays").font(.subheadline).foregroundColor(.white.opacity(0.8))
                    overlayToggleGrid()
                  }
                  .frame(maxWidth: .infinity)
                }
              }
            } else {
              // Single column layout for portrait
              VStack(alignment: .leading, spacing: 16) {
                HStack {
                  Text("Performance Controls").font(.headline).foregroundColor(.white)
                  Spacer()
                  Button { showPerfOverlay = false } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.white).font(.title3) }
                    .buttonStyle(.plain)
                }
                Divider().background(.white.opacity(0.2))
                HStack {
                  Toggle("CPU Clock Override", isOn: Binding(get: { ocEnabled }, set: { v in
                    ocEnabled = v
                    DOLConfigBridge.setMainOverclockEnable(v)
                    // Re-apply current percent on enable (100% leaves the factor unchanged otherwise).
                    if v { DOLConfigBridge.setMainOverclockPercent(ocPercent) }
                  }))
                  .tint(.blue)
                  .foregroundColor(.white)
                  .disabled(ocOverride != .none)
                  autoBadge(ocOverride)
                }
                HStack {
                  Slider(value: $ocPercent.onSet { DOLConfigBridge.setMainOverclockPercent($0) }.asDouble, in: 1 ... 400)
                    .disabled(!ocEnabled || ocOverride != .none)
                  Text("\(ocPercent)%").foregroundColor(.white.opacity(0.8)).frame(width: 52, alignment: .trailing)
                }
                HStack {
                  Toggle("VBI Frequency Override", isOn: Binding(get: { vbiEnabledQuick }, set: { v in
                    vbiEnabledQuick = v
                    DOLConfigBridge.setMainViOverclockEnable(v)
                    if v { DOLConfigBridge.setMainViOverclockPercent(vbiPercentQuick) }
                  }))
                  .tint(.blue)
                  .foregroundColor(.white)
                  .disabled(vbiOverride != .none)
                  autoBadge(vbiOverride)
                }
                HStack {
                  Slider(value: $vbiPercentQuick.onSet { DOLConfigBridge.setMainViOverclockPercent($0) }.asDouble, in: 1 ... 400)
                    .disabled(!vbiEnabledQuick || vbiOverride != .none)
                  Text("\(vbiPercentQuick)%").foregroundColor(.white.opacity(0.8)).frame(width: 52, alignment: .trailing)
                }

                // Adaptive clock (auto) + VI-skip mode
                adaptiveControls()

                Divider().background(.white.opacity(0.2))
                // Overlays + diagnostics, as a scannable icon grid.
                overlayToggleGrid()

                // Quick graphics controls
                HStack {
                  Text(L("Internal Resolution"))
                    .foregroundColor(.white.opacity(0.8))
                  autoBadge(efbOverride)
                  Spacer()
                  Slider(value: efbScaleQuickBinding.asDouble, in: 0 ... Double(max(1, efbMaxScaleQuick)), step: 1)
                    .disabled(efbOverride != .none)
                  Text(efbScaleQuick == 0 ? "Auto" : "\(efbScaleQuick)x").foregroundColor(.white.opacity(0.8)).frame(width: 60, alignment: .trailing)
                }
                HStack {
                  Text(L("Anisotropic Filtering"))
                    .foregroundColor(.white.opacity(0.8))
                  Spacer()
                  Slider(value: $anisotropyQuick.onSet { DOLConfigBridge.setGfxEnhanceAnisotropySamples($0) }.asDouble, in: 1 ... 16, step: 1)
                  Text("\(anisotropyQuick)x").foregroundColor(.white.opacity(0.8)).frame(width: 60, alignment: .trailing)
                }
                if overscanApplicable {
                  Toggle(L("Full Screen Display"), isOn: overscanFullscreenBinding)
                    .tint(.blue)
                    .foregroundColor(.white)
                }
              }
            }
          }
          .padding(20)
          .frame(maxWidth: isLandscape ? min(geometry.size.width * 0.9, 720) : 420)
          .frame(maxHeight: isLandscape ? min(geometry.size.height * 0.8, 400) : .infinity)
          .background(.black.opacity(0.6))
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
          .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .zIndex(5)
      }

      // Legacy touch pads
      if isTouchControlsActive {
        touchPadsContainer
          .id(touchPadsRefreshToken)
          .ignoresSafeArea()
          // Hidden, not removed, while the editor draws the same layout above it.
          .opacity(isEditingLayout ? 0 : 1)
          .allowsHitTesting(!isEditingLayout)
          .transition(.opacity)
          .onAppear {
            // Ensure touch input is always a valid IR source
            TCDeviceMotion.shared.setMotionEnabled(true)
            syncMotionPortToTouchscreen()
            TCDeviceMotion.shared.statusBarOrientationChanged()
          }
      }

      // Edit Layout…: the editor lays out on the same canvas as the pads above (the whole screen), so
      // nothing moves when play resumes, and sits above the top bar and its reveal strip.
      if isEditingLayout {
        TouchOverlayLayoutEditorView(padKind: layoutEditPadKind, overGame: true, onDone: endLayoutEdit)
          .zIndex(7)
      }
    }
    // Single owner of the core's IMU pointer on the touchscreen Wii Remote: always OFF, whether the
    // overlay is shown or hidden. The app drives that slot's IR itself (touch in drag/follow,
    // device attitude in gyro mode) and keeps feeding the phone's motion into its IMU axes, so
    // turning the core pointer ON while the overlay was hidden aimed the remote at the ceiling as
    // soon as the phone was held upright: the hand vanished and never came back (there is no
    // working Recenter on the touchscreen device). Only a slot bound to a physical motion
    // controller owns the core pointer, and its profile sets it; this never touches that slot.
    // This used to be toggled from four places (pad onAppear/onDisappear, TCWiiPad.setTouchIRMode,
    // the long-press handler, and setup).
    .onChange(of: isTouchControlsActive) { _ in
      // No touchscreen Wii Remote: the overlay drives no pointer, so there is nothing to keep from
      // fighting. `?? 0` used to flip Wii Remote 1's IMU pointer here even when a gyro pad owns it
      // (controller hub decision 12).
      guard isWiiSystem, let touchSlot = controllerManager.touchscreenSlot(system: .wii) else { return }
      TVEmulationBridge.setWiiIMUPointEnabled(false, forWiimote: touchSlot)
    }
    .modifier(SettingsNavigationFallback(showSettings: $showSettings))
    .fullScreenCover(isPresented: $showPauseMenu) {
      PauseMenuView(
        selectedSlot: $selectedSlot,
        onClose: { showPauseMenu = false },
        onShowSettings: { showSettings = true },
        platform: .ios,
        game: game
      )
    }
    .fileImporter(isPresented: $showSkyImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
      if case .success(let urls) = result {
        for url in urls {
          let started = url.startAccessingSecurityScopedResource()
          defer { if started { url.stopAccessingSecurityScopedResource() } }
          let slot = DOLConfigBridge.skylanderLoad(fromPath: url.path)
          if slot > 0 { skyLastLoadedSlot = slot }
        }
      }
    }
    .confirmationDialog("Clear Skylander Slot", isPresented: $showSkyClearPicker, titleVisibility: .visible) {
      ForEach(1 ... 16, id: \.self) { slot in
        Button("Slot \(slot)") { _ = DOLConfigBridge.skylanderRemove(atSlot: slot) }
      }
      if skyLastLoadedSlot > 0 {
        Button("Clear Last Loaded (Slot \(skyLastLoadedSlot))", role: .destructive) {
          _ = DOLConfigBridge.skylanderRemove(atSlot: skyLastLoadedSlot)
        }
      }
      Button(L("Cancel"), role: .cancel) {}
    }
    .onAppear {
      NSLog("[INPUT] iOS EmulationScreen onAppear. input_debug=%d", UserDefaults.standard.bool(forKey: "input_debug"))
      NSLog("[INPUT] iOS initial controllers count: %d", GCController.controllers().count)
      // Controller observation is started app-wide from MainDisplaySceneDelegate
      // (scene root) so hotplug auto-assign works in library/menus/in-game on both
      // iOS and tvOS. Do not start/stop it here.
      // Initialize expected system early from metadata to avoid startup races
      isWiiSystem = inferIsWii(from: game)
      irModeRaw = DOLConfigBridge.mainTouchPadIRMode()
      let useIMU = (irModeRaw == 0)
      let wantsMotionForShake = MotionSettings.enhancedShakeDetection() && isWiiSystem
      // The core's IMU pointer stays OFF while the on-screen pads own the pointer: the app
      // synthesizes IR itself (touch in drag/follow, device attitude in gyro mode) and shake
      // detection only needs the accelerometer. Enabling it here for gyro mode or shake made
      // the core fold the phone's real tilt into the IR transform on top of the app's pointer,
      // which is the "touch pointer stopped working" report. The `isTouchControlsActive` onChange
      // above (declared before this block) is the runtime owner of this flag afterwards.
      // Target whichever Wii Remote the overlay is actually bound to, and none when no Wii Remote is
      // on the Touchscreen: `?? 0` used to switch a gyro pad's IMU pointer off on Wii Remote 1 at
      // every Wii boot (controller hub decision 12).
      if let imuTouchSlot = controllerManager.touchscreenSlot(system: .wii) {
        TVEmulationBridge.setWiiIMUPointEnabled(false, forWiimote: imuTouchSlot)
      }
      let wantsMotion = (isTouchControlsActive && useIMU) || wantsMotionForShake
      TCDeviceMotion.shared.setMotionEnabled(wantsMotion)
      if wantsMotion {
        syncMotionPortToTouchscreen()
        TCDeviceMotion.shared.statusBarOrientationChanged()
      }

      // Enable enhanced motion controls for touchscreen by default (Wii games)
      if isWiiSystem {
        setupEnhancedMotionControls()
      }

      // Listen for motion settings changes during gameplay
      obsMotionSettingsChanged = NotificationCenter.default.addObserver(forName: Notification.Name("DOLMotionSettingsChanged"), object: nil, queue: .main) { _ in
        restartMotionSystemForSettingsChange()
        // Ensure motion stays on for shake even if touch overlay is hidden but an external controller is connected
        let wantsMotionForShake2 = MotionSettings.enhancedShakeDetection() && isWiiSystem
        if wantsMotionForShake2 {
          Task { @MainActor in
            TCDeviceMotion.shared.setMotionEnabled(true)
            syncMotionPortToTouchscreen()
            TCDeviceMotion.shared.statusBarOrientationChanged()
          }
        }
      }
      // Ensure touch controls start visible
      isTouchControlsActive = controllerManager.overlayVisible
      desiredTouchControls = true
      controllerManager.setSystem(isWii: isWiiSystem)
      // Reconcile port ownership. The touchscreen fallback (ControllerManager.prepareForBoot)
      // runs once, pre-boot, from the coordinator; running it here too would re-decide AFTER
      // the engine and overwrite what reconcile() had just bound.
      ControllerManager.shared.reconcile()
      // Configure Wiimote sources based on connected controllers
      ControllerManager.shared.updateWiimoteEmulationForExternalControllers()
      // reconcile() may have moved the touchscreen to another slot; follow it.
      syncMotionPortToTouchscreen()
      #if os(iOS)
      ReplayKitManager.shared.startBufferingIfEnabled()
      // A skin whose files vanished is forgotten here, not while the screen draws (that would publish mid-update).
      SkinMount.forgetDeadSelections(in: .shared)
      if UserDefaults.standard.bool(forKey: "thermal_auto_enable") { ThermalManager.shared.start() }
      #endif
      // On iOS, do not hand controller button presses to the system while in-game
      GCController.shouldMonitorBackgroundEvents = false

      logCurrentControllers()
      fastForwardEnabled = TVEmulationBridge.isFastForwardEnabled()
      ControllerManager.shared.refreshInputHandlers()
      #if os(iOS)
      SiriShortcutManager.shared.donatePlay(game: game)
      #endif
      // Controller connect/disconnect handled by ControllerManager
      // NotificationCenter bridging for assignments remains
      obsAssignmentsChanged = NotificationCenter.default.addObserver(forName: ControllerManager.assignmentsChanged, object: nil, queue: .main) { _ in
        if !userOverrideTouchControls {
          let visible = controllerManager.touchscreenSlot(system: isWiiSystem ? .wii : .gamecube) != nil
          controllerManager.overlayVisible = visible
          isTouchControlsActive = visible
        }
        touchPadsRefreshToken = UUID()
      }
      obsWiiOverlayLayoutChanged = NotificationCenter.default.addObserver(forName: Notification.Name("DOLWiiOverlayLayoutChangedNotification"), object: nil, queue: .main) { _ in
        touchPadsRefreshToken = UUID()
      }
      endObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidEndNotification"), object: nil, queue: .main) { _ in
        dismiss()
      }
      obsShowPause = NotificationCenter.default.addObserver(forName: Notification.Name("DOLShowPauseMenu"), object: nil, queue: .main) { _ in
        showPauseMenu = true
      }
      // Re-fetch AR soon after appear to avoid tiny first layout
      scheduleARPoll()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { TVEmulationBridge.resizeSurfaceNow() }
      // Re-infer system shortly after appear in case metadata was incomplete
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        isWiiSystem = inferIsWii(from: game)
        touchPadsRefreshToken = UUID()
      }
      // Apply saved CoreAudio DSP defaults if CoreAudio backend is selected
      if DOLConfigBridge.audioBackend() == "CoreAudio" {
        applyCoreAudioDSPDefaults()
      }
      // Load current OC/VBI state
      ocEnabled = DOLConfigBridge.mainOverclockEnableBase()
      ocPercent = DOLConfigBridge.mainOverclockPercentBase()
      vbiEnabledQuick = DOLConfigBridge.mainViOverclockEnableBase()
      vbiPercentQuick = DOLConfigBridge.mainViOverclockPercentBase()
      // Resolver step #3: does an auto controller or the running game outrank these keys?
      ocOverride = DOLConfigBridge.overclockOverride()
      vbiOverride = DOLConfigBridge.viOverclockOverride()
      efbOverride = DOLConfigBridge.efbScaleOverride()
      // Overlay toggles and quick graphics
      showFPSQuick = DOLConfigBridge.gfxShowFPS()
      showVPSQuick = DOLConfigBridge.gfxShowVPS()
      showSpeedQuick = DOLConfigBridge.gfxShowSpeed()
      showVBlankQuick = DOLConfigBridge.gfxShowVTimes()
      efbMaxScaleQuick = max(1, DOLConfigBridge.gfxEfbMaxScale())
      efbScaleQuick = DOLConfigBridge.gfxEfbScaleBase()
      anisotropyQuick = DOLConfigBridge.gfxEnhanceAnisotropySamples()
      // Adaptive clock (NSUserDefault), VI-skip mode, perf graph
      adaptiveClockQuick = UserDefaults.standard.bool(forKey: "adaptive_clock_enable")
      viSkipModeQuick = DOLConfigBridge.gfxHackViSkipMode()
      showGraphsQuick = DOLConfigBridge.gfxShowGraphs()
      overlayStatsQuick = DOLConfigBridge.gfxOverlayStats()
      refreshOverscanApplicable()
      if overscanApplicable {
        TVEmulationBridge.setOverscanFullscreenEnabled(overscanFullscreen)
      }
      // (Removed) "IR mode 0 means unset -> force Follow": mode 0 is the user's Gyro choice
      // (PointerMode.gyro) and the engine default is 2 (iOSSettings.cpp), so this bounced every
      // Gyro selection back to Follow on each appearance.
      // Initialize overlay signature for Wii type (extension + sideways)
      let touchSlot = controllerManager.touchscreenSlot(system: .wii) ?? 0
      let ext0 = Int(DOLWiimoteBridge.selectedExtension(forWiimote: touchSlot))
      let side0 = DOLWiimoteBridge.isSideways(forWiimote: touchSlot)
      wiiOverlaySignature = (ext0 & 0xFF) | (side0 ? 0x100 : 0)
      // Default touch controls: shown while some active slot of the running system is bound to the
      // on-screen Touchscreen (only if not user-overridden). "Hidden whenever any controller is
      // connected" made an explicit Touchscreen assignment with a pad attached look dead.
      if !userOverrideTouchControls {
        let visible = controllerManager.touchscreenSlot(system: isWiiSystem ? .wii : .gamecube) != nil
        controllerManager.overlayVisible = visible
        isTouchControlsActive = visible
      }
      // ControllerManager publishes connect/disconnect; adjust default overlay there via reconcile if needed
      // Show the bar on appear; it hides itself once idle (see TopBarVisibility)
      topBar.show(now: Date())
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLExternalDisplayDidChangeNotification"))) { _ in
      refreshOverscanApplicable()
    }
    .onDisappear {
      if let token = endObserver { NotificationCenter.default.removeObserver(token)
        endObserver = nil
      }
      // Without this the resume observer outlived the screen and stacked up one per launch —
      // the same double-handler bug as the tvOS branch (see the start observer there).
      if let token = resumeObserver { NotificationCenter.default.removeObserver(token)
        resumeObserver = nil
      }
      if let t = obsShowPause { NotificationCenter.default.removeObserver(t)
        obsShowPause = nil
      }
      if let t = obsMotionSettingsChanged { NotificationCenter.default.removeObserver(t)
        obsMotionSettingsChanged = nil
      }
      if let t = obsAssignmentsChanged { NotificationCenter.default.removeObserver(t)
        obsAssignmentsChanged = nil
      }
      if let t = obsWiiOverlayLayoutChanged { NotificationCenter.default.removeObserver(t)
        obsWiiOverlayLayoutChanged = nil
      }
      // Do not stopObserving() here — the controller observer is app-wide (started
      // in MainDisplaySceneDelegate) so auto-assign stays live after exiting a game.
      // Disable motion when leaving screen
      TCDeviceMotion.shared.setMotionEnabled(false)
      resetAllControllerInputState()
      arPollTask?.cancel()
      arPollTask = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      // Ask the renderer to resize/reconfigure
      TVEmulationBridge.resizeSurfaceNow()
      // The gyro pointer reads its axes from the interface orientation and re-centres when it
      // changes, but the orientation was only refreshed by explicit calls (overlay shown, motion
      // restarted), so the re-centre fired at random. Read it on the next main-actor turn, once
      // UIKit has applied the rotation; this also covers the 180-degree landscape flip, which the
      // overlay host's portrait/landscape layout callback does not see.
      Task { @MainActor in TCDeviceMotion.shared.statusBarOrientationChanged() }
    }
    .onReceive(NotificationCenter.default.publisher(for: SkinLibrary.didChangeNotification)) { _ in
      // A skin was picked, imported or deleted (possibly the one on screen): rebuild the pads and the game placement.
      touchPadsRefreshToken = UUID()
    }
    .onReceive(NotificationCenter.default.publisher(for: SkinActionNotification.name)) { note in
      if let action = SkinActionNotification.action(in: note) { handleSkinAction(action) }
    }
    .onReceive(controllerManager.controllerConnectedPublisher) { _ in
      touchPadsRefreshToken = UUID()
      ControllerStyleManager.shared.refreshDetection()
    }
    .onReceive(controllerManager.controllerDisconnectedPublisher) { _ in
      touchPadsRefreshToken = UUID()
      ControllerStyleManager.shared.refreshDetection()
    }
    .onReceive(controllerManager.fastForwardToggledPublisher) { enabled in
      fastForwardEnabled = enabled
    }
    .onReceive(controllerManager.$overlayMode) { _ in
      // Choosing Wii binds Wii Remote 1 to the touchscreen in `overlayMode`'s didSet.
      touchPadsRefreshToken = UUID()
    }
    .onChange(of: isWiiSystem) { controllerManager.setSystem(isWii: $0) }
    .onReceive(controllerManager.$overlayVisible) { v in
      isTouchControlsActive = v
      touchPadsRefreshToken = UUID()
    }
    .onReceive(NotificationCenter.default.publisher(for: .DOLPointerModeDidChange)) { _ in
      irModeRaw = PointerModeController.shared.mode.rawValue
    }
    // The hub chose on-screen visibility or style: treat it as the top bar's own buttons do, so the
    // assignmentsChanged observer stops re-deriving visibility. Posted before the change is applied.
    .onReceive(NotificationCenter.default.publisher(for: .DOLOnScreenControlsChosen)) { _ in
      userOverrideTouchControls = true
      touchPadsRefreshToken = UUID()
    }
    .onReceive(NotificationCenter.default.publisher(for: .DOLEditTouchLayout)) { _ in beginLayoutEdit() }
    // iOS has no 1s timer (the tvOS branch does); poll paused-state for the HUD pill.
    .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
      isPaused = TVEmulationBridge.isPaused()
      if !isPaused { PauseOwnership.pausedFromBar = false }
      // Clear a stale disconnect banner if the game resumed via any other path.
      if controllerManager.disconnectPause != nil && !TVEmulationBridge.isPaused() {
        controllerManager.clearDisconnectPause()
      }
    }
    .onChange(of: showPauseMenu) { visible in
      isPaused = TVEmulationBridge.isPaused()
      // The fullScreenCover transition perturbs the GeometryReader size and the Metal
      // surface never resizes itself (updateUIViewController is empty), so without this
      // the game could come back small, bottom-left, or half off screen until the next
      // rotation.
      if !visible { TVEmulationBridge.resizeSurfaceNow() }
    }
    // The library stack pushes this screen; hide its bar (iOS 26 renders leftover
    // toolbar items as floating glass buttons that also swallow the top-edge tap).
    .toolbar(.hidden, for: .navigationBar)
    .navigationBarBackButtonHidden(true)
    .statusBar(hidden: true)
    .animation(TopBarStyle.transition, value: showTopBar)
    .modifier(TopBarChildPresentationHold(visibility: $topBar, isPresented: topBarChildPresented))
    .sheet(isPresented: $showShaderSheet) {
      NavigationStack {
        ShaderSettingsView()
          .navigationTitle(L("Shaders"))
      }
    }
    .sheet(isPresented: $showShaderParams) {
      NavigationStack {
        ShaderParameterEditor()
          .navigationTitle(L("Shader Parameters"))
      }
    }
    .sheet(isPresented: $showFXSheet) {
      NavigationStack {
        Group {
          if DOLConfigBridge.audioBackend() == "AVAudioEngine" || AudioFXBridge.isEngineActive() {
            FXChainEditor()
              .navigationTitle(L("Audio Effects"))
          } else {
            CoreAudioDSPEditor()
              .navigationTitle(L("Audio Effects"))
          }
        }
      }
    }
    .sheet(isPresented: $showControllerSettings, onDismiss: controllerSettingsDismissed) {
      NavigationStack {
        ControllerHubView(system: .forRunningGame, onBack: { showControllerSettings = false })
          .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { showControllerSettings = false } }
          }
      }
      .claimsController()
    }
    .alert("Exit Game?", isPresented: $showExitConfirm) {
      Button("Save & Quit") {
        SaveStateService.saveSlot(selectedSlot)
        TVEmulationBridge.stop()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        GameActivityManager.end()
        #endif
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      }
      Button("Quit", role: .destructive) {
        TVEmulationBridge.stop()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        GameActivityManager.end()
        #endif
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      }
      Button("Continue", role: .cancel) {
        TVEmulationBridge.resume()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        GameActivityManager.update(isPaused: false, elapsedSeconds: elapsedSeconds)
        #endif
        withAnimation(TopBarStyle.transition) { topBar.hideNow() }
      }
    } message: {
      Text("Do you want to stop the current game and return to the library?")
    }
    // Claim controller ownership for as long as the game is on screen. The
    // library is only *covered*, not dismissed, so SwiftUI never sends it an
    // onDisappear and its raw nav handlers would otherwise keep moving the grid
    // (and could launch another game) underneath the running one.
    .claimsController()
    #endif
  }

  // Adaptive-clock (auto) live toggle + VI-skip mode picker, shared across all perf-overlay layouts.
  // Resolver step #3: refresh the perf-overlay state from the live config whenever the overlay is
  // opened. The auto controllers (adaptive clock / Auto-IR / thermal) only write CurrentRun once
  // gameplay is underway — AFTER the one-time onAppear load — so re-reading here is what makes the
  // "Auto" badge appear and the manual controls disable when the user opens the overlay mid-game.

  #if os(iOS)
  private var emulationTopBar: some View {
    EmulationTopBar(
      visibility: $topBar,
      selectedSlot: $selectedSlot,
      isPaused: $isPaused,
      fastForwardEnabled: $fastForwardEnabled,
      isWii: isWiiSystem,
      onScreenControlsVisible: controllerManager.overlayVisible,
      irModeRaw: irModeRaw,
      pointerIsThisGameOnly: PointerModeController.shared.isThisGameOnly,
      overscanApplicable: overscanApplicable,
      overscanFullscreen: overscanFullscreen,
      childPresented: topBarChildPresented,
      open: openFromTopBar,
      onToggleOnScreenControls: toggleOnScreenControls,
      onSetPointerMode: { mode in
        isTouchControlsActive = true
        userOverrideTouchControls = true
        PointerModeController.shared.set(mode)
      },
      onSetOverscanFullscreen: { applyOverscanFullscreenToggle($0) },
      readPlayer1Devices: player1DeviceOptions,
      onChoosePlayer1: { qualifier in
        // The on-screen controls follow the choice (the assignmentsChanged observer).
        userOverrideTouchControls = false
        controllerManager.choosePlayer1(qualifier, isWii: isWiiSystem)
      })
  }

  /// The top bar's Player 1 section: the on-screen controls and every connected pad, the current one checked.
  private func player1DeviceOptions() -> [TopBarDeviceOption] {
    let reader = LiveControllerHubReader()
    let bound = isWiiSystem ? reader.boundQualifier(forWiimote: 1) : reader.boundQualifier(forGCPort: 1)
    let touchscreen = TopBarDeviceOption(
      qualifier: nil, name: L("On-Screen Controls"), isSelected: AssignmentEngine.isVirtual(bound))
    return [touchscreen] + reader.connectedPads().filter { !$0.qualifier.isEmpty }.map { pad in
      TopBarDeviceOption(qualifier: pad.qualifier, name: pad.name, isSelected: pad.qualifier == bound)
    }
  }

  /// True while anything the bar opened (or the pause menu) is on screen; the bar must not hide under it.
  private var topBarChildPresented: Bool {
    showPerfOverlay || showShaderSheet || showShaderParams || showFXSheet || showControllerSettings
      || showPauseMenu || showExitConfirm || showSkyImporter || showSkyClearPicker
  }

  private func openFromTopBar(_ destination: TopBarDestination) {
    switch destination {
    case .exitConfirm: showExitConfirm = true
    case .perfOverlay:
      refreshPerfOverlayState()
      showPerfOverlay = true
    case .audioEffects: showFXSheet = true
    case .shaders: showShaderSheet = true
    case .shaderParameters: showShaderParams = true
    case .controllerSettings:
      controllerSettingsOwnsPause = PauseOwnership.claim(isPaused: TVEmulationBridge.isPaused(), pause: TVEmulationBridge.pause)
      showControllerSettings = true
    case .pauseMenu: showPauseMenu = true
    case .editLayout: beginLayoutEdit()
    case .skylanderImport: showSkyImporter = true
    case .skylanderClear: showSkyClearPicker = true
    }
  }

  /// The settings sheet paused the game on open (unless it was already paused); resume only what it paused,
  /// and refresh the pause icon without waiting for the 1 s poll.
  private func controllerSettingsDismissed() {
    PauseOwnership.release(owned: controllerSettingsOwnsPause, resume: TVEmulationBridge.resume)
    controllerSettingsOwnsPause = false
    isPaused = TVEmulationBridge.isPaused()
  }

  private func toggleOnScreenControls() {
    userOverrideTouchControls = true
    controllerManager.overlayVisible.toggle()
    isTouchControlsActive = controllerManager.overlayVisible
    touchPadsRefreshToken = UUID()
  }

  /// Edit Layout… (the top bar, the Controllers hub wherever it is open, or a long-press on the
  /// overlay): closes whatever covers the game and edits the pad on screen, on the canvas it is played
  /// on. Edit mode owns the screen: the top bar and its reveal strip stay hidden until Done.
  private func beginLayoutEdit() {
    let pads = touchPadsContainer
    layoutEditPadKind = pads.programmaticPadKind() ?? (pads.isWii ? .wiiRemote : .gameCube)
    showControllerSettings = false
    showPauseMenu = false
    showSettings = false
    topBar.hideNow()
    isEditingLayout = true
  }

  /// Done. The menus closed for editing resume only a pause they made, and a pause menu closed with one
  /// of its own sheets still up does not, so resume here unless the player paused from the bar or a
  /// controller disconnected.
  private func endLayoutEdit() {
    isEditingLayout = false
    if TVEmulationBridge.isRunning(), TVEmulationBridge.isPaused(), !PauseOwnership.pausedFromBar,
       controllerManager.disconnectPause == nil {
      TVEmulationBridge.resume()
    }
    isPaused = TVEmulationBridge.isPaused()
  }
  #endif

  /// The quick IR control: writes Base only when the player moves it, and turns Auto-IR off for an
  /// explicit scale, since both drive GFX_EFB_SCALE (same rule as the Settings picker, step #6).
  private var efbScaleQuickBinding: Binding<Int> {
    $efbScaleQuick.onSet { newScale in
      DOLConfigBridge.setGfxEfbScale(newScale)
      if newScale != 0 { DOLConfigBridge.setGfxAutoIREnable(false) }
    }
  }

  /// Seeds the quick controls from the user's own values (Base). The adaptive clock and Auto-IR write
  /// CurrentRun; seeding from the resolved value let those reach Base through the controls' writers.
  private func refreshPerfOverlayState() {
    ocEnabled = DOLConfigBridge.mainOverclockEnableBase()
    ocPercent = DOLConfigBridge.mainOverclockPercentBase()
    vbiEnabledQuick = DOLConfigBridge.mainViOverclockEnableBase()
    vbiPercentQuick = DOLConfigBridge.mainViOverclockPercentBase()
    ocOverride = DOLConfigBridge.overclockOverride()
    vbiOverride = DOLConfigBridge.viOverclockOverride()
    efbOverride = DOLConfigBridge.efbScaleOverride()
    efbMaxScaleQuick = max(1, DOLConfigBridge.gfxEfbMaxScale())
    efbScaleQuick = DOLConfigBridge.gfxEfbScaleBase()
    anisotropyQuick = DOLConfigBridge.gfxEnhanceAnisotropySamples()
  }

  // Resolver step #3: small "Auto" / "Game" pill shown next to a perf control whose key is currently
  // driven by an auto controller (CurrentRun) or by the running game's INI, either of which outranks
  // the user's manual Base value. When shown, the corresponding manual control is also disabled: it
  // shows and edits the user's Base value, which applies again once the override clears.
  @ViewBuilder
  private func autoBadge(_ override: DOLConfigOverride) -> some View {
    if override != .none {
      Text(override == .game ? L("Game") : L("Auto"))
        .font(.caption2).bold()
        .foregroundColor(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.blue.opacity(0.85))
        .clipShape(Capsule())
    }
  }

  @ViewBuilder
  private func adaptiveControls() -> some View {
    Toggle("Adaptive Clock (Auto)", isOn: Binding(get: { adaptiveClockQuick }, set: { v in
      adaptiveClockQuick = v
      // Live: writes the adaptive_clock_enable default AND starts/stops the controller now.
      EmulationCoordinator.shared().setAdaptiveClockEnabled(v)
      // Live-lock the manual CPU + VI controls: Adaptive Clock owns BOTH levers when on. The actual
      // CurrentRun override write/clear happens async on the emu thread, so reflect the badge/disabled
      // state immediately, then reconcile the effective values once that write lands. (Fixes: toggling
      // Auto didn't lock/unlock the sliders, and a stale manual VI bled through because the UI never
      // re-read the override layer on toggle.)
      ocOverride = v ? .auto : .none
      vbiOverride = v ? .auto : .none
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshPerfOverlayState() }
    }))
    .tint(.blue)
    .foregroundColor(.white)
    HStack {
      Text("VI-Skip Mode").foregroundColor(.white.opacity(0.8))
      Spacer()
      Picker("VI-Skip Mode", selection: Binding(get: { viSkipModeQuick }, set: { v in
        viSkipModeQuick = v
        DOLConfigBridge.setGfxHackViSkipMode(v) // TriState: 0=Off, 1=On, 2=Auto
      })) {
        Text("Off").tag(0)
        Text("On").tag(1)
        Text("Auto").tag(2)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 220)
    }
  }

  // MARK: - HUD overlay/diagnostics toggle grid
  //
  // Replaces the stacked pile of overlay toggles (FPS/VPS/Speed/VBlank + perf graph
  // + overlay stats) with a scannable icon-over-label grid. Pure layout reorg —
  // every cell drives the same bindings/bridge calls the old stacked toggles used.

  // One square HUD cell: SF Symbol on top, short label under it; tap toggles `isOn`.
  @ViewBuilder
  private func hudToggleCell(_ label: String, systemImage: String, isOn: Binding<Bool>) -> some View {
    Button {
      isOn.wrappedValue.toggle()
    } label: {
      VStack(spacing: 4) {
        Image(systemName: systemImage)
          .font(.system(size: 20))
          .frame(height: 24)
        Text(label)
          .font(.caption2)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
      .foregroundColor(isOn.wrappedValue ? .white : .white.opacity(0.55))
      .background((isOn.wrappedValue ? Color.blue.opacity(0.45) : Color.white.opacity(0.08)))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  // The full overlay/diagnostics toggle grid, shared across all perf-overlay layouts.
  private var overscanFullscreenBinding: Binding<Bool> {
    Binding(
      get: { overscanFullscreen },
      set: { applyOverscanFullscreenToggle($0) }
    )
  }

  private func refreshOverscanApplicable() {
    overscanApplicable = TVEmulationBridge.isOverscanCompensationApplicable()
  }

  private func applyOverscanFullscreenToggle(_ enabled: Bool) {
    overscanFullscreen = enabled
    TVEmulationBridge.setOverscanFullscreenEnabled(enabled)
    TVEmulationBridge.resizeSurfaceNow()
  }

  @ViewBuilder
  private func overlayToggleGrid() -> some View {
    let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]
    LazyVGrid(columns: columns, spacing: 8) {
      hudToggleCell("FPS", systemImage: "speedometer",
                    isOn: Binding(get: { showFPSQuick }, set: { v in showFPSQuick = v; DOLConfigBridge.setGfxShowFPS(v) }))
      hudToggleCell("VPS", systemImage: "gauge.with.dots.needle.67percent",
                    isOn: Binding(get: { showVPSQuick }, set: { v in showVPSQuick = v; DOLConfigBridge.setGfxShowVPS(v) }))
      hudToggleCell("Speed", systemImage: "hare",
                    isOn: Binding(get: { showSpeedQuick }, set: { v in showSpeedQuick = v; DOLConfigBridge.setGfxShowSpeed(v) }))
      hudToggleCell("VBlank", systemImage: "clock",
                    isOn: Binding(get: { showVBlankQuick }, set: { v in showVBlankQuick = v; DOLConfigBridge.setGfxShowVTimes(v) }))
      hudToggleCell("Perf Graph", systemImage: "chart.xyaxis.line",
                    isOn: Binding(get: { showGraphsQuick }, set: { v in showGraphsQuick = v; DOLConfigBridge.setGfxShowGraphs(v) }))
      // Dolphin's deep engine HUD (GFX_OVERLAY_STATS / g_ActiveConfig.bOverlayStats).
      hudToggleCell("Overlay Stats", systemImage: "list.bullet.rectangle",
                    isOn: Binding(get: { overlayStatsQuick }, set: { v in overlayStatsQuick = v; DOLConfigBridge.setGfxOverlayStats(v) }))
    }
    // Copy State stays a one-shot action button under the grid.
    Button {
      EmulationCoordinator.copyStateToClipboard()
      stateCopied = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { stateCopied = false }
    } label: {
      HStack {
        Image(systemName: stateCopied ? "checkmark.circle.fill" : "doc.on.clipboard")
        Text(stateCopied ? "Copied" : "Copy State")
      }
      .foregroundColor(.white)
    }
    .buttonStyle(.plain)
  }

  private func logCurrentControllers() {
    guard UserDefaults.standard.bool(forKey: "input_debug") else { return }
    let controllers = GCController.controllers()
    NSLog("[INPUT] Currently connected controllers: %d", controllers.count)
    for (idx, c) in controllers.enumerated() {
      NSLog("[INPUT] #%d vendor=%@ category=%@ extended=%d micro=%d", idx, c.vendorName ?? "(nil)", c.productCategory, c.extendedGamepad != nil, c.microGamepad != nil)
    }
  }
}

private struct SettingsNavigationFallback: ViewModifier {
  @Binding var showSettings: Bool
  func body(content: Content) -> some View {
    Group {
      content
        .navigationDestination(isPresented: $showSettings) {
          SettingsRootView()
          #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
          #endif
        }
    }
  }
}
