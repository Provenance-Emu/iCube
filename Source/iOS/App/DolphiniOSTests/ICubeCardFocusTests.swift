// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import SwiftUI
import UIKit
import XCTest

@testable import iCube

/// Spec §2.7: `.icubeCardArtFocus` + `.icubeCardFocus` must draw exactly what GameGridItem drew
/// before the extraction. `legacy(...)` is a verbatim copy of the pre-extraction code (commit before
/// this test landed); keep it frozen. It is the definition of the effect.
@MainActor
final class ICubeCardFocusTests: XCTestCase {
  private static let canvas = CGSize(width: 520, height: 760)

  func test_extractedEffect_isPixelIdenticalToLegacy() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    for style in [UIUserInterfaceStyle.light, .dark] {
      var legacyByFocus: [Bool: [UInt8]] = [:]
      for focused in [false, true] {
        let before = try render(Self.legacy(isFocused: focused), style: style, scene: scene)
        let after = try render(Self.extracted(isFocused: focused), style: style, scene: scene)
        XCTAssertEqual(before.count, after.count)
        let diffs = zip(before, after).filter { $0 != $1 }.count
        XCTAssertEqual(diffs, 0, "focused=\(focused) style=\(style.rawValue): \(diffs) bytes differ")
        // Non-vacuity: blank captures would be identical on both sides and pass the check above.
        XCTAssertGreaterThan(distinctColours(before), 1, "focused=\(focused) style=\(style.rawValue): blank capture")
        legacyByFocus[focused] = before
      }
      XCTAssertNotEqual(legacyByFocus[true], legacyByFocus[false], "style=\(style.rawValue): focused render equals rest render")
    }
  }

  private func distinctColours(_ bytes: [UInt8]) -> Int {
    var seen = Set<UInt32>()
    for i in stride(from: 0, to: bytes.count - 3, by: 4) {
      seen.insert(UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
      if seen.count > 1 { break }
    }
    return seen.count
  }

  // MARK: The card stand-in: flat art plus a one-line title, the same structure as GameGridItem's tvOS body.

  private static func art() -> some View {
    Color.orange
      .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private static func extracted(isFocused: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ZStack(alignment: .topTrailing) {
        art().icubeCardArtFocus(isFocused: isFocused)
      }
      Text("Title")
    }
    .frame(width: LibraryLayout.cardSize.width)
    .icubeCardFocus(isFocused: isFocused)
    .frame(width: canvas.width, height: canvas.height)
  }

  /// VERBATIM from GameGridItem.swift before the extraction. Do not edit.
  private static func legacy(isFocused: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ZStack(alignment: .topTrailing) {
        art()
          .overlay(
            // Award-winning focus glow with GameCube/Wii theming
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(
                LinearGradient(
                  colors: isFocused ? [
                    Color.cyan.opacity(0.95),
                    Color(.dolphinTint).opacity(0.9),
                    Color.purple.opacity(0.95),
                    Color.cyan.opacity(0.95)
                  ] : [Color.clear],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                ),
                lineWidth: isFocused ? 8 : 0
              )
              .shadow(color: .cyan.opacity(isFocused ? 0.8 : 0), radius: isFocused ? 25 : 0)
              .shadow(color: .blue.opacity(isFocused ? 0.6 : 0), radius: isFocused ? 35 : 0)
              .shadow(color: .purple.opacity(isFocused ? 0.7 : 0), radius: isFocused ? 45 : 0)
              .animation(.easeInOut(duration: 0.6), value: isFocused)
          )
          .overlay(
            // Inner highlight for premium feel
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(
                Color.white.opacity(isFocused ? 0.4 : 0),
                lineWidth: isFocused ? 2 : 0
              )
              .padding(4)
              .animation(.easeInOut(duration: 0.4), value: isFocused)
          )
          .shadow(
            color: Color.black.opacity(isFocused ? 0.4 : 0.2),
            radius: isFocused ? 20 : 8,
            x: 0,
            y: isFocused ? 12 : 6
          )

        if isFocused {
          VStack { LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)
            Spacer()
          }
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
          .allowsHitTesting(false)
        }
      }
      Text("Title")
    }
    .frame(width: LibraryLayout.cardSize.width)
    .scaleEffect(isFocused ? 1.08 : 1.0)
    .rotation3DEffect(
      .degrees(isFocused ? 5 : 2),
      axis: (x: 0.1, y: 1.0, z: 0),
      perspective: isFocused ? 0.8 : 1.0
    )
    .shadow(
      color: .black.opacity(isFocused ? 0.4 : 0.2),
      radius: isFocused ? 20 : 8,
      x: 0,
      y: isFocused ? 12 : 4
    )
    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isFocused)
    .frame(width: canvas.width, height: canvas.height)
  }

  // MARK: Rendering (same window-hosted approach as TouchOverlaySnapshotTests)

  /// Hosts the view in its own window and returns the settled frame's RGBA bytes.
  ///
  /// A single capture after a fixed wait flaked under machine load (a 37- and a 73-byte diff on
  /// otherwise identical renders): `drawHierarchy` caught a frame before SwiftUI's follow-up layout
  /// or shadow pass had committed on one side only. So animations are off for the whole hosting
  /// (UIKit and SwiftUI), and the window is captured repeatedly until two consecutive frames are
  /// byte-identical. The comparison itself stays exact: this only decides *when* to read the pixels.
  private func render<V: View>(_ view: V, style: UIUserInterfaceStyle, scene: UIWindowScene) throws -> [UInt8] {
    let animationsWereEnabled = UIView.areAnimationsEnabled
    UIView.setAnimationsEnabled(false)
    defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: Self.canvas)
    window.overrideUserInterfaceStyle = style
    let host = UIHostingController(rootView: view.transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    })
    host.safeAreaRegions = []
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true }
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))

    var previous = try capture(window)
    for _ in 0 ..< Self.settleAttempts {
      RunLoop.main.run(until: Date().addingTimeInterval(Self.settleInterval))
      let next = try capture(window)
      if next == previous { return next }
      previous = next
    }
    XCTFail("style=\(style.rawValue): render did not settle after \(Self.settleAttempts) captures")
    return previous
  }

  /// Generous for a loaded machine; the loop exits on the first pair of identical frames, so an
  /// idle run pays only one extra capture.
  private static let settleAttempts = 40
  private static let settleInterval: TimeInterval = 0.05

  private func capture(_ window: UIWindow) throws -> [UInt8] {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    let image = UIGraphicsImageRenderer(size: Self.canvas, format: format).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let data = try XCTUnwrap(image.cgImage?.dataProvider?.data as Data?)
    return [UInt8](data)
  }
}
#endif
