// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// One choice in the Controller menu's Player 1 section.
struct TopBarDeviceOption: Identifiable, Equatable {
  /// nil: the on-screen controls.
  let qualifier: String?
  let name: String
  let isSelected: Bool

  var id: String { qualifier ?? "touchscreen" }
}

/// Side effects are injected so the DEBUG audit renders the actual toolbar without touching a core.
@MainActor
struct TopBarRuntimeActions {
  var readVolume: () -> Int = { Int(DOLConfigBridge.audioVolume()) }
  var setVolume: (Int) -> Void = { DOLConfigBridge.setAudioVolume($0) }
  var toggleMute: () -> Bool = { QuickMute.toggle() }
  var toggleFastForward: () -> Bool = { TVEmulationBridge.toggleFastForward() }
  var recenterPointer: () -> Void = { TCDeviceMotion.requestPointerRecenter() }
  var clearSkylanders: () -> Void = { DOLConfigBridge.skylanderClearAll() }
  var saveReplay: () -> Void = { ReplayKitManager.shared.saveRecentClip(seconds: 15) }
  var captureScreenshot: @MainActor () async -> QuickScreenshot.Outcome = { await QuickScreenshot.capture() }
  var replayEnabled: () -> Bool = { UserDefaults.standard.bool(forKey: TopBarDefaultsKey.instantReplayEnabled) }
  var portalEnabled: () -> Bool = { DOLConfigBridge.mainEmulateSkylanderPortal() }
  var thermalEnabled: () -> Bool = { UserDefaults.standard.bool(forKey: TopBarDefaultsKey.thermalAutoEnable) }
}

/// The popovers the bar can show. Only one is up at a time.
private enum TopBarPopover: String {
  case audio, controller, display, options
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

/// A compact labeled play toolbar. Portrait has one row; secondary controls live in Options.
/// Every popover has an owned presentation binding so visibility holds and sheet handoff stay exact.
struct EmulationTopBar: View {
  @Binding var visibility: TopBarVisibility
  @Binding var selectedSlot: Int
  @Binding var isPaused: Bool
  @Binding var fastForwardEnabled: Bool
  let isWii: Bool
  let onScreenControlsVisible: Bool
  let irModeRaw: Int
  /// The running title has its own pointer mode: a pick lasts for this game only.
  var pointerIsThisGameOnly = false
  let overscanApplicable: Bool
  let overscanFullscreen: Bool
  /// True while anything the bar opened (or the pause menu) is up. When it goes away the bar re-reads its toggles.
  var childPresented = false
  /// Where mute and fast-forward are read from; the live state unless a snapshot says otherwise.
  var readToggles: () -> TopBarToggles = TopBarToggles.live
  let open: (TopBarDestination) -> Void
  let onToggleOnScreenControls: () -> Void
  let onSetPointerMode: (PointerMode) -> Void
  let onSetOverscanFullscreen: (Bool) -> Void
  /// Player 1's choices, read when the Controller menu opens; the section shows only with a pad connected.
  var readPlayer1Devices: () -> [TopBarDeviceOption] = { [] }
  /// nil puts the on-screen controls on Player 1.
  var onChoosePlayer1: (String?) -> Void = { _ in }

  /// The parent supplies the reviewed history policy; nil retains classic behavior for older callers.
  var onQuickSave: (() -> Void)? = nil
  var onQuickLoad: (() -> Void)? = nil
  var runtime = TopBarRuntimeActions()

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var popover: TopBarPopover?
  @State private var handoff = TopBarHandoff<TopBarDestination>()
  @State private var isMuted = false
  @State private var volume: Double = 100

  private static let popoverWidth: CGFloat = 320

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        toolbar(width: geometry.size.width, height: geometry.size.height)
          .padding(.horizontal, TopBarLayout.horizontalPadding)
          .padding(.vertical, TopBarLayout.verticalPadding)
          .background(.ultraThinMaterial)
          .overlay(alignment: .bottom) {
            ICubeDesign.color(.hairline).frame(height: ICubeDesign.Line.hairline.rawValue)
          }
          .background(GeometryReader { Color.clear.preference(key: TopBarHeightKey.self, value: $0.size.height) })
          .popover(isPresented: popoverPresented) {
            ScrollView {
              popoverContents
                .padding(.vertical, ICubeDesign.Spacing.xs.rawValue)
            }
            .frame(width: min(Self.popoverWidth, max(TopBarLayout.minimumTarget, geometry.size.width - 2 * ICubeDesign.Spacing.m.rawValue)))
            .frame(maxHeight: max(TopBarLayout.minimumTarget, geometry.size.height - TopBarLayout.standardHeight - 2 * ICubeDesign.Spacing.m.rawValue))
            .presentationCompactAdaptation(.popover)
            .onDisappear { presentPendingDestination() }
          }
        Spacer(minLength: 0)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("play-toolbar")
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

  @ViewBuilder
  private func toolbar(width: CGFloat, height: CGFloat) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: ICubeDesign.Spacing.xs.rawValue) {
        ForEach(TopBarLayout.compactControls, id: \.self) { toolbarControl($0).accessibilityIdentifier("play-toolbar.\($0.rawValue)") }
      }
    } else {
      let controls = TopBarLayout.usesWideRow(width: width, height: height, accessibilityType: false)
        ? TopBarLayout.wideControls : TopBarLayout.compactControls
      HStack(spacing: 0) {
        ForEach(controls, id: \.self) { toolbarControl($0).accessibilityIdentifier("play-toolbar.\($0.rawValue)") }
      }
    }
  }

  @ViewBuilder
  private func toolbarControl(_ control: TopBarControl) -> some View {
    switch control {
    case .pause:
      toolButton("pause.fill", title: L("Pause"), selected: true) { openDirect(.pause) }
    case .save:
      toolButton("square.and.arrow.down", title: L("Save"), accessibility: L("Quick Save")) {
        if let onQuickSave { onQuickSave() } else { openDirect(.saves) }
      }
    case .load:
      toolButton("square.and.arrow.up", title: L("Load"), accessibility: L("Quick Load")) {
        if let onQuickLoad { onQuickLoad() } else { openDirect(.saves) }
      }
    case .saves:
      toolButton("clock.arrow.circlepath", title: L("Saves"), accessibility: L("Save States")) { openDirect(.saves) }
    case .fastForward:
      toolButton("forward.fill", title: L("Fast Forward"), selected: fastForwardEnabled) {
        fastForwardEnabled = runtime.toggleFastForward()
      }
    case .audio:
      toolButton(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", title: L("Audio")) { popover = .audio }
    case .controller:
      toolButton("gamecontroller", title: L("Controller")) { popover = .controller }
    case .display:
      toolButton("display", title: L("Display")) { popover = .display }
    case .shaders:
      toolButton("square.3.layers.3d", title: L("Shaders")) { openDirect(.shaders) }
    case .options:
      toolButton("slider.horizontal.3", title: L("Options")) { popover = .options }
    case .hide:
      toolButton("chevron.up", title: nil, accessibility: L("Hide Toolbar")) {
        withAnimation(TopBarStyle.transition) { visibility.hideNow() }
      }
    }
  }

  private func toolButton(_ symbol: String, title: String?, accessibility: String? = nil,
                          selected: Bool = false, action: @escaping () -> Void) -> some View {
    Button { act(action) } label: {
      VStack(spacing: ICubeDesign.Spacing.xxs.rawValue) {
        Image(systemName: symbol).font(ICubeDesign.symbolFont(.rail))
        if let title { Text(title).icubeText(.detail).fixedSize(horizontal: false, vertical: true) }
      }
      .frame(minWidth: TopBarLayout.minimumTarget, maxWidth: .infinity,
             minHeight: TopBarLayout.controlHeight)
      .foregroundStyle(ICubeDesign.color(selected ? .accent : .textPrimary))
      .background(selected ? ICubeDesign.color(.selectedFill) : ICubeDesign.color(.rowSurface).opacity(0),
                  in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibility ?? title ?? "")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var popoverPresented: Binding<Bool> {
    Binding(get: { popover != nil }, set: { if !$0 { popover = nil } })
  }

  @ViewBuilder
  private var popoverContents: some View {
    switch popover {
    case .audio: audioPopover
    case .controller: controllerPopover
    case .display: displayPopover
    case .options: optionsPopover
    case nil: EmptyView()
    }
  }

  private var audioPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(L("Audio"))
      PopoverRow(title: L("Mute"), systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", isChecked: isMuted) {
        act { isMuted = runtime.toggleMute(); volume = Double(runtime.readVolume()) }
      }
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        Text(L("Volume")).icubeText(.body)
        Slider(value: Binding(get: { volume }, set: { value in
          act { volume = value; runtime.setVolume(Int(value)); isMuted = value <= 0 }
        }), in: 0...100, step: 1)
          .accessibilityLabel(L("Volume"))
          .accessibilityValue("\(Int(volume))%")
          .frame(minHeight: TopBarLayout.minimumTarget)
      }
      .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
      PopoverRow(title: L("Audio Effects"), systemImage: "slider.horizontal.3") { closeThenOpen(.audioEffects) }
    }
  }

  private var controllerPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(L("Controller"))
      PopoverRow(title: L("On-Screen Controls"), systemImage: "gamecontroller", isChecked: onScreenControlsVisible) {
        close { onToggleOnScreenControls() }
      }
      let player1Devices = readPlayer1Devices()
      if player1Devices.count > 1 {
        Divider()
        sectionHeader(L("Player 1"))
        ForEach(player1Devices) { device in
          PopoverRow(title: device.name, systemImage: "gamecontroller", isChecked: device.isSelected) {
            close { onChoosePlayer1(device.qualifier) }
          }
        }
      }
      if isWii {
        Divider()
        sectionHeader(L("Wii Pointer"))
        if pointerIsThisGameOnly {
          Text(L("This game only")).icubeText(.detail)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
            .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
        }
        ForEach(PointerMode.allCases) { mode in
          PopoverRow(title: mode.title, systemImage: mode.systemImage, isChecked: irModeRaw == mode.rawValue) {
            close { onSetPointerMode(mode) }
          }
        }
        PopoverRow(title: L("Recenter Pointer"), systemImage: "scope") { close { runtime.recenterPointer() } }
      }
      Divider()
      PopoverRow(title: L("Edit Layout…"), systemImage: "rectangle.and.pencil.and.ellipsis") { closeThenOpen(.editLayout) }
      PopoverRow(title: L("Controller Settings…"), systemImage: "gearshape") { closeThenOpen(.controllerSettings) }
    }
  }

  private var displayPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(L("Display"))
      PopoverRow(title: L("Screenshot"), systemImage: "camera") { close { takeScreenshot() } }
      PopoverRow(title: L("Performance"), systemImage: "speedometer") { closeThenOpen(.perfOverlay) }
      PopoverRow(title: L("Shader Parameters"), systemImage: "slider.vertical.3") { closeThenOpen(.shaderParameters) }
      if runtime.thermalEnabled() { ThermalBadgeView() }
      if overscanApplicable {
        PopoverRow(title: L("Full Screen Display"), systemImage: "tv", isChecked: overscanFullscreen) {
          close { onSetOverscanFullscreen(!overscanFullscreen) }
        }
      }
      auxiliaryActions
    }
  }

  private var optionsPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(L("Options"))
      PopoverRow(title: L("Audio"), systemImage: "speaker.wave.2") { act { popover = .audio } }
      PopoverRow(title: L("Controller"), systemImage: "gamecontroller") { act { popover = .controller } }
      PopoverRow(title: L("Display"), systemImage: "display") { act { popover = .display } }
      PopoverRow(title: L("Shaders"), systemImage: "square.3.layers.3d") { closeThenOpen(.shaders) }
      PopoverRow(title: L("Fast Forward"), systemImage: "forward.fill", isChecked: fastForwardEnabled) {
        act { fastForwardEnabled = runtime.toggleFastForward() }
      }
      PopoverRow(title: L("Screenshot"), systemImage: "camera") { close { takeScreenshot() } }
      PopoverRow(title: L("Performance"), systemImage: "speedometer") { closeThenOpen(.perfOverlay) }
      auxiliaryActions
    }
  }

  private var auxiliaryActions: some View {
    VStack(alignment: .leading, spacing: 0) {
      if runtime.replayEnabled() {
        PopoverRow(title: L("Save Instant Replay Clip"), systemImage: "clock.arrow.circlepath") {
          close { runtime.saveReplay() }
        }
      }
      if runtime.portalEnabled() && isWii {
        Divider()
        sectionHeader(L("Skylanders"))
        PopoverRow(title: L("Load Skylander…"), systemImage: "externaldrive") { closeThenOpen(.skylanderImport) }
        PopoverRow(title: L("Clear Slot…"), systemImage: "minus.circle") { closeThenOpen(.skylanderClear) }
        PopoverRow(title: L("Clear All"), systemImage: "trash") { close { runtime.clearSkylanders() } }
      }
      Divider()
      PopoverRow(title: L("Exit Game"), systemImage: "xmark.circle") { closeThenOpen(.exitConfirm) }
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title).icubeText(.detail)
      .foregroundStyle(ICubeDesign.color(.textSecondary))
      .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
      .padding(.top, ICubeDesign.Spacing.xs.rawValue)
      .padding(.bottom, ICubeDesign.Spacing.xxs.rawValue)
  }

  // MARK: - Actions

  private func openDirect(_ control: TopBarControl) {
    guard let destination = control.directDestination else { return }
    open(destination)
  }

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
    volume = Double(runtime.readVolume())
    fastForwardEnabled = toggles.fastForwardEnabled
  }

  /// Mute and fast-forward can change behind the bar's back (Settings, a controller button), so re-read them while it is up.
  private func refreshTogglesWhileVisible() async {
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: TopBarTiming.nanoseconds(TopBarTiming.stateRefreshInterval))
      refreshToggles()
    }
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

  private func takeScreenshot() {
    Task { @MainActor in
      switch await runtime.captureScreenshot() {
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
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        Image(systemName: systemImage).frame(width: Self.iconWidth)
        Text(title).icubeText(.body)
        Spacer(minLength: 0)
        if isChecked { Image(systemName: "checkmark").foregroundStyle(ICubeDesign.color(.accent)) }
      }
      .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
      .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isChecked ? .isSelected : [])
  }
}

#endif
