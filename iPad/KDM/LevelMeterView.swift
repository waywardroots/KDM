import SwiftUI

/// Horizontal level meter in dBFS: green up to -18, yellow to -6, red above, a
/// peak-hold tick, a thin RMS line and a latched clip lamp.
struct LevelMeterView: View {
    let label: String
    let meter: AnalysisViewModel.Meter

    static let minDb: Float = -60
    static let ticks: [Float] = [-60, -48, -36, -24, -18, -12, -6, 0]

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))

                    // Level bar, coloured by zone.
                    LinearGradient(stops: [
                        .init(color: .green,  location: 0),
                        .init(color: .green,  location: Self.position(-18)),
                        .init(color: .yellow, location: Self.position(-18)),
                        .init(color: .yellow, location: Self.position(-6)),
                        .init(color: .red,    location: Self.position(-6)),
                        .init(color: .red,    location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: w * Self.position(meter.level))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    // RMS (average loudness) line.
                    Rectangle()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: max(0, w * Self.position(meter.rms)), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)

                    // Peak hold.
                    if meter.peakHold > Self.minDb {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2)
                            .offset(x: max(0, w * Self.position(meter.peakHold) - 2))
                    }
                }
            }
            .frame(height: 22)

            Text(meter.peakHold > Self.minDb ? String(format: "%5.1f", meter.peakHold) : "  -∞ ")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Circle()
                .fill(meter.clipping ? Color.red : Color.white.opacity(0.12))
                .frame(width: 14, height: 14)
                .accessibilityLabel(meter.clipping ? "Clipping" : "Not clipping")
        }
    }

    /// 0…1 position of a dB value on the meter.
    static func position(_ db: Float) -> CGFloat {
        CGFloat(min(1, max(0, (db - minDb) / -minDb)))
    }
}

/// dB scale shown under the meters.
struct MeterScaleView: View {
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18, height: 1)
            GeometryReader { geo in
                ForEach(LevelMeterView.ticks, id: \.self) { db in
                    Text(db == 0 ? "0" : "\(Int(db))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: geo.size.width * LevelMeterView.position(db), y: 6)
                }
            }
            .frame(height: 12)
            Color.clear.frame(width: 52 + 10 + 14, height: 1)
        }
    }
}
