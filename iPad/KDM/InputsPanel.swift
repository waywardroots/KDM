import SwiftUI
import UIKit

/// The "Inputs" panel, opened from the button at the top right of the main
/// screen: input source and channel pickers, plus audio diagnostics.
struct InputsPanel: View {
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var model: AnalysisViewModel
    @ObservedObject var players: PlayerLink
    var onDone: () -> Void

    @State private var showDiagnostics = false
    @State private var showPlayerLog = false
    @State private var copiedLog = false
    @State private var showSingleChannels = false

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
                    playersCard
                    mixerChannelsCard
                    if audio.channelCount >= 4 { allInputsCard }
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

                // Main output: tap a channel pair. A grid instead of a menu, so a
                // 10-channel mixer's options all fit without scrolling.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Main output").foregroundStyle(.secondary)
                    if audio.channelCount == 0 {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        channelGrid(audio.channelOptions.filter { $0.rightIndex != nil })
                        if audio.channelCount >= 2 {
                            Toggle("Show single channels", isOn: $showSingleChannels)
                                .font(.callout)
                                .fixedSize()
                        }
                        if showSingleChannels || audio.channelOptions.allSatisfy({ $0.rightIndex == nil }) {
                            channelGrid(audio.channelOptions.filter { $0.rightIndex == nil })
                        }
                        if !audio.channelNames.isEmpty {
                            Text(channelLabel(audio.channelSelection))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                Text("Main output level. Aim for peaks between −18 and −6 dBFS; the red lamp means clipping.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if audio.status == .running && !model.hasSignal {
                    Text("Nothing above \(Int(AnalysisViewModel.signalThresholdDb)) dBFS on these channels. Check the cable and the mixer's USB send, and try another channel pair. On the Denon X1800 the master mix is on channels 9 + 10 by default.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Tappable buttons, one per option ("1 + 2", "3 + 4" … or "1", "2" …).
    private func channelGrid(_ options: [ChannelSelection]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                let selected = option == audio.channelSelection
                Button {
                    audio.selectChannels(option)
                } label: {
                    Text(shortChannelLabel(option))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(selected ? Color.accentColor : Color.white.opacity(0.08)))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func shortChannelLabel(_ option: ChannelSelection) -> String {
        if let r = option.rightIndex { return "\(option.leftIndex + 1) + \(r + 1)" }
        return "\(option.leftIndex + 1)"
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

    // MARK: - Media players (StageLinQ)

    private var playersCard: some View {
        Card(title: "Media players") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Read keys from the media players", isOn: $players.enabled)

                if players.enabled {
                    HStack(spacing: 8) {
                        Circle().fill(playerStatusColor).frame(width: 10, height: 10)
                        Text(playerStatusText).font(.callout)
                        Spacer()
                        Button("Reconnect") { players.restart() }
                            .buttonStyle(.bordered)
                            .font(.callout)
                    }

                    if players.status == .needsPermission {
                        Text("iPadOS is blocking the network search. KDM needs Apple's multicast networking permission before it can find the players; until then keys come from the audio.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if players.decks.isEmpty {
                        Text("Connect the iPad to the players' network: plug it into a free Ethernet port on the mixer or the players' network switch (a USB-C hub with Ethernet keeps the mixer's USB audio connected too). Works with Denon Engine DJ players (SC6000 / SC5000 / Prime) and Pioneer CDJ-3000s (with a DJM mixer for on-air).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(players.decks.filter { $0.loaded }) { deck in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(deck.label).font(.body.weight(.semibold)).frame(width: 84, alignment: .leading)
                            Text(model.keyText(deck.key)).font(.body.weight(.bold).monospacedDigit()).frame(width: 64, alignment: .leading)
                            Text(AnalysisViewModel.bpmText(deck.bpm)).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                            Text(deck.trackLine).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: deck.playing ? "play.fill" : "pause.fill")
                                .font(.caption)
                                .foregroundStyle(deck.isAudible ? Color.green : Color.secondary)
                        }
                    }

                    if !model.channels.isEmpty && !players.decks.isEmpty {
                        Divider()
                        Text("Which player is on each mixer channel")
                            .font(.subheadline.weight(.semibold))
                        Text("Auto learns it as you play: bring a fader up on a playing deck and its channel is matched within a few seconds.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(model.channels) { ch in
                            LabeledRow(ch.name) {
                                Menu {
                                    Button(autoTitle(for: ch.id)) { model.playerAssignments[ch.id] = nil }
                                    Button("Audio only") { model.playerAssignments[ch.id] = PlayerAssignment.none }
                                    ForEach(players.decks.map(\.label), id: \.self) { label in
                                        Button(label) { model.playerAssignments[ch.id] = .deck(label) }
                                    }
                                } label: {
                                    MenuLabel(text: assignmentTitle(for: ch.id))
                                }
                            }
                        }
                    }

                    DisclosureGroup("Connection log", isExpanded: $showPlayerLog) {
                        VStack(alignment: .leading, spacing: 3) {
                            Button {
                                UIPasteboard.general.string = players.log.joined(separator: "\n")
                                copiedLog = true
                            } label: {
                                Label(copiedLog ? "Copied" : "Copy log", systemImage: copiedLog ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .font(.callout)
                            .padding(.bottom, 4)
                            ForEach(Array(players.log.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var playerStatusText: String {
        switch players.status {
        case .off:                  return "Off"
        case .searching:            return "Searching for players…"
        case .connected(let n):     return n == 1 ? "Connected to 1 player" : "Connected to \(n) players"
        case .needsPermission:      return "Waiting for network permission"
        case .failed(let message):  return "Couldn't start: \(message)"
        }
    }

    private var playerStatusColor: Color {
        switch players.status {
        case .connected:                return .green
        case .searching:                return .yellow
        case .needsPermission, .failed: return .orange
        case .off:                      return .gray
        }
    }

    private func autoTitle(for channel: Int) -> String {
        model.autoMatches[channel].map { "Auto (\($0))" } ?? "Auto"
    }

    private func assignmentTitle(for channel: Int) -> String {
        switch model.playerAssignments[channel] ?? .auto {
        case .auto:            return model.autoMatches[channel].map { "Auto · \($0)" } ?? "Auto · not matched yet"
        case .none:            return "Audio only"
        case .deck(let label): return label
        }
    }

    // MARK: - Mixer channels

    private var mixerChannelsCard: some View {
        Card(title: "Mixer channels") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show the key of each mixer channel", isOn: $audio.analyseAllChannels)
                    .disabled(audio.channelCount < 4)

                if audio.channelCount >= 4 {
                    LabeledRow("Mixer layout") {
                        Picker("Mixer layout", selection: $audio.mixerLayout) {
                            ForEach(AudioInputManager.MixerLayout.allCases) { l in
                                Text(l == .auto ? "Auto (\(audio.effectiveLayout.title))" : l.title).tag(l)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Text("Denon X1800: channels on USB 1+2 … 7+8, master on 9+10. Pioneer DJM-A9: mix on USB 1+2, CH1 … CH4 on 3+4 … 9+10, FX send on 11+12.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledRow("Sample rate") {
                        Picker("Sample rate", selection: $audio.usbSampleRate) {
                            ForEach(AudioInputManager.sampleRates, id: \.self) { r in
                                Text(r == 44100 ? "44.1 kHz" : "\(r / 1000) kHz").tag(r)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Text("Match the mixer's setting (DJM-A9: sampling rate in the Setting Utility). " + audio.sampleRateNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if audio.channelCount < 4 {
                    Text("This input has \(audio.channelCount) channel\(audio.channelCount == 1 ? "" : "s"). Connect a mixer that sends each channel over USB (e.g. the Denon X1800) to see a key per channel.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if audio.analyseAllChannels {
                    Text("Every stereo pair except the main output is shown as a channel card.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(model.channels) { ch in
                        HStack {
                            Text(ch.name).font(.body.weight(.semibold)).frame(width: 60, alignment: .leading)
                            Text(ch.channelsLabel).foregroundStyle(.secondary)
                            Spacer()
                            Circle()
                                .fill(ch.hasSignal ? Color.green : Color.white.opacity(0.15))
                                .frame(width: 10, height: 10)
                                .accessibilityLabel(ch.hasSignal ? "Signal" : "No signal")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// Every stereo pair with a live level and what KDM uses it for, to find
    /// out which pair the mixer sends each channel on.
    private var allInputsCard: some View {
        Card(title: "All USB inputs (live)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Play one deck at a time and watch which pair moves.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(Array(model.pairLevels.enumerated()), id: \.offset) { i, db in
                    let left = i * 2
                    HStack(spacing: 10) {
                        Text("USB \(left + 1) + \(left + 2)")
                            .font(.callout.monospacedDigit())
                            .frame(width: 92, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(db > -6 ? Color.red : db > -18 ? Color.yellow : Color.green)
                                    .frame(width: geo.size.width * LevelMeterView.position(db))
                            }
                        }
                        .frame(height: 8)
                        Text(db <= AnalysisViewModel.floorDb + 1 ? "—" : String(format: "%.0f dB", db))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                        Text(pairRole(left))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                    }
                }
            }
        }
        .onAppear { model.showingAllInputs = true }
        .onDisappear { model.showingAllInputs = false }
    }

    private func pairRole(_ left: Int) -> String {
        if audio.channelSelection.leftIndex == left { return "Main" }
        if let strip = audio.strips.first(where: { $0.id == left }) { return strip.name }
        if audio.mixerProfile?.ignoredLefts.contains(left) == true { return "FX send" }
        return "—"
    }

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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio health").font(.subheadline.weight(.semibold))
                    Text(model.audioHealth.isEmpty ? "—" : model.audioHealth)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Steady buffers/s and no gaps = the mixer's audio arrives without interruption; then any jumpiness is in the display.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
