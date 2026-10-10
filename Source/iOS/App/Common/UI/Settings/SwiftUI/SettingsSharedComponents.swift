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
  ///
  /// `sync` only assigns @State. Write Config from the control's binding with `onSet`, never from
  /// `.onChange(of:)`: SwiftUI runs `onChange` for the assignments `sync` makes too, so a value it
  /// read (a game INI's, or the adaptive clock's CurrentRun override) went straight back into the
  /// Base layer and was saved as the user's own setting.
  func configSynced(_ sync: @escaping () -> Void) -> some View {
    modifier(ConfigSynced(sync: sync))
  }
}

/// The pill beside a setting whose user value (Base) is outranked right now: "Auto" while an auto
/// controller drives it for this run, "Game" while the running game's settings do. The control
/// beside it is disabled: it shows and edits the user's own value, which applies again once the
/// override goes away.
struct ConfigOverrideBadge: View {
  let override: DOLConfigOverride

  var body: some View {
    if let title = Self.title(for: override) {
      Text(title)
        .font(.caption).bold()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.blue.opacity(0.1), in: Capsule())
    }
  }

  static func title(for override: DOLConfigOverride) -> String? {
    switch override {
    case .auto: return L("Auto")
    case .game: return L("Game")
    default: return nil
    }
  }
}

extension Binding where Value: Equatable {
  /// The binding to give a control whose value is written somewhere (Config, user defaults).
  /// `action` runs only when the control sets a different value, i.e. the user changed it.
  /// Assigning the underlying @State directly, as `configSynced` does, never calls it.
  func onSet(_ action: @escaping (Value) -> Void) -> Binding<Value> {
    Binding(
      get: { wrappedValue },
      set: { newValue, transaction in
        guard newValue != wrappedValue else { return }
        self.transaction(transaction).wrappedValue = newValue
        action(newValue)
      }
    )
  }
}

extension Binding where Value == Int {
  /// An Int setting as the Double a `Slider` takes.
  var asDouble: Binding<Double> {
    Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Int($0) })
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

/// Shared inline-description helper. Wraps any control with a `.caption` secondary
/// line directly under it. This is the single canonical row style for the whole
/// settings surface — every page uses it instead of section footers or tap-to-open
/// info popovers, so descriptions are always visible inline.
@ViewBuilder
func settingsCaption<Content: View>(_ content: Content, _ caption: String) -> some View {
  VStack(alignment: .leading, spacing: 4) {
    content
    Text(caption)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// NavigationLink row with an inline caption *inside* the link's label, so the row
/// keeps its disclosure chevron and full-row tap target (wrapping a NavigationLink
/// in an external VStack would strip both). `label` is the normal row content
/// (e.g. an HStack with title + trailing value).
@ViewBuilder
func settingsNavCaption<Destination: View, Label: View>(
  destination: Destination,
  _ caption: String,
  @ViewBuilder label: () -> Label
) -> some View {
  NavigationLink(destination: destination) {
    VStack(alignment: .leading, spacing: 4) {
      label()
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Reset All Settings, with its confirmation. One view so the iPhone toolbar and the About leaf share the alert text
/// (the sidebar shell has no toolbar, so About is where tvOS and iPad reach it).
struct SettingsResetAllButton<Label: View>: View {
  var role: ButtonRole?
  let label: Label
  @State private var confirming = false

  init(role: ButtonRole? = nil, @ViewBuilder label: () -> Label) {
    self.role = role
    self.label = label()
  }

  var body: some View {
    Button(role: role) { confirming = true } label: { label }
      .alert(L("Reset All Settings"), isPresented: $confirming) {
        Button(L("Cancel"), role: .cancel) {}
        Button(L("Reset"), role: .destructive) { DOLConfigBridge.resetAllToDefaults() }
      } message: {
        Text(L("This will reset all settings to factory defaults. This may require restarting emulation."))
      }
  }
}
