// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The apply/MRU logic `ShaderQuickPickerView` had inline, shared with the pause overlay's Shaders
/// tile, which cycles through the recently used presets (unified menu UX spec §5.2).
enum ShaderQuickApply {
  static let noneValue: AnyHashable = AnyHashable("")
  static let mruKey = "shader_mru"
  static let presetPathKey = "shader_preset_path"
  static let enabledKey = "shader_enabled"
  static let mruLimit = 10

  static var currentPath: String? { UserDefaults.standard.string(forKey: presetPathKey) }

  static func displayName(forPath path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }

  /// "None", then the current preset (if any) and the MRU list, deduplicated, in that order.
  static func options(mru: [String], current: String?) -> [(String, AnyHashable)] {
    var paths: [String] = []
    if let current, !current.isEmpty { paths.append(current) }
    for path in mru where !paths.contains(path) { paths.append(path) }
    return [(L("None"), noneValue)] + paths.map { (displayName(forPath: $0), AnyHashable($0)) }
  }

  /// Applies to the live pipeline and persists. `nil` is "None": clears the preset without touching
  /// `shader_enabled` (turning one shader off is not disabling the feature).
  static func apply(path: String?) {
    let defaults = UserDefaults.standard
    guard let path, !path.isEmpty else {
      defaults.removeObject(forKey: presetPathKey)
      NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
      DOLShaderPostProcessor.shared.applyPresetPath(nil)
      return
    }
    let normalized = ShaderLibrary.normalizedPath(path)
    defaults.set(true, forKey: enabledKey)
    defaults.set(normalized, forKey: presetPathKey)
    NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
    DOLShaderPostProcessor.shared.applyPresetPath(normalized)
    pushMRU(normalized)
  }

  static func pushMRU(_ normalized: String, defaults: UserDefaults = .standard) {
    var list = (defaults.stringArray(forKey: mruKey) ?? []).filter { $0 != normalized }
    list.insert(normalized, at: 0)
    if list.count > mruLimit { list = Array(list.prefix(mruLimit)) }
    defaults.set(list, forKey: mruKey)
  }
}
