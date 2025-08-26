// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import GameController

internal enum PlatformKind { case ios, tvos }

internal struct PauseMenuView: View {
  @Binding var selectedSlot: Int
  let onClose: () -> Void
  let onShowSettings: () -> Void
  let platform: PlatformKind
  let game: TVGameItem

  @FocusState private var focused: FocusField?
      internal enum FocusField: Hashable { case resume, openSaves, cheats, mapping, settings, exit, back, slot(Int), save, load }
    private enum Pane { case main, saves, cheats, controllers }
    @State private var pane: Pane = .main

  var body: some View {
    ZStack {
      // Full screen black background
      Color.black
        .ignoresSafeArea()


                  switch pane {
            case .main:
                mainMenu
                    .onAppear { NSLog("[PAUSE] Main menu appeared") }
            case .saves:
                savesMenu
                    .onAppear { NSLog("[PAUSE] Saves menu appeared") }
            case .cheats:
                CheatsMenuView(game: game, onBack: { pane = .main })
                    .onAppear { NSLog("[PAUSE] Cheats menu appeared") }
            case .controllers:
                ControllerMappingView(game: game, onBack: { pane = .main })
                    .onAppear { NSLog("[PAUSE] Controller mapping menu appeared") }
            }
    }
    .onAppear { NSLog("[PAUSE] PauseMenuView appeared") }
    .focusSection()
    .onChange(of: pane) { p in
      DispatchQueue.main.async {
        switch p {
        case .main:
          focused = .resume
        case .saves:
          focused = .back
        case .cheats:
          focused = .back
        case .controllers:
          focused = .back
        }
      }
    }
    .onExitCommand {
      if pane == .main {
        onClose()
      } else {
        pane = .main
      }
    }
    .defaultFocus($focused, .resume)
  }

  private var mainMenu: some View {
    ZStack {
      // Beautiful blurred background
      Image(uiImage: game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 25)
        .opacity(0.8)
        .ignoresSafeArea()

      // Elegant gradient overlay
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

      // Netflix-style content overlay
      HStack(spacing: 80) {
        // Left side - Game cover and info
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

        // Right side - Menu options
        VStack(alignment: .leading, spacing: 24) {
          // Hero resume button
          Button(action: { TVEmulationBridge.resume(); onClose() }) {
            HStack(spacing: 16) {
              Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .bold))
              Text(L("Resume Game"))
                .font(.system(size: 20, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .background(
              LinearGradient(
                colors: [Color.blue, Color.purple],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .blue.opacity(0.5), radius: 12, x: 0, y: 6)
          }
          .buttonStyle(.plain)
          .focused($focused, equals: .resume)

          // Menu items with SettingsMenuRow styling
          VStack(spacing: 12) {
            // Save States
            Button(action: { pane = .saves }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Save States"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text("Manage game saves")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.white.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.white.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .openSaves)

            // Cheats
            Button(action: { pane = .cheats }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "star.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Cheats"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text(L("Game enhancement codes"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.white.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.white.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .cheats)

            // Controllers
            Button(action: { pane = .controllers }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "gamecontroller")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Controllers"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text("Input configuration")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.white.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.white.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .mapping)

            // Settings
            Button(action: { onShowSettings() }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Settings"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text("Game & system options")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.white.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.white.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .settings)

            // Exit Game
            Button(action: { NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil) }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.red.opacity(0.15))
                    .frame(width: 48, height: 48)

                  Image(systemName: "xmark.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.red)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Exit Game"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.red)

                  Text("Return to library")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.red.opacity(0.7))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.red.opacity(0.5))
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 16)
              .background(.red.opacity(0.05))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .exit)
          }
        }
        .frame(width: 480)
      }
      .padding(60)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .zIndex(100)
    }
    .animation(.easeInOut(duration: 0.3), value: focused)
  }

  private var savesMenu: some View {
    ZStack {
      // Beautiful blurred background
      Image(uiImage: game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 25)
        .opacity(0.8)
        .ignoresSafeArea()

      // Elegant gradient overlay
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

      // Content with proper layout
      VStack(spacing: 40) {
        // Header with back button and title
        HStack {
          Button(action: { pane = .main }) {
            HStack(spacing: 12) {
              Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
              Text("Back to Menu")
                .font(.system(size: 18, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .buttonStyle(.plain)
          .focused($focused, equals: .back)

          Spacer()

          VStack(spacing: 4) {
            Text(L("Save States"))
              .font(.system(size: 28, weight: .bold))
              .foregroundColor(.white)

            Text("Manage your game progress")
              .font(.system(size: 16, weight: .medium))
              .foregroundColor(.white.opacity(0.7))
          }

          Spacer()
        }

        // Save slot selection
        VStack(spacing: 24) {
          Text(L("Select Save Slot"))
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(1...10, id: \.self) { i in
                Button(action: { selectedSlot = i }) {
                  VStack(spacing: 4) {
                    ZStack {
                      RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selectedSlot == i ? .blue.opacity(0.3) : .white.opacity(0.1))
                        .frame(width: 44, height: 44)

                      VStack(spacing: 1) {
                        if selectedSlot == i {
                          Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.blue)
                        } else {
                          Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                        }

                        Text("\(i)")
                          .font(.system(size: 10, weight: .semibold))
                          .foregroundColor(selectedSlot == i ? .blue : .white)
                      }
                    }

                    Text("Slot \(i)")
                      .font(.system(size: 8, weight: .medium))
                      .foregroundColor(.white.opacity(0.7))
                  }
                }
                .buttonStyle(.plain)
                .focused($focused, equals: .slot(i))
              }
            }
            .padding(.horizontal, 30)
          }
        }

        // Action buttons
        HStack(spacing: 24) {
          Button(action: { TVEmulationBridge.saveState(toSlot: selectedSlot, wait: true) }) {
            HStack(spacing: 12) {
              Image(systemName: "square.and.arrow.down")
                .font(.system(size: 16, weight: .semibold))
              Text(L("Save to Slot \(selectedSlot)"))
                .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.green.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.green.opacity(0.4), lineWidth: 1)
            )
          }
          .buttonStyle(.plain)
          .focused($focused, equals: .save)

          Button(action: { TVEmulationBridge.loadState(fromSlot: selectedSlot) }) {
            HStack(spacing: 12) {
              Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
              Text(L("Load from Slot \(selectedSlot)"))
                .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.blue.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.blue.opacity(0.4), lineWidth: 1)
            )
          }
          .buttonStyle(.plain)
          .focused($focused, equals: .load)
        }
        .frame(maxWidth: 600)
      }
      .padding(60)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .zIndex(100)
    }
    .onExitCommand { pane = .main }
  }


}
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
                Text(statusMessage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
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
        statusMessage = L("Downloading cheats...")

        TVCheatsBridge.downloadGeckoCodes(forGameId: game.gameID, revision: game.revision, gametdbId: game.gametdbID) { success, downloadedCount, addedCount in
            DispatchQueue.main.async {
                isLoading = false
                if success {
                    statusMessage = L("✓ Downloaded \(downloadedCount) cheats, added \(addedCount) new")
                    loadCheats()
                } else {
                    statusMessage = L("✗ Failed to download cheats")
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

// MARK: - Modern Action Card
internal struct ModernActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let isLoading: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 50, height: 50)

                    if isLoading && isFocused {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(color)
                    }
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Arrow
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(20)
            .background(.white.opacity(isFocused ? 0.15 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(color.opacity(isFocused ? 0.6 : 0), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .disabled(isLoading)
    }
}

// MARK: - Modern Cheat Section
internal struct ModernCheatSection: View {
    let title: String
    let codes: [ModernCheatItem]
    let onToggle: (Int, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            HStack {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                Text("\(codes.count) codes")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }

            // Codes Grid
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ], spacing: 16) {
                ForEach(Array(codes.enumerated()), id: \.offset) { index, code in
                    ModernCheatCard(
                        item: code,
                        index: index,
                        onToggle: { enabled in
                            onToggle(index, enabled)
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Modern Cheat Item
internal enum ModernCheatItem {
    case gecko(TVGeckoCodeInfo)
    case actionReplay(TVActionReplayCodeInfo)

    var name: String {
        switch self {
        case .gecko(let code): return code.name
        case .actionReplay(let code): return code.name
        }
    }

    var isEnabled: Bool {
        switch self {
        case .gecko(let code): return code.enabled
        case .actionReplay(let code): return code.enabled
        }
    }

    var type: String {
        switch self {
        case .gecko: return "GECKO"
        case .actionReplay: return "AR"
        }
    }

    var typeColor: Color {
        switch self {
        case .gecko: return .blue
        case .actionReplay: return .orange
        }
    }
}

// MARK: - Modern Cheat Card
internal struct ModernCheatCard: View {
    let item: ModernCheatItem
    let index: Int
    let onToggle: (Bool) -> Void

    @State private var isEnabled: Bool
    @FocusState private var isFocused: Bool

    init(item: ModernCheatItem, index: Int, onToggle: @escaping (Bool) -> Void) {
        self.item = item
        self.index = index
        self.onToggle = onToggle
        self._isEnabled = State(initialValue: item.isEnabled)
    }

    var body: some View {
        Button(action: { toggleCheat() }) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    // Type Badge
                    Text(item.type)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(item.typeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Spacer()

                    // Toggle
                    ZStack {
                        Circle()
                            .fill(isEnabled ? .green : .white.opacity(0.3))
                            .frame(width: 20, height: 20)

                        if isEnabled {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }

                // Name
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                Spacer()
            }
            .padding(16)
            .frame(height: 120)
            .background(.white.opacity(isFocused ? 0.15 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(isFocused ? 0.3 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
    }

    private func toggleCheat() {
        let newState = !isEnabled
        onToggle(newState)
        isEnabled = newState
    }
}

// MARK: - Modern Empty State
internal struct ModernEmptyState: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.white.opacity(0.4))

            VStack(spacing: 8) {
                Text(L("No Cheats Available"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)

                Text(L("Download cheats to get started"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(40)
    }
}

// MARK: - Modern Style Card
internal struct ModernStyleCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let isLoading: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 50, height: 50)

                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(color)
                    }
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Arrow
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(20)
            .background(.white.opacity(isFocused ? 0.15 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(color.opacity(isFocused ? 0.6 : 0), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .disabled(isLoading)
    }
}

// Pause menu row component matching SettingsMenuRow styling
private struct PauseMenuRow: View {
  let icon: String
  let title: String
  let subtitle: String
  let isDestructive: Bool
  let action: () -> Void

  init(icon: String, title: String, subtitle: String, isDestructive: Bool = false, action: @escaping () -> Void) {
    self.icon = icon
    self.title = title
    self.subtitle = subtitle
    self.isDestructive = isDestructive
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 20) {
        // Icon with background
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isDestructive ? .red.opacity(0.15) : .white.opacity(0.1))
            .frame(width: 48, height: 48)

          Image(systemName: icon)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(isDestructive ? .red : .white)
        }

        // Text content
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(isDestructive ? .red : .white)

          Text(subtitle)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(isDestructive ? .red.opacity(0.7) : .white.opacity(0.7))
        }

        Spacer()

        // Chevron
        Image(systemName: "chevron.right")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(isDestructive ? .red.opacity(0.5) : .white.opacity(0.5))
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(isDestructive ? .red.opacity(0.05) : .white.opacity(0.05))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

/// Card container used in the tvOS pause overlay
private struct TvOSCard<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title).font(.headline)
        Spacer()
      }
      content
    }
    .padding(16)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

/// Uniform action button used in the tvOS pause overlay
private struct ActionButton: View {
  let title: String
  let equals: PauseMenuView.FocusField
  let action: () -> Void
  let focused: FocusState<PauseMenuView.FocusField?>.Binding
  init(_ title: String, equals: PauseMenuView.FocusField, focused: FocusState<PauseMenuView.FocusField?>.Binding, action: @escaping () -> Void) {
    self.title = title
    self.equals = equals
    self.action = action
    self.focused = focused
  }
  var body: some View {
    Button(title, action: action)
      .buttonStyle(.bordered)
      .frame(maxWidth: .infinity)
      .focused(focused, equals: equals)
  }
}

/// Slots grid with tvOS focus
private struct SlotsGrid: View {
  @Binding var selectedSlot: Int
  let focused: FocusState<PauseMenuView.FocusField?>.Binding
  private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(1...10, id: \.self) { i in
        Button(action: { selectedSlot = i }) {
          HStack {
            if selectedSlot == i { Image(systemName: "checkmark") }
            Text("Slot \(i)")
            Spacer()
          }
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .focused(focused, equals: .slot(i))
      }
    }
  }
}

internal struct ControllerMappingView: View {
  @State private var controllers: [GCController] = []
  @State private var currentQualifiers: [Int: String] = [:] // portOneBased -> qualifier
  @State private var showPickerForPort: Int?
  let game: TVGameItem
  let onBack: () -> Void

  @FocusState private var focused: FocusField?
  private enum FocusField: Hashable {
    case back
    case assign(Int)
    case clear(Int)
  }

  private func reload() {
    controllers = GCController.controllers()
    for port in 1...4 {
      currentQualifiers[port] = TVControllerMappingBridge.defaultDevice(forGCPort: port) as String
    }
  }

  var body: some View {
    ZStack {
      // Beautiful blurred background
      Image(uiImage: game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 25)
        .opacity(0.8)
        .ignoresSafeArea()

      // Elegant gradient overlay
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

      // Content with proper layout
      VStack(spacing: 40) {
        // Header with back button and title
        HStack {
          Button(action: { onBack() }) {
            HStack(spacing: 12) {
              Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
              Text(L("Back to Menu"))
                .font(.system(size: 18, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .buttonStyle(.plain)
          .focusable()
          .focused($focused, equals: .back)

          Spacer()

          VStack(spacing: 4) {
            Text(L("Controller Mapping"))
              .font(.system(size: 28, weight: .bold))
              .foregroundColor(.white)

            Text(L("Configure input devices"))
              .font(.system(size: 16, weight: .medium))
              .foregroundColor(.white.opacity(0.7))
          }

          Spacer()
        }

        // Player cards
        VStack(spacing: 20) {
          ForEach(1...4, id: \.self) { port in
            VStack(spacing: 16) {
              // Player info
              HStack(spacing: 20) {
                // Player icon
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "person.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Player info
                VStack(alignment: .leading, spacing: 4) {
                  Text("Player \(port)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text((currentQualifiers[port] ?? "").isEmpty ? L("No controller assigned") : (currentQualifiers[port] ?? ""))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                }

                Spacer()
              }

              // Action buttons - separate row for better focus
              HStack(spacing: 20) {
                Button(action: {
                  NSLog("[CONTROLLER] Assign button pressed for port \(port)")
                  showPickerForPort = port
                }) {
                  HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text(L("Assign"))
                  }
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundColor(.white)
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 12)
                  .background(.blue.opacity(0.3))
                  .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focused($focused, equals: .assign(port))

                Button(action: {
                  NSLog("[CONTROLLER] Clear button pressed for port \(port)")
                  TVControllerMappingBridge.clearDefaultDevice(forGCPort: port)
                  reload()
                }) {
                  HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                    Text(L("Clear"))
                  }
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundColor(.white.opacity(0.8))
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 12)
                  .background(.white.opacity(0.2))
                  .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focused($focused, equals: .clear(port))
              }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
        }

        // Connected controllers section
        VStack(alignment: .leading, spacing: 16) {
          Text("Connected Controllers")
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)

          if controllers.isEmpty {
            VStack(spacing: 12) {
              Image(systemName: "gamecontroller")
                .font(.system(size: 32, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

              Text(L("No controllers connected"))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            }
            .padding(24)
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          } else {
            VStack(spacing: 8) {
              ForEach(Array(controllers.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 16) {
                  ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                      .fill(.white.opacity(0.1))
                      .frame(width: 32, height: 32)

                    Image(systemName: "gamecontroller.fill")
                      .font(.system(size: 14, weight: .medium))
                      .foregroundColor(.white)
                  }

                  VStack(alignment: .leading, spacing: 2) {
                    Text(c.vendorName ?? c.productCategory)
                      .font(.system(size: 16, weight: .medium))
                      .foregroundColor(.white)

                    Text(c.productCategory)
                      .font(.system(size: 12, weight: .medium))
                      .foregroundColor(.white.opacity(0.6))
                  }

                  Spacer()

                  Text("P\(c.playerIndex.rawValue + 1)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              }
            }
          }
        }
      }
      .padding(60)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .zIndex(100)
    }
    .focusSection()
    .defaultFocus($focused, .back)
    .onAppear { reload() }
    .onExitCommand { onBack() }
    .sheet(isPresented: Binding(get: { showPickerForPort != nil }, set: { if !$0 { showPickerForPort = nil } })) {
      if let port = showPickerForPort {
        ControllerPickerSheet(port: port) { selected in
          if let idx = selected, controllers.indices.contains(idx) {
            TVControllerMappingBridge.assign(controllers[idx], toGCPort: port)
            reload()
          }
          showPickerForPort = nil
        }
      }
    }
  }
}

private struct ControllerPickerSheet: View {
  let port: Int
  let onDone: (Int?) -> Void // selected controller index or nil
  @Environment(\.dismiss) private var dismiss
  @State private var controllers: [GCController] = []
  @State private var selection: Int?

  var body: some View {
    NavigationStack {
      List {
        ForEach(Array(controllers.enumerated()), id: \.offset) { idx, c in
          Button(action: {
            selection = idx
            // Assign controller immediately when selected
            if controllers.indices.contains(idx) {
              TVControllerMappingBridge.assign(controllers[idx], toGCPort: port)
              NSLog("[CONTROLLER] Immediately assigned controller \(c.vendorName ?? c.productCategory) to port \(port)")
            }
          }) {
            HStack {
              VStack(alignment: .leading) {
                Text(c.vendorName ?? c.productCategory)
                Text(c.productCategory).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if selection == idx { Image(systemName: "checkmark") }
            }
          }
          .buttonStyle(.plain)
        }
      }
      .navigationTitle(L("Assign to Player \(port)"))
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(L("Cancel")) {
            onDone(nil)
            dismiss()
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(L("Done")) {
            onDone(selection)
            dismiss()
          }
        }
      }
      .onAppear { controllers = GCController.controllers() }
      .onExitCommand {
        // When B is pressed, still call onDone to refresh the parent view
        onDone(selection)
        dismiss()
      }
    }
  }
}

// Real cheat row component for displaying actual cheat codes
private struct RealCheatRow: View {
  let title: String
  @State var isEnabled: Bool
  let isUserDefined: Bool
  let onToggle: (Bool) -> Void

  var body: some View {
    HStack(spacing: 16) {
      // Cheat info
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)

          if isUserDefined {
            Text(L("USER"))
              .font(.system(size: 10, weight: .bold))
              .foregroundColor(.orange)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.orange.opacity(0.2))
              .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
        }

        Text(isEnabled ? L("Enabled") : L("Disabled"))
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(isEnabled ? .green : .white.opacity(0.7))
      }

      Spacer()

      // Toggle switch
      Button(action: {
        isEnabled.toggle()
        onToggle(isEnabled)
      }) {
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isEnabled ? .green : .white.opacity(0.2))
            .frame(width: 50, height: 30)

          Circle()
            .fill(.white)
            .frame(width: 26, height: 26)
            .offset(x: isEnabled ? 10 : -10)
        }
      }
      .buttonStyle(.plain)
      .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.white.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
