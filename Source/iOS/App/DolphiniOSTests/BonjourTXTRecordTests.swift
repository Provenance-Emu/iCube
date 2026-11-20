// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class BonjourTXTRecordTests: XCTestCase {
  /// One length-prefixed entry per string, the way a TXT record is laid out on the wire.
  private func record(_ entries: [String]) -> Data {
    entries.reduce(into: Data()) { data, entry in
      data.append(UInt8(entry.utf8.count))
      data.append(contentsOf: entry.utf8)
    }
  }

  func testReadsKeysAndValues() {
    let txt = BonjourTXTRecord.dictionary(from: record(["path=/dav", "u=joe", "v=2"]))
    XCTAssertEqual(txt, ["path": Data("/dav".utf8), "u": Data("joe".utf8), "v": Data("2".utf8)])
  }

  func testMatchesFoundationOnAnOrdinaryRecord() {
    let source = ["id": Data("abc".utf8), "name": Data("Living Room".utf8)]
    let data = NetService.data(fromTXTRecord: source)
    XCTAssertEqual(BonjourTXTRecord.dictionary(from: data), source)
  }

  /// A key with no `=` is legal ("boolean attribute") and is what crashed: Foundation hands it
  /// back as NSNull, which cannot be bridged to `[String: Data]` (ICUBE-NH).
  func testAKeyWithoutAValueIsLeftOutInsteadOfCrashing() {
    let txt = BonjourTXTRecord.dictionary(from: record(["flag", "port=8091"]))
    XCTAssertEqual(txt, ["port": Data("8091".utf8)])
  }

  func testAnEmptyValueIsKept() {
    XCTAssertEqual(BonjourTXTRecord.dictionary(from: record(["note="])), ["note": Data()])
  }

  func testTheFirstOfARepeatedKeyWins() {
    XCTAssertEqual(BonjourTXTRecord.dictionary(from: record(["k=1", "k=2"])), ["k": Data("1".utf8)])
  }

  func testAValueMayContainAnEqualsSign() {
    XCTAssertEqual(BonjourTXTRecord.dictionary(from: record(["q=a=b"])), ["q": Data("a=b".utf8)])
  }

  func testEmptyAndMalformedRecordsReadAsFarAsTheyGo() {
    XCTAssertEqual(BonjourTXTRecord.dictionary(from: Data()), [:])
    XCTAssertEqual(BonjourTXTRecord.dictionary(from: Data([0])), [:])
    XCTAssertEqual(BonjourTXTRecord.dictionary(from: record(["=novalue"])), [:])
    // The last entry claims more bytes than the record holds.
    var truncated = record(["a=1"])
    truncated.append(contentsOf: [9, 0x62, 0x3D])
    XCTAssertEqual(BonjourTXTRecord.dictionary(from: truncated), ["a": Data("1".utf8)])
  }

  /// A slice does not start at index 0.
  func testReadsADataSlice() {
    let padded = Data([0xFF, 0xFF]) + record(["a=1"])
    XCTAssertEqual(BonjourTXTRecord.dictionary(from: padded.dropFirst(2)), ["a": Data("1".utf8)])
  }
}
