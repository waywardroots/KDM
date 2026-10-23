#if canImport(Darwin)
import Foundation

/// One device: its main TCP connection (service list) and, once the
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

    private var main: TCPSocket?
    private var mainConnected = false
    private var mainBuffer: [UInt8] = []
    private var stateMap: TCPSocket?
    private var stateBuffer: [UInt8] = []
    private var services: [String: UInt16] = [:]
    private var closed = false
    private var requestedServices = false
    private var loggedFirstData = false
    private var loggedReference = false
    private var handshakeTimeout: DispatchWorkItem?
    private var fallbackRequest: DispatchWorkItem?
    private var connectTimeout: DispatchWorkItem?

    init(device: DiscoveredDevice, token: Token, subscriptions: [String], queue: DispatchQueue) {
        self.device = device
        self.token = token
        self.subscriptions = subscriptions
        self.queue = queue
    }

    func start() {
        let index = device.interfaceIndex
        log("connecting" + (device.interfaceName.map { " via \($0)" } ?? ""))
        let sock = TCPSocket(queue: queue)
        main = sock
        // Don't sit in the system's 75 s TCP timeout (e.g. while the Ethernet
        // adapter has no address yet): give up after 6 s and let the client retry.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.closed, !self.mainConnected else { return }
            self.close("couldn't connect within 6 s; will retry")
        }
        connectTimeout = timeout
        queue.asyncAfter(deadline: .now() + 6, execute: timeout)

        sock.onEvent = { [weak self] event in
            guard let self, !self.closed else { return }
            switch event {
            case .connected(let local):
                self.mainConnected = true
                self.connectTimeout?.cancel()
                self.log("connected from \(local); waiting for the device to start the handshake")
                // Current Engine firmware speaks first: it sends a services request,
                // and only then accepts ours. Sending before that (or sending
                // keep-alives) makes the player reset the connection at once.
                // If it stays silent, ask anyway after 3 s.
                let fallback = DispatchWorkItem { [weak self] in
                    guard let self, !self.closed, !self.requestedServices else { return }
                    self.log("device didn't start the handshake; asking for its services")
                    self.requestServices()
                }
                self.fallbackRequest = fallback
                self.queue.asyncAfter(deadline: .now() + 3, execute: fallback)
                // A player that doesn't recognise us (it hasn't heard our
                // announcement from this address yet) stays silent. Don't wait
                // forever: drop it and let the client reconnect in a few seconds.
                let handshake = DispatchWorkItem { [weak self] in
                    guard let self, !self.closed, self.services.isEmpty else { return }
                    self.close("no reply from the device in 8 s; will retry")
                }
                self.handshakeTimeout = handshake
                self.queue.asyncAfter(deadline: .now() + 8, execute: handshake)
            case .data(let bytes):
                if !self.loggedFirstData {
                    self.loggedFirstData = true
                    self.log("device sent its first data (\(bytes.count) bytes)")
                }
                self.mainBuffer += bytes
                self.drainMain()
            case .closed(let reason):
                self.close("main connection: \(reason)")
            }
        }
        sock.connect(address: device.address, port: device.port, interfaceIndex: index)
    }

    func cancel() {
        close("stopped")
    }

    // MARK: - Main connection

    private func drainMain() {
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
                    log("device started the handshake")
                    if !requestedServices { requestServices() }
                case .reference:
                    if !loggedReference {
                        loggedReference = true
                        log("device sent a timestamp")
                    }
                }
            }
        } catch {
            log("main stream out of sync (\(error)); dropping \(mainBuffer.count) bytes")
            mainBuffer.removeAll()
        }
    }

    private func requestServices() {
        requestedServices = true
        fallbackRequest?.cancel()
        main?.send(MainMessage.servicesRequest(token: token).encoded())
    }

    // MARK: - StateMap

    private func openStateMap(port: UInt16) {
        let sock = TCPSocket(queue: queue)
        stateMap = sock
        sock.onEvent = { [weak self] event in
            guard let self, !self.closed else { return }
            switch event {
            case .connected:
                var hello = StateMapMessage.hello(token: self.token, localPort: sock.localPort)
                for path in self.subscriptions {
                    hello += StateMapMessage.subscribe(name: path, interval: 0).encoded()
                }
                sock.send(hello)
                self.log("StateMap: subscribed to \(self.subscriptions.count) states")
            case .data(let bytes):
                self.stateBuffer += bytes
                self.drainStateMap()
            case .closed(let reason):
                self.close("StateMap: \(reason)")
            }
        }
        sock.connect(address: device.address, port: port, interfaceIndex: device.interfaceIndex)
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

    private func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        fallbackRequest?.cancel()
        handshakeTimeout?.cancel()
        connectTimeout?.cancel()
        main?.close()
        stateMap?.close()
        log("disconnected: \(reason)")
        onClosed?(device, reason)
    }

    private func log(_ s: String) {
        onLog?("[\(device.softwareName) \(device.address)] \(s)")
    }
}
#endif
