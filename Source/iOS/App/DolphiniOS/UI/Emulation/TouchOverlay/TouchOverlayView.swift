// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SkinKit2Core
import SwiftUI
import UIKit

/// Renders the bundled Format 2 pad and hosts the native layout editor and Wii IR surface.
struct TouchOverlayView: View {
  let padKind: TouchOverlayPadKind
  /// The Touchscreen device id (`ControllerManager.shared.touchscreenControllerId(isWii:)`) —
  /// NEVER the player slot (design §6.3). Named explicitly, not `port`, per the design's own
  /// call-out of that exact mix-up as a historical bug source.
  let deviceId: Int
  /// `TCWiiTouchIRMode`'s raw value (`DOLConfigBridge.mainTouchPadIRMode()`, threaded down from
  /// `TouchPadsContainer.irMode`). Only meaningful for the Wii Remote pad kind's `wiiIRPad` group.
  let irMode: Int

  /// The space the editor's drags are measured in (`PositionedTouchGroup`): the whole overlay, which
  /// does not move while a group does.
  static let coordinateSpace = NamedCoordinateSpace.named("TouchOverlayView")

  @ObservedObject private var store: TouchOverlayLayoutStore
  @State private var previewFrames: [String: CGRect] = [:]
  @State private var editMode: TouchOverlayEditMode
  /// Set only by the DEBUG layout gallery: the safe area of the device being simulated. Live
  /// overlays read the real one from the window.
  private let previewSafeArea: UIEdgeInsets?
  /// What Done does in a host that exists only to edit (`TouchOverlayLayoutEditorView`): it closes
  /// that host. nil returns the overlay to play in place.
  private let onDone: (() -> Void)?
  /// Drawn at the start of the edit toolbar (the editor's pad picker).
  private let toolbarAccessory: AnyView?
  /// Used by the snapshot comparator while the original drawing remains a test oracle.
  private let previewIsPad: Bool?

  /// - Parameter initialEditMode: opens straight into an edit mode, for
  ///   `TouchOverlayLayoutEditorView` ("Edit Layout…" / "Edit IR Area…") — it has no live
  ///   device context, so every group's input is suppressed from the first frame
  ///   (`TouchOverlayEditMode.inputSuppressed`), and no `TCManagerInterface` write can happen
  ///   regardless of the placeholder `deviceId` it passes. It also passes
  ///   `irMode: .gyro` so the IR pad's `mode`/`isEditingFlag` transition on mount
  ///   can't send a stray "recenter" write either (see `TouchOverlayIRPadView`'s doc comment).
  /// - Parameter store: the gallery passes an empty in-memory store so it always shows defaults.
  init(padKind: TouchOverlayPadKind, deviceId: Int, irMode: Int, initialEditMode: TouchOverlayEditMode = .none,
       store: TouchOverlayLayoutStore = .shared, previewSafeArea: UIEdgeInsets? = nil,
       onDone: (() -> Void)? = nil, toolbarAccessory: AnyView? = nil, previewIsPad: Bool? = nil) {
    self.padKind = padKind
    self.deviceId = deviceId
    self.irMode = irMode
    _editMode = State(initialValue: initialEditMode)
    _store = ObservedObject(wrappedValue: store)
    self.previewSafeArea = previewSafeArea
    self.onDone = onDone
    self.toolbarAccessory = toolbarAccessory
    self.previewIsPad = previewIsPad
  }

  var body: some View {
    GeometryReader { geo in
      let geometry = TouchOverlayCanvas(hostSize: geo.size, hostInsets: UIEdgeInsets(geo.safeAreaInsets),
                                        previewSafeArea: previewSafeArea)
      if let source = try? DefaultSkin2Pad.document(for: padKind) {
        let flags: Set<String> = DOLConfigBridge.mainSlotBMicrophone() ? ["microphone"] : []
        let environment = DefaultSkin2Pad.environment(canvas: geometry.size, safeArea: geometry.safeArea, flags: flags, isPad: previewIsPad)
        let opacity = TouchOverlayInput.resolvedOpacity(isEditing: editMode != .none,
                                                        configuredOpacity: DOLConfigBridge.mainTouchPadOpacity())
        let document = DefaultSkin2Pad.documentForCanvas(source, for: padKind, environment: environment)
        let resolution = Skin2Resolver.resolve(document, in: environment)
        let layouts = DefaultSkin2Pad.groups(in: resolution)
        let _ = store.revision
        let edits = store.format2Edits(padKind: padKind, orientation: geometry.orientation,
                                      resolution: resolution, bounds: geometry.bounds, previews: previewFrames)
        let renderingDocument = DefaultSkin2Pad.documentForRendering(document, unit: resolution.unit,
                                                                     edits: edits, opacity: opacity)

        let foreground = layouts.filter { !Self.isIRSurfaceLayout($0) }
        let exclusions = foreground.map {
          store.resolvedBox(for: $0, padKind: padKind, orientation: geometry.orientation, in: geometry.bounds)
        }
        ZStack {
          Color.clear.contentShape(Rectangle()).onLongPressGesture(minimumDuration: 0.5) {
            guard editMode == .none else { return }
            NotificationCenter.default.post(name: .DOLEditTouchLayout, object: nil)
          }
          DefaultSkin2Canvas(document: renderingDocument, environment: environment, edits: edits,
                             padKind: padKind, deviceId: deviceId, inputEnabled: !editMode.inputSuppressed)
            .id("\(padKind.rawValue).\(deviceId)")
          // Keep the IR mode/gain/recenter tracker, using the document's migrated surface rectangle.
          ForEach(layouts.filter(Self.isIRSurfaceLayout), id: \.group) { layout in
            groupView(layout: layout, bounds: geometry.bounds, orientation: geometry.orientation, opacity: opacity,
                      excludedFrames: exclusions)
          }
          if editMode != .none {
            safeAreaGuide(bounds: geometry.bounds, safeArea: geometry.safeArea)
            ForEach(foreground, id: \.group) { layout in
              groupView(layout: layout, bounds: geometry.bounds, orientation: geometry.orientation, opacity: opacity,
                        excludedFrames: [])
            }
            editToolbar(safeArea: geometry.safeArea)
          }
        }
        .coordinateSpace(Self.coordinateSpace)
        .onChange(of: padKind) { _, _ in previewFrames.removeAll() }
        .onChange(of: editMode.inputSuppressed) { _, suppressed in
          if !suppressed { previewFrames.removeAll() }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .offset(x: -geometry.hostOrigin.x, y: -geometry.hostOrigin.y)
      } else {
        ContentUnavailableView("Controls unavailable", systemImage: "gamecontroller")
      }
    }
  }

  private static func isIRSurfaceLayout(_ layout: TouchOverlayGroupLayout) -> Bool {
    layout.controls.contains { if case .irSurface = $0.kind { return true }; return false }
  }

  // MARK: Per-group dispatch

  @ViewBuilder
  private func groupView(layout: TouchOverlayGroupLayout, bounds: CGRect, orientation: TouchOverlayOrientation,
                         opacity: Double, excludedFrames: [CGRect]) -> some View {
    let inputSuppressed = editMode.inputSuppressed
    let showsChrome = editMode.showsChrome(for: layout.group)
    let isIRPad = layout.group == .wiiIRPad
    let scale = store.sizeScale(for: layout.group, padKind: padKind, orientation: orientation)
    let box = store.resolvedBox(for: layout, padKind: padKind, orientation: orientation, in: bounds)
    PositionedTouchGroup(
      group: layout.group, box: box, bounds: bounds, inputSuppressed: inputSuppressed, showsChrome: showsChrome,
      onCommit: { resolved in
        store.setCenter(resolved, in: bounds, for: layout.group, padKind: padKind, orientation: orientation)
      },
      // `.layout` mode resizes every group (including `wiiIRPad`) UNIFORMLY, exactly as before
      // task item 1 — that's the "drag the corner handle" experience already shipped and
      // persisted, unaffected by the new independent-axis editor below.
      resize: editMode == .layout ? (scale: scale, onCommit: { newScale in
        store.setSizeScale(newScale, for: layout.group, padKind: padKind, orientation: orientation, in: bounds)
      }) : nil,
      // `.irArea` mode is ONLY ever entered for the Wii Remote pad kind's `wiiIRPad` group
      // (Edit IR Area… opens the editor with `padKind: .wiiRemote`), so this is the sole
      // group that ever gets `resizeAxes` — task item 1's independent width/height editor.
      resizeAxes: (editMode == .irArea && isIRPad) ? (scale: store.sizeScaleXY(for: layout.group, padKind: padKind, orientation: orientation), onCommit: { newScaleXY in
        store.setIRSizeScale(newScaleXY, for: layout.group, padKind: padKind, orientation: orientation,
                             bounds: bounds, baseSize: layout.placement.resolvedSize(in: bounds))
      }) : nil,
      onPreview: { previewFrames[layout.group.rawValue] = $0 },
      content: {
        content(for: layout, inputSuppressed: inputSuppressed, box: box, excludedFrames: excludedFrames)
          .opacity(opacity)
      }
    )
  }

  @ViewBuilder
  private func content(for layout: TouchOverlayGroupLayout, inputSuppressed: Bool,
                       box: CGRect, excludedFrames: [CGRect]) -> some View {
    if layout.group == .wiiIRPad {
      let localExcluded = excludedFrames.map { $0.offsetBy(dx: -box.minX, dy: -box.minY) }
      ZStack {
        if inputSuppressed {
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
              .stroke(Color(red: 0.32, green: 0.62, blue: 1).opacity(0.35), lineWidth: 1.5))
        }
        TouchOverlayIRPadView(mode: TCWiiTouchIRMode(rawValue: irMode) ?? .gyro, deviceId: deviceId,
                              excludedFrames: localExcluded, isEditing: inputSuppressed,
                              dragGain: TouchOverlayIRGeometry.clampDragGain(MotionSettings.irPointerGain()))
      }
    } else {
      Color.clear
    }
  }

  // MARK: Edit chrome

  /// The safe area's edges, drawn faintly while editing. Every editor clamps groups to the whole
  /// canvas (the defaults stay inside the safe area on their own), so this shows where the rounded
  /// corners and the sensor housing begin, and that a group stopping past it is at the screen edge.
  private func safeAreaGuide(bounds: CGRect, safeArea: UIEdgeInsets) -> some View {
    let safe = bounds.inset(by: safeArea)
    return Rectangle()
      .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
      .frame(width: safe.width, height: safe.height)
      .position(x: safe.midX, y: safe.midY)
      .allowsHitTesting(false)
  }

  /// Top centre, inside the safe area: clear of the top corners, where the shoulder buttons sit, and of
  /// the bottom edge every default hangs from. It used to sit top right, which in landscape (no top
  /// inset) was under the game screen's 80 pt reveal strip, so Done revealed the top bar instead. The
  /// editor now covers that strip and the bar, and this keeps it clear of the controls too.
  private func editToolbar(safeArea: UIEdgeInsets) -> some View {
    VStack {
      HStack {
        Spacer()
        HStack(spacing: 8) {
          if let toolbarAccessory {
            toolbarAccessory
          }
          Button {
            // The IR area editor's Reset only clears `wiiIRPad` (task item 1) — resetting the
            // WHOLE pad kind here would also silently discard the user's face-button/D-pad/stick
            // layout, which they weren't editing in this mode.
            switch editMode {
            case .irArea: store.resetGroup(.wiiIRPad, padKind: padKind)
            case .layout, .none: store.reset(padKind: padKind)
            }
          } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
          }
          .buttonStyle(.bordered)

          Button {
            if let onDone {
              onDone()
            } else {
              editMode = .none
            }
          } label: {
            Label("Done", systemImage: "checkmark")
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding()
        Spacer()
      }
      Spacer()
    }
    .padding(EdgeInsets(top: safeArea.top, leading: safeArea.left, bottom: safeArea.bottom, trailing: safeArea.right))
  }
}
#endif

#if os(iOS)
/// The rectangle the overlay lays out on, from what its `GeometryReader` reports. Every host lays the
/// overlay out inside the safe area (the game's `TouchPadsContainer`, the full-screen layout editor)
/// and the canvas adds the insets back, so it is the whole screen in each of them; the DEBUG gallery
/// hosts edge to edge and passes the simulated device's insets instead. Positions are stored as
/// fractions of `bounds` and sizes scale with it, so the hosts must agree on it: the layout editor
/// used to sit under a navigation bar and a picker, and everything placed there moved in the game.
struct TouchOverlayCanvas: Equatable {
  let size: CGSize
  let safeArea: UIEdgeInsets
  /// Where the host's origin sits on the canvas: the leading and top insets it was laid out inside.
  let hostOrigin: CGPoint

  init(hostSize: CGSize, hostInsets: UIEdgeInsets, previewSafeArea: UIEdgeInsets? = nil) {
    let live = previewSafeArea == nil ? hostInsets : .zero
    size = CGSize(width: hostSize.width + live.left + live.right, height: hostSize.height + live.top + live.bottom)
    safeArea = previewSafeArea ?? live
    hostOrigin = CGPoint(x: live.left, y: live.top)
  }

  var bounds: CGRect { CGRect(origin: .zero, size: size) }
  var orientation: TouchOverlayOrientation { TouchOverlayOrientation(isPortrait: size.height >= size.width) }
}

private extension UIEdgeInsets {
  init(_ insets: EdgeInsets) {
    self.init(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
  }
}
#endif
