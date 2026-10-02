// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

extension ControllerSetupSystem {
  /// The pad kinds a player can pick a skin for on this screen: a GameCube hub offers the GameCube pad,
  /// a Wii hub the three Wii pads, and a hub that lists both offers all four.
  var skinPadKinds: [TouchOverlayPadKind] {
    switch self {
    case .gamecube: return [.gameCube]
    case .wii: return [.wiiRemote, .wiiRemoteSideways, .wiiClassic]
    case .both, .wiiAndGameCube: return TouchOverlayPadKind.allCases
    }
  }
}

/// Controllers hub -> On-Screen Controls -> Skins: choose the skin that replaces the on-screen controller
/// for a pad kind and orientation, import new ones, and delete ones no longer wanted.
struct SkinPickerView: View {
  private static let thumbnailHeight: CGFloat = 64
  private static let thumbnailCornerRadius: CGFloat = 8
  /// Logical screens the thumbnails lay a skin out on (an iPhone-sized landscape or portrait screen).
  private static let landscapeCanvas = CGSize(width: 844, height: 390)
  private static let portraitCanvas = CGSize(width: 390, height: 844)

  let padKinds: [TouchOverlayPadKind]
  @ObservedObject private var library: SkinLibrary
  @State private var padKind: TouchOverlayPadKind
  @State private var orientation: TouchOverlayOrientation
  @State private var showImporter = false
  @State private var alertMessage: String?

  init(padKinds: [TouchOverlayPadKind], library: SkinLibrary = .shared) {
    self.padKinds = padKinds
    self.library = library
    _padKind = State(initialValue: padKinds.first ?? .gameCube)
    _orientation = State(initialValue: Self.currentOrientation())
  }

  var body: some View {
    let skins = library.skins.filter { $0.gameType.padKinds.contains(padKind) }
    let selected = library.selectedSkin(for: padKind, orientation: orientation)
    List {
      Section {
        if padKinds.count > 1 {
          Picker(L("Controller"), selection: $padKind) {
            ForEach(padKinds, id: \.self) { Text(Self.title(for: $0)).tag($0) }
          }
          .pickerStyle(.segmented)
        }
        Picker(L("Orientation"), selection: $orientation) {
          Text(L("Portrait")).tag(TouchOverlayOrientation.portrait)
          Text(L("Landscape")).tag(TouchOverlayOrientation.landscape)
        }
        .pickerStyle(.segmented)
      }
      Section {
        row(title: L("Swift-drawn (default)"), subtitle: nil, isSelected: selected == nil, onSelect: { library.select(nil, for: padKind, orientation: orientation) }, thumbnail: {
          Image(systemName: "gamecontroller")
            .font(.title2)
            .frame(width: Self.thumbnailHeight, height: Self.thumbnailHeight)
        })
        ForEach(skins) { skin in
          row(title: skin.name, subtitle: hasLayout(skin) ? nil : L("No layout for this orientation"), isSelected: selected == skin, onSelect: { library.select(skin, for: padKind, orientation: orientation) }, thumbnail: {
            SkinThumbnail(skin: skin, padKind: padKind, orientation: orientation,
                          canvas: orientation == .portrait ? Self.portraitCanvas : Self.landscapeCanvas,
                          height: Self.thumbnailHeight, cornerRadius: Self.thumbnailCornerRadius)
          })
        }
        .onDelete { offsets in delete(offsets.map { skins[$0] }) }
      } footer: {
        if skins.isEmpty { Text(L("No skins imported for this controller yet. Use Import… to add a .deltaskin or .manicskin file.")) }
      }
    }
    .navigationTitle(L("Skins"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(L("Import…")) { showImporter = true }
      }
    }
    .fileImporter(isPresented: $showImporter, allowedContentTypes: SkinLibrary.archiveContentTypes, allowsMultipleSelection: false) { result in
      handleImport(result)
    }
    .alert(L("Skins"), isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
      Button(L("OK"), role: .cancel) {}
    } message: {
      Text(alertMessage ?? "")
    }
    // A running game forgets picks whose files are gone here, not while it draws.
    .onAppear { SkinMount.forgetDeadSelections(in: library) }
  }

  /// The orientation the app's window is in. The device orientation reads unknown when the phone lies flat.
  private static func currentOrientation() -> TouchOverlayOrientation {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    guard let interfaceOrientation = scene?.interfaceOrientation, interfaceOrientation != .unknown else { return .portrait }
    return TouchOverlayOrientation(isPortrait: interfaceOrientation.isPortrait)
  }

  private func hasLayout(_ skin: InstalledSkin) -> Bool {
    SkinMount.supports(skin, orientation: orientation, isPad: UIDevice.current.userInterfaceIdiom == .pad)
  }

  private func row<Thumbnail: View>(title: String, subtitle: String?, isSelected: Bool, onSelect: @escaping () -> Void,
                                    @ViewBuilder thumbnail: () -> Thumbnail) -> some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        thumbnail()
        VStack(alignment: .leading, spacing: 2) {
          Text(title).foregroundStyle(.primary)
          if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        Spacer()
        if isSelected { Image(systemName: "checkmark").foregroundStyle(.tint) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private static func title(for padKind: TouchOverlayPadKind) -> String {
    switch padKind {
    case .gameCube: return L("GameCube")
    case .wiiRemote: return L("Wii Remote")
    case .wiiRemoteSideways: return L("Sideways")
    case .wiiClassic: return L("Classic")
    }
  }

  private func delete(_ skins: [InstalledSkin]) {
    for skin in skins {
      do {
        try library.delete(skin)
      } catch {
        alertMessage = String(format: L("Couldn't delete skin: %@"), error.localizedDescription)
      }
    }
  }

  private func handleImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      for url in urls {
        // The importer also lets through whatever type the system resolves a skin's extension to, so vet the pick here.
        guard SkinLibrary.isImportableArchive(url) else {
          alertMessage = String(format: L("Couldn't import skin: %@"), SkinImportError.describe(SkinImportError.unreadableArchive))
          continue
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
          try library.importSkin(from: url)
        } catch {
          alertMessage = String(format: L("Couldn't import skin: %@"), SkinImportError.describe(error))
        }
      }
    case .failure(let error):
      alertMessage = String(format: L("Couldn't import skin: %@"), SkinImportError.describe(error))
    }
  }
}

/// A skin drawn small on a stand-in screen, input off. A skin with no layout for the orientation says so instead.
private struct SkinThumbnail: View {
  let skin: InstalledSkin
  let padKind: TouchOverlayPadKind
  let orientation: TouchOverlayOrientation
  let canvas: CGSize
  let height: CGFloat
  let cornerRadius: CGFloat

  private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  var body: some View {
    let scale = height / canvas.height
    ZStack {
      Color.black
      if SkinMount.supports(skin, orientation: orientation, isPad: isPad) {
        SkinOverlayView(skin: skin, padKind: padKind, deviceId: 0, previewDevice: isPad ? .ipad : .iphone, onAction: { _ in })
          .frame(width: canvas.width, height: canvas.height)
          .scaleEffect(scale)
          .frame(width: canvas.width * scale, height: height)
          .allowsHitTesting(false)
      } else {
        Image(systemName: "rectangle.slash")
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: canvas.width * scale, height: height)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .accessibilityHidden(true)
  }
}
#endif
