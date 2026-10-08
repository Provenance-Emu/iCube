// DolphiniOSTests/UILayerPauseCallsTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

/// Spec §4.3: the arbiter owns every `TVEmulationBridge.pause()` / `.resume()` in the Swift UI layer.
/// A new direct call is the bug this PR fixes coming back, so it fails here.
final class UILayerPauseCallsTests: XCTestCase {
  private static let allowed: Set<String> = ["PauseArbiter.swift"]
  private static let patterns = ["TVEmulationBridge.pause()", "TVEmulationBridge.resume()"]

  func test_noDirectBridgePauseOrResumeOutsideArbiter() throws {
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let swiftRoot = testsDir.deletingLastPathComponent().appendingPathComponent("Common/Swift")
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: swiftRoot, includingPropertiesForKeys: nil))
    var offenders: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      guard !Self.allowed.contains(url.lastPathComponent) else { continue }
      let text = try String(contentsOf: url, encoding: .utf8)
      for (number, line) in text.components(separatedBy: "\n").enumerated() {
        let code = line.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
        if Self.patterns.contains(where: { code.contains($0) }) {
          offenders.append("\(url.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
      }
    }
    XCTAssertTrue(offenders.isEmpty, "Pause/resume must go through PauseArbiter:\n" + offenders.joined(separator: "\n"))
  }
}
