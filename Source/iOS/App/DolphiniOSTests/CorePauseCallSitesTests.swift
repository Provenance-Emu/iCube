// DolphiniOSTests/CorePauseCallSitesTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

/// App-level code must not change the core's run state behind the PauseArbiter. `Core::SetState` is called
/// only by the bridges (`TVEmulationBridge`, the arbiter's seam, and the debug API's own bridge), and no
/// service or scene delegate may pause or resume on its own: DolphinCoreService resuming on become-active
/// was the bug that ran the game behind the pause menu.
final class CorePauseCallSitesTests: XCTestCase {
  private static let setStateAllowed: Set<String> = ["TVEmulationBridge.mm", "DOLDebugBridge.mm"]
  private static let lifecycleFiles: Set<String> = ["MainDisplaySceneDelegate.swift", "ExternalDisplaySceneDelegate.swift"]
  // swiftlint:disable:next force_try
  private static let setState = try! NSRegularExpression(pattern: #"\bSetState\s*\("#)
  // swiftlint:disable:next force_try
  private static let bridgePause = try! NSRegularExpression(pattern: #"TVEmulationBridge\s*\.\s*(pause|resume)(Async)?\b|\[\s*TVEmulationBridge\s+(pause|resume)"#)

  private func code(of url: URL) throws -> [(Int, String, String)] {
    try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated().map { number, line in
      var stripped = line
      if let comment = stripped.range(of: "//") { stripped = String(stripped[..<comment.lowerBound]) }
      return (number + 1, stripped, line)
    }
  }

  func test_coreSetStateIsCalledOnlyFromTheBridges() throws {
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = testsDir.deletingLastPathComponent().appendingPathComponent("Common")
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var offenders: [String] = []
    var seen: Set<String> = []
    for case let url as URL in enumerator where ["mm", "m", "cpp", "swift"].contains(url.pathExtension) {
      seen.insert(url.lastPathComponent)
      guard !Self.setStateAllowed.contains(url.lastPathComponent) else { continue }
      for (number, stripped, line) in try code(of: url)
      where Self.setState.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil {
        offenders.append("\(url.lastPathComponent):\(number): \(line.trimmingCharacters(in: .whitespaces))")
      }
    }
    XCTAssertTrue(seen.contains("TVEmulationBridge.mm"), "TVEmulationBridge.mm not found under \(root.path): path derivation is broken")
    XCTAssertTrue(seen.contains("DolphinCoreService.mm"), "DolphinCoreService.mm not scanned")
    XCTAssertTrue(offenders.isEmpty, "Core::SetState outside the bridges:\n" + offenders.joined(separator: "\n"))
  }

  func test_servicesAndSceneDelegatesDoNotPauseOrResume() throws {
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let common = testsDir.deletingLastPathComponent().appendingPathComponent("Common")
    var files = try FileManager.default.contentsOfDirectory(at: common.appendingPathComponent("Services"), includingPropertiesForKeys: nil)
    files += Self.lifecycleFiles.map { common.appendingPathComponent($0) }
    var offenders: [String] = []
    for url in files where ["mm", "m", "swift"].contains(url.pathExtension) {
      for (number, stripped, line) in try code(of: url)
      where Self.bridgePause.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil {
        offenders.append("\(url.lastPathComponent):\(number): \(line.trimmingCharacters(in: .whitespaces))")
      }
    }
    XCTAssertGreaterThan(files.count, Self.lifecycleFiles.count, "no service files scanned: path derivation is broken")
    XCTAssertTrue(offenders.isEmpty, "Lifecycle code must go through PauseArbiter:\n" + offenders.joined(separator: "\n"))
  }
}
