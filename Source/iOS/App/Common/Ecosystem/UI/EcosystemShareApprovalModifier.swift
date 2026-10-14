// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The ecosystem share UI: the confirm prompt for `dolphinios://requestGame`
/// (a peer app, e.g. Provenance, asked for one of this library's games), the
/// share sheet that hands the file over, and the error alert.
///
/// The prompt is an alert rather than a sheet, matching
/// `ContinuityPairingPromptModifier`: it has to interrupt, and it has exactly
/// two answers. The hand-over is the system share sheet, so the user picks
/// the receiving app ("Copy to Provenance") and iOS copies the file even
/// after iCube is suspended. tvOS has no share sheet; the routes that reach
/// `exportItems` are iOS-only (`EcosystemSendButton`, `UIApplication.open`
/// callbacks), so the sheet is simply not attached there.
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
    /// Attaches the ecosystem share prompt, share sheet and error alert.
    /// Attach once, at the app root (see `TVRootView`) — a `requestGame` ask
    /// arrives UNSOLICITED, the same reasoning `.continuityLibraryPullPrompt()`
    /// documents there: a modifier scoped to one screen would miss it whenever
    /// the owner is elsewhere in the app.
    func ecosystemShareApprovalPrompt() -> some View {
        modifier(EcosystemShareApprovalModifier(center: .shared))
    }
}
