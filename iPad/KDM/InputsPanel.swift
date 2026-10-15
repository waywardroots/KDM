import SwiftUI

/// The "Inputs" panel, opened from the button at the top right of the main
/// screen: input source and channel pickers, plus audio diagnostics.
struct InputsPanel: View {
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var model: AnalysisViewModel
    var onDone: () -> Void

    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Inputs").font(.title2.weight(.bold))
                Spacer()
                Button("Done", action: onDone)
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceCard
                    diagnosticsCard
                }
                .padding(20)
            }
        }
        .background(Color(white: 0.09))
        .preferredColorScheme(.dark)
    }

    // MARK: - Source + channels

    private var sourceCard: some View {
        Card(title: "Input source") {
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
                        MenuLabel(text: audio.currentInput.map { "\($0.name) (\($0.kind))" } ?? "None")
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
                        MenuLabel(text: audio.channelCount > 0 ? channelLabel(audio.channelSelection) : "—")
                    }
                    .disabled(audio.channelCount == 0)
                }

                Text(deviceSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // Live level, so the right channel pair can be found without
                // closing the panel.
                VStack(spacing: 6) {
                    LevelMeterView(label: model.isStereo ? "L" : "M", meter: model.left)
                    if model.isStereo {
                        LevelMeterView(label: "R", meter: model.right)
                    }
                }
                .padding(.top, 4)

                if audio.status == .running && !model.hasSignal {
                    Text("Nothing above \(Int(AnalysisViewModel.signalThresholdDb)) dBFS on these channels. Check the cable and the mixer's USB send, and try another channel pair. On the Denon X1800 the master mix is on channels 9 + 10 by default.")
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

    // MARK: - Diagnostics

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
}

/// Text + chevrons, styled as a dropdown.
struct MenuLabel: View {
    let text: String

    var body: some View {
        HStack {
            Text(text).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down").font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
    }
}
