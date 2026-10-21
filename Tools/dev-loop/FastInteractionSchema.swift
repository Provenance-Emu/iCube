// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreFoundation

/// Validate the entire plan before any app activation or input.
enum FastInteractionSchema {
  enum Failure: Error { case invalid(String) }

  static func validate(_ actions: [[String: Any]], tvOS: Bool) throws {
    guard (1...100).contains(actions.count) else { throw Failure.invalid("Use 1–100 actions") }
    let selection: Set<String> = ["identifier", "label", "type", "timeout"]
    let keys: [String: Set<String>] = [
      "launch": ["arguments"], "activate": [], "capture": ["name", "ax"],
      "remote": ["button", "duration"], "tap": selection,
      "type": selection.union(["text", "clear"]),
      "assert": selection.union(["exists", "enabled", "focused", "value", "valueContains"])
    ]
    for (index, action) in actions.enumerated() {
      guard let operation = action["op"] as? String, let allowed = keys[operation],
            Set(action.keys).isSubset(of: allowed.union(["op"])) else {
        throw Failure.invalid("Unknown operation or field in action \(index)")
      }
      for field in ["ax", "clear", "exists", "enabled", "focused"] where action[field] != nil {
        guard isBoolean(action[field]!) else { throw Failure.invalid("\(field) must be Boolean") }
      }
      for field in ["identifier", "label", "type", "text", "name", "button", "value", "valueContains"] where action[field] != nil {
        guard action[field] is String else { throw Failure.invalid("\(field) must be a string") }
      }
      for (field, range) in [("timeout", 0.1...10.0), ("duration", 0.1...3.0)] where action[field] != nil {
        guard let value = action[field] as? NSNumber, !isBoolean(value),
              value.doubleValue.isFinite, range.contains(value.doubleValue) else {
          throw Failure.invalid("\(field) must be a bounded number")
        }
      }
      if let arguments = action["arguments"], !(arguments is [String]) {
        throw Failure.invalid("Launch arguments must be strings")
      }
      if ["tap", "type", "assert"].contains(operation) {
        let selectors = [action["identifier"] as? String, action["label"] as? String].compactMap { $0 }
        guard selectors.count == 1, !selectors[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw Failure.invalid("Choose one non-empty identifier or label")
        }
        if let kind = action["type"] as? String,
           !["button", "textField", "secureTextField", "staticText", "switch", "slider", "any"].contains(kind) {
          throw Failure.invalid("Unsupported element type")
        }
      }
      if operation == "type" {
        guard let text = action["text"] as? String, text.count <= 10_000 else {
          throw Failure.invalid("Text must have at most 10,000 characters")
        }
      }
      if action["focused"] != nil && !tvOS { throw Failure.invalid("Focus assertions require tvOS") }
      if operation == "assert", action["exists"] as? Bool == false,
         ["enabled", "focused", "value", "valueContains"].contains(where: { action[$0] != nil }) {
        throw Failure.invalid("A missing element cannot have state assertions")
      }
      if let name = action["name"] as? String, name.isEmpty || name.count > 120 {
        throw Failure.invalid("Capture names must have 1–120 characters")
      }
      if operation == "remote" {
        guard tvOS, let button = action["button"] as? String,
              ["up", "down", "left", "right", "select", "menu", "back", "playPause"].contains(button) else {
          throw Failure.invalid("A supported remote button requires tvOS")
        }
      }
    }
  }

  private static func isBoolean(_ value: Any) -> Bool {
    CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
  }
}
