// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVPatchEngine
import SwiftUI
import UniformTypeIdentifiers

/// The "Apply Patch" sheet. Everything is rows and buttons: `Menu` and `Picker` have no usable
/// presentation on tvOS, and tvOS has no document picker, so a patch is chosen from the files already
/// on the device (`<User>/Patches/`) there.
struct DiscPatchSheet: View {
  @ObservedObject var model: DiscPatchModel
  @State private var showingGames = false
  @State private var confirmingReplace = false
  #if os(iOS)
  @State private var showingFilePicker = false
  #endif

  var body: some View {
    NavigationStack {
      List {
        switch model.state {
        case .running(let progress):
          runningSection(progress)
        case .succeeded(let message):
          succeededSection(message)
        case .idle, .failed:
          patchSection
          if model.selectedPatch != nil, model.patchProblem == nil {
            gameSection
            modeSection
            if case .failed(let message, let canApplyAnyway) = model.state {
              failureSection(message, canApplyAnyway: canApplyAnyway)
            }
            actionSection
          }
        }
        TVStorageNoteSection()
      }
      .navigationTitle(L("Apply Patch"))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if !model.isRunning { Button(L("Close")) { model.dismiss() } }
        }
      }
      #if os(iOS)
      .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: Self.patchTypes) { result in
        if case .success(let url) = result { model.importPatch(from: url) }
      }
      #endif
      .alert(L("Replace the original?"), isPresented: $confirmingReplace) {
        Button(L("Replace"), role: .destructive) { model.start() }
        Button(L("Cancel"), role: .cancel) {}
      } message: {
        Text(L("The original disc file will be overwritten with the patched one. This cannot be undone."))
      }
    }
    .claimsController()
    .interactiveDismissDisabled(model.isRunning)
    .onDisappear { model.teardown() }
  }

  // MARK: - Patch

  @ViewBuilder
  private var patchSection: some View {
    if let patch = model.selectedPatch {
      Section(L("Patch")) {
        Text(patch.lastPathComponent)
        if let problem = model.patchProblem {
          Text(problem).foregroundStyle(.red)
        } else if let info = model.patchInfo {
          patchDetails(info)
        }
        Button(L("Choose a Different Patch")) { model.clearPatch() }
      }
    } else {
      Section {
        ForEach(model.availablePatches, id: \.self) { url in
          Button { model.choosePatch(url) } label: {
            Label(url.lastPathComponent, systemImage: "doc")
          }
        }
        #if os(iOS)
        Button { showingFilePicker = true } label: {
          Label(L("Choose File…"), systemImage: "folder")
        }
        #endif
        if let problem = model.patchProblem { Text(problem).foregroundStyle(.red) }
      } header: {
        Text(L("Choose a Patch"))
      } footer: {
        Text(Self.chooseFooter)
      }
    }
  }

  private static var chooseFooter: String {
    #if os(iOS)
    return L("iCube reads xdelta, BPS, IPS, UPS and PPF patches. A patch you choose is kept in the Patches folder.")
    #else
    return L("iCube reads xdelta, BPS, IPS, UPS and PPF patches. To add one, upload it from a computer with the web server, or from the Patches folder.")
    #endif
  }

  @ViewBuilder
  private func patchDetails(_ info: PatchInfo) -> some View {
    LabeledContent(L("Format"), value: info.format.displayName)
    LabeledContent(L("Patch size"), value: DiscPatchPlanner.byteString(info.patchSize))
    if let size = info.sourceSize {
      LabeledContent(L("Made for a disc of"), value: DiscPatchPlanner.byteString(size))
    }
    if let crc = info.sourceCRC32 {
      LabeledContent(L("Disc checksum"), value: String(format: "%08X", crc))
    }
    if let size = info.targetSize {
      LabeledContent(L("Produces a disc of"), value: DiscPatchPlanner.byteString(size))
    }
    if let description = info.description {
      Text(description).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
    }
  }

  // MARK: - Game

  @ViewBuilder
  private var gameSection: some View {
    Section {
      if let game = model.selectedGame, !showingGames {
        VStack(alignment: .leading, spacing: 4) {
          Text(game.title)
          Text(game.gameID).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
        }
        Button(L("Choose a Different Game")) { showingGames = true }
      } else if model.candidates.isEmpty {
        Text(L("There are no GameCube or Wii discs in your library that can be patched."))
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.candidates) { candidate in
          Button {
            model.chooseGame(candidate.id)
            showingGames = false
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title)
                if model.likelyIDs.contains(candidate.id) {
                  Text(L("Likely match")).icubeText(.detail).foregroundStyle(.green)
                }
              }
              Spacer()
              if candidate.id == model.selectedGameID { Image(systemName: "checkmark") }
            }
          }
        }
      }
    } header: {
      Text(L("Game"))
    } footer: {
      if model.selectedGame == nil, !model.candidates.isEmpty { Text(L("Which game is this patch for?")) }
    }
  }

  // MARK: - Mode

  private var modeSection: some View {
    Section {
      modeRow(.thisRun, title: L("Play with the Patch"),
              detail: L("Patches a temporary copy and starts it. The next play of the same patch starts at once. Your original is not touched."))
      modeRow(.saveCopy, title: L("Save a Patched Copy"),
              detail: L("Adds the patched game to your library as its own game. The original stays as it is."))
      if model.mode == .saveCopy {
        ForEach(DiscPatchCopyFormat.allCases) { format in
          Button { model.copyFormat = format } label: {
            HStack {
              Text(format == .rvz ? L("RVZ (smaller, recommended)") : L("ISO (larger, plain)"))
              Spacer()
              if model.copyFormat == format { Image(systemName: "checkmark") }
            }
          }
          .padding(.leading)
        }
      }
      modeRow(.replaceOriginal, title: L("Replace the Original"),
              detail: model.canReplaceOriginal
                ? L("Overwrites your disc file with the patched one. This cannot be undone.")
                : DiscPatchPlanner.unverifiedReplacementMessage,
              destructive: true, enabled: model.canReplaceOriginal)
    } header: {
      Text(L("What to do"))
    }
  }

  private func modeRow(_ mode: DiscPatchMode, title: String, detail: String, destructive: Bool = false, enabled: Bool = true) -> some View {
    Button { model.mode = mode } label: {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).foregroundStyle(destructive ? .red : .primary)
          Text(detail).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
        }
        Spacer()
        if model.mode == mode { Image(systemName: "checkmark") }
      }
    }
    .disabled(!enabled)
  }

  // MARK: - Actions and states

  @ViewBuilder
  private var actionSection: some View {
    Section {
      Button(actionTitle) {
        if model.mode == .replaceOriginal { confirmingReplace = true } else { model.start() }
      }
      .disabled(!model.canStart)
    }
  }

  private var actionTitle: String {
    switch model.mode {
    case .thisRun: return L("Patch and Play")
    case .saveCopy: return L("Save Patched Copy")
    case .replaceOriginal: return L("Replace Original…")
    }
  }

  private func failureSection(_ message: String, canApplyAnyway: Bool) -> some View {
    Section {
      Text(message).foregroundStyle(.red)
      if canApplyAnyway {
        Button(L("Apply Anyway")) { model.applyAnyway() }
      }
    } footer: {
      if canApplyAnyway {
        Text(L("Applying anyway skips the check that the disc is the one the patch was made for. The result may not work, so the original cannot be replaced this way."))
      }
    }
  }

  private func runningSection(_ progress: DiscPatchProgress) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        Text(Self.phaseTitle(progress.phase))
        ProgressView(value: progress.fraction)
        Text(String(format: "%d%%", Int(progress.fraction * 100))).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
      }
      Button(L("Cancel"), role: .cancel) { model.cancel() }
    } footer: {
      Text(L("This can take several minutes for a large disc. Keep iCube open."))
    }
  }

  private func succeededSection(_ message: String) -> some View {
    Section {
      Text(message)
      Button(L("Done")) { model.dismiss() }
    }
  }

  private static func phaseTitle(_ phase: DiscPatchPhase) -> String {
    switch phase {
    case .preparing: return L("Checking the disc and patch…")
    case .expanding: return L("Unpacking the disc image…")
    case .patching: return L("Applying the patch…")
    case .compressing: return L("Compressing the patched disc…")
    case .finishing: return L("Finishing…")
    }
  }

  #if os(iOS)
  /// Dynamic types for extensions the system does not know still enable those files in the picker.
  private static let patchTypes: [UTType] = DiscPatchPlanner.patchExtensions.compactMap { UTType(filenameExtension: $0) }
  #endif
}
