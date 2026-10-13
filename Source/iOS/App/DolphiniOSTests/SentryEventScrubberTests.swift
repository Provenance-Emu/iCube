import XCTest
@testable import iCube

final class SentryEventScrubberTests: XCTestCase {
  func testStripsGameIdentity() {
    let out = SentryEventScrubber.scrubTags(["game_id": "GALE01", "jit": "on", "session_id": "abc"])
    XCTAssertNil(out["game_id"])
    XCTAssertEqual(out["jit"], "on")
  }

  // The file name is a game title, so the whole path (name included) becomes <path>.
  func testRedactsContainerPaths() {
    let msg = "Failed to open /var/mobile/Containers/Data/Application/1234-ABCD/Documents/Software/Zelda.rvz"
    XCTAssertEqual(SentryEventScrubber.scrubMessage(msg), "Failed to open <path>")
  }

  // Game file names contain spaces and dots; none of the title may survive, and the text after the path stays.
  func testRedactsPathsWhoseFileNameHasSpaces() {
    let msg = "Cannot read /private/var/mobile/Containers/Shared/AppGroup/ABCD/Software/Super Smash Bros. Melee.iso: denied"
    XCTAssertEqual(SentryEventScrubber.scrubMessage(msg), "Cannot read <path>: denied")
  }

  func testLeavesPlainTextAlone() {
    XCTAssertEqual(SentryEventScrubber.scrubMessage("Invalid read from 0x80001234"), "Invalid read from 0x80001234")
  }
}
