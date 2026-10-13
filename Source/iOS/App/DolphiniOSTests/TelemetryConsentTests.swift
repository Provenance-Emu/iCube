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

  // Opting out deletes the SDK's queued envelopes and pending crash reports, and nothing else in Caches.
  func testRemovesOnlyTheSDKDiskState() throws {
    let fileManager = FileManager.default
    let caches = fileManager.temporaryDirectory.appendingPathComponent("TelemetryConsentTests-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: caches) }
    for name in SentryTelemetryService.sdkCacheDirectoryNames + ["Keep"] {
      let directory = caches.appendingPathComponent(name)
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("x".utf8).write(to: directory.appendingPathComponent("file"))
    }

    SentryTelemetryService.removeSDKDiskState(cachesDirectory: caches, fileManager: fileManager)

    for name in SentryTelemetryService.sdkCacheDirectoryNames {
      XCTAssertFalse(fileManager.fileExists(atPath: caches.appendingPathComponent(name).path), name)
    }
    XCTAssertTrue(fileManager.fileExists(atPath: caches.appendingPathComponent("Keep/file").path))
  }
}
