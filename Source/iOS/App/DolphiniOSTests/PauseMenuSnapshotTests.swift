// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import SwiftUI
import UIKit
import XCTest

@testable import iCube

/// Renders the pause overlay at iPhone portrait/landscape and iPad widths to PNGs for eyeballing.
/// Skipped unless an output directory is given. Export the variable before running (passing it inside
/// TEST_ARGS silently skips the test):
///   export TEST_RUNNER_PAUSE_MENU_SNAPSHOT_DIR=/tmp/shots
///   make test DEST="platform=iOS Simulator,id=<udid>" TEST_ARGS="-only-testing:iCubeTests/PauseMenuSnapshotTests"
@MainActor
final class PauseMenuSnapshotTests: XCTestCase {
  private static let outputDirKey = "PAUSE_MENU_SNAPSHOT_DIR"
  private static let sizes: [(String, CGSize)] = [
    ("iphone-portrait", CGSize(width: 393, height: 852)),
    ("iphone-landscape", CGSize(width: 852, height: 393)),
    ("ipad", CGSize(width: 1024, height: 768)),
  ]

  func testRenderPauseMenu() throws {
    guard let dir = ProcessInfo.processInfo.environment[Self.outputDirKey], !dir.isEmpty else {
      throw XCTSkip("set \(Self.outputDirKey) to render pause menu snapshots")
    }
    let outputDir = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    for (name, size) in Self.sizes {
      let view = PauseMenuView(selectedSlot: .constant(3), onClose: {}, onShowSettings: {}, platform: .ios, game: PauseMenuView.previewGame())
      let image = render(view, size: size, scene: scene)
      try XCTUnwrap(image.pngData()).write(to: outputDir.appendingPathComponent("pause-\(name).png"))
    }
  }

  /// Hosts the view in its own window so UIKit-backed pieces lay out as they do on screen, then snapshots it.
  private func render<V: View>(_ view: V, size: CGSize, scene: UIWindowScene) -> UIImage {
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let host = UIHostingController(rootView: view)
    host.safeAreaRegions = []
    window.rootViewController = host
    window.isHidden = false
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    window.isHidden = true
    return image
  }
}
#endif
