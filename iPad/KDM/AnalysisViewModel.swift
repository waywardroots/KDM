import Foundation
import Combine

/// Polls the analysis engine ~30 times a second and turns its raw numbers into
/// what the screen shows: meter levels with fall-off and peak hold, the key and
/// BPM read-outs (using the same thresholds as the desktop plug-in).
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
    @Published private(set) var tunerText = "—"
    @Published private(set) var chroma: [Float] = Array(repeating: 0, count: 12)

    /// Musical ("C major") or Camelot ("8B"). Remembered between launches.
    @Published var notation: KeyNotation {
        didSet {
            defaults.set(notation.rawValue, forKey: Keys.notation)
            refreshKeyText()
        }
    }

    /// Off = major keys only (like the desktop plug-in). Remembered between launches.
    @Published var showMinorKeys: Bool {
        didSet {
            defaults.set(showMinorKeys, forKey: Keys.showMinorKeys)
            engine.majorOnly = !showMinorKeys
            engine.reset()
        }
    }

    private let engine: KDMAnalysisEngine
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
    }

    nonisolated static let noteNames = KeyNotation.noteNames

    init(engine: KDMAnalysisEngine) {
        self.engine = engine
        let saved = UserDefaults.standard
        notation = saved.string(forKey: Keys.notation).flatMap(KeyNotation.init(rawValue:)) ?? .musical
        showMinorKeys = saved.bool(forKey: Keys.showMinorKeys)
        engine.majorOnly = !showMinorKeys
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

    func resetKey() {
        engine.reset()
    }

    // MARK: -

    private func tick() {
        let now = Date()
        let dt = Float(now.timeIntervalSince(lastTick))
        lastTick = now

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
        chroma = chromaValues
        let chromaSum = chromaValues.reduce(0, +)
        if s.keyPitchClass >= 0, chromaSum > 1e-4, s.keyCorrelation >= 0.6 {
            lastKey = (s.keyPitchClass, s.keyIsMinor)
            keyDetail = String(format: "corr %.2f  ·  conf %d%%", s.keyCorrelation, Int((s.keyConfidence * 100).rounded()))
            keyIsReliable = true
        } else {
            lastKey = nil
            keyDetail = chromaSum > 1e-4 ? "no clear key" : "waiting…"
            keyIsReliable = false
        }
        refreshKeyText()

        // BPM: shown when the tempo estimate is confident enough (>= 0.25).
        if s.bpm > 0, s.bpmConfidence >= 0.25 {
            bpmText = String(format: "%.1f", s.bpm)
            bpmIsReliable = true
        } else {
            bpmText = "—"
            bpmIsReliable = false
        }

        tunerText = Self.tunerString(frequency: s.tunerFrequency)
    }

    private func refreshKeyText() {
        guard let key = lastKey else {
            keyText = "—"
            keyAltText = ""
            return
        }
        keyText = notation.format(pitchClass: key.pitchClass, isMinor: key.isMinor)
        keyAltText = notation.alternate.format(pitchClass: key.pitchClass, isMinor: key.isMinor)
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

    private static func tunerString(frequency: Float) -> String {
        guard frequency > 0 else { return "—" }
        let midi = 69 + 12 * log2(Double(frequency) / 440)
        let nearest = Int(midi.rounded())
        let cents = Int(((midi - Double(nearest)) * 100).rounded())
        let name = noteNames[((nearest % 12) + 12) % 12] + "\(nearest / 12 - 1)"
        return String(format: "%@  %+d¢  (%.1f Hz)", name, cents, frequency)
    }
}
