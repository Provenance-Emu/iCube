// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

@objc class TCView: UIView {
  var real_view: UIView?

  private var _port: Int = 0
  @objc var port: Int {
    get {
      return _port
    }
    set {
      _port = newValue
      if let rv = real_view {
        debugLog("[TOUCH] TCView set port=\(newValue) on \(type(of: self)); propagating to subtree")
        SetPort(newValue, view: rv)
      } else {
        debugLog("[TOUCH] TCView set port=\(newValue) but real_view is nil for \(type(of: self))")
      }
    }
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)

    // Load ourselves from the nib
    let name = String(describing: type(of: self))
    let view = Bundle(for: type(of: self)).loadNibNamed(name, owner: self, options: nil)![0] as! UIView
    view.frame = bounds
    addSubview(view)

    self.real_view = view
    debugLog("[TOUCH] TCView loaded nib=\(name); real_view=\(String(describing: real_view))")
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    let name = String(describing: type(of: self))
    if let view = Bundle(for: type(of: self)).loadNibNamed(name, owner: self, options: nil)?.first as? UIView {
      view.frame = bounds
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(view)
      self.real_view = view
      debugLog("[TOUCH] TCView init(frame:) loaded nib=\(name)")
    } else {
      debugLog("[TOUCH] TCView init(frame:) failed to load nib=\(name)")
    }
  }

  func SetPort(_ port: Int, view: UIView) {
    for subview in view.subviews {
      switch subview {
      case let button as TCButton:
        debugLog("[TOUCH]   -> set port=\(port) on TCButton \(button)")
        button.port = port
      case let joystick as TCJoystick:
        debugLog("[TOUCH]   -> set port=\(port) on TCJoystick \(joystick)")
        joystick.port = port
      case let dpad as TCDirectionalPad:
        debugLog("[TOUCH]   -> set port=\(port) on TCDirectionalPad \(dpad)")
        dpad.port = port
      default:
        SetPort(port, view: subview)
      }
    }
  }

  private func debugLog(_ message: String) {
    if UserDefaults.standard.bool(forKey: "input_debug") {
      NSLog(message)
    }
  }
}
