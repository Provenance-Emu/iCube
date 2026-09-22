// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/DebugServerManager.swift
//
// Lifecycle owner for the debug/benchmark HTTP server. Self-gating:
//   - DEBUG builds: `start()` always starts the server (developer convenience).
//   - Release builds: `start()` starts ONLY when the user has flipped the
//     "Perf Test Bench (HTTP)" toggle, persisted in UserDefaults under
//     `ICubeBenchServerEnabled` (default OFF). With the toggle off — the default
//     for every shipping install — nothing binds, so there is no always-on local
//     HTTP server to flag in App Store review.
//
// App Store safety: the server is loopback-only (NativeWebServer binds 127.0.0.1;
// do not change that — it's the review-safety property), default-off, and gated
// behind a user-visible toggle. Reaching it requires an explicit USB
// `iproxy 8723 8723` forward from a Mac. Opt-in developer feature, not a service.
//
// ObjC visibility: this is `@objc`/NSObject so EmulationCoordinator.mm (ObjC++)
// can call `[DebugServerManager.shared start]` through the generated
// iCube-Swift.h.

import Foundation
import Security
import PVWebServer
#if canImport(UIKit)
import UIKit
#endif

/// Reference-counted wrapper around `UIApplication.isIdleTimerDisabled`.
///
/// Two independent features need the device awake, and the flag is a single global: a game on
/// screen, and the debug/bench HTTP server. Setting the flag directly meant whoever finished
/// last re-enabled sleep for the other — exiting a game to the library re-armed auto-lock even
/// though a remote test session was still driving the app over `iproxy`, and the phone then
/// locked, iOS suspended the app, and every later request failed with a connection reset.
/// Game Mode does not inhibit auto-lock; only this flag does.
/// Swift-only on purpose: `release` is a reserved Objective-C selector, so this type is never
/// exposed to ObjC. ObjC++ callers should go through `DebugServerManager` instead.
///
/// Deliberately NOT `@MainActor`: the emulation reason is dropped from `deinit`, which is a
/// nonisolated context. The reason set is guarded by a lock and the UIKit flag is only ever
/// touched on the main thread.
enum KeepAwake {
  enum Reason: Hashable {
    case emulation
    case debugServer
  }

  private static let lock = NSLock()
  private static var reasons: Set<Reason> = []

  /// Keep the device awake for `reason` until the matching `release`.
  static func acquire(_ reason: Reason) {
    update { $0.insert(reason) }
  }

  /// Drop `reason`; the device may sleep again once no reason remains.
  static func release(_ reason: Reason) {
    update { $0.remove(reason) }
  }

  private static func update(_ body: (inout Set<Reason>) -> Void) {
    lock.lock()
    body(&reasons)
    let disabled = !reasons.isEmpty
    let count = reasons.count
    lock.unlock()

    if Thread.isMainThread {
      apply(disabled, count)
    } else {
      DispatchQueue.main.async { apply(disabled, count) }
    }
  }

  private static func apply(_ disabled: Bool, _ count: Int) {
    #if canImport(UIKit)
    guard UIApplication.shared.isIdleTimerDisabled != disabled else { return }
    UIApplication.shared.isIdleTimerDisabled = disabled
    NSLog("[KeepAwake] idle timer disabled = \(disabled) (reasons held: \(count))")
    #endif
  }
}

@objc(DebugServerManager)
@MainActor
final class DebugServerManager: NSObject {
  @objc(sharedManager) static let shared = DebugServerManager()

  /// Set by POST /api/debug/boot (default true) and consumed once by EmulationScreen: skip the
  /// "Waiting for JIT" prompt and go straight to the no-JIT path, exactly as tapping
  /// "Use No JIT Mode (Slow)" would. Main-thread only. Never set by any user-facing path.
  static var skipJITPromptOnce = false

  private(set) var isRunning = false
  private var routesRegistered = false
  private(set) var serverURL: String = ""

  /// Port for the loopback debug API. Reach it over USB with:
  ///   iproxy 8723 8723
  static let port: UInt16 = 8723

  /// True when the server is running because the user explicitly asked for it,
  /// rather than because this is a DEBUG build where it is always on. An explicit
  /// opt-in earns LAN reachability: usbmux TCP forwarding to an ordinary app port
  /// does not reach a Release (AppStore) build on iOS 26, so a loopback-only bench
  /// there is a toggle that silently does nothing.
  private static var isExplicitOptIn: Bool {
    #if DEBUG
    return false
    #else
    return UserDefaults.standard.bool(forKey: DebugServerManager.enabledDefaultsKey)
    #endif
  }

  /// UserDefaults key holding the LAN bench token.
  static let tokenDefaultsKey = "ICubeBenchServerToken"

  /// The token a LAN client must present. Generated once and persisted, so
  /// tooling configured with it keeps working across launches; rotating it is a
  /// matter of clearing this key. 256 bits from the system CSPRNG.
  ///
  /// Only meaningful when the bench is LAN-reachable — loopback callers (USB via
  /// iproxy, and anything on-device) are exempt.
  static var lanToken: String {
    let d = UserDefaults.standard
    if let existing = d.string(forKey: tokenDefaultsKey), !existing.isEmpty { return existing }
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    d.set(token, forKey: tokenDefaultsKey)
    return token
  }

  private let server = NativeWebServer(
    port: DebugServerManager.port,
    allowsNonLoopbackClients: DebugServerManager.isExplicitOptIn,
    requiredToken: DebugServerManager.isExplicitOptIn ? DebugServerManager.lanToken : nil)
  private let routes = DebugAPIRoutes()

  override private init() { super.init() }

  /// UserDefaults key for the Release-build opt-in. Default OFF.
  static let enabledDefaultsKey = "ICubeBenchServerEnabled"

  /// Whether the server is permitted to run. Always true in DEBUG; in Release
  /// only when the user has opted in via the "Perf Test Bench (HTTP)" toggle.
  private var isEnabled: Bool {
    #if DEBUG
    return true
    #else
    return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    #endif
  }

  /// Start the server. No-op unless permitted (see `isEnabled`).
  @objc func start() {
    guard isEnabled else { return }
    guard !isRunning else { return }
    if !routesRegistered {
      routesRegistered = true
      server.webSocketHandler = { path, socket in
        guard path == "/ws/events" else { return false }
        DebugEventBus.shared.attach(socket)
        return true
      }
      DebugEventBus.shared.startProducers()
      routes.registerRoutes(on: server)
      // Listener died after it was up (seen after ~100 loopback connections on iOS 26): mark
      // stopped and bring it back, otherwise every later request is reset with no log line.
      server.onListenerLost = { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.isRunning = false
          try? await Task.sleep(for: .seconds(1))
          self.start()
        }
      }
    }
    Task {
      do {
        try await server.start()
        self.isRunning = true
        // A remote session drives the app with no touches, so the phone would otherwise
        // auto-lock and iOS would suspend the app out from under the test.
        KeepAwake.acquire(.debugServer)
        self.serverURL = self.server.serverURL?.absoluteString ?? "http://127.0.0.1:\(Self.port)/"
        if self.server.allowsNonLoopbackClients {
          // Say the LAN address, because that is the one that will actually work:
          // this path exists precisely because USB forwarding does not reach here.
          let lan = PVWebServer.shared.ipAddress.map { "http://\($0):\(Self.port)/" } ?? "(no LAN address yet)"
          NSLog("[DebugServer] listening on \(self.serverURL) and \(lan) "
                + "(LAN reachable: Perf Test Bench is on in a non-DEBUG build; "
                + "LAN requests need Authorization: Bearer <token> — see Settings > Debug)")
        } else {
          NSLog("[DebugServer] listening on \(self.serverURL) (loopback only; iproxy to reach over USB)")
        }
      } catch {
        self.isRunning = false
        NSLog("[DebugServer] failed to start: \(error.localizedDescription)")
      }
    }
  }

  @objc func stop() {
    guard isRunning else { return }
    DebugEventBus.shared.stopProducers()
    server.stop()
    isRunning = false
    KeepAwake.release(.debugServer)
    serverURL = ""
  }
}
