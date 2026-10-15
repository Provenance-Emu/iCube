// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Tells a boot of a modded disc from a boot of the pristine game.
///
/// Dolphin names save-state slots by game ID and a patched disc keeps its base game's ID, so a modded
/// run shares `{GameID}.auto` with the vanilla game. That file is the "resume where I left off" state:
/// loading it into a patched disc, or overwriting the vanilla one from it, corrupts a run in both
/// directions. A modded boot therefore has no auto-state at all: `TVEmulationBridge.autoStateFilePath`
/// returns nil for it, which skips both the save in `stop` and the load in `SaveStateService`. Manual
/// slots stay shared on purpose.
///
/// A boot is modded by where its file lives, so nothing has to be remembered per game and every way
/// of starting one (library tile, "Apply Patch…" run, Siri, a later launch of a saved copy) agrees:
///   - `<User>/Cache/PatchedDiscs/`: a cached patched disc (disc patching, "this run");
///   - `<Software>/Patched/`: a patched copy saved to the library (disc patching, "copy");
///   - any `.json` file: a Dolphin mod descriptor (Riivolution), which boots a base disc plus patches
///     without a file of its own. The Riivolution flow shares this helper.
@objc(DOLModdedBoot)
final class ModdedBoot: NSObject {
  private static let descriptorExtension = "json"

  /// True when `path` is a modded boot target. Symlinks are resolved on both sides (`/var` against
  /// `/private/var`) and folders are compared whole component by whole component, so `Patched` does
  /// not claim `PatchedX`.
  static func isModded(path: String, patchedDiscsDirectory: String, patchedSoftwareDirectory: String) -> Bool {
    if URL(fileURLWithPath: path).pathExtension.lowercased() == descriptorExtension { return true }
    let target = components(of: path)
    return [patchedDiscsDirectory, patchedSoftwareDirectory].contains { folder in
      let prefix = components(of: folder)
      return target.count > prefix.count && target.starts(with: prefix)
    }
  }

  /// `resolvingSymlinksInPath` drops `/private` only from paths it could resolve, so a path that does not
  /// exist yet would come out as `/private/var/...` on one side and `/var/...` on the other.
  private static func components(of path: String) -> [String] {
    var resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    if resolved.hasPrefix(privatePrefix + "/") { resolved.removeFirst(privatePrefix.count) }
    return URL(fileURLWithPath: resolved).pathComponents
  }

  private static let privatePrefix = "/private"

  /// `isModded(path:...)` against the app's real folders.
  @objc static func isModdedPath(_ path: String) -> Bool {
    guard let directories = DiscPatchDirectories.live else {
      return URL(fileURLWithPath: path).pathExtension.lowercased() == descriptorExtension
    }
    return isModded(path: path,
                    patchedDiscsDirectory: directories.patchedDiscs.path,
                    patchedSoftwareDirectory: directories.patchedSoftware.path)
  }

  // MARK: - The running boot

  private static let lock = NSLock()
  private static var bootPath: String?

  /// Called by the emulation loop when a boot starts. `nil` for boots without a file (the GameCube menu).
  @objc(beginBootAtPath:)
  static func beginBoot(atPath path: String?) {
    lock.lock()
    bootPath = path
    lock.unlock()
  }

  /// Called by the emulation loop when the run ends.
  @objc static func endBoot() {
    lock.lock()
    bootPath = nil
    lock.unlock()
  }

  /// True while the running boot is a modded one.
  @objc static var isCurrentBootModded: Bool {
    lock.lock()
    let path = bootPath
    lock.unlock()
    return path.map(isModdedPath) ?? false
  }
}

extension DiscPatchDirectories {
  /// The app's real folders; nil until Dolphin's user directory exists.
  static var live: DiscPatchDirectories? {
    guard let user = DolphinPaths.userDirectoryURL() else { return nil }
    return DiscPatchDirectories(user: user, software: URL(fileURLWithPath: UserFolderUtil.getSoftwareFolder(), isDirectory: true))
  }
}
