import SwiftUI
import UIKit

/// Main screen: header (logo, KDM, signal status, Inputs button), the main
/// output's key and BPM, one card per mixer channel, and the key settings.
/// Input selection and diagnostics live in the Inputs panel.
struct ContentView: View {
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var model: AnalysisViewModel

    @State private var showInputs = false
    /// Minimal view (key + note bars only). Remembered between launches.
    @AppStorage("kdm.view.minimal") private var minimal = false

    var body: some View {
        Group {
            if minimal {
                MinimalView(model: model) {
                    withAnimation(.easeInOut(duration: 0.2)) { minimal = false }
                }
                .transition(.opacity)
            } else {
                fullView
                    .transition(.opacity)
            }
        }
        .onAppear {
            // Used by the CI screenshot job.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-KDMMinimal") { minimal = true }
            if args.contains("-KDMFull") { minimal = false }
        }
    }

    private var fullView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                switch audio.status {
                case .permissionDenied: permissionCard
                case .failed(let message): messageCard("Audio couldn't start", message)
                default: EmptyView()
                }
                mainOutputCard
                channelsSection
                keySettings
                noteBarsCard
            }
            .padding(24)
            .frame(maxWidth: 1100)
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
            minimalButton
            inputsButton
        }
    }

    private var minimalButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { minimal = true }
        } label: {
            Label("Minimal", systemImage: "rectangle.compress.vertical")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Show only the key and the note bars")
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
                .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 660)
        }
        .accessibilityHint("Choose the input source and channels, and see audio diagnostics")
    }

    /// e.g. "X1800 Prime · 10 ch", shown under the status badge.
    private var sourceSummary: String {
        guard let input = audio.currentInput else { return "No input" }
        guard audio.channelCount > 0 else { return input.name }
        return "\(input.name) · \(audio.channelCount) ch"
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

    // MARK: - Main output

    private var mainOutputCard: some View {
        Card(title: mainOutputTitle) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("KEY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(model.keyText)
                            .font(.system(size: 88, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .foregroundStyle(model.keyIsReliable ? .primary : .secondary)
                        HStack(spacing: 12) {
                            if !model.keyAltText.isEmpty {
                                Text(model.keyAltText)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(model.keyDetail)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("BPM").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(model.bpmText)
                            .font(.system(size: 88, weight: .bold, design: .rounded).monospacedDigit())
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .foregroundStyle(model.bpmIsReliable ? .primary : .secondary)
                    }
                }

                if let key = model.mainKey {
                    NextKeysView(from: key, model: model)
                }

                VStack(spacing: 6) {
                    LevelMeterView(label: model.isStereo ? "L" : "M", meter: model.left)
                    if model.isStereo {
                        LevelMeterView(label: "R", meter: model.right)
                    }
                }
            }
        }
    }

    private var mainOutputTitle: String {
        guard audio.channelCount > 0 else { return "Main output" }
        if case .stereo(let l) = audio.channelSelection {
            return "Main output · USB \(l + 1) + \(l + 2)"
        }
        return "Main output · USB \(audio.channelSelection.leftIndex + 1)"
    }

    // MARK: - Mixer channels

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MIXER CHANNELS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                ForEach(model.channels) { channel in
                    ChannelCard(channel: channel,
                                keyText: model.keyText(channel.key),
                                keyAltText: model.keyAltText(channel.key),
                                match: mixMatch(for: channel))
                }
            }
            if model.mainKey != nil && !model.channels.isEmpty {
                MixLegend()
            }
        }
    }

    /// How a channel's key mixes with the main output (nil = a key is unknown).
    private func mixMatch(for channel: ChannelReadout) -> MixMatch? {
        guard let main = model.mainKey, let key = channel.key else { return nil }
        return MixMatch(from: main, to: key)
    }

    // MARK: - Key settings

    private var keySettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Picker("Key notation", selection: $model.notation) {
                    ForEach(KeyNotation.allCases) { n in
                        Text(n.title).tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Toggle("Detect minor keys", isOn: $model.showMinorKeys)
                    .fixedSize()

                Spacer()

                Button("Reset keys") { model.resetKey() }
                    .buttonStyle(.bordered)
            }
            if model.notation == .camelot && !model.showMinorKeys {
                Text("Major keys only: Camelot codes will all be B. Turn on Detect minor keys to get A codes too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Note bars

    private var noteBarsCard: some View {
        Card(title: "Notes · main output") {
            NoteBarsView(values: model.chroma, key: model.mainKey)
                .frame(height: 140)
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

/// One mixer channel: its key, BPM and level. Dimmed when the channel is silent.
struct ChannelCard: View {
    let channel: ChannelReadout
    let keyText: String
    let keyAltText: String
    /// How this channel mixes with the main output (nil = a key is unknown).
    var match: MixMatch? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(channel.name).font(.headline)
                Spacer()
                Text(channel.channelsLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(keyText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(channel.key != nil ? .primary : .secondary)

            // How this channel's key mixes with the main output.
            if let match {
                Text(match.label)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(match.category.color.opacity(0.2)))
                    .foregroundStyle(match.category.color)
            } else {
                Text(" ").font(.caption.weight(.bold)).padding(.vertical, 3)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(keyAltText.isEmpty ? " " : keyAltText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text(AnalysisViewModel.bpmText(channel.bpm))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(channel.bpm != nil ? .primary : .secondary)
                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Slim level bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(channel.levelDb > -6 ? Color.red : channel.levelDb > -18 ? Color.yellow : Color.green)
                        .frame(width: geo.size.width * LevelMeterView.position(channel.levelDb))
                }
            }
            .frame(height: 5)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(channel.hasSignal ? 0.07 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(match.map { $0 == .clash ? Color.clear : $0.category.color.opacity(0.7) } ?? .clear, lineWidth: 2))
        .opacity(channel.hasSignal ? 1 : 0.55)
        .accessibilityElement(children: .combine)
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
                .frame(width: 100, alignment: .leading)
            content
                .frame(maxWidth: 520, alignment: .leading)
        }
    }
}

/// "Next keys": where the set can go from the main output's key on the Camelot
/// wheel, in the chosen notation. Green = smooth mix, orange = energy change.
struct NextKeysView: View {
    let from: DetectedKey
    @ObservedObject var model: AnalysisViewModel
    /// Bigger chips in one row, for the Minimal view.
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 12 : 8) {
            Text("NEXT KEYS")
                .font((large ? Font.callout : Font.caption).weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: large ? Array(repeating: GridItem(.flexible(), spacing: 12), count: MixMove.suggestions.count)
                                     : [GridItem(.adaptive(minimum: 84), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(MixMove.suggestions) { move in
                    let target = move.target(from: CamelotKey(from)).detectedKey
                    VStack(alignment: .leading, spacing: large ? 4 : 2) {
                        Text(move.label)
                            .font((large ? Font.callout : Font.caption2).weight(.semibold))
                            .foregroundStyle(move.category.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(model.keyText(target))
                            .font(large ? .system(size: 38, weight: .bold, design: .rounded) : .headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .padding(.horizontal, large ? 14 : 10)
                    .padding(.vertical, large ? 12 : 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: large ? 12 : 8).fill(move.category.color.opacity(large ? 0.16 : 0.12)))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Explains the channel card colours.
struct MixLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            item(.smooth, "same, ±1, relative")
            item(.energy, "+2, semitone up, parallel")
            item(.clash, "doesn't mix")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(_ c: MixCategory, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c.color).frame(width: 8, height: 8)
            Text("\(c.title): \(text)")
        }
    }
}
