import Foundation

/// A key as reported by Engine DJ: pitch class 0 = C … 11 = B, major or minor.
public struct MusicalKey: Equatable, Hashable {
    public let pitchClass: Int
    public let isMinor: Bool

    public init(pitchClass: Int, isMinor: Bool) {
        self.pitchClass = ((pitchClass % 12) + 12) % 12
        self.isMinor = isMinor
    }

    /// Parses the key text Engine sends in `Track/CurrentKey`. Engine shows keys in
    /// the notation chosen on the player, so all common ones are accepted:
    ///   Camelot  "8A", "12B"
    ///   Open Key "1m", "6d"
    ///   Musical  "Am", "A min", "A minor", "F#m", "Bb", "Ebm", "C# major", "D♭"
    /// Returns nil for anything else (empty, "-", unknown formats).
    public init?(parsing text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Camelot / Open Key: a number 1-12 and a letter.
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, let n = Int(digits), (1...12).contains(n) {
            let suffix = s.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
            switch suffix {
            case "a": self.init(camelot: n, isMinor: true); return
            case "b": self.init(camelot: n, isMinor: false); return
            // Open Key n is Camelot n + 7 (1d = C major = 8B, 1m = A minor = 8A).
            case "m": self.init(camelot: (n + 6) % 12 + 1, isMinor: true); return
            case "d": self.init(camelot: (n + 6) % 12 + 1, isMinor: false); return
            default: return nil
            }
        }

        // Musical: note letter, optional accidental, optional mode.
        var chars = Array(s)
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let root = letters[Character(chars[0].uppercased())] else { return nil }
        chars.removeFirst()
        var pc = root
        if let c = chars.first {
            if c == "#" || c == "♯" { pc += 1; chars.removeFirst() }
            else if c == "b" || c == "♭" { pc -= 1; chars.removeFirst() }
        }
        let mode = String(chars).trimmingCharacters(in: .whitespaces)
        switch mode {
        case "", "M", "maj", "Maj", "major", "Major", "MAJ", "MAJOR":
            self.init(pitchClass: pc, isMinor: false)
        case "m", "min", "Min", "minor", "Minor", "MIN", "MINOR", "-":
            self.init(pitchClass: pc, isMinor: true)
        default:
            return nil
        }
    }

    /// Camelot number 1-12 (A = minor, B = major) → key. 8B = C major; each step
    /// is a fifth, so the major root is 7 × (n − 8) semitones above C, and a minor
    /// key's root is 3 semitones below its relative major's.
    public init(camelot n: Int, isMinor: Bool) {
        let majorRoot = ((7 * (n - 8)) % 12 + 12) % 12
        self.init(pitchClass: isMinor ? majorRoot + 9 : majorRoot, isMinor: isMinor)
    }

    public var camelot: String {
        let relativeMajor = isMinor ? (pitchClass + 3) % 12 : pitchClass
        return "\((relativeMajor * 7 + 7) % 12 + 1)\(isMinor ? "A" : "B")"
    }

    public var name: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[pitchClass] + (isMinor ? " minor" : " major")
    }
}
