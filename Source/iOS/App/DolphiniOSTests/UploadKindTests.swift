import XCTest
@testable import iCube

final class UploadKindTests: XCTestCase {
  func testBootMiiDumpIsANandBackup() {
    for size in UploadKind.acceptedSizes {
      XCTAssertEqual(UploadKind.classify(fileName: "nand.bin", size: size), .nandBackup)
      XCTAssertEqual(UploadKind.classify(fileName: "NAND.BIN", size: size), .nandBackup)
    }
  }

  func testWrongSizeIsNotANandBackup() {
    XCTAssertEqual(UploadKind.classify(fileName: "nand.bin", size: 1_459_978_240), .other) // a renamed GameCube ISO
    XCTAssertEqual(UploadKind.classify(fileName: "nand.bin", size: 0), .other)
  }

  func testOtherNamesAreOther() {
    XCTAssertEqual(UploadKind.classify(fileName: "game.rvz", size: UploadKind.acceptedSizes.first!), .other)
  }
}
