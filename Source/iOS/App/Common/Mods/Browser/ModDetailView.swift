// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One mod: description, credits, licence and its files.
struct ModDetailView: View {
  let summary: GameBananaModSummary
  let entry: ModGameTable.Entry
  let ownedGame: ModLibraryGame?
  let handler: any ModInstallHandling

  private enum Load {
    case loading
    case loaded(GameBananaModDetail)
    case failed(String)
  }

  private static let collapsedDescriptionLength = 1200
  private static let previewHeight: CGFloat = 180

  @State private var load = Load.loading
  @State private var descriptionExpanded = false

  var body: some View {
    List {
      switch load {
      case .loading:
        Section { HStack { Spacer(); ProgressView(); Spacer() } }
      case .failed(let message):
        Section {
          Text(message).foregroundColor(.secondary)
          Button(L("Try Again")) { Task { await fetch() } }
        }
      case .loaded(let detail):
        content(detail)
      }
      Section { ModBrowserAttribution() }
    }
    .navigationTitle(summary.name)
    .task { await fetch() }
  }

  private func fetch() async {
    load = .loading
    do {
      load = .loaded(try await GameBananaClient.shared.modDetail(id: summary.id))
    } catch is CancellationError {
      return
    } catch {
      load = .failed(error.localizedDescription)
    }
  }

  @ViewBuilder
  private func content(_ detail: GameBananaModDetail) -> some View {
    if !detail.summary.images.isEmpty {
      Section { previews(detail.summary.images) }
    }
    descriptionSection(detail)
    creditsSection(detail)
    licenseSection(detail)
    Section(L("Files")) {
      if detail.files.isEmpty {
        Text(L("This mod has no downloadable files.")).foregroundColor(.secondary)
      }
      ForEach(detail.files) { file in
        NavigationLink {
          ModFileView(file: file, modName: detail.summary.name, ownedGame: ownedGame, handler: handler)
        } label: {
          ModFileRow(file: file)
        }
      }
    }
    Section {
      if let url = detail.summary.profileURL {
        #if os(tvOS)
        Text(String(format: L("Open %@ in a browser on another device."), url.absoluteString)).icubeText(.detail)
        #else
        Link(destination: url) { Label(L("Open on GameBanana"), systemImage: "safari") }
        #endif
      }
    }
  }

  private func previews(_ images: [GameBananaImage]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 12) {
        ForEach(Array(images.prefix(8).enumerated()), id: \.offset) { _, image in
          AsyncImage(url: image.url(minimumWidth: 530)) { rendered in
            rendered.resizable().scaledToFit()
          } placeholder: {
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: Self.previewHeight * 1.6)
          }
          .frame(height: Self.previewHeight)
          .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue))
          .accessibilityHidden(true)
        }
      }
    }
    .listRowInsets(EdgeInsets())
  }

  @ViewBuilder
  private func descriptionSection(_ detail: GameBananaModDetail) -> some View {
    let text = HTMLPlainText.text(from: detail.descriptionHTML)
    if !text.isEmpty {
      Section(L("About")) {
        let truncated = !descriptionExpanded && text.count > Self.collapsedDescriptionLength
        Text(truncated ? String(text.prefix(Self.collapsedDescriptionLength)) + "…" : text)
        if text.count > Self.collapsedDescriptionLength {
          Button(descriptionExpanded ? L("Show Less") : L("Show More")) { descriptionExpanded.toggle() }
        }
      }
    }
  }

  @ViewBuilder
  private func creditsSection(_ detail: GameBananaModDetail) -> some View {
    let groups = detail.credits.filter { !$0.members.isEmpty }
    Section(L("Credits")) {
      if let submitter = detail.summary.submitter, !submitter.name.isEmpty {
        creditRow(role: L("Submitted by"), name: submitter.name)
      }
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        ForEach(Array(group.members.enumerated()), id: \.offset) { _, member in
          creditRow(role: member.role ?? group.name, name: member.name)
        }
      }
    }
  }

  private func creditRow(role: String, name: String) -> some View {
    HStack {
      Text(name)
      Spacer()
      Text(role).foregroundColor(.secondary)
    }
  }

  @ViewBuilder
  private func licenseSection(_ detail: GameBananaModDetail) -> some View {
    let licence = HTMLPlainText.text(from: detail.licenseHTML)
    let checklist = detail.licenseChecklist
    if !licence.isEmpty || !checklist.allowed.isEmpty || !checklist.askFirst.isEmpty || !checklist.forbidden.isEmpty {
      Section(L("Licence")) {
        if !licence.isEmpty { Text(licence).icubeText(.detail) }
        ForEach(checklist.allowed, id: \.self) { Label($0, systemImage: "checkmark.circle") }
        ForEach(checklist.askFirst, id: \.self) { Label($0, systemImage: "questionmark.circle") }
        ForEach(checklist.forbidden, id: \.self) { Label($0, systemImage: "xmark.circle") }
      }
    }
  }
}

struct ModFileRow: View {
  let file: GameBananaFile

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(file.fileName).lineLimit(2)
      Text(subtitle).icubeText(.detail).foregroundColor(ICubeDesign.color(.textSecondary))
    }
  }

  private var subtitle: String {
    var parts = [ModInstallModel.formatted(file.size)]
    if let scan = file.virusScanResult, !scan.isEmpty { parts.append(String(format: L("Scan: %@"), scan)) }
    parts.append(String(format: L("%d downloads"), file.downloadCount))
    if !file.analysisWarnings.isEmpty { parts.append(L("Has warnings")) }
    return parts.joined(separator: " · ")
  }
}

// MARK: - A file: download and install

struct ModFileView: View {
  let file: GameBananaFile
  let modName: String
  let ownedGame: ModLibraryGame?
  @StateObject private var model: ModInstallModel

  init(file: GameBananaFile, modName: String, ownedGame: ModLibraryGame?, handler: any ModInstallHandling) {
    self.file = file
    self.modName = modName
    self.ownedGame = ownedGame
    _model = StateObject(wrappedValue: ModInstallModel(file: file, ownedGame: ownedGame, handler: handler))
  }

  var body: some View {
    List {
      infoSection
      actionSection
      if case .ready(let classification) = model.phase {
        ForEach(Array(classification.kinds.enumerated()), id: \.offset) { _, kind in kindSection(kind) }
        if !classification.skippedPrograms.isEmpty {
          Section {
            Text(String(format: L("Not installed, and never run: %@"), classification.skippedPrograms.joined(separator: ", ")))
              .icubeText(.detail)
          }
        }
      }
      if !model.log.isEmpty {
        Section(L("Done")) {
          ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in Text(line) }
        }
      }
      Section { ModBrowserAttribution() }
      TVStorageNoteSection()
    }
    .navigationTitle(file.fileName)
    .onDisappear { model.cleanUp() }
    .alert(L("Large Download"), isPresented: Binding(get: { model.largeDownloadBytes != nil }, set: { if !$0 { model.largeDownloadBytes = nil } })) {
      Button(L("Download")) { model.start() }
      Button(L("Cancel"), role: .cancel) {}
    } message: {
      Text(String(format: L("This file is %@. Download it?"), ModInstallModel.formatted(model.largeDownloadBytes ?? file.size)))
    }
    .alert(L("Play with Mods?"), isPresented: $model.offerPlayWithMods) {
      Button(L("Play with Mods")) { model.playWithMods() }
      Button(L("Not Now"), role: .cancel) {}
    } message: {
      Text(String(format: L("The pack is installed. Choose its options for %@ now?"), ownedGame?.title ?? ""))
    }
    .alert(L("Turn On Cheats?"), isPresented: $model.offerCheats) {
      Button(L("Turn On")) { model.enableCheats() }
      Button(L("Not Now"), role: .cancel) {}
    } message: {
      Text(L("Gecko codes only run while cheats are enabled in the settings."))
    }
    .alert(L("Turn On Custom Textures?"), isPresented: $model.offerCustomTextures) {
      Button(L("Turn On")) { model.enableCustomTextures() }
      Button(L("Not Now"), role: .cancel) {}
    } message: {
      Text(L("Texture packs only show up while custom textures are enabled in the graphics settings."))
    }
  }

  // MARK: Sections

  private var infoSection: some View {
    Section(L("File")) {
      Text(modName)
      detail(L("Size"), ModInstallModel.formatted(file.size))
      detail(L("Downloads"), "\(file.downloadCount)")
      if let scan = file.virusScanResult, !scan.isEmpty { detail(L("Virus scan"), scan) }
      ForEach(file.analysisWarnings.keys.sorted(), id: \.self) { key in
        Text(Self.warningText(kind: key, paths: file.analysisWarnings[key] ?? [])).icubeText(.detail)
      }
    }
  }

  private func detail(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).foregroundColor(.secondary)
    }
  }

  @ViewBuilder
  private var actionSection: some View {
    Section {
      switch model.phase {
      case .idle:
        if let reason = ModInstallModel.blockedReason(for: file) {
          Text(reason).foregroundColor(.secondary)
        } else {
          Button { model.requestStart() } label: { Label(L("Download and Install"), systemImage: "arrow.down.circle") }
        }
      case .downloading(let fraction):
        ProgressView(value: fraction) { Text(String(format: L("Downloading… %d%%"), Int(fraction * 100))) }
        Button(L("Cancel"), role: .cancel) { model.cancel() }
      case .verifying:
        HStack { ProgressView(); Text(L("Checking the download…")) }
      case .extracting:
        HStack { ProgressView(); Text(L("Unpacking…")) }
      case .ready:
        EmptyView()
      case .failed(let message):
        Text(message).foregroundColor(.secondary)
        Button(L("Try Again")) { model.requestStart() }
      }
    } footer: {
      if case .idle = model.phase {
        Text(L("Mods are made by other people. iCube downloads the file you pick from GameBanana and never runs programs inside it."))
      }
    }
  }

  @ViewBuilder
  private func kindSection(_ kind: ModPackageKind) -> some View {
    switch kind {
    case .textures(let gameID, let root):
      Section(L("Texture Pack")) {
        Text(String(format: L("Textures for game %@."), gameID))
        if let warning = ModInstallModel.regionWarning(packID: gameID, ownedID: ownedGame?.gameID) { Text(warning).icubeText(.detail) }
        Button(L("Install Textures")) { model.installTextures(gameID: gameID, root: root) }
          .disabled(model.isInstalling)
      }
    case .gecko(let codesFile):
      Section(L("Gecko Codes")) {
        Text(codesFile.lastPathComponent)
        if let game = ownedGame {
          Button(String(format: L("Add Codes to %@"), game.title)) { model.installGecko(file: codesFile) }
            .disabled(model.isInstalling)
        } else {
          Text(L("Add the game to your library first; Gecko codes are stored per game.")).icubeText(.detail)
        }
      }
    case .riivolution(let root):
      Section(L("Riivolution Pack")) {
        Text(L("Adds a pack you can switch on when you play a game."))
        Button(L("Install Pack")) { model.installRiivolutionPack(root: root, named: modName) }
          .disabled(model.isInstalling)
      }
    case .discPatch(let patches, let suggested):
      Section(L("Disc Patch")) {
        Text(patches.map(\.lastPathComponent).joined(separator: ", "))
        Text(L("Patches are applied to a copy of your game disc, never to the original unless you choose that.")).icubeText(.detail)
        Button(L("Choose a Game to Patch…")) { model.presentDiscPatch(patches, suggestedGameID: suggested) }
      }
    case .unsupported(let reason):
      Section(L("Can't Install")) { Text(reason) }
    }
  }

  private static func warningText(kind: String, paths: [String]) -> String {
    switch kind {
    case "contains_exe":
      return String(format: L("Contains %d program file(s). iCube never runs them."), paths.count)
    default:
      return "\(kind): \(paths.count)"
    }
  }
}
