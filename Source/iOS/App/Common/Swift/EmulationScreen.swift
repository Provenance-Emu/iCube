import SwiftUI
import UIKit
import GameController

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

        DispatchQueue.main.async {
          TVEmulationBridge.registerMainDisplay(displayContainer)
            if TVEmulationBridge.isRunning() {
                NSLog("[INPUT] tvOS Container: core running, skipping relaunch; display registered")
            } else {
                NSLog("[INPUT] tvOS Container: launching game after registerMainDisplayView")
                TVEmulationBridge.launchGame(atPath: self.gamePath)
            }
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
        vc.gamePath = gamePath
        return vc
    }
    func updateUIViewController(_ uiViewController: EmuContainerViewController, context: Context) { }
}

private struct EmulationProgrammaticHost: UIViewControllerRepresentable {
    let gamePath: String

    func makeUIViewController(context: Context) -> UIViewController {
        #if os(tvOS)
        return UIViewController()
        #else
        TVEmulationBridge.launchGame(atPath: gamePath)
        let sb = UIStoryboard(name: "Emulation", bundle: .main)
        return sb.instantiateInitialViewController()!
        #endif
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
                Color.black.ignoresSafeArea()
                SettingsRootView(backgroundView: AnyView(Color.black), isPauseMenuStyle: true, game: game)
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
                UserDefaults.standard.set(true, forKey: "input_debug")
              InputOverriderBridge.registerGameCubeOverride(forController: 0)
                NSLog("[INPUT] tvOS EmulationScreen onAppear. input_debug=%d", UserDefaults.standard.bool(forKey: "input_debug"))
                let initialCount = GCController.controllers().count
                NSLog("[INPUT] tvOS initial controllers count: %d", initialCount)
                GCController.shouldMonitorBackgroundEvents = true
                configureAllControllersForTVOS()
                logCurrentControllers()
                if initialCount == 0 {
                    NSLog("[INPUT] tvOS starting wireless controller discovery")
                    GCController.startWirelessControllerDiscovery(completionHandler: {
                        NSLog("[INPUT] tvOS wireless controller discovery completed")
                    })
                }
                NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
                    if let c = note.object as? GCController { configureControllerForTVOS(c) }
                }
                NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in }
                endObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidEndNotification"), object: nil, queue: .main) { _ in
                    dismiss()
                }
                NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main) { _ in
                    InputOverriderBridge.registerGameCubeOverride(forController: 0)
                    configureAllControllersForTVOS()
                }
                NotificationCenter.default.addObserver(forName: Notification.Name("DOLShowPauseMenu"), object: nil, queue: .main) { _ in
                    showPauseMenu = true
                }
                exitObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil, queue: .main) { _ in
                    dismiss()
                }
            }
            .onDisappear {
                if let token = endObserver { NotificationCenter.default.removeObserver(token); endObserver = nil }
                #if os(tvOS)
                if let token = exitObserver { NotificationCenter.default.removeObserver(token); exitObserver = nil }
                #endif
              InputOverriderBridge.unregisterGameCubeOverride(forController: 0)
                for c in GCController.controllers() {
                    c.extendedGamepad?.valueChangedHandler = nil
                    c.gamepad?.valueChangedHandler = nil
                    c.microGamepad?.valueChangedHandler = nil
                }
            }
            .onChange(of: showPauseMenu) { visible in
                NotificationCenter.default.post(name: Notification.Name(visible ? "DOLPauseOverlayShown" : "DOLPauseOverlayHidden"), object: nil)
            }
            .onExitCommand { if showPauseMenu { TVEmulationBridge.resume(); showPauseMenu = false } }
            .onPlayPauseCommand { }
        #else
        VStack(spacing: 0) {
            // iOS top bar
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                Spacer()
                Button { togglePause() } label: { Image(systemName: TVEmulationBridge.isPaused() ? "play.fill" : "pause.fill") }
                Spacer()
                Menu {
                    Picker("Slot", selection: $selectedSlot) {
                        ForEach(1...10, id: \.self) { Text("Slot \($0)").tag($0) }
                    }
                    Button("Save State") { TVEmulationBridge.saveState(toSlot: selectedSlot, wait: true) }
                    Button("Load State") { TVEmulationBridge.loadState(fromSlot: selectedSlot) }
                    Divider()
                    Button("Settings…") { showSettings = true }
                    #if !os(tvOS)
                    Divider()
                    // Touch controls settings entry (iOS only)
                    Button("Touch Controls…") { NotificationCenter.default.post(name: Notification.Name("DOLShowTouchSettings"), object: nil) }
                    #endif
                } label: {
                    Image(systemName: "tray.and.arrow.down.fill")
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            EmulationProgrammaticHost(gamePath: game.filePath)
                .ignoresSafeArea()
        }
            .sheet(isPresented: $showSettings) { SettingsRootView() }
            .onAppear {
                NSLog("[INPUT] iOS EmulationScreen onAppear. input_debug=%d", UserDefaults.standard.bool(forKey: "input_debug"))
                NSLog("[INPUT] iOS initial controllers count: %d", GCController.controllers().count)
                GCController.shouldMonitorBackgroundEvents = true
                logCurrentControllers()
                for c in GCController.controllers() { installInputDebugHandlers(c) }
                NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
                    if let c = note.object as? GCController { installInputDebugHandlers(c) }
                }
                NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in }
                endObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidEndNotification"), object: nil, queue: .main) { _ in
                    dismiss()
                }
            }
            .onDisappear {
                if let token = endObserver { NotificationCenter.default.removeObserver(token); endObserver = nil }
            }
        #endif
    }

    private func togglePause() {
        if TVEmulationBridge.isPaused() { TVEmulationBridge.resume() } else { TVEmulationBridge.pause() }
    }
}

private func logCurrentControllers() {
    guard UserDefaults.standard.bool(forKey: "input_debug") else { return }
    let controllers = GCController.controllers()
    NSLog("[INPUT] Currently connected controllers: %d", controllers.count)
    for (idx, c) in controllers.enumerated() {
        NSLog("[INPUT] #%d vendor=%@ category=%@ extended=%d micro=%d", idx, c.vendorName ?? "(nil)", c.productCategory, c.extendedGamepad != nil, c.microGamepad != nil)
    }
}
