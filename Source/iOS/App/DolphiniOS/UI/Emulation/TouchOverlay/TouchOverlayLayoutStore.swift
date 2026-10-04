// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Combine
import CoreGraphics
import Foundation

/// Where a group the user moved sits: on each axis, the canvas edge (or centre line) nearest to
/// it and the distance in points from there to the group's centre. Points from an edge, like the
/// defaults' `TouchOverlayPlacement.inset`, so a stick placed 40 pt from the right edge stays 40 pt
/// from the right edge on a wider or narrower screen; fractions of the canvas did not.
struct TouchOverlayAnchoredCenter: Codable, Equatable, Sendable {
  enum Edge: String, Codable, Sendable {
    /// Leading (x) or top (y).
    case min
    /// The centre line; the offset is signed, positive towards trailing / bottom.
    case mid
    /// Trailing (x) or bottom (y).
    case max
  }

  var h: Edge
  var x: Double
  var v: Edge
  var y: Double

  /// Anchors `center` to the nearest edge on each axis: the outer thirds of the canvas hang from
  /// their edge, the middle third from the centre line.
  static func anchoring(_ center: CGPoint, in bounds: CGRect) -> Self {
    let (h, x) = anchor(center.x, min: bounds.minX, mid: bounds.midX, max: bounds.maxX, extent: bounds.width)
    let (v, y) = anchor(center.y, min: bounds.minY, mid: bounds.midY, max: bounds.maxY, extent: bounds.height)
    return Self(h: h, x: x, v: v, y: y)
  }

  func point(in bounds: CGRect) -> CGPoint {
    CGPoint(x: Self.resolve(h, x, min: bounds.minX, mid: bounds.midX, max: bounds.maxX),
            y: Self.resolve(v, y, min: bounds.minY, mid: bounds.midY, max: bounds.maxY))
  }

  private static func anchor(_ value: CGFloat, min lo: CGFloat, mid: CGFloat, max hi: CGFloat,
                             extent: CGFloat) -> (Edge, Double) {
    if value < lo + extent / 3 { return (.min, Double(value - lo)) }
    if value > hi - extent / 3 { return (.max, Double(hi - value)) }
    return (.mid, Double(value - mid))
  }

  private static func resolve(_ edge: Edge, _ offset: Double, min lo: CGFloat, mid: CGFloat,
                              max hi: CGFloat) -> CGFloat {
    switch edge {
    case .min: return lo + CGFloat(offset)
    case .mid: return mid + CGFloat(offset)
    case .max: return hi - CGFloat(offset)
    }
  }
}

/// Persists the user's custom group positions and size scales per pad kind and orientation. A
/// group without a stored position falls back to `TouchOverlayDefaults`, so a fresh install and
/// "Reset" both render exactly like the xib pads. Ported from iFly's `ButtonLayoutStore`, but
/// backed by a JSON file next to `game_profiles.json` (`<UserFolder>/Profiles/`) instead of
/// UserDefaults, following `GameProfiles`. Global, not per game, in v1 (§2.3).
///
/// On disk (`touch_overlay_layout_v2.json`), each group is an `Entry`: `at` is a
/// `TouchOverlayAnchoredCenter` (absent while the group keeps its default position, so a resize
/// alone does not pin it), `scale` is `[]`, `[s]` or `[sx, sy]`.
///
/// Migration: v1 (`touch_overlay_layout.json`) stored `[x, y]`, `[x, y, s]` or `[x, y, sx, sy]`
/// with x and y as 0-1 fractions of the canvas. With no v2 file, the v1 file is read and its
/// positions kept as `fraction` until the first edit of that pad kind and orientation, which
/// re-anchors every fraction there against the canvas it is showing on, so nothing moves. The v1
/// file is never written, so an older build still reads the layout it saved.
@MainActor
final class TouchOverlayLayoutStore: ObservableObject {
  static let shared = TouchOverlayLayoutStore()

  static let fileName = "touch_overlay_layout_v2.json"
  static let legacyFileName = "touch_overlay_layout.json"

  struct Entry: Codable, Equatable {
    /// Where the user moved the group; nil keeps the default position.
    var at: TouchOverlayAnchoredCenter?
    /// A v1 position (0-1 of the canvas) not yet re-anchored.
    var fraction: [Double]?
    /// `[]` (default size), `[s]` (uniform) or `[sx, sy]` (the IR pad's own width and height).
    var scale: [Double] = []

    init(at: TouchOverlayAnchoredCenter? = nil, fraction: [Double]? = nil, scale: [Double] = []) {
      self.at = at
      self.fraction = fraction
      self.scale = scale
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      at = try container.decodeIfPresent(TouchOverlayAnchoredCenter.self, forKey: .at)
      fraction = try container.decodeIfPresent([Double].self, forKey: .fraction)
      scale = try container.decodeIfPresent([Double].self, forKey: .scale) ?? []
    }

    /// A v1 array: `[x, y]` followed by zero, one or two scale elements.
    init?(legacy values: [Double]) {
      guard values.count >= 2 else { return nil }
      self.init(fraction: Array(values[0 ..< 2]), scale: Array(values.dropFirst(2).prefix(2)))
    }

    func center(in bounds: CGRect) -> CGPoint? {
      if let at { return at.point(in: bounds) }
      if let fraction, fraction.count >= 2 {
        return TouchOverlayLayoutEngine.denormalize(CGPoint(x: fraction[0], y: fraction[1]), in: bounds)
      }
      return nil
    }
  }

  /// Bumped on every mutation so SwiftUI re-renders even though the backing map is private.
  @Published private(set) var revision = 0

  private let fileURL: URL?
  private let legacyFileURL: URL?
  /// "<padKind>.<orientation>" -> [group.rawValue: Entry].
  private var layouts: [String: [String: Entry]] = [:]

  private init() {
    let dir = Self.profilesDirectory()
    fileURL = dir?.appendingPathComponent(Self.fileName)
    legacyFileURL = dir?.appendingPathComponent(Self.legacyFileName)
    load()
  }

  /// Test / preview entry point: explicit files (nil keeps everything in memory).
  init(fileURL: URL?, legacyFileURL: URL? = nil) {
    self.fileURL = fileURL
    self.legacyFileURL = legacyFileURL
    load()
  }

  private static func profilesDirectory() -> URL? {
    let base = UserFolderUtil.getUserFolder()
    let dir = URL(fileURLWithPath: base).appendingPathComponent("Profiles", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func key(_ kind: TouchOverlayPadKind, _ orientation: TouchOverlayOrientation) -> String {
    kind.rawValue + "." + orientation.rawValue
  }

  private func load() {
    if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
      do {
        layouts = try JSONDecoder().decode([String: [String: Entry]].self, from: Data(contentsOf: url))
      } catch {
        NSLog("[TouchOverlay] Failed to load %@: %@", url.lastPathComponent, String(describing: error))
      }
      return
    }
    guard let url = legacyFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      let legacy = try JSONDecoder().decode([String: [String: [Double]]].self, from: Data(contentsOf: url))
      layouts = legacy.mapValues { groups in groups.compactMapValues { Entry(legacy: $0) } }
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

  private func entry(_ group: TouchOverlayGroup, _ padKind: TouchOverlayPadKind,
                     _ orientation: TouchOverlayOrientation) -> Entry? {
    layouts[Self.key(padKind, orientation)]?[group.rawValue]
  }

  /// The stored centre of a group in `bounds`, or nil when the user has not moved it.
  func center(for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
              orientation: TouchOverlayOrientation, in bounds: CGRect) -> CGPoint? {
    entry(group, padKind, orientation)?.center(in: bounds)
  }

  /// The stored anchored position of a group, or nil when it is default or not yet re-anchored.
  func anchoredCenter(for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
                      orientation: TouchOverlayOrientation) -> TouchOverlayAnchoredCenter? {
    entry(group, padKind, orientation)?.at
  }

  /// The stored size scale for a group, or 1.0 (the default footprint). For a group with an
  /// independent width/height scale (only `wiiIRPad`, written by `setIRSizeScale`), this returns
  /// the WIDTH component; use `sizeScaleXY` to read both.
  func sizeScale(for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
                 orientation: TouchOverlayOrientation) -> CGFloat {
    sizeScaleXY(for: group, padKind: padKind, orientation: orientation).width
  }

  /// The stored (width, height) size scale for a group: `[]` -> (1, 1); `[s]` (every group's
  /// uniform resize in Edit Layout) -> (s, s); `[sx, sy]` (only `setIRSizeScale`) -> (sx, sy).
  func sizeScaleXY(for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
                   orientation: TouchOverlayOrientation) -> CGSize {
    guard let scale = entry(group, padKind, orientation)?.scale, let sx = scale.first else {
      return CGSize(width: 1, height: 1)
    }
    return CGSize(width: CGFloat(sx), height: CGFloat(scale.count >= 2 ? scale[1] : sx))
  }

  func hasCustomLayout(padKind: TouchOverlayPadKind, orientation: TouchOverlayOrientation) -> Bool {
    !(layouts[Self.key(padKind, orientation)] ?? [:]).isEmpty
  }

  /// The box a group occupies in `bounds`: the stored centre when the user moved it, otherwise
  /// the xib-derived default, scaled by the stored size scale (default 1.0); either way
  /// re-clamped so it stays on-screen. Scaling happens BEFORE clamping so an enlarged group
  /// clamps against its own (larger) footprint, not the unscaled one.
  func resolvedBox(for layout: TouchOverlayGroupLayout, padKind: TouchOverlayPadKind,
                   orientation: TouchOverlayOrientation, in bounds: CGRect) -> CGRect {
    let baseSize = layout.placement.resolvedSize(in: bounds)
    let scaleXY = layout.placement.anchor == .fill ? CGSize(width: 1, height: 1)
      : sizeScaleXY(for: layout.group, padKind: padKind, orientation: orientation)
    let size = CGSize(width: baseSize.width * scaleXY.width, height: baseSize.height * scaleXY.height)
    let stored = center(for: layout.group, padKind: padKind, orientation: orientation, in: bounds)
    let clamped = TouchOverlayLayoutEngine.clampCenter(stored ?? layout.placement.center(in: bounds),
                                                       size: size, bounds: bounds)
    return TouchOverlayLayoutEngine.box(center: clamped, size: size)
  }

  // MARK: Writes

  /// Re-anchors every v1 fraction of one pad kind and orientation against `bounds`, the canvas
  /// they are showing on now, so the conversion moves nothing.
  private func reanchorFractions(_ key: String, in bounds: CGRect) {
    guard var groups = layouts[key] else { return }
    for (group, entry) in groups where entry.at == nil {
      guard let center = entry.center(in: bounds) else { continue }
      groups[group] = Entry(at: .anchoring(center, in: bounds), scale: entry.scale)
    }
    layouts[key] = groups
  }

  private func update(_ group: TouchOverlayGroup, _ padKind: TouchOverlayPadKind,
                      _ orientation: TouchOverlayOrientation, in bounds: CGRect,
                      _ change: (inout Entry) -> Void) {
    let key = Self.key(padKind, orientation)
    reanchorFractions(key, in: bounds)
    var entry = layouts[key]?[group.rawValue] ?? Entry()
    change(&entry)
    layouts[key, default: [:]][group.rawValue] = entry
    save()
    revision += 1
  }

  /// Store a centre given in points of `bounds` (the editor's drop position), anchored to the
  /// nearest edges. Keeps the group's size scale.
  func setCenter(_ center: CGPoint, in bounds: CGRect, for group: TouchOverlayGroup,
                 padKind: TouchOverlayPadKind, orientation: TouchOverlayOrientation) {
    let clamped = CGPoint(x: min(max(center.x, bounds.minX), bounds.maxX),
                          y: min(max(center.y, bounds.minY), bounds.maxY))
    update(group, padKind, orientation, in: bounds) { $0.at = .anchoring(clamped, in: bounds) }
  }

  /// Store a uniform size scale (clamped to `scaleRange`). The group's position is untouched: a
  /// group the user never moved keeps following its default placement. Used by the editor's
  /// resize handles (§2.4).
  func setSizeScale(_ scale: CGFloat, for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
                    orientation: TouchOverlayOrientation, in bounds: CGRect) {
    let clamped = min(max(Double(scale), Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    update(group, padKind, orientation, in: bounds) { $0.scale = [clamped] }
  }

  /// Store an independent (width, height) size scale (task item 1's "Edit IR Area" editor). Each
  /// axis is clamped by `TouchOverlayIRGeometry.clampFillInsetScale` against `bounds`/`baseSize`
  /// on that axis, NOT the generic `scaleRange` `setSizeScale` uses: a `.fillInset` group needs a
  /// tighter, bounds-aware cap. The position is untouched, as in `setSizeScale`.
  func setIRSizeScale(_ scale: CGSize, for group: TouchOverlayGroup, padKind: TouchOverlayPadKind,
                      orientation: TouchOverlayOrientation, bounds: CGRect, baseSize: CGSize) {
    let clampedX = TouchOverlayIRGeometry.clampFillInsetScale(scale.width, baseExtent: baseSize.width, boundsExtent: bounds.width)
    let clampedY = TouchOverlayIRGeometry.clampFillInsetScale(scale.height, baseExtent: baseSize.height, boundsExtent: bounds.height)
    update(group, padKind, orientation, in: bounds) { $0.scale = [Double(clampedX), Double(clampedY)] }
  }

  /// The editor's "Reset": clear every custom position of a pad kind, both orientations.
  func reset(padKind: TouchOverlayPadKind) {
    for orientation in TouchOverlayOrientation.allCases {
      layouts.removeValue(forKey: Self.key(padKind, orientation))
    }
    save()
    revision += 1
  }

  /// A narrower reset for the "Edit IR Area" editor's own Reset button (task item 1): clears only
  /// ONE group's stored entry, both orientations, instead of every group in the pad kind — the
  /// editor should not silently discard the user's face-button/D-pad/stick layout just because
  /// they were resetting the IR pad's rectangle.
  func resetGroup(_ group: TouchOverlayGroup, padKind: TouchOverlayPadKind) {
    for orientation in TouchOverlayOrientation.allCases {
      layouts[Self.key(padKind, orientation)]?.removeValue(forKey: group.rawValue)
    }
    save()
    revision += 1
  }
}
#endif
