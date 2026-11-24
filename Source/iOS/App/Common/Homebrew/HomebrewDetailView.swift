// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One homebrew title: what it is, who made it, its licence, and the button that installs it.
struct HomebrewDetailView: View {
  let title: HomebrewTitle
  @ObservedObject var browser: HomebrewBrowserModel

  var body: some View {
    if let root = browser.root {
      HomebrewDetailContent(title: title, browser: browser, root: root)
    } else {
      List {
        Section { Text(L("iCube cannot reach its Homebrew folder, so nothing can be installed.")).foregroundColor(.secondary) }
      }
      .navigationTitle(title.name)
    }
  }
}

private struct HomebrewDetailContent: View {
  let title: HomebrewTitle
  @ObservedObject var browser: HomebrewBrowserModel
  @StateObject private var model: HomebrewInstallModel

  private static let previewHeight: CGFloat = 180
  private static let collapsedDescriptionLength = 1200

  @State private var descriptionExpanded = false
  #if !os(tvOS)
  @Environment(\.openURL) private var openURL
  #endif

  init(title: HomebrewTitle, browser: HomebrewBrowserModel, root: URL) {
    self.title = title
    self.browser = browser
    _model = StateObject(wrappedValue: HomebrewInstallModel.attach(title: title, root: root))
  }

  var body: some View {
    List {
      if !previewPaths.isEmpty {
        Section { previews }
      }
      headerSection
      actionSection
      aboutSection
      factsSection
      linksSection
      Section { HomebrewAttribution() }
      TVStorageNoteSection()
    }
    .navigationTitle(title.name)
    .onAppear { model.refreshState() }
    .onChange(of: model.phase) { _, phase in
      if phase == .installed || phase == .idle { browser.reloadIndex() }
    }
    .alert(L("Large Download"), isPresented: Binding(
      get: { model.largeDownloadBytes != nil },
      set: { if !$0 { model.largeDownloadBytes = nil } }
    )) {
      Button(L("Download")) { model.start() }
      Button(L("Cancel"), role: .cancel) {}
    } message: {
      Text(String(format: L("This download is %@."), ModInstallModel.formatted(model.largeDownloadBytes ?? 0)))
    }
  }

  // MARK: - Sections

  private var previewPaths: [String] {
    #if os(tvOS)
    // One picture: a row of them would be a row of focus stops with nothing to do.
    return Array(([title.heroPath].compactMap { $0 } + title.screenshotPaths).prefix(1))
    #else
    return title.screenshotPaths.isEmpty ? [title.heroPath].compactMap { $0 } : title.screenshotPaths
    #endif
  }

  private var previews: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 12) {
        ForEach(previewPaths, id: \.self) { path in
          AsyncImage(url: DolphinDepotEndpoint.image(path: path)) { rendered in
            rendered.resizable().scaledToFit()
          } placeholder: {
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: Self.previewHeight * 4 / 3)
          }
          .frame(height: Self.previewHeight)
          .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue))
          .accessibilityHidden(true)
        }
      }
    }
    .listRowInsets(EdgeInsets())
  }

  private var headerSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 2) {
        Text(title.name)
        if !title.author.isEmpty {
          Text(String(format: L("By %@"), title.author))
            .icubeText(.detail).foregroundColor(ICubeDesign.color(.textSecondary))
        }
        if !title.summary.isEmpty {
          Text(title.summary).icubeText(.detail).foregroundColor(ICubeDesign.color(.textSecondary))
        }
      }
    }
  }

  @ViewBuilder
  private var actionSection: some View {
    Section {
      switch model.phase {
      case .downloading(let fraction):
        ProgressView(value: fraction) { Text(L("Downloading…")) }
        Button(L("Cancel"), role: .cancel) { model.cancel() }
      case .verifying:
        progressRow(L("Checking the download…"))
      case .installing:
        progressRow(L("Installing…"))
      case .idle, .installed, .failed:
        if case .failed(let message) = model.phase {
          Text(message).foregroundColor(.secondary)
        }
        idleButtons
      }
      if title.needsSDCard {
        Text(L("This program looks for files on an SD card, which iCube does not provide yet."))
          .icubeText(.detail).foregroundColor(ICubeDesign.color(.textSecondary))
      }
    }
  }

  @ViewBuilder
  private var idleButtons: some View {
    if model.state != .notInstalled, let program = model.programURL {
      Button(L("Play")) { HomebrewBrowserPresenter.shared.closeAndPlay(program) }
    }
    switch model.state {
    case .installed:
      EmptyView()
    case .updateAvailable:
      Button(L("Update")) { model.requestStart() }
    case .notInstalled:
      if title.latest == nil {
        Text(L("No download is available for this title yet.")).foregroundColor(.secondary)
      } else if case .failed = model.phase {
        Button(L("Try Again")) { model.requestStart() }
      } else {
        Button(L("Download")) { model.requestStart() }
      }
    }
  }

  private func progressRow(_ text: String) -> some View {
    HStack(spacing: 12) {
      ProgressView()
      Text(text)
    }
  }

  @ViewBuilder
  private var aboutSection: some View {
    let text = title.details.trimmingCharacters(in: .whitespacesAndNewlines)
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

  private var factsSection: some View {
    Section {
      if let category = title.category { factRow(L("Category"), category.displayName) }
      factRow(L("Licence"), title.licence?.spdx ?? title.licence?.notes ?? L("Not stated"))
      if let url = title.licence?.url { linkRow(L("Licence Text"), url) }
      if !title.hardware.isEmpty { factRow(L("Works With"), title.hardware.joined(separator: ", ")) }
      if let latest = title.latest {
        factRow(L("Version"), latest.version)
        factRow(L("Size"), ModInstallModel.formatted(latest.size))
        if let date = latest.releaseDate {
          factRow(L("Released"), date.formatted(date: .abbreviated, time: .omitted))
        }
      }
    }
  }

  @ViewBuilder
  private var linksSection: some View {
    if !title.links.isEmpty {
      Section(L("Links")) {
        ForEach(title.links, id: \.self) { linkRow($0.label, $0.url) }
      }
    }
  }

  private func factRow(_ name: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(name)
      Spacer()
      Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
    }
  }

  @ViewBuilder
  private func linkRow(_ label: String, _ url: URL) -> some View {
    #if os(tvOS)
    // No browser on tvOS: show the address to open elsewhere.
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
      Text(String(format: L("Open %@ in a browser on another device."), url.absoluteString))
        .icubeText(.detail).foregroundColor(ICubeDesign.color(.textSecondary))
    }
    #else
    Button {
      openURL(url)
    } label: {
      Label(label, systemImage: "safari")
    }
    #endif
  }
}
