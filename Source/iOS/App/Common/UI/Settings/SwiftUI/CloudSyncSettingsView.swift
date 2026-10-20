// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVCloudSync
import PVSyncRules
import SwiftUI

/// Settings surface for iCloud sync: the toggle, why it is or is not running,
/// what syncs and the opt-in switches, per-category counts, conflicts, the
/// trash, and the recent log.
///
/// The "why" is the point. iCube's CloudKit container is not provisioned yet, so
/// the shipping state of this screen is "off, and here is the reason" — a toggle
/// that silently does nothing would be worse than no toggle.
struct CloudSyncSettingsView: View {

    @ObservedObject private var coordinator = CloudSyncCoordinator.shared
    @State private var showClearConfirmation = false
    #if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsPaneBack) private var paneBack
    @Environment(\.icubeLeafParentTitle) private var parentTitle
    #endif

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        iosBody
        #endif
    }

    #if os(tvOS)
    private var tvBody: some View {
        MenuScreen(model: CloudSyncModelBuilder.make(snapshot, conflicts: AnyView(SyncConflictResolutionView())) { change in
            switch change {
            case .enabled(let on): coordinator.isEnabled = on
            case .syncNow: Task { await coordinator.syncNow() }
            case .clearCloudData: showClearConfirmation = true
            }
        }, style: .list, onBack: SettingsLeafScreen.backAction(paneBack: paneBack, dismiss: { dismiss() }),
                   tvHeader: SettingsLeafScreen.header(title: L("iCloud Sync"), parentTitle: parentTitle), tvInset: .xxl)
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
            .task { await coordinator.refreshAvailability() }
    }

    private var snapshot: CloudSyncSnapshot {
        CloudSyncSnapshot(
            isEnabled: coordinator.isEnabled,
            isSyncing: coordinator.isSyncing,
            unavailableReason: coordinator.unavailableReason?.localizedDescription,
            lastError: coordinator.lastError,
            lastSyncDate: coordinator.statistics.lastSyncDate,
            countsByType: coordinator.statistics.countsByType,
            bytesByType: coordinator.statistics.bytesByType,
            totalFiles: coordinator.statistics.totalFiles,
            formattedTotalSize: coordinator.statistics.formattedTotalSize,
            errorFiles: coordinator.statistics.errorFiles,
            pendingConflicts: coordinator.pendingConflicts.count,
            recentEvents: coordinator.recentEvents.map { ($0.message, $0.file) })
    }
    #endif

    private var iosBody: some View {
        Form {
            statusSection
            if coordinator.isEnabled, !coordinator.pendingConflicts.isEmpty {
                conflictsSection
            }
            scopeSection
            optInSection
            networkSection
            if coordinator.isEnabled {
                contentsSection
                recentlyDeletedSection
                if !coordinator.recentEvents.isEmpty {
                    activitySection
                }
                maintenanceSection
            }
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
        } else if coordinator.heldForWiFiCount > 0 {
            Text(L("Waiting for Wi-Fi to move large files. Saves and settings still sync on any connection."))
        } else {
            Text(L("Saves, memory cards, settings, controller layouts, favorites and play stats are kept in step across your devices. Games are never uploaded."))
        }
    }

    // MARK: - Scope

    /// States the policy plainly, because "what gets uploaded" is the question
    /// people actually have about a sync feature.
    private var scopeSection: some View {
        Section(header: Text(L("Always Synced"))) {
            Label(L("Save states and resume points"), systemImage: "checkmark")
            Label(L("GameCube memory cards, Wii and GBA saves"), systemImage: "checkmark")
            Label(L("Settings, controller setup and per-game settings & cheats"), systemImage: "checkmark")
            Label(L("Touch controls layout and skins"), systemImage: "checkmark")
            Label(L("Favorites, last played and play time"), systemImage: "checkmark")
            Label(L("Games are never uploaded"), systemImage: "xmark")
                .foregroundStyle(.secondary)
            Label(L("Custom titles, covers and classification tags"), systemImage: "checkmark")
        }
    }

    /// The categories that are the user's own dumps of system software. Off by
    /// default; each switch says what it moves and where it goes.
    private var optInSection: some View {
        Section(
            header: Text(L("Also Sync")),
            footer: Text(L("These go only to your own private iCloud storage, like any other backup. Nothing is shared with anyone."))
        ) {
            Toggle(isOn: $coordinator.policy.firmwareEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("GameCube Firmware"))
                    Text(L("Your IPL dump, about 2 MB per region."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: channelsBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Wii Channels & DLC"))
                    Text(L("Installed WiiWare, Virtual Console and downloadable content. Up to a few hundred MB."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(coordinator.policy.fullWiiNANDEnabled)
            Toggle(isOn: $coordinator.policy.fullWiiNANDEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Full Wii NAND"))
                    Text(L("Everything on the emulated Wii, including the System Menu. Includes channels. Can be 500 MB."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Channels read as on while the NAND switch covers them, without moving
    /// the stored value, so turning the NAND back off leaves channels as the
    /// user had them.
    private var channelsBinding: Binding<Bool> {
        Binding(
            get: { coordinator.policy.effectiveWiiChannelsEnabled },
            set: { coordinator.policy.wiiChannelsEnabled = $0 }
        )
    }

    private var networkSection: some View {
        Section(footer: Text(L("Applies to firmware, channels and the NAND. Saves and settings are small and always sync."))) {
            Toggle(L("Large Files Over Wi-Fi Only"), isOn: $coordinator.policy.largeFilesOverWiFiOnly)
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

    // MARK: - Recently Deleted

    private var recentlyDeletedSection: some View {
        Section(footer: Text(L("Files removed because they were deleted on another device are kept for 30 days."))) {
            NavigationLink(destination: SyncRecentlyDeletedView()) {
                HStack {
                    Label(L("Recently Deleted"), systemImage: "trash")
                    Spacer()
                    Text("\(coordinator.trashEntries.count)")
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

    // MARK: - Formatting

    static func displayName(for type: SyncableFileType) -> String {
        switch type {
        case .saveState: return L("Save States")
        case .resumeState: return L("Resume Points")
        case .saveStateMetadata: return L("Save Details")
        case .saveStateThumbnail: return L("Save Thumbnails")
        case .gameCubeMemoryCard: return L("Memory Cards")
        case .wiiSave: return L("Wii Saves")
        case .gbaSave: return L("GBA Saves")
        case .config: return L("Settings")
        case .gameSettings: return L("Per-Game Settings & Cheats")
        case .gameProfile: return L("Game Profiles and Library Edits")
        case .touchOverlayLayout: return L("Touch Controls Layout")
        case .libraryState: return L("Favorites & Play Stats")
        case .skin: return L("Controller Skins")
        case .firmware: return L("GameCube Firmware")
        case .wiiChannel: return L("Wii Channels & DLC")
        case .wiiSystem: return L("Wii System Files")
        }
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
