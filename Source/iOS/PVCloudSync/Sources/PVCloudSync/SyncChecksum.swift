// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation

/// The one checksum the engine uses, so a merge result hashed by the
/// coordinator and a file hashed by the scanner agree byte for byte.
public enum SyncChecksum {
    /// SHA-256, lowercase hex.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
