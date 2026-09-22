// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One concrete write the engine has decided on.
/// `qualifier == nil` means the on-screen Touchscreen virtual device.
struct ControllerAssignment: Equatable {
  let qualifier: String?
  /// 0-based player index (0 == Player 1 / Wiimote 1).
  let playerZeroBased: Int
  let system: EmulatedSystem
}

/// The complete set of writes to apply for one reconcile pass. An empty list
/// means the current configuration is already correct — the engine is
/// idempotent, so a second pass over an unchanged state decides nothing.
struct AssignmentDecision: Equatable {
  let assignments: [ControllerAssignment]

  static let none = AssignmentDecision(assignments: [])
}

/// The **only** policy that chooses which controller owns which port.
///
/// Before this, six writers raced: two C++ auto-assign policies, this engine, a
/// bridge fallback that bypassed the assignment service, and four scattered
/// `playerIndex =` writes. A single connect event could assign, re-decide and
/// reassign the same controller several times. The C++ side is now purely
/// mechanical — it enumerates devices and drops bindings to devices that have
/// gone away — and every *choice* is made here, from an immutable snapshot, and
/// applied through `ControllerAssignmentService`.
///
/// This engine deliberately does NOT reshape Dolphin's `ciface`/`ControllerEmu`
/// layer: Dolphin polls per frame through per-system INI profiles shared with
/// every other backend. The arbitration lives above it, in app code.
final class AssignmentEngine {
  /// Wiimote slot 1 is reserved for the on-screen touch overlay — see
  /// `ControllerManager.updateWiimoteEmulationForExternalControllers`, which
  /// starts external controllers at slot 2. GameCube pads have no such
  /// reservation and start at port 1.
  static let firstWiimoteSlotOneBased = 2
  static let firstGCPortOneBased = 1

  func decide(from state: ControllerStateStore.State) -> AssignmentDecision {
    let connected = Set(state.connectedQualifiers)
    let physical = state.connectedQualifiers.filter { !Self.isVirtual($0) }
    var out: [ControllerAssignment] = []

    // MARK: GameCube pads

    var gcSlots = Self.slots(from: state.portAssignments)
    for qualifier in physical where !gcSlots.contains(qualifier) {
      guard let slot = Self.firstFreeSlot(in: gcSlots, connected: connected,
                                          startingAt: Self.firstGCPortOneBased) else { break }
      gcSlots[slot] = qualifier
      out.append(ControllerAssignment(qualifier: qualifier, playerZeroBased: slot, system: .gamecube))
    }

    // With nothing physical attached, Pad 1 falls back to the on-screen pad so
    // the game is still playable.
    if physical.isEmpty, let pad1 = gcSlots.first, !Self.isVirtual(pad1) {
      out.append(ControllerAssignment(qualifier: nil, playerZeroBased: 0, system: .gamecube))
    }

    // MARK: Wiimotes
    //
    // The old C++ auto-assign hardcoded `isWii:NO`, so during a Wii game it only
    // ever touched GC pad config and silently no-opped on Wiimote config — a
    // controller connected mid-Wii-game reached no Wiimote slot at all. The
    // snapshot has always carried `isWiiSystem`; now it is actually used.
    guard state.isWiiSystem else { return AssignmentDecision(assignments: out) }

    var wiiSlots = Self.slots(from: state.wiimoteAssignments)
    for qualifier in physical where !wiiSlots.contains(qualifier) {
      guard let slot = Self.firstFreeSlot(in: wiiSlots, connected: connected,
                                          startingAt: Self.firstWiimoteSlotOneBased) else { break }
      wiiSlots[slot] = qualifier
      out.append(ControllerAssignment(qualifier: qualifier, playerZeroBased: slot, system: .wii))
    }

    return AssignmentDecision(assignments: out)
  }

  // MARK: Private

  /// Device qualifiers are `source/id/name`. The only virtual source the app
  /// binds is `iOS` (the on-screen Touchscreen); `MFi` and `DSUClient` are real
  /// hardware and are what auto-assign is for.
  private static func isVirtual(_ qualifier: String) -> Bool {
    qualifier.hasPrefix("iOS/")
  }

  private static func slots(from assignments: [ControllerStateStore.PortAssignment]) -> [String] {
    assignments.sorted { $0.portOneBased < $1.portOneBased }.map(\.defaultDeviceQualifier)
  }

  /// A slot is available when it is empty, holds the on-screen pad, or holds a
  /// device that is no longer enumerated. Slots below `startingAt` are reserved
  /// and never considered.
  private static func firstFreeSlot(in slots: [String], connected: Set<String>,
                                    startingAt oneBased: Int) -> Int? {
    let start = max(0, oneBased - 1)
    guard start < slots.count else { return nil }
    return (start ..< slots.count).first { index in
      let qualifier = slots[index]
      return qualifier.isEmpty || isVirtual(qualifier) || !connected.contains(qualifier)
    }
  }
}
