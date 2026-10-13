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

  func testKeysFileIsRecognisedByNameAndSize() {
    XCTAssertEqual(UploadKind.classify(fileName: "keys.bin", size: 0x400), .nandKeys)
    XCTAssertEqual(UploadKind.classify(fileName: "KEYS.BIN", size: 0x400), .nandKeys)
  }

  func testKeysFileOfAnotherSizeIsOther() {
    XCTAssertEqual(UploadKind.classify(fileName: "keys.bin", size: 0x401), .other)
    XCTAssertEqual(UploadKind.classify(fileName: "keys.bin", size: 0), .other)
    XCTAssertEqual(UploadKind.classify(fileName: "nand.bin", size: 0x400), .other)
  }

  func testOnlyTheKeylessDumpNeedsSeparateKeys() {
    XCTAssertTrue(UploadKind.needsSeparateKeys(size: 0x2100_0000))
    XCTAssertFalse(UploadKind.needsSeparateKeys(size: 0x2100_0400))
  }
}
