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

/// One control group shown as a section. `id` is the raw C++ enum value the
/// bridge's `padControlNames(forGroup:group:)` / `wiimoteControlNames(...)`
/// take: `PadGroup` (`GCPadEmu.h`) for GameCube, `WiimoteEmu::WiimoteGroup`
/// (`WiimoteEmu.h`) for Wii. The legacy `groupIdForName` table used different,
/// wrong numbers (it labelled `MainStick` as "D-Pad"), which is why these are
/// spelled out here and pinned by a test.
struct RemapGroup: Identifiable, Equatable {
  let id: Int
  let title: String

  static let gamecube: [RemapGroup] = [
    RemapGroup(id: 0, title: L("Buttons")),
    RemapGroup(id: 3, title: L("D-Pad")),
    RemapGroup(id: 1, title: L("Control Stick")),
    RemapGroup(id: 2, title: L("C-Stick")),
    RemapGroup(id: 4, title: L("Triggers")),
    RemapGroup(id: 5, title: L("Rumble")),
    RemapGroup(id: 7, title: L("Options")),
  ]

  /// Attachments (7) is the header's Extension control, not a mappable group;
  /// Hotkeys, IMU* and IRPassthrough are not exposed.
  static let wii: [RemapGroup] = [
    RemapGroup(id: 0, title: L("Buttons")),
    RemapGroup(id: 1, title: L("D-Pad")),
    RemapGroup(id: 3, title: L("IR")),
    RemapGroup(id: 5, title: L("Swing")),
    RemapGroup(id: 4, title: L("Tilt")),
    RemapGroup(id: 2, title: L("Shake")),
    RemapGroup(id: 6, title: L("Rumble")),
    RemapGroup(id: 8, title: L("Options")),
  ]

  static func groups(for system: RemapSystem) -> [RemapGroup] {
    switch system {
    case .gamecube: return gamecube
    case .wii: return wii
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

/// One mappable control as the screen shows it: the group it belongs to, its
/// index within that group (what the bridge setters take), its display name
/// and its current expression (`RemapExpression.unboundDisplay` when empty).
struct RemapControlRow: Identifiable, Equatable {
  let groupId: Int
  let index: Int
  let name: String
  let expression: String

  var id: String { "\(groupId)-\(index)" }
}
