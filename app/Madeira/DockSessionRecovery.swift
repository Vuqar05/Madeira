// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Recovery after Madeira is closed while a Dock game runs (milestone 5 item 3).
///
/// Observed on an iPad (2026-11-15): after Madeira was closed mid-game, the
/// next two starts stopped at "Loading Steam". Valve's client started and
/// Dock's engine factory succeeded, but the client's connection check
/// (`CJobTestConnectivity`, `test.steampowered.com/204`) never finished, so
/// sign-in never began; closing and reopening Madeira cleared it.
///
/// A Dock start now records that a session runs and removes the record when
/// the session ends. A record found at the next start means the previous one
/// was cut off: the client's state that a cut-off session can leave half
/// written (its crash marker and its HTTP cache, both rebuilt by the client)
/// is removed before the client starts, and the start says so in the log. If
/// sign-in still does not begin, the starting screen says so in words and the
/// log gets the client's own connection lines, redacted, so the cause can be
/// read from one exported log.
@MainActor enum DockSessionRecovery {
    static var root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MadeiraDock", isDirectory: true)
    private static var marker: URL { root.appendingPathComponent("session-running.json") }
    private struct Marker: Codable { var appID: Int; var started: Date }

    /// Client paths a cut-off session can leave behind, relative to the
    /// client root. Both are rebuilt by the client; nothing the account needs
    /// (sign-in, licenses, settings, games) is among them.
    static let volatile = [".crash", "appcache/httpcache"]

    /// Seconds after the start before "Loading Steam" without sign-in reads as stalled.
    static let stallAfter = 120.0

    /// Before Dock's handoff. Returns the leftovers removed (relative paths),
    /// empty after a clean previous session.
    @discardableResult
    static func begin(appID: Int, clientRoot: URL, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        if let data = try? Data(contentsOf: marker), data.count <= 4096,
           let previous = try? JSONDecoder().decode(Marker.self, from: data) {
            for path in volatile {
                let url = clientRoot.appendingPathComponent(path)
                // Never follow a link out of the client folder.
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      fm.fileExists(atPath: url.path) else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed.append(path) }
            }
            SteamLog.event("[dock-recovery] previous session app=\(previous.appID) ended without closing "
                           + "(\(Int(now.timeIntervalSince(previous.started)))s before this start); removed: "
                           + (removed.isEmpty ? "nothing" : removed.joined(separator: ",")))
        }
        stallLogged = false
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(Marker(appID: appID, started: now)).write(to: marker, options: .atomic)
        } catch { SteamLog.event("[dock-recovery] session record not written") }
        return removed
    }

    /// The Dock session ended (or its start failed) with Madeira still running.
    static func end() {
        try? FileManager.default.removeItem(at: marker)
    }

    /// The starting screen's words when the client has started but sign-in
    /// has not begun after `stallAfter` seconds.
    static let stallText = "Steam has not connected yet. This can follow a session that was closed while a game ran; "
        + "Madeira cleaned up after it. If it goes on, close this session and start the game again. "
        + "If it still stops here, close Madeira completely, reopen it and export the diagnostic log."

    private static var stallLogged = false
    /// Once per start: the client's connection lines, redacted, into the log.
    static func logStall(clientRoot: URL, elapsed: Double) {
        guard !stallLogged else { return }
        stallLogged = true
        let lines = connectionLines(clientRoot: clientRoot)
        SteamLog.event("[dock-recovery] sign-in not started after \(Int(elapsed))s; client connection log:"
                       + (lines.isEmpty ? " (none)" : ""))
        for line in lines { SteamLog.event("[dock-recovery]   " + line) }
    }

    /// The last connection-related lines of the client's logs, at most 40,
    /// with addresses, Steam IDs and long numbers removed.
    static func connectionLines(clientRoot: URL) -> [String] {
        var out: [String] = []
        for name in ["logs/connection_log.txt", "logs/bootstrap_log.txt"] {
            let url = clientRoot.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
            guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { continue }
            let keep = ["connect", "test", "cm ", "websocket", "logon", "timeout", "fail", "dns", "http", "ping"]
            for line in text.split(whereSeparator: \.isNewline).suffix(400)
            where keep.contains(where: { line.lowercased().contains($0) }) {
                out.append(name.split(separator: "/").last! + ": " + redact(String(line.prefix(240))))
            }
        }
        return Array(out.suffix(40))
    }

    /// No account or network identity in the app log.
    static func redact(_ line: String) -> String {
        var text = line
        let patterns = [
            #"\[[UGAI]:\d+:\d+(:\d+)?\]"#,                       // Steam IDs, [U:1:n]
            #"\b7656\d{13}\b"#,                                   // 64-bit Steam IDs
            #"\b(\d{1,3}\.){3}\d{1,3}(:\d+)?\b"#,                 // IPv4 and port
            #"\b(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b"#,  // IPv6 (a time like 12:34:56 has two colons)
            #"[0-9a-fA-F:]*::[0-9a-fA-F:]+"#,                     // compressed IPv6
            #"\b\d{7,}\b"#,                                       // other long numbers
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
        }
        return text
    }
}
