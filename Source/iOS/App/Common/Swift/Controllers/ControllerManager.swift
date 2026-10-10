import Combine
import Foundation
import GameController

@objcMembers
final class ControllerManager: NSObject, ObservableObject {
  static let shared = ControllerManager()
  static let assignmentsChanged = Notification.Name("ControllerAssignmentsChanged")

  enum OverlayMode: Int { case auto, gamecube, wii }
  @Published var overlayVisible: Bool = true
  /// The hub's Overlay Style, kept across launches (`overlayModeDefaultsKey`, registered default Auto).
  @Published var overlayMode: OverlayMode = ControllerManager.storedOverlayMode() {
    didSet {
      Self.storeOverlayMode(overlayMode)
      if overlayMode == .wii { ensureWiimote1EmulatedTouchscreen() }
    }
  }

  static let overlayModeDefaultsKey = "controller_overlay_mode"

  /// "Controllers Take Player 1" (More Controller Settings), on unless turned off:
  /// `AssignmentEngine.player1Takeover`.
  static let connectTakesPlayer1DefaultsKey = "controller_connect_takes_player1"

  static func connectTakesPlayer1(in defaults: UserDefaults = .standard) -> Bool {
    defaults.register(defaults: [connectTakesPlayer1DefaultsKey: true])
    return defaults.bool(forKey: connectTakesPlayer1DefaultsKey)
  }

  /// The Overlay Style kept across launches; Auto when none was kept or the value is unknown.
  static func storedOverlayMode(in defaults: UserDefaults = .standard) -> OverlayMode {
    defaults.register(defaults: [overlayModeDefaultsKey: OverlayMode.auto.rawValue])
    return OverlayMode(rawValue: defaults.integer(forKey: overlayModeDefaultsKey)) ?? .auto
  }

  static func storeOverlayMode(_ mode: OverlayMode, in defaults: UserDefaults = .standard) {
    defaults.set(mode.rawValue, forKey: overlayModeDefaultsKey)
  }

  // Map GCController -> Wiimote slot (1-based), for touchpad pads that drive the Wii pointer.
  private var wiimoteSlotByController: [ObjectIdentifier: Int] = [:]
  @Published var isWiiSystem: Bool = false

  /// Single source of truth for controller assignment: activates the port,
  /// binds the device, applies the default profile, and saves — atomically.
  /// reconcile()/change-notification stay in this manager's wrappers, not the service.
  private let assignmentService = ControllerAssignmentService(writer: BridgeControllerConfigWriter())

  /// Slots the user assigned explicitly (setup / remap UI). Persisted so a pad that connects at
  /// the next launch cannot take over a slot the user gave to the touchscreen or another pad.
  static let pinnedSlotsDefaultsKey = "controller_pinned_slots"
  private(set) var pinnedSlots: Set<PinnedSlot> = []

  override private init() {
    super.init()
    pinnedSlots = Self.loadPinnedSlots()
  }

  private static func loadPinnedSlots() -> Set<PinnedSlot> {
    let raw = UserDefaults.standard.stringArray(forKey: pinnedSlotsDefaultsKey) ?? []
    return Set(raw.compactMap { entry -> PinnedSlot? in
      let parts = entry.split(separator: ":")
      guard parts.count == 2, let player = Int(parts[1]) else { return nil }
      switch parts[0] {
      case "gamecube": return PinnedSlot(system: .gamecube, playerZeroBased: player)
      case "wii": return PinnedSlot(system: .wii, playerZeroBased: player)
      default: return nil
      }
    })
  }

  private func savePinnedSlots() {
    let raw = pinnedSlots.map { "\($0.system == .gamecube ? "gamecube" : "wii"):\($0.playerZeroBased)" }.sorted()
    UserDefaults.standard.set(raw, forKey: Self.pinnedSlotsDefaultsKey)
  }

  private func pin(_ system: EmulatedSystem, player: Int) {
    pinnedSlots.insert(PinnedSlot(system: system, playerZeroBased: player))
    savePinnedSlots()
  }

  private func unpin(_ system: EmulatedSystem, player: Int) {
    pinnedSlots.remove(PinnedSlot(system: system, playerZeroBased: player))
    savePinnedSlots()
  }

  /// The user chose this slot's device; auto-assignment leaves it alone. Shown on the player
  /// screen's Device row.
  func isPinned(_ system: EmulatedSystem, player: Int) -> Bool {
    pinnedSlots.contains(PinnedSlot(system: system, playerZeroBased: player))
  }

  /// The Device list's "Auto": forget the user's choice for this slot and let auto-assignment place
  /// a connected controller there again. The slot's device stays until something takes it.
  func unpinAndReassign(_ system: EmulatedSystem, player: Int) {
    unpin(system, player: player)
    reconcile()
  }

  // MARK: Observing / Publishers

  private var observers: [NSObjectProtocol] = []
  private var cancellables = Set<AnyCancellable>()
  private let controllerConnectedSubject = PassthroughSubject<GCController, Never>()
  private let controllerDisconnectedSubject = PassthroughSubject<GCController?, Never>()
  private let fastForwardToggledSubject = PassthroughSubject<Bool, Never>()
  private var isObserving = false
  private var isReconciling = false

  var controllerConnectedPublisher: AnyPublisher<GCController, Never> { controllerConnectedSubject.eraseToAnyPublisher() }
  var controllerDisconnectedPublisher: AnyPublisher<GCController?, Never> { controllerDisconnectedSubject.eraseToAnyPublisher() }
  var fastForwardToggledPublisher: AnyPublisher<Bool, Never> { fastForwardToggledSubject.eraseToAnyPublisher() }

  // MARK: Disconnect-pause

  /// Identifies a slot whose assigned physical controller dropped mid-game.
  /// `port` is 0-based; `qualifier` is the bridge-qualified device name so the
  /// same physical device can be matched on reconnect (object identity is gone).
  struct DisconnectPause: Equatable {
    let qualifier: String
    let port: Int
    let isWii: Bool
  }

  /// Non-nil while a disconnect-induced pause is active. The emulation screen
  /// observes this to show the reconnect banner and to gate the paused pill.
  @Published private(set) var disconnectPause: DisconnectPause?

  /// Clears the disconnect-pause state (dismisses the banner). Called by the
  /// emulation screen's poll when the game has resumed via any other path
  /// (pill tap, pause menu Resume, new game launch) so the banner can never get
  /// stuck over a running game.
  func clearDisconnectPause() {
    disconnectPause = nil
    MainActor.assumeIsolated { PauseArbiter.shared.release(reason: PauseArbiter.Reason.disconnect) }
  }

  /// Resolves an active disconnect-pause by handing the vacated slot to the
  /// on-screen touchscreen and resuming immediately, instead of waiting for the
  /// physical controller to reconnect. Backs `ControllerDisconnectBanner`'s
  /// "Use Touch Controls" action (iOS only — there is no touchscreen on tvOS).
  func useTouchControlsForDisconnectedSlot() {
    guard let pending = disconnectPause else { return }
    if pending.isWii {
      assignTouchscreen(toWiimote: pending.port + 1)
    } else {
      assignTouchscreen(toGCPort: pending.port + 1)
    }
    overlayVisible = true
    disconnectPause = nil
    MainActor.assumeIsolated { PauseArbiter.shared.release(reason: PauseArbiter.Reason.disconnect) }
  }

  /// Returns the 0-based slot and Wii-ness for a controller currently assigned as
  /// a physical device, or nil if it is not bound to any port (touchscreen-only /
  /// unassigned). Matches by bridge qualifier across GC ports then Wiimotes.
  private func assignedSlot(for controller: GCController) -> (port: Int, isWii: Bool)? {
    let qualifier = TVControllerMappingBridge.qualifiedName(for: controller)
    guard !qualifier.isEmpty else { return nil }
    for portOneBased in 1 ... 4 {
      if TVControllerMappingBridge.defaultDevice(forGCPort: portOneBased) as String == qualifier {
        return (portOneBased - 1, false)
      }
    }
    for indexOneBased in 1 ... 4 {
      if TVControllerMappingBridge.defaultDevice(forWiimote: indexOneBased) as String == qualifier {
        return (indexOneBased - 1, true)
      }
    }
    return nil
  }

  func startObserving() {
    guard !isObserving else { return }
    isObserving = true

    // Initial configure
    refreshInputHandlers()

    // Connect/disconnect notifications
    let onConnect = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
      guard let self = self else { return }
      if let c = note.object as? GCController {
        PauseGestureTracker.shared.noteControllerConnected()
        configureController(c)
        ControllerStyleManager.shared.refreshDetection()
        // If a disconnect-pause is active, any connecting controller resumes the
        // game so the user is never stranded. If it is the SAME physical device,
        // restore it to its original slot; otherwise auto-assign to the first
        // free slot. Either way, clear the pause + dismiss the banner + resume.
        if let pending = self.disconnectPause {
          // Restoring the *original* slot is knowledge reconcile() does not
          // have (the Touchscreen may hold it by now), so it is written here and
          // the reconcile below leaves it alone because the device is now bound.
          // The pad's mapping comes back with it (stashed when the slot changed hands).
          if TVControllerMappingBridge.qualifiedName(for: c) as String == pending.qualifier {
            self.assignmentService.assign(qualifier: pending.qualifier, toPlayer: pending.port, system: pending.isWii ? .wii : .gamecube)
          }
          self.disconnectPause = nil
          MainActor.assumeIsolated { PauseArbiter.shared.release(reason: PauseArbiter.Reason.disconnect) }
          self.updateWiimoteEmulationForExternalControllers()
          self.controllerConnectedSubject.send(c)
          self.reconcile()
          return
        }
        self.updateWiimoteEmulationForExternalControllers()
        // Battery toast if available
        if #available(iOS 14.0, tvOS 14.0, *), let battery = c.battery {
          let level = battery.batteryLevel
          var state = ""
          switch battery.batteryState { case .charging: state = L("Charging")
          case .full: state = L("Full")
          default: state = "" }
          if level >= 0.0 {
            let pct = Int((level * 100.0).rounded())
            let text = state.isEmpty ? String(format: L("Controller Battery: %d%%"), pct) : String(format: L("Controller Battery: %d%% (%@)"), pct, state)
            NotificationCenter.default.post(name: Notification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": text])
          }
        }
        self.controllerConnectedSubject.send(c)
        self.takePlayer1FromTouchscreen(for: c)
        self.reconcile()
      }
    }
    let onDisconnect = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
      guard let self = self else { return }
      let c = note.object as? GCController
      // Auto-pause when an ASSIGNED PHYSICAL controller drops mid-game. A
      // touchscreen-only / unassigned disconnect does nothing. Capture the slot
      // before reconcile() can rewrite the bindings.
      if self.disconnectPause == nil,
         let dropped = c,
         let slot = self.assignedSlot(for: dropped),
         TVEmulationBridge.isRunning(),
         !(TVEmulationBridge.currentGameID() as String).isEmpty,
         !TVEmulationBridge.isPaused() {
        let qualifier = TVControllerMappingBridge.qualifiedName(for: dropped) as String
        self.disconnectPause = DisconnectPause(qualifier: qualifier, port: slot.port, isWii: slot.isWii)
        MainActor.assumeIsolated { _ = PauseArbiter.shared.claim(PauseArbiter.Reason.disconnect) }
      }
      // Drop this controller's shoulder / shake / touchpad-IR caches. They are
      // keyed by ObjectIdentifier (the object address), so leaving them behind
      // both leaks and lets a future allocation inherit dead state.
      if let dropped = c { releaseControllerInputState(for: dropped) }
      ControllerStyleManager.shared.refreshDetection()
      self.controllerDisconnectedSubject.send(c)
      self.reconcile()
      self.updateWiimoteEmulationForExternalControllers()
      // Defect #11: reconcile() can hand a vacated slot back to the on-screen
      // touchscreen (via AssignmentEngine), but nothing told the overlay's own
      // visibility flag that happened, so the buttons stayed hidden after a
      // mid-game disconnect even though the touchscreen was now live again.
      // Only ever turns the overlay ON here — never hides it — so an explicit
      // user hide of an unrelated slot is not clobbered. Ask the core directly
      // for Wii-ness (matches the PauseMenuView / ControllerStateStore pattern)
      // rather than `isWiiSystem`, which only iOS keeps in sync from the view.
      if TVEmulationBridge.isRunning() {
        let ownedSystem: EmulatedSystem = TVEmulationBridge.isCurrentSystemWii() ? .wii : .gamecube
        if self.touchscreenSlot(system: ownedSystem) != nil {
          self.overlayVisible = true
        }
      }
    }
    // Boot auto-assign: controllers already connected when a game starts never
    // fire GCControllerDidConnect, so reconcile here. This runs after the
    // ControllerInterface is initialized (the notification is posted once the
    // core reaches Running/Paused, after UICommon::InitControllers), which is the
    // only point the bridge can produce valid device qualifiers — and the only
    // point `isCurrentSystemWii()` is meaningful, which is what lets the engine
    // put controllers on Wiimote slots for a Wii title.
    let onEmulationStart = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.refreshInputHandlers()
      self.updateWiimoteEmulationForExternalControllers()
      self.reconcile()
    }
    // Hardware Menu presses that arrive on the UIPress path (tvOS Siri Remote)
    // land here so they go through the same gated + coalesced sink as the
    // GCController paths, and so the core is actually paused before the overlay
    // is shown. This observer is app-wide, matching the connect observer.
    let onPauseRequest = NotificationCenter.default.addObserver(
      forName: PauseGestureTracker.requestPauseMenuNotification, object: nil, queue: .main) { _ in
        PauseGestureTracker.shared.requestPauseMenu(reason: "uipress-menu")
      }
    observers.append(contentsOf: [onConnect, onDisconnect, onEmulationStart, onPauseRequest])

    // Fast-forward toggled bridge -> publisher
    NotificationCenter.default.publisher(for: Notification.Name("DOLFastForwardToggled"))
      .compactMap { $0.userInfo?["enabled"] as? NSNumber }
      .map { $0.boolValue }
      .sink { [weak self] enabled in self?.fastForwardToggledSubject.send(enabled) }
      .store(in: &cancellables)
  }

  func stopObserving() {
    guard isObserving else { return }
    isObserving = false
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    cancellables.removeAll()
  }

  /// The single install entry point for controller input handlers.
  ///
  /// There used to be five ways in — `configureController`,
  /// `configureControllerForCurrentPlatform`, `setupPauseGestureHandlers`,
  /// `setupPauseGestureHandler(for:)` and two raw loops in `EmulationScreen` —
  /// all writing the same single-slot handler properties in an order nobody
  /// controlled. Now everything routes here.
  ///
  /// It is safe (and cheap) to call repeatedly: every handler it installs is an
  /// unconditional assignment. It is called at connect time, when observation
  /// starts, and once when a game starts, because `installExtraInputHandlers`
  /// reads `DOLConfigBridge.mainTouchPadIRMode()` at install time and that
  /// setting can change between games.
  func refreshInputHandlers() {
    for c in GCController.controllers() { configureController(c) }
  }

  // MARK: Overrides (GC)

  func registerGCOverride(forController index: Int) {
    InputOverriderBridge.registerGameCubeOverride(forController: index)
  }

  func unregisterGCOverride(forController index: Int) {
    InputOverriderBridge.unregisterGameCubeOverride(forController: index)
  }

  // MARK: Overlays

  func setSystem(isWii: Bool) { isWiiSystem = isWii }

  // ObjC helper: decide whether Wii overlay should be shown given system and availability
  func shouldShowWiiOverlay(wiiSystem: Bool, wiiPadAttached: Bool, gcPadAttached: Bool) -> Bool {
    switch overlayMode {
    case .wii:
      return true
    case .gamecube:
      return false
    case .auto:
      if wiiSystem {
        return wiiPadAttached
      } else {
        return false
      }
    }
  }

  func shouldShowGCPad(wiiSystem: Bool, wiiPadAttached: Bool, gcPadAttached: Bool) -> Bool {
    switch overlayMode {
    case .wii:
      return false
    case .gamecube:
      return true
    case .auto:
      if wiiSystem {
        return !wiiPadAttached && gcPadAttached
      } else {
        return true
      }
    }
  }

  // MARK: Touchscreen slot

  /// First Touchscreen device id the iOS backend registers for Wii Remote inputs. Ids 0-3 carry
  /// the GameCube pad inputs, 4-7 the Wii Remote inputs (iOS.mm PopulateDevices; mirrored by
  /// `kTouchscreenWiimoteIdBase` in EmulationCoordinator.mm).
  static let touchscreenWiimoteIdBase = 4

  /// Zero-based player slot the on-screen overlay is bound to for `system`, or nil when no
  /// active slot points at a Touchscreen device. GC: the port's SIDevice must not be None;
  /// Wii: the slot's source must be Emulated. Lowest matching slot wins.
  func touchscreenSlot(system: EmulatedSystem) -> Int? {
    for port in 1 ... 4 {
      let qualifier: String
      switch system {
      case .gamecube:
        guard DOLConfigBridge.gcPortDevice(forPort: port) != 0 else { continue }
        qualifier = TVControllerMappingBridge.defaultDevice(forGCPort: port) as String
      case .wii:
        guard DOLConfigBridge.wiimoteSource(for: port) == 1 else { continue }
        qualifier = TVControllerMappingBridge.defaultDevice(forWiimote: port) as String
      }
      if Self.touchscreenDeviceId(fromQualifier: qualifier) != nil { return port - 1 }
    }
    return nil
  }

  /// Touchscreen device id (the `StateManager` controller index) the overlay and the device
  /// motion feed must write to. Read from the bound qualifier (`iOS/<id>/Touchscreen`) so it
  /// matches whatever the core actually reads, with the stock instance (GC 0 / Wii 4) as the
  /// fallback while nothing is bound yet. The overlay used to hardcode 4 for every Wii pad and 0
  /// for every GC pad, so a touchscreen bound to any other slot produced no input.
  func touchscreenControllerId(isWii: Bool) -> Int {
    let system: EmulatedSystem = isWii ? .wii : .gamecube
    let fallback = isWii ? Self.touchscreenWiimoteIdBase : 0
    guard let slot = touchscreenSlot(system: system) else { return fallback }
    let qualifier: String = isWii
      ? TVControllerMappingBridge.defaultDevice(forWiimote: slot + 1) as String
      : TVControllerMappingBridge.defaultDevice(forGCPort: slot + 1) as String
    return Self.touchscreenDeviceId(fromQualifier: qualifier) ?? fallback
  }

  /// Parses `iOS/<id>/Touchscreen`; nil for anything else.
  static func touchscreenDeviceId(fromQualifier qualifier: String) -> Int? {
    let parts = qualifier.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "iOS", parts[2] == "Touchscreen" else { return nil }
    return Int(parts[1])
  }

  // MARK: Ensure Wiimote1 Touchscreen

  func ensureWiimote1EmulatedTouchscreen() {
    DOLConfigBridge.setWiimoteSourceFor(1, source: 1)
    DOLConfigBridge.setConnectWiimotesForControllerInterface(true)
    EmulationCoordinator.ensureWiimoteDefaultsToTouchscreen(forPort: 1)
    updateWiimoteEmulationForExternalControllers()
    NotificationCenter.default.post(name: Self.assignmentsChanged, object: nil)
  }

  // MARK: Reconcile

  /// The one place controller assignment is decided and applied.
  ///
  /// Sequence: snapshot, let `AssignmentEngine` decide, apply every decision through
  /// `ControllerAssignmentService` (which re-affirms connected pads' slots as active), then
  /// mirror the result onto `playerIndex`. A device that goes away keeps its binding and its
  /// mapping, so it comes back to them; when the engine gives its slot to the Touchscreen or
  /// another pad meanwhile, the service stashes its mapping first.
  /// The engine is idempotent, so calling this repeatedly is free and port
  /// assignments stay put across connect/disconnect cycles.
  /// `autoAssign: false` is for explicit user actions: re-affirm activation and sync player
  /// indices, but make no new placement decisions. Running
  /// the engine after every explicit choice is what made a GameCube assignment also rewrite the
  /// Wii Remotes (and vice versa) and put a connected pad straight back onto a slot the user had
  /// just given to the touchscreen.
  func reconcile(autoAssign: Bool = true) {
    // Re-entrancy guard. Connect used to run auto-assign, which called
    // reconcile, which assigned, which called reconcile again — so one connect
    // event could decide, re-decide and reassign the same controller several
    // times before the callback returned.
    guard !isReconciling else { return }
    isReconciling = true
    defer { isReconciling = false }

    assignmentService.reconcile(ControllerStateStore.shared.snapshot(), pinned: pinnedSlots, autoAssign: autoAssign)

    syncPlayerIndices()
    NotificationCenter.default.post(name: Self.assignmentsChanged, object: nil)
  }

  /// The pre-boot pass (`AssignmentEngine.decideBoot`). Called by EmulationCoordinator on the main
  /// thread after `UICommon::InitControllers` and before `BootCore`, with the platform of the title
  /// about to boot (`isCurrentSystemWii()` means nothing yet). The coordinator keeps only the
  /// mechanical work around it.
  func prepareForBoot(isWii: Bool) {
    let state = ControllerStateStore.shared.snapshot(isWiiSystem: isWii)
    assignmentService.apply(AssignmentEngine().decideBoot(from: state, pinned: pinnedSlots))
  }

  /// The **only** writer of `GCController.playerIndex`.
  ///
  /// It is derived from the config bindings rather than set alongside them, so
  /// the player LED can never disagree with the port the device is actually
  /// bound to. Four scattered `playerIndex =` writes (three here, one in
  /// `TVControllerMappingBridge`) used to drift out of sync with the config.
  private func syncPlayerIndices() {
    for controller in GCController.controllers() {
      if let slot = assignedSlot(for: controller) {
        controller.playerIndex = GCControllerPlayerIndex(rawValue: slot.port) ?? .indexUnset
      } else {
        controller.playerIndex = .indexUnset
      }
    }
  }

  // MARK: Assign

  func assignTouchscreen(toGCPort portOneBased: Int) {
    assignmentService.assignTouchscreen(toPlayer: portOneBased - 1, system: .gamecube)
    pin(.gamecube, player: portOneBased - 1)
    reconcile(autoAssign: false)
  }

  func assign(_ controller: GCController, toGCPort portOneBased: Int) {
    assign(controller, toPlayer: portOneBased - 1, system: .gamecube)
  }

  // MARK: Wii assign wrappers (mirror the GC wrappers; add reconcile + notification)

  func assignTouchscreen(toWiimote indexOneBased: Int) {
    assignmentService.assignTouchscreen(toPlayer: indexOneBased - 1, system: .wii)
    pin(.wii, player: indexOneBased - 1)
    reconcile(autoAssign: false)
  }

  func assign(_ controller: GCController, toWiimote indexOneBased: Int) {
    assign(controller, toPlayer: indexOneBased - 1, system: .wii)
  }

  /// Shared body of the explicit (user-driven) assign wrappers.
  ///
  /// The bridge-qualifier fallback that used to live here — activate the port,
  /// then let `TVControllerMappingBridge.assign(_:toGCPort:)` pick "the first
  /// connected MFi device" — was one of the six competing writers and bound a
  /// device the user had not chosen. It is gone: if the ControllerInterface has
  /// not enumerated this controller yet there is nothing meaningful to bind, so
  /// the assignment is refused loudly instead of guessing.
  private func assign(_ controller: GCController, toPlayer portZeroBased: Int, system: EmulatedSystem) {
    let qualifier = TVControllerMappingBridge.qualifiedName(for: controller) as String
    guard !qualifier.isEmpty else {
      NSLog("[INPUT] Cannot assign %@ to player %d: no ControllerInterface device yet",
            controller.vendorName ?? "controller", portZeroBased + 1)
      return
    }
    assignmentService.assign(qualifier: qualifier, toPlayer: portZeroBased, system: system)
    pin(system, player: portZeroBased)
    reconcile(autoAssign: false)
  }

  /// The top bar's Player 1 picker: the Touchscreen (nil) or a connected pad becomes Player 1
  /// (GameCube port 1, or Wii Remote 1 in a Wii title), pinned like any explicit choice. A pad leaves
  /// the other slots of that system it held, so one press does not reach two players.
  func choosePlayer1(_ qualifier: String?, isWii: Bool) {
    let system: EmulatedSystem = isWii ? .wii : .gamecube
    guard let qualifier else {
      if isWii { assignTouchscreen(toWiimote: 1) } else { assignTouchscreen(toGCPort: 1) }
      return
    }
    guard let controller = GCController.controllers().first(where: {
      (TVControllerMappingBridge.qualifiedName(for: $0) as String) == qualifier
    }) else { return }
    let state = ControllerStateStore.shared.snapshot(isWiiSystem: isWii)
    for slot in isWii ? state.wiimoteAssignments : state.portAssignments
      where slot.portOneBased != 1 && slot.defaultDeviceQualifier == qualifier {
      assignmentService.clear(player: slot.portOneBased - 1, system: system)
      unpin(system, player: slot.portOneBased - 1)
    }
    if isWii { assign(controller, toWiimote: 1) } else { assign(controller, toGCPort: 1) }
  }

  /// A pad that connects while the on-screen controls are Player 1 takes Player 1, unpinning it, when
  /// "Controllers Take Player 1" is on (`AssignmentEngine.player1Takeover`). The pad's mapping moves
  /// with it: clearing its old slot stashes it, and the assign restores it.
  private func takePlayer1FromTouchscreen(for controller: GCController) {
    #if os(iOS)
    // Only in a running game: outside one the snapshot's system (`isCurrentSystemWii`) is stale,
    // and the boot pass places a pad connected beforehand.
    guard Self.connectTakesPlayer1(), TVEmulationBridge.isRunning() else { return }
    let qualifier = TVControllerMappingBridge.qualifiedName(for: controller) as String
    guard let takeover = AssignmentEngine.player1Takeover(
      of: qualifier, in: ControllerStateStore.shared.snapshot(), pinned: pinnedSlots) else { return }
    if let vacated = takeover.vacatedPlayerZeroBased {
      assignmentService.clear(player: vacated, system: takeover.system)
    }
    assignmentService.assign(qualifier: qualifier, toPlayer: 0, system: takeover.system)
    unpin(takeover.system, player: 0)
    #endif
  }

  func clearDefaultDevice(forWiimote indexOneBased: Int) {
    assignmentService.clear(player: indexOneBased - 1, system: .wii)
    unpin(.wii, player: indexOneBased - 1)
    reconcile(autoAssign: false)
  }

  func defaultDeviceQualifier(forWiimote indexOneBased: Int) -> String {
    return TVControllerMappingBridge.defaultDevice(forWiimote: indexOneBased) as String
  }

  // MARK: Defaults API

  func clearDefaultDevice(forGCPort portOneBased: Int) {
    assignmentService.clear(player: portOneBased - 1, system: .gamecube)
    unpin(.gamecube, player: portOneBased - 1)
    reconcile(autoAssign: false)
  }

  func defaultDeviceQualifier(forGCPort portOneBased: Int) -> String {
    return TVControllerMappingBridge.defaultDevice(forGCPort: portOneBased) as String
  }

  // MARK: Wiimote Emulation for External Controllers

  // Assign Wiimote slots 2..4 to external controllers that have a touchpad (DS4/DS5). Slot 1 is
  // never handed out here: it is the on-screen controls' or a pad the AssignmentEngine put there.
  func updateWiimoteEmulationForExternalControllers() {
    wiimoteSlotByController.removeAll()

    // Slots the AssignmentEngine has bound to a CONNECTED physical controller
    // are off limits. This method used to blanket-zero slots 2-4 before
    // re-enabling only touchpad controllers, and it runs after reconcile() on
    // both the disconnect path and the pause-menu path — so it silently
    // deactivated the Wiimote slot of every pad without a touchpad (Xbox,
    // Switch Pro, bare MFi) on each disconnect and each pause.
    let connected = Set(TVControllerMappingBridge.allQualifiedDevices().filter { !$0.hasPrefix("iOS/") })
    var slotForQualifier: [String: Int] = [:]
    var reserved = Set<Int>()
    // Slot 1 is read too, so a touchpad pad the engine put on Wii Remote 1 keeps it rather than
    // also being given slot 2; it is never switched off here.
    for slot in 1 ... 4 {
      let qualifier = TVControllerMappingBridge.defaultDevice(forWiimote: slot) as String
      if connected.contains(qualifier) {
        reserved.insert(slot)
        slotForQualifier[qualifier] = slot
      } else if isPinned(.wii, player: slot - 1) {
        // The user's choice (a touchscreen Wii Remote 2, a pad that is off): neither switched off
        // nor handed to a touchpad pad.
        reserved.insert(slot)
      } else if slot > 1 {
        DOLConfigBridge.setWiimoteSourceFor(slot, source: 0)
      }
    }

    // Touchpad controllers (DS4/DS5) additionally drive Wii IR from the pad.
    var nextSlot = 2
    for c in GCController.controllers() {
      guard c.supportsTouchpad else { continue }
      let qualifier = TVControllerMappingBridge.qualifiedName(for: c) as String
      if let bound = slotForQualifier[qualifier] {
        // Already on a slot the engine assigned to this exact device; keep it.
        wiimoteSlotByController[ObjectIdentifier(c)] = bound
        continue
      }
      while nextSlot <= 4, reserved.contains(nextSlot) { nextSlot += 1 }
      guard nextSlot <= 4 else { break }
      wiimoteSlotByController[ObjectIdentifier(c)] = nextSlot
      DOLConfigBridge.setWiimoteSourceFor(nextSlot, source: 1)
      EmulationCoordinator.ensureWiimoteDefaultsToTouchscreen(forPort: nextSlot)
      nextSlot += 1
    }
    NotificationCenter.default.post(name: Self.assignmentsChanged, object: nil)
  }

  // Resolve Wiimote slot (1-based) for a controller if assigned for touch IR.
  func wiimoteIndex(for controller: GCController) -> Int? {
    return wiimoteSlotByController[ObjectIdentifier(controller)]
  }
}
