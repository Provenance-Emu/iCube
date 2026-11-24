import XCTest
@testable import iCube

final class SharedPlusEntitlementTests: XCTestCase {
  func testSandboxRecognizesExistingProductionMembership() {
    let mirrors = ["provenance.plus": "active", "ifly.pro": "active"]
    XCTAssertEqual(SharedPlusMirrorReader.activeSources(sandbox: true) { mirrors[$0] }, ["Provenance", "iFly"])
  }

  func testSandboxMirrorCannotUnlockProduction() {
    let mirrors = ["provenance.plus.sandbox": "active"]
    XCTAssertEqual(SharedPlusMirrorReader.activeSources(sandbox: true) { mirrors[$0] }, ["Provenance"])
    XCTAssertTrue(SharedPlusMirrorReader.activeSources(sandbox: false) { mirrors[$0] }.isEmpty)
  }

  func testProvenanceIsReportedOnceWhenBothMirrorsAreActive() {
    let mirrors = ["provenance.plus": "active", "provenance.plus.sandbox": "active"]
    XCTAssertEqual(SharedPlusMirrorReader.activeSources(sandbox: true) { mirrors[$0] }, ["Provenance"])
  }

  func testStrictMirrorShapeAndExistingRenewalGrace() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func grants(_ period: String?, expiry: Date?, version: Int = 1, status: String = "active") -> Bool {
      SharedPlusMirrorReader.grants(.init(v: version, period: period, status: status, expiresAt: expiry), now: now)
    }
    XCTAssertTrue(grants("lifetime", expiry: nil))
    XCTAssertFalse(grants(nil, expiry: nil))
    XCTAssertFalse(grants("monthly", expiry: nil))
    XCTAssertFalse(grants("yearly", expiry: nil))
    XCTAssertFalse(grants("lifetime", expiry: nil, version: 2))
    XCTAssertFalse(grants("lifetime", expiry: now))
    XCTAssertFalse(grants("lifetime", expiry: nil, status: "revoked"))
    XCTAssertTrue(grants("monthly", expiry: now.addingTimeInterval(-6 * 86400)))
    XCTAssertFalse(grants("monthly", expiry: now.addingTimeInterval(-7 * 86400)))
  }
}
