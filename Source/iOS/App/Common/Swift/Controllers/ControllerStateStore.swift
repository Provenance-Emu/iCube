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
    /// Wiimote bindings, slots 1-4.
    let wiimoteAssignments: [PortAssignment]
    /// Qualified names of every device the ControllerInterface currently
    /// enumerates (iOS / MFi / DSU). A binding whose qualifier is missing from
    /// this list points at a device that has gone away.
    let connectedQualifiers: [String]
    let isWiiSystem: Bool
    /// The on-screen controls are using Wii Remote 1: iOS only, the controls are shown, and
    /// Wii Remote 1 is active and bound to the Touchscreen. Auto-assign then starts at Wii Remote 2.
    let touchscreenHoldsWiimote1: Bool
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
    #if os(iOS)
    let touchscreenHoldsWiimote1 = ControllerManager.shared.overlayVisible
      && DOLConfigBridge.wiimoteSource(for: 1) == 1
      && (wiiAssigns.first?.defaultDeviceQualifier ?? "").hasPrefix("iOS/")
    #else
    // No touchscreen to hold it: the first pad is Wii Remote 1.
    let touchscreenHoldsWiimote1 = false
    #endif
    return State(
      controllers: controllers,
      portAssignments: gcAssigns,
      wiimoteAssignments: wiiAssigns,
      connectedQualifiers: connected,
      isWiiSystem: isWii,
      touchscreenHoldsWiimote1: touchscreenHoldsWiimote1)
  }
}
