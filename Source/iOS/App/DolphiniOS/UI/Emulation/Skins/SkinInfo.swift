// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SkinKitCore
import UIKit

/// Device buckets a Delta/Manic skin's `info.json` declares representations for.
enum SkinDevice: String, CaseIterable, Sendable {
  case iphone
  case ipad

  fileprivate var kitDevice: DeltaSkinDevice {
    switch self {
    case .iphone: return .iphone
    case .ipad: return .ipad
    }
  }
}

/// Display buckets inside a device. `standard` and `edgeToEdge` describe the same fullscreen layout
/// at slightly different insets and skins routinely ship only one of them, so a lookup tries both.
enum SkinDisplayType: String, CaseIterable, Sendable {
  case standard
  case edgeToEdge

  /// Buckets to try, in order, when resolving a skin for this display type.
  var lookupChain: [SkinDisplayType] {
    switch self {
    case .standard: return [.standard, .edgeToEdge]
    case .edgeToEdge: return [.edgeToEdge, .standard]
    }
  }
}

// MARK: - What the overlay draws and hit-tests

// These are the values `SkinLayout`, `SkinOverlayInput` and `SkinOverlayView` work with. They are no
// longer decoded from `info.json` by the app: `SkinInfo` reads the file through SkinKitCore's
// `DeltaSkin.Info` and projects it onto these.

/// A skin image reference. One shape serves a Manic per-item asset (`normal`) and a
/// representation's background (`resizable`, or a fixed `small` / `medium` / `large` raster).
struct SkinAsset: Equatable {
  let normal: String?
  let resizable: String?
  let small: String?
  let medium: String?
  let large: String?

  init(normal: String? = nil, resizable: String? = nil, small: String? = nil, medium: String? = nil, large: String? = nil) {
    self.normal = normal
    self.resizable = resizable
    self.small = small
    self.medium = medium
    self.large = large
  }
}

struct SkinScreen: Equatable {
  let outputFrame: CGRect
  let inputFrame: CGRect?

  init(outputFrame: CGRect, inputFrame: CGRect? = nil) {
    self.outputFrame = outputFrame
    self.inputFrame = inputFrame
  }
}

struct SkinThumbstick: Equatable {
  let name: String
  let width: CGFloat
  let height: CGFloat
}

/// What an item's `inputs` field names: a list of buttons that all press together, or the four
/// directions of a d-pad / thumbstick.
enum SkinItemInputs: Equatable {
  case buttons([String])
  case directional(up: String, down: String, left: String, right: String)
}

struct SkinItem: Equatable {
  let inputs: SkinItemInputs
  let frame: CGRect
  let extendedEdges: UIEdgeInsets
  let asset: SkinAsset?
  let thumbstick: SkinThumbstick?

  init(inputs: SkinItemInputs, frame: CGRect, extendedEdges: UIEdgeInsets, asset: SkinAsset? = nil, thumbstick: SkinThumbstick? = nil) {
    self.inputs = inputs
    self.frame = frame
    self.extendedEdges = extendedEdges
    self.asset = asset
    self.thumbstick = thumbstick
  }
}

struct SkinRepresentation: Equatable {
  let mappingSize: CGSize
  let items: [SkinItem]
  let screens: [SkinScreen]
  let background: SkinAsset?
  let translucent: Bool
  let extendedEdges: UIEdgeInsets
}

enum SkinInfoError: Error, Equatable {
  /// The skin declares no representation this app can decode (all absent, unsupported or malformed).
  case noUsableRepresentation
}

/// The parsed `info.json` of a Delta/Manic skin directory.
///
/// The file is decoded by SkinKitCore (`DeltaSkin.Info`). SkinKitCore's decoder is strict, reads no `//`
/// comments and has no frame limits, so `SkinInfoSanitizer` first applies iCube's import rules to the
/// raw JSON (see its documentation); what reaches SkinKitCore is already clean.
struct SkinInfo {
  private static let infoFileName = "info.json"

  let name: String
  let identifier: String
  let gameType: SkinGameType
  let representations: [SkinDevice: [SkinDisplayType: [TouchOverlayOrientation: SkinRepresentation]]]

  /// The representation for a device and orientation; `edgeToEdge` and `standard` stand in for each other.
  func representation(device: SkinDevice, orientation: TouchOverlayOrientation,
                      displayType: SkinDisplayType = .edgeToEdge) -> SkinRepresentation? {
    guard let buckets = representations[device] else { return nil }
    for display in displayType.lookupChain {
      if let representation = buckets[display]?[orientation] { return representation }
    }
    return nil
  }

  /// Decodes an `info.json` body. Authoring tools and hand-edited skins carry `//` comments, which
  /// are stripped first.
  static func decode(_ data: Data) throws -> SkinInfo {
    let sanitized = try SkinInfoSanitizer.sanitize(data)
    let info = try JSONDecoder().decode(DeltaSkin.Info.self, from: sanitized.json)
    var parsed: [SkinDevice: [SkinDisplayType: [TouchOverlayOrientation: SkinRepresentation]]] = [:]
    for device in SkinDevice.allCases {
      guard let kitDevice = info.representations[device.kitDevice] else { continue }
      for display in SkinDisplayType.allCases {
        let orientations = display == .standard ? kitDevice.standard : kitDevice.edgeToEdge
        for orientation in TouchOverlayOrientation.allCases {
          guard let kit = orientations?[orientation.rawValue] else { continue }
          let key = SkinInfoSanitizer.Key(device: device.rawValue, display: display.rawValue, orientation: orientation.rawValue)
          parsed[device, default: [:]][display, default: [:]][orientation] =
            SkinRepresentation(kit, itemAssets: sanitized.itemAssets[key] ?? [])
        }
      }
    }
    guard !parsed.isEmpty else { throw SkinInfoError.noUsableRepresentation }
    return SkinInfo(name: info.name, identifier: info.identifier, gameType: sanitized.gameType, representations: parsed)
  }

  /// Reads `<directory>/info.json`.
  static func load(directory: URL) throws -> SkinInfo {
    try decode(Data(contentsOf: directory.appendingPathComponent(infoFileName)))
  }

  /// Removes `//` comments (whole-line or trailing) without touching `//` inside a string, such as a URL.
  static func stripComments(_ data: Data) throws -> Data {
    try SkinInfoSanitizer.stripComments(data)
  }
}

// MARK: - SkinKitCore → overlay values

private extension SkinRepresentation {
  /// `itemAssets` runs parallel to `kit.items`: SkinKitCore has no per-item `asset` key (Manic's `asset.normal`).
  init(_ kit: DeltaSkin.OrientationRepresentations, itemAssets: [SkinAsset?]) {
    let items = (kit.items ?? []).enumerated().map { index, item in
      SkinItem(item, asset: itemAssets.indices.contains(index) ? itemAssets[index] : nil)
    }
    self.init(
      mappingSize: kit.mappingSize ?? .zero,
      items: items,
      screens: (kit.screens ?? []).compactMap { screen in
        screen.outputFrame.map { SkinScreen(outputFrame: $0, inputFrame: screen.inputFrame) }
      },
      background: kit.assets.map {
        SkinAsset(resizable: $0.resizable, small: $0.small, medium: $0.medium, large: $0.large)
      },
      translucent: kit.translucent ?? false,
      extendedEdges: kit.extendedEdges ?? .zero
    )
  }
}

private extension SkinItem {
  init(_ kit: DeltaSkin.ItemRepresentation, asset: SkinAsset?) {
    let inputs: SkinItemInputs
    switch kit.inputs {
    case .single(let names):
      inputs = .buttons(names)
    case .directional(let directions):
      // The sanitizer only lets complete d-pads through, so the four names are always there.
      inputs = .directional(up: directions["up"] ?? "", down: directions["down"] ?? "",
                            left: directions["left"] ?? "", right: directions["right"] ?? "")
    }
    self.init(inputs: inputs, frame: kit.frame, extendedEdges: kit.extendedEdges ?? .zero, asset: asset,
              thumbstick: kit.thumbstick.map { SkinThumbstick(name: $0.name, width: $0.width, height: $0.height) })
  }
}
#endif
