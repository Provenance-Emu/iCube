import XCTest
@testable import PVLibrarySnapshot

final class DiscHeaderReaderTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: fixtures

    /// A 0x80-byte disc header. `wii` selects the magic word.
    private func discHeader(id: String = "GALE01", disc: UInt8 = 0, rev: UInt8 = 2,
                            title: String = "Super Smash Bros. Melee", wii: Bool = false) -> Data {
        var d = Data(count: 0x80)
        d.replaceSubrange(0..<6, with: Array(id.utf8))
        d[6] = disc
        d[7] = rev
        let magic: UInt32 = wii ? 0x5D1C9EA3 : 0xC2339F3D
        let off = wii ? 0x18 : 0x1C
        d[off] = UInt8(magic >> 24); d[off + 1] = UInt8((magic >> 16) & 0xFF)
        d[off + 2] = UInt8((magic >> 8) & 0xFF); d[off + 3] = UInt8(magic & 0xFF)
        let t = Array(title.utf8.prefix(0x60))
        d.replaceSubrange(0x20..<(0x20 + t.count), with: t)
        return d
    }

    private func write(_ data: Data, _ name: String) -> URL {
        let url = tmp.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    private func padded(_ prefix: Data, to length: Int) -> Data {
        var d = prefix
        if d.count < length { d.append(Data(count: length - d.count)) }
        return d
    }

    // MARK: parseDiscHeader

    func testParsesGameCubeHeader() {
        let h = DiscHeaderReader.parseDiscHeader(discHeader())
        XCTAssertEqual(h?.gameID, "GALE01")
        XCTAssertEqual(h?.makerCode, "01")
        XCTAssertEqual(h?.discNumber, 0)
        XCTAssertEqual(h?.revision, 2)
        XCTAssertEqual(h?.title, "Super Smash Bros. Melee")
        XCTAssertEqual(h?.platform, .gamecube)
        XCTAssertEqual(h?.regionCode, "E")
    }

    func testParsesWiiHeader() {
        let h = DiscHeaderReader.parseDiscHeader(discHeader(id: "RMGP01", title: "SUPER MARIO GALAXY", wii: true))
        XCTAssertEqual(h?.platform, .wii)
        XCTAssertEqual(h?.regionCode, "P")
    }

    func testRejectsHeaderWithoutMagic() {
        var d = discHeader()
        d.replaceSubrange(0x18..<0x20, with: Data(count: 8))
        XCTAssertNil(DiscHeaderReader.parseDiscHeader(d))
    }

    func testRejectsNonAlphanumericGameID() {
        XCTAssertNil(DiscHeaderReader.parseDiscHeader(discHeader(id: "G@LE01")))
    }

    func testRejectsShortBuffer() {
        XCTAssertNil(DiscHeaderReader.parseDiscHeader(discHeader().prefix(0x40)))
    }

    // MARK: container detection

    func testDetectsContainers() {
        XCTAssertEqual(DiscHeaderReader.container(of: Data("RVZ\u{01}".utf8)), .rvz)
        XCTAssertEqual(DiscHeaderReader.container(of: Data("WIA\u{01}".utf8)), .wia)
        XCTAssertEqual(DiscHeaderReader.container(of: Data("WBFS".utf8)), .wbfs)
        XCTAssertEqual(DiscHeaderReader.container(of: Data("CISO".utf8)), .ciso)
        XCTAssertEqual(DiscHeaderReader.container(of: Data([0x01, 0xC0, 0x0B, 0xB1])), .gcz)
        XCTAssertEqual(DiscHeaderReader.container(of: Data([0xAE, 0x0F, 0x38, 0xA2])), .tgc)
        XCTAssertEqual(DiscHeaderReader.container(of: discHeader()), .iso)
        XCTAssertEqual(DiscHeaderReader.container(of: Data([0, 0, 0, 0])), .unknown)
        XCTAssertEqual(DiscHeaderReader.container(of: Data()), .unknown)
    }

    // MARK: read(url:)

    func testReadsRawISO() {
        let url = write(padded(discHeader(), to: 0x10000), "game.iso")
        XCTAssertEqual(DiscHeaderReader.read(url: url)?.gameID, "GALE01")
    }

    func testReadsRVZ() {
        var d = Data("RVZ\u{01}".utf8)
        d.append(Data(count: 0x58 - 4))
        d.append(discHeader(id: "GM4E01", title: "Mario Kart: Double Dash!!"))
        let url = write(padded(d, to: 0x200), "game.rvz")
        let h = DiscHeaderReader.read(url: url)
        XCTAssertEqual(h?.gameID, "GM4E01")
        XCTAssertEqual(h?.title, "Mario Kart: Double Dash!!")
    }

    func testReadsWBFS() {
        var d = Data("WBFS".utf8)
        d.append(Data(count: 4))              // n_hd_sec
        d.append(0x09)                        // hd_sec_sz_s → 512-byte sectors
        d = padded(d, to: 0x200)
        d.append(discHeader(id: "RSBE01", title: "Super Smash Bros. Brawl", wii: true))
        let url = write(padded(d, to: 0x400), "game.wbfs")
        XCTAssertEqual(DiscHeaderReader.read(url: url)?.gameID, "RSBE01")
        XCTAssertEqual(DiscHeaderReader.read(url: url)?.platform, .wii)
    }

    func testReadsCISO() {
        var d = Data("CISO".utf8)
        d.append(contentsOf: [0x00, 0x00, 0x20, 0x00]) // block size (LE), irrelevant here
        d.append(0x01)                                   // block 0 present
        d = padded(d, to: 0x8000)
        d.append(discHeader(id: "GZLE01", title: "Wind Waker"))
        let url = write(padded(d, to: 0x8100), "game.ciso")
        XCTAssertEqual(DiscHeaderReader.read(url: url)?.gameID, "GZLE01")
    }

    func testCISOWithoutBlockZeroIsNil() {
        var d = Data("CISO".utf8)
        d.append(Data(count: 4))
        d.append(0x00)
        let url = write(padded(d, to: 0x8100), "game.ciso")
        XCTAssertNil(DiscHeaderReader.read(url: url))
    }

    func testUnsupportedContainersReturnNil() {
        XCTAssertNil(DiscHeaderReader.read(url: write(padded(Data([0x01, 0xC0, 0x0B, 0xB1]), to: 0x100), "game.gcz")))
        XCTAssertNil(DiscHeaderReader.read(url: write(padded(Data([0xAE, 0x0F, 0x38, 0xA2]), to: 0x100), "game.tgc")))
    }

    func testEmptyAndGarbageFilesReturnNil() {
        XCTAssertNil(DiscHeaderReader.read(url: write(Data(), "empty.iso")))
        XCTAssertNil(DiscHeaderReader.read(url: write(Data((0..<4096).map { UInt8($0 % 251) }), "garbage.iso")))
        XCTAssertNil(DiscHeaderReader.read(url: tmp.appendingPathComponent("missing.iso")))
    }

    func testTruncatedISOReturnsNil() {
        XCTAssertNil(DiscHeaderReader.read(url: write(discHeader().prefix(0x30), "short.iso")))
    }
}
