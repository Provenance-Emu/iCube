// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// Pure model for the button-remap screen (`RemapPlayerView`). Nothing in this
// file touches the bridges, GameController or SwiftUI, so all of it is unit
// tested in `RemapModelTests`.

/// Which emulated controller a remap screen edits.
enum RemapSystem: Equatable {
  case gamecube
  case wii
}

/// Which bridge family a `RemapGroup`'s `id` is looked up through. GameCube
/// has no attached extension so it gets a single `.gcPad` owner; a Wii Remote
/// and its extension are separate `EmulatedController`-like group sets that
/// happen to number their groups from 0 independently, so `owner` is what
/// disambiguates them once both are shown together.
enum RemapGroupOwner: Equatable {
  case gcPad
  case wiimote
  case nunchuk
  case classic
}

/// One control group shown as a section. `id` is the raw C++ enum value the
/// bridge's `padControlNames(forGroup:group:)` / `wiimoteControlNames(...)` /
/// `wiimoteExtensionControlNames(forIndex:kind:group:)` take, scoped by
/// `owner`: `PadGroup` (`GCPadEmu.h`) for `.gcPad`, `WiimoteEmu::WiimoteGroup`
/// (`WiimoteEmu.h`) for `.wiimote`, `WiimoteEmu::NunchukGroup` (`Nunchuk.h`)
/// for `.nunchuk`, `WiimoteEmu::ClassicGroup` (`Classic.h`) for `.classic`.
/// The legacy `groupIdForName` table used different, wrong numbers (it
/// labelled `MainStick` as "D-Pad"), which is why these are spelled out here
/// and pinned by a test.
struct RemapGroup: Identifiable, Equatable {
  let owner: RemapGroupOwner
  let id: Int
  let title: String

  /// Unique across every group shown together. `id` alone is not: a Wii
  /// Remote's own groups and its extension's both number from 0. This is what
  /// `RemapPlayerView` uses for row/section identity and its `rows` dictionary
  /// key.
  var key: String { Self.key(owner: owner, id: id) }

  /// Same value as `key`, computable without an instance — `RemapPlayerView`
  /// uses this to address `rows` from a bare `(owner, groupId)` pair (e.g.
  /// after a write-back, where it never reconstructed the full `RemapGroup`).
  static func key(owner: RemapGroupOwner, id: Int) -> String { "\(owner)-\(id)" }

  static let gamecube: [RemapGroup] = [
    RemapGroup(owner: .gcPad, id: 0, title: L("Buttons")),
    RemapGroup(owner: .gcPad, id: 3, title: L("D-Pad")),
    RemapGroup(owner: .gcPad, id: 1, title: L("Control Stick")),
    RemapGroup(owner: .gcPad, id: 2, title: L("C-Stick")),
    RemapGroup(owner: .gcPad, id: 4, title: L("Triggers")),
    RemapGroup(owner: .gcPad, id: 5, title: L("Rumble")),
    RemapGroup(owner: .gcPad, id: 7, title: L("Options")),
  ]

  /// Attachments (7) is the header's Extension control, not a mappable group;
  /// Hotkeys, IMU* and IRPassthrough are not exposed.
  static let wiimote: [RemapGroup] = [
    RemapGroup(owner: .wiimote, id: 0, title: L("Buttons")),
    RemapGroup(owner: .wiimote, id: 1, title: L("D-Pad")),
    RemapGroup(owner: .wiimote, id: 3, title: L("IR")),
    RemapGroup(owner: .wiimote, id: 5, title: L("Swing")),
    RemapGroup(owner: .wiimote, id: 4, title: L("Tilt")),
    RemapGroup(owner: .wiimote, id: 2, title: L("Shake")),
    RemapGroup(owner: .wiimote, id: 6, title: L("Rumble")),
    RemapGroup(owner: .wiimote, id: 8, title: L("Options")),
  ]

  /// `WiimoteEmu::NunchukGroup` (`Nunchuk.h`): `Buttons=0, Stick=1, Tilt=2,
  /// Swing=3, Shake=4, IMUAccelerometer=5`. The motion group is never exposed,
  /// same as the Wii Remote's own IMU* groups.
  static let nunchuk: [RemapGroup] = [
    RemapGroup(owner: .nunchuk, id: 0, title: L("Nunchuk Buttons")),
    RemapGroup(owner: .nunchuk, id: 1, title: L("Nunchuk Stick")),
    RemapGroup(owner: .nunchuk, id: 4, title: L("Nunchuk Shake")),
    RemapGroup(owner: .nunchuk, id: 2, title: L("Nunchuk Tilt")),
    RemapGroup(owner: .nunchuk, id: 3, title: L("Nunchuk Swing")),
  ]

  /// `WiimoteEmu::ClassicGroup` (`Classic.h`): `Buttons=0, Triggers=1,
  /// DPad=2, LeftStick=3, RightStick=4`.
  static let classic: [RemapGroup] = [
    RemapGroup(owner: .classic, id: 0, title: L("Classic Buttons")),
    RemapGroup(owner: .classic, id: 2, title: L("Classic D-Pad")),
    RemapGroup(owner: .classic, id: 3, title: L("Classic Left Stick")),
    RemapGroup(owner: .classic, id: 4, title: L("Classic Right Stick")),
    RemapGroup(owner: .classic, id: 1, title: L("Classic Triggers")),
  ]

  /// `attachment` is `WiimoteEmu::ExtensionNumber`'s raw value
  /// (`Source/Core/Core/HW/WiimoteEmu/ExtensionPort.h`): `NONE=0, NUNCHUK=1,
  /// CLASSIC=2, GUITAR=3, …` — the same convention already documented on
  /// `WiimoteSlotOptions.extensionCount` and that
  /// `WiimoteSlotOptions.selectedExtension(forWiimote:)` returns. Ignored for
  /// `.gamecube`. An attachment with no groups defined yet (Guitar, Drums, …)
  /// falls back to the plain Wii Remote groups rather than assuming Nunchuk.
  static func groups(for system: RemapSystem, attachment: Int = 0) -> [RemapGroup] {
    switch system {
    case .gamecube:
      return gamecube
    case .wii:
      switch attachment {
      case 1: return wiimote + nunchuk
      case 2: return wiimote + classic
      default: return wiimote
      }
    }
  }
}

/// Expression strings as Dolphin's `ControlReference` parser wants them.
enum RemapExpression {
  /// What the bridge returns for an unbound control.
  static let unboundDisplay = "—"

  /// A bare device-relative reference: `` `Button A` ``. The device itself is
  /// the pad's default device, so no `MFi/0/...` prefix is needed — the same
  /// shape as every line in `Data/Sys/Profiles/GCPad/Physical Controller.ini`.
  static func expression(forInputName name: String) -> String {
    "`\(name)`"
  }

  /// Motion-sensor inputs are never capture candidates: gravity keeps an
  /// accelerometer half pinned near 1.0 and a hand tremor would win the race
  /// against the button the user is trying to press.
  static func isCapturable(inputName name: String) -> Bool {
    !(name.hasPrefix("Accel ") || name.hasPrefix("Gyro "))
  }
}

/// The live-capture state machine for one armed control row.
///
/// Fed one `poll(_:)` per tick (~60 Hz) with the device's full input-state
/// vector (`TVControllerMappingBridge.inputStates(forQualifiedDevice:)`, same
/// order as `inputsForQualifiedDevice:`). Every input is a 0…1 half — buttons
/// 0/1, pressure buttons 0…1, stick axes split into `X+`/`X-` halves by the
/// MFi backend — so one threshold covers digital and analog alike.
///
/// Phases:
/// 1. `waitingForRelease` — inputs that were already past `threshold` when the
///    row was armed (the A press that activated it) must fall below
///    `restEpsilon` first. Touch arming holds nothing, so this passes on the
///    first poll. On passing, the vector is re-snapshotted as the rest
///    baseline, which absorbs trigger drift and stick centering error.
/// 2. `listening` — the input with the largest rise above its rest value that
///    stays past `threshold` for `holdPolls` consecutive polls wins. Nothing
///    qualifying for `timeoutPolls` polls ends the session with `.timedOut`.
struct RemapCaptureMachine: Equatable {
  struct Config: Equatable {
    var threshold: Float = 0.35
    var restEpsilon: Float = 0.15
    var holdPolls: Int = 3
    /// 5 s at 60 Hz.
    var timeoutPolls: Int = 300
  }

  enum Phase: Equatable {
    case waitingForRelease
    case listening
    case finished
  }

  enum Result: Equatable {
    case captured(inputIndex: Int)
    case timedOut
  }

  let config: Config
  private(set) var phase: Phase = .waitingForRelease
  private let capturable: [Bool]
  private let heldAtArm: [Bool]
  private var restBaseline: [Float]
  private var candidate: Int?
  private var candidateRun = 0
  private var listeningPolls = 0

  /// - Parameters:
  ///   - baseline: the input vector at arm time.
  ///   - capturable: per-input eligibility (see `RemapExpression.isCapturable`).
  init(baseline: [Float], capturable: [Bool], config: Config = Config()) {
    self.config = config
    self.capturable = capturable
    self.restBaseline = baseline
    self.heldAtArm = baseline.map { $0 > config.threshold }
  }

  /// Advance one tick. Returns a result exactly once, when the session ends.
  mutating func poll(_ values: [Float]) -> Result? {
    switch phase {
    case .finished:
      return nil

    case .waitingForRelease:
      for (i, held) in heldAtArm.enumerated() where held {
        if value(values, i) >= config.restEpsilon { return nil }
      }
      restBaseline = (0 ..< restBaseline.count).map { value(values, $0) }
      phase = .listening
      return nil

    case .listening:
      listeningPolls += 1
      var best: Int?
      var bestDelta: Float = 0
      for i in 0 ..< restBaseline.count where i < capturable.count && capturable[i] {
        let delta = value(values, i) - restBaseline[i]
        if delta > config.threshold && delta > bestDelta {
          best = i
          bestDelta = delta
        }
      }
      if let best {
        if best == candidate {
          candidateRun += 1
        } else {
          candidate = best
          candidateRun = 1
        }
        if candidateRun >= config.holdPolls {
          phase = .finished
          return .captured(inputIndex: best)
        }
      } else {
        candidate = nil
        candidateRun = 0
      }
      if listeningPolls >= config.timeoutPolls {
        phase = .finished
        return .timedOut
      }
      return nil
    }
  }

  /// A device that vanished mid-capture reports an empty vector; missing
  /// entries read as released so the session times out instead of crashing.
  private func value(_ values: [Float], _ i: Int) -> Float {
    i < values.count ? values[i] : 0
  }
}

/// D18 moved this engine into `MenuControllerNav`
/// (`Common/Swift/Menu/MenuControllerNav.swift`), which `MenuScreen` now uses
/// too; this alias keeps `RemapPlayerView` and `RemapModelTests` compiling
/// unchanged (behaviour is identical — same file, same tests, new name).
typealias RemapControllerNav = MenuControllerNav

/// One mappable control as the screen shows it: the group it belongs to (and
/// that group's owner, so the write-back goes through the right bridge call),
/// its index within that group (what the bridge setters take), its display
/// name and its current expression (`RemapExpression.unboundDisplay` when
/// empty).
struct RemapControlRow: Identifiable, Equatable {
  let owner: RemapGroupOwner
  let groupId: Int
  let index: Int
  let name: String
  let expression: String

  /// Includes `owner` for the same reason `RemapGroup.key` does: a Wii
  /// Remote's own group and its extension's can share `groupId`.
  var id: String { "\(owner)-\(groupId)-\(index)" }
}
