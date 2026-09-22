// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation

// MARK: - Audio FX Chain Editor (iOS)
#if os(iOS)
import AVFoundation

struct FXChainEditor: View {
  @State private var effects: [FXItem] = []
  @State private var showingAU: UIViewController?
  @State private var showAddSheet = false
  @State private var searchText = ""
  @State private var availableCount: Int = 0
  @State private var showEnableEnginePrompt = false

  struct FXItem: Identifiable, Equatable { let id = UUID(); let name: String; var bypass: Bool; let index: Int }

  var body: some View {
    Group {
      HStack {
        Spacer()
        Button(action: {
          NSLog("[FX] Add button tapped")
          showAddSheet = true
        }) { Label(L("Add Effect"), systemImage: "plus").padding(.horizontal, 8).padding(.vertical, 6) }
          .contentShape(Rectangle())
          .allowsHitTesting(true)
      }
      .padding(.top, 4)
      HStack {
        Button(action: { refresh() }) { Label(L("Refresh Effects"), systemImage: "arrow.clockwise") }
          .padding(.vertical, 4)
        Spacer()
      }
      if effects.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(isEngineActive() ? L("No active effects. Tap Add to insert an AUv3 effect.") : L("Requires AVAudioEngine backend.")).foregroundStyle(.secondary)
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
    .sheet(isPresented: Binding(get: { showingAU != nil }, set: { if !$0 { showingAU = nil } })) {
      if let vc = showingAU { UIViewControllerWrapper(controller: vc) }
    }
    .sheet(isPresented: $showAddSheet) { AUAddSheet(onPick: { name in add(name) }).onDisappear { refresh() } }
    .alert(L("Enable AVAudioEngine?"), isPresented: $showEnableEnginePrompt) {
      Button(L("Enable")) {
        DOLConfigBridge.setAudioBackend("AVAudioEngine")
        waitUntilEngineActiveThen { showAddSheet = true; refresh() }
      }
      Button(L("Cancel"), role: .cancel) { }
    } message: {
      Text(L("Audio Effects require the AVAudioEngine backend."))
    }
  }

  private func isEngineActive() -> Bool { AudioFXBridge.isEngineActive() }
  private func waitUntilEngineActiveThen(_ action: @escaping () -> Void) {
    func poll(_ attempts: Int) {
      if AudioFXBridge.isEngineActive() {
        action()
      } else if attempts > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll(attempts - 1) }
      }
    }
    poll(20)
  }

  private func refresh() {
    let list = AudioFXBridge.currentEffects()
    effects = list.enumerated().map { (i, d) in FXItem(name: (d["name"] as? String) ?? "Effect", bypass: (d["bypass"] as? Bool) ?? false, index: i) }
    // Log available AUv3 effects from the system for diagnostics
    let available = AudioFXBridge.availableEffects()
    availableCount = available.count
    NSLog("[FX] Available AUv3 effects count: %d", Int32(available.count))
    for (idx, entry) in available.enumerated() {
      let e: [AnyHashable: Any] = entry
      if let nm = e["name"] as? String, let ident = e["identifier"] as? String {
        NSLog("[FX] #%d name=%@ ident=%@", Int32(idx), nm, ident)
      }
    }
  }
  private func add(_ name: String) {
    attemptAdd(name, attempts: 8)
  }
  private func attemptAdd(_ name: String, attempts: Int) {
    NSLog("[FX] Request add identifier=%@ attempts=%d", name, Int32(attempts))
    if AudioFXBridge.addEffect(withName: name) {
      NSLog("[FX] Add success for ident=%@", name)
      refresh()
      return
    }
    NSLog("[FX] Add failed for ident=%@ (engineActive=%d)", name, Int32(AudioFXBridge.isEngineActive() ? 1 : 0))
    if attempts > 0 && AudioFXBridge.isEngineActive() {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        attemptAdd(name, attempts: attempts - 1)
      }
    }
  }
  private func remove(at offsets: IndexSet) {
    for o in offsets { AudioFXBridge.removeEffect(at: UInt(o)) }
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
      if let vc = vc {
        showingAU = vc
      }
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
    @State private var effects: [[String: Any]] = []
    let onPick: (String) -> Void
    var body: some View {
      NavigationStack {
        VStack(spacing: 0) {
          HStack { TextField(L("Search Effects"), text: $search).textFieldStyle(.roundedBorder) }
            .padding()
          List(filtered()) { item in
            Button(action: { NSLog("[FX] (AddSheet) pick name=%@ ident=%@", item.name, item.identifier); onPick(item.identifier); dismiss() }) {
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
      let arr = AudioFXBridge.availableEffects()
      NSLog("[FX] (AddSheet) discovered AUv3 effects: %d", Int32(arr.count))
      effects = arr.compactMap { ($0 as? [String: AnyHashable])?.reduce(into: [String: Any]()) { acc, kv in acc[kv.key] = kv.value } }
      for (idx, d) in effects.enumerated() {
        let nm = (d["name"] as? String) ?? "?"
        let id = (d["identifier"] as? String) ?? "?"
        NSLog("[FX] (AddSheet) #%d name=%@ ident=%@", Int32(idx), nm, id)
      }
    }
    private func filtered() -> [FXRow] {
      let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
      let source = effects
        .compactMap { dict -> FXRow? in
          guard let name = dict["name"] as? String, let id = dict["identifier"] as? String else { return nil }
          return FXRow(name: name, identifier: id)
        }
      if q.isEmpty { return source }
      return source.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.identifier.localizedCaseInsensitiveContains(q) }
    }
    struct FXRow: Identifiable { let id = UUID(); let name: String; let identifier: String }
  }
}

struct CoreAudioDSPEditor: View {
  let embedded: Bool
  init(embedded: Bool = false) { self.embedded = embedded }
  @State private var delayEnabled = false
  @State private var delayMs = 200.0
  @State private var delayFeedback = 0.35
  @State private var crushEnabled = false
  @State private var crushBits = 16.0
  @State private var crushDown = 1.0
  @State private var eqEnabled = false
  @State private var low = 0.0
  @State private var mid = 0.0
  @State private var high = 0.0

  private func defaults(_ key: String) -> Any? { UserDefaults.standard.object(forKey: key) }
  private func setDefaults(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
  private func applyToEngine() {
    AudioFXBridge.setCADelayEnabled(delayEnabled)
    AudioFXBridge.setCADelayMs(Int(delayMs))
    AudioFXBridge.setCADelayFeedback(delayFeedback)
    AudioFXBridge.setCABitcrushEnabled(crushEnabled)
    AudioFXBridge.setCABitcrushBits(Int(crushBits))
    AudioFXBridge.setCABitcrushDownsample(Int(crushDown))
    AudioFXBridge.setCAEQEnabled(eqEnabled)
    AudioFXBridge.setCAEQLowGainDb(low)
    AudioFXBridge.setCAEQMidGainDb(mid)
    AudioFXBridge.setCAEQHighGainDb(high)
  }
  private func syncFromDefaultsOrEngine() {
    // Prefer stored defaults if present; else query engine
    if defaults("ca_fx_delay_enabled") != nil {
      delayEnabled = UserDefaults.standard.bool(forKey: "ca_fx_delay_enabled")
      let dms = UserDefaults.standard.double(forKey: "ca_fx_delay_ms"); if dms > 0 { delayMs = dms }
      let dfb = UserDefaults.standard.double(forKey: "ca_fx_delay_fb"); if dfb > 0 { delayFeedback = dfb }
      crushEnabled = UserDefaults.standard.bool(forKey: "ca_fx_crush_enabled")
      let cb = UserDefaults.standard.integer(forKey: "ca_fx_crush_bits"); if cb > 0 { crushBits = Double(cb) }
      let cd = UserDefaults.standard.integer(forKey: "ca_fx_crush_down"); if cd > 0 { crushDown = Double(cd) }
      eqEnabled = UserDefaults.standard.bool(forKey: "ca_fx_eq_enabled")
      low = UserDefaults.standard.double(forKey: "ca_fx_eq_low")
      mid = UserDefaults.standard.double(forKey: "ca_fx_eq_mid")
      high = UserDefaults.standard.double(forKey: "ca_fx_eq_high")
      applyToEngine()
    } else {
      syncFromEngine()
    }
  }

  private func syncFromEngine() {
    let d = AudioFXBridge.coreAudioDSPState()
    if let v = d["delayEnabled"] as? Bool { delayEnabled = v }
    if let v = d["delayMs"] as? NSNumber { delayMs = v.doubleValue }
    if let v = d["delayFeedback"] as? NSNumber { delayFeedback = v.doubleValue }
    if let v = d["crushEnabled"] as? Bool { crushEnabled = v }
    if let v = d["crushBits"] as? NSNumber { crushBits = v.doubleValue }
    if let v = d["crushDown"] as? NSNumber { crushDown = v.doubleValue }
    if let v = d["eqEnabled"] as? Bool { eqEnabled = v }
    if let v = d["low"] as? NSNumber { low = v.doubleValue }
    if let v = d["mid"] as? NSNumber { mid = v.doubleValue }
    if let v = d["high"] as? NSNumber { high = v.doubleValue }
  }

  @ViewBuilder private var sections: some View {
    Group {
      VStack(alignment: .leading, spacing: 8) {
        Text(L("Delay / Echo")).font(.headline)
        Toggle(L("Enabled"), isOn: Binding(get: { delayEnabled }, set: { v in delayEnabled = v; setDefaults("ca_fx_delay_enabled", v); AudioFXBridge.setCADelayEnabled(v) }))
        HStack { Text(L("Time")); Slider(value: $delayMs, in: 10...2000, step: 10).onChange(of: delayMs) { setDefaults("ca_fx_delay_ms", $0); AudioFXBridge.setCADelayMs(Int($0)) }; Text("\(Int(delayMs)) ms") }
        HStack { Text(L("Feedback")); Slider(value: $delayFeedback, in: 0...0.95, step: 0.01).onChange(of: delayFeedback) { setDefaults("ca_fx_delay_fb", $0); AudioFXBridge.setCADelayFeedback($0) }; Text(String(format: "%.2f", delayFeedback)) }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(L("Bitcrusher")).font(.headline)
        Toggle(L("Enabled"), isOn: Binding(get: { crushEnabled }, set: { v in crushEnabled = v; setDefaults("ca_fx_crush_enabled", v); AudioFXBridge.setCABitcrushEnabled(v) }))
        HStack { Text(L("Bits")); Slider(value: $crushBits, in: 4...16, step: 1).onChange(of: crushBits) { setDefaults("ca_fx_crush_bits", Int($0)); AudioFXBridge.setCABitcrushBits(Int($0)) }; Text("\(Int(crushBits))") }
        HStack { Text(L("Downsample")); Slider(value: $crushDown, in: 1...16, step: 1).onChange(of: crushDown) { setDefaults("ca_fx_crush_down", Int($0)); AudioFXBridge.setCABitcrushDownsample(Int($0)) }; Text("\(Int(crushDown))x") }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(L("3‑Band EQ")).font(.headline)
        Toggle(L("Enabled"), isOn: Binding(get: { eqEnabled }, set: { v in eqEnabled = v; setDefaults("ca_fx_eq_enabled", v); AudioFXBridge.setCAEQEnabled(v) }))
        HStack { Text(L("Low")); Slider(value: $low, in: -24...24, step: 0.5).onChange(of: low) { setDefaults("ca_fx_eq_low", $0); AudioFXBridge.setCAEQLowGainDb($0) }; Text(String(format: "%+.1f dB", low)) }
        HStack { Text(L("Mid")); Slider(value: $mid, in: -24...24, step: 0.5).onChange(of: mid) { setDefaults("ca_fx_eq_mid", $0); AudioFXBridge.setCAEQMidGainDb($0) }; Text(String(format: "%+.1f dB", mid)) }
        HStack { Text(L("High")); Slider(value: $high, in: -24...24, step: 0.5).onChange(of: high) { setDefaults("ca_fx_eq_high", $0); AudioFXBridge.setCAEQHighGainDb($0) }; Text(String(format: "%+.1f dB", high)) }
      }
    }
  }

  var body: some View {
    if embedded {
      VStack(alignment: .leading, spacing: 16) { sections }
        .onAppear { syncFromDefaultsOrEngine() }
    } else {
      List { Section { sections } }
        .navigationTitle(L("Audio Effects"))
        .onAppear { syncFromDefaultsOrEngine() }
    }
  }
}
#endif
