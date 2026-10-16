#if canImport(Darwin)
import Darwin
import Foundation

/// A StageLinQ device seen on the network.
public struct DiscoveredDevice: Hashable, CustomStringConvertible {
    public let token: Token
    public let address: String          // IPv4, e.g. "192.168.1.20"
    public let port: UInt16             // main TCP port
    public let name: String             // e.g. "sc6000"
    public let softwareName: String     // e.g. "SC6000", "JM08" (mixer)
    public let softwareVersion: String

    public var description: String { "\(softwareName) \"\(name)\" \(address):\(port) v\(softwareVersion)" }
}

/// Listens for StageLinQ announcements on UDP 51337 and announces us once a
/// second (devices only answer peers that announce themselves).
///
/// On iPadOS this needs the com.apple.developer.networking.multicast
/// entitlement (UDP broadcast); without it sends fail and nothing is received.
final class Discovery: @unchecked Sendable {
    static let port: UInt16 = 51337

    var onDevice: ((DiscoveredDevice, DiscoveryMessage.Action) -> Void)?
    var onLog: ((String) -> Void)?

    private let token: Token
    private let name: String
    private let softwareName: String
    private let softwareVersion: String

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "stagelinq.discovery")
    private var announceTimer: DispatchSourceTimer?
    private var readSource: DispatchSourceRead?
    private var lastSendError: Int32 = 0

    init(token: Token, name: String, softwareName: String, softwareVersion: String) {
        self.token = token
        self.name = name
        self.softwareName = softwareName
        self.softwareVersion = softwareVersion
    }

    func start() throws {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw posixError("socket") }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(s)
            throw posixError("bind UDP \(Self.port)")
        }
        fd = s

        let read = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        read.setEventHandler { [weak self] in self?.receive() }
        read.resume()
        readSource = read

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.announce(.howdy) }
        timer.resume()
        announceTimer = timer
    }

    func stop() {
        queue.sync {
            announce(.exit)
            announceTimer?.cancel()
            announceTimer = nil
            readSource?.cancel()
            readSource = nil
            if fd >= 0 { close(fd); fd = -1 }
        }
    }

    // MARK: -

    private func announce(_ action: DiscoveryMessage.Action) {
        guard fd >= 0 else { return }
        let bytes = DiscoveryMessage(token: token, source: name, action: action,
                                     softwareName: softwareName, softwareVersion: softwareVersion,
                                     port: 0).encoded()
        var targets = Self.broadcastAddresses()
        targets.append(INADDR_BROADCAST)
        for target in Set(targets) {
            var to = sockaddr_in()
            to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            to.sin_family = sa_family_t(AF_INET)
            to.sin_port = Self.port.bigEndian
            to.sin_addr.s_addr = target
            let sent = bytes.withUnsafeBytes { buf in
                withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0, errno != lastSendError {
                lastSendError = errno
                onLog?("Announcement failed: \(String(cString: strerror(errno)))"
                       + (errno == EHOSTUNREACH || errno == EPERM ? " (on iPad: needs the multicast networking entitlement)" : ""))
            }
        }
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBytes { buf in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &fromLen)
                }
            }
        }
        guard n > 0 else { return }
        guard let msg = try? DiscoveryMessage.decode(Array(buffer[0..<n])) else { return }
        if msg.token == token { return }   // our own announcement

        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var a = from.sin_addr
        inet_ntop(AF_INET, &a, &ip, socklen_t(INET_ADDRSTRLEN))
        let device = DiscoveredDevice(token: msg.token, address: String(cString: ip), port: msg.port,
                                      name: msg.source, softwareName: msg.softwareName,
                                      softwareVersion: msg.softwareVersion)
        onDevice?(device, msg.action)
    }

    /// Broadcast address of every IPv4 interface that's up (e.g. 192.168.1.255).
    private static func broadcastAddresses() -> [in_addr_t] {
        var result: [in_addr_t] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cur {
            let flags = Int32(ifa.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
               let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
               let bcast = ifa.pointee.ifa_dstaddr {
                bcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    result.append($0.pointee.sin_addr.s_addr)
                }
            }
            cur = ifa.pointee.ifa_next
        }
        return result
    }

    private func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}
#endif
