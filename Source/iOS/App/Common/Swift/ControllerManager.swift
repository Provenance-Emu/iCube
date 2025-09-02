import Foundation
import GameController

@objcMembers
final class ControllerManager: NSObject, ObservableObject {
  static let shared = ControllerManager()
  static let assignmentsChanged = Notification.Name("ControllerAssignmentsChanged")

  enum OverlayMode: Int { case auto, gamecube, wii }
  @Published var overlayVisible: Bool = true
  @Published var overlayMode: OverlayMode = .auto

  private override init() {}

  // MARK: Overlays
  func overlayIsWii(isWiiSystem: Bool) -> Bool {
    switch overlayMode {
    case .auto: return isWiiSystem
    case .gamecube: return false
    case .wii: return true
    }
  }

  // MARK: Reconcile
  func reconcile() {
    // Run legacy reconciliation to clear phantoms and auto-assign connected devices
    TVControllerMappingBridge.reconcileAssignments()

    // Compute a single decision based on a snapshot, then apply via existing bridge methods
    let state = ControllerStateStore.shared.snapshot()
    let decision = AssignmentEngine().decide(from: state)
    if let p = decision.reassignPortOneBased {
      TVControllerMappingBridge.assignTouchscreen(toGCPort: p)
    }
    // (Optional) assign by qualifier path reserved for future expansion

    NotificationCenter.default.post(name: Self.assignmentsChanged, object: nil)
  }

  // MARK: Assign
  func assignTouchscreen(toGCPort portOneBased: Int) {
    TVControllerMappingBridge.assignTouchscreen(toGCPort: portOneBased)
    reconcile()
  }

  func assign(_ controller: GCController, toGCPort portOneBased: Int) {
    TVControllerMappingBridge.assign(controller, toGCPort: portOneBased)
    reconcile()
  }

  // MARK: Defaults API
  func clearDefaultDevice(forGCPort portOneBased: Int) {
    TVControllerMappingBridge.clearDefaultDevice(forGCPort: portOneBased)
    reconcile()
  }

  func defaultDeviceQualifier(forGCPort portOneBased: Int) -> String {
    return TVControllerMappingBridge.defaultDevice(forGCPort: portOneBased) as String
  }
}
