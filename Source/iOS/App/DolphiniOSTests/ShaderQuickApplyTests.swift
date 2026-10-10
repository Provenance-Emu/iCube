// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class ShaderQuickApplyTests: XCTestCase {
  func test_displayName_isFileNameWithoutExtension() {
    XCTAssertEqual(ShaderQuickApply.displayName(forPath: "/Shaders/crt/crt-royale.slangp"), "crt-royale")
  }

  func test_options_noneFirst_thenMRU_withCurrentIncluded() {
    let options = ShaderQuickApply.options(mru: ["/a/one.slangp", "/b/two.slangp"], current: "/c/three.slangp")
    XCTAssertEqual(options.map(\.0), ["None", "three", "one", "two"])
    XCTAssertEqual(options.first?.1, ShaderQuickApply.noneValue)
    XCTAssertEqual(options[1].1, AnyHashable("/c/three.slangp"))
  }

  func test_options_currentAlreadyInMRU_isNotDuplicated() {
    let options = ShaderQuickApply.options(mru: ["/a/one.slangp"], current: "/a/one.slangp")
    XCTAssertEqual(options.map(\.0), ["None", "one"])
  }

  func test_pushMRU_frontInsertsDedupesAndCaps() {
    let defaults = UserDefaults(suiteName: "ShaderQuickApplyTests")!
    defaults.removePersistentDomain(forName: "ShaderQuickApplyTests")
    for i in 0 ..< 12 { ShaderQuickApply.pushMRU("/p/\(i).slangp", defaults: defaults) }
    ShaderQuickApply.pushMRU("/p/5.slangp", defaults: defaults)
    let list = defaults.stringArray(forKey: "shader_mru") ?? []
    XCTAssertEqual(list.count, 10)
    XCTAssertEqual(list.first, "/p/5.slangp")
    XCTAssertEqual(list.filter { $0 == "/p/5.slangp" }.count, 1)
  }
}
