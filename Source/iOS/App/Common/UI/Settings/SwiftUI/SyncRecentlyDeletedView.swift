// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVCloudSync
import SwiftUI

/// Files iCloud sync removed from this device because another device deleted
/// them. Kept for 30 days; restorable with one tap.
///
/// Every delete the engine performs locally lands here. A save that vanishes
/// because of a tap on another device is a bad surprise; being able to undo it
/// is what makes propagating deletes acceptable at all.
struct SyncRecentlyDeletedView: View {

    @ObservedObject private var coordinator = CloudSyncCoordinator.shared
    @State private var pendingPermanentDelete: SyncTrashEntry?

    var body: some View {
        Form {
            if coordinator.trashEntries.isEmpty {
                Section {
                    Text(L("Nothing here. Files removed by a delete on another device appear here for 30 days."))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(footer: Text(L("Restoring a file brings it back on every device."))) {
                    ForEach(coordinator.trashEntries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.relativePath)
                                .font(.footnote)
                                .lineLimit(2)
                                .truncationMode(.head)
                            HStack {
                                Text(entry.deletedAt.formatted(date: .abbreviated, time: .shortened))
                                Text(CloudSyncSettingsView.formattedBytes(entry.fileSize))
                                Spacer()
                                Button(L("Restore")) {
                                    Task { await coordinator.restoreFromTrash(entry) }
                                }
                                .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    pendingPermanentDelete = entry
                                } label: {
                                    Text(L("Delete"))
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(L("Recently Deleted"))
        .task { await coordinator.refreshTrash() }
        .confirmationDialog(
            L("Delete this file for good?"),
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: { if !$0 { pendingPermanentDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Delete Permanently"), role: .destructive) {
                if let entry = pendingPermanentDelete {
                    Task { await coordinator.deleteFromTrash(entry) }
                }
                pendingPermanentDelete = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingPermanentDelete = nil }
        }
    }
}
