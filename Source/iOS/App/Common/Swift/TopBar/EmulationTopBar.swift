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

/// One choice of the Controller menu's "On-Screen Controller" section.
struct TopBarOnScreenControllerOption: Identifiable, Equatable {
  let controller: OnScreenController
  let isSelected: Bool

  var id: String { controller.title }
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
  /// Fast-forward speed in percent while on (0 = unlimited), nil when off; and the setter the Speed list uses.
  var readSpeed: () -> Int? = { QuickMenuHost.fastForwardPercent() }
  var setSpeed: (Int?) -> Void = { QuickMenuHost.setFastForward(percent: $0) }
  /// Dolphin's aspect setting (`AspectRatio.aspectRaw`); applies to the running game.
  var readAspect: () -> Int = { DOLConfigBridge.gfxAspectRatio() }
  var setAspect: (Int) -> Void = { DOLConfigBridge.setGfxAspectRatio($0) }
  /// The selected preset's name, nil when shaders are off or none is selected.
  var readShaderName: () -> String? = {
    guard UserDefaults.standard.bool(forKey: ShaderQuickApply.enabledKey), let path = ShaderQuickApply.currentPath, !path.isEmpty else { return nil }
    return ShaderQuickApply.displayName(forPath: path)
  }
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

/// A compact labeled play toolbar: Menu first, Exit last, and each button captioned with what it is set to.
/// Portrait has one row; secondary controls live in More. Holding a button runs `TopBarControl.longPress`.
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
  /// The on-screen controller choices (Auto, GameCube, the Wii Remote variants), the current one
  /// selected; empty when there is nothing to choose (a GameCube title).
  var readOnScreenControllers: () -> [TopBarOnScreenControllerOption] = { [] }
  var onChooseOnScreenController: (OnScreenController) -> Void = { _ in }

  /// What only the screen knows (quick slot, Player 1's device, the TV); the bar reads the rest itself.
  var readContextValues: () -> TopBarValues = { TopBarValues() }
  /// A TV could be drawn around the picture right now, so Display offers the TV list.
  var bezelsOffered = false

  /// The parent supplies the reviewed history policy; nil retains classic behavior for older callers.
  var onQuickSave: (() -> Void)? = nil
  var onQuickLoad: (() -> Void)? = nil
  var runtime = TopBarRuntimeActions()

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var popover: TopBarPopover?
  @State private var handoff = TopBarHandoff<TopBarDestination>()
  @State private var isMuted = false
  @State private var volume: Double = 100
  @State private var values = TopBarValues()

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
    case .menu:
      toolButton(control, "line.3.horizontal", title: L("Menu"), accessibility: L("Game Menu"), selected: true) { openDirect(.menu) }
    case .save:
      toolButton(control, "square.and.arrow.down", title: L("Save"), accessibility: L("Quick Save")) {
        if let onQuickSave { onQuickSave() } else { openDirect(.saves) }
      }
    case .load:
      toolButton(control, "square.and.arrow.up", title: L("Load"), accessibility: L("Quick Load")) {
        if let onQuickLoad { onQuickLoad() } else { openDirect(.saves) }
      }
    case .saves:
      toolButton(control, "clock.arrow.circlepath", title: L("Saves"), accessibility: L("Save States")) { openDirect(.saves) }
    case .fastForward:
      toolButton(control, "forward.fill", title: L("Speed"), accessibility: L("Fast Forward"), selected: fastForwardEnabled) {
        fastForwardEnabled = runtime.toggleFastForward()
        refreshValues()
      }
    case .audio:
      toolButton(control, isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", title: L("Audio")) { popover = .audio }
    case .controller:
      toolButton(control, "gamecontroller", title: L("Controller")) { popover = .controller }
    case .display:
      toolButton(control, "display", title: L("Display")) { popover = .display }
    case .shaders:
      toolButton(control, "square.3.layers.3d", title: L("Shaders"), selected: values.shaderName != nil) { openDirect(.shaders) }
    case .options:
      toolButton(control, "ellipsis.circle", title: L("More")) { popover = .options }
    case .exit:
      toolButton(control, "xmark.circle", title: L("Exit"), accessibility: L("Exit Game"), destructive: true) { openDirect(.exit) }
    }
  }

  private func toolButton(_ control: TopBarControl, _ symbol: String, title: String, accessibility: String? = nil,
                          selected: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> some View {
    TopBarButton(
      symbol: symbol, title: title, caption: values.caption(for: control), accessibility: accessibility ?? title,
      selected: selected, destructive: destructive,
      holdTitle: control.longPressTitle,
      tap: { act(action) },
      hold: control.longPress.map { longPress in { act { perform(longPress) } } })
  }

  /// A held button's second action.
  private func perform(_ longPress: TopBarLongPress) {
    switch longPress {
    case .popover(let kind): popover = kind
    case .destination(let destination): open(destination)
    case .toggleMute:
      isMuted = runtime.toggleMute()
      volume = Double(runtime.readVolume())
      refreshValues()
      EmulationToast.post(isMuted ? L("Muted") : L("Sound on"))
    }
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
    case .speed: speedPopover
    case nil: EmptyView()
    }
  }

  private var audioPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(L("Audio"))
      PopoverRow(title: L("Mute"), systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", isChecked: isMuted) {
        act { isMuted = runtime.toggleMute()
          volume = Double(runtime.readVolume())
          refreshValues()
        }
      }
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        Text(L("Volume")).icubeText(.body)
        Slider(value: Binding(get: { volume }, set: { value in
          act { volume = value
            runtime.setVolume(Int(value))
            isMuted = value <= 0
            refreshValues()
          }
        }), in: 0 ... 100, step: 1)
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
      // One tap makes the on-screen controls that controller (Player 1 of its kind, that pad drawn):
      // a Wii game that wants a GameCube pad, or a Classic Controller, without opening Settings.
      let onScreenControllers = readOnScreenControllers()
      if onScreenControllers.count > 1 {
        Divider()
        sectionHeader(L("On-Screen Controller"))
        ForEach(onScreenControllers) { option in
          PopoverRow(title: option.controller.title, systemImage: "rectangle.3.group", isChecked: option.isSelected) {
            close { onChooseOnScreenController(option.controller) }
          }
        }
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
      sectionHeader(L("Picture"))
      PopoverChoiceRow(
        title: L("Scaling"), options: TopBarValues.aspectOptions.map { ($0.title, $0.raw) }, selection: values.aspectRaw
      ) { raw in
        act { runtime.setAspect(raw)
          refreshValues()
        }
      }
      if bezelsOffered {
        PopoverRow(title: L("Bezel"), systemImage: "tv", value: values.bezelName ?? L("None"), showsChevron: true) {
          closeThenOpen(.bezels)
        }
      }
      if overscanApplicable {
        PopoverRow(title: L("Full Screen Display"), systemImage: "arrow.up.left.and.arrow.down.right", isChecked: overscanFullscreen) {
          close { onSetOverscanFullscreen(!overscanFullscreen) }
        }
      }
      Divider()
      sectionHeader(L("Shader"))
      PopoverRow(title: L("Shader"), systemImage: "square.3.layers.3d", value: values.shaderName ?? L("Off"), showsChevron: true) {
        closeThenOpen(.shaders)
      }
      PopoverRow(title: L("Shader Parameters"), systemImage: "slider.vertical.3", showsChevron: true) { closeThenOpen(.shaderParameters) }
      PopoverRow(title: L("Shader Options"), systemImage: "gearshape", showsChevron: true) { closeThenOpen(.shaderOptions) }
      Divider()
      sectionHeader(L("Tools"))
      PopoverRow(title: L("Screenshot"), systemImage: "camera") { close { takeScreenshot() } }
      PopoverRow(title: L("Performance"), systemImage: "speedometer", showsChevron: true) { closeThenOpen(.perfOverlay) }
      if runtime.thermalEnabled() { ThermalBadgeView() }
      auxiliaryActions
    }
  }

  private var speedPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(L("Fast Forward"))
      ForEach(TopBarValues.speedOptions, id: \.title) { option in
        PopoverRow(title: option.title, systemImage: option.percent == nil ? "play.fill" : "forward.fill",
                   isChecked: option.percent == values.fastForwardPercent) {
          close {
            runtime.setSpeed(option.percent)
            fastForwardEnabled = option.percent != nil
            refreshValues()
          }
        }
      }
    }
  }

  private var optionsPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(L("Options"))
      PopoverRow(title: L("Audio"), systemImage: "speaker.wave.2", value: values.audioTitle, showsChevron: true) { act { popover = .audio } }
      PopoverRow(title: L("Controller"), systemImage: "gamecontroller", value: values.controllerName, showsChevron: true) {
        act { popover = .controller }
      }
      PopoverRow(title: L("Display"), systemImage: "display", value: TopBarValues.aspectTitle(raw: values.aspectRaw), showsChevron: true) {
        act { popover = .display }
      }
      PopoverRow(title: L("Shaders"), systemImage: "square.3.layers.3d", value: values.shaderName ?? L("Off"), showsChevron: true) {
        closeThenOpen(.shaders)
      }
      PopoverRow(title: L("Fast Forward"), systemImage: "forward.fill", isChecked: fastForwardEnabled) {
        act { fastForwardEnabled = runtime.toggleFastForward()
          refreshValues()
        }
      }
      PopoverRow(title: L("Speed"), systemImage: "gauge.with.needle", value: TopBarValues.speedTitle(percent: values.fastForwardPercent),
                 showsChevron: true) {
        act { popover = .speed }
      }
      PopoverRow(title: L("Screenshot"), systemImage: "camera") { close { takeScreenshot() } }
      PopoverRow(title: L("Performance"), systemImage: "speedometer", showsChevron: true) { closeThenOpen(.perfOverlay) }
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
    refreshValues()
  }

  /// The captions under the buttons and the values in the popovers.
  private func refreshValues() {
    var next = readContextValues()
    next.fastForwardPercent = fastForwardEnabled ? runtime.readSpeed() : nil
    next.volume = Int(volume)
    next.isMuted = isMuted
    next.aspectRaw = runtime.readAspect()
    next.shaderName = runtime.readShaderName()
    if next != values { values = next }
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

// MARK: - Bar button

/// One bar button: a symbol, its title and what it is set to. A tap runs `tap`; holding it runs `hold`,
/// which VoiceOver and Switch Control reach as a named action.
///
/// Not a `Button`: a long press stacked on a button still delivers the button's tap on release, and
/// telling the two apart needs a flag that can outlive the press and swallow the next tap. The view's
/// own tap and long-press gestures decide instead: a press that reaches `longPressDuration` is the hold
/// and never also a tap.
private struct TopBarButton: View {
  let symbol: String
  let title: String
  let caption: String?
  let accessibility: String
  let selected: Bool
  let destructive: Bool
  let holdTitle: String?
  let tap: () -> Void
  let hold: (() -> Void)?

  @State private var isPressed = false

  private var tint: Color {
    if destructive { return ICubeDesign.color(.destructive) }
    return ICubeDesign.color(selected ? .accent : .textPrimary)
  }

  var body: some View {
    VStack(spacing: 1) {
      Image(systemName: symbol).font(ICubeDesign.symbolFont(.rail))
      Text(title).icubeText(.detail).lineLimit(1).minimumScaleFactor(0.8)
      if let caption {
        Text(caption).icubeText(.tag).lineLimit(1).minimumScaleFactor(0.7)
          .foregroundStyle(ICubeDesign.color(selected ? .accent : .textSecondary))
      }
    }
    .padding(.horizontal, 2)
    .frame(minWidth: TopBarLayout.minimumTarget, maxWidth: .infinity, minHeight: TopBarLayout.controlHeight)
    .foregroundStyle(tint)
    .background(selected || isPressed ? ICubeDesign.color(.selectedFill) : ICubeDesign.color(.rowSurface).opacity(0),
                in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue))
    .opacity(isPressed ? 0.7 : 1)
    .contentShape(Rectangle())
    .onTapGesture { tap() }
    .modifier(HoldGesture(hold: hold, isPressed: $isPressed))
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(accessibility)
    .accessibilityValue(caption ?? "")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityAction { tap() }
    .modifier(HoldAccessibilityAction(title: holdTitle, action: hold))
  }
}

/// The long press of a bar button that has a second action; a button without one keeps only its tap.
private struct HoldGesture: ViewModifier {
  let hold: (() -> Void)?
  @Binding var isPressed: Bool

  func body(content: Content) -> some View {
    if let hold {
      content.onLongPressGesture(minimumDuration: TopBarLayout.longPressDuration, perform: hold,
                                 onPressingChanged: { isPressed = $0 })
    } else {
      content
    }
  }
}

private struct HoldAccessibilityAction: ViewModifier {
  let title: String?
  let action: (() -> Void)?

  func body(content: Content) -> some View {
    if let title, let action {
      content.accessibilityAction(named: Text(title), action)
    } else {
      content
    }
  }
}

// MARK: - Popover building blocks

/// A setting with a few values, chosen in place: the popover stays open and the row shows the choice.
private struct PopoverChoiceRow: View {
  let title: String
  let options: [(title: String, value: Int)]
  let selection: Int
  let onSelect: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
      Text(title).icubeText(.body)
      HStack(spacing: ICubeDesign.Spacing.xxs.rawValue) {
        ForEach(options, id: \.value) { option in
          let isOn = option.value == selection
          Button { onSelect(option.value) } label: {
            Text(option.title).icubeText(.detail).lineLimit(1).minimumScaleFactor(0.8)
              .frame(maxWidth: .infinity, minHeight: TopBarLayout.minimumTarget)
              .foregroundStyle(ICubeDesign.color(isOn ? .accent : .textPrimary))
              .background(ICubeDesign.color(isOn ? .selectedFill : .rowSurface),
                          in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(title), \(option.title)")
          .accessibilityAddTraits(isOn ? .isSelected : [])
        }
      }
    }
    .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
    .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
  }
}

private struct PopoverRow: View {
  private static let rowHeight: CGFloat = 44
  private static let iconWidth: CGFloat = 28

  let title: String
  let systemImage: String
  var isChecked = false
  /// What the row is set to, shown at its trailing edge.
  var value: String?
  /// The row opens another screen or list.
  var showsChevron = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        Image(systemName: systemImage).frame(width: Self.iconWidth)
        Text(title).icubeText(.body)
        Spacer(minLength: ICubeDesign.Spacing.xs.rawValue)
        if let value {
          Text(value).icubeText(.detail).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
        }
        if isChecked { Image(systemName: "checkmark").foregroundStyle(ICubeDesign.color(.accent)) }
        if showsChevron {
          Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            .foregroundStyle(ICubeDesign.color(.textSecondary))
        }
      }
      .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
      .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(value ?? "")
    .accessibilityAddTraits(isChecked ? .isSelected : [])
  }
}

#endif
