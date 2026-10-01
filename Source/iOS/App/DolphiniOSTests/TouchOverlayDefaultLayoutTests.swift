// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import UIKit
import XCTest

@testable import iCube

/// Invariants of the DEFAULT touch layouts on every preview device, both orientations: what the
/// "controls in bad places, overlapping, too small" report was about.
final class TouchOverlayDefaultLayoutTests: XCTestCase {
  private struct Case {
    let kind: TouchOverlayPadKind
    let device: TouchOverlayPreviewDevice
    let orientation: TouchOverlayOrientation
    var bounds: CGRect { CGRect(origin: .zero, size: device.size(orientation)) }
    var safeArea: UIEdgeInsets { device.insets(orientation) }
    var label: String { "\(kind) \(device.name) \(orientation)" }
    var layouts: [TouchOverlayGroupLayout] {
      TouchOverlayDefaults.layout(for: kind, orientation: orientation, canvas: bounds.size, safeArea: safeArea)
    }
  }

  private func cases(_ kinds: [TouchOverlayPadKind] = TouchOverlayPadKind.allCases) -> [Case] {
    kinds.flatMap { kind in
      TouchOverlayPreviewDevice.all.flatMap { device in
        TouchOverlayOrientation.allCases.map { Case(kind: kind, device: device, orientation: $0) }
      }
    }
  }

  private static func isIRSurface(_ layout: TouchOverlayGroupLayout) -> Bool {
    layout.controls.contains { if case .irSurface = $0.kind { return true }; return false }
  }

  /// Absolute frame of a control: group box origin + the control's local frame.
  private func frame(of control: TouchOverlayControl, in layout: TouchOverlayGroupLayout, bounds: CGRect) -> CGRect {
    let box = layout.placement.box(in: bounds)
    return control.frame.offsetBy(dx: box.minX, dy: box.minY)
  }

  func testEveryGroupStaysInsideTheSafeArea() {
    for c in cases() {
      let safe = c.bounds.inset(by: c.safeArea)
      for layout in c.layouts where !Self.isIRSurface(layout) {
        let box = layout.placement.box(in: c.bounds)
        XCTAssertTrue(safe.insetBy(dx: -0.5, dy: -0.5).contains(box), "\(c.label): \(layout.group) \(box) leaves safe area \(safe)")
      }
    }
  }

  /// Pad kinds whose defaults are computed per screen (the sideways remote is still xib-derived).
  private static let computedKinds: [TouchOverlayPadKind] = [.gameCube, .wiiRemote, .wiiClassic]

  func testComputedLayoutGroupsDoNotOverlap() {
    for c in cases(Self.computedKinds) {
      // The Wii IR surface covers the pad on purpose; controls drawn over it take touches first.
      let boxes = c.layouts.filter { !Self.isIRSurface($0) }.map { ($0.group, $0.placement.box(in: c.bounds)) }
      for (i, a) in boxes.enumerated() {
        for b in boxes[(i + 1)...] {
          XCTAssertFalse(a.1.insetBy(dx: 0.5, dy: 0.5).intersects(b.1), "\(c.label): \(a.0) overlaps \(b.0)")
        }
      }
    }
  }

  func testComputedLayoutControlsAreFingerSized() {
    for c in cases(Self.computedKinds) {
      for layout in c.layouts where !Self.isIRSurface(layout) {
        for control in layout.controls {
          XCTAssertGreaterThanOrEqual(min(control.frame.width, control.frame.height), 44, "\(c.label): \(control.id) is too small")
        }
      }
    }
  }

  /// A circle drawn into a non-square frame shrinks to the short side and leaves dead space
  /// around it, which is what made the old face buttons look small and spread apart.
  func testComputedLayoutRoundButtonsHaveSquareFrames() {
    let roundIds: Set<String> = ["gc.a", "gc.b", "wii.a", "wii.b", "wii.one", "wii.two", "wii.minus", "wii.plus",
                                 "wii.home", "nunchuk.c", "classic.a", "classic.b", "classic.x", "classic.y",
                                 "classic.minus", "classic.plus", "classic.home"]
    for c in cases(Self.computedKinds) {
      for control in c.layouts.flatMap(\.controls) where roundIds.contains(control.id) {
        XCTAssertEqual(control.frame.width, control.frame.height, accuracy: 0.01, "\(c.label): \(control.id)")
      }
    }
  }

  func testComputedLayoutControlsInsideAGroupDoNotOverlap() {
    for c in cases(Self.computedKinds) {
      for layout in c.layouts {
        let frames = layout.controls.map(\.frame)
        for (i, a) in frames.enumerated() {
          for b in frames[(i + 1)...] {
            XCTAssertFalse(a.insetBy(dx: 0.5, dy: 0.5).intersects(b), "\(c.label): controls overlap in \(layout.group)")
          }
        }
      }
    }
  }

  /// In portrait the game picture sits at the top, so the controls belong under it.
  func testGameCubePortraitControlsStayBelowTheGame() {
    for c in cases([.gameCube]) where c.orientation == .portrait {
      let gameBottom = c.safeArea.top + (c.bounds.width - c.safeArea.left - c.safeArea.right) * 3 / 4
      for layout in c.layouts {
        XCTAssertGreaterThanOrEqual(layout.placement.box(in: c.bounds).minY, gameBottom - 0.5, "\(c.label): \(layout.group)")
      }
    }
  }

  func testWiiRemoteHasEveryButton() {
    let ids = Set(cases([.wiiRemote])[0].layouts.flatMap(\.controls).map(\.id))
    XCTAssertEqual(ids, ["wii.dpad", "nunchuk.stick", "wii.a", "wii.b", "wii.one", "wii.two", "wii.minus", "wii.plus",
                         "wii.home", "nunchuk.c", "nunchuk.z", "wii.ir"])
  }

  func testClassicHasEveryButton() {
    let ids = Set(cases([.wiiClassic])[0].layouts.flatMap(\.controls).map(\.id))
    XCTAssertEqual(ids, ["classic.dpad", "classic.leftStick", "classic.rightStick", "classic.a", "classic.b", "classic.x",
                         "classic.y", "classic.l", "classic.r", "classic.zl", "classic.zr", "classic.minus",
                         "classic.plus", "classic.home"])
  }

  func testGameCubeHasEveryButton() {
    let ids = Set(cases([.gameCube])[0].layouts.flatMap(\.controls).map(\.id))
    XCTAssertEqual(ids, ["gc.mainStick", "gc.cStick", "gc.dpad", "gc.a", "gc.b", "gc.x", "gc.y",
                         "gc.l", "gc.r", "gc.z", "gc.start"])
  }
}
#endif
