// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Interface, on the menu engine. `sync()` reads Config and UserDefaults into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct ConfigInterfaceView: View {
  @State private var state = ConfigInterfaceState()

  var body: some View {
    SettingsLeafScreen(model: ConfigInterfaceModelBuilder.make(state: state, apply: apply), title: L("Interface"), sync: sync)
  }

  private func sync() {
    let defaults = UserDefaults.standard
    var s = ConfigInterfaceState()
    s.useNamesDB = DOLConfigBridge.mainUseBuiltInTitleDatabase()
    s.useCovers = DOLConfigBridge.mainUseGameCovers()
    s.backgroundStyle = LibraryBackgroundStyle.from(stored: defaults.string(forKey: ConfigInterfaceDefaultsKey.backgroundStyle))
    s.showSubtitles = ConfigInterfaceState.storedShowSubtitles(defaults.object(forKey: ConfigInterfaceDefaultsKey.showSubtitles) as? Bool)
    s.confirmOnStop = DOLConfigBridge.mainConfirmOnStop()
    s.usePanicHandlers = DOLConfigBridge.mainUsePanicHandlers()
    s.osdMessages = DOLConfigBridge.mainOSDMessages()
    state = s
  }

  private func apply(_ change: ConfigInterfaceChange) {
    let defaults = UserDefaults.standard
    switch change {
    case .useNamesDB(let v): state.useNamesDB = v; DOLConfigBridge.setMainUseBuiltInTitleDatabase(v)
    case .useCovers(let v): state.useCovers = v; DOLConfigBridge.setMainUseGameCovers(v)
    case .backgroundStyle(let v): state.backgroundStyle = v; defaults.set(v.rawValue, forKey: ConfigInterfaceDefaultsKey.backgroundStyle)
    case .showSubtitles(let v): state.showSubtitles = v; defaults.set(v, forKey: ConfigInterfaceDefaultsKey.showSubtitles)
    case .confirmOnStop(let v): state.confirmOnStop = v; DOLConfigBridge.setMainConfirmOnStop(v)
    case .usePanicHandlers(let v): state.usePanicHandlers = v; DOLConfigBridge.setMainUsePanicHandlers(v)
    case .osdMessages(let v): state.osdMessages = v; DOLConfigBridge.setMainOSDMessages(v)
    }
  }
}
