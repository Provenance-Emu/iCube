// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import GameController
#if os(iOS)
import NavigationStackBackport
#endif

internal struct ControllerMappingView: View {
  @State private var controllers: [GCController] = []
  @State private var currentQualifiers: [Int: String] = [:] // portOneBased -> qualifier
  @State private var showPickerForPort: Int?
  /// Selected GC port to load a profile for (1-based). When non-nil, present GC profile sheet.
  @State private var showProfileForGCPort: Int? = nil
  /// Selected Wiimote to load a profile for (1-based). When non-nil, present Wiimote profile sheet.
  @State private var showProfileForWiimote: Int? = nil
  /// Per-Wiimote extension: 0 None, 1 Nunchuk, 2 Classic
  @State private var wiiExtension: [Int] = [0, 0, 0, 0]
  /// Per-Wiimote sideways toggle
  @State private var wiiSideways: [Bool] = [false, false, false, false]
  /// Cached GC profiles for the active port sheet
  @State private var gcProfiles: [String] = []
  /// Cached Wiimote profiles for the active port sheet
  @State private var wiiProfiles: [String] = []
  /// GC assignment per port (0 None, 1 Controller, ...)
  @State private var gcPortDevices: [Int] = [0, 0, 0, 0]
  /// Wiimote source per port (0 None, 1 Emulated, ...)
  @State private var wiiSources: [Int] = [0, 0, 0, 0]
  let game: TVGameItem
  let onBack: () -> Void

  @FocusState private var focused: FocusField?
  private enum FocusField: Hashable {
    case back
    case assign(Int)
    case clear(Int)
  }

  private func reload() {
    controllers = GCController.controllers()
    for port in 1...4 {
      currentQualifiers[port] = ControllerManager.shared.defaultDeviceQualifier(forGCPort: port)
      gcPortDevices[port - 1] = DOLConfigBridge.gcPortDevice(forPort: port)
      wiiSources[port - 1] = DOLConfigBridge.wiimoteSource(for: port)
    }
  }

  /// Fetch GC profiles for the given port.
  private func loadGCProfiles(forPort port: Int) {
    gcProfiles = TVControllerMappingBridge.profiles(forGCPort: port)
  }

  /// Fetch Wiimote profiles for the given port.
  private func loadWiimoteProfiles(forWiimote port: Int) {
    wiiProfiles = TVControllerMappingBridge.profiles(forWiimote: port)
  }

  /// Initialize Wiimote extension/sideways state from the bridge.
  private func syncWiimoteState() {
    for i in 0..<4 {
      let ext = Int(DOLWiimoteBridge.selectedExtension(forWiimote: Int(i)))
      let side = DOLWiimoteBridge.isSideways(forWiimote: Int(i))
      wiiExtension[i] = ext
      wiiSideways[i] = side
    }
  }

#if os(iOS)
  var sectionPlayers: some View {
    Section(header: Text(L("Players"))) {
      ForEach(1...4, id: \.self) { port in
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(String(format: L("Player %d"), port)).font(.headline)
            let q = currentQualifiers[port] ?? ""
            Text(q.isEmpty ? L("No controller assigned") : q)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          // Badges to clarify assignment types
          HStack(spacing: 6) {
            if gcPortDevices[port - 1] != 0 {
              Text("GC").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.15), in: Capsule())
            }
            if wiiSources[port - 1] != 0 {
              Text("Wii").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.green.opacity(0.15), in: Capsule())
            }
          }
          Button(L("Assign")) { showPickerForPort = port }
          Button(L("Profiles")) {
            showProfileForGCPort = port
            loadGCProfiles(forPort: port)
          }
          Button(L("Clear")) {
            ControllerManager.shared.clearDefaultDevice(forGCPort: port)
            reload()
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Cleared Player %d"), port)])
          }
        }
      }
    }
  }

  var sectionWiiMotes: some View {
    Section(header: Text(L("Wii Remotes (Quick)"))) {
      ForEach(1...4, id: \.self) { w in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(String(format: L("Wii Remote %d"), w)).font(.headline)
            Spacer()
            Button(L("Profiles")) { showProfileForWiimote = w; loadWiimoteProfiles(forWiimote: w) }
          }
          // Clear, separate affordances for extension and sideways
          HStack(spacing: 16) {
            // Extension segmented control
            Picker(L("Extension"), selection: Binding(get: { wiiExtension[w - 1] }, set: { v in
              wiiExtension[w - 1] = v
              DOLWiimoteBridge.setExtensionForWiimote(Int(w - 1), extension: v)
              // retrigger overlay/nib refresh
              ControllerManager.shared.reconcile()
              NotificationCenter.default.post(name: Notification.Name("DOLWiiOverlayLayoutChangedNotification"), object: nil)
            })) {
              Text(L("None")).tag(0)
              Text(L("Nunchuk")).tag(1)
              Text(L("Classic")).tag(2)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            // Sideways toggle
            Toggle(L("Sideways"), isOn: Binding(get: { wiiSideways[w - 1] }, set: { v in
              wiiSideways[w - 1] = v
              DOLWiimoteBridge.setSidewaysForWiimote(Int(w - 1), enabled: v)
              ControllerManager.shared.reconcile()
              NotificationCenter.default.post(name: Notification.Name("DOLWiiOverlayLayoutChangedNotification"), object: nil)
            }))
            .toggleStyle(.switch)
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  var sectionConnectedControllers: some View {
    Section(header: Text(L("Connected Controllers"))) {
      if controllers.isEmpty {
        CompactDolphinError(message: L("No controllers connected"))
          .padding(.vertical, 8)
      } else {
        ForEach(Array(controllers.enumerated()), id: \.offset) { _, c in
          HStack {
            Image(systemName: "gamecontroller").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
              Text(c.vendorName ?? c.productCategory)
              Text(c.productCategory).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("P\(c.playerIndex.rawValue + 1)").font(.caption)
          }
        }
      }
    }
  }
#endif

  var body: some View {
#if os(iOS)
    NavigationStack {
      List {
        sectionPlayers
        sectionWiiMotes
        sectionConnectedControllers
      }
      .navigationTitle(L("Controllers"))
      .toolbar(content: {
        ToolbarItem(placement: .navigationBarLeading) {
          Button(L("Back")) { onBack() }
        }
      })
      .onAppear { reload(); syncWiimoteState() }
      .sheet(isPresented: Binding(get: { showPickerForPort != nil }, set: { if !$0 { showPickerForPort = nil } })) {
        if let port = showPickerForPort {
          ControllerPickerSheet(game: game, port: port) { selected in
            if let idx = selected, controllers.indices.contains(idx) {
              ControllerManager.shared.assign(controllers[idx], toGCPort: port)
              reload()
              NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Assigned to Player %d"), port)])
            }
            else if selected == -1 {
              ControllerManager.shared.assignTouchscreen(toGCPort: port)
              reload()
              NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Touchscreen assigned to Player %d"), port)])
            }
            showPickerForPort = nil
          }
        }
      }
      .sheet(isPresented: Binding(get: { showProfileForGCPort != nil }, set: { if !$0 { showProfileForGCPort = nil } })) {
        if let port = showProfileForGCPort {
          NavigationStack {
            List(gcProfiles, id: \.self) { p in
              Button(action: {
                let ok = TVControllerMappingBridge.loadProfile(p, forGCPort: port, restoreDevice: true)
                if ok {
                  ControllerManager.shared.reconcile()
                  reload()
                  NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Loaded profile %@ for P%d"), p, port)])
                }
                showProfileForGCPort = nil
              }) { Text(p) }
            }
            .navigationTitle(L("GC Profiles"))
          }
        }
      }
      .sheet(isPresented: Binding(get: { showProfileForWiimote != nil }, set: { if !$0 { showProfileForWiimote = nil } })) {
        if let w = showProfileForWiimote {
          NavigationStack {
            List(wiiProfiles, id: \.self) { p in
              Button(action: {
                let ok = TVControllerMappingBridge.loadProfile(p, forWiimote: w, restoreDevice: true)
                if ok {
                  ControllerManager.shared.reconcile()
                  NotificationCenter.default.post(name: Notification.Name("DOLWiiOverlayLayoutChangedNotification"), object: nil)
                  NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Loaded Wiimote %d profile %@"), w, p)])
                }
                showProfileForWiimote = nil
              }) { Text(p) }
            }
            .navigationTitle(L("Wiimote Profiles"))
          }
        }
      }
    }
#else
    ZStack {
      // Beautiful blurred background
      Image(uiImage: game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 25)
        .opacity(0.8)
        .ignoresSafeArea()

      // Elegant gradient overlay
      LinearGradient(
        colors: [
          Color.black.opacity(0.85),
          Color.black.opacity(0.4),
          Color.black.opacity(0.85)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      // Content with proper layout
      VStack(spacing: 40) {
        // Header with back button and title
        HStack {
          Button(action: { onBack() }) {
            HStack(spacing: 12) {
              Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
              Text(L("Back to Menu"))
                .font(.system(size: 18, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .buttonStyle(.plain)
          .focusable()
          .focused($focused, equals: .back)

          Spacer()

          VStack(spacing: 4) {
            Text(L("Controller Mapping"))
              .font(.system(size: 28, weight: .bold))
              .foregroundColor(.white)

            Text(L("Configure input devices"))
              .font(.system(size: 16, weight: .medium))
              .foregroundColor(.white.opacity(0.7))
          }

          Spacer()
        }

        // Player cards
        VStack(spacing: 20) {
          ForEach(1...4, id: \.self) { port in
            VStack(spacing: 16) {
              // Player info
              HStack(spacing: 20) {
                // Player icon
                ZStack {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                  Image(systemName: "person.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                }

                // Player info
                VStack(alignment: .leading, spacing: 4) {
                  Text("Player \(port)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                  let q2 = currentQualifiers[port] ?? ""
                  HStack(spacing: 8) {
                    Text(q2.isEmpty ? L("No controller assigned") : q2)
                      .font(.system(size: 14, weight: .medium))
                      .foregroundColor(.white.opacity(0.7))
                      .lineLimit(1)
                    if !q2.isEmpty && q2.localizedCaseInsensitiveContains("DSUClient") {
                      Text("DSU")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.35))
                        .clipShape(Capsule())
                    }
                  }
                }

                Spacer()
              }

              // Action buttons - separate row for better focus
              HStack(spacing: 20) {
                Button(action: {
                  NSLog("[CONTROLLER] Assign button pressed for port \(port)")
                  showPickerForPort = port
                }) {
                  HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text(L("Assign"))
                  }
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundColor(.white)
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 12)
                  .background(.blue.opacity(0.3))
                  .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focused($focused, equals: .assign(port))

                Button(action: {
                  NSLog("[CONTROLLER] Clear button pressed for port \(port)")
                  ControllerManager.shared.clearDefaultDevice(forGCPort: port)
                  reload()
                }) {
                  HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                    Text(L("Clear"))
                  }
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundColor(.white.opacity(0.8))
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 12)
                  .background(.white.opacity(0.2))
                  .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focused($focused, equals: .clear(port))
              }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
        }

        // Connected controllers section
        VStack(alignment: .leading, spacing: 16) {
          Text(L("Connected Controllers"))
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)

          if controllers.isEmpty {
            DolphinErrorView(
              title: L("No Controllers"),
              message: L("Connect external controllers to configure button mappings and enjoy the full iCube experience! 🎮")
            )
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          } else {
            VStack(spacing: 8) {
              ForEach(Array(controllers.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 16) {
                  ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                      .fill(.white.opacity(0.1))
                      .frame(width: 32, height: 32)

                    Image(systemName: "gamecontroller.fill")
                      .font(.system(size: 14, weight: .medium))
                      .foregroundColor(.white)
                  }

                  VStack(alignment: .leading, spacing: 2) {
                    Text(c.vendorName ?? c.productCategory)
                      .font(.system(size: 16, weight: .medium))
                      .foregroundColor(.white)

                    Text(c.productCategory)
                      .font(.system(size: 12, weight: .medium))
                      .foregroundColor(.white.opacity(0.6))
                  }

                  Spacer()

                  Text("P\(c.playerIndex.rawValue + 1)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              }
            }
          }
        }
      }
      .padding(60)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .zIndex(100)
      .defaultFocus($focused, .back)
      .focusSection()
      .onExitCommand { onBack() }
      .onAppear { reload() }
      .sheet(isPresented: Binding(get: { showPickerForPort != nil }, set: { if !$0 { showPickerForPort = nil } })) {
        if let port = showPickerForPort {
          ControllerPickerSheet(game: game, port: port) { selected in
            if let idx = selected, controllers.indices.contains(idx) {
              ControllerManager.shared.assign(controllers[idx], toGCPort: port)
              reload()
              NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Assigned to Player %d"), port)])
            }
            else if selected == -1 {
              ControllerManager.shared.assignTouchscreen(toGCPort: port)
              reload()
              NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Touchscreen assigned to Player %d"), port)])
            }
            showPickerForPort = nil
          }
        }
      }
    }
#endif
  }
}

#if DEBUG
import UIKit
private func makePreviewGame() -> TVGameItem {
  let clsName = "TVGameItem"
  if let cls = NSClassFromString(clsName) as? NSObject.Type {
    let obj = cls.init()
    let img = UIImage(systemName: "gamecontroller")?.withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage()
    obj.setValue("Preview Game", forKey: "title")
    obj.setValue("RMCP01", forKey: "gameID")
    obj.setValue(img, forKey: "coverImage")
    return unsafeBitCast(obj, to: TVGameItem.self)
  }
  fatalError("TVGameItem class not found for preview")
}

#Preview("iPhone Portrait") {
  ControllerMappingView(game: makePreviewGame(), onBack: {

  })
}

#Preview("iPhone Landscape") {
  ControllerMappingView(game: makePreviewGame(), onBack: {

  })
  .previewInterfaceOrientation(.landscapeLeft)
}
#endif
