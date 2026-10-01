// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Advanced → Raw Bindings → one control: its Dolphin expression as editable text, pushed from the
/// player screen. The core's parser checks the text as it is typed. Text that does not parse shows
/// the parser's message and cannot be saved (controller hub spec, Edge cases).
///
/// Typing needs touch, a keyboard or the tvOS keyboard (select the field on tvOS). A pad can still
/// reach Save, Revert and Clear (the pad's way to unbind), and Back pops.
struct ExpressionEditorView: View {
  let title: String
  /// `RemapControlRow.editableExpression`: never the bridges' "—".
  let original: String
  let check: (String) -> ExpressionCheck
  /// Writes the text; false when it was refused.
  let save: (String) -> Bool

  @State private var text: String
  @Environment(\.dismiss) private var dismiss

  init(title: String, original: String, check: @escaping (String) -> ExpressionCheck, save: @escaping (String) -> Bool) {
    self.title = title
    self.original = original
    self.check = check
    self.save = save
    _text = State(initialValue: original)
  }

  var body: some View {
    MenuScreen(
      model: ExpressionEditorModelBuilder.make(
        text: $text, original: original, check: check(text),
        onSave: { if save(text) { dismiss() } },
        onRevert: { text = original },
        onClear: { text = "" }),
      style: .list,
      onBack: { dismiss() })
      .navigationTitle(title)
  }
}

/// Pure: the editor's rows for the current text and its check.
enum ExpressionEditorModelBuilder {
  static func make(
    text: Binding<String>, original: String, check: ExpressionCheck,
    onSave: @escaping () -> Void, onRevert: @escaping () -> Void, onClear: @escaping () -> Void
  ) -> MenuModel {
    // Only an edit is judged: a legacy expression that reports a syntax error can still work through
    // the parser's bareword fallback, and it must never be rejected or rewritten untouched.
    let isEdited = text.wrappedValue != original
    return MenuModel(sections: [
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
      MenuSection(id: "actions", items: [
        MenuItem(
          id: "expression-save", title: L("Save"), icon: "square.and.arrow.down", role: .action(onSave),
          isEnabled: isEdited && check.canSave),
        MenuItem(
          id: "expression-revert", title: L("Revert"), icon: "arrow.uturn.backward", role: .action(onRevert),
          isEnabled: isEdited),
        MenuItem(
          id: "expression-clear", title: L("Clear"), icon: "xmark.circle", role: .destructive(onClear),
          isEnabled: !text.wrappedValue.isEmpty),
      ]),
    ])
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
