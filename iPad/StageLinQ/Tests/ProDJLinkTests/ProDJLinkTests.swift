import XCTest
@testable import ProDJLink

final class ProDJLinkTests: XCTestCase {

    /// A synthetic CDJ-3000 status packet (0x200 bytes) with the fields KDM reads.
    private func cdj3000Status(player: UInt8 = 2, note: UInt8, mode: UInt8, accidental: UInt8 = 0,
                               keyShiftCents: Int64 = 0, bpm: UInt16 = 12400, pitch: UInt32 = 0x100000,
                               flags: UInt8 = 0x40 | 0x08) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 0x200)
        b.replaceSubrange(0..<10, with: ProDJLinkPacket.magic)
        b[0x0a] = 0x0a
        b.replaceSubrange(0x0b..<0x13, with: Array("CDJ-3000".utf8))
        b[0x7b] = 0x03                   // playing
        b[0x20] = 0x06
        b[0x21] = player
        b[0x24] = player
        b[0x28] = player                 // track from this player's media
        b[0x29] = 0x03                   // USB
        b[0x2a] = 0x01                   // rekordbox
        b.replaceSubrange(0x2c..<0x30, with: [0, 0, 0x01, 0x2c])   // rekordbox id 300
        b[0x89] = flags
        b.replaceSubrange(0x8c..<0x90, with: withUnsafeBytes(of: pitch.bigEndian, Array.init))
        b.replaceSubrange(0x92..<0x94, with: withUnsafeBytes(of: bpm.bigEndian, Array.init))
        b[0x158] = 1
        b[0x15c] = note; b[0x15d] = mode; b[0x15e] = accidental
        b.replaceSubrange(0x164..<0x16c, with: withUnsafeBytes(of: keyShiftCents.bigEndian, Array.init))
        return b
    }

    // Examples from the protocol analysis (Table 7).
    func testKeyEncoding() throws {
        let csharpMinor = try XCTUnwrap(ProDJLinkPacket.parseStatus(cdj3000Status(note: 0x04, mode: 0x00, accidental: 0x01)))
        XCTAssertEqual(csharpMinor.key, CDJKey(pitchClass: 1, isMinor: true))
        let cMajor = try XCTUnwrap(ProDJLinkPacket.parseStatus(cdj3000Status(note: 0x00, mode: 0x01)))
        XCTAssertEqual(cMajor.key, CDJKey(pitchClass: 0, isMinor: false))
        let bFlatMinor = try XCTUnwrap(ProDJLinkPacket.parseStatus(cdj3000Status(note: 0x01, mode: 0x00, accidental: 0xff)))
        XCTAssertEqual(bFlatMinor.key, CDJKey(pitchClass: 10, isMinor: true))
        let aMinor = try XCTUnwrap(ProDJLinkPacket.parseStatus(cdj3000Status(note: 0x00, mode: 0x00)))
        XCTAssertEqual(aMinor.key?.description, "Am")
    }

    func testKeyShift() throws {
        // +2 semitones (0xc8 cents) on A minor -> B minor; -12 keeps the key.
        let up = try XCTUnwrap(ProDJLinkPacket.parseStatus(cdj3000Status(note: 0, mode: 0, keyShiftCents: 200)))
        XCTAssertEqual(up.keyShiftSemitones, 2)
        XCTAssertEqual(up.currentKey, CDJKey(pitchClass: 11, isMinor: true))
        let down = try XCTUnwrap(ProDJLinkPacket.parseStatus(cdj3000Status(note: 0, mode: 0, keyShiftCents: -1200)))
        XCTAssertEqual(down.keyShiftSemitones, -12)
        XCTAssertEqual(down.currentKey, CDJKey(pitchClass: 9, isMinor: true))
    }

    func testStatusFields() throws {
        // 124.00 BPM at +5 % pitch, playing, on air, not master.
        let s = try XCTUnwrap(ProDJLinkPacket.parseStatus(cdj3000Status(note: 0, mode: 1, pitch: 0x10cccc)))
        XCTAssertEqual(s.player, 2)
        XCTAssertEqual(s.name, "CDJ-3000")
        XCTAssertTrue(s.loaded)
        XCTAssertEqual(s.rekordboxID, 300)
        XCTAssertTrue(s.playing)
        XCTAssertTrue(s.onAir)
        XCTAssertFalse(s.isMaster)
        XCTAssertEqual(s.trackBPM, 124.0)
        XCTAssertEqual(s.effectiveBPM ?? 0, 130.2, accuracy: 0.05)
        XCTAssertEqual(s.masterTempo, true)
    }

    func testNoTrackAndOlderPlayer() throws {
        var b = cdj3000Status(note: 0, mode: 0, bpm: 0xffff)
        b[0x28] = 0
        b[0x7b] = 0
        let empty = try XCTUnwrap(ProDJLinkPacket.parseStatus(b))
        XCTAssertFalse(empty.loaded)
        XCTAssertNil(empty.trackBPM)
        // An older player's shorter packet has no key field.
        let old = try XCTUnwrap(ProDJLinkPacket.parseStatus(Array(cdj3000Status(note: 0, mode: 0).prefix(0x124))))
        XCTAssertNil(old.key)
    }

    func testKeepAliveLayout() {
        let mac: [UInt8] = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
        let ip: [UInt8] = [169, 254, 60, 131]
        let b = ProDJLinkPacket.keepAlive(name: "KDM", number: 7, mac: mac, ip: ip, peers: 3)
        XCTAssertEqual(b.count, 0x36)
        XCTAssertEqual(Array(b[0..<10]), ProDJLinkPacket.magic)
        XCTAssertEqual(b[0x0a], 0x06)
        XCTAssertEqual(Array(b[0x0c..<0x0f]), Array("KDM".utf8))
        XCTAssertEqual(b[0x22], 0x00); XCTAssertEqual(b[0x23], 0x36)
        XCTAssertEqual(b[0x24], 7)
        XCTAssertEqual(Array(b[0x26..<0x2c]), mac)
        XCTAssertEqual(Array(b[0x2c..<0x30]), ip)
        XCTAssertEqual(b[0x30], 3)
        XCTAssertEqual(b[0x35], 0x64)

        // And it parses back as a device announcement.
        let d = ProDJLinkPacket.parseKeepAlive(b, from: "169.254.60.131")
        XCTAssertEqual(d?.number, 7)
        XCTAssertEqual(d?.name, "KDM")
        XCTAssertEqual(d?.address, "169.254.60.131")
    }

    func testClaimPacketLengths() {
        let mac = [UInt8](repeating: 1, count: 6), ip: [UInt8] = [169, 254, 1, 2]
        XCTAssertEqual(ProDJLinkPacket.hello(name: "KDM").count, 0x26)
        XCTAssertEqual(ProDJLinkPacket.claim1(name: "KDM", mac: mac, counter: 1).count, 0x2c)
        let c2 = ProDJLinkPacket.claim2(name: "KDM", ip: ip, mac: mac, number: 7, counter: 2)
        XCTAssertEqual(c2.count, 0x32)
        XCTAssertEqual(Array(c2[0x24..<0x28]), ip)
        XCTAssertEqual(c2[0x2e], 7)
        XCTAssertEqual(c2[0x2f], 2)
        let c3 = ProDJLinkPacket.claim3(name: "KDM", number: 7, counter: 3)
        XCTAssertEqual(c3.count, 0x26)
        XCTAssertEqual(c3[0x24], 7)
    }
}
