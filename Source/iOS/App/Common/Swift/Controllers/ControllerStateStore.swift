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
    /// GameCube pad bindings, ports 1-4.
    let portAssignments: [PortAssignment]
    /// Wiimote bindings, slots 1-4. Slot 1 is reserved for the touch overlay.
    let wiimoteAssignments: [PortAssignment]
    /// Qualified names of every device the ControllerInterface currently
    /// enumerates (iOS / MFi / DSU). A binding whose qualifier is missing from
    /// this list points at a device that has gone away.
    let connectedQualifiers: [String]
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
    var gcAssigns: [PortAssignment] = []
    var wiiAssigns: [PortAssignment] = []
    for port in 1 ... 4 {
      gcAssigns.append(PortAssignment(
        portOneBased: port,
        defaultDeviceQualifier: TVControllerMappingBridge.defaultDevice(forGCPort: port) as String))
      wiiAssigns.append(PortAssignment(
        portOneBased: port,
        defaultDeviceQualifier: TVControllerMappingBridge.defaultDevice(forWiimote: port) as String))
    }
    let connected = TVControllerMappingBridge.allQualifiedDevices()
    let isWii = TVEmulationBridge.isCurrentSystemWii()
    return State(
      controllers: controllers,
      portAssignments: gcAssigns,
      wiimoteAssignments: wiiAssigns,
      connectedQualifiers: connected,
      isWiiSystem: isWii)
  }
}
