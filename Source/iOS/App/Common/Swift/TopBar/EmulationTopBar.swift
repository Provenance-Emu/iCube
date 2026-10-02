// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// Where a bar button sends the user. `EmulationScreen` owns the sheets and overlays these open.
enum TopBarDestination {
  case exitConfirm, perfOverlay, audioEffects, shaders, shaderParameters
  case controllerSettings, pauseMenu, skylanderImport, skylanderClear
}

/// The popovers the bar can show. Only one is up at a time.
private enum TopBarPopover: String {
  case quickSaveSlots, quickLoadSlots, slot, controller, display, more
}

/// Keeps the bar up while something it opened (a sheet, the pause menu, the perf overlay, an alert) is
/// presented, and restarts the countdown when that goes away. One hold covers all of them.
struct TopBarChildPresentationHold: ViewModifier {
  private static let holdID = "childPresentation"
  @Binding var visibility: TopBarVisibility
  let isPresented: Bool

  func body(content: Content) -> some View {
    content.onChange(of: isPresented) { _, presented in
      if presented {
        visibility.menuOpened(Self.holdID, now: Date())
      } else {
        visibility.menuClosed(Self.holdID, now: Date())
      }
    }
  }
}

/// The in-game quick-access bar, left to right: exit, quick save/load + slot, playback toggles,
/// controller/display/performance, more, hide. Exit and hide are pinned; the rest scrolls horizontally
/// on narrow screens.
///
/// Auto-hide is owned by `TopBarVisibility`. SwiftUI's `Menu` has no open/close callback (and a menu
/// dismissed by tapping outside never reports it), so every menu on this bar is a `.popover` bound to
/// state we own: open and close are exact, and the bar can hold itself up for exactly as long as one is on
/// screen. `.presentationCompactAdaptation(.popover)` keeps them popovers on iPhone.
struct EmulationTopBar: View {
  @Binding var visibility: TopBarVisibility
  @Binding var selectedSlot: Int
  @Binding var isPaused: Bool
  @Binding var fastForwardEnabled: Bool
  let isWii: Bool
  let onScreenControlsVisible: Bool
  let irModeRaw: Int
  let overscanApplicable: Bool
  let overscanFullscreen: Bool
  let open: (TopBarDestination) -> Void
  let onToggleOnScreenControls: () -> Void
  let onSetPointerMode: (PointerMode) -> Void
  let onSetProgrammaticOverlay: (Bool) -> Void
  let onSetOverscanFullscreen: (Bool) -> Void

  @State private var popover: TopBarPopover?
  @State private var isMuted = false
  @State private var lastScrollTouch = Date.distantPast

  private static let controlSize: CGFloat = 44
  private static let itemSpacing: CGFloat = 0
  private static let groupSpacing: CGFloat = 8
  private static let separatorHeight: CGFloat = 24
  private static let longPressDuration: TimeInterval = 0.4
  private static let scrollTouchThrottle: TimeInterval = 0.5
  private static let scrollDragThreshold: CGFloat = 8
  private static let slotRange = 1 ... 10
  private static let slotColumns = 5
  private static let popoverWidth: CGFloat = 280
  private static let hideAnimation = Animation.spring(response: 0.3, dampingFraction: 0.9)

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        iconButton("xmark.circle.fill", label: L("Exit Game")) { open(.exitConfirm) }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Self.groupSpacing) {
            stateGroup
            separator
            playbackGroup
            separator
            settingsGroup
            separator
            moreGroup
          }
        }
        .scrollBounceBehavior(.basedOnSize)
        .simultaneousGesture(
          DragGesture(minimumDistance: Self.scrollDragThreshold).onChanged { _ in touchedWhileScrolling() })

        iconButton("chevron.up.circle.fill", label: L("Hide Toolbar")) {
          withAnimation(Self.hideAnimation) { visibility.hideNow() }
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)
      .padding(.bottom, 8)
      .background(.ultraThinMaterial)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear { isMuted = QuickMute.isMuted }
    .onChange(of: popover) { old, new in
      if let old { visibility.menuClosed(old.rawValue, now: Date()) }
      if let new { visibility.menuOpened(new.rawValue, now: Date()) }
    }
    .task(id: visibility.deadline) { await hideWhenIdle() }
  }

  // MARK: - Groups

  private var stateGroup: some View {
    HStack(spacing: Self.itemSpacing) {
      slotActionIcon("square.and.arrow.down", label: L("Quick Save"), tap: { quickSave(slot: selectedSlot) }, longPress: .quickSaveSlots)
      slotActionIcon("square.and.arrow.up", label: L("Quick Load"), tap: { quickLoad(slot: selectedSlot) }, longPress: .quickLoadSlots)
      slotButton
    }
  }

  private var playbackGroup: some View {
    HStack(spacing: Self.itemSpacing) {
      toggleButton(isPaused ? "play.fill" : "pause.fill", label: isPaused ? L("Resume") : L("Pause"), isOn: nil) { togglePause() }
      toggleButton(fastForwardEnabled ? "forward.fill" : "forward", label: L("Fast Forward"), isOn: fastForwardEnabled) {
        fastForwardEnabled = TVEmulationBridge.toggleFastForward()
      }
      .animation(nil, value: fastForwardEnabled)
      toggleButton(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: L("Mute"), isOn: isMuted) {
        isMuted = QuickMute.toggle()
      }
      iconButton("camera", label: L("Screenshot")) { takeScreenshot() }
      toggleButton(onScreenControlsVisible ? "hand.tap.fill" : "hand.tap",
                   label: onScreenControlsVisible ? L("Hide On-Screen Controls") : L("Show On-Screen Controls"), isOn: nil) {
        onToggleOnScreenControls()
      }
    }
  }

  private var settingsGroup: some View {
    HStack(spacing: Self.itemSpacing) {
      popoverIcon("gamecontroller", label: L("Controller"), kind: .controller) { controllerPopover }
      popoverIcon("slider.horizontal.3", label: L("Display & Effects"), kind: .display) { displayPopover }
      iconButton("speedometer", label: L("Performance")) { open(.perfOverlay) }
      if UserDefaults.standard.bool(forKey: "thermal_auto_enable") {
        ThermalBadgeView()
          .frame(width: Self.controlSize, height: Self.controlSize)
      }
    }
  }

  private var moreGroup: some View {
    popoverIcon("ellipsis.circle", label: L("More"), kind: .more) { morePopover }
  }

  private var separator: some View {
    Rectangle()
      .fill(.secondary.opacity(0.35))
      .frame(width: 1, height: Self.separatorHeight)
      .accessibilityHidden(true)
  }

  // MARK: - Buttons

  private func iconLabel(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.title2)
      .frame(width: Self.controlSize, height: Self.controlSize)
      .contentShape(Rectangle())
  }

  private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
    Button { act(action) } label: { iconLabel(systemName) }
      .buttonStyle(.plain)
      .accessibilityLabel(label)
  }

  /// A button whose icon changes with state. `isOn` non-nil also tints it and is announced as On/Off.
  private func toggleButton(_ systemName: String, label: String, isOn: Bool?, action: @escaping () -> Void) -> some View {
    Button { act(action) } label: { iconLabel(systemName).foregroundStyle(isOn == true ? Color.accentColor : Color.primary) }
      .buttonStyle(.plain)
      .accessibilityLabel(label)
      .accessibilityValue(isOn.map { $0 ? L("On") : L("Off") } ?? "")
  }

  /// Quick Save / Quick Load: tap acts on the current slot, long-press picks a slot first. Not a `Button`
  /// so the long-press gesture can coexist with the tap.
  private func slotActionIcon(_ systemName: String, label: String, tap: @escaping () -> Void, longPress kind: TopBarPopover) -> some View {
    iconLabel(systemName)
      .onTapGesture { act(tap) }
      .onLongPressGesture(minimumDuration: Self.longPressDuration) { act { popover = kind } }
      .accessibilityElement()
      .accessibilityLabel(label)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { act(tap) }
      .accessibilityAction(named: L("Choose Slot")) { act { popover = kind } }
      .popover(isPresented: popoverBinding(kind)) {
        slotPicker(for: kind)
      }
  }

  private var slotButton: some View {
    Button { act { popover = .slot } } label: {
      Text("\(selectedSlot)")
        .font(.title3.weight(.semibold).monospacedDigit())
        .frame(width: Self.controlSize, height: Self.controlSize)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L("Save Slot"))
    .accessibilityValue("\(selectedSlot)")
    .popover(isPresented: popoverBinding(.slot)) { slotPicker(for: .slot) }
  }

  private func popoverIcon<Content: View>(_ systemName: String, label: String, kind: TopBarPopover,
                                          @ViewBuilder content: @escaping () -> Content) -> some View {
    Button { act { popover = kind } } label: { iconLabel(systemName) }
      .buttonStyle(.plain)
      .accessibilityLabel(label)
      .popover(isPresented: popoverBinding(kind)) {
        content()
          .frame(width: Self.popoverWidth)
          .presentationCompactAdaptation(.popover)
      }
  }

  private func popoverBinding(_ kind: TopBarPopover) -> Binding<Bool> {
    Binding(get: { popover == kind }, set: { if !$0, popover == kind { popover = nil } })
  }

  // MARK: - Popover contents

  private var controllerPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      if isWii {
        sectionHeader(L("Pointer"))
        ForEach(PointerMode.allCases) { mode in
          PopoverRow(title: mode.title, systemImage: mode.systemImage, isChecked: irModeRaw == mode.rawValue) {
            close { onSetPointerMode(mode) }
          }
        }
        PopoverRow(title: L("Recenter Pointer"), systemImage: "scope") { close { TCDeviceMotion.requestPointerRecenter() } }
        Divider()
      }
      PopoverRow(title: L("New On‑Screen Controller (Beta)"), systemImage: "sparkles", isChecked: TouchOverlayFlag.isProgrammatic) {
        close { onSetProgrammaticOverlay(!TouchOverlayFlag.isProgrammatic) }
      }
      Divider()
      PopoverRow(title: L("Controller Settings…"), systemImage: "gearshape") { close { open(.controllerSettings) } }
    }
  }

  private var displayPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      PopoverRow(title: L("Audio Effects"), systemImage: "slider.horizontal.3") { close { open(.audioEffects) } }
      PopoverRow(title: L("Shaders"), systemImage: "wand.and.stars") { close { open(.shaders) } }
      PopoverRow(title: L("Shader Parameters"), systemImage: "slider.vertical.3") { close { open(.shaderParameters) } }
    }
  }

  private var morePopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      PopoverRow(title: L("Pause Menu"), systemImage: "list.bullet.rectangle") { close { open(.pauseMenu) } }
      if overscanApplicable {
        PopoverRow(title: L("Full Screen Display"), systemImage: "tv", isChecked: overscanFullscreen) {
          close { onSetOverscanFullscreen(!overscanFullscreen) }
        }
      }
      if UserDefaults.standard.bool(forKey: "replaykit_instant_replay_enabled") {
        PopoverRow(title: L("Save Instant Replay Clip"), systemImage: "clock.arrow.circlepath") {
          close { ReplayKitManager.shared.saveRecentClip(seconds: Self.instantReplaySeconds) }
        }
      }
      if DOLConfigBridge.mainEmulateSkylanderPortal() && isWii {
        Divider()
        sectionHeader(L("Skylanders"))
        PopoverRow(title: L("Load Skylander…"), systemImage: "externaldrive") { close { open(.skylanderImport) } }
        PopoverRow(title: L("Clear Slot…"), systemImage: "minus.circle") { close { open(.skylanderClear) } }
        PopoverRow(title: L("Clear All"), systemImage: "trash") { close { DOLConfigBridge.skylanderClearAll() } }
      }
    }
  }

  private func slotPicker(for kind: TopBarPopover) -> some View {
    let purpose: SlotPickerPurpose
    switch kind {
    case .quickSaveSlots: purpose = .save
    case .quickLoadSlots: purpose = .load
    default: purpose = .choose
    }
    return SlotPickerView(
      purpose: purpose,
      slots: Array(Self.slotRange),
      columns: Self.slotColumns,
      selected: selectedSlot,
      hasState: Self.slotHasState,
      onPick: { slot in
        act {
          selectedSlot = slot
          popover = nil
          switch purpose {
          case .save: quickSave(slot: slot)
          case .load: quickLoad(slot: slot)
          case .choose: break
          }
        }
      })
      .presentationCompactAdaptation(.popover)
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.top, 10)
      .padding(.bottom, 2)
  }

  // MARK: - Actions

  private static let instantReplaySeconds: TimeInterval = 15

  /// Any tap on the bar restarts the idle countdown.
  private func act(_ action: () -> Void) {
    visibility.interaction(now: Date())
    action()
  }

  /// Dismisses the popover first, then performs `action` (which may present a sheet).
  private func close(_ action: () -> Void) {
    popover = nil
    act(action)
  }

  private func touchedWhileScrolling() {
    let now = Date()
    guard now.timeIntervalSince(lastScrollTouch) >= Self.scrollTouchThrottle else { return }
    lastScrollTouch = now
    visibility.interaction(now: now)
  }

  private func hideWhenIdle() async {
    while !Task.isCancelled, let deadline = visibility.deadline {
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 {
        if visibility.shouldHide(at: Date()) { withAnimation(Self.hideAnimation) { visibility.hideNow() } }
        return
      }
      try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
  }

  private func togglePause() {
    if TVEmulationBridge.isPaused() {
      TVEmulationBridge.resume()
    } else {
      // Same as the pause menu: grab the last live frame first so a save made while paused has a thumbnail.
      SaveStateService.capturePausePreview()
      TVEmulationBridge.pause()
    }
    isPaused = TVEmulationBridge.isPaused()
  }

  private func quickSave(slot: Int) {
    SaveStateService.saveSlot(slot)
    EmulationToast.post(String(format: L("Saved to Slot %d"), slot))
  }

  /// A single tap, as the pause menu's own Load button: there is no load-confirmation pattern in the app.
  private func quickLoad(slot: Int) {
    guard Self.slotHasState(slot) else {
      EmulationToast.post(String(format: L("No save in Slot %d"), slot))
      return
    }
    TVEmulationBridge.loadState(fromSlot: slot)
    EmulationToast.post(String(format: L("Loaded Slot %d"), slot))
  }

  private static func slotHasState(_ slot: Int) -> Bool {
    guard let path = TVEmulationBridge.stateFilePath(forSlot: slot) else { return false }
    return FileManager.default.fileExists(atPath: path)
  }

  private func takeScreenshot() {
    Task { @MainActor in
      switch await QuickScreenshot.capture() {
      case .saved: EmulationToast.post(L("Screenshot saved to ScreenShots"))
      case .pausedNoFrame: EmulationToast.post(L("Resume to take a screenshot"))
      case .failed: EmulationToast.post(L("Screenshot failed"))
      }
    }
  }
}

// MARK: - Popover building blocks

private struct PopoverRow: View {
  private static let rowHeight: CGFloat = 44
  private static let iconWidth: CGFloat = 28

  let title: String
  let systemImage: String
  var isChecked = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage).frame(width: Self.iconWidth)
        Text(title)
        Spacer(minLength: 0)
        if isChecked { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isChecked ? .isSelected : [])
  }
}

private enum SlotPickerPurpose {
  case save, load, choose

  var title: String {
    switch self {
    case .save: return L("Save to Slot")
    case .load: return L("Load from Slot")
    case .choose: return L("Save Slot")
    }
  }
}

/// A 2 x 5 grid of the save slots: filled when the slot holds a state, ringed when it is the current one.
private struct SlotPickerView: View {
  private static let cellSize: CGFloat = 44

  let purpose: SlotPickerPurpose
  let slots: [Int]
  let columns: Int
  let selected: Int
  let hasState: (Int) -> Bool
  let onPick: (Int) -> Void

  var body: some View {
    VStack(spacing: 8) {
      Text(purpose.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellSize), spacing: 6), count: columns), spacing: 6) {
        ForEach(slots, id: \.self) { slot in
          let filled = hasState(slot)
          Button { onPick(slot) } label: {
            Text("\(slot)")
              .font(.body.weight(.semibold).monospacedDigit())
              .frame(width: Self.cellSize, height: Self.cellSize)
              .background(filled ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Circle())
              .overlay(Circle().stroke(Color.accentColor, lineWidth: slot == selected ? 2 : 0))
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .disabled(purpose == .load && !filled)
          .accessibilityLabel(String(format: L("Slot %d"), slot))
          .accessibilityValue(filled ? L("In use") : L("Empty"))
          .accessibilityAddTraits(slot == selected ? .isSelected : [])
        }
      }
    }
    .padding(14)
  }
}
#endif
