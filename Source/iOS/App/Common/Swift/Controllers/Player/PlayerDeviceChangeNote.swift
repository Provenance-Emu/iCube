// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

extension PlayerScreenIO {
  /// The slot's control rows, every group in remap order, for the extension it holds.
  func controlRows(for slot: PlayerSlot, attachment: Int) -> [RemapControlRow] {
    let system: RemapSystem = slot.kind == .gameCube ? .gamecube : .wii
    return RemapGroup.groups(for: system, attachment: attachment).flatMap {
      controlRows(owner: $0.owner, group: $0.id, port: slot.port)
    }
  }
}

/// The profile bookkeeping around ONE device assignment (decision 5), shared by the player screen
/// and the hub, so the name and "(edited)" a port shows never go stale whichever screen moved the
/// device. `begin` before the write, `finish` right after it (and before any reload that reads the
/// name).
///
/// Which profile the port holds now is, as far as the app can know (Dolphin does not record it):
/// - Touchscreen: both kinds reload the "Touchscreen" profile whenever the bound device changes
///   (`assignTouchscreen(toGCPort:)`, the coordinator's BindTouchscreen), and it always changes.
/// - A pad: the assignment loads the pad's default profile unless the port's mapping binds
///   something on that pad (ControllerAssignmentService.assign), and the bridge's answer to that
///   cannot be read after the fact (the profile is already loaded). What can: the port's control
///   rows (each carries its expression). Changed means the default was loaded; unchanged means
///   the mapping was kept and the remembered name stays.
/// - No Device unbinds the device only; the mapping and its name stay.
@MainActor
struct PlayerDeviceChangeNote {
  private let slot: PlayerSlot
  private let reader: any ControllerHubReading
  private let io: any PlayerScreenIO
  private let memory: PlayerProfileMemory
  private let controlsBefore: [RemapControlRow]
  private let entryBefore: PlayerProfileMemory.Entry?

  /// Reads the port as it is before the write.
  static func begin(
    slot: PlayerSlot, reader: any ControllerHubReading, io: any PlayerScreenIO, memory: PlayerProfileMemory
  ) -> PlayerDeviceChangeNote {
    PlayerDeviceChangeNote(slot: slot, reader: reader, io: io, memory: memory)
  }

  private init(slot: PlayerSlot, reader: any ControllerHubReading, io: any PlayerScreenIO, memory: PlayerProfileMemory) {
    self.slot = slot
    self.reader = reader
    self.io = io
    self.memory = memory
    controlsBefore = io.controlRows(for: slot, attachment: Self.attachment(slot, reader))
    entryBefore = memory.entry(for: slot.playerID, qualifier: Self.qualifier(slot, reader))
  }

  /// Reads the port again and remembers or carries the profile name, after `choice` was written.
  func finish(choice: PlayerDeviceChoice) {
    let controlsAfter = io.controlRows(for: slot, attachment: Self.attachment(slot, reader))
    let reloadedDefault = choice == .touchscreen || (choice != .noDevice && controlsAfter != controlsBefore)
    let qualifier = Self.qualifier(slot, reader)
    if reloadedDefault, !qualifier.isEmpty {
      // A pad that got its own mapping back (the assignment's mapping stash) keeps the name it
      // had on this port; otherwise its default profile was loaded.
      let restoredName = choice == .touchscreen ? nil : memory.storedName(for: slot.playerID, qualifier: qualifier)
      if let name = restoredName ?? io.defaultProfileName(forQualifier: qualifier) {
        memory.remember(name, for: slot.playerID, qualifier: qualifier)
      }
    } else if !reloadedDefault, let entryBefore {
      memory.adopt(entryBefore, for: slot.playerID, qualifier: qualifier)
    }
  }

  private static func qualifier(_ slot: PlayerSlot, _ reader: any ControllerHubReading) -> String {
    slot.kind == .gameCube ? reader.boundQualifier(forGCPort: slot.port) : reader.boundQualifier(forWiimote: slot.port)
  }

  private static func attachment(_ slot: PlayerSlot, _ reader: any ControllerHubReading) -> Int {
    slot.kind == .gameCube ? 0 : reader.wiiExtension(forWiimote: slot.port)
  }
}
