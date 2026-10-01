// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The player screen's Device list (decision 9), pushed on both platforms. One pick is one
/// assignment, then the list pops. A stepped picker would assign on every A or d-pad press, and one
/// such step through Touchscreen reloads the Touchscreen profile over the port's mapping.
struct DeviceListView: View {
  /// Read on every render, from the view model's observable snapshot, so the first render is never
  /// empty and every `refresh` shows at once.
  let options: () -> [DeviceOption]
  let current: () -> PlayerDeviceChoice
  /// Re-reads the snapshot (`PlayerScreenViewModel.reload()`). Needed because pushing this list
  /// stops the player screen's own observers (its `onDisappear`), so this list watches the device
  /// notices itself while it is on top.
  let refresh: () -> Void
  let onPick: (PlayerDeviceChoice) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    MenuScreen(
      model: DeviceListModelBuilder.make(options: options(), current: current(), onPick: { choice in
        onPick(choice)
        dismiss()
      }),
      style: .list,
      onBack: { dismiss() })
      .navigationTitle(L("Device"))
      .onAppear { refresh() }
      // The same notices `PlayerScreenViewModel.start()` observes; all declared names.
      .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refresh() }
      .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refresh() }
      .onReceive(NotificationCenter.default.publisher(for: .TVControllerDevicesChanged)) { _ in refresh() }
      .onReceive(NotificationCenter.default.publisher(for: ControllerManager.assignmentsChanged)) { _ in refresh() }
  }
}

/// Pure: one action row per option, the current one marked. Plain rows, not a picker, so a pad's A
/// or d-pad never steps through devices.
enum DeviceListModelBuilder {
  static func itemID(for choice: PlayerDeviceChoice) -> String {
    switch choice {
    case .noDevice: return "device-none"
    case .touchscreen: return "device-touchscreen"
    case .pad(let qualifier): return "device-\(qualifier)"
    }
  }

  static func make(options: [DeviceOption], current: PlayerDeviceChoice, onPick: @escaping (PlayerDeviceChoice) -> Void) -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "devices", header: L("Device"), items: options.map { option in
        MenuItem(
          id: itemID(for: option.choice), title: option.title, icon: icon(for: option.choice),
          role: .action { onPick(option.choice) }, badge: option.choice == current ? L("Current") : nil)
      }),
    ])
  }

  private static func icon(for choice: PlayerDeviceChoice) -> String {
    switch choice {
    case .noDevice: return "xmark.circle"
    case .touchscreen: return "hand.tap"
    case .pad: return "gamecontroller"
    }
  }
}
