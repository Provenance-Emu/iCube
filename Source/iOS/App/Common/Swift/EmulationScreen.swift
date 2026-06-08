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
    let currentCore = DOLConfigBridge.mainCpuCore()
    let isJitCoreSelected = (currentCore == 4 || currentCore == 3) // JITARM64 (4) + legacy 3
    if manager.jitSupported, !manager.acquiredJit, isJitCoreSelected {
      let alert = UIAlertController(title: "Waiting for JIT", message: "iCube may need a remote debugger to enable JIT. You can continue with a slower, no-JIT mode.", preferredStyle: .alert)
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
  @State private var showMotionDebug = false
  @State private var tvPauseObserver: NSObjectProtocol?
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

  @State var showTopBar = false
  @State private var fastForwardEnabled = false
  @State var hideBarWorkItem: DispatchWorkItem?
  // iOS observer tokens to avoid leaks
  @State private var obsGCConnect: NSObjectProtocol?
  @State private var obsGCDisconnect: NSObjectProtocol?
  @State private var showExitConfirm = false
  @State private var showShaderSheet = false
  @State private var showShaderParams = false
  @State private var showFXSheet = false
  @State private var showMotionDebug = false
  // Auto-hide coordination
  @State var hasTopBarInteraction: Bool = false
  @State var autoHideScheduled: Bool = false
  @State var autoHideToken = UUID()
  // AR stabilization
  @State var stableAR: CGFloat?
  @State var arPollTask: Task<Void, Never>?
  // Touch pad refresh coordination to avoid system detection races
  @State private var touchPadsRefreshToken = UUID()
  @State private var irModeRaw: Int = 1
  @State private var desiredTouchControls: Bool = true
  @StateObject var touchVM = TouchControlsViewModel()
  @State private var wiiOverlaySignature: Int = 0
  @ObservedObject private var controllerManager = ControllerManager.shared
  #endif
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
  // Resolver step #3 "Auto" badge: true when an auto controller (adaptive clock / Auto-IR / thermal)
  // is currently overriding the key on the CurrentRun layer, shadowing the user's manual Base value.
  // Loaded alongside the other perf state at overlay-open; the manual control is disabled and an
  // "Auto" badge shown while true, so the slider can't author a silently-shadowed Base value.
  @State private var ocAutoOverridden: Bool = false
  @State private var vbiAutoOverridden: Bool = false
  @State private var efbAutoOverridden: Bool = false

  #if os(iOS)
  @State private var showSkyMenu = false
  @State private var showSkyImporter = false
  @State private var skyPickedURL: URL? = nil
  @State private var showSkyClearPicker = false
  @State private var skyLastLoadedSlot: Int = 0
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
            // control is disabled and the displayed % is the live effective value.
            .disabled(ocAutoOverridden)
            autoBadge(ocAutoOverridden)
          }
          HStack {
            Text("\(ocPercent)%").foregroundColor(.white.opacity(0.8))
            Spacer()
            TVIntStepperOverlay(value: $ocPercent, range: 1 ... 400, step: 1)
              .disabled(!ocEnabled || ocAutoOverridden)
              .onChange(of: ocPercent) { DOLConfigBridge.setMainOverclockPercent($0) }
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
            .disabled(vbiAutoOverridden)
            autoBadge(vbiAutoOverridden)
          }
          HStack {
            Text("\(vbiPercentQuick)%").foregroundColor(.white.opacity(0.8))
            Spacer()
            TVIntStepperOverlay(value: $vbiPercentQuick, range: 1 ... 400, step: 1)
              .disabled(!vbiEnabledQuick || vbiAutoOverridden)
              .onChange(of: vbiPercentQuick) { DOLConfigBridge.setMainViOverclockPercent($0) }
          }

          // Adaptive clock (auto) + VI-skip mode
          adaptiveControls()

          Divider().background(.white.opacity(0.2))

          // Overlays + diagnostics, as a scannable icon grid.
          overlayToggleGrid()

          // Graphics quick controls
          HStack {
            Text("Internal Resolution: \(efbScaleQuick == 0 ? "Auto" : "\(efbScaleQuick)x")").foregroundColor(.white.opacity(0.8))
            autoBadge(efbAutoOverridden)
            Spacer()
            TVIntStepperOverlay(value: $efbScaleQuick, range: 0 ... efbMaxScaleQuick, step: 1)
              // Resolver step #3: while Auto-IR / thermal drives GFX_EFB_SCALE (CurrentRun), the
              // manual stepper is disabled and the value shown is the live effective scale.
              .disabled(efbAutoOverridden)
              .onChange(of: efbScaleQuick) { newScale in
                DOLConfigBridge.setGfxEfbScale(newScale)
                // A manual IR pick fights Auto-IR (both drive GFX_EFB_SCALE). Disable Auto-IR so
                // the manual choice sticks -- same rule as the Settings picker (step #6).
                if newScale != 0 { DOLConfigBridge.setGfxAutoIREnable(false) }
              }
          }
          HStack {
            Text("Anisotropic: \(anisotropyQuick)x").foregroundColor(.white.opacity(0.8))
            Spacer()
            TVIntStepperOverlay(value: $anisotropyQuick, range: 1 ... 16, step: 1)
              .onChange(of: anisotropyQuick) { DOLConfigBridge.setGfxEnhanceAnisotropySamples($0) }
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
    .sheet(isPresented: $showSettings) {
      ZStack {
        // Beautiful blurred background like other menus
        Image(uiImage: game.coverImage)
          .resizable()
          .scaledToFill()
          .blur(radius: 25)

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

        SettingsRootView(backgroundView: AnyView(Color.clear), isPauseMenuStyle: true, game: game)
      }
    }
    //    .sheet(isPresented: $showMotionDebug) {
    //      NavigationStack {
    //        MotionDebugView()
    //      }
    //      .environment(\.colorScheme, .dark)
    //    }
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
              showMotionDebug = true
            } label: {
              Image(systemName: "gyroscope")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .padding(12)
                .background(.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable(true)
            .padding([.top, .trailing], 8)
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
      configureAllControllers()
      setupPauseGestureHandlers()
      logCurrentControllers()
      for c in GCController.controllers() { installExtraInputHandlers(c) }

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
      NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main) { _ in
        ControllerManager.shared.registerGCOverride(forController: 0)
        configureAllControllers()
        // Resume where I left off: if enabled and an auto-state exists, load it.
        SaveStateService.resumeIfAvailable()
      }
      // Auto-pause when app goes to background on tvOS
      NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
        NSLog("[INPUT] tvOS app backgrounded - showing pause menu")
        showPauseMenu = true
      }
      NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
        NSLog("[INPUT] tvOS app foregrounded - keeping pause menu visible")
        // Keep pause menu visible when returning to foreground so user can choose to resume
      }
      // Load current OC/VBI state
      ocEnabled = DOLConfigBridge.mainOverclockEnable()
      ocPercent = DOLConfigBridge.mainOverclockPercent()
      vbiEnabledQuick = DOLConfigBridge.mainViOverclockEnable()
      vbiPercentQuick = DOLConfigBridge.mainViOverclockPercent()
      // Resolver step #3: is an auto controller currently overriding these keys (CurrentRun)?
      ocAutoOverridden = DOLConfigBridge.isOverclockAutoOverridden()
      vbiAutoOverridden = DOLConfigBridge.isViOverclockAutoOverridden()
      efbAutoOverridden = DOLConfigBridge.isEfbScaleAutoOverridden()
      // Overlay toggles and quick graphics
      showFPSQuick = DOLConfigBridge.gfxShowFPS()
      showVPSQuick = DOLConfigBridge.gfxShowVPS()
      showSpeedQuick = DOLConfigBridge.gfxShowSpeed()
      showVBlankQuick = DOLConfigBridge.gfxShowVTimes()
      efbMaxScaleQuick = max(1, DOLConfigBridge.gfxEfbMaxScale())
      efbScaleQuick = DOLConfigBridge.gfxEfbScale()
      anisotropyQuick = DOLConfigBridge.gfxEnhanceAnisotropySamples()
      // Adaptive clock (NSUserDefault), VI-skip mode, perf graph
      adaptiveClockQuick = UserDefaults.standard.bool(forKey: "adaptive_clock_enable")
      viSkipModeQuick = DOLConfigBridge.gfxHackViSkipMode()
      showGraphsQuick = DOLConfigBridge.gfxShowGraphs()
      overlayStatsQuick = DOLConfigBridge.gfxOverlayStats()
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
    .onDisappear {
      if let token = endObserver { NotificationCenter.default.removeObserver(token)
        endObserver = nil
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
      #endif
      ControllerManager.shared.unregisterGCOverride(forController: 0)
      for c in GCController.controllers() {
        c.extendedGamepad?.valueChangedHandler = nil
        c.gamepad?.valueChangedHandler = nil
        c.microGamepad?.valueChangedHandler = nil
        c.extendedGamepad?.buttonMenu.pressedChangedHandler = nil
        c.microGamepad?.buttonMenu.pressedChangedHandler = nil
      }
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
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        GeometryReader { proxy in
          let isPortrait = proxy.size.height > proxy.size.width
          let gameAR = stableAR ?? (proxy.size.width / max(proxy.size.height, 1))
          if isPortrait {
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
          // Resume where I left off (iOS): the tvOS branch wires this via its
          // start observer; iOS had none, so .auto auto-saved on quit but never
          // reloaded. Register once (guarded) so it loads on emulation start.
          guard resumeObserver == nil else { return }
          resumeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("DOLEmulationDidStartNotification"),
            object: nil, queue: .main) { _ in
            SaveStateService.resumeIfAvailable()
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
          ControllerDisconnectBanner()
            .zIndex(5)
        }

        // Top hit area: tap near status bar to reveal overlay (active only when hidden)
        if !showTopBar {
          VStack(spacing: 0) {
            Color.clear
              .frame(height: 80)
              .contentShape(Rectangle())
              .onTapGesture { toggleTopBar() }
            Spacer()
          }
          .ignoresSafeArea(edges: .top)
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

        if showTopBar {
          VStack {
            HStack(spacing: 16) {
              Button {
                hasTopBarInteraction = true
                // Prompt to exit rather than opening pause menu
                showExitConfirm = true
              } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
              Spacer()
              // Touch controls menu
              Menu {
                Button {
                  hasTopBarInteraction = true
                  userOverrideTouchControls = true
                  controllerManager.overlayVisible.toggle()
                  isTouchControlsActive = controllerManager.overlayVisible
                  touchPadsRefreshToken = UUID()
                } label: {
                  Label(controllerManager.overlayVisible ? "Hide On‑Screen Controller" : "Show On‑Screen Controller", systemImage: controllerManager.overlayVisible ? "eye.slash" : "eye")
                }
                Divider()
                Button {
                  hasTopBarInteraction = true
                  userOverrideTouchControls = true
                  controllerManager.overlayMode = .auto
                  touchPadsRefreshToken = UUID()
                } label: {
                  Label("Auto", systemImage: controllerManager.overlayMode == .auto ? "checkmark" : "")
                }
                Button {
                  hasTopBarInteraction = true
                  userOverrideTouchControls = true
                  controllerManager.overlayMode = .gamecube
                  controllerManager.overlayVisible = true
                  isTouchControlsActive = true
                  touchPadsRefreshToken = UUID()
                } label: {
                  Label("GameCube", systemImage: controllerManager.overlayMode == .gamecube ? "checkmark" : "")
                }
                Button {
                  hasTopBarInteraction = true
                  userOverrideTouchControls = true
                  controllerManager.overlayMode = .wii
                  controllerManager.overlayVisible = true
                  isTouchControlsActive = true
                  touchPadsRefreshToken = UUID()
                } label: {
                  Label("Wii", systemImage: controllerManager.overlayMode == .wii ? "checkmark" : "")
                }
              } label: {
                Image(systemName: "gamecontroller").font(.title2)
              }
              // Quick performance overlay button
              Button {
                hasTopBarInteraction = true
                refreshPerfOverlayState()
                showPerfOverlay = true
              } label: {
                Image(systemName: "speedometer").font(.title2)
              }
              Button {
                hasTopBarInteraction = true
                fastForwardEnabled = TVEmulationBridge.toggleFastForward()
              } label: {
                Image(systemName: fastForwardEnabled ? "forward.fill" : "forward")
                  .font(.title2)
              }

              #if os(iOS)
              // Thermal badge
              if UserDefaults.standard.bool(forKey: "thermal_auto_enable") {
                ThermalBadgeView()
              }
              if UserDefaults.standard.bool(forKey: "replaykit_instant_replay_enabled") {
                Button {
                  hasTopBarInteraction = true
                  ReplayKitManager.shared.saveRecentClip(seconds: 15)
                } label: {
                  Image(systemName: "clock.arrow.circlepath").font(.title2)
                }
              }
              #endif // os(iOS)
              Menu {
                Button {
                  hasTopBarInteraction = true
                  showFXSheet = true
                } label: {
                  Label("Audio Effects", systemImage: "slider.horizontal.3")
                }
                Button {
                  hasTopBarInteraction = true
                  showShaderSheet = true
                } label: {
                  Label("Shaders", systemImage: "wand.and.stars")
                }
                Button {
                  hasTopBarInteraction = true
                  showShaderParams = true
                } label: {
                  Label("Shader Parameters", systemImage: "slider.horizontal.3")
                }
              } label: {
                Image(systemName: "slider.horizontal.3").font(.title2)
              }

              Menu {
                Menu {
                  ForEach(1 ... 10, id: \.self) { slot in
                    Button("Slot \(slot)") {
                      hasTopBarInteraction = true
                      selectedSlot = slot
                      SaveStateService.saveSlot(slot)
                    }
                  }
                } label: {
                  Label("Save State", systemImage: "square.and.arrow.down")
                }
                Menu {
                  ForEach(1 ... 10, id: \.self) { slot in
                    Button("Slot \(slot)") {
                      hasTopBarInteraction = true
                      selectedSlot = slot
                      TVEmulationBridge.loadState(fromSlot: slot)
                    }
                  }
                } label: {
                  Label("Load State", systemImage: "square.and.arrow.up")
                }
                #if os(iOS)
                Menu {
                  let currentIR = DOLConfigBridge.mainTouchPadIRMode()
                  Button {
                    hasTopBarInteraction = true
                    DOLConfigBridge.setMainTouchPadIRMode(0)
                    isTouchControlsActive = true
                    userOverrideTouchControls = true
                    touchPadsRefreshToken = UUID()
                  } label: {
                    Label("Gyro", systemImage: currentIR == 0 ? "checkmark" : "gyroscope")
                  }
                  Button {
                    hasTopBarInteraction = true
                    DOLConfigBridge.setMainTouchPadIRMode(1)
                    isTouchControlsActive = true
                    userOverrideTouchControls = true
                    touchPadsRefreshToken = UUID()
                  } label: {
                    Label("Follow", systemImage: currentIR == 1 ? "checkmark" : "hand.point.up")
                  }
                  Button {
                    hasTopBarInteraction = true
                    DOLConfigBridge.setMainTouchPadIRMode(2)
                    isTouchControlsActive = true
                    userOverrideTouchControls = true
                    touchPadsRefreshToken = UUID()
                  } label: {
                    Label("Drag", systemImage: currentIR == 2 ? "checkmark" : "hand.draw")
                  }
                } label: {
                  Label("Touch Cursor Mode", systemImage: "cursor.rays")
                }
                #endif
                Button {
                  hasTopBarInteraction = true
                  showMotionDebug = true
                } label: {
                  Label("Motion Controls", systemImage: "gyroscope")
                }
              } label: {
                Image(systemName: "square.stack.3d.up").font(.title2)
              }
              Button { hasTopBarInteraction = true
                showPauseMenu = true
              } label: { Image(systemName: "list.bullet.rectangle").font(.title2) }
              Button { hasTopBarInteraction = true
                hideTopBar(now: true)
              } label: { Image(systemName: "chevron.up.circle.fill").font(.title2) }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
            Spacer()
          }
          .transition(.move(edge: .top).combined(with: .opacity))
          .zIndex(2)
        }

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
                        .disabled(ocAutoOverridden)
                        autoBadge(ocAutoOverridden)
                      }
                      HStack {
                        Slider(value: Binding(get: { Double(ocPercent) }, set: { ocPercent = Int($0) }), in: 1 ... 400)
                          .disabled(!ocEnabled || ocAutoOverridden)
                          .onChange(of: ocPercent) { DOLConfigBridge.setMainOverclockPercent($0) }
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
                        .disabled(vbiAutoOverridden)
                        autoBadge(vbiAutoOverridden)
                      }
                      HStack {
                        Slider(value: Binding(get: { Double(vbiPercentQuick) }, set: { vbiPercentQuick = Int($0) }), in: 1 ... 400)
                          .disabled(!vbiEnabledQuick || vbiAutoOverridden)
                          .onChange(of: vbiPercentQuick) { DOLConfigBridge.setMainViOverclockPercent($0) }
                        Text("\(vbiPercentQuick)%").foregroundColor(.white.opacity(0.8)).frame(width: 52, alignment: .trailing)
                      }

                      // Graphics controls
                      HStack {
                        Text(L("Internal Resolution"))
                          .foregroundColor(.white.opacity(0.8))
                          .font(.caption)
                        autoBadge(efbAutoOverridden)
                        Spacer()
                        Slider(value: Binding(get: { Double(efbScaleQuick) }, set: { efbScaleQuick = Int($0) }), in: 0 ... Double(max(1, efbMaxScaleQuick)), step: 1)
                          .disabled(efbAutoOverridden)
                          .onChange(of: efbScaleQuick) { newScale in
                            DOLConfigBridge.setGfxEfbScale(newScale)
                            // Manual IR pick disables Auto-IR so the choice sticks (step #6).
                            if newScale != 0 { DOLConfigBridge.setGfxAutoIREnable(false) }
                          }
                        Text(efbScaleQuick == 0 ? "Auto" : "\(efbScaleQuick)x").foregroundColor(.white.opacity(0.8)).frame(width: 50, alignment: .trailing)
                      }
                      HStack {
                        Text(L("Anisotropic Filtering"))
                          .foregroundColor(.white.opacity(0.8))
                          .font(.caption)
                        Spacer()
                        Slider(value: Binding(get: { Double(anisotropyQuick) }, set: { anisotropyQuick = Int($0) }), in: 1 ... 16, step: 1)
                          .onChange(of: anisotropyQuick) { DOLConfigBridge.setGfxEnhanceAnisotropySamples($0) }
                        Text("\(anisotropyQuick)x").foregroundColor(.white.opacity(0.8)).frame(width: 50, alignment: .trailing)
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
                    .disabled(ocAutoOverridden)
                    autoBadge(ocAutoOverridden)
                  }
                  HStack {
                    Slider(value: Binding(get: { Double(ocPercent) }, set: { ocPercent = Int($0) }), in: 1 ... 400)
                      .disabled(!ocEnabled || ocAutoOverridden)
                      .onChange(of: ocPercent) { DOLConfigBridge.setMainOverclockPercent($0) }
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
                    .disabled(vbiAutoOverridden)
                    autoBadge(vbiAutoOverridden)
                  }
                  HStack {
                    Slider(value: Binding(get: { Double(vbiPercentQuick) }, set: { vbiPercentQuick = Int($0) }), in: 1 ... 400)
                      .disabled(!vbiEnabledQuick || vbiAutoOverridden)
                      .onChange(of: vbiPercentQuick) { DOLConfigBridge.setMainViOverclockPercent($0) }
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
                    autoBadge(efbAutoOverridden)
                    Spacer()
                    Slider(value: Binding(get: { Double(efbScaleQuick) }, set: { efbScaleQuick = Int($0) }), in: 0 ... Double(max(1, efbMaxScaleQuick)), step: 1)
                      .disabled(efbAutoOverridden)
                      .onChange(of: efbScaleQuick) { newScale in
                        DOLConfigBridge.setGfxEfbScale(newScale)
                        // Manual IR pick disables Auto-IR so the choice sticks (step #6).
                        if newScale != 0 { DOLConfigBridge.setGfxAutoIREnable(false) }
                      }
                    Text(efbScaleQuick == 0 ? "Auto" : "\(efbScaleQuick)x").foregroundColor(.white.opacity(0.8)).frame(width: 60, alignment: .trailing)
                  }
                  HStack {
                    Text(L("Anisotropic Filtering"))
                      .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Slider(value: Binding(get: { Double(anisotropyQuick) }, set: { anisotropyQuick = Int($0) }), in: 1 ... 16, step: 1)
                      .onChange(of: anisotropyQuick) { DOLConfigBridge.setGfxEnhanceAnisotropySamples($0) }
                    Text("\(anisotropyQuick)x").foregroundColor(.white.opacity(0.8)).frame(width: 60, alignment: .trailing)
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
          let isWiiToShow: Bool = {
            switch controllerManager.overlayMode {
            case .auto: return isWiiSystem
            case .gamecube: return false
            case .wii: return true
            }
          }()
          TouchPadsContainer(forceVisible: true, isWii: isWiiToShow)
            .id(touchPadsRefreshToken)
            .ignoresSafeArea()
            .transition(.opacity)
            .onAppear {
              TVEmulationBridge.setWiiIMUPointEnabled(false)
              // Ensure touch input is always a valid IR source
              TCDeviceMotion.shared.setMotionEnabled(true)
              TCDeviceMotion.shared.setPort(4)
              TCDeviceMotion.shared.statusBarOrientationChanged()
            }
            .onDisappear {
              TVEmulationBridge.setWiiIMUPointEnabled(true)
            }
        }
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
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          HStack(spacing: 12) {
            Button { showPauseMenu = true } label: { Image(systemName: "line.3.horizontal") }
            #if os(iOS)
            if DOLConfigBridge.mainEmulateSkylanderPortal() && isWiiSystem {
              Menu {
                Button("Load Skylander…") { showSkyImporter = true }
                Button("Clear Slot…") { showSkyClearPicker = true }
                Button("Clear All") {
                  DOLConfigBridge.skylanderClearAll()
                }
              } label: {
                Image(systemName: "externaldrive")
              }
            }
            #endif // os(iOS)
          }
        }
      }
      .fileImporter(isPresented: $showSkyImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
        if case .success(let urls) = result, let url = urls.first {
          let started = url.startAccessingSecurityScopedResource()
          defer { if started { url.stopAccessingSecurityScopedResource() } }
          let slot = DOLConfigBridge.skylanderLoad(fromPath: url.path)
          if slot > 0 { skyLastLoadedSlot = slot }
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
      let wantsMotionForShake = UserDefaults.standard.bool(forKey: "motion_enhanced_shake_detection") && isWiiSystem
      TVEmulationBridge.setWiiIMUPointEnabled(useIMU || wantsMotionForShake)
      let wantsMotion = (isTouchControlsActive && useIMU) || wantsMotionForShake
      TCDeviceMotion.shared.setMotionEnabled(wantsMotion)
      if wantsMotion {
        TCDeviceMotion.shared.setPort(4)
        TCDeviceMotion.shared.statusBarOrientationChanged()
      }

      // Enable enhanced motion controls for touchscreen by default (Wii games)
      if isWiiSystem {
        setupEnhancedMotionControls()
      }

      // Listen for motion settings changes during gameplay
      NotificationCenter.default.addObserver(forName: Notification.Name("DOLMotionSettingsChanged"), object: nil, queue: .main) { _ in
        restartMotionSystemForSettingsChange()
        // Ensure motion stays on for shake even if touch overlay is hidden but an external controller is connected
        let wantsMotionForShake2 = UserDefaults.standard.bool(forKey: "motion_enhanced_shake_detection") && isWiiSystem
        if wantsMotionForShake2 {
          Task { @MainActor in
            TCDeviceMotion.shared.setMotionEnabled(true)
            TCDeviceMotion.shared.setPort(4)
            TCDeviceMotion.shared.statusBarOrientationChanged()
          }
        }
      }
      // Ensure touch controls start visible
      isTouchControlsActive = controllerManager.overlayVisible
      desiredTouchControls = true
      // Reconcile and ensure Pad 1 defaults to touchscreen if needed
      ControllerManager.shared.reconcile()
      EmulationCoordinator.ensurePad1DefaultsToTouchscreen()
      // Configure Wiimote sources based on connected controllers
      ControllerManager.shared.updateWiimoteEmulationForExternalControllers()
      #if os(iOS)
      ReplayKitManager.shared.startBufferingIfEnabled()
      if UserDefaults.standard.bool(forKey: "thermal_auto_enable") { ThermalManager.shared.start() }
      #endif
      // On iOS, do not hand controller button presses to the system while in-game
      GCController.shouldMonitorBackgroundEvents = false

      logCurrentControllers()
      fastForwardEnabled = TVEmulationBridge.isFastForwardEnabled()
      for c in GCController.controllers() { installExtraInputHandlers(c) }
      #if os(iOS)
      SiriShortcutManager.shared.donatePlay(game: game)
      #endif
      // Controller connect/disconnect handled by ControllerManager
      // NotificationCenter bridging for assignments remains
      NotificationCenter.default.addObserver(forName: ControllerManager.assignmentsChanged, object: nil, queue: .main) { _ in
        touchPadsRefreshToken = UUID()
      }
      NotificationCenter.default.addObserver(forName: Notification.Name("DOLWiiOverlayLayoutChangedNotification"), object: nil, queue: .main) { _ in
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
      ocEnabled = DOLConfigBridge.mainOverclockEnable()
      ocPercent = DOLConfigBridge.mainOverclockPercent()
      vbiEnabledQuick = DOLConfigBridge.mainViOverclockEnable()
      vbiPercentQuick = DOLConfigBridge.mainViOverclockPercent()
      // Resolver step #3: is an auto controller currently overriding these keys (CurrentRun)?
      ocAutoOverridden = DOLConfigBridge.isOverclockAutoOverridden()
      vbiAutoOverridden = DOLConfigBridge.isViOverclockAutoOverridden()
      efbAutoOverridden = DOLConfigBridge.isEfbScaleAutoOverridden()
      // Overlay toggles and quick graphics
      showFPSQuick = DOLConfigBridge.gfxShowFPS()
      showVPSQuick = DOLConfigBridge.gfxShowVPS()
      showSpeedQuick = DOLConfigBridge.gfxShowSpeed()
      showVBlankQuick = DOLConfigBridge.gfxShowVTimes()
      efbMaxScaleQuick = max(1, DOLConfigBridge.gfxEfbMaxScale())
      efbScaleQuick = DOLConfigBridge.gfxEfbScale()
      anisotropyQuick = DOLConfigBridge.gfxEnhanceAnisotropySamples()
      // Adaptive clock (NSUserDefault), VI-skip mode, perf graph
      adaptiveClockQuick = UserDefaults.standard.bool(forKey: "adaptive_clock_enable")
      viSkipModeQuick = DOLConfigBridge.gfxHackViSkipMode()
      showGraphsQuick = DOLConfigBridge.gfxShowGraphs()
      overlayStatsQuick = DOLConfigBridge.gfxOverlayStats()
      // Default Wii IR mode if unset: set to Absolute (1) and schedule one-time deferred recalc
      let currentIR = DOLConfigBridge.mainTouchPadIRMode()
      if currentIR == 0 { // None
        DOLConfigBridge.setMainTouchPadIRMode(1) // Absolute
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
          TVEmulationBridge.resizeSurfaceNow()
        }
      }
      // Initialize overlay signature for Wii type (extension + sideways)
      let ext0 = Int(DOLWiimoteBridge.selectedExtension(forWiimote: 0))
      let side0 = DOLWiimoteBridge.isSideways(forWiimote: 0)
      wiiOverlaySignature = (ext0 & 0xFF) | (side0 ? 0x100 : 0)
      // Default touch controls: enabled when no controllers are connected (only if not user-overridden)
      if !userOverrideTouchControls {
        let visible = GCController.controllers().isEmpty
        controllerManager.overlayVisible = visible
        isTouchControlsActive = visible
      }
      // ControllerManager publishes connect/disconnect; adjust default overlay there via reconcile if needed
      // Show bar on appear and schedule one-time auto-hide
      showTopBar = true
      hasTopBarInteraction = false
      if !autoHideScheduled { autoHideScheduled = true
        scheduleAutoHide()
      }
    }
    .onDisappear {
      if let token = endObserver { NotificationCenter.default.removeObserver(token)
        endObserver = nil
      }
      if let t = obsGCConnect { NotificationCenter.default.removeObserver(t)
        obsGCConnect = nil
      }
      if let t = obsGCDisconnect { NotificationCenter.default.removeObserver(t)
        obsGCDisconnect = nil
      }
      if let t = obsShowPause { NotificationCenter.default.removeObserver(t)
        obsShowPause = nil
      }
      // Do not stopObserving() here — the controller observer is app-wide (started
      // in MainDisplaySceneDelegate) so auto-assign stays live after exiting a game.
      // Disable motion when leaving screen
      TCDeviceMotion.shared.setMotionEnabled(false)
      arPollTask?.cancel()
      arPollTask = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      // Ask the renderer to resize/reconfigure
      TVEmulationBridge.resizeSurfaceNow()
    }
    .onReceive(controllerManager.controllerConnectedPublisher) { _ in
      touchPadsRefreshToken = UUID()
      ControllerStyleManager.shared.refreshDetection()
      ControllerStyleManager.shared.applyPresetDefaults()
    }
    .onReceive(controllerManager.controllerDisconnectedPublisher) { _ in
      touchPadsRefreshToken = UUID()
      ControllerStyleManager.shared.refreshDetection()
    }
    .onReceive(controllerManager.fastForwardToggledPublisher) { enabled in
      fastForwardEnabled = enabled
    }
    .onReceive(controllerManager.$overlayMode) { _ in
      touchPadsRefreshToken = UUID()
      if controllerManager.overlayMode == .wii {
        // Ensure Wiimote1 uses touchscreen and configure external controllers appropriately
        controllerManager.ensureWiimote1EmulatedTouchscreen()
      }
    }
    .onReceive(controllerManager.$overlayVisible) { v in
      isTouchControlsActive = v
      touchPadsRefreshToken = UUID()
    }
    // iOS has no 1s timer (the tvOS branch does); poll paused-state for the HUD pill.
    .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
      isPaused = TVEmulationBridge.isPaused()
      // Clear a stale disconnect banner if the game resumed via any other path.
      if controllerManager.disconnectPause != nil && !TVEmulationBridge.isPaused() {
        controllerManager.clearDisconnectPause()
      }
    }
    .onChange(of: showPauseMenu) { _ in
      isPaused = TVEmulationBridge.isPaused()
    }
    .navigationBarHidden(true)
    .statusBar(hidden: true)
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
    .sheet(isPresented: $showMotionDebug) {
      NavigationStack {
        MotionDebugView()
      }
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
        withAnimation { showTopBar = false }
      }
    } message: {
      Text("Do you want to stop the current game and return to the library?")
    }
    #endif
  }

  // Adaptive-clock (auto) live toggle + VI-skip mode picker, shared across all perf-overlay layouts.
  // Resolver step #3: refresh the perf-overlay state from the live config whenever the overlay is
  // opened. The auto controllers (adaptive clock / Auto-IR / thermal) only write CurrentRun once
  // gameplay is underway — AFTER the one-time onAppear load — so re-reading here is what makes the
  // "Auto" badge appear and the manual controls disable when the user opens the overlay mid-game.
  private func refreshPerfOverlayState() {
    ocEnabled = DOLConfigBridge.mainOverclockEnable()
    ocPercent = DOLConfigBridge.mainOverclockPercent()
    vbiEnabledQuick = DOLConfigBridge.mainViOverclockEnable()
    vbiPercentQuick = DOLConfigBridge.mainViOverclockPercent()
    ocAutoOverridden = DOLConfigBridge.isOverclockAutoOverridden()
    vbiAutoOverridden = DOLConfigBridge.isViOverclockAutoOverridden()
    efbAutoOverridden = DOLConfigBridge.isEfbScaleAutoOverridden()
    efbMaxScaleQuick = max(1, DOLConfigBridge.gfxEfbMaxScale())
    efbScaleQuick = DOLConfigBridge.gfxEfbScale()
    anisotropyQuick = DOLConfigBridge.gfxEnhanceAnisotropySamples()
  }

  // Resolver step #3: small "Auto" pill shown next to a perf control whose key is currently being
  // driven by an auto controller (CurrentRun override shadowing the user's manual Base value). When
  // shown, the corresponding manual control is also disabled so the displayed effective value can't
  // be silently shadowed by a stale Base authored underneath.
  @ViewBuilder
  private func autoBadge(_ active: Bool) -> some View {
    if active {
      Text("Auto")
        .font(.caption2).bold()
        .foregroundColor(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.blue.opacity(0.85))
        .clipShape(Capsule())
        .accessibilityLabel(Text("Auto override active"))
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
      ocAutoOverridden = v
      vbiAutoOverridden = v
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
