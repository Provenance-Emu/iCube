// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The ecosystem share UI: the confirm prompt for `dolphinios://requestGame`
/// (a peer app, e.g. Provenance, asked for one of this library's games), the
/// share sheet that hands the file over to a peer without a drop box, the
/// error alert and the notice alert.
///
/// The prompt is an alert rather than a sheet, matching
/// `ContinuityPairingPromptModifier`: it has to interrupt, and it has exactly
/// two answers. A hand-over to a peer that receives direct hand-offs shows
/// nothing here (`EcosystemShareCenter` stages the file and opens the peer).
/// Otherwise it is the system share sheet, where the user picks the receiving
/// app ("Copy to Provenance") and iOS copies the file even after iCube is
/// suspended. tvOS has no share sheet, so it is not attached there:
/// `EcosystemShareCenter` never sets `exportItems` on tvOS.
struct EcosystemShareApprovalModifier: ViewModifier {
  @ObservedObject var center: EcosystemShareCenter

  func body(content: Content) -> some View {
    content.alert(
      L("Share Game?"),
      isPresented: Binding(
        get: { center.request != nil },
        // Dismissal without an explicit answer is a decline.
        set: { if !$0 { center.deny() } }
      ),
      presenting: center.request
    ) { _ in
      Button(L("Don't Share"), role: .cancel) { center.deny() }
      Button(L("Share")) { center.approve() }
    } message: { request in
      Text(String(
        format: L("%@ wants to copy \u{201C}%@\u{201D} (%@)."),
        EcosystemShareCenter.peerName(request.callbackScheme),
        request.game.title,
        Self.sizeString(forPath: request.game.filePath)
      ))
    }
    // Share failure — so a tap is never a silent no-op.
    .alert(
      L("Couldn\u{2019}t Share"),
      isPresented: Binding(
        get: { center.shareError != nil },
        set: { if !$0 { center.shareError = nil } }
      )
    ) {
      Button(L("OK"), role: .cancel) { center.shareError = nil }
    } message: {
      Text(center.shareError ?? "")
    }
    // A staged hand-off the peer still has to pick up, or an incoming one
    // iCube could not import.
    .alert(
      center.notice?.title ?? "",
      isPresented: Binding(
        get: { center.notice != nil },
        set: { if !$0 { center.notice = nil } }
      )
    ) {
      Button(L("OK"), role: .cancel) { center.notice = nil }
    } message: {
      Text(center.notice?.message ?? "")
    }
    .modifier(ExportSheetModifier(center: center))
  }

  private static func sizeString(forPath path: String) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? Int64 else {
      return L("unknown size")
    }
    return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
  }
}

/// The share sheet for `EcosystemShareCenter.exportItems`.
private struct ExportSheetModifier: ViewModifier {
  @ObservedObject var center: EcosystemShareCenter

  func body(content: Content) -> some View {
    #if os(iOS)
    content.sheet(
      isPresented: Binding(
        get: { center.exportItems != nil },
        set: { if !$0 { center.finishExport() } }
      )
    ) {
      ShareSheet(activityItems: center.exportItems ?? [])
    }
    #else
    content
    #endif
  }
}

extension View {
  /// Attaches the ecosystem share prompt, share sheet and alerts.
  /// Attach once, at the app root (`TVRootView`, the root on iOS and tvOS
  /// alike) — a `requestGame` ask
  /// arrives UNSOLICITED, the same reasoning `.continuityLibraryPullPrompt()`
  /// documents there: a modifier scoped to one screen would miss it whenever
  /// the owner is elsewhere in the app.
  func ecosystemShareApprovalPrompt() -> some View {
    modifier(EcosystemShareApprovalModifier(center: .shared))
  }
}
