// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/DebugServerManager.swift
//
// Lifecycle owner for the debug/benchmark HTTP server. DEBUG-gated: in a
// release build `start()` is a no-op and nothing binds, so there is no
// always-on local HTTP server to flag in App Store review.
//
// ObjC visibility: this is `@objc`/NSObject so EmulationCoordinator.mm (ObjC++)
// can call `[DebugServerManager.shared start]` through the generated
// iCube-Swift.h. The whole class is compiled in release too, but `start()` is
// `#if DEBUG` internally, so the release build links an empty method and binds
// nothing.

import Foundation

@objc(DebugServerManager)
@MainActor
final class DebugServerManager: NSObject {
  @objc(sharedManager) static let shared = DebugServerManager()

  private(set) var isRunning = false
  private(set) var serverURL: String = ""

  /// Port for the loopback debug API. Reach it over USB with:
  ///   iproxy 8723 8723
  static let port: UInt16 = 8723

  private let server = NativeWebServer(port: DebugServerManager.port)
  private let routes = DebugAPIRoutes()

  override private init() { super.init() }

  /// Start the server. No-op unless this is a DEBUG build.
  @objc func start() {
    #if DEBUG
    guard !isRunning else { return }
    routes.registerRoutes(on: server)
    Task {
      do {
        try await server.start()
        self.isRunning = true
        self.serverURL = self.server.serverURL?.absoluteString ?? "http://127.0.0.1:\(Self.port)/"
        NSLog("[DebugServer] listening on \(self.serverURL) (loopback only; iproxy to reach over USB)")
      } catch {
        self.isRunning = false
        NSLog("[DebugServer] failed to start: \(error.localizedDescription)")
      }
    }
    #else
    // Release builds: intentionally do nothing.
    #endif
  }

  @objc func stop() {
    #if DEBUG
    server.stop()
    isRunning = false
    serverURL = ""
    #endif
  }
}
