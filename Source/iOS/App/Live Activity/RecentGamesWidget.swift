// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import PVLibrarySnapshot
import SwiftUI
import WidgetKit

/// Small = last game played, medium = last three. Cells link straight to
/// `dolphinios://play?id=`, the same URL Top Shelf and Siri intents use. Data comes from the App
/// Group snapshot (`LibrarySnapshotStore`); the app calls
/// `WidgetCenter.shared.reloadTimelines(ofKind:)` after every snapshot write
/// (`EcosystemSurfaceRefresher`).
struct RecentGamesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: RecentGamesWidgetKind.identifier, provider: RecentGamesTimelineProvider()) { entry in
            RecentGamesWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent Games")
        .description("Jump back into a recently played game.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RecentGamesEntry: TimelineEntry {
    let date: Date
    let games: [LibrarySnapshotGame]
}

struct RecentGamesTimelineProvider: TimelineProvider {
    static let maxGames = 3

    func placeholder(in context: Context) -> RecentGamesEntry {
        RecentGamesEntry(date: Date(), games: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentGamesEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentGamesEntry>) -> Void) {
        // The App Group snapshot only changes when the app rewrites it, and the app explicitly
        // reloads this widget's timeline when that happens (`EcosystemSurfaceRefresher`), so a
        // single never-expiring entry is correct — no need for WidgetKit's own refresh budget.
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> RecentGamesEntry {
        let snapshot = LibrarySnapshotStore().load()
        return RecentGamesEntry(date: Date(), games: Array(snapshot.recentlyPlayed.prefix(Self.maxGames)))
    }
}

struct RecentGamesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentGamesEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                HStack(spacing: 8) {
                    if entry.games.isEmpty {
                        emptyState
                    } else {
                        ForEach(entry.games) { game in
                            cell(for: game)
                        }
                    }
                }
            default:
                if let game = entry.games.first {
                    cell(for: game)
                } else {
                    emptyState
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func cell(for game: LibrarySnapshotGame) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            cover(for: game)
            Text(game.title)
                .font(.caption2)
                .fontWeight(.semibold)
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        if let url = game.launchURL {
            Link(destination: url) { content }
        } else {
            content
        }
    }

    @ViewBuilder
    private func cover(for game: LibrarySnapshotGame) -> some View {
        if let coverURL = game.coverURL, let data = try? Data(contentsOf: coverURL), let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(3.0 / 4.0, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.tertiary)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(Image(systemName: "gamecontroller").foregroundStyle(.secondary))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "gamecontroller")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No recent games")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
