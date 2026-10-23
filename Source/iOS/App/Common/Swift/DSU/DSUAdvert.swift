// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Who a phone says it is in its DSU Bonjour record (`_dolphin-dsu._udp`).
/// The phone publishes it (`DSUServerBridge.setIdentity`); the TV parses it
/// from the browse result's TXT data.
struct DSUAdvert: Equatable {
  static let version = "1"

  private enum Key {
    static let version = "v"
    static let pid = "pid"
    static let name = "name"
    static let deviceType = "dt"
    static let role = "role"
  }

  private static let controllerRole = "controller"

  /// A stable id for this install of the app on this device.
  let pid: String
  let name: String
  /// The device family, for example "iPhone" or "iPad".
  let deviceType: String
  /// Whether the phone is on its controller screen and wants to be a pad.
  let isController: Bool

  func txtRecord() -> [String: String] {
    var record = [
      Key.version: Self.version,
      Key.pid: pid,
      Key.name: name,
      Key.deviceType: deviceType,
    ]
    if isController { record[Key.role] = Self.controllerRole }
    return record
  }

  /// `nil` unless the record is version 1 and names a phone (non-empty `pid` and `name`).
  static func parse(_ txt: [String: Data]) -> DSUAdvert? {
    func string(_ key: String) -> String? {
      txt[key].flatMap { String(data: $0, encoding: .utf8) }
    }
    guard string(Key.version) == version,
          let pid = string(Key.pid), !pid.isEmpty,
          let name = string(Key.name), !name.isEmpty
    else { return nil }
    return DSUAdvert(pid: pid,
                     name: name,
                     deviceType: string(Key.deviceType) ?? "",
                     isController: string(Key.role) == controllerRole)
  }
}
