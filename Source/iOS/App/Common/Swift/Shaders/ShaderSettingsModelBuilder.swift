// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct ShaderSettingsSnapshot {
  var enabled: Bool
  var presetLabel: String
  var flipVertically: Bool
  var preCopy: Bool
  var lastError: String?
  var isDebug: Bool
}

enum ShaderSettingsChange: Equatable { case enabled(Bool), flipVertically(Bool), preCopy(Bool) }

/// Pure: the Shaders leaf as rows. The preset picker and the debug tools are pushed views.
enum ShaderSettingsModelBuilder {
  static func make(_ s: ShaderSettingsSnapshot, picker: AnyView, debugTools: AnyView, apply: @escaping (ShaderSettingsChange) -> Void) -> MenuModel {
    var main: [MenuItem] = [
      SettingsRow.toggle("enabled", L("Enable Shader"), s.enabled, L("Runs the chosen post-processing preset over the game."), icon: "wand.and.stars", set: { apply(.enabled($0)) }),
      {
        var item = SettingsRow.destination("preset", L("Preset"), L("Choose a shader preset."), icon: "paintbrush", view: picker)
        item.badge = s.presetLabel
        item.isEnabled = s.enabled
        return item
      }(),
    ]
    if let error = s.lastError { main.append(SettingsRow.caption("error", error)) }
    var sections = [
      MenuSection(id: "shader", header: L("Post-Processing Shader"),
                  footer: L("Note: Some shaders can reduce performance. Heavier effects may cause slowdowns depending on your device."), items: main),
      MenuSection(id: "advanced", header: L("Advanced"),
                  footer: L("Compatibility options for specific devices or shaders. Most people never need these."), items: [
        SettingsRow.toggle("flip", L("Flip vertically"), s.flipVertically, L("Flips the shader output for presets that render upside down."), icon: "arrow.up.and.down", set: { apply(.flipVertically($0)) }),
        SettingsRow.toggle("precopy", L("Enable pre-copy (compat)"), s.preCopy, L("Copies the frame before the shader runs. Fixes a few presets on some devices."), icon: "doc.on.doc", set: { apply(.preCopy($0)) }),
      ]),
    ]
    if s.isDebug {
      sections.append(MenuSection(id: "developer", header: L("Developer"), items: [
        SettingsRow.destination("debug-tools", L("Shader Debug Tools"), L("Compile log and pipeline inspection."), icon: "ladybug", view: debugTools),
      ]))
    }
    return MenuModel(sections: sections)
  }
}
