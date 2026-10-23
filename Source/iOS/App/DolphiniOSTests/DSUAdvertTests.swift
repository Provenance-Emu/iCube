// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class DSUAdvertTests: XCTestCase {
  private func txtData(_ advert: DSUAdvert) -> [String: Data] {
    advert.txtRecord().mapValues { Data($0.utf8) }
  }

  func test_roundTrip() {
    let advert = DSUAdvert(pid: "6F1C2A", name: "Joe's iPhone", deviceType: "iPhone", isController: true)
    XCTAssertEqual(DSUAdvert.parse(txtData(advert)), advert)

    let plain = DSUAdvert(pid: "A1", name: "Den iPad", deviceType: "iPad", isController: false)
    XCTAssertEqual(DSUAdvert.parse(txtData(plain)), plain)
  }

  func test_txtRecord_usesTheDocumentedKeys() {
    let advert = DSUAdvert(pid: "P1", name: "N", deviceType: "iPhone", isController: true)
    XCTAssertEqual(advert.txtRecord(), ["v": "1", "pid": "P1", "name": "N", "dt": "iPhone", "role": "controller"])
  }

  func test_parse_rejectsUnknownVersionOrMissingIdentity() {
    var good = txtData(DSUAdvert(pid: "P1", name: "N", deviceType: "iPhone", isController: true))
    XCTAssertNotNil(DSUAdvert.parse(good))

    var wrongVersion = good
    wrongVersion["v"] = Data("2".utf8)
    XCTAssertNil(DSUAdvert.parse(wrongVersion))

    var noVersion = good
    noVersion["v"] = nil
    XCTAssertNil(DSUAdvert.parse(noVersion))

    var noPid = good
    noPid["pid"] = nil
    XCTAssertNil(DSUAdvert.parse(noPid))

    var emptyPid = good
    emptyPid["pid"] = Data()
    XCTAssertNil(DSUAdvert.parse(emptyPid))

    var noName = good
    noName["name"] = nil
    XCTAssertNil(DSUAdvert.parse(noName))

    good["name"] = Data()
    XCTAssertNil(DSUAdvert.parse(good))

    XCTAssertNil(DSUAdvert.parse([:]))
  }

  func test_nonController_hasNoRole() {
    let advert = DSUAdvert(pid: "P1", name: "N", deviceType: "iPad", isController: false)
    XCTAssertNil(advert.txtRecord()["role"])
    XCTAssertFalse(DSUAdvert.parse(txtData(advert))?.isController ?? true)
  }

  // MARK: Bonjour service name

  func test_serviceName_keepsAShortNameUnchanged() {
    XCTAssertEqual(DSUServerBridge.bonjourServiceName(forDeviceName: "Joe's iPhone"), "Joe's iPhone")
  }

  func test_serviceName_isAtMost63Utf8Bytes_withoutSplittingACharacter() {
    // 40 four-byte characters = 160 bytes; the cap is 63, so 15 whole characters (60 bytes).
    let emoji = String(repeating: "\u{1F3AE}", count: ICubeDeviceName.maxLength)
    let name = DSUServerBridge.bonjourServiceName(forDeviceName: emoji)
    XCTAssertLessThanOrEqual(name.utf8.count, 63)
    XCTAssertEqual(name, String(repeating: "\u{1F3AE}", count: 15))

    // A 2-byte character straddling the limit is dropped whole.
    let accents = String(repeating: "a", count: 62) + "\u{E9}"
    XCTAssertEqual(DSUServerBridge.bonjourServiceName(forDeviceName: accents), String(repeating: "a", count: 62))

    // A combining sequence is never split from its base.
    let combining = String(repeating: "a", count: 60) + "e\u{301}" // 63 bytes
    let kept = DSUServerBridge.bonjourServiceName(forDeviceName: combining)
    XCTAssertLessThanOrEqual(kept.utf8.count, 63)
    XCTAssertEqual(kept, combining)
    let tooLong = String(repeating: "a", count: 61) + "e\u{301}" // 64 bytes
    XCTAssertEqual(DSUServerBridge.bonjourServiceName(forDeviceName: tooLong), String(repeating: "a", count: 61))
  }

  func test_serviceName_exactly63BytesIsKept() {
    let sixtyThree = String(repeating: "x", count: 63)
    XCTAssertEqual(DSUServerBridge.bonjourServiceName(forDeviceName: sixtyThree), sixtyThree)
  }
}
