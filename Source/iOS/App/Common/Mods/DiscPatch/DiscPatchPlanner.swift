// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVPatchEngine

// Pure planning for the disc patching flow: what to refuse, where each mode writes, how much room it
// needs and which game a patch most likely belongs to. Plain values in, plain values out, so the whole
// table is unit-testable without a disc, a patch or the core.

/// Where the patched disc ends up.
enum DiscPatchMode: String, CaseIterable, Identifiable {
  /// Cached copy in `<User>/Cache/PatchedDiscs/`, booted now and reused by the next run.
  case thisRun
  /// A new file in `<Software>/Patched/`, which the library lists as its own game.
  case saveCopy
  /// The original file is replaced. Destructive.
  case replaceOriginal

  var id: String { rawValue }
}

/// Container of the copy written by `DiscPatchMode.saveCopy`.
enum DiscPatchCopyFormat: String, CaseIterable, Identifiable {
  case rvz
  case iso

  var id: String { rawValue }
  var fileExtension: String { rawValue }
}

/// `DOLDiscContainer`, as a Swift value that tests can build without the bridge.
enum DiscContainer: Equatable {
  case plain, rvz, wia, gcz, wbfs, ciso, other

  /// Containers DiscIO can expand to a plain ISO.
  var isCompressed: Bool {
    switch self {
    case .rvz, .wia, .gcz, .wbfs, .ciso: return true
    case .plain, .other: return false
    }
  }
}

/// `DOLDiscPlatform`, as a Swift value.
enum DiscPlatform: Equatable {
  case gameCube, triforce, wii, wiiWAD, executable, unknown

  var isDisc: Bool { self == .gameCube || self == .triforce || self == .wii }
}

/// What the patch flow needs to know about an image.
struct DiscPatchImage: Equatable {
  var gameID: String
  var container: DiscContainer
  var platform: DiscPlatform
  var isNKit: Bool
  /// Size of the plain ISO this image expands to; exact only when `plainSizeIsExact`.
  var plainSize: UInt64
  var plainSizeIsExact: Bool
  /// Size of the file on disk.
  var fileSize: UInt64
}

/// Why an image cannot be patched.
enum DiscPatchRefusal: Equatable {
  case nKit, wad, executable, unsupportedContainer, notADisc

  var message: String {
    switch self {
    case .nKit:
      return L("This is an NKit image. NKit discards parts of the disc, so a patch made for the original disc cannot be applied to it. Use a full ISO or RVZ of the game.")
    case .wad:
      return L("WAD files cannot be patched here. Only GameCube and Wii discs can.")
    case .executable:
      return L("DOL and ELF programs cannot be patched here. Only GameCube and Wii discs can.")
    case .unsupportedContainer:
      return L("This disc image format cannot be patched. Convert it to ISO or RVZ first.")
    case .notADisc:
      return L("This file is not a GameCube or Wii disc.")
    }
  }
}

/// Folders the flow reads and writes, all derived from two roots so the plan can be tested.
struct DiscPatchDirectories: Equatable {
  /// Dolphin's `User/` directory.
  var user: URL
  /// The library folder (`Software/`).
  var software: URL

  var patches: URL { user.appendingPathComponent("Patches", isDirectory: true) }
  var patchWork: URL { user.appendingPathComponent("Cache/PatchWork", isDirectory: true) }
  var patchedDiscs: URL { user.appendingPathComponent("Cache/PatchedDiscs", isDirectory: true) }
  var patchedSoftware: URL { software.appendingPathComponent("Patched", isDirectory: true) }
}

/// Where each file of one run goes.
struct DiscPatchOutputPlan: Equatable {
  /// `PatchEngine` writes here (and renames it from `<patchedImage>.partial` when it is done).
  var patchedImage: URL
  /// The RVZ made from `patchedImage`, when the result has to be compressed.
  var convertedImage: URL?
  /// The finished file.
  var destination: URL
  /// The destination takes the original's place.
  var replacesOriginal: Bool
  /// The original, to delete once `destination` is in place, when it has a different name.
  var originalToRemove: URL?
}

/// A game a patch might be for.
struct DiscPatchCandidate: Equatable, Identifiable {
  var id: String
  var title: String
  var gameID: String
  var plainSize: UInt64
  var plainSizeIsExact: Bool
}

enum DiscPatchPlanner {
  // MARK: - Refusals

  static func refusal(for image: DiscPatchImage) -> DiscPatchRefusal? {
    if image.isNKit { return .nKit }
    switch image.platform {
    case .wiiWAD: return .wad
    case .executable: return .executable
    case .unknown: return .notADisc
    case .gameCube, .triforce, .wii: break
    }
    return image.container == .other ? .unsupportedContainer : nil
  }

  // MARK: - Cache key

  /// Identifies one patched copy: the same source file (by path, size and modification date) patched
  /// with the same patch (by size and digest) under the same options always maps to the same folder.
  static func cacheKey(sourcePath: String, sourceSize: UInt64, sourceModified: TimeInterval,
                       patchSize: UInt64, patchDigest: String, ignoreSourceChecksum: Bool) -> String {
    let material = [sourcePath, String(sourceSize), String(Int64(sourceModified)),
                    String(patchSize), patchDigest, ignoreSourceChecksum ? "forced" : "checked"]
      .joined(separator: "|")
    return SHA256.hash(data: Data(material.utf8)).prefix(keyByteCount).map { String(format: "%02x", $0) }.joined()
  }

  private static let keyByteCount = 8

  // MARK: - Output paths

  static let cachedImageName = "Patched.iso"

  /// Plans the files of one run. `workID` names the temporary files; `exists` answers whether a path is
  /// taken, so a copy never overwrites another.
  static func outputPlan(mode: DiscPatchMode, copyFormat: DiscPatchCopyFormat, source: URL,
                         sourceContainer: DiscContainer, cacheKey: String, copyName: String,
                         workID: String, directories: DiscPatchDirectories,
                         exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> DiscPatchOutputPlan {
    let workISO = directories.patchWork.appendingPathComponent("\(workID).iso")
    switch mode {
    case .thisRun:
      let cached = directories.patchedDiscs.appendingPathComponent(cacheKey, isDirectory: true)
        .appendingPathComponent(cachedImageName)
      return DiscPatchOutputPlan(patchedImage: cached, convertedImage: nil, destination: cached,
                                 replacesOriginal: false, originalToRemove: nil)

    case .saveCopy:
      let destination = uniqueURL(base: copyName, extension: copyFormat.fileExtension,
                                  in: directories.patchedSoftware, exists: exists)
      switch copyFormat {
      case .iso:
        return DiscPatchOutputPlan(patchedImage: destination, convertedImage: nil, destination: destination,
                                   replacesOriginal: false, originalToRemove: nil)
      case .rvz:
        let staged = destination.appendingPathExtension(stagingExtension)
        return DiscPatchOutputPlan(patchedImage: workISO, convertedImage: staged, destination: destination,
                                   replacesOriginal: false, originalToRemove: nil)
      }

    case .replaceOriginal:
      if sourceContainer == .plain {
        return DiscPatchOutputPlan(patchedImage: workISO, convertedImage: nil, destination: source,
                                   replacesOriginal: true, originalToRemove: nil)
      }
      let workRVZ = directories.patchWork.appendingPathComponent("\(workID).rvz")
      let destination = sourceContainer == .rvz
        ? source
        : source.deletingPathExtension().appendingPathExtension("rvz")
      return DiscPatchOutputPlan(patchedImage: workISO, convertedImage: workRVZ, destination: destination,
                                 replacesOriginal: true,
                                 originalToRemove: destination == source ? nil : source)
    }
  }

  /// The suffix of a file that is still being written; the same one imports use, so the launch sweep
  /// recognises it.
  static let stagingExtension = "importing"

  static func uniqueURL(base: String, extension ext: String, in directory: URL, exists: (URL) -> Bool) -> URL {
    let name = sanitizedFileName(base)
    var candidate = directory.appendingPathComponent(name).appendingPathExtension(ext)
    var counter = 2
    while exists(candidate) {
      candidate = directory.appendingPathComponent("\(name) \(counter)").appendingPathExtension(ext)
      counter += 1
    }
    return candidate
  }

  /// A name that is safe as a single path component.
  static func sanitizedFileName(_ name: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    let cleaned = name.components(separatedBy: forbidden)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return cleaned.isEmpty ? "Patched" : cleaned
  }

  /// The replacement happens only when the destination can be named safely: an `.rvz` that already sits
  /// beside a GCZ/WIA/WBFS/CISO original is never overwritten.
  static func replacementBlocker(plan: DiscPatchOutputPlan, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String? {
    guard plan.replacesOriginal, plan.originalToRemove != nil, exists(plan.destination) else { return nil }
    return String(format: L("A file named %@ already exists next to the original. Rename or remove it, then try again."),
                  plan.destination.lastPathComponent)
  }

  // MARK: - Free space

  /// Room kept free on top of the files themselves.
  static let freeSpaceMargin: UInt64 = 256 * 1024 * 1024

  /// What RVZ-compressing the patched disc is expected to take: about the size of the original when that
  /// already is a WIA/RVZ, otherwise half of the plain image.
  static func estimatedRVZSize(of image: DiscPatchImage) -> UInt64 {
    image.container == .rvz || image.container == .wia ? image.fileSize : image.plainSize / 2
  }

  /// Whether the run ends in an RVZ that has to be made from the patched ISO.
  static func writesRVZ(mode: DiscPatchMode, copyFormat: DiscPatchCopyFormat, container: DiscContainer) -> Bool {
    switch mode {
    case .thisRun: return false
    case .saveCopy: return copyFormat == .rvz
    case .replaceOriginal: return container != .plain
    }
  }

  /// The most disk the run needs at one moment. While patching, the plain copy of a compressed source and
  /// the patched ISO coexist; while compressing, the patched ISO and the RVZ do. `targetSize` is the size
  /// the patch declares for its result, when it declares one.
  static func requiredFreeSpace(image: DiscPatchImage, targetSize: UInt64?, mode: DiscPatchMode,
                                copyFormat: DiscPatchCopyFormat) -> UInt64 {
    let plainCopy = image.container == .plain ? 0 : image.plainSize
    let patched = max(image.plainSize, targetSize ?? 0)
    let patching = plainCopy + patched
    guard writesRVZ(mode: mode, copyFormat: copyFormat, container: image.container) else {
      return patching + freeSpaceMargin
    }
    return max(patching, patched + estimatedRVZSize(of: image)) + freeSpaceMargin
  }

  /// nil when `available` covers `required`; otherwise the message, with both numbers.
  static func freeSpaceShortfall(required: UInt64, available: UInt64) -> String? {
    guard available < required else { return nil }
    return String(format: L("Patching needs about %@ of free space, but only %@ is available. Free up space and try again."),
                  byteString(required), byteString(available))
  }

  static func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
  }

  // MARK: - Which game is this patch for

  /// Orders `candidates` so the likeliest game comes first: a plain size equal to the one the patch
  /// declares beats everything, then the game the caller suggested, then a disc large enough for an
  /// xdelta patch's lower bound. Ties keep their order.
  static func rankTargets(_ candidates: [DiscPatchCandidate], declaredSourceSize: UInt64?,
                          minimumSourceSize: UInt64?, suggestedGameID: String?) -> [DiscPatchCandidate] {
    func score(_ candidate: DiscPatchCandidate) -> Int {
      var total = 0
      if let declared = declaredSourceSize, candidate.plainSizeIsExact, candidate.plainSize == declared { total += 4 }
      if let suggested = suggestedGameID, !suggested.isEmpty, candidate.gameID == suggested { total += 2 }
      if let minimum = minimumSourceSize, candidate.plainSize >= minimum { total += 1 }
      return total
    }
    return candidates.enumerated()
      .sorted { lhs, rhs in
        let (left, right) = (score(lhs.element), score(rhs.element))
        return left == right ? lhs.offset < rhs.offset : left > right
      }
      .map(\.element)
  }

  /// Patch file extensions the flow accepts, lowercase and without the dot.
  static let patchExtensions: [String] = PatchFormat.allFileExtensions

  static func isPatchFile(_ url: URL) -> Bool {
    patchExtensions.contains(url.pathExtension.lowercased())
  }
}
