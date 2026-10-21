// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import iCube

@MainActor
final class QuickSavePickerSnapshotTests: XCTestCase {
  private struct FixtureProvider: SaveStateProviding {
    func states(for gameID: String) async -> [SaveStateInfo] { Self.fixtures }
    func statesGroupedByGame() async -> [String: [SaveStateInfo]] { ["GALE01": Self.fixtures] }
    func thumbnail(for state: SaveStateInfo) async -> UIImage? { nil }
    func delete(state: SaveStateInfo) throws { XCTFail("Rendering must not delete a state") }
    func rename(state: SaveStateInfo, to title: String) throws { XCTFail("Rendering must not rename a state") }

    static var fixtures: [SaveStateInfo] {
      let entries: [(String, String, Int?, Bool, Bool)] = [("Quick save", "GALE01.quick-A2CC29A2-38BC-41B6-B37C-7624990EAE90.s01", nil, false, true),
       ("Slot 4", "GALE01.s04", 4, false, false),
       ("Automatic resume", "GALE01.auto", nil, true, false)]
      return entries.enumerated().map { index, item in
        SaveStateInfo(gameID: "GALE01", displayName: item.0, slot: item.2, createdAt: nil,
                      modifiedAt: Date(timeIntervalSince1970: 1_792_500_000 - Double(index) * 600),
                      sizeBytes: nil, versionHash: nil, isCompatible: index != 1,
                      path: URL(fileURLWithPath: "/fixture/\(item.1)"), thumbnailURL: nil,
                      isAuto: item.3, isQuickSave: item.4)
      }
    }
  }

  private struct Harness: View {
    var onFooter: (CGRect) -> Void = { _ in }
    @State private var mode: QuickSaveMode
    @State private var slot = 4

    init(mode: QuickSaveMode, onFooter: @escaping (CGRect) -> Void = { _ in }) {
      _mode = State(initialValue: mode)
      self.onFooter = onFooter
    }

    var body: some View {
      QuickSavePickerView(gameID: "GALE01", mode: $mode, selectedSlot: $slot, onDismiss: {},
        operations: QuickSavePickerOperations(save: { _, _ in XCTFail("Rendering must not save"); return .saveFailed },
                                            load: { _, _ in XCTFail("Rendering must not load"); return .unavailable },
                                            setKept: { _, _, _ in XCTFail("Rendering must not pin"); return .keepFailed },
                                            saveSlot: { _ in XCTFail("Rendering must not save a classic slot"); return .saveFailed }),
        provider: FixtureProvider(), isModded: { false }, onFooterFrameChange: onFooter)
    }
  }

  func testPinnedActionsStayInsidePhonePadLandscapeAndSplitWindows() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852),
                 CGSize(width: 852, height: 393), CGSize(width: 1024, height: 1366),
                 CGSize(width: 320, height: 800)] {
      for mode in [QuickSaveMode.history, .slots] {
        var footer: CGRect = .zero
        var observedFrames: [CGRect] = []
        _ = render(Harness(mode: mode, onFooter: { observedFrames.append($0); footer = $0 }), size: size, scene: scene,
                   layoutReady: { footer.height > 0 })
        XCTAssertGreaterThanOrEqual(footer.height, 44, "Footer lifecycle samples: \(observedFrames)")
        XCTAssertGreaterThanOrEqual(footer.minX, 0)
        XCTAssertLessThanOrEqual(footer.maxX, size.width)
        XCTAssertGreaterThanOrEqual(footer.minY, 0)
        XCTAssertLessThanOrEqual(footer.maxY, size.height, "Save/Load footer is offscreen at \(size)")
      }
    }
  }

  func testAccessibilityFooterStaysReachableInLandscape() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let size = CGSize(width: 852, height: 393)
    var footer: CGRect = .zero
    var observedFrames: [CGRect] = []
    _ = render(Harness(mode: .slots, onFooter: { observedFrames.append($0); footer = $0 }).dynamicTypeSize(.accessibility3), size: size, scene: scene,
               layoutReady: { footer.height > 0 })
    XCTAssertGreaterThanOrEqual(footer.height, 88, "Footer lifecycle samples: \(observedFrames)")
    XCTAssertGreaterThanOrEqual(footer.minX, 0)
    XCTAssertLessThanOrEqual(footer.maxX, size.width)
    XCTAssertGreaterThanOrEqual(footer.minY, 0)
    XCTAssertLessThanOrEqual(footer.maxY, size.height)
  }

  func testFooterFrameCallbackTracksAccessibilityReflowInMountedPicker() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let size = CGSize(width: 852, height: 393)
    var observedFrames: [CGRect] = []
    let onFooter: (CGRect) -> Void = { observedFrames.append($0) }
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let host = UIHostingController(rootView: Harness(mode: .slots, onFooter: onFooter).dynamicTypeSize(.large))
    host.safeAreaRegions = []
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true }
    waitForLayout(in: window) { (observedFrames.last?.height ?? 0) >= 44 }
    let initialFrame = try XCTUnwrap(observedFrames.last)
    let initialCount = observedFrames.count

    // Keep the same mounted picker; Dynamic Type changes its footer from a row to a column.
    host.rootView = Harness(mode: .slots, onFooter: onFooter).dynamicTypeSize(.accessibility3)
    waitForLayout(in: window) {
      observedFrames.count > initialCount && (observedFrames.last?.height ?? 0) > initialFrame.height
    }
    let reflowed = try XCTUnwrap(observedFrames.last)
    XCTAssertGreaterThanOrEqual(reflowed.height, 88, "Footer lifecycle samples: \(observedFrames)")
    XCTAssertGreaterThan(reflowed.height, initialFrame.height)
    XCTAssertGreaterThanOrEqual(reflowed.minX, 0)
    XCTAssertLessThanOrEqual(reflowed.maxX, size.width)
    XCTAssertGreaterThanOrEqual(reflowed.minY, 0)
    XCTAssertLessThanOrEqual(reflowed.maxY, size.height)
  }

  func testRenderPicker() throws {
    guard let dir = ProcessInfo.processInfo.environment["TOP_BAR_SNAPSHOT_DIR"], !dir.isEmpty else {
      throw XCTSkip("set TOP_BAR_SNAPSHOT_DIR to render picker snapshots")
    }
    let output = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    for (name, size) in [("phone-portrait", CGSize(width: 393, height: 852)),
                         ("phone-landscape", CGSize(width: 852, height: 393)),
                         ("ipad-portrait", CGSize(width: 1024, height: 1366)),
                         ("ipad-landscape", CGSize(width: 1366, height: 1024)),
                         ("split", CGSize(width: 320, height: 800))] {
      for mode in [QuickSaveMode.history, .slots] {
        let image = render(Harness(mode: mode), size: size, scene: scene)
        try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("save-picker-\(name)-\(mode.rawValue).png"))
      }
    }
    let large = render(Harness(mode: .slots).dynamicTypeSize(.accessibility3), size: CGSize(width: 393, height: 852), scene: scene)
    try XCTUnwrap(large.pngData()).write(to: output.appendingPathComponent("save-picker-phone-accessibility.png"))
  }

  private func waitForLayout(in window: UIWindow, until layoutReady: () -> Bool) {
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let deadline = Date().addingTimeInterval(2)
    while !layoutReady(), Date() < deadline {
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(layoutReady(), "The real picker footer did not complete layout")
  }

  private func render<V: View>(_ view: V, size: CGSize, scene: UIWindowScene,
                               layoutReady: () -> Bool = { true }) -> UIImage {
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let host = UIHostingController(rootView: view)
    host.safeAreaRegions = []
    window.rootViewController = host
    window.isHidden = false
    waitForLayout(in: window, until: layoutReady)
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
