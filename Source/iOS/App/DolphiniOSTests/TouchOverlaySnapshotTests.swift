// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import SwiftUI
import UIKit
import XCTest

@testable import iCube

/// Renders every pad kind's default layout on every `TouchOverlayPreviewDevice` in both
/// orientations to PNGs, for eyeballing layout changes without a device. Not an assertion test:
/// it is skipped unless an output directory is given, e.g.
///   make test DEST="platform=iOS Simulator,id=<udid>" \
///     TEST_ARGS="-only-testing:iCubeTests/TouchOverlaySnapshotTests TEST_RUNNER_TOUCH_OVERLAY_SNAPSHOT_DIR=/tmp/shots"
@MainActor
final class TouchOverlaySnapshotTests: XCTestCase {
  private static let outputDirKey = "TOUCH_OVERLAY_SNAPSHOT_DIR"

  func testRenderDefaultLayouts() throws {
    guard let dir = ProcessInfo.processInfo.environment[Self.outputDirKey], !dir.isEmpty else {
      throw XCTSkip("set \(Self.outputDirKey) to render layout snapshots")
    }
    let outputDir = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)

    for kind in TouchOverlayPadKind.allCases {
      for device in TouchOverlayPreviewDevice.all {
        for orientation in TouchOverlayOrientation.allCases {
          let image = render(TouchOverlayPreviewScreen(padKind: kind, device: device, orientation: orientation),
                             size: device.size(orientation), scene: scene)
          let name = "\(kind.rawValue)-\(orientation.rawValue)-\(device.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "\"", with: "in")).png"
          try XCTUnwrap(image.pngData()).write(to: outputDir.appendingPathComponent(name))
        }
      }
    }
  }

  /// Hosts the view in its own window so UIKit-backed pieces (the touch surfaces) lay out the same
  /// way they do on screen, then snapshots the window.
  private func render<V: View>(_ view: V, size: CGSize, scene: UIWindowScene) -> UIImage {
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let host = UIHostingController(rootView: view)
    host.safeAreaRegions = []
    window.rootViewController = host
    window.isHidden = false
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
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
