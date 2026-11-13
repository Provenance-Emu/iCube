// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The profile text editor: a port's mapping as the text of a Dolphin profile, for players who
/// would rather edit, paste or share the `.ini` than tap through capture rows.
///
/// - The text is coloured as it is typed (`ProfileTextHighlighter`) and checked per line
///   (`ProfileTextLinter`): unknown keys, expressions the core's parser rejects, inputs the device
///   does not have.
/// - A strip above the keyboard completes keys, input names and functions (`ProfileTextCompletion`).
/// - Import reads a `.ini` from Files into the editor; Export hands the text to Files or a share.
/// - Nothing reaches the port until Apply, which a text with an error cannot do.
///
/// iOS only: tvOS has no keyboard worth editing a file with and no Files.
@MainActor
struct ProfileTextEditorView: View {
  @State private var model: ProfileTextEditorModel
  /// Called after a successful Apply, so the player screen re-reads the port.
  private let onApplied: () -> Void

  @State private var isImporting = false
  @State private var isExporting = false
  @State private var showsProblems = false
  @State private var jumpToLine: Int?
  @State private var notice: String?
  @Environment(\.dismiss) private var dismiss

  /// `init` reads nothing: the player screen builds its destinations on every render.
  init(slot: PlayerSlot, io: any ProfileTextIO = LiveProfileTextIO(), onApplied: @escaping () -> Void = {}) {
    _model = State(initialValue: ProfileTextEditorModel(slot: slot, io: io))
    self.onApplied = onApplied
  }

  var body: some View {
    VStack(spacing: 0) {
      ProfileTextView(
        text: $model.text, cursor: $model.cursor, diagnostics: model.diagnostics, jumpToLine: $jumpToLine)
      if !model.completions.isEmpty { completionStrip }
      problemsBar
    }
    .navigationTitle(L("Edit as Text"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button { isImporting = true } label: { Label(L("Import…"), systemImage: "square.and.arrow.down") }
          Button { isExporting = true } label: { Label(L("Export…"), systemImage: "square.and.arrow.up") }
          ShareLink(item: model.text) { Label(L("Share Text"), systemImage: "text.bubble") }
          Button(role: .destructive) { model.revert() } label: { Label(L("Revert Changes"), systemImage: "arrow.uturn.backward") }
            .disabled(!model.isChanged)
        } label: {
          Image(systemName: "ellipsis.circle").accessibilityLabel(L("More"))
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button(L("Apply")) { apply() }
          .fontWeight(.semibold)
          .disabled(!model.canApply)
      }
    }
    .onAppear { model.load() }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: ProfileTextFile.readableContentTypes) { result in
      importFile(result)
    }
    .fileExporter(
      isPresented: $isExporting, document: ProfileTextFile(text: ProfileTextDocument.normalized(model.text)),
      contentType: ProfileTextFile.iniType, defaultFilename: model.exportName
    ) { result in
      if case .failure(let error) = result { notice = error.localizedDescription }
    }
    .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
      Button(L("OK"), role: .cancel) {}
    }
    .padBackNavigation()
  }

  // MARK: Completion strip

  private var completionStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(model.completions) { completion in
          Button(completion.title) { model.accept(completion) }
            .font(.system(.footnote, design: .monospaced))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
    .background(.bar)
  }

  // MARK: Problems

  private var problemsBar: some View {
    VStack(spacing: 0) {
      Divider()
      Button {
        withAnimation { showsProblems.toggle() }
      } label: {
        HStack(spacing: 12) {
          if model.diagnostics.isEmpty {
            Label(L("No problems"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
          } else {
            if model.errorCount > 0 {
              Label("\(model.errorCount)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if model.warningCount > 0 {
              Label("\(model.warningCount)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
          }
          Spacer()
          if model.isChanged { Text(L("Not applied")).foregroundStyle(.secondary) }
          if !model.diagnostics.isEmpty {
            Image(systemName: showsProblems ? "chevron.down" : "chevron.up").foregroundStyle(.secondary)
          }
        }
        .icubeText(.detail)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(model.diagnostics.isEmpty)
      .accessibilityLabel(String(format: L("%1$d errors, %2$d warnings"), model.errorCount, model.warningCount))
      if showsProblems, !model.diagnostics.isEmpty {
        List(model.diagnostics) { diagnostic in
          Button {
            jumpToLine = diagnostic.line
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
              VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.message).icubeText(.detail)
                Text(String(format: L("Line %d"), diagnostic.line)).icubeText(.detail).foregroundStyle(.secondary)
              }
            }
          }
          .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .frame(maxHeight: 180)
      }
    }
    .background(.bar)
  }

  // MARK: Actions

  private func apply() {
    if model.apply() {
      onApplied()
      EmulationToast.post(String(format: L("Applied to %@"), model.slot.title))
    } else {
      notice = L("The profile could not be applied.")
    }
  }

  private func importFile(_ result: Result<URL, Error>) {
    switch result {
    case .failure(let error):
      notice = error.localizedDescription
    case .success(let url):
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      guard let data = try? Data(contentsOf: url), data.count <= ProfileTextFile.maximumBytes,
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
        notice = L("That file is not a controller profile.")
        return
      }
      model.replaceText(with: text)
    }
  }
}

/// The exported or imported file: plain text with the `.ini` extension.
struct ProfileTextFile: FileDocument {
  /// A profile is a few kilobytes; anything far larger is not one.
  static let maximumBytes = 1_000_000
  static let iniType = UTType(filenameExtension: "ini", conformingTo: .plainText) ?? .plainText
  static let readableContentTypes: [UTType] = [iniType, .plainText, .text, .data]
  static let writableContentTypes: [UTType] = [iniType]

  var text: String

  init(text: String) { self.text = text }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.text = text
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

/// The coloured, monospaced text view. A `UITextView`, because `TextEditor` cannot colour runs,
/// cannot turn off smart quotes and dashes (which would rewrite `'` and `--` inside an expression),
/// and does not report the cursor.
private struct ProfileTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var cursor: Int
  let diagnostics: [ProfileDiagnostic]
  @Binding var jumpToLine: Int?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.delegate = context.coordinator
    view.font = Self.font
    view.autocorrectionType = .no
    view.autocapitalizationType = .none
    view.spellCheckingType = .no
    view.smartQuotesType = .no
    view.smartDashesType = .no
    view.smartInsertDeleteType = .no
    view.keyboardType = .asciiCapable
    view.alwaysBounceVertical = true
    view.keyboardDismissMode = .interactive
    view.backgroundColor = .systemBackground
    view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
    view.accessibilityIdentifier = "profile-text"
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.parent = self
    if view.text != text {
      // The model changed the text (load, revert, import, a completion): keep the cursor it set.
      // Setting the text moves the selection to the end first; that must not be reported back.
      context.coordinator.isApplyingModel = true
      view.text = text
      view.selectedRange = NSRange(location: min(cursor, (text as NSString).length), length: 0)
      context.coordinator.isApplyingModel = false
    }
    // Never recolour under an input method's marked text: it would commit the composition.
    if view.markedTextRange == nil { Self.colour(view.textStorage, text: text, diagnostics: diagnostics) }
    if let line = jumpToLine {
      DispatchQueue.main.async {
        jumpToLine = nil
        guard let target = ProfileTextDocument.lines(of: view.text).first(where: { $0.number == line }) else { return }
        view.selectedRange = NSRange(location: target.range.location + target.range.length, length: 0)
        view.scrollRangeToVisible(target.range)
        view.becomeFirstResponder()
      }
    }
  }

  private static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

  private static func colour(_ storage: NSTextStorage, text: String, diagnostics: [ProfileDiagnostic]) {
    let whole = NSRange(location: 0, length: storage.length)
    guard whole.length == (text as NSString).length else { return }
    storage.beginEditing()
    storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: whole)
    for token in ProfileTextHighlighter.tokens(for: text) where token.range.location + token.range.length <= whole.length {
      storage.addAttribute(.foregroundColor, value: colour(of: token.kind), range: token.range)
    }
    for diagnostic in diagnostics where diagnostic.range.location + diagnostic.range.length <= whole.length {
      let tint = diagnostic.severity == .error ? UIColor.systemRed : UIColor.systemOrange
      storage.addAttribute(.backgroundColor, value: tint.withAlphaComponent(0.16), range: diagnostic.range)
    }
    storage.endEditing()
  }

  private static func colour(of kind: ProfileTextToken.Kind) -> UIColor {
    switch kind {
    case .comment: return .secondaryLabel
    case .section: return .systemPurple
    case .key: return .label
    case .punctuation, .operatorSymbol: return .secondaryLabel
    case .control: return .systemTeal
    case .string: return .systemGreen
    case .variable: return .systemPink
    case .number, .boolean: return .systemOrange
    case .function: return .systemIndigo
    case .invalid: return .systemRed
    }
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ProfileTextView
    /// True while `updateUIView` writes the model's text and cursor into the view.
    var isApplyingModel = false

    init(_ parent: ProfileTextView) { self.parent = parent }

    func textViewDidChange(_ textView: UITextView) {
      guard !isApplyingModel else { return }
      parent.text = textView.text
      parent.cursor = textView.selectedRange.location
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      let location = textView.selectedRange.location
      guard !isApplyingModel, parent.cursor != location else { return }
      // Selection changes arrive during view updates too; publish after the update.
      DispatchQueue.main.async { [parent] in parent.cursor = location }
    }
  }
}
#endif
