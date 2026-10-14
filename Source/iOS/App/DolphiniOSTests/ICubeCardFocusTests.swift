// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import SwiftUI
import XCTest

@testable import iCube

/// Spec §2.7: `.icubeCardArtFocus` + `.icubeCardFocus` must draw exactly what GameGridItem drew
/// before the extraction. `legacy(...)` is a verbatim copy of the pre-extraction code (commit before
/// this test landed); keep it frozen. It is the definition of the effect.
@MainActor
final class ICubeCardFocusTests: XCTestCase {
  private static let canvas = CGSize(width: 520, height: 760)

  func test_extractedEffect_isPixelIdenticalToLegacy() throws {
    for scheme in [ColorScheme.light, .dark] {
      var legacyByFocus: [Bool: [UInt8]] = [:]
      for focused in [false, true] {
        let before = try render(Self.legacy(isFocused: focused), scheme: scheme)
        let after = try render(Self.extracted(isFocused: focused), scheme: scheme)
        XCTAssertEqual(before.count, after.count)
        let diffs = zip(before, after).filter { $0 != $1 }.count
        XCTAssertEqual(diffs, 0, "focused=\(focused) scheme=\(scheme): \(diffs) bytes differ")
        // Non-vacuity: blank captures would be identical on both sides and pass the check above.
        XCTAssertGreaterThan(distinctColours(before), 1, "focused=\(focused) scheme=\(scheme): blank capture")
        legacyByFocus[focused] = before
      }
      XCTAssertNotEqual(legacyByFocus[true], legacyByFocus[false], "scheme=\(scheme): focused render equals rest render")
    }
  }

  /// The dark pass must really draw the dark asset colours (the ring's `dolphinTint` has a separate
  /// dark value), or it would only repeat the light comparison.
  func test_renderResolvesTheSchemeOfAssetColours() throws {
    let light = try render(Color(.dolphinTint).frame(width: Self.canvas.width, height: Self.canvas.height), scheme: .light)
    let dark = try render(Color(.dolphinTint).frame(width: Self.canvas.width, height: Self.canvas.height), scheme: .dark)
    XCTAssertNotEqual(Array(light.prefix(4)), Array(dark.prefix(4)))
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

  // MARK: Rendering

  /// Rasterises the view offscreen with `ImageRenderer` and returns its pixel bytes.
  ///
  /// Not a window plus `drawHierarchy`: that path goes through the render server, which composited
  /// these large blurred shadows two slightly different ways from run to run (under half an 8-bit
  /// step, in a band near the card's bottom edge). A capture of the legacy tree then differed from a
  /// second capture of the same tree as often as from the extracted one. `ImageRenderer` draws the
  /// same display list on the CPU, so one tree always produces the same bytes and the comparison
  /// stays exact. Float output (`.extendedLinear`, 16 bits per channel) keeps it at least as
  /// strict as the half-float window capture was. The background stands in for the hosting
  /// controller's system background.
  private func render<V: View>(_ view: V, scheme: ColorScheme) throws -> [UInt8] {
    let renderer = ImageRenderer(content: view
      .background(Color(.systemBackground))
      .environment(\.colorScheme, scheme))
    renderer.proposedSize = ProposedViewSize(Self.canvas)
    renderer.scale = 2
    renderer.colorMode = .extendedLinear
    let image = try XCTUnwrap(renderer.cgImage)
    let data = try XCTUnwrap(image.dataProvider?.data as Data?)
    return [UInt8](data)
  }
}
#endif
