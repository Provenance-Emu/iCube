// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

class TCButton: UIButton {
#if os(iOS)
  let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)
#endif
  @IBInspectable var controllerButton: Int = 0 { // default: GC A button
    didSet {
      updateImage()
    }
  }

  @IBInspectable var isAxis: Bool = false

  var port: Int = 0
  var useHapicTouch: Bool = true
  var lastForce: CGFloat = CGFloat.zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    sharedInit()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    sharedInit()
  }

  func sharedInit() {
    self.setTitle("", for: .normal)
    self.addTarget(self, action: #selector(buttonPressed), for: .touchDown)
    self.addTarget(self, action: #selector(buttonReleased), for: .touchUpInside)

    // TODO: Setting for hapic touch analog triggers enabled
    self.useHapicTouch = self.traitCollection.forceTouchCapability == .available
  }

  func updateImage() {
    let buttonType = TCButtonType(rawValue: controllerButton)!

    let buttonImage = getImage(named: buttonType.getImageName(), scale: buttonType.getButtonScale())
    self.setImage(buttonImage, for: .normal)

    let buttonPressedImage = getImage(named: buttonType.getImageName() + "_pressed", scale: buttonType.getButtonScale())
    self.setImage(buttonPressedImage, for: .selected)
  }

  func getImage(named: String, scale: CGFloat) -> UIImage {
    // In Interface Builder, the default bundle is not Dolphin's, so we must specify
    // the bundle for the image to load correctly
    let image = UIImage(named: named, in: Bundle(for: type(of: self)), compatibleWith: nil)!

    // Create a new CGSize with the new scale
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

    // Render the image into a context
    UIGraphicsBeginImageContext(newSize)
    image.draw(in: CGRect(origin: CGPoint.zero, size: newSize))
    let newImage = UIGraphicsGetImageFromCurrentImageContext()!
    UIGraphicsEndImageContext()

    return newImage.withRenderingMode(.alwaysOriginal)
  }

  @objc func buttonPressed() {
    if isAxis && useHapicTouch {
      return
    }

#if os(iOS)
    hapticGenerator.impactOccurred()
#endif

    if isAxis {
#if os(iOS)
      TCManagerInterface.setAxisValueFor(controllerButton, controller: port, value: 1.0)
#endif
    } else {
#if os(iOS)
      TCManagerInterface.setButtonStateFor(controllerButton, controller: port, state: true)
#endif
    }
  }

  @objc func buttonReleased() {
    if isAxis {
#if os(iOS)
      TCManagerInterface.setAxisValueFor(controllerButton, controller: port, value: 0.0)
#endif
    } else {
#if os(iOS)
      TCManagerInterface.setButtonStateFor(controllerButton, controller: port, state: false)
#endif
    }
  }

  @objc override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    if !isAxis || !useHapicTouch {
      return
    }

    let touch = touches.first!
    let force = touch.force
    let maxForce = touch.maximumPossibleForce
    let percentage: Float = Float(force / maxForce)

#if os(iOS)
    TCManagerInterface.setAxisValueFor(controllerButton, controller: port, value: percentage)
#endif

    if self.lastForce != force && force == maxForce {
#if os(iOS)
      hapticGenerator.impactOccurred()
#endif
    }

    self.lastForce = force
  }

}
