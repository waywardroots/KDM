// prodjlink-monitor: shows what Pioneer DJ gear (CDJ-3000, DJM-A9 …) reports
// over Pro DJ Link.
//
//   cd iPad/StageLinQ
//   swift run prodjlink-monitor
//
// Everything is also written to prodjlink-log.txt in the current folder.
// Close rekordbox first (it uses the same ports).

#if canImport(Darwin)
import Foundation
import ProDJLink

let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("prodjlink-log.txt")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logFile = try? FileHandle(forWritingTo: logURL)
let timeFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func write(_ line: String) {
    let stamped = "\(timeFormat.string(from: Date()))  \(line)"
    print(stamped)
    logFile?.write((stamped + "\n").data(using: .utf8)!)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n - 1)) + "…" : s + String(repeating: " ", count: n - s.count)
}

let link = ProDJLinkClient(name: "KDM-monitor")
link.onLog = { write($0) }
link.onDevicesChanged = { devices in
    write("Devices: " + (devices.isEmpty ? "none" : devices.map(\.description).joined(separator: ", ")))
}
var lastSummary = ""
link.onStatus = { players in
    var lines = ["── Players ───────────────────────────────────────────────────────────",
                 pad("Player", 14) + pad("Key", 8) + pad("Shift", 7) + pad("BPM", 9) + pad("Pitch", 9) + pad("Play", 6) + pad("Master", 8) + pad("On air", 8) + "Track"]
    for p in players {
        let key = p.currentKey.map(\.description) ?? "—"
        let bpm = p.effectiveBPM.map { String(format: "%.2f", $0) } ?? "—"
        let pitch = String(format: "%+.2f%%", (p.pitch - 1) * 100)
        let track = p.loaded ? "rekordbox #\(p.rekordboxID) from player \(p.trackSourcePlayer) slot \(p.trackSlot)" : "—"
        lines.append(pad("\(p.name) #\(p.player)", 14) + pad(key, 8) + pad(p.keyShiftSemitones == 0 ? "0" : String(format: "%+d", p.keyShiftSemitones), 7)
                     + pad(bpm, 9) + pad(pitch, 9) + pad(p.playing ? "▶" : "■", 6) + pad(p.isMaster ? "yes" : "", 8)
                     + pad(p.onAir ? "yes" : "", 8) + track)
    }
    let summary = lines.joined(separator: "\n")
    if summary != lastSummary {
        lastSummary = summary
        write("\n" + summary)
    }
}

do {
    try link.start()
    write("KDM Pro DJ Link monitor. Waiting for CDJ / DJM devices… (Ctrl-C to quit)")
    write("Logging to \(logURL.path)")
} catch {
    write("Couldn't start: \(error.localizedDescription)")
    write("Is rekordbox (or another DJ Link app) running? It uses UDP 50000 / 50002.")
    exit(1)
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    link.stop()
    exit(0)
}
sigint.resume()
RunLoop.main.run()
#else
print("prodjlink-monitor runs on macOS.")
#endif
