// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import MachO

/// A conservative precondition for CloudKit construction, using the executable's
/// code-signature slots, never linker entitlements or a provisioning profile.
/// This does not validate a signature or account access; the OS owns those checks.
/// Unknown encodings fail closed. No CloudKit API is called to discover eligibility.
enum SignedCloudKitEntitlements {
  private static let limit = 1_048_576
  private enum Invalid: Error { case signature }
  private static let keys = ["com.apple.developer.icloud-services",
                             "com.apple.developer.icloud-container-identifiers",
                             "com.apple.developer.icloud-container-environment"]

  static func allowsCloudKit(identifier: String) -> Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    guard let url = Bundle.main.executableURL, let header = _dyld_get_image_header(0),
          let imageName = _dyld_get_image_name(0),
          URL(fileURLWithPath: String(cString: imageName)).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else { return false }
    return allowsCloudKit(executableURL: url, identifier: identifier,
                          cpuType: UInt32(bitPattern: header.pointee.cputype),
                          cpuSubtype: UInt32(bitPattern: header.pointee.cpusubtype))
    #endif
  }

  /// Internal seam also exercises file-range validation in native regression tests.
  static func allowsCloudKit(executableURL: URL, identifier: String, cpuType: UInt32, cpuSubtype: UInt32) -> Bool {
    do {
      let file = try FileHandle(forReadingFrom: executableURL)
      defer { try? file.close() }
      let size = try file.seekToEnd()
      func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, count <= limit, offset <= size, UInt64(count) <= size - offset else { throw Invalid.signature }
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: count), data.count == count else { throw Invalid.signature }
        return data
      }
      var base: UInt64 = 0, sliceSize = size
      let first = try read(0, 32)
      let magic = try word(first, 0)
      if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
        let count = Int(try word(first, 4))
        guard count > 0, count <= 32 else { return false }
        let stride = magic == 0xCAFE_BABE ? 20 : 32
        let table = try read(8, count * stride)
        var matches = 0
        for i in 0 ..< count {
          let p = i * stride
          if try word(table, p) == cpuType, try word(table, p + 4) == cpuSubtype {
            matches += 1
            if stride == 20 {
              base = UInt64(try word(table, p + 8))
              sliceSize = UInt64(try word(table, p + 12))
            } else {
              base = try wide(table, p + 8)
              sliceSize = try wide(table, p + 16)
            }
          }
        }
        guard matches == 1, base >= UInt64(8 + count * stride), base <= size, sliceSize <= size - base else { return false }
      }
      let header = try read(base, 32)
      guard sliceSize >= 32, try word(header, 0, little: true) == 0xFEED_FACF,
            try word(header, 4, little: true) == cpuType, try word(header, 8, little: true) == cpuSubtype,
            try word(header, 12, little: true) == 2 else { return false } // MH_EXECUTE
      let ncmds = Int(try word(header, 16, little: true))
      let commandsSize = Int(try word(header, 20, little: true))
      guard ncmds > 0, ncmds <= 4096, commandsSize <= limit, UInt64(commandsSize) <= sliceSize - 32 else { return false }
      let commands = try read(base + 32, commandsSize)
      var p = 0, signature: (UInt64, Int)?
      for _ in 0 ..< ncmds {
        let command = try word(commands, p, little: true)
        let length = Int(try word(commands, p + 4, little: true))
        guard length >= 8, length % 8 == 0, p <= commands.count, length <= commands.count - p else { return false }
        if command == 0x1D { // LC_CODE_SIGNATURE
          guard length == 16, signature == nil else { return false }
          let offset = UInt64(try word(commands, p + 8, little: true))
          let size = Int(try word(commands, p + 12, little: true))
          guard offset >= UInt64(32 + commandsSize), offset <= sliceSize, UInt64(size) <= sliceSize - offset else { return false }
          signature = (base + offset, size)
        }
        p += length
      }
      guard p == commands.count, let signature else { return false }
      return signatureAllowsCloudKit(try read(signature.0, signature.1), identifier: identifier)
    } catch { return false }
  }

  private static func word(_ data: Data, _ p: Int, little: Bool = false) throws -> UInt32 {
    guard p >= 0, p <= data.count, data.count - p >= 4 else { throw Invalid.signature }
    let bytes = data[p ..< p + 4]
    return (little ? Array(bytes.reversed()) : Array(bytes)).reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private static func wide(_ data: Data, _ p: Int) throws -> UInt64 {
    (UInt64(try word(data, p)) << 32) | UInt64(try word(data, p + 4))
  }

  static func signatureAllowsCloudKit(_ signature: Data, identifier: String) -> Bool {
    do {
      guard !identifier.isEmpty, signature.count <= limit, try word(signature, 0) == 0xFADE_0CC0 else { return false }
      let length = Int(try word(signature, 4)), count = Int(try word(signature, 8))
      guard length <= signature.count, count > 0, count <= 128, length >= 12 + count * 8 else { return false }
      var xml: Data?, der: Data?, ranges: [Range<Int>] = [], slots = Set<UInt32>()
      for i in 0 ..< count {
        let slot = try word(signature, 12 + i * 8)
        let offset = Int(try word(signature, 16 + i * 8))
        guard slots.insert(slot).inserted, offset >= 12 + count * 8, offset <= length - 8 else { return false }
        let magic = try word(signature, offset), size = Int(try word(signature, offset + 4))
        guard size >= 8, size <= length - offset else { return false }
        let range = offset ..< offset + size
        guard !ranges.contains(where: { $0.overlaps(range) }) else { return false }
        ranges.append(range)
        if slot == 5 || slot == 7 {
          guard magic == (slot == 5 ? 0xFADE_7171 : 0xFADE_7172) else { return false }
          let payload = signature.subdata(in: offset + 8 ..< offset + size)
          if slot == 5 { xml = payload } else { der = payload }
        }
      }
      // iCube's minimum OS supports DER. XML alone cannot establish what the
      // runtime sees; missing/unknown DER disables CloudKit on that install.
      guard let der else { return false }
      var reader = DER(data: der)
      guard case let .dictionary(values) = try reader.rootValue(), reader.position == der.count,
            let entitlement = projection(values), entitlement.services.contains("CloudKit"),
            entitlement.containers.contains(identifier),
            ["Development", "Production"].contains(entitlement.environment) else { return false }
      if let xml {
        let validator = XMLKeys()
        let parser = XMLParser(data: xml)
        parser.delegate = validator
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), validator.valid,
              let dict = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let xmlProjection = projection(dict), xmlProjection == entitlement else { return false }
      }
      return true
    } catch { return false }
  }

  private struct Entitlement: Equatable { let services: [String]
    let containers: [String]
    let environment: String
  }

  private static func projection(_ values: [String: Value]) -> Entitlement? {
    guard case let .array(services)? = values[keys[0]], case let .array(containers)? = values[keys[1]],
          case let .string(environment)? = values[keys[2]] else { return nil }
    func strings(_ values: [Value]) -> [String]? {
      var strings: [String] = []
      for value in values { guard case let .string(s) = value, !s.isEmpty, !s.contains("*") else { return nil }
        strings.append(s)
      }
      return strings
    }
    guard let s = strings(services), let c = strings(containers) else { return nil }
    return Entitlement(services: s, containers: c, environment: environment)
  }

  private static func projection(_ values: [String: Any]) -> Entitlement? {
    guard let services = values[keys[0]] as? [String], let containers = values[keys[1]] as? [String],
          let environment = values[keys[2]] as? String else { return nil }
    return Entitlement(services: services, containers: containers, environment: environment)
  }

  private indirect enum Value { case string(String), array([Value]), dictionary([String: Value]), other }
  /// DER plist uses SET dictionaries and SEQUENCE arrays/key-value tuples
  /// (Apple Security/OSX/utilities/der_dictionary.c, der_plist.c). Modern
  /// entitlements wrap version 1 and context-tagged dictionaries in tag 0x70.
  /// This encoding is also checked against existing codesign-produced archives.
  /// No private framework entry points are used. Unknown versions fail closed.
  private struct DER {
    let data: Data
    var position = 0, nodes = 0
    private var dictionaryTag: UInt8 = 49
    init(data: Data) { self.data = data }
    mutating func rootValue() throws -> Value {
      if data.first == 0x70 {
        let (_, end) = try item(end: data.count)
        let (versionTag, versionEnd) = try item(end: end)
        guard versionTag == 2, versionEnd - position == 1, data[position] == 1 else { throw Invalid.signature }
        position = versionEnd
        dictionaryTag = 0xB0
        let result = try value(depth: 0, end: end)
        guard position == end, end == data.count else { throw Invalid.signature }
        return result
      }
      return try value(depth: 0)
    }

    mutating func item(end: Int) throws -> (UInt8, Int) {
      guard position < end else { throw Invalid.signature }
      let tag = data[position]
      position += 1
      guard position < end else { throw Invalid.signature }
      let initial = Int(data[position])
      position += 1
      var length = initial
      if initial >= 128 {
        let count = initial & 127
        guard count > 0, count <= 4, count <= end - position, data[position] != 0 else { throw Invalid.signature }
        length = 0
        for _ in 0 ..< count { length = length * 256 + Int(data[position])
          position += 1
        }
        guard length >= 128 else { throw Invalid.signature }
      }
      guard length <= end - position else { throw Invalid.signature }
      return (tag, position + length)
    }

    mutating func value(depth: Int, end: Int? = nil) throws -> Value {
      nodes += 1
      guard depth <= 32, nodes <= 4096 else { throw Invalid.signature }
      let (tag, finish) = try item(end: end ?? data.count)
      switch tag {
      case 12:
        guard let string = String(data: data.subdata(in: position ..< finish), encoding: .utf8), !string.contains("\0") else { throw Invalid.signature }
        position = finish
        return .string(string)
      case 48:
        var array: [Value] = []
        while position < finish { array.append(try value(depth: depth + 1, end: finish)) }
        return .array(array)
      case dictionaryTag:
        var dict: [String: Value] = [:]
        var previousKey: String?
        while position < finish {
          let (pairTag, pairEnd) = try item(end: finish)
          guard pairTag == 48, case let .string(key) = try value(depth: depth + 1, end: pairEnd), dict[key] == nil else { throw Invalid.signature }
          if dictionaryTag == 0xB0, let previousKey,
             !previousKey.utf8.lexicographicallyPrecedes(key.utf8) { throw Invalid.signature }
          previousKey = key
          let v = try value(depth: depth + 1, end: pairEnd)
          guard position == pairEnd else { throw Invalid.signature }
          dict[key] = v
        }
        return .dictionary(dict)
      case 1:
        guard finish - position == 1, [0, 1, 255].contains(data[position]) else { throw Invalid.signature }
      case 2:
        guard (1 ... 8).contains(finish - position) else { throw Invalid.signature }
      case 4: break // Data is allowed for unrelated entitlements.
      default: throw Invalid.signature
      }
      position = finish
      return .other
    }
  }

  /// Foundation plist decoding silently accepts duplicate keys. Reject these
  /// before comparing XML and DER, rather than relying on a last-value choice.
  private final class XMLKeys: NSObject, XMLParserDelegate {
    var valid = true
    private var dictionaries: [Set<String>] = [], key: String?, depth = 0, nodes = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
      depth += 1
      nodes += 1
      guard depth <= 32, nodes <= 4096 else { valid = false
        parser.abortParsing()
        return
      }
      if name == "dict" { dictionaries.append([]) }
      if name == "key" { key = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if key != nil { key! += string } }
    func parser(_ parser: XMLParser, foundCDATA block: Data) {
      guard let string = String(data: block, encoding: .utf8) else { valid = false
        parser.abortParsing()
        return
      }
      if key != nil { key! += string }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
      valid = false
      parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
      depth -= 1
      if name == "key" {
        guard let k = key, !dictionaries.isEmpty, dictionaries[dictionaries.count - 1].insert(k).inserted else {
          valid = false
          parser.abortParsing()
          return
        }
        key = nil
      }
      if name == "dict", !dictionaries.isEmpty { dictionaries.removeLast() }
    }
  }
}
