// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVLibrarySnapshot

/// One incoming `dolphinios://requestGame` ask, awaiting the user's decision.
struct EcosystemShareRequest: Identifiable {
  let id = UUID()
  let game: LibrarySnapshotGame
  let callbackScheme: String
}

/// A message the ecosystem UI shows once, as an alert at the app root.
struct EcosystemNotice: Equatable {
  let title: String
  let message: String
}

/// Hands a game's disc image to a sibling app on this device.
///
/// Two transports, picked per send:
///
/// - **Direct**, when the peer has said it receives hand-offs
///   (`EcosystemPresence` in the shared App Group container): the disc image
///   is cloned into the peer's drop-box inbox and the peer is opened, with no
///   sheet and no picking. See `EcosystemHandoff`.
/// - **Share sheet** (`EcosystemShareApprovalModifier` presents it), for a
///   peer build from before the drop box, or when staging fails: the sheet
///   lists every installed app that declares the file's type (Provenance
///   declares the GameCube and Wii disc types), and iOS copies the file into
///   the one the user picks. Apple TV has no share sheet, so it sends direct
///   or not at all.
///
/// Both work while iCube is suspended, which the first hand-off did not: it
/// opened a short-lived HTTP session and the peer downloaded from it after
/// being opened by URL. On one device opening the peer sends iCube to the
/// background and suspends the server before the first byte is fetched, so
/// every transfer failed silently.
///
/// A send the user starts here ("Send to Provenance") needs no prompt. A send
/// a peer asks for (`dolphinios://requestGame`) is confirmed every time, even
/// between Joe's own apps: the requesting URL is attacker-forgeable. The drop
/// box itself is readable only by apps in the App Group.
@MainActor
final class EcosystemShareCenter: ObservableObject {
  static let shared = EcosystemShareCenter()

  @Published var request: EcosystemShareRequest?
  /// The files the share sheet is offering, or nil when no sheet is up.
  @Published var exportItems: [URL]?
  /// Non-nil when a share couldn't start (the game's file is gone).
  /// Surfaced as an alert by `EcosystemShareApprovalModifier` so a "Send to
  /// Provenance" tap always produces visible feedback instead of silently
  /// doing nothing.
  @Published var shareError: String?
  /// Something the user should read that is not a failed share: a direct
  /// hand-off is staged but the peer could not be opened, or a sibling sent
  /// a game iCube cannot import.
  @Published var notice: EcosystemNotice?

  /// Installed peers that receive direct hand-offs, as of the last
  /// `refreshDirectPeers`. Views read this instead of the presence files, so
  /// a library grid does not hit the disk once per cell.
  @Published private(set) var directPeers: Set<String> = []

  private init() {}

  /// Re-reads which installed peers take direct hand-offs. Called every time
  /// the app becomes active (a peer may have been installed, updated or
  /// removed meanwhile). Only Provenance is a send target today.
  func refreshDirectPeers() {
    guard let root = EcosystemHandoff.sharedRoot else {
      directPeers = []
      return
    }
    let peers = [EcosystemSchemes.provenanceScheme].filter { scheme in
      Self.takesDirectHandoff(
        peer: scheme, system: nil, root: root,
        installed: EcosystemBridge.peerInstalled(scheme: scheme)
      )
    }
    directPeers = Set(peers)
  }

  /// Does `peer` get this game straight through the drop box? Only when it
  /// is installed (its presence file outlives it) and its presence entry
  /// takes a game for `system`.
  nonisolated static func takesDirectHandoff(peer: String, system: String?, root: URL, installed: Bool) -> Bool {
    installed && EcosystemPresence.read(scheme: peer, root: root)?
      .accepts(kind: EcosystemHandoff.gameKind, system: system) == true
  }

  /// Should the library offer "Send to <peer>"? iPhone, iPad and Mac can
  /// always fall back to the share sheet; Apple TV has none, so it offers the
  /// send only to a peer that takes direct hand-offs.
  func canSend(toScheme scheme: String) -> Bool {
    #if os(tvOS)
    return directPeers.contains(scheme)
    #else
    return directPeers.contains(scheme) || EcosystemBridge.peerInstalled(scheme: scheme)
    #endif
  }

  /// Entry point from `EcosystemBridge.perform`.
  func handleRequest(gameID: String, callbackScheme: String) {
    guard let game = EcosystemBridge.game(forID: gameID) else { return }
    // One ask at a time; a second requester is dropped (it can retry).
    guard request == nil else { return }
    request = EcosystemShareRequest(game: game, callbackScheme: callbackScheme)
  }

  func deny() {
    request = nil
  }

  /// Friendly peer name for user-facing messages ("provenance" → "Provenance").
  nonisolated static func peerName(_ scheme: String) -> String {
    switch scheme.lowercased() {
    case EcosystemSchemes.provenanceScheme: "Provenance"
    case EcosystemSchemes.iflyScheme: "iFly"
    default: "\(scheme)://"
    }
  }

  func approve() {
    guard let request else { return }
    self.request = nil
    offer(game: request.game, peer: request.callbackScheme)
  }

  /// User-initiated push ("Send to Provenance" in the game context menu). No
  /// confirm prompt: the user's tap IS the consent.
  func send(gameID: String, toScheme scheme: String = EcosystemSchemes.provenanceScheme) {
    guard let game = EcosystemBridge.game(forID: gameID) else {
      shareError = "That game isn\u{2019}t in the library snapshot yet. Try again in a moment."
      return
    }
    offer(game: game, peer: scheme)
  }

  func finishExport() {
    exportItems = nil
  }

  private func offer(game: LibrarySnapshotGame, peer: String) {
    let title = game.title
    guard let items = Self.exportItems(forFilePath: game.filePath) else {
      shareError = "The file for \u{201C}\(title)\u{201D} is missing. Rescan the library and try again."
      return
    }
    let system = EcosystemHandoff.systemID(for: game.icubePlatform)
    if let root = EcosystemHandoff.sharedRoot,
       Self.takesDirectHandoff(peer: peer, system: system, root: root,
                               installed: EcosystemBridge.peerInstalled(scheme: peer)) {
      sendDirect(items: items, title: title, system: system, peer: peer, root: root)
    } else {
      presentShareSheet(items: items, title: title, peer: peer)
    }
  }

  /// Clones the disc image into the peer's drop-box inbox, then opens the
  /// peer. Falls back to the share sheet when the drop box can't be written.
  private func sendDirect(items: [URL], title: String, system: String?, peer: String, root: URL) {
    Task {
      let staged = await Task.detached(priority: .userInitiated) {
        Result {
          // No md5: the snapshot identifies a game by its disc id.
          try EcosystemHandoffStager.stage(
            files: items, to: peer, title: title, system: system, md5: nil, root: root
          )
        }
      }.value
      switch staged {
      case .success(let manifest):
        NSLog("[Ecosystem] staged '%@' (%d file(s)) for %@:// as %@", title, manifest.files.count, peer, manifest.id)
        var opened = false
        if let url = EcosystemHandoff.wakeURL(to: peer, id: manifest.id) {
          opened = await EcosystemBridge.open(url)
        }
        if !opened {
          // The game is in the peer's inbox either way; it imports the next time the peer runs.
          NSLog("[Ecosystem] couldn't open %@:// after staging '%@'", peer, title)
          let peerName = Self.peerName(peer)
          notice = EcosystemNotice(
            title: String(format: L("Open %@"), peerName),
            message: String(format: L("\u{201C}%@\u{201D} is waiting for %@. Open %@ to finish the import."),
                            title, peerName, peerName)
          )
        }
      case .failure(let error):
        NSLog("[Ecosystem] direct hand-off of '%@' to %@:// failed: %@", title, peer, error.localizedDescription)
        presentShareSheet(items: items, title: title, peer: peer)
      }
    }
  }

  private func presentShareSheet(items: [URL], title: String, peer: String) {
    #if os(iOS)
    exportItems = items
    #else
    let peerName = Self.peerName(peer)
    shareError = String(
      format: L("Couldn\u{2019}t hand \u{201C}%@\u{201D} to %@. Update %@ on this Apple TV, or send the game from iPhone or iPad."),
      title, peerName, peerName
    )
    #endif
  }

  /// What the share sheet offers for a game: its disc image, or nil when the
  /// file is not on disk. A game is one file on iCube (every supported disc
  /// format is single-file), so there is nothing else to bundle.
  nonisolated static func exportItems(forFilePath path: String) -> [URL]? {
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
    return [URL(fileURLWithPath: path)]
  }
}
