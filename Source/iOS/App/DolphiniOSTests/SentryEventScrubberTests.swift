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

  // A version number looks like an extension ("v1.02"); only a known file extension may end the path.
  func testRedactsTitlesContainingVersionNumbers() {
    let msg = "Cannot read /var/mobile/Containers/Data/Application/ABCD/Documents/Software/Foo v1.02 Collector's Edition.iso: denied"
    XCTAssertEqual(SentryEventScrubber.scrubMessage(msg), "Cannot read <path>: denied")
  }

  func testRedactsFileURLs() {
    let msg = "No such file file:///var/mobile/Containers/Data/Application/ABCD/Documents/Software/Metroid%20Prime.rvz."
    XCTAssertEqual(SentryEventScrubber.scrubMessage(msg), "No such file <path>.")
  }

  func testRedactsUsersPathsAndIgnoresExtensionCase() {
    XCTAssertEqual(SentryEventScrubber.scrubMessage("Loaded /Users/joe/Games/Mario Kart.WBFS ok"), "Loaded <path> ok")
  }

  func testRedactsEveryPathInAMessage() {
    let msg = "Copy /var/mobile/a/One Game.iso to /private/var/mobile/b/Two Game.nkit.iso failed"
    XCTAssertEqual(SentryEventScrubber.scrubMessage(msg), "Copy <path> to <path> failed")
  }

  // Without a known extension the rest of the line goes: over-redacting is the safe direction.
  func testRedactsPathWithoutExtensionToEndOfLine() {
    let msg = "No such directory /var/mobile/Containers/Data/Application/ABCD/Documents/Super Mario Sunshine: denied"
    XCTAssertEqual(SentryEventScrubber.scrubMessage(msg), "No such directory <path>")
  }

  func testLeavesPlainTextAlone() {
    XCTAssertEqual(SentryEventScrubber.scrubMessage("Invalid read from 0x80001234"), "Invalid read from 0x80001234")
  }
}
