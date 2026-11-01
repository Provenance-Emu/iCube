// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
#if canImport(iCube)
@testable import iCube
#elseif canImport(CloudKitGate)
@testable import CloudKitGate
#endif

final class SignedCloudKitEntitlementsTests: XCTestCase {
    private let identifier = "iCloud.com.joemattiello.iCube"
    private var valid: [String: Any] {
        ["com.apple.developer.icloud-services": ["CloudKit"],
         "com.apple.developer.icloud-container-identifiers": [identifier],
         "com.apple.developer.icloud-container-environment": "Production"]
    }
    private func be(_ n: Int) -> Data { var n = UInt32(n).bigEndian; return Data(bytes: &n, count: 4) }
    private func tlv(_ tag: UInt8, _ body: Data) -> Data {
        let length = body.count < 128 ? Data([UInt8(body.count)]) : (body.count < 256 ? Data([0x81, UInt8(body.count)]) : Data([0x82, UInt8(body.count >> 8), UInt8(body.count & 255)]))
        return Data([tag]) + length + body
    }
    private func der(_ value: Any) -> Data {
        if let s = value as? String { return tlv(12, Data(s.utf8)) }
        if let a = value as? [String] { return tlv(48, a.reduce(Data()) { $0 + der($1) }) }
        let d = value as! [String: Any]
        return tlv(49, d.keys.sorted().reduce(Data()) { $0 + tlv(48, der($1) + der(d[$1]!)) })
    }
    private func signature(_ dict: [String: Any]? = nil, xml: [String: Any]? = nil, rawDER: Data? = nil, rawXML: Data? = nil) -> Data {
        let payload = rawDER ?? der(dict ?? valid)
        var blobs = [(7, be(0xfade7172) + be(payload.count + 8) + payload)]
        if xml != nil || rawXML != nil {
            let x = rawXML ?? (try! PropertyListSerialization.data(fromPropertyList: xml!, format: .xml, options: 0))
            blobs.append((5, be(0xfade7171) + be(x.count + 8) + x))
        }
        var offset = 12 + blobs.count * 8
        var indices = Data(), bodies = Data()
        for (slot, blob) in blobs { indices += be(slot) + be(offset); bodies += blob; offset += blob.count }
        return be(0xfade0cc0) + be(offset) + be(blobs.count) + indices + bodies
    }
    private func allows(_ blob: Data) -> Bool {
        SignedCloudKitEntitlements.signatureAllowsCloudKit(blob, identifier: identifier)
    }
    func testValidDERAndMatchingXMLAllowCloudKit() {
        XCTAssertTrue(allows(signature()))
        XCTAssertTrue(allows(signature(xml: valid)))
        var development = valid; development["com.apple.developer.icloud-container-environment"] = "Development"
        XCTAssertTrue(allows(signature(development)))
    }
    func testModernVersionOnePreservesValidInstalls() {
        // Modern codesign layout observed in existing device archive slot 7:
        // APPLICATION 16 { INTEGER 1, CONTEXT 16 { SEQUENCE(key, value)... } }.
        let pairs = valid.keys.sorted().reduce(Data()) { $0 + tlv(48, der($1) + der(valid[$1]!)) }
        let modern = tlv(0x70, tlv(2, Data([1])) + tlv(0xb0, pairs))
        XCTAssertTrue(allows(signature(rawDER: modern)))
        XCTAssertTrue(allows(signature(xml: valid, rawDER: modern)))
        XCTAssertFalse(allows(signature(rawDER: tlv(0x70, tlv(2, Data([2])) + tlv(0xb0, pairs)))))
        let reversed = valid.keys.sorted().reversed().reduce(Data()) { $0 + tlv(48, der($1) + der(valid[$1]!)) }
        XCTAssertFalse(allows(signature(rawDER: tlv(0x70, tlv(2, Data([1])) + tlv(0xb0, reversed)))))
    }
    func testMalformedServicesAndEnvironmentNeverAllowCloudKit() {
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertFalse(allows(signature(missing)), key)
            var wildcard = valid; wildcard[key] = "*"
            XCTAssertFalse(allows(signature(wildcard)), key)
        }
        var wrongContainer = valid; wrongContainer["com.apple.developer.icloud-container-identifiers"] = ["iCloud.other"]
        XCTAssertFalse(allows(signature(wrongContainer)))
    }
    func testXMLDERDisagreementIsRejected() {
        var wrong = valid; wrong["com.apple.developer.icloud-container-environment"] = "Development"
        XCTAssertFalse(allows(signature(xml: wrong)))
        var malformed = valid; malformed["com.apple.developer.icloud-services"] = "*"
        XCTAssertFalse(allows(signature(malformed, xml: valid)))
    }
    func testTruncationsUnknownDERAndDuplicateKeysAreRejected() {
        let good = signature()
        for n in 0..<good.count { XCTAssertFalse(allows(Data(good.prefix(n))), "truncation \(n)") }
        XCTAssertFalse(allows(signature(rawDER: Data([0x70, 0]))))
        let pair = tlv(48, der("com.apple.developer.icloud-services") + der(["CloudKit"]))
        XCTAssertFalse(allows(signature(rawDER: tlv(49, pair + pair))))
        XCTAssertFalse(allows(signature(rawDER: der(valid) + Data([0]))))
    }
    func testDuplicateXMLKeysAndEntityDeclarationsAreRejected() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: valid, format: .xml, options: 0)
        let raw = String(data: xml, encoding: .utf8)!
        let extra = "<key><![CDATA[com.apple.developer.icloud-services]]></key><array><string>CloudKit</string></array>"
        XCTAssertFalse(allows(signature(rawXML: Data(raw.replacingOccurrences(of: "</dict>", with: extra + "</dict>").utf8))))
        let withEntity = raw.replacingOccurrences(of: "<plist version=\"1.0\">", with: "<!DOCTYPE plist [<!ENTITY custom 'CloudKit'>]><plist version=\"1.0\">")
        XCTAssertFalse(allows(signature(rawXML: Data(withEntity.utf8))))
    }
    func testSuperblobOffsetsDuplicatesAndSizeLimitsAreRejected() {
        func changed(_ source: Data, at offset: Int, to value: Int) -> Data {
            var copy = source; copy.replaceSubrange(offset..<offset + 4, with: be(value)); return copy
        }
        let good = signature(xml: valid)
        XCTAssertFalse(allows(changed(good, at: 16, to: good.count)))
        XCTAssertFalse(allows(changed(good, at: 8, to: 0xffffffff)))
        XCTAssertFalse(allows(changed(good, at: 4, to: 0xffffffff)))
        XCTAssertFalse(allows(changed(good, at: 20, to: 7))) // duplicate DER slot
        XCTAssertFalse(allows(changed(good, at: 24, to: 28))) // overlapping blobs
        XCTAssertFalse(allows(changed(signature(), at: 12, to: 8))) // no DER slot
        XCTAssertFalse(allows(Data(repeating: 0, count: 1_048_577)))
    }
    func testMachOFileUsesSignatureInsteadOfLinkerEntitlements() throws {
        func le(_ n: Int) -> Data { var n = UInt32(n).littleEndian; return Data(bytes: &n, count: 4) }
        let blob = signature()
        // Thin arm64 MH_EXECUTE with a single LC_CODE_SIGNATURE.
        let header = le(0xfeedfacf) + le(0x100000c) + le(0) + le(2) + le(1) + le(16) + le(0) + le(0)
        let command = le(0x1d) + le(16) + le(48) + le(blob.count)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try (header + command + blob).write(to: url)
        XCTAssertTrue(SignedCloudKitEntitlements.allowsCloudKit(executableURL: url, identifier: identifier, cpuType: 0x100000c, cpuSubtype: 0))
        try (header + command + Data(blob.prefix(10))).write(to: url)
        XCTAssertFalse(SignedCloudKitEntitlements.allowsCloudKit(executableURL: url, identifier: identifier, cpuType: 0x100000c, cpuSubtype: 0))
        // Plausible entitlement XML outside the signature cannot grant access.
        try (header + Data(repeating: 0, count: 16) + der(valid)).write(to: url)
        XCTAssertFalse(SignedCloudKitEntitlements.allowsCloudKit(executableURL: url, identifier: identifier, cpuType: 0x100000c, cpuSubtype: 0))
    }
}
