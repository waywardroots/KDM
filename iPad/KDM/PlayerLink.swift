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

/// Connects to Denon / Engine DJ media players over the network (StageLinQ) and
/// publishes their decks: the key and tempo each player has analysed for its
/// track, whether it's playing, and where its fader is.
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
    private static let tokenKey = "kdm.players.token"

    /// The same StageLinQ identity on every launch. Players keep a session open
    /// for a while after the app is closed; with a new random token each time,
    /// a relaunched KDM looked like an unknown second device at the same address
    /// and the players never sent their service list.
    private static func savedToken() -> Token {
        if let bytes = UserDefaults.standard.array(forKey: tokenKey) as? [Int], bytes.count == 16 {
            return Token(bytes.map { UInt8(truncatingIfNeeded: $0) })
        }
        let token = Token.random()
        UserDefaults.standard.set(token.bytes.map(Int.init), forKey: tokenKey)
        return token
    }
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private var client: StageLinQClient?
    private var deviceCount = 0
    private var permissionBlocked = false

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard enabled, client == nil else { return }
        let c = StageLinQClient(name: "kdm", softwareName: "KDM", softwareVersion: "1.0", token: Self.savedToken())
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
    }

    func stop() {
        client?.stop()
        client = nil
        decks = []
        deviceCount = 0
        status = .off
    }

    /// Stop and start again (e.g. after plugging in the Ethernet adapter).
    func restart() {
        stop()
        permissionBlocked = false
        start()
    }

    // MARK: -

    private func update(_ statuses: [DeckStatus]) {
        let new = statuses.map { s in
            PlayerDeck(id: s.id, label: s.label,
                       key: s.key.map { DetectedKey(pitchClass: $0.pitchClass, isMinor: $0.isMinor) },
                       keyText: s.keyText, bpm: s.bpm.map(Float.init),
                       title: s.title, artist: s.artist, loaded: s.loaded, playing: s.playing,
                       fader: s.faderPosition, isMaster: s.isMaster)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        if new != decks { decks = new }
        updateStatus()
    }

    private func updateStatus() {
        guard client != nil else { status = .off; return }
        if deviceCount > 0 {
            status = .connected(players: deviceCount)
        } else {
            status = permissionBlocked ? .needsPermission : .searching
        }
    }

    private func append(_ line: String) {
        if line.contains("multicast networking entitlement") || line.contains("Operation not permitted") {
            permissionBlocked = true
            updateStatus()
        }
        log.append("\(Self.timeFormat.string(from: Date()))  \(line)")
        print("[KDM players] \(line)")      // also in Xcode's console when run from Xcode
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
