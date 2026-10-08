// DolphiniOSTests/UILayerPauseCallsTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

/// Spec §4.3: the arbiter owns every `TVEmulationBridge.pause()` / `.resume()` in the Swift UI layer.
/// A new direct call is the bug this PR fixes coming back, so it fails here.
final class UILayerPauseCallsTests: XCTestCase {
  private static let allowed: Set<String> = ["PauseArbiter.swift"]
  // swiftlint:disable:next force_try
  private static let pattern = try! NSRegularExpression(pattern: #"TVEmulationBridge\s*\.\s*(pause|resume)\b"#)

  func test_noDirectBridgePauseOrResumeOutsideArbiter() throws {
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let swiftRoot = testsDir.deletingLastPathComponent().appendingPathComponent("Common/Swift")
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: swiftRoot, includingPropertiesForKeys: nil))
    var offenders: [String] = []
    var seen: Set<String> = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      seen.insert(url.lastPathComponent)
      guard !Self.allowed.contains(url.lastPathComponent) else { continue }
      let text = try String(contentsOf: url, encoding: .utf8)
      for (number, line) in text.components(separatedBy: "\n").enumerated() {
        var code = line
        if let comment = code.range(of: "//") { code = String(code[..<comment.lowerBound]) }
        let range = NSRange(code.startIndex..., in: code)
        if Self.pattern.firstMatch(in: code, range: range) != nil {
          offenders.append("\(url.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
      }
    }
    XCTAssertFalse(seen.isEmpty, "no Swift files scanned: #filePath derivation is broken")
    XCTAssertTrue(seen.contains("PauseArbiter.swift"), "PauseArbiter.swift not found under \(swiftRoot.path)")
    XCTAssertTrue(offenders.isEmpty, "Pause/resume must go through PauseArbiter:\n" + offenders.joined(separator: "\n"))
  }
}
