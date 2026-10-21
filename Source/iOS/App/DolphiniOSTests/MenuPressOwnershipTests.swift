import XCTest
@testable import iCube

final class MenuPressOwnershipTests: XCTestCase {
  func testOverlayOwnedPressCannotBecomeGameplayPressAfterDismissalInEitherRouteOrder() {
    for order in [["gc", "ui"], ["ui", "gc"]] {
      var ownership = MenuPressOwnership()
      ownership.began(route: order[0], overlayOwned: true)
      ownership.began(route: order[1], overlayOwned: false)
      XCTAssertFalse(ownership.ended(route: order[0]))
      XCTAssertFalse(ownership.ended(route: order[1]))
      ownership.began(route: "gc", overlayOwned: false)
      XCTAssertTrue(ownership.ended(route: "gc"))
    }
  }

  func testUnmatchedReleaseNeverOpensMenuAndGameplayDuplicateOpensOnce() {
    var ownership = MenuPressOwnership()
    XCTAssertFalse(ownership.ended(route: "ui"))
    ownership.began(route: "gc", overlayOwned: false)
    ownership.began(route: "ui", overlayOwned: false)
    XCTAssertFalse(ownership.ended(route: "ui"))
    XCTAssertTrue(ownership.ended(route: "gc"))
    XCTAssertFalse(ownership.ended(route: "ui"))
  }
}
