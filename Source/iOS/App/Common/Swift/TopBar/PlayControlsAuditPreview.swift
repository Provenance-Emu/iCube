// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if DEBUG
import SwiftUI
import UIKit

/// Read-only launch fixture for the external rendered audit. It is never a library/game destination.
struct PlayControlsAuditPreview: View {
  @State private var mode: QuickSaveMode
  @State private var selectedSlot = 4
  @State private var showPicker: Bool
  @State private var lastAction = "Ready"
  #if os(iOS)
  @State private var visibility = TopBarVisibility()
  @State private var paused = false
  @State private var fastForward = false
  @State private var muted = false
  @State private var controlsVisible = true
  @State private var pointerMode = PointerMode.touchFollow.rawValue
  @State private var fullscreen = false
  @State private var volume = 80
  @State private var toolbarHeight: CGFloat = 0
  #endif

  init() {
    let choice = TVRootView.argument(after: "-ICubePlayControlsPicker", in: ProcessInfo.processInfo.arguments)
    _mode = State(initialValue: choice == "slots" ? .slots : .history)
    #if os(iOS)
    _showPicker = State(initialValue: choice != nil)
    #else
    _showPicker = State(initialValue: true)
    #endif
  }

  var body: some View {
    ZStack {
      ICubeRoom(style: .gradient)
      VStack(spacing: ICubeDesign.Spacing.m.rawValue) {
        Spacer()
        Text("Read-only play-controls preview").icubeText(.tag)
        Text(lastAction).icubeText(.detail).accessibilityIdentifier("play-preview.last-action")
        #if os(iOS)
        Text("Toolbar height: \(Int(toolbarHeight))")
          .icubeText(.detail).accessibilityIdentifier("play-preview.toolbar-height")
        if !visibility.isVisible {
          Button("Reveal toolbar") { revealToolbar() }
            .buttonStyle(ICubeRowButtonStyle())
            .accessibilityIdentifier("play-preview.reveal")
        }
        #else
        if !showPicker { Button("Open save preview") { showPicker = true }.buttonStyle(ICubeRowButtonStyle()) }
        #endif
      }
      .padding(ICubeDesign.Spacing.l.rawValue)
      #if os(iOS)
      if visibility.isVisible { toolbar }
      #else
      if showPicker { picker }
      #endif
    }
    #if os(iOS)
    .sheet(isPresented: $showPicker) { picker.presentationDetents([.large]) }
    .onPreferenceChange(TopBarHeightKey.self) { toolbarHeight = $0 }
    .onAppear { revealToolbar() }
    #endif
  }

  private var picker: some View {
    QuickSavePickerView(gameID: "GALE01", mode: $mode, selectedSlot: $selectedSlot,
      onDismiss: { lastAction = "picker.done"; showPicker = false },
      operations: QuickSavePickerOperations(
        save: { mode, slot in lastAction = "picker.save.\(mode.rawValue).\(slot)"; return .cancelled },
        load: { state, _ in lastAction = "picker.load.\(state.path.lastPathComponent)"; return .cancelled },
        setKept: { state, kept, _ in lastAction = "picker.keep.\(kept).\(state.path.lastPathComponent)"; return .cancelled },
        slotDestination: { URL(fileURLWithPath: String(format: "/read-only-fixture/GALE01.s%02d", $0)) },
        saveSlot: { consent in lastAction = "picker.save.slots.\(consent.request.slot)"; return .cancelled },
        occupancy: { $0.lastPathComponent == "GALE01.s04" ? .occupied : .empty }),
      provider: PlayControlsFixtureProvider(), isModded: { false },
      readSessionIdentifier: { 1 }, sessionIsCurrent: { _, _ in true })
      .claimsController()
  }

  #if os(iOS)
  private var toolbar: some View {
    EmulationTopBar(visibility: $visibility, selectedSlot: $selectedSlot, isPaused: $paused,
      fastForwardEnabled: $fastForward, isWii: true, onScreenControlsVisible: controlsVisible,
      irModeRaw: pointerMode, overscanApplicable: true, overscanFullscreen: fullscreen,
      childPresented: showPicker,
      readToggles: { TopBarToggles(isMuted: muted, fastForwardEnabled: fastForward) },
      open: { destination in
        lastAction = "destination.\(destination)"
        if destination == .saveStates { showPicker = true }
      },
      onToggleOnScreenControls: { controlsVisible.toggle() },
      onSetPointerMode: { pointerMode = $0.rawValue },
      onSetOverscanFullscreen: { fullscreen = $0 },
      readPlayer1Devices: {
        [TopBarDeviceOption(qualifier: nil, name: "On-Screen Controls", isSelected: true),
         TopBarDeviceOption(qualifier: "fixture-pad", name: "Preview Controller", isSelected: false)]
      },
      onChoosePlayer1: { lastAction = "controller.\($0 ?? "touchscreen")" },
      onQuickSave: { lastAction = "toolbar.save" }, onQuickLoad: { lastAction = "toolbar.load" },
      runtime: TopBarRuntimeActions(
        readVolume: { volume }, setVolume: { volume = $0 },
        toggleMute: { muted.toggle(); return muted },
        toggleFastForward: { fastForward.toggle(); return fastForward },
        recenterPointer: { lastAction = "pointer.recenter" },
        clearSkylanders: { lastAction = "skylanders.clear" },
        saveReplay: { lastAction = "replay" },
        captureScreenshot: { lastAction = "screenshot"; return .failed },
        replayEnabled: { true }, portalEnabled: { true }, thermalEnabled: { false }))
  }

  private func revealToolbar() {
    visibility.show(now: Date())
    visibility.menuOpened("read-only-audit", now: Date())
  }
  #endif
}

private struct PlayControlsFixtureProvider: SaveStateProviding {
  func states(for gameID: String) async -> [SaveStateInfo] { Self.states }
  func statesGroupedByGame() async -> [String: [SaveStateInfo]] { ["GALE01": Self.states] }
  func thumbnail(for state: SaveStateInfo) async -> UIImage? {
    state.slot == 4 ? nil : await UIImage(systemName: "gamecontroller")
  }
  func delete(state: SaveStateInfo) throws { throw CocoaError(.fileWriteNoPermission) }
  func rename(state: SaveStateInfo, to title: String) throws { throw CocoaError(.fileWriteNoPermission) }

  private static var states: [SaveStateInfo] {
    let entries: [(String, String, Int?, Bool, Bool, Bool, Bool)] = [
      ("Quick save", "GALE01.quick-A2CC29A2-38BC-41B6-B37C-7624990EAE90.s01", nil, false, true, false, true),
      ("Slot 4", "GALE01.s04", 4, false, false, false, false),
      ("Earlier quick save", "GALE01.quick-4F47B891-8628-45E3-98A3-A403A04BB4FB.s01", nil, false, true, true, true),
      ("Automatic resume", "GALE01.auto", nil, true, false, false, true)
    ]
    return entries.enumerated().map { index, item in
      SaveStateInfo(gameID: "GALE01", displayName: item.0, slot: item.2, createdAt: nil,
                    modifiedAt: Date(timeIntervalSince1970: 1_792_500_000 - Double(index) * 600),
                    sizeBytes: nil, versionHash: nil, isCompatible: item.6,
                    path: URL(fileURLWithPath: "/read-only-fixture/\(item.1)"), thumbnailURL: nil,
                    isAuto: item.3, isQuickSave: item.4, isKept: item.5)
    }
  }
}
#endif
