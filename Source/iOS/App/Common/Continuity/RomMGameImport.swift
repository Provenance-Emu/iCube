// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVContinuity
import RomMClient

@MainActor
enum RomMGameImport {
    static func copy(_ game: RomMGame, from client: RomMClient) async throws {
        let download = try await client.download(game)
        defer { try? FileManager.default.removeItem(at: download.directory) }
        let (source, candidates) = try await prepare(download)
        guard !candidates.isEmpty, candidates.allSatisfy({ DiscImageBridge.gameItem(forPath: $0.path) != nil }) else {
            throw RomMError.invalidContent
        }
        try Task.checkCancellation()

        let key = client.address.baseURL.absoluteString + "\n" + String(game.id)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let relative = "Software/RomM/" + digest
        let destination = try ContinuityPaths.validatedURL(forRelativePath: relative)
        let prefix = source.resolvingSymlinksInPath().path + "/"
        let urls = try candidates.map { file in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let path = file.resolvingSymlinksInPath().path
            guard values.isRegularFile == true, values.isSymbolicLink != true, path.hasPrefix(prefix) else {
                throw RomMError.invalidContent
            }
            return try ContinuityPaths.validatedURL(forRelativePath: relative + "/" + path.dropFirst(prefix.count))
        }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: source, to: destination)
        TVLibraryBridge.updateLibrary(withRemotePaths: urls.map(\.path), fetchMetadata: true)
    }

    private static func prepare(_ download: RomMDownload) async throws -> (URL, [URL]) {
        if download.files.count == 1, let file = download.files.first,
           ImportableFileTypes.isArchiveFile(file) {
            let unpacked = download.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let games = try await Task.detached(priority: .userInitiated) {
                try ZipImportHelper.extractArchive(at: file, to: unpacked)
                return ZipImportHelper.supportedFiles(in: unpacked)
            }.value
            return (unpacked, games)
        }
        let games = download.files.filter { ImportableFileTypes.isSoftwareFile($0) }
        return (download.directory, games)
    }
}

enum RomMLoginStore {
    static func read(_ server: RomMAddress) -> String? {
        KeychainService.getPassword(for: "romm:" + server.baseURL.absoluteString)
    }

    static func write(_ value: String?, server: RomMAddress) throws {
        let account = "romm:" + server.baseURL.absoluteString
        if let value {
            guard KeychainService.setPassword(value, for: account) else { throw CocoaError(.fileWriteUnknown) }
        } else {
            KeychainService.deletePassword(for: account)
        }
    }
}
