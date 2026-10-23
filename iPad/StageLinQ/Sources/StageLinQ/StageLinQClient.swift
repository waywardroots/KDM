#if canImport(Network) && canImport(Darwin)
import Foundation

/// What one deck on one device reports.
public struct DeckStatus: Equatable {
    public let device: String       // e.g. "SC6000 192.168.1.20"
    public let deck: Int            // 1…4 (an SC6000 uses 1 and 2 for its layers)
    public var loaded = false
    public var title: String?
    public var artist: String?
    public var keyText: String?     // as Engine shows it ("8A", "Am", …)
    public var key: MusicalKey?     // parsed from keyText
    public var bpm: Double?         // current (pitched) BPM
    public var playing = false
    public var faderPosition: Double?   // ExternalMixerVolume, 0…1
    public var isMaster = false
    /// The player number set on the unit (Preferences → Player), if known.
    public var player: Int?

    public init(device: String, deck: Int) {
        self.device = device
        self.deck = deck
    }

    /// Stable within a session: "<device>#<deck>".
    public var id: String { "\(device)#\(deck)" }

    /// "Player 1", "Player 1 B" (an SC6000's second layer); without a player
    /// number, "<device> deck N".
    public var label: String {
        if let player { return deck == 2 ? "Player \(player) B" : "Player \(player)" }
        return "\(device) deck \(deck)"
    }
}

/// Mixer state (X1800 / X1850): channel faders and crossfader, 0…1.
public struct MixerStatus: Equatable {
    public let device: String
    public var channelFaders: [Int: Double] = [:]    // channel 1…4
    public var crossfader: Double?
    public var channelAssignments: [Int: String] = [:]

    public init(device: String) { self.device = device }
}

/// Finds Denon / Engine DJ devices on the network and follows their decks.
///
///     let client = StageLinQClient()
///     client.onChange = { decks, mixers in … }   // main queue
///     try client.start()
public final class StageLinQClient: @unchecked Sendable {
    /// Called on the main queue whenever a deck or mixer value changes.
    public var onChange: (([DeckStatus], [MixerStatus]) -> Void)?
    /// Every raw state update, on the main queue (for the monitor / debugging).
    public var onRawState: ((DiscoveredDevice, String, StateValue) -> Void)?
    /// Devices connected right now, on the main queue.
    public var onDevicesChanged: (([DiscoveredDevice]) -> Void)?
    public var onLog: ((String) -> Void)?

    public let token: Token
    private let queue = DispatchQueue(label: "stagelinq.client")
    private let discovery: Discovery
    private var connections: [Token: DeviceConnection] = [:]
    private var retryAfter: [Token: Date] = [:]
    private var notedMixers: Set<Token> = []
    private var decks: [String: DeckStatus] = [:]          // "<address>#<deck>"
    private var mixers: [String: MixerStatus] = [:]        // address
    private var playerNumbers: [String: Int] = [:]         // address -> Preferences/Player

    /// Software names that aren't DJ gear (analysers, lighting / VJ apps, other clients).
    public static let ignoredSoftware: Set<String> = ["OfflineAnalyzer", "SoundSwitch", "SSS0", "Resolume", "NowPlaying", "Now Playing"]

    /// The token and names used in our announcements. Engine gear accepts any
    /// well-formed identity; `nowPlaying` copies the one used by the Now Playing
    /// app, as a fallback if a firmware ever rejects unknown software.
    public init(name: String = "KDM", softwareName: String = "KDM", softwareVersion: String = "0.1", token: Token = .random()) {
        self.token = token
        discovery = Discovery(token: token, name: name, softwareName: softwareName, softwareVersion: softwareVersion)
    }

    public func start() throws {
        discovery.onLog = { [weak self] in self?.log($0) }
        discovery.onDevice = { [weak self] device, action in
            self?.queue.async { self?.handleDiscovery(device, action) }
        }
        try discovery.start()
        log("Listening for StageLinQ devices on UDP \(Discovery.port)")
    }

    public func stop() {
        discovery.stop()
        queue.sync {
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - States we subscribe to

    static func subscriptions() -> [String] {
        var paths = [
            "/Mixer/CH1faderPosition", "/Mixer/CH2faderPosition",
            "/Mixer/CH3faderPosition", "/Mixer/CH4faderPosition",
            "/Mixer/CrossfaderPosition", "/Mixer/NumberOfChannels",
            "/Mixer/ChannelAssignment1", "/Mixer/ChannelAssignment2",
            "/Mixer/ChannelAssignment3", "/Mixer/ChannelAssignment4",
            "/Engine/DeckCount", "/Engine/Master/MasterTempo",
            "/Client/Preferences/Player", "/Client/Preferences/LayerA", "/Client/Preferences/LayerB",
            "/GUI/Decks/Deck/ActiveDeck",
        ]
        for d in 1...4 {
            let p = "/Engine/Deck\(d)"
            paths += [
                "\(p)/Track/SongLoaded", "\(p)/Track/SongName", "\(p)/Track/ArtistName",
                "\(p)/Track/CurrentKey", "\(p)/Track/CurrentKeyIndex", "\(p)/Track/OriginalKey",
                "\(p)/Track/CurrentBPM", "\(p)/CurrentBPM",
                "\(p)/Play", "\(p)/PlayState",
                "\(p)/ExternalMixerVolume", "\(p)/DeckIsMaster",
            ]
        }
        return paths
    }

    // MARK: -

    private func handleDiscovery(_ device: DiscoveredDevice, _ action: DiscoveryMessage.Action) {
        if Self.ignoredSoftware.contains(device.softwareName) { return }
        // The X1800/X1850 (JM08) refuses StageLinQ connections; its faders aren't
        // available this way. Note it once and leave it alone.
        if device.softwareName == "JM08" {
            if notedMixers.insert(device.token).inserted {
                log("Found \(device): mixer noted (it doesn't accept StageLinQ connections)")
            }
            return
        }
        switch action {
        case .howdy:
            guard connections[device.token] == nil, device.port != 0 else { return }
            // After a dropped connection, wait a few seconds before trying again
            // instead of reconnecting on every announcement.
            if let until = retryAfter[device.token], Date() < until { return }
            log("Found \(device)")
            let conn = DeviceConnection(device: device, token: token, subscriptions: Self.subscriptions(), queue: queue)
            conn.onLog = { [weak self] in self?.log($0) }
            conn.onState = { [weak self] dev, path, value in self?.handleState(dev, path, value) }
            conn.onClosed = { [weak self] dev, _ in
                // Forget it; an announcement after the retry delay reconnects.
                self?.connections[dev.token] = nil
                self?.forgetDecks(of: dev)
                self?.retryAfter[dev.token] = Date().addingTimeInterval(5)
                self?.publishDevices()
            }
            connections[device.token] = conn
            // Introduce ourselves directly first: players close connections from
            // peers they haven't heard announce. Then connect a moment later.
            discovery.announce(to: device.address)
            queue.asyncAfter(deadline: .now() + 1.2) { [weak self, weak conn] in
                guard let self, let conn, self.connections[device.token] === conn else { return }
                conn.start()
            }
            publishDevices()
        case .exit:
            if let conn = connections.removeValue(forKey: device.token) {
                log("\(device) left")
                conn.cancel()
                publishDevices()
            }
        case .other:
            break
        }
    }

    private func handleState(_ device: DiscoveredDevice, _ path: String, _ value: StateValue) {
        let raw = onRawState
        DispatchQueue.main.async { raw?(device, path, value) }

        let deviceLabel = "\(device.softwareName) \(device.address)"
        var changed = false

        if path == "/Client/Preferences/Player" {
            let n = value.string.flatMap { Int($0) } ?? value.number.map { Int($0) }
            playerNumbers[device.address] = n
            for (id, var d) in decks where id.hasPrefix("\(device.address)#") && d.player != n {
                d.player = n
                decks[id] = d
                changed = true
            }
        } else if path.hasPrefix("/Mixer/") {
            var m = mixers[device.address] ?? MixerStatus(device: deviceLabel)
            let leaf = String(path.dropFirst("/Mixer/".count))
            if leaf.hasPrefix("CH"), leaf.hasSuffix("faderPosition"), let ch = Int(leaf.dropFirst(2).prefix(1)) {
                m.channelFaders[ch] = value.number
            } else if leaf == "CrossfaderPosition" {
                m.crossfader = value.number
            } else if leaf.hasPrefix("ChannelAssignment"), let ch = Int(leaf.suffix(1)) {
                m.channelAssignments[ch] = value.string ?? value.description
            }
            if mixers[device.address] != m { mixers[device.address] = m; changed = true }
        } else if path.hasPrefix("/Engine/Deck"), let deck = Int(path.dropFirst("/Engine/Deck".count).prefix(1)) {
            let id = "\(device.address)#\(deck)"
            var d = decks[id] ?? DeckStatus(device: deviceLabel, deck: deck)
            d.player = playerNumbers[device.address]
            let leaf = path.split(separator: "/").dropFirst(2).joined(separator: "/")   // e.g. "Track/SongName"
            switch leaf {
            case "Track/SongLoaded":
                d.loaded = value.bool ?? false
                if !d.loaded { d.title = nil; d.artist = nil; d.keyText = nil; d.key = nil }
            case "Track/SongName":   d.title = value.string
            case "Track/ArtistName": d.artist = value.string
            case "Track/CurrentKey":
                d.keyText = value.string
                d.key = value.string.flatMap(MusicalKey.init(parsing:))
            case "CurrentBPM", "Track/CurrentBPM":
                if let bpm = value.number, bpm > 0 { d.bpm = bpm }
            case "Play":                d.playing = value.bool ?? d.playing
            case "ExternalMixerVolume": d.faderPosition = value.number
            case "DeckIsMaster":        d.isMaster = value.bool ?? false
            default: break
            }
            if decks[id] != d { decks[id] = d; changed = true }
        }

        if changed {
            let decksNow = decks.values.sorted { ($0.device, $0.deck) < ($1.device, $1.deck) }
            let mixersNow = mixers.values.sorted { $0.device < $1.device }
            let cb = onChange
            DispatchQueue.main.async { cb?(decksNow, mixersNow) }
        }
    }

    /// A device went away: drop its decks so stale keys aren't shown.
    private func forgetDecks(of device: DiscoveredDevice) {
        let prefix = "\(device.address)#"
        let before = decks.count
        decks = decks.filter { !$0.key.hasPrefix(prefix) }
        mixers[device.address] = nil
        guard decks.count != before else { return }
        let decksNow = decks.values.sorted { ($0.device, $0.deck) < ($1.device, $1.deck) }
        let mixersNow = mixers.values.sorted { $0.device < $1.device }
        let cb = onChange
        DispatchQueue.main.async { cb?(decksNow, mixersNow) }
    }

    private func publishDevices() {
        let list = connections.values.map(\.device).sorted { $0.address < $1.address }
        let cb = onDevicesChanged
        DispatchQueue.main.async { cb?(list) }
    }

    private func log(_ s: String) {
        let cb = onLog
        DispatchQueue.main.async { cb?(s) }
    }
}
#endif
