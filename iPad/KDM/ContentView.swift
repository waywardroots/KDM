import SwiftUI
import UIKit

/// Test screen for the input picker and meter. Deliberately plain: the real
/// interface comes with the redesign.
struct ContentView: View {
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var model: AnalysisViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                switch audio.status {
                case .permissionDenied: permissionCard
                case .failed(let message): messageCard("Audio couldn't start", message)
                default: EmptyView()
                }
                inputCard
                meterCard
                readoutCard
                diagnosticsCard
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Color(white: 0.07).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("KDM").font(.largeTitle.weight(.bold))
            Text("Key Detector").font(.title3).foregroundStyle(.secondary)
            Spacer()
            statusBadge
        }
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

    // MARK: - Input picker

    private var inputCard: some View {
        Card(title: "Input") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledRow("Source") {
                    Menu {
                        ForEach(audio.inputs) { input in
                            Button {
                                audio.selectInput(input)
                            } label: {
                                if input.id == audio.currentInputID {
                                    Label("\(input.name) (\(input.kind))", systemImage: "checkmark")
                                } else {
                                    Text("\(input.name) (\(input.kind))")
                                }
                            }
                        }
                    } label: {
                        menuLabel(audio.currentInput.map { "\($0.name) (\($0.kind))" } ?? "None")
                    }
                    .disabled(audio.inputs.isEmpty)
                }

                LabeledRow("Channels") {
                    Menu {
                        ForEach(audio.channelOptions, id: \.self) { option in
                            Button {
                                audio.selectChannels(option)
                            } label: {
                                if option == audio.channelSelection {
                                    Label(channelLabel(option), systemImage: "checkmark")
                                } else {
                                    Text(channelLabel(option))
                                }
                            }
                        }
                    } label: {
                        menuLabel(audio.channelCount > 0 ? channelLabel(audio.channelSelection) : "—")
                    }
                    .disabled(audio.channelCount == 0)
                }

                Text(deviceSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if audio.status == .running && !model.hasSignal {
                    Text("Nothing above \(Int(AnalysisViewModel.signalThresholdDb)) dBFS on these channels. Check the cable, the mixer's USB/record send, and try another channel pair.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var deviceSummary: String {
        guard audio.channelCount > 0 else { return "No audio input available. Connect the mixer or audio interface." }
        let rate = audio.sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? String(format: "%.0f kHz", audio.sampleRate / 1000)
            : String(format: "%.1f kHz", audio.sampleRate / 1000)
        return "\(audio.channelCount) input channel\(audio.channelCount == 1 ? "" : "s") at \(rate)"
    }

    /// "Channels 3 + 4 — USB In 3 / USB In 4" when iPadOS reports channel names.
    private func channelLabel(_ option: ChannelSelection) -> String {
        let names = audio.channelNames
        let l = option.leftIndex
        guard l < names.count else { return option.label }
        if let r = option.rightIndex, r < names.count {
            return "\(option.label) — \(names[l]) / \(names[r])"
        }
        return "\(option.label) — \(names[l])"
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down").font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
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

    // MARK: - Diagnostics

    @State private var showDiagnostics = true

    private var diagnosticsCard: some View {
        Card(title: "Audio diagnostics") {
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup("What iPadOS reports", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(audio.diagnostics.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                Button("Re-scan audio devices") { audio.restart() }
                    .buttonStyle(.bordered)
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

private struct Card<Content: View>: View {
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

private struct LabeledRow<Content: View>: View {
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
