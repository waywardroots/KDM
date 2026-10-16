import XCTest
@testable import StageLinQ

/// Byte fixtures are captures published with icedream/go-stagelinq (MIT),
/// recorded from Denon Prime hardware.
final class CodecTests: XCTestCase {

    let primeToken = Token([0xf4, 0x05, 0xdc, 0x14, 0x02, 0x23, 0x47, 0xf5, 0x8b, 0x79, 0x2c, 0x8c, 0x49, 0x33, 0x52, 0x76])

    let discoveryBytes: [UInt8] = [
        0x61, 0x69, 0x72, 0x44, 0xf4, 0x05, 0xdc, 0x14, 0x02, 0x23, 0x47, 0xf5, 0x8b, 0x79, 0x2c, 0x8c,
        0x49, 0x33, 0x52, 0x76, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x70, 0x00, 0x72, 0x00, 0x69, 0x00, 0x6d,
        0x00, 0x65, 0x00, 0x34, 0x00, 0x00, 0x00, 0x22, 0x00, 0x44, 0x00, 0x49, 0x00, 0x53, 0x00, 0x43,
        0x00, 0x4f, 0x00, 0x56, 0x00, 0x45, 0x00, 0x52, 0x00, 0x45, 0x00, 0x52, 0x00, 0x5f, 0x00, 0x48,
        0x00, 0x4f, 0x00, 0x57, 0x00, 0x44, 0x00, 0x59, 0x00, 0x5f, 0x00, 0x00, 0x00, 0x08, 0x00, 0x4a,
        0x00, 0x43, 0x00, 0x31, 0x00, 0x31, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x31, 0x00, 0x2e, 0x00, 0x35,
        0x00, 0x2e, 0x00, 0x32, 0x84, 0x03,
    ]

    func testDiscoveryDecodeAndEncode() throws {
        let m = try DiscoveryMessage.decode(discoveryBytes)
        XCTAssertEqual(m.token, primeToken)
        XCTAssertEqual(m.source, "prime4")
        XCTAssertEqual(m.action, .howdy)
        XCTAssertEqual(m.softwareName, "JC11")
        XCTAssertEqual(m.softwareVersion, "1.5.2")
        XCTAssertEqual(m.port, 0x8403)
        XCTAssertEqual(m.encoded(), discoveryBytes)
    }

    func testDiscoveryRejectsOtherTraffic() {
        XCTAssertThrowsError(try DiscoveryMessage.decode(Array("hello".utf8)))
        XCTAssertThrowsError(try DiscoveryMessage.decode(Array(discoveryBytes.prefix(30))))
    }

    let serviceAnnouncementBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x52, 0x3e, 0x67, 0x9d, 0xa4, 0x18, 0x4d, 0x1e, 0x83, 0xd0, 0xc7, 0x52,
        0xcf, 0xca, 0x8f, 0xf7, 0x00, 0x00, 0x00, 0x10, 0x00, 0x53, 0x00, 0x74, 0x00, 0x61, 0x00, 0x74,
        0x00, 0x65, 0x00, 0x4d, 0x00, 0x61, 0x00, 0x70, 0xe1, 0x96,
    ]
    let servicesRequestBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x02, 0xf4, 0x05, 0xdc, 0x14, 0x02, 0x23, 0x47, 0xf5, 0x8b, 0x79, 0x2c, 0x8c,
        0x49, 0x33, 0x52, 0x76,
    ]
    let referenceBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xf4, 0x05, 0xdc, 0x14, 0x02, 0x23, 0x47, 0xf5, 0x8b, 0x79, 0x2c, 0x8c,
        0x49, 0x33, 0x52, 0x76, 0x00, 0x00, 0x09, 0xed, 0x4f, 0x31, 0x06, 0x04,
    ]

    func testMainMessages() throws {
        var buf = serviceAnnouncementBytes
        let svcToken = Token([0x52, 0x3e, 0x67, 0x9d, 0xa4, 0x18, 0x4d, 0x1e, 0x83, 0xd0, 0xc7, 0x52, 0xcf, 0xca, 0x8f, 0xf7])
        XCTAssertEqual(try MainMessage.decode(from: &buf), .serviceAnnouncement(token: svcToken, service: "StateMap", port: 0xe196))
        XCTAssertTrue(buf.isEmpty)

        buf = servicesRequestBytes
        XCTAssertEqual(try MainMessage.decode(from: &buf), .servicesRequest(token: primeToken))

        buf = referenceBytes
        XCTAssertEqual(try MainMessage.decode(from: &buf), .reference(token: .zero, token2: primeToken, reference: 0x000009ed4f310604))

        XCTAssertEqual(MainMessage.serviceAnnouncement(token: svcToken, service: "StateMap", port: 0xe196).encoded(), serviceAnnouncementBytes)
        XCTAssertEqual(MainMessage.servicesRequest(token: primeToken).encoded(), servicesRequestBytes)
        XCTAssertEqual(MainMessage.reference(token: .zero, token2: primeToken, reference: 0x000009ed4f310604).encoded(), referenceBytes)
    }

    func testMainStreamFraming() throws {
        // Two messages arriving in pieces.
        let stream = serviceAnnouncementBytes + servicesRequestBytes
        var buf = Array(stream.prefix(10))
        XCTAssertNil(try MainMessage.decode(from: &buf))       // not enough yet
        XCTAssertEqual(buf.count, 10)                          // nothing consumed
        buf += stream.dropFirst(10)
        XCTAssertNotNil(try MainMessage.decode(from: &buf))
        XCTAssertEqual(try MainMessage.decode(from: &buf), .servicesRequest(token: primeToken))
        XCTAssertNil(try MainMessage.decode(from: &buf))
        XCTAssertTrue(buf.isEmpty)
    }

    let subscribeBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x44, 0x73, 0x6d, 0x61, 0x61, 0x00, 0x00, 0x07, 0xd2, 0x00, 0x00, 0x00, 0x34,
        0x00, 0x2f, 0x00, 0x43, 0x00, 0x6c, 0x00, 0x69, 0x00, 0x65, 0x00, 0x6e, 0x00, 0x74, 0x00, 0x2f,
        0x00, 0x50, 0x00, 0x72, 0x00, 0x65, 0x00, 0x66, 0x00, 0x65, 0x00, 0x72, 0x00, 0x65, 0x00, 0x6e,
        0x00, 0x63, 0x00, 0x65, 0x00, 0x73, 0x00, 0x2f, 0x00, 0x50, 0x00, 0x6c, 0x00, 0x61, 0x00, 0x79,
        0x00, 0x65, 0x00, 0x72, 0x00, 0x00, 0x00, 0x00,
    ]
    let emitBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x72, 0x73, 0x6d, 0x61, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x34,
        0x00, 0x2f, 0x00, 0x43, 0x00, 0x6c, 0x00, 0x69, 0x00, 0x65, 0x00, 0x6e, 0x00, 0x74, 0x00, 0x2f,
        0x00, 0x50, 0x00, 0x72, 0x00, 0x65, 0x00, 0x66, 0x00, 0x65, 0x00, 0x72, 0x00, 0x65, 0x00, 0x6e,
        0x00, 0x63, 0x00, 0x65, 0x00, 0x73, 0x00, 0x2f, 0x00, 0x50, 0x00, 0x6c, 0x00, 0x61, 0x00, 0x79,
        0x00, 0x65, 0x00, 0x72, 0x00, 0x00, 0x00, 0x2e, 0x00, 0x7b, 0x00, 0x22, 0x00, 0x73, 0x00, 0x74,
        0x00, 0x72, 0x00, 0x69, 0x00, 0x6e, 0x00, 0x67, 0x00, 0x22, 0x00, 0x3a, 0x00, 0x22, 0x00, 0x31,
        0x00, 0x22, 0x00, 0x2c, 0x00, 0x22, 0x00, 0x74, 0x00, 0x79, 0x00, 0x70, 0x00, 0x65, 0x00, 0x22,
        0x00, 0x3a, 0x00, 0x34, 0x00, 0x7d,
    ]
    let subscribeResponseBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x44, 0x73, 0x6d, 0x61, 0x61, 0x00, 0x00, 0x07, 0xd1, 0x00, 0x00, 0x00, 0x34,
        0x00, 0x2f, 0x00, 0x43, 0x00, 0x6c, 0x00, 0x69, 0x00, 0x65, 0x00, 0x6e, 0x00, 0x74, 0x00, 0x2f,
        0x00, 0x50, 0x00, 0x72, 0x00, 0x65, 0x00, 0x66, 0x00, 0x65, 0x00, 0x72, 0x00, 0x65, 0x00, 0x6e,
        0x00, 0x63, 0x00, 0x65, 0x00, 0x73, 0x00, 0x2f, 0x00, 0x50, 0x00, 0x6c, 0x00, 0x61, 0x00, 0x79,
        0x00, 0x65, 0x00, 0x72, 0xff, 0xff, 0xff, 0xff,
    ]

    func testStateMapMessages() throws {
        XCTAssertEqual(StateMapMessage.subscribe(name: "/Client/Preferences/Player", interval: 0).encoded(), subscribeBytes)

        var buf = emitBytes + subscribeResponseBytes
        XCTAssertEqual(try StateMapMessage.decode(from: &buf), .emit(name: "/Client/Preferences/Player", json: #"{"string":"1","type":4}"#))
        XCTAssertEqual(try StateMapMessage.decode(from: &buf), .subscribeResponse(name: "/Client/Preferences/Player", interval: 0xffffffff))
        XCTAssertTrue(buf.isEmpty)
    }

    func testStateMapPartialFrameWaits() throws {
        var buf = Array(emitBytes.prefix(50))
        XCTAssertNil(try StateMapMessage.decode(from: &buf))
        XCTAssertEqual(buf.count, 50)
        buf += emitBytes.dropFirst(50)
        XCTAssertNotNil(try StateMapMessage.decode(from: &buf))
    }

    func testStateValues() {
        XCTAssertEqual(StateValue(json: #"{"string":"8A","type":8}"#), .string("8A"))
        XCTAssertEqual(StateValue(json: #"{"type":0,"value":124.5}"#), .number(124.5))
        XCTAssertEqual(StateValue(json: #"{"state":true,"type":1}"#), .bool(true))
        XCTAssertEqual(StateValue(json: #"{"state":false,"type":2}"#).bool, false)
        XCTAssertEqual(StateValue(json: "not json"), .other("not json"))
        XCTAssertEqual(StateValue(json: #"{"value":0.75}"#).number, 0.75)
    }

    func testTokens() {
        for _ in 0..<100 { XCTAssertEqual(Token.random().bytes[0] & 0x80, 0) }
    }
}

final class KeyParsingTests: XCTestCase {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    func testCamelotRoundTripAllKeys() {
        for pc in 0..<12 {
            for minor in [false, true] {
                let k = MusicalKey(pitchClass: pc, isMinor: minor)
                XCTAssertEqual(MusicalKey(parsing: k.camelot), k, k.camelot)
            }
        }
    }

    func testCamelot() {
        XCTAssertEqual(MusicalKey(parsing: "8B"), MusicalKey(pitchClass: 0, isMinor: false))   // C major
        XCTAssertEqual(MusicalKey(parsing: "8A"), MusicalKey(pitchClass: 9, isMinor: true))    // A minor
        XCTAssertEqual(MusicalKey(parsing: "12B"), MusicalKey(pitchClass: 4, isMinor: false))  // E major
        XCTAssertEqual(MusicalKey(parsing: "1a"), MusicalKey(pitchClass: 8, isMinor: true))    // G# minor
        XCTAssertNil(MusicalKey(parsing: "13A"))
        XCTAssertNil(MusicalKey(parsing: "0B"))
    }

    func testOpenKey() {
        XCTAssertEqual(MusicalKey(parsing: "1d"), MusicalKey(pitchClass: 0, isMinor: false))   // C major
        XCTAssertEqual(MusicalKey(parsing: "1m"), MusicalKey(pitchClass: 9, isMinor: true))    // A minor
        XCTAssertEqual(MusicalKey(parsing: "12d"), MusicalKey(pitchClass: 5, isMinor: false))  // F major
        XCTAssertEqual(MusicalKey(parsing: "4m"), MusicalKey(pitchClass: 6, isMinor: true))    // F# minor
        XCTAssertEqual(MusicalKey(parsing: "6m"), MusicalKey(pitchClass: 8, isMinor: true))    // G# minor
    }

    func testMusicalNames() {
        XCTAssertEqual(MusicalKey(parsing: "Am"), MusicalKey(pitchClass: 9, isMinor: true))
        XCTAssertEqual(MusicalKey(parsing: "A min"), MusicalKey(pitchClass: 9, isMinor: true))
        XCTAssertEqual(MusicalKey(parsing: "A minor"), MusicalKey(pitchClass: 9, isMinor: true))
        XCTAssertEqual(MusicalKey(parsing: "F#m"), MusicalKey(pitchClass: 6, isMinor: true))
        XCTAssertEqual(MusicalKey(parsing: "Bb"), MusicalKey(pitchClass: 10, isMinor: false))
        XCTAssertEqual(MusicalKey(parsing: "Ebm"), MusicalKey(pitchClass: 3, isMinor: true))
        XCTAssertEqual(MusicalKey(parsing: "D♭"), MusicalKey(pitchClass: 1, isMinor: false))
        XCTAssertEqual(MusicalKey(parsing: "C# major"), MusicalKey(pitchClass: 1, isMinor: false))
        XCTAssertEqual(MusicalKey(parsing: "Cb"), MusicalKey(pitchClass: 11, isMinor: false))
        XCTAssertEqual(MusicalKey(parsing: "bm"), MusicalKey(pitchClass: 11, isMinor: true))
        XCTAssertNil(MusicalKey(parsing: ""))
        XCTAssertNil(MusicalKey(parsing: "-"))
        XCTAssertNil(MusicalKey(parsing: "H"))
    }

    func testCamelotNames() {
        XCTAssertEqual(MusicalKey(pitchClass: 9, isMinor: true).camelot, "8A")
        XCTAssertEqual(MusicalKey(pitchClass: 0, isMinor: false).camelot, "8B")
        XCTAssertEqual(MusicalKey(pitchClass: 7, isMinor: false).camelot, "9B")
        XCTAssertEqual(MusicalKey(pitchClass: 9, isMinor: true).name, "A minor")
    }
}
