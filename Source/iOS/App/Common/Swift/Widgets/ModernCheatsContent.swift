// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

internal struct ModernCheatsContent: View {
  let game: TVGameItem
  let availableHeight: CGFloat

  @State private var geckoCodeList: [TVGeckoCodeInfo] = []
  @State private var actionReplayCodeList: [TVActionReplayCodeInfo] = []
  @State private var statusMessage = ""
  @State private var isLoading = false

  var body: some View {
    VStack(spacing: 24) {
      // Action Cards Section
      HStack(spacing: 24) {
        // Download Card
        ModernActionCard(
          title: L("Download Cheats"),
          subtitle: L("Get latest codes"),
          icon: "arrow.down.circle.fill",
          color: .blue,
          isLoading: isLoading
        ) {
          downloadCheats()
        }

        // Refresh Card
        ModernActionCard(
          title: L("Refresh List"),
          subtitle: L("Reload codes"),
          icon: "arrow.clockwise.circle.fill",
          color: .green,
          isLoading: isLoading
        ) {
          loadCheats()
        }
      }

      // Status Message
      if !statusMessage.isEmpty {
        if statusMessage.contains("✗") || statusMessage.contains("Failed") {
          // Show cute dolphin error for failures
          CompactDolphinError(message: statusMessage.replacingOccurrences(of: "✗ ", with: ""))
            .padding(.vertical, 8)
        } else {
          Text(statusMessage)
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(.white.opacity(0.8))
        }
      }

      // Cheats List - Scrollable
      ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(spacing: 16) {
          // Gecko Codes Section
          if !geckoCodeList.isEmpty {
            ModernCheatSection(
              title: L("Gecko Codes"),
              codes: geckoCodeList.map { ModernCheatItem.gecko($0) },
              onToggle: { index, enabled in
                let success = TVCheatsBridge.setGeckoCodeEnabled(enabled, at: index, forGameId: game.gameID, revision: game.revision)
                if success {
                  geckoCodeList[index].enabled = enabled
                }
              }
            )
          }

          // Action Replay Codes Section
          if !actionReplayCodeList.isEmpty {
            ModernCheatSection(
              title: L("Action Replay"),
              codes: actionReplayCodeList.map { ModernCheatItem.actionReplay($0) },
              onToggle: { index, enabled in
                let success = TVCheatsBridge.setActionReplayCodeEnabled(enabled, at: index, forGameId: game.gameID, revision: game.revision)
                if success {
                  actionReplayCodeList[index].enabled = enabled
                }
              }
            )
          }

          // Empty State
          if geckoCodeList.isEmpty && actionReplayCodeList.isEmpty && !isLoading {
            ModernEmptyState()
          }
        }
        .padding(.bottom, 40)
      }
      .frame(maxHeight: .infinity)
    }
    .onAppear {
      loadCheats()
    }
  }

  private func downloadCheats() {
    isLoading = true
    statusMessage = L("Downloading cheats") + "..."

    TVCheatsBridge.downloadGeckoCodes(forGameId: game.gameID, revision: game.revision, gametdbId: game.gametdbID) { success, downloadedCount, addedCount in
      DispatchQueue.main.async {
        isLoading = false
        if success {
          statusMessage = "✓" + " " + L("Downloaded") + "\(downloadedCount)" + L("cheats, added") + "\(addedCount)" + L("new")
          loadCheats()
        } else {
          statusMessage = L("✗") + " " + L("Failed to download cheats")
        }

        // Clear status after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
          statusMessage = ""
        }
      }
    }
  }

  private func loadCheats() {
    geckoCodeList = TVCheatsBridge.geckoCodes(forGameId: game.gameID, revision: game.revision)
    actionReplayCodeList = TVCheatsBridge.actionReplayCodes(forGameId: game.gameID, revision: game.revision)
  }
}
