// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import SwiftUI
import UIKit
import XCTest

@testable import iCube

/// Renders the in-game top bar at iPhone width, portrait and landscape, with the toggles off and on, to
/// PNGs for eyeballing. Not an assertion test: it is skipped unless an output directory is given. Export
/// the variable before running (passing it inside TEST_ARGS silently skips the test):
///   export TEST_RUNNER_TOP_BAR_SNAPSHOT_DIR=/tmp/shots
///   make test DEST="platform=iOS Simulator,id=<udid>" TEST_ARGS="-only-testing:iCubeTests/TopBarSnapshotTests"
@MainActor
final class TopBarSnapshotTests: XCTestCase {
  private static let outputDirKey = "TOP_BAR_SNAPSHOT_DIR"
  private static let portrait = CGSize(width: 393, height: 852)
  private static let landscape = CGSize(width: 852, height: 393)

  private struct Harness: View {
    let togglesOn: Bool
    let compactHeight: Bool
    var onHeight: (CGFloat) -> Void = { _ in }
    @State private var visibility = TopBarVisibility()
    @State private var slot = 3
    @State private var paused: Bool
    @State private var fastForward: Bool

    init(togglesOn: Bool, compactHeight: Bool, onHeight: @escaping (CGFloat) -> Void = { _ in }) {
      self.togglesOn = togglesOn
      self.compactHeight = compactHeight
      self.onHeight = onHeight
      _paused = State(initialValue: togglesOn)
      _fastForward = State(initialValue: togglesOn)
    }

    var body: some View {
      ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()
        LinearGradient(colors: [.indigo, .purple.opacity(0.5)], startPoint: .top, endPoint: .bottom).opacity(0.5)
        EmulationTopBar(
          visibility: $visibility, selectedSlot: $slot, isPaused: $paused, fastForwardEnabled: $fastForward,
          isWii: true, onScreenControlsVisible: !togglesOn, irModeRaw: 1,
          overscanApplicable: false, overscanFullscreen: false,
          readToggles: { TopBarToggles(isMuted: togglesOn, fastForwardEnabled: togglesOn) },
          open: { _ in }, onToggleOnScreenControls: {}, onSetPointerMode: { _ in },
          onSetOverscanFullscreen: { _ in })
      }
      .environment(\.verticalSizeClass, compactHeight ? .compact : .regular)
      .onPreferenceChange(TopBarHeightKey.self, perform: onHeight)
    }
  }

  func testPortraitToolbarFitsPhonePadAndSplitWidth() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    for size in [CGSize(width: 320, height: 568), Self.portrait, CGSize(width: 1024, height: 1366)] {
      var height: CGFloat = 0
      _ = render(Harness(togglesOn: false, compactHeight: false, onHeight: { height = $0 }), size: size, scene: scene)
      XCTAssertGreaterThanOrEqual(height, 44, "The toolbar must report its rendered height at \(size)")
      XCTAssertLessThanOrEqual(height, 80, "Portrait must fit one control row at \(size)")
    }
  }

  func testAccessibilityTypeExpandsWithoutClippingToStandardHeight() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    var height: CGFloat = 0
    _ = render(Harness(togglesOn: false, compactHeight: false, onHeight: { height = $0 })
      .dynamicTypeSize(.accessibility3), size: Self.portrait, scene: scene)
    XCTAssertGreaterThan(height, 80, "Accessibility labels must be allowed to reflow")
    XCTAssertLessThan(height, Self.portrait.height, "All primary actions must remain reachable")
  }

  func testRenderTopBar() throws {
    guard let dir = ProcessInfo.processInfo.environment[Self.outputDirKey], !dir.isEmpty else {
      throw XCTSkip("set \(Self.outputDirKey) to render top bar snapshots")
    }
    let outputDir = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)

    for (orientation, size) in [("portrait", Self.portrait), ("landscape", Self.landscape),
                              ("ipad-portrait", CGSize(width: 1024, height: 1366)),
                              ("ipad-landscape", CGSize(width: 1366, height: 1024)),
                              ("split", CGSize(width: 320, height: 800))] {
      for (state, on) in [("idle", false), ("toggled", true)] {
        let image = render(Harness(togglesOn: on, compactHeight: size == Self.landscape), size: size, scene: scene)
        try XCTUnwrap(image.pngData()).write(to: outputDir.appendingPathComponent("top-bar-\(orientation)-\(state).png"))
      }
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
