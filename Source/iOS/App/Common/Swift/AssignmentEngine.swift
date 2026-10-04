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

/// A slot the user chose explicitly in the setup / remap UI. Auto-assignment never takes a
/// pinned slot: before this, picking Touchscreen for Player 1 with a pad connected was undone by
/// the very next reconcile, because a slot holding the on-screen pad counted as free.
struct PinnedSlot: Hashable {
  let system: EmulatedSystem
  let playerZeroBased: Int
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
/// mechanical — it enumerates devices, binds, loads and saves — and every
/// *choice* is made here, from an immutable snapshot, and applied through
/// `ControllerAssignmentService`. A device that goes away keeps its binding (it
/// reads as a free slot here), as Dolphin itself keeps it.
///
/// This engine deliberately does NOT reshape Dolphin's `ciface`/`ControllerEmu`
/// layer: Dolphin polls per frame through per-system INI profiles shared with
/// every other backend. The arbitration lives above it, in app code.
final class AssignmentEngine {
  static let firstGCPortOneBased = 1

  /// Wii Remote 1 belongs to the on-screen controls only while they are actually using it
  /// (`State.touchscreenHoldsWiimote1`: iOS, controls shown, Wii Remote 1 on the Touchscreen).
  /// Otherwise (tvOS, controls hidden, or Wii Remote 1 on another device) the first pad takes it,
  /// instead of a lone pad landing on Wii Remote 2.
  static func firstWiimoteSlotOneBased(for state: ControllerStateStore.State) -> Int {
    state.touchscreenHoldsWiimote1 ? 2 : 1
  }

  func decide(from state: ControllerStateStore.State, pinned: Set<PinnedSlot> = []) -> AssignmentDecision {
    let connected = Set(state.connectedQualifiers)
    let physical = state.connectedQualifiers.filter { !Self.isVirtual($0) }
    var out: [ControllerAssignment] = []
    let pinnedGC = Set(pinned.filter { $0.system == .gamecube }.map(\.playerZeroBased))
    let pinnedWii = Set(pinned.filter { $0.system == .wii }.map(\.playerZeroBased))

    // MARK: GameCube pads

    // A pad goes where the running title reads it: GameCube ports for a GameCube title, Wii
    // Remotes for a Wii title. Binding it to both made one press reach two emulated controllers
    // in Wii games that also read the GameCube ports. Bindings already in place are left alone.

    var gcSlots = Self.slots(from: state.portAssignments)
    if !state.isWiiSystem {
      for qualifier in physical where !gcSlots.contains(qualifier) {
        guard let slot = Self.firstFreeSlot(in: gcSlots, connected: connected,
                                            startingAt: Self.firstGCPortOneBased, pinned: pinnedGC) else { break }
        gcSlots[slot] = qualifier
        out.append(ControllerAssignment(qualifier: qualifier, playerZeroBased: slot, system: .gamecube))
      }
    }

    // With nothing physical attached, Pad 1 falls back to the on-screen pad so
    // the game is still playable (unless the user pinned something else there).
    // A pad that disconnected keeps its binding, so Pad 1 may still name it: the
    // service stashes that pad's mapping before the Touchscreen takes the port and
    // gives it back when the pad returns. tvOS enumerates no Touchscreen, and
    // there the binding simply waits for the pad.
    if physical.isEmpty, state.connectedQualifiers.contains(where: Self.isVirtual),
       let pad1 = gcSlots.first, !Self.isVirtual(pad1), !pinnedGC.contains(0) {
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
    let firstWiimoteSlot = Self.firstWiimoteSlotOneBased(for: state)
    for qualifier in physical where !wiiSlots.contains(qualifier) {
      guard let slot = Self.firstFreeSlot(in: wiiSlots, connected: connected,
                                          startingAt: firstWiimoteSlot, pinned: pinnedWii) else { break }
      wiiSlots[slot] = qualifier
      out.append(ControllerAssignment(qualifier: qualifier, playerZeroBased: slot, system: .wii))
    }

    return AssignmentDecision(assignments: out)
  }

  /// Device qualifiers are `source/id/name`. The only virtual source the app
  /// binds is `iOS` (the on-screen Touchscreen); `MFi` and `DSUClient` are real
  /// hardware and are what auto-assign is for.
  static func isVirtual(_ qualifier: String) -> Bool {
    qualifier.hasPrefix("iOS/")
  }

  /// A real controller's qualifier, connected or not: what a mapping stash is kept for.
  static func isPhysical(_ qualifier: String) -> Bool {
    !qualifier.isEmpty && !isVirtual(qualifier)
  }

  // MARK: Private

  private static func slots(from assignments: [ControllerStateStore.PortAssignment]) -> [String] {
    assignments.sorted { $0.portOneBased < $1.portOneBased }.map(\.defaultDeviceQualifier)
  }

  /// A slot is available when it is empty, holds the on-screen pad, or holds a
  /// device that is no longer enumerated. Slots below `startingAt` are reserved
  /// and never considered.
  private static func firstFreeSlot(in slots: [String], connected: Set<String>,
                                    startingAt oneBased: Int, pinned: Set<Int> = []) -> Int? {
    let start = max(0, oneBased - 1)
    guard start < slots.count else { return nil }
    return (start ..< slots.count).first { index in
      guard !pinned.contains(index) else { return false }
      let qualifier = slots[index]
      return qualifier.isEmpty || isVirtual(qualifier) || !connected.contains(qualifier)
    }
  }
}
