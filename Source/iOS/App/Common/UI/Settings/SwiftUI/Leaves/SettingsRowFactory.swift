// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The one place a settings row becomes a `MenuItem`; Tasks 3-6 use it instead of nested helpers.
/// Rows never write anything themselves: `set` is the builder's `apply(.change(value))`.
enum SettingsRow {
  static func toggle(_ id: String, _ title: String, _ value: Bool, _ description: String,
                     enabled: Bool = true, badge: String? = nil, set: @escaping (Bool) -> Void) -> MenuItem {
    MenuItem(id: id, title: title, role: .toggle(Binding(get: { value }, set: set)),
             badge: badge, isEnabled: enabled, description: description)
  }

  static func cycle<V: Hashable>(_ id: String, _ title: String, _ options: [(String, V)], _ value: V, _ description: String,
                                 enabled: Bool = true, badge: String? = nil, set: @escaping (V) -> Void) -> MenuItem {
    MenuItem(id: id, title: title,
             role: .cycle(options: options.map { ($0.0, AnyHashable($0.1)) },
                          selection: Binding(get: { AnyHashable(value) }, set: { if let v = $0.base as? V { set(v) } })),
             badge: badge, isEnabled: enabled, description: description)
  }

  static func stepper(_ id: String, _ title: String, _ value: Double, range: ClosedRange<Double>, step: Double,
                      format: @escaping (Double) -> String, _ description: String,
                      enabled: Bool = true, badge: String? = nil, set: @escaping (Double) -> Void) -> MenuItem {
    MenuItem(id: id, title: title,
             role: .stepper(MenuStepper(value: Binding(get: { value }, set: set), range: range, step: step, format: format)),
             badge: badge, isEnabled: enabled, description: description)
  }

  static func action(_ id: String, _ title: String, _ description: String, icon: String? = nil,
                     enabled: Bool = true, run: @escaping () -> Void) -> MenuItem {
    MenuItem(id: id, title: title, icon: icon, role: .action(run), isEnabled: enabled, description: description)
  }

  static func destination(_ id: String, _ title: String, _ description: String, view: AnyView) -> MenuItem {
    MenuItem(id: id, title: title, role: .destination(view), description: description)
  }
}
