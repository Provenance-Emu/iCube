// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreHaptics
import GameController
import Observation
import SwiftUI

/// Everything the hub reads, behind one seam, so `ControllerHubViewModel` is testable without the
/// core, the bridges or real pads.
@MainActor
protocol ControllerHubReading {
  /// The device bound to a GameCube port, or "" while the port is off.
  func boundQualifier(forGCPort port: Int) -> String
  /// The device bound to a Wii Remote slot, or "" while the slot is off.
  func boundQualifier(forWiimote index: Int) -> String
  func wiiExtension(forWiimote index: Int) -> Int
  func isSideways(forWiimote index: Int) -> Bool
  func connectedPads() -> [ConnectedPadState]
  func isGameRunning() -> Bool
  func overlayVisible() -> Bool
  func overlayMode() -> ControllerManager.OverlayMode
  /// 0…1.
  func overlayOpacity() -> Float
  func continuousScanning() -> Bool
  func dsuClientEnabled() -> Bool
  func dsuServerCount() -> Int
}

struct LiveControllerHubReader: ControllerHubReading {
  /// Explicit and `nonisolated` so `reader: any ControllerHubReading = LiveControllerHubReader()`
  /// can be used as a default argument value: conforming to the `@MainActor` protocol otherwise
  /// infers global-actor isolation for the whole type, including its synthesized `init()`, and a
  /// default-argument expression is evaluated outside the initializer's own isolation.
  nonisolated init() {} // swiftlint:disable:this unneeded_synthesized_initializer

  /// A port's stock default device is `iOS/0/Touchscreen` even while the port is off, so only an
  /// active port reports its device (the rule `ControllerSetupSections.reloadQualifiers` used).
  func boundQualifier(forGCPort port: Int) -> String {
    DOLConfigBridge.gcPortDevice(forPort: port) != 0 ? TVControllerMappingBridge.defaultDevice(forGCPort: port) as String : ""
  }

  func boundQualifier(forWiimote index: Int) -> String {
    DOLConfigBridge.wiimoteSource(for: index) != 0 ? TVControllerMappingBridge.defaultDevice(forWiimote: index) as String : ""
  }

  func wiiExtension(forWiimote index: Int) -> Int { WiimoteSlotOptions.selectedExtension(forWiimote: index) }
  func isSideways(forWiimote index: Int) -> Bool { WiimoteSlotOptions.isSideways(forWiimote: index) }

  func connectedPads() -> [ConnectedPadState] {
    GCController.controllers().map { controller in
      let battery = controller.battery
      let hasLevel = battery.map { $0.batteryLevel >= 0 && $0.batteryState != .unknown } ?? false
      return ConnectedPadState(
        qualifier: TVControllerMappingBridge.qualifiedName(for: controller) as String,
        name: controller.vendorName ?? controller.productCategory,
        batteryPercent: hasLevel ? battery.map { Int(($0.batteryLevel * 100).rounded()) } : nil,
        isCharging: battery?.batteryState == .charging,
        playerLabel: controller.playerIndex == .indexUnset ? nil : "P\(controller.playerIndex.rawValue + 1)",
        hasGyro: controller.motion?.hasRotationRate == true)
    }
  }

  func isGameRunning() -> Bool { TVEmulationBridge.isRunning() }
  func overlayVisible() -> Bool { ControllerManager.shared.overlayVisible }
  func overlayMode() -> ControllerManager.OverlayMode { ControllerManager.shared.overlayMode }
  func overlayOpacity() -> Float { DOLConfigBridge.mainTouchPadOpacity() }
  func continuousScanning() -> Bool { DOLConfigBridge.wiimoteContinuousScanning() }
  func dsuClientEnabled() -> Bool { DOLConfigBridge.dsuClientEnabled() }
  func dsuServerCount() -> Int { DOLConfigBridge.dsuServersParsed().count }
}

/// The Controllers hub's state (controller hub spec, "Architecture"). The only hub unit that
/// touches `ControllerManager`, `TVControllerMappingBridge`, `DOLConfigBridge` and `GCController`.
///
/// `init` reads nothing and installs nothing: SwiftUI builds hosts eagerly (Settings builds every
/// destination on each render), so reads wait for `start()`.
@MainActor
@Observable
final class ControllerHubViewModel {
  let system: ControllerSetupSystem
  private(set) var state: ControllerHubState

  private let reader: any ControllerHubReading
  private let notificationCenter: NotificationCenter
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  /// Keeps each Identify haptic engine alive until its pulse ends.
  @ObservationIgnored private var identifyEngines: [CHHapticEngine] = []

  init(
    system: ControllerSetupSystem,
    reader: any ControllerHubReading = LiveControllerHubReader(),
    notificationCenter: NotificationCenter = .default
  ) {
    self.system = system
    self.reader = reader
    self.notificationCenter = notificationCenter
    self.state = .empty(system: system)
  }

  // MARK: Snapshot

  func reload() {
    let players = ControllerHubState.slots(for: system).map { slot -> PlayerState in
      switch slot.kind {
      case .gameCube:
        return PlayerState(
          kind: .gameCube, port: slot.port, deviceQualifier: reader.boundQualifier(forGCPort: slot.port),
          wiiExtension: 0, isSideways: false)
      case .wiiRemote:
        return PlayerState(
          kind: .wiiRemote, port: slot.port, deviceQualifier: reader.boundQualifier(forWiimote: slot.port),
          wiiExtension: reader.wiiExtension(forWiimote: slot.port), isSideways: reader.isSideways(forWiimote: slot.port))
      }
    }
    state = ControllerHubState(
      system: system,
      players: players,
      showAllPorts: state.showAllPorts,
      pads: reader.connectedPads(),
      isGameRunning: reader.isGameRunning(),
      overlayVisible: reader.overlayVisible(),
      overlayMode: reader.overlayMode(),
      overlayOpacityPercent: ControllerHubState.snappedOpacityPercent(reader.overlayOpacity()),
      continuousScanning: reader.continuousScanning(),
      dsuClientEnabled: reader.dsuClientEnabled(),
      dsuServerCount: reader.dsuServerCount())
  }

  /// Takes a snapshot and follows assignment and device changes until `stop()`. Idempotent.
  /// Observers deliver on the main queue: `TVControllerDevicesChangedNotification` can be posted
  /// off-main by `TVControllerMappingBridge`.
  func start() {
    reload()
    guard observers.isEmpty else { return }
    let names: [Notification.Name] = [
      ControllerManager.assignmentsChanged,
      .GCControllerDidConnect,
      .GCControllerDidDisconnect,
      .TVControllerDevicesChanged,
    ]
    observers = names.map { name in
      notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reload() }
      }
    }
  }

  func stop() {
    observers.forEach { notificationCenter.removeObserver($0) }
    observers.removeAll()
  }

  // MARK: Actions

  /// Every setter ends by reloading (or by changing `state` directly), because the builder's
  /// bindings read the snapshot: a setter that only wrote a bridge would snap its row back.
  var actions: ControllerHubActions {
    ControllerHubActions(
      playerDestination: { player in
        AnyView(PlayerScreenView(slot: PlayerSlot(kind: player.kind, port: player.port)))
      },
      toggleShowAllPorts: { [weak self] in
        self?.state.showAllPorts.toggle()
      },
      setOverlayVisible: { [weak self] visible in
        self?.chooseOnScreenControls { ControllerManager.shared.overlayVisible = visible }
      },
      setOverlayMode: { [weak self] mode in
        self?.chooseOnScreenControls {
          ControllerManager.shared.overlayMode = mode
          // The top bar's rule: picking a specific style also shows the controls.
          if mode != .auto { ControllerManager.shared.overlayVisible = true }
        }
      },
      setOverlayOpacity: { [weak self] opacity in
        DOLConfigBridge.setMainTouchPadOpacity(opacity)
        self?.reload()
      },
      editLayoutDestination: {
        #if os(iOS)
        AnyView(TouchOverlayLayoutEditorView().padBackNavigation())
        #else
        AnyView(EmptyView())
        #endif
      },
      identifyPad: { [weak self] qualifier in
        self?.identify(qualifier: qualifier)
      },
      setContinuousScanning: { [weak self] enabled in
        DOLConfigBridge.setWiimoteContinuousScanning(enabled)
        self?.reload()
      },
      // Plain lists, not menus: they get pad Back from the modifier (Phase 2 left them touch-only).
      dsuDestination: { AnyView(DSUSettingsView().padBackNavigation()) },
      moreSettingsDestination: { AnyView(ControllerMoreSettingsView().padBackNavigation()) })
  }

  /// Announces the choice BEFORE applying it: `overlayMode = .wii` posts `assignmentsChanged`
  /// synchronously, and the emulation screen re-derives visibility on that notice unless it
  /// already knows the player chose.
  private func chooseOnScreenControls(_ apply: () -> Void) {
    notificationCenter.post(name: .DOLOnScreenControlsChosen, object: nil)
    apply()
    reload()
  }

  // MARK: Identify

  /// Makes one pad visibly and physically react (LED blink, short rumble) so the player can tell
  /// which row is which pad.
  private func identify(qualifier: String) {
    guard let controller = GCController.controllers().first(where: {
      (TVControllerMappingBridge.qualifiedName(for: $0) as String) == qualifier
    }) else { return }
    if let light = controller.light {
      let original = light.color
      for step in 0 ..< 6 {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.15) {
          light.color = step % 2 == 0 ? GCColor(red: 1, green: 1, blue: 1) : original
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { light.color = original }
    }
    if let haptics = controller.haptics {
      playIdentifyPulse(haptics)
    }
  }

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
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(1))
        try? player.stop(atTime: 0)
        engine.stop(completionHandler: nil)
        self?.identifyEngines.removeAll { $0 === engine }
      }
    } catch {}
  }
}
