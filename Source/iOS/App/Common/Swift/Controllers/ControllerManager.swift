import Combine
import Foundation
import GameController

@objcMembers
final class ControllerManager: NSObject, ObservableObject {
  static let shared = ControllerManager()
  static let assignmentsChanged = Notification.Name("ControllerAssignmentsChanged")

  enum OverlayMode: Int { case auto, gamecube, wii }
  @Published var overlayVisible: Bool = true
  @Published var overlayMode: OverlayMode = .auto { didSet { if overlayMode == .wii { ensureWiimote1EmulatedTouchscreen() } } }
  // Map GCController -> Wiimote slot (1-based). Slot 1 reserved for on-screen Touch.
  private var wiimoteSlotByController: [ObjectIdentifier: Int] = [:]
  @Published var isWiiSystem: Bool = false

  final class PresetManager: NSObject {
    func applyCurrentPreset() {
      ControllerStyleManager.shared.refreshDetection()
      ControllerStyleManager.shared.applyPresetDefaults()
    }
  }

  let presets = PresetManager()

  /// Single source of truth for controller assignment: activates the port,
  /// binds the device, applies the default profile, and saves — atomically.
  /// reconcile()/change-notification stay in this manager's wrappers, not the service.
  private let assignmentService = ControllerAssignmentService(writer: BridgeControllerConfigWriter())

  override private init() {}

  // ObjC proxies for wrapped Swift properties
  var overlayVisibleObjc: Bool {
    get { overlayVisible }
    set { overlayVisible = newValue }
  }

  var overlayModeRaw: Int {
    get { overlayMode.rawValue }
    set { overlayMode = OverlayMode(rawValue: newValue) ?? .auto }
  }

  // MARK: Observing / Publishers

  private var observers: [NSObjectProtocol] = []
  private var cancellables = Set<AnyCancellable>()
  private let controllerConnectedSubject = PassthroughSubject<GCController, Never>()
  private let controllerDisconnectedSubject = PassthroughSubject<GCController?, Never>()
  private let fastForwardToggledSubject = PassthroughSubject<Bool, Never>()
  private var isObserving = false

  var controllerConnectedPublisher: AnyPublisher<GCController, Never> { controllerConnectedSubject.eraseToAnyPublisher() }
  var controllerDisconnectedPublisher: AnyPublisher<GCController?, Never> { controllerDisconnectedSubject.eraseToAnyPublisher() }
  var fastForwardToggledPublisher: AnyPublisher<Bool, Never> { fastForwardToggledSubject.eraseToAnyPublisher() }

  func startObserving() {
    guard !isObserving else { return }
    isObserving = true

    // Initial configure
    configureAllControllersForCurrentPlatform()

    // Connect/disconnect notifications
    let onConnect = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
      guard let self = self else { return }
      if let c = note.object as? GCController {
        self.configureControllerForCurrentPlatform(c)
        self.presets.applyCurrentPreset()
        EmulationCoordinator.autoAssignNewestExternalControllerToFirstAvailableSlot()
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
        self.reconcile()
      }
    }
    let onDisconnect = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
      guard let self = self else { return }
      let c = note.object as? GCController
      self.presets.applyCurrentPreset()
      self.controllerDisconnectedSubject.send(c)
      self.reconcile()
      self.updateWiimoteEmulationForExternalControllers()
    }
    observers.append(contentsOf: [onConnect, onDisconnect])

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

  private func configureAllControllersForCurrentPlatform() {
    for c in GCController.controllers() { configureControllerForCurrentPlatform(c) }
  }

  private func configureControllerForCurrentPlatform(_ c: GCController) {
    // Install debug/gesture handlers
    installExtraInputHandlers(c)
    // Prefer receiving Menu button events inside app
    if let gp = c.extendedGamepad {
      if #available(iOS 14.0, tvOS 14.0, *) {
        gp.buttonMenu.preferredSystemGestureState = .disabled
        gp.buttonOptions?.preferredSystemGestureState = .disabled
      }
    }
    if let mgp = c.microGamepad {
      if #available(iOS 14.0, tvOS 14.0, *) {
        mgp.buttonMenu.preferredSystemGestureState = .disabled
      }
    }
  }

  // MARK: Overrides (GC)

  func registerGCOverride(forController index: Int) {
    InputOverriderBridge.registerGameCubeOverride(forController: index)
  }

  func unregisterGCOverride(forController index: Int) {
    InputOverriderBridge.unregisterGameCubeOverride(forController: index)
  }

  // MARK: Overlays

  func overlayIsWii(isWiiSystem: Bool) -> Bool {
    switch overlayMode {
    case .auto: return isWiiSystem
    case .gamecube: return false
    case .wii: return true
    }
  }

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

  // MARK: Ensure Wiimote1 Touchscreen

  func ensureWiimote1EmulatedTouchscreen() {
    DOLConfigBridge.setWiimoteSourceFor(1, source: 1)
    DOLConfigBridge.setConnectWiimotesForControllerInterface(true)
    EmulationCoordinator.ensureWiimoteDefaultsToTouchscreen(forPort: 1)
    updateWiimoteEmulationForExternalControllers()
    NotificationCenter.default.post(name: Self.assignmentsChanged, object: nil)
  }

  // MARK: Reconcile

  func reconcile() {
    TVControllerMappingBridge.reconcileAssignments()

    let state = ControllerStateStore.shared.snapshot()
    let decision = AssignmentEngine().decide(from: state)
    if let p = decision.reassignPortOneBased {
      // Route through the service so the chosen GC slot is activated, not just bound.
      assignmentService.assignTouchscreen(toPlayer: p - 1, system: .gamecube)
    }

    NotificationCenter.default.post(name: Self.assignmentsChanged, object: nil)
  }

  // MARK: Assign

  func assignTouchscreen(toGCPort portOneBased: Int) {
    assignmentService.assignTouchscreen(toPlayer: portOneBased - 1, system: .gamecube)
    reconcile()
  }

  func assign(_ controller: GCController, toGCPort portOneBased: Int) {
    let qualifier = TVControllerMappingBridge.qualifiedName(for: controller)
    if qualifier.isEmpty {
      // Fallback path retains the bridge's first-connected-MFi heuristic; still
      // activate the port so ports 2-4 produce input.
      assignmentService.activate(port: portOneBased - 1, system: .gamecube)
      TVControllerMappingBridge.assign(controller, toGCPort: portOneBased)
    } else {
      assignmentService.assign(qualifier: qualifier, toPlayer: portOneBased - 1, system: .gamecube)
    }
    controller.playerIndex = GCControllerPlayerIndex(rawValue: portOneBased - 1) ?? .indexUnset
    reconcile()
  }

  /// ObjC-callable assignment that routes through the service (activate + bind +
  /// profile + save). Used by the C++ auto-assign path so slots 2-4 get activated.
  /// `portZeroBased` is 0-based (Pad controller index).
  @objc func assignViaService(qualifier: String, toPort portZeroBased: Int, isWii: Bool) {
    let system: EmulatedSystem = isWii ? .wii : .gamecube
    assignmentService.assign(qualifier: qualifier, toPlayer: portZeroBased, system: system)
    reconcile()
  }

  // MARK: Defaults API

  func clearDefaultDevice(forGCPort portOneBased: Int) {
    assignmentService.clear(player: portOneBased - 1, system: .gamecube)
    reconcile()
  }

  func defaultDeviceQualifier(forGCPort portOneBased: Int) -> String {
    return TVControllerMappingBridge.defaultDevice(forGCPort: portOneBased) as String
  }

  // MARK: Wiimote Emulation for External Controllers

  // Assign Wiimote slots 2..4 to external controllers that have a touchpad (DS4/DS5).
  // Slot 1 remains for the on-screen touch overlay.
  func updateWiimoteEmulationForExternalControllers() {
    var nextSlot = 2
    wiimoteSlotByController.removeAll()

    // Disable all P2–P4 by default
    for s in 2 ... 4 { DOLConfigBridge.setWiimoteSourceFor(s, source: 0) }

    for c in GCController.controllers() {
      guard nextSlot <= 4 else { break }
      guard c.supportsTouchpad else { continue }
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
