// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SkinCatalogKit
import SkinKitManager
import SkinKitUI
import SwiftUI

/// Browse and install controller skins from the emuskins.com catalog.
///
/// The screen is SkinKit's catalog browser, the one Provenance and iFly show, scoped to iCube's store
/// (`SkinCatalogStoreHost.iCube`): the shelves of `SkinStorePolicy.iCube` (GameCube, Wii, N64 layouts rewritten to
/// the GameCube pad, NES, Super NES) are category chips over one searchable, sortable grid, and a card opens the
/// skin's page with its install button. Files download from each author's host; iCube never re-hosts them.
/// Callers wrap it in a `NavigationStack`.
struct SkinStoreView: View {
  /// Adds a Done button for sheet presentation.
  var showsDoneButton = false

  @Environment(\.dismiss) private var dismiss
  private let store: SkinCatalogStoreHost
  private let library: SkinLibrary

  init(showsDoneButton: Bool = false, store: SkinCatalogStoreHost? = nil, library: SkinLibrary = .shared) {
    self.showsDoneButton = showsDoneButton
    self.store = store ?? .iCube()
    self.library = library
  }

  var body: some View {
    SkinCatalogBrowserView(store: store)
      .toolbar {
        if showsDoneButton {
          ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } }
        }
      }
      .onAppear { reconcileInstalled() }
      .onReceive(NotificationCenter.default.publisher(for: SkinLibrary.didChangeNotification)) { _ in reconcileInstalled() }
  }

  /// Drops "Installed" marks for skins the player has since deleted in the picker.
  private func reconcileInstalled() {
    store.installer.reconcileInstalled(with: Set(library.skins.map(\.id)))
  }
}

extension SkinCatalogStoreHost {
  /// iCube's store for SkinKit's catalog browser: iCube's shelves as the categories, iCube's installer (the library
  /// import, the N64 rewrite, `store.json`) and iCube's wording. The device filter is the host's default, the device
  /// iCube is running on. Tests pass their own installer and service.
  @MainActor
  static func iCube(installer: SkinStoreInstaller = .shared, service: SkinCatalogService = .shared,
                    policy: SkinStorePolicy = .iCube) -> SkinCatalogStoreHost {
    ICubeSkinStoreAppearance.apply()
    return SkinCatalogStoreHost(policy: policy, installer: installer, service: service,
                                categoryTitle: { $0.storeHeader }, categoryNote: { $0.storeNote },
                                describeError: SkinStoreMessages.describe)
  }
}

/// Points SkinKit's catalog screens at iCube's strings and colours.
///
/// Both are global SkinKit values read while its views build. Nothing else iCube shows from SkinKit reads them (the
/// overlay draws skins, not SkinKit's screens), so setting them when the store is built is enough.
@MainActor
enum ICubeSkinStoreAppearance {
  private static var isApplied = false

  static func apply() {
    guard !isApplied else { return }
    isApplied = true

    // iCube's strings live in the "Core" table (see `L()`), not `Localizable`.
    SkinKitLocalization.tableName = "Core"
    SkinKitLocalization.bundle = .main

    // The browser draws white text on its own backdrop in either appearance, so it takes iCube's dark palette: the
    // dark DolphinTint, the GameCube and Wii platform colours, and the dark room gradient.
    let dark = UITraitCollection(userInterfaceStyle: .dark)
    func resolved(_ color: UIColor) -> Color { Color(uiColor: color.resolvedColor(with: dark)) }
    var theme = SkinKitTheme.current
    theme.pink = resolved(ICubeDesign.uiColor(.accent))
    theme.purple = resolved(ICubeDesign.uiPlatformAccent(.gameCube))
    theme.blue = resolved(ICubeDesign.uiPlatformAccent(.wii))
    theme.cyan = theme.blue
    let room = ICubeDesign.roomStops.map(resolved)
    theme.background = {
      AnyView(LinearGradient(colors: room, startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
    }
    theme.backgroundColorScheme = .dark
    SkinKitTheme.current = theme
  }
}

/// Store-screen copy for each shelf, kept out of the policy so wording can change without touching routing.
extension SkinStoreSection {
  /// The category chip.
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

  /// What installing from the shelf does, shown under the chips while it is selected and on its skins' pages.
  var storeNote: String? {
    switch id {
    case SkinStoreSection.nintendo64.id:
      return L("Built for N64-style layouts. iCube puts A, B, Z, L, R, Start, the D-pad and the stick on the GameCube pad and the C buttons on the C-stick, so the art keeps its N64 labels.")
    case SkinStoreSection.nes.id, SkinStoreSection.snes.id:
      return L("For Virtual Console and WiiWare games. iCube puts A, B, Start and Select on the GameCube pad or Classic Controller the way the Virtual Console does; the skin picker lets you choose one per game type.")
    default: return nil
    }
  }
}
#endif
