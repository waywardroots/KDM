// kdm-bridge: sends the key, BPM and track loaded on each deck of the DJ
// software on this Mac to KDM on the iPad (same Wi-Fi / network).
//
//   cd iPad/StageLinQ
//   swift run kdm-bridge                 # Serato DJ Pro 4+
//   swift run kdm-bridge --db <path>     # a different master.sqlite
//
// Serato: read-only from ~/Library/Application Support/Serato/Library/master.sqlite
// (the history Serato keeps of every track loaded in the current session).
// KDM finds the bridge by itself over Bonjour (_kdm-decks._tcp).

#if os(macOS)
import Foundation
import Network
import SQLite3

// MARK: - What we send (one JSON object per line)

struct BridgeDeck: Codable, Equatable {
    var deck: String          // "1" … "4"
    var title: String?
    var artist: String?
    var key: String?          // as Serato shows it ("Gm", "6A" …)
    var bpm: Double?
    var played: Bool          // Serato marks a track played once it has been playing a while
    var started: Int64        // when the track was loaded / started (Unix time)
}

struct BridgeMessage: Codable, Equatable {
    var source: String
    var decks: [BridgeDeck]
}

// MARK: - Logging

let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("kdm-bridge-log.txt")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logFile = try? FileHandle(forWritingTo: logURL)
let timeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func log(_ line: String) {
    let stamped = "\(timeFormat.string(from: Date()))  \(line)"
    print(stamped)
    logFile?.write((stamped + "\n").data(using: .utf8)!)
}

// MARK: - Serato

let args = CommandLine.arguments
let dbPath: String = {
    if let i = args.firstIndex(of: "--db"), i + 1 < args.count { return args[i + 1] }
    return NSString(string: "~/Library/Application Support/Serato/Library/master.sqlite").expandingTildeInPath
}()

/// The latest track on each deck in Serato's current history session.
func readSerato() -> [BridgeDeck]? {
    var db: OpaquePointer?
    let uri = "file:" + dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro"
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)
    let sql = """
        WITH current_session AS (
            SELECT id FROM history_session WHERE end_time = -1 ORDER BY start_time DESC LIMIT 1
        ),
        ranked AS (
            SELECT deck, artist, name, bpm, key, start_time, played,
                   ROW_NUMBER() OVER (PARTITION BY deck ORDER BY start_time DESC, id DESC) AS rn
            FROM history_entry
            WHERE session_id = (SELECT id FROM current_session)
        )
        SELECT deck, artist, name, bpm, key, start_time, played FROM ranked WHERE rn = 1 ORDER BY deck
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        log("Couldn't read Serato's history: \(String(cString: sqlite3_errmsg(db)))")
        return nil
    }
    defer { sqlite3_finalize(stmt) }
    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        let s = String(cString: c)
        return s.isEmpty ? nil : s
    }
    var decks: [BridgeDeck] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let bpm = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
        decks.append(BridgeDeck(deck: text(0) ?? "?", title: text(2), artist: text(1), key: text(4),
                                bpm: bpm.flatMap { $0 > 0 ? $0 : nil },
                                played: sqlite3_column_int(stmt, 6) != 0,
                                started: sqlite3_column_int64(stmt, 5)))
    }
    return decks
}

// MARK: - Network (Bonjour + newline-delimited JSON)

final class Server {
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "kdm.bridge")
    var current = BridgeMessage(source: "Serato DJ Pro", decks: [])

    func start() throws {
        let l = try NWListener(using: .tcp)
        l.service = NWListener.Service(name: "KDM Bridge on \(Host.current().localizedName ?? "Mac")", type: "_kdm-decks._tcp")
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: log("Ready: KDM on the iPad will find this Mac (port \(l.port?.rawValue ?? 0))")
            case .failed(let e): log("Network error: \(e.localizedDescription)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log("iPad connected: \(conn.endpoint)")
                self.send(self.current, to: conn)
            case .failed, .cancelled:
                log("iPad disconnected: \(conn.endpoint)")
                self.clients[id] = nil
            default: break
            }
        }
        clients[id] = conn
        conn.start(queue: queue)
        receiveNothing(conn)
    }

    /// Read (and ignore) anything the iPad sends, so we notice when it goes away.
    private func receiveNothing(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
            if done || error != nil { conn.cancel() } else { self?.receiveNothing(conn) }
        }
    }

    func publish(_ message: BridgeMessage) {
        queue.async {
            guard message != self.current else { return }
            self.current = message
            self.clients.values.forEach { self.send(message, to: $0) }
        }
    }

    private func send(_ message: BridgeMessage, to conn: NWConnection) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0a)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }
}

// MARK: - Main loop

let server = Server()
do { try server.start() } catch {
    log("Couldn't start the network service: \(error.localizedDescription)")
    exit(1)
}
log("KDM Bridge: reading Serato from \(dbPath)")
log("Logging to \(logURL.path)  (Ctrl-C to quit)")

var lastDecks: [BridgeDeck]? = nil
var warnedMissing = false
let poll = DispatchSource.makeTimerSource(queue: .main)
poll.schedule(deadline: .now(), repeating: 0.5)
poll.setEventHandler {
    guard FileManager.default.fileExists(atPath: dbPath) else {
        if !warnedMissing { log("Serato's database isn't there yet (\(dbPath)). Is Serato DJ Pro 4 installed and has it been opened?"); warnedMissing = true }
        return
    }
    guard let decks = readSerato() else { return }
    if decks != lastDecks {
        lastDecks = decks
        for d in decks {
            log("Deck \(d.deck): \(d.key ?? "—")  \(d.bpm.map { String(format: "%.1f", $0) } ?? "—") BPM  \(d.played ? "played" : "loaded")  \([d.artist, d.title].compactMap { $0 }.joined(separator: " – "))")
        }
        if decks.isEmpty { log("No tracks in Serato's current session yet. Load a track on a deck.") }
        server.publish(BridgeMessage(source: "Serato DJ Pro", decks: decks))
    }
}
poll.resume()

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { exit(0) }
sigint.resume()
RunLoop.main.run()
#else
print("kdm-bridge runs on macOS.")
#endif
