// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class DSUSettingsTests: XCTestCase {
  private var store: UserDefaults!
  private let suite = "DSUSettingsTests"

  override func setUp() {
    super.setUp()
    UserDefaults().removePersistentDomain(forName: suite)
    store = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suite)
    super.tearDown()
  }

  /// "sender" is what the runtime did with the key unset: TVLibraryView's "Start DSU Controller"
  /// read `?? "sender"` and started the session.
  func testRegisteredRoleIsSender() {
    DSUSettings.registerDefaults(in: store)
    XCTAssertEqual(store.string(forKey: DSUSettings.Key.role), "sender")
    XCTAssertEqual(DSUSettings.role(in: store), .sender)
  }

  func testAUserChoiceBeatsTheRegisteredDefault() {
    DSUSettings.registerDefaults(in: store)
    store.set(DSUSettings.Role.receiver.rawValue, forKey: DSUSettings.Key.role)
    XCTAssertEqual(DSUSettings.role(in: store), .receiver)
  }

  func testAnUnknownStoredValueReadsAsSender() {
    store.set("server", forKey: DSUSettings.Key.role)
    XCTAssertEqual(DSUSettings.role(in: store), .sender)
  }

  func testKeyAndValuesAreTheExistingOnes() {
    XCTAssertEqual(DSUSettings.Key.role, "dsu_role")
    XCTAssertEqual(DSUSettings.Role.receiver.rawValue, "receiver")
    XCTAssertEqual(DSUSettings.Role.sender.rawValue, "sender")
  }

  /// FirstRunInitializationService registers DefaultPreferences.plist on every launch AFTER
  /// AppDelegate, so a DSU key left in it would silently override DSUSettings.defaults.
  func testBundledDefaultPreferencesDefineNoDSUSettingsKey() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "DefaultPreferences", withExtension: "plist"))
    let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
    for key in DSUSettings.defaults.keys {
      XCTAssertNil(plist[key], "\(key) is registered by both DefaultPreferences.plist and DSUSettings")
    }
  }
}
