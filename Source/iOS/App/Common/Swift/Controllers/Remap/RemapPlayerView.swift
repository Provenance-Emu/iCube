// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController
import SwiftUI

/// One screen per player (GameCube port or Wii Remote) for button remapping.
/// Replaced the legacy storyboard / `TVMappingRootViewController` drill-down
/// (deleted) that needed three taps before the first "capture", which then only
/// accepted typed expression text. Design: `docs/superpowers/specs/2026-09-24-remap-ui-design.md`.
///
/// Layout is one `List`: a header (device, profile, save/reset, Wii extension +
/// sideways) followed by every control group inline. Tapping a control arms a
/// live capture driven by `RemapCaptureMachine` over
/// `TVControllerMappingBridge.inputStates(forQualifiedDevice:)` at ~60 Hz.
///
/// Platforms:
/// - Touch: tap to arm, tap again to cancel, long-press (context menu) or swipe
///   to clear.
/// - iOS + game controller: d-pad / left stick move a highlight, A activates,
///   B goes back (`RemapControllerNav`, polled — no `valueChangedHandler` is
///   installed, so nothing fights the pause menu's handler slot). Gated on
///   `ControllerFocusCoordinator` so a covered surface goes quiet.
/// - tvOS: native focus only; every row is one `Button`, no `Picker`/`Menu`.
///   Menu/B is swallowed while a capture is armed so `Button B` stays bindable.
///
/// Device changes go through `ControllerManager.shared`, never the bridge.
struct RemapPlayerView: View {
  let isGC: Bool
  let portOneBased: Int

  @Environment(\.dismiss) private var dismiss

  // Header state.
  @State private var deviceQualifier = ""
  @State private var controllers: [GCController] = []
  @State private var showDeviceOptions = false
  @State private var profileName: String?
  @State private var profileEdited = false
  @State private var profiles: [String] = []
  @State private var showProfileOptions = false
  @State private var showSavePrompt = false
  @State private var saveName = ""
  @State private var showSaveError = false
  @State private var wiiExtension = 0
  @State private var wiiSideways = false

  // Control rows by group id.
  @State private var rows: [Int: [RemapControlRow]] = [:]

  // Live capture.
  @State private var capture: CaptureSession?
  @State private var ticker: Timer?

  #if os(iOS)
  @State private var nav = RemapControllerNav()
  @State private var focusedID: String?
  @State private var scopeID = UUID()
  #endif

  private struct CaptureSession {
    let rowID: String
    let groupId: Int
    let index: Int
    let inputNames: [String]
    var machine: RemapCaptureMachine
  }

  private enum FocusID {
    static let device = "device"
    static let profile = "profile"
    static let save = "save"
    static let reset = "reset"
    static let ext = "ext"
    static let sideways = "sideways"
    static func deviceOption(_ qualifier: String) -> String { "dev-\(qualifier)" }
    static func profileOption(_ name: String) -> String { "prof-\(name)" }
  }

  private static let tickInterval: TimeInterval = 1.0 / 60.0

  private var system: RemapSystem { isGC ? .gamecube : .wii }
  private var groups: [RemapGroup] { RemapGroup.groups(for: system) }
  private var allRows: [RemapControlRow] { groups.flatMap { rows[$0.id] ?? [] } }
  private var title: String {
    String(format: isGC ? L("Player %d") : L("Wii Remote %d"), portOneBased)
  }

  /// Capture needs a physical device: the touchscreen is laid out by the
  /// on-screen overlay, and an unbound slot has nothing to poll.
  private var deviceIsPhysical: Bool {
    !deviceQualifier.isEmpty && !deviceQualifier.hasPrefix("iOS/")
  }

  // MARK: Body

  var body: some View {
    let list = listView
      .navigationTitle(title)
      .onAppear {
        reloadAll()
        startTicker()
      }
      .onDisappear {
        stopTicker()
        capture = nil
      }
    let observed = observing(list)
    let alerted = alerts(observed)
    #if os(iOS)
    alerted.controllerScope(scopeID)
    #else
    alerted.onExitCommand {
      // While armed the same press must reach the capture poll (so `Button B`
      // is bindable); the 5 s timeout is the cancel path.
      if capture == nil { dismiss() }
    }
    #endif
  }

  private var listView: some View {
    ScrollViewReader { proxy in
      List {
        headerSection
        ForEach(groups) { group in
          Section(header: Text(group.title)) {
            ForEach(rows[group.id] ?? []) { row in
              controlRow(row)
            }
          }
        }
      }
      #if os(iOS)
      .onChange(of: focusedID) { _, id in
        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
      }
      #endif
    }
  }

  private func observing<V: View>(_ content: V) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reloadDevices() }
      .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reloadDevices() }
      .onReceive(NotificationCenter.default.publisher(for: .TVControllerDevicesChanged)) { _ in reloadDevices() }
      .onReceive(NotificationCenter.default.publisher(for: ControllerManager.assignmentsChanged)) { _ in reloadAll() }
  }

  private func alerts<V: View>(_ content: V) -> some View {
    content
      .alert(L("Save Profile"), isPresented: $showSavePrompt) {
        TextField(L("Name"), text: $saveName)
        Button(L("Save")) { saveProfile() }
        Button(L("Cancel"), role: .cancel) {}
      } message: {
        Text(L("Saves this player's current mapping as a profile you can load on any port."))
      }
      .alert(L("Could Not Save Profile"), isPresented: $showSaveError) {
        Button(L("OK"), role: .cancel) {}
      } message: {
        Text(L("The profile file could not be written."))
      }
  }

  // MARK: Header

  private var headerSection: some View {
    Section {
      focusRow(FocusID.device) {
        Button { toggleDeviceOptions() } label: {
          labelValue(L("Device"), deviceSummary(deviceQualifier))
        }
      }
      if showDeviceOptions {
        deviceOptionRows
      }

      focusRow(FocusID.profile) {
        Button { toggleProfileOptions() } label: {
          labelValue(L("Profile"), profileDisplayName)
        }
      }
      if showProfileOptions {
        if profiles.isEmpty {
          Text(L("No profiles")).foregroundStyle(.secondary)
        }
        ForEach(profiles, id: \.self) { name in
          focusRow(FocusID.profileOption(name)) {
            optionRow(name, isSelected: name == profileName) { loadProfile(name) }
          }
        }
      }

      focusRow(FocusID.save) {
        Button(L("Save Profile As…")) { openSavePrompt() }
      }
      focusRow(FocusID.reset) {
        Button(L("Reset to Default Profile")) { resetToDefaultProfile() }
          .disabled(deviceQualifier.isEmpty)
      }

      if !isGC {
        wiiOptionRows
      }
    } footer: {
      Text(captureHint)
    }
    // Per the design spec: while a control is armed, every other row in the
    // screen is disabled for activation. Without this, tapping the Device row
    // mid-capture (touch, or native tvOS select — neither goes through the
    // iOS controller-nav ticker, which already gates on `capture == nil`)
    // could switch the bound device out from under a session still polling
    // the OLD device's input list, producing a nonsense binding.
    // DEVICE-CHECK: on tvOS, disabling this whole section removes every header
    // row from the focus engine's candidate set the instant a capture arms.
    // If the Siri Remote's focus happened to be sitting on a header row at
    // that moment (e.g. the user free-navigated there right before arming a
    // control row via touch/AssistiveTouch), confirm the focus engine settles
    // somewhere sane (the armed control row) rather than showing no focus
    // ring at all — this can only be observed on a real Apple TV.
    .disabled(capture != nil)
  }

  @ViewBuilder
  private var deviceOptionRows: some View {
    focusRow(FocusID.deviceOption("")) {
      optionRow(L("None"), isSelected: deviceQualifier.isEmpty) { applyDevice(nil) }
    }
    #if os(iOS)
    focusRow(FocusID.deviceOption("iOS/")) {
      optionRow(L("Touchscreen"), isSelected: deviceQualifier.hasPrefix("iOS/")) { applyTouchscreen() }
    }
    #endif
    ForEach(Array(controllers.enumerated()), id: \.offset) { _, controller in
      let qualifier = TVControllerMappingBridge.qualifiedName(for: controller) as String
      focusRow(FocusID.deviceOption(qualifier)) {
        optionRow(friendlyName(controller), isSelected: deviceQualifier == qualifier) { applyDevice(controller) }
      }
    }
  }

  @ViewBuilder
  private var wiiOptionRows: some View {
    #if os(tvOS)
    ForEach(0 ..< WiimoteSlotOptions.extensionCount, id: \.self) { value in
      optionRow(String(format: L("Extension: %@"), WiimoteSlotOptions.extensionName(value)),
                isSelected: wiiExtension == value) { setExtension(value) }
    }
    #else
    focusRow(FocusID.ext) {
      Picker(L("Extension"), selection: Binding(get: { wiiExtension }, set: { setExtension($0) })) {
        ForEach(0 ..< WiimoteSlotOptions.extensionCount, id: \.self) { value in
          Text(WiimoteSlotOptions.extensionName(value)).tag(value)
        }
      }
      .pickerStyle(.segmented)
    }
    #endif
    focusRow(FocusID.sideways) {
      Toggle(L("Sideways"), isOn: Binding(get: { wiiSideways }, set: { setSideways($0) }))
    }
  }

  private var captureHint: String {
    if !deviceIsPhysical {
      return L("Bind a game controller to this player to capture buttons. Touchscreen controls are laid out by the on-screen overlay.")
    }
    return L("Tap a control, then press the button or move the stick to bind it. Tap again to cancel; long-press to clear.")
  }

  private var profileDisplayName: String {
    guard let profileName else { return L("Custom") }
    return profileEdited ? String(format: L("%@ (edited)"), profileName) : profileName
  }

  // MARK: Control rows

  @ViewBuilder
  private func controlRow(_ row: RemapControlRow) -> some View {
    let armed = capture?.rowID == row.id
    focusRow(row.id) {
      Button { toggleCapture(row) } label: {
        HStack {
          Text(row.name)
          Spacer()
          if armed {
            Text(L("Press a button…"))
              .foregroundStyle(Color.accentColor)
          } else {
            Text(row.expression)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
      .opacity(capture != nil && !armed ? 0.5 : 1)
      // Explicit gate, not just the dimming above: `contextMenu`/`swipeActions`
      // are separate gesture recognizers that are not reliably silenced by
      // SwiftUI's `isEnabled` environment, and `toggleCapture`'s own no-op
      // guard only covers the primary tap. Without this, long-pressing (or
      // swiping) a DIFFERENT row than the one armed could still clear it
      // while a capture was in flight.
      .disabled(capture != nil && !armed)
      .contextMenu {
        Button(L("Clear"), role: .destructive) { clear(row) }
      }
      #if os(iOS)
      .swipeActions(edge: .trailing) {
        Button(L("Clear"), role: .destructive) { clear(row) }
      }
      #endif
      .accessibilityLabel("\(row.name), \(armed ? L("Press a button…") : row.expression)")
    }
  }

  /// A row's id for `ScrollViewReader` and, on iOS, the controller-nav
  /// highlight. On tvOS native focus draws its own ring.
  @ViewBuilder
  private func focusRow<Content: View>(_ id: String, @ViewBuilder content: () -> Content) -> some View {
    #if os(iOS)
    content()
      .id(id)
      .listRowBackground(focusedID == id ? Color.accentColor.opacity(0.22) : nil)
    #else
    content().id(id)
    #endif
  }

  @ViewBuilder
  private func optionRow(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        if isSelected { Image(systemName: "checkmark") }
      }
    }
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  @ViewBuilder
  private func labelValue(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value).foregroundStyle(.secondary).lineLimit(1)
    }
  }

  // MARK: Capture

  private func toggleCapture(_ row: RemapControlRow) {
    if let capture {
      // Tapping the armed row cancels; taps anywhere else are ignored while armed.
      if capture.rowID == row.id { endCapture() }
      return
    }
    guard deviceIsPhysical else { return }
    let names = TVControllerMappingBridge.inputs(forQualifiedDevice: deviceQualifier) as [String]
    guard !names.isEmpty else { return }
    let baseline = TVControllerMappingBridge.inputStates(forQualifiedDevice: deviceQualifier).map { $0.floatValue }
    capture = CaptureSession(
      rowID: row.id, groupId: row.groupId, index: row.index, inputNames: names,
      machine: RemapCaptureMachine(baseline: baseline, capturable: names.map(RemapExpression.isCapturable(inputName:)))
    )
  }

  private func pollCapture() {
    guard var session = capture else { return }
    let values = TVControllerMappingBridge.inputStates(forQualifiedDevice: deviceQualifier).map { $0.floatValue }
    guard let result = session.machine.poll(values) else {
      capture = session
      return
    }
    if case .captured(let inputIndex) = result, inputIndex < session.inputNames.count {
      write(expression: RemapExpression.expression(forInputName: session.inputNames[inputIndex]),
            groupId: session.groupId, index: session.index)
    }
    endCapture()
  }

  private func endCapture() {
    capture = nil
    #if os(iOS)
    // The captured button / stick push is still held; adopt it silently so it
    // is not read back as "activate" or "move".
    if let pad = navGamepad() {
      nav.resync(navInput(pad), at: CACurrentMediaTime())
    }
    #endif
  }

  private func clear(_ row: RemapControlRow) {
    // A capture in flight for a DIFFERENT row must not be raced by a
    // long-press/swipe Clear on this one — the `.disabled` on the row only
    // gates the tap gesture, not the context menu / swipe action.
    if let capture, capture.rowID != row.id { return }
    if capture != nil { endCapture() }
    write(expression: "", groupId: row.groupId, index: row.index)
  }

  private func write(expression: String, groupId: Int, index: Int) {
    if isGC {
      TVControllerMappingBridge.setPadControlExpressionForPort(portOneBased, group: groupId, index: index, expression: expression)
    } else {
      TVControllerMappingBridge.setWiimoteControlExpressionFor(portOneBased, group: groupId, index: index, expression: expression)
    }
    profileEdited = true
    reloadGroup(groupId)
  }

  // MARK: Ticker (capture poll + iOS controller nav)

  private func startTicker() {
    stopTicker()
    // Scheduled directly on `.common` (not `.default`, `scheduledTimer`'s
    // implicit mode) so capture polling and controller-nav keep ticking while
    // the user is dragging the List — `.default` mode timers are starved
    // during UIScrollView's `.tracking` run-loop mode, which would otherwise
    // freeze an armed capture mid-scroll.
    let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { _ in tick() }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
  }

  private func tick() {
    if capture != nil {
      pollCapture()
      return
    }
    #if os(iOS)
    pollNav()
    #endif
  }

  #if os(iOS)
  private func pollNav() {
    guard ControllerFocusCoordinator.isActiveScope(scopeID), let pad = navGamepad() else { return }
    for event in nav.update(navInput(pad), at: CACurrentMediaTime()) {
      switch event {
      case .move(let step): moveFocus(step)
      case .activate: if let id = focusedID { activate(id) }
      case .back: dismiss()
      case .jumpSection: break // no sections on this screen; no shoulder input is wired into navInput(_:)
      }
    }
  }

  /// The controller bound to this player if it is connected, else any pad.
  private func navGamepad() -> GCExtendedGamepad? {
    let bound = controllers.first { (TVControllerMappingBridge.qualifiedName(for: $0) as String) == deviceQualifier }
    return (bound ?? controllers.first { $0.extendedGamepad != nil })?.extendedGamepad
  }

  private func navInput(_ pad: GCExtendedGamepad) -> RemapControllerNav.Input {
    RemapControllerNav.Input(
      up: pad.dpad.up.isPressed,
      down: pad.dpad.down.isPressed,
      stickY: pad.leftThumbstick.yAxis.value,
      a: pad.buttonA.isPressed,
      b: pad.buttonB.isPressed
    )
  }

  /// Everything a controller can land on, top to bottom, for the current
  /// expanded state.
  private var focusOrder: [String] {
    var ids = [FocusID.device]
    if showDeviceOptions {
      ids.append(FocusID.deviceOption(""))
      ids.append(FocusID.deviceOption("iOS/"))
      ids += controllers.map { FocusID.deviceOption(TVControllerMappingBridge.qualifiedName(for: $0) as String) }
    }
    ids.append(FocusID.profile)
    if showProfileOptions { ids += profiles.map(FocusID.profileOption) }
    ids += [FocusID.save, FocusID.reset]
    if !isGC { ids += [FocusID.ext, FocusID.sideways] }
    ids += allRows.map(\.id)
    return ids
  }

  private func moveFocus(_ step: Int) {
    let order = focusOrder
    guard !order.isEmpty else { return }
    guard let current = focusedID, let index = order.firstIndex(of: current) else {
      focusedID = order.first
      return
    }
    focusedID = order[max(0, min(order.count - 1, index + step))]
  }

  private func activate(_ id: String) {
    switch id {
    case FocusID.device: toggleDeviceOptions()
    case FocusID.profile: toggleProfileOptions()
    case FocusID.save: openSavePrompt()
    case FocusID.reset: resetToDefaultProfile()
    case FocusID.ext: setExtension((wiiExtension + 1) % WiimoteSlotOptions.extensionCount)
    case FocusID.sideways: setSideways(!wiiSideways)
    case FocusID.deviceOption(""): applyDevice(nil)
    case FocusID.deviceOption("iOS/"): applyTouchscreen()
    default:
      if let row = allRows.first(where: { $0.id == id }) {
        toggleCapture(row)
      } else if let controller = controllers.first(where: { FocusID.deviceOption(TVControllerMappingBridge.qualifiedName(for: $0) as String) == id }) {
        applyDevice(controller)
      } else if let name = profiles.first(where: { FocusID.profileOption($0) == id }) {
        loadProfile(name)
      }
    }
  }
  #endif

  // MARK: Header actions

  private func toggleDeviceOptions() {
    showDeviceOptions.toggle()
    if showDeviceOptions { showProfileOptions = false }
  }

  private func toggleProfileOptions() {
    if !showProfileOptions { reloadProfiles() }
    showProfileOptions.toggle()
    if showProfileOptions { showDeviceOptions = false }
  }

  private func applyDevice(_ controller: GCController?) {
    if let controller {
      if isGC { ControllerManager.shared.assign(controller, toGCPort: portOneBased) }
      else { ControllerManager.shared.assign(controller, toWiimote: portOneBased) }
    } else {
      if isGC { ControllerManager.shared.clearDefaultDevice(forGCPort: portOneBased) }
      else { ControllerManager.shared.clearDefaultDevice(forWiimote: portOneBased) }
    }
    showDeviceOptions = false
    reloadAll()
    applyDeviceDefaultProfileName()
  }

  private func applyTouchscreen() {
    if isGC { ControllerManager.shared.assignTouchscreen(toGCPort: portOneBased) }
    else { ControllerManager.shared.assignTouchscreen(toWiimote: portOneBased) }
    showDeviceOptions = false
    reloadAll()
    applyDeviceDefaultProfileName()
  }

  /// Binding a device applies its default profile (`ControllerAssignmentService`),
  /// so the header must show that profile's name, not "Custom" — `reloadAll()`
  /// above has already refreshed `deviceQualifier` to the just-bound device.
  private func applyDeviceDefaultProfileName() {
    profileName = deviceQualifier.isEmpty
      ? nil
      : BridgeControllerConfigWriter().defaultProfileName(forQualifier: deviceQualifier)
    profileEdited = false
  }

  private func loadProfile(_ name: String) {
    showProfileOptions = false
    // Same shape as ControllerSetupSections: collapse first, load on the next
    // main-queue turn so the UI updates before the synchronous config write.
    DispatchQueue.main.async {
      let ok = isGC
        ? TVControllerMappingBridge.loadProfile(name, forGCPort: portOneBased, restoreDevice: true)
        : TVControllerMappingBridge.loadProfile(name, forWiimote: portOneBased, restoreDevice: true)
      // autoAssign: false — loading a profile for THIS port must not let the
      // assignment engine re-decide every other port's device binding (see
      // ControllerManager.reconcile(autoAssign:)'s doc comment). That was the
      // "profiles loading weird" bug: loading a profile for one player could
      // silently reassign a different player's controller.
      ControllerManager.shared.reconcile(autoAssign: false)
      if ok {
        profileName = name
        profileEdited = false
      }
      reloadAll()
    }
  }

  private func openSavePrompt() {
    saveName = profileName ?? ""
    showSavePrompt = true
  }

  private func saveProfile() {
    let name = saveName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/", with: "-")
    guard !name.isEmpty else { return }
    let ok = isGC
      ? TVControllerMappingBridge.saveProfile(name, forGCPort: portOneBased)
      : TVControllerMappingBridge.saveProfile(name, forWiimote: portOneBased)
    if ok {
      profileName = name
      profileEdited = false
      reloadProfiles()
    } else {
      // Deferred a turn: this runs from the "Save" action of the
      // `showSavePrompt` alert, which SwiftUI is dismissing on this same
      // turn. Presenting the error alert synchronously here can race that
      // dismissal and silently fail to appear.
      DispatchQueue.main.async {
        showSaveError = true
      }
    }
  }

  /// Reload the profile the assignment service would pick for this device
  /// ("Physical Controller", "Touchscreen", "DSU"), keeping the device.
  private func resetToDefaultProfile() {
    guard let name = BridgeControllerConfigWriter().defaultProfileName(forQualifier: deviceQualifier) else { return }
    loadProfile(name)
  }

  private func setExtension(_ value: Int) {
    wiiExtension = value
    WiimoteSlotOptions.setExtension(value, forWiimote: portOneBased)
  }

  private func setSideways(_ enabled: Bool) {
    wiiSideways = enabled
    WiimoteSlotOptions.setSideways(enabled, forWiimote: portOneBased)
  }

  // MARK: Reload

  private func reloadAll() {
    reloadDevices()
    reloadQualifier()
    for group in groups { reloadGroup(group.id) }
    if !isGC {
      wiiExtension = WiimoteSlotOptions.selectedExtension(forWiimote: portOneBased)
      wiiSideways = WiimoteSlotOptions.isSideways(forWiimote: portOneBased)
    }
  }

  private func reloadDevices() {
    controllers = GCController.controllers()
    reloadQualifier()
  }

  /// Same rule as `ControllerSetupSections.reloadQualifiers`: an inactive slot
  /// shows no device even though its stock default device string is the
  /// touchscreen.
  private func reloadQualifier() {
    let active = isGC
      ? DOLConfigBridge.gcPortDevice(forPort: portOneBased) != 0
      : DOLConfigBridge.wiimoteSource(for: portOneBased) != 0
    guard active else {
      deviceQualifier = ""
      return
    }
    deviceQualifier = isGC
      ? TVControllerMappingBridge.defaultDevice(forGCPort: portOneBased) as String
      : TVControllerMappingBridge.defaultDevice(forWiimote: portOneBased) as String
  }

  private func reloadGroup(_ groupId: Int) {
    let names: [String]
    let expressions: [String]
    if isGC {
      names = TVControllerMappingBridge.padControlNames(forGroup: portOneBased, group: groupId) as [String]
      expressions = TVControllerMappingBridge.padControlExpressions(forGroup: portOneBased, group: groupId) as [String]
    } else {
      names = TVControllerMappingBridge.wiimoteControlNames(forGroup: portOneBased, group: groupId) as [String]
      expressions = TVControllerMappingBridge.wiimoteControlExpressions(forGroup: portOneBased, group: groupId) as [String]
    }
    rows[groupId] = names.enumerated().map { index, name in
      RemapControlRow(groupId: groupId, index: index, name: name,
                      expression: index < expressions.count ? expressions[index] : RemapExpression.unboundDisplay)
    }
  }

  private func reloadProfiles() {
    let list = isGC
      ? TVControllerMappingBridge.profiles(forGCPort: portOneBased) as [String]
      : TVControllerMappingBridge.profiles(forWiimote: portOneBased) as [String]
    profiles = list.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  // MARK: Helpers

  private func friendlyName(_ controller: GCController) -> String {
    controller.vendorName ?? controller.productCategory
  }

  private func deviceSummary(_ qualifier: String) -> String {
    if qualifier.isEmpty { return L("None") }
    if qualifier.hasPrefix("iOS/") { return L("Touchscreen") }
    if let controller = controllers.first(where: { (TVControllerMappingBridge.qualifiedName(for: $0) as String) == qualifier }) {
      return friendlyName(controller)
    }
    return qualifier
  }
}
