import Foundation

// StageLinQ wire format (reverse-engineered; see README.md for sources).
// Everything is big-endian. Strings are a UInt32 byte count followed by UTF-16BE.

/// A 16-byte device identifier. Ours is random with the top bit cleared:
/// devices ignore service requests whose token has the top bit set.
public struct Token: Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count == 16, "a StageLinQ token is 16 bytes")
        self.bytes = bytes
    }

    public static func random() -> Token {
        var b = (0..<16).map { _ in UInt8.random(in: 0...255) }
        b[0] &= 0x7F
        return Token(b)
    }

    /// The token the Now Playing / SoundSwitch apps announce with.
    public static let nowPlaying = Token([82, 253, 252, 7, 33, 130, 101, 79, 22, 63, 95, 15, 154, 98, 29, 114])

    public static let zero = Token([UInt8](repeating: 0, count: 16))

    public var description: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

public enum CodecError: Error, Equatable {
    case invalid(String)
}

// MARK: - Byte reading / writing

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((v >> UInt64(s)) & 0xFF)) } }
    mutating func raw(_ b: [UInt8]) { bytes += b }
    mutating func token(_ t: Token) { bytes += t.bytes }

    /// UInt32 byte count + UTF-16BE.
    mutating func string(_ s: String) {
        let units = Array(s.utf16)
        u32(UInt32(units.count * 2))
        for u in units { u16(u) }
    }
}

/// Reads from a byte array. Running out of bytes throws `Incomplete`, which
/// the stream decoders turn into "wait for more data".
struct ByteReader {
    struct Incomplete: Error {}

    let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, remaining >= n else { throw Incomplete() }
        defer { offset += n }
        return bytes[offset..<offset + n]
    }

    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
    }

    mutating func u32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() throws -> UInt64 {
        try take(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func token() throws -> Token { Token(Array(try take(16))) }

    /// UInt32 byte count + UTF-16BE. `maxBytes` guards against garbage lengths.
    mutating func string(maxBytes: Int = 1 << 20) throws -> String {
        let n = Int(try u32())
        guard n % 2 == 0, n <= maxBytes else { throw CodecError.invalid("bad string length \(n)") }
        let b = try take(n)
        var units: [UInt16] = []
        units.reserveCapacity(n / 2)
        var i = b.startIndex
        while i < b.endIndex {
            units.append(UInt16(b[i]) << 8 | UInt16(b[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}

// MARK: - Discovery (UDP 51337)

public struct DiscoveryMessage: Equatable {
    public enum Action: Equatable {
        case howdy      // "DISCOVERER_HOWDY_": present
        case exit       // "DISCOVERER_EXIT_": leaving
        case other(String)

        var wireValue: String {
            switch self {
            case .howdy: return "DISCOVERER_HOWDY_"
            case .exit: return "DISCOVERER_EXIT_"
            case .other(let s): return s
            }
        }

        init(wireValue: String) {
            switch wireValue {
            case "DISCOVERER_HOWDY_": self = .howdy
            case "DISCOVERER_EXIT_": self = .exit
            default: self = .other(wireValue)
            }
        }
    }

    public static let magic: [UInt8] = Array("airD".utf8)

    public var token: Token
    public var source: String            // device name, e.g. "sc6000"
    public var action: Action
    public var softwareName: String      // e.g. "SC6000", "JC11", "OfflineAnalyzer"
    public var softwareVersion: String
    public var port: UInt16              // TCP port of the device's main connection

    public init(token: Token, source: String, action: Action, softwareName: String, softwareVersion: String, port: UInt16) {
        self.token = token
        self.source = source
        self.action = action
        self.softwareName = softwareName
        self.softwareVersion = softwareVersion
        self.port = port
    }

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        w.raw(Self.magic)
        w.token(token)
        w.string(source)
        w.string(action.wireValue)
        w.string(softwareName)
        w.string(softwareVersion)
        w.u16(port)
        return w.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> DiscoveryMessage {
        var r = ByteReader(bytes)
        do {
            guard Array(try r.take(4)) == magic else { throw CodecError.invalid("not a discovery message") }
            let token = try r.token()
            let source = try r.string(maxBytes: 1024)
            let action = Action(wireValue: try r.string(maxBytes: 1024))
            let name = try r.string(maxBytes: 1024)
            let version = try r.string(maxBytes: 1024)
            let port = try r.u16()
            return DiscoveryMessage(token: token, source: source, action: action,
                                    softwareName: name, softwareVersion: version, port: port)
        } catch is ByteReader.Incomplete {
            throw CodecError.invalid("truncated discovery message")
        }
    }
}

// MARK: - Main connection (device's announced TCP port)

public enum MainMessage: Equatable {
    /// 0x0: a service the device offers and its TCP port.
    case serviceAnnouncement(token: Token, service: String, port: UInt16)
    /// 0x1: timestamp / keep-alive.
    case reference(token: Token, token2: Token, reference: UInt64)
    /// 0x2: request for the other side's services.
    case servicesRequest(token: Token)

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case let .serviceAnnouncement(token, service, port):
            w.u32(0); w.token(token); w.string(service); w.u16(port)
        case let .reference(token, token2, reference):
            w.u32(1); w.token(token); w.token(token2); w.u64(reference)
        case let .servicesRequest(token):
            w.u32(2); w.token(token)
        }
        return w.bytes
    }

    /// Decodes one message from the front of `buffer` and removes it.
    /// Returns nil when the buffer holds only part of a message (wait for more).
    public static func decode(from buffer: inout [UInt8]) throws -> MainMessage? {
        var r = ByteReader(buffer)
        let message: MainMessage
        do {
            let id = try r.u32()
            let token = try r.token()
            switch id {
            case 0:
                let service = try r.string(maxBytes: 1024)
                message = .serviceAnnouncement(token: token, service: service, port: try r.u16())
            case 1:
                let token2 = try r.token()
                message = .reference(token: token, token2: token2, reference: try r.u64())
            case 2:
                message = .servicesRequest(token: token)
            default:
                throw CodecError.invalid("unknown main message id \(id)")
            }
        } catch is ByteReader.Incomplete {
            return nil
        }
        buffer.removeFirst(r.offset)
        return message
    }
}

// MARK: - StateMap service

/// StateMap frames: UInt32 length, then "smaa", a UInt32 type and the payload.
public enum StateMapMessage: Equatable {
    /// 0x000: a state value, as JSON (e.g. {"string":"8A","type":8}).
    case emit(name: String, json: String)
    /// 0x7d1: the device confirming a subscription.
    case subscribeResponse(name: String, interval: UInt32)
    /// 0x7d2: subscribe to a state path (we send these).
    case subscribe(name: String, interval: UInt32)
    /// Anything else (kept so the stream stays in sync).
    case unknown(type: UInt32)

    static let magic: [UInt8] = Array("smaa".utf8)

    public func encoded() -> [UInt8] {
        var body = ByteWriter()
        body.raw(Self.magic)
        switch self {
        case let .emit(name, json):
            body.u32(0); body.string(name); body.string(json)
        case let .subscribeResponse(name, interval):
            body.u32(0x7d1); body.string(name); body.u32(interval)
        case let .subscribe(name, interval):
            body.u32(0x7d2); body.string(name); body.u32(interval)
        case let .unknown(type):
            body.u32(type)
        }
        var w = ByteWriter()
        w.u32(UInt32(body.bytes.count))
        w.raw(body.bytes)
        return w.bytes
    }

    /// The bytes the StateMap connection must start with: our token, the service
    /// name and our local TCP port.
    public static func hello(token: Token, localPort: UInt16) -> [UInt8] {
        MainMessage.serviceAnnouncement(token: token, service: "StateMap", port: localPort).encoded()
    }

    /// Decodes one frame from the front of `buffer` and removes it.
    /// Returns nil when the buffer holds only part of a frame.
    public static func decode(from buffer: inout [UInt8]) throws -> StateMapMessage? {
        // 1. Is a whole frame here yet?
        var r = ByteReader(buffer)
        let frame: [UInt8]
        do {
            let length = Int(try r.u32())
            guard length >= 8, length <= 4 << 20 else { throw CodecError.invalid("bad StateMap frame length \(length)") }
            frame = Array(try r.take(length))
        } catch is ByteReader.Incomplete {
            return nil
        }

        // 2. Parse it. Running short inside a complete frame means it's malformed.
        var f = ByteReader(frame)
        let message: StateMapMessage
        do {
            guard Array(try f.take(4)) == magic else { throw CodecError.invalid("missing smaa marker") }
            let type = try f.u32()
            switch type {
            case 0:
                let name = try f.string()
                message = .emit(name: name, json: try f.string())
            case 0x7d1:
                let name = try f.string()
                message = .subscribeResponse(name: name, interval: try f.u32())
            case 0x7d2:
                let name = try f.string()
                message = .subscribe(name: name, interval: try f.u32())
            default:
                message = .unknown(type: type)
            }
        } catch is ByteReader.Incomplete {
            buffer.removeFirst(r.offset)   // skip the bad frame, keep the stream in sync
            throw CodecError.invalid("StateMap frame shorter than its contents")
        }
        buffer.removeFirst(r.offset)
        return message
    }
}
