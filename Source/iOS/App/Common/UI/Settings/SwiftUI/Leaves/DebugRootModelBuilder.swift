// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVHelp
import SwiftUI

/// The bench token, with the caption that explains it. A custom row renders only its view, so the view carries the title, the
/// value and the caption; the token is selectable on iOS so it can be copied into tooling.
struct DebugBenchTokenRow: View {
  let token: String
  let caption: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L("Bench Token"))
      Text(token)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
#if os(iOS)
        .textSelection(.enabled)
#endif
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Pure: snapshot in, changes out (it cannot write, and it reads no singleton). Descriptions are the captions the hand-built
/// screen showed; the read-only status rows have a one-sentence description of their own.
enum DebugRootModelBuilder {
  typealias Apply = (DebugRootChange) -> Void

  static func make(state: DebugRootState, apply: @escaping Apply) -> MenuModel {
    var sections = [cpuMemory(state, apply)]
    if state.isIOS { sections.append(recording(state, apply)) }
    sections += [environment(state, apply), diagnostics(state, apply), rendering(state, apply), logging(state, apply), artwork(state, apply)]
    return MenuModel(sections: sections.filter { !$0.items.isEmpty })
  }

  private static func status(_ id: String, _ title: String, _ description: String, badge: String? = nil) -> MenuItem {
    SettingsRow.action(id, title, description, enabled: false, badge: badge, run: {})
  }

  private static func cpuMemory(_ state: DebugRootState, _ apply: @escaping Apply) -> MenuSection {
    MenuSection(id: "cpu-memory", header: L("CPU / Memory"), items: [
      SettingsRow.toggle("fastmem", L("Fastmem"), state.fastmem,
                         L("Fast memory-access path for the CPU emulator. A large speedup where supported; disabled if the device can't provide it."),
                         enabled: state.hydrated.fastmemAvailable, set: { apply(.fastmem($0)) }),
    ])
  }

  private static func recording(_ state: DebugRootState, _ apply: @escaping Apply) -> MenuSection {
    MenuSection(id: "recording", header: L("Recording"), items: [
      SettingsRow.toggle("instant-replay", L("Enable ReplayKit Instant Replay"), state.instantReplay,
                         L("Continuously buffers gameplay for instant replay. May reduce performance on older devices."),
                         set: { apply(.instantReplay($0)) }),
    ])
  }

  private static func environment(_ state: DebugRootState, _ apply: @escaping Apply) -> MenuSection {
    let h = state.hydrated
    var items = [
      status("user-folder", L("User Folder"),
             h.userFolder.isEmpty
               ? L("Where iCube keeps its settings, saves and game data.")
               : String(format: L("Where iCube keeps its settings, saves and game data: %@"), h.userFolder)),
      status("jit-status", L("JIT"), L("Whether the emulator can generate native code on this device right now."),
             badge: h.jitAcquired ? L("Acquired") : L("Not Acquired")),
      status("debugger-status", L("Debugger"), L("Whether a debugger is attached; iOS 26 needs one to switch JIT on."),
             badge: h.debuggerAttached ? L("Attached") : L("Not Attached")),
    ]
    if h.deviceHasTxm {
      items.append(status("txm-region", L("TXM JIT Region"), L("Whether this device's JIT memory region has been authorized for iCube."),
                          badge: h.txmAuthorized ? L("Authorized") : L("Not Authorized")))
    }
    items.append(status("jit-error", L("JIT Error"),
                        String(format: L("The last error from trying to acquire JIT: %@"), h.jitError.isEmpty ? L("(none)") : h.jitError)))
    // Recovery that does NOT depend on StikDebug being installed. The cookie is set before the brk and cleared on return,
    // so anything that kills the app in between (a non-broker debugger, but also jetsam while the region faults in) leaves it set.
    if h.txmHandshakeBlocked {
      items.append(SettingsRow.action("retry-jit-authorization", L("Retry JIT Authorization"),
                                      L("A previous attempt to authorize the JIT region never finished, so iCube is declining to retry on its own. This re-arms it for the next time you open a game with a debugger attached."),
                                      run: { apply(.retryJitAuthorization) }))
    }
    if state.showsStikDebugEnable {
      items.append(SettingsRow.action("enable-jit-stikdebug", L("Enable JIT via StikDebug"),
                                      L("Hands iCube's bundled JIT script to StikDebug and enables JIT for this app. StikDebug will relaunch iCube; reopen a game afterward to run with JIT."),
                                      run: { apply(.enableJitViaStikDebug) }))
    }
    if state.showsStikDebugHelp {
      items.append(SettingsRow.caption("stikdebug-help",
                                       L("StikDebug didn't attach?") + " "
                                         + L("In StikDebug: run \"Reset Developer Disk Image\", confirm its VPN is connected, and re-import your pairing file if it was removed. Those three cover most failures. On a Mac, Xcode or lldb works instead.")))
    }
    // In-app (not Safari): works on tvOS and offline, since the guide is bundled (see WikiContentProvider).
    items.append(SettingsRow.destination("jit-guide", L("JIT Setup Guide"),
                                         L("What JIT does, why iOS 26 needs a debugger to switch it on, and what to expect without it."),
                                         view: AnyView(WikiPageView(path: WikiConstants.Paths.jitGuide, title: L("JIT Setup Guide")).padBackNavigation())))
    items.append(status("fastmem-available", L("Fastmem"), L("Whether this device can provide the fast memory-access path."),
                        badge: h.fastmemAvailable ? L("Available") : L("Not Available")))
    return MenuSection(id: "environment", header: L("Environment"), items: items)
  }

  private static func diagnostics(_ state: DebugRootState, _ apply: @escaping Apply) -> MenuSection {
    var items = [
      status("launch-times", L("Launch Times"), L("How many times iCube has been launched."), badge: "\(state.launchTimes)"),
      SettingsRow.action("reset-launch-times", L("Reset Launch Times"), L("Sets the launch counter back to zero."),
                         run: { apply(.resetLaunchTimes) }),
    ]
    #if DEBUG && canImport(CoreMotion)
    items.append(SettingsRow.destination("motion-debug", L("Motion Debug"), L("Live gyro and accelerometer readings, for checking motion input."),
                                         icon: "sensor.tag.radiowaves.forward", view: AnyView(MotionDebugView().padBackNavigation())))
    #endif
    #if os(iOS) && DEBUG
    items.append(SettingsRow.destination("gallery", L("Gallery"), L("Every on-screen controller layout, for checking how each one looks."),
                                         view: AnyView(TouchOverlayGalleryView().padBackNavigation())))
    #endif
    // Stall instrumentation is engine-agnostic (VideoCommon), so it lives in this always-visible Diagnostics group.
    items.append(SettingsRow.toggle("stall-metrics", L("Stall Metrics"), state.stallMetrics,
                                    L("Measures where the CPU thread waits during emulation. Adds the data to Copy State as a STALL REPORT section. <0.5% overhead."),
                                    set: { apply(.stallMetrics($0)) }))
    items.append(SettingsRow.toggle("perf-bench", L("Perf Test Bench (HTTP)"), state.benchEnabled,
                                    L("Runs an HTTP server on port 8723 for automated perf testing. Over USB: `iproxy 8723 8723`. On a non-debug build it is also reachable over Wi-Fi, because USB forwarding does not reach App Store builds — those requests need the token below. Takes effect at the next game boot."),
                                    set: { apply(.perfBench($0)) }))
    // The token is the whole reason LAN exposure is safe to offer: this API can write settings, boot games and load save
    // states. Shown so it can be copied into tooling; loopback/USB callers never need it.
    if !state.benchToken.isEmpty {
      let caption = L("Optional: headless tooling can send `Authorization: Bearer <token>` to skip the on-device prompt. Requests over USB or from the device itself never need it.")
      items.append(SettingsRow.custom("bench-token", L("Bench Token"), AnyView(DebugBenchTokenRow(token: state.benchToken, caption: caption)), caption))
    }
    // A mis-tapped "Always Allow" would otherwise be permanent short of a reinstall, so it has to be undoable from here.
    let clients = state.hydrated.approvedClients
    if !clients.isEmpty {
      items.append(SettingsRow.destructive("forget-approved-devices", String(format: L("Forget %1$ld Approved Device(s)"), clients.count),
                                           String(format: L("Currently allowed without prompting: %1$@"), clients.joined(separator: ", ")),
                                           run: { apply(.forgetApprovedDevices) }))
    }
    return MenuSection(id: "diagnostics", header: L("Diagnostics"), items: items)
  }

  private static func rendering(_ state: DebugRootState, _ apply: @escaping Apply) -> MenuSection {
    MenuSection(id: "rendering", header: L("Rendering"), items: [
      SettingsRow.toggle("wireframe", L("Wireframe"), state.wireframe,
                         L("Renders geometry as wireframe instead of filled polygons. Diagnostic only — for inspecting how a scene is built."),
                         set: { apply(.wireframe($0)) }),
    ])
  }

  private static func logging(_ state: DebugRootState, _ apply: @escaping Apply) -> MenuSection {
    MenuSection(id: "logging", header: L("Logging"), items: [
      SettingsRow.toggle("console-logging", L("Enable Console Logging"), state.loggingEnabled,
                         L("Writes core log messages to the device console. For diagnostics; leave off for normal use."),
                         set: { apply(.consoleLogging($0)) }),
      SettingsRow.cycle("logging-verbosity", L("Verbosity"), DebugRootState.verbosityLevels.map { ("\($0)", $0) }, state.loggingVerbosity,
                        L("How much detail the log captures (1 = errors only, 5 = everything)."),
                        set: { apply(.loggingVerbosity($0)) }),
      SettingsRow.toggle("input-debug", L("Input Event Debug"), state.inputDebug,
                         L("Logs every controller/touch input event. Noisy; for input troubleshooting only."),
                         set: { apply(.inputDebug($0)) }),
    ])
  }

  private static func artwork(_ state: DebugRootState, _ apply: @escaping Apply) -> MenuSection {
    MenuSection(id: "screenshots-artwork", header: L("Screenshots / Artwork"), items: [
      SettingsRow.toggle("template-covers", L("Use Template Covers (Disable Artwork)"), state.disableArtwork,
                         L("Hides downloaded box art and shows platform templates (GameCube/Wii) instead. Handy for App Store screenshots."),
                         set: { apply(.templateCovers($0)) }),
    ])
  }
}
