// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// The in-game Audio Effects sheet: the same effect rows as the Audio settings screen, plus the plug-in
/// chain on AVAudioEngine. Reads Config, writes through `ConfigAudioSync`.
struct AudioEffectsSheet: View {
  @State private var state = ConfigAudioState()

  var body: some View {
    SettingsLeafScreen(model: ConfigAudioModelBuilder.effectsModel(state: state, apply: apply), title: L("Audio Effects"), sync: sync)
  }

  private func sync() { state = ConfigAudioSync.read() }
  private func apply(_ change: ConfigAudioChange) { ConfigAudioSync.apply(change, to: &state) }
}

// MARK: - Audio Unit plug-in chain (iOS, AVAudioEngine backend)
#if os(iOS)
import AVFoundation

struct FXChainEditor: View {
  @State private var effects: [FXItem] = []
  @State private var showingAU: UIViewController?
  @State private var showAddSheet = false
  @State private var availableCount: Int = 0

  struct FXItem: Identifiable, Equatable { let id = UUID(); let name: String; var bypass: Bool; let index: Int }

  var body: some View {
    Group {
      HStack {
        Button(action: { refresh() }) { Label(L("Refresh Effects"), systemImage: "arrow.clockwise") }
          .padding(.vertical, 4)
        Spacer()
        Button(action: { showAddSheet = true }) { Label(L("Add Effect"), systemImage: "plus").padding(.horizontal, 8).padding(.vertical, 6) }
          .contentShape(Rectangle())
      }
      .padding(.top, 4)
      if effects.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(isEngineActive() ? L("No active effects. Tap Add to insert an Audio Unit effect.") : L("Start a game on the AVAudioEngine backend to edit the chain. A saved chain is restored automatically."))
            .foregroundStyle(.secondary)
          Text(String(format: L("Installed: %d"), availableCount)).foregroundStyle(.secondary)
        }
      } else {
        ForEach(effects) { fx in
          HStack {
            Text(fx.name)
            Spacer()
            Toggle(L("Bypass"), isOn: Binding(get: { fx.bypass }, set: { v in setBypass(fx.index, v) }))
              .labelsHidden()
            Button { showUI(fx.index) } label: { Image(systemName: "slider.horizontal.3") }
              .buttonStyle(.borderless)
          }
        }
        .onMove(perform: move)
        .onDelete(perform: remove)
      }
    }
    .onAppear { refresh() }
    .sheet(isPresented: Binding(get: { showingAU != nil }, set: { if !$0 { showingAU = nil } }), onDismiss: {
      // The plug-in's own view edited its parameters; keep them with the chain.
      AudioFXBridge.saveEffectChain()
    }) {
      if let vc = showingAU { UIViewControllerWrapper(controller: vc) }
    }
    .sheet(isPresented: $showAddSheet) { AUAddSheet(onPick: { name in add(name) }).onDisappear { refresh() } }
  }

  private func isEngineActive() -> Bool { AudioFXBridge.isEngineActive() }

  private func refresh() {
    effects = AudioFXBridge.currentEffects().enumerated().map { (i, d) in
      FXItem(name: (d["name"] as? String) ?? "Effect", bypass: (d["bypass"] as? Bool) ?? false, index: i)
    }
    availableCount = AudioFXBridge.availableEffects().count
  }
  private func add(_ name: String) {
    if !AudioFXBridge.addEffect(withName: name) {
      NSLog("[FX] Add failed for %@ (engineActive=%d)", name, Int32(AudioFXBridge.isEngineActive() ? 1 : 0))
    }
    refresh()
  }
  private func remove(at offsets: IndexSet) {
    for o in offsets.sorted(by: >) { AudioFXBridge.removeEffect(at: UInt(o)) }
    refresh()
  }
  private func move(from src: IndexSet, to dst: Int) {
    guard let from = src.first else { return }
    let to = dst > from ? dst - 1 : dst
    AudioFXBridge.moveEffect(from: UInt(from), to: UInt(to))
    refresh()
  }
  private func setBypass(_ idx: Int, _ v: Bool) { AudioFXBridge.setEffectAt(UInt(idx), bypassed: v); refresh() }
  private func showUI(_ idx: Int) {
    AudioFXBridge.requestEffectViewController(at: UInt(idx)) { vc in
      if let vc = vc { showingAU = vc }
    }
  }

  private struct UIViewControllerWrapper: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }
  }

  private struct AUAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var rows: [FXRow] = []
    let onPick: (String) -> Void
    var body: some View {
      NavigationStack {
        VStack(spacing: 0) {
          HStack { TextField(L("Search Effects"), text: $search).textFieldStyle(.roundedBorder) }
            .padding()
          List(filtered()) { item in
            Button(action: { onPick(item.identifier); dismiss() }) {
              VStack(alignment: .leading) {
                Text(item.name)
                Text(item.identifier).font(.footnote).foregroundStyle(.secondary)
              }
            }
          }
        }
        .navigationTitle(L("Add Effect"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Close")) { dismiss() } } }
        .onAppear { reload() }
      }
    }
    private func reload() {
      rows = AudioFXBridge.availableEffects().compactMap { dict -> FXRow? in
        guard let name = dict["name"] as? String, let id = dict["identifier"] as? String else { return nil }
        return FXRow(name: name, identifier: id)
      }
    }
    private func filtered() -> [FXRow] {
      let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
      if q.isEmpty { return rows }
      return rows.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.identifier.localizedCaseInsensitiveContains(q) }
    }
    struct FXRow: Identifiable { let id = UUID(); let name: String; let identifier: String }
  }
}
#endif
