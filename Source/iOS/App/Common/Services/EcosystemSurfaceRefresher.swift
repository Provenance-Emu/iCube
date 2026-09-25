// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
// Spotlight, quick actions and the widget are all iOS-only surfaces (see the individual types).
#if !os(tvOS)
import PVLibrarySnapshot
import WidgetKit

/// Refreshes every OS-level surface driven by the library snapshot — the Spotlight index,
/// home-screen quick actions, and the RecentGamesWidget timeline — after every snapshot write.
/// Called from `LibrarySnapshotWriter`, already off the main thread; only the quick-actions
/// update needs to hop back to it (`UIApplication.shared.shortcutItems`).
enum EcosystemSurfaceRefresher {
    static func refresh(with snapshot: LibrarySnapshot) async {
        SpotlightSnapshotIndexer.indexSnapshotGames(snapshot)
        await MainActor.run { QuickActionsUpdater.update(with: snapshot) }
        WidgetCenter.shared.reloadTimelines(ofKind: RecentGamesWidgetKind.identifier)
    }
}
#endif
