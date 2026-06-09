// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreHaptics
import GameController
import SwiftUI
import UIKit

/// System filter for `ControllerSetupView`. Distinct from `EmulatedSystem`
/// (which the assignment service switches on exhaustively) so `.both` can never
/// leak into the service. Each row maps back to a concrete `EmulatedSystem`.
enum ControllerSetupSystem {
  case gamecube
  case wii
  case both

  var showsGameCube: Bool { self == .gamecube || self == .both }
  var showsWii: Bool { self == .wii || self == .both }
}

/// The single shared controller-setup surface, hosted by both Settings
/// (`ControllersRootView`, `system: .both`) and the Pause menu
/// (`system:` the running game's system).
///
/// Choosing a physical device in a Player row routes through
/// `ControllerManager.shared`, which activates the port + binds + applies the
/// device-default profile atomically (Phase 1 service) and then reconciles +
/// posts the change notification — so there is no separate "Type" step and
/// Settings vs. Pause produce identical mappings.
///
/// The body is platform-agnostic (List / Picker / Toggle / the existing
/// `ControllersMappingView` representable all compile on iOS and tvOS). Hosts
/// that need extra sections (Settings keeps DSU Client + Alternate Input
/// Sources) embed `sections` in their own `List` instead of using `body`.
/// Thin host wrapper. The Pause menu renders this directly (`body` wraps the
/// sections in its own `List`); Settings embeds `sections` into its own `List`.
///
/// `sections` returns `ControllerSetupSections` — a real `View` node — rather
/// than inlined section content. This is required for correctness: a host that
/// accesses `.sections` on a transient `ControllerSetupView` value would never
/// give that value's `@State` a managed storage node, so its refresh state
/// (connected controllers, qualifiers) would stay empty. Wrapping the stateful
/// content in its own view guarantees the state is owned by the tree in both
/// hosting paths.
struct ControllerSetupView: View {
  let system: ControllerSetupSystem

  init(system: ControllerSetupSystem) {
    self.system = system
  }

  var sections: some View { ControllerSetupSections(system: system) }

  var body: some View {
    List { sections }
      .navigationTitle(L("Controllers"))
  }
}

struct ControllerSetupSections: View {
  let system: ControllerSetupSystem

  init(system: ControllerSetupSystem) {
    self.system = system
  }

  // Per-port (1-based) bound device qualifiers, refreshed from the bridges.
  @State private var gcQualifiers: [Int: String] = [:]
  @State private var wiiQualifiers: [Int: String] = [:]
  // Per-Wiimote (0-based) extension (0 None, 1 Nunchuk, 2 Classic) + sideways.
  @State private var wiiExtension: [Int] = [0, 0, 0, 0]
  @State private var wiiSideways: [Bool] = [false, false, false, false]
  // Live connected-controller list.
  @State private var controllers: [GCController] = []

  // Profile sheet drivers (1-based port).
  @State private var showProfileForGCPort: Int?
  @State private var showProfileForWiimote: Int?
  @State private var gcProfiles: [String] = []
  @State private var wiiProfiles: [String] = []

  // Button-mapping drill-in driver. isGC + 1-based port.
  @State private var mappingTarget: MappingTarget?

  // Global section toggles.
  @AppStorage("virtual_mfi_connect") private var mfiConnect: Bool = false
  @State private var backgroundInput: Bool = false
  @State private var wiimoteScan: Bool = false
  @State private var wiimoteSpeaker: Bool = false

  /// Rumble destination preference, honored by the core rumble path (`Motor`).
  /// 0 = device haptics, 1 = controller rumble, 2 = both. tvOS has no device to
  /// hold, so the option is hidden there and the core forces controller rumble.
  @AppStorage("rumble_destination") private var rumbleDestination: Int = 1
  /// Retains the transient haptic engines spun up by "Identify controller" so
  /// they outlive the call and finish their pulse before being torn down.
  @State private var identifyEngines: [CHHapticEngine] = []

  private struct MappingTarget: Identifiable {
    let isGC: Bool
    let portOneBased: Int
    var id: String { "\(isGC ? "gc" : "wii")-\(portOneBased)" }
  }

  // Device-picker selection tags. Touchscreen / a connected controller / None.
  private enum DeviceTag: Hashable {
    case none
    case touchscreen
    case controller(String) // qualifier
  }

  /// The controller sections. This view is embedded directly into a host `List`,
  /// so its `@State` is owned by the tree in both hosting paths.
  ///
  /// The data-refresh lifecycle (`onAppear` / device + assignment notifications)
  /// and the mapping/profile sheets are attached to the always-present
  /// "Connected Controllers" section. Attaching to a single concrete `Section`
  /// (not a `Group`, whose modifiers would propagate to every child) keeps a
  /// single `onAppear` and one instance of each sheet.
  @ViewBuilder
  var body: some View {
    if system.showsGameCube {
      Section(header: Text(L("GameCube Controllers"))) {
        ForEach(1 ... 4, id: \.self) { port in
          gcPlayerRow(port)
        }
      }
    }

    if system.showsWii {
      Section(header: Text(L("Wii Remotes"))) {
        ForEach(1 ... 4, id: \.self) { w in
          wiiPlayerRow(w)
        }
      }
    }

    Section(header: Text(L("Connected Controllers"))) {
      if controllers.isEmpty {
        Text(L("No controllers connected")).foregroundStyle(.secondary)
      } else {
        ForEach(Array(controllers.enumerated()), id: \.offset) { _, c in
          connectedRow(c)
        }
      }
    }
    .onAppear { reloadAll() }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reloadDevices() }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reloadDevices() }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TVControllerDevicesChangedNotification"))) { _ in reloadDevices() }
    .onReceive(NotificationCenter.default.publisher(for: ControllerManager.assignmentsChanged)) { _ in reloadQualifiers() }
    .sheet(item: $mappingTarget) { target in
      NavigationStack {
        ControllersMappingView(isGC: target.isGC, portOneBased: target.portOneBased)
          .navigationTitle(L("Customize Buttons"))
          #if os(iOS)
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { mappingTarget = nil } } }
          #endif
      }
    }
    .sheet(isPresented: Binding(get: { showProfileForGCPort != nil }, set: { if !$0 { showProfileForGCPort = nil } })) {
      profileSheet(profiles: gcProfiles, title: L("GC Profiles")) { name in
        if let port = showProfileForGCPort {
          _ = TVControllerMappingBridge.loadProfile(name, forGCPort: port, restoreDevice: true)
          ControllerManager.shared.reconcile()
          reloadQualifiers()
        }
        showProfileForGCPort = nil
      }
    }
    .sheet(isPresented: Binding(get: { showProfileForWiimote != nil }, set: { if !$0 { showProfileForWiimote = nil } })) {
      profileSheet(profiles: wiiProfiles, title: L("Wiimote Profiles")) { name in
        if let w = showProfileForWiimote {
          _ = TVControllerMappingBridge.loadProfile(name, forWiimote: w, restoreDevice: true)
          ControllerManager.shared.reconcile()
          NotificationCenter.default.post(name: Notification.Name("DOLWiiOverlayLayoutChangedNotification"), object: nil)
          reloadQualifiers()
        }
        showProfileForWiimote = nil
      }
    }

    Section(header: Text(L("General"))) {
      Toggle(L("Connect MFi Controllers"), isOn: $mfiConnect)
      Toggle(L("Background Input"), isOn: $backgroundInput)
        .onChange(of: backgroundInput) { DOLConfigBridge.setMainBackgroundInput($0) }
      #if os(iOS)
      Picker(L("Rumble Output"), selection: $rumbleDestination) {
        Text(L("Device Haptics")).tag(0)
        Text(L("Controller")).tag(1)
        Text(L("Both")).tag(2)
      }
      #endif
    }

    if system.showsWii {
      Section(header: Text(L("Wii Remotes (Global)"))) {
        Toggle(L("Continuous Scanning"), isOn: $wiimoteScan)
          .onChange(of: wiimoteScan) { DOLConfigBridge.setWiimoteContinuousScanning($0) }
        Toggle(L("Enable Speaker"), isOn: $wiimoteSpeaker)
          .onChange(of: wiimoteSpeaker) { DOLConfigBridge.setWiimoteEnableSpeaker($0) }
      }
    }
  }

  // MARK: Player rows

  @ViewBuilder
  private func gcPlayerRow(_ port: Int) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      devicePicker(
        label: String(format: L("Player %d"), port),
        current: gcQualifiers[port] ?? "",
        onSelect: { tag in applyGC(tag, port: port) }
      )
      HStack {
        Button(L("Profiles…")) {
          gcProfiles = TVControllerMappingBridge.profiles(forGCPort: port)
          showProfileForGCPort = port
        }
        .padding(.vertical, 8)
        Spacer()
        Button(L("Customize Buttons…")) { mappingTarget = MappingTarget(isGC: true, portOneBased: port) }
          .padding(.vertical, 8)
      }
      .font(.caption)
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private func wiiPlayerRow(_ w: Int) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      devicePicker(
        label: String(format: L("Wii Remote %d"), w),
        current: wiiQualifiers[w] ?? "",
        onSelect: { tag in applyWii(tag, wiimote: w) }
      )
      Picker(L("Extension"), selection: Binding(
        get: { wiiExtension[w - 1] },
        set: { v in
          wiiExtension[w - 1] = v
          DOLWiimoteBridge.setExtensionForWiimote(w - 1, extension: v)
          ControllerManager.shared.reconcile()
          NotificationCenter.default.post(name: Notification.Name("DOLWiiOverlayLayoutChangedNotification"), object: nil)
        }
      )) {
        Text(L("None")).tag(0)
        Text(L("Nunchuk")).tag(1)
        Text(L("Classic")).tag(2)
      }
      .pickerStyle(.segmented)

      Toggle(L("Sideways"), isOn: Binding(
        get: { wiiSideways[w - 1] },
        set: { v in
          wiiSideways[w - 1] = v
          DOLWiimoteBridge.setSidewaysForWiimote(w - 1, enabled: v)
          ControllerManager.shared.reconcile()
          NotificationCenter.default.post(name: Notification.Name("DOLWiiOverlayLayoutChangedNotification"), object: nil)
        }
      ))

      HStack {
        Button(L("Profiles…")) {
          wiiProfiles = TVControllerMappingBridge.profiles(forWiimote: w)
          showProfileForWiimote = w
        }
        .padding(.vertical, 8)
        Spacer()
        Button(L("Customize Buttons…")) { mappingTarget = MappingTarget(isGC: false, portOneBased: w) }
          .padding(.vertical, 8)
      }
      .font(.caption)
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 6)
  }

  /// A Device picker: Touchscreen / each connected controller (by friendly
  /// name) / None. Selecting a physical device auto-activates the port.
  @ViewBuilder
  private func devicePicker(label: String, current: String, onSelect: @escaping (DeviceTag) -> Void) -> some View {
    let selection = tag(forQualifier: current)
    Picker(label, selection: Binding(get: { selection }, set: { onSelect($0) })) {
      Text(L("None")).tag(DeviceTag.none)
      Text(L("Touchscreen")).tag(DeviceTag.touchscreen)
      ForEach(Array(controllers.enumerated()), id: \.offset) { _, c in
        let q = TVControllerMappingBridge.qualifiedName(for: c) as String
        Text(friendlyName(c)).tag(DeviceTag.controller(q))
      }
    }
  }

  @ViewBuilder
  private func connectedRow(_ c: GCController) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: "gamecontroller").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(friendlyName(c))
          Text(c.productCategory).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if #available(iOS 14.0, tvOS 14.0, *), let battery = c.battery, battery.batteryLevel >= 0 {
          Text("\(Int((battery.batteryLevel * 100).rounded()))%")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text("P\(c.playerIndex.rawValue + 1)").font(.caption).foregroundStyle(.secondary)
      }

      HStack(spacing: 16) {
        Button(L("Identify")) { identify(c) }
        #if os(iOS)
        if #available(iOS 14.0, *), let light = c.light {
          ColorPicker(L("LED Color"), selection: ledBinding(for: light))
            .labelsHidden()
          Text(L("LED Color")).foregroundStyle(.secondary)
        }
        #endif
        Spacer()
      }
      .font(.caption)
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func profileSheet(profiles: [String], title: String, onPick: @escaping (String) -> Void) -> some View {
    NavigationStack {
      List {
        if profiles.isEmpty {
          Text(L("No profiles")).foregroundStyle(.secondary)
        } else {
          ForEach(profiles, id: \.self) { p in
            Button(action: { onPick(p) }) { Text(p) }
          }
        }
      }
      .navigationTitle(title)
    }
  }

  // MARK: Apply selections (route through ControllerManager.shared)

  private func applyGC(_ tag: DeviceTag, port: Int) {
    switch tag {
    case .none:
      ControllerManager.shared.clearDefaultDevice(forGCPort: port)
    case .touchscreen:
      ControllerManager.shared.assignTouchscreen(toGCPort: port)
    case .controller(let qualifier):
      if let c = controller(forQualifier: qualifier) {
        ControllerManager.shared.assign(c, toGCPort: port)
      }
    }
    reloadQualifiers()
  }

  private func applyWii(_ tag: DeviceTag, wiimote w: Int) {
    switch tag {
    case .none:
      ControllerManager.shared.clearDefaultDevice(forWiimote: w)
    case .touchscreen:
      ControllerManager.shared.assignTouchscreen(toWiimote: w)
    case .controller(let qualifier):
      if let c = controller(forQualifier: qualifier) {
        ControllerManager.shared.assign(c, toWiimote: w)
      }
    }
    reloadQualifiers()
  }

  // MARK: Helpers

  private func friendlyName(_ c: GCController) -> String {
    c.vendorName ?? c.productCategory
  }

  #if os(iOS)
  /// Two-way bridge between SwiftUI's `Color` and a controller's `GCDeviceLight`.
  @available(iOS 14.0, *)
  private func ledBinding(for light: GCDeviceLight) -> Binding<Color> {
    Binding(
      get: { Color(red: Double(light.color.red), green: Double(light.color.green), blue: Double(light.color.blue)) },
      set: { newColor in
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(newColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        light.color = GCColor(red: Float(r), green: Float(g), blue: Float(b))
      }
    )
  }
  #endif

  /// Makes a specific controller perceptibly react (LED blink + a short rumble
  /// pulse where supported) so the user can tell which physical device maps to
  /// which list entry.
  private func identify(_ c: GCController) {
    if #available(iOS 14.0, tvOS 14.0, *), let light = c.light {
      let original = light.color
      for step in 0 ..< 6 {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.15) {
          light.color = step % 2 == 0 ? GCColor(red: 1, green: 1, blue: 1) : original
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { light.color = original }
    }
    if #available(iOS 14.0, tvOS 14.0, *), let haptics = c.haptics {
      playIdentifyPulse(haptics)
    }
  }

  @available(iOS 14.0, tvOS 14.0, *)
  private func playIdentifyPulse(_ haptics: GCDeviceHaptics) {
    guard let engine = haptics.createEngine(withLocality: .default) else { return }
    do {
      try engine.start()
      let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
      let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
      let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0, duration: 0.6)
      let pattern = try CHHapticPattern(events: [event], parameters: [])
      let player = try engine.makePlayer(with: pattern)
      try player.start(atTime: 0)
      identifyEngines.append(engine)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        try? player.stop(atTime: 0)
        engine.stop(completionHandler: nil)
        identifyEngines.removeAll { $0 === engine }
      }
    } catch {}
  }

  private func controller(forQualifier qualifier: String) -> GCController? {
    controllers.first { (TVControllerMappingBridge.qualifiedName(for: $0) as String) == qualifier }
  }

  private func tag(forQualifier qualifier: String) -> DeviceTag {
    if qualifier.isEmpty { return .none }
    if qualifier.hasPrefix("iOS/") { return .touchscreen }
    return .controller(qualifier)
  }

  private func reloadAll() {
    reloadDevices()
    reloadQualifiers()
    reloadGlobals()
    for i in 0 ..< 4 {
      wiiExtension[i] = Int(DOLWiimoteBridge.selectedExtension(forWiimote: i))
      wiiSideways[i] = DOLWiimoteBridge.isSideways(forWiimote: i)
    }
  }

  private func reloadDevices() {
    controllers = GCController.controllers()
  }

  private func reloadQualifiers() {
    for port in 1 ... 4 {
      gcQualifiers[port] = TVControllerMappingBridge.defaultDevice(forGCPort: port) as String
      wiiQualifiers[port] = TVControllerMappingBridge.defaultDevice(forWiimote: port) as String
    }
  }

  private func reloadGlobals() {
    backgroundInput = DOLConfigBridge.mainBackgroundInput()
    wiimoteScan = DOLConfigBridge.wiimoteContinuousScanning()
    wiimoteSpeaker = DOLConfigBridge.wiimoteEnableSpeaker()
  }
}
