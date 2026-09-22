// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVCloudSync
import SwiftUI

/// Compact "where does sync stand" badge. Small enough for a settings row or a
/// toolbar, and it never shows a bare "off" — an unavailable state always
/// carries its reason.
struct SyncStatusIndicator: View {

    @ObservedObject private var coordinator = CloudSyncCoordinator.shared
    /// When false, only the icon is shown (toolbar use).
    var showsLabel: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            icon
            if showsLabel {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var icon: some View {
        if coordinator.isSyncing {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: systemImageName)
                .foregroundStyle(tint)
        }
    }

    private var systemImageName: String {
        if coordinator.unavailableReason != nil { return "icloud.slash" }
        if !coordinator.isEnabled { return "icloud.slash" }
        if !coordinator.pendingConflicts.isEmpty { return "exclamationmark.icloud.fill" }
        if coordinator.statistics.errorFiles > 0 { return "xmark.icloud.fill" }
        return "checkmark.icloud.fill"
    }

    private var tint: Color {
        if coordinator.unavailableReason != nil || !coordinator.isEnabled { return .secondary }
        if !coordinator.pendingConflicts.isEmpty { return .orange }
        if coordinator.statistics.errorFiles > 0 { return .red }
        return .green
    }

    private var label: String {
        if let reason = coordinator.unavailableReason { return reason.localizedDescription }
        if !coordinator.isEnabled { return L("Off") }
        if coordinator.isSyncing { return L("Syncing…") }
        if !coordinator.pendingConflicts.isEmpty {
            return L("Needs your decision")
        }
        if coordinator.statistics.errorFiles > 0 { return L("Some files failed") }
        return L("Up to date")
    }
}
