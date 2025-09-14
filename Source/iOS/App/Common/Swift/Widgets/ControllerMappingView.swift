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
    }
  }

  var body: some View {
#if os(iOS)
    NavigationStack {
      List {
        Section(header: Text(L("Players"))) {
          ForEach(1...4, id: \.self) { port in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L("Player %d"), port)).font(.headline)
                let q = currentQualifiers[port] ?? ""
                HStack(spacing: 6) {
                  Text(q.isEmpty ? L("No controller assigned") : q)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  if !q.isEmpty && q.localizedCaseInsensitiveContains("DSUClient") {
                    Text("DSU")
                      .font(.caption2)
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(Color(.dolphinTint).opacity(0.2), in: Capsule())
                  }
                }
              }
              Spacer()
              Button(L("Assign")) { showPickerForPort = port }
              Button(L("Clear")) { ControllerManager.shared.clearDefaultDevice(forGCPort: port); reload(); NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Cleared Player %d"), port)]) }
            }
          }
        }
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
      .navigationTitle(L("Controllers"))
      .toolbar(content: {
        ToolbarItem(placement: .navigationBarLeading) {
          Button(L("Back")) { onBack() }
        }
      })
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
