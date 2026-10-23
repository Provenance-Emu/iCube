// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ICubeDeviceNameTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "ICubeDeviceNameTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func test_current_fallsBackToSystemName_whenUnsetOrBlank() {
    XCTAssertEqual(ICubeDeviceName.current(defaults: defaults, systemName: "iPhone"), "iPhone")
    defaults.set("   ", forKey: ICubeDeviceName.defaultsKey)
    XCTAssertEqual(ICubeDeviceName.current(defaults: defaults, systemName: "iPhone"), "iPhone")
  }

  func test_set_trimsAndCaps() {
    ICubeDeviceName.set("  Joe's iPhone  ", defaults: defaults)
    XCTAssertEqual(ICubeDeviceName.current(defaults: defaults, systemName: "iPhone"), "Joe's iPhone")

    let sixty = String(repeating: "abcdefghij", count: 6)
    ICubeDeviceName.set(sixty, defaults: defaults)
    XCTAssertEqual(ICubeDeviceName.current(defaults: defaults, systemName: "iPhone"), String(sixty.prefix(40)))
  }

  func test_set_nil_clears() {
    ICubeDeviceName.set("Den", defaults: defaults)
    ICubeDeviceName.set(nil, defaults: defaults)
    XCTAssertNil(defaults.string(forKey: ICubeDeviceName.defaultsKey))
    XCTAssertEqual(ICubeDeviceName.current(defaults: defaults, systemName: "iPhone"), "iPhone")
  }

  func test_set_blank_clears() {
    ICubeDeviceName.set("Den", defaults: defaults)
    ICubeDeviceName.set("   ", defaults: defaults)
    XCTAssertNil(defaults.string(forKey: ICubeDeviceName.defaultsKey))
  }
}
