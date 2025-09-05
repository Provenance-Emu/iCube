// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import GameController

struct ControllerPickerSheet: View {
  let game: TVGameItem
  let port: Int
  let onDone: (Int?) -> Void // selected controller index or nil
  @Environment(\.dismiss) private var dismiss
  @State private var controllers: [GCController] = []
  @State private var selection: Int?
  @FocusState private var focused: FocusField?
  private enum FocusField: Hashable { case back, row(Int), done }

  var body: some View {
#if os(iOS)
    NavigationStack {
      List {
        Section(header: Text(L("Select Controller"))) {
          // Always provide a Touchscreen option at top
          Button(action: {
            selection = -1
            ControllerManager.shared.assignTouchscreen(toGCPort: port)
          }) {
            HStack(spacing: 12) {
              Image(systemName: "hand.tap").foregroundStyle(.secondary)
              Text(L("Touchscreen"))
              Spacer()
              if selection == -1 { Image(systemName: "checkmark").foregroundStyle(.blue) }
            }
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .focused($focused, equals: .row(-1))
          }

          if controllers.isEmpty {
            Text(L("No external controllers connected")).foregroundStyle(.secondary)
          } else {
            ForEach(Array(controllers.enumerated()), id: \.offset) { idx, c in
              Button(action: {
                selection = idx
                if controllers.indices.contains(idx) {
                  ControllerManager.shared.assign(controllers[idx], toGCPort: port)
                }
              }) {
                HStack(spacing: 12) {
                  Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(c.vendorName ?? c.productCategory)
                    Text(c.productCategory).font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer()
                  if selection == idx { Image(systemName: "checkmark").foregroundStyle(.blue) }
                }
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .focused($focused, equals: .row(idx))
              }
            }
          }
        }
      }
      .navigationTitle(L("Assign to Player") + " \(port)")
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) { Button(L("Cancel")) { onDone(nil); dismiss() } }
        ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { onDone(selection); dismiss() } }
      }
      .onAppear { controllers = GCController.controllers() }
    }
#else
    ZStack {
      // Background
      Image(uiImage: game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 25)
        .opacity(0.8)
        .ignoresSafeArea()

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

      // Content
      HStack(spacing: 80) {
        // Left column — game cover + info
        VStack(alignment: .leading, spacing: 16) {
          Image(uiImage: game.coverImage)
            .resizable()
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .frame(width: 180, height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)

          VStack(alignment: .leading, spacing: 6) {
            Text(L("Assign Controller"))
              .font(.system(size: 24, weight: .bold))
              .foregroundColor(.white)
            Text(String(format: L("Player") + " %d", port))
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(.white.opacity(0.7))
          }
        }
        .frame(width: 180)

        // Right column — list & actions
        VStack(alignment: .leading, spacing: 24) {
          // Header actions
          HStack(alignment: .center, spacing: 20) {
            Button(action: { onDone(nil); dismiss() }) {
              HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                  .font(.system(size: 16, weight: .semibold))
                Text(L("Back"))
                  .font(.system(size: 18, weight: .semibold))
              }
              .foregroundColor(.white.opacity(0.8))
              .padding(.horizontal, 20)
              .padding(.vertical, 12)
              .background(.white.opacity(0.1))
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .back)

            Spacer()

            Text(String(format: L("Assign to Player %d"), port))
              .font(.system(size: 28, weight: .bold))
              .foregroundColor(.white)

            Spacer()

            Button(action: { onDone(selection); dismiss() }) {
              HStack(spacing: 12) {
                Text(L("Done"))
                  .font(.system(size: 18, weight: .semibold))
              }
              .foregroundColor(.white)
              .padding(.horizontal, 20)
              .padding(.vertical, 12)
              .background(.blue.opacity(0.4))
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .done)
          }

          // Controller list
          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(Array(controllers.enumerated()), id: \.offset) { idx, c in
                Button(action: {
                  selection = idx
                  if controllers.indices.contains(idx) {
                    ControllerManager.shared.assign(controllers[idx], toGCPort: port)
                    NSLog("[CONTROLLER] Immediately assigned controller \(c.vendorName ?? c.productCategory) to port \(port)")
                  }
                }) {
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

                    if selection == idx {
                      Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    }
                  }
                  .padding(.horizontal, 16)
                  .padding(.vertical, 12)
                  .background(.white.opacity(0.05))
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .focused($focused, equals: .row(idx))
              }
            }
          }
          .frame(maxWidth: 820, maxHeight: 520)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: 900, alignment: .leading)
      }
      .padding(.horizontal, 60)
    }
#if os(tvOS)
    .focusSection()
    .onExitCommand { onDone(selection); dismiss() }
#endif
    .defaultFocus($focused, .back)
    .onAppear { controllers = GCController.controllers() }
#endif
  }
}
