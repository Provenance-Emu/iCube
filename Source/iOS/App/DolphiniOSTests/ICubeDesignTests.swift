// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import XCTest

@testable import iCube

final class ICubeDesignTests: XCTestCase {
  func test_sixTypeRoles() {
    XCTAssertEqual(ICubeDesign.TypeRole.allCases, [.title, .section, .nav, .body, .detail, .tag])
  }

  func test_displayFaceIsRegistered() {
    XCTAssertTrue(UIFont.familyNames.contains(ICubeDesign.DisplayFace.family),
                  "UIAppFonts did not register \(ICubeDesign.DisplayFace.family)")
    XCTAssertNotNil(UIFont(name: ICubeDesign.DisplayFace.postScriptName(bold: false), size: 12))
    XCTAssertNotNil(UIFont(name: ICubeDesign.DisplayFace.postScriptName(bold: true), size: 12))
    XCTAssertTrue(ICubeDesign.DisplayFace.isAvailable)
  }

  func test_typeTable_matchesSpec() {
    // (tvOS pt, iPad pt) per spec §2.1.
    let expected: [ICubeDesign.TypeRole: (CGFloat, CGFloat)] = [
      .title: (48, 34), .section: (30, 20), .nav: (24, 17), .body: (29, 17), .detail: (23, 13), .tag: (20, 12),
    ]
    for role in ICubeDesign.TypeRole.allCases {
      let spec = ICubeDesign.TypeSpec.of(role)
      XCTAssertEqual(spec.tvSize, expected[role]!.0, "\(role) tvOS size")
      XCTAssertEqual(spec.padSize, expected[role]!.1, "\(role) iPad size")
    }
    XCTAssertTrue(ICubeDesign.TypeSpec.of(.section).uppercase)
    XCTAssertTrue(ICubeDesign.TypeSpec.of(.nav).uppercase)
    XCTAssertTrue(ICubeDesign.TypeSpec.of(.tag).uppercase)
    XCTAssertFalse(ICubeDesign.TypeSpec.of(.body).uppercase)
    XCTAssertEqual(ICubeDesign.TypeSpec.of(.section).tracking, 1.5)
    XCTAssertEqual(ICubeDesign.TypeSpec.of(.nav).tracking, 1.2)
    XCTAssertEqual(ICubeDesign.TypeSpec.of(.tag).tracking, 0.5)
  }
}
