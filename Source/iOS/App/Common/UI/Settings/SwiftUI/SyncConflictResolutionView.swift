// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVCloudSync
import SwiftUI

/// Lets the user settle files that changed on two devices at once.
///
/// This screen only ever sees the cases the resolver refused to guess: two
/// writes inside the 5-second simultaneity window with different contents.
/// Everything else is decided automatically by timestamp, so a list here should
/// be short and rare.
///
/// "Keep both" saves this device's copy alongside under a timestamped name
/// rather than discarding either — the safest option and the one offered first
/// in the per-file menu.
struct SyncConflictResolutionView: View {

    @ObservedObject private var coordinator = CloudSyncCoordinator.shared
    @State private var resolutionFeedback: String?

    var body: some View {
        Form {
            if coordinator.pendingConflicts.isEmpty {
                Section {
                    Text(L("Nothing to decide."))
                        .foregroundStyle(.secondary)
                }
            } else {
                if let reason = coordinator.conflictResolutionUnavailableReason {
                    Section {
                        HStack {
                            if coordinator.isResolvingConflict || coordinator.isSyncing { ProgressView() }
                            Text(reason)
                        }
                    }
                }
                ForEach(coordinator.pendingConflicts) { conflict in
                    Section(header: Text(conflict.metadata.relativePath), footer: footer(for: conflict)) {
                        switch conflict.kind {
                        case .bothChanged:
                            versionRow(
                                title: L("This Device"),
                                date: conflict.localVersion.modifiedDate,
                                size: conflict.localVersion.size
                            )
                            versionRow(
                                title: L("iCloud"),
                                date: conflict.remoteVersion.modifiedDate,
                                size: conflict.remoteVersion.size
                            )
                            Button(L("Keep Both")) {
                                resolve(conflict, as: .keepBoth)
                            }
                            Button(L("Keep This Device's Copy")) {
                                resolve(conflict, as: .useLocal)
                            }
                            Button(L("Keep iCloud's Copy")) {
                                resolve(conflict, as: .useRemote)
                            }

                        case .deletedRemotelyChangedLocally:
                            versionRow(
                                title: L("Changed Here"),
                                date: conflict.localVersion.modifiedDate,
                                size: conflict.localVersion.size
                            )
                            HStack {
                                Text(L("Deleted Elsewhere"))
                                Spacer()
                                Text(conflict.remoteVersion.modifiedDate.formatted(date: .abbreviated, time: .standard))
                                    .font(.footnote)
                            }
                            Button(L("Keep It")) {
                                resolve(conflict, as: .useLocal)
                            }
                            Button(L("Delete It Here Too"), role: .destructive) {
                                resolve(conflict, as: .useRemote)
                            }
                        }
                    }
                }
                .disabled(coordinator.conflictResolutionUnavailableReason != nil)

                Section(footer: Text(L("Applies your choice to every conflict above."))) {
                    Button(L("Keep Both, Everywhere")) {
                        resolveAll(as: .keepBoth)
                    }
                    Button(L("Keep This Device Everywhere")) {
                        resolveAll(as: .useLocal)
                    }
                    Button(L("Keep iCloud Everywhere")) {
                        resolveAll(as: .useRemote)
                    }
                }
                .disabled(coordinator.conflictResolutionUnavailableReason != nil)
            }
        }
        .navigationTitle(L("Sync Conflicts"))
        .alert(L("Sync Conflicts"), isPresented: Binding(
            get: { resolutionFeedback != nil },
            set: { if !$0 { resolutionFeedback = nil } }
        )) {
            Button(L("OK"), role: .cancel) { resolutionFeedback = nil }
        } message: {
            Text(resolutionFeedback ?? "")
        }
    }

    private func resolve(_ conflict: SyncConflict, as resolution: ConflictResolution) {
        Task {
            let result = await coordinator.resolve(conflict, as: resolution)
            resolutionFeedback = result.message
        }
    }

    private func resolveAll(as resolution: ConflictResolution) {
        Task {
            let result = await coordinator.resolveAllConflicts(as: resolution)
            resolutionFeedback = result.message
        }
    }

    @ViewBuilder
    private func footer(for conflict: SyncConflict) -> some View {
        switch conflict.kind {
        case .bothChanged:
            EmptyView()
        case .deletedRemotelyChangedLocally:
            Text(L("Another device deleted this after you changed it here. Keeping it brings it back everywhere; deleting it moves it to Recently Deleted for 30 days."))
        }
    }

    private func versionRow(title: String, date: Date, size: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(date.formatted(date: .abbreviated, time: .standard))
                    .font(.footnote)
                Text(CloudSyncSettingsView.formattedBytes(size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
