import Foundation

/// How a detected key is written on screen. The user picks one; it's remembered.
enum KeyNotation: String, CaseIterable, Identifiable {
    /// "C major", "A minor"
    case musical
    /// Camelot wheel: "8B" (C major), "8A" (A minor). Neighbouring numbers and the
    /// A/B partner with the same number mix harmonically.
    case camelot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .musical: return "Musical"
        case .camelot: return "Camelot"
        }
    }

    /// The other notation, shown small under the main read-out.
    var alternate: KeyNotation {
        self == .musical ? .camelot : .musical
    }

    /// Writes a key. `pitchClass`: 0 = C … 11 = B.
    func format(pitchClass: Int, isMinor: Bool) -> String {
        switch self {
        case .musical: return KeyNotation.musicalName(pitchClass: pitchClass, isMinor: isMinor)
        case .camelot: return KeyNotation.camelotCode(pitchClass: pitchClass, isMinor: isMinor)
        }
    }

    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func musicalName(pitchClass: Int, isMinor: Bool) -> String {
        noteNames[((pitchClass % 12) + 12) % 12] + (isMinor ? " minor" : " major")
    }

    /// Camelot code. Major keys are "B", minor keys "A". C major is 8B and each step
    /// round the circle of fifths (C → G → D …) adds one: G major = 9B, F major = 7B.
    /// A minor key has the same number as its relative major (A minor = 8A, the
    /// relative of C major).
    static func camelotNumber(pitchClass: Int, isMinor: Bool) -> Int {
        let pc = ((pitchClass % 12) + 12) % 12
        let relativeMajor = isMinor ? (pc + 3) % 12 : pc
        return (relativeMajor * 7 + 7) % 12 + 1
    }

    static func camelotCode(pitchClass: Int, isMinor: Bool) -> String {
        "\(camelotNumber(pitchClass: pitchClass, isMinor: isMinor))\(isMinor ? "A" : "B")"
    }
}

/// How quickly the shown key follows the music. Chord progressions make the
/// moment-to-moment key wander (e.g. C ↔ Am ↔ G in a I–vi–IV–V), so a DJ "track
/// key" needs long averaging. Measured on a C-major I–vi–IV–V loop followed by a
/// move to G (tests/AnalysisEngineTest.cpp):
///   Fast      3.4 s / 0.7 s: 27 wrong changes in 90 s, follows a real change in ~1 s
///   Balanced  15 s / 5 s:     2 wrong changes,         follows in ~19 s
///   Steady    30 s / 8 s:     0 wrong changes,         follows in ~25 s
enum KeyStability: String, CaseIterable, Identifiable {
    case fast, balanced, steady

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast:     return "Fast"
        case .balanced: return "Balanced"
        case .steady:   return "Steady"
        }
    }

    var footnote: String {
        switch self {
        case .fast:     return "Fast: follows every chord change. Best for checking a short loop."
        case .balanced: return "Balanced: settles on the track key; a new key shows after about 20 s."
        case .steady:   return "Steady: ignores chord changes; a new track's key shows after about 25 s. Tap Reset keys to restart it straight away."
        }
    }

    /// (averaging seconds, hold seconds)
    var timing: (smoothing: Double, hold: Double) {
        switch self {
        case .fast:     return (3.4, 0.7)
        case .balanced: return (15, 5)
        case .steady:   return (30, 8)
        }
    }
}
