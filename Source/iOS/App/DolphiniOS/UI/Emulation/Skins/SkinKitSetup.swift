// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation
import SkinCatalogKit
import SkinKitCore
import SkinKitManager

/// Wires iCube into SkinKit once, at launch (the same single `configure()` shape Provenance uses).
///
/// What SkinKit takes over: the catalog models and service (`SkinCatalogKit`), the store's policy, downloader, installer
/// state machine and installed record (`SkinKitManager`, `SkinStorePolicy.iCube`), and the `info.json` model
/// (`SkinKitCore`, read through `SkinInfo`). What stays here: `SkinLibrary` (import, `selection.json`, pad-kind picks),
/// the overlay, the settings UI and the install step, which is `SkinLibrary.importSkin`.
enum SkinKitSetup {
  private static let logPrefix = "[SKINSTORE]"
  private static let lock = NSLock()
  private static var isConfigured = false

  /// Idempotent. Everything it sets is a seam with an inert default, so calling late changes only where lines are logged.
  static func configure() {
    lock.lock()
    defer { lock.unlock() }
    guard !isConfigured else { return }
    isConfigured = true

    // iCube logged the store with `NSLog("[SKINSTORE] ...")`; SkinKit defaults to os.Logger, so route its three
    // modules to the same place and prefix.
    SkinCatalogLog.logger = { _, message in NSLog("%@ %@", logPrefix, message) }
    SkinManagerLog.logger = { _, message in NSLog("%@ %@", logPrefix, message) }
    SkinKitCoreLog.logger = { _, message in NSLog("%@ %@", logPrefix, message) }
  }
}

/// iCube's wording for what SkinKit reports. SkinKit's messages are English with the English text as the lookup key,
/// which is the key `L()` already uses, so iCube's translations keep applying.
enum SkinStoreMessages {
  static func describe(_ error: Error) -> String {
    switch error {
    case let error as SkinCatalogError: return error.message(localizing: L)
    case let error as URLSessionSkinStoreDownloader.HTTPStatusError: return error.message(localizing: L)
    case let error as SkinImportError: return SkinImportError.describe(error)
    default: return error.localizedDescription
    }
  }

  static func notInstallable(_ name: String) -> String {
    String(format: L("%@ isn't a skin iCube can install."), name)
  }
}

extension SkinStoreInstaller {
  /// The store's installer: iCube's policy, the `store.json` beside the library's `selection.json` (unchanged, so
  /// installs from before the move still show "Installed"), and `SkinLibrary` as the install step.
  static let shared: SkinStoreInstaller = iCube(library: .shared, record: .iCube(rootURL: SkinLibrary.defaultRootURL()))

  /// iCube's wiring of SkinKit's installer; tests pass their own library and record.
  static func iCube(library: SkinLibrary, record: SkinStoreInstalledRecord,
                    downloader: any SkinStoreDownloading = URLSessionSkinStoreDownloader()) -> SkinStoreInstaller {
    SkinKitSetup.configure()
    let policy = SkinStorePolicy.iCube
    return SkinStoreInstaller(
      policy: policy,
      downloader: downloader,
      record: record,
      appName: "iCube",
      notInstallableMessage: SkinStoreMessages.notInstallable,
      describeError: SkinStoreMessages.describe,
      installStep: libraryInstallStep(library, policy: policy)
    )
  }

  /// The install step: the library's import, rewritten to the shelf's target when it has one (the N64 shelf's
  /// `"gamecube"`). The rewrite and the `-gamecube` identifier suffix stay `SkinLibrary`'s own rules.
  static func libraryInstallStep(_ library: SkinLibrary, policy: SkinStorePolicy) -> InstallStep {
    { file, section in
      let target = policy.retarget(for: section, isSupportedGameType: false).flatMap(SkinGameType.init(retargetID:))
      return .installed(identifier: try library.importSkin(from: file, retargetingTo: target).id)
    }
  }
}

extension SkinGameType {
  /// The game type a `SkinStoreRetarget` id names (`"gamecube"` for the N64 shelf); nil for an id iCube does not know.
  init?(retargetID: String) {
    switch retargetID {
    case "gamecube": self = .gameCube
    default: return nil
    }
  }
}
#endif
