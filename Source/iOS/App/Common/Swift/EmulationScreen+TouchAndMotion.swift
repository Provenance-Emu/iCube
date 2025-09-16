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
  private func overlayIsWii() -> Bool {
    let currentIsWii = TVEmulationBridge.isRunning() ? TVEmulationBridge.isCurrentSystemWii() : isWiiSystem
    switch touchVM.mode {
    case .auto: return currentIsWii
    case .gamecube: return false
    case .wii: return true
    }
  }
  
  @State private var isTouchControlsActive = false
  @State private var userOverrideTouchControls = false
  
  private func toggleTopBar() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
      showTopBar.toggle()
    }
    if showTopBar { scheduleAutoHide() }
  }
  
  private func hideTopBar(now: Bool = false) {
    if now {
      withAnimation { showTopBar = false }
      hideBarWorkItem?.cancel()
      hideBarWorkItem = nil
    } else {
      withAnimation { showTopBar = false }
    }
  }
  
  private func scheduleAutoHide() {
    hideBarWorkItem?.cancel()
    let token = UUID()
    autoHideToken = token
    let work = DispatchWorkItem {
      if token == autoHideToken && !hasTopBarInteraction {
        withAnimation { self.showTopBar = false }
      }
    }
    hideBarWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
  }
  
  private func scheduleARPoll() {
    arPollTask?.cancel()
    arPollTask = Task { @MainActor in
      for _ in 0..<20 {
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
  private func applyCoreAudioDSPDefaults() {
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
  private func setupEnhancedMotionControls() {
    // Enable enhanced motion controls by default for touchscreen Wii games
    UserDefaults.standard.set(true, forKey: "motion_enhanced_shake_detection")
    UserDefaults.standard.set(true, forKey: "motion_enable_ir_cursor")
    
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
  private func restartMotionSystemForSettingsChange() {
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
  private func inferIsWii(from item: TVGameItem) -> Bool {
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
    
  private struct TouchPadsContainer: UIViewRepresentable {
    let forceVisible: Bool
    let isWii: Bool
    func makeUIView(context: Context) -> UIView {
      let host = UIView()
      host.backgroundColor = .clear
      host.isUserInteractionEnabled = true
      
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
          NSLog("[TOUCH] Added GC pad with alpha=%.2f", v.alpha)
        } else {
          NSLog("[TOUCH] Failed to load TCGameCubePad nib")
        }
      }
      return host
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
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
      let classic = DOLWiimoteBridge.isClassicActive(forWiimote: 0)
      let sideways = DOLWiimoteBridge.isSideways(forWiimote: 0)
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
      view.port = 4
      let modeRaw = DOLConfigBridge.mainTouchPadIRMode()
      if let mode = TCWiiTouchIRMode(rawValue: Int(modeRaw)) { view.setTouchIRMode(mode) }
      return view
    }
    
    private func configureWiiView(_ view: UIView, in container: UIView) {
      if let wiiPad = findTCWiiPad(in: view) {
        let motion = TCDeviceMotion.shared
        motion.setMotionEnabled(true)
        motion.setPort(4)
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
        applyPortRecursively(4, to: view)
      }
    }
    
    private func loadPad(named name: String) -> UIView? {
      let candidateBundles: [Bundle] = [Bundle(for: TCWiiPad.self), Bundle.main]
      var candidateNames: [String] = [name]
      if name == "TCWiiPad" {
        candidateNames.append(contentsOf: ["TCWiiPad_iOS", "TCWiiPad~iphone", "TCWiiPad~ipad", "WiiPad", "WiiPadView"]) }
      if name == "TCGameCubePad" {
        candidateNames.append(contentsOf: ["TCGameCubePadView", "TCGamePad", "GameCubePad"]) }
      for b in candidateBundles {
        for n in candidateNames {
          if let _ = b.path(forResource: n, ofType: "nib") {
            let nib = UINib(nibName: n, bundle: b)
            let objects = nib.instantiate(withOwner: nil, options: nil)
            if let v = objects.first as? UIView { NSLog("[TOUCH] Loaded nib %@ from %@", n, String(describing: b.bundlePath)); return v }
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
