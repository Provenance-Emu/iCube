// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVPatchEngine
import UIKit

/// State of the "Apply Patch" sheet: which patch, which game, which mode, and the job itself.
@MainActor
final class DiscPatchModel: ObservableObject {
  enum RunState: Equatable {
    case idle
    case running(DiscPatchProgress)
    case succeeded(String)
    case failed(message: String, canApplyAnyway: Bool)
  }

  @Published private(set) var availablePatches: [URL] = []
  @Published private(set) var selectedPatch: URL?
  @Published private(set) var patchInfo: PatchInfo?
  @Published private(set) var patchProblem: String?
  @Published private(set) var candidates: [DiscPatchCandidate] = []
  @Published private(set) var likelyIDs: Set<String> = []
  @Published private(set) var selectedGameID: String?
  @Published var mode: DiscPatchMode = .thisRun
  @Published var copyFormat: DiscPatchCopyFormat = .rvz
  @Published private(set) var ignoreSourceChecksum = false
  @Published private(set) var state: RunState = .idle

  /// Set by the presenter; closes the sheet.
  var dismiss: () -> Void = {}

  private let directories: DiscPatchDirectories
  private let service: DiscPatchService
  private let suggestedGameID: String?
  private var sourcePaths: [String: URL] = [:]
  private var task: Task<Void, Never>?
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid

  init(patchURLs: [URL], suggestedGameID: String?, directories: DiscPatchDirectories) {
    self.directories = directories
    self.service = DiscPatchService(directories: directories)
    self.suggestedGameID = suggestedGameID
    loadCandidates()
    availablePatches = Self.merged(patchURLs, DiscPatchStore.availablePatches(directories: directories))
    if patchURLs.count == 1, let only = patchURLs.first { choosePatch(only) }
  }

  // MARK: - Derived

  var isRunning: Bool {
    if case .running = state { return true }
    return false
  }

  var selectedGame: DiscPatchCandidate? {
    candidates.first { $0.id == selectedGameID }
  }

  var canStart: Bool {
    selectedPatch != nil && patchProblem == nil && selectedGame != nil && !isRunning
  }

  // MARK: - Choosing

  /// A patch picked from a document picker: stored in `Patches/`, then inspected.
  func importPatch(from url: URL) {
    do {
      choosePatch(try DiscPatchStore.importPatch(from: url, directories: directories))
    } catch {
      patchProblem = error.localizedDescription
    }
  }

  func choosePatch(_ url: URL) {
    selectedPatch = url
    ignoreSourceChecksum = false
    state = .idle
    do {
      let info = try PatchEngine.inspect(patch: url)
      patchInfo = info
      patchProblem = nil
      rank(for: info)
    } catch {
      patchInfo = nil
      patchProblem = (error as? PatchError).map { DiscPatchError.patch($0).localizedDescription } ?? error.localizedDescription
    }
  }

  func clearPatch() {
    selectedPatch = nil
    patchInfo = nil
    patchProblem = nil
    ignoreSourceChecksum = false
    state = .idle
  }

  func chooseGame(_ id: String) {
    selectedGameID = id
    ignoreSourceChecksum = false
    state = .idle
  }

  private func loadCandidates() {
    var found: [DiscPatchCandidate] = []
    for item in TVLibraryBridge.currentGames() where !item.isDemoItem && item.filePath.hasPrefix("/") {
      guard let info = DiscImageBridge.info(forGameItem: item),
            DiscPatchPlanner.refusal(for: DiscPatchImage(info)) == nil else { continue }
      sourcePaths[item.filePath] = URL(fileURLWithPath: item.filePath)
      found.append(DiscPatchCandidate(id: item.filePath, title: item.title.isEmpty ? URL(fileURLWithPath: item.filePath).lastPathComponent : item.title,
                                      gameID: item.gameID, plainSize: info.plainSize, plainSizeIsExact: info.plainSizeIsExact))
    }
    candidates = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    if let suggestedGameID, let match = candidates.first(where: { $0.gameID == suggestedGameID }) {
      selectedGameID = match.id
    }
  }

  /// Puts the likeliest game first and selects it when nothing was chosen yet.
  private func rank(for info: PatchInfo) {
    candidates = DiscPatchPlanner.rankTargets(candidates, declaredSourceSize: info.sourceSize,
                                              minimumSourceSize: info.minimumSourceSize, suggestedGameID: suggestedGameID)
    likelyIDs = Set(candidates.filter { candidate in
      guard let declared = info.sourceSize else { return false }
      return candidate.plainSizeIsExact && candidate.plainSize == declared
    }.map(\.id))
    if selectedGameID == nil {
      selectedGameID = candidates.first(where: { likelyIDs.contains($0.id) })?.id
    }
  }

  private static func merged(_ first: [URL], _ second: [URL]) -> [URL] {
    var seen = Set<String>()
    return (first + second).filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  // MARK: - Running

  func start() {
    guard canStart, let patch = selectedPatch, let game = selectedGame, let source = sourcePaths[game.id] else { return }
    let request = DiscPatchRequest(
      source: source, patch: patch, mode: mode, copyFormat: copyFormat,
      ignoreSourceChecksum: ignoreSourceChecksum,
      copyName: "\(source.deletingPathExtension().lastPathComponent) (\(patch.deletingPathExtension().lastPathComponent))")
    state = .running(DiscPatchProgress(phase: .preparing, fraction: 0))
    beginBackgroundTask()
    task = Task { [service] in
      do {
        let outcome = try await service.run(request) { [weak self] progress in
          Task { @MainActor in self?.update(progress) }
        }
        self.finish(outcome)
      } catch {
        self.fail(error)
      }
    }
  }

  func cancel() {
    task?.cancel()
  }

  /// "Apply anyway" after a source mismatch. Replacing the original is never offered for it.
  func applyAnyway() {
    ignoreSourceChecksum = true
    if mode == .replaceOriginal { mode = .saveCopy }
    start()
  }

  /// Called when the sheet goes away.
  func teardown() {
    task?.cancel()
    service.discardWork()
  }

  private func update(_ progress: DiscPatchProgress) {
    guard isRunning else { return }
    state = .running(progress)
  }

  private func finish(_ outcome: DiscPatchOutcome) {
    endBackgroundTask()
    service.discardWork()
    switch outcome.mode {
    case .thisRun:
      state = .idle
      dismiss()
      DiscPatchFlow.launch(path: outcome.result.path)
    case .saveCopy:
      announceLibraryChange(L("Saved a patched copy to your library."))
      state = .succeeded(withWarning(String(format: L("Saved %@ to your library as its own game."), outcome.result.lastPathComponent), outcome))
    case .replaceOriginal:
      announceLibraryChange(L("Replaced the original disc with the patched one."))
      state = .succeeded(String(format: L("Replaced %@ with the patched disc."), outcome.result.lastPathComponent))
    }
  }

  private func withWarning(_ message: String, _ outcome: DiscPatchOutcome) -> String {
    outcome.targetMismatch
      ? message + "\n\n" + L("The result does not match what the patch describes, as expected for a different disc. It may not work.")
      : message
  }

  private func fail(_ error: Error) {
    endBackgroundTask()
    if error is CancellationError { state = .idle; return }
    if let patchError = error as? DiscPatchError {
      if case .cancelled = patchError { state = .idle; return }
      state = .failed(message: patchError.localizedDescription, canApplyAnyway: patchError.allowsApplyAnyway)
      return
    }
    state = .failed(message: error.localizedDescription, canApplyAnyway: false)
  }

  private func announceLibraryChange(_ snackbar: String) {
    NotificationCenter.default.post(name: NSNotification.Name("DOLImportFileFinishedNotification"), object: nil)
    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": snackbar])
  }

  // MARK: - Background time

  /// Keeps the job going for the few minutes iOS grants after the app is left. When that runs out the
  /// job is cancelled (which cleans its files) and the task is ended in the same breath, as iOS requires.
  private func beginBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "iCube.discpatch") { [weak self] in
      MainActor.assumeIsolated {
        self?.task?.cancel()
        self?.endBackgroundTask()
      }
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }
}
