import SwiftUI
import UIKit
import GameController
import Combine

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
  func updateUIView(_ uiView: UIView, context: Context) { }
}

private final class EmuContainerViewController: UIViewController {
  private weak var emuVC: EmuEventVC?
  private var exitObserver: NSObjectProtocol?
  var gamePath: String = ""

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
    vc.controllerUserInteractionEnabled = true
    addChild(vc)
    vc.view.frame = view.bounds
    vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(vc.view)
    vc.didMove(toParent: self)
    self.emuVC = vc
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

    // JIT warning dialog when JIT is unavailable and a JIT core is selected
    let manager = JitManager.shared()
    let currentCore = DOLConfigBridge.mainCpuCore()
    let isJitCoreSelected = (currentCore == 3) // JITARM64
    if !manager.acquiredJit && isJitCoreSelected {
      let alert = UIAlertController(title: "Waiting for JIT", message: "DolphiniOS may need a remote debugger to enable JIT. You can continue with a slower, no-JIT mode.", preferredStyle: .alert)
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
  }

  private func handleExit() {
    NotificationCenter.default.post(name: Notification.Name("DOLEmulationDidEndNotification"), object: nil)
  }

  deinit {
    if let token = exitObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }
}

private struct EmulationSurfaceController: UIViewControllerRepresentable {
  let gamePath: String
  func makeUIViewController(context: Context) -> EmuContainerViewController {
    let vc = EmuContainerViewController()
    vc.gamePath = resolveCachedPathIfAvailable(gamePath)
    return vc
  }
  func updateUIViewController(_ uiViewController: EmuContainerViewController, context: Context) { }
}

  @MainActor
  private func resolveCachedPathIfAvailable(_ path: String) -> String {
    guard let url = URL(string: path), let scheme = url.scheme?.lowercased(), ["http","https","webdav","webdavs"].contains(scheme) else {
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

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }
}

struct EmulationScreen: View {
  let game: TVGameItem
  @Environment(\.dismiss) private var dismiss
  @State private var endObserver: NSObjectProtocol?
#if os(tvOS)
  @State private var exitObserver: NSObjectProtocol?
#endif

  // Pause menu state
  @State private var showPauseMenu = false
  @State private var selectedSlot = 1
  @State private var showSettings = false
  // iOS top overlay
#if os(iOS)
  @State private var showTopBar = false
  @State private var fastForwardEnabled = false
  @State private var hideBarWorkItem: DispatchWorkItem?
  // iOS observer tokens to avoid leaks
  @State private var obsGCConnect: NSObjectProtocol?
  @State private var obsGCDisconnect: NSObjectProtocol?
  @State private var obsShowPause: NSObjectProtocol?
  @State private var showExitConfirm = false
  @State private var showShaderSheet = false
  @State private var showShaderParams = false
  // Auto-hide coordination
  @State private var hasTopBarInteraction: Bool = false
  @State private var autoHideScheduled: Bool = false
  @State private var autoHideToken = UUID()
  // AR stabilization
  @State private var stableAR: CGFloat?
  @State private var arPollTask: Task<Void, Never>?
  // Touch pad refresh coordination to avoid system detection races
  @State private var touchPadsRefreshToken = UUID()
  @State private var irModeRaw: Int = 1
  @State private var desiredTouchControls: Bool = true
  @StateObject private var touchVM = TouchControlsViewModel()
  @ObservedObject private var controllerManager = ControllerManager.shared
#endif
  @State private var elapsedSeconds: Int = 0
  @State private var timer: Timer?
  @State private var isWiiSystem: Bool = false

  var body: some View {
#if os(tvOS)
    ZStack {
      EmulationSurfaceController(gamePath: game.filePath)
        .ignoresSafeArea()
        .focusable(!showPauseMenu)
        .allowsHitTesting(!showPauseMenu)
        .navigationBarBackButtonHidden(true)

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
    .fullScreenCover(isPresented: $showPauseMenu) {
      PauseMenuView(
        selectedSlot: $selectedSlot,
        onClose: { showPauseMenu = false },
        onShowSettings: { showSettings = true },
        platform: .tvos,
        game: game
      )
    }
    .onAppear {
      NSLog("[INPUT] tvOS EmulationScreen onAppear. input_debug=%d", UserDefaults.standard.bool(forKey: "input_debug"))
      let initialCount = GCController.controllers().count
      NSLog("[INPUT] tvOS initial controllers count: %d", initialCount)
      GCController.shouldMonitorBackgroundEvents = true
      configureAllControllersForTVOS()
      setupPauseGestureHandlers()
      logCurrentControllers()
      if initialCount == 0 {
        NSLog("[INPUT] tvOS starting wireless controller discovery")
        GCController.startWirelessControllerDiscovery(completionHandler: {
          NSLog("[INPUT] tvOS wireless controller discovery completed")
        })
      }
      NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
        if let c = note.object as? GCController {
          configureControllerForTVOS(c)
          setupPauseGestureHandler(for: c)
        }
      }
      NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in }
      endObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidEndNotification"), object: nil, queue: .main) { _ in
        dismiss()
      }
      NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main) { _ in
        ControllerManager.shared.registerGCOverride(forController: 0)
        configureAllControllersForTVOS()
      }
      NotificationCenter.default.addObserver(forName: Notification.Name("DOLShowPauseMenu"), object: nil, queue: .main) { _ in
        showPauseMenu = true
      }
      exitObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil, queue: .main) { _ in
        dismiss()
      }
      // Live Activity start
      #if canImport(ActivityKit)
      GameActivityManager.start(gameId: game.gameID, title: game.title, subtitle: game.makerLong, isPaused: TVEmulationBridge.isPaused())
      #endif
      // Start elapsed timer
      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        elapsedSeconds += 1
        #if canImport(ActivityKit)
        GameActivityManager.update(isPaused: TVEmulationBridge.isPaused(), elapsedSeconds: elapsedSeconds)
        #endif
      }
    }
    .onDisappear {
      if let token = endObserver { NotificationCenter.default.removeObserver(token); endObserver = nil }
#if os(tvOS)
      if let token = exitObserver { NotificationCenter.default.removeObserver(token); exitObserver = nil }
#endif
      ControllerManager.shared.unregisterGCOverride(forController: 0)
      for c in GCController.controllers() {
        c.extendedGamepad?.valueChangedHandler = nil
        c.gamepad?.valueChangedHandler = nil
        c.microGamepad?.valueChangedHandler = nil
      }
      #if !os(tvOS)
      arPollTask?.cancel(); arPollTask = nil
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
      #if canImport(ActivityKit)
      GameActivityManager.update(isPaused: visible, elapsedSeconds: elapsedSeconds)
      #endif
    }
    .onExitCommand { if showPauseMenu { TVEmulationBridge.resume(); showPauseMenu = false } }
    .onPlayPauseCommand { }
#else
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
                        #endif
                        Button {
                            hasTopBarInteraction = true
                            showShaderSheet = true
                        } label: {
                            Image(systemName: "wand.and.stars").font(.title2)
                        }
                        Button {
                            hasTopBarInteraction = true
                            showShaderParams = true
                        } label: {
                            Image(systemName: "slider.horizontal.3").font(.title2)
                        }
                        Menu {
                            Menu("Save State") {
                                ForEach(1...10, id: \.self) { slot in
                                    Button("Slot \(slot)") {
                                        hasTopBarInteraction = true
                                        selectedSlot = slot
                                        TVEmulationBridge.saveState(toSlot: slot, wait: true)
                                    }
                                }
                            }
                            Menu("Load State") {
                                ForEach(1...10, id: \.self) { slot in
                                    Button("Slot \(slot)") {
                                        hasTopBarInteraction = true
                                        selectedSlot = slot
                                        TVEmulationBridge.loadState(fromSlot: slot)
                                    }
                                }
                            }
                            #if os(iOS)
                            Menu("Touch Cursor Mode") {
                                let currentIR = DOLConfigBridge.mainTouchPadIRMode()
                                Button {
                                    hasTopBarInteraction = true
                                    DOLConfigBridge.setMainTouchPadIRMode(0)
                                    isTouchControlsActive = true
                                    userOverrideTouchControls = true
                                    touchPadsRefreshToken = UUID()
                                } label: {
                                    Label("Gyro", systemImage: currentIR == 0 ? "checkmark" : "")
                                }
                                Button {
                                    hasTopBarInteraction = true
                                    DOLConfigBridge.setMainTouchPadIRMode(1)
                                    isTouchControlsActive = true
                                    userOverrideTouchControls = true
                                    touchPadsRefreshToken = UUID()
                                } label: {
                                    Label("Follow", systemImage: currentIR == 1 ? "checkmark" : "")
                                }
                                Button {
                                    hasTopBarInteraction = true
                                    DOLConfigBridge.setMainTouchPadIRMode(2)
                                    isTouchControlsActive = true
                                    userOverrideTouchControls = true
                                    touchPadsRefreshToken = UUID()
                                } label: {
                                    Label("Drag", systemImage: currentIR == 2 ? "checkmark" : "")
                                }
                            }
                            #endif
                        } label: {
                            Image(systemName: "square.stack.3d.up").font(.title2)
                        }
                        Button { hasTopBarInteraction = true; showPauseMenu = true } label: { Image(systemName: "list.bullet.rectangle").font(.title2) }
                        Button { hasTopBarInteraction = true; hideTopBar(now: true) } label: { Image(systemName: "chevron.up.circle.fill").font(.title2) }
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
                    }
                    .onDisappear {
                        TVEmulationBridge.setWiiIMUPointEnabled(true)
                    }
            }
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsRootView()
                .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(isPresented: $showPauseMenu) {
            PauseMenuView(
                selectedSlot: $selectedSlot,
                onClose: { showPauseMenu = false },
                onShowSettings: { showSettings = true },
                platform: .ios,
                game: game
            )
        }
    }
    .onAppear {
        NSLog("[INPUT] iOS EmulationScreen onAppear. input_debug=%d", UserDefaults.standard.bool(forKey: "input_debug"))
        NSLog("[INPUT] iOS initial controllers count: %d", GCController.controllers().count)
        ControllerManager.shared.startObserving()
        // Initialize expected system early from metadata to avoid startup races
        isWiiSystem = inferIsWii(from: game)
        irModeRaw = DOLConfigBridge.mainTouchPadIRMode()
        let useIMU = (irModeRaw == 0)
        TVEmulationBridge.setWiiIMUPointEnabled(useIMU)
        TCDeviceMotion.shared.setMotionEnabled(isTouchControlsActive && useIMU)
        // Ensure touch controls start visible
        isTouchControlsActive = controllerManager.overlayVisible
        desiredTouchControls = true
        // Reconcile and ensure Pad 1 defaults to touchscreen if needed
        ControllerManager.shared.reconcile()
        EmulationCoordinator.ensurePad1DefaultsToTouchscreen()
        #if os(iOS)
        ReplayKitManager.shared.startBufferingIfEnabled()
        if UserDefaults.standard.bool(forKey: "thermal_auto_enable") { ThermalManager.shared.start() }
        #endif
        // On iOS, do not hand controller button presses to the system while in-game
        GCController.shouldMonitorBackgroundEvents = false
        for c in GCController.controllers() {
            c.controllerPausedHandler = { _ in }
            if let gp = c.extendedGamepad {
                if #available(iOS 14.0, *) {
                    gp.buttonMenu.preferredSystemGestureState = .alwaysReceive
                    gp.buttonOptions?.preferredSystemGestureState = .disabled
                }
            }
        }
        logCurrentControllers()
        fastForwardEnabled = TVEmulationBridge.isFastForwardEnabled()
        for c in GCController.controllers() { installInputDebugHandlers(c) }
        #if os(iOS)
        SiriShortcutManager.shared.donatePlay(game: game)
        #endif
        // Controller connect/disconnect handled by ControllerManager
        // NotificationCenter bridging for assignments remains
        NotificationCenter.default.addObserver(forName: ControllerManager.assignmentsChanged, object: nil, queue: .main) { _ in
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
        // Default Wii IR mode if unset: set to Absolute (1) and schedule one-time deferred recalc
        let currentIR = DOLConfigBridge.mainTouchPadIRMode()
        if currentIR == 0 { // None
            DOLConfigBridge.setMainTouchPadIRMode(1) // Absolute
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                TVEmulationBridge.resizeSurfaceNow()
            }
        }
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
        if !autoHideScheduled { autoHideScheduled = true; scheduleAutoHide() }
    }
    .onDisappear {
        if let token = endObserver { NotificationCenter.default.removeObserver(token); endObserver = nil }
        if let t = obsGCConnect { NotificationCenter.default.removeObserver(t); obsGCConnect = nil }
        if let t = obsGCDisconnect { NotificationCenter.default.removeObserver(t); obsGCDisconnect = nil }
        if let t = obsShowPause { NotificationCenter.default.removeObserver(t); obsShowPause = nil }
        ControllerManager.shared.stopObserving()
        // Disable motion when leaving screen
        TCDeviceMotion.shared.setMotionEnabled(false)
        arPollTask?.cancel(); arPollTask = nil
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
            DOLConfigBridge.setWiimoteSourceFor(1, source: 1)
            DOLConfigBridge.setConnectWiimotesForControllerInterface(true)
            EmulationCoordinator.ensurePad1DefaultsToTouchscreen()
        }
    }
    .onReceive(controllerManager.$overlayVisible) { v in
        isTouchControlsActive = v
        touchPadsRefreshToken = UUID()
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
    .alert("Exit Game?", isPresented: $showExitConfirm) {
        Button("Save & Quit") {
            TVEmulationBridge.saveState(toSlot: selectedSlot, wait: true)
            TVEmulationBridge.stop()
            #if canImport(ActivityKit)
            GameActivityManager.end()
            #endif
            NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
        }
        Button("Quit", role: .destructive) {
            TVEmulationBridge.stop()
            #if canImport(ActivityKit)
            GameActivityManager.end()
            #endif
            NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
        }
        Button("Continue", role: .cancel) {
            TVEmulationBridge.resume()
            #if canImport(ActivityKit)
            GameActivityManager.update(isPaused: false, elapsedSeconds: elapsedSeconds)
            #endif
            withAnimation { showTopBar = false }
        }
    } message: {
        Text("Do you want to stop the current game and return to the library?")
    }
#endif
  }

#if os(iOS)
  /// ViewModel for on-screen controller visibility and mode
  final class TouchControlsViewModel: ObservableObject {
    enum Mode { case auto, gamecube, wii }
    @Published var isVisible: Bool = true
    @Published var mode: Mode = .auto
  }

  /// Resolve whether the overlay should show Wii or GC pads based on VM mode and current system
  private func overlayIsWii() -> Bool {
    let currentIsWii = TVEmulationBridge.isRunning() ? TVEmulationBridge.isCurrentSystemWii() : isWiiSystem
    switch touchVM.mode {
    case .auto: return currentIsWii
    case .gamecube: return false
    case .wii: return true
    }
  }

  @State private var isTouchControlsActive = false
  @State private var userOverrideTouchControls = false

  private func toggleTopBar() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
      showTopBar.toggle()
    }
    if showTopBar { scheduleAutoHide() }
  }

  private func hideTopBar(now: Bool = false) {
    if now {
      withAnimation { showTopBar = false }
      hideBarWorkItem?.cancel()
      hideBarWorkItem = nil
    } else {
      withAnimation { showTopBar = false }
    }
  }

  private func scheduleAutoHide() {
    hideBarWorkItem?.cancel()
    let token = UUID()
    autoHideToken = token
    let work = DispatchWorkItem {
      if token == autoHideToken && !hasTopBarInteraction {
        withAnimation { self.showTopBar = false }
      }
    }
    hideBarWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
  }

  private func scheduleARPoll() {
    arPollTask?.cancel()
    arPollTask = Task { @MainActor in
      for _ in 0..<20 {
        let ar = CGFloat(TVEmulationBridge.currentDrawAspectRatio())
        if ar.isFinite && ar > 0.4 && ar < 3.5 {
          stableAR = ar
          TVEmulationBridge.resizeSurfaceNow()
          break
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
      }
    }
  }

  /// Heuristic: infer Wii vs GC from game metadata (gameID prefix, file extension)
  private func inferIsWii(from item: TVGameItem) -> Bool {
    let id = item.gameID.uppercased()
    if let first = id.first {
      if first == "R" || first == "S" { return true }
      if first == "G" { return false }
    }
    if let url = URL(string: item.filePath) {
      let ext = url.pathExtension.lowercased()
      if ext == "wbfs" || ext == "wad" { return true }
      if ext == "gcm" { return false }
    }
    return isWiiSystem
  }

  // Pause gesture setup is centralized in ControllerManager.installInputDebugHandlers
  private func setupPauseGestureHandlers() { }
  private func setupPauseGestureHandler(for controller: GCController) { }

#if os(iOS)
  private struct TouchPadsContainer: UIViewRepresentable {
    let forceVisible: Bool
    let isWii: Bool
    func makeUIView(context: Context) -> UIView {
      let host = UIView()
      host.backgroundColor = .clear
      host.isUserInteractionEnabled = true

      // Decide which pad to show based on current system/controller config
      if shouldShowWiiPad() {
        let wiiView = makeWiiPadView()
        wiiView.frame = host.bounds
        wiiView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(wiiView)
        configureWiiView(wiiView, in: host)
      } else if shouldShowGameCubePad() {
        if let v = loadPad(named: "TCGameCubePad") {
          v.frame = host.bounds
          v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
          v.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
          host.addSubview(v)
          NSLog("[TOUCH] Added GC pad with alpha=%.2f", v.alpha)
        } else {
          NSLog("[TOUCH] Failed to load TCGameCubePad nib")
        }
      }
      return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
      uiView.subviews.forEach { $0.removeFromSuperview() }
      if shouldShowWiiPad() {
        let v = makeWiiPadView()
        v.frame = uiView.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        uiView.addSubview(v)
        configureWiiView(v, in: uiView)
      } else if shouldShowGameCubePad() {
        if let v = loadPad(named: "TCGameCubePad") {
          v.frame = uiView.bounds
          v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
          v.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
          uiView.addSubview(v)
        } else {
          NSLog("[TOUCH] Failed to load TCGameCubePad nib (update)")
        }
      } else {
        for sub in uiView.subviews {
          if let wiiPad = findTCWiiPad(in: sub) {
            let ar = CGFloat(TVEmulationBridge.currentDrawAspectRatio())
            let vr = TVEmulationBridge.currentVideoContentRect()
            let inHost = vr == .zero ? uiView.bounds : vr
            wiiPad.recalculatePointerValues(new_rect: inHost, game_aspect: ar)
            wiiPad.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
          } else {
            sub.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
          }
        }
      }
    }

    // MARK: - Decision Logic via ControllerManager
    private func shouldShowGameCubePad() -> Bool {
      let hasExternal = !GCController.controllers().isEmpty
      if hasExternal && !forceVisible { return false }
      let show = ControllerManager.shared.shouldShowGCPad(wiiSystem: isWii, wiiPadAttached: true, gcPadAttached: true)
      NSLog("[TOUCH] GameCube pad decision: isWiiState=\(isWii) shouldShow=\(show)")
      return show
    }

    private func shouldShowWiiPad() -> Bool {
      let hasExternal = !GCController.controllers().isEmpty
      if hasExternal && !forceVisible { return false }
      let show = ControllerManager.shared.shouldShowWiiOverlay(wiiSystem: isWii, wiiPadAttached: true, gcPadAttached: true)
      NSLog("[TOUCH] Wii pad decision: isWiiState=\(isWii) shouldShow=\(show)")
      return show
    }

    // MARK: - Wii Subclass selection & configuration
    private func makeWiiPadView() -> UIView {
      let classic = DOLWiimoteBridge.isClassicActive(forWiimote: 0)
      let sideways = DOLWiimoteBridge.isSideways(forWiimote: 0)
      let view: TCWiiPad
      if classic {
        view = TCClassicWiiPad()
        NSLog("[TOUCH] Using TCClassicWiiPad")
      } else if sideways {
        view = TCSidewaysWiiPad()
        NSLog("[TOUCH] Using TCSidewaysWiiPad")
      } else {
        view = TCWiiPad()
        NSLog("[TOUCH] Using TCWiiPad")
      }
      view.port = 4
      let modeRaw = DOLConfigBridge.mainTouchPadIRMode()
      if let mode = TCWiiTouchIRMode(rawValue: Int(modeRaw)) { view.setTouchIRMode(mode) }
      return view
    }

    private func configureWiiView(_ view: UIView, in container: UIView) {
      if let wiiPad = findTCWiiPad(in: view) {
        let motion = TCDeviceMotion.shared
        motion.setMotionEnabled(true)
        motion.setPort(4)
        motion.statusBarOrientationChanged()
        wiiPad.resetPointer()
        let ar = CGFloat(TVEmulationBridge.currentDrawAspectRatio())
        let vr = TVEmulationBridge.currentVideoContentRect()
        let inHost = vr == .zero ? container.bounds : vr
        wiiPad.recalculatePointerValues(new_rect: inHost, game_aspect: ar)
      } else {
        applyPortRecursively(4, to: view)
      }
    }

    private func loadPad(named name: String) -> UIView? {
      let candidateBundles: [Bundle] = [Bundle(for: TCWiiPad.self), Bundle.main]
      var candidateNames: [String] = [name]
      if name == "TCWiiPad" {
        candidateNames.append(contentsOf: ["TCWiiPad_iOS", "TCWiiPad~iphone", "TCWiiPad~ipad", "WiiPad", "WiiPadView"]) }
      if name == "TCGameCubePad" {
        candidateNames.append(contentsOf: ["TCGameCubePadView", "TCGamePad", "GameCubePad"]) }
      for b in candidateBundles {
        for n in candidateNames {
          if let _ = b.path(forResource: n, ofType: "nib") {
            let nib = UINib(nibName: n, bundle: b)
            let objects = nib.instantiate(withOwner: nil, options: nil)
            if let v = objects.first as? UIView { NSLog("[TOUCH] Loaded nib %@ from %@", n, String(describing: b.bundlePath)); return v }
          }
        }
      }
      NSLog("[TOUCH] Could not find nib for %@ in candidate bundles", name)
      return nil
    }

    private func viewContainsTCWiiPad(_ v: UIView) -> Bool { return findTCWiiPad(in: v) != nil }
    private func findTCWiiPad(in v: UIView) -> TCWiiPad? {
      if let w = v as? TCWiiPad { return w }
      for sub in v.subviews { if let found = findTCWiiPad(in: sub) { return found } }
      return nil
    }

    private func applyPortRecursively(_ port: Int, to view: UIView) {
      if let b = view as? TCButton { b.port = port }
      else if let j = view as? TCJoystick { j.port = port }
      else if let d = view as? TCDirectionalPad { d.port = port }
      for sub in view.subviews { applyPortRecursively(port, to: sub) }
      NSLog("[TOUCH] Applied port=\(port) recursively to subtree: \(type(of: view))")
    }
  }
#endif

  #endif

  private func logCurrentControllers() {
    guard UserDefaults.standard.bool(forKey: "input_debug") else { return }
    let controllers = GCController.controllers()
    NSLog("[INPUT] Currently connected controllers: %d", controllers.count)
    for (idx, c) in controllers.enumerated() {
      NSLog("[INPUT] #%d vendor=%@ category=%@ extended=%d micro=%d", idx, c.vendorName ?? "(nil)", c.productCategory, c.extendedGamepad != nil, c.microGamepad != nil)
    }
  }
}

#if os(iOS)
private struct ThermalBadgeView: View {
    @State private var state: Int = 0
    private func icon() -> String {
        switch state {
        case 1: return "thermometer"
        case 2: return "thermometer.sun"
        case 3: return "thermometer.high"
        default: return "thermometer"
        }
    }
    private func color() -> Color {
        switch state {
        case 1: return .yellow
        case 2: return .orange
        case 3: return .red
        default: return .green
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon()).foregroundStyle(color())
        }
        .onReceive(NotificationCenter.default.publisher(for: ThermalManager.changedNotification)) { note in
            if let s = note.userInfo?["state"] as? Int { state = s }
        }
        .onAppear { state = 0 }
    }
}
#endif
