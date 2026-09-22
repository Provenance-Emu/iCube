// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A small, dependency-free Markdown renderer covering exactly what iCube's bundled wiki
/// content uses today: ATX headings, paragraphs (with inline bold/italic/code/links via
/// `AttributedString(markdown:)`), bullet lists, numbered lists, simple pipe tables, fenced
/// code blocks, and blockquotes.
///
/// This is deliberately NOT a general CommonMark/GitBook implementation — it exists so the
/// Help feature doesn't need a new third-party SPM dependency (which the build gate would need
/// to freshly resolve). If wiki content grows real complexity later, swap this view's body for
/// a proper Markdown package without touching any caller.
struct MarkdownContentView: View {
  let markdown: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(inline(text))
        .font(font(forHeadingLevel: level))
        .fontWeight(.bold)
        .fixedSize(horizontal: false, vertical: true)
    case .paragraph(let text):
      Text(inline(text))
        .fixedSize(horizontal: false, vertical: true)
    case .bulletItem(let text):
      HStack(alignment: .top, spacing: 8) {
        Text("•")
        Text(inline(text))
      }
      .fixedSize(horizontal: false, vertical: true)
    case .numberedItem(let number, let text):
      HStack(alignment: .top, spacing: 8) {
        Text("\(number).")
        Text(inline(text))
      }
      .fixedSize(horizontal: false, vertical: true)
    case .codeBlock(let code):
      Text(code)
        .font(.system(.footnote, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    case .blockquote(let text):
      HStack(spacing: 8) {
        Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
        Text(inline(text)).foregroundStyle(.secondary)
      }
    case .divider:
      Divider()
    case .table(let headers, let rows):
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        GridRow {
          ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
            Text(header).font(.subheadline.bold())
          }
        }
        Divider()
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
              Text(inline(cell))
            }
          }
        }
      }
    }
  }

  private func font(forHeadingLevel level: Int) -> Font {
    switch level {
    case 1: return .title
    case 2: return .title2
    case 3: return .title3
    default: return .headline
    }
  }

  /// Parses inline Markdown (bold/italic/code/links) within a single block of text.
  /// Falls back to the raw text if it isn't valid inline Markdown for any reason.
  private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
  }
}

/// A single rendering unit produced by parsing Markdown text top to bottom.
enum MarkdownBlock: Equatable {
  case heading(level: Int, text: String)
  case paragraph(text: String)
  case bulletItem(text: String)
  case numberedItem(number: Int, text: String)
  case codeBlock(code: String)
  case blockquote(text: String)
  case divider
  case table(headers: [String], rows: [[String]])

  /// Splits a Markdown document into an ordered list of blocks. Line-oriented and single-pass;
  /// see the type doc on ``MarkdownContentView`` for what it intentionally does not support.
  static func parse(_ markdown: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraphLines: [String] = []
    var codeLines: [String] = []
    var tableLines: [String] = []
    var inCodeBlock = false

    func flushParagraph() {
      guard !paragraphLines.isEmpty else { return }
      blocks.append(.paragraph(text: paragraphLines.joined(separator: " ")))
      paragraphLines = []
    }

    func flushTable() {
      guard !tableLines.isEmpty else { return }
      defer { tableLines = [] }
      guard tableLines.count >= 2 else {
        // Not actually a table (need at least a header + separator row) — treat as text.
        paragraphLines.append(contentsOf: tableLines)
        return
      }
      let headerCells = splitTableRow(tableLines[0])
      let dataRows = tableLines.dropFirst(2).map { splitTableRow($0) }
      blocks.append(.table(headers: headerCells, rows: Array(dataRows)))
    }

    func splitTableRow(_ line: String) -> [String] {
      var s = line
      if s.hasPrefix("|") { s.removeFirst() }
      if s.hasSuffix("|") { s.removeLast() }
      return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    for rawLine in markdown.components(separatedBy: "\n") {
      if rawLine.hasPrefix("```") {
        if inCodeBlock {
          blocks.append(.codeBlock(code: codeLines.joined(separator: "\n")))
          codeLines = []
          inCodeBlock = false
        } else {
          flushParagraph()
          flushTable()
          inCodeBlock = true
        }
        continue
      }
      if inCodeBlock {
        codeLines.append(rawLine)
        continue
      }

      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("|") {
        flushParagraph()
        tableLines.append(trimmed)
        continue
      } else if !tableLines.isEmpty {
        flushTable()
      }

      if trimmed.isEmpty {
        flushParagraph()
        continue
      }

      if trimmed == "---" || trimmed == "***" {
        flushParagraph()
        blocks.append(.divider)
        continue
      }

      if trimmed.hasPrefix("#") {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        if (1...6).contains(hashes.count) {
          flushParagraph()
          let text = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
          blocks.append(.heading(level: hashes.count, text: text))
          continue
        }
      }

      if trimmed.hasPrefix("> ") {
        flushParagraph()
        blocks.append(.blockquote(text: String(trimmed.dropFirst(2))))
        continue
      }

      if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
        flushParagraph()
        blocks.append(.bulletItem(text: String(trimmed.dropFirst(2))))
        continue
      }

      if let dotIndex = trimmed.firstIndex(of: "."),
         let number = Int(trimmed[trimmed.startIndex..<dotIndex]),
         trimmed[trimmed.index(after: dotIndex)...].hasPrefix(" ") {
        flushParagraph()
        let text = String(trimmed[trimmed.index(dotIndex, offsetBy: 2)...])
        blocks.append(.numberedItem(number: number, text: text))
        continue
      }

      paragraphLines.append(trimmed)
    }

    if inCodeBlock, !codeLines.isEmpty {
      blocks.append(.codeBlock(code: codeLines.joined(separator: "\n")))
    }
    flushTable()
    flushParagraph()

    return blocks
  }
}
