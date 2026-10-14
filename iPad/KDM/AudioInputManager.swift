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
    @Published private(set) var channelNames: [String] = []
    @Published private(set) var channelSelection: ChannelSelection = .stereo(left: 0)
    @Published private(set) var sampleRate: Double = 0

    var channelOptions: [ChannelSelection] { ChannelSelection.options(forChannelCount: channelCount) }

    var currentInput: AudioInput? { inputs.first { $0.id == currentInputID } }

    /// The analysis engine the UI reads results from.
    let analysis = KDMAnalysisEngine()

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []
    private var pendingRestart: DispatchWorkItem?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let inputUID = "kdm.input.uid"
        static func channels(_ uid: String) -> String { "kdm.input.channels.\(uid)" }
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
    func restart() {
        pendingRestart?.cancel()
        stopEngine()

        do {
            try configureSession()
            refreshInputs()
            try startEngine()
        } catch {
            status = .failed(error.localizedDescription)
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
            installTap(format: engine.inputNode.outputFormat(forBus: 0))
        }
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

        // iPadOS only opens 2 input channels unless asked for more. Ask for all of
        // them so every channel pair a mixer sends over USB can be selected.
        let maxChannels = session.maximumInputNumberOfChannels
        if maxChannels > session.inputNumberOfChannels {
            try? session.setPreferredInputNumberOfChannels(maxChannels)
        }
    }

    private func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        inputs = (session.availableInputs ?? []).map {
            AudioInput(id: $0.uid, name: $0.portName, kind: Self.kindLabel($0.portType))
        }
        let routeInput = session.currentRoute.inputs.first
        currentInputID = routeInput?.uid
        channelNames = routeInput?.channels?.map(\.channelName) ?? []
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        channelCount = Int(format.channelCount)
        sampleRate = format.sampleRate

        guard channelCount > 0, sampleRate > 0 else {
            status = .noInput
            return
        }

        // Restore this device's saved channel choice; default to the first pair.
        var selection: ChannelSelection = channelCount >= 2 ? .stereo(left: 0) : .mono(0)
        if let uid = currentInputID,
           let saved = defaults.string(forKey: Keys.channels(uid)).flatMap(ChannelSelection.init(storageValue:)),
           saved.isValid(forChannelCount: channelCount) {
            selection = saved
        }
        channelSelection = selection

        analysis.prepare(withSampleRate: sampleRate, maxBlockSize: 4096)
        installTap(format: format)

        engine.prepare()
        try engine.start()
        status = .running
    }

    private func installTap(format: AVAudioFormat) {
        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
        }
        input.installTap(onBus: 0,
                         bufferSize: 1024,
                         format: format,
                         block: Self.makeTapBlock(analysis: analysis,
                                                  left: channelSelection.leftIndex,
                                                  right: channelSelection.rightIndex))
        tapInstalled = true
    }

    /// Built outside the main actor: the tap runs on an audio thread.
    nonisolated private static func makeTapBlock(analysis: KDMAnalysisEngine,
                                                 left: Int,
                                                 right: Int?) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            guard left < channels else { return }

            var rightPtr: UnsafePointer<Float>? = nil
            if let r = right, r < channels {
                rightPtr = UnsafePointer(data[r])
            }
            analysis.processLeft(UnsafePointer(data[left]),
                                 right: rightPtr,
                                 frameCount: Int(buffer.frameLength))
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
                if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
                    self.scheduleRestart()
                }
            }
        })

        // The hardware format changed under the engine (it stops itself).
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRestart() }
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

    /// Route changes arrive in bursts; rebuild once they settle.
    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
