// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum ConfigAdvancedModelBuilder {
  static func make(state: ConfigAdvancedState, apply: @escaping (ConfigAdvancedChange) -> Void) -> MenuModel {
    let memory = MenuSection(
      id: "memory-override", header: L("Memory Override"),
      footer: L("For CPU and interpreter performance options, see Performance Tuning in Settings or Config."),
      items: [
        SettingsRow.toggle("mem-override", L("Enable Emulated Memory Size Override"), state.memOverride,
                           L("Changes the emulated console's RAM. MEM1 is main memory (24–64 MB); MEM2 is Wii extended memory (64–128 MB). ⚠️ Enabling this breaks many games and invalidates save states made at a different size."),
                           set: { apply(.memOverride($0)) }),
        SettingsRow.stepper("mem1", L("MEM1"), Double(state.mem1MB), range: ConfigAdvancedLimits.mem1MB, step: 1, format: megabytes,
                            L("Main memory. The real console has 24 MB."),
                            enabled: state.memOverride, set: { apply(.mem1MB(Int($0))) }),
        SettingsRow.stepper("mem2", L("MEM2"), Double(state.mem2MB), range: ConfigAdvancedLimits.mem2MB, step: 1, format: megabytes,
                            L("Wii extended memory. The real console has 64 MB."),
                            enabled: state.memOverride, set: { apply(.mem2MB(Int($0))) }),
      ])

    let rtcToggle = SettingsRow.toggle("rtc-enabled", L("Enable Custom RTC"), state.rtcEnabled,
                                       L("Sets a custom real-time clock for the emulated console, separate from your device clock. Useful for time-based game events. If unsure, leave off."),
                                       set: { apply(.rtcEnabled($0)) })
    return MenuModel(sections: [memory, MenuSection(id: "custom-rtc", header: L("Custom RTC Options"), items: [rtcToggle] + rtcDateRow(state, apply))])
  }

  /// The old tvOS view had no date row (tvOS has no DatePicker); keep it that way.
  private static func rtcDateRow(_ state: ConfigAdvancedState, _ apply: @escaping (ConfigAdvancedChange) -> Void) -> [MenuItem] {
    #if os(tvOS)
    return []
    #else
    let title = L("Date and Time")
    let caption = L("The emulated console's clock when the game starts.")
    return [SettingsRow.custom(
      "rtc-date", title,
      AnyView(SettingsDateRow(title: title, caption: caption, date: rtcDateBinding(state, apply), isEnabled: state.rtcEnabled)),
      caption, enabled: state.rtcEnabled)]
    #endif
  }

  /// Split out so a test can drive the date without a view.
  static func rtcDateBinding(_ state: ConfigAdvancedState, _ apply: @escaping (ConfigAdvancedChange) -> Void) -> Binding<Date> {
    Binding(get: { state.rtcDate }, set: { apply(.rtcDate($0)) })
  }

  private static func megabytes(_ value: Double) -> String { String(format: L("%1$ld MB"), Int(value)) }
}

#if !os(tvOS)
/// The one control the engine has no role for. A `.custom` row renders only its view, so the row owns its title and caption.
struct SettingsDateRow: View {
  let title: String
  let caption: String
  let date: Binding<Date>
  let isEnabled: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      DatePicker(title, selection: date, displayedComponents: [.date, .hourAndMinute])
      Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .disabled(!isEnabled)
  }
}
#endif
