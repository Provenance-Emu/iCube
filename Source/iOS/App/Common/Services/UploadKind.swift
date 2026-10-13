// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a Web UI / WebDAV upload is. tvOS has no file picker, so a BootMii NAND backup uploaded from a computer
/// is how an Apple TV gets the user's own Wii system files (the App Store build has no online System Update).
enum UploadKind: Equatable {
  case nandBackup, other

  /// DiscIO/NANDImporter.cpp:53-58: a BootMii dump (0x21000000) and the same with its 0x400-byte keys appended.
  static let acceptedSizes: Set<Int64> = [0x2100_0000, 0x2100_0000 + 0x400]

  static func classify(fileName: String, size: Int64) -> UploadKind {
    fileName.lowercased() == "nand.bin" && acceptedSizes.contains(size) ? .nandBackup : .other
  }
}
