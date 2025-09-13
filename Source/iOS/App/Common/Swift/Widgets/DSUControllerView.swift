// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import GameController
import UIKit

#if os(iOS)
struct DSUControllerView: View {
  let onClose: () -> Void
  @State private var virtualController: GCVirtualController?
  @State private var showMotionSheet = false
  @State private var irModeLabel: String = ""
  @State private var showLayoutSheet = false
  @AppStorage("dsu_controller_layout") private var layoutRaw: String = DSUControllerLayout.appleVirtual.rawValue
  @AppStorage("dsu_apple_left_is_dpad") private var appleLeftIsDPad: Bool = false
  @AppStorage("dsu_restrict_client") private var restrictClient: String = ""
  @State private var hasClient: Bool = false
  @State private var clientAddr: String = ""
  @State private var txCount: UInt = 0
  @State private var rxCount: UInt = 0
  @State private var clients: [String] = []
  @AppStorage("dsu_show_touch_area") private var showTouchArea: Bool = false
  @State private var motorStates: [Int: Int] = [0: 0, 1: 0] // motorId -> intensity
  @State private var rumbleTimer: Timer?

  /// Whether to show the touch area overlay for the current layout
  private var shouldShowTouchArea: Bool {
    guard showTouchArea else { return false }
    let layout = DSUControllerLayout(rawValue: layoutRaw) ?? .appleVirtual
    // Show touch area for layouts that could benefit from touch input
    return layout == .appleVirtual || layout == .wiiRemote
  }

  var body: some View {
    Group {
      if #available(iOS 16.0, *) {
        NavigationStack { controllerContent }
      } else {
        NavigationView { controllerContent }
      }
    }
  }

  private var controllerContent: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      Group {
        switch DSUControllerLayout(rawValue: layoutRaw) ?? .appleVirtual {
        case .appleVirtual:
          AppleVirtualControllerPlaceholder()
            .onAppear { startVirtualController() }
            .onDisappear { stopVirtualController() }
        case .gamecube:
          TouchControllerNibHost(layout: .gamecube)
            .onAppear { stopVirtualController() }
        case .wiiRemote:
          TouchControllerNibHost(layout: .wiiRemote)
            .onAppear { stopVirtualController() }
        case .wiiClassic:
          TouchControllerNibHost(layout: .wiiClassic)
            .onAppear { stopVirtualController() }
        case .wiiSideways:
          TouchControllerNibHost(layout: .wiiSideways)
            .onAppear { stopVirtualController() }
        }
      }

      // Touch area overlay (for layouts that support touch)
      if shouldShowTouchArea {
        TouchAreaOverlay()
      }

      // Status HUD
      VStack {
        HStack(spacing: 12) {
          // Connection indicator
          Circle().fill(hasClient ? Color.green : Color.red).frame(width: 10, height: 10)
          Text(hasClient ? (clientAddr.isEmpty ? L("Receiver connected") : clientAddr) : L("Waiting for receiver…"))
            .foregroundColor(.white)
            .font(.footnote)
            .lineLimit(1)
          Spacer()
          // Counters
          Text("TX: \(txCount)  RX: \(rxCount)")
            .foregroundColor(.white.opacity(0.8))
            .font(.caption2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.35))
        .clipShape(Capsule())
        .padding(.top, 12)
        .padding(.horizontal, 12)
        Spacer()
      }
      .allowsHitTesting(false)
    }
    .onAppear {
      refreshIRLabel()
      if !DSUServerBridge.isRunning() {
        let p = UserDefaults.standard.integer(forKey: "dsu_server_port")
        let port = (p > 0 && p < 65536) ? p : 26760
        let ok = DSUServerBridge.start(onPort: NSNumber(value: port).intValue)
        if !ok {
          let err = DSUServerBridge.lastError()
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": err.isEmpty ? L("Failed to start DSU server") : err])
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: toggleIRMode) {
          Label(irModeLabel, systemImage: "gyroscope")
        }
      }
      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: { showLayoutSheet = true }) {
          Label(L("Layout"), systemImage: "rectangle.3.offgrid")
        }
      }
      // Target receiver selection
      ToolbarItem(placement: .navigationBarLeading) {
        Menu {
          Button(action: {
            restrictClient = ""; DSUServerBridge.setRestrictToClient(nil)
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Target: All receivers")])
          }) { Label(L("All Receivers"), systemImage: restrictClient.isEmpty ? "checkmark" : "person.3") }
          if clients.isEmpty { Text(L("No receivers seen yet")).foregroundColor(.secondary) }
          ForEach(clients, id: \.self) { addr in
            Button(action: {
              restrictClient = addr; DSUServerBridge.setRestrictToClient(addr)
              NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Target: %@"), addr)])
            }) { Label(addr, systemImage: (restrictClient == addr ? "checkmark" : "antenna.radiowaves.left.and.right")) }
          }
        } label: {
          Label(L("Target"), systemImage: "antenna.radiowaves.left.and.right")
        }
      }
      // Apple controller: toggle between Left Stick and D-Pad (mutually exclusive)
      ToolbarItem(placement: .navigationBarLeading) {
        if (DSUControllerLayout(rawValue: layoutRaw) ?? .appleVirtual) == .appleVirtual {
          Button(action: {
            appleLeftIsDPad.toggle()
            reconfigureVirtualControllerIfNeeded()
          }) {
            Label(appleLeftIsDPad ? L("Left=D‑Pad") : L("Left=Stick"), systemImage: appleLeftIsDPad ? "circle.grid.cross" : "circle")
          }
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: { showMotionSheet = true }) {
          Label(L("Motion"), systemImage: "slider.horizontal.3")
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: { showTouchArea.toggle() }) {
          Label(L("Touch"), systemImage: showTouchArea ? "hand.tap.fill" : "hand.tap")
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: { DSUServerBridge.sendNow() }) { Label(L("Send Test Frame"), systemImage: "paperplane") }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: onClose) { Label(L("Exit"), systemImage: "xmark") }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showMotionSheet) { MotionQuickSettingsView() }
    .sheet(isPresented: $showLayoutSheet) { LayoutPickerSheet(selectedRaw: $layoutRaw) }
    .onChange(of: layoutRaw) { _ in reconfigureVirtualControllerIfNeeded() }
    .onChange(of: restrictClient) { newVal in DSUServerBridge.setRestrictToClient(newVal.isEmpty ? nil : newVal) }
        .onAppear {
      DSUServerBridge.setRestrictToClient(restrictClient.isEmpty ? nil : restrictClient)
      // Publish layout metadata for auto-profile selection on receivers
      publishLayoutTXT(raw: layoutRaw)
    }
     .onChange(of: layoutRaw) { newVal in publishLayoutTXT(raw: newVal) }
    .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
      hasClient = DSUServerBridge.hasClient()
      clientAddr = DSUServerBridge.lastClientAddress()
      txCount = UInt(DSUServerBridge.txCount())
      rxCount = UInt(DSUServerBridge.rxCount())
      clients = DSUServerBridge.clients() as? [String] ?? []
      if !hasClient { DSUServerBridge.sendNow() }
    }
  }

  private func startVirtualController() {
    guard virtualController == nil else { return }
    let cfg = GCVirtualController.Configuration()
    // Use only elements supported by the Apple touch controller.
    // Do NOT include the Menu button; it is system-reserved and not supported here.
    var elems: [String] = [
      GCInputRightThumbstick,
      GCInputLeftShoulder,
      GCInputRightShoulder,
      GCInputLeftTrigger,
      GCInputRightTrigger,
      GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY
    ]
    if appleLeftIsDPad {
      elems.append(GCInputDirectionPad)
    } else {
      elems.append(GCInputLeftThumbstick)
    }
    cfg.elements = Set<String>(elems)
    let vc = GCVirtualController(configuration: cfg)
    vc.connect()
    virtualController = vc
    // Attempt to bind handlers shortly after connect
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { bindVirtualControllerHandlers() }
  }

  private func stopVirtualController() {
    virtualController?.disconnect()
    virtualController = nil
  }

  private func refreshIRLabel() {
    let raw = DOLConfigBridge.mainTouchPadIRMode()
    irModeLabel = (raw == 0) ? L("Gyro") : (raw == 1 ? L("Follow") : L("Drag"))
  }

  private func toggleIRMode() {
    let raw = DOLConfigBridge.mainTouchPadIRMode()
    // Cycle: gyro(0) -> follow(1) -> drag(2) -> gyro(0)
    let next = (raw + 1) % 3
    DOLConfigBridge.setMainTouchPadIRMode(next)
    refreshIRLabel()
    // Haptic and toast for feedback
    #if os(iOS)
    let gen = UINotificationFeedbackGenerator(); gen.notificationOccurred(.success)
    #endif
    NotificationCenter.default.post(
      name: NSNotification.Name("DOLShowSnackbar"),
      object: nil,
      userInfo: ["text": String(format: L("IR Mode: %@"), irModeLabel)]
    )
  }

  private func reconfigureVirtualControllerIfNeeded() {
    // Only applies to Apple virtual layout
    guard (DSUControllerLayout(rawValue: layoutRaw) ?? .appleVirtual) == .appleVirtual else { return }
    // Recreate with new configuration
    stopVirtualController()
    startVirtualController()
  }

  private func bindVirtualControllerHandlers() {
    guard (DSUControllerLayout(rawValue: layoutRaw) ?? .appleVirtual) == .appleVirtual else { return }
    guard let gp = virtualController?.controller?.extendedGamepad else { return }
    // Ensure reports absolute for predictable values
    gp.dpad.valueChangedHandler = nil
    gp.leftThumbstick.valueChangedHandler = nil
    gp.rightThumbstick.valueChangedHandler = nil
    gp.valueChangedHandler = { gamepad, element in
      // Left control: either D-Pad or Left Stick
      if appleLeftIsDPad {
        let dx = gamepad.dpad.xAxis.value
        let dy = gamepad.dpad.yAxis.value
        if element == gamepad.dpad || element == gamepad.dpad.xAxis || element == gamepad.dpad.yAxis {
          DSUServerBridge.setAxis(0, controller: 0, value: dx)
          DSUServerBridge.setAxis(1, controller: 0, value: dy)
        }
      } else {
        if element == gamepad.leftThumbstick || element == gamepad.leftThumbstick.xAxis || element == gamepad.leftThumbstick.yAxis {
          DSUServerBridge.setAxis(0, controller: 0, value: gamepad.leftThumbstick.xAxis.value)
          DSUServerBridge.setAxis(1, controller: 0, value: gamepad.leftThumbstick.yAxis.value)
        }
      }

      // Right stick
      if element == gamepad.rightThumbstick || element == gamepad.rightThumbstick.xAxis || element == gamepad.rightThumbstick.yAxis {
        DSUServerBridge.setAxis(2, controller: 0, value: gamepad.rightThumbstick.xAxis.value)
        DSUServerBridge.setAxis(3, controller: 0, value: gamepad.rightThumbstick.yAxis.value)
      }

      // Triggers (0..1) -> (-1..1)
      if element == gamepad.leftTrigger { DSUServerBridge.setAxis(4, controller: 0, value: (gamepad.leftTrigger.value * 2.0) - 1.0) }
      if element == gamepad.rightTrigger { DSUServerBridge.setAxis(5, controller: 0, value: (gamepad.rightTrigger.value * 2.0) - 1.0) }

      // Face buttons: map A,B,X,Y -> Cross,Circle,Square,Triangle indices 1,2,0,3
      if element == gamepad.buttonA { DSUServerBridge.setButton(1, controller: 0, state: gamepad.buttonA.isPressed) }
      if element == gamepad.buttonB { DSUServerBridge.setButton(2, controller: 0, state: gamepad.buttonB.isPressed) }
      if element == gamepad.buttonX { DSUServerBridge.setButton(0, controller: 0, state: gamepad.buttonX.isPressed) }
      if element == gamepad.buttonY { DSUServerBridge.setButton(3, controller: 0, state: gamepad.buttonY.isPressed) }

      // Push a frame immediately so TX updates promptly
      DSUServerBridge.sendNow()
    }
  }
}

private func publishLayoutTXT(raw: String) {
  let layout = (DSUControllerLayout(rawValue: raw) ?? .appleVirtual)
  switch layout {
  case .gamecube:
    DSUServerBridge.setLayout("gc", extension: nil, sideways: false)
  case .wiiRemote:
    DSUServerBridge.setLayout("wii", extension: nil, sideways: false)
  case .wiiClassic:
    DSUServerBridge.setLayout("wii", extension: "classic", sideways: false)
  case .wiiSideways:
    DSUServerBridge.setLayout("wii", extension: nil, sideways: true)
  case .appleVirtual:
    DSUServerBridge.setLayout("appleVirtual", extension: nil, sideways: false)
  }
}

// MARK: - Subviews

private struct AppleVirtualControllerPlaceholder: View {
  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "gamecontroller.fill").font(.system(size: 48)).foregroundColor(.white.opacity(0.8))
      Text(L("Apple Touch Controller Active"))
        .font(.title2).foregroundColor(.white)
      Text(L("Inputs are being sent over DSU to the connected client."))
        .font(.footnote).foregroundColor(.white.opacity(0.7))
    }
  }
}

private struct MotionQuickSettingsView: View {
  @State private var gain: Double = UserDefaults.standard.object(forKey: "dsu_gyro_gain") as? Double ?? 1.0
  @State private var deadzone: Double = UserDefaults.standard.object(forKey: "dsu_deadzone") as? Double ?? 0.05
  @State private var smoothing: Double = UserDefaults.standard.object(forKey: "dsu_smoothing") as? Double ?? 0.0
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    if #available(iOS 16.0, *) {
      NavigationStack {
        Form {
          Section(header: Text(L("Gyro Gain"))) {
            HStack {
              Slider(value: $gain, in: 0.1...3.0, step: 0.05)
              Text(String(format: "%.2f", gain)).frame(width: 50).monospacedDigit()
            }
          }
          Section(header: Text(L("Deadzone"))) {
            HStack {
              Slider(value: $deadzone, in: 0.0...0.49, step: 0.01)
              Text(String(format: "%.2f", deadzone)).frame(width: 50).monospacedDigit()
            }
          }
          Section(header: Text(L("Smoothing"))) {
            HStack {
              Slider(value: $smoothing, in: 0.0...0.9, step: 0.05)
              Text(String(format: "%.2f", smoothing)).frame(width: 50).monospacedDigit()
            }
          }
        }
        .navigationTitle(L("Motion Settings"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { dismiss() } } }
        .onChange(of: gain) { UserDefaults.standard.set($0, forKey: "dsu_gyro_gain") }
        .onChange(of: deadzone) { UserDefaults.standard.set($0, forKey: "dsu_deadzone") }
        .onChange(of: smoothing) { UserDefaults.standard.set($0, forKey: "dsu_smoothing") }
      }
    } else {
      NavigationView {
        Form {
          Section(header: Text(L("Gyro Gain"))) {
            HStack {
              Slider(value: $gain, in: 0.1...3.0, step: 0.05)
              Text(String(format: "%.2f", gain)).frame(width: 50).monospacedDigit()
            }
          }
          Section(header: Text(L("Deadzone"))) {
            HStack {
              Slider(value: $deadzone, in: 0.0...0.49, step: 0.01)
              Text(String(format: "%.2f", deadzone)).frame(width: 50).monospacedDigit()
            }
          }
          Section(header: Text(L("Smoothing"))) {
            HStack {
              Slider(value: $smoothing, in: 0.0...0.9, step: 0.05)
              Text(String(format: "%.2f", smoothing)).frame(width: 50).monospacedDigit()
            }
          }
        }
        .navigationTitle(L("Motion Settings"))
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { dismiss() } } }
        .onChange(of: gain) { UserDefaults.standard.set($0, forKey: "dsu_gyro_gain") }
        .onChange(of: deadzone) { UserDefaults.standard.set($0, forKey: "dsu_deadzone") }
        .onChange(of: smoothing) { UserDefaults.standard.set($0, forKey: "dsu_smoothing") }
      }
    }
  }
}

// MARK: - Layout Picker

private enum DSUControllerLayout: String, CaseIterable {
  case appleVirtual = "appleVirtual"
  case gamecube = "gamecube"
  case wiiRemote = "wiiRemote"
  case wiiClassic = "wiiClassic"
  case wiiSideways = "wiiSideways"

  var displayName: String {
    switch self {
    case .appleVirtual: return L("Apple Touch Controller")
    case .gamecube: return L("GameCube (NIB)")
    case .wiiRemote: return L("Wii Remote (NIB)")
    case .wiiClassic: return L("Wii Classic (NIB)")
    case .wiiSideways: return L("Wii Sideways (NIB)")
    }
  }
}

private struct LayoutPickerSheet: View {
  @Binding var selectedRaw: String
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    if #available(iOS 16.0, *) {
      NavigationStack {
        List {
          ForEach(DSUControllerLayout.allCases, id: \.rawValue) { opt in
            HStack {
              Text(opt.displayName)
              Spacer()
              if opt.rawValue == selectedRaw { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedRaw = opt.rawValue; dismiss() }
          }
        }
        .navigationTitle(L("Controller Layout"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { dismiss() } } }
      }
    } else {
      NavigationView {
        List {
          ForEach(DSUControllerLayout.allCases, id: \.rawValue) { opt in
            HStack {
              Text(opt.displayName)
              Spacer()
              if opt.rawValue == selectedRaw { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedRaw = opt.rawValue; dismiss() }
          }
        }
        .navigationTitle(L("Controller Layout"))
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { dismiss() } } }
      }
    }
  }
}

// MARK: - NIB Host

private struct TouchControllerNibHost: UIViewControllerRepresentable {
  let layout: DSUControllerLayout

  func makeUIViewController(context: Context) -> TouchControllerHostViewController {
    let vc = TouchControllerHostViewController(layout: layout)
    return vc
  }

  func updateUIViewController(_ uiViewController: TouchControllerHostViewController, context: Context) {
    // no-op
  }
}

private final class TouchControllerHostViewController: UIViewController {
  let layout: DSUControllerLayout
  init(layout: DSUControllerLayout) {
    self.layout = layout
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    // Map to nib name and root class
    let nibName: String
    switch layout {
    case .gamecube: nibName = "TCGameCubePad"
    case .wiiRemote: nibName = "TCWiiPad"
    case .wiiClassic: nibName = "TCClassicWiiPad"
    case .wiiSideways: nibName = "TCSidewaysWiiPad"
    case .appleVirtual:
      assertionFailure("appleVirtual should not create nib host")
      return
    }

    let nib = UINib(nibName: nibName, bundle: .main)
    guard let loaded = nib.instantiate(withOwner: nil, options: nil).first as? UIView else { return }
    loaded.frame = view.bounds
    loaded.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(loaded)

    // If Wii pad, set initial IR mode to match settings
    if let wii = loaded as? TCWiiPad {
      let mode = DOLConfigBridge.mainTouchPadIRMode()
      wii.mode = TCWiiTouchIRMode(rawValue: mode) ?? .none
    }
  }
}

// MARK: - Touch Area Overlay

private struct TouchAreaOverlay: View {
  @State private var touchPoints: [Int: CGPoint] = [:] // touchId -> position

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Semi-transparent touch area background
        Rectangle()
          .fill(Color.white.opacity(0.1))
          .overlay(
            Rectangle()
              .stroke(Color.white.opacity(0.3), lineWidth: 2)
              .overlay(
                Text(L("Touch Area"))
                  .font(.caption)
                  .foregroundColor(.white.opacity(0.6))
                  .padding(4)
                  .background(Color.black.opacity(0.3))
                  .clipShape(RoundedRectangle(cornerRadius: 4))
                  .position(x: geometry.size.width / 2, y: 20)
              )
          )

        // Active touch points
        ForEach(Array(touchPoints.keys), id: \.self) { touchId in
          if let point = touchPoints[touchId] {
            Circle()
              .fill(Color.cyan.opacity(0.6))
              .frame(width: 44, height: 44)
              .position(point)
              .overlay(
                Text("\(touchId + 1)")
                  .font(.caption2.bold())
                  .foregroundColor(.white)
                  .position(point)
              )
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: 200) // Limit height to bottom portion
    .frame(maxHeight: .infinity, alignment: .bottom)
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .local)
        .onChanged { value in
          handleTouchChanged(value)
        }
        .onEnded { value in
          handleTouchEnded(value)
        }
        .simultaneously(with:
          // Support multi-touch
          DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
              handleTouchChanged(value, touchId: 1)
            }
            .onEnded { value in
              handleTouchEnded(value, touchId: 1)
            }
        )
    )
  }

  private func handleTouchChanged(_ value: DragGesture.Value, touchId: Int = 0) {
    let location = value.location
    touchPoints[touchId] = location

    // Convert to DSU touch coordinates (0-1920 x 0-1080)
    // Assume the touch area represents the full DS4 touchpad
    let x = Int(location.x / 300.0 * 1920.0) // Assuming ~300pt wide touch area
    let y = Int(location.y / 200.0 * 1080.0) // Assuming ~200pt tall touch area

    DSUServerBridge.setTouchPoint(touchId, controller: 0, active: true, x: x, y: y)
  }

  private func handleTouchEnded(_ value: DragGesture.Value, touchId: Int = 0) {
    touchPoints.removeValue(forKey: touchId)
    DSUServerBridge.setTouchPoint(touchId, controller: 0, active: false, x: 0, y: 0)
    }
}

#endif
