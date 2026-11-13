// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Which server a copied game came from, kept beside its files so an edit made here can be written back.
struct RemoteGameOrigin: Codable, Equatable, Sendable {
  static let fileName = ".icube-origin.json"
  /// The folder every Emulation Server game folder sits in (`EmulationServer.folder(for:)`).
  private static let container = "EmulationServer"
  /// A disc of a multi-disc game sits at most this many folders below its game folder.
  private static let maximumDepth = 4

  let server: URL
  /// The catalog key the server listed the game under: `source:<id>` or `item:<id>`.
  let key: String

  func write(in folder: URL) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    try? data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
  }

  /// The origin of the game whose file is at `path` (a path or a file URL string), or nil when it did not
  /// come from an Emulation Server.
  static func find(forGameAt path: String) -> RemoteGameOrigin? {
    guard var folder = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(string: path))?.deletingLastPathComponent(),
          folder.isFileURL else { return nil }
    for _ in 0 ..< maximumDepth {
      let parent = folder.deletingLastPathComponent()
      if parent.lastPathComponent == container {
        return (try? Data(contentsOf: folder.appendingPathComponent(fileName)))
          .flatMap { try? JSONDecoder().decode(RemoteGameOrigin.self, from: $0) }
      }
      guard parent.path != folder.path else { return nil }
      folder = parent
    }
    return nil
  }
}

/// Writes a title or cover edited on this device back to the Emulation Server the game was copied from, so
/// every device that browses the server sees it. The local save has already happened and never depends on this.
@MainActor
enum EmulationServerMetadataSync {
  /// Longest side of an uploaded cover, in pixels.
  private static let coverPixelSize = 1200
  /// The server's limit for a front cover.
  private static let maximumCoverBytes = 2 * 1024 * 1024

  /// `title` and `cover` are what changed; pass nil for what did not.
  static func push(gamePath: String, title: String?, cover: Data?) {
    guard title != nil || cover != nil, let origin = RemoteGameOrigin.find(forGameAt: gamePath),
          let server = try? EmulationServer(address: origin.server.absoluteString) else { return }
    let token = writeToken(for: server) ?? KeychainService.getPassword(for: server.id)
    Task {
      let upload = await Task.detached(priority: .utility) { cover.flatMap(Self.uploadCover) }.value
      do {
        try await EmulationServerLibrary(server: server, token: token)
          .saveDetails(forKey: origin.key, title: title, cover: upload)
        announce(String(format: L("Saved to %@ too."), server.name))
      } catch {
        announce(String(format: L("Saved on this device. %1$@ did not take the change: %2$@"),
                        server.name, error.localizedDescription))
      }
    }
  }

  /// The backup token is the one the user entered for writing, and only for a connection they allowed it on.
  private static func writeToken(for server: EmulationServer) -> String? {
    guard let target = EmulationServerBackups.shared.targets[server.id],
          server.origin.scheme == "https" || target.allowsHTTP else { return nil }
    return KeychainService.getPassword(for: target.credentialKey)
  }

  nonisolated private static func uploadCover(_ data: Data) -> Data? {
    for size in [coverPixelSize, RemoteCoverCache.maximumPixelSize] {
      if let cover = RemoteCoverCache.thumbnail(data, maximumPixelSize: size), cover.count <= maximumCoverBytes {
        return cover
      }
    }
    return nil
  }

  private static func announce(_ text: String) {
    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": text])
  }
}
