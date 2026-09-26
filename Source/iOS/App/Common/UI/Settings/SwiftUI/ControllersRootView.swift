// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation

// MARK: - Motion Settings (DSU)

private struct MotionSettingsView: View {
  @State private var gain: Double = UserDefaults.standard.object(forKey: "dsu_gyro_gain") as? Double ?? 1.0
  @State private var deadzone: Double = UserDefaults.standard.object(forKey: "dsu_deadzone") as? Double ?? 0.05
  @State private var smoothing: Double = UserDefaults.standard.object(forKey: "dsu_smoothing") as? Double ?? 0.0
  var body: some View {
    Form {
      Section(header: Text(L("Gyro Gain"))) {
        settingsCaption(
          Group {
#if os(tvOS)
            TVFloatStepper(
              value: Binding(
                get: { CGFloat(gain) },
                set: { gain = Double($0) }
              ),
              range: 0.1...3.0,
              step: 0.05
            )
#else
            HStack {
              Slider(value: $gain, in: 0.1...3.0, step: 0.05)
              Text(String(format: "%.2f", gain)).frame(width: 50).monospacedDigit()
            }
#endif
          },
          L("Scales motion intensity. Higher values increase sensitivity."))
      }
      Section(header: Text(L("Deadzone"))) {
        settingsCaption(
          Group {
#if os(tvOS)
            TVFloatStepper(
              value: Binding(
                get: { CGFloat(deadzone) },
                set: { deadzone = Double($0) }
              ),
              range: 0.0...0.49,
              step: 0.01
            )
#else
            HStack {
              Slider(value: $deadzone, in: 0.0...0.49, step: 0.01)
              Text(String(format: "%.2f", deadzone)).frame(width: 50).monospacedDigit()
            }
#endif
          },
          L("Ignores small movements to reduce jitter."))
      }
      Section(header: Text(L("Smoothing"))) {
        settingsCaption(
          Group {
#if os(tvOS)
            TVFloatStepper(
              value: Binding(
                get: { CGFloat(smoothing) },
                set: { smoothing = Double($0) }
              ),
              range: 0.0...0.9,
              step: 0.05
            )
#else
            HStack {
              Slider(value: $smoothing, in: 0.0...0.9, step: 0.05)
              Text(String(format: "%.2f", smoothing)).frame(width: 50).monospacedDigit()
            }
#endif
          },
          L("Applies exponential smoothing. 0 disables smoothing."))
      }
    }
    .navigationTitle(L("Advanced Motion Settings"))
    .onChange(of: gain) { UserDefaults.standard.set($0, forKey: "dsu_gyro_gain") }
    .onChange(of: deadzone) { UserDefaults.standard.set($0, forKey: "dsu_deadzone") }
    .onChange(of: smoothing) { UserDefaults.standard.set($0, forKey: "dsu_smoothing") }
  }
}

// Convenience initializer for no background
// MARK: - Controllers (single page)

struct ControllersRootView: View {
  @State private var backgroundInput: Bool = false
  @State private var wiimoteScan: Bool = false
  @State private var wiimoteSpeaker: Bool = false
  @State private var connectWiimotes: Bool = false
  @State private var autoSelectOnScreenBySystem: Bool = true
  // DSU client
  @State private var dsuEnabled: Bool = false
  @State private var dsuServers: [[String: Any]] = [] // keys: description, address, port
  @State private var showAddDsuServer: Bool = false
  @State private var newDsuDesc: String = "DS4"
  @State private var newDsuAddr: String = ""
  @State private var newDsuPort: String = "26760"
  @StateObject private var dsuBrowser = DSUDiscoveryBrowser()
  @State private var recentlyAdded: Set<String> = [] // address:port keys
  @AppStorage("dsu_role") private var dsuRole: String = "receiver" // "receiver" or "sender"
  @State private var pingingServerKey: String? = nil

  // Touchscreen
#if os(iOS)
  @State private var touchOpacity: Float = 0.5
  // Programmatic touch overlay (phase 2, beta): see docs/superpowers/specs/
  // 2026-09-24-programmatic-touch-overlay-design.md. Defaults false (DefaultPreferences.plist).
  @State private var touchOverlayProgrammatic: Bool = UserDefaults.standard.bool(forKey: "touch_overlay_programmatic")
  // Phase 3 additions (task item 3). `touchOverlayStyle` is the raw `TouchOverlayArt.Style`
  // UserDefaults integer, not the enum itself — the Picker below just needs the raw tags.
  @State private var touchOverlayStyle: Int = UserDefaults.standard.integer(forKey: "touch_overlay_style")
  @State private var showTouchOverlayEditor = false
  @State private var touchOverlayEditorPadKind: TouchOverlayPadKind = .gameCube
  @State private var showTouchOverlayIRAreaEditor = false
  /// Drag-mode IR pointer sensitivity gain (task item 1): a NEW setting — neither the legacy
  /// `TCWiiPad` drag math nor gyro mode (`TCDeviceMotion.handleIRCursorMapping`'s hardcoded
  /// 2.66/2.0) exposed a user-facing gain to reuse, despite this feature's original design doc
  /// (docs/superpowers/specs/2026-09-24-programmatic-touch-overlay-design.md §7) assuming one
  /// already existed. See `TouchOverlayIRGeometry.clampDragGain`/`.drag` for why this only
  /// affects Drag mode, never Follow (absolute) or gyro mode.
  @State private var touchOverlayIRPointerGain: Double = UserDefaults.standard.double(forKey: "touch_overlay_ir_pointer_gain")
#endif
  @State private var touchIRMode: TouchIRMode = .drag
  // Raw SerialInterface::SIDevices values (SI_Device.h): 0 = SIDEVICE_NONE,
  // 6 = SIDEVICE_GC_CONTROLLER. The enum is NOT sequential (1-5 are N64/GBA
  // devices), so the GC Controller value is 6, not 1.
  @State private var gcPortDevices: [Int] = [0, 0, 0, 0]
  // Raw WiimoteSource values (Wiimote.h): 0 None, 1 Emulated, 2 Real.
  @State private var wiiSources: [Int] = [0, 0, 0, 0]

  var body: some View {
    List {
      // Unified controller surface (Players + Connected + Global), shared with
      // the Pause menu. Embedded here as raw Sections so this view can keep its
      // own DSU Client + Alternate Input Sources sections below.
      ControllerSetupView(system: .both).sections

      // DSU Client
      Section(
        header: HStack {
          Text("DSU Client")
          if !dsuBrowser.servers.isEmpty {
            Text("\(dsuBrowser.servers.count) \(dsuBrowser.servers.count == 1 ? L("found") : L("found"))")
              .font(.caption)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.blue.opacity(0.15), in: Capsule())
          }
        }
      ) {
        #if !os(tvOS)
        settingsCaption(
          Picker(L("Role"), selection: $dsuRole) {
            Text(L("Receiver")).tag("receiver")
            Text(L("Sender")).tag("sender")
          }
          .onChange(of: dsuRole) { role in
            if role == "sender" {
              dsuEnabled = false
              DOLConfigBridge.setDsuClientEnabled(false)
            }
          },
          L("Receiver pulls motion/input from a DSU server; Sender shares this device's input instead."))
        #endif
        settingsCaption(
          Toggle(L("Enable DSU Client"), isOn: $dsuEnabled)
            .onChange(of: dsuEnabled) { DOLConfigBridge.setDsuClientEnabled($0) }
            .disabled(dsuRole == "sender"),
          L("Receives input from a Cemuhook DSU server on your network (e.g. a phone's gyro). Add servers below as IP:Port."))
        Toggle(L("Show DSU Debug HUD"), isOn: Binding(get: {
#if DEBUG
          true
#else
          UserDefaults.standard.bool(forKey: "ui_show_dsu_debug_hud")
#endif
        }, set: { v in
#if DEBUG
          // Always on in DEBUG; ignore writes
#else
          UserDefaults.standard.set(v, forKey: "ui_show_dsu_debug_hud")
#endif
        }))
        Toggle(L("Map IR (Gyro) to DSU Touch"), isOn: Binding(get: {
          UserDefaults.standard.bool(forKey: "dsu_map_ir_to_touch")
        }, set: { v in
          UserDefaults.standard.set(v, forKey: "dsu_map_ir_to_touch")
          NotificationCenter.default.post(name: Notification.Name("DOLMotionSettingsChanged"), object: nil)
        }))
        Toggle(L("Send DSU Gyro/Accel"), isOn: Binding(get: {
          let has = UserDefaults.standard.object(forKey: "dsu_enable_gyro") != nil
          return has ? UserDefaults.standard.bool(forKey: "dsu_enable_gyro") : true
        }, set: { v in
          UserDefaults.standard.set(v, forKey: "dsu_enable_gyro")
        }))
        if dsuServers.isEmpty {
          HStack {
            Text(L("Servers"))
            Spacer()
            Text(L("None")).foregroundStyle(.secondary)
          }
        } else {
          ForEach(0..<dsuServers.count, id: \.self) { idx in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(dsuServerTitle(idx))
                Text(dsuServerAddressPort(idx)).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              let addr = (dsuServers[idx]["address"] as? String) ?? ""
              let sanAddr: String = {
                let trimmed = addr.trimmingCharacters(in: .whitespacesAndNewlines)
                if let at = trimmed.firstIndex(of: "@") { return String(trimmed[..<at]) } else { return trimmed }
              }()
              let port = (dsuServers[idx]["port"] as? NSNumber)?.intValue ?? 26760
              let key = "\(sanAddr):\(port)"
              if pingingServerKey == key {
                ProgressView().padding(.vertical, 4)
              } else {
                Button {
                  // Enlarge hit target and give quick feedback
                  pingingServerKey = key
                  NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Pinging %@…"), key)])
                  #if DEBUG
                  print("[DSU-PING] tapping Test for \(key)")
                  #endif
                  DSUPingBridge.pingServerAddress(sanAddr, port: port, timeout: 1.0) { ok, info in
                    pingingServerKey = nil
                    let msg = ok ? String(format: L("Reachable: %@"), info ?? key) : L("No response")
                    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": msg])
                  }
                } label: {
                  Label(L("Test"), systemImage: "paperplane")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 72)
                }
                .buttonStyle(.bordered)
                #if !os(tvOS)
                .controlSize(.regular)
                #endif
                .padding(.vertical, 4)
              }
            }
            #if !os(tvOS)
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                DOLConfigBridge.removeDsuServer(at: idx)
                refreshDsuServers()
              } label: { Label(L("Delete"), systemImage: "trash") }
            }
            #else
            // TODO: TVOS Deletion @JoeMatt
            #endif // !os(tvOS)
          }
        }
        Button(action: { newDsuDesc = "DS4"; newDsuAddr = ""; newDsuPort = "26760"; showAddDsuServer = true }) {
          Label(L("Add Server"), systemImage: "plus")
        }

        NavigationLink(destination: MotionSettingsView()) {
          Label(L("Advanced Motion Settings"), systemImage: "gyroscope")
        }
      }

      if !dsuBrowser.servers.isEmpty {
        Section(header: Text(L("Discovered on Network"))) {
          ForEach(dsuBrowser.servers) { s in
            let key = "\(s.address):\(s.port)"
            let isSaved = dsuServers.contains { server in
              ((server["address"] as? String) == s.address) && ((server["port"] as? NSNumber)?.intValue == s.port)
            }
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                  Text(s.name)
                  if recentlyAdded.contains(key) {
                    Text(L("New"))
                      .font(.caption2)
                      .padding(.horizontal, 6).padding(.vertical, 2)
                      .background(Color.green.opacity(0.15), in: Capsule())
                  }
                }
                Text(key).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if isSaved {
                Text(L("Saved"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 8).padding(.vertical, 4)
                  .background(Color.blue.opacity(0.1), in: Capsule())
              } else {
                Button(L("Add")) {
                  let trimmed = s.address.trimmingCharacters(in: .whitespacesAndNewlines)
                  let addr = (trimmed.firstIndex(of: "@").map { String(trimmed[..<$0]) } ) ?? trimmed
                  DOLConfigBridge.addDsuServer(s.name, address: addr, port: s.port)
                  refreshDsuServers()
                  recentlyAdded.insert(key)
                  NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Added DSU server: %@"), key)])
                }
                .buttonStyle(.bordered)
              }
            }
          }
        }
      }

      // NOTE: Background Input, Continuous Scanning, Enable Speaker, and the
      // master "Connect MFi Controllers" toggle now live in the unified
      // ControllerSetupView sections above (relocated from here / the Debug tab).
      Section(header: Text(L("General"))) {
        settingsCaption(
          Toggle(L("Auto‑select On‑Screen Controller by System"), isOn: $autoSelectOnScreenBySystem)
            .onChange(of: autoSelectOnScreenBySystem) { newValue in UserDefaults.standard.set(newValue, forKey: "auto_touchpad_by_system") },
          L("Automatically shows the GameCube or Wii on-screen layout based on the game being played."))

#if os(iOS)
        Button(action: { testRumble() }) {
          Label(L("Test Rumble"), systemImage: "waveform")
        }
#endif
      }

      Section(header: Text(L("Wii Remotes"))) {
        settingsCaption(
          Toggle(L("Connect Wiimotes for Controller Interface"), isOn: $connectWiimotes)
            .onChange(of: connectWiimotes) { newValue in DOLConfigBridge.setConnectWiimotesForControllerInterface(newValue) },
          L("Automatically pairs Wii Remotes when the controller interface is in use."))
      }

      Section(header: Text(L("Alternate Input Sources"))) {
#if os(iOS)
        settingsCaption(
          HStack {
            Text(L("Opacity"))
            Spacer()
            Slider(value: Binding(get: { Double(touchOpacity) }, set: { touchOpacity = Float($0) }), in: 0...1)
              .frame(width: 220)
              .onChange(of: touchOpacity) { DOLConfigBridge.setMainTouchPadOpacity($0) }
          },
          L("Transparency of the on-screen touch controls."))
#endif
        settingsNavCaption(
          destination: TouchIRModePicker(selected: $touchIRMode),
          L("How the Wii Remote pointer is driven. Gyro uses device motion; Follow/Drag use touch gestures.")
        ) {
          Text("\(L("Touch IR Pointer")): \(touchIRMode.label)")
        }
        .onChange(of: touchIRMode) { DOLConfigBridge.setMainTouchPadIRMode($0.rawValue) }

#if os(iOS)
        settingsCaption(
          Toggle(L("Programmatic touch overlay (beta)"), isOn: $touchOverlayProgrammatic)
            .onChange(of: touchOverlayProgrammatic) { newValue in
              UserDefaults.standard.set(newValue, forKey: "touch_overlay_programmatic")
            },
          L("Replaces the on-screen GameCube/Wii pads with the new SwiftUI-rendered, user-editable overlay. Long-press the overlay in-game to move or resize its controls."))

        settingsCaption(
          Picker(L("Overlay Style"), selection: $touchOverlayStyle) {
            Text(L("Auto")).tag(0)
            Text(L("GameCube")).tag(1)
            Text(L("Wii")).tag(2)
          }
          .pickerStyle(.segmented)
          .onChange(of: touchOverlayStyle) { newValue in UserDefaults.standard.set(newValue, forKey: "touch_overlay_style") },
          L("Overrides whether the programmatic overlay's button art uses GameCube or Wii coloring, or matches the pad kind automatically."))

        Button {
          touchOverlayEditorPadKind = .gameCube
          showTouchOverlayEditor = true
        } label: {
          Label(L("Edit Layout…"), systemImage: "rectangle.and.pencil.and.ellipsis")
        }

        Button(role: .destructive) {
          for kind in TouchOverlayPadKind.allCases { TouchOverlayLayoutStore.shared.reset(padKind: kind) }
        } label: {
          Label(L("Reset All Overlay Layouts"), systemImage: "arrow.counterclockwise")
        }

        // Task item 1's three new rows — gated on the beta flag (unlike Style/Edit Layout/Reset
        // above, which apply even with the flag off since they only touch stored settings, not
        // live rendering). Opacity is intentionally NOT duplicated here: it already exists, and
        // already applies to this overlay, via the generic "Opacity" slider above
        // (`DOLConfigBridge.mainTouchPadOpacity`/`setMainTouchPadOpacity`, read by
        // `TouchOverlayView` through `TouchOverlayInput.resolvedOpacity`).
        if touchOverlayProgrammatic {
          Button {
            showTouchOverlayIRAreaEditor = true
          } label: {
            Label(L("Edit IR Area…"), systemImage: "scope")
          }

          settingsCaption(
            HStack {
              Text(L("Pointer Sensitivity"))
              Spacer()
              Slider(value: $touchOverlayIRPointerGain, in: Double(TouchOverlayIRGeometry.dragGainRange.lowerBound)...Double(TouchOverlayIRGeometry.dragGainRange.upperBound))
                .frame(width: 220)
                .onChange(of: touchOverlayIRPointerGain) { UserDefaults.standard.set($0, forKey: "touch_overlay_ir_pointer_gain") }
            },
            L("Scales how far the Wii Remote pointer moves per drag in Drag mode. Doesn't affect Follow or Gyro mode."))
        }
#endif

        NavigationLink(destination: EnhancedMotionControlsView()) {
          Label(L("Advanced Motion Settings"), systemImage: "gyroscope")
        }
      }
    }
    .navigationTitle(L("Controllers"))
    .onAppear {
      syncFromConfig()
      syncPortTypes()
      ensureDefaultGCPlayer1()
      if UserDefaults.standard.object(forKey: "auto_touchpad_by_system") == nil {
        UserDefaults.standard.set(true, forKey: "auto_touchpad_by_system")
      }
      autoSelectOnScreenBySystem = UserDefaults.standard.bool(forKey: "auto_touchpad_by_system")
      dsuBrowser.start()
    }
    .onDisappear { dsuBrowser.stop() }
#if os(iOS)
    .sheet(isPresented: $showTouchOverlayEditor) {
      TouchOverlayLayoutEditorSheet(padKind: $touchOverlayEditorPadKind)
    }
    .sheet(isPresented: $showTouchOverlayIRAreaEditor) {
      TouchOverlayIRAreaEditorSheet()
    }
#endif
    .sheet(isPresented: $showAddDsuServer) {
      NavigationStack {
        Form {
          Section(header: Text(L("Description"))) {
            TextField("DS4", text: $newDsuDesc)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
          }
          Section(header: Text(L("Server Address"))) {
            TextField("192.168.1.100", text: $newDsuAddr)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .keyboardType(.numbersAndPunctuation)
          }
          Section(header: Text(L("Port"))) {
            TextField("26760", text: $newDsuPort)
              .keyboardType(.numberPad)
          }
        }
        .navigationTitle("Add DSU Server")
        .toolbar {
          ToolbarItem(placement: .topBarLeading) { Button(L("Cancel")) { showAddDsuServer = false } }
          ToolbarItem(placement: .topBarTrailing) {
            Button(L("Add")) {
              let port = Int(newDsuPort) ?? 26760
              DOLConfigBridge.addDsuServer(newDsuDesc, address: newDsuAddr, port: port)
              refreshDsuServers()
              showAddDsuServer = false
            }.disabled(newDsuAddr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }
  }

  private func syncFromConfig() {
    backgroundInput = DOLConfigBridge.mainBackgroundInput()
    wiimoteScan = DOLConfigBridge.wiimoteContinuousScanning()
    wiimoteSpeaker = DOLConfigBridge.wiimoteEnableSpeaker()
    connectWiimotes = DOLConfigBridge.connectWiimotesForControllerInterface()
#if os(iOS)
    touchOpacity = DOLConfigBridge.mainTouchPadOpacity()
    touchOverlayProgrammatic = UserDefaults.standard.bool(forKey: "touch_overlay_programmatic")
    touchOverlayStyle = UserDefaults.standard.integer(forKey: "touch_overlay_style")
    touchOverlayIRPointerGain = Double(TouchOverlayIRGeometry.clampDragGain(UserDefaults.standard.double(forKey: "touch_overlay_ir_pointer_gain")))
#endif
    touchIRMode = TouchIRMode.from(raw: DOLConfigBridge.mainTouchPadIRMode())
    // DSU
    dsuEnabled = DOLConfigBridge.dsuClientEnabled()
    refreshDsuServers()
  }

  private func refreshDsuServers() {
    let arr: [[String: Any]] = DOLConfigBridge.dsuServersParsed() ?? []
    dsuServers = arr
  }

  private func dsuServerTitle(_ idx: Int) -> String {
    if idx < 0 || idx >= dsuServers.count { return "Server \(idx+1)" }
    let desc = (dsuServers[idx]["description"] as? String) ?? ""
    let addrPort = dsuServerAddressPort(idx)
    if desc.isEmpty {
      return addrPort.isEmpty ? "Server \(idx+1)" : addrPort
    } else {
      return addrPort.isEmpty ? desc : "\(desc) — \(addrPort)"
    }
  }

  private func dsuServerAddressPort(_ idx: Int) -> String {
    if idx < 0 || idx >= dsuServers.count { return "" }
    let addr = (dsuServers[idx]["address"] as? String) ?? ""
    let port = (dsuServers[idx]["port"] as? NSNumber)?.intValue ?? 0
    return port > 0 ? "\(addr):\(port)" : addr
  }

  private func syncPortTypes() {
    for i in 0..<4 {
      gcPortDevices[i] = DOLConfigBridge.gcPortDevice(forPort: i + 1)
      wiiSources[i] = DOLConfigBridge.wiimoteSource(for: i + 1)
    }
  }

  // If all GC ports are None, default Player 1 to a GameCube Controller
  // (SIDEVICE_GC_CONTROLLER == 6).
  private func ensureDefaultGCPlayer1() {
    if gcPortDevices.allSatisfy({ $0 == 0 }) {
      DOLConfigBridge.setGCPortDeviceForPort(1, device: 6)
      gcPortDevices[0] = 6
    }
  }

  private func localizedSIDevice(_ device: Int) -> String {
    switch device {
    case 0: return L("<Nothing>")
    case 6: return L("GameCube Controller") // SIDEVICE_GC_CONTROLLER
    default: return L("Unknown")
    }
  }

  private func localizedWiimoteSource(_ source: Int) -> String {
    switch source {
    case 0: return L("<Nothing>")
    case 1: return L("Emulated Wii Remote")
    default: return L("Unknown")
    }
  }

#if os(iOS)
  /// Test rumble/haptic feedback on device and connected controllers
  func testRumble() {
    var controllersTestedCount = 0
    var deviceTested = false
    #if canImport(GameController)
    // Test ALL connected external controller haptics
    let controllers = GCController.controllers()
    if #available(iOS 14.0, tvOS 14.0, * ) {
      for controller in controllers {
        if let haptics = controller.haptics {
          do {
            let engine = try haptics.createEngine(withLocality: .default)
            try engine?.start()
            // Simple transient pulse
            let pattern = try CHHapticPattern(events: [
              CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
              ], relativeTime: 0)
            ], parameters: [])
            if let engine = engine {
              let player = try engine.makePlayer(with: pattern)
              try player.start(atTime: 0)
              controllersTestedCount += 1
            }
          } catch {
          }
        }
      }
    }
    #endif
    #if canImport(CoreHaptics)
    if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
      do {
        let engine = try CHHapticEngine()
        try engine.start()
        let pattern = try CHHapticPattern(events: [
          CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
          ], relativeTime: 0)
        ], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        deviceTested = true
      } catch {
      }
    }
    #endif
    let message: String
    if controllersTestedCount > 0 && deviceTested {
      message = String(format: L("Tested %d controller(s) + device rumble"), controllersTestedCount)
    } else if controllersTestedCount > 0 {
      message = String(format: L("Tested %d controller(s) rumble"), controllersTestedCount)
    } else if deviceTested {
      message = L("Tested device rumble")
    } else {
      message = L("No haptic feedback available")
    }
    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": message])
  }

  private func mfiControllerTitle(_ controller: GCController, index: Int) -> String {
    // Prefer the product category (e.g., "Gamepad", "DualSense") when available
    let category = controller.productCategory
    if !category.isEmpty { return category }
    if let vendor = controller.vendorName, !vendor.isEmpty { return vendor }
    return "Controller"
  }

  private func mfiControllerDetail(_ controller: GCController) -> String {
    // Compose a stable short identifier to disambiguate same-model controllers
    let ptr = Unmanaged.passUnretained(controller).toOpaque()
    let hex = String(format: "%p", Int(bitPattern: ptr))
    let shortId = hex.count > 4 ? String(hex.suffix(4)) : hex
    let vendor = controller.vendorName ?? ""
    let category = controller.productCategory
    var parts: [String] = []
    if !vendor.isEmpty { parts.append(vendor) }
    if !category.isEmpty { parts.append(category) }
    parts.append(shortId)
    return parts.joined(separator: " · ")
  }
#endif
}

enum TouchIRMode: Int, CaseIterable { case gyro = 0, follow = 1, drag = 2
  var label: String { switch self { case .gyro: return L("Gyro"); case .follow: return L("Follow"); case .drag: return L("Drag") } }
  static func from(raw: Int) -> TouchIRMode { TouchIRMode(rawValue: raw) ?? .drag }
}

struct TouchIRModePicker: View {
  @Binding var selected: TouchIRMode
  var body: some View {
    List {
      ForEach(Array(TouchIRMode.allCases.enumerated()), id: \.offset) { _, value in
        SettingsSelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setMainTouchPadIRMode(value.rawValue) }
      }
    }
    .navigationTitle(L("Touch IR Pointer"))
  }
}

#if os(iOS)
/// The Settings "Edit Layout…" preview (task item 3): opens the programmatic overlay already in
/// `.layout` edit mode, with no live game/device context. `TouchOverlayView.init(initialEditMode:)`
/// makes this safe — every group's input is suppressed while any edit mode is active, so nothing
/// here can reach `TCManagerInterface` through the ordinary button/D-pad/stick paths regardless of
/// the placeholder `deviceId`. There's no live game to infer the current Wii variant
/// (Classic/sideways/upright) from outside a running emulation session, so the picker lets the
/// user choose which of the four pad kinds to edit directly.
///
/// `irMode: .none` (task item 2's DSU pass) rather than the live `DOLConfigBridge.
/// mainTouchPadIRMode()`: `TouchOverlayIRPadView`'s `mode`/`isEditingFlag` `didSet`s both call
/// `forceReleaseAndCenter()` on mount (a legitimate "recenter on mode change" behavior during real
/// play), but mounting THIS preview with any mode other than `.none` fired that write twice in a
/// row to the placeholder `deviceId: 0` purely from `updateUIView`'s property-assignment order —
/// contradicting this comment's own former claim that nothing here reaches `TCManagerInterface`.
/// `.none` makes both call sites true no-ops (`sendIR`'s own `mode != .none` guard).
struct TouchOverlayLayoutEditorSheet: View {
  @Binding var padKind: TouchOverlayPadKind
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker(L("Layout"), selection: $padKind) {
          Text(L("GameCube")).tag(TouchOverlayPadKind.gameCube)
          Text(L("Wii Remote")).tag(TouchOverlayPadKind.wiiRemote)
          Text(L("Wii Remote (Sideways)")).tag(TouchOverlayPadKind.wiiRemoteSideways)
          Text(L("Wii + Classic Controller")).tag(TouchOverlayPadKind.wiiClassic)
        }
        .pickerStyle(.segmented)
        .padding()

        TouchOverlayView(padKind: padKind, deviceId: 0,
                         irMode: TCWiiTouchIRMode.none.rawValue, initialEditMode: .layout)
          .id(padKind)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black.opacity(0.85))
      }
      .navigationTitle(L("Edit Layout"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(L("Close")) { dismiss() }
        }
      }
    }
  }
}

/// The Settings "Edit IR Area…" preview (task item 1): opens the SAME `TouchOverlayView` the
/// "Edit Layout…" sheet above does, seeded into `.irArea` mode instead of `.layout` — see
/// `TouchOverlayEditMode`'s doc comment for why a single enum, not a second independent flag,
/// is what actually satisfies design §9's "entering IR-area edit disables layout edit and vice
/// versa": there is exactly one edit mode active per sheet, so the two can't overlap. Forces
/// `padKind: .wiiRemote` with no picker, unlike the layout sheet — `wiiIRPad` (the only group
/// `.irArea` mode ever shows chrome for) exists ONLY in that one pad kind's default layout
/// (`TouchOverlayDefaults.wiiRemote`), so a picker offering the other three would just open an
/// editor with nothing editable in it.
struct TouchOverlayIRAreaEditorSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      // `irMode: .none` for the same reason as `TouchOverlayLayoutEditorSheet` above — this
      // preview has no live game/device context, so nothing should reach `TCManagerInterface`.
      TouchOverlayView(padKind: .wiiRemote, deviceId: 0,
                       irMode: TCWiiTouchIRMode.none.rawValue, initialEditMode: .irArea)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
        .navigationTitle(L("Edit IR Area"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button(L("Close")) { dismiss() }
          }
        }
    }
  }
}
#endif
