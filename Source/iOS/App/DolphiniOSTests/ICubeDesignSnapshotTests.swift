// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import SwiftUI
import UIKit
import XCTest

@testable import iCube

/// PNGs of the design module's pieces in light and dark, for eyeballing. Skipped unless
/// TEST_RUNNER_ICUBE_DESIGN_SNAPSHOT_DIR is EXPORTED (not passed in TEST_ARGS), e.g.
///   export TEST_RUNNER_ICUBE_DESIGN_SNAPSHOT_DIR=/tmp/icube-design
///   make test TEST_ARGS="-only-testing:iCubeTests/ICubeDesignSnapshotTests"
@MainActor
final class ICubeDesignSnapshotTests: XCTestCase {
  private static let outputDirKey = "ICUBE_DESIGN_SNAPSHOT_DIR"

  func testRenderPieces() throws {
    guard let dir = ProcessInfo.processInfo.environment[Self.outputDirKey], !dir.isEmpty else {
      throw XCTSkip("set \(Self.outputDirKey) to render design snapshots")
    }
    let out = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let size = CGSize(width: 900, height: 1100)
    for style in [UIUserInterfaceStyle.light, .dark] {
      let name = style == .dark ? "dark" : "light"
      for focused in [false, true] {
        let image = render(Self.sheet(focused: focused), size: size, style: style, scene: scene)
        try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent("design-\(name)-\(focused ? "focused" : "rest").png"))
      }
    }
  }

  private static func sheet(focused: Bool) -> some View {
    ZStack {
      LinearGradient(colors: ICubeDesign.roomStops.map { Color(uiColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
        Text("Settings").icubeText(.title).foregroundStyle(ICubeDesign.titleGradient)
        Text("Graphics").icubeText(.section).foregroundStyle(ICubeDesign.color(.textPrimary))
        VStack(spacing: ICubeDesign.Spacing.m.rawValue) {
          Button {} label: {
            VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
              Text("Internal Resolution").icubeText(.body).foregroundStyle(ICubeDesign.color(.textPrimary))
              Text("Higher looks sharper and costs more GPU.").icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
            }
          }
          .buttonStyle(ICubeRowButtonStyle(isFocusedOverride: focused))
          HStack(spacing: ICubeDesign.Spacing.m.rawValue) {
            Button {} label: { Text("Resume").icubeText(.body) }.buttonStyle(ICubeTileButtonStyle(isFocusedOverride: focused))
            Button {} label: { Text("GALE01").icubeText(.tag) }.buttonStyle(ICubeTileButtonStyle(isFocusedOverride: false))
          }
        }
        .padding(ICubeDesign.Spacing.l.rawValue)
        .icubePanel()
        Color.orange
          .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
          .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
          .icubeCardArtFocus(isFocused: focused)
          .icubeCardFocus(isFocused: focused)
      }
      .padding(ICubeDesign.Spacing.xl.rawValue)
    }
  }

  private func render<V: View>(_ view: V, size: CGSize, style: UIUserInterfaceStyle, scene: UIWindowScene) -> UIImage {
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    window.overrideUserInterfaceStyle = style
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
