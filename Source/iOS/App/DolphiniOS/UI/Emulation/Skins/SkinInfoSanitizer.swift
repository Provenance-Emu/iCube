// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation

/// Bounds for the numbers a skin's `info.json` supplies. A skin comes from anywhere, and JSON still allows values
/// like `1e308` that are finite but would overflow every layout calculation downstream.
enum SkinFrameLimits {
  /// Largest magnitude any coordinate, size or edge may have (mapping points; real skins use a few thousand).
  static let maxMagnitude: CGFloat = 100_000

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

/// Applies iCube's import rules to a raw `info.json` and returns JSON in the shape SkinKitCore's `DeltaSkin.Info`
/// decodes.
///
/// SkinKitCore is the model; this is the part of iCube's old decoder that SkinKitCore does not do, kept app-side so no
/// other app's behavior changes. What it preserves, one rule per behavior:
///
/// - **Comments.** `//` comments (whole-line or trailing) are stripped before parsing, string-aware, so a URL in a string
///   survives. `DeltaSkin(fileURL:)` parses first and rejects a commented file.
/// - **Lossy decoding.** A representation, item or screen that fails is dropped on its own; the skin is rejected only
///   when nothing usable is left (`SkinInfoError.noUsableRepresentation`). SkinKitCore throws on the first defect.
/// - **Frame sanity.** Every coordinate, size and edge goes through `SkinFrameLimits`; `mappingSize` must also be
///   positive. SkinKitCore has no limits and defaults a missing `mappingSize` to 0.
/// - **Edge inheritance.** An item side with no value takes the representation's, then 0. SkinKitCore fills absent sides
///   with 0. Every item leaves here with all four sides written.
/// - **Complete d-pads only.** A directional item needs `up`, `down`, `left` and `right`, all strings.
/// - **Per-item art.** SkinKitCore has no `asset` key on items (Manic's `asset.normal`), so the names are returned beside
///   the JSON, in item order.
/// - **Game types.** Only GameCube and Wii are accepted (`SkinGameType`), by the same suffixes as before. The identifier
///   handed to SkinKitCore is the canonical Manic spelling of that type.
/// - **Buckets.** Only `iphone` / `ipad`, `standard` / `edgeToEdge` and `portrait` / `landscape` are read.
///
/// Anything the overlay never reads (screen filters, haptics, button states, themes, game overrides, ...) is left out, so
/// a malformed value there cannot reject a skin SkinKitCore would otherwise decode.
enum SkinInfoSanitizer {
  struct Key: Hashable {
    let device: String
    let display: String
    let orientation: String
  }

  struct Output {
    let json: Data
    let gameType: SkinGameType
    /// Per-item `asset` values, parallel to each representation's `items`.
    let itemAssets: [Key: [SkinAsset?]]
  }

  private static let commentMarker = "//"

  static func sanitize(_ data: Data) throws -> Output {
    let object = try JSONSerialization.jsonObject(with: stripComments(data))
    guard let root = object as? [String: Any] else { throw invalid("info.json is not an object") }
    guard let name = root["name"] as? String else { throw invalid("name is missing") }
    guard let identifier = root["identifier"] as? String else { throw invalid("identifier is missing") }
    guard let gameTypeIdentifier = root["gameTypeIdentifier"] as? String else { throw invalid("gameTypeIdentifier is missing") }
    guard let gameType = SkinGameType(identifier: gameTypeIdentifier) else {
      throw invalid("Unsupported game type \(gameTypeIdentifier)")
    }
    guard let devices = root["representations"] as? [String: Any] else { throw invalid("representations is missing") }

    var representations: [String: Any] = [:]
    var itemAssets: [Key: [SkinAsset?]] = [:]
    for device in SkinDevice.allCases {
      guard let displays = devices[device.rawValue] as? [String: Any] else { continue }
      for display in SkinDisplayType.allCases {
        guard let orientations = displays[display.rawValue] as? [String: Any] else { continue }
        for orientation in TouchOverlayOrientation.allCases {
          guard let cleaned = representation(orientations[orientation.rawValue]) else { continue }
          let key = Key(device: device.rawValue, display: display.rawValue, orientation: orientation.rawValue)
          itemAssets[key] = cleaned.itemAssets
          var deviceNode = (representations[device.rawValue] as? [String: Any]) ?? [:]
          var displayNode = (deviceNode[display.rawValue] as? [String: Any]) ?? [:]
          displayNode[orientation.rawValue] = cleaned.node
          deviceNode[display.rawValue] = displayNode
          representations[device.rawValue] = deviceNode
        }
      }
    }
    guard !representations.isEmpty else { throw SkinInfoError.noUsableRepresentation }

    let json: [String: Any] = [
      "name": name,
      "identifier": identifier,
      "gameTypeIdentifier": gameType.manicIdentifier,
      "representations": representations
    ]
    return Output(json: try JSONSerialization.data(withJSONObject: json), gameType: gameType, itemAssets: itemAssets)
  }

  // MARK: - Comments

  /// Removes `//` comments (whole-line or trailing) without touching `//` inside a string, such as a URL.
  static func stripComments(_ data: Data) throws -> Data {
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

  // MARK: - Representation

  private struct Cleaned {
    let node: [String: Any]
    let itemAssets: [SkinAsset?]
  }

  /// One representation, or nil when it must be dropped.
  private static func representation(_ value: Any?) -> Cleaned? {
    guard let raw = value as? [String: Any], let mapping = size(raw["mappingSize"]),
          mapping.width > 0, mapping.height > 0 else { return nil }
    guard case .value(let ownEdges) = edges(raw["extendedEdges"]) else { return nil }
    let inherited = ownEdges ?? EdgeSides()
    var node: [String: Any] = [
      "mappingSize": ["width": Double(mapping.width), "height": Double(mapping.height)],
      "extendedEdges": inherited.node(over: EdgeSides())
    ]

    switch optionalBool(raw["translucent"]) {
    case .invalid: return nil
    case .value(let translucent): if let translucent { node["translucent"] = translucent }
    }

    switch asset(raw["assets"]) {
    case .invalid: return nil
    case .value(let background):
      if let background {
        node["assets"] = ["resizable": background.resizable, "small": background.small,
                          "medium": background.medium, "large": background.large].compactMapValues { $0 }
      }
    }

    var items: [[String: Any]] = []
    var itemAssets: [SkinAsset?] = []
    if let rawItems = raw["items"], !(rawItems is NSNull) {
      guard let list = rawItems as? [Any] else { return nil }
      for element in list {
        guard let cleaned = item(element, inheriting: inherited) else { continue }
        items.append(cleaned.node)
        itemAssets.append(cleaned.asset)
      }
      node["items"] = items
    }

    if let rawScreens = raw["screens"], !(rawScreens is NSNull) {
      guard let list = rawScreens as? [Any] else { return nil }
      node["screens"] = list.compactMap(screen)
    }
    return Cleaned(node: node, itemAssets: itemAssets)
  }

  // MARK: - Items and screens

  private static func item(_ value: Any, inheriting rep: EdgeSides) -> (node: [String: Any], asset: SkinAsset?)? {
    guard let raw = value as? [String: Any], let inputs = inputs(raw["inputs"]), let frame = rect(raw["frame"]) else { return nil }
    guard case .value(let ownEdges) = edges(raw["extendedEdges"]) else { return nil }
    guard case .value(let itemAsset) = asset(raw["asset"]) else { return nil }
    var node: [String: Any] = [
      "inputs": inputs,
      "frame": frameNode(frame),
      "extendedEdges": (ownEdges ?? EdgeSides()).node(over: rep)
    ]
    if let present = raw["thumbstick"], !(present is NSNull) {
      guard let stick = present as? [String: Any], let name = stick["name"] as? String,
            let width = number(stick["width"]), let height = number(stick["height"]) else { return nil }
      node["thumbstick"] = ["name": name, "width": Double(width), "height": Double(height)] as [String: Any]
    }
    return (node, itemAsset)
  }

  /// `["a", "b"]`, or a complete d-pad / thumbstick.
  private static func inputs(_ value: Any?) -> Any? {
    if let names = value as? [Any] {
      let strings = names.compactMap { $0 as? String }
      return strings.count == names.count ? strings : nil
    }
    guard let directions = value as? [String: Any] else { return nil }
    var result: [String: String] = [:]
    for direction in ["up", "down", "left", "right"] {
      guard let name = directions[direction] as? String else { return nil }
      result[direction] = name
    }
    return result
  }

  /// A screen with an `outputFrame`; one without (placement-only), or with a bad frame, is dropped.
  private static func screen(_ value: Any) -> [String: Any]? {
    guard let raw = value as? [String: Any], let output = rect(raw["outputFrame"]) else { return nil }
    var node: [String: Any] = ["outputFrame": frameNode(output)]
    if let present = raw["inputFrame"], !(present is NSNull) {
      guard let input = rect(present) else { return nil }
      node["inputFrame"] = frameNode(input)
    }
    return node
  }

  // MARK: - Values

  private enum Parsed<Value> {
    case value(Value)
    case invalid
  }

  private struct EdgeSides {
    var top: CGFloat?
    var left: CGFloat?
    var bottom: CGFloat?
    var right: CGFloat?

    /// All four sides, an absent one taken from `base`, then 0.
    func node(over base: EdgeSides) -> [String: Double] {
      ["top": Double(top ?? base.top ?? 0), "left": Double(left ?? base.left ?? 0),
       "bottom": Double(bottom ?? base.bottom ?? 0), "right": Double(right ?? base.right ?? 0)]
    }
  }

  /// Edge insets where any side may be absent. A present but wrong or insane side invalidates the whole value.
  private static func edges(_ value: Any?) -> Parsed<EdgeSides?> {
    guard let value, !(value is NSNull) else { return .value(nil) }
    guard let raw = value as? [String: Any] else { return .invalid }
    var sides = EdgeSides()
    let sideKeys: [(String, WritableKeyPath<EdgeSides, CGFloat?>)] = [
      ("top", \.top), ("left", \.left), ("bottom", \.bottom), ("right", \.right)
    ]
    for (key, keyPath) in sideKeys {
      guard let side = raw[key], !(side is NSNull) else { continue }
      guard let amount = number(side), SkinFrameLimits.isSane(amount) else { return .invalid }
      sides[keyPath: keyPath] = amount
    }
    return .value(sides)
  }

  /// A skin image reference; every key optional, any present key must be a string.
  private static func asset(_ value: Any?) -> Parsed<SkinAsset?> {
    guard let value, !(value is NSNull) else { return .value(nil) }
    guard let raw = value as? [String: Any] else { return .invalid }
    func string(_ key: String) -> Parsed<String?> {
      guard let entry = raw[key], !(entry is NSNull) else { return .value(nil) }
      guard let text = entry as? String else { return .invalid }
      return .value(text)
    }
    guard case .value(let normal) = string("normal"), case .value(let resizable) = string("resizable"),
          case .value(let small) = string("small"), case .value(let medium) = string("medium"),
          case .value(let large) = string("large") else { return .invalid }
    return .value(SkinAsset(normal: normal, resizable: resizable, small: small, medium: medium, large: large))
  }

  private static func optionalBool(_ value: Any?) -> Parsed<Bool?> {
    guard let value, !(value is NSNull) else { return .value(nil) }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return .invalid }
    return .value(number.boolValue)
  }

  /// A JSON number (not a boolean).
  private static func number(_ value: Any?) -> CGFloat? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return CGFloat(number.doubleValue)
  }

  private static func size(_ value: Any?) -> CGSize? {
    guard let raw = value as? [String: Any], let width = number(raw["width"]), let height = number(raw["height"]) else { return nil }
    let size = CGSize(width: width, height: height)
    return SkinFrameLimits.isSane(size) ? size : nil
  }

  /// A frame as the `{x, y, width, height}` dictionary, or the `[x, y, width, height]` array some skins use.
  private static func rect(_ value: Any?) -> CGRect? {
    let rect: CGRect
    if let list = value as? [Any] {
      let numbers = list.compactMap(number)
      guard list.count == 4, numbers.count == 4 else { return nil }
      rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    } else if let raw = value as? [String: Any] {
      guard let x = number(raw["x"]), let y = number(raw["y"]),
            let width = number(raw["width"]), let height = number(raw["height"]) else { return nil }
      rect = CGRect(x: x, y: y, width: width, height: height)
    } else {
      return nil
    }
    return SkinFrameLimits.isSane(rect) ? rect : nil
  }

  private static func frameNode(_ rect: CGRect) -> [String: Double] {
    ["x": Double(rect.origin.x), "y": Double(rect.origin.y), "width": Double(rect.width), "height": Double(rect.height)]
  }

  private static func invalid(_ message: String) -> DecodingError {
    DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: message))
  }
}
#endif
