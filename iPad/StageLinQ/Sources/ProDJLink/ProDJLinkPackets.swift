import Foundation

// Pioneer DJ "Pro DJ Link" packets (CDJ-3000, DJM-A9 …), as documented by Deep
// Symmetry's protocol analysis (djl-analysis.deepsymmetry.org) and beat-link.
//
// Every packet starts with the 10-byte magic "Qspt1WmJOL", then a type byte:
//   port 50000: 0x0a hello, 0x00/0x02/0x04 number claims, 0x06 keep-alive, 0x08 defense
//   port 50002: 0x0a CDJ status, 0x29 mixer status

/// A key as a CDJ reports it: pitch class 0 = C … 11 = B.
public struct CDJKey: Equatable, Hashable, CustomStringConvertible {
    public let pitchClass: Int
    public let isMinor: Bool

    public init(pitchClass: Int, isMinor: Bool) {
        self.pitchClass = ((pitchClass % 12) + 12) % 12
        self.isMinor = isMinor
    }

    public func transposed(by semitones: Int) -> CDJKey {
        CDJKey(pitchClass: pitchClass + semitones, isMinor: isMinor)
    }

    public var description: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[pitchClass] + (isMinor ? "m" : "")
    }
}

/// A device seen on the Pro DJ Link network (from its keep-alive packets).
public struct ProDJLinkDevice: Equatable, Hashable, CustomStringConvertible {
    public enum Kind: Equatable, Hashable { case player, mixer, other(UInt8) }

    public let number: Int            // player 1…6, mixer 33, rekordbox 17+
    public let name: String           // "CDJ-3000", "DJM-A9"
    public let kind: Kind
    public let address: String        // IPv4
    public var interfaceName: String? = nil

    public var description: String {
        "\(name) #\(number) \(address)" + (interfaceName.map { " on \($0)" } ?? "")
    }
}

/// What one CDJ reports about itself (port 50002, type 0x0a).
public struct CDJStatus: Equatable {
    public let player: Int
    public var name: String
    public var trackSourcePlayer: Int     // Dr: which player's media the track is from (0 = none)
    public var trackSlot: Int             // Sr: 1 CD, 2 SD, 3 USB, 4 rekordbox, …
    public var trackType: Int             // Tr: 1 rekordbox, 2 unanalysed, 5 CD, 6 streaming
    public var rekordboxID: UInt32
    public var playing: Bool
    public var isMaster: Bool
    public var sync: Bool
    public var onAir: Bool                // only meaningful with a mixer that reports on-air
    public var trackBPM: Double?          // the track's own tempo
    public var pitch: Double              // 1.0 = 0 %
    /// The key as the track is playing (tempo and master tempo applied), before
    /// key shift. CDJ-3000 only; nil on older players.
    public var key: CDJKey?
    public var keyShiftSemitones: Int
    public var masterTempo: Bool?

    public var loaded: Bool { trackSourcePlayer != 0 && rekordboxID != 0 }
    public var effectiveBPM: Double? { trackBPM.map { $0 * pitch } }
    /// What you hear: the key with key shift applied.
    public var currentKey: CDJKey? { key?.transposed(by: keyShiftSemitones) }
}

public enum ProDJLinkPacket {
    public static let magic: [UInt8] = [0x51, 0x73, 0x70, 0x74, 0x31, 0x57, 0x6d, 0x4a, 0x4f, 0x4c]
    public static let announcePort: UInt16 = 50000
    public static let beatPort: UInt16 = 50001
    public static let statusPort: UInt16 = 50002

    static let nameOffset = 0x0c
    static let nameLength = 20

    public static func hasMagic(_ b: [UInt8]) -> Bool {
        b.count > 0x0b && Array(b[0..<10]) == magic
    }

    static func name(_ b: [UInt8]) -> String {
        guard b.count >= nameOffset + nameLength else { return "" }
        let raw = b[nameOffset..<(nameOffset + nameLength)].prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }

    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    static func i64(_ b: [UInt8], _ o: Int) -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(b[o + i]) }
        return Int64(bitPattern: v)
    }

    // MARK: - Parsing

    /// A keep-alive (type 0x06) from another device.
    public static func parseKeepAlive(_ b: [UInt8], from address: String) -> ProDJLinkDevice? {
        guard hasMagic(b), b[0x0a] == 0x06, b.count >= 0x30 else { return nil }
        let number = Int(b[0x24])
        let kind: ProDJLinkDevice.Kind
        switch b[0x25] {
        case 0x01: kind = .player
        case 0x02: kind = .mixer
        default:   kind = .other(b[0x25])
        }
        let ip = "\(b[0x2c]).\(b[0x2d]).\(b[0x2e]).\(b[0x2f])"
        return ProDJLinkDevice(number: number, name: name(b), kind: kind, address: ip == "0.0.0.0" ? address : ip)
    }

    /// A device-number defense (type 0x08): someone already uses `number`.
    public static func parseDefense(_ b: [UInt8]) -> Int? {
        guard hasMagic(b), b[0x0a] == 0x08, b.count > 0x24 else { return nil }
        return Int(b[0x24])
    }

    /// A CDJ status packet (port 50002, type 0x0a).
    public static func parseStatus(_ b: [UInt8]) -> CDJStatus? {
        guard hasMagic(b), b[0x0a] == 0x0a, b.count >= 0xa0 else { return nil }
        let flags = b[0x89]
        let rawBPM = u16(b, 0x92)
        let rawPitch = u32(b, 0x8c)

        var key: CDJKey? = nil
        var shift = 0
        var masterTempo: Bool? = nil
        if b.count >= 0x16c {
            // CDJ-3000: note (0x15c) and mode (0x15d: 0 minor, 1 major). Minor
            // notes count from A (00 = Am … 0b = G#m), major from C.
            let note = Int(b[0x15c]), mode = b[0x15d]
            if note < 12 && (mode == 0 || mode == 1) {
                key = mode == 0 ? CDJKey(pitchClass: 9 + note, isMinor: true) : CDJKey(pitchClass: note, isMinor: false)
            }
            masterTempo = b[0x158] == 1
            let cents = i64(b, 0x164)
            if abs(cents) < 100 * 48 { shift = Int((Double(cents) / 100).rounded()) }
        }

        return CDJStatus(
            player: Int(b[0x21]),
            name: name(b),
            trackSourcePlayer: Int(b[0x28]),
            trackSlot: Int(b[0x29]),
            trackType: Int(b[0x2a]),
            rekordboxID: u32(b, 0x2c),
            playing: flags & 0x40 != 0,
            isMaster: flags & 0x20 != 0,
            sync: flags & 0x10 != 0,
            onAir: flags & 0x08 != 0,
            trackBPM: rawBPM == 0xffff || rawBPM == 0 ? nil : Double(rawBPM) / 100,
            pitch: rawPitch == 0 ? 1 : Double(rawPitch) / Double(0x100000),
            key: key,
            keyShiftSemitones: shift,
            masterTempo: masterTempo
        )
    }

    // MARK: - Building (what a "virtual CDJ" sends to join the network)
    //
    // Byte templates follow beat-link's VirtualCdj (Deep Symmetry).

    static func header(type: UInt8, sub: UInt8 = 0x00, name: String) -> [UInt8] {
        var b = magic + [type, sub]
        var n = Array(name.utf8.prefix(nameLength))
        n += [UInt8](repeating: 0, count: nameLength - n.count)
        b += n
        return b
    }

    /// "Coming online", sent 3 times.
    public static func hello(name: String) -> [UInt8] {
        header(type: 0x0a, name: name) + [0x01, 0x04, 0x00, 0x26, 0x01, 0x40]
    }

    /// Claim stage 1 (counter 1…3).
    public static func claim1(name: String, mac: [UInt8], counter: UInt8) -> [UInt8] {
        var b = header(type: 0x00, name: name) + [0x01, 0x03, 0x00, 0x2c, counter, 0x01]
        b += mac.prefix(6) + [UInt8](repeating: 0, count: max(0, 6 - mac.count))
        return b
    }

    /// Claim stage 2: our IP, MAC and the number we want (counter 1…3).
    public static func claim2(name: String, ip: [UInt8], mac: [UInt8], number: UInt8, counter: UInt8) -> [UInt8] {
        var b = header(type: 0x02, name: name) + [0x01, 0x03, 0x00, 0x32]
        b += ip.prefix(4)
        b += mac.prefix(6) + [UInt8](repeating: 0, count: max(0, 6 - mac.count))
        b += [number, counter, 0x01, 0x02]     // 0x31: 2 = we chose this number ourselves
        return b
    }

    /// Claim stage 3 (final): the number (counter 1…3).
    public static func claim3(name: String, number: UInt8, counter: UInt8) -> [UInt8] {
        header(type: 0x04, name: name) + [0x01, 0x03, 0x00, 0x26, number, counter]
    }

    /// Keep-alive, every ~1.5 s once the number is ours. 54 bytes; byte 0x35 is
    /// 0x64 like a CDJ-3000 (players numbered 5 and 6 drop off otherwise).
    public static func keepAlive(name: String, number: UInt8, mac: [UInt8], ip: [UInt8], peers: UInt8 = 1) -> [UInt8] {
        var b = header(type: 0x06, name: name) + [0x01, 0x02, 0x00, 0x36, number, 0x01]
        b += mac.prefix(6) + [UInt8](repeating: 0, count: max(0, 6 - mac.count))
        b += ip.prefix(4)
        b += [max(1, peers), 0x00, 0x00, 0x00, 0x01, 0x64]
        return b
    }
}
