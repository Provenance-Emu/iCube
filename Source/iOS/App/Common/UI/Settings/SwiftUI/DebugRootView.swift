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

struct DebugRootView: View {
  @State private var fastmem: Bool = false
  @State private var userFolder: String = ""
  @State private var jitAcquired: Bool = false
  @State private var jitError: String = ""
  @State private var debuggerAttached: Bool = false
  @State private var txmAuthorized: Bool = false
  @State private var txmHandshakeBlocked: Bool = false
  @State private var fastmemAvailable: Bool = false
  @State private var launchTimes: Int = 0
  @State private var loggingEnabled: Bool = false
  /// Read, never written here: DebugServerManager mints it on first LAN start.
  /// Empty on a DEBUG build, where the bench is loopback-only and needs no token.
  private var benchToken: String {
    UserDefaults.standard.string(forKey: "ICubeBenchServerToken") ?? ""
  }
  @State private var loggingVerbosity: Int = 4
  @State private var inputDebug: Bool = false
  @State private var instantReplay: Bool = false
  @State private var hydrated: Bool = false
  @AppStorage("library_disable_artwork") private var disableArtwork: Bool = false

  var body: some View {
    List {
      Section(header: Text(L("CPU / Memory"))) {
        settingsCaption(
          Toggle(L("Fastmem"), isOn: $fastmem)
            .onChange(of: fastmem) { DOLConfigBridge.setMainFastmem($0) }
            .disabled(!fastmemAvailable),
          L("Fast memory-access path for the CPU emulator. A large speedup where supported; disabled if the device can't provide it."))
      }

      // The master "Connect MFi Controllers" toggle was relocated to the unified
      // ControllerSetupView's Global section (Settings ▸ Controllers).

      Section(header: Text(L("Recording"))) {
#if os(iOS)
        settingsCaption(
          Toggle(L("Enable ReplayKit Instant Replay"), isOn: $instantReplay)
            .onChange(of: instantReplay) { UserDefaults.standard.set($0, forKey: "replaykit_instant_replay_enabled") },
          L("Continuously buffers gameplay for instant replay. May reduce performance on older devices."))
#endif
      }

      Section(header: Text(L("Environment"))) {
        HStack { Text(L("User Folder")); Spacer(); Text(userFolder).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        HStack { Text(L("JIT")); Spacer(); Text(jitAcquired ? L("Acquired") : L("Not Acquired")).foregroundStyle(.secondary) }
        HStack { Text(L("Debugger")); Spacer(); Text(debuggerAttached ? L("Attached") : L("Not Attached")).foregroundStyle(.secondary) }
        if JitManager.shared().deviceHasTxm {
          HStack { Text(L("TXM JIT Region")); Spacer(); Text(txmAuthorized ? L("Authorized") : L("Not Authorized")).foregroundStyle(.secondary) }
        }
        HStack { Text(L("JIT Error")); Spacer(); Text(jitError.isEmpty ? "(none)" : jitError).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        /// Recovery that does NOT depend on StikDebug being installed. The cookie is set
        /// before the brk and cleared on return, so anything that kills the app in between
        /// (a non-broker debugger, but also jetsam while the region faults in) leaves it set.
        /// Without this, a developer on Xcode or a user with no StikDebug has no way back.
        if txmHandshakeBlocked {
          settingsCaption(
            Button(L("Retry JIT Authorization")) {
              JitManager.shared().clearTXMHandshakeCookie()
              txmHandshakeBlocked = false
            },
            L("A previous attempt to authorize the JIT region never finished, so iCube is declining to retry on its own. This re-arms it for the next time you open a game with a debugger attached."))
        }
        #if os(iOS)
        /// iOS 26 TXM hand-off: ship iCube's own broker script to StikDebug inline so JIT can be
        /// authorized without the user pre-assigning a script. Shown only when actionable: JIT
        /// not acquired, or acquired on a TXM device with no broker attached and no region yet.
        if !jitAcquired || (JitManager.shared().deviceHasTxm && !txmAuthorized && !debuggerAttached),
           JitManager.shared().jitSupported, JitManager.shared().deviceHasTxm, StikDebugLauncher.isStikDebugInstalled {
          settingsCaption(
            Button(L("Enable JIT via StikDebug")) { StikDebugLauncher.enableJIT() },
            L("Hands iCube's bundled JIT script to StikDebug and enables JIT for this app. StikDebug will relaunch iCube; reopen a game afterward to run with JIT."))

          /// Shown only after StikDebug has been asked and did not attach. Every current iOS 26
          /// JIT app rides the same StikDebug protocol -- there is no alternative broker to offer
          /// instead -- and the live failures cluster in StikDebug's transport, not the handshake.
          /// These are the three checks that resolve most of them.
          if !debuggerAttached && !txmAuthorized {
            settingsCaption(
              Text(L("StikDebug didn't attach?")).font(.footnote).foregroundStyle(.secondary),
              L("In StikDebug: run \"Reset Developer Disk Image\", confirm its VPN is connected, and re-import your pairing file if it was removed. Those three cover most failures. On a Mac, Xcode or lldb works instead."))
          }
        }
        #endif

        // In-app (not Safari): works on tvOS and offline, since the guide is bundled — see
        // WikiContentProvider. Was previously an external-only link to icube-emu.com/guide/jit/.
        settingsNavCaption(
          destination: WikiPageView(path: WikiConstants.Paths.jitGuide, title: L("JIT Setup Guide")),
          L("What JIT does, why iOS 26 needs a debugger to switch it on, and what to expect without it.")
        ) {
          Text(L("JIT Setup Guide"))
        }

        HStack { Text(L("Fastmem")); Spacer(); Text(fastmemAvailable ? L("Available") : L("Not Available")).foregroundStyle(.secondary) }
      }

      Section(header: Text(L("Diagnostics"))) {
        HStack { Text(L("Launch Times")); Spacer(); Text("\(launchTimes)").foregroundStyle(.secondary) }
        Button(L("Reset Launch Times")) { launchTimes = 0; UserDefaults.standard.set(0, forKey: "launch_times") }
        #if canImport(CoreMotion)
        NavigationLink(destination: MotionDebugView()) {
          Label(L("Motion Debug"), systemImage: "sensor.tag.radiowaves.forward")
        }
        #endif // canImport(CoreMotion)
        // Stall instrumentation is engine-agnostic (VideoCommon), so it lives in this
        // always-visible Diagnostics group rather than the CIR-gated one. Config-backed
        // (MAIN_STALL_METRICS), so bind read-through to the bridge — no @State — to avoid
        // the write-through desync that bit the gated toggles.
        settingsCaption(
          Toggle(L("Stall Metrics"), isOn: Binding(
            get: { DOLConfigBridge.stallMetrics() },
            set: { DOLConfigBridge.setStallMetrics($0) })),
          L("Measures where the CPU thread waits during emulation. Adds the data to Copy State as a STALL REPORT section. <0.5% overhead."))
        // Perf test bench: UserDefaults-backed (DebugServerManager reads it at boot).
        settingsCaption(
          Toggle(L("Perf Test Bench (HTTP)"), isOn: Binding(
            get: { UserDefaults.standard.bool(forKey: "ICubeBenchServerEnabled") },
            set: { UserDefaults.standard.set($0, forKey: "ICubeBenchServerEnabled") })),
          L("Runs an HTTP server on port 8723 for automated perf testing. Over USB: `iproxy 8723 8723`. On a non-debug build it is also reachable over Wi-Fi, because USB forwarding does not reach App Store builds — those requests need the token below. Takes effect at the next game boot."))
        // The token is the whole reason LAN exposure is safe to offer: this API can
        // write settings, boot games and load save states. Shown so it can be copied
        // into tooling; loopback/USB callers never need it.
        if !benchToken.isEmpty {
          settingsCaption(
            VStack(alignment: .leading, spacing: 4) {
              Text(L("Bench Token"))
              Text(benchToken)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
#if os(iOS)
                .textSelection(.enabled)
#endif
            },
            L("Send as `Authorization: Bearer <token>` on Wi-Fi requests. Requests over USB or from the device itself do not need it."))
        }
      }

      Section(header: Text(L("Rendering"))) {
        // Config-backed (GFX_ENABLE_WIREFRAME). Read-through Binding (no @State) mirrors
        // Stall Metrics above to avoid write-through desync.
        settingsCaption(
          Toggle(L("Wireframe"), isOn: Binding(
            get: { DOLConfigBridge.gfxWireframe() },
            set: { DOLConfigBridge.setGfxWireframe($0) })),
          L("Renders geometry as wireframe instead of filled polygons. Diagnostic only — for inspecting how a scene is built."))
      }

      Section(header: Text(L("Logging"))) {
        settingsCaption(
          Toggle(L("Enable Console Logging"), isOn: $loggingEnabled)
            .onChange(of: loggingEnabled) { UserDefaults.standard.set($0, forKey: "logger_console_enabled") },
          L("Writes core log messages to the device console. For diagnostics; leave off for normal use."))
        settingsCaption(
          HStack {
            Text(L("Verbosity"))
            Spacer()
            Button("\(loggingVerbosity)") {
              var v = UserDefaults.standard.integer(forKey: "logger_console_verbosity"); if v <= 0 { v = 4 }
              v = (v % 5) + 1
              UserDefaults.standard.set(v, forKey: "logger_console_verbosity")
              loggingVerbosity = v
            }
            .buttonStyle(.bordered)
          },
          L("How much detail the log captures (1 = errors only, 5 = everything)."))
        settingsCaption(
          Toggle(L("Input Event Debug"), isOn: $inputDebug)
            .onChange(of: inputDebug) { UserDefaults.standard.set($0, forKey: "input_debug") },
          L("Logs every controller/touch input event. Noisy; for input troubleshooting only."))
      }

      Section(header: Text(L("Screenshots / Artwork"))) {
        settingsCaption(
          Toggle(L("Use Template Covers (Disable Artwork)"), isOn: $disableArtwork),
          L("Hides downloaded box art and shows platform templates (GameCube/Wii) instead. Handy for App Store screenshots."))
      }
    }
    .navigationTitle(L("Debug"))
    .task {
      if !hydrated {
        hydrated = true
        await withTaskGroup(of: Void.self) { group in
          group.addTask { await syncDebugAsync() }
        }
      }
    }
  }

  private func syncDebug() {
    // Kept for potential call-sites; now delegates to async variant
    Task { await syncDebugAsync() }
  }

  private func syncDebugChunk1() async {
    await MainActor.run {
      fastmem = DOLConfigBridge.mainFastmem()
      fastmemAvailable = (FastmemManager.shared().fastmemAvailable)
      launchTimes = UserDefaults.standard.integer(forKey: "launch_times")
    }
  }

  private func syncDebugChunk2() async {
    let folder = UserFolderUtil.getUserFolder()
    await MainActor.run { userFolder = folder }
  }

  private func syncDebugChunk3() async {
    let manager = JitManager.shared()
    manager.recheckIfJitIsAcquired()
    let acquired = manager.acquiredJit
    let error = manager.acquisitionError ?? ""
    let attached = manager.debuggerAttached
    let authorized = manager.txmAuthorized
    let blocked = manager.txmHandshakeBlocked
    await MainActor.run {
      jitAcquired = acquired
      jitError = error
      debuggerAttached = attached
      txmAuthorized = authorized
      txmHandshakeBlocked = blocked
    }
  }

  private func syncDebugChunk4() async {
    let logEnabled = UserDefaults.standard.bool(forKey: "logger_console_enabled")
    var v = UserDefaults.standard.integer(forKey: "logger_console_verbosity"); if v <= 0 { v = 4 }
    let inputDbg = UserDefaults.standard.bool(forKey: "input_debug")
    let ir = UserDefaults.standard.bool(forKey: "replaykit_instant_replay_enabled")
    await MainActor.run {
      loggingEnabled = logEnabled
      loggingVerbosity = v
      inputDebug = inputDbg
      instantReplay = ir
    }
  }

  private func syncDebugAsync() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await syncDebugChunk1() }
      group.addTask { await syncDebugChunk2() }
      group.addTask { await syncDebugChunk3() }
      group.addTask { await syncDebugChunk4() }
    }
  }
}

/// Animation style for the About sheet logo — chosen at random on each open.
