import Foundation
import GameController

@objcMembers
final class ControllerManager: NSObject {
  static let shared = ControllerManager()
  static let assignmentsChanged = Notification.Name("ControllerAssignmentsChanged")

  private override init() {}

  // MARK: Reconcile
  func reconcile() {
    TVControllerMappingBridge.reconcileAssignments()
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
