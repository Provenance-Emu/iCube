// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A pause-menu child: selecting a disc never replaces the game or releases the menu's pause claim.
struct DiscChangePicker: View {
  let games: [TVGameItem]
  let isWii: Bool
  let onBack: () -> Void
  @State private var candidates: [DiscChangeCandidate] = []
  @State private var feedback: TVDiscChangeResult?

  var body: some View {
    NavigationStack {
      MenuScreen(model: DiscChangeModelBuilder.make(candidates: candidates, onSelect: select, onCancel: onBack),
                 style: .list, onBack: onBack,
                 modal: feedback == nil ? nil : MenuModal(onConfirm: dismissFeedback, onCancel: dismissFeedback),
                 tvHeader: ICubeLeafHeader(title: L("Change Disc"), subtitle: L("Insert another local disc without restarting the game.")),
                 tvClaimsFocus: true)
        .navigationTitle(L("Change Disc"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    .pauseClaim("change-disc")
    #if os(tvOS)
    // iOS MenuScreen owns its polling scope; an outer claim would hide it behind an inert owner.
    // tvOS uses native focus and needs this claim only to silence covered raw controller handlers.
    .claimsController()
    #endif
    .onAppear {
      candidates = DiscChangePolicy.eligible(games.map {
        DiscChangeCandidate(title: $0.title, path: $0.filePath, platform: $0.platform,
                            discNumber: $0.discNumber, isDemo: $0.isDemoItem)
      }, isWii: isWii)
    }
    .alert(L("Change Disc"), isPresented: Binding(get: { feedback != nil }, set: { if !$0 { dismissFeedback() } })) {
      Button(L("OK")) { dismissFeedback() }
    } message: {
      Text(feedbackMessage)
    }
  }

  private func select(_ candidate: DiscChangeCandidate) {
    feedback = TVEmulationBridge.changeDisc(atPath: candidate.path)
  }

  private func dismissFeedback() {
    let completed = feedback == .scheduled
    feedback = nil
    if completed { onBack() }
  }

  private var feedbackMessage: String {
    switch feedback {
    case .scheduled: return L("Disc change queued. Resume the game to insert the disc.")
    case .fileUnavailable: return L("The disc file is missing or unreadable.")
    case .invalidDisc: return L("The selected file is not a valid GameCube or Wii disc.")
    case .incompatibleSystem: return L("This disc is not compatible with the running system.")
    case .noRunningGame: return L("The game is no longer running.")
    case .pendingInsertion: return L("Another disc is already waiting to be inserted. Resume the game before changing discs again.")
    case nil: return ""
    @unknown default: return L("The selected file is not a valid GameCube or Wii disc.")
    }
  }
}

enum DiscChangeModelBuilder {
  static func make(candidates: [DiscChangeCandidate], onSelect: @escaping (DiscChangeCandidate) -> Void,
                   onCancel: @escaping () -> Void) -> MenuModel {
    var items = [MenuItem(id: "disc-cancel", title: L("Cancel"), icon: "xmark", role: .action(onCancel))]
    items += candidates.map { candidate in
      MenuItem(id: candidate.path, title: candidate.title,
               subtitle: "\(String(format: L("Disc %d"), candidate.discNumber + 1)) · \(URL(fileURLWithPath: candidate.path).lastPathComponent)",
               icon: "opticaldisc", role: .action { onSelect(candidate) })
    }
    if candidates.isEmpty {
      items.append(MenuItem(id: "disc-empty", title: L("No compatible local discs are available."),
                            icon: "opticaldisc", role: .action {}, isEnabled: false))
    }
    return MenuModel(sections: [MenuSection(id: "change-disc", items: items)])
  }
}
