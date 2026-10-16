import SwiftUI

/// A position on the Camelot wheel: 1…12 and A (minor) / B (major).
struct CamelotKey: Equatable {
    let number: Int      // 1…12
    let isMinor: Bool    // A = minor, B = major

    init(number: Int, isMinor: Bool) {
        self.number = ((number - 1) % 12 + 12) % 12 + 1
        self.isMinor = isMinor
    }

    init(_ key: DetectedKey) {
        self.init(number: KeyNotation.camelotNumber(pitchClass: key.pitchClass, isMinor: key.isMinor),
                  isMinor: key.isMinor)
    }

    /// Back to a musical key. Each wheel step is a fifth (7 semitones) and 7 × 7 ≡ 1
    /// (mod 12), so the major key at number n has root 7 × (n − 8) semitones above C
    /// (8B = C major); a minor key's root is 3 semitones below its relative major's.
    var detectedKey: DetectedKey {
        let majorRoot = ((7 * (number - 8)) % 12 + 12) % 12
        let root = isMinor ? (majorRoot + 9) % 12 : majorRoot
        return DetectedKey(pitchClass: root, isMinor: isMinor)
    }

    func shifted(by steps: Int) -> CamelotKey { CamelotKey(number: number + steps, isMinor: isMinor) }
}

/// How well two keys mix.
enum MixCategory {
    case smooth   // same notes or 6 of 7 shared: blends cleanly
    case energy   // deliberate change: lift or mood shift
    case clash

    var color: Color {
        switch self {
        case .smooth: return .green
        case .energy: return .orange
        case .clash:  return Color.white.opacity(0.35)
        }
    }

    var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .energy: return "Energy"
        case .clash:  return "Clash"
        }
    }
}

/// The Camelot-wheel moves DJs use to go from one key to the next.
enum MixMove: CaseIterable, Identifiable {
    case same
    case down          // −1: down a fifth (subdominant)
    case up            // +1: up a fifth (dominant)
    case relative      // same number, A ↔ B: same notes, minor ↔ major
    case energyBoost   // +2: up a whole step
    case semitoneUp    // +7 (≡ −5): up one semitone
    case parallel      // same root, minor ↔ major (major → minor: −3 A, minor → major: +3 B)

    var id: Self { self }

    /// Short label for chips and badges.
    var label: String {
        switch self {
        case .same:        return "Same"
        case .down:        return "−1"
        case .up:          return "+1"
        case .relative:    return "Relative"
        case .energyBoost: return "Energy +2"
        case .semitoneUp:  return "Semitone +1"
        case .parallel:    return "Parallel"
        }
    }

    var category: MixCategory {
        switch self {
        case .same, .down, .up, .relative: return .smooth
        case .energyBoost, .semitoneUp, .parallel: return .energy
        }
    }

    /// The key this move leads to from `key`.
    func target(from key: CamelotKey) -> CamelotKey {
        switch self {
        case .same:        return key
        case .down:        return key.shifted(by: -1)
        case .up:          return key.shifted(by: 1)
        case .relative:    return CamelotKey(number: key.number, isMinor: !key.isMinor)
        case .energyBoost: return key.shifted(by: 2)
        case .semitoneUp:  return key.shifted(by: 7)
        case .parallel:    return key.isMinor ? CamelotKey(number: key.number + 3, isMinor: false)
                                              : CamelotKey(number: key.number - 3, isMinor: true)
        }
    }

    /// The moves shown as "next keys" under the main output, in this order.
    static let suggestions: [MixMove] = [.down, .up, .relative, .energyBoost, .semitoneUp, .parallel]

    /// The move that takes `from` to `to`, if it's one of these (else a clash).
    static func move(from: DetectedKey, to: DetectedKey) -> MixMove? {
        let a = CamelotKey(from), b = CamelotKey(to)
        return allCases.first { $0.target(from: a) == b }
    }
}

/// How one key relates to another for mixing: a known move, or a clash.
enum MixMatch: Equatable {
    case move(MixMove)
    case clash

    init(from: DetectedKey, to: DetectedKey) {
        self = MixMove.move(from: from, to: to).map(MixMatch.move) ?? .clash
    }

    var category: MixCategory {
        switch self {
        case .move(let m): return m.category
        case .clash:       return .clash
        }
    }

    /// e.g. "Smooth · +1", "Energy · Parallel", "Clash".
    var label: String {
        switch self {
        case .move(let m): return "\(m.category.title) · \(m.label)"
        case .clash:       return MixCategory.clash.title
        }
    }
}
