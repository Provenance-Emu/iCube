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
  func dsuClientEnabled() -> Bool
  func dsuServerCount() -> Int
  /// The user picked this port's device, so auto-assignment leaves it alone.
  func isPinned(_ slot: PlayerSlot) -> Bool
  func isMotionPointerEnabled(wiimote: Int) -> Bool
  func pointerMode() -> PointerMode
  /// The running title has its own pointer mode, so a change lasts for this game only.
  func pointerIsThisGameOnly() -> Bool
  func backgroundInput() -> Bool
  func rumbleDestination() -> RumbleDestination
  func connectTakesPlayer1() -> Bool
  func touchOverlayProgrammatic() -> Bool
}

struct LiveControllerHubReader: ControllerHubReading {
  /// Explicit and `nonisolated` so `reader: any ControllerHubReading = LiveControllerHubReader()`
  /// can be used as a default argument value: conforming to the `@MainActor` protocol otherwise
  /// infers global-actor isolation for the whole type, including its synthesized `init()`, and a
  /// default-argument expression is evaluated outside the initializer's own isolation.
  nonisolated init() {} // swiftlint:disable:this unneeded_synthesized_initializer

  /// A port's stock default device is `iOS/0/Touchscreen` even while the port is off, so only an
  /// active port reports its device (the rule the old controller setup screen used).
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
        hasGyro: controller.motion?.hasRotationRate == true,
        hasLight: controller.light != nil)
    }
  }

  func isGameRunning() -> Bool { TVEmulationBridge.isRunning() }
  func overlayVisible() -> Bool { ControllerManager.shared.overlayVisible }
  func overlayMode() -> ControllerManager.OverlayMode { ControllerManager.shared.overlayMode }
  func overlayOpacity() -> Float { DOLConfigBridge.mainTouchPadOpacity() }
  func dsuClientEnabled() -> Bool { DOLConfigBridge.dsuClientEnabled() }
  func dsuServerCount() -> Int { DOLConfigBridge.dsuServersParsed().count }

  // One source for the per-port reads: the player screen's IO (ruling H8).
  func isPinned(_ slot: PlayerSlot) -> Bool { LivePlayerScreenIO().isPinned(slot) }
  func isMotionPointerEnabled(wiimote: Int) -> Bool { LivePlayerScreenIO().isMotionPointerEnabled(wiimote: wiimote) }
  func pointerMode() -> PointerMode { PointerModeController.shared.mode }
  func pointerIsThisGameOnly() -> Bool { PointerModeController.shared.isThisGameOnly }
  func backgroundInput() -> Bool { DOLConfigBridge.mainBackgroundInput() }
  func rumbleDestination() -> RumbleDestination { RumbleDestination.stored() }
  func connectTakesPlayer1() -> Bool { ControllerManager.connectTakesPlayer1() }

  func touchOverlayProgrammatic() -> Bool {
    #if os(iOS)
    TouchOverlayFlag.isProgrammatic
    #else
    false
    #endif
  }
}

/// Runs deferred work for the settle delay; a protocol so tests fire it by hand.
@MainActor
protocol ControllerHubScheduling {
  /// Runs `work` once after `delay` seconds. The returned closure cancels it.
  func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void
}

struct TaskHubScheduler: ControllerHubScheduling {
  nonisolated init() {} // swiftlint:disable:this unneeded_synthesized_initializer

  func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
    let task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      work()
    }
    return { task.cancel() }
  }
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
  /// Edit Layout… outside a game: `ControllerHubView` presents the full-screen editor.
  var isLayoutEditorPresented = false
  /// Edit IR Area…: `ControllerHubView` presents the full-screen IR area editor.
  var isIRAreaEditorPresented = false

  /// How long a Device, Plays as or Layout choice must stand unchanged before it is written
  /// (ruling H4): tap-cycling otherwise writes every value it passes through.
  static let settleDelay: TimeInterval = 0.6
  /// A player's Plays as row id is its player id plus this.
  static let playsAsRowSuffix = "-plays-as"

  private let reader: any ControllerHubReading
  private let writer: any ControllerHubWriting
  private let scheduler: any ControllerHubScheduling
  /// Only for the profile bookkeeping around a device change (`PlayerDeviceChangeNote`): the
  /// control rows the port holds before and after.
  private let io: any PlayerScreenIO
  private let memory: PlayerProfileMemory
  @ObservationIgnored private var cancelSettle: (() -> Void)?
  private let notificationCenter: NotificationCenter
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  /// Keeps each Identify haptic engine alive until its pulse ends.
  @ObservationIgnored private var identifyEngines: [CHHapticEngine] = []

  init(
    system: ControllerSetupSystem,
    reader: any ControllerHubReading = LiveControllerHubReader(),
    writer: any ControllerHubWriting = LiveControllerHubWriter(),
    scheduler: any ControllerHubScheduling = TaskHubScheduler(),
    io: any PlayerScreenIO = LivePlayerScreenIO(),
    memory: PlayerProfileMemory = .shared,
    notificationCenter: NotificationCenter = .default
  ) {
    self.system = system
    self.reader = reader
    self.writer = writer
    self.scheduler = scheduler
    self.io = io
    self.memory = memory
    self.notificationCenter = notificationCenter
    self.state = .empty(system: system)
  }

  // MARK: Snapshot

  func reload() {
    let players = ControllerHubState.slots(for: system).map { slot -> PlayerState in
      var player: PlayerState
      switch slot.kind {
      case .gameCube:
        player = PlayerState(
          kind: .gameCube, port: slot.port, deviceQualifier: reader.boundQualifier(forGCPort: slot.port),
          wiiExtension: 0, isSideways: false)
      case .wiiRemote:
        player = PlayerState(
          kind: .wiiRemote, port: slot.port, deviceQualifier: reader.boundQualifier(forWiimote: slot.port),
          wiiExtension: reader.wiiExtension(forWiimote: slot.port), isSideways: reader.isSideways(forWiimote: slot.port))
        player.motionPointerEnabled = reader.isMotionPointerEnabled(wiimote: slot.port)
      }
      player.isPinned = reader.isPinned(slot)
      return player
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
      dsuClientEnabled: reader.dsuClientEnabled(),
      dsuServerCount: reader.dsuServerCount(),
      pointerMode: reader.pointerMode(),
      pointerIsThisGameOnly: reader.pointerIsThisGameOnly(),
      backgroundInput: reader.backgroundInput(),
      rumbleDestination: reader.rumbleDestination(),
      connectTakesPlayer1: reader.connectTakesPlayer1(),
      touchOverlayProgrammatic: reader.touchOverlayProgrammatic(),
      pending: state.pending)
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
    flushPending()
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
        self?.chooseOverlayMode(mode)
      },
      setOverlayOpacity: { [weak self] opacity in
        DOLConfigBridge.setMainTouchPadOpacity(opacity)
        self?.reload()
      },
      editLayout: { [weak self] in
        self?.editLayout()
      },
      editIRArea: { [weak self] in
        self?.isIRAreaEditorPresented = true
      },
      skinsDestination: { [system] in Self.skinsDestination(for: system) },
      identifyPad: { [weak self] qualifier in
        self?.identify(qualifier: qualifier)
      },
      // Plain lists, not menus: they get pad Back from the modifier (Phase 2 left them touch-only).
      dsuDestination: { AnyView(DSUSettingsView().padBackNavigation()) },
      moreSettingsDestination: { AnyView(ControllerMoreSettingsView().padBackNavigation()) },
      setDevice: { [weak self] player, choice in
        self?.chooseDevice(player, choice)
      },
      setPlaysAs: { [weak self] player, target in
        self?.choosePlaysAs(player, target)
      },
      setPointerMode: { [weak self] mode in
        self?.writer.setPointerMode(mode)
        self?.reload()
      },
      setMotionPointer: { [weak self] player, enabled in
        self?.writer.setMotionPointer(enabled, wiimote: player.port)
        self?.reload()
      },
      setBackgroundInput: { [weak self] enabled in
        self?.writer.setBackgroundInput(enabled)
        self?.reload()
      },
      setRumbleDestination: { [weak self] value in
        self?.writer.setRumbleDestination(value)
        self?.reload()
      },
      setConnectTakesPlayer1: { [weak self] enabled in
        self?.writer.setConnectTakesPlayer1(enabled)
        self?.reload()
      },
      testRumble: { [weak self] in
        self?.writer.testRumble()
      },
      setTouchOverlayProgrammatic: { [weak self] enabled in
        self?.writer.setTouchOverlayProgrammatic(enabled)
        self?.reload()
      },
      resetOverlayLayouts: { [weak self] in
        self?.writer.resetOverlayLayouts()
        self?.reload()
      },
      // The real view arrives with the Lights screen.
      lightsDestination: { AnyView(EmptyView()) })
  }

  private static func skinsDestination(for system: ControllerSetupSystem) -> AnyView {
    #if os(iOS)
    AnyView(SkinPickerView(padKinds: system.skinPadKinds))
    #else
    AnyView(EmptyView())
    #endif
  }

  /// The controls must be edited on the canvas the game draws them on: positions are stored as
  /// fractions of it, so a layout made on any other rectangle (the old editor, pushed under this
  /// hub's navigation bar) moved when play resumed. In a game, the game screen closes this hub and
  /// edits its live overlay; outside one, the hub presents a full-screen editor.
  private func editLayout() {
    if reader.isGameRunning() {
      notificationCenter.post(name: .DOLEditTouchLayout, object: nil)
    } else {
      isLayoutEditorPresented = true
    }
  }

  /// Announces the choice BEFORE applying it: `overlayMode = .wii` posts `assignmentsChanged`
  /// synchronously, and the emulation screen re-derives visibility on that notice unless it
  /// already knows the player chose.
  private func chooseOnScreenControls(_ apply: () -> Void) {
    notificationCenter.post(name: .DOLOnScreenControlsChosen, object: nil)
    apply()
    reload()
  }

  // MARK: Settling choices (ruling H4)

  func chooseDevice(_ player: PlayerState, _ choice: PlayerDeviceChoice) {
    state.pending.devices[player.id] = choice == PlayerDeviceChoice(qualifier: player.deviceQualifier) ? nil : choice
    settle()
  }

  func choosePlaysAs(_ player: PlayerState, _ target: PlaysAs) {
    state.pending.playsAs[player.id] = target == PlaysAs.current(of: player) ? nil : target
    settle()
  }

  func chooseOverlayMode(_ mode: ControllerManager.OverlayMode) {
    state.pending.overlayMode = mode == state.overlayMode ? nil : mode
    settle()
  }

  /// Restarts the delay; nothing pending, nothing scheduled.
  private func settle() {
    cancelSettle?()
    cancelSettle = nil
    guard !state.pending.isEmpty else { return }
    cancelSettle = scheduler.schedule(after: Self.settleDelay) { [weak self] in self?.commitPending() }
  }

  /// Commits now whatever is pending (the hub is going away: a pushed player screen must see it).
  func flushPending() {
    guard !state.pending.isEmpty else { return }
    commitPending()
  }

  /// Devices first, then Plays as (looked up again by id, so it sees the device just written), then
  /// Layout.
  private func commitPending() {
    cancelSettle?()
    cancelSettle = nil
    let pending = state.pending
    state.pending = PendingHubChanges()
    for (id, choice) in pending.devices.sorted(by: { $0.key < $1.key }) {
      if let player = state.players.first(where: { $0.id == id }) { setDevice(player, choice) }
    }
    for (id, target) in pending.playsAs.sorted(by: { $0.key < $1.key }) {
      if let player = state.players.first(where: { $0.id == id }) { setPlaysAs(player, target) }
    }
    if let mode = pending.overlayMode { setOverlayMode(mode) }
  }

  // MARK: Committing writes

  func setDevice(_ player: PlayerState, _ choice: PlayerDeviceChoice) {
    let slot = PlayerSlot(kind: player.kind, port: player.port)
    let note = PlayerDeviceChangeNote.begin(slot: slot, reader: reader, io: io, memory: memory)
    writer.setDevice(choice, slot: slot)
    note.finish(choice: choice)
    reload()
  }

  /// Announces the choice BEFORE applying it (see `chooseOnScreenControls`).
  func setOverlayMode(_ mode: ControllerManager.OverlayMode) {
    chooseOnScreenControls { writer.setOverlayMode(mode) }
  }

  /// Runs `PlaysAsTransition.plan` in order. On a failing step the view model stops, re-reads state
  /// and toasts; it does not replay inverse steps (ruling H15), so a half-applied change is visible.
  func setPlaysAs(_ player: PlayerState, _ target: PlaysAs) {
    // The occupied-destination check below reads `state.players`: a caller's copy may be stale.
    reload()
    for step in PlaysAsTransition.plan(from: player, to: target) {
      switch step {
      case .setExtension(let wiimote, let value):
        writer.setExtension(value, wiimote: wiimote)
        if value != player.wiiExtension { markEdited(wiimote: wiimote) }
      case .setSideways(let wiimote, let enabled):
        writer.setSideways(enabled, wiimote: wiimote)
        if enabled != player.isSideways { markEdited(wiimote: wiimote) }
      case .clearSlot(let slot):
        writer.clear(slot: slot)
      case .moveDevice(let qualifier, let from, let to):
        // Moving into a port that has a device would overwrite it: refuse before writing anything.
        if let destination = state.players.first(where: { $0.kind == to.kind && $0.port == to.port }), destination.isBound {
          EmulationToast.post(String(format: L("%@ is in use"), destination.title))
          reload()
          return
        }
        let toNote = PlayerDeviceChangeNote.begin(slot: to, reader: reader, io: io, memory: memory)
        guard writer.assign(qualifier: qualifier, slot: to) else {
          EmulationToast.post(L("Couldn't move the controller"))
          reload()
          return
        }
        toNote.finish(choice: PlayerDeviceChoice(qualifier: qualifier))
        let fromNote = PlayerDeviceChangeNote.begin(slot: from, reader: reader, io: io, memory: memory)
        writer.clear(slot: from)
        fromNote.finish(choice: .noDevice)
      }
    }
    reload()
    if target.kind != player.kind {
      state.focusRequest = PlayerSlot(kind: target.kind, port: player.port).playerID + Self.playsAsRowSuffix
    }
  }

  /// The player screen's `setExtension`/`setSideways` mark the remembered profile edited; the hub
  /// does the same, on the device the Wii slot holds NOW: after a cross-kind move that is the
  /// target's (a Touchscreen is `iOS/5/…` there, not the GameCube port's `iOS/1/…`). Any capture is
  /// already over: `PlayerScreenViewModel.stop()` ends it when the player screen leaves, and the hub
  /// is only visible then.
  private func markEdited(wiimote: Int) {
    memory.markEdited(PlayerSlot(kind: .wiiRemote, port: wiimote).playerID, qualifier: reader.boundQualifier(forWiimote: wiimote))
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
