// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreImage
import XCTest
@testable import iCube

final class AddGamesServerStateTests: XCTestCase {
  func test_notRunning_isStarting_withNoURLOrQR() {
    let s = AddGamesServerState.make(isRunning: false, webURL: "http://10.0.0.2/", webDavURL: "http://10.0.0.2/")
    XCTAssertEqual(s.status, .starting)
    XCTAssertNil(s.uploadURL)
    XCTAssertNil(s.webDavURL)
    XCTAssertNil(s.qrPayload)
  }

  func test_running_sharedListener_showsOneURL() {
    let s = AddGamesServerState.make(isRunning: true, webURL: "http://192.168.1.221/", webDavURL: "http://192.168.1.221/")
    XCTAssertEqual(s.status, .running)
    XCTAssertEqual(s.uploadURL, "http://192.168.1.221/")
    XCTAssertNil(s.webDavURL)
    XCTAssertEqual(s.qrPayload, "http://192.168.1.221/")
  }

  func test_running_distinctWebDAV_keepsBoth_QRIsBrowserURL() {
    let s = AddGamesServerState.make(isRunning: true, webURL: "http://10.0.0.2/", webDavURL: "http://10.0.0.2:8081/")
    XCTAssertEqual(s.uploadURL, "http://10.0.0.2/")
    XCTAssertEqual(s.webDavURL, "http://10.0.0.2:8081/")
    XCTAssertEqual(s.qrPayload, "http://10.0.0.2/")
  }

  func test_running_withoutAddress_isResolving() {
    let s = AddGamesServerState.make(isRunning: true, webURL: "  ", webDavURL: nil)
    XCTAssertEqual(s.status, .running)
    XCTAssertNil(s.uploadURL)
    XCTAssertNil(s.qrPayload)
  }

  func test_running_onlyWebDAV_becomesUploadURL() {
    let s = AddGamesServerState.make(isRunning: true, webURL: nil, webDavURL: "http://10.0.0.2/")
    XCTAssertEqual(s.uploadURL, "http://10.0.0.2/")
    XCTAssertNil(s.webDavURL)
  }

  func test_qrCode_emptyString_isNil() {
    XCTAssertNil(QRCode.image(from: ""))
  }

  func test_qrCode_decodesToPayload() throws {
    let payload = "http://192.168.1.221/"
    let image = try XCTUnwrap(QRCode.image(from: payload))
    let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let decoded = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    XCTAssertEqual(decoded, [payload])
  }
}
