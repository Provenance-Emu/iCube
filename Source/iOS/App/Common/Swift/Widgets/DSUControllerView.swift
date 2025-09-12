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
    }
    .onAppear { refreshIRLabel() }
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
        Button(action: onClose) { Label(L("Exit"), systemImage: "xmark") }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showMotionSheet) { MotionQuickSettingsView() }
    .sheet(isPresented: $showLayoutSheet) { LayoutPickerSheet(selectedRaw: $layoutRaw) }
    .onChange(of: layoutRaw) { _ in reconfigureVirtualControllerIfNeeded() }
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
#endif
