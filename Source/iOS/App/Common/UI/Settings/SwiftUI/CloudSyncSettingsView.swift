// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVCloudSync
import PVSyncRules
import SwiftUI

/// Settings surface for iCloud sync: the toggle, why it is or is not running,
/// per-category counts, conflicts, and the recent log.
///
/// The "why" is the point. iCube's CloudKit container is not provisioned yet, so
/// the shipping state of this screen is "off, and here is the reason" — a toggle
/// that silently does nothing would be worse than no toggle.
struct CloudSyncSettingsView: View {

    @ObservedObject private var coordinator = CloudSyncCoordinator.shared
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            statusSection
            if coordinator.isEnabled {
                if !coordinator.pendingConflicts.isEmpty {
                    conflictsSection
                }
                contentsSection
                maintenanceSection
                if !coordinator.recentEvents.isEmpty {
                    activitySection
                }
            }
            scopeSection
        }
        .navigationTitle(L("iCloud Sync"))
        .task { await coordinator.refreshAvailability() }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section(header: Text(L("iCloud Sync")), footer: statusFooter) {
            HStack {
                Label(L("Sync This Device"), systemImage: "icloud")
                Spacer()
                // Deliberately NOT disabled when sync is unavailable. Turning it
                // on with no container is harmless — the engine runs, scans
                // locally, finds no cloud, and says so in the footer — and it
                // is what makes this whole screen exercisable on a build that
                // has no CloudKit container, which is every build today.
                Toggle("", isOn: $coordinator.isEnabled)
                    .labelsHidden()
            }

            if coordinator.isEnabled {
                HStack {
                    Text(L("Status"))
                    Spacer()
                    SyncStatusIndicator()
                }
                if let lastSync = coordinator.statistics.lastSyncDate {
                    HStack {
                        Text(L("Last Synced"))
                        Spacer()
                        Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
                Button(L("Sync Now")) {
                    Task { await coordinator.syncNow() }
                }
                .disabled(coordinator.isSyncing || coordinator.unavailableReason != nil)
            }
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let reason = coordinator.unavailableReason {
            Text(reason.localizedDescription)
                .foregroundStyle(.orange)
        } else if let error = coordinator.lastError {
            Text(error).foregroundStyle(.red)
        } else {
            Text(L("Save states, memory cards, Wii saves and settings are kept in step across your devices. Games are never uploaded."))
        }
    }

    // MARK: - Per-category counts

    private var contentsSection: some View {
        Section(header: Text(L("Synced Contents"))) {
            if coordinator.statistics.totalFiles == 0 {
                Text(L("Nothing synced yet."))
                    .foregroundStyle(.secondary)
            } else {
                // Stable order so the list does not reshuffle between syncs.
                ForEach(SyncableFileType.allCases.sorted { $0.pullPriority < $1.pullPriority }, id: \.self) { type in
                    let count = coordinator.statistics.countsByType[type] ?? 0
                    if count > 0 {
                        HStack {
                            Text(Self.displayName(for: type))
                            Spacer()
                            Text("\(count)").foregroundStyle(.secondary)
                            Text(Self.formattedBytes(coordinator.statistics.bytesByType[type] ?? 0))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack {
                    Text(L("Total"))
                    Spacer()
                    Text("\(coordinator.statistics.totalFiles)").foregroundStyle(.secondary)
                    Text(coordinator.statistics.formattedTotalSize)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if coordinator.statistics.errorFiles > 0 {
                    HStack {
                        Text(L("Files With Errors"))
                        Spacer()
                        Text("\(coordinator.statistics.errorFiles)").foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Conflicts

    private var conflictsSection: some View {
        Section(header: Text(L("Needs Your Decision"))) {
            NavigationLink(destination: SyncConflictResolutionView()) {
                HStack {
                    Label(L("Conflicts"), systemImage: "exclamationmark.icloud.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("\(coordinator.pendingConflicts.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Maintenance

    private var maintenanceSection: some View {
        Section(footer: Text(L("Removes this app's data from iCloud. Files on this device are not touched."))) {
            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Text(L("Clear iCloud Data"))
            }
            .disabled(coordinator.isSyncing)
            .confirmationDialog(
                L("Remove all iCube data from iCloud?"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(L("Clear iCloud Data"), role: .destructive) {
                    Task { await coordinator.clearCloudData() }
                }
                Button(L("Cancel"), role: .cancel) {}
            }
        }
    }

    // MARK: - Activity log

    private var activitySection: some View {
        Section(header: Text(L("Recent Activity"))) {
            ForEach(coordinator.recentEvents.prefix(20)) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.message)
                        .font(.footnote)
                    if let file = event.file {
                        Text(file)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        }
    }

    // MARK: - Scope

    /// States the policy plainly, because "what gets uploaded" is the question
    /// people actually have about a sync feature.
    private var scopeSection: some View {
        Section(header: Text(L("What Is Synced"))) {
            Label(L("Save states and resume points"), systemImage: "checkmark")
            Label(L("GameCube memory cards"), systemImage: "checkmark")
            Label(L("Wii save data"), systemImage: "checkmark")
            Label(L("Settings, per-game settings and cheats"), systemImage: "checkmark")
            Label(L("Games are never uploaded"), systemImage: "xmark")
                .foregroundStyle(.secondary)
            Label(L("Cover art is not uploaded — it is re-downloaded instead"), systemImage: "xmark")
                .foregroundStyle(.secondary)
            Label(L("System firmware is never uploaded"), systemImage: "xmark")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatting

    static func displayName(for type: SyncableFileType) -> String {
        switch type {
        case .saveState: return L("Save States")
        case .resumeState: return L("Resume Points")
        case .saveStateMetadata: return L("Save Details")
        case .saveStateThumbnail: return L("Save Thumbnails")
        case .gameCubeMemoryCard: return L("Memory Cards")
        case .wiiSave: return L("Wii Saves")
        case .config: return L("Settings")
        case .gameSettings: return L("Per-Game Settings & Cheats")
        }
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
