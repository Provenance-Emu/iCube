// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The DSU role (`dsu_role`): whether this device receives motion from a DSU server or shares its
/// own input as one. The two readers disagreed on the unset value: Settings → Controllers showed
/// "receiver" while the library's "Start DSU Controller" (the only code that acts on the role)
/// treated it as "sender". Registered on every launch from `AppDelegate`, like `MotionSettings`.
/// `DefaultPreferences.plist` must not define it: `FirstRunInitializationService` registers that
/// plist on every launch after `AppDelegate`, and would win.
enum DSUSettings {
  enum Key {
    static let role = "dsu_role"
  }

  enum Role: String {
    case receiver
    case sender
  }

  /// "sender": what the app did with the key unset (`TVLibraryView`'s `?? "sender"`).
  static let defaults: [String: Any] = [Key.role: Role.sender.rawValue]

  static func registerDefaults(in store: UserDefaults = .standard) {
    store.register(defaults: defaults)
  }

  static func role(in store: UserDefaults = .standard) -> Role {
    Role(rawValue: store.string(forKey: Key.role) ?? "") ?? .sender
  }
}
