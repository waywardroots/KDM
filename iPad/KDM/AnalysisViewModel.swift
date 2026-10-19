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

    private let audio: AudioInputManager
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
    }

    nonisolated static let noteNames = KeyNotation.noteNames

    init(audio: AudioInputManager) {
        self.audio = audio
        let saved = UserDefaults.standard
        // DJ defaults: Camelot notation, minor keys on (needed for A codes and the
        // relative / parallel moves). A saved choice still wins.
        notation = saved.string(forKey: Keys.notation).flatMap(KeyNotation.init(rawValue:)) ?? .camelot
        showMinorKeys = saved.object(forKey: Keys.showMinorKeys) as? Bool ?? true
        stability = saved.string(forKey: Keys.stability).flatMap(KeyStability.init(rawValue:)) ?? .steady
        audio.analysis.majorOnly = !showMinorKeys
        applyStability()
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
        refreshKeyText()

        // BPM: shown when the tempo estimate is confident enough (>= 0.25).
        if let bpm = Self.reliableBpm(s) {
            bpmText = Self.bpmText(bpm)
            bpmIsReliable = true
        } else {
            bpmText = "—"
            bpmIsReliable = false
        }

        updateChannels(now: now, dt: dt)
    }

    private func updateChannels(now: Date, dt: Float) {
        if audio.strips.count != appliedStripCount { applyStability() }   // strips were rebuilt
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
            result.append(r)
        }
        if result != channels { channels = result }
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
                           key: DetectedKey(pitchClass: 9, isMinor: true), bpm: 124.0, levelDb: -11, hasSignal: true),
            ChannelReadout(id: 2, name: "Ch 2", channelsLabel: "USB 3 + 4",
                           key: DetectedKey(pitchClass: 4, isMinor: true), bpm: 124.0, levelDb: -14, hasSignal: true),
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
