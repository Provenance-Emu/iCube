// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SkinCatalogKit
import SkinKitManager
import SwiftUI

/// Browse and install controller skins from the emuskins.com catalog. Shelves follow
/// `SkinStorePolicy`: GameCube, Wii, then N64 layouts rewritten to the GameCube pad. Files download
/// from each author's host; iCube never re-hosts them. Callers wrap it in a `NavigationStack`.
struct SkinStoreView: View {
  /// Adds a Done button for sheet presentation.
  var showsDoneButton = false

  @Environment(\.dismiss) private var dismiss
  @StateObject private var model: SkinStoreViewModel
  /// Shelves showing every card; the others show `SkinStoreShelf.collapsedFamilyLimit`.
  @State private var expandedShelves: Set<String> = []
  @ObservedObject private var installer: SkinStoreInstaller

  private static let submitURL = URL(string: "https://emuskins.com/submit.html")
  private static let cardMinimumWidth: CGFloat = 160
  private static let cardMaximumWidth: CGFloat = 240

  init(showsDoneButton: Bool = false, model: SkinStoreViewModel? = nil) {
    self.showsDoneButton = showsDoneButton
    let model = model ?? SkinStoreViewModel()
    _model = StateObject(wrappedValue: model)
    _installer = ObservedObject(wrappedValue: model.installer)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
        intro
        if let offline = model.offlineMessage { offlineBanner(offline) }
        switch model.loadState {
        case .loading:
          loadingView
        case .failed(let message):
          failedView(message)
        case .loaded:
          if model.shelves.isEmpty {
            emptyView
          } else {
            ForEach(model.shelves) { shelf in shelfView(shelf) }
          }
        }
        creditFooter
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(ICubeDesign.Spacing.m.rawValue)
    }
    .navigationTitle(L("Skin Store"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if showsDoneButton {
        ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } }
      }
      ToolbarItem(placement: .primaryAction) {
        if model.isRefreshing {
          ProgressView()
        } else {
          Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel(L("Refresh"))
        }
      }
    }
    .refreshable { await model.refresh() }
    .task { await model.loadIfNeeded() }
    .onAppear { model.reconcileInstalled() }
    .onReceive(NotificationCenter.default.publisher(for: SkinLibrary.didChangeNotification)) { _ in model.reconcileInstalled() }
  }

  // MARK: - Shelves

  private func shelfView(_ shelf: SkinStoreShelf) -> some View {
    let expanded = expandedShelves.contains(shelf.id)
    return VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
      HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
        HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
          Text(shelf.section.storeHeader).icubeText(.section)
          Text("\(shelf.families.count)").icubeText(.tag).foregroundStyle(ICubeDesign.color(.textSecondary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        if shelf.isCollapsible {
          Button(expanded ? L("Show fewer") : L("Show all")) {
            if expanded { expandedShelves.remove(shelf.id) } else { expandedShelves.insert(shelf.id) }
          }
          .icubeText(.detail)
        }
      }
      if let note = shelf.section.storeNote {
        Text(note).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
          .fixedSize(horizontal: false, vertical: true)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardMinimumWidth, maximum: Self.cardMaximumWidth),
                                   spacing: ICubeDesign.Spacing.s.rawValue, alignment: .top)],
                alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
        ForEach(shelf.visibleFamilies(expanded: expanded)) { family in
          if family.isMultiFile {
            SkinStoreFamilyCard(family: family, section: shelf.section, installer: installer, policy: model.policy)
          } else {
            let entry = family.primary
            SkinStoreCard(entry: entry, section: shelf.section, state: installer.state(for: entry),
                          onInstall: { installer.startInstall(entry) }, onCancel: { installer.cancelInstall(entry) })
          }
        }
      }
    }
  }

  // MARK: - States

  private var intro: some View {
    Text(L("Controller skins made by the community. Installed skins show up in the skin picker, where you choose one per controller and orientation."))
      .icubeText(.detail)
      .foregroundStyle(ICubeDesign.color(.textSecondary))
      .fixedSize(horizontal: false, vertical: true)
  }

  private var loadingView: some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      ProgressView()
      Text(L("Loading skins")).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, ICubeDesign.Spacing.xl.rawValue)
  }

  private func failedView(_ message: String) -> some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      Image(systemName: "wifi.exclamationmark").font(ICubeDesign.symbolFont(.tilePrimary)).foregroundStyle(ICubeDesign.color(.textSecondary))
      Text(L("Couldn't load the skin store")).icubeText(.body)
      Text(message).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      Button(L("Try Again")) { Task { await model.refresh() } }
        .buttonStyle(.bordered)
        .disabled(model.isRefreshing)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, ICubeDesign.Spacing.xl.rawValue)
  }

  private func offlineBanner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: ICubeDesign.Spacing.xs.rawValue) {
      Image(systemName: "wifi.slash").foregroundStyle(ICubeDesign.color(.accent))
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        Text(L("Offline. Showing skins from your last visit.")).icubeText(.detail)
        Text(message).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary)).lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(ICubeDesign.Spacing.s.rawValue)
    .background(ICubeDesign.color(.rowSurface), in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous))
  }

  private var emptyView: some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      Text(emptyMessage).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
      if let url = Self.submitURL { Link(L("Submit a skin"), destination: url).icubeText(.body) }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, ICubeDesign.Spacing.xl.rawValue)
  }

  /// Names every console the store has a shelf for, so the message stays right when the policy changes.
  private var emptyMessage: String {
    let systems = ListFormatter.localizedString(byJoining: model.policy.sections.map(\.badge))
    return String(format: L("No %@ skins in the catalog yet."), systems)
  }

  private var creditFooter: some View {
    Text(L("Skins are listed by the Provenance skin catalog and download from each author's own site. Each card credits its author and where it's hosted."))
      .icubeText(.detail)
      .foregroundStyle(ICubeDesign.color(.textSecondary))
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Store-screen copy for each shelf, kept out of the policy so wording can change without touching routing.
private extension SkinStoreSection {
  var storeHeader: String {
    switch id {
    case SkinStoreSection.gameCube.id: return L("GameCube")
    case SkinStoreSection.wii.id: return L("Wii")
    case SkinStoreSection.nintendo64.id: return L("N64-style layout")
    case SkinStoreSection.nes.id: return L("NES")
    case SkinStoreSection.snes.id: return L("Super NES")
    default: return title
    }
  }

  var storeNote: String? {
    switch id {
    case SkinStoreSection.nintendo64.id:
      return L("Built for N64-style layouts. iCube puts A, B, Z, L, R, Start, the D-pad and the stick on the GameCube pad and the C buttons on the C-stick, so the art keeps its N64 labels.")
    case SkinStoreSection.nes.id, SkinStoreSection.snes.id:
      return L("For Virtual Console and WiiWare games. iCube puts A, B, Start and Select on the GameCube pad or Classic Controller the way the Virtual Console does; the skin picker lets you choose one per game type.")
    default: return nil
    }
  }

  /// The badge on a card: the console the skin was made for.
  var badge: String {
    switch id {
    case SkinStoreSection.gameCube.id: return L("GameCube")
    case SkinStoreSection.wii.id: return L("Wii")
    case SkinStoreSection.nintendo64.id: return L("N64")
    case SkinStoreSection.nes.id: return L("NES")
    case SkinStoreSection.snes.id: return L("SNES")
    default: return title
    }
  }
}

/// One skin in the store: thumbnail, name, author, host, the console it was made for, and its install control.
private struct SkinStoreCard: View {
  let entry: SkinCatalogEntry
  let section: SkinStoreSection
  let state: SkinStoreInstallState
  let onInstall: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
      SkinStoreThumbnail(url: entry.thumbnailURL, badge: section.badge)
        .overlay(alignment: .topLeading) {
          Text(section.badge).icubeText(.tag)
            .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue).padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(ICubeDesign.Spacing.xs.rawValue)
        }
      Text(entry.name).icubeText(.body).lineLimit(2).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        if let author = entry.author, !author.isEmpty {
          Text(String(format: L("by %@"), author)).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary)).lineLimit(1)
        }
        if entry.hasPackedVariants {
          // A single-file skin that packs several layouts: one download brings them all.
          Text(String(format: L("Includes %@"), entry.variants.map(\.label).joined(separator: ", ")))
            .icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary)).lineLimit(2)
        }
        if let host = entry.sourceHost {
          Text(host).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textTertiary)).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      SkinStoreActionView(state: state, onInstall: onInstall, onCancel: onCancel)
    }
    .padding(ICubeDesign.Spacing.s.rawValue)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(ICubeDesign.color(.rowSurface), in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
  }
}

/// A variant family (SkinKit#17): one card for every file of a pack, each variant by its label with its own install
/// control, and Install All, which fetches the rest one file at a time through the family's download plan.
private struct SkinStoreFamilyCard: View {
  let family: SkinFamily
  let section: SkinStoreSection
  @ObservedObject var installer: SkinStoreInstaller
  let policy: SkinStorePolicy

  /// Every member iCube can install, one URL per file.
  private var plan: SkinDownloadPlan { family.downloadPlan(policy: policy) }

  private var creditLine: String? {
    let names = family.authors
    switch names.count {
    case 0: return nil
    case 1, 2: return String(format: L("by %@"), names.joined(separator: " & "))
    default: return String(format: L("by %@"), "\(names[0]) & \(names.count - 1)+")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
      SkinStoreThumbnail(url: family.primary.thumbnailURL, badge: section.badge)
        .overlay(alignment: .topLeading) {
          Label(String(format: L("%ld variants"), family.variantCount), systemImage: "square.stack.3d.up.fill").icubeText(.tag)
            .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue).padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(ICubeDesign.Spacing.xs.rawValue)
        }
      Text(family.name).icubeText(.body).lineLimit(2).fixedSize(horizontal: false, vertical: true)
      if let creditLine {
        Text(creditLine).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary)).lineLimit(1)
      }
      ForEach(family.members) { member in
        VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
          Text(family.label(for: member)).icubeText(.detail).lineLimit(1)
          SkinStoreActionView(state: installer.state(for: member),
                              onInstall: { installer.startInstall(member) }, onCancel: { installer.cancelInstall(member) })
        }
        .accessibilityElement(children: .contain)
      }
      Spacer(minLength: 0)
      installAllButton
    }
    .padding(ICubeDesign.Spacing.s.rawValue)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(ICubeDesign.color(.rowSurface), in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
  }

  private var installAllButton: some View {
    let remaining = installer.remaining(plan).count
    return Button { installer.startInstall(plan) } label: {
      Label(remaining == 0 ? L("All Installed") : String(format: L("Install All (%ld)"), remaining),
            systemImage: remaining == 0 ? "checkmark.circle.fill" : "square.and.arrow.down.on.square")
        .icubeText(.detail)
        .padding(.horizontal, ICubeDesign.Spacing.s.rawValue).padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
        .background(ICubeDesign.color(.selectedFill), in: Capsule())
        .foregroundStyle(ICubeDesign.color(.accent))
    }
    .buttonStyle(.plain)
    .disabled(remaining == 0 || installer.isBusy(plan))
  }
}

/// Square skin preview for a card. Many feed entries have no thumbnail; those and failed loads get a gamepad glyph.
private struct SkinStoreThumbnail: View {
  let url: URL?
  let badge: String

  var body: some View {
    ZStack {
      if let url {
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let image): image.resizable().scaledToFit()
          case .failure: placeholder
          case .empty: placeholder.overlay(ProgressView())
          @unknown default: placeholder
          }
        }
      } else {
        placeholder
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .background(ICubeDesign.color(.rowSurface))
    .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous))
    .accessibilityHidden(true)
  }

  private var placeholder: some View {
    VStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
      Image(systemName: "gamecontroller").font(ICubeDesign.symbolFont(.tile))
      Text(badge).icubeText(.tag)
    }
    .foregroundStyle(ICubeDesign.color(.textTertiary))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// The install control at the bottom of a card: Install, download progress with cancel, Installing,
/// Installed, or the failure with Retry.
private struct SkinStoreActionView: View {
  let state: SkinStoreInstallState
  let onInstall: () -> Void
  let onCancel: () -> Void

  private static let minimumHeight: CGFloat = 28

  var body: some View {
    switch state {
    case .idle:
      actionPill(L("Install"), systemImage: "arrow.down.circle.fill", action: onInstall)
    case .downloading(let progress):
      HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
        // The downloader reports 0 until it knows the length, and stays there when the server never says.
        if progress > 0 {
          ProgressView(value: progress).tint(ICubeDesign.color(.accent))
        } else {
          ProgressView()
          Text(L("Downloading")).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
          Spacer(minLength: 0)
        }
        Button(action: onCancel) {
          Image(systemName: "xmark.circle.fill").foregroundStyle(ICubeDesign.color(.textSecondary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Cancel Download"))
      }
      .frame(minHeight: Self.minimumHeight)
    case .installing:
      HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
        ProgressView()
        Text(L("Installing")).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
      }
      .frame(minHeight: Self.minimumHeight)
    case .installed:
      Label(L("Installed"), systemImage: "checkmark.circle.fill").icubeText(.detail).foregroundStyle(ICubeDesign.color(.accent))
        .frame(minHeight: Self.minimumHeight)
    case .failed(let message):
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        Text(message).icubeText(.detail).foregroundStyle(ICubeDesign.color(.destructive)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        actionPill(L("Retry"), systemImage: "arrow.clockwise", action: onInstall)
      }
    }
  }

  private func actionPill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage).icubeText(.detail)
        .padding(.horizontal, ICubeDesign.Spacing.s.rawValue).padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
        .background(ICubeDesign.color(.selectedFill), in: Capsule())
        .foregroundStyle(ICubeDesign.color(.accent))
    }
    .buttonStyle(.plain)
  }
}
#endif
