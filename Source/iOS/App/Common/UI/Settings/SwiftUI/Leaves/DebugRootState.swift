// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// UserDefaults keys behind the Debug screen, named once for the host's reader and writer. The bench keys and the instant-replay
/// key are owned by DebugServerManager and the top bar; the rest are read by the core service, the library grid and the first-run service.
enum DebugDefaultsKey {
  static let instantReplay = TopBarDefaultsKey.instantReplayEnabled
  static let launchTimes = "launch_times"
  static let benchEnabled = DebugServerManager.enabledDefaultsKey
  static let benchToken = DebugServerManager.tokenDefaultsKey
  static let loggingEnabled = "logger_console_enabled"
  static let loggingVerbosity = "logger_console_verbosity"
  static let inputDebug = "input_debug"
  static let disableArtwork = "library_disable_artwork"
}

/// Facts about the device and the process that the host reads ONCE, when the screen first appears. Reading them has side
/// effects (`JitManager.recheckIfJitIsAcquired()`) or asks the system (installed apps, the user folder), so `sync()` never
/// re-reads them; it carries this struct forward from the previous snapshot.
struct DebugHydratedState: Equatable {
  var userFolder = ""
  var fastmemAvailable = false
  var jitAcquired = false
  var jitError = ""
  var debuggerAttached = false
  var txmAuthorized = false
  var txmHandshakeBlocked = false
  var deviceHasTxm = false
  var jitSupported = false
  var stikDebugInstalled = false
  var approvedClients: [String] = []
}

/// Snapshot of Config, UserDefaults and (through `hydrated`) the JIT state for the Debug screen. Defaults match the old view's `@State` defaults.
struct DebugRootState: Equatable {
  /// The Recording section and the StikDebug rows are iOS only; the tvOS host leaves this false.
  var isIOS = true
  var fastmem = false
  var launchTimes = 0
  var stallMetrics = false
  var benchEnabled = false
  /// Read, never written here: DebugServerManager mints it on first LAN start. Empty on a DEBUG build, where the bench is loopback-only.
  var benchToken = ""
  var wireframe = false
  var loggingEnabled = false
  var loggingVerbosity = LoggerIniMigration.defaultVerbosity
  var inputDebug = false
  var instantReplay = false
  var disableArtwork = false
  var hydrated = DebugHydratedState()

  /// The verbosity levels the cycle offers, 1 (errors only) to 5 (everything).
  static let verbosityLevels = Array(1 ... 5)

  /// Unset (0) or outside the levels is the default, as the old button treated a stored value of zero.
  static func normalizedVerbosity(_ stored: Int) -> Int {
    verbosityLevels.contains(stored) ? stored : LoggerIniMigration.defaultVerbosity
  }

  /// Shown only when actionable: JIT not acquired, or acquired on a TXM device with no broker attached and no region yet.
  var showsStikDebugEnable: Bool {
    isIOS && hydrated.jitSupported && hydrated.deviceHasTxm && hydrated.stikDebugInstalled
      && (!hydrated.jitAcquired || (hydrated.deviceHasTxm && !hydrated.txmAuthorized && !hydrated.debuggerAttached))
  }

  /// Shown only after StikDebug has been asked and did not attach.
  var showsStikDebugHelp: Bool {
    showsStikDebugEnable && !hydrated.debuggerAttached && !hydrated.txmAuthorized
  }
}

/// One user edit. The host applies it to its snapshot AND to Config or UserDefaults; the builder only emits it.
enum DebugRootChange: Equatable {
  case fastmem(Bool)
  case instantReplay(Bool)
  case stallMetrics(Bool)
  case perfBench(Bool)
  case wireframe(Bool)
  case consoleLogging(Bool)
  case loggingVerbosity(Int)
  case inputDebug(Bool)
  case templateCovers(Bool)
  case retryJitAuthorization
  case enableJitViaStikDebug
  case resetLaunchTimes
  case forgetApprovedDevices
}
