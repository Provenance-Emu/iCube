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

/// The in-game quick-access bar: exit, quick save/load + slot, playback toggles, controller/display/
/// performance, more, hide. On a wide screen it is one row; in compact-width portrait it is two (the first
/// holds the things used mid-play, the second the settings); on a screen too narrow even for that, one
/// row that scrolls with exit and hide pinned.
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
  /// True while anything the bar opened (or the pause menu) is up. When it goes away the bar re-reads its toggles.
  var childPresented = false
  /// Where mute and fast-forward are read from; the live state unless a snapshot says otherwise.
  var readToggles: () -> TopBarToggles = TopBarToggles.live
  let open: (TopBarDestination) -> Void
  let onToggleOnScreenControls: () -> Void
  let onSetPointerMode: (PointerMode) -> Void
  let onSetProgrammaticOverlay: (Bool) -> Void
  let onSetOverscanFullscreen: (Bool) -> Void

  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @State private var popover: TopBarPopover?
  @State private var handoff = TopBarHandoff<TopBarDestination>()
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
  private static let instantReplaySeconds: TimeInterval = 15
  private static let barHorizontalPadding: CGFloat = 12
  private static let barTopPadding: CGFloat = 12
  private static let barBottomPadding: CGFloat = 8
  private static let rowSpacing: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        wideRow
        // Landscape phones are short: scroll rather than spend a second row of height.
        if verticalSizeClass != .compact { twoRows }
        scrollingRow
      }
      .padding(.horizontal, Self.barHorizontalPadding)
      .padding(.top, Self.barTopPadding)
      .padding(.bottom, Self.barBottomPadding)
      .background(.ultraThinMaterial)
      .background(GeometryReader { Color.clear.preference(key: TopBarHeightKey.self, value: $0.size.height) })
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear { refreshToggles() }
    .onChange(of: popover) { old, new in
      if let old { visibility.menuClosed(old.rawValue, now: Date()) }
      if let new { visibility.menuOpened(new.rawValue, now: Date()) }
      if new == nil { presentPendingAfterFallback() }
    }
    .onChange(of: childPresented) { was, now in
      if TopBarToggleRefresh.shouldRefresh(childWasPresented: was, childIsPresented: now) { refreshToggles() }
      if now { releaseHandoffHold() }
    }
    .task { await refreshTogglesWhileVisible() }
    .task(id: visibility.deadline) { await hideWhenIdle() }
  }

  // MARK: - Layouts

  /// One row, everything visible: wide screens.
  private var wideRow: some View {
    HStack(spacing: Self.groupSpacing) {
      exitButton
      stateGroup
      separator
      playbackGroup
      separator
      settingsGroup
      separator
      moreButton
      Spacer(minLength: 0)
      hideButton
    }
  }

  /// Compact-width portrait: mid-play actions on top, settings below, spread across the width.
  private var twoRows: some View {
    VStack(spacing: Self.rowSpacing) {
      HStack(spacing: 0) {
        exitButton
        Spacer(minLength: 0)
        quickSaveButton
        Spacer(minLength: 0)
        quickLoadButton
        Spacer(minLength: 0)
        slotButton
        Spacer(minLength: 0)
        pauseButton
        Spacer(minLength: 0)
        fastForwardButton
        Spacer(minLength: 0)
        hideButton
      }
      HStack(spacing: 0) {
        muteButton
        Spacer(minLength: 0)
        screenshotButton
        Spacer(minLength: 0)
        onScreenControlsButton
        Spacer(minLength: 0)
        controllerButton
        Spacer(minLength: 0)
        displayButton
        Spacer(minLength: 0)
        performanceButton
        if thermalBadgeEnabled {
          Spacer(minLength: 0)
          thermalBadge
        }
        Spacer(minLength: 0)
        moreButton
      }
    }
  }

  /// Fallback for screens too narrow for either layout: the middle scrolls, exit and hide stay put.
  private var scrollingRow: some View {
    HStack(spacing: Self.groupSpacing) {
      exitButton
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Self.groupSpacing) {
          stateGroup
          separator
          playbackGroup
          separator
          settingsGroup
          separator
          moreButton
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .simultaneousGesture(
        DragGesture(minimumDistance: Self.scrollDragThreshold).onChanged { _ in touchedWhileScrolling() })
      hideButton
    }
  }

  // MARK: - Groups and buttons

  private var stateGroup: some View {
    HStack(spacing: Self.itemSpacing) {
      quickSaveButton
      quickLoadButton
      slotButton
    }
  }

  private var playbackGroup: some View {
    HStack(spacing: Self.itemSpacing) {
      pauseButton
      fastForwardButton
      muteButton
      screenshotButton
      onScreenControlsButton
    }
  }

  private var settingsGroup: some View {
    HStack(spacing: Self.itemSpacing) {
      controllerButton
      displayButton
      performanceButton
      if thermalBadgeEnabled { thermalBadge }
    }
  }

  private var exitButton: some View {
    iconButton("xmark.circle.fill", label: L("Exit Game")) { open(.exitConfirm) }
  }

  private var hideButton: some View {
    iconButton("chevron.up.circle.fill", label: L("Hide Toolbar")) {
      withAnimation(TopBarStyle.transition) { visibility.hideNow() }
    }
  }

  private var quickSaveButton: some View {
    slotActionIcon("arrow.down.doc", label: L("Quick Save"), tap: { QuickSlot.save(slot: selectedSlot) }, longPress: .quickSaveSlots)
  }

  private var quickLoadButton: some View {
    slotActionIcon("arrow.up.doc", label: L("Quick Load"), tap: { QuickSlot.load(slot: selectedSlot) }, longPress: .quickLoadSlots)
  }

  private var pauseButton: some View {
    toggleButton(isPaused ? "play.fill" : "pause.fill", label: isPaused ? L("Resume") : L("Pause"), isOn: nil) { togglePause() }
  }

  private var fastForwardButton: some View {
    toggleButton(fastForwardEnabled ? "forward.fill" : "forward", label: L("Fast Forward"), isOn: fastForwardEnabled) {
      fastForwardEnabled = TVEmulationBridge.toggleFastForward()
    }
    .animation(nil, value: fastForwardEnabled)
  }

  private var muteButton: some View {
    toggleButton(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: L("Mute"), isOn: isMuted) {
      isMuted = QuickMute.toggle()
    }
  }

  private var screenshotButton: some View {
    iconButton("camera", label: L("Screenshot")) { takeScreenshot() }
  }

  private var onScreenControlsButton: some View {
    toggleButton(onScreenControlsVisible ? "hand.tap.fill" : "hand.tap",
                 label: onScreenControlsVisible ? L("Hide On-Screen Controls") : L("Show On-Screen Controls"), isOn: nil) {
      onToggleOnScreenControls()
    }
  }

  private var controllerButton: some View {
    popoverIcon("gamecontroller", label: L("Controller"), kind: .controller) { controllerPopover }
  }

  private var displayButton: some View {
    popoverIcon("slider.horizontal.3", label: L("Display & Effects"), kind: .display) { displayPopover }
  }

  private var performanceButton: some View {
    iconButton("speedometer", label: L("Performance")) { open(.perfOverlay) }
  }

  private var moreButton: some View {
    popoverIcon("ellipsis.circle", label: L("More"), kind: .more) { morePopover }
  }

  private var thermalBadgeEnabled: Bool {
    UserDefaults.standard.bool(forKey: TopBarDefaultsKey.thermalAutoEnable)
  }

  private var thermalBadge: some View {
    ThermalBadgeView()
      .frame(width: Self.controlSize, height: Self.controlSize)
  }

  private var separator: some View {
    Rectangle()
      .fill(.secondary.opacity(0.35))
      .frame(width: 1, height: Self.separatorHeight)
      .accessibilityHidden(true)
  }

  // MARK: - Button builders

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
          .onDisappear { presentPendingDestination() }
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
    .popover(isPresented: popoverBinding(.slot)) {
      slotPicker(for: .slot)
        .onDisappear { presentPendingDestination() }
    }
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
          .onDisappear { presentPendingDestination() }
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
      PopoverRow(title: L("Controller Settings…"), systemImage: "gearshape") { closeThenOpen(.controllerSettings) }
    }
  }

  private var displayPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      PopoverRow(title: L("Audio Effects"), systemImage: "slider.horizontal.3") { closeThenOpen(.audioEffects) }
      PopoverRow(title: L("Shaders"), systemImage: "wand.and.stars") { closeThenOpen(.shaders) }
      PopoverRow(title: L("Shader Parameters"), systemImage: "slider.vertical.3") { closeThenOpen(.shaderParameters) }
    }
  }

  private var morePopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      PopoverRow(title: L("Pause Menu"), systemImage: "list.bullet.rectangle") { closeThenOpen(.pauseMenu) }
      if overscanApplicable {
        PopoverRow(title: L("Full Screen Display"), systemImage: "tv", isChecked: overscanFullscreen) {
          close { onSetOverscanFullscreen(!overscanFullscreen) }
        }
      }
      if UserDefaults.standard.bool(forKey: TopBarDefaultsKey.instantReplayEnabled) {
        PopoverRow(title: L("Save Instant Replay Clip"), systemImage: "clock.arrow.circlepath") {
          close { ReplayKitManager.shared.saveRecentClip(seconds: Self.instantReplaySeconds) }
        }
      }
      if DOLConfigBridge.mainEmulateSkylanderPortal() && isWii {
        Divider()
        sectionHeader(L("Skylanders"))
        PopoverRow(title: L("Load Skylander…"), systemImage: "externaldrive") { closeThenOpen(.skylanderImport) }
        PopoverRow(title: L("Clear Slot…"), systemImage: "minus.circle") { closeThenOpen(.skylanderClear) }
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
      hasState: QuickSlot.hasState,
      onPick: { slot in
        act {
          selectedSlot = slot
          popover = nil
          switch purpose {
          case .save: QuickSlot.save(slot: slot)
          case .load: QuickSlot.load(slot: slot)
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

  /// Any tap on the bar restarts the idle countdown.
  private func act(_ action: () -> Void) {
    visibility.interaction(now: Date())
    action()
  }

  /// Dismisses the popover, then performs `action` (an immediate effect, not a presentation).
  private func close(_ action: () -> Void) {
    popover = nil
    act(action)
  }

  /// Dismisses the popover and presents `destination` only once the popover has gone, never in the same
  /// update. The hand-off hold is taken before the popover's hold is released, and kept until the
  /// destination's own hold has taken over, so the bar cannot time out in between.
  private func closeThenOpen(_ destination: TopBarDestination) {
    visibility.menuOpened(TopBarHandoff<TopBarDestination>.holdID, now: Date())
    handoff.request(destination)
    popover = nil
    visibility.interaction(now: Date())
  }

  /// The popover reported its dismissal: present what was waiting on it.
  private func presentPendingDestination() {
    guard let destination = handoff.take() else { return }
    open(destination)
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: TopBarTiming.nanoseconds(TopBarTiming.handoffGrace))
      releaseHandoffHold()
    }
  }

  /// Safety net for a popover that never reports its dismissal.
  private func presentPendingAfterFallback() {
    guard handoff.isPending else { return }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: TopBarTiming.nanoseconds(TopBarTiming.popoverDismissFallback))
      presentPendingDestination()
    }
  }

  private func releaseHandoffHold() {
    visibility.menuClosed(TopBarHandoff<TopBarDestination>.holdID, now: Date())
  }

  private func refreshToggles() {
    let toggles = readToggles()
    isMuted = toggles.isMuted
    fastForwardEnabled = toggles.fastForwardEnabled
  }

  /// Mute and fast-forward can change behind the bar's back (Settings, a controller button), so re-read them while it is up.
  private func refreshTogglesWhileVisible() async {
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: TopBarTiming.nanoseconds(TopBarTiming.stateRefreshInterval))
      refreshToggles()
    }
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
        if visibility.shouldHide(at: Date()) { withAnimation(TopBarStyle.transition) { visibility.hideNow() } }
        return
      }
      try? await Task.sleep(nanoseconds: TopBarTiming.nanoseconds(remaining))
    }
  }

  private func togglePause() {
    if TVEmulationBridge.isPaused() {
      TVEmulationBridge.resume()
      PauseOwnership.pausedFromBar = false
    } else {
      // Same as the pause menu: grab the last live frame first so a save made while paused has a thumbnail.
      SaveStateService.capturePausePreview()
      TVEmulationBridge.pause()
      PauseOwnership.pausedFromBar = true
    }
    isPaused = TVEmulationBridge.isPaused()
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
