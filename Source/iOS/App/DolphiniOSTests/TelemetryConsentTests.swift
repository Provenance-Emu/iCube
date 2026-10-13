import XCTest
@testable import iCube

final class TelemetryConsentTests: XCTestCase {
  private var defaults: UserDefaults!
  override func setUp() { defaults = UserDefaults(suiteName: "TelemetryConsentTests")!; defaults.removePersistentDomain(forName: "TelemetryConsentTests") }

  // Sentry starts in AppDelegate before DefaultPreferences.plist is registered, so the default must live in code.
  func testDefaultsToOnWhenNeverSet() { XCTAssertTrue(TelemetryConsent.isEnabled(defaults)) }

  func testRemembersOptOut() {
    TelemetryConsent.set(false, defaults: defaults)
    XCTAssertFalse(TelemetryConsent.isEnabled(defaults))
  }
}
