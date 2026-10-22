// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a pad can aim the Wii pointer with (design B1). Read from one `GCController` by the hub's
/// reader and carried on `ConnectedPadState`.
struct PadCapabilities: Equatable {
  /// `GCController.motion?.hasRotationRate`: the MFi backend exposes the pad's `Gyro …` inputs.
  var hasGyro = false
  /// `GCController.supportsTouchpad` (DualSense, DualShock 4).
  var hasTouchpad = false
}

/// What holds Wii Remote 1, as far as its pointer is concerned.
enum PointerPlayer1: Equatable {
  /// Wii Remote 1 has no device.
  case none
  /// The on-screen controls (iOS) or the idle touchscreen device (tvOS, where nothing drives it).
  case touchscreen
  /// A gameplay pad, by its display name.
  case pad(name: String, capabilities: PadCapabilities)

  /// Wii Remote 1's bound device (`ControllerHubReading.boundQualifier(forWiimote: 1)`, "" while off)
  /// against the connected pads. A pad that is not in the list (disconnected, or a DSU device) has
  /// no known capabilities and is named from its qualifier.
  static func from(qualifier: String, pads: [ConnectedPadState]) -> PointerPlayer1 {
    if qualifier.isEmpty { return .none }
    if DeviceFamily.from(qualifier: qualifier) == .touchscreen { return .touchscreen }
    if let pad = pads.first(where: { $0.qualifier == qualifier && !$0.isMenuRemote }) {
      return .pad(name: pad.name, capabilities: pad.capabilities)
    }
    let name = qualifier.split(separator: "/", maxSplits: 2).last.map(String.init) ?? qualifier
    return .pad(name: name, capabilities: PadCapabilities())
  }
}

/// Where Wii Remote 1's pointer comes from (design B2).
enum PointerSource: Equatable {
  /// The pad's own gyro, through its profile's IMU pointer.
  case padGyro(padName: String)
  /// The pad's touchpad.
  case padTouchpad(padName: String)
  /// tvOS: the Siri Remote's motion, written to Wii Remote 1's IR by the app.
  case remoteGyro
  /// iOS: the phone's or iPad's own motion.
  case deviceGyro
  /// iOS: the on-screen IR area, following the finger.
  case touchFollow
  /// iOS: the on-screen IR area, dragged.
  case touchDrag
  /// Nothing can aim.
  case none

  /// The case without its pad name: what the user's override stores (`PointerSourceOverrideStore`).
  /// The raw values are persisted: do not rename.
  enum Kind: String, CaseIterable {
    case padGyro, padTouchpad, remoteGyro, deviceGyro, touchFollow, touchDrag, none
  }

  var kind: Kind {
    switch self {
    case .padGyro: return .padGyro
    case .padTouchpad: return .padTouchpad
    case .remoteGyro: return .remoteGyro
    case .deviceGyro: return .deviceGyro
    case .touchFollow: return .touchFollow
    case .touchDrag: return .touchDrag
    case .none: return .none
    }
  }

  /// What the player holds that moves the pointer: "DualSense gyro", "Siri Remote", "iPad gyro",
  /// "Touch (Follow)", "No pointer". `deviceModel` is `UIDevice.current.model` ("iPhone", "iPad").
  func label(deviceModel: String) -> String {
    switch self {
    case .padGyro(let name): return String(format: L("%@ gyro"), name)
    case .padTouchpad(let name): return String(format: L("%@ touchpad"), name)
    case .remoteGyro: return L("Siri Remote")
    case .deviceGyro: return String(format: L("%@ gyro"), deviceModel)
    case .touchFollow: return L("Touch (Follow)")
    case .touchDrag: return L("Touch (Drag)")
    case .none: return L("No pointer")
    }
  }

  var systemImage: String {
    switch self {
    case .padGyro, .deviceGyro: return "gyroscope"
    case .padTouchpad: return "hand.point.up.left"
    case .remoteGyro: return "appletvremote.gen4"
    case .touchFollow: return "hand.point.up"
    case .touchDrag: return "hand.draw"
    case .none: return "scope"
    }
  }
}

/// Decides Wii Remote 1's pointer source from what is connected (design B2). Pure: the hub, the
/// player screen and `RemotePointerBinding` all read it through `PointerSourceModel`.
///
/// Scope: Player 1 (Wii Remote 1) only. Wii Remotes 2-4 keep today's behaviour (a gyro pad aims
/// through its profile, anything else has no pointer).
enum PointerSourceResolver {
  /// Order: a valid user override, then the pad's gyro, then its touchpad, then (tvOS) the Siri
  /// Remote's motion, then nothing. An iOS touchscreen Player 1 follows `preferredMode` (the
  /// existing Follow / Drag / Gyro choice, `PointerModeController`) and ignores the override: that
  /// mode IS its choice. A plain pad on iOS gets no pointer unless the user overrides it to the
  /// device's gyro (plan call 4). An override the setup cannot honour (a gyro pad that left, a
  /// remote without motion) falls through to automatic.
  static func resolve(
    player1: PointerPlayer1, remoteHasMotion: Bool, platform: PlatformKind,
    preferredMode: PointerMode, userOverride: PointerSource.Kind?
  ) -> PointerSource {
    if platform == .ios, player1 == .touchscreen {
      switch preferredMode {
      case .gyro: return .deviceGyro
      case .touchFollow: return .touchFollow
      case .touchDrag: return .touchDrag
      }
    }
    let valid = sources(player1: player1, remoteHasMotion: remoteHasMotion, platform: platform)
    if let userOverride, let chosen = valid.first(where: { $0.kind == userOverride }) {
      return chosen
    }
    if case .pad(let name, let capabilities) = player1 {
      if capabilities.hasGyro { return .padGyro(padName: name) }
      if capabilities.hasTouchpad { return .padTouchpad(padName: name) }
    }
    if platform == .tvos, remoteHasMotion, player1 != .none { return .remoteGyro }
    return .none
  }

  /// Every source this setup can drive, in the resolver's order. The override must name one of them.
  static func sources(player1: PointerPlayer1, remoteHasMotion: Bool, platform: PlatformKind) -> [PointerSource] {
    switch (platform, player1) {
    case (_, .none):
      return []
    case (.ios, .touchscreen):
      return [.touchFollow, .touchDrag, .deviceGyro]
    case (.tvos, .touchscreen):
      return remoteHasMotion ? [.remoteGyro] : []
    case (_, .pad(let name, let capabilities)):
      var out: [PointerSource] = []
      if capabilities.hasGyro { out.append(.padGyro(padName: name)) }
      if capabilities.hasTouchpad { out.append(.padTouchpad(padName: name)) }
      switch platform {
      case .tvos: if remoteHasMotion { out.append(.remoteGyro) }
      case .ios: out.append(.deviceGyro)
      }
      return out
    }
  }

  /// What the Pointer Source row offers besides Automatic. Narrower than `sources`: an iOS
  /// touchscreen chooses with its own Follow / Drag / Gyro row, and the iPhone/iPad gyro for a pad
  /// (design B4) has no binding in this build, so offering it would do nothing.
  static func choices(player1: PointerPlayer1, remoteHasMotion: Bool, platform: PlatformKind) -> [PointerSource] {
    if platform == .ios, player1 == .touchscreen { return [] }
    return sources(player1: player1, remoteHasMotion: remoteHasMotion, platform: platform).filter { $0 != .deviceGyro }
  }
}

/// Everything a pointer row shows for Wii Remote 1: the resolved source, its label, and the choices.
struct PointerSourceModel: Equatable {
  let source: PointerSource
  /// Sources the user can pick besides Automatic (`PointerSourceResolver.choices`).
  let choices: [PointerSource]
  /// The stored override when the setup can honour it; nil is Automatic.
  let override: PointerSource.Kind?
  let platform: PlatformKind
  /// `UIDevice.current.model`, for "iPad gyro".
  let deviceModel: String

  static func make(
    player1: PointerPlayer1, remoteHasMotion: Bool, platform: PlatformKind, preferredMode: PointerMode,
    userOverride: PointerSource.Kind?, deviceModel: String
  ) -> PointerSourceModel {
    let source = PointerSourceResolver.resolve(
      player1: player1, remoteHasMotion: remoteHasMotion, platform: platform, preferredMode: preferredMode,
      userOverride: userOverride)
    let choices = PointerSourceResolver.choices(player1: player1, remoteHasMotion: remoteHasMotion, platform: platform)
    let honoured = choices.contains { $0.kind == userOverride } ? userOverride : nil
    return PointerSourceModel(source: source, choices: choices, override: honoured, platform: platform, deviceModel: deviceModel)
  }

  /// "DualSense gyro", "Siri Remote", "No pointer".
  var label: String { source.label(deviceModel: deviceModel) }

  /// "Pointer: DualSense gyro"; just "No pointer" when nothing aims.
  var headline: String {
    source == .none ? label : String(format: L("Pointer: %@"), label)
  }

  /// Why nothing aims, and what fixes it. nil while something does.
  var explanation: String? {
    guard source == .none else { return nil }
    return platform == .tvos
      ? L("Connect a controller with motion, or use the Siri Remote.")
      : L("Connect a controller with motion.")
  }

  /// The Pointer Source row's tag for Automatic; the others are `PointerSource.Kind.rawValue`.
  static let automaticTag = "automatic"

  /// Automatic first, then each choice by its label.
  var options: [(String, AnyHashable)] {
    [(L("Automatic"), AnyHashable(Self.automaticTag))]
      + choices.map { ($0.label(deviceModel: deviceModel), AnyHashable($0.kind.rawValue)) }
  }

  var selectedTag: String { override?.rawValue ?? Self.automaticTag }

  /// The override a tag stands for; nil for Automatic or an unknown tag.
  static func override(forTag tag: AnyHashable) -> PointerSource.Kind? {
    (tag.base as? String).flatMap(PointerSource.Kind.init(rawValue:))
  }

  /// The Pointer Source row's help line, while it offers a choice.
  var rowDescription: String {
    platform == .tvos
      ? L("Automatic picks the controller's gyro, then its touchpad, then the Siri Remote.")
      : L("Automatic picks the controller's gyro, then its touchpad.")
  }
}

/// The user's Pointer Source pick, one for every Wii title (design B2's per-system default; the
/// per-game layer is not built). Absent = Automatic.
struct PointerSourceOverrideStore {
  static let defaultsKey = "wii_pointer_source_override"

  var defaults: UserDefaults = .standard

  var value: PointerSource.Kind? {
    get { defaults.string(forKey: Self.defaultsKey).flatMap(PointerSource.Kind.init(rawValue:)) }
    nonmutating set {
      if let newValue { defaults.set(newValue.rawValue, forKey: Self.defaultsKey) } else { defaults.removeObject(forKey: Self.defaultsKey) }
    }
  }
}
