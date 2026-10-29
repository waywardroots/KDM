#if canImport(Darwin)
import Darwin
import Foundation

/// Track title and artist from a Pioneer player's rekordbox database
/// ("dbserver", TCP), as described by Deep Symmetry's protocol analysis and
/// beat-link's dbserver client.
///
/// 1. Ask TCP 12523 for the database port ("RemoteDBServer").
/// 2. Greeting (number 1), setup (posing as a player number).
/// 3. Metadata request for a rekordbox id → "menu available" (n items).
/// 4. Render the menu → header, n items (title is type 0x04, artist 0x07), footer.
public struct TrackMetadata: Equatable {
    public var title: String?
    public var artist: String?
    /// The key as rekordbox shows it ("Am", "8A" …), for players that don't
    /// report the key themselves (CDJ-2000NXS2 and older).
    public var key: String?
}

public enum DBServer {

    // MARK: - Fields and messages

    public enum Field: Equatable {
        case number(UInt32, size: Int)    // 1, 2 or 4 bytes
        case binary([UInt8])
        case string(String)

        var argumentTag: UInt8 {
            switch self {
            case .number: return 0x06
            case .binary: return 0x03
            case .string: return 0x02
            }
        }

        public var number: UInt32? { if case let .number(v, _) = self { return v }; return nil }
        public var string: String? { if case let .string(s) = self { return s }; return nil }

        func encoded() -> [UInt8] {
            switch self {
            case let .number(v, size):
                switch size {
                case 1: return [0x0f, UInt8(v & 0xff)]
                case 2: return [0x10, UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
                default: return [0x11] + be32(v)
                }
            case let .binary(b):
                return [0x14] + be32(UInt32(b.count)) + b
            case let .string(s):
                let units = Array((s + "\u{0}").utf16)
                var out: [UInt8] = [0x26] + be32(UInt32(units.count))
                for u in units { out += [UInt8(u >> 8), UInt8(u & 0xff)] }
                return out
            }
        }
    }

    public struct Message: Equatable {
        public static let start: UInt32 = 0x872349ae
        public var transaction: UInt32
        public var type: UInt16
        public var arguments: [Field]

        public func encoded() -> [UInt8] {
            var tags = [UInt8](repeating: 0, count: 12)
            for (i, a) in arguments.prefix(12).enumerated() { tags[i] = a.argumentTag }
            var out = Field.number(Self.start, size: 4).encoded()
            out += Field.number(transaction, size: 4).encoded()
            out += Field.number(UInt32(type), size: 2).encoded()
            out += Field.number(UInt32(arguments.count), size: 1).encoded()
            out += Field.binary(tags).encoded()
            for a in arguments { out += a.encoded() }
            return out
        }
    }

    // Message types.
    static let setupRequest: UInt16 = 0x0000
    static let teardownRequest: UInt16 = 0x0100
    static let rekordboxMetadataRequest: UInt16 = 0x2002
    static let unanalyzedMetadataRequest: UInt16 = 0x2202
    static let renderMenuRequest: UInt16 = 0x3000
    static let menuAvailable: UInt16 = 0x4000
    static let menuItem: UInt16 = 0x4101
    static let menuFooter: UInt16 = 0x4201

    // Menu item types.
    static let itemTitle: UInt32 = 0x0004
    static let itemArtist: UInt32 = 0x0007
    static let itemKey: UInt32 = 0x000f

    /// r:m:s:t — requesting player, menu (1 = main), slot, track type.
    static func rmst(player: Int, slot: Int, trackType: Int) -> Field {
        .number(UInt32(player & 0xff) << 24 | 1 << 16 | UInt32(slot & 0xff) << 8 | UInt32(trackType & 0xff), size: 4)
    }

    // MARK: - Reading

    /// Reads fields and messages from a byte source (a socket, or test data).
    struct Reader {
        let read: (Int) throws -> [UInt8]

        func field() throws -> Field {
            let tag = try read(1)[0]
            switch tag {
            case 0x0f: return .number(UInt32(try read(1)[0]), size: 1)
            case 0x10: let b = try read(2); return .number(UInt32(b[0]) << 8 | UInt32(b[1]), size: 2)
            case 0x11: return .number(u32(try read(4)), size: 4)
            case 0x14:
                let n = Int(u32(try read(4)))
                guard n <= 1 << 20 else { throw DBServerError.protocolError("binary field too long") }
                return .binary(n == 0 ? [] : try read(n))
            case 0x26:
                let chars = Int(u32(try read(4)))
                guard chars <= 1 << 16 else { throw DBServerError.protocolError("string too long") }
                let b = chars == 0 ? [] : try read(chars * 2)
                var units: [UInt16] = []
                for i in stride(from: 0, to: b.count - 1, by: 2) { units.append(UInt16(b[i]) << 8 | UInt16(b[i + 1])) }
                if units.last == 0 { units.removeLast() }
                return .string(String(decoding: units, as: UTF16.self))
            default:
                throw DBServerError.protocolError(String(format: "unknown field type 0x%02x", tag))
            }
        }

        func message() throws -> Message {
            guard case let .number(start, 4) = try field(), start == Message.start else {
                throw DBServerError.protocolError("message doesn't start with 872349ae")
            }
            guard case let .number(tx, 4) = try field(),
                  case let .number(type, 2) = try field(),
                  case let .number(argc, 1) = try field(), argc <= 12,
                  case let .binary(tags) = try field() else {
                throw DBServerError.protocolError("bad message header")
            }
            var args: [Field] = []
            for i in 0..<Int(argc) {
                // A binary argument right after a zero length isn't sent at all.
                if i < tags.count, tags[i] == 0x03, case .number(0, _)? = args.last {
                    args.append(.binary([]))
                } else {
                    args.append(try field())
                }
            }
            return Message(transaction: tx, type: UInt16(type), arguments: args)
        }
    }

    /// Title and artist from the items of a rendered metadata menu.
    static func metadata(from items: [Message]) -> TrackMetadata {
        var m = TrackMetadata()
        for item in items where item.type == menuItem && item.arguments.count > 6 {
            let kind = (item.arguments[6].number ?? 0) & 0xffff
            let label = item.arguments[3].string?.trimmingCharacters(in: .whitespaces)
            guard let label, !label.isEmpty else { continue }
            if kind == itemTitle { m.title = label }
            if kind == itemArtist { m.artist = label }
            if kind == itemKey { m.key = label }
        }
        return m
    }

    // MARK: - Query (blocking; call off the main thread)

    /// Title and artist for a track on `host`'s media. `posingAs` is the player
    /// number to ask as (the target player's own number works when our virtual
    /// CDJ is numbered above 4, as beat-link does).
    public static func fetchMetadata(host: String, interfaceIndex: UInt32?, localAddress: in_addr_t?,
                                     posingAs: Int, slot: Int, trackType: Int, rekordboxID: UInt32) throws -> TrackMetadata {
        // 1. Which port is the database on?
        let query = try Socket.connect(host: host, port: 12523, interfaceIndex: interfaceIndex, localAddress: localAddress)
        try query.write([0x00, 0x00, 0x00, 0x0f] + Array("RemoteDBServer".utf8) + [0x00])
        let portBytes = try query.read(2)
        query.close()
        let port = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
        guard port != 0 && port != 0xffff else { throw DBServerError.notReady }

        // 2. Greeting and setup.
        let s = try Socket.connect(host: host, port: port, interfaceIndex: interfaceIndex, localAddress: localAddress)
        defer { s.close() }
        let reader = Reader(read: s.read)
        try s.write(Field.number(1, size: 4).encoded())
        guard case .number(1, _) = try reader.field() else { throw DBServerError.protocolError("no greeting") }
        try s.write(Message(transaction: 0xfffffffe, type: setupRequest, arguments: [.number(UInt32(posingAs), size: 4)]).encoded())
        guard try reader.message().type == menuAvailable else { throw DBServerError.protocolError("setup refused") }

        // 3. Ask for the track's metadata menu.
        let requestType = trackType == 1 ? rekordboxMetadataRequest : unanalyzedMetadataRequest
        let r = rmst(player: posingAs, slot: slot, trackType: trackType)
        try s.write(Message(transaction: 1, type: requestType, arguments: [r, .number(rekordboxID, size: 4)]).encoded())
        let available = try reader.message()
        guard available.type == menuAvailable, available.arguments.count >= 2,
              let count = available.arguments[1].number, count != 0xffffffff, count > 0 else {
            return TrackMetadata()
        }

        // 4. Render it.
        let n = min(count, 64)
        try s.write(Message(transaction: 2, type: renderMenuRequest,
                            arguments: [r, .number(0, size: 4), .number(n, size: 4), .number(0, size: 4),
                                        .number(n, size: 4), .number(0, size: 4)]).encoded())
        var items: [Message] = []
        for _ in 0..<(Int(n) + 2) {
            let m = try reader.message()
            if m.type == menuFooter { break }
            items.append(m)
        }
        try? s.write(Message(transaction: 0xfffffffe, type: teardownRequest, arguments: []).encoded())
        return metadata(from: items)
    }

    /// A small blocking TCP socket with timeouts, bound to the DJ network interface.
    final class Socket {
        private var fd: Int32

        private init(fd: Int32) { self.fd = fd }

        static func connect(host: String, port: UInt16, interfaceIndex: UInt32?, localAddress: in_addr_t?) throws -> Socket {
            let s = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard s >= 0 else { throw DBServerError.socket(String(cString: strerror(errno))) }
            var on: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            if var index = interfaceIndex, index > 0 {
                setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            }
            if let localAddress {
                var local = sockaddr_in()
                local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                local.sin_family = sa_family_t(AF_INET)
                local.sin_addr.s_addr = localAddress
                _ = withUnsafePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { Darwin.close(s); throw DBServerError.socket("bad address \(host)") }
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard r == 0 else {
                let e = String(cString: strerror(errno))
                Darwin.close(s)
                throw DBServerError.socket("connect \(host):\(port): \(e)")
            }
            return Socket(fd: s)
        }

        func write(_ bytes: [UInt8]) throws {
            var sent = 0
            while sent < bytes.count {
                let n = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { throw DBServerError.socket("send: \(String(cString: strerror(errno)))") }
                sent += n
            }
        }

        func read(_ count: Int) throws -> [UInt8] {
            var out = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = out[got...].withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { throw DBServerError.socket(n == 0 ? "connection closed" : "receive: \(String(cString: strerror(errno)))") }
                got += n
            }
            return out
        }

        func close() {
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }

        deinit { close() }
    }
}

public enum DBServerError: Error, CustomStringConvertible {
    case socket(String)
    case protocolError(String)
    case notReady

    public var description: String {
        switch self {
        case .socket(let s): return s
        case .protocolError(let s): return "protocol: \(s)"
        case .notReady: return "database not ready"
        }
    }
}

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
private func u32(_ b: [UInt8]) -> UInt32 { UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]) }
#endif
