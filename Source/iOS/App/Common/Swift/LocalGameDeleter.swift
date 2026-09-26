// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Deletes local game files for the Library's delete actions, off the main thread. ICUBE-2F: the
/// delete alert's action called `removeItem` on main, and removing a multi-GB image or a Wii folder
/// title hung the app for 3-4 s (once per game in a batch delete).
enum LocalGameDeleter {
  struct Outcome: Sendable {
    var deleted: [String] = []
    var failures: [(path: String, message: String)] = []
  }

  /// `remove` is injectable so tests can observe where the removal runs. `Task.detached` rather
  /// than relying on a nonisolated `async` func hopping off the caller's actor, which stops being
  /// true under Swift 6.2's NonisolatedNonsendingByDefault.
  static func delete(
    paths: [String],
    remove: @escaping @Sendable (String) throws -> Void = { try FileManager.default.removeItem(atPath: $0) }
  ) async -> Outcome {
    await Task.detached(priority: .userInitiated) {
      var outcome = Outcome()
      for path in paths {
        do {
          try remove(path)
          outcome.deleted.append(path)
        } catch {
          outcome.failures.append((path, error.localizedDescription))
        }
      }
      return outcome
    }.value
  }
}
