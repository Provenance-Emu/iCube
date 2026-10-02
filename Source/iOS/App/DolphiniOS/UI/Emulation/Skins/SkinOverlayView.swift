// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI
import UIKit

/// Draws an imported Delta/Manic skin over the game and turns touches on it into controller input,
/// through the same `TCManagerInterface` writes the Swift-drawn overlay makes. The geometry and the
/// touch-to-write logic live in `SkinOverlayInput`; this view is glue.
///
/// Swapping the skin or pad kind rebuilds the content, so a new skin never draws with the old `info.json`.
struct SkinOverlayView: View {
  let skin: InstalledSkin
  let padKind: TouchOverlayPadKind
  /// The Touchscreen device id, never the player slot (the same rule as `TouchOverlayView`).
  let deviceId: Int
  /// The Wii IR pointer mode (`TCWiiTouchIRMode` raw value); only a Wii Remote skin uses it.
  let irMode: Int
  /// Set only by the DEBUG gallery: the device bucket being previewed. A preview ignores the live safe area.
  let previewDevice: SkinDevice?
  let onAction: (SkinAction) -> Void

  init(skin: InstalledSkin, padKind: TouchOverlayPadKind, deviceId: Int, irMode: Int = TCWiiTouchIRMode.none.rawValue,
       previewDevice: SkinDevice? = nil, onAction: @escaping (SkinAction) -> Void) {
    self.skin = skin
    self.padKind = padKind
    self.deviceId = deviceId
    self.irMode = irMode
    self.previewDevice = previewDevice
    self.onAction = onAction
  }

  var body: some View {
    SkinOverlayContent(skin: skin, padKind: padKind, deviceId: deviceId, irMode: irMode, previewDevice: previewDevice, onAction: onAction)
      .id(ContentIdentity(skinID: skin.id, directory: skin.directory, padKind: padKind))
  }
}

private struct ContentIdentity: Hashable {
  let skinID: String
  let directory: URL
  let padKind: TouchOverlayPadKind
}

private struct SkinOverlayContent: View {
  let skin: InstalledSkin
  let padKind: TouchOverlayPadKind
  let deviceId: Int
  let irMode: Int
  let previewDevice: SkinDevice?
  let onAction: (SkinAction) -> Void

  @StateObject private var infoBox: SkinInfoBox
  @Environment(\.displayScale) private var displayScale

  init(skin: InstalledSkin, padKind: TouchOverlayPadKind, deviceId: Int, irMode: Int, previewDevice: SkinDevice?,
       onAction: @escaping (SkinAction) -> Void) {
    self.skin = skin
    self.padKind = padKind
    self.deviceId = deviceId
    self.irMode = irMode
    self.previewDevice = previewDevice
    self.onAction = onAction
    _infoBox = StateObject(wrappedValue: SkinInfoBox(directory: skin.directory))
  }

  var body: some View {
    GeometryReader { geo in
      // Like `TouchOverlayView`: lay out edge to edge, under the safe area.
      let insets = previewDevice == nil ? geo.safeAreaInsets : EdgeInsets()
      let canvas = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                          height: geo.size.height + insets.top + insets.bottom)
      let orientation = TouchOverlayOrientation(isPortrait: canvas.height >= canvas.width)
      if let info = infoBox.info,
         let representation = SkinOverlayInput.representation(info: info, isPad: isPad, orientation: orientation) {
        let layout = SkinLayout.make(representation, canvas: canvas)
        let opacity = representation.translucent
          ? TouchOverlayInput.resolvedOpacity(isEditing: false, configuredOpacity: DOLConfigBridge.mainTouchPadOpacity())
          : 1.0
        let input = SkinOverlayInput(layout: layout, padKind: padKind)
        ZStack(alignment: .topLeading) {
          SkinArtLayer(representation: representation, layout: layout, directory: skin.directory,
                       displayScale: displayScale, controlOpacity: opacity)
            .allowsHitTesting(false)
          SkinTouchLayer(input: input, directory: skin.directory, deviceId: deviceId, displayScale: displayScale,
                         controlOpacity: opacity, onAction: onAction)
            // A new layout (rotation, resize) starts with nothing pressed; the old layer releases what it held.
            .id(LayoutIdentity(canvas: canvas, orientation: orientation, skinID: skin.id, padKind: padKind))
          // Only a real game has a pointer: a preview (the gallery, the picker's thumbnails) never mounts it, nor does a
          // pointer mode of "none" (the gyro pointer drives the axes itself).
          if previewDevice == nil, pointerMode != .none, let pointer = input.pointerSurface() {
            SkinPointerLayer(surface: pointer, deviceId: deviceId, mode: pointerMode)
              .id(LayoutIdentity(canvas: canvas, orientation: orientation, skinID: skin.id, padKind: padKind))
          }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .offset(x: -insets.leading, y: -insets.top)
      }
    }
  }

  private var pointerMode: TCWiiTouchIRMode { TCWiiTouchIRMode(rawValue: irMode) ?? .none }

  private var isPad: Bool {
    switch previewDevice {
    case .ipad?: return true
    case .iphone?: return false
    case nil: return UIDevice.current.userInterfaceIdiom == .pad
    }
  }
}

private struct LayoutIdentity: Hashable {
  let canvas: CGSize
  let orientation: TouchOverlayOrientation
  let skinID: String
  let padKind: TouchOverlayPadKind
}

/// Holds a skin's parsed `info.json` for the life of the view, so layout passes do not re-read the file.
private final class SkinInfoBox: ObservableObject {
  let info: SkinInfo?

  init(directory: URL) {
    info = try? SkinInfo.load(directory: directory)
  }
}

private extension SkinAsset {
  /// A representation's background: the resizable PDF, else the largest raster the skin ships.
  var backgroundName: String? {
    [resizable, large, medium, small].lazy.compactMap { $0 }.first { !$0.isEmpty }
  }
}

/// The skin's pictures (a translucent skin fades as a whole): background, then each item's art (sticks' bases included, their knobs are drawn by
/// `SkinStickView`). Holds no touch state, so presses never redraw it.
private struct SkinArtLayer: View {
  let representation: SkinRepresentation
  let layout: SkinLayout
  let directory: URL
  let displayScale: CGFloat
  let controlOpacity: Double

  var body: some View {
    ZStack(alignment: .topLeading) {
      if let name = representation.background?.backgroundName,
         let image = SkinAssetRenderer.image(named: name, in: directory, size: layout.skinRect.size, scale: displayScale) {
        Image(uiImage: image)
          .resizable()
          .frame(width: layout.skinRect.width, height: layout.skinRect.height)
          .position(x: layout.skinRect.midX, y: layout.skinRect.midY)
          .opacity(controlOpacity)
      }
      ForEach(layout.items.indices, id: \.self) { index in
        let entry = layout.items[index]
        if let name = entry.item.asset?.normal,
           let image = SkinAssetRenderer.image(named: name, in: directory, size: entry.drawFrame.size, scale: displayScale) {
          Image(uiImage: image)
            .resizable()
            .frame(width: entry.drawFrame.width, height: entry.drawFrame.height)
            .position(x: entry.drawFrame.midX, y: entry.drawFrame.midY)
            .opacity(controlOpacity)
        }
      }
    }
  }
}

/// The live part: one multi-touch surface over the whole skin for buttons and the d-pad, with a
/// single-touch surface on top of each thumbstick.
private struct SkinTouchLayer: View {
  let input: SkinOverlayInput
  let directory: URL
  let deviceId: Int
  let displayScale: CGFloat
  let controlOpacity: Double
  let onAction: (SkinAction) -> Void

  @State private var pressed: Set<SkinOverlayInput.Hit> = []
  /// The hits last applied (for press edges), and the pad ids actually held down (so any teardown or
  /// layout change releases exactly those).
  @State private var applied: Set<SkinOverlayInput.Hit> = []
  @State private var held: Set<SkinOverlayInput.Key> = []
  private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)

  var body: some View {
    ZStack(alignment: .topLeading) {
      TouchOverlayCluster<SkinOverlayInput.Hit>(
        hitTest: { location, _ in input.hits(at: location, previous: pressed) },
        onChange: { _, _ in
          // Transitions are applied together in `apply`, once per touch event, so an id shared by two
          // items is never released while the other still holds it.
        },
        pressed: $pressed,
        onBegan: { locations in
          // App actions (menu, quick save/load) fire on touch-down only; a finger sliding onto them does nothing.
          for location in locations {
            guard let item = input.actionItem(at: location) else { continue }
            for action in input.actions(ofItem: item) { onAction(action) }
          }
        }
      )
      ForEach(input.sticks, id: \.itemIndex) { stick in
        SkinStickView(stick: stick, directory: directory, deviceId: deviceId,
                      displayScale: displayScale, controlOpacity: controlOpacity)
      }
    }
    .onChange(of: pressed) { _, now in apply(now) }
    .onDisappear { apply([]) }
  }

  private func apply(_ now: Set<SkinOverlayInput.Hit>) {
    let previous = applied
    guard now != previous else { return }
    applied = now
    let keys = input.keys(of: now)
    let writes = SkinOverlayInput.writes(from: held, to: keys)
    held = keys
    for write in writes {
      switch write.channel {
      case .button: TCManagerInterface.setButtonStateFor(write.id, controller: deviceId, state: write.pressed)
      case .axis: TCManagerInterface.setAxisValueFor(write.id, controller: deviceId, value: write.axisValue)
      }
    }
    // Like `TouchOverlayDPadView`: once per press, not on every direction or button change while held.
    if previous.isEmpty, !now.isEmpty { hapticGenerator.impactOccurred() }
  }
}

/// The Wii Remote's touch pointer over a skin's game screen: the Swift-drawn overlay's own IR surface, with the skin's
/// items cut out so a touch that starts on one reaches the item. It sits above the button surface (which covers the whole
/// skin) and below the sticks.
private struct SkinPointerLayer: View {
  let surface: SkinOverlayInput.PointerSurface
  let deviceId: Int
  let mode: TCWiiTouchIRMode

  var body: some View {
    TouchOverlayIRPadView(mode: mode, deviceId: deviceId,
                          excludedFrames: surface.excludedFrames, isEditing: false,
                          dragGain: TouchOverlayIRGeometry.clampDragGain(MotionSettings.irPointerGain()),
                          passesThroughExcludedFrames: true)
      .frame(width: surface.frame.width, height: surface.frame.height)
      .position(x: surface.frame.midX, y: surface.frame.midY)
  }
}

/// A thumbstick: the knob follows the finger inside the item and the four half-axes are written
/// with `TouchOverlayInput.stickWrites`, exactly like the xib stick.
private struct SkinStickView: View {
  let stick: SkinOverlayInput.Stick
  let directory: URL
  let deviceId: Int
  let displayScale: CGFloat
  let controlOpacity: Double

  @State private var knobOffset: CGSize = .zero

  var body: some View {
    ZStack(alignment: .topLeading) {
      if let name = stick.knobName, let size = stick.thumbSize,
         let image = SkinAssetRenderer.image(named: name, in: directory, size: size, scale: displayScale) {
        Image(uiImage: image)
          .resizable()
          .frame(width: size.width, height: size.height)
          .position(x: stick.center.x + knobOffset.width, y: stick.center.y + knobOffset.height)
          .opacity(controlOpacity)
          .allowsHitTesting(false)
      }
      TouchOverlaySingleTouch { location in
        knobOffset = stick.knobOffset(touch: location)
        for write in stick.writes(touch: location) {
          TCManagerInterface.setAxisValueFor(write.id, controller: deviceId, value: write.value)
        }
      }
    }
    .frame(width: stick.hitFrame.width, height: stick.hitFrame.height, alignment: .topLeading)
    .position(x: stick.hitFrame.midX, y: stick.hitFrame.midY)
  }
}
#endif
