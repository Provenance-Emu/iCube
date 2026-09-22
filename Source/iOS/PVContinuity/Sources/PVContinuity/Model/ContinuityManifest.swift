// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The full description of a handoff payload, served at
/// `ContinuityRoutes.manifest`.
///
/// Versioned, and the version is checked **during decode**: an app that doesn't
/// understand a manifest fails loudly with
/// `ContinuityError.manifestVersionUnsupported` rather than quietly parsing a
/// subset of it and pulling half a payload.
///
/// The session bearer token is never part of the manifest. It travels only in
/// the `Authorization` header (and, on the same-user Handoff path, in the
/// activity payload) — never in anything a peer could be handed by accident.
public struct ContinuityManifest: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let supportedVersions: ClosedRange<Int> = 1...1

    public var version: Int
    public var sessionId: String
    public var mintedAt: Date
    public var sourceDevice: SourceDevice
    public var game: GameIdentity
    /// The state to resume from, when one was minted.
    public var saveState: SaveStateDescriptor?
    /// Everything else: the disc image and the user-data files that passed
    /// `SyncClassifier`.
    public var files: [FileDescriptor]

    public init(
        version: Int = ContinuityManifest.currentVersion,
        sessionId: String,
        mintedAt: Date,
        sourceDevice: SourceDevice,
        game: GameIdentity,
        saveState: SaveStateDescriptor? = nil,
        files: [FileDescriptor] = []
    ) {
        self.version = version
        self.sessionId = sessionId
        self.mintedAt = mintedAt
        self.sourceDevice = sourceDevice
        self.game = game
        self.saveState = saveState
        self.files = files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard Self.supportedVersions.contains(version) else {
            throw ContinuityError.manifestVersionUnsupported(found: version)
        }
        self.version = version
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.mintedAt = try container.decode(Date.self, forKey: .mintedAt)
        self.sourceDevice = try container.decode(SourceDevice.self, forKey: .sourceDevice)
        self.game = try container.decode(GameIdentity.self, forKey: .game)
        self.saveState = try container.decodeIfPresent(SaveStateDescriptor.self, forKey: .saveState)
        self.files = try container.decode([FileDescriptor].self, forKey: .files)
    }

    /// Every transferable descriptor, save state included.
    ///
    /// This is also the **allow-list** the file route serves from: a path that
    /// is not in here cannot be fetched, so no crafted request can reach
    /// outside the payload the manifest describes.
    public var allDescriptors: [FileDescriptor] {
        var all = files
        if let saveState { all.append(saveState.fileDescriptor) }
        return all
    }

    public func descriptor(forRelativePath relativePath: String) -> FileDescriptor? {
        allDescriptors.first { $0.relativePath == relativePath }
    }

    // MARK: - Wire codec

    /// ISO 8601 dates and sorted keys, so two devices on different locales and
    /// different Foundation versions produce byte-identical manifests for
    /// identical content.
    public static func decode(from data: Data) throws -> ContinuityManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ContinuityManifest.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
