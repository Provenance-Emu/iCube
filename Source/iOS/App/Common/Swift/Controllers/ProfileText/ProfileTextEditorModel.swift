// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation

/// Everything the profile text editor reads and writes, behind one seam.
@MainActor
protocol ProfileTextIO {
  /// The slot's live mapping as a profile file's text.
  func profileText(for slot: PlayerSlot) -> String
  func profileKeys(for slot: PlayerSlot) -> [ProfileKey]
  /// The slot's bound device (`MFi/0/…`), or "" when it has none.
  func boundQualifier(for slot: PlayerSlot) -> String
  func inputNames(forQualifier qualifier: String) -> [String]
  func check(_ expression: String) -> ExpressionCheck
  /// Loads the text into the slot's live mapping, keeping the slot's device. False when it could not.
  func apply(_ text: String, to slot: PlayerSlot) -> Bool
}

struct LiveProfileTextIO: ProfileTextIO {
  /// Explicit and `nonisolated`, so it can be a default argument of the main-actor model's `init`.
  nonisolated init() {}

  func profileText(for slot: PlayerSlot) -> String {
    slot.kind == .gameCube
      ? TVControllerMappingBridge.profileText(forGCPort: slot.port)
      : TVControllerMappingBridge.profileText(forWiimote: slot.port)
  }

  func profileKeys(for slot: PlayerSlot) -> [ProfileKey] {
    let infos = slot.kind == .gameCube
      ? TVControllerMappingBridge.profileKeys(forGCPort: slot.port)
      : TVControllerMappingBridge.profileKeys(forWiimote: slot.port)
    return infos.map { info in
      let kind: ProfileKey.Kind
      switch info.kind {
      case .device: kind = .device
      case .control: kind = .control
      case .number: kind = .number
      case .toggle: kind = .toggle
      case .choice: kind = .choice(info.choices)
      case .output: kind = .output
      @unknown default: kind = .control
      }
      return ProfileKey(name: info.name, kind: kind)
    }
  }

  func boundQualifier(for slot: PlayerSlot) -> String {
    let reader = LiveControllerHubReader()
    return slot.kind == .gameCube ? reader.boundQualifier(forGCPort: slot.port) : reader.boundQualifier(forWiimote: slot.port)
  }

  func inputNames(forQualifier qualifier: String) -> [String] { LivePlayerScreenIO().inputNames(forQualifier: qualifier) }
  func check(_ expression: String) -> ExpressionCheck { LivePlayerScreenIO().check(expression) }

  func apply(_ text: String, to slot: PlayerSlot) -> Bool {
    let applied = slot.kind == .gameCube
      ? TVControllerMappingBridge.applyProfileText(text, forGCPort: slot.port, restoreDevice: true)
      : TVControllerMappingBridge.applyProfileText(text, forWiimote: slot.port, restoreDevice: true)
    // As a profile load does: this port's mapping changed, nobody else's device is re-decided.
    ControllerManager.shared.reconcile(autoAssign: false)
    return applied
  }
}

/// The profile text editor's state: the text, what is wrong with it and what can be typed next.
/// The editor edits a copy; nothing reaches the port's mapping until `apply()`, and `apply()`
/// refuses a text with an error in it.
@MainActor
@Observable
final class ProfileTextEditorModel {
  let slot: PlayerSlot
  private let io: any ProfileTextIO

  /// The text being edited. Every change is checked again.
  var text = "" {
    didSet { if text != oldValue { relint() } }
  }
  /// The cursor (UTF-16 offset): what the completion strip completes.
  var cursor = 0
  private(set) var diagnostics: [ProfileDiagnostic] = []
  private(set) var keys: [ProfileKey] = []
  private(set) var inputs: [String] = []
  private(set) var device = ""
  /// The text the port's mapping amounts to now: what Revert restores and "changed" is judged against.
  private(set) var appliedText = ""
  /// Each expression is parsed once: the linter runs on every keystroke.
  @ObservationIgnored private var checks: [String: ExpressionCheck] = [:]

  init(slot: PlayerSlot, io: any ProfileTextIO = LiveProfileTextIO()) {
    self.slot = slot
    self.io = io
  }

  /// Reads the port's mapping. Called when the editor appears.
  func load() {
    keys = io.profileKeys(for: slot)
    device = io.boundQualifier(for: slot)
    inputs = io.inputNames(forQualifier: device)
    appliedText = io.profileText(for: slot)
    text = appliedText
    cursor = min(cursor, (text as NSString).length)
    relint()
  }

  var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
  var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
  var isChanged: Bool { text != appliedText }
  var canApply: Bool { isChanged && errorCount == 0 }

  var completions: [ProfileCompletion] {
    ProfileTextCompletion.suggestions(text: text, cursor: cursor, keys: keys, inputs: inputs)
  }

  /// A file name for an export: "Player 1 - DualSense Wireless Controller.ini".
  var exportName: String {
    let name = ProfileTextLinter.deviceName(device)
    return name.isEmpty ? slot.title : "\(slot.title) - \(name)"
  }

  /// Writes the text into the port's mapping. False (and nothing written) while the text has an
  /// error, or when the core could not read it.
  @discardableResult
  func apply() -> Bool {
    guard errorCount == 0, io.apply(ProfileTextDocument.normalized(text), to: slot) else { return false }
    // Read back what the core made of it: defaults are dropped and the keys come out in its order.
    load()
    return true
  }

  func revert() {
    text = appliedText
    cursor = min(cursor, (text as NSString).length)
  }

  /// Replaces the text with an imported file's. Nothing is applied until the player says so.
  func replaceText(with imported: String) {
    text = imported.replacingOccurrences(of: "\r\n", with: "\n")
    cursor = 0
  }

  /// Writes a completion over the fragment it completes and puts the cursor after it.
  func accept(_ completion: ProfileCompletion) {
    let ns = text as NSString
    guard completion.range.location + completion.range.length <= ns.length else { return }
    text = ns.replacingCharacters(in: completion.range, with: completion.insertion)
    cursor = completion.range.location + (completion.insertion as NSString).length
  }

  private func relint() {
    diagnostics = ProfileTextLinter.lint(text, keys: keys, device: device, inputs: inputs) { [self] expression in
      if let known = checks[expression] { return known }
      let verdict = io.check(expression)
      checks[expression] = verdict
      return verdict
    }
  }
}
