// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import SwiftUI

/// A screen the overlay is previewed on: logical size in points (portrait) plus the safe-area
/// insets the real device reports in each orientation. Shared by the DEBUG gallery and the
/// snapshot test so both show the same set.
struct TouchOverlayPreviewDevice: Identifiable, Hashable {
  let name: String
  let portraitSize: CGSize
  let portraitInsets: UIEdgeInsets
  let landscapeInsets: UIEdgeInsets
  var isPad = false

  var id: String { name }

  /// The skin device bucket this screen previews.
  var skinDevice: SkinDevice { isPad ? .ipad : .iphone }

  func size(_ orientation: TouchOverlayOrientation) -> CGSize {
    orientation == .portrait ? portraitSize : CGSize(width: portraitSize.height, height: portraitSize.width)
  }

  func insets(_ orientation: TouchOverlayOrientation) -> UIEdgeInsets {
    orientation == .portrait ? portraitInsets : landscapeInsets
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
  func hash(into hasher: inout Hasher) { hasher.combine(name) }

  static let all: [TouchOverlayPreviewDevice] = [
    TouchOverlayPreviewDevice(name: "iPhone SE", portraitSize: CGSize(width: 375, height: 667),
                              portraitInsets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0),
                              landscapeInsets: .zero),
    TouchOverlayPreviewDevice(name: "iPhone 16 Pro", portraitSize: CGSize(width: 402, height: 874),
                              portraitInsets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
                              landscapeInsets: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
    TouchOverlayPreviewDevice(name: "iPhone 16 Pro Max", portraitSize: CGSize(width: 440, height: 956),
                              portraitInsets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
                              landscapeInsets: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
    TouchOverlayPreviewDevice(name: "iPad mini", portraitSize: CGSize(width: 744, height: 1133),
                              portraitInsets: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
                              landscapeInsets: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0), isPad: true),
    TouchOverlayPreviewDevice(name: "iPad Pro 13\"", portraitSize: CGSize(width: 1032, height: 1376),
                              portraitInsets: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
                              landscapeInsets: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0), isPad: true),
  ]
}

/// One device screen with a stand-in game picture and the overlay's default layout on top, at
/// the device's real point size. Input is off; nothing is written to the core. With a `skin`, the
/// skin is drawn instead (its hit frames outlined) and the game picture sits where the skin puts it.
struct TouchOverlayPreviewScreen: View {
  let padKind: TouchOverlayPadKind
  let device: TouchOverlayPreviewDevice
  let orientation: TouchOverlayOrientation
  var skin: InstalledSkin?

  /// GameCube / Wii output is 4:3 by default.
  private static let gameAspect: CGFloat = 4.0 / 3.0

  var body: some View {
    let size = device.size(orientation)
    let insets = device.insets(orientation)
    ZStack(alignment: .topLeading) {
      Color.black
      gamePicture(in: size, insets: insets)
      overlay(insets: insets)
        .allowsHitTesting(false)
      safeAreaShading(size: size, insets: insets)
    }
    .frame(width: size.width, height: size.height)
    .clipped()
  }

  @ViewBuilder
  private func overlay(insets: UIEdgeInsets) -> some View {
    if let skin {
      SkinOverlayView(skin: skin, padKind: padKind, deviceId: 0, previewDevice: device.skinDevice, onAction: { _ in })
      if let layout = skinLayout() {
        ForEach(layout.items.indices, id: \.self) { index in
          let item = layout.items[index]
          outline(item.hitFrame, color: .yellow)
          outline(item.drawFrame, color: .cyan)
        }
      }
    } else {
      TouchOverlayView(padKind: padKind, deviceId: 0, irMode: TCWiiTouchIRMode.none.rawValue,
                       store: TouchOverlayLayoutStore(fileURL: nil), previewSafeArea: insets)
    }
  }

  private func outline(_ frame: CGRect, color: Color) -> some View {
    Rectangle()
      .stroke(color.opacity(0.7), lineWidth: 1)
      .frame(width: frame.width, height: frame.height)
      .offset(x: frame.minX, y: frame.minY)
  }

  /// The skin laid out for this device, or nil when it has no layout for it.
  private func skinLayout() -> SkinLayout? {
    guard let skin, let info = try? SkinInfo.load(directory: skin.directory),
          let representation = SkinOverlayInput.representation(info: info, isPad: device.isPad, orientation: orientation) else { return nil }
    return SkinLayout.make(representation, canvas: device.size(orientation))
  }

  /// Where EmulationScreen draws the game: aspect-fit, top-aligned under the safe area in
  /// portrait, centred in landscape.
  private func gamePicture(in size: CGSize, insets: UIEdgeInsets) -> some View {
    if let gameRect = skinLayout()?.gameRect {
      return stubPicture(width: gameRect.width, height: gameRect.height, x: gameRect.minX, y: gameRect.minY)
    }
    let available = CGSize(width: size.width - insets.left - insets.right, height: size.height - insets.top - insets.bottom)
    let width = min(available.width, available.height * Self.gameAspect)
    let height = width / Self.gameAspect
    let x = insets.left + (available.width - width) / 2
    let y = orientation == .portrait ? insets.top : insets.top + (available.height - height) / 2
    return stubPicture(width: width, height: height, x: x, y: y)
  }

  private func stubPicture(width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat) -> some View {
    LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 0.75), Color(red: 0.2, green: 0.55, blue: 0.3)],
                   startPoint: .top, endPoint: .bottom)
      .overlay(Text("game").font(.caption).foregroundStyle(.white.opacity(0.6)))
      .frame(width: width, height: height)
      .offset(x: x, y: y)
  }

  /// Red tint over the areas the system owns (notch, home indicator) so controls under them show.
  private func safeAreaShading(size: CGSize, insets: UIEdgeInsets) -> some View {
    let tint = Color.red.opacity(0.18)
    return ZStack(alignment: .topLeading) {
      tint.frame(width: size.width, height: insets.top)
      tint.frame(width: size.width, height: insets.bottom).offset(y: size.height - insets.bottom)
      tint.frame(width: insets.left, height: size.height)
      tint.frame(width: insets.right, height: size.height).offset(x: size.width - insets.right)
    }
    .allowsHitTesting(false)
  }
}

/// DEBUG gallery of every pad kind's default layout on several devices and both orientations,
/// scaled to fit. Reached from the Edit Layout screen's toolbar in DEBUG builds.
struct TouchOverlayGalleryView: View {
  @ObservedObject private var library = SkinLibrary.shared
  @State private var padKind: TouchOverlayPadKind = .gameCube
  @State private var orientation: TouchOverlayOrientation = .landscape

  var body: some View {
    VStack(spacing: 0) {
      Picker("Layout", selection: $padKind) {
        Text("GC").tag(TouchOverlayPadKind.gameCube)
        Text("Wii").tag(TouchOverlayPadKind.wiiRemote)
        Text("Sideways").tag(TouchOverlayPadKind.wiiRemoteSideways)
        Text("Classic").tag(TouchOverlayPadKind.wiiClassic)
      }
      .pickerStyle(.segmented)
      .padding([.horizontal, .top])
      Picker("Orientation", selection: $orientation) {
        Text("Landscape").tag(TouchOverlayOrientation.landscape)
        Text("Portrait").tag(TouchOverlayOrientation.portrait)
      }
      .pickerStyle(.segmented)
      .padding()

      GeometryReader { geo in
        ScrollView {
          LazyVStack(spacing: 24) {
            ForEach(TouchOverlayPreviewDevice.all) { device in
              previewCell(device: device, skin: nil, width: geo.size.width)
            }
            Text("Skins").font(.headline)
            let skins = library.skins.filter { $0.gameType.padKinds.contains(padKind) }
            if skins.isEmpty {
              Text("No installed skins for this pad").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(skins) { skin in
              ForEach(TouchOverlayPreviewDevice.all) { device in
                previewCell(device: device, skin: skin, width: geo.size.width)
              }
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 24)
        }
      }
    }
    .navigationTitle("Layout Gallery")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func previewCell(device: TouchOverlayPreviewDevice, skin: InstalledSkin?, width: CGFloat) -> some View {
    let size = device.size(orientation)
    let scale = min(1, (width - 32) / size.width)
    return VStack(alignment: .leading, spacing: 6) {
      Text("\(skin?.name ?? "Default") · \(device.name) — \(Int(size.width))×\(Int(size.height)) pt")
        .font(.caption.monospaced())
      TouchOverlayPreviewScreen(padKind: padKind, device: device, orientation: orientation, skin: skin)
        .id("\(padKind)-\(skin?.id ?? "default")-\(device.name)-\(orientation)")
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }
}
#endif
