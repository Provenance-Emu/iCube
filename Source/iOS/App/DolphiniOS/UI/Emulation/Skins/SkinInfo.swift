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

// These are the values `SkinLayout`, `SkinOverlayInput` and `SkinOverlayView` work with. The app no longer
// decodes `info.json`: `SkinInfo` reads it with SkinKitCore (`DeltaSkin.Info`, `.lenient`) and projects it onto these.

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
/// Decoded by SkinKitCore with `DeltaSkin.DecodingOptions.lenient`, which carries iCube's import rules: `//` comments
/// are stripped, a bad representation, item or screen is dropped on its own, every frame is limited, item edges
/// inherit the representation's, d-pads must be complete, Manic per-item art is kept, and only the canonical game
/// type spellings are read. This type only projects the result onto the overlay's values and applies the one rule that
/// is iCube's alone: the skin must be a GameCube or Wii skin.
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

  /// Decodes an `info.json` body.
  static func decode(_ data: Data) throws -> SkinInfo {
    let info: DeltaSkin.Info
    do {
      info = try DeltaSkin.Info.decode(data, options: .lenient)
    } catch DeltaSkinInfoError.noUsableRepresentation {
      throw SkinInfoError.noUsableRepresentation
    }
    guard let gameType = SkinGameType(info.gameTypeIdentifier) else {
      throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "Unsupported game type \(info.gameTypeIdentifier)"))
    }

    var parsed: [SkinDevice: [SkinDisplayType: [TouchOverlayOrientation: SkinRepresentation]]] = [:]
    for device in SkinDevice.allCases {
      guard let kitDevice = info.representations[device.kitDevice] else { continue }
      for display in SkinDisplayType.allCases {
        let orientations = display == .standard ? kitDevice.standard : kitDevice.edgeToEdge
        for orientation in TouchOverlayOrientation.allCases {
          guard let kit = orientations?[orientation.rawValue] else { continue }
          parsed[device, default: [:]][display, default: [:]][orientation] = SkinRepresentation(kit)
        }
      }
    }
    // SkinKitCore keeps buckets this app has no use for (iPad models, split view, tvOS, ...); a skin that only has those
    // has nothing to show here.
    guard !parsed.isEmpty else { throw SkinInfoError.noUsableRepresentation }
    return SkinInfo(name: info.name, identifier: info.identifier, gameType: gameType, representations: parsed)
  }

  /// Reads `<directory>/info.json`.
  static func load(directory: URL) throws -> SkinInfo {
    try decode(Data(contentsOf: directory.appendingPathComponent(infoFileName)))
  }

  /// Removes `//` comments (whole-line or trailing) without touching `//` inside a string, such as a URL.
  static func stripComments(_ data: Data) throws -> Data {
    try DeltaSkin.stripComments(data)
  }
}

private extension SkinGameType {
  /// The only two types iCube runs; every other SkinKit game type (N64 included) is not a skin for this app.
  init?(_ kit: DeltaSkinGameType) {
    switch kit {
    case .gamecube: self = .gameCube
    case .wii: self = .wii
    default: return nil
    }
  }
}

/// Bounds for the numbers a skin's `info.json` supplies. The rules live in SkinKitCore (`DeltaSkin.DecodingOptions.limitsFrames`).
enum SkinFrameLimits {
  /// Largest magnitude any coordinate, size or edge may have.
  static let maxMagnitude = DeltaSkin.DecodingOptions.maxFrameMagnitude

  /// Whether `value` is a usable coordinate: finite and within `maxMagnitude` either way.
  static func isSane(_ value: CGFloat) -> Bool {
    value.isFinite && abs(value) <= maxMagnitude
  }

  /// A size whose sides are sane and not negative (a zero side is legal; layout skips it).
  static func isSane(_ size: CGSize) -> Bool {
    isSane(size.width) && isSane(size.height) && size.width >= 0 && size.height >= 0
  }

  /// A frame with a sane origin and a sane, non-negative size.
  static func isSane(_ rect: CGRect) -> Bool {
    isSane(rect.origin.x) && isSane(rect.origin.y) && isSane(rect.size)
  }
}

// MARK: - SkinKitCore → overlay values

private extension SkinRepresentation {
  init(_ kit: DeltaSkin.OrientationRepresentations) {
    let items = (kit.items ?? []).map(SkinItem.init)
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
  init(_ kit: DeltaSkin.ItemRepresentation) {
    let inputs: SkinItemInputs
    switch kit.inputs {
    case .single(let names):
      inputs = .buttons(names)
    case .directional(let directions):
      // `requiresCompleteDirections` only lets complete d-pads through, so the four names are always there.
      inputs = .directional(up: directions["up"] ?? "", down: directions["down"] ?? "",
                            left: directions["left"] ?? "", right: directions["right"] ?? "")
    }
    self.init(inputs: inputs, frame: kit.frame, extendedEdges: kit.extendedEdges ?? .zero, asset: kit.asset.map { SkinAsset(normal: $0.normal) },
              thumbstick: kit.thumbstick.map { SkinThumbstick(name: $0.name, width: $0.width, height: $0.height) })
  }
}
#endif
