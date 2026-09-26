// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if os(iOS)

extension EmulationScreen {
  /// ViewModel for on-screen controller visibility and mode
  final class TouchControlsViewModel: ObservableObject {
    enum Mode { case auto, gamecube, wii }
    @Published var isVisible: Bool = true
    @Published var mode: Mode = .auto
  }

  /// Resolve whether the overlay should show Wii or GC pads based on VM mode and current system
  func overlayIsWii() -> Bool {
    let currentIsWii = TVEmulationBridge.isRunning() ? TVEmulationBridge.isCurrentSystemWii() : isWiiSystem
    switch touchVM.mode {
    case .auto: return currentIsWii
    case .gamecube: return false
    case .wii: return true
    }
  }

  func toggleTopBar() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
      showTopBar.toggle()
    }
    if showTopBar { scheduleAutoHide() }
  }

  func hideTopBar(now: Bool = false) {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
      showTopBar = false
    }
    if now {
      hideBarWorkItem?.cancel()
      hideBarWorkItem = nil
    }
  }

  func scheduleAutoHide() {
    hideBarWorkItem?.cancel()
    let token = UUID()
    autoHideToken = token
    let work = DispatchWorkItem {
      if token == autoHideToken && !hasTopBarInteraction {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
          self.showTopBar = false
        }
      }
    }
    hideBarWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
  }

  func scheduleARPoll() {
    arPollTask?.cancel()
    arPollTask = Task { @MainActor in
      for _ in 0 ..< 20 {
        let ar = CGFloat(TVEmulationBridge.currentDrawAspectRatio())
        if ar.isFinite && ar > 0.4 && ar < 3.5 {
          stableAR = ar
          TVEmulationBridge.resizeSurfaceNow()
          break
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
      }
    }
  }

  /// Apply saved CoreAudio DSP defaults to the engine when a game starts
  func applyCoreAudioDSPDefaults() {
    func has(_ k: String) -> Bool { UserDefaults.standard.object(forKey: k) != nil }
    if has("ca_fx_delay_enabled") { AudioFXBridge.setCADelayEnabled(UserDefaults.standard.bool(forKey: "ca_fx_delay_enabled")) }
    if has("ca_fx_delay_ms") { AudioFXBridge.setCADelayMs(Int(UserDefaults.standard.double(forKey: "ca_fx_delay_ms"))) }
    if has("ca_fx_delay_fb") { AudioFXBridge.setCADelayFeedback(UserDefaults.standard.double(forKey: "ca_fx_delay_fb")) }
    if has("ca_fx_crush_enabled") { AudioFXBridge.setCABitcrushEnabled(UserDefaults.standard.bool(forKey: "ca_fx_crush_enabled")) }
    if has("ca_fx_crush_bits") { AudioFXBridge.setCABitcrushBits(UserDefaults.standard.integer(forKey: "ca_fx_crush_bits")) }
    if has("ca_fx_crush_down") { AudioFXBridge.setCABitcrushDownsample(UserDefaults.standard.integer(forKey: "ca_fx_crush_down")) }
    if has("ca_fx_eq_enabled") { AudioFXBridge.setCAEQEnabled(UserDefaults.standard.bool(forKey: "ca_fx_eq_enabled")) }
    if has("ca_fx_eq_low") { AudioFXBridge.setCAEQLowGainDb(UserDefaults.standard.double(forKey: "ca_fx_eq_low")) }
    if has("ca_fx_eq_mid") { AudioFXBridge.setCAEQMidGainDb(UserDefaults.standard.double(forKey: "ca_fx_eq_mid")) }
    if has("ca_fx_eq_high") { AudioFXBridge.setCAEQHighGainDb(UserDefaults.standard.double(forKey: "ca_fx_eq_high")) }
  }

  /// Setup enhanced motion controls optimized for touchscreen usage
  func setupEnhancedMotionControls() {
    // Enable enhanced motion controls by default for touchscreen Wii games
    UserDefaults.standard.set(true, forKey: "motion_enhanced_shake_detection")

    // Set sensible defaults for axis inversion (can be adjusted by user)
    if UserDefaults.standard.object(forKey: "motion_invert_roll") == nil {
      UserDefaults.standard.set(false, forKey: "motion_invert_roll")
    }
    if UserDefaults.standard.object(forKey: "motion_invert_pitch") == nil {
      UserDefaults.standard.set(false, forKey: "motion_invert_pitch")
    }

    NSLog("[MOTION] Enhanced motion controls enabled for Wii game - roll/pitch → IR cursor, improved shake detection")

    // CRITICAL: Restart motion system to pick up the newly enabled settings
    // Small delay to ensure UserDefaults are synchronized
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      NotificationCenter.default.post(
        name: Notification.Name("DOLMotionSettingsChanged"),
        object: nil
      )
      NSLog("[MOTION] Triggered motion system restart after enabling enhanced controls")
    }
  }

  /// Restart motion system when settings change during gameplay
  /// Points the device-motion feed (gyro/accel/shake, gyro-mode IR) at the Wii Remote slot the
  /// touch overlay is bound to. Replaces three hardcoded `setPort(4)` calls.
  func syncMotionPortToTouchscreen() {
    TCDeviceMotion.shared.setPort(ControllerManager.shared.touchscreenControllerId(isWii: true))
  }

  func restartMotionSystemForSettingsChange() {
    NSLog("[MOTION] Motion settings changed during gameplay - restarting motion system")

    // If we're using TCDeviceMotion, restart it to pick up new settings
    if isTouchControlsActive {
      let currentMotionEnabled = TCDeviceMotion.shared.motionEnabled
      TCDeviceMotion.shared.setMotionEnabled(false)

      // Small delay to ensure clean restart
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        TCDeviceMotion.shared.setMotionEnabled(currentMotionEnabled)
        NSLog("[MOTION] TCDeviceMotion restarted with new settings - cursor reset to center")
      }
    }

    // The PVDolphinCore instance will handle its own motion system restart
    // and cursor reset via the notification observer
  }

  /// Heuristic: infer Wii vs GC from game metadata (gameID prefix, file extension)
  func inferIsWii(from item: TVGameItem) -> Bool {
    let id = item.gameID.uppercased()
    if let first = id.first {
      if first == "R" || first == "S" { return true }
      if first == "G" { return false }
    }
    if let url = URL(string: item.filePath) {
      let ext = url.pathExtension.lowercased()
      if ext == "wbfs" || ext == "wad" { return true }
      if ext == "gcm" { return false }
    }
    return isWiiSystem
  }

  struct TouchPadsContainer: UIViewRepresentable {
    let forceVisible: Bool
    let isWii: Bool
    /// Current touch-IR mode (TCWiiTouchIRMode raw value). Passed as state so a change updates
    /// the live pad in place instead of tearing the overlay down (which dropped held buttons and
    /// re-ran every pad's lifecycle hooks).
    var irMode: Int = Int(DOLConfigBridge.mainTouchPadIRMode())

    /// Phase 2 of the programmatic touch overlay (docs/superpowers/specs/
    /// 2026-09-24-programmatic-touch-overlay-design.md), gated off by default. When on, this
    /// container mounts a `UIHostingController`-hosted `TouchOverlayView` instead of the xib pad;
    /// every other path in this file (opacity, IR-mode passthrough, port resolution) is untouched.
    private static var useProgrammaticOverlay: Bool {
      UserDefaults.standard.bool(forKey: "touch_overlay_programmatic")
    }

    /// Holds the hosting controller across `updateUIView` calls so a live setting change (pad
    /// kind, opacity, IR mode) updates its `rootView` in place instead of tearing down and
    /// rebuilding the whole SwiftUI tree.
    final class Coordinator {
      var hosting: UIHostingController<TouchOverlayView>?
      /// The hosting view's teardown-safe wrapper (task item 2, DSU pass) — see
      /// `TouchOverlayHostContainer`'s doc comment for why the hosting view can't guarantee its
      /// own release-on-teardown via SwiftUI alone.
      var hostContainer: TouchOverlayHostContainer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Mirrors `makeWiiPadView()`'s selection exactly (slot -> classic/sideways), so the
    /// programmatic overlay picks the same variant the xib path would have shown. `nil` when
    /// neither a Wii nor a GameCube pad should be visible right now (e.g. an external controller
    /// is connected and `forceVisible` is false).
    private func programmaticPadKind() -> TouchOverlayPadKind? {
      if shouldShowWiiPad() {
        let slot = ControllerManager.shared.touchscreenSlot(system: .wii) ?? 0
        return .wii(classicActive: DOLWiimoteBridge.isClassicActive(forWiimote: slot),
                    sideways: DOLWiimoteBridge.isSideways(forWiimote: slot))
      } else if shouldShowGameCubePad() {
        return .gameCube
      }
      return nil
    }

    /// Mount or update the programmatic overlay in `container`. Returns without doing anything
    /// when neither pad should currently show, leaving `container` empty exactly like the legacy
    /// path does.
    private func syncProgrammaticOverlay(in container: UIView, context: Context) {
      guard let kind = programmaticPadKind() else {
        teardownProgrammaticOverlay(context: context)
        return
      }
      let isWiiKind = kind != .gameCube
      let deviceId = ControllerManager.shared.touchscreenControllerId(isWii: isWiiKind)
      if isWiiKind {
        // The IMU pointer's port must follow the touchscreen device id (§6.3) even though phase 2
        // doesn't drive IR itself yet — gyro-mode IR keeps working unchanged (design §2 non-goal).
        TCDeviceMotion.shared.setPort(deviceId)
      }
      // Kept current on every sync (task item 2's DSU pass), not just at creation: the overlay can
      // switch device ids in place (e.g. a controller connects mid-session) without ever
      // disappearing, so a LATER teardown must clear whichever id was actually live.
      context.coordinator.hostContainer?.deviceId = deviceId
      if let hosting = context.coordinator.hosting, let hostContainer = context.coordinator.hostContainer {
        hosting.rootView = TouchOverlayView(padKind: kind, deviceId: deviceId, irMode: irMode)
        if hostContainer.superview !== container {
          hostContainer.frame = container.bounds
          container.addSubview(hostContainer)
        }
      } else {
        let hosting = UIHostingController(rootView: TouchOverlayView(padKind: kind, deviceId: deviceId, irMode: irMode))
        hosting.view.backgroundColor = .clear
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let hostContainer = TouchOverlayHostContainer(frame: container.bounds)
        hostContainer.deviceId = deviceId
        hostContainer.backgroundColor = .clear
        hostContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.view.frame = hostContainer.bounds
        hostContainer.addSubview(hosting.view)
        container.addSubview(hostContainer)
        context.coordinator.hosting = hosting
        context.coordinator.hostContainer = hostContainer
      }
      // TouchOverlayView applies the opacity setting per group itself; the container stays opaque.
      container.alpha = 1.0
    }

    /// Removes the hosting view via its teardown-safe wrapper (task item 2's DSU pass) and drops
    /// both coordinator references, so the NEXT sync (if any) creates a fresh hosting controller
    /// rather than reusing a torn-down one.
    private func teardownProgrammaticOverlay(context: Context) {
      context.coordinator.hostContainer?.removeFromSuperview()
      context.coordinator.hostContainer = nil
      context.coordinator.hosting = nil
    }

    func makeUIView(context: Context) -> UIView {
      let host = UIView()
      host.backgroundColor = .clear
      host.isUserInteractionEnabled = true

      if Self.useProgrammaticOverlay {
        syncProgrammaticOverlay(in: host, context: context)
        return host
      }

      // Decide which pad to show based on current system/controller config
      if shouldShowWiiPad() {
        let wiiView = makeWiiPadView()
        wiiView.frame = host.bounds
        wiiView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(wiiView)
        configureWiiView(wiiView, in: host)
      } else if shouldShowGameCubePad() {
        if let v = loadPad(named: "TCGameCubePad") {
          v.frame = host.bounds
          v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
          v.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
          host.addSubview(v)
          applyPort(ControllerManager.shared.touchscreenControllerId(isWii: false), to: v)
          NSLog("[TOUCH] Added GC pad with alpha=%.2f", v.alpha)
        } else {
          NSLog("[TOUCH] Failed to load TCGameCubePad nib")
        }
      }
      return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
      // If the flag flipped (or the hosting view was torn down) since this container was last
      // mounted, do a full rebuild instead of letting the legacy branch below mistake the
      // programmatic overlay's UIHostingController view for a plain GC pad subview (or vice
      // versa) — they're both just "a subview" to the legacy logic's `uiView.subviews.first`.
      let mountedIsHosting = context.coordinator.hostContainer?.superview === uiView
      if Self.useProgrammaticOverlay != mountedIsHosting {
        // Going FROM the programmatic overlay TO the legacy path: tear down through the
        // wrapper (task item 2's DSU pass) so whatever the overlay was mid-holding gets released,
        // exactly like `TCView`'s own teardown does for the path this is switching TO.
        if mountedIsHosting { teardownProgrammaticOverlay(context: context) }
        uiView.subviews.forEach { $0.removeFromSuperview() }
      }

      if Self.useProgrammaticOverlay {
        syncProgrammaticOverlay(in: uiView, context: context)
        return
      }

      // In-place update when the right kind of pad is already mounted: mode, opacity and the
      // pointer rect. A full rebuild only happens when the pad kind changes (or on a new
      // `touchPadsRefreshToken`, which SwiftUI turns into a fresh makeUIView).
      let wantWii = shouldShowWiiPad()
      let wantGC = !wantWii && shouldShowGameCubePad()
      let mountedWii = uiView.subviews.first { findTCWiiPad(in: $0) != nil }
      if wantWii, let host = mountedWii, let wiiPad = findTCWiiPad(in: host) {
        if let mode = TCWiiTouchIRMode(rawValue: irMode), wiiPad.mode != mode {
          wiiPad.setTouchIRMode(mode)
        }
        let wantPort = ControllerManager.shared.touchscreenControllerId(isWii: true)
        if wiiPad.port != wantPort {
          wiiPad.port = wantPort
          TCDeviceMotion.shared.setPort(wantPort)
        }
        let ar = CGFloat(TVEmulationBridge.currentDrawAspectRatio())
        let vr = TVEmulationBridge.currentVideoContentRect()
        let inPad: CGRect = {
          if vr == .zero { return wiiPad.bounds }
          if let main = EmulationCoordinator.shared().mainDisplayView() {
            return wiiPad.convert(vr, from: main)
          }
          return wiiPad.bounds
        }()
        wiiPad.recalculatePointerValues(new_rect: inPad, game_aspect: ar)
        host.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
        return
      }
      if wantGC, mountedWii == nil, let gc = uiView.subviews.first {
        gc.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
        let wantPort = ControllerManager.shared.touchscreenControllerId(isWii: false)
        if let tc = gc as? TCView, tc.port != wantPort { tc.port = wantPort }
        return
      }
      uiView.subviews.forEach { $0.removeFromSuperview() }
      if shouldShowWiiPad() {
        let v = makeWiiPadView()
        v.frame = uiView.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        uiView.addSubview(v)
        configureWiiView(v, in: uiView)
      } else if shouldShowGameCubePad() {
        if let v = loadPad(named: "TCGameCubePad") {
          v.frame = uiView.bounds
          v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
          v.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
          uiView.addSubview(v)
          applyPort(ControllerManager.shared.touchscreenControllerId(isWii: false), to: v)
        } else {
          NSLog("[TOUCH] Failed to load TCGameCubePad nib (update)")
        }
      } else {
        for sub in uiView.subviews {
          if let wiiPad = findTCWiiPad(in: sub) {
            let ar = CGFloat(TVEmulationBridge.currentDrawAspectRatio())
            let vr = TVEmulationBridge.currentVideoContentRect()
            let inPad: CGRect = {
              if vr == .zero { return wiiPad.bounds }
              if let main = EmulationCoordinator.shared().mainDisplayView() {
                return wiiPad.convert(vr, from: main)
              }
              return wiiPad.bounds
            }()
            wiiPad.recalculatePointerValues(new_rect: inPad, game_aspect: ar)
            wiiPad.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
          } else {
            sub.alpha = max(0.2, CGFloat(DOLConfigBridge.mainTouchPadOpacity()))
          }
        }
      }
    }

    // MARK: - Decision Logic via ControllerManager

    private func shouldShowGameCubePad() -> Bool {
      let hasExternal = !GCController.controllers().isEmpty
      if hasExternal && !forceVisible { return false }
      let show = ControllerManager.shared.shouldShowGCPad(wiiSystem: isWii, wiiPadAttached: true, gcPadAttached: true)
      NSLog("[TOUCH] GameCube pad decision: isWiiState=\(isWii) shouldShow=\(show)")
      return show
    }

    private func shouldShowWiiPad() -> Bool {
      let hasExternal = !GCController.controllers().isEmpty
      if hasExternal && !forceVisible { return false }
      let show = ControllerManager.shared.shouldShowWiiOverlay(wiiSystem: isWii, wiiPadAttached: true, gcPadAttached: true)
      NSLog("[TOUCH] Wii pad decision: isWiiState=\(isWii) shouldShow=\(show)")
      return show
    }

    // MARK: - Wii Subclass selection & configuration

    private func makeWiiPadView() -> UIView {
      // Layout (classic / sideways) and the input port both follow the Wii Remote slot the
      // touchscreen is actually bound to, not slot 1.
      let slot = ControllerManager.shared.touchscreenSlot(system: .wii) ?? 0
      let classic = DOLWiimoteBridge.isClassicActive(forWiimote: slot)
      let sideways = DOLWiimoteBridge.isSideways(forWiimote: slot)
      let view: TCWiiPad
      if classic {
        view = TCClassicWiiPad()
        NSLog("[TOUCH] Using TCClassicWiiPad")
      } else if sideways {
        view = TCSidewaysWiiPad()
        NSLog("[TOUCH] Using TCSidewaysWiiPad")
      } else {
        view = TCWiiPad()
        NSLog("[TOUCH] Using TCWiiPad")
      }
      view.port = ControllerManager.shared.touchscreenControllerId(isWii: true)
      let modeRaw = DOLConfigBridge.mainTouchPadIRMode()
      if let mode = TCWiiTouchIRMode(rawValue: Int(modeRaw)) { view.setTouchIRMode(mode) }
      return view
    }

    private func configureWiiView(_ view: UIView, in container: UIView) {
      if let wiiPad = findTCWiiPad(in: view) {
        let motion = TCDeviceMotion.shared
        motion.setMotionEnabled(true)
        motion.setPort(wiiPad.port)
        motion.statusBarOrientationChanged()
        wiiPad.resetPointer()
        let ar = CGFloat(TVEmulationBridge.currentDrawAspectRatio())
        let vr = TVEmulationBridge.currentVideoContentRect()
        let inPad: CGRect = {
          if vr == .zero { return wiiPad.bounds }
          if let main = EmulationCoordinator.shared().mainDisplayView() {
            return wiiPad.convert(vr, from: main)
          }
          return wiiPad.bounds
        }()
        wiiPad.recalculatePointerValues(new_rect: inPad, game_aspect: ar)
      } else {
        applyPort(ControllerManager.shared.touchscreenControllerId(isWii: true), to: view)
      }
    }

    /// A `TCView` propagates `port` to its nib subtree itself; anything else gets the walk.
    private func applyPort(_ port: Int, to view: UIView) {
      if let tc = view as? TCView { tc.port = port } else { applyPortRecursively(port, to: view) }
    }

    private func loadPad(named name: String) -> UIView? {
      let candidateBundles: [Bundle] = [Bundle(for: TCWiiPad.self), Bundle.main]
      var candidateNames: [String] = [name]
      if name == "TCWiiPad" {
        candidateNames.append(contentsOf: ["TCWiiPad_iOS", "TCWiiPad~iphone", "TCWiiPad~ipad", "WiiPad", "WiiPadView"])
      }
      if name == "TCGameCubePad" {
        candidateNames.append(contentsOf: ["TCGameCubePadView", "TCGamePad", "GameCubePad"])
      }
      for b in candidateBundles {
        for n in candidateNames {
          if let _ = b.path(forResource: n, ofType: "nib") {
            let nib = UINib(nibName: n, bundle: b)
            let objects = nib.instantiate(withOwner: nil, options: nil)
            if let v = objects.first as? UIView { NSLog("[TOUCH] Loaded nib %@ from %@", n, String(describing: b.bundlePath))
              return v
            }
          }
        }
      }
      NSLog("[TOUCH] Could not find nib for %@ in candidate bundles", name)
      return nil
    }

    private func viewContainsTCWiiPad(_ v: UIView) -> Bool { return findTCWiiPad(in: v) != nil }
    private func findTCWiiPad(in v: UIView) -> TCWiiPad? {
      if let w = v as? TCWiiPad { return w }
      for sub in v.subviews { if let found = findTCWiiPad(in: sub) { return found } }
      return nil
    }

    private func applyPortRecursively(_ port: Int, to view: UIView) {
      if let b = view as? TCButton { b.port = port }
      else if let j = view as? TCJoystick { j.port = port }
      else if let d = view as? TCDirectionalPad { d.port = port }
      for sub in view.subviews { applyPortRecursively(port, to: sub) }
      NSLog("[TOUCH] Applied port=\(port) recursively to subtree: \(type(of: view))")
    }
  }
}

#endif // iOS
