import Foundation
import Combine

/// A detected key: pitch class 0 = C … 11 = B.
struct DetectedKey: Equatable {
    let pitchClass: Int
    let isMinor: Bool
}

/// What one mixer channel card shows.
struct ChannelReadout: Identifiable, Equatable {
    let id: Int                 // left input channel index of the pair
    let name: String            // "Ch 1"
    let channelsLabel: String   // "USB 1 + 2"
    var key: DetectedKey?       // nil = no clear key
    var bpm: Float?             // nil = no confident tempo
    var levelDb: Float = AnalysisViewModel.floorDb   // peak with fall-off
    var hasSignal = false
    /// Set when the key comes from a media player ("Player 1"), not the audio.
    var player: String? = nil
    var track: String? = nil
    /// Players are connected but it isn't known yet which one feeds this channel.
    var matching = false
    /// Nothing has been heard on this channel yet and no player feeds it.
    var empty = false
}

/// Which media-player deck feeds a mixer channel.
enum PlayerAssignment: Equatable, Hashable {
    case auto                 // matched by watching faders and levels
    case none                 // audio only
    case deck(String)         // a deck label, "Player 1"

    var storageValue: String {
        switch self {
        case .auto: return "auto"
        case .none: return "none"
        case .deck(let label): return label
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "auto": self = .auto
        case "none": self = .none
        default: self = .deck(storageValue)
        }
    }
}

/// Polls the analysis engines ~30 times a second and turns their raw numbers into
/// what the screen shows: the main output (meter, key, BPM) and one read-out per
/// mixer channel, using the same thresholds as the desktop plug-in.
@MainActor
final class AnalysisViewModel: ObservableObject {

    struct Meter: Equatable {
        var level: Float = AnalysisViewModel.floorDb     // dBFS, with ~24 dB/s fall-off
        var peakHold: Float = AnalysisViewModel.floorDb  // dBFS, held ~1.5 s
        var rms: Float = AnalysisViewModel.floorDb       // dBFS
        var clipping = false                             // latched ~2 s after a clip
    }

    nonisolated static let floorDb: Float = -90

    /// Below this the input counts as silent ("no signal").
    nonisolated static let signalThresholdDb: Float = -60

    @Published private(set) var left = Meter()
    @Published private(set) var right = Meter()
    @Published private(set) var isStereo = true
    @Published private(set) var hasSignal = false

    @Published private(set) var keyText = "—"        // in the chosen notation
    @Published private(set) var keyAltText = ""       // the same key in the other notation
    @Published private(set) var keyDetail = "waiting…"
    @Published private(set) var keyIsReliable = false
    @Published private(set) var bpmText = "—"
    @Published private(set) var bpmIsReliable = false
    @Published private(set) var mainKey: DetectedKey?
    /// Note energy of the main output, C … B (the note bars), normalised 0…1.
    @Published private(set) var chroma: [Float] = Array(repeating: 0, count: 12)
    /// "43 buffers/s · 0 gaps" — refreshed once a second.
    @Published private(set) var audioHealth = ""
    private var lastHealth = Date.distantPast

    /// Level of each input stereo pair (dBFS, with fall-off): USB 1+2, 3+4, …
    @Published private(set) var pairLevels: [Float] = []
    /// Set while the "All USB inputs" card is on screen; the live meters only
    /// update then, so the main screen isn't redrawn for them 30 times a second.
    var showingAllInputs = false

    /// The deck the main key comes from ("Serato 2", "CDJ 1"), nil = from the audio.
    @Published private(set) var mainDeckLabel: String?
    /// One entry per mixer channel (empty for a 1-2 channel input).
    @Published private(set) var channels: [ChannelReadout] = []

    /// Musical ("C major") or Camelot ("8B"). Remembered between launches.
    @Published var notation: KeyNotation {
        didSet {
            defaults.set(notation.rawValue, forKey: Keys.notation)
            refreshKeyText()
        }
    }

    /// How quickly the key follows the music. Remembered; Steady by default.
    @Published var stability: KeyStability {
        didSet {
            defaults.set(stability.rawValue, forKey: Keys.stability)
            applyStability()
        }
    }

    /// Off = major keys only (like the desktop plug-in). Remembered between launches.
    @Published var showMinorKeys: Bool {
        didSet {
            defaults.set(showMinorKeys, forKey: Keys.showMinorKeys)
            engine.majorOnly = !showMinorKeys
            audio.strips.forEach { $0.engine.majorOnly = !showMinorKeys }
            audio.resetAllAnalysis()
        }
    }

    /// Per mixer channel (strip id): which player deck feeds it. Missing = auto.
    @Published var playerAssignments: [Int: PlayerAssignment] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: playerAssignments.map { (String($0.key), $0.value.storageValue) }),
                         forKey: Keys.playerAssignments)
        }
    }
    /// What auto-matching currently thinks: channel id -> deck label.
    @Published private(set) var autoMatches: [Int: String] = [:]

    private let audio: AudioInputManager
    let players: PlayerLink
    /// Evidence that deck (label) feeds channel (id): grows while the deck plays
    /// with its fader up and the channel has signal, shrinks on contradictions.
    private var matchScore: [String: [Int: Float]] = [:]
    private var engine: KDMAnalysisEngine { audio.analysis }
    private var channelLevels: [Int: (db: Float, lastSignal: Date)] = [:]
    /// `-KDMDemo` launch argument: fixed sample values, for screenshots/design.
    private let demo = ProcessInfo.processInfo.arguments.contains("-KDMDemo")
    private var timer: Timer?
    private var lastTick = Date()
    private var peakHoldTime = [Date.distantPast, Date.distantPast]
    private var clipTime = [Date.distantPast, Date.distantPast]
    private var lastSignalTime = Date.distantPast
    private var lastKey: (pitchClass: Int, isMinor: Bool)?   // nil = no reliable key
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let notation = "kdm.key.notation"
        static let showMinorKeys = "kdm.key.showMinor"
        static let stability = "kdm.key.stability"
        static let playerAssignments = "kdm.players.assignments"
        static let learnedMatches = "kdm.players.learned"
    }

    nonisolated static let noteNames = KeyNotation.noteNames

    init(audio: AudioInputManager, players: PlayerLink) {
        self.audio = audio
        self.players = players
        let saved = UserDefaults.standard
        let storedAssignments = saved.dictionary(forKey: Keys.playerAssignments) as? [String: String] ?? [:]
        playerAssignments = Dictionary(uniqueKeysWithValues: storedAssignments.compactMap { k, v in
            Int(k).map { ($0, PlayerAssignment(storageValue: v)) }
        })

        // DJ defaults: Camelot notation, minor keys on (needed for A codes and the
        // relative / parallel moves). A saved choice still wins.
        notation = saved.string(forKey: Keys.notation).flatMap(KeyNotation.init(rawValue:)) ?? .camelot
        showMinorKeys = saved.object(forKey: Keys.showMinorKeys) as? Bool ?? true
        stability = saved.string(forKey: Keys.stability).flatMap(KeyStability.init(rawValue:)) ?? .steady
        audio.analysis.majorOnly = !showMinorKeys
        applyStability()
        // Start from last session's matches so cards are right straight away.
        for (label, channel) in saved.dictionary(forKey: Keys.learnedMatches) as? [String: Int] ?? [:] {
            matchScore[label, default: [:]][channel] = 60
        }
    }

    /// Key in the chosen notation ("C major" / "8B"), or "—".
    func keyText(_ key: DetectedKey?) -> String {
        guard let key else { return "—" }
        return notation.format(pitchClass: key.pitchClass, isMinor: key.isMinor)
    }

    /// The same key in the other notation, or "".
    func keyAltText(_ key: DetectedKey?) -> String {
        guard let key else { return "" }
        return notation.alternate.format(pitchClass: key.pitchClass, isMinor: key.isMinor)
    }

    static func bpmText(_ bpm: Float?) -> String {
        bpm.map { String(format: "%.1f", $0) } ?? "—"
    }

    func start() {
        guard timer == nil else { return }
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Applies the stability setting to the main output and every channel engine.
    private func applyStability() {
        let t = stability.timing
        audio.analysis.setKeySmoothingSeconds(t.smoothing, holdSeconds: t.hold)
        audio.strips.forEach { $0.engine.setKeySmoothingSeconds(t.smoothing, holdSeconds: t.hold) }
        appliedStripCount = audio.strips.count
    }
    private var appliedStripCount = -1

    /// Last key / BPM per channel, kept while the channel's fader is down.
    private var heldChannel: [Int: (key: DetectedKey?, bpm: Float?)] = [:]

    func resetKey() {
        heldChannel.removeAll()
        audio.resetAllAnalysis()
    }

    // MARK: -

    private func tick() {
        let now = Date()
        let dt = Float(now.timeIntervalSince(lastTick))
        lastTick = now

        if demo {
            applyDemo()
            return
        }

        let s = engine.snapshot()

        isStereo = s.numChannels >= 2
        left  = updated(left,  peak: s.peakLeft,  rms: s.rmsLeft,  clipped: s.clippedLeft,  channel: 0, now: now, dt: dt)
        right = updated(right, peak: s.peakRight, rms: s.rmsRight, clipped: s.clippedRight, channel: 1, now: now, dt: dt)

        let loudest = max(Self.db(s.peakLeft), Self.db(s.peakRight))
        if loudest > Self.signalThresholdDb { lastSignalTime = now }
        hasSignal = now.timeIntervalSince(lastSignalTime) < 1.0

        // Key: shown when the chroma matches a key profile well enough (corr >= 0.6),
        // exactly like the desktop editor.
        let chromaValues = s.chroma.map { $0.floatValue }
        let chromaMax = chromaValues.max() ?? 0
        chroma = chromaMax > 1e-6 ? chromaValues.map { $0 / chromaMax } : Array(repeating: 0, count: 12)
        let chromaSum = chromaValues.reduce(0, +)
        if let key = Self.reliableKey(s) {
            lastKey = (key.pitchClass, key.isMinor)
            keyDetail = String(format: "corr %.2f  ·  conf %d%%", s.keyCorrelation, Int((s.keyConfidence * 100).rounded()))
            keyIsReliable = true
        } else {
            lastKey = nil
            keyDetail = chromaSum > 1e-4 ? "no clear key" : "waiting…"
            keyIsReliable = false
        }
        // BPM: shown when the tempo estimate is confident enough (>= 0.25).
        if let bpm = Self.reliableBpm(s) {
            bpmText = Self.bpmText(bpm)
            bpmIsReliable = true
        } else {
            bpmText = "—"
            bpmIsReliable = false
        }

        // Media players connected: the main key is the key of the deck leading
        // the mix (the master deck if it's audible, otherwise the one with its
        // fader highest), exactly as the player analysed it.
        let lead = mainPlayerDeck()
        mainDeckLabel = lead?.key != nil ? lead?.label : nil
        if let deck = lead, let key = deck.key {
            lastKey = (key.pitchClass, key.isMinor)
            keyIsReliable = true
            keyDetail = "from \(deck.label)" + (deck.trackLine.isEmpty ? "" : " · \(deck.trackLine)")
            if let bpm = deck.bpm {
                bpmText = Self.bpmText(bpm)
                bpmIsReliable = true
            }
        }
        refreshKeyText()

        updateChannels(now: now, dt: dt)
        updatePairLevels(dt: dt)
        if now.timeIntervalSince(lastHealth) >= 1 {
            lastHealth = now
            let h = audio.inputMeter.health()
            audioHealth = String(format: "%.0f buffers/s · %d gap%@ over 100 ms (longest %.0f ms) · %d restart%@ · %d auto-recover%@ · %d skipped · UI tick %.0f ms",
                                 h.buffersPerSecond, h.gaps, h.gaps == 1 ? "" : "s", h.longestGapMs,
                                 audio.restartCount, audio.restartCount == 1 ? "" : "s",
                                 audio.stallRecoveries, audio.stallRecoveries == 1 ? "y" : "ies", audio.worker.dropped, dt * 1000)
            audio.checkForStall()
        }
    }

    /// The deck leading the mix, or nil when no player deck is audible.
    private func mainPlayerDeck() -> PlayerDeck? {
        let audible = players.decks.filter { $0.isAudible && $0.key != nil }
        if let master = audible.first(where: { $0.isMaster }) { return master }
        return audible.max { ($0.fader ?? 0) < ($1.fader ?? 0) }
    }

    /// Learns which deck feeds which channel. The X1800's USB channel sends are
    /// post-fader, so the strongest evidence is a fader move: when a playing
    /// deck's fader goes up or down, only its own channel's level follows.
    ///   • fader moved and the channel's level moved the same way   +20
    ///   • fader moved but the channel's level didn't move           −10
    ///   • deck playing with its fader shut, yet the channel plays    −1 per tick
    ///   • deck playing, fader up, channel silent                     −1 per tick
    ///   • only one deck audible and the channel plays                +0.5 per tick
    /// Matches are remembered between launches (by player label).
    private func updateMatches(levels: [Int: Float], now: Date, dt: Float) {
        let decks = players.decks
        guard !decks.isEmpty else {
            if !autoMatches.isEmpty { autoMatches = [:] }
            return
        }
        let step = dt * 30          // ≈ 1 per tick at 30 Hz
        let audible = decks.filter { $0.playing && ($0.fader ?? 0) > 0.25 }

        // Fader-move evidence, sampled every 0.3 s.
        let window = now.timeIntervalSince(lastMatchSample) >= 0.3
        for deck in decks {
            var row = matchScore[deck.label] ?? [:]
            let fader = deck.fader ?? 0
            let faderDelta = fader - (lastFader[deck.label] ?? fader)
            for (channel, level) in levels {
                var score = row[channel] ?? 0
                let hasSignal = level > -50
                if window && deck.playing && abs(faderDelta) >= 0.08 {
                    let levelDelta = level - (lastLevel[channel] ?? level)
                    if levelDelta * Float(faderDelta) > 0 && abs(levelDelta) >= 2 { score += 20 }
                    else if abs(levelDelta) < 1 { score -= 10 }
                    else { score -= 15 }
                }
                if deck.playing && fader < 0.03 && hasSignal {
                    score -= step       // its fader is shut, so this channel's sound is someone else's
                }
                if deck.playing && fader > 0.25 && !hasSignal { score -= step }
                if audible.count == 1 && audible[0].label == deck.label && hasSignal { score += step * 0.5 }
                row[channel] = min(300, max(-300, score))
            }
            matchScore[deck.label] = row
        }
        if window {
            lastMatchSample = now
            for deck in decks { lastFader[deck.label] = deck.fader ?? 0 }
            lastLevel = levels
        }

        // Best pairs first, each deck and channel used once.
        var pairs: [(label: String, channel: Int, score: Float)] = []
        for (label, row) in matchScore where decks.contains(where: { $0.label == label }) {
            for (channel, score) in row where score >= 40 { pairs.append((label, channel, score)) }
        }
        pairs.sort { $0.score > $1.score }
        var result: [Int: String] = [:]
        var used: Set<String> = []
        for p in pairs where result[p.channel] == nil && !used.contains(p.label) {
            result[p.channel] = p.label
            used.insert(p.label)
        }
        if result != autoMatches {
            autoMatches = result
            // Remember for next time: label -> channel.
            defaults.set(Dictionary(uniqueKeysWithValues: result.map { ($0.value, $0.key) }), forKey: Keys.learnedMatches)
        }
    }
    private func updatePairLevels(dt: Float) {
        let peaks = audio.inputMeter.take(channels: audio.channelCount)
        guard showingAllInputs else {
            if !pairLevels.isEmpty { pairLevels = [] }
            return
        }
        let pairs = stride(from: 0, to: peaks.count, by: 2).map { i in
            Self.db(max(peaks[i], i + 1 < peaks.count ? peaks[i + 1] : 0))
        }
        var levels = pairLevels.count == pairs.count ? pairLevels : pairs
        for i in pairs.indices { levels[i] = max(pairs[i], levels[i] - 24 * dt) }
        if levels != pairLevels { pairLevels = levels }
    }

    /// Pioneer setups normally put player N on mixer channel N: start each new
    /// "CDJ N" just above the match threshold on "Ch N", so its card is right
    /// at once; fader evidence still overrides it if the wiring is different.
    private func seedPioneerMatches() {
        for deck in players.decks where deck.label.hasPrefix("CDJ ") && matchScore[deck.label] == nil {
            guard let n = Int(deck.label.dropFirst(4)),
                  let strip = audio.strips.first(where: { $0.name == "Ch \(n)" }) else { continue }
            matchScore[deck.label] = [strip.id: 45]
        }
    }

    private var lastMatchSample = Date.distantPast
    private var lastFader: [String: Double] = [:]
    private var lastLevel: [Int: Float] = [:]

    /// The player deck feeding a channel, from the manual choice or auto-matching.
    func playerDeck(forChannel id: Int) -> PlayerDeck? {
        let label: String?
        switch playerAssignments[id] ?? .auto {
        case .none: label = nil
        case .deck(let l): label = l
        case .auto: label = autoMatches[id]
        }
        guard let label else { return nil }
        return players.decks.first { $0.label == label }
    }

    private func updateChannels(now: Date, dt: Float) {
        if audio.strips.count != appliedStripCount { applyStability() }   // strips were rebuilt
        var levels: [Int: Float] = [:]
        var result: [ChannelReadout] = []
        for strip in audio.strips {
            let s = strip.engine.snapshot()
            let peakDb = max(Self.db(s.peakLeft), Self.db(s.peakRight))
            var state = channelLevels[strip.id] ?? (db: Self.floorDb, lastSignal: .distantPast)
            state.db = max(peakDb, state.db - 24 * dt)
            if peakDb > Self.signalThresholdDb { state.lastSignal = now }
            channelLevels[strip.id] = state

            let left = strip.selection.leftIndex + 1
            var r = ChannelReadout(id: strip.id, name: strip.name, channelsLabel: "USB \(left) + \(left + 1)")
            r.levelDb = state.db
            r.hasSignal = now.timeIntervalSince(state.lastSignal) < 1.0
            // Fader down: the engine pauses on silence and keeps its key, and we also
            // remember the last key/BPM here so the card keeps showing them (dimmed)
            // until the channel plays something else or keys are reset.
            var held = heldChannel[strip.id] ?? (key: nil, bpm: nil)
            if let key = Self.reliableKey(s) { held.key = key }
            else if r.hasSignal { held.key = nil }                // playing, but no clear key
            if let bpm = Self.reliableBpm(s) { held.bpm = bpm }
            else if r.hasSignal { held.bpm = nil }
            heldChannel[strip.id] = held
            r.key = held.key
            r.bpm = held.bpm
            levels[strip.id] = state.db      // peak with fall-off, so beats' gaps don't count as silence
            // A media player feeds this channel: use its key and tempo (they're
            // there as soon as a track loads, even with the fader down).
            let everHeard = state.lastSignal != .distantPast
            if !players.decks.isEmpty, playerAssignments[strip.id] ?? .auto == .auto, autoMatches[strip.id] == nil {
                if everHeard { r.matching = true } else { r.empty = true }
            } else if !everHeard && playerDeck(forChannel: strip.id) == nil {
                r.empty = true
            }
            if let deck = playerDeck(forChannel: strip.id), deck.loaded {
                r.player = deck.label
                r.track = deck.trackLine.isEmpty ? nil : deck.trackLine
                if let key = deck.key { r.key = key }
                if let bpm = deck.bpm { r.bpm = bpm }
            }
            result.append(r)
        }
        // No per-channel audio (e.g. Serato on a laptop, or a 2-channel input):
        // show each player / software deck as its own card instead.
        if result.isEmpty {
            for (i, deck) in players.decks.filter(\.loaded).enumerated() {
                var r = ChannelReadout(id: 10_000 + i, name: deck.label, channelsLabel: "")
                r.key = deck.key
                r.bpm = deck.bpm
                r.player = deck.isMaster ? "Leading" : nil
                r.track = deck.trackLine.isEmpty ? nil : deck.trackLine
                r.hasSignal = deck.playing
                r.levelDb = deck.playing ? -12 : Self.floorDb
                result.append(r)
            }
        }
        if result != channels { channels = result }
        seedPioneerMatches()
        updateMatches(levels: levels, now: now, dt: dt)
    }

    /// Key shown only when the chroma matches a key profile well (corr >= 0.6),
    /// exactly like the desktop editor.
    private static func reliableKey(_ s: KDMAnalysisSnapshot) -> DetectedKey? {
        let chromaSum = s.chroma.reduce(Float(0)) { $0 + $1.floatValue }
        guard s.keyPitchClass >= 0, chromaSum > 1e-4, s.keyCorrelation >= 0.6 else { return nil }
        return DetectedKey(pitchClass: s.keyPitchClass, isMinor: s.keyIsMinor)
    }

    private static func reliableBpm(_ s: KDMAnalysisSnapshot) -> Float? {
        s.bpm > 0 && s.bpmConfidence >= 0.25 ? s.bpm : nil
    }

    /// Fixed sample values (launch argument -KDMDemo), so the layout can be
    /// reviewed in the simulator without a mixer.
    private func applyDemo() {
        hasSignal = true
        isStereo = true
        left = Meter(level: -9, peakHold: -7, rms: -16, clipping: false)
        right = Meter(level: -10, peakHold: -8, rms: -17, clipping: false)
        lastKey = (9, true)                       // A minor = 8A
        keyDetail = "corr 0.84  ·  conf 62%"
        keyIsReliable = true
        refreshKeyText()
        bpmText = "124.0"
        // A natural minor: strong A, C, E; weaker scale notes; little else.
        chroma = [0.62, 0.05, 0.30, 0.08, 0.78, 0.22, 0.04, 0.35, 0.06, 1.0, 0.07, 0.18]
        bpmIsReliable = true
        channels = [
            ChannelReadout(id: 0, name: "Ch 1", channelsLabel: "USB 1 + 2",
                           key: DetectedKey(pitchClass: 9, isMinor: true), bpm: 124.0, levelDb: -11, hasSignal: true,
                           player: "Player 1", track: "Demo Artist – Demo Track"),
            ChannelReadout(id: 2, name: "Ch 2", channelsLabel: "USB 3 + 4",
                           key: DetectedKey(pitchClass: 4, isMinor: true), bpm: 124.0, levelDb: -14, hasSignal: true,
                           player: "Player 2", track: "Another Artist – Second Track"),
            ChannelReadout(id: 4, name: "Ch 3", channelsLabel: "USB 5 + 6",
                           key: DetectedKey(pitchClass: 8, isMinor: false), bpm: 128.0, levelDb: -26, hasSignal: true),
            ChannelReadout(id: 6, name: "Ch 4", channelsLabel: "USB 7 + 8",
                           key: DetectedKey(pitchClass: 11, isMinor: true), bpm: 126.0, levelDb: -20, hasSignal: true),
        ]
    }

    private func refreshKeyText() {
        mainKey = lastKey.map { DetectedKey(pitchClass: $0.pitchClass, isMinor: $0.isMinor) }
        keyText = keyText(mainKey)
        keyAltText = keyAltText(mainKey)
    }

    private func updated(_ m: Meter, peak: Float, rms: Float, clipped: Bool,
                         channel: Int, now: Date, dt: Float) -> Meter {
        var m = m
        let peakDb = Self.db(peak)

        // Instant attack, ~24 dB/s release.
        m.level = max(peakDb, m.level - 24 * dt)
        m.rms = max(Self.db(rms), m.rms - 24 * dt)

        if peakDb >= m.peakHold || now.timeIntervalSince(peakHoldTime[channel]) > 1.5 {
            m.peakHold = peakDb >= m.peakHold ? peakDb : m.level
            peakHoldTime[channel] = now
        }

        if clipped { clipTime[channel] = now }
        m.clipping = now.timeIntervalSince(clipTime[channel]) < 2.0
        return m
    }

    nonisolated static func db(_ linear: Float) -> Float {
        linear > 0 ? max(floorDb, 20 * log10(linear)) : floorDb
    }
}
