// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import CryptoKit
import Foundation

/// Optional iCube extension. ROM permissions never imply permission to share states.
/// Requests are signed by an already-paired identity and bound to this server, game,
/// nonce and timestamp. Every catalog needs fresh owner consent. File grants expire,
/// recheck trust/exclusions live, and refer only to immutable snapshots, never wire paths.
enum NearbySaveWire {
  static let catalogPath = "/icube/library/states/v1/catalog"
  static let filePath = "/icube/library/states/v1/file"
  static let maxStates = 100
  static let maxBytes: Int64 = 1_073_741_824

  struct Request: Codable {
    let peerID: String
    let serverID: String
    let gameKey: String
    let nonce: String
    let issuedAt: Date
  }

  struct SignedRequest: Codable {
    let payload: Data
    let signature: Data
  }

  struct State: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let savedAt: Date
    let size: Int64
    let sha256: String
  }

  struct Catalog: Codable {
    let gameKey: String
    let token: String
    let states: [State]
  }

  static func signingData(_ payload: Data) -> Data {
    Data("icube.library.states.v1\0".utf8) + payload
  }

  static func verify(_ signed: SignedRequest, publicKey: Data, serverID: String, now: Date) -> Request? {
    guard signed.payload.count < 8192,
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
          key.isValidSignature(signed.signature, for: signingData(signed.payload)),
          let request = try? JSONDecoder().decode(Request.self, from: signed.payload),
          request.serverID == serverID,
          UUID(uuidString: request.nonce) != nil,
          abs(now.timeIntervalSince(request.issuedAt)) < 120 else { return nil }
    return request
  }
}

/// Replays stay consumed until every timestamp that could accompany them has expired.
struct NearbySaveReplayGuard {
  private var nonces: [String: Date] = [:]
  mutating func prune(now: Date) { nonces = nonces.filter { $0.value > now } }
  mutating func accept(_ nonce: String, now: Date) -> Bool {
    prune(now: now)
    guard nonces[nonce] == nil, nonces.count < 256 else { return false }
    nonces[nonce] = now.addingTimeInterval(240)
    return true
  }
}
