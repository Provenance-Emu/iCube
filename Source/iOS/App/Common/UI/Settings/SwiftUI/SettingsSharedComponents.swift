// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation

// Keeps a settings view bound to Dolphin's Config (the single source of truth): seeds it on appear
// and re-reads on every Config change (Reset / game-INI / runtime). Replaces the copy-pasted
// `.onAppear { syncX() } + .onReceive(DOLConfigChangedNotification) { syncX() }` pair on each view.
struct ConfigSynced: ViewModifier {
  let sync: () -> Void
  func body(content: Content) -> some View {
    content
      .onAppear(perform: sync)
      .onReceive(NotificationCenter.default.publisher(for: .DOLConfigChanged)) { _ in sync() }
  }
}

extension View {
  /// Seed from Config on appear and re-sync whenever Config changes. `sync` should copy the relevant
  /// Config values into the view's @State (the view's existing syncX() function).
  func configSynced(_ sync: @escaping () -> Void) -> some View {
    modifier(ConfigSynced(sync: sync))
  }
}
// MARK: tvOS-friendly selectable row
struct SettingsSelectRow: View {
  let label: String
  let checked: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack {
        Text(label)
        Spacer()
        if checked { Image(systemName: "checkmark") }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
#if os(tvOS)
    .buttonStyle(.automatic)
#else
    .buttonStyle(.plain)
#endif
#if os(tvOS)
    .focusable(true)
#endif
  }
}

// MARK: tvOS fallback for sliders
internal struct TVIntStepper: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  let step: Int
#if os(tvOS)
  @FocusState private var isFocused: Bool
#endif
  var body: some View {
#if os(tvOS)
    HStack(spacing: 16) {
      Image(systemName: "minus.circle")
      Text("\(value)")
      Image(systemName: "plus.circle")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .focusable(true)
    .focused($isFocused)
    .padding(8)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 4)
    )
    .animation(.easeInOut(duration: 0.12), value: isFocused)
    .onMoveCommand { direction in
      switch direction {
      case .left:
        value = max(range.lowerBound, value - step)
      case .right:
        value = min(range.upperBound, value + step)
      default:
        break
      }
    }
#else
    HStack(spacing: 16) {
      Button("−") { value = max(range.lowerBound, value - step) }
      Text("\(value)")
      Button("+") { value = min(range.upperBound, value + step) }
    }
#endif
  }
}

// MARK: Tooltip helper
struct HelpButton: ToolbarContent {
  let helpKey: String
  func helpText() -> String {
    let raw = L(helpKey)
    return raw
      .replacingOccurrences(of: "<br><br>", with: "\n\n")
      .replacingOccurrences(of: "<br>", with: "\n")
      .replacingOccurrences(of: "<dolphin_emphasis>", with: "")
      .replacingOccurrences(of: "</dolphin_emphasis>", with: "")
  }
  var body: some ToolbarContent {
    ToolbarItem(placement: .navigationBarTrailing) {
      HelpSheetButton(text: helpText())
    }
  }
}

struct HelpSheetButton: View {
  let text: String
  @State private var showing = false
  var body: some View {
    Button { showing = true } label: { Image(systemName: "info.circle") }
      .accessibilityLabel(L("Help"))
      .sheet(isPresented: $showing) {
        NavigationStack {
          ScrollView { Text(text).padding() }
            .navigationTitle(L("Help"))
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Close")) { showing = false } } }
        }
      }
  }
}
