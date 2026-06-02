import Foundation
import GameController

@objcMembers
final class ControllerStateStore: NSObject, Sendable {
  static let shared = ControllerStateStore()
  override private init() {}

  struct ControllerInfo: Equatable {
    let id: ObjectIdentifier
    let vendorName: String
    let category: String
    let hasExtendedGamepad: Bool
    let hasMicroGamepad: Bool
  }

  struct PortAssignment: Equatable {
    let portOneBased: Int
    let defaultDeviceQualifier: String
  }

  struct State: Equatable {
    let controllers: [ControllerInfo]
    let portAssignments: [PortAssignment]
    let isWiiSystem: Bool
  }

  func snapshot() -> State {
    let controllers = GCController.controllers().map { c in
      ControllerInfo(
        id: ObjectIdentifier(c),
        vendorName: c.vendorName ?? "",
        category: c.productCategory,
        hasExtendedGamepad: c.extendedGamepad != nil,
        hasMicroGamepad: c.microGamepad != nil
      )
    }
    var assigns: [PortAssignment] = []
    for port in 1 ... 4 {
      let q = TVControllerMappingBridge.defaultDevice(forGCPort: port) as String
      assigns.append(PortAssignment(portOneBased: port, defaultDeviceQualifier: q))
    }
    let isWii = TVEmulationBridge.isCurrentSystemWii()
    return State(controllers: controllers, portAssignments: assigns, isWiiSystem: isWii)
  }
}
