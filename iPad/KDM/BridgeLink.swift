import Foundation
import Network

/// Receives the decks of DJ software on a computer (Serato DJ Pro) from
/// "KDM Bridge" running on that computer. The bridge advertises itself over
/// Bonjour (_kdm-decks._tcp) and sends one JSON message per line:
///   {"source":"Serato DJ Pro","decks":[{"deck":"1","key":"Gm","bpm":124,…}]}
final class BridgeLink: @unchecked Sendable {

    struct Deck: Codable, Equatable {
        var deck: String
        var title: String?
        var artist: String?
        var key: String?
        var bpm: Double?
        var played: Bool
        var started: Int64
    }

    struct Message: Codable, Equatable {
        var source: String
        var decks: [Deck]
    }

    static let serviceType = "_kdm-decks._tcp"

    /// (computer name, its message), on the main queue. Empty when none connected.
    var onChange: (([String: Message]) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "kdm.bridge.client")
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]   // service name -> connection
    private var buffers: [String: Data] = [:]
    private var messages: [String: Message] = [:]

    func start() {
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { self?.log("Computer search failed: \(e.localizedDescription)") }
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() {
        queue.sync {
            browser?.cancel(); browser = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll(); buffers.removeAll(); messages.removeAll()
        }
        publish()
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var seen: Set<String> = []
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            seen.insert(name)
            if connections[name] == nil { connect(name: name, endpoint: r.endpoint) }
        }
        for name in connections.keys where !seen.contains(name) {
            connections[name]?.cancel()
            drop(name)
        }
    }

    private func connect(name: String, endpoint: NWEndpoint) {
        log("Found \(name)")
        let c = NWConnection(to: endpoint, using: .tcp)
        connections[name] = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.log("Connected to \(name)")
            case .failed(let e):
                self.log("\(name): \(e.localizedDescription)")
                self.drop(name)
            case .cancelled: self.drop(name)
            default: break
            }
        }
        receive(c, name: name)
        c.start(queue: queue)
    }

    private func receive(_ c: NWConnection, name: String) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var buffer = (self.buffers[name] ?? Data()) + data
                while let nl = buffer.firstIndex(of: 0x0a) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let m = try? JSONDecoder().decode(Message.self, from: line) {
                        self.messages[name] = m
                        self.publish()
                    }
                }
                self.buffers[name] = buffer
            }
            if done || error != nil {
                self.log("\(name) disconnected")
                c.cancel()
            } else {
                self.receive(c, name: name)
            }
        }
    }

    private func drop(_ name: String) {
        connections[name] = nil
        buffers[name] = nil
        if messages.removeValue(forKey: name) != nil { publish() }
    }

    private func publish() {
        let m = messages
        let cb = onChange
        DispatchQueue.main.async { cb?(m) }
    }

    private func log(_ s: String) {
        let cb = onLog
        DispatchQueue.main.async { cb?(s) }
    }
}
