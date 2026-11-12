// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The words of Dolphin's input expression language the editor names (ExpressionParser.cpp,
/// FunctionExpression.cpp `MakeFunctionExpression`).
enum ProfileExpressionSyntax {
  static let functions = [
    "not", "if", "toggle", "hold", "tap", "pulse", "timer", "relative", "deadzone", "smooth",
    "min", "max", "clamp", "abs", "minus", "plus", "pow", "sqrt",
    "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
  ]
  static let booleans = ["True", "False"]
  /// Every character the lexer reads as an operator or a bracket.
  static let operatorCharacters = Set("+-*/%=<>,^&|!?:()@".utf16)
}

/// One coloured run of a profile's text.
struct ProfileTextToken: Equatable {
  enum Kind: Equatable {
    case comment
    case section
    case key
    case punctuation
    /// A backticked input name: `` `Button A` ``.
    case control
    /// A quoted literal: `'Full Speed'`.
    case string
    case variable
    case number
    case function
    case boolean
    case operatorSymbol
    /// A whole line the core would drop.
    case invalid
  }

  let range: NSRange
  let kind: Kind
}

/// Lexes a profile for colouring. Lexical only: whether a key exists or an expression parses is the
/// linter's question (`ProfileTextLinter`), which asks the core. Pure.
enum ProfileTextHighlighter {
  static func tokens(for text: String) -> [ProfileTextToken] {
    let ns = text as NSString
    var tokens: [ProfileTextToken] = []
    for line in ProfileTextDocument.lines(of: text) {
      switch line.content {
      case .blank:
        break
      case .comment:
        tokens.append(ProfileTextToken(range: line.range, kind: .comment))
      case .section:
        tokens.append(ProfileTextToken(range: ProfileTextDocument.trimmed(line.range, in: ns), kind: .section))
      case .malformed:
        tokens.append(ProfileTextToken(range: ProfileTextDocument.trimmed(line.range, in: ns), kind: .invalid))
      case .entry(let key, _, let keyRange, let valueRange, let equalsLocation):
        tokens.append(ProfileTextToken(range: keyRange, kind: .key))
        tokens.append(ProfileTextToken(range: NSRange(location: equalsLocation, length: 1), kind: .punctuation))
        // A device is a name (`MFi/0/Xbox Wireless Controller`), not an expression.
        if key != deviceKey { tokens += expressionTokens(in: valueRange, of: ns) }
      }
    }
    return tokens
  }

  /// The backticked input names of an expression, without their backticks.
  static func controlNames(in expression: String) -> [String] {
    let ns = expression as NSString
    return expressionTokens(in: NSRange(location: 0, length: ns.length), of: ns).compactMap { token in
      guard token.kind == .control else { return nil }
      var inner = NSRange(location: token.range.location + 1, length: token.range.length - 1)
      if inner.length > 0, ns.character(at: inner.location + inner.length - 1) == backtick { inner.length -= 1 }
      return ns.substring(with: inner)
    }
  }

  /// The one key whose value is not an expression.
  static let deviceKey = "Device"

  // MARK: Expressions

  private static let backtick: unichar = 0x60
  private static let quote: unichar = 0x27
  private static let dollar: unichar = 0x24
  private static let slash: unichar = 0x2F
  private static let star: unichar = 0x2A
  private static let dot: unichar = 0x2E
  private static let comma: unichar = 0x2C
  private static let underscore: unichar = 0x5F
  private static let openParenthesis: unichar = 0x28
  private static let space: unichar = 0x20
  private static let tab: unichar = 0x09

  private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
  private static func isLetter(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == underscore }
  private static func isWord(_ c: unichar) -> Bool { isLetter(c) || isDigit(c) }

  static func expressionTokens(in range: NSRange, of ns: NSString) -> [ProfileTextToken] {
    var tokens: [ProfileTextToken] = []
    let end = range.location + range.length
    var index = range.location
    func emit(_ start: Int, _ kind: ProfileTextToken.Kind) {
      tokens.append(ProfileTextToken(range: NSRange(location: start, length: index - start), kind: kind))
    }
    /// Advances past the closing `delimiter`, or to the end when there is none.
    func skipDelimited(_ delimiter: unichar) {
      index += 1
      while index < end, ns.character(at: index) != delimiter { index += 1 }
      if index < end { index += 1 }
    }
    while index < end {
      let start = index
      let c = ns.character(at: index)
      if c == space || c == tab {
        index += 1
      } else if c == backtick {
        skipDelimited(backtick)
        emit(start, .control)
      } else if c == quote {
        skipDelimited(quote)
        emit(start, .string)
      } else if c == slash, index + 1 < end, ns.character(at: index + 1) == star {
        index += 2
        while index < end {
          if ns.character(at: index) == star, index + 1 < end, ns.character(at: index + 1) == slash {
            index += 2
            break
          }
          index += 1
        }
        emit(start, .comment)
      } else if c == dollar {
        index += 1
        while index < end, isWord(ns.character(at: index)) { index += 1 }
        emit(start, .variable)
      } else if isDigit(c) {
        // A profile saved under a comma-decimal locale writes `100,000000`.
        while index < end, isDigit(ns.character(at: index)) || ns.character(at: index) == dot
          || (ns.character(at: index) == comma && index + 1 < end && isDigit(ns.character(at: index + 1))) { index += 1 }
        emit(start, .number)
      } else if isLetter(c) {
        while index < end, isWord(ns.character(at: index)) { index += 1 }
        let word = ns.substring(with: NSRange(location: start, length: index - start))
        var next = index
        while next < end, ns.character(at: next) == space { next += 1 }
        if next < end, ns.character(at: next) == openParenthesis, ProfileExpressionSyntax.functions.contains(word) {
          emit(start, .function)
        } else if ProfileExpressionSyntax.booleans.contains(word) {
          emit(start, .boolean)
        }
      } else if ProfileExpressionSyntax.operatorCharacters.contains(c) {
        index += 1
        emit(start, .operatorSymbol)
      } else {
        index += 1
      }
    }
    return tokens
  }
}
