// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SwiftUI

/// The player screen's prompts (decision 10), shown one at a time by the host's single alert and
/// answered by a pad through `MenuModal`.
enum PlayerPrompt: Equatable {
  case saveAs
  /// The typed name matches an existing (user or bundled) profile.
  case confirmOverwrite(name: String)
  /// The typed name is a device-default profile name (`ProfileNaming.builtInNames`).
  case confirmBuiltIn(name: String)
  case confirmReset(profile: String)
  /// Clear All Buttons: unbinds every control of the port.
  case confirmClearAll
  case saveFailed

  var title: String {
    switch self {
    case .saveAs: return L("Save Profile")
    case .confirmOverwrite: return L("Replace Profile?")
    case .confirmBuiltIn: return L("Replace the Built-In Profile?")
    case .confirmReset: return L("Reset to Default Profile?")
    case .confirmClearAll: return L("Clear All Buttons?")
    case .saveFailed: return L("Could Not Save Profile")
    }
  }

  var message: String {
    switch self {
    case .saveAs:
      return L("Saves this player's current mapping as a profile you can load on any port.")
    case .confirmOverwrite(let name):
      return String(format: L("A profile named %@ already exists. Replace it?"), name)
    case .confirmBuiltIn(let name):
      return String(
        format: L("Your profile named %@ will be used instead of the built-in one whenever a device of this kind is first bound, and by Reset to Default Profile."),
        name)
    case .confirmReset(let profile):
      return String(format: L("Loads %@ for this player and replaces its current buttons."), profile)
    case .confirmClearAll:
      return L("Unbinds every control of this player, rumble included. Load a profile or reset to get them back.")
    case .saveFailed:
      return L("The profile file could not be written.")
    }
  }
}

/// The profile last loaded, saved or applied on each port (decision 5). Dolphin does not record
/// which profile a port's mapping came from (`loadProfile:` copies the ini into the live
/// controller), so this is the only source of the name. Main thread only.
///
/// With `defaults`, an unedited name is also kept across launches, keyed by port and the device the
/// port holds (`player_profile_name.<player id>.<qualifier>`), and read back when the session has
/// none for the port; it used to read "Custom" after every relaunch. Keyed by device because a
/// pad's mapping follows the pad (the mapping stash) while the port's other devices bring their
/// own. `qualifier` is always the port's device at the time: applying a profile replaces that
/// device's stored name, editing the mapping or forgetting the name drops it. The session's names
/// are keyed the same way, so a port whose device changes without the player screen (automatic
/// assignment on a connect or disconnect) does not show the previous device's name.
final class PlayerProfileMemory {
  static let shared = PlayerProfileMemory(defaults: .standard)
  static let defaultsKeyPrefix = "player_profile_name."

  struct Entry: Equatable {
    var name: String
    var edited: Bool
  }

  private let defaults: UserDefaults?
  private var entries: [String: Entry] = [:]

  /// Without `defaults` (tests), names last for the session only.
  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
  }

  func entry(for playerID: String, qualifier: String = "") -> Entry? {
    if let entry = entries[Self.key(playerID, qualifier)] { return entry }
    return storedName(for: playerID, qualifier: qualifier).map { Entry(name: $0, edited: false) }
  }

  func remember(_ name: String, for playerID: String, qualifier: String = "") {
    adopt(Entry(name: name, edited: false), for: playerID, qualifier: qualifier)
  }

  /// The port's mapping moved to another device unchanged (a rebind that kept it, or No Device):
  /// `entry`, edited or not, now describes the port on `qualifier`.
  func adopt(_ entry: Entry, for playerID: String, qualifier: String) {
    entries[Self.key(playerID, qualifier)] = entry
    if entry.edited {
      dropStored(playerID, qualifier)
    } else if !qualifier.isEmpty {
      defaults?.set(entry.name, forKey: Self.key(playerID, qualifier))
    }
  }

  /// The mapping changed after the remembered profile was applied.
  func markEdited(_ playerID: String, qualifier: String = "") {
    let key = Self.key(playerID, qualifier)
    if entries[key] == nil, let name = storedName(for: playerID, qualifier: qualifier) {
      entries[key] = Entry(name: name, edited: false)
    }
    entries[key]?.edited = true
    dropStored(playerID, qualifier)
  }

  /// The remembered profile no longer exists: the port reads "Custom".
  func forget(_ playerID: String, qualifier: String = "") {
    entries[Self.key(playerID, qualifier)] = nil
    dropStored(playerID, qualifier)
  }

  /// A profile was deleted: every port and device of one system (`playerIDPrefix`, "gc-" or
  /// "wii-") that remembers it reads "Custom", this session and after a relaunch. Other names, and
  /// the other system's ports (its profiles are separate files), are kept.
  func forgetProfile(named name: String, playerIDPrefix: String) {
    let matches = { (remembered: String) in remembered.caseInsensitiveCompare(name) == .orderedSame }
    // Session and kept names share one key shape (`key(_:_:)`), prefix included.
    let systemPrefix = Self.defaultsKeyPrefix + playerIDPrefix
    for (key, entry) in entries where key.hasPrefix(systemPrefix) && matches(entry.name) {
      entries[key] = nil
    }
    guard let defaults else { return }
    for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(systemPrefix) && (value as? String).map(matches) == true {
      defaults.removeObject(forKey: key)
    }
  }

  private static func key(_ playerID: String, _ qualifier: String) -> String {
    defaultsKeyPrefix + playerID + "." + qualifier
  }

  /// The name kept across launches for the port and device, if any.
  func storedName(for playerID: String, qualifier: String) -> String? {
    guard !qualifier.isEmpty else { return nil }
    return defaults?.string(forKey: Self.key(playerID, qualifier))
  }

  private func dropStored(_ playerID: String, _ qualifier: String) {
    guard !qualifier.isEmpty else { return }
    defaults?.removeObject(forKey: Self.key(playerID, qualifier))
  }
}

/// One player's screen state (controller hub spec, "Player screen"; decision 1). It fills
/// `PlayerState` through the hub's `ControllerHubReading`, exactly as `ControllerHubViewModel` fills
/// the hub's rows, and reaches everything else through `PlayerScreenIO`.
///
/// `init` reads nothing and installs nothing: the hub rebuilds this screen's host on every render.
/// The host renders `displayState`, which is a fresh read until `start()` stores the first snapshot.
@MainActor
@Observable
final class PlayerScreenViewModel {
  let slot: PlayerSlot
  private(set) var state: PlayerScreenState
  /// The prompt the host shows, if any.
  var prompt: PlayerPrompt?
  /// Save Profile As…'s text field.
  var saveName = ""

  /// ~60 Hz while a capture is armed, as the old remap screen polled.
  static let captureTickInterval: TimeInterval = 1.0 / 60
  /// After a capture binds, activation and Back are ignored at least this long, and until the bound
  /// input is released (`isCaptureSettling`). A capture binds while the button is still held (three
  /// polls), but a tvOS `Button` fires on release, and B / Menu still arrive as an exit command.
  /// Without this, binding A re-arms the row on release and binding B pops the screen. The delay
  /// alone is not enough: a player who holds the button longer than this releases after it closed.
  static let rearmDelay: TimeInterval = 0.5

  private let reader: any ControllerHubReading
  private let io: any PlayerScreenIO
  private let memory: PlayerProfileMemory
  private let notificationCenter: NotificationCenter
  /// Seconds, monotonic. Injected so a test can step past `rearmDelay`.
  private let clock: () -> TimeInterval
  /// False in tests, which call `pollCapture()` themselves.
  private let pollsCapture: Bool
  @ObservationIgnored private var isLoaded = false
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var capture: Capture?
  @ObservationIgnored private var ticker: Timer?
  @ObservationIgnored private var captureEndedAt: TimeInterval?
  /// The input the last capture bound, until it has been seen released. It keeps the ticker running
  /// (`pollCapture` samples the release) and keeps `isCaptureSettling` true while it is down.
  @ObservationIgnored private var boundInput: BoundInput?

  /// What `isCaptureSettling` needs to ask "is it still down": the finished machine knows the rest
  /// value it settled on, so an analog input resting above zero never reads held.
  private struct BoundInput {
    let qualifier: String
    let index: Int
    let machine: RemapCaptureMachine
  }

  private struct Capture {
    let row: RemapControlRow
    /// The device being listened to; the capture ends if the port loses it.
    let qualifier: String
    let inputNames: [String]
    var machine: RemapCaptureMachine
  }

  init(
    slot: PlayerSlot,
    reader: any ControllerHubReading = LiveControllerHubReader(),
    io: any PlayerScreenIO = LivePlayerScreenIO(),
    memory: PlayerProfileMemory = .shared,
    notificationCenter: NotificationCenter = .default,
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    pollsCapture: Bool = true
  ) {
    self.slot = slot
    self.reader = reader
    self.io = io
    self.memory = memory
    self.notificationCenter = notificationCenter
    self.clock = clock
    self.pollsCapture = pollsCapture
    state = .empty(PlayerState(kind: slot.kind, port: slot.port, deviceQualifier: "", wiiExtension: 0, isSideways: false))
  }

  // MARK: Snapshot

  /// What the screen shows. Before `start()` it is a fresh read, so the first render (and tvOS's
  /// default focus, computed from the first model) never sees the empty state. A read changes no
  /// state, so this is safe inside `body`.
  var displayState: PlayerScreenState { isLoaded ? state : makeSnapshot() }

  func reload() {
    var snapshot = makeSnapshot()
    // Spec edge case: the pad left mid-capture, or the port changed device. The capture cancels;
    // the binding is kept. A DSU device is never "missing" (decision 11).
    // Also when the armed row left the list (the Wii Remote's extension changed elsewhere): the
    // builder disables every other row while one is armed, so a stale armed id would leave none
    // enabled.
    if let capture,
       capture.qualifier != snapshot.player.deviceQualifier
        || PlayerScreenState.isMissing(capture.qualifier, pads: snapshot.pads)
        || !snapshot.controls.contains(where: { $0.id == capture.row.id }) {
      endCapture()
      snapshot.armedControlID = nil
    }
    state = snapshot
    isLoaded = true
  }

  private func makeSnapshot() -> PlayerScreenState {
    let player = readPlayer()
    let system: RemapSystem = slot.kind == .gameCube ? .gamecube : .wii
    let remembered = memory.entry(for: slot.playerID, qualifier: player.deviceQualifier)
    return PlayerScreenState(
      player: player,
      pads: reader.connectedPads(),
      profileName: remembered?.name,
      profileEdited: remembered?.edited ?? false,
      controls: RemapGroup.groups(for: system, attachment: player.wiiExtension).flatMap {
        io.controlRows(owner: $0.owner, group: $0.id, port: slot.port)
      },
      armedControlID: capture?.row.id,
      pointerMotion: io.pointerMotion(),
      motionPointerEnabled: player.motionPointerEnabled,
      showsAdvanced: state.showsAdvanced,
      advanced: AdvancedSettingGroups.entries(for: system, attachment: player.wiiExtension).map { entry in
        AdvancedGroupState(
          owner: entry.owner, groupId: entry.groupId, title: entry.title,
          settings: io.numericSettings(owner: entry.owner, group: entry.groupId, port: slot.port))
      },
      isPinned: player.isPinned,
      isSensorBarOnTop: io.isSensorBarOnTop())
  }

  /// The same reads, in the same shape, as `ControllerHubViewModel.reload()` makes for this port.
  private func readPlayer() -> PlayerState {
    var player: PlayerState
    switch slot.kind {
    case .gameCube:
      player = PlayerState(
        kind: .gameCube, port: slot.port, deviceQualifier: reader.boundQualifier(forGCPort: slot.port),
        wiiExtension: 0, isSideways: false)
    case .wiiRemote:
      player = PlayerState(
        kind: .wiiRemote, port: slot.port, deviceQualifier: reader.boundQualifier(forWiimote: slot.port),
        wiiExtension: reader.wiiExtension(forWiimote: slot.port), isSideways: reader.isSideways(forWiimote: slot.port))
      player.motionPointerEnabled = io.isMotionPointerEnabled(wiimote: slot.port)
    }
    player.isPinned = io.isPinned(slot)
    return player
  }

  /// Takes a snapshot and follows assignment and device changes until `stop()`. Idempotent.
  func start() {
    reload()
    guard observers.isEmpty else { return }
    let names: [Notification.Name] = [
      ControllerManager.assignmentsChanged,
      .GCControllerDidConnect,
      .GCControllerDidDisconnect,
      .TVControllerDevicesChanged,
    ]
    observers = names.map { name in
      notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reload() }
      }
    }
  }

  /// Also ends an armed capture: a pushed list or editor covers this screen.
  func stop() {
    boundInput = nil
    endCapture()
    observers.forEach { notificationCenter.removeObserver($0) }
    observers.removeAll()
  }

  // MARK: Actions

  var actions: PlayerScreenActions {
    PlayerScreenActions(
      deviceListDestination: { [weak self] in
        AnyView(DeviceListView(
          options: { [weak self] in
            guard let self else { return [] }
            return PlayerScreenModelBuilder.deviceOptions(state: self.displayState, platform: .current)
          },
          current: { [weak self] in self?.displayState.deviceChoice ?? .noDevice },
          refresh: { [weak self] in self?.reload() },
          onPick: { [weak self] in self?.setDevice($0) }))
      },
      profileListDestination: { [weak self] in
        AnyView(ProfileListView(
          current: self?.state.profileName,
          loadNames: { [weak self] in self?.profileNames() ?? [] },
          onPick: { [weak self] in self?.loadProfile($0) },
          loadDeletable: { [weak self] in self?.deletableProfileNames() ?? [] },
          onDelete: { [weak self] in self?.deleteProfile($0) ?? false }))
      },
      saveProfileAs: { [weak self] in self?.openSavePrompt() },
      resetProfile: { [weak self] in self?.requestReset() },
      clearAll: { [weak self] in self?.requestClearAll() },
      setExtension: { [weak self] in self?.setExtension($0) },
      setSideways: { [weak self] in self?.setSideways($0) },
      toggleCapture: { [weak self] in self?.toggleCapture($0) },
      clearBinding: { [weak self] in self?.clear($0) },
      resetBinding: { [weak self] in self?.resetToDefault($0) },
      setPointerMode: { [weak self] mode in self?.write { $0.setPointerMode(mode) } },
      recenterPointer: { [weak self] in self?.io.recenterPointer() },
      setDragGain: { [weak self] gain in self?.write { $0.setDragGain(gain) } },
      setGyroSensitivity: { [weak self] gain in self?.write { $0.setGyroSensitivity(gain) } },
      setInvertX: { [weak self] enabled in self?.write { $0.setInvertX(enabled) } },
      setInvertY: { [weak self] enabled in self?.write { $0.setInvertY(enabled) } },
      setShakeToWiggle: { [weak self] enabled in self?.write { $0.setShakeToWiggle(enabled) } },
      setMotionPointer: { [weak self] in self?.setMotionPointer($0) },
      toggleAdvanced: { [weak self] in self?.state.showsAdvanced.toggle() },
      setNumericSetting: { [weak self] setting, value in self?.setNumericSetting(setting, value: value) },
      expressionDestination: { [weak self] row in
        // Built for every Raw Bindings row on every render: nothing here may read the bridges. The
        // editor reads the inputs and their values only once it is on screen.
        let qualifier = self?.state.player.deviceQualifier ?? ""
        return AnyView(ExpressionEditorView(
          title: ControlCategory.title(for: row),
          original: row.editableExpression,
          family: DeviceFamily.from(qualifier: qualifier),
          loadInputs: { [weak self] in self?.editorInputs(forQualifier: qualifier) ?? [] },
          loadDefault: { [weak self] in self?.defaultExpression(for: row) },
          readInputStates: { [weak self] in self?.io.inputStates(forQualifier: qualifier) ?? [] },
          check: { [weak self] in self?.io.check($0) ?? ExpressionCheck(status: .invalid, message: "") },
          save: { [weak self] in self?.saveExpression($0, for: row) ?? false }))
      })
  }

  /// A setting that is not part of the port's mapping (pointer, motion): write, then re-read.
  private func write(_ change: (any PlayerScreenIO) -> Void) {
    change(io)
    reload()
  }

  // MARK: Device (decisions 9 and 12)

  /// One pick from the Device list: one assignment. Reads a fresh snapshot first: the screen stopped
  /// observing when the list was pushed, so `state` may predate a pad that connected since.
  func setDevice(_ choice: PlayerDeviceChoice) {
    reload()
    guard choice != state.deviceChoice else { return }
    endCapture()
    let controlsBefore = state.controls
    let nameBefore = memory.entry(for: slot.playerID, qualifier: state.player.deviceQualifier)
    var bindsGyroPad = false
    if case .pad(let qualifier) = choice {
      bindsGyroPad = state.pads.first { $0.qualifier == qualifier }?.hasGyro == true
    }
    io.setDevice(choice, slot: slot)
    // Which profile the port holds now, as far as the app can know (Dolphin does not record it):
    // - Touchscreen: both kinds reload the "Touchscreen" profile whenever the bound device changes
    //   (`assignTouchscreen(toGCPort:)`, the coordinator's BindTouchscreen), and it always changes here.
    // - A pad: the assignment loads the pad's default profile unless the port's mapping binds
    //   something on that pad (ControllerAssignmentService.assign), and the bridge's answer to that
    //   cannot be read after the fact (the profile is already loaded). What can: the port's control
    //   rows (each carries its expression). Changed means the default was loaded; unchanged means
    //   the mapping was kept and the remembered name stays.
    // - No Device unbinds the device only; the mapping and its name stay.
    reload()
    let reloadedDefault = choice == .touchscreen || (choice != .noDevice && state.controls != controlsBefore)
    let qualifier = state.player.deviceQualifier
    if reloadedDefault, !qualifier.isEmpty {
      // A pad that got its own mapping back (the assignment's mapping stash) keeps the name it
      // had on this port; otherwise its default profile was loaded.
      let restoredName = choice == .touchscreen ? nil : memory.storedName(for: slot.playerID, qualifier: qualifier)
      if let name = restoredName ?? io.defaultProfileName(forQualifier: qualifier) {
        memory.remember(name, for: slot.playerID, qualifier: qualifier)
      }
    } else if !reloadedDefault, let nameBefore {
      memory.adopt(nameBefore, for: slot.playerID, qualifier: qualifier)
    }
    // Decision 12: the app turns the IMU pointer off on every touchscreen-bound Wii Remote
    // (EmulationCoordinator.mm:1501-1525), and a re-bind keeps the mapping, so a gyro pad taking
    // over would leave its pointer off.
    if slot.kind == .wiiRemote, bindsGyroPad {
      io.setMotionPointerEnabled(true, wiimote: slot.port)
    }
    reload()
  }

  // MARK: Profile (decisions 5 and 10)

  func profileNames() -> [String] { io.profiles(for: slot) }

  /// The profiles Load Profile… may offer to delete: the user's own, never a bundled one.
  func deletableProfileNames() -> [String] { io.userProfileNames(for: slot) }

  /// Deletes one of the user's profiles (Load Profile… asked first). The port keeps its mapping.
  /// Unless a profile of that name is left (a bundled one it shadowed), every port and device of
  /// this system that remembers it reads "Custom".
  @discardableResult
  func deleteProfile(_ name: String) -> Bool {
    guard io.deleteProfile(name, slot: slot) else { return false }
    if !ProfileNaming.exists(name, in: io.allProfileNames(for: slot)) {
      memory.forgetProfile(named: name, playerIDPrefix: slot.playerIDPrefix)
    }
    reload()
    return true
  }

  func loadProfile(_ name: String) {
    endCapture()
    if io.loadProfile(name, slot: slot) {
      memory.remember(name, for: slot.playerID, qualifier: state.player.deviceQualifier)
    }
    reload()
  }

  /// Asks before loading the device's default profile over this port's mapping.
  func requestReset() {
    let qualifier = state.player.deviceQualifier
    guard !qualifier.isEmpty, let name = io.defaultProfileName(forQualifier: qualifier) else { return }
    prompt = .confirmReset(profile: name)
  }

  /// Prefilled so a pad user can save with A without typing; never a device-default name.
  func openSavePrompt() {
    // `suggestion` returns "" for a whitespace-only pad name, a built-in name once a padded name
    // ("Touchscreen ") is trimmed, and the title unsanitized. Fall back to the sanitized title so
    // Save As never opens on a name that cannot be saved or that would replace a built-in profile.
    let suggestion = ProfileNaming.suggestion(padName: state.boundPad?.name, playerTitle: slot.title)
    let usable = !suggestion.isEmpty && !ProfileNaming.isBuiltIn(suggestion)
    saveName = usable ? suggestion : ProfileNaming.sanitized(slot.title)
    prompt = .saveAs
  }

  /// A pad's A, or the alert's own confirming button.
  func confirmPrompt() {
    guard let current = prompt else { return }
    prompt = nil
    switch current {
    case .saveAs:
      let name = ProfileNaming.sanitized(saveName)
      guard !name.isEmpty else { return }
      if ProfileNaming.isBuiltIn(name) {
        present(.confirmBuiltIn(name: name))
      } else if ProfileNaming.exists(name, in: io.allProfileNames(for: slot)) {
        present(.confirmOverwrite(name: name))
      } else {
        save(name)
      }
    case .confirmOverwrite(let name), .confirmBuiltIn(let name):
      save(name)
    case .confirmReset(let profile):
      loadProfile(profile)
    case .confirmClearAll:
      clearAll()
    case .saveFailed:
      break
    }
  }

  /// Asks before unbinding every control. Only where capture works: a port that cannot capture
  /// could not bind anything again, as with a single row's Clear.
  func requestClearAll() {
    guard state.canCapture else { return }
    prompt = .confirmClearAll
  }

  /// Every control of the port (`state.controls`: buttons, sticks, motion, rumble), unbound.
  private func clearAll() {
    guard state.canCapture else { return }
    endCapture()
    for row in state.controls where !row.editableExpression.isEmpty {
      io.setExpression("", for: row, port: slot.port)
    }
    memory.markEdited(slot.playerID, qualifier: state.player.deviceQualifier)
    reload()
  }

  /// A pad's B, or the alert's Cancel.
  func cancelPrompt() {
    prompt = nil
  }

  private func save(_ name: String) {
    if io.saveProfile(name, slot: slot) {
      memory.remember(name, for: slot.playerID, qualifier: state.player.deviceQualifier)
      reload()
    } else {
      present(.saveFailed)
    }
  }

  /// A follow-up prompt, a turn later: the alert that led here is still being dismissed, and
  /// presenting on the same turn can silently fail (seen in the old remap screen).
  private func present(_ next: PlayerPrompt) {
    Task { @MainActor [weak self] in self?.prompt = next }
  }

  // MARK: Wii Remote and settings

  func setExtension(_ value: Int) {
    guard slot.kind == .wiiRemote, value != state.player.wiiExtension else { return }
    endCapture()
    io.setExtension(value, wiimote: slot.port)
    memory.markEdited(slot.playerID, qualifier: state.player.deviceQualifier)
    reload()
  }

  func setSideways(_ enabled: Bool) {
    guard slot.kind == .wiiRemote else { return }
    io.setSideways(enabled, wiimote: slot.port)
    memory.markEdited(slot.playerID, qualifier: state.player.deviceQualifier)
    reload()
  }

  func setMotionPointer(_ enabled: Bool) {
    guard slot.kind == .wiiRemote else { return }
    io.setMotionPointerEnabled(enabled, wiimote: slot.port)
    memory.markEdited(slot.playerID, qualifier: state.player.deviceQualifier)
    reload()
  }

  func setNumericSetting(_ setting: NumericSettingState, value: Double) {
    io.setNumericSetting(setting, value: value, port: slot.port)
    memory.markEdited(slot.playerID, qualifier: state.player.deviceQualifier)
    reload()
  }

  // MARK: Capture

  /// True after a capture bound or timed out, until `rearmDelay` has passed AND the bound input is
  /// released, whichever ends later: the press that was just bound may still be on its way up, and
  /// a tvOS `Button` fires on that release however long the player held it. A timeout bound
  /// nothing, so it settles for the plain delay. The host ignores Back while this is true.
  var isCaptureSettling: Bool {
    if let boundInput, boundInput.machine.isHeld(boundInput.index, in: io.inputStates(forQualifier: boundInput.qualifier)) {
      return true
    }
    return captureEndedAt.map { clock() - $0 < Self.rearmDelay } ?? false
  }

  /// Arms `row`, or cancels when it is the armed row. While one row is armed the builder disables
  /// the others, so another row's activation never gets here mid-capture.
  func toggleCapture(_ row: RemapControlRow) {
    if let capture {
      if capture.row.id == row.id {
        endCapture()
        reload()
      }
      return
    }
    guard !isCaptureSettling, state.canCapture else { return }
    boundInput = nil
    let qualifier = state.player.deviceQualifier
    let names = io.inputNames(forQualifier: qualifier)
    guard !names.isEmpty else { return }
    capture = Capture(
      row: row, qualifier: qualifier, inputNames: names,
      machine: RemapCaptureMachine(
        baseline: io.inputStates(forQualifier: qualifier), capturable: names.map(RemapExpression.isCapturable(inputName:))))
    state.armedControlID = row.id
    if pollsCapture { startTicker() }
  }

  /// One capture tick. A captured input becomes the row's expression; a timeout leaves the binding
  /// as it was (spec edge case "Capture times out").
  func pollCapture() {
    guard var session = capture else {
      sampleBoundInputRelease()
      return
    }
    guard let result = session.machine.poll(io.inputStates(forQualifier: session.qualifier)) else {
      capture = session
      return
    }
    if case .captured(let index) = result, index < session.inputNames.count {
      io.setExpression(RemapExpression.expression(forInputName: session.inputNames[index]), for: session.row, port: slot.port)
      memory.markEdited(slot.playerID, qualifier: state.player.deviceQualifier)
      // The ticker keeps running (`endCapture` leaves it while this is set) to sample the release.
      boundInput = BoundInput(qualifier: session.qualifier, index: index, machine: session.machine)
    }
    captureEndedAt = clock()
    endCapture()
    reload()
  }

  /// A tick with no capture armed: forget the bound input once it has been released. Sampled, not
  /// inferred when asked: on iOS a pad's A arms a row on its press, and a remembered input that
  /// only cleared when somebody asked would still read held on the next press and refuse it.
  private func sampleBoundInputRelease() {
    guard let bound = boundInput else {
      stopTicker()
      return
    }
    if !bound.machine.isHeld(bound.index, in: io.inputStates(forQualifier: bound.qualifier)) {
      boundInput = nil
      stopTicker()
    }
  }

  /// Long-press or swipe Clear. Never races a capture armed on a different row.
  func clear(_ row: RemapControlRow) {
    // A port that cannot capture (No Device, Touchscreen, a disconnected pad) cannot rebind either,
    // so unbinding there would strand the control. `CaptureRowView` offers no Clear then; this is
    // the other half.
    guard state.canCapture else { return }
    if let capture, capture.row.id != row.id { return }
    endCapture()
    io.setExpression("", for: row, port: slot.port)
    memory.markEdited(slot.playerID, qualifier: state.player.deviceQualifier)
    reload()
  }

  /// The expression the bound device's default profile ("Physical Controller", "Touchscreen", …)
  /// gives `row`: what Reset to Default puts back. nil without a device, or when that profile cannot
  /// be read (no bundled DSU profile ships yet).
  func defaultExpression(for row: RemapControlRow) -> String? {
    let qualifier = state.player.deviceQualifier
    guard !qualifier.isEmpty, let profile = io.defaultProfileName(forQualifier: qualifier) else { return nil }
    return io.expression(inProfile: profile, for: row, port: slot.port)
  }

  /// A capture row's Reset to Default: one control back to the default profile's binding. The same
  /// guards as Clear: a port that cannot capture offers neither, and an armed capture on another row
  /// is never raced.
  func resetToDefault(_ row: RemapControlRow) {
    guard state.canCapture else { return }
    if let capture, capture.row.id != row.id { return }
    guard let expression = defaultExpression(for: row) else { return }
    endCapture()
    io.setExpression(expression, for: row, port: slot.port)
    memory.markEdited(slot.playerID, qualifier: state.player.deviceQualifier)
    reload()
  }

  /// The raw-expression editor's input list: the bound device's inputs, in the order its live values
  /// come in. None without a device.
  func editorInputs(forQualifier qualifier: String) -> [String] {
    qualifier.isEmpty ? [] : io.inputNames(forQualifier: qualifier)
  }

  /// Advanced → Raw Bindings. Text that does not parse is never written (spec edge case); the
  /// editor already disables Save for it, and this is the backstop.
  @discardableResult
  func saveExpression(_ text: String, for row: RemapControlRow) -> Bool {
    guard io.check(text).canSave else { return false }
    io.setExpression(text, for: row, port: slot.port)
    memory.markEdited(slot.playerID, qualifier: state.player.deviceQualifier)
    reload()
    return true
  }

  private func startTicker() {
    ticker?.invalidate()
    // `.common`, not `.default`: a `.default` timer starves while the List scrolls, which would
    // freeze an armed capture mid-scroll (seen in the old remap screen).
    let timer = Timer(timeInterval: Self.captureTickInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollCapture() }
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
  }

  /// Leaves the ticker running while a bound input is still being watched for its release.
  private func endCapture() {
    capture = nil
    state.armedControlID = nil
    if boundInput == nil { stopTicker() }
  }
}
