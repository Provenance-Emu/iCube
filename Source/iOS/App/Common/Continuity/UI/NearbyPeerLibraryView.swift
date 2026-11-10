// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import SwiftUI

/// One nearby device's shared library as covers, opened from the main
/// library: inline in the tvOS content column, in a sheet on iOS.
///
/// Opening it is the explicit user action, so it is the one place pairing may
/// start (`load(from:)` with pairing allowed): an unpaired device asks for the
/// code here, inline, instead of sending the user through Settings.
///
/// Settings' Nearby screen keeps its own list-based `ContinuityPeerLibraryView`;
/// both drive the same `ContinuityLibraryBrowseController`.
struct NearbyPeerLibraryView: View {
  @Environment(\.icube) private var icube
  let peer: NearbyLibrariesModel.Peer
  /// Disc IDs already in this library, to mark covers "In Library".
  let ownedGameIDs: Set<String>
  /// Shows the device name and glyph above the content. The tvOS library
  /// already titles its column, so it passes false.
  var showsHeader = true
  /// tvOS: the first control takes this focus, so the rail can hand focus
  /// into the column.
  var initialFocus: FocusState<Bool>.Binding?
  var onShowStatus: () -> Void = {}
  var onPlay: (TVGameItem, URL?) -> Void = { _, _ in }
  static let statusID = "nearby-transfer-status"

  private enum Sheet: Identifiable {
    case options(ContinuityLibraryEntry)
    case boot(TVGameItem)
    var id: String {
      switch self {
      case .options(let entry): return "options:" + entry.key
      case .boot(let game): return "boot:" + game.filePath
      }
    }
  }

  @State private var sheet: Sheet?
  @State private var transferTask: Task<Void, Never>?
  @State private var transferID = UUID()
  @State private var saveProgress: (bytes: Int64, total: Int64)?
  @State private var copyingSaves = false
  @State private var transferError: String?
  @State private var completedEntry: ContinuityLibraryEntry?
  @State private var downloaded: [String: TVGameItem] = [:]
  @State private var pendingPlay: (TVGameItem, URL?)?
  @State private var pendingCopy: (ContinuityLibraryEntry, NearbyCopyOptions)?
  @State private var pendingBootGame: TVGameItem?

  @StateObject private var controller = ContinuityLibraryBrowseController(
    identity: ContinuityManager.shared.identity
  )
  @State private var pairingCode = ""
  @State private var codeRejected = false
  /// The catalog stays on screen while a copy runs and after it lands.
  @State private var entries: [ContinuityLibraryEntry] = []
  @State private var hasCatalog = false
  private struct CatalogRequest: Equatable {
    let peerID: String
    let needsConnection: Bool
    let search: String
  }

  @State private var search = ""
  @State private var loadedRequest: CatalogRequest?

  private var catalogRequest: CatalogRequest {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return CatalogRequest(
      peerID: peer.id,
      needsConnection: peer.needsServerConnection,
      search: peer.server == nil ? "" : String(query.unicodeScalars.prefix(256))
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
      if showsHeader { header }
      Group {
        if let server = peer.server, needsServerAccess {
          card {
            Text(L("Connect to browse")).font(icube.font(.nav))
            EmulationServerConnectionFields(model: .shared, discoveredServer: server, initialFocus: initialFocus) {
              if peer.serverConnected { Task { await load() } }
            }
          }
        } else if let transferError {
          card {
            Text(transferError)
            actionButton(L("Try Again"), systemImage: "arrow.clockwise") {
              self.transferError = nil
              if let completedEntry { sheet = .options(completedEntry) }
            }
          }
        } else if copyingSaves {
          card {
            Text(L("Copying Save States"))
            if let saveProgress {
              NearbyTransferProgress(bytes: saveProgress.bytes, total: saveProgress.total)
            }
            actionButton(L("Cancel"), systemImage: "xmark", role: .cancel) { cancelCopy() }
              .modifier(FirstFocus(binding: initialFocus))
          }
        } else {
          statusContent
        }
      }
      .id(Self.statusID)
      if peer.server != nil, !needsServerAccess {
        TextField(L("Search games"), text: $search)
          .textFieldStyle(.roundedBorder)
          .disabled(isCopying)
      }
      if hasCatalog, !needsServerAccess, loadedRequest == catalogRequest {
        grid.disabled(controller.isLoadingMoreServerGames || controller.phase == .loading)
        if controller.hasMoreServerGames, canLoadMore {
          if controller.isLoadingMoreServerGames {
            ProgressView()
          } else {
            actionButton(L("Load More"), systemImage: "chevron.down") {
              Task { await controller.loadMoreServerGames() }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: catalogRequest) {
      let request = catalogRequest
      if request.needsConnection {
        loadedRequest = nil
        return
      }
      guard loadedRequest != request else { return }
      if loadedRequest?.peerID == request.peerID {
        do { try await Task.sleep(for: .milliseconds(250)) }
        catch { return }
      }
      guard !Task.isCancelled, request == catalogRequest else { return }
      await load()
    }
    .onChange(of: controller.phase) { _, phase in
      if case .browsing(let list) = phase {
        entries = list
        hasCatalog = true
        NearbyLibrariesModel.shared.noteCatalog(peerID: peer.id, count: list.count)
      }
    }
    .onChange(of: isCopying) { _, copying in
      if copying { onShowStatus() }
    }
    .sheet(item: $sheet, onDismiss: {
      if let pendingPlay {
        self.pendingPlay = nil
        onPlay(pendingPlay.0, pendingPlay.1)
      } else if let pendingCopy {
        self.pendingCopy = nil
        startCopy(pendingCopy.0, options: pendingCopy.1)
      } else if let pendingBootGame {
        self.pendingBootGame = nil
        sheet = .boot(pendingBootGame)
      }
    }, content: { route in
      switch route {
      case .options(let entry):
        NearbyGameOptionsView(
          entry: entry,
          peer: peer,
          isOwned: localGame(for: entry) != nil,
          onCopy: { options in
            pendingCopy = (entry, options)
            sheet = nil
          },
          onBoot: {
            if let game = localGame(for: entry) {
              pendingBootGame = game
              sheet = nil
            }
          }
        )
      case .boot(let game):
        NearbyBootOptionsView(game: game) { state in
          pendingPlay = (game, state)
          sheet = nil
        }
      }
    })
    .onDisappear {
      if sheet == nil {
        transferTask?.cancel()
        controller.cancel()
      }
    }
  }

  // MARK: - Pieces

  private var header: some View {
    HStack(spacing: Metrics.headerSpacing) {
      Image(systemName: NearbyLibrariesModel.glyph(for: peer.deviceType))
        .font(ICubeDesign.symbolFont(.tile))
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(peer.name).font(icube.font(.nav))
        Text(hasCatalog && loadedRequest == catalogRequest ? Self.gameCount(entries.count) : L("Nearby Library"))
          .icubeText(.detail)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var statusContent: some View {
    switch controller.phase {
    case .idle, .loading:
      HStack(spacing: Metrics.headerSpacing) {
        ProgressView()
        Text(String(format: L("Looking at what %@ is sharing…"), peer.name))
          .foregroundStyle(.secondary)
      }

    case .awaitingPairing:
      pairingCard

    case .browsing(let list):
      if list.isEmpty, loadedRequest == catalogRequest {
        if peer.server == nil {
          Text(String(format: L("%@ isn't sharing any games right now."), peer.name))
            .foregroundStyle(.secondary)
        } else {
          Text(catalogRequest.search.isEmpty
            ? L("No GameCube or Wii games are available. Check the server’s library permissions and system labels.")
            : L("No games match your search."))
            .foregroundStyle(.secondary)
        }
      }

    case .copying(let entry, let progress):
      card {
        Text(String(format: L("Copying %@"), entry.game.displayName)).font(icube.font(.nav))
        if let progress, progress.bytesTransferred == progress.totalBytes,
           progress.currentFile.relativePath.lowercased().hasSuffix(".7z") {
          ProgressView(L("Extracting archive…"))
        } else if let progress {
          NearbyTransferProgress(bytes: progress.bytesTransferred, total: progress.totalBytes)
        } else {
          Text(peer.server == nil ? String(format: L("Asking %@…"), peer.name) : L("Preparing download…")).foregroundStyle(.secondary)
        }
        actionButton(L("Cancel"), systemImage: "xmark", role: .destructive) { cancelCopy() }
          .modifier(FirstFocus(binding: initialFocus))
      }

    case .copied(let entry):
      card {
        Label(String(format: L("%@ is now in your library."), entry.game.displayName),
              systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if let game = localGame(for: entry) {
          actionButton(L("Play Local Copy…"), systemImage: "play.fill", prominent: true) { sheet = .boot(game) }
            .modifier(FirstFocus(binding: initialFocus))
        }
      }

    case .failed(let message):
      card {
        Text(message)
        actionButton(L("Try Again"), systemImage: "arrow.clockwise", prominent: true) { Task { await load() } }
          .modifier(FirstFocus(binding: initialFocus))
      }
    }
  }

  private var pairingCard: some View {
    card {
      Text(String(format: L("Pair with %@"), peer.name)).font(icube.font(.nav))
      Text(String(format: L("Enter the 6-digit code shown on %@."), peer.name))
        .foregroundStyle(.secondary)
      ContinuityPairingCodeField(code: $pairingCode, onSubmit: submit)
        .frame(maxWidth: Metrics.codeFieldWidth)
        .modifier(FirstFocus(binding: initialFocus))
      if codeRejected {
        Text(L("That code didn't match. Check the other device and try again."))
          .icubeText(.detail)
          .foregroundStyle(.red)
      }
      actionStack {
        actionButton(L("Pair"), systemImage: "link", prominent: true) { submit(pairingCode) }
          .disabled(!ContinuityPairingCodeField.isComplete(pairingCode))
        actionButton(L("Cancel"), systemImage: "xmark", role: .cancel) { controller.cancel() }
      }
      ContinuitySecurityNotice()
        .icubeText(.detail)
    }
  }

  private var grid: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: Metrics.tileWidth), spacing: Metrics.gridSpacing, alignment: .top)],
      alignment: .leading,
      spacing: Metrics.gridSpacing
    ) {
      ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
        Button { sheet = .options(entry) } label: {
          NearbyGameTile(
            entry: entry,
            artwork: controller.artwork[entry.key],
            isOwned: localGame(for: entry) != nil,
            supportsSaveTransfer: peer.advertisement != nil
          )
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(isCopying)
        .modifier(FirstFocus(binding: index == 0 && !hasStatusControl ? initialFocus : nil))
        .task { await controller.loadArtwork(for: entry) }
      }
    }
  }

  /// The card's actions. tvOS draws them as the app's focus rows (a system bordered button inside the library
  /// column rendered as an empty tinted pill, label missing), stacked so each is its own focus target; iOS
  /// keeps the standard pills side by side.
  @ViewBuilder
  private func actionButton(
    _ title: String,
    systemImage: String,
    role: ButtonRole? = nil,
    prominent: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    #if os(tvOS)
    Button(role: role, action: action) {
      Label(title, systemImage: systemImage)
        .icubeText(.body)
        .foregroundStyle(ICubeDesign.color(.textPrimary))
    }
    .buttonStyle(ICubeRowButtonStyle())
    .frame(maxWidth: Metrics.codeFieldWidth)
    #else
    if prominent {
      Button(title, systemImage: systemImage, role: role, action: action)
        .buttonStyle(.borderedProminent) // design-lint: allow native iOS primary action
    } else {
      Button(title, systemImage: systemImage, role: role, action: action).buttonStyle(.bordered)
    }
    #endif
  }

  @ViewBuilder
  private func actionStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    #if os(tvOS)
    VStack(alignment: .leading, spacing: Metrics.headerSpacing) { content() }
    #else
    HStack(spacing: Metrics.headerSpacing) { content() }
    #endif
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Metrics.cardSpacing) { content() }
      .padding(Metrics.cardPadding)
      .frame(maxWidth: Metrics.cardMaxWidth, alignment: .leading)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
  }

  // MARK: - Actions

  private var needsServerAccess: Bool {
    peer.needsServerConnection || controller.serverNeedsAuthorization
  }

  private var isCopying: Bool {
    if copyingSaves { return true }
    if case .copying = controller.phase { return true }
    return false
  }

  private var canLoadMore: Bool {
    switch controller.phase {
    case .browsing, .copied: return !copyingSaves
    default: return false
    }
  }

  /// The status area holds a focusable control, which then gets first focus
  /// instead of the first cover.
  private var hasStatusControl: Bool {
    switch controller.phase {
    case .awaitingPairing, .copying, .copied, .failed: return true
    default: return false
    }
  }

  private func load() async {
    codeRejected = false
    let request = catalogRequest
    if loadedRequest != request {
      entries = []
      hasCatalog = false
    }
    loadedRequest = request
    await controller.load(peer: peer, search: request.search)
    if Task.isCancelled, loadedRequest == request { loadedRequest = nil }
  }

  /// The controller drops back to `.awaitingPairing` on a wrong code without
  /// saying so; `codeRejected` is how the user finds out.
  private func submit(_ code: String) {
    guard ContinuityPairingCodeField.isComplete(code) else { return }
    pairingCode = ""
    codeRejected = false
    Task {
      await controller.submitPairingCode(code)
      codeRejected = controller.phase == .awaitingPairing
    }
  }

  /// Cancelling a copy returns to the covers, not to an error screen.
  private func cancelCopy() {
    transferTask?.cancel()
    transferTask = nil
    transferID = UUID()
    copyingSaves = false
    saveProgress = nil
    controller.cancel()
    Task { await load() }
  }

  /// Match disc and revision, not just GameID (multi-disc and patched games share IDs).
  private func localGame(for entry: ContinuityLibraryEntry) -> TVGameItem? {
    if let game = downloaded[entry.key], Self.existsLocally(game.filePath) { return game }
    if let server = peer.server, let folder = try? server.folder(for: entry) {
      return TVLibraryBridge.currentGames().first { item in
        guard Self.existsLocally(item.filePath) else { return false }
        let url = item.filePath.hasPrefix("/") ? URL(fileURLWithPath: item.filePath) : URL(string: item.filePath)
        return url?.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.path
      }
    }
    return TVLibraryBridge.currentGames().first {
      !$0.isDemoItem && GameIdentity(gameItem: $0).stableKey == entry.game.stableKey &&
        Self.existsLocally($0.filePath)
    }
  }

  private static func existsLocally(_ path: String) -> Bool {
    if path.hasPrefix("/") { return FileManager.default.fileExists(atPath: path) }
    guard let url = URL(string: path), url.isFileURL else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  private func startCopy(_ entry: ContinuityLibraryEntry, options: NearbyCopyOptions) {
    transferTask?.cancel()
    transferError = nil
    completedEntry = entry
    let id = UUID()
    transferID = id
    transferTask = Task {
      if let advertisement = peer.advertisement, let catalog = options.catalog, !options.states.isEmpty {
        copyingSaves = true
        saveProgress = (0, options.states.reduce(0) { $0 + $1.size })
        onShowStatus()
        do {
          _ = try await NearbySaveClient(identity: ContinuityManager.shared.identity)
            .copy(options.states, catalog: catalog, from: advertisement, entry: entry) { bytes, total in
              Task { @MainActor in
                if transferID == id, copyingSaves { saveProgress = (bytes, total) }
              }
            }
          try Task.checkCancellation()
        } catch {
          guard transferID == id else { return }
          if !Task.isCancelled { transferError = error.localizedDescription }
          copyingSaves = false
          return
        }
        guard transferID == id, !Task.isCancelled else { return }
        copyingSaves = false
      }
      guard transferID == id, !Task.isCancelled else { return }
      if localGame(for: entry) == nil {
        await controller.copy(entry)
        guard !Task.isCancelled, case .copied = controller.phase,
              let path = controller.copiedFileURL?.path,
              let game = DiscImageBridge.gameItem(forPath: path) else { return }
        downloaded[entry.key] = game
      }
      guard !Task.isCancelled else { return }
      if let game = localGame(for: entry) { sheet = .boot(game) }
    }
  }

  // MARK: - Formatting

  static func gameCount(_ count: Int) -> String {
    count == 1 ? L("1 game") : String(format: L("%d games"), count)
  }

  private enum Metrics {
    #if os(tvOS)
    static let tileWidth: CGFloat = 220
    static let gridSpacing: CGFloat = 48
    static let codeFieldWidth: CGFloat = 360
    static let cardMaxWidth: CGFloat = 900
    #else
    static let tileWidth: CGFloat = 110
    static let gridSpacing: CGFloat = 16
    static let codeFieldWidth: CGFloat = 220
    static let cardMaxWidth: CGFloat = 520
    #endif
    static let sectionSpacing: CGFloat = 20
    static let headerSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let cornerRadius: CGFloat = 16
  }
}

/// Applies a focus binding when there is one; tvOS inline use only.
private struct FirstFocus: ViewModifier {
  let binding: FocusState<Bool>.Binding?

  func body(content: Content) -> some View {
    if let binding {
      content.focused(binding)
    } else {
      content
    }
  }
}

/// One shared title: cover, name, and whether it is already here.
private struct NearbyGameTile: View {
  let entry: ContinuityLibraryEntry
  let artwork: Data?
  let isOwned: Bool
  let supportsSaveTransfer: Bool

  @Environment(\.icube) private var icube

  /// GameCube/Wii case proportions, as the library's own cards.
  private static let coverAspect: CGFloat = 2.0 / 3.0

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      cover
        .aspectRatio(Self.coverAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous))
        .overlay(alignment: .topTrailing) {
          if isOwned {
            Image(systemName: "checkmark.circle.fill")
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, .green)
              .font(ICubeDesign.symbolFont(.rail))
              .padding(6)
              .accessibilityHidden(true)
          }
        }
      Text(entry.game.displayName)
        .font(icube.font(.detail).weight(.semibold))
        .lineLimit(2)
        .multilineTextAlignment(.leading)
      Text(isOwned ? L("In Library") : (entry.sizeBytes > 0 ? Self.size(entry.sizeBytes) : L("Download")))
        .icubeText(.detail)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint(actionHint)
  }

  private var actionHint: String {
    if supportsSaveTransfer {
      return isOwned ? L("Play the local copy or copy save states.") : L("Choose download and save options.")
    }
    return isOwned ? L("Play Local Copy…") : L("Download")
  }

  @ViewBuilder
  private var cover: some View {
    // A missing cover is a placeholder, never a gap or an error: the host
    // may simply have no art for that title.
    if let artwork, let image = UIImage(data: artwork) {
      Image(uiImage: image).resizable().scaledToFill()
    } else {
      ZStack {
        Rectangle().fill(.quaternary)
        Image(systemName: "opticaldisc")
          .font(ICubeDesign.symbolFont(.tilePrimary))
          .foregroundStyle(.secondary)
      }
    }
  }

  private static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
