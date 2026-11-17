// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Runs iCube's side of the shared drop box (see `EcosystemHandoff`) at the
/// moments the app is in front: publishes iCube's presence entry, clears out
/// what its own sends left behind, and imports the games sibling apps have
/// handed over.
@MainActor
enum EcosystemHandoffImporter {
  /// One hand-off taken out of the inbox.
  struct Received: Equatable, Sendable {
    let manifest: EcosystemHandoffManifest
    let placement: EcosystemHandoffInbox.Placement
  }

  private static var importing = false
  /// A second request arrived while one was running: look again when it ends,
  /// because the hand-off that prompted it may have landed after the listing.
  private static var lookAgain = false

  /// Launch: tell the siblings this build receives hand-offs, before the
  /// first scene is active.
  static func publishPresence() {
    guard let root = EcosystemHandoff.sharedRoot else { return }
    let presence = EcosystemPresence.own()
    Task.detached(priority: .utility) {
      do {
        try presence.write(root: root)
      } catch {
        NSLog("[Ecosystem] couldn't write presence: %@", error.localizedDescription)
      }
    }
  }

  /// Every time the app becomes active, launch included.
  static func appBecameActive() {
    EcosystemShareCenter.shared.refreshDirectPeers()
    guard let root = EcosystemHandoff.sharedRoot else { return }
    publishPresence()
    Task.detached(priority: .utility) {
      let removed = EcosystemHandoffStager.collectGarbage(root: root)
      if removed > 0 {
        NSLog("[Ecosystem] removed %d stale hand-off(s) from the drop box", removed)
      }
    }
    Task { await importPending() }
  }

  /// Imports every hand-off waiting in iCube's inbox. Called when the app
  /// becomes active and when a sender opens `dolphinios://handoff`; the two
  /// can arrive together, so a call while one is running only asks it to look
  /// once more.
  static func importPending() async {
    guard let root = EcosystemHandoff.sharedRoot else { return }
    if importing {
      lookAgain = true
      return
    }
    importing = true
    defer { importing = false }

    let library = URL(fileURLWithPath: UserFolderUtil.getSoftwareFolder(), isDirectory: true)
    repeat {
      lookAgain = false
      let received = await Task.detached(priority: .userInitiated) {
        receive(root: root, into: library)
      }.value
      report(received)
    } while lookAgain
  }

  /// Takes every hand-off addressed to `own` out of the drop box and into
  /// `library`. File work only, so it runs off the main actor and against a
  /// temporary directory in tests.
  nonisolated static func receive(
    root: URL,
    into library: URL,
    own: String = EcosystemSchemes.ownScheme,
    fileManager: FileManager = .default
  ) -> [Received] {
    EcosystemHandoffInbox.pending(root: root, own: own, fileManager: fileManager).map { pending in
      Received(
        manifest: pending.manifest,
        placement: EcosystemHandoffInbox.place(
          pending, into: library,
          allowedExtensions: ImportableFileTypes.softwareExtensions,
          fileManager: fileManager
        )
      )
    }
  }

  /// What went wrong with one hand-off, or nil when its game is in the
  /// library. Pure, for tests.
  nonisolated static func problemMessage(for received: Received) -> String? {
    let peer = EcosystemShareCenter.peerName(received.manifest.from)
    if !received.placement.failed.isEmpty {
      // The hand-off is still in the drop box (`EcosystemHandoffInbox.place`).
      return String(
        format: L("Couldn\u{2019}t import \u{201C}%@\u{201D} from %@. iCube will try again the next time it opens."),
        received.manifest.title, peer
      )
    }
    guard received.placement.primaries.isEmpty else { return nil }
    return String(
      format: L("%@ sent \u{201C}%@\u{201D}, but none of its files are a format iCube can import."),
      peer, received.manifest.title
    )
  }

  /// Hand-offs kept for a retry that the user has been told about since
  /// launch: one that keeps failing is reported once, not on every activation.
  private static var reportedFailures = Set<String>()

  private static func report(_ received: [Received]) {
    var placedAny = false
    for item in received {
      NSLog("[Ecosystem] hand-off '%@' from %@:// — %d placed, %d already here, %d refused, %d failed",
            item.manifest.title, item.manifest.from, item.placement.placed.count,
            item.placement.alreadyPresent.count, item.placement.rejected.count, item.placement.failed.count)
      for url in item.placement.placed {
        LibraryAddedDateStore.record(path: url.path)
        placedAny = true
      }
    }
    if placedAny {
      // The library rescans on this, as it does after a picked import.
      NotificationCenter.default.post(name: .DOLImportFileFinished, object: nil)
    }

    let problems = received.compactMap { item -> String? in
      guard let message = problemMessage(for: item) else { return nil }
      if !item.placement.failed.isEmpty, !reportedFailures.insert(item.manifest.id).inserted { return nil }
      return message
    }
    if let problem = problems.last {
      EcosystemShareCenter.shared.notice = EcosystemNotice(title: L("Couldn\u{2019}t Import"), message: problem)
    }
    guard let imported = received.last(where: { problemMessage(for: $0) == nil }) else { return }
    let peer = EcosystemShareCenter.peerName(imported.manifest.from)
    let text = imported.placement.placed.isEmpty
      ? String(format: L("\u{201C}%@\u{201D} from %@ is already in your library."), imported.manifest.title, peer)
      : String(format: L("Imported \u{201C}%@\u{201D} from %@."), imported.manifest.title, peer)
    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": text])
  }
}
