// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Observation
import SwiftUI

/// Advanced → Raw Bindings → one control: its Dolphin expression as editable text, pushed from the
/// player screen. The core's parser checks the text as it is typed. Text that does not parse shows
/// the parser's message and cannot be saved (controller hub spec, Edge cases).
///
/// Typing needs touch, a keyboard or the tvOS keyboard (select the field on tvOS). A pad can still
/// reach Save, Revert and Clear (the pad's way to unbind), and Back pops.
///
/// Below the actions, Inputs lists the bound device's inputs with their live values, as desktop
/// Dolphin's input list does: selecting one adds it to the expression (`ExpressionEditorModelBuilder
/// .inserting`), so a pad or a Siri Remote can build an expression without typing.
@MainActor
struct ExpressionEditorView: View {
  let title: String
  /// `RemapControlRow.editableExpression`: never the bridges' "—".
  let original: String
  /// The bound device's labels (`BindingDisplay`), for the input rows' subtitles.
  let family: DeviceFamily
  /// The bound device's input names, read once when the editor first renders: the player screen
  /// builds this view for every Raw Bindings row on every render, so `init` must read nothing.
  let loadInputs: () -> [String]
  /// The control's expression in the device's default profile (a file read), read once on appear;
  /// nil when there is none.
  let loadDefault: () -> String?
  let check: (String) -> ExpressionCheck
  /// Writes the text; false when it was refused.
  let save: (String) -> Bool

  @State private var text: String
  @State private var inputs: [String]?
  @State private var defaultExpression: String?
  @State private var live: LiveInputValues
  @Environment(\.dismiss) private var dismiss

  init(
    title: String, original: String, family: DeviceFamily = .unknown, loadInputs: @escaping () -> [String] = { [] },
    loadDefault: @escaping () -> String? = { nil }, readInputStates: @escaping () -> [Float] = { [] },
    check: @escaping (String) -> ExpressionCheck, save: @escaping (String) -> Bool
  ) {
    self.title = title
    self.original = original
    self.family = family
    self.loadInputs = loadInputs
    self.loadDefault = loadDefault
    self.check = check
    self.save = save
    _text = State(initialValue: original)
    _live = State(initialValue: LiveInputValues(read: readInputStates))
  }

  var body: some View {
    MenuScreen(
      model: ExpressionEditorModelBuilder.make(
        text: $text, original: original, check: check(text),
        onSave: { if save(text) { dismiss() } },
        onRevert: { text = original },
        onClear: { text = "" },
        defaultExpression: defaultExpression,
        onDefault: { if let defaultExpression { text = defaultExpression } },
        inputs: inputs ?? loadInputs(), family: family, live: live,
        onInsert: { text = ExpressionEditorModelBuilder.inserting($0, into: text) }),
      style: .list,
      onBack: { dismiss() })
      .navigationTitle(title)
      .onAppear {
        if inputs == nil {
          inputs = loadInputs()
          defaultExpression = loadDefault()
        }
        live.start()
      }
      .onDisappear { live.stop() }
  }
}

/// Pure: the editor's rows for the current text and its check.
enum ExpressionEditorModelBuilder {
  static func make(
    text: Binding<String>, original: String, check: ExpressionCheck,
    onSave: @escaping () -> Void, onRevert: @escaping () -> Void, onClear: @escaping () -> Void,
    defaultExpression: String? = nil, onDefault: @escaping () -> Void = {},
    inputs: [String] = [], family: DeviceFamily = .unknown, live: LiveInputValues? = nil,
    onInsert: @escaping (String) -> Void = { _ in }
  ) -> MenuModel {
    // Only an edit is judged: a legacy expression that reports a syntax error can still work through
    // the parser's bareword fallback, and it must never be rejected or rewritten untouched.
    let isEdited = text.wrappedValue != original
    var actionItems = [
      MenuItem(
        id: "expression-save", title: L("Save"), icon: "square.and.arrow.down", role: .action(onSave),
        isEnabled: isEdited && check.canSave),
      MenuItem(
        id: "expression-revert", title: L("Revert"), icon: "arrow.uturn.backward", role: .action(onRevert),
        isEnabled: isEdited),
    ]
    if let defaultExpression {
      // Puts the default profile's text in the field; Save writes it, like any edit.
      actionItems.append(MenuItem(
        id: "expression-default", title: L("Reset to Default"),
        subtitle: defaultExpression.isEmpty ? L("Unbound") : defaultExpression, icon: "arrow.counterclockwise",
        role: .action(onDefault), isEnabled: text.wrappedValue != defaultExpression))
    }
    actionItems.append(MenuItem(
      id: "expression-clear", title: L("Clear"), icon: "xmark.circle", role: .destructive(onClear),
      isEnabled: !text.wrappedValue.isEmpty))
    var sections = [
      MenuSection(id: "expression", header: L("Expression"), items: [
        MenuItem(id: "expression-text", title: L("Expression"), role: .custom(AnyView(ExpressionTextField(text: text)))),
      ]),
      MenuSection(id: "check", items: [
        // Enabled no-op so tvOS focus can reach it.
        MenuItem(
          id: "expression-check", title: isEdited ? check.message : L("Edit the expression, then Save."),
          icon: !isEdited || check.canSave ? "checkmark.circle" : "exclamationmark.triangle",
          tint: !isEdited || check.canSave ? nil : .orange, role: .action({})),
      ]),
      MenuSection(id: "actions", items: actionItems),
    ]
    if !inputs.isEmpty {
      // A caption, never focused, like the player screen's help rows.
      let help = L("Select an input to add it to the expression. A value near 1 means it is pressed.")
      let caption = MenuItem(id: "inputs-help", title: help, role: .custom(AnyView(PlayerHelpCaption(text: help))), isEnabled: false)
      let rows: [MenuItem] = inputs.enumerated().map { index, name in
        let label = BindingDisplay.text(for: RemapExpression.expression(forInputName: name), family: family)
        return MenuItem(
          id: inputRowID(index), title: name, subtitle: label == name ? nil : label,
          role: .custom(AnyView(ExpressionInputRow(
            name: name, label: label, index: index, live: live, onInsert: { onInsert(name) }))),
          onCustomActivate: { onInsert(name) })
      }
      sections.append(MenuSection(id: "inputs", header: L("Inputs"), items: [caption] + rows))
    }
    return MenuModel(sections: sections)
  }

  static func inputRowID(_ index: Int) -> String { "input-\(index)" }

  /// `text` with `input` added as a backquoted reference: the whole expression when it is blank,
  /// otherwise OR'd on (`|`), which always parses and binds either input. A different operator is
  /// one edit away in the text field.
  static func inserting(_ input: String, into text: String) -> String {
    let reference = RemapExpression.expression(forInputName: input)
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? reference : trimmed + " | " + reference
  }
}

/// The text row: one `TextField`, so on tvOS it is one focus target that opens the keyboard.
private struct ExpressionTextField: View {
  @Binding var text: String

  var body: some View {
    TextField(L("Expression"), text: $text)
      .font(.body.monospaced())
      .autocorrectionDisabled()
      .textInputAutocapitalization(.never)
  }
}

/// The bound device's input values while the editor is on screen, polled ~10 times a second
/// (`TVControllerMappingBridge.inputStates(forQualifiedDevice:)`, the read capture uses). Only the
/// input rows observe it, so a tick redraws them and not the menu. Main thread only.
@MainActor
@Observable
final class LiveInputValues {
  static let interval: TimeInterval = 0.1

  /// Rounded to two places, and stored only when they change: an idle device redraws nothing.
  private(set) var values: [Float] = []
  @ObservationIgnored private let read: () -> [Float]
  @ObservationIgnored private var timer: Timer?

  init(read: @escaping () -> [Float]) {
    self.read = read
  }

  func value(at index: Int) -> Float { index >= 0 && index < values.count ? values[index] : 0 }

  func refresh() {
    let next = read().map { ($0 * 100).rounded() / 100 }
    if next != values { values = next }
  }

  func start() {
    guard timer == nil else { return }
    refresh()
    // `.common`, as the capture ticker: a `.default` timer starves while the List scrolls.
    let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }
}

/// One input of the bound device: its name, its readable label, its live value. One `Button`, so on
/// tvOS it is one focus target; a controller's A on iOS reaches it through `onCustomActivate`.
private struct ExpressionInputRow: View {
  let name: String
  let label: String
  let index: Int
  let live: LiveInputValues?
  let onInsert: () -> Void

  var body: some View {
    let value = live?.value(at: index) ?? 0
    Button(action: onInsert) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(name).font(.body.monospaced())
          if label != name {
            Text(label).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if live != nil {
          Text(String(format: "%.2f", value))
            .font(.callout.monospacedDigit())
            .foregroundStyle(value >= 0.5 ? Color.accentColor : Color.secondary)
        }
      }
    }
    .accessibilityLabel(label == name ? name : "\(name), \(label)")
  }
}
