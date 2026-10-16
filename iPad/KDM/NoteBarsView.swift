import SwiftUI

/// The note bars: how strongly each of the 12 notes (C … B) is playing in the
/// main output, which is what the key is worked out from. Notes in the detected
/// key are highlighted; the key's root note is brightest.
struct NoteBarsView: View {
    let values: [Float]           // 12 values, 0…1 (C … B)
    let key: DetectedKey?
    var showsLabels = true

    static let accent = Color(red: 230 / 255, green: 162 / 255, blue: 60 / 255)   // logo orange

    var body: some View {
        let inKey = Self.scaleNotes(of: key)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<12, id: \.self) { i in
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let v = i < values.count ? CGFloat(max(0, min(1, values[i]))) : 0
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(note: i, inKey: inKey))
                                .frame(height: max(2, geo.size.height * v))
                        }
                    }
                    if showsLabels {
                        Text(KeyNotation.noteNames[i])
                            .font(.caption.weight(key?.pitchClass == i ? .bold : .regular))
                            .foregroundStyle(key?.pitchClass == i ? Self.accent : .secondary)
                    }
                }
            }
        }
        .animation(.linear(duration: 0.08), value: values)
        .accessibilityElement()
        .accessibilityLabel("Note bars")
    }

    private func barColor(note: Int, inKey: Set<Int>) -> Color {
        if key?.pitchClass == note { return Self.accent }
        if inKey.contains(note) { return Self.accent.opacity(0.55) }
        return Color.white.opacity(0.22)
    }

    /// The 7 notes of the key's (natural) scale.
    static func scaleNotes(of key: DetectedKey?) -> Set<Int> {
        guard let key else { return [] }
        let steps = key.isMinor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        return Set(steps.map { (key.pitchClass + $0) % 12 })
    }
}
