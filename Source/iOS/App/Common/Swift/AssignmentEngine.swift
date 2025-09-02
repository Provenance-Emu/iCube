import Foundation

struct AssignmentDecision {
  let reassignPortOneBased: Int?
  let assignQualifierToPort: (qualifier: String, portOneBased: Int)?
}

final class AssignmentEngine {
  func decide(from state: ControllerStateStore.State) -> AssignmentDecision {
    // Keep current assignments if any physical controller is already assigned
    let assignedPhysical = state.portAssignments.first { !$0.defaultDeviceQualifier.isEmpty && !$0.defaultDeviceQualifier.contains("Touchscreen") }
    if assignedPhysical != nil {
      return AssignmentDecision(reassignPortOneBased: nil, assignQualifierToPort: nil)
    }
    // If no physical assigned, ensure Pad1 has Touchscreen
    if let p1 = state.portAssignments.first(where: { $0.portOneBased == 1 }), (p1.defaultDeviceQualifier.isEmpty || !p1.defaultDeviceQualifier.contains("Touchscreen")) {
      return AssignmentDecision(reassignPortOneBased: 1, assignQualifierToPort: nil)
    }
    return AssignmentDecision(reassignPortOneBased: nil, assignQualifierToPort: nil)
  }
}
