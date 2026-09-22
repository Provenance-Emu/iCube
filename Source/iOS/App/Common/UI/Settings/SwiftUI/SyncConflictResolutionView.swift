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

    var body: some View {
        Form {
            if coordinator.pendingConflicts.isEmpty {
                Section {
                    Text(L("Nothing to decide."))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(coordinator.pendingConflicts) { conflict in
                    Section(header: Text(conflict.metadata.relativePath)) {
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
                            Task { await coordinator.resolve(conflict, as: .keepBoth) }
                        }
                        Button(L("Keep This Device's Copy")) {
                            Task { await coordinator.resolve(conflict, as: .useLocal) }
                        }
                        Button(L("Keep iCloud's Copy")) {
                            Task { await coordinator.resolve(conflict, as: .useRemote) }
                        }
                    }
                }

                Section(footer: Text(L("Applies your choice to every conflict above."))) {
                    Button(L("Keep Both, Everywhere")) {
                        Task { await coordinator.resolveAllConflicts(as: .keepBoth) }
                    }
                    Button(L("Keep This Device Everywhere")) {
                        Task { await coordinator.resolveAllConflicts(as: .useLocal) }
                    }
                    Button(L("Keep iCloud Everywhere")) {
                        Task { await coordinator.resolveAllConflicts(as: .useRemote) }
                    }
                }
            }
        }
        .navigationTitle(L("Sync Conflicts"))
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
