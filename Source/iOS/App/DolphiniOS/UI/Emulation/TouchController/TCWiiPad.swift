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
    debugLog(String(format: "[TOUCH] Wii recalc: rect=(%.1fx%.1f) center=(%.1f,%.1f) inv=(%.4f,%.4f) AR=%.3f",
                    new_rect.width, new_rect.height, gameCenterX, gameCenterY, gameWidthHalfInv, gameHeightHalfInv, game_aspect))
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if touch.view == self.real_view {
      return true
    }

    return false
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
#if os(iOS)
    if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer {
      return true
    }
#endif

    return false
  }

  @objc func handleLongPress(gesture: UILongPressGestureRecognizer) {
    if mode == .none {
      return
    }

    let point = gesture.location(in: self)

    if gesture.state == .began {
      touchStartPoint = point
      debugLog(String(format: "[TOUCH] Wii IR begin at (%.3f, %.3f) port=%d mode=%d", point.x, point.y, port, mode.rawValue))
      return
    }

    var x: CGFloat, y: CGFloat

    if mode == .follow {
      x = (point.x - gameCenterX) * gameWidthHalfInv
      y = (point.y - gameCenterY) * gameHeightHalfInv
    } else {
      x = oldX + (point.x - touchStartPoint.x) * gameWidthHalfInv
      y = oldY + (point.y - touchStartPoint.y) * gameHeightHalfInv
    }

#if os(iOS)
    let axisStartIdx = TCButtonType.wiiInfrared
    for (i, axis) in [y, y, x, x].enumerated() {
      let idx = axisStartIdx.rawValue + i + 1
      TCManagerInterface.setAxisValueFor(idx, controller: self.port, value: Float(axis))
      debugLog(String(format: "[TOUCH] Wii IR axis send idx=%d val=%.4f port=%d", idx, axis, port))
    }
#endif

    if gesture.state == .ended && mode == .drag {
      oldX = x
      oldY = y
      debugLog(String(format: "[TOUCH] Wii IR end; persisted (x=%.4f,y=%.4f)", x, y))
    }
  }

  @objc func setTouchIRMode(_ newMode: TCWiiTouchIRMode) {
    self.mode = newMode
    debugLog("[TOUCH] Wii IR mode set to \(newMode.rawValue)")
  }

  @objc func resetPointer() {
    touchStartPoint = CGPoint(x: 0, y: 0)
    oldX = 0
    oldY = 0
    debugLog("[TOUCH] Wii IR pointer reset")
  }

  private func debugLog(_ message: String) {
    if UserDefaults.standard.bool(forKey: "input_debug") {
      NSLog(message)
    }
  }
}
