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

#if os(tvOS)
// UIKit wrapper for the legacy mapping UI (MappingRootViewController in ButtonMapping.storyboard)
// Not private: ControllerSetupView's "Customize buttons…" row drills into this same representable.
typealias ControllersMappingView = ButtonMappingView
#else
// UIKit wrapper for the legacy mapping UI (MappingRootViewController in ButtonMapping.storyboard)
// Not private: ControllerSetupView's "Customize buttons…" row drills into this same representable.
struct ControllersMappingView: UIViewControllerRepresentable {
  let isGC: Bool
  let portOneBased: Int

  func makeUIViewController(context: Context) -> UIViewController {
    let storyboard = UIStoryboard(name: "ButtonMapping", bundle: nil)
    let vc = storyboard.instantiateInitialViewController() ?? UIViewController()
    // Pass mapping context via KVC to avoid additional bridging requirements
    // DOLMappingType: 0 = Pad, 1 = Wiimote
    vc.setValue(isGC ? 0 : 1, forKey: "mappingType")
    vc.setValue(max(0, portOneBased - 1), forKey: "mappingPort")
    return vc
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    // No-op; mapping UI manages its own state
  }
}
#endif
