#if canImport(Darwin)
import Darwin
import Foundation

/// Joins a Pioneer Pro DJ Link network as a "virtual CDJ" (device number 7 or
/// above, so it never takes a real player's slot) and follows the players'
/// status: key (CDJ-3000), tempo, play / master / on-air.
///
///     let link = ProDJLinkClient()
///     link.onStatus = { players in … }      // main queue
///     try link.start()
///
/// Like the StageLinQ client, every socket that sends is bound to the network
/// interface the players were heard on *and* to its own address: on iPadOS a
/// link-local Ethernet adapter is otherwise skipped or given the Wi-Fi source
/// address. On iPad this needs the multicast networking entitlement.
public final class ProDJLinkClient: @unchecked Sendable {

    public var onStatus: (([CDJStatus]) -> Void)?
    public var onDevicesChanged: (([ProDJLinkDevice]) -> Void)?
    public var onLog: ((String) -> Void)?

    public let name: String
    public private(set) var deviceNumber: UInt8 = 7

    private let queue = DispatchQueue(label: "prodjlink.client")
    private var announceFD: Int32 = -1          // :50000 keep-alives, claims, defenses
    private var statusFD: Int32 = -1            // :50002 CDJ / mixer status
    private var sources: [DispatchSourceRead] = []
    private var timer: DispatchSourceTimer?

    private var devices: [Int: (device: ProDJLinkDevice, seen: Date)] = [:]
    private var status: [Int: CDJStatus] = [:]
    private var lastPublished: [CDJStatus] = []

    // The interface we joined on (where the first device was heard).
    private var iface: (index: UInt32, name: String, address: in_addr_t, broadcast: in_addr_t, mac: [UInt8])?
    private enum Phase { case waiting, joining(step: Int), online }
    private var phase: Phase = .waiting
    private var nextKeepAlive = Date.distantPast

    public init(name: String = "KDM") {
        self.name = name
    }

    public func start() throws {
        announceFD = try Self.openListener(port: ProDJLinkPacket.announcePort)
        statusFD = try Self.openListener(port: ProDJLinkPacket.statusPort)
        for (fd, handler) in [(announceFD, handleAnnounce), (statusFD, handleStatus)] as [(Int32, ([UInt8], String, UInt32) -> Void)] {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                if let (bytes, from, ifIndex) = Self.receive(fd) { handler(bytes, from, ifIndex) }
            }
            src.resume()
            sources.append(src)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 0.3)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        log("Listening for Pro DJ Link devices on UDP \(ProDJLinkPacket.announcePort) / \(ProDJLinkPacket.statusPort)")
    }

    public func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            sources.forEach { $0.cancel() }; sources.removeAll()
            if announceFD >= 0 { close(announceFD); announceFD = -1 }
            if statusFD >= 0 { close(statusFD); statusFD = -1 }
            devices.removeAll(); status.removeAll()
            phase = .waiting
        }
    }

    // MARK: - Joining

    /// Every 0.3 s: walk the join sequence (hello ×3, claims ×3 each), then send
    /// a keep-alive every 1.5 s; forget devices not heard for 10 s.
    private func tick() {
        guard let iface else { return }
        let now = Date()
        let ip = Self.bytes(of: iface.address)
        switch phase {
        case .waiting:
            break
        case .joining(let step):
            let counter = UInt8(step % 3 + 1)
            let packet: [UInt8]
            switch step / 3 {
            case 0: packet = ProDJLinkPacket.hello(name: name)
            case 1: packet = ProDJLinkPacket.claim1(name: name, mac: iface.mac, counter: counter)
            case 2: packet = ProDJLinkPacket.claim2(name: name, ip: ip, mac: iface.mac, number: deviceNumber, counter: counter)
            case 3: packet = ProDJLinkPacket.claim3(name: name, number: deviceNumber, counter: counter)
            default:
                phase = .online
                log("Joined as device \(deviceNumber) on \(iface.name) (\(Self.ip(iface.address)))")
                return
            }
            send(packet, to: iface.broadcast, port: ProDJLinkPacket.announcePort)
            phase = .joining(step: step + 1)
        case .online:
            if now >= nextKeepAlive {
                nextKeepAlive = now.addingTimeInterval(1.5)
                let peers = UInt8(min(255, devices.count + 1))
                send(ProDJLinkPacket.keepAlive(name: name, number: deviceNumber, mac: iface.mac, ip: ip, peers: peers),
                     to: iface.broadcast, port: ProDJLinkPacket.announcePort)
            }
        }

        let stale = devices.filter { now.timeIntervalSince($0.value.seen) > 10 }.map(\.key)
        if !stale.isEmpty {
            for n in stale {
                log("\(devices[n]?.device.description ?? "#\(n)") left")
                devices[n] = nil
                status[n] = nil
            }
            publishDevices()
            publishStatus()
        }
    }

    private func beginJoining(on index: UInt32) {
        guard let found = Self.interfaces().first(where: { $0.index == index }) else {
            log("Heard Pro DJ Link on interface \(index) but it has no IPv4 address yet")
            return
        }
        iface = found
        phase = .joining(step: 0)
        log("Pro DJ Link network found on \(found.name) (\(Self.ip(found.address))); joining as device \(deviceNumber)")
    }

    // MARK: - Receiving

    private func handleAnnounce(_ b: [UInt8], from: String, ifIndex: UInt32) {
        guard ProDJLinkPacket.hasMagic(b) else { return }
        if let iface, from == Self.ip(iface.address) { return }     // our own

        if let defended = ProDJLinkPacket.parseDefense(b), defended == Int(deviceNumber) {
            // Someone already uses our number: try the next one and start over.
            deviceNumber = deviceNumber >= 15 ? 7 : deviceNumber + 1
            log("Device number in use; trying \(deviceNumber)")
            phase = .joining(step: 3)
            return
        }

        guard var device = ProDJLinkPacket.parseKeepAlive(b, from: from) else { return }
        device.interfaceName = Self.interfaceName(ifIndex)
        if case .waiting = phase, ifIndex > 0 { beginJoining(on: ifIndex) }
        if device.number == Int(deviceNumber) {
            // Another device announces our number (our own packets were filtered
            // out above): move out of its way and claim again.
            deviceNumber = deviceNumber >= 15 ? 7 : deviceNumber + 1
            log("Device \(device.number) is taken by \(device.name); using \(deviceNumber)")
            if case .online = phase { phase = .joining(step: 3) }
        }
        let isNew = devices[device.number]?.device != device
        devices[device.number] = (device, Date())
        if isNew {
            log("Found \(device)")
            publishDevices()
        }
    }

    private func handleStatus(_ b: [UInt8], from: String, ifIndex: UInt32) {
        guard let s = ProDJLinkPacket.parseStatus(b) else { return }
        if s.player == Int(deviceNumber) { return }
        if status[s.player] == nil { log("Status from \(s.name) #\(s.player)" + (s.key == nil ? " (no key field: not a CDJ-3000?)" : "")) }
        status[s.player] = s
        publishStatus()
    }

    private func publishStatus() {
        let list = status.values.sorted { $0.player < $1.player }
        guard list != lastPublished else { return }
        lastPublished = list
        let cb = onStatus
        DispatchQueue.main.async { cb?(list) }
    }

    private func publishDevices() {
        let list = devices.values.map(\.device).sorted { $0.number < $1.number }
        let cb = onDevicesChanged
        DispatchQueue.main.async { cb?(list) }
    }

    private func log(_ s: String) {
        let cb = onLog
        DispatchQueue.main.async { cb?(s) }
    }

    // MARK: - Sockets

    private func send(_ bytes: [UInt8], to target: in_addr_t, port: UInt16) {
        guard let iface else { return }
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return }
        defer { close(s) }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var index = iface.index
        setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = iface.address
        _ = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = port.bigEndian
        to.sin_addr.s_addr = target
        let sent = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { log("Send to \(Self.ip(target)) failed: \(String(cString: strerror(errno)))") }
    }

    private static func openListener(port: UInt16) throws -> Int32 {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw posixError("socket") }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_IP, IP_RECVIF, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { close(s); throw posixError("bind UDP \(port)") }
        return s
    }

    /// One datagram, its sender and the interface it arrived on.
    private static func receive(_ fd: Int32) -> ([UInt8], String, UInt32)? {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var control = [UInt8](repeating: 0, count: 256)
        var from = sockaddr_in()
        var ifIndex: UInt32 = 0
        let n: Int = buffer.withUnsafeMutableBytes { buf in
            control.withUnsafeMutableBytes { ctl in
                withUnsafeMutablePointer(to: &from) { fromPtr in
                    var iov = iovec(iov_base: buf.baseAddress, iov_len: buf.count)
                    return withUnsafeMutablePointer(to: &iov) { iovPtr in
                        var msg = msghdr(msg_name: UnsafeMutableRawPointer(fromPtr),
                                         msg_namelen: socklen_t(MemoryLayout<sockaddr_in>.size),
                                         msg_iov: iovPtr, msg_iovlen: 1,
                                         msg_control: ctl.baseAddress, msg_controllen: socklen_t(ctl.count),
                                         msg_flags: 0)
                        let got = recvmsg(fd, &msg, 0)
                        var offset = 0
                        let total = Int(msg.msg_controllen)
                        let header = MemoryLayout<cmsghdr>.size
                        while got > 0, offset + header <= total {
                            let h = ctl.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
                            let len = Int(h.cmsg_len)
                            guard len >= header else { break }
                            if h.cmsg_level == IPPROTO_IP, h.cmsg_type == IP_RECVIF, offset + header + 4 <= total {
                                ifIndex = UInt32(ctl.loadUnaligned(fromByteOffset: offset + align(header) + 2, as: UInt16.self))
                            }
                            offset += align(len)
                        }
                        return got
                    }
                }
            }
        }
        guard n > 0 else { return nil }
        return (Array(buffer[0..<n]), ip(from.sin_addr.s_addr), ifIndex)
    }

    /// IPv4 interfaces that can broadcast, with their MAC (zeros if hidden).
    private static func interfaces() -> [(index: UInt32, name: String, address: in_addr_t, broadcast: in_addr_t, mac: [UInt8])] {
        var result: [(index: UInt32, name: String, address: in_addr_t, broadcast: in_addr_t, mac: [UInt8])] = []
        var macs: [String: [UInt8]] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cur {
            let name = String(cString: ifa.pointee.ifa_name)
            if let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_LINK) {
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let nlen = Int(dl.pointee.sdl_nlen), alen = Int(dl.pointee.sdl_alen)
                    if alen == 6 {
                        withUnsafePointer(to: &dl.pointee.sdl_data) {
                            $0.withMemoryRebound(to: UInt8.self, capacity: nlen + alen) { p in
                                macs[name] = (0..<6).map { p[nlen + $0] }
                            }
                        }
                    }
                }
            }
            cur = ifa.pointee.ifa_next
        }
        cur = first
        while let ifa = cur {
            let flags = Int32(ifa.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
               let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
               let bcast = ifa.pointee.ifa_dstaddr {
                let name = String(cString: ifa.pointee.ifa_name)
                let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let b = bcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                result.append((if_nametoindex(ifa.pointee.ifa_name), name, a, b, macs[name] ?? [0, 0, 0, 0, 0, 0]))
            }
            cur = ifa.pointee.ifa_next
        }
        return result
    }

    private static func interfaceName(_ index: UInt32) -> String? {
        guard index > 0 else { return nil }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        return if_indextoname(index, &name) != nil ? String(cString: name) : nil
    }

    private static func align(_ n: Int) -> Int { (n + 3) & ~3 }

    private static func bytes(of addr: in_addr_t) -> [UInt8] {
        withUnsafeBytes(of: addr) { Array($0) }     // already network byte order
    }

    private static func ip(_ addr: in_addr_t) -> String {
        var a = in_addr(s_addr: addr)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    private static func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}
#endif
