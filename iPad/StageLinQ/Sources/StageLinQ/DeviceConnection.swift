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
                self.log("connected")
                // Ask for the device's services, and keep the link alive.
                self.send(MainMessage.servicesRequest(token: self.token).encoded(), on: conn)
                self.startKeepAlive(on: conn)
            case .failed(let error):
                self.close("main connection failed: \(error.localizedDescription)")
            case .waiting(let error):
                self.log("waiting: \(error.localizedDescription)")
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
                    // The device asks what we offer: nothing. Ask for its list
                    // again, in case our first request came too early.
                    send(MainMessage.servicesRequest(token: token).encoded(), on: conn)
                case .reference:
                    break
                }
            }
        } catch {
            log("main stream out of sync (\(error)); dropping \(mainBuffer.count) bytes")
            mainBuffer.removeAll()
        }
    }

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
