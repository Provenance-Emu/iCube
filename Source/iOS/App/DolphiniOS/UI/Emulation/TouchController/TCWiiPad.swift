// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

class TCWiiPad: TCView, UIGestureRecognizerDelegate {
  var mode: TCWiiTouchIRMode = .none

  var gameCenterX: CGFloat = 0
  var gameCenterY: CGFloat = 0
  var gameWidthHalfInv: CGFloat = 0
  var gameHeightHalfInv: CGFloat = 0
  /// Tracked game-content rect within this view for precise mapping
  private var gameRectLocal: CGRect = .zero

  var touchStartPoint: CGPoint = CGPoint(x: 0, y: 0)
  var oldX: CGFloat = 0
  var oldY: CGFloat = 0

  required init?(coder: NSCoder) {
    super.init(coder: coder)

    // Register our "long press" gesture recognizer
    let pressHandler = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
    pressHandler.minimumPressDuration = 0
    #if os(iOS)
    pressHandler.numberOfTouchesRequired = 1
    #endif
    pressHandler.cancelsTouchesInView = false
    pressHandler.delegate = self
    self.real_view!.addGestureRecognizer(pressHandler)

    // Three-finger hold to center IR
    let centerHold = UILongPressGestureRecognizer(target: self, action: #selector(handleThreeFingerHold))
    centerHold.minimumPressDuration = 3.0
    #if os(iOS)
    centerHold.numberOfTouchesRequired = 3
    #endif
    centerHold.cancelsTouchesInView = false
    centerHold.delegate = self
    self.real_view!.addGestureRecognizer(centerHold)

    debugLog("[TOUCH] TCWiiPad initialized; gesture recognizer installed")
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    let pressHandler = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
    pressHandler.minimumPressDuration = 0
    #if os(iOS)
    pressHandler.numberOfTouchesRequired = 1
    #endif
    pressHandler.cancelsTouchesInView = false
    pressHandler.delegate = self
    self.real_view!.addGestureRecognizer(pressHandler)

    // Three-finger hold to center IR
    let centerHold = UILongPressGestureRecognizer(target: self, action: #selector(handleThreeFingerHold))
    centerHold.minimumPressDuration = 3.0
    #if os(iOS)
    centerHold.numberOfTouchesRequired = 3
    #endif
    centerHold.cancelsTouchesInView = false
    centerHold.delegate = self
    self.real_view!.addGestureRecognizer(centerHold)

    debugLog("[TOUCH] TCWiiPad init(frame:) gesture recognizer installed")
  }

  @objc func recalculatePointerValues(new_rect: CGRect, game_aspect: CGFloat) {
    gameCenterX = new_rect.midX
    gameCenterY = new_rect.midY

    var gameWidth = new_rect.width
    var gameHeight = new_rect.height

    // Adjusting for device's black bars.
    let surfaceAR = gameWidth / gameHeight
    let gameAR = game_aspect
    if gameAR <= surfaceAR {
        // Black bars on left/right
        gameWidth = gameHeight * gameAR
    } else {
        // Black bars on top/bottom
        gameHeight = gameWidth / gameAR
    }

    gameWidthHalfInv = 1 / (gameWidth * 0.5)
    gameHeightHalfInv = 1 / (gameHeight * 0.5)

    // Track the exact content rect inside this view for precise mapping
    let gx = gameCenterX - (gameWidth * 0.5)
    let gy = gameCenterY - (gameHeight * 0.5)
    gameRectLocal = CGRect(x: gx, y: gy, width: gameWidth, height: gameHeight)

    debugLog(String(format: "[TOUCH] Wii recalc: rect=(%.1fx%.1f) center=(%.1f,%.1f) inv=(%.4f,%.4f) AR=%.3f content=(%.1f,%.1f,%.1f,%.1f)",
                    new_rect.width, new_rect.height, gameCenterX, gameCenterY, gameWidthHalfInv, gameHeightHalfInv, game_aspect,
                    gameRectLocal.origin.x, gameRectLocal.origin.y, gameRectLocal.size.width, gameRectLocal.size.height))
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if let rv = self.real_view {
      return touch.view?.isDescendant(of: rv) ?? true
    }

    return true
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    #if os(iOS)
    if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer {
      return true
    }
    #endif

    return false
  }

  private func clamp(_ v: CGFloat) -> CGFloat { max(-1.0, min(1.0, v)) }

  /// Map a touch point in local coords into normalized IR space using the tracked game rect
  private func normalizedFromPoint(_ p: CGPoint) -> (x: CGFloat, y: CGFloat) {
    var rect = gameRectLocal
    if rect.isEmpty {
      // Fallback to full bounds if we haven't been told yet; assume centered with aspect already accounted for by inv factors
      rect = self.bounds
    }
    let cx = rect.midX
    let cy = rect.midY
    let halfW = max(1.0, rect.width * 0.5)
    let halfH = max(1.0, rect.height * 0.5)

    let nx = clamp((p.x - cx) / halfW)
    let ny = clamp((p.y - cy) / halfH)
    return (nx, ny)
  }

  @objc private func handleThreeFingerHold(gesture: UILongPressGestureRecognizer) {
    if gesture.state == .began {
      debugLog("[TOUCH] Three-finger hold detected; centering IR")
      centerPointer()
    }
  }

  @objc func handleLongPress(gesture: UILongPressGestureRecognizer) {
    if mode == .none {
      return
    }

    let point = gesture.location(in: self)

    if gesture.state == .began {
      touchStartPoint = point
    #if os(iOS)
      TVEmulationBridge.setWiiIMUPointEnabled(false)
    #endif
      debugLog(String(format: "[TOUCH] Wii IR begin at (%.3f, %.3f) port=%d mode=%d", point.x, point.y, port, mode.rawValue))
      return
    }

    var x: CGFloat, y: CGFloat

    if mode == .follow {
      // Directly map screen position to IR normalized coords using content rect
      let n = normalizedFromPoint(point)
      x = n.x
      y = n.y
    } else {
      // Drag delta mapping using content rect scaling for correct sensitivity
      let rect = gameRectLocal.isEmpty ? self.bounds : gameRectLocal
      let halfW = max(1.0, rect.width * 0.5)
      let halfH = max(1.0, rect.height * 0.5)
      let dx = (point.x - touchStartPoint.x) / halfW
      let dy = (point.y - touchStartPoint.y) / halfH
      x = oldX + dx
      y = oldY + dy
      x = clamp(x); y = clamp(y)
    }

    sendIR(x: x, y: y)

    if gesture.state == .ended && mode == .drag {
      oldX = x
      oldY = y
      debugLog(String(format: "[TOUCH] Wii IR end; persisted (x=%.4f,y=%.4f)", x, y))
    }
  }

  @objc func setTouchIRMode(_ newMode: TCWiiTouchIRMode) {
    self.mode = newMode
    #if os(iOS)
    let useIMU = (newMode == .none)
    TVEmulationBridge.setWiiIMUPointEnabled(useIMU)
    #endif
    // Center between mode changes for predictable handoff
    centerPointer()
    debugLog("[TOUCH] Wii IR mode set to \(newMode.rawValue)")
  }

  @objc func resetPointer() {
    touchStartPoint = CGPoint(x: 0, y: 0)
    oldX = 0
    oldY = 0
    debugLog("[TOUCH] Wii IR pointer reset")
  }

  private func centerPointer() {
    resetPointer()
    sendIR(x: 0, y: 0)
  }

  private func sendIR(x: CGFloat, y: CGFloat) {
    #if os(iOS)
    let axisStartIdx = TCButtonType.wiiInfrared
    for (i, axis) in [y, y, x, x].enumerated() {
      let idx = axisStartIdx.rawValue + i + 1
      TCManagerInterface.setAxisValueFor(idx, controller: self.port, value: Float(axis))
      debugLog(String(format: "[TOUCH] Wii IR axis send idx=%d val=%.4f port=%d", idx, axis, port))
    }
    #endif
  }

  private func debugLog(_ message: String) {
    if UserDefaults.standard.bool(forKey: "input_debug") {
      NSLog(message)
    }
  }
}
