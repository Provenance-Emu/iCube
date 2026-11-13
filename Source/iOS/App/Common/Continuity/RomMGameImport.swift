// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVContinuity
import RomMClient

@MainActor
enum RomMGameImport {
    /// Downloads a game into its own folder under Software/RomM and returns its disc images. The caller
    /// registers them with the library. A game that is already there is returned as it is.
    static func copy(_ game: RomMGame, from client: RomMClient, server: RomMServer) async throws -> [URL] {
        let destination = try server.folder(forGameID: game.id)
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let existing = ZipImportHelper.supportedFiles(in: destination).sorted { $0.path < $1.path }
            guard !existing.isEmpty else { throw CocoaError(.fileWriteFileExists) }
            return existing
        }
        let download = try await client.download(game)
        defer { try? manager.removeItem(at: download.directory) }
        let (source, candidates) = try await prepare(download)
        guard !candidates.isEmpty, candidates.allSatisfy({ DiscImageBridge.gameItem(forPath: $0.path) != nil }) else {
            throw RomMError.invalidContent
        }
        try Task.checkCancellation()

        guard let relative = ContinuityPaths.relativePath(forAbsolutePath: destination.path) else {
            throw RomMError.invalidContent
        }
        let prefix = source.resolvingSymlinksInPath().path + "/"
        let urls = try candidates.map { file in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let path = file.resolvingSymlinksInPath().path
            guard values.isRegularFile == true, values.isSymbolicLink != true, path.hasPrefix(prefix) else {
                throw RomMError.invalidContent
            }
            return try ContinuityPaths.validatedURL(forRelativePath: relative + "/" + path.dropFirst(prefix.count))
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: source, to: destination)
        return urls
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

    static func login(for server: RomMServer) -> RomMSavedLogin? {
        KeychainService.getPassword(for: server.id).flatMap { RomMSavedLogin(storedValue: $0) }
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
