// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Combine
import CoreGraphics
import Foundation

/// Persists the user's custom group CENTERS (and, phase 2, an optional per-group SIZE SCALE) per
/// pad kind and orientation, normalized to 0-1 of the overlay's bounds so they survive device and
/// orientation changes. A group without a stored center falls back to `TouchOverlayDefaults`, so a
/// fresh install and "Reset" both render exactly like the xib pads. Ported from iFly's
/// `ButtonLayoutStore`, but backed by a JSON file next to `game_profiles.json`
/// (`<UserFolder>/Profiles/touch_overlay_layout.json`) instead of UserDefaults, following
/// `GameProfiles`. Global, not per game, in v1 (§2.3).
///
/// On-disk schema: `[x, y]` (phase 1) or `[x, y, scale]` (phase 2, added backward-compatibly — a
/// missing third element reads as `1.0`, so every phase-1 file and every group the user has never
/// resized keep working unchanged).
@MainActor
final class TouchOverlayLayoutStore: ObservableObject {
  static let shared = TouchOverlayLayoutStore()

  static let fileName = "touch_overlay_layout.json"

  /// Bumped on every mutation so SwiftUI re-renders even though the backing map is private.
  @Published private(set) var revision = 0

  private let fileURL: URL?
  /// "<padKind>.<orientation>" -> [group.rawValue: [x, y]].
  private var layouts: [String: [String: [Double]]] = [:]

  private init() {
    fileURL = Self.defaultFileURL()
    load()
  }

  /// Test / preview entry point: an explicit file (nil keeps everything in memory).
  init(fileURL: URL?) {
    self.fileURL = fileURL
    load()
  }

  private static func defaultFileURL() -> URL? {
    let base = UserFolderUtil.getUserFolder()
    let dir = URL(fileURLWithPath: base).appendingPathComponent("Profiles", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(fileName)
  }

  static func key(_ kind: TouchOverlayPadKind, _ orientation: TouchOverlayOrientation) -> String {
    kind.rawValue + "." + orientation.rawValue
  }

  private func load() {
    guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      let data = try Data(contentsOf: url)
      layouts = try JSONDecoder().decode([String: [String: [Double]]].self, from: data)
    } catch {
      NSLog("[TouchOverlay] Failed to load %@: %@", url.lastPathComponent, String(describing: error))
    }
  }

  private func save() {
    guard let url = fileURL else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(layouts).write(to: url, options: .atomic)
    } catch {
      NSLog("[TouchOverlay] Failed to save %@: %@", url.lastPathComponent, String(describing: error))
    }
  }

  /// Clamp range for a per-group size scale (§2.4 extension, phase 2). 1.0 is the xib-derived
  /// default footprint; the range keeps a resize from either disappearing (too small to hit) or
  /// swallowing the rest of the pad (too large).
  static let scaleRange: ClosedRange<Double> = 0.5...2.0

  // MARK: Reads

  /// The stored normalized center for a group, or nil when the user has not moved it. Accepts
  /// both the phase 1 `[x, y]` and phase 2 `[x, y, scale]` encodings.
  func normalizedCenter(for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
                        orientation: TouchOverlayOrientation) -> CGPoint? {
    guard let xy = layouts[Self.key(padKind, orientation)]?[group.rawValue], xy.count >= 2 else { return nil }
    return CGPoint(x: xy[0], y: xy[1])
  }

  /// The stored size scale for a group, or 1.0 (the default footprint) when absent — either
  /// because the entry predates phase 2, or the user has never resized this group.
  func sizeScale(for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
                 orientation: TouchOverlayOrientation) -> CGFloat {
    guard let xy = layouts[Self.key(padKind, orientation)]?[group.rawValue], xy.count >= 3 else { return 1.0 }
    return CGFloat(xy[2])
  }

  func hasCustomLayout(padKind: TouchOverlayPadKind, orientation: TouchOverlayOrientation) -> Bool {
    !(layouts[Self.key(padKind, orientation)] ?? [:]).isEmpty
  }

  /// The box a group occupies in `bounds`: the stored center (denormalized) when the user moved
  /// it, otherwise the xib-derived default, scaled by the stored size scale (default 1.0); either
  /// way re-clamped so it stays on-screen. Scaling happens BEFORE clamping so an enlarged group
  /// clamps against its own (larger) footprint, not the unscaled one.
  func resolvedBox(for layout: TouchOverlayGroupLayout, padKind: TouchOverlayPadKind,
                   orientation: TouchOverlayOrientation, in bounds: CGRect) -> CGRect {
    let baseSize = layout.placement.resolvedSize(in: bounds)
    let scale = layout.placement.anchor == .fill ? 1.0 : sizeScale(for: layout.group, padKind: padKind, orientation: orientation)
    let size = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    let center: CGPoint
    if let stored = normalizedCenter(for: layout.group, padKind: padKind, orientation: orientation) {
      center = TouchOverlayLayoutEngine.denormalize(stored, in: bounds)
    } else {
      center = layout.placement.center(in: bounds)
    }
    let clamped = TouchOverlayLayoutEngine.clampCenter(center, size: size, bounds: bounds)
    return TouchOverlayLayoutEngine.box(center: clamped, size: size)
  }

  // MARK: Writes

  /// Store a normalized center (clamped to 0-1) and bump `revision`. Preserves any existing size
  /// scale for the group (a drag shouldn't reset a resize).
  func setNormalizedCenter(_ point: CGPoint, for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
                           orientation: TouchOverlayOrientation) {
    let x = min(max(Double(point.x), 0), 1)
    let y = min(max(Double(point.y), 0), 1)
    let existingScale = layouts[Self.key(padKind, orientation)]?[group.rawValue].flatMap { $0.count >= 3 ? $0[2] : nil }
    var entry = [x, y]
    if let existingScale { entry.append(existingScale) }
    layouts[Self.key(padKind, orientation), default: [:]][group.rawValue] = entry
    save()
    revision += 1
  }

  /// Store a size scale (clamped to `scaleRange`), keeping the group's current (or default)
  /// center. Used by the editor's resize handles (§2.4).
  func setSizeScale(_ scale: CGFloat, for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
                    orientation: TouchOverlayOrientation, defaultCenter: CGPoint) {
    let clampedScale = min(max(Double(scale), Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    let key = Self.key(padKind, orientation)
    let existing = layouts[key]?[group.rawValue]
    let x = (existing?.count ?? 0) >= 1 ? existing![0] : Double(defaultCenter.x)
    let y = (existing?.count ?? 0) >= 2 ? existing![1] : Double(defaultCenter.y)
    layouts[key, default: [:]][group.rawValue] = [x, y, clampedScale]
    save()
    revision += 1
  }

  /// Store a center given in points of `bounds` (the editor's drop position).
  func setCenter(_ center: CGPoint, in bounds: CGRect, for group: TouchOverlayGroup,
                 padKind: TouchOverlayPadKind, orientation: TouchOverlayOrientation) {
    setNormalizedCenter(TouchOverlayLayoutEngine.normalize(center, in: bounds),
                        for: group, padKind: padKind, orientation: orientation)
  }

  /// The editor's "Reset": clear every custom position of a pad kind, both orientations.
  func reset(padKind: TouchOverlayPadKind) {
    for orientation in TouchOverlayOrientation.allCases {
      layouts.removeValue(forKey: Self.key(padKind, orientation))
    }
    save()
    revision += 1
  }
}
#endif
