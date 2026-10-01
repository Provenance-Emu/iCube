// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import UIKit

/// Device buckets a Delta/Manic skin's `info.json` declares representations for.
enum SkinDevice: String, CaseIterable, Sendable {
  case iphone
  case ipad
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

/// A skin image reference. One shape serves a Manic per-item asset (`normal`) and a
/// representation's background (`resizable`, or a fixed `small` / `medium` / `large` raster).
struct SkinAsset: Decodable, Equatable {
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

struct SkinThumbstick: Decodable, Equatable {
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

/// The parsed `info.json` of a Delta/Manic skin directory.
struct SkinInfo: Decodable {
  private static let infoFileName = "info.json"
  private static let commentMarker = "//"

  let name: String
  let identifier: String
  let gameType: SkinGameType
  let representations: [SkinDevice: [SkinDisplayType: [TouchOverlayOrientation: SkinRepresentation]]]

  private enum CodingKeys: String, CodingKey {
    case name, identifier, gameTypeIdentifier, representations
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    identifier = try container.decode(String.self, forKey: .identifier)
    let gameTypeIdentifier = try container.decode(String.self, forKey: .gameTypeIdentifier)
    guard let gameType = SkinGameType(identifier: gameTypeIdentifier) else {
      throw DecodingError.dataCorruptedError(forKey: .gameTypeIdentifier, in: container,
                                             debugDescription: "Unsupported game type \(gameTypeIdentifier)")
    }
    self.gameType = gameType

    // Buckets this app has no use for (iPad models, split view, external display, ...) are skipped.
    let devices = try container.nestedContainer(keyedBy: SkinDynamicKey.self, forKey: .representations)
    var parsed: [SkinDevice: [SkinDisplayType: [TouchOverlayOrientation: SkinRepresentation]]] = [:]
    for deviceKey in devices.allKeys {
      guard let device = SkinDevice(rawValue: deviceKey.stringValue) else { continue }
      let displays = try devices.nestedContainer(keyedBy: SkinDynamicKey.self, forKey: deviceKey)
      for displayKey in displays.allKeys {
        guard let display = SkinDisplayType(rawValue: displayKey.stringValue) else { continue }
        let orientations = try displays.nestedContainer(keyedBy: SkinDynamicKey.self, forKey: displayKey)
        for orientationKey in orientations.allKeys {
          guard let orientation = TouchOverlayOrientation(rawValue: orientationKey.stringValue) else { continue }
          parsed[device, default: [:]][display, default: [:]][orientation] =
            try orientations.decode(SkinRepresentation.self, forKey: orientationKey)
        }
      }
    }
    representations = parsed
  }

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
    try JSONDecoder().decode(SkinInfo.self, from: stripComments(data))
  }

  /// Reads `<directory>/info.json`.
  static func load(directory: URL) throws -> SkinInfo {
    try decode(Data(contentsOf: directory.appendingPathComponent(infoFileName)))
  }

  /// Removes `//` comments (whole-line or trailing) without touching `//` inside a string, such as a URL.
  private static func stripComments(_ data: Data) throws -> Data {
    guard let text = String(data: data, encoding: .utf8) else {
      throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "info.json is not UTF-8"))
    }
    let stripped = text.components(separatedBy: .newlines).map { line -> String in
      var inString = false
      var escaped = false
      var previous: Character?
      for index in line.indices {
        let character = line[index]
        if inString {
          if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
        } else if character == "\"" {
          inString = true
        } else if character == "/", previous == "/" {
          return String(line[..<line.index(before: index)])
        }
        previous = character
      }
      return line
    }
    return Data(stripped.joined(separator: "\n").utf8)
  }
}

// MARK: - Representation decoding

extension SkinRepresentation: Decodable {
  private enum CodingKeys: String, CodingKey {
    case assets, items, screens, mappingSize, extendedEdges, translucent
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mappingSize = try container.decode(SkinSize.self, forKey: .mappingSize).value
    extendedEdges = try container.decodeIfPresent(SkinEdges.self, forKey: .extendedEdges)?.resolved(over: .zero) ?? .zero
    translucent = try container.decodeIfPresent(Bool.self, forKey: .translucent) ?? false
    background = try container.decodeIfPresent(SkinAsset.self, forKey: .assets)
    screens = try container.decodeIfPresent([SkinScreenRecord].self, forKey: .screens)?.compactMap(\.screen) ?? []
    let inherited = extendedEdges
    items = try container.decodeIfPresent([SkinItemRecord].self, forKey: .items)?.map { $0.item(inheriting: inherited) } ?? []
  }
}

/// Wire shape of one screen. A screen without an `outputFrame` (placement-only) is dropped.
private struct SkinScreenRecord: Decodable {
  let outputFrame: SkinRect?
  let inputFrame: SkinRect?

  var screen: SkinScreen? {
    outputFrame.map { SkinScreen(outputFrame: $0.value, inputFrame: inputFrame?.value) }
  }
}

/// Wire shape of one item, before its edges resolve against the representation's.
private struct SkinItemRecord: Decodable {
  let inputs: SkinItemInputs
  let frame: SkinRect
  let extendedEdges: SkinEdges?
  let asset: SkinAsset?
  let thumbstick: SkinThumbstick?

  func item(inheriting base: UIEdgeInsets) -> SkinItem {
    SkinItem(inputs: inputs, frame: frame.value, extendedEdges: extendedEdges?.resolved(over: base) ?? base,
             asset: asset, thumbstick: thumbstick)
  }
}

extension SkinItemInputs: Decodable {
  private enum Direction: String, CodingKey {
    case up, down, left, right
  }

  init(from decoder: Decoder) throws {
    if let names = try? decoder.singleValueContainer().decode([String].self) {
      self = .buttons(names)
      return
    }
    let container = try decoder.container(keyedBy: Direction.self)
    self = .directional(up: try container.decode(String.self, forKey: .up),
                        down: try container.decode(String.self, forKey: .down),
                        left: try container.decode(String.self, forKey: .left),
                        right: try container.decode(String.self, forKey: .right))
  }
}

// MARK: - Geometry wire types

private struct SkinDynamicKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

private struct SkinSize: Decodable {
  let value: CGSize

  private enum CodingKeys: String, CodingKey { case width, height }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    value = CGSize(width: try container.decode(CGFloat.self, forKey: .width), height: try container.decode(CGFloat.self, forKey: .height))
  }
}

/// A frame as the `{x, y, width, height}` dictionary, or the `[x, y, width, height]` array some skins use.
private struct SkinRect: Decodable {
  private static let componentCount = 4
  let value: CGRect

  private enum CodingKeys: String, CodingKey { case x, y, width, height }

  init(from decoder: Decoder) throws {
    if let values = try? decoder.singleValueContainer().decode([CGFloat].self) {
      guard values.count == Self.componentCount else {
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                debugDescription: "Expected 4 values for a frame"))
      }
      value = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    value = CGRect(x: try container.decode(CGFloat.self, forKey: .x), y: try container.decode(CGFloat.self, forKey: .y),
                   width: try container.decode(CGFloat.self, forKey: .width), height: try container.decode(CGFloat.self, forKey: .height))
  }
}

/// Edge insets where any side may be absent; an absent side inherits from the enclosing value.
private struct SkinEdges: Decodable {
  let top: CGFloat?
  let left: CGFloat?
  let bottom: CGFloat?
  let right: CGFloat?

  func resolved(over base: UIEdgeInsets) -> UIEdgeInsets {
    UIEdgeInsets(top: top ?? base.top, left: left ?? base.left, bottom: bottom ?? base.bottom, right: right ?? base.right)
  }
}
#endif
