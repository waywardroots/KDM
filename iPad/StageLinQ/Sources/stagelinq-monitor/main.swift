// stagelinq-monitor: shows what Denon / Engine DJ gear on the network reports.
//
//   cd iPad/StageLinQ
//   swift run stagelinq-monitor            # live deck summary
//   swift run stagelinq-monitor --raw      # also print every state update
//
// Every update is also written to stagelinq-log.txt in the current folder, so
// it can be sent back for checking.

#if canImport(Network) && canImport(Darwin)
import Foundation
import StageLinQ

let showRaw = CommandLine.arguments.contains("--raw")
let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("stagelinq-log.txt")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logFile = try? FileHandle(forWritingTo: logURL)

let timeFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func write(_ line: String, toScreen: Bool = true) {
    let stamped = "\(timeFormat.string(from: Date()))  \(line)"
    if toScreen { print(stamped) }
    logFile?.write((stamped + "\n").data(using: .utf8)!)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n - 1)) + "…" : s + String(repeating: " ", count: n - s.count)
}

let client = StageLinQClient(name: "kdm-monitor", softwareName: "KDM", softwareVersion: "0.1")

client.onLog = { write($0) }

client.onDevicesChanged = { devices in
    write("Connected devices: " + (devices.isEmpty ? "none" : devices.map(\.description).joined(separator: ", ")))
}

client.onRawState = { device, path, value in
    write("\(device.softwareName) \(device.address)  \(path) = \(value)", toScreen: showRaw)
}

var lastSummary = ""
var pendingSummary = false
client.onChange = { decks, mixers in
    // Coalesce bursts of updates into one summary per half second.
    guard !pendingSummary else { return }
    pendingSummary = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        pendingSummary = false
        var lines = ["", "── Decks ─────────────────────────────────────────────────────────────────────────",
                     pad("Device", 24) + pad("Deck", 6) + pad("Key", 14) + pad("BPM", 9) + pad("Play", 6) + pad("Fader", 7) + "Track"]
        for d in decks where d.loaded || d.title != nil {
            let key = d.keyText.map { text in d.key.map { "\(text) (\($0.camelot))" } ?? "\(text) (?)" } ?? "—"
            let bpm = d.bpm.map { String(format: "%.2f", $0) } ?? "—"
            let fader = d.faderPosition.map { String(format: "%.2f", $0) } ?? "—"
            let track = [d.artist, d.title].compactMap { $0 }.joined(separator: " – ")
            lines.append(pad(d.device, 24) + pad("\(d.deck)\(d.isMaster ? "*" : "")", 6) + pad(key, 14)
                         + pad(bpm, 9) + pad(d.playing ? "▶" : "■", 6) + pad(fader, 7) + track)
        }
        for m in mixers {
            let faders = (1...4).map { ch in m.channelFaders[ch].map { String(format: "CH%d %.2f", ch, $0) } ?? "CH\(ch) —" }
            let xf = m.crossfader.map { String(format: "%.2f", $0) } ?? "—"
            lines.append("Mixer \(m.device): " + faders.joined(separator: "  ") + "  X-fader \(xf)")
            if !m.channelAssignments.isEmpty {
                lines.append("  assignments: " + m.channelAssignments.sorted { $0.key < $1.key }.map { "CH\($0.key)=\($0.value)" }.joined(separator: "  "))
            }
        }
        let summary = lines.joined(separator: "\n")
        if summary != lastSummary {
            lastSummary = summary
            write(summary)
        }
    }
}

do {
    try client.start()
    write("KDM StageLinQ monitor. Waiting for SC6000 / X1800 / Engine DJ devices… (Ctrl-C to quit)")
    write("Logging to \(logURL.path)")
} catch {
    write("Couldn't start: \(error.localizedDescription)")
    write("Is another StageLinQ app (Engine DJ, SoundSwitch, Now Playing) using UDP 51337?")
    exit(1)
}

// Ctrl-C: tell the network we're leaving, then quit.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    client.stop()
    exit(0)
}
sigint.resume()

RunLoop.main.run()
#else
print("stagelinq-monitor runs on macOS.")
#endif
