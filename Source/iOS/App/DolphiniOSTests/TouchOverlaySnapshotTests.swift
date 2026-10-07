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

  /// The `TestCube` fixture skin on every preview device, with each item's hit (yellow) and draw (cyan)
  /// frame outlined. The fixture ships no button art, so only its background and the geometry show.
  func testRenderFixtureSkin() throws {
    guard let dir = ProcessInfo.processInfo.environment[Self.outputDirKey], !dir.isEmpty else {
      throw XCTSkip("set \(Self.outputDirKey) to render layout snapshots")
    }
    let outputDir = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestCube", withExtension: "deltaskin", subdirectory: "Skins"))
    let info = try SkinInfo.load(directory: directory)
    let skin = InstalledSkin(id: info.identifier, name: info.name, gameType: info.gameType, directory: directory)

    for device in TouchOverlayPreviewDevice.all {
      for orientation in TouchOverlayOrientation.allCases {
        let image = render(TouchOverlayPreviewScreen(padKind: .gameCube, device: device, orientation: orientation, skin: skin),
                           size: device.size(orientation), scene: scene)
        let name = "skin-\(orientation.rawValue)-\(device.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "\"", with: "in")).png"
        try XCTUnwrap(image.pngData()).write(to: outputDir.appendingPathComponent(name))
      }
    }
  }

  /// Every steady state of the procedural art (each button shape and palette pressed and released, the
  /// D-pad with arrows lit, the stick base dragging and idle, the knob, a whole stick), each also at the
  /// shipped 50 % overlay opacity. For pixel-diffing an art or render-cost change against the commit
  /// before it: the pressed looks never show in the layout snapshots above.
  func testRenderArtStates() throws {
    guard let dir = ProcessInfo.processInfo.environment[Self.outputDirKey], !dir.isEmpty else {
      throw XCTSkip("set \(Self.outputDirKey) to render layout snapshots")
    }
    let outputDir = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("art", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let canvas = CGSize(width: 200, height: 200)
    let shippedOpacity = 0.5

    func write<V: View>(_ name: String, _ view: V) throws {
      for (suffix, opacity) in [("", 1.0), ("-faded", shippedOpacity)] {
        let framed = ZStack { Color(white: 0.3); view.opacity(opacity) }.frame(width: canvas.width, height: canvas.height)
        let image = render(framed, size: canvas, scene: scene)
        try XCTUnwrap(image.pngData()).write(to: outputDir.appendingPathComponent("\(name)\(suffix).png"))
      }
    }

    let buttons: [(id: String, shape: TouchOverlayArt.ButtonShape, size: CGSize)] = [
      ("gc.a", .circle, CGSize(width: 72, height: 72)), ("gc.b", .circle, CGSize(width: 48, height: 48)),
      ("gc.x", .kidney, CGSize(width: 76, height: 46)), ("gc.z", .bar, CGSize(width: 96, height: 40)),
      ("gc.start", .pill, CGSize(width: 54, height: 26)),
    ]
    for variant in [TouchOverlayArt.Variant.gameCube, .wii] {
      for button in buttons {
        for pressed in [false, true] {
          try write("button-\(variant)-\(button.id)-\(pressed ? "down" : "up")",
                    TouchOverlayArt.button(controlId: button.id, shape: button.shape, variant: variant, pressed: pressed)
                      .frame(width: button.size.width, height: button.size.height))
        }
      }
      let lit: [(String, Set<TouchOverlayHitTester.DPadDirection>)] = [
        ("none", []), ("up", [.up]), ("downleft", [.down, .left]), ("right", [.right]),
      ]
      for (name, directions) in lit {
        try write("dpad-\(variant)-\(name)", TouchOverlayArt.dpad(pressed: directions, variant: variant).frame(width: 128, height: 128))
      }
      for dragging in [false, true] {
        try write("stickbase-\(variant)-\(dragging ? "drag" : "idle")",
                  TouchOverlayArt.stickBase(variant: variant, dragging: dragging).frame(width: 140, height: 140))
      }
      try write("stickknob-\(variant)", TouchOverlayArt.stickKnob(variant: variant).frame(width: 56, height: 56))
      try write("stick-\(variant)", TouchOverlayStickView(baseId: 10, deviceId: 0, variant: variant,
                                                          groupSize: CGSize(width: 140, height: 140), isEditing: true))
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
