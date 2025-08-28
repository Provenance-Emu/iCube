// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

struct CheatsMenuView: View {
    let game: TVGameItem
    let onBack: () -> Void

    @State private var geckoCodeList: [TVGeckoCodeInfo] = []
    @State private var actionReplayCodeList: [TVActionReplayCodeInfo] = []
    @State private var searchText: String = ""
    @FocusState private var focused: FocusField?

    enum FocusField: Hashable {
        case back
        case downloadCheats
        case refreshCheats
        case cheat(String)
    }

    var body: some View {
        ZStack {
            // Match parent background
            Image(uiImage: game.coverImage)
                .resizable()
                .scaledToFill()
                .blur(radius: 25)
                .opacity(0.8)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.85),
                    Color.black.opacity(0.4),
                    Color.black.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Match parent content structure
            HStack(spacing: 80) {
                // Left column — game cover + info, same as parent
                VStack(alignment: .leading, spacing: 16) {
                    Image(uiImage: game.coverImage)
                        .resizable()
                        .aspectRatio(2.0/3.0, contentMode: .fit)
                        .frame(width: 180, height: 270)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)

                        Text(game.gameID)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .frame(width: 180)

                // Right column — cheats UI
                VStack(alignment: .leading, spacing: 24) {
                    // Back button + title
                    HStack(alignment: .center, spacing: 20) {
                        Button(action: onBack) {
                            HStack(spacing: 12) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 18, weight: .medium))
                                Text(L("Back"))
                                    .font(.system(size: 18, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .focused($focused, equals: .back)

                        Text(L("Cheat Codes"))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                    }

                    // Search & actions
                    HStack(spacing: 24) {
                        // Search field (tvOS-friendly)
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.white.opacity(0.7))
                            TextField(L("Search cheats"), text: $searchText)
                                .textCase(.none)
                                .disableAutocorrection(true)
                                .textInputAutocapitalization(.never)
                                .foregroundColor(.white)
                                .tint(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: 360)

                        Button(action: {
                            TVCheatsBridge.downloadGeckoCodes(forGameId: game.gameID, revision: game.revision, gametdbId: game.gametdbID) { success, downloaded, added in
                                DispatchQueue.main.async { loadCheats() }
                            }
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Download Cheats"))
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(L("Get latest codes"))
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .foregroundColor(.white)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .focused($focused, equals: .downloadCheats)

                        Button(action: { loadCheats() }) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Refresh List"))
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(L("Reload codes"))
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .foregroundColor(.white)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .focused($focused, equals: .refreshCheats)
                    }

                    // Combined cheats list — clamped size like a page panel
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            let allCheats = createCombinedCheatList().filter { searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? true : $0.name.localizedCaseInsensitiveContains(searchText) || $0.type.localizedCaseInsensitiveContains(searchText) }
                            if allCheats.isEmpty {
                                VStack(spacing: 16) {
                                    Image(systemName: "gamecontroller")
                                        .font(.system(size: 40))
                                        .foregroundColor(.white.opacity(0.5))
                                    Text(L("No Cheats Available"))
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text(L("Download cheats to get started"))
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .padding(30)
                            } else {
                                ForEach(allCheats, id: \.id) { cheat in
                                    CheatRowView(
                                        cheat: cheat,
                                        isFocused: focused == .cheat(cheat.id),
                                        onToggle: { toggleCheat(cheat) }
                                    )
                                    .focused($focused, equals: .cheat(cheat.id))
                                }
                            }
                        }
                        .padding(.trailing, 10)
                    }
                    .frame(maxWidth: 820, maxHeight: 520) // clamp like a panel
                }
                .frame(maxWidth: 900, alignment: .leading) // clamp right column width
            }
            .padding(.horizontal, 60)
        }
      #if os(tvOS)
        .onExitCommand { onBack() }
        .focusSection()
      #endif
        .defaultFocus($focused, .back)
        .onAppear { loadCheats() }
    }

    private func createCombinedCheatList() -> [CheatItem] {
        var allCheats: [CheatItem] = []
        for (index, code) in geckoCodeList.enumerated() {
            allCheats.append(CheatItem(id: "gecko_\(index)", name: code.name, type: "Gecko Code", enabled: code.enabled, isGecko: true, index: index))
        }
        for (index, code) in actionReplayCodeList.enumerated() {
            allCheats.append(CheatItem(id: "ar_\(index)", name: code.name, type: "Action Replay", enabled: code.enabled, isGecko: false, index: index))
        }
        return allCheats
    }

    private func toggleCheat(_ cheat: CheatItem) {
        if cheat.isGecko {
            TVCheatsBridge.setGeckoCodeEnabled(!cheat.enabled, at: cheat.index, forGameId: game.gameID, revision: game.revision)
        } else {
            TVCheatsBridge.setActionReplayCodeEnabled(!cheat.enabled, at: cheat.index, forGameId: game.gameID, revision: game.revision)
        }
        loadCheats()
    }

    private func loadCheats() {
        geckoCodeList = TVCheatsBridge.geckoCodes(forGameId: game.gameID, revision: game.revision)
        actionReplayCodeList = TVCheatsBridge.actionReplayCodes(forGameId: game.gameID, revision: game.revision)
    }
}

struct CheatItem {
    let id: String
    let name: String
    let type: String
    let enabled: Bool
    let isGecko: Bool
    let index: Int
}

struct CheatRowView: View {
    let cheat: CheatItem
    let isFocused: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 20) {
                Image(systemName: cheat.enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(cheat.enabled ? .green : .white.opacity(0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Text(cheat.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                    Text(cheat.type)
                        .font(.system(size: 13))
                        .foregroundColor(cheat.isGecko ? .blue.opacity(0.8) : .orange.opacity(0.8))
                }
                Spacer()
                Text(cheat.enabled ? L("Enabled") : L("Disabled"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(cheat.enabled ? .green : .white.opacity(0.6))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isFocused ? 0.15 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(isFocused ? 0.35 : 0.1), lineWidth: isFocused ? 2 : 1)
                    )
            )
            .zIndex(isFocused ? 10 : 0)
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}
