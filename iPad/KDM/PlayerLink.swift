import Foundation
import Combine

/// One deck on a media player (SC6000 layer), as the app uses it.
struct PlayerDeck: Identifiable, Equatable {
    let id: String              // stable for this session
    let label: String           // "Player 1", "Player 1 B"
    var key: DetectedKey?       // the key Engine DJ analysed for the track
    var keyText: String?        // as the player shows it ("Dm", "8A" …)
    var bpm: Float?
    var title: String?
    var artist: String?
    var loaded = false
    var playing = false
    var fader: Double?          // the player's view of its mixer fader, 0…1
    var isMaster = false

    /// Playing with its fader up, so it's in the mix.
    var isAudible: Bool { playing && (fader ?? 1) > 0.05 }

    var trackLine: String {
        [artist, title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " – ")
    }
}

/// Connects to DJ media players over the network and publishes their decks: the
/// key and tempo each player has analysed for its track, whether it's playing,
/// and whether its channel is up.
///   • Denon / Engine DJ (SC6000 …) over StageLinQ: labels "Player 1", "Player 1 B"
///   • Pioneer DJ (CDJ-3000 …) over Pro DJ Link: labels "CDJ 1" …
///     Key needs a CDJ-3000; "up" comes from the mixer's on-air signal (DJM-A9).
///
/// Works over Wi-Fi or Ethernet (plug the iPad into a free port on the mixer).
/// On iPad it needs Apple's multicast networking permission
/// (com.apple.developer.networking.multicast) to find the players.
@MainActor
final class PlayerLink: ObservableObject {

    enum Status: Equatable {
        case off
        case searching
        case connected(players: Int)
        case needsPermission          // iPadOS blocked the network search
        case failed(String)
    }

    /// Remembered between launches; on by default.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    @Published private(set) var status: Status = .off
    @Published private(set) var decks: [PlayerDeck] = []
    /// Recent connection messages, for the Inputs panel.
    @Published private(set) var log: [String] = []

    private static let enabledKey = "kdm.players.enabled"
    /// Our StageLinQ identity. A fresh one each time the connection starts:
    /// with one fixed identity the players kept answering the handshake but
    /// offering no services (the Mac monitor, with a fresh identity per run,
    /// got them straight away). If the players keep refusing, KDM also switches
    /// to a new identity by itself (see `append`).
    private var token = Token.random()
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private var client: StageLinQClient?
    private var pioneer: ProDJLinkClient?
    private var deviceCount = 0
    private var pioneerCount = 0
    private var denonDecks: [PlayerDeck] = []
    private var cdjDecks: [PlayerDeck] = []
    /// Set once any CDJ reports "on air": the mixer sends on-air, so a CDJ that
    /// isn't on air has its fader down.
    private var onAirKnown = false
    private var permissionBlocked = false

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard enabled, client == nil else { return }
        let c = StageLinQClient(name: "kdm", softwareName: "KDM", softwareVersion: "1.0", token: token)
        c.onLog = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        c.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                guard let self else { return }
                self.deviceCount = devices.filter { $0.softwareName != "JM08" }.count
                self.updateStatus()
            }
        }
        c.onChange = { [weak self] decks, _ in
            Task { @MainActor in self?.update(decks) }
        }
        do {
            try c.start()
            client = c
            status = .searching
        } catch {
            status = .failed(error.localizedDescription)
            append("Couldn't start: \(error.localizedDescription)")
        }
        startPioneer()
    }

    private func startPioneer() {
        guard pioneer == nil else { return }
        let p = ProDJLinkClient(name: "KDM")
        p.onLog = { [weak self] line in
            Task { @MainActor in self?.append("Pioneer: " + line) }
        }
        p.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                guard let self else { return }
                self.pioneerCount = devices.filter { $0.kind == .player }.count
                self.updateStatus()
            }
        }
        p.onStatus = { [weak self] players in
            Task { @MainActor in self?.updatePioneer(players) }
        }
        do {
            try p.start()
            pioneer = p
            if client == nil { status = .searching }
        } catch {
            append("Pioneer: couldn't start: \(error.localizedDescription) (is rekordbox running on this device?)")
        }
    }

    private func updatePioneer(_ players: [CDJStatus]) {
        if players.contains(where: { $0.onAir }) { onAirKnown = true }
        cdjDecks = players.map { p in
            let key = p.currentKey.map { DetectedKey(pitchClass: $0.pitchClass, isMinor: $0.isMinor) }
            return PlayerDeck(id: "cdj#\(p.player)", label: "CDJ \(p.player)",
                              key: key, keyText: p.currentKey?.description,
                              bpm: p.effectiveBPM.map(Float.init),
                              title: nil, artist: nil,
                              loaded: p.loaded, playing: p.playing,
                              fader: onAirKnown ? (p.onAir ? 1 : 0) : nil,
                              isMaster: p.isMaster)
        }
        publishDecks()
    }

    private func publishDecks() {
        let all = (denonDecks + cdjDecks).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        if all != decks { decks = all }
        updateStatus()
    }

    func stop() {
        client?.stop()
        client = nil
        pioneer?.stop()
        pioneer = nil
        decks = []
        denonDecks = []
        cdjDecks = []
        deviceCount = 0
        pioneerCount = 0
        status = .off
    }

    /// Stop and start again (e.g. after plugging in the Ethernet adapter).
    func restart() {
        stop()
        permissionBlocked = false
        refusals = 0
        token = Token.random()
        start()
    }

    /// Players answering the handshake but offering no services, in a row.
    private var refusals = 0
    private var heardDevices = false

    // MARK: -

    private func update(_ statuses: [DeckStatus]) {
        let new = statuses.map { s in
            PlayerDeck(id: s.id, label: s.label,
                       key: s.key.map { DetectedKey(pitchClass: $0.pitchClass, isMinor: $0.isMinor) },
                       keyText: s.keyText, bpm: s.bpm.map(Float.init),
                       title: s.title, artist: s.artist, loaded: s.loaded, playing: s.playing,
                       fader: s.faderPosition, isMaster: s.isMaster)
        }
        denonDecks = new
        publishDecks()
    }

    private func updateStatus() {
        guard client != nil || pioneer != nil else { status = .off; return }
        if deviceCount + pioneerCount > 0 {
            status = .connected(players: deviceCount + pioneerCount)
        } else {
            status = permissionBlocked ? .needsPermission : .searching
        }
    }

    private func append(_ line: String) {
        // A real permission block means we never hear any device at all.
        if line.hasPrefix("Found ") || line.hasPrefix("Pioneer: Found ") {
            heardDevices = true
            if permissionBlocked { permissionBlocked = false; updateStatus() }
        } else if !heardDevices && line.contains("Operation not permitted") {
            permissionBlocked = true
            updateStatus()
        }
        if line.contains("no reply from the device") {
            refusals += 1
        } else if line.contains(" offers StateMap") {
            refusals = 0
        }
        log.append("\(Self.timeFormat.string(from: Date()))  \(line)")
        print("[KDM players] \(line)")      // also in Xcode's console when run from Xcode
        if log.count > 200 { log.removeFirst(log.count - 200) }

        // Refused four times (two rounds with two players) and nothing loaded:
        // start over with a new identity.
        if refusals >= 4 && decks.isEmpty {
            let old = token
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == old else { return }
                self.log.append("\(Self.timeFormat.string(from: Date()))  Players keep refusing; switching to a new identity")
                self.restart()
            }
        }
    }
}
