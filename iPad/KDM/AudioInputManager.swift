import AVFoundation
import Combine

/// An audio input iPadOS offers: a USB mixer or interface, the built-in mic, etc.
struct AudioInput: Identifiable, Hashable {
    let id: String      // AVAudioSessionPortDescription.uid (stable per device)
    let name: String    // e.g. "DJM-A9", "USB Audio", "iPad Microphone"
    let kind: String    // e.g. "USB", "Built-in mic"
}

/// Which input channel(s) to analyse. Indices are zero-based.
enum ChannelSelection: Hashable {
    case stereo(left: Int)   // left and left + 1
    case mono(Int)

    var leftIndex: Int {
        switch self {
        case .stereo(let l): return l
        case .mono(let c):   return c
        }
    }

    var rightIndex: Int? {
        switch self {
        case .stereo(let l): return l + 1
        case .mono:          return nil
        }
    }

    var label: String {
        switch self {
        case .stereo(let l): return "Channels \(l + 1) + \(l + 2)"
        case .mono(let c):   return "Channel \(c + 1) (mono)"
        }
    }

    // Saved per device in UserDefaults, e.g. "s:2" or "m:0".
    var storageValue: String {
        switch self {
        case .stereo(let l): return "s:\(l)"
        case .mono(let c):   return "m:\(c)"
        }
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]), n >= 0 else { return nil }
        switch parts[0] {
        case "s": self = .stereo(left: n)
        case "m": self = .mono(n)
        default:  return nil
        }
    }

    /// Every pair (1+2, 3+4, …) then every single channel, for a device with `count` inputs.
    static func options(forChannelCount count: Int) -> [ChannelSelection] {
        guard count > 0 else { return [] }
        let pairs = stride(from: 0, to: count - 1, by: 2).map { ChannelSelection.stereo(left: $0) }
        let monos = (0..<count).map { ChannelSelection.mono($0) }
        return pairs + monos
    }

    func isValid(forChannelCount count: Int) -> Bool {
        (rightIndex ?? leftIndex) < count
    }
}

/// One mixer channel analysed alongside the main output: a stereo pair of the
/// input (e.g. X1800 channel 1 on USB 1 + 2) with its own analysis engine.
struct ChannelStrip: Identifiable {
    let id: Int                     // left channel index (stable per pair)
    let name: String                // "Ch 1", "Ch 2", …
    let selection: ChannelSelection
    let engine: KDMAnalysisEngine
}

/// Owns the audio session and AVAudioEngine: lists inputs, switches between them,
/// picks the channel(s) to analyse and feeds them to the analysis engine.
///
/// The session is set up for line-level analysis: record-only (nothing is played
/// back, so no feedback) and "measurement" mode, which turns off iPadOS's voice
/// processing / automatic gain so the mixer's level reaches the analyser as-is.
@MainActor
final class AudioInputManager: ObservableObject {

    enum Status: Equatable {
        case starting
        case running
        case permissionDenied
        case noInput
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var inputs: [AudioInput] = []
    @Published private(set) var currentInputID: String?
    @Published private(set) var channelCount = 0
    /// Live peak of every input channel (for the "All USB inputs" meters).
    let inputMeter = InputPeakMeter()
    @Published private(set) var channelNames: [String] = []
    /// The pair analysed as the main output (mixer master) — the big read-out.
    @Published private(set) var channelSelection: ChannelSelection = .stereo(left: 0)
    /// Every other stereo pair of a multi-channel input, analysed per mixer channel.
    @Published private(set) var strips: [ChannelStrip] = []
    /// Analyse each mixer channel as well as the main output. Remembered.
    @Published var analyseAllChannels: Bool = UserDefaults.standard.object(forKey: "kdm.strips.enabled") as? Bool ?? true {
        didSet {
            defaults.set(analyseAllChannels, forKey: Keys.stripsEnabled)
            if engine.isRunning { reinstallTap() }
        }
    }
    @Published private(set) var sampleRate: Double = 0
    /// What iPadOS reports about audio inputs, for the diagnostics panel.
    @Published private(set) var diagnostics: [String] = []

    var channelOptions: [ChannelSelection] { ChannelSelection.options(forChannelCount: channelCount) }

    var currentInput: AudioInput? { inputs.first { $0.id == currentInputID } }

    /// The analysis engine for the main output.
    let analysis: KDMAnalysisEngine = {
        let e = KDMAnalysisEngine()
        e.tunerEnabled = false      // key + BPM only
        return e
    }()
    private var stripEnginePool: [KDMAnalysisEngine] = []

    /// Recreated on every restart: AVAudioEngine caches the input format it first
    /// saw (e.g. the built-in mic's mono), so reusing it after switching to a USB
    /// mixer would keep reporting the old channel count.
    private var engine = AVAudioEngine()
    private var engineConfigObserver: NSObjectProtocol?
    /// What the running engine was built for, to spot route changes that matter.
    private var engineInputUID: String?
    private var engineChannelCount = 0
    /// Extra rebuilds while a new device's channels are still being negotiated.
    private var settleRetries = 0
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []
    private var pendingRestart: DispatchWorkItem?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let inputUID = "kdm.input.uid"
        static func channels(_ uid: String) -> String { "kdm.input.channels.\(uid)" }
        static let stripsEnabled = "kdm.strips.enabled"
    }

    // MARK: - Starting

    func start() {
        requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.status = .permissionDenied
                    return
                }
                self.observeNotifications()
                self.restart()
            }
        }
    }

    /// Tears the audio graph down and rebuilds it for the current route.
    /// How many times the audio engine was (re)started, and the last reason.
    @Published private(set) var restartCount = 0
    /// Times the watchdog found the audio stopped and restarted it.
    @Published private(set) var stallRecoveries = 0
    private var lastStallRestart = Date.distantPast

    /// Called about once a second. If the engine says it's running but no audio
    /// has arrived for 2 s (the USB stream stalled), rebuild it.
    func checkForStall() {
        guard status == .running, Date().timeIntervalSince(lastStallRestart) > 5 else { return }
        let silentMs = inputMeter.msSinceLastBuffer()
        guard silentMs > 2000 || (!engine.isRunning && tapInstalled) else { return }
        lastStallRestart = Date()
        stallRecoveries += 1
        log(String(format: "No audio for %.1f s; restarting the engine", silentMs / 1000))
        restart()
    }

    func restart() {
        restartCount += 1
        inputMeter.resetHealth()
        pendingRestart?.cancel()
        stopEngine()
        engine = AVAudioEngine()
        observeEngineConfiguration()

        do {
            try configureSession()
            refreshInputs()
            try startEngine()
        } catch {
            status = .failed(error.localizedDescription)
        }
        updateDiagnostics()

        // A just-connected USB device can take a moment to offer all its
        // channels. If more are available than we got, rebuild again (a few times).
        let session = AVAudioSession.sharedInstance()
        if session.maximumInputNumberOfChannels > channelCount, settleRetries < 3 {
            settleRetries += 1
            scheduleRestart(after: 0.5)
        } else {
            settleRetries = 0
        }
    }

    // MARK: - User choices

    func selectInput(_ input: AudioInput) {
        defaults.set(input.id, forKey: Keys.inputUID)
        restart()
    }

    func selectChannels(_ selection: ChannelSelection) {
        guard selection.isValid(forChannelCount: channelCount) else { return }
        channelSelection = selection
        if let uid = currentInputID {
            defaults.set(selection.storageValue, forKey: Keys.channels(uid))
        }
        // Swap the tap in place; the engine keeps running.
        if engine.isRunning {
            reinstallTap()
        }
    }

    /// Clears key / tempo history on every channel (e.g. when a new set starts).
    func resetAllAnalysis() {
        analysis.reset()
        strips.forEach { $0.engine.reset() }
    }

    // MARK: - Session and engine

    private func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        // A roomier I/O buffer (~21 ms) rides out USB hiccups better than the
        // default, and key/BPM analysis doesn't need low latency.
        try? session.setPreferredIOBufferDuration(1024.0 / 48000.0)
        try session.setActive(true)

        // Use the input the user picked last time if it's plugged in; otherwise
        // prefer a USB device (mixer / interface) over the built-in mic.
        let available = session.availableInputs ?? []
        if let uid = defaults.string(forKey: Keys.inputUID),
           let port = available.first(where: { $0.uid == uid }) {
            try session.setPreferredInput(port)
        } else if let usb = available.first(where: { $0.portType == .usbAudio }) {
            try session.setPreferredInput(usb)
        }

        // iPadOS opens only 1-2 input channels unless asked for more. Ask for all
        // of them so every channel pair a mixer sends over USB can be selected.
        // (This only works once the device is the active route; if the switch is
        // still in progress, the route-change handler / settle retry asks again.)
        let maxChannels = session.maximumInputNumberOfChannels
        if maxChannels > session.inputNumberOfChannels {
            do {
                try session.setPreferredInputNumberOfChannels(maxChannels)
            } catch {
                log("Couldn't open \(maxChannels) input channels: \(error.localizedDescription)")
            }
        }
    }

    private func log(_ s: String) {
        NSLog("[KDM audio] %@", s)
    }

    private func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        inputs = (session.availableInputs ?? []).map {
            AudioInput(id: $0.uid, name: $0.portName, kind: Self.kindLabel($0.portType))
        }
        let routeInput = session.currentRoute.inputs.first
        currentInputID = routeInput?.uid
        channelNames = routeInput?.channels?.map(\.channelName) ?? []
        updateDiagnostics()
    }

    func updateDiagnostics() {
        let session = AVAudioSession.sharedInstance()
        var lines: [String] = []
        let available = session.availableInputs ?? []
        lines.append("Inputs iPadOS offers: \(available.count)")
        for port in available {
            let ch = port.channels?.count ?? 0
            lines.append("  • \(port.portName) — \(Self.kindLabel(port.portType)) [\(port.portType.rawValue)], \(ch) ch")
        }
        let route = session.currentRoute
        lines.append("Current route inputs: " + (route.inputs.isEmpty ? "none"
            : route.inputs.map { "\($0.portName) (\($0.channels?.count ?? 0) ch)" }.joined(separator: ", ")))
        lines.append("Current route outputs: " + (route.outputs.isEmpty ? "none"
            : route.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")))
        lines.append(String(format: "Input available: %@ · channels %d of max %d · %.0f Hz",
                            session.isInputAvailable ? "yes" : "no",
                            session.inputNumberOfChannels,
                            session.maximumInputNumberOfChannels,
                            session.sampleRate))
        lines.append("Category: \(session.category.rawValue) · mode: \(session.mode.rawValue)")
        lines.append("App is using: \(channelCount) ch @ \(Int(sampleRate)) Hz")
        diagnostics = lines
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        channelCount = Int(format.channelCount)
        sampleRate = format.sampleRate
        engineInputUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        engineChannelCount = channelCount
        log("Engine input: \(channelCount) ch @ \(Int(sampleRate)) Hz from \(currentInput?.name ?? "?")")

        guard channelCount > 0, sampleRate > 0 else {
            status = .noInput
            return
        }

        // Restore this device's saved choice. Otherwise: a multi-channel device
        // (a mixer) defaults to its LAST pair, which is where mixers usually put the
        // master (X1800: USB 9 + 10); a 1-2 channel device uses its first pair.
        var selection: ChannelSelection
        if let profile = mixerProfile {
            selection = .stereo(left: profile.mainLeft)
        } else if channelCount >= 4 {
            selection = .stereo(left: (channelCount / 2 - 1) * 2)
        } else {
            selection = channelCount >= 2 ? .stereo(left: 0) : .mono(0)
        }
        if let uid = currentInputID,
           let saved = defaults.string(forKey: Keys.channels(uid)).flatMap(ChannelSelection.init(storageValue:)),
           saved.isValid(forChannelCount: channelCount) {
            selection = saved
        }
        channelSelection = selection

        analysis.prepare(withSampleRate: sampleRate, maxBlockSize: 4096)
        installTap(format: format)   // also builds the channel strips

        engine.prepare()
        try engine.start()
        status = .running
    }

    private func reinstallTap() {
        installTap(format: engine.inputNode.outputFormat(forBus: 0))
    }

    /// (Re)builds the channel strips and installs one tap that feeds the main
    /// engine and every strip engine.
    private func installTap(format: AVAudioFormat) {
        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }

        // The tap is off here, so engines can be (re)prepared safely.
        rebuildStrips()

        var routes: [Route] = [Route(engine: analysis,
                                     left: channelSelection.leftIndex,
                                     right: channelSelection.rightIndex)]
        routes += strips.map { Route(engine: $0.engine, left: $0.selection.leftIndex, right: $0.selection.rightIndex) }

        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(routes: routes, meter: inputMeter))
        tapInstalled = true
    }

    /// Every stereo pair that doesn't overlap the main output becomes a strip,
    /// numbered in order (X1800 default: USB 1+2 … 7+8 = Ch 1 … Ch 4).
    private func rebuildStrips() {
        guard analyseAllChannels, channelCount >= 4 else {
            strips = []
            return
        }
        let main = Set([channelSelection.leftIndex, channelSelection.rightIndex].compactMap { $0 })
        var pairs = stride(from: 0, to: channelCount - 1, by: 2).filter { !main.contains($0) && !main.contains($0 + 1) }
        if let profile = mixerProfile {
            pairs = pairs.filter { !profile.ignoredLefts.contains($0) }
        }

        while stripEnginePool.count < pairs.count {
            let e = KDMAnalysisEngine()
            e.tunerEnabled = false
            stripEnginePool.append(e)
        }
        strips = pairs.enumerated().map { i, left in
            let e = stripEnginePool[i]
            e.majorOnly = analysis.majorOnly
            e.prepare(withSampleRate: sampleRate, maxBlockSize: 4096)
            return ChannelStrip(id: left, name: "Ch \(i + 1)", selection: .stereo(left: left), engine: e)
        }
    }

    /// Mixers whose USB layout differs from "channels first, master last".
    struct MixerProfile {
        let mainLeft: Int            // left channel index of the main pair
        let ignoredLefts: Set<Int>   // pairs that aren't mixer channels
    }

    /// How the mixer lays out its USB channels. Auto picks from the device name.
    enum MixerLayout: String, CaseIterable, Identifiable {
        case auto
        case masterLast    // Denon X1800: USB 1/2 … 7/8 = CH1 … CH4, 9/10 = master
        case masterFirst   // Pioneer DJM-A9: USB 1/2 = mix, 3/4 … 9/10 = CH1 … CH4, 11/12 = FX send
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto:        return "Auto"
            case .masterLast:  return "Master last (Denon)"
            case .masterFirst: return "Master first (Pioneer)"
            }
        }
    }

    @Published var mixerLayout: MixerLayout =
        MixerLayout(rawValue: UserDefaults.standard.string(forKey: "kdm.mixer.layout") ?? "") ?? .auto {
        didSet {
            defaults.set(mixerLayout.rawValue, forKey: "kdm.mixer.layout")
            // Re-pick the main pair for the new layout and rebuild the strips.
            if let uid = currentInputID { defaults.removeObject(forKey: Keys.channels(uid)) }
            if let profile = mixerProfile { channelSelection = .stereo(left: profile.mainLeft) }
            else if channelCount >= 4 { channelSelection = .stereo(left: (channelCount / 2 - 1) * 2) }
            if engine.isRunning { reinstallTap() }
        }
    }

    /// The layout in effect: the user's choice, or for Auto a Pioneer / DJM
    /// mixer with 12+ channels (the DJM-A9 reports itself in several ways).
    var effectiveLayout: MixerLayout {
        if mixerLayout != .auto { return mixerLayout }
        let name = currentInput?.name.uppercased() ?? ""
        let pioneer = name.contains("DJM") || name.contains("PIONEER") || name.contains("A9")
        return pioneer && channelCount >= 12 ? .masterFirst : .masterLast
    }

    var mixerProfile: MixerProfile? {
        guard effectiveLayout == .masterFirst, channelCount >= 4 else { return nil }
        // Ignore the FX-send pair (11/12) when there is one.
        return MixerProfile(mainLeft: 0, ignoredLefts: channelCount >= 12 ? [10] : [])
    }

    /// One engine and the input channels that feed it.
    private struct Route {
        let engine: KDMAnalysisEngine
        let left: Int
        let right: Int?
    }

    /// Built outside the main actor: the tap runs on an audio thread.
    nonisolated private static func makeTapBlock(routes: [Route], meter: InputPeakMeter) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            meter.update(data, channels: channels, frames: frames)
            for route in routes where route.left < channels {
                var rightPtr: UnsafePointer<Float>? = nil
                if let r = route.right, r < channels {
                    rightPtr = UnsafePointer(data[r])
                }
                route.engine.processLeft(UnsafePointer(data[route.left]), right: rightPtr, frameCount: frames)
            }
        }
    }

    private func stopEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Hot-plugging, interruptions

    private func observeNotifications() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        // A mixer / interface was plugged in or pulled out.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshInputs()
                let session = AVAudioSession.sharedInstance()
                let routeUID = session.currentRoute.inputs.first?.uid
                // Rebuild when a device comes or goes or the active input changes.
                if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
                    || routeUID != self.engineInputUID {
                    self.settleRetries = 0
                    self.scheduleRestart()
                } else if (session.inputNumberOfChannels != self.engineChannelCount
                           || session.maximumInputNumberOfChannels > self.engineChannelCount),
                          self.settleRetries < 3 {
                    // Channel count still settling. Bounded, because asking for
                    // more channels itself causes a route change.
                    self.settleRetries += 1
                    self.scheduleRestart(after: 0.5)
                }
            }
        })

        // Phone call, Siri, another app took the audio: resume afterwards.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                if type == .ended { self?.scheduleRestart() }
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRestart() }
        })
    }

    /// The hardware format changed under the engine (it stops itself): rebuild.
    private func observeEngineConfiguration() {
        if let old = engineConfigObserver {
            NotificationCenter.default.removeObserver(old)
        }
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRestart() }
        }
    }

    /// Route changes arrive in bursts; rebuild once they settle.
    private func scheduleRestart(after delay: TimeInterval = 0.3) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func kindLabel(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .usbAudio:     return "USB"
        case .builtInMic:   return "Built-in mic"
        case .headsetMic:   return "Headset mic"
        case .lineIn:       return "Line in"
        case .bluetoothHFP: return "Bluetooth"
        case .carAudio:     return "CarPlay"
        default:            return type.rawValue
        }
    }
}
