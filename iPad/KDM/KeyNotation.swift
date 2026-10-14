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
