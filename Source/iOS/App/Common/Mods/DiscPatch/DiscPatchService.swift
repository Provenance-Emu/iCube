// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVPatchEngine

/// One patching job.
struct DiscPatchRequest {
  var source: URL
  var patch: URL
  var mode: DiscPatchMode
  var copyFormat: DiscPatchCopyFormat
  /// Apply although the patch says it was made for another disc. Never combined with `.replaceOriginal`.
  var ignoreSourceChecksum: Bool
  /// File name (without extension) for `.saveCopy`.
  var copyName: String
}

enum DiscPatchPhase: Equatable {
  case preparing, expanding, patching, compressing, finishing
}

struct DiscPatchProgress: Equatable {
  var phase: DiscPatchPhase
  /// 0...1 over the whole job.
  var fraction: Double
}

/// What a finished job produced.
struct DiscPatchOutcome: Equatable {
  var mode: DiscPatchMode
  /// The patched disc: the cached copy, the saved copy, or the replaced original.
  var result: URL
  /// The result differs from what the patch describes (only possible when the source check was skipped).
  var targetMismatch: Bool
}

enum DiscPatchError: Error, LocalizedError {
  case refused(DiscPatchRefusal)
  case unreadableImage
  case wrongSourceSize(expected: UInt64, actual: UInt64)
  case insufficientSpace(String)
  case patch(PatchError)
  case conversionFailed(String)
  case gameRunning
  case blocked(String)
  case verificationFailed
  case cancelled
  case io(Error)

  /// "Apply anyway" is offered for these.
  var allowsApplyAnyway: Bool {
    switch self {
    case .wrongSourceSize: return true
    case .patch(let error):
      switch error {
      case .sourceMismatch, .sourceSizeMismatch: return true
      default: return false
      }
    default: return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .refused(let refusal):
      return refusal.message
    case .unreadableImage:
      return L("The disc image could not be opened. It may be damaged or incomplete.")
    case let .wrongSourceSize(expected, actual):
      return String(format: L("This patch was made for a disc of %@, but this one is %@. It is probably for a different game or version."),
                    DiscPatchPlanner.byteString(expected), DiscPatchPlanner.byteString(actual))
    case .insufficientSpace(let message), .conversionFailed(let message), .blocked(let message):
      return message
    case .patch(let error):
      return Self.describe(error)
    case .gameRunning:
      return L("A game is running. Quit it before replacing a disc file.")
    case .verificationFailed:
      return L("The patched disc could not be verified, so the original was left untouched.")
    case .cancelled:
      return L("Patching was cancelled.")
    case .io(let error):
      return error.localizedDescription
    }
  }

  private static func describe(_ error: PatchError) -> String {
    switch error {
    case .sourceMismatch:
      return L("This patch is not for this disc, or the patch file is damaged. Check that you chose the right game and version.")
    case .sourceSizeMismatch(let expected, let actual):
      return String(format: L("This patch was made for a disc of %@, but this one is %@. It is probably for a different game or version."),
                    DiscPatchPlanner.byteString(expected), DiscPatchPlanner.byteString(actual))
    case .unsupportedSecondaryCompression:
      return L("This xdelta patch uses LZMA compression, which iCube cannot read. Ask the author for a patch made without LZMA (xdelta3 -S none), or for a BPS or IPS patch.")
    case .unsupportedFormat:
      return L("This is not a patch file iCube understands. It reads xdelta, BPS, IPS, UPS and PPF patches.")
    case .outputTooLarge:
      return L("The patched disc would be larger than iCube allows.")
    case .truncatedPatch, .corruptPatch:
      return L("The patch file is incomplete or damaged. Download it again.")
    case .targetMismatch:
      return L("The patched disc failed the patch's own checksum, so it was discarded.")
    case .cancelled:
      return L("Patching was cancelled.")
    case .io(let underlying):
      return underlying.localizedDescription
    }
  }
}

/// Patches a disc: expands it when needed, applies the patch and delivers the result for a mode.
/// Runs off the main thread; cancel by cancelling the calling task. One job at a time per instance.
///
/// "Replace original" containers: a plain ISO is replaced by a plain ISO; an RVZ by an RVZ under the
/// same name. GCZ, WIA, WBFS and CISO cannot be written back by DiscIO (only ISO, GCZ and WIA/RVZ can
/// be made, and GCZ/WIA are superseded by RVZ), so they are replaced by an RVZ with the same base
/// name next to the original, and the original is deleted once the new file is verified.
final class DiscPatchService: @unchecked Sendable {
  private let directories: DiscPatchDirectories
  private let lock = NSLock()
  private var retainedExpansion: (source: URL, expanded: URL)?

  init(directories: DiscPatchDirectories) {
    self.directories = directories
  }

  /// Deletes the expanded copy kept for an "Apply anyway" retry. Call when the sheet closes.
  func discardWork() {
    let kept = lock.withLock { () -> (source: URL, expanded: URL)? in
      defer { retainedExpansion = nil }
      return retainedExpansion
    }
    if let kept { try? FileManager.default.removeItem(at: kept.expanded) }
  }

  // MARK: - Job

  func run(_ request: DiscPatchRequest,
           progress report: @escaping @Sendable (DiscPatchProgress) -> Void) async throws -> DiscPatchOutcome {
    if request.mode == .replaceOriginal {
      guard !request.ignoreSourceChecksum else {
        throw DiscPatchError.blocked(L("The original is only replaced by a patch that was checked against it. Save a copy instead."))
      }
      guard !TVEmulationBridge.isRunning() else { throw DiscPatchError.gameRunning }
    }
    try Task.checkCancellation()
    report(DiscPatchProgress(phase: .preparing, fraction: 0))

    let image = try await Self.inspectImage(at: request.source)
    if let refusal = DiscPatchPlanner.refusal(for: image) { throw DiscPatchError.refused(refusal) }
    let patchInfo: PatchInfo
    do { patchInfo = try PatchEngine.inspect(patch: request.patch) } catch { throw Self.map(error) }
    if patchInfo.format == .xdelta3, Self.usesUnsupportedCompression(request.patch) {
      throw DiscPatchError.patch(.unsupportedSecondaryCompression)
    }

    if !request.ignoreSourceChecksum, let declared = patchInfo.sourceSize, image.plainSizeIsExact, declared != image.plainSize {
      throw DiscPatchError.wrongSourceSize(expected: declared, actual: image.plainSize)
    }

    let key = try Self.cacheKey(for: request, patchInfo: patchInfo)
    if request.mode == .thisRun, let cached = Self.cachedCopy(directories: directories, key: key) {
      report(DiscPatchProgress(phase: .finishing, fraction: 1))
      return DiscPatchOutcome(mode: .thisRun, result: cached, targetMismatch: false)
    }

    try prepareDirectories()
    let plan = DiscPatchPlanner.outputPlan(
      mode: request.mode, copyFormat: request.copyFormat, source: request.source,
      sourceContainer: image.container, cacheKey: key, copyName: request.copyName,
      workID: UUID().uuidString, directories: directories)
    if let blocker = DiscPatchPlanner.replacementBlocker(plan: plan) { throw DiscPatchError.blocked(blocker) }
    try checkFreeSpace(image: image, targetSize: patchInfo.targetSize, request: request)

    let writesRVZ = plan.convertedImage != nil
    let needsExpansion = image.container != .plain
    let weights = ProgressWeights(expanding: needsExpansion, compressing: writesRVZ)
    var temporaries: [URL] = [plan.patchedImage]
    if let converted = plan.convertedImage { temporaries.append(converted) }

    do {
      let plainSource: URL
      if needsExpansion {
        plainSource = try await expansion(of: request.source, report: { report(weights.progress(.expanding, $0)) })
      } else {
        plainSource = request.source
      }

      try FileManager.default.createDirectory(at: plan.patchedImage.deletingLastPathComponent(), withIntermediateDirectories: true)
      let result: PatchResult
      do {
        result = try await PatchEngine.apply(
          patch: request.patch, source: plainSource, output: plan.patchedImage,
          options: PatchOptions(ignoreSourceChecksum: request.ignoreSourceChecksum),
          progress: { report(weights.progress(.patching, $0.fractionCompleted)) })
      } catch {
        let mapped = Self.map(error)
        if !mapped.allowsApplyAnyway || !needsExpansion { discardWork() }
        throw mapped
      }
      if needsExpansion { discardWork() }

      let targetMismatch = result.ignoredTargetMismatch != nil
      let outcome = try await deliver(plan: plan, request: request, image: image, key: key,
                                      targetSize: patchInfo.targetSize, targetMismatch: targetMismatch, weights: weights, report: report)
      temporaries.removeAll { $0 == plan.destination }
      Self.remove(temporaries)
      report(DiscPatchProgress(phase: .finishing, fraction: 1))
      return outcome
    } catch {
      Self.remove(temporaries)
      if request.mode == .thisRun { Self.removeIfEmpty(plan.destination.deletingLastPathComponent()) }
      if error is CancellationError { throw DiscPatchError.cancelled }
      throw error
    }
  }

  // MARK: - Delivering the result

  private func deliver(plan: DiscPatchOutputPlan, request: DiscPatchRequest, image: DiscPatchImage, key: String,
                       targetSize: UInt64?, targetMismatch: Bool, weights: ProgressWeights,
                       report: @escaping @Sendable (DiscPatchProgress) -> Void) async throws -> DiscPatchOutcome {
    let fileManager = FileManager.default
    var staged = plan.patchedImage
    if let converted = plan.convertedImage {
      try await Self.convert(.rvz, from: plan.patchedImage, to: converted,
                             report: { report(weights.progress(.compressing, $0)) })
      staged = converted
    }

    switch request.mode {
    case .thisRun:
      Self.pruneCache(directories: directories, keeping: key)
      return DiscPatchOutcome(mode: .thisRun, result: plan.destination, targetMismatch: targetMismatch)

    case .saveCopy:
      if staged != plan.destination {
        do { try fileManager.moveItem(at: staged, to: plan.destination) } catch { throw DiscPatchError.io(error) }
      }
      return DiscPatchOutcome(mode: .saveCopy, result: plan.destination, targetMismatch: targetMismatch)

    case .replaceOriginal:
      guard !targetMismatch else {
        throw DiscPatchError.blocked(L("The patched disc does not match what the patch describes, so the original was not replaced. Save a copy instead."))
      }
      try await Self.verify(staged, expectedContainer: plan.convertedImage == nil ? .plain : .rvz,
                            original: image, targetSize: targetSize)
      do {
        if plan.destination == request.source {
          _ = try fileManager.replaceItemAt(request.source, withItemAt: staged)
        } else {
          try fileManager.moveItem(at: staged, to: plan.destination)
          if let original = plan.originalToRemove { try fileManager.removeItem(at: original) }
        }
      } catch {
        throw DiscPatchError.io(error)
      }
      return DiscPatchOutcome(mode: .replaceOriginal, result: plan.destination, targetMismatch: false)
    }
  }

  /// The replacement is only trusted once DiscIO reads it back as a disc of the same platform and the
  /// expected container, and, when the patch declares its result size, of that size.
  private static func verify(_ url: URL, expectedContainer: DiscContainer, original: DiscPatchImage,
                             targetSize: UInt64?) async throws {
    let patched = try await inspectImage(at: url)
    let sizeMatches = targetSize.map { !patched.plainSizeIsExact || patched.plainSize == $0 } ?? true
    guard patched.platform == original.platform, patched.container == expectedContainer,
          !patched.isNKit, sizeMatches else { throw DiscPatchError.verificationFailed }
  }

  // MARK: - Expansion

  /// A plain ISO of `source`. A copy kept from an earlier attempt at the same source is reused, so
  /// "Apply anyway" does not expand the disc a second time.
  private func expansion(of source: URL, report: @escaping @Sendable (Double) -> Void) async throws -> URL {
    let kept = lock.withLock { retainedExpansion }
    if let kept, kept.source == source, FileManager.default.fileExists(atPath: kept.expanded.path) {
      report(1)
      return kept.expanded
    }
    discardWork()

    let expanded = directories.patchWork.appendingPathComponent("\(UUID().uuidString)-source.iso")
    do {
      try await Self.convert(.plain, from: source, to: expanded, report: report)
    } catch {
      try? FileManager.default.removeItem(at: expanded)
      throw error
    }
    lock.withLock { retainedExpansion = (source, expanded) }
    return expanded
  }

  private enum Conversion { case plain, rvz }

  private static func convert(_ kind: Conversion, from source: URL, to destination: URL,
                              report: @escaping @Sendable (Double) -> Void) async throws {
    let token = DOLDiscConversionToken()
    try await withTaskCancellationHandler {
      try await Task.detached(priority: .userInitiated) {
        do {
          switch kind {
          case .plain:
            try DiscImageBridge.convertToPlain(from: source.path, to: destination.path, token: token, progress: { report($0) })
          case .rvz:
            try DiscImageBridge.convertToRVZ(from: source.path, to: destination.path, token: token, progress: { report($0) })
          }
        } catch {
          if token.isCancelled { throw DiscPatchError.cancelled }
          throw DiscPatchError.conversionFailed(error.localizedDescription)
        }
      }.value
    } onCancel: {
      token.cancel()
    }
  }

  // MARK: - Checks

  private func checkFreeSpace(image: DiscPatchImage, targetSize: UInt64?, request: DiscPatchRequest) throws {
    let required = DiscPatchPlanner.requiredFreeSpace(image: image, targetSize: targetSize,
                                                      mode: request.mode, copyFormat: request.copyFormat)
    guard let available = Self.availableCapacity(at: directories.user) else { return }
    if let message = DiscPatchPlanner.freeSpaceShortfall(required: required, available: available) {
      throw DiscPatchError.insufficientSpace(message)
    }
  }

  /// Bytes the app may still write on the volume holding `url`. iOS counts space it could reclaim from
  /// purgeable caches; tvOS has no such figure.
  static func availableCapacity(at url: URL) -> UInt64? {
    #if os(iOS)
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(clamping: $0) }
    #else
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
    return values?.volumeAvailableCapacity.map { UInt64(clamping: $0) }
    #endif
  }

  // MARK: - Files

  /// Creates the work folders. Work files and cached discs are gigabytes and rebuildable, so they stay
  /// out of device backups.
  private func prepareDirectories() throws {
    let fileManager = FileManager.default
    do {
      for folder in [directories.patchWork, directories.patchedDiscs] {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
      }
      try fileManager.createDirectory(at: directories.patches, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: directories.patchedSoftware, withIntermediateDirectories: true)
    } catch {
      throw DiscPatchError.io(error)
    }
  }

  private static func cacheKey(for request: DiscPatchRequest, patchInfo: PatchInfo) throws -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: request.source.path)
    let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return DiscPatchPlanner.cacheKey(
      sourcePath: request.source.path, sourceSize: size, sourceModified: modified,
      patchSize: patchInfo.patchSize, patchDigest: try sha256(of: request.patch),
      ignoreSourceChecksum: request.ignoreSourceChecksum)
  }

  private static func usesUnsupportedCompression(_ patch: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: patch) else { return false }
    defer { try? handle.close() }
    let header = (try? handle.read(upToCount: DiscPatchPlanner.vcdiffHeaderProbeLength)) ?? Data()
    return DiscPatchPlanner.xdeltaNeedsUnsupportedCompression(header: [UInt8](header))
  }

  private static let digestChunk = 1 << 20

  static func sha256(of url: URL) throws -> String {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hasher = SHA256()
      while let chunk = try handle.read(upToCount: digestChunk), !chunk.isEmpty { hasher.update(data: chunk) }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      throw DiscPatchError.io(error)
    }
  }

  /// The cached patched disc for `key`, if a complete one exists. Using it makes it the newest.
  static func cachedCopy(directories: DiscPatchDirectories, key: String) -> URL? {
    let file = directories.patchedDiscs.appendingPathComponent(key, isDirectory: true)
      .appendingPathComponent(DiscPatchPlanner.cachedImageName)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    return file
  }

  /// Keeps only the most recent cached disc.
  private static func pruneCache(directories: DiscPatchDirectories, keeping key: String) {
    let fileManager = FileManager.default
    let names = (try? fileManager.contentsOfDirectory(atPath: directories.patchedDiscs.path)) ?? []
    for name in names where name != key {
      try? fileManager.removeItem(at: directories.patchedDiscs.appendingPathComponent(name))
    }
  }

  /// Removes leftovers of an interrupted job. Call at launch, before anything can be patching.
  static func sweepWork(directories: DiscPatchDirectories) {
    let fileManager = FileManager.default
    for name in (try? fileManager.contentsOfDirectory(atPath: directories.patchWork.path)) ?? [] {
      try? fileManager.removeItem(at: directories.patchWork.appendingPathComponent(name))
    }
    let stagedSuffix = "." + DiscPatchPlanner.stagingExtension
    for folder in [directories.patchedSoftware, directories.patchedDiscs] {
      guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
      for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(stagedSuffix)
        || url.lastPathComponent.hasSuffix(".partial") {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  private static func remove(_ urls: [URL]) {
    for url in urls { try? FileManager.default.removeItem(at: url) }
  }

  private static func removeIfEmpty(_ folder: URL) {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    if contents.isEmpty { try? FileManager.default.removeItem(at: folder) }
  }

  private static func inspectImage(at url: URL) async throws -> DiscPatchImage {
    try await Task.detached(priority: .userInitiated) {
      guard let info = DiscImageBridge.inspectImage(atPath: url.path) else { throw DiscPatchError.unreadableImage }
      return DiscPatchImage(info)
    }.value
  }

  private static func map(_ error: Error) -> DiscPatchError {
    switch error {
    case let patch as PatchError:
      if case .cancelled = patch { return .cancelled }
      return .patch(patch)
    case is CancellationError:
      return .cancelled
    case let service as DiscPatchError:
      return service
    default:
      return .io(error)
    }
  }
}

extension DiscPatchImage {
  init(_ info: DOLDiscImageInfo) {
    self.init(
      gameID: info.gameID,
      container: DiscContainer(info.container),
      platform: DiscPlatform(info.platform),
      isNKit: info.isNKit,
      plainSize: info.plainSize,
      plainSizeIsExact: info.plainSizeIsExact,
      fileSize: info.fileSize)
  }
}

extension DiscContainer {
  init(_ container: DOLDiscContainer) {
    switch container {
    case .plain: self = .plain
    case .RVZ: self = .rvz
    case .WIA: self = .wia
    case .GCZ: self = .gcz
    case .WBFS: self = .wbfs
    case .CISO: self = .ciso
    case .other: self = .other
    @unknown default: self = .other
    }
  }
}

extension DiscPlatform {
  init(_ platform: DOLDiscPlatform) {
    switch platform {
    case .gameCube: self = .gameCube
    case .triforce: self = .triforce
    case .wii: self = .wii
    case .wiiWAD: self = .wiiWAD
    case .executable: self = .executable
    case .unknown: self = .unknown
    @unknown default: self = .unknown
    }
  }
}

/// Splits the job's 0...1 into phases. Compressing is the slowest step per byte, so it weighs double.
private struct ProgressWeights: Sendable {
  private static let expandingWeight = 1.0
  private static let patchingWeight = 1.0
  private static let compressingWeight = 2.0

  let expanding: Bool
  let compressing: Bool

  func progress(_ phase: DiscPatchPhase, _ fraction: Double) -> DiscPatchProgress {
    let weights: [(DiscPatchPhase, Double)] = [
      (.expanding, expanding ? Self.expandingWeight : 0),
      (.patching, Self.patchingWeight),
      (.compressing, compressing ? Self.compressingWeight : 0),
    ]
    let total = weights.reduce(0) { $0 + $1.1 }
    var done = 0.0
    for (candidate, weight) in weights {
      if candidate == phase {
        return DiscPatchProgress(phase: phase, fraction: min(1, (done + weight * min(max(fraction, 0), 1)) / total))
      }
      done += weight
    }
    return DiscPatchProgress(phase: phase, fraction: 1)
  }
}

/// Launch-time cleanup of disc patching work files, called from `DolphinCoreService` next to the
/// import-staging sweep (and, unlike that one, on tvOS as well).
@objc(DOLDiscPatchSweep)
final class DiscPatchLaunchSweep: NSObject {
  @objc static func sweep() {
    guard let directories = DiscPatchDirectories.live else { return }
    DiscPatchService.sweepWork(directories: directories)
  }
}
