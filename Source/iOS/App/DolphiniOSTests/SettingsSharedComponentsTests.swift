// DolphiniOSTests/SettingsSharedComponentsTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import SwiftUI
import UIKit

@testable import iCube

final class SettingsSharedComponentsTests: XCTestCase {
  /// Confirmation hosts ask for intrinsic height. Every action must contribute
  /// usable space even without an ancestor assigning the menu a height.
  @MainActor
  func test_confirmationActionsHaveIntrinsicHeightWithoutActivating() {
    var activations = 0
    let model = MenuModel(sections: [MenuSection(id: "exit", items: [
      MenuItem(id: "cancel", title: "Cancel", icon: "xmark", role: .action { activations += 1 }),
      MenuItem(id: "quit", title: "Quit", icon: "xmark.circle", role: .destructive { activations += 1 }),
      MenuItem(id: "save", title: "Save & Quit", icon: "square.and.arrow.down", role: .action { activations += 1 }),
    ])])
    for width: CGFloat in [260, 348] {
      let host = UIHostingController(rootView: MenuScreen(model: model, style: .actions))
      let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
      XCTAssertTrue(size.height.isFinite)
      XCTAssertGreaterThanOrEqual(size.height, 3 * 44,
        "A confirmation must allocate height for all three touch actions")
      XCTAssertLessThanOrEqual(size.width, width)
    }
    XCTAssertEqual(activations, 0)
  }

  /// A two-core host offers only one shader compiler thread. The row must still render,
  /// without creating a Slider whose maximum stride is zero or writing a new setting.
  @MainActor
  func test_singleValueStepperRendersWithoutChangingTheSetting() {
    var writes: [Double] = []
    let stepper = MenuStepper(value: Binding(get: { 1 }, set: { writes.append($0) }),
                              range: 1 ... 1, step: 1, format: { String(Int($0)) })
    let host = UIHostingController(rootView: ValueStepper(stepper: stepper, title: "Compiler Threads", isEnabled: true))

    let size = host.sizeThatFits(in: CGSize(width: 390, height: 100))

    XCTAssertGreaterThan(size.height, 0)
    XCTAssertTrue(writes.isEmpty)
  }

  func test_overrideBadgeTitle_namesWhoIsDrivingTheKey() {
    XCTAssertEqual(ConfigOverrideBadge.title(for: .auto), L("Auto"))
    XCTAssertEqual(ConfigOverrideBadge.title(for: .game), L("Game"))
    XCTAssertNil(ConfigOverrideBadge.title(for: .none))
  }
}
