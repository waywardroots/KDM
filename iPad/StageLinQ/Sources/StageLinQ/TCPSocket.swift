#if canImport(Darwin)
import Darwin
import Foundation

/// A TCP connection on a plain BSD socket, optionally pinned to one network
/// interface (IP_BOUND_IF).
///
/// Used instead of Network.framework because on iPadOS an Ethernet adapter that
/// only has a link-local (169.254.x.x) address — e.g. plugged straight into a DJ
/// mixer's network port — isn't offered to NWConnection, so connections to the
/// players went out of the Wi-Fi instead and never arrived.
final class TCPSocket: @unchecked Sendable {
    enum Event {
        case connected(local: String)
        case data([UInt8])
        case closed(String)
    }

    var onEvent: ((Event) -> Void)?
    private(set) var localPort: UInt16 = 0

    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var liveSources = 0
    private var pending: [UInt8] = []
    private var connected = false
    private var finished = false

    /// All calls (and all events) happen on `queue`.
    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func connect(address: String, port: UInt16, interfaceIndex: UInt32?) {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { return finish("socket: \(Self.errorText())") }
        fd = s
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        if var index = interfaceIndex, index > 0 {
            setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return finish("bad address \(address)") }

        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return didConnect() }
        guard errno == EINPROGRESS else { return finish("connect: \(Self.errorText())") }

        // Wait until the socket is writable, then check how the connect went.
        let w = makeWriteSource { [weak self] in
            guard let self, !self.finished else { return }
            self.writeSource?.cancel()
            self.writeSource = nil
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(self.fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err == 0 { self.didConnect() } else { self.finish("connect: \(String(cString: strerror(err)))") }
        }
        writeSource = w
        w.resume()
    }

    func send(_ bytes: [UInt8]) {
        guard !finished else { return }
        pending += bytes
        if connected { flush() }
    }

    /// Close without reporting an event.
    func close() {
        guard !finished else { return }
        finished = true
        teardown()
    }

    // MARK: -

    private func didConnect() {
        connected = true
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var localText = "?"
        let got = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        if got == 0 {
            localPort = UInt16(bigEndian: local.sin_port)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = local.sin_addr
            inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            localText = "\(String(cString: buf)):\(localPort)"
        }

        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        liveSources += 1
        r.setEventHandler { [weak self] in self?.readAvailable() }
        r.setCancelHandler { [weak self] in self?.sourceCancelled() }
        readSource = r
        r.resume()

        onEvent?(.connected(local: localText))
        flush()
    }

    private func readAvailable() {
        guard !finished else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            onEvent?(.data(Array(buf[0..<n])))
        } else if n == 0 {
            finish("device closed the connection")
        } else if errno != EAGAIN && errno != EINTR {
            finish(Self.errorText())
        }
    }

    private func flush() {
        while !pending.isEmpty && !finished {
            let n = pending.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                // Socket buffer full: continue when it's writable again.
                guard writeSource == nil else { return }
                let w = makeWriteSource { [weak self] in
                    guard let self else { return }
                    self.writeSource?.cancel()
                    self.writeSource = nil
                    self.flush()
                }
                writeSource = w
                w.resume()
                return
            } else {
                return finish("send: \(Self.errorText())")
            }
        }
    }

    private func makeWriteSource(_ handler: @escaping () -> Void) -> DispatchSourceWrite {
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        liveSources += 1
        w.setEventHandler(handler: handler)
        w.setCancelHandler { [weak self] in self?.sourceCancelled() }
        return w
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        teardown()
        onEvent?(.closed(reason))
    }

    private func teardown() {
        let sources: [DispatchSourceProtocol] = [readSource, writeSource].compactMap { $0 }
        readSource = nil
        writeSource = nil
        if sources.isEmpty {
            closeDescriptor()
        } else {
            sources.forEach { $0.cancel() }   // the descriptor closes once they're all cancelled
        }
    }

    private func sourceCancelled() {
        liveSources -= 1
        if liveSources == 0 && finished { closeDescriptor() }
    }

    private func closeDescriptor() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private static func errorText() -> String { String(cString: strerror(errno)) }
}
#endif
