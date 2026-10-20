import PVContinuity
import XCTest
@testable import iCube

final class ICubeSaveStateMinterTests: XCTestCase {
  private actor Probe {
    var requests: [(Int, String?, UInt64)] = []
    func record(_ slot: Int, _ gameID: String?, _ session: UInt64) { requests.append((slot, gameID, session)) }
  }

  func test_failedFreshSaveCannotExportAnExistingStaleSlot99() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).s99")
    try Data("old state".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let probe = Probe()
    let minter = ICubeSaveStateMinter(saveSnapshot: { slot, gameID, session in
      await probe.record(slot, gameID, session)
      return nil
    })
    do {
      _ = try await minter.mintHandoffState(identity: GameIdentity(gameID: "GALE01", displayName: "Test", platform: "gc"))
      XCTFail("A failed save must not mint a descriptor for stale bytes")
    } catch let error as ContinuityError {
      guard case .noActiveSession = error else { return XCTFail("Unexpected error: \(error)") }
    }
    let requests = await probe.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.0, 99)
    XCTAssertEqual(requests.first?.1, "GALE01")
    XCTAssertGreaterThan(requests.first?.2 ?? 0, 0)
    XCTAssertEqual(try Data(contentsOf: file), Data("old state".utf8))
  }
}
