// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import GameController
#if os(iOS)
#endif

internal enum PlatformKind { case ios, tvos }

internal struct PauseMenuView: View {
  @Binding var selectedSlot: Int
  let onClose: () -> Void
  let onShowSettings: () -> Void
  let platform: PlatformKind
  let game: TVGameItem

  @FocusState private var focused: FocusField?
  internal enum FocusField: Hashable { case resume, openSaves, cheats, mapping, settings, shaders, exit, back, slot(Int), save, load }
  private enum Pane { case main, saves, cheats, controllers }
  @State private var pane: Pane = .main
  @State private var showExitDialog: Bool = false
  @State private var showShaders: Bool = false
  @State private var showSettingsSheet: Bool = false
  @State private var showFilmstripSheet: Bool = false

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
    .onAppear {
      NSLog("[PAUSE] PauseMenuView appeared")
      #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
      GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
      #endif
      TVEmulationBridge.pause()
    }
    .onDisappear {
      if TVEmulationBridge.isRunning() && TVEmulationBridge.isPaused() { TVEmulationBridge.resume() }
    }
#if os(tvOS)
    .focusSection()
#endif
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
#if os(tvOS)
    .onExitCommand {
      if pane == .main {
        onClose()
      } else {
        pane = .main
      }
    }
#endif
    .modifier(DefaultFocusCompat(focused: $focused, value: .resume))
    .sheet(isPresented: $showShaders) {
      NavigationStack {
        ShaderSettingsView()
          .navigationTitle(L("Shaders"))
      }
#if os(tvOS)
      .focusSection()
#endif
    }
#if os(iOS)
    .sheet(isPresented: $showSettingsSheet) {
      NavigationStack {
        SettingsRootView()
          .navigationTitle(L("Settings"))
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Close")) { showSettingsSheet = false } } }
      }
    }
#endif
  }

  // Add pull-down to dismiss for iOS
  #if os(iOS)
  init(selectedSlot: Binding<Int>, onClose: @escaping () -> Void, onShowSettings: @escaping () -> Void, platform: PlatformKind, game: TVGameItem) {
    self._selectedSlot = selectedSlot
    self.onClose = onClose
    self.onShowSettings = onShowSettings
    self.platform = platform
    self.game = game
  }
  #endif

  @ViewBuilder
  private var mainMenu: some View {
    if platform == .ios {
      iosMainMenu
    } else {
      tvMainMenu
    }
  }

  // iOS: compact layout with adaptive grid and safe-area background
  private var iosMainMenu: some View {
    let backgroundView = ZStack {
      // Use cover image for iOS (better aspect ratio fit)
      Image(uiImage: game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 24)
        .opacity(0.5)
        .ignoresSafeArea()
      LinearGradient(
        colors: [
          Color.black.opacity(0.85),
          Color.black.opacity(0.35),
          Color.black.opacity(0.85)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    }

    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Button(action: { onClose() }) {
            Text(L("Close"))
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(.white)
              .padding(.horizontal, 18)
              .padding(.vertical, 10)
              .background(
                Capsule(style: .continuous)
                  .fill(.ultraThinMaterial)
              )
              .overlay(
                Capsule(style: .continuous)
                  .stroke(Color.white.opacity(0.08), lineWidth: 1)
              )
          }
          .buttonStyle(.plain)
          Spacer()
        }

        HStack(alignment: .top, spacing: 12) {
          Image(uiImage: game.coverImage)
            .resizable()
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .frame(width: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          VStack(alignment: .leading, spacing: 4) {
            Text(game.title)
              .font(.headline)
              .foregroundStyle(.white)
            Text(game.gameID)
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.7))
          }
          Spacer(minLength: 0)
        }

        // Adaptive grid: 1 column portrait, 2+ landscape based on width automatically
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
          menuButtonIOS(title: L("Resume Game"), subtitle: L("Return to gameplay"), icon: "play.fill", tint: .blue) {
            TVEmulationBridge.resume(); onClose()
          }
          menuButtonIOS(title: L("Save States"), subtitle: L("Manage game saves"), icon: "square.stack.3d.up", tint: .purple) { pane = .saves }
          menuButtonIOS(title: L("Cheats"), subtitle: L("Game enhancement codes"), icon: "star.circle", tint: .yellow) { pane = .cheats }
          menuButtonIOS(title: L("Controllers"), subtitle: L("Input configuration"), icon: "gamecontroller", tint: .green) { pane = .controllers }
          menuButtonIOS(title: L("Shaders"), subtitle: L("Post-processing"), icon: "wand.and.stars", tint: .orange) { showShaders = true }
          #if os(iOS)
          menuButtonIOS(title: L("Settings"), subtitle: L("Game & system options"), icon: "gearshape", tint: .gray) { showSettingsSheet = true }
          #endif
          menuButtonIOS(title: L("Exit Game"), subtitle: L("Return to library"), icon: "xmark.circle", tint: .red, role: .destructive) { showExitDialog = true }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(backgroundView)
    .alert(L("Exit Game"), isPresented: $showExitDialog) {
      Button(L("Cancel"), role: .cancel) { showExitDialog = false }
      Button(L("Quit"), role: .destructive) {
        TVEmulationBridge.stop()
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      }
      Button(L("Save & Quit")) {
        TVEmulationBridge.saveState(toSlot: selectedSlot, wait: true)
        TVEmulationBridge.stop()
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      }
    } message: {
      Text(L("Do you want to quit the game? Unsaved progress will be lost."))
    }
  }

  /// Styled iOS pause menu row with icon and subtitle
  @ViewBuilder
  private func menuRowIOS(title: String, subtitle: String, icon: String, tint: Color) -> some View {
    HStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(tint.opacity(0.15))
          .frame(width: 44, height: 44)
        Image(systemName: icon)
          .font(.system(size: 18, weight: .semibold))
          .foregroundColor(tint)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.white)
        Text(subtitle)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(.white.opacity(0.7))
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white.opacity(0.5))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  /// Reusable iOS menu button applying consistent styling
  @ViewBuilder
  private func menuButtonIOS(title: String, subtitle: String, icon: String, tint: Color, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
    Button(role: role, action: action) {
      menuRowIOS(title: title, subtitle: subtitle, icon: icon, tint: tint)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        )
    }
    .buttonStyle(.plain)
  }

  // Platform-specific Settings button row
  @ViewBuilder
  private var settingsButtonRow: some View {
    #if os(tvOS)
    PauseMenuRow(
      icon: "gearshape",
      title: L("Settings"),
      subtitle: L("Game & system options"),
      action: { onShowSettings() }
    )
    .focused($focused, equals: .settings)
    #else
    EmptyView()
    #endif
  }

  // tvOS: original layout preserved
  private var tvMainMenu: some View {
    ZStack {
      // Beautiful blurred background - use GameBanner if available
      Image(uiImage: game.bannerImage ?? game.coverImage)
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
              Text(L("Resume Game"))
                .font(.system(size: 20, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .background(
              LinearGradient(
                colors: [Color(.dolphinTint), Color.purple],
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

            // Shaders
            Button(action: { showShaders = true }) {
              HStack(spacing: 20) {
                // Icon with background
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "wand.and.stars")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                  Text(L("Shaders"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  Text(L("Post-processing"))
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
            .focused($focused, equals: .shaders)

            // Settings
            settingsButtonRow

            // Exit Game
            Button(action: { showExitDialog = true }) {
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

                  Text(L("Return to library"))
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
      .alert(L("Exit Game"), isPresented: $showExitDialog) {
        Button(L("Cancel"), role: .cancel) { showExitDialog = false }
        Button(L("Quit"), role: .destructive) {
          TVEmulationBridge.stop()
          NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
        }
        Button(L("Save & Quit")) {
          TVEmulationBridge.saveState(toSlot: selectedSlot, wait: true)
          TVEmulationBridge.stop()
          NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
        }
      } message: {
        Text(L("Do you want to quit the game? Unsaved progress will be lost."))
      }
    }
    .animation(.easeInOut(duration: 0.3), value: focused)
  }

  private var savesMenu: some View {
    Group {
      if platform == .ios {
        NavigationStack {
          List {
            Section(header: Text(L("Quick Slots"))) {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                  ForEach(1...10, id: \.self) { i in
                    Button(action: { selectedSlot = i }) {
                      Label(String(format: L("Slot %d"), i), systemImage: selectedSlot == i ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.bordered)
                  }
                }
                .padding(.vertical, 4)
              }
            }
            Section(header: Text(L("Actions"))) {
              Button { TVEmulationBridge.saveState(toSlot: selectedSlot, wait: true); NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Saved to Slot %d"), selectedSlot)]) } label: {
                HStack { Image(systemName: ControllerGlyphs.glyphName(for: "confirm", set: ControllerStyleManager.shared.current())); Text(String(format: L("Save to Slot %d"), selectedSlot)) }
              }
              Button { TVEmulationBridge.loadState(fromSlot: selectedSlot); NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Loaded Slot %d"), selectedSlot)]) } label: {
                HStack { Image(systemName: "arrow.down.circle"); Text(String(format: L("Load Slot %d"), selectedSlot)) }
              }
              Button { showFilmstripSheet = true } label: {
                HStack { Image(systemName: "film"); Text(L("Open Filmstrip")) }
              }
            }
          }
          .navigationTitle(L("Save States"))
          .toolbar(content: {
            ToolbarItem(placement: .navigationBarLeading) {
              Button(L("Back")) { pane = .main }
            }
          })
          .sheet(isPresented: $showFilmstripSheet) {
            NavigationStack { SaveStateFilmstripView(gameID: game.gameID) }
          }
        }
      } else {
        ZStack {
          // Beautiful blurred background - use GameBanner if available
          Image(uiImage: game.bannerImage ?? game.coverImage)
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

                Text(L("Manage your game progress"))
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

                        Text(L("Slot") + "\(i)")
                          .font(.system(size: 8, weight: .medium))
                          .foregroundColor(.white.opacity(0.7))
                      }
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .compositingGroup()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                  Text(L("Save to Slot") + "\(selectedSlot)")
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
                  Text(L("Load from Slot") + "\(selectedSlot)")
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
#if os(tvOS)
        .onExitCommand { pane = .main }
#endif
      }
    }
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

#if DEBUG
import UIKit
private func makePreviewGame() -> TVGameItem {
  let clsName = "TVGameItem"
  if let cls = NSClassFromString(clsName) as? NSObject.Type {
    let obj = cls.init()
    let img = UIImage(systemName: "gamecontroller")?.withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage()
    obj.setValue("Preview Game", forKey: "title")
    obj.setValue("RMCP01", forKey: "gameID")
    obj.setValue(img, forKey: "coverImage")
    return unsafeBitCast(obj, to: TVGameItem.self)
  }
  fatalError("TVGameItem class not found for preview")
}

#Preview("iPhone Portrait") {
  PauseMenuView(
    selectedSlot: .constant(1),
    onClose: {},
    onShowSettings: {},
    platform: .ios,
    game: makePreviewGame()
  )
}

#Preview("iPhone Landscape") {
  PauseMenuView(
    selectedSlot: .constant(1),
    onClose: {},
    onShowSettings: {},
    platform: .ios,
    game: makePreviewGame()
  )
  .previewInterfaceOrientation(.landscapeLeft)
}
#endif

private struct DefaultFocusCompat<Value: Hashable>: ViewModifier {
  var focused: FocusState<Value?>.Binding
  let value: Value
  func body(content: Content) -> some View {
    if #available(iOS 17, tvOS 17, *) {
      content.defaultFocus(focused, value)
    } else {
      content
    }
  }
}
