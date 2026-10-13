// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a Web UI / WebDAV upload is. tvOS has no file picker, so a BootMii NAND backup uploaded from a computer
/// is how an Apple TV gets the user's own Wii system files (the App Store build has no online System Update).
enum UploadKind: Equatable {
  /// `nand.bin`, a BootMii dump with or without its keys appended.
  case nandBackup
  /// `keys.bin`, the separate OTP/SEEPROM dump that goes with a dump that has no keys appended.
  case nandKeys
  case other

  /// DiscIO/NANDImporter.cpp: NAND_KEYS_SIZE.
  static let keysSize: Int64 = 0x400
  /// DiscIO/NANDImporter.cpp:53-58: NAND_BIN_SIZE, a BootMii dump without its keys.
  static let keylessDumpSize: Int64 = 0x2100_0000
  /// A dump without keys, and the same with its 0x400-byte keys appended.
  static let acceptedSizes: Set<Int64> = [keylessDumpSize, keylessDumpSize + keysSize]

  static func classify(fileName: String, size: Int64) -> UploadKind {
    switch fileName.lowercased() {
    case "nand.bin" where acceptedSizes.contains(size): return .nandBackup
    case "keys.bin" where size == keysSize: return .nandKeys
    default: return .other
    }
  }

  /// True for a dump that can only be imported together with a separately uploaded keys.bin.
  static func needsSeparateKeys(size: Int64) -> Bool {
    size == keylessDumpSize
  }
}
