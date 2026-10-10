// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Debug, on the menu engine. `sync()` reads Config and UserDefaults into the snapshot and writes nothing; `apply(_:)` is the only writer.
/// The JIT, fastmem and user-folder facts are read once by `.task` (reading them rechecks JIT) and carried forward by `sync()`.
struct DebugRootView: View {
  @State private var state = DebugRootState()
  @State private var hydrated = false

  var body: some View {
    SettingsLeafScreen(model: DebugRootModelBuilder.make(state: state, apply: apply), title: L("Debug"), sync: sync)
      .task {
        guard !hydrated else { return }
        hydrated = true
        state.hydrated = Self.readHydratedState()
      }
  }

  private static func readHydratedState() -> DebugHydratedState {
    let manager = JitManager.shared()
    manager.recheckIfJitIsAcquired()
    return DebugHydratedState(
      userFolder: UserFolderUtil.getUserFolder(),
      fastmemAvailable: FastmemManager.shared().fastmemAvailable,
      jitAcquired: manager.acquiredJit,
      jitError: manager.acquisitionError ?? "",
      debuggerAttached: manager.debuggerAttached,
      txmAuthorized: manager.txmAuthorized,
      txmHandshakeBlocked: manager.txmHandshakeBlocked,
      deviceHasTxm: manager.deviceHasTxm,
      jitSupported: manager.jitSupported,
      stikDebugInstalled: StikDebugLauncher.isStikDebugInstalled,
      approvedClients: BenchAccessApproval.shared.rememberedAddresses)
  }

  private func sync() {
    let defaults = UserDefaults.standard
    var s = DebugRootState()
    #if !os(iOS)
    s.isIOS = false
    #endif
    // sync builds a fresh state, so what the task read would otherwise vanish on every Config change.
    s.hydrated = state.hydrated
    s.fastmem = DOLConfigBridge.mainFastmem()
    s.launchTimes = defaults.integer(forKey: DebugDefaultsKey.launchTimes)
    s.stallMetrics = DOLConfigBridge.stallMetrics()
    s.benchEnabled = defaults.bool(forKey: DebugDefaultsKey.benchEnabled)
    s.benchToken = defaults.string(forKey: DebugDefaultsKey.benchToken) ?? ""
    s.wireframe = DOLConfigBridge.gfxWireframe()
    s.loggingEnabled = defaults.bool(forKey: DebugDefaultsKey.loggingEnabled)
    s.loggingVerbosity = DebugRootState.normalizedVerbosity(defaults.integer(forKey: DebugDefaultsKey.loggingVerbosity))
    s.inputDebug = defaults.bool(forKey: DebugDefaultsKey.inputDebug)
    s.instantReplay = defaults.bool(forKey: DebugDefaultsKey.instantReplay)
    s.disableArtwork = defaults.bool(forKey: DebugDefaultsKey.disableArtwork)
    state = s
  }

  private func apply(_ change: DebugRootChange) {
    let defaults = UserDefaults.standard
    switch change {
    case .fastmem(let v): state.fastmem = v; DOLConfigBridge.setMainFastmem(v)
    case .instantReplay(let v): state.instantReplay = v; defaults.set(v, forKey: DebugDefaultsKey.instantReplay)
    case .stallMetrics(let v): state.stallMetrics = v; DOLConfigBridge.setStallMetrics(v)
    case .perfBench(let v): state.benchEnabled = v; defaults.set(v, forKey: DebugDefaultsKey.benchEnabled)
    case .wireframe(let v): state.wireframe = v; DOLConfigBridge.setGfxWireframe(v)
    case .consoleLogging(let v): state.loggingEnabled = v; defaults.set(v, forKey: DebugDefaultsKey.loggingEnabled)
    case .loggingVerbosity(let v): state.loggingVerbosity = v; defaults.set(v, forKey: DebugDefaultsKey.loggingVerbosity)
    case .inputDebug(let v): state.inputDebug = v; defaults.set(v, forKey: DebugDefaultsKey.inputDebug)
    case .templateCovers(let v): state.disableArtwork = v; defaults.set(v, forKey: DebugDefaultsKey.disableArtwork)
    case .resetLaunchTimes: state.launchTimes = 0; defaults.set(0, forKey: DebugDefaultsKey.launchTimes)
    case .retryJitAuthorization:
      JitManager.shared().clearTXMHandshakeCookie()
      state.hydrated.txmHandshakeBlocked = false
    case .forgetApprovedDevices:
      BenchAccessApproval.shared.forgetAll()
      state.hydrated.approvedClients = []
    case .enableJitViaStikDebug:
      #if os(iOS)
      StikDebugLauncher.enableJIT()
      #endif
    }
  }
}
