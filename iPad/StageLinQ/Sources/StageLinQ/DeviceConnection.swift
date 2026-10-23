#if canImport(Network)
import Foundation
import Network

/// One device: its main TCP connection (service list + keep-alive) and, once the
/// device announces it, a StateMap connection that streams the states we
/// subscribe to.
final class DeviceConnection: @unchecked Sendable {
    let device: DiscoveredDevice

    var onState: ((DiscoveredDevice, String, StateValue) -> Void)?
    var onClosed: ((DiscoveredDevice, String) -> Void)?
    var onLog: ((String) -> Void)?

    private let token: Token
    private let subscriptions: [String]
    private let queue: DispatchQueue

    private var main: NWConnection?
    private var mainBuffer: [UInt8] = []
    private var stateMap: NWConnection?
    private var stateBuffer: [UInt8] = []
    private var keepAlive: DispatchSourceTimer?
    private var services: [String: UInt16] = [:]
    private var closed = false
    private var requestedServices = false
    private var fallbackRequest: DispatchWorkItem?

    init(device: DiscoveredDevice, token: Token, subscriptions: [String], queue: DispatchQueue) {
        self.device = device
        self.token = token
        self.subscriptions = subscriptions
        self.queue = queue
    }

    func start() {
        guard let port = NWEndpoint.Port(rawValue: device.port) else {
            close("invalid port \(device.port)")
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(device.address), port: port, using: .tcp)
        main = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log("connected; waiting for the device to start the handshake")
                // Current Engine firmware speaks first: it sends a services request,
                // and only then accepts ours. Sending before that (or sending
                // keep-alives) makes the player reset the connection at once.
                // If it stays silent, ask anyway after 3 s.
                let fallback = DispatchWorkItem { [weak self] in
                    guard let self, !self.closed, !self.requestedServices else { return }
                    self.log("device didn't start the handshake; asking for its services")
                    self.requestServices(on: conn)
                }
                self.fallbackRequest = fallback
                self.queue.asyncAfter(deadline: .now() + 3, execute: fallback)
            case .failed(let error):
                self.close("main connection failed: \(error.localizedDescription)")
            case .waiting(let error):
                // The network isn't ready (e.g. the Ethernet adapter has no
                // address yet). Give up now; the client retries in a few seconds
                // instead of this connection waiting forever.
                self.close("network not ready: \(error.localizedDescription)")
            case .cancelled:
                self.close("main connection closed")
            default:
                break
            }
        }
        receiveMain(conn)
        conn.start(queue: queue)
    }

    func cancel() {
        close("stopped")
    }

    // MARK: - Main connection

    private func receiveMain(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.mainBuffer += data
                self.drainMain(conn)
            }
            if let error {
                self.close("main connection: \(error.localizedDescription)")
            } else if isComplete {
                self.close("device closed the connection")
            } else {
                self.receiveMain(conn)
            }
        }
    }

    private func drainMain(_ conn: NWConnection) {
        do {
            while let msg = try MainMessage.decode(from: &mainBuffer) {
                switch msg {
                case let .serviceAnnouncement(_, service, port):
                    services[service] = port
                    log("offers \(service) on port \(port)")
                    if service == "StateMap", stateMap == nil {
                        openStateMap(port: port)
                    }
                case .servicesRequest:
                    // The device opens the handshake; answer with our request
                    // (we offer no services of our own).
                    if !requestedServices { requestServices(on: conn) }
                case .reference:
                    break
                }
            }
        } catch {
            log("main stream out of sync (\(error)); dropping \(mainBuffer.count) bytes")
            mainBuffer.removeAll()
        }
    }

    private func requestServices(on conn: NWConnection) {
        requestedServices = true
        fallbackRequest?.cancel()
        send(MainMessage.servicesRequest(token: token).encoded(), on: conn)
    }

    /// Not used: current firmware resets connections that send these unprompted.
    private func startKeepAlive(on conn: NWConnection) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.send(MainMessage.reference(token: self.token, token2: self.device.token, reference: 0).encoded(), on: conn)
        }
        timer.resume()
        keepAlive = timer
    }

    // MARK: - StateMap

    private func openStateMap(port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(device.address), port: p, using: .tcp)
        stateMap = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var localPort: UInt16 = 0
                if case let .hostPort(_, lp)? = conn.currentPath?.localEndpoint { localPort = lp.rawValue }
                var hello = StateMapMessage.hello(token: self.token, localPort: localPort)
                for path in self.subscriptions {
                    hello += StateMapMessage.subscribe(name: path, interval: 0).encoded()
                }
                self.send(hello, on: conn)
                self.log("StateMap: subscribed to \(self.subscriptions.count) states")
            case .failed(let error):
                self.close("StateMap failed: \(error.localizedDescription)")
            case .waiting(let error):
                self.close("StateMap: network not ready: \(error.localizedDescription)")
            default:
                break
            }
        }
        receiveStateMap(conn)
        conn.start(queue: queue)
    }

    private func receiveStateMap(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.stateBuffer += data
                self.drainStateMap()
            }
            if let error {
                self.close("StateMap: \(error.localizedDescription)")
            } else if isComplete {
                self.close("device closed StateMap")
            } else {
                self.receiveStateMap(conn)
            }
        }
    }

    private func drainStateMap() {
        while true {
            do {
                guard let msg = try StateMapMessage.decode(from: &stateBuffer) else { return }
                if case let .emit(name, json) = msg {
                    onState?(device, name, StateValue(json: json))
                }
            } catch {
                // decode() already skipped a bad frame; a bad length can't be
                // skipped, so start over from the next data.
                if case CodecError.invalid(let why) = error, why.hasPrefix("bad StateMap frame length") {
                    log("StateMap out of sync (\(why)); dropping \(stateBuffer.count) bytes")
                    stateBuffer.removeAll()
                    return
                }
            }
        }
    }

    // MARK: -

    private func send(_ bytes: [UInt8], on conn: NWConnection) {
        conn.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.log("send failed: \(error.localizedDescription)") }
        })
    }

    private func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        fallbackRequest?.cancel()
        keepAlive?.cancel()
        keepAlive = nil
        main?.cancel()
        stateMap?.cancel()
        log("disconnected: \(reason)")
        onClosed?(device, reason)
    }

    private func log(_ s: String) {
        onLog?("[\(device.softwareName) \(device.address)] \(s)")
    }
}
#endif
