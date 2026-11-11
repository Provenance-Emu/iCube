// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SkinKit2Core
import SkinKit2Render
import SkinKitUI
import SwiftUI
import UIKit

/// Bundled format 2 defaults. Imported classic skins retain their own mount path.
@MainActor
enum DefaultSkin2Pad {
  private static var documents: [TouchOverlayPadKind: Skin2Document] = [:]

  static func document(for kind: TouchOverlayPadKind, bundle: Bundle = .main) throws -> Skin2Document {
    if bundle == .main, let document = documents[kind] { return document }
    guard let directory = bundle.url(forResource: "DefaultSkins", withExtension: nil) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let file = directory.appendingPathComponent(kind.rawValue).appendingPathComponent("skin.json")
    let data = try Data(contentsOf: file)
    let report = Skin2Validator.validate(data: data)
    guard report.isValid else { throw Skin2Error("/", "Invalid bundled pad \(kind.rawValue): \(report)") }
    let document = try Skin2Document.load(data: data)
    if bundle == .main { documents[kind] = document }
    return document
  }

  static func environment(canvas: CGSize, safeArea: UIEdgeInsets, flags: Set<String>, isPad: Bool? = nil) -> Skin2Environment {
    let pad = isPad ?? (UIDevice.current.userInterfaceIdiom == .pad)
    return Skin2Environment(size: Skin2Size(width: canvas.width, height: canvas.height),
                            safeArea: Skin2Insets(top: safeArea.top, left: safeArea.left,
                                                  bottom: safeArea.bottom, right: safeArea.right),
                            device: pad ? .ipad : .iphone,
                            displayType: pad || safeArea == .zero ? .standard : .edgeToEdge, flags: flags)
  }

  /// The bundled pads retain iCube's usable-width policy, including the Duo status column.
  /// Classic bake canvases use the source reference; a live host also accounts for its safe area.
  static func documentForCanvas(_ source: Skin2Document, for kind: TouchOverlayPadKind,
                                environment: Skin2Environment) -> Skin2Document {
    var document = source
    let unit: Double
    if kind == .wiiRemoteSideways {
      unit = 1
    } else {
      let usableWidth = max(0, environment.size.width - environment.safeArea.left - environment.safeArea.right)
      var scale = min(usableWidth, environment.size.height) / source.reference.shortSide
      if environment.orientation == .landscape { scale = min(scale, usableWidth / 600) }
      unit = min(max(scale, source.reference.minScale), source.reference.maxScale)
    }
    document.reference.minScale = unit
    document.reference.maxScale = unit
    if kind != .wiiRemoteSideways {
      prepareCanvasGuides(in: &document, environment: environment, unit: unit)
    }
    return document
  }

  static func documentForRendering(_ layout: Skin2Document, unit: Double,
                                   edits: [String: Skin2Edit], opacity: Double) -> Skin2Document {
    var document = layout
    prepareControlArt(in: &document.root, unit: unit, opacity: opacity, controlKind: nil,
                      controlScale: 1, edits: edits)
    return document
  }

  /// SwiftUI propagates the configured opacity into the original control's drawing layers.
  /// Apply it to the corresponding paints, preserving the translucent overlap of the d-pad and gloss.
  private static func prepareControlArt(in node: inout Skin2Node, unit: Double, opacity: Double,
                                        controlKind inherited: Skin2ControlKind?, controlScale inheritedScale: Double,
                                        edits: [String: Skin2Edit]) {
    let kind = node.type == .control ? node.kind : inherited
    let edit = node.id.flatMap { edits[$0] }
    let uniform = edit?.scale ?? 1
    let axes = max(edit?.scaleX ?? uniform, edit?.scaleY ?? uniform)
    let requestedScale = node.type == .control ? axes : inheritedScale
    let scale = requestedScale.isFinite && requestedScale > 0 ? requestedScale : 1
    if kind != nil {
      node.fills = node.fills.map { preparePaint($0, kind: kind, unit: unit, opacity: opacity, controlScale: scale) }
      node.strokes = node.strokes.map { prepareStroke($0, unit: unit, opacity: opacity) }
      if node.type == .text { node.opacity = (node.opacity ?? 1) * opacity }
      if var font = node.font {
        font.size = physicalLength(font.size, unit: unit)
        node.font = font
      }
      if var shape = node.shape {
        shape.cornerRadius = shape.cornerRadius.map { physicalLength($0, unit: unit) }
        shape.corners = shape.corners?.map { physicalLength($0, unit: unit) }
        node.shape = shape
      }
      if node.type == .shape, var inset = node.layout?.inset {
        inset.top = inset.top.map { physicalLength($0, unit: unit) }
        inset.left = inset.left.map { physicalLength($0, unit: unit) }
        inset.bottom = inset.bottom.map { physicalLength($0, unit: unit) }
        inset.right = inset.right.map { physicalLength($0, unit: unit) }
        node.layout?.inset = inset
      }
      node.effects = node.effects.map { original in
        var effect = original
        effect.radius = effect.radius.map { physicalLength($0, unit: unit) }
        effect.spread = effect.spread.map { physicalLength($0, unit: unit) }
        effect.offset = effect.offset.map { physicalLength($0, unit: unit) }
        return effect
      }
      for key in node.states.keys {
        var state = node.states[key]!
        state.patch = state.patch.map { original in
          var patch = original
          patch.fills = patch.fills?.map { preparePaint($0, kind: kind, unit: unit, opacity: opacity, controlScale: scale) }
          patch.strokes = patch.strokes?.map { prepareStroke($0, unit: unit, opacity: opacity) }
          return patch
        }
        node.states[key] = state
      }
    }
    node.children = node.children.map { original in
      var child = original
      prepareControlArt(in: &child, unit: unit, opacity: opacity, controlKind: kind, controlScale: scale, edits: edits)
      return child
    }
  }

  private static func physicalLength(_ length: Skin2Length, unit: Double) -> Skin2Length {
    if case .pt(let value) = length { return .pt(value / unit) }
    return length
  }

  private static func preparePaint(_ original: Skin2Paint, kind: Skin2ControlKind?,
                                   unit: Double, opacity: Double, controlScale: Double) -> Skin2Paint {
    var paint = original
    paint.opacity = (paint.opacity ?? 1) * opacity
    if paint.type == .radial {
      if kind == .thumbstick {
        paint.radius = paint.radius.map { $0 / (unit * controlScale) }
      } else if kind == .dpad, !paint.stops.isEmpty {
        paint.stops[0].at /= unit * controlScale
      }
    }
    return paint
  }

  private static func prepareStroke(_ original: Skin2Stroke, unit: Double, opacity: Double) -> Skin2Stroke {
    var stroke = original
    stroke.opacity = (stroke.opacity ?? 1) * opacity
    stroke.width = physicalLength(stroke.width, unit: unit)
    stroke.dash = stroke.dash.map { physicalLength($0, unit: unit) }
    return stroke
  }

  /// The app's edge clearances and IR margin are physical points. The source lengths scale
  /// with the reference unit, so prepare those layout guides for the live canvas.
  private static func prepareCanvasGuides(in document: inout Skin2Document,
                                          environment: Skin2Environment, unit: Double) {
    let safe = environment.safeArea
    let bottom = environment.size.height - max(safe.bottom, 8) - 6
    let usableWidth = environment.size.width - safe.left - safe.right
    let regionTop = environment.orientation == .portrait
      ? safe.top + usableWidth * 3 / 4 + 8 * unit : max(safe.top, 8) + 8
    let top = max(regionTop, bottom - 420 * unit)
    for index in document.root.children.indices {
      var node = document.root.children[index]
      switch node.id {
      case "edges":
        node.layout?.inset = Skin2EdgeLengths(top: .pt(0),
                                              left: .pt((max(safe.left, 8) + 8) / unit),
                                              bottom: .pt((max(safe.bottom, 8) + 6) / unit),
                                              right: .pt((max(safe.right, 8) + 8) / unit))
      case "centerColumn":
        node.layout?.inset = Skin2EdgeLengths(top: .pt(0), left: .pt(safe.left / unit),
                                              bottom: .pt((max(safe.bottom, 8) + 6) / unit), right: .pt(safe.right / unit))
      case "wiiIRPad":
        node.layout?.inset = Skin2EdgeLengths(uniform: .pt(24 / unit))
      case "gcLeftShoulder", "gcRightShoulder":
        let height = (node.id == "gcLeftShoulder" ? 44.0 : 96.0) * unit
        let band = (node.id == "gcLeftShoulder" ? 296.0 : 346.0) * unit
        let desiredTop = max(top, bottom - band)
        let clampedTop = max(0, min(environment.size.height - height, desiredTop))
        node.layout?.offset?.y = .pt((clampedTop + height - bottom) / unit)
      default:
        break
      }
      document.root.children[index] = node
    }
  }

  /// Reuses the existing edit chrome with document-authored group frames.
  static func groups(in resolution: Skin2Resolution) -> [TouchOverlayGroupLayout] {
    TouchOverlayGroup.allCases.compactMap { group in
      guard let node = resolution.node(id: group.rawValue) else { return nil }
      guard let frame = footprint(of: node) else { return nil }
      let size = CGSize(width: frame.width, height: frame.height)
      let placement = TouchOverlayPlacement(.bottomLeading,
                                            inset: CGPoint(x: frame.midX, y: resolution.environment.size.height - frame.midY), size: size)
      let controls: [TouchOverlayControl] = group == .wiiIRPad
        ? [TouchOverlayControl(id: "wii.ir", kind: .irSurface, frame: .zero)] : []
      return TouchOverlayGroupLayout(group: group, placement: placement, controls: controls)
    }
  }

  private static func footprint(of node: Skin2ResolvedNode) -> Skin2Rect? {
    if node.node.type == .control { return node.exactFrame }
    let frames = node.children.compactMap { footprint(of: $0) }
    guard let first = frames.first else { return nil }
    return frames.dropFirst().reduce(first) { bounds, frame in
      let left = min(bounds.x, frame.x)
      let top = min(bounds.y, frame.y)
      let right = max(bounds.x + bounds.width, frame.x + frame.width)
      let bottom = max(bounds.y + bounds.height, frame.y + frame.height)
      return Skin2Rect(x: left, y: top, width: right - left, height: bottom - top)
    }
  }
}

/// Input ownership stays in SkinKit's bridge. The sink retains iCube's existing TCButtonType mapping.
final class DefaultSkin2Input: ObservableObject, Skin2InputSink {
  let padKind: TouchOverlayPadKind
  let deviceId: Int
  private let writeButton: (Int, Bool) -> Void
  private let writeAxis: (Int, Float) -> Void
  private var bridge = Skin2InputBridge()
  private var triggers: [String: Int] = [:]
  private var hapticPresses: Set<String> = []
  private var stickFeedback: [String: StickHapticTracker] = [:]
  private let playHaptic: @MainActor (TouchHapticEvent) -> Void

  @MainActor
  init(padKind: TouchOverlayPadKind, deviceId: Int,
       writeButton: ((Int, Bool) -> Void)? = nil, writeAxis: ((Int, Float) -> Void)? = nil,
       playHaptic: (@MainActor (TouchHapticEvent) -> Void)? = nil) {
    self.padKind = padKind
    self.deviceId = deviceId
    self.playHaptic = playHaptic ?? TouchOverlayHaptics.play
    self.writeButton = writeButton ?? { TCManagerInterface.setButtonStateFor($0, controller: deviceId, state: $1) }
    self.writeAxis = writeAxis ?? { TCManagerInterface.setAxisValueFor($0, controller: deviceId, value: $1) }
  }

  @MainActor
  func handle(_ event: Skin2InputEvent) {
    let id = event.control.id
    if event.control.kind == .thumbstick {
      var feedback = stickFeedback[id] ?? StickHapticTracker()
      let point = event.state.isPressed ? CGPoint(x: event.state.stick.x, y: event.state.stick.y) : nil
      if let haptic = feedback.update(axes: point) { playHaptic(haptic) }
      stickFeedback[id] = event.state.isPressed ? feedback : nil
    } else if event.control.kind != .touchSurface {
      if event.state.isPressed {
        if hapticPresses.insert(id).inserted { playHaptic(.press) }
      } else {
        hapticPresses.remove(id)
      }
    }
    if event.control.kind == .trigger,
       case .control(.axisButton(let id))? = SkinInputMap.action(for: event.control.inputs, padKind: padKind) {
      triggers[event.control.id] = event.state.isPressed ? id : nil
      let value = event.state.isPressed ? Float(event.state.pressure ?? 1) : 0
      writeAxis(id, value)
    } else {
      bridge.handle(event, sink: self)
    }
  }

  @MainActor
  func releaseAll() {
    hapticPresses.removeAll()
    stickFeedback.removeAll()
    bridge.releaseAll(sink: self)
    for id in Set(triggers.values) { writeAxis(id, 0) }
    triggers.removeAll()
  }

  func press(_ input: String) { set(input, pressed: true) }
  func release(_ input: String) { set(input, pressed: false) }

  private func set(_ input: String, pressed: Bool) {
    let directions = ["up", "down", "left", "right"]
    if let direction = directions.firstIndex(of: input.lowercased()),
       case .dpad(let base) = SkinInputMap.dpad(padKind: padKind) {
      writeButton(base + direction, pressed)
      return
    }
    guard let action = SkinInputMap.action(for: [input], padKind: padKind) else { return }
    switch action {
    case .control(.button(let id)):
      writeButton(id, pressed)
    case .control(.axisButton(let id)):
      writeAxis(id, pressed ? 1 : 0)
    case .control: break
    default:
      if pressed { SkinActionNotification.post(action) }
    }
  }

  func stick(_ input: String, x: Double, y: Double) {
    guard case .stick(let base)? = SkinInputMap.stick(prefix: input, padKind: padKind) else { return }
    for write in TouchOverlayInput.stickWrites(x: x, y: y, baseId: base) {
      writeAxis(write.id, write.value)
    }
  }

  // The host mounts the existing IR tracker over the document's touch surface to retain drag/follow
  // mode, gain, recenter and gyro behavior.
  func surface(_ input: String, point: Skin2SurfacePoint?) {}
  func action(_ name: String) {
    if let action = SkinInputMap.action(for: [name], padKind: padKind) { SkinActionNotification.post(action) }
  }
}

struct DefaultSkin2Canvas: View {
  let document: Skin2Document
  let environment: Skin2Environment
  let edits: [String: Skin2Edit]
  let inputEnabled: Bool
  @StateObject private var input: DefaultSkin2Input

  init(document: Skin2Document, environment: Skin2Environment, edits: [String: Skin2Edit],
       padKind: TouchOverlayPadKind, deviceId: Int, inputEnabled: Bool) {
    self.document = document
    self.environment = environment
    self.edits = edits
    self.inputEnabled = inputEnabled
    _input = StateObject(wrappedValue: DefaultSkin2Input(padKind: padKind, deviceId: deviceId))
  }

  var body: some View {
    Skin2SkinView(document: document, device: environment.device, displayType: environment.displayType, flags: environment.flags, edits: edits, playsHaptics: false,
                  onInput: { input.handle($0) }, onReleaseAll: { input.releaseAll() },
                  safeAreaOverride: environment.safeArea)
      .id(inputEnabled)
      .allowsHitTesting(inputEnabled)
      .onChange(of: inputEnabled) { _, enabled in if !enabled { input.releaseAll() } }
      .onDisappear { input.releaseAll() }
  }
}
#endif
