import SwiftUI
import UIKit

/// Main screen: header (logo, KDM, signal status, Inputs button), level meter
/// and the key / BPM read-outs. Input selection and diagnostics live in the
/// Inputs panel.
struct ContentView: View {
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var model: AnalysisViewModel

    @State private var showInputs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                switch audio.status {
                case .permissionDenied: permissionCard
                case .failed(let message): messageCard("Audio couldn't start", message)
                default: EmptyView()
                }
                meterCard
                readoutCard
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Color(white: 0.07).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            // Used by the CI screenshot job to capture the Inputs panel.
            if ProcessInfo.processInfo.arguments.contains("-KDMShowInputs") {
                showInputs = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            // Company logo (Assets.xcassets/Logo). Already has rounded corners.
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 52, height: 52)
                .accessibilityLabel("Fuzzy Audio")
            Text("KDM")
                .font(.largeTitle.weight(.bold))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                statusBadge
                Text(sourceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            inputsButton
        }
    }

    private var inputsButton: some View {
        Button {
            showInputs = true
        } label: {
            Label("Inputs", systemImage: "cable.connector")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showInputs, arrowEdge: .top) {
            InputsPanel(audio: audio, model: model) { showInputs = false }
                .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 620)
        }
        .accessibilityHint("Choose the input source and channels, and see audio diagnostics")
    }

    /// e.g. "X1800 Prime · Channels 9 + 10", shown under the status badge.
    private var sourceSummary: String {
        guard let input = audio.currentInput else { return "No input" }
        guard audio.channelCount > 0 else { return input.name }
        return "\(input.name) · \(audio.channelSelection.label)"
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch audio.status {
            case .starting:         return ("Starting…", .gray)
            case .running:          return model.hasSignal ? ("Signal", .green) : ("No signal", .orange)
            case .noInput:          return ("No input", .orange)
            case .permissionDenied: return ("No permission", .red)
            case .failed:           return ("Error", .red)
            }
        }()
        return Label(text, systemImage: "circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    // MARK: - Meter

    private var meterCard: some View {
        Card(title: "Level") {
            VStack(spacing: 8) {
                LevelMeterView(label: model.isStereo ? "L" : "M", meter: model.left)
                if model.isStereo {
                    LevelMeterView(label: "R", meter: model.right)
                }
                MeterScaleView()
                Text("Aim for peaks between −18 and −6 dBFS. Red lamp = clipping: turn the send down.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Read-outs

    private var readoutCard: some View {
        Card(title: "Analysis") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("KEY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(model.keyText)
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(model.keyIsReliable ? .primary : .secondary)
                            Text(model.keyAltText)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(model.keyDetail).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BPM").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(model.bpmText)
                            .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(model.bpmIsReliable ? .primary : .secondary)
                    }
                    Spacer()
                }

                ChromaBarsView(values: model.chroma)
                    .frame(height: 70)

                Text("Tuner: \(model.tunerText)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Text("Key notation").foregroundStyle(.secondary)
                    Picker("Key notation", selection: $model.notation) {
                        ForEach(KeyNotation.allCases) { n in
                            Text(n.title).tag(n)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    Spacer()
                }

                if model.notation == .camelot && !model.showMinorKeys {
                    Text("Major keys only: Camelot codes will all be B. Turn on Detect minor keys to get A codes too.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Toggle("Detect minor keys", isOn: $model.showMinorKeys)
                        .fixedSize()
                    Spacer()
                    Button("Reset key") { model.resetKey() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Messages

    private var permissionCard: some View {
        Card(title: "Audio input permission needed") {
            VStack(alignment: .leading, spacing: 10) {
                Text("KDM needs permission to use audio input to hear the mixer. iPadOS calls this the microphone permission; it covers USB audio too.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func messageCard(_ title: String, _ message: String) -> some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: 10) {
                Text(message).foregroundStyle(.secondary)
                Button("Try again") { audio.restart() }.buttonStyle(.bordered)
            }
        }
    }
}

/// Pitch-class energy, C to B.
struct ChromaBarsView: View {
    let values: [Float]

    var body: some View {
        let maxValue = max(values.max() ?? 0, 1e-6)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<12, id: \.self) { i in
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        let v = i < values.count ? CGFloat(values[i] / maxValue) : 0
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(0.35 + 0.65 * v))
                                .frame(height: geo.size.height * v)
                        }
                    }
                    Text(AnalysisViewModel.noteNames[i])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Small layout helpers

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            content
                .frame(maxWidth: 520, alignment: .leading)
        }
    }
}
