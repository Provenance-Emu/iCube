// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation

/// The pure half of the skin overlay: given a laid-out skin, turns touch points into the items they
/// press and the presses into writes for the touchscreen pad, using the same helpers the Swift-drawn
/// overlay uses (`TouchOverlayHitTester`, `TouchOverlayInput`). `SkinOverlayView` only forwards touches
/// here and the results to `TCManagerInterface`.
struct SkinOverlayInput {
  typealias LayoutItem = (item: SkinItem, drawFrame: CGRect, hitFrame: CGRect)
  typealias Direction = TouchOverlayHitTester.DPadDirection

  /// One thing a finger is on: a button item, or one direction of a d-pad item. A d-pad contributes
  /// one hit per engaged direction (two for a diagonal).
  enum Hit: Hashable {
    case item(Int)
    case direction(item: Int, Direction)
  }

  enum Channel: Int, Hashable {
    /// `TCManagerInterface.setButtonStateFor`.
    case button
    /// `TCManagerInterface.setAxisValueFor`, 1.0 down / 0.0 up (an analog trigger).
    case axis
  }

  struct Write: Equatable {
    let channel: Channel
    let id: Int
    let pressed: Bool

    /// The value an axis write carries.
    var axisValue: Float { pressed ? Self.axisDown : Self.axisUp }

    private static let axisDown: Float = 1
    private static let axisUp: Float = 0
  }

  /// What an item does on the current pad. Items whose inputs the pad does not know resolve to nothing.
  private enum Control {
    case buttons(kinds: [TouchOverlayControlKind], actions: [SkinAction])
    case dpad(baseId: Int)
    case stick(baseId: Int)
  }

  /// A thumbstick item, in the coordinates of its own `hitFrame` (where the stick's touch surface sits).
  struct Stick {
    let itemIndex: Int
    let baseId: Int
    let drawFrame: CGRect
    let hitFrame: CGRect
    /// The knob image's file name and its size on screen, if the skin gives them.
    let knobName: String?
    let thumbSize: CGSize?

    /// Centre of the art, in `hitFrame`-local coordinates.
    var center: CGPoint { CGPoint(x: drawFrame.midX - hitFrame.minX, y: drawFrame.midY - hitFrame.minY) }

    /// How far the knob's centre may move: until it touches the art's edge, or a third of the width
    /// (the xib stick's travel) when the skin has no knob image.
    var travel: CGFloat {
      let shortSide = min(drawFrame.width, drawFrame.height)
      if let thumbSize {
        let room = (shortSide - max(thumbSize.width, thumbSize.height)) / 2
        if room > 0 { return room }
      }
      return shortSide * TouchOverlayInput.stickTravelFraction
    }

    /// `touch` is in `hitFrame`-local coordinates; nil is a release (centred).
    private func axes(touch: CGPoint?) -> (x: CGFloat, y: CGFloat) {
      guard let touch else { return (0, 0) }
      return TouchOverlayInput.stickAxes(touch: touch, center: center, maxDistance: travel)
    }

    func writes(touch: CGPoint?) -> [(id: Int, value: Float)] {
      let axes = axes(touch: touch)
      return TouchOverlayInput.stickWrites(x: axes.x, y: axes.y, baseId: baseId)
    }

    func knobOffset(touch: CGPoint?) -> CGSize {
      let axes = axes(touch: touch)
      return CGSize(width: axes.x * travel, height: axes.y * travel)
    }
  }

  private static let upSuffix = "Up"

  private let items: [LayoutItem]
  private let controls: [Control?]
  let sticks: [Stick]

  init(layout: SkinLayout, padKind: TouchOverlayPadKind) {
    items = layout.items
    controls = layout.items.map { Self.resolve($0.item, padKind: padKind) }
    sticks = zip(layout.items, controls).enumerated().compactMap { index, pair in
      guard case .stick(let baseId)? = pair.1 else { return nil }
      let entry = pair.0
      let scale = entry.item.frame.width > 0 ? entry.drawFrame.width / entry.item.frame.width : 1
      let thumbSize = entry.item.thumbstick.map { CGSize(width: $0.width * scale, height: $0.height * scale) }
      return Stick(itemIndex: index, baseId: baseId, drawFrame: entry.drawFrame, hitFrame: entry.hitFrame,
                   knobName: entry.item.thumbstick?.name, thumbSize: thumbSize)
    }
  }

  // MARK: Representation

  /// An iPad uses the skin's iPad layout when it has one and its iPhone layout otherwise; an iPhone
  /// only ever uses the iPhone layout.
  static func representation(info: SkinInfo, isPad: Bool, orientation: TouchOverlayOrientation) -> SkinRepresentation? {
    let devices: [SkinDevice] = isPad ? [.ipad, .iphone] : [.iphone]
    for device in devices {
      if let representation = info.representation(device: device, orientation: orientation) { return representation }
    }
    return nil
  }

  // MARK: Resolving items

  private static func resolve(_ item: SkinItem, padKind: TouchOverlayPadKind) -> Control? {
    switch item.inputs {
    case .buttons(let names):
      var kinds: [TouchOverlayControlKind] = []
      var actions: [SkinAction] = []
      for name in names {
        guard let action = SkinInputMap.action(for: [name], padKind: padKind) else { continue }
        if case .control(let kind) = action {
          if !kinds.contains(kind) { kinds.append(kind) }
        } else if !actions.contains(action) {
          actions.append(action)
        }
      }
      return kinds.isEmpty && actions.isEmpty ? nil : .buttons(kinds: kinds, actions: actions)
    case .directional(let up, _, _, _):
      if let prefix = thumbstickPrefix(ofUp: up) {
        guard case .stick(let baseId)? = SkinInputMap.stick(prefix: prefix, padKind: padKind) else { return nil }
        return .stick(baseId: baseId)
      }
      guard case .dpad(let baseId) = SkinInputMap.dpad(padKind: padKind) else { return nil }
      return .dpad(baseId: baseId)
    }
  }

  /// `leftThumbstick` for `leftThumbstickUp`; nil for any other name (a d-pad's `up`).
  private static func thumbstickPrefix(ofUp up: String) -> String? {
    guard up.lowercased().hasSuffix(upSuffix.lowercased()) else { return nil }
    let prefix = String(up.dropLast(upSuffix.count))
    let sticks = [SkinInputName.leftThumbstick, SkinInputName.rightThumbstick].map { $0.lowercased() }
    return sticks.contains(prefix.lowercased()) ? prefix : nil
  }

  // MARK: Hit testing

  /// The item (or d-pad directions) under a finger at `point`. `previous` carries the d-pad's
  /// direction hysteresis from the last pass. Where hit frames overlap, the item whose art is under
  /// the finger wins, then the one with the nearest centre. Sticks have their own surface.
  func hits(at point: CGPoint, previous: Set<Hit>) -> Set<Hit> {
    let candidates = items.indices.filter { index in
      switch controls[index] {
      case .buttons?, .dpad?: return items[index].hitFrame.contains(point)
      case .stick?, nil: return false
      }
    }
    let ordered = candidates.sorted { lhs, rhs in
      let left = (items[lhs].drawFrame.contains(point) ? 0 : 1, distance(from: point, toCentreOf: items[lhs].drawFrame))
      let right = (items[rhs].drawFrame.contains(point) ? 0 : 1, distance(from: point, toCentreOf: items[rhs].drawFrame))
      return left < right
    }
    let regions = ordered.map { TouchOverlayHitTester.Region(id: String($0), frame: items[$0].hitFrame) }
    guard let id = TouchOverlayHitTester.union(touches: [point], regions: regions).first, let index = Int(id) else { return [] }

    guard case .dpad? = controls[index] else { return [.item(index)] }
    let frame = items[index].drawFrame
    let previousDirections = Set(previous.compactMap { hit -> Direction? in
      if case .direction(let item, let direction) = hit, item == index { return direction }
      return nil
    })
    let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    let directions = TouchOverlayHitTester.dpadDirections(at: local, in: frame.size, previous: previousDirections)
    return Set(directions.map { .direction(item: index, $0) })
  }

  private func distance(from point: CGPoint, toCentreOf frame: CGRect) -> CGFloat {
    hypot(point.x - frame.midX, point.y - frame.midY)
  }

  // MARK: Writes and actions

  /// One pad id a hit drives. The view remembers the keys it has written rather than the hits, so a
  /// layout change (rotation) between press and release still releases exactly what was pressed.
  struct Key: Hashable {
    let channel: Channel
    let id: Int
  }

  func keys(of hits: Set<Hit>) -> Set<Key> {
    var result: Set<Key> = []
    for hit in hits {
      switch hit {
      case .item(let index):
        guard case .buttons(let kinds, _)? = control(at: index) else { continue }
        for kind in kinds {
          switch kind {
          case .button(let id): result.insert(Key(channel: .button, id: id))
          case .axisButton(let id): result.insert(Key(channel: .axis, id: id))
          case .stick, .dpad, .irSurface: break
          }
        }
      case .direction(let index, let direction):
        guard case .dpad(let baseId)? = control(at: index) else { continue }
        let writes = TouchOverlayInput.dpadWrites(up: direction == .up, down: direction == .down,
                                                  left: direction == .left, right: direction == .right, baseId: baseId)
        if let id = writes.first(where: { $0.pressed })?.id { result.insert(Key(channel: .button, id: id)) }
      }
    }
    return result
  }

  private func control(at index: Int) -> Control? {
    controls.indices.contains(index) ? controls[index] : nil
  }

  /// What to send when the ids held go from `before` to `after`: releases first, then presses.
  /// Computed per pad id, so an id two items share stays down until both let go.
  static func writes(from before: Set<Key>, to after: Set<Key>) -> [Write] {
    func ordered(_ keys: Set<Key>, pressed: Bool) -> [Write] {
      keys.sorted { ($0.channel.rawValue, $0.id) < ($1.channel.rawValue, $1.id) }
        .map { Write(channel: $0.channel, id: $0.id, pressed: pressed) }
    }
    return ordered(before.subtracting(after), pressed: false) + ordered(after.subtracting(before), pressed: true)
  }

  func writes(now: Set<Hit>, previous: Set<Hit>) -> [Write] {
    Self.writes(from: keys(of: previous), to: keys(of: now))
  }

  /// The app-level actions (menu, quick save/load) of items that just became covered; each fires once per press.
  func actions(now: Set<Hit>, previous: Set<Hit>) -> [SkinAction] {
    let newItems = now.subtracting(previous).compactMap { hit -> Int? in
      if case .item(let index) = hit { return index }
      return nil
    }
    return newItems.sorted().flatMap { index -> [SkinAction] in
      guard case .buttons(_, let actions)? = control(at: index) else { return [] }
      return actions
    }
  }
}
#endif
