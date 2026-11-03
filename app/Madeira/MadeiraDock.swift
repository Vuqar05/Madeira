// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Darwin
import Network

/// JIT pool size of a Dock session. A Dock session runs no desktop Steam
/// client (no Chromium helper fan-out), so it can live with a smaller pool.
/// Opt-in per launch (the Dock sheet's toggle, default from
/// `env.MADEIRA_DOCK_COMPACT_POOL`, off unless set to 1). It never applies
/// outside a Dock launch, and an explicit madeira.cfg `pool` still wins
/// because the caller applies that afterwards.
enum DockPerformancePolicy {
    static let compactPoolMB = 512

    static func sessionPoolMB(standard: Int, dock: Bool, compact: Bool) -> Int {
        dock && compact ? min(standard, compactPoolMB) : standard
    }
}

enum DockError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// A game Steam's client has installed in the prefix, read from its
/// `steamapps/appmanifest_<appid>.acf`.
struct DockGame: Identifiable, Equatable, Sendable, Codable {
    let id: Int                 // App ID
    let name: String
    let installDir: String      // one folder name under <library>/common
    let library: String         // drive-relative steamapps folder
    let installed: Bool         // StateFlags has "fully installed"
    let customExecutables: Bool // the install record lists per-user executables (CheckGuid)

    /// Windows path of the game's folder, which Dock requires Valve's client to resolve to.
    var windowsInstallPath: String {
        "C:\\" + (library + "/common/" + installDir).replacingOccurrences(of: "/", with: "\\")
    }
}

/// Madeira Dock: a small headless host (madeira-dock, built by
/// build/madeira-dock/build.sh into arm64ec-windows/dockhost.exe) that loads
/// Valve's genuine Windows Steam client inside the Wine session, signs in
/// with the user's own refresh token and asks the client to start an
/// installed game with Valve's own LaunchApp. Valve's client performs the
/// online authentication and licence checks; the game and its DRM are
/// untouched. The host drives undocumented client interfaces and supports
/// only client builds it has verified by SHA-256; anything else fails closed
/// with a report code.
///
/// The app side is this contract: environment variables, a one-use sign-in
/// transfer file and a numeric report file (C:\madeira-dock.txt).
enum MadeiraDock {
    /// `env.MADEIRA_DOCK = 0` hides Dock. Without a built dockhost.exe it is hidden too.
    static var enabled: Bool { SteamSignIn.flag("MADEIRA_DOCK", default: true) && bundled }
    static var bundled: Bool {
        Bundle.main.url(forResource: "dockhost", withExtension: "exe", subdirectory: "arm64ec-windows") != nil
    }
    static let executable = "C:\\windows\\system32\\dockhost.exe"

    static var prefix: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("wine")
    }
    static var drive: URL { prefix.appendingPathComponent("drive_c") }
    static var clientRoot: URL { drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot, isDirectory: true) }
    static var clientInstalled: Bool {
        FileManager.default.fileExists(atPath: clientRoot.appendingPathComponent("steamclient64.dll").path)
    }

    // MARK: Installed games

    static func validAppID(_ value: Int) -> Bool { value > 0 && UInt64(value) < UInt64(UInt32.max) }

    /// One folder name: no separators, drive letters, parent references or control characters.
    static func validFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains(":") && !name.contains("\"") &&
            !name.unicodeScalars.contains { $0.value < 32 } && !name.hasSuffix(" ") && !name.hasSuffix(".")
    }

    /// The game an app manifest describes, or nil when it is not one Dock can start.
    static func game(manifest data: Data, library: String) -> DockGame? {
        guard data.count <= 1 << 20, var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], let appID = state["appid"]?.string.flatMap({ Int($0) }), validAppID(appID),
              let folder = state["installdir"]?.string, validFolderName(folder) else { return nil }
        let flags = state["StateFlags"]?.string.flatMap { UInt32($0) } ?? 0
        let name = state["name"]?.string.map { String($0.prefix(200)) } ?? ""
        return DockGame(id: appID, name: name.isEmpty ? "App \(appID)" : name, installDir: folder, library: library,
                        installed: flags & 4 != 0, customExecutables: !(state["CheckGuid"]?.fields.isEmpty ?? true))
    }

    /// A record's depots: the ones it lends from each owner app (`SharedDepots`, depot -> owner)
    /// and the ones installed for the app itself (`InstalledDepots`).
    static func depots(manifest data: Data) -> (lent: [Int: Set<String>], installed: Set<String>) {
        guard data.count <= 1 << 20, var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], let appID = state["appid"]?.string.flatMap({ Int($0) }) else { return ([:], []) }
        var lent: [Int: Set<String>] = [:]
        for (depot, owner) in (state["SharedDepots"]?.fields ?? [:]).prefix(64) {
            guard let ownerID = owner.string.flatMap({ Int($0) }), validAppID(ownerID), ownerID != appID else { continue }
            lent[ownerID, default: []].insert(depot)
        }
        return (lent, Set((state["InstalledDepots"]?.fields ?? [:]).keys.prefix(256)))
    }

    /// Installed games in the client's own library (`<client>/steamapps`) and the other
    /// libraries on C: that its `libraryfolders.vdf` lists. Read-only.
    static func games(drive: URL) -> [DockGame] {
        let fm = FileManager.default
        let clientLibrary = SteamRuntimeFiles.relativeRoot + "/steamapps"
        var libraries = [clientLibrary]
        if let data = try? Data(contentsOf: drive.appendingPathComponent(clientLibrary + "/libraryfolders.vdf")),
           data.count <= 1 << 20, var parser = try? SteamKeyValues(data), let root = try? parser.read() {
            for (_, entry) in (root["libraryfolders"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let path = entry["path"]?.string?.replacingOccurrences(of: "\\\\", with: "\\"),
                      let relative = libraryRelative(path) else { continue }
                if !libraries.contains(where: { $0.caseInsensitiveCompare(relative) == .orderedSame }) { libraries.append(relative) }
            }
        }
        // Libraries on external drives (ExternalDrives.swift). They are reached
        // through drive_c/External/<name> links, so they resolve outside drive_c.
        let external = ExternalDrives.steamLibraries
        for library in external where !libraries.contains(where: { $0.caseInsensitiveCompare(library) == .orderedSame }) {
            libraries.append(library)
        }
        var result: [DockGame] = []
        // Apps that only lend depots to another install ("Shared Only", e.g. GTA V
        // Enhanced's RGL/SC 1899670) have a record but nothing to start. A game that
        // lends depots but has its own installed too (a base game whose depots its
        // expansions share) stays: the same test as the uninstall (SteamInstall.swift).
        var lent: [Int: Set<String>] = [:], installed: [Int: Set<String>] = [:]
        for library in libraries.prefix(32) {
            let folder = drive.appendingPathComponent(library, isDirectory: true)
            let isExternal = external.contains { $0.caseInsensitiveCompare(library) == .orderedSame }
            guard isExternal || folder.resolvingSymlinksInPath().path.hasPrefix(drive.resolvingSymlinksInPath().path + "/"),
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in names.sorted().prefix(2000) where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { continue }
                let held = depots(manifest: data)
                lent.merge(held.lent) { $0.union($1) }
                guard let game = game(manifest: data, library: library),
                      !result.contains(where: { $0.id == game.id }) else { continue }
                installed[game.id] = held.installed
                result.append(game)
            }
        }
        result.removeAll { game in lent[game.id].map { installed[game.id, default: []].isSubset(of: $0) } ?? false }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "C:\\Games\\SteamLibrary" -> "Games/SteamLibrary/steamapps" (C: only).
    static func libraryRelative(_ windowsPath: String) -> String? {
        let path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard path.lowercased().hasPrefix("c:/") else { return nil }
        let parts = path.dropFirst(3).split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.count <= 16, parts.allSatisfy(validFolderName) else { return nil }
        return (parts + ["steamapps"]).joined(separator: "/")
    }

    /// Everything a launch needs, checked before any sign-in is handed over.
    static func validate(_ game: DockGame, drive: URL, bundled: Bool = MadeiraDock.bundled) throws {
        guard bundled else { throw DockError.message("Madeira Dock is not built into this app. Run build/madeira-dock/build.sh.") }
        guard validAppID(game.id), validFolderName(game.installDir) else {
            throw DockError.message("This game's Steam install record is invalid.")
        }
        guard FileManager.default.fileExists(atPath: drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/steamclient64.dll").path) else {
            throw DockError.message("Steam's client files are missing. Download Valve's client components first.")
        }
        var isFolder: ObjCBool = false
        guard game.installed,
              FileManager.default.fileExists(atPath: drive.appendingPathComponent(game.library + "/common/" + game.installDir).path, isDirectory: &isFolder),
              isFolder.boolValue else {
            throw DockError.message("Steam does not list this game as fully installed.")
        }
    }

    // MARK: Sign-in transfer

    /// Tokens stay in Keychain except for this bounded one-use transfer. The
    /// payload is not an ownership claim: Valve authenticates it in the guest.
    static func envelope(account: String, token: String, steamID: UInt64, appID: Int) throws -> Data {
        let name = Array(account.utf8), secret = Array(token.utf8)
        guard (1...64).contains(name.count), (1...8192).contains(secret.count),
              name.allSatisfy({ (33...126).contains($0) }),
              secret.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              steamID >> 56 == 1, (steamID >> 52) & 15 == 1, (steamID >> 32) & 0xfffff == 1,
              steamID & 0xffffffff != 0, validAppID(appID) else {
            throw DockError.message("Your Steam sign-in cannot be handed to Dock. Sign in to Steam again in Madeira.")
        }
        var data = Data("MDOCK001".utf8)
        func append(_ value: UInt64, bytes: Int) {
            for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        append(steamID, bytes: 8); append(UInt64(appID), bytes: 4)
        append(UInt64(name.count), bytes: 2); append(UInt64(secret.count), bytes: 2)
        data.append(contentsOf: name); data.append(contentsOf: secret)
        return data
    }

    /// The JWT subject selects the account; it is deliberately not treated as
    /// authenticated identity. Only Valve accepting the token can establish it.
    static func subject(_ token: String) throws -> UInt64 {
        guard token.utf8.count <= 8192 else { throw DockError.message("Steam sign-in is too large.") }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw DockError.message("Steam sign-in needs renewal.") }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["sub"] as? String, let id = UInt64(text) else {
            throw DockError.message("Steam sign-in needs renewal.")
        }
        return id
    }

    /// The seeded prefix has C: but no guaranteed Z: mapping. Wine's Unix
    /// namespace reaches the protected native file without a drive mapping
    /// and without moving the transfer into the user-visible Documents folder.
    static func handoffGuestPath(_ url: URL, unixNamespace: Bool = true) -> String {
        (unixNamespace ? "\\\\?\\unix" : "Z:") + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: Report

    /// The host's report: a bounded set of numeric fields, never arbitrary guest text.
    struct Report {
        var fields: [String: String] = [:]
        var result: Int? { fields["probe-result"].flatMap(Int.init) }
        var failure: String? {
            guard let result, result != 0 else { return nil }
            if result == 30 {
                if fields["session-unsupported-client"] == "1" || fields["session-user-method-mismatch"] != nil {
                    return "Madeira Dock does not support this Steam client build. Dock only drives client builds it has verified; the log has the client fingerprint and the failed check."
                }
                return "Madeira Dock could not initialize the Steam session (code 30). Export the log to identify the failed check."
            }
            // The host waits 90 s after sign-in for Valve's client to count the game
            // among the account's subscriptions (madeira-dock src/session.c).
            if result == 34 {
                return fields["session-authenticated-online"] == "1"
                    ? "Steam signed in but did not confirm this game's license in time. Export the log before trying again."
                    : "Steam did not finish signing in. Check the connection and try again."
            }
            if result == 54, fields["launch-user-arguments-invalid"] != nil {
                return "The game's launch arguments are invalid or too long. Edit them in Game details and try again."
            }
            if result == 35 { return "Steam did not confirm a license for this game on the signed-in account." }
            // Offline start (madeira-dock docs/OFFLINE.md): Valve's client decides.
            if result == 50 {
                return fields["session-offline-abi"] == "0"
                    ? "There is no connection, and this Steam client build cannot be started offline by Madeira Dock. Connect to the internet and try again."
                    : "There is no connection, and Steam has nothing saved to sign this account in offline. Start a game once while online; Steam then allows offline starts until its offline sign-in expires."
            }
            if result == 51 { return "There is no connection, and Steam refused to sign in offline. Connect to the internet and start the game once. Export the log if it happens again." }
            if result == 52 { return "Steam signed in offline, but what it has saved does not list this game. Start this game once while online, then it can be played offline." }
            if result == 37 {
                if fields["session-native-handoff-app-mismatch"] == "1" {
                    return "Madeira Dock received a sign-in transfer for a different launch. Close the session and try again."
                }
                return "Madeira Dock could not read the one-use Steam sign-in transfer. Steam has not checked the login yet. Export the log before trying again."
            }
            // Valve's client could not prepare the game's per-user executable.
            if result == 49 {
                switch fields["ceg-result"].flatMap(Int.init) {
                case -1: return "Steam took too long to prepare this game's executable. Check the connection and try again."
                case 0: return "Steam did not start preparing this game's executable. Verify the game's files with Steam, then try again."
                case 10: return "Steam is busy with this game (updating or running). Try again in a moment."
                case -4: return "Steam's Windows service manager could not be started, so Steam could not prepare this game's executable."
                case -5: return "Steam's Windows service is not installed in Madeira's Windows setup, so Steam could not prepare this game's executable."
                default: return "Steam could not prepare this game's executable for your account (code \(fields["ceg-result"] ?? "?"))."
                }
            }
            if result == 45 || result == 48, fields["launch-option-missing"] != nil || fields["launch-option-invalid"] != nil {
                return "Steam rejected this game's launch option. Refresh the Steam library and try again."
            }
            if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
               (22...23).contains(error), fields["launch-config-wait"] != nil {
                return "Steam did not finish loading this game's configuration after signing in. Wait a minute and start the game again."
            }
            // The host asked again for up to three minutes while Steam still counted
            // another session of this account as playing (refusal 35); it still did.
            if result == 45 || result == 48, fields["launch-client-error"] == "35", fields["launch-session-wait"] != nil {
                return "Steam still says this account is playing in another session. Close the game on your other device (or wait a few minutes after a closed session) and start it again."
            }
            if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
               let reason = Self.launchRefusal(error, waited: result == 48) {
                return reason
            }
            return "Madeira Dock could not complete the Steam launch (code \(result)). Export the log before trying again."
        }

        /// Valve's own launch refusal (EAppUpdateError) in words. Numbers only
        /// come from the host report; nothing here changes what Steam decided.
        static func launchRefusal(_ error: Int, waited: Bool) -> String? {
            switch error {
            case 5: return "Steam did not confirm a license for this game on the signed-in account."
            case 6, 21: return "Steam could not reach its servers to start this game. Check the connection and try again."
            case 16: return "Steam reports this game is already running. Close it, then try again."
            case 17, 19, 20:
                return waited
                    ? "Steam could not finish installing content this game needs. Try again later."
                    : "Steam needs to install or update content this game depends on before it can start. Start the game again to let Madeira Dock wait for Steam."
            case 18: return "Steam does not see this game as installed."
            case 28: return "Steam could not find the game's executable."
            // Steam's CreateProcess for the game failed: Madeira could not load the program.
            case 29: return "Steam started this game's program, but Madeira could not load it (Steam reports an invalid platform). Export the log: it names the reason."
            case 22, 23, 24: return "Steam could not read this game's configuration. Try again."
            case 25: return "Steam says this game is not released yet."
            case 26: return "Steam says this game is not available in your region."
            case 35: return "Steam says this account is playing in another session. Close the game on your other device and start it again."
            default: return nil
            }
        }
    }

    static let reportAllowed: Set<String> = ["probe-start-bits", "client-machine", "client-pe-timestamp",
        "load-client-begin", "load-client-error", "public-client021-present", "engine005-present",
        "engine-factory-result", "session-client-adapter", "session-unsupported-client", "session-user-method-mismatch",
        "session-private-abi-verified", "session-login-disabled", "session-native-handoff-invalid",
        "session-native-handoff-app-mismatch", "session-handoff-stage", "session-handoff-error",
        "session-account-input-invalid", "session-app-input-invalid",
        "session-native-token-submitted", "session-logon-start-result", "session-connection-result",
        "session-authenticated-online", "session-requested-app-entitled", "session-subscription-count",
        "session-requested-app-listed", "session-auth-test-result",
        "session-online-subscription-count", "session-online-app-zero-query", "session-online-callback-id",
        "session-timeout-subscription-count", "session-timeout-app-listed", "session-timeout-still-online",
        "session-online-blip", "session-online-blips", "session-online-lost", "session-entitlement-source",
        "session-offline-abi", "session-offline-requested", "session-offline-can", "session-offline-logon-result",
        "session-offline-logon-retry", "session-offline-logon-state", "session-offline-callback-id",
        "session-offline-entitled", "session-offline-listed", "session-offline-timeout-state",
        "session-offline-fallback", "session-offline-ready",
        "launch-user-arguments-bytes", "launch-user-arguments-invalid",
        "launch-game-running", "friends-available", "friends-own-state", "friends-signin-available", "friends-signin", "friends-requested", "friends-own-game", "friends-total", "friends-valid-ids", "friends-named", "friends-playing", "friends-seconds", "friends-count", "friends-cmd-seq", "friends-cmd-result",
        "steam-input-available", "steam-input-controllers", "steam-input-ps-support", "steam-input-ps-support-set", "steam-input-ps-support-restored", "steam-input-settings-changed", "steam-input-config", "steam-input-store1-ps", "steam-input-store1-app", "steam-input-store2-ps", "steam-input-store2-app", "steam-input-store3-ps", "steam-input-store3-app", "steam-input-store4-ps", "steam-input-store4-app", "steam-input-store1-set", "steam-input-store2-set", "steam-input-store3-set", "steam-input-store4-set", "steam-input-override-restored", "steam-input-sdl-init", "steam-input-sdl-joysticks", "steam-input-focus-pid", "steam-input-focus-set", "steam-input-focused-app", "steam-input-activated", "steam-input-selected", "steam-input-layout-loaded", "steam-input-binding",
        "steam-input-mapping-cached", "steam-input-layout-source", "steam-input-layout-queued", "steam-input-layout-unavailable", "steam-input-connected",
        "steam-input-output-stream", "steam-input-output-reserved", "steam-input-output-connected", "steam-input-output-changed",
        "steam-input-activation-requested", "steam-input-focus-reported",
        "steam-input-config-loaded-events", "steam-input-config-loaded-major",
        "steam-input-config-loaded-minor", "steam-input-config-loaded-flags",
        "steam-input-layout-revision-known", "steam-input-layout-revision",
        "steam-input-load-result-events", "steam-input-load-result-completed",
        "steam-input-load-result-revision", "steam-input-load-result-matches-revision",
        "steam-input-probe-phase",
        "launch-client-error", "launch-option-index", "launch-option-invalid", "launch-option-missing",
        "launch-update-wait", "launch-update-retry", "launch-update-ready",
        "launch-config-wait", "launch-config-gave-up", "launch-session-wait", "launch-session-gave-up",
        "ceg-request", "ceg-request-result", "ceg-request-busy", "ceg-server-result", "ceg-job-result",
        "ceg-finished-jobs", "ceg-result", "ceg-disabled", "ceg-unsupported-client",
        "ceg-scm", "ceg-scm-started", "ceg-scm-error", "ceg-service-registered", "ceg-service-install", "ceg-service-stop", "ceg-scm-stopped",
        "game-scm", "game-scm-timeout", "launch-keep-alive",
        "shutdown-begin", "shutdown-complete", "probe-result"]
    /// The host's report rounds (madeira-dock src/main.c).
    static let reportRounds: Set<String> = ["ml1820", "ml1830", "ml1860", "ml1870", "ml1970", "ml1990", "ml2000", "ml2011", "ml2015", "ml2016"]

    /// The largest report read. Dock bounds its friends lines, but a long session
    /// still writes more than the old 32 KB, and a report past the cap would hide
    /// probe-result at game end.
    static let reportCap = 1 << 20

    static func parseReport(_ data: Data) -> Report {
        guard data.count <= reportCap, let text = String(data: data, encoding: .utf8) else { return Report() }
        var report = Report()
        // Ignore a partial final line until the writer completes and flushes it.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "[steam-host]", reportRounds.contains(String(parts[1])) else { continue }
            let field = parts[2].trimmingCharacters(in: .newlines).split(separator: "=", maxSplits: 1)
            guard field.count == 2 else { continue }
            let key = String(field[0]), value = String(field[1])
            if key == "client-sha256", value.utf8.count == 64,
               value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                report.fields[key] = value
            } else if key == "session-callback-id", let number = Int32(value) {
                // Valve's callback IDs after sign-in (the host reports the first 16), in
                // order, as one field: the poll logs a field only when it changes.
                let ids = report.fields["session-callback-ids"]
                if (ids?.split(separator: ",").count ?? 0) < 16 {
                    report.fields["session-callback-ids"] = (ids.map { $0 + "," } ?? "") + String(number)
                }
            } else if reportAllowed.contains(key), let number = Int32(value) {
                report.fields[key] = String(number)
            }
        }
        return report
    }

    @MainActor private static var lastReport = Report()

    /// Reads C:\madeira-dock.txt and logs fields that changed ([dock-report]).
    @MainActor static func pollReport() -> Report {
        DockSteamInputService.refresh()
        let url = drive.appendingPathComponent("madeira-dock.txt")
        guard let file = try? FileHandle(forReadingFrom: url) else { return lastReport }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: reportCap + 1), data.count <= reportCap else { return lastReport }
        let report = parseReport(data)
        for key in report.fields.keys.sorted() where report.fields[key] != lastReport.fields[key] {
            SteamLog.event("[dock-report] \(key)=\(report.fields[key]!)")
        }
        // The host ended: its whole report, in order, so the sequence and repeats of
        // its numeric fields are in the diagnostic log (each line is `[steam-host]
        // <round> <field>=<number>`; nothing else is in the file).
        if report.fields["probe-result"] != nil, lastReport.fields["probe-result"] == nil {
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("[steam-host] ") }
            SteamLog.event("[dock-report-file] lines=\(lines.count)")
            for line in lines.prefix(400) { SteamLog.event("[dock-report-file] " + line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        lastReport = report
        return report
    }

    // MARK: Launch

    private static var transferURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MadeiraDock", isDirectory: true).appendingPathComponent("launch.auth")
    }

    /// Removes an unconsumed transfer (session end, sign-out, app start).
    @MainActor static func cleanup() {
        DockSteamInputService.end()
        if let url = transferURL { try? FileManager.default.removeItem(at: url) }
        unsetenv("MADEIRA_DOCK_AUTH_FILE")
        unsetenv("MADEIRA_DOCK_OFFLINE")
    }

    /// Writes the one-use transfer to protected Application Support storage
    /// (complete file protection, mode 0600, excluded from backups, created
    /// exclusively) and puts only its guest path in the environment. No
    /// token, account name or path is logged.
    @MainActor static func writeHandoff(account: String, token: String, appID: Int) throws {
        cleanup()
        lastReport = Report()
        DockFriends.shared.reset()
        let report = drive.appendingPathComponent("madeira-dock.txt")
        if FileManager.default.fileExists(atPath: report.path) { try FileManager.default.removeItem(at: report) }
        guard let url = transferURL else { throw DockError.message("Dock's private transfer folder is unavailable.") }
        var data = try envelope(account: account, token: token, steamID: subject(token), appID: appID)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let fm = FileManager.default
        var folder = url.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw DockError.message("Dock's transfer folder is invalid.")
        }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DockError.message("Madeira could not create Dock's private sign-in transfer.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            try file.write(contentsOf: data); try file.close()
            DockSteamInputService.begin(accountID: UInt32(truncatingIfNeeded: try subject(token)), appID: UInt32(appID))
            setenv("MADEIRA_DOCK_AUTH_FILE", handoffGuestPath(url), 1)
            SteamLog.event("[dock-handoff] protected-file-ready=1")
        } catch { try? file.close(); cleanup(); throw error }
    }

    /// The host's environment for one launch.
    static func configure(_ game: DockGame, launchOption: UInt32 = 0, arguments: String = "") {
        for key in ["MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN", "MADEIRA_STEAM_HOST_LAUNCH"] {
            setenv(key, "1", 1)
        }
        setenv("MADEIRA_STEAM_HOST_APPID", String(game.id), 1)
        setenv("MADEIRA_DOCK_PERSONA_STATE", String(SteamOnlineStatus.current.rawValue), 1)
        setenv("MADEIRA_STEAM_HOST_LAUNCH_OPTION", String(launchOption), 1)
        setenv("MADEIRA_STEAM_HOST_CLIENT_DIR", SteamRuntimeFiles.windowsRoot, 1)
        setenv("MADEIRA_STEAM_HOST_EXPECTED_INSTALL", game.windowsInstallPath, 1)
        setenv("MADEIRA_STEAM_HOST_LOG", "C:\\madeira-dock.txt", 1)
        // The client receives only this game's extra arguments, separately from the host's
        // explorer/cmd command. An empty profile clears any previous game's choice.
        if arguments.isEmpty { unsetenv("MADEIRA_STEAM_HOST_ARGUMENTS") }
        else { setenv("MADEIRA_STEAM_HOST_ARGUMENTS", arguments, 1) }
        // The install record lists per-user executables: Dock asks Valve's client to prepare
        // them before it launches. env.MADEIRA_DOCK_CEG = 0 never asks.
        if game.customExecutables && SteamSignIn.flag("MADEIRA_DOCK_CEG", default: true) {
            setenv("MADEIRA_STEAM_HOST_CEG", "1", 1)
        } else {
            unsetenv("MADEIRA_STEAM_HOST_CEG")
        }
        // Never let a stale environment choose the PC cached-account test path.
        unsetenv("MADEIRA_STEAM_HOST_ACCOUNT"); unsetenv("MADEIRA_STEAM_HOST_STEAMID")
        // Valve's client unloads DLLs while it starts and the loader can map a different
        // DLL of the same size at the same address. The engine's opt-in image-retire
        // switch (MADEIRA_JIT_IMAGE_RETIRE, off for every other session) gives that DLL
        // fresh code instead of the unloaded one's translation. Dock sessions turn it on;
        // an engine without the switch ignores the variable. env.MADEIRA_DOCK_IMAGE_RETIRE = 0
        // leaves it off, and an explicit env.MADEIRA_JIT_IMAGE_RETIRE in madeira.cfg still wins.
        let retire = SteamSignIn.flag("MADEIRA_DOCK_IMAGE_RETIRE", default: true)
        if retire { setenv("MADEIRA_JIT_IMAGE_RETIRE", "1", 1) }
        SteamLog.event("[dock-launch] image-retire=\(retire ? 1 : 0)")
        // While the loader loads Valve's client and its many imports, the emulator's
        // image-map handler can commit a page of its own heap under its interval lock; the
        // commit's notification then waits for that same lock and the host parks for good
        // (no report after load-client-begin). Wine's opt-in MADEIRA_IMAGE_MAP_GUARD (off for
        // every other session) keeps the emulator's own memory calls un-notified there, as
        // on the syscall path. Dock sessions turn it on; ntdll without the switch ignores it.
        // env.MADEIRA_DOCK_IMAGE_MAP_GUARD = 0 leaves it off.
        let guardMap = SteamSignIn.flag("MADEIRA_DOCK_IMAGE_MAP_GUARD", default: true)
        if guardMap { setenv("MADEIRA_IMAGE_MAP_GUARD", "1", 1) }
        SteamLog.event("[dock-launch] image-map-guard=\(guardMap ? 1 : 0)")
        DockOffline.configure(appID: game.id)
    }

    /// Wine's explorer opens a virtual desktop and starts the host in it. With
    /// `installers` (DockInstallers.script), cmd.exe first runs the game's one-time
    /// installs in the same session, then the host. No token is quoted: MADEIRA_ARGS is
    /// split at spaces and passed on as is, so quote characters would reach Wine
    /// literally, and none of these paths contains a space.
    /// madeira-bcd: `host` false runs only the installers; the session ends after them
    /// (DockInstallers.installsOnly).
    static func launchArguments(width: Int, height: Int, installers: String? = nil, host: Bool = true) -> String {
        guard let installers else { return "/desktop=madeira,\(width)x\(height) \(executable)" }
        guard host else { return "/desktop=madeira,\(width)x\(height) C:\\windows\\system32\\cmd.exe /c call \(installers)" }
        return "/desktop=madeira,\(width)x\(height) C:\\windows\\system32\\cmd.exe /c call \(installers) & \(executable)"
    }

    /// Set on the main actor right before a Dock launch; read (and cleared) once by the
    /// launch worker, so only that launch sees it.
    nonisolated(unsafe) private static var launchRequest: (dock: Bool, compact: Bool) = (false, false)
    static func requestLaunch(compactPool: Bool) { launchRequest = (true, compactPool) }
    static func takeLaunchRequest() -> (dock: Bool, compact: Bool) {
        defer { launchRequest = (false, false) }
        return launchRequest
    }
}

/// Offline play for Steam games started through Madeira Dock.
///
/// Valve's client can log an account on without a connection, with an offline
/// logon ticket Steam issues to it during an online logon (desktop Steam's
/// Offline Mode). The host asks the client for exactly that (madeira-dock
/// docs/OFFLINE.md): Madeira decides nothing about ownership and stores no
/// ticket. What lives here is only what the app needs around it:
///
/// - whether the device has a network path, so a start without one asks for the
///   offline logon straight away (`MADEIRA_DOCK_OFFLINE=1`) instead of waiting
///   out a connection that cannot happen;
/// - a note of the last online start in which Valve's client confirmed a licence
///   and said the account can log on offline (the host's
///   `session-offline-ready=1`), for the Game details mark. Steam's offline
///   sign-in belongs to the ACCOUNT: with it, Valve's client answers the licence
///   question for any game from the list it cached, whether or not that game was
///   ever started online. So the note is one date for the account, plus the games
///   started online since, which matters only for a game whose per-user
///   executable Steam prepares on its first start (that needs a connection). It
///   is a display aid: an offline start is always decided by Valve's client.
///
/// `env.MADEIRA_DOCK_OFFLINE_LOGON = 0` removes the feature in the app and in
/// the host (which reads the same variable).
enum DockOffline {
    static let enabled = SteamSignIn.flag("MADEIRA_DOCK_OFFLINE_LOGON", default: true)

    private static let monitor = NWPathMonitor()
    private static var started = false
    /// Starts the path monitor. Called at app start, so the path is current by
    /// the time anything is launched.
    static func begin() {
        guard enabled, !started else { return }
        started = true
        monitor.start(queue: DispatchQueue(label: "madeira.dock-offline.path"))
    }
    /// No usable network path right now. False until the monitor has started.
    static var networkDown: Bool { started && monitor.currentPath.status != .satisfied }

    private static let key = "madeiraDockOfflineVerified", accountKey = "madeiraDockOfflineAccount"
    /// When Valve's client last reported, in an online start, that it can log this
    /// account on offline; nil if it never has on this installation.
    static var accountSaved: Date? {
        guard enabled else { return nil }
        var t = UserDefaults.standard.double(forKey: accountKey)
        // A build that kept only the per-game dates: the newest of those is the account's.
        if t <= 0, let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] {
            t = all.values.max() ?? 0
        }
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    /// When this game last started online in such a session; nil if it never has.
    static func verified(_ appID: Int) -> Date? {
        guard enabled, let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let t = all[String(appID)] else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    /// What Game details says about a game the Dock starts.
    enum Mark: Equatable {
        case ready(Date)        // Steam can sign in offline; this game needs nothing more
        case needsFirstStart    // Steam can sign in offline, but prepares this game's program online first
        case needsOnline        // Steam has no offline sign-in saved yet
    }
    /// `preparedOnline`: the game's install record lists per-user executables,
    /// which Valve's client prepares on the first start, over the network.
    static func mark(_ appID: Int, preparedOnline: Bool) -> Mark {
        guard let saved = accountSaved else { return .needsOnline }
        if preparedOnline, verified(appID) == nil { return .needsFirstStart }
        return .ready(saved)
    }
    private static func save(_ appID: Int) {
        let now = Date().timeIntervalSince1970
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        all[String(appID)] = now
        UserDefaults.standard.set(all, forKey: key)
        UserDefaults.standard.set(now, forKey: accountKey)
    }
    /// Sign-in removed or changed: the notes belonged to that account.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: accountKey)
    }

    /// The app the running Dock session was started for.
    private(set) static var sessionApp: Int?
    private static var sessionMarked = false

    /// Part of MadeiraDock.configure: tells the host when there is no network.
    static func configure(appID: Int) {
        sessionApp = appID
        sessionMarked = false
        let offline = enabled && networkDown
        if offline { setenv("MADEIRA_DOCK_OFFLINE", "1", 1) } else { unsetenv("MADEIRA_DOCK_OFFLINE") }
        SteamLog.event("[dock-offline] enabled=\(enabled ? 1 : 0) network=\(networkDown ? "down" : "up") request=\(offline ? 1 : 0) account-saved=\(accountSaved != nil ? 1 : 0) game-started-online=\(verified(appID) != nil ? 1 : 0)")
    }

    /// Follows the host's report (MadeiraDockModel.watchReport): an online start
    /// in which Valve's client confirmed the licence and reported that it can log
    /// the account on offline saves the game for offline play.
    @MainActor static func observe(_ fields: [String: String]) {
        guard enabled, !sessionMarked, let app = sessionApp,
              fields["session-offline-requested"] == nil,
              fields["session-requested-app-listed"] == "1",
              fields["session-offline-ready"] == "1" else { return }
        sessionMarked = true
        save(app)
        SteamLog.event("[dock-offline] Valve's client can log this account on offline: saved")
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static let changed = Notification.Name("MadeiraDockOfflineChanged")
}

/// Version 1 of Dock's bounded, session-scoped read-only layout service.
/// Wire integers are little endian; native memory layouts are never serialized.
enum DockSteamInputWire {
    static let headerSize = 72
    static let maxFeedSize = headerSize + 4096
    enum Action: UInt32 { case query = 1, sources, apply, restoreDefault }
    enum State: UInt32 { case idle, disconnected, queued, cached, activationRequested, failed, active }
    struct Snapshot: Equatable {
        let session: [UInt8]
        let appID: UInt32
        let epoch: UInt32
        let sequence: UInt32
        let result: UInt32
        let state: State
        let sources: UInt32
        let flags: UInt32
        let workshopID: UInt64
        /// Supported transport groups: buttons, sticks, triggers, touch click.
        /// Motion, touch positions and extra Deck/Steam Controller inputs absent.
        let forwardedInputs: UInt32
        let selection: String
        var connected: Bool { flags & 2 != 0 }
        /// Cache presence for the game, independent of the selected revision.
        var mappingCached: Bool { flags & 4 != 0 }
    }
    static func parse(_ data: Data) -> Snapshot? {
        guard data.count >= headerSize, data.count <= maxFeedSize else { return nil }
        let b = [UInt8](data)
        guard Array(b[0..<8]) == Array("MSIFEED1".utf8) else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[at + $1]) << (8 * $1) } }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[at + $1]) << (8 * $1) } }
        let length = Int(u32(68))
        guard u32(24) > 0, u32(28) == 0, u32(40) <= 8,
              u32(48) & ~UInt32(1) == 0, u32(52) & ~UInt32(63) == 0,
              u32(64) & ~UInt32(15) == 0,
              let state = State(rawValue: u32(44)), length <= 4096,
              b.count == headerSize + length,
              b[8..<24].contains(where: { $0 != 0 }),
              let key = String(bytes: b[headerSize...], encoding: .utf8),
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return Snapshot(session: Array(b[8..<24]), appID: u32(24), epoch: u32(32),
                        sequence: u32(36), result: u32(40), state: state, sources: u32(48),
                        flags: u32(52), workshopID: u64(56), forwardedInputs: u32(64), selection: key)
    }
    static func command(_ action: Action, snapshot: Snapshot, sequence: UInt32) -> Data? {
        guard snapshot.session.count == 16, snapshot.session.contains(where: { $0 != 0 }),
              snapshot.appID > 0, sequence > 0 else { return nil }
        var bytes = Array("MSICMD01".utf8) + snapshot.session
        for value in [snapshot.appID, 0, snapshot.epoch, sequence, action.rawValue] {
            for shift in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
        }
        return Data(bytes)
    }
}

/// The single Madeira virtual DualSense transport currently occupies slot 0.
/// This identity describes that bridge, not a paired controller's hardware ID.
/// Physical per-device identity/player assignment remains to be implemented.
@MainActor enum DockSteamInputService {
    static let controllerID = UUID(uuidString: "77F4893A-244E-4808-994C-617331E9DC25")!
    private(set) static var snapshot: DockSteamInputWire.Snapshot?
    private(set) static var selection: DockSteamInputSelection?
    /// Pending journal work requires explicit recovery; never reapply it just
    /// because a new launch or controller connection appeared.
    private(set) static var recovery: DockSteamInputJournal.Pending?
    private(set) static var prepared: DockSteamInputJournal.Pending?
    private static var journal: DockSteamInputJournal?
    private static var preparedChoice: DockSteamInputSelection.Revision?
    private static var preparedReapplication = false
    private static var preparedClearOverride = false
#if DEBUG
    private static var diagnosticSequence: UInt32 = 0
#endif
    private static var restartAttempted = false
    private static var restartEpoch: UInt32?
    private static var restartWaitStarted: Date?
    private(set) static var activeChoice: DockSteamInputSelection.Revision?
    private(set) static var inputQuiesced = false
    static var onInputQuiescedChanged: ((Bool) -> Void)?
    static let baselineRestoreIdentity = "0EBD445F-87AE-46F2-96BB-042CB53B35E1"

    private static func updateInputQuiesced() {
        let next = prepared != nil || submission != nil
        guard next != inputQuiesced else { return }
        inputQuiesced = next
        onInputQuiescedChanged?(next)
    }
    private struct Submission {
        let work: DockSteamInputJournal.Pending
        let request: DockSteamInputJournal.Request
        let choice: DockSteamInputSelection.Revision
        let generation: UInt64
        let reapplication: Bool
        let clearOverride: Bool
        let previousChoice: DockSteamInputSelection.Revision?
        let sent: Date
    }
    private static var submission: Submission?
    private(set) static var receipt: DockSteamInputTransport.Receipt?
    private static var session: [UInt8] = []
    private static var appID: UInt32 = 0
    private static var accountID: UInt32 = 0
    private static var sequence: UInt32 = 0
    private static var epoch: UInt32?
    private static var attempts = 0
    private static var pending: (sequence: UInt32, sent: Date)?
    private static var storage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MadeiraDock", isDirectory: true)
    }
    private static var feed: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input.bin") }
    private static var command: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-cmd.bin") }

    private static var payloadFile: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-apply.bin") }
    private static var receiptFile: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-tx.bin") }
    private static var baselineFile: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-baseline.bin") }

    static func begin(accountID: UInt32, appID: UInt32) {
        end()
        self.accountID = accountID; self.appID = appID
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        session = stride(from: 0, to: 32, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        // This random launch identifier is not a credential. Never log it.
        setenv("MADEIRA_DOCK_INPUT_SESSION", hex, 1)
        do {
            let store = try DockSteamInputJournal(root: storage,
                scope: .init(accountID: accountID, appID: appID, controllerID: controllerID))
            try store.interrupt()
            let record = try store.snapshot()
            journal = store
            if record.pending?.phase == .interrupted { recovery = record.pending }
        } catch {
            SteamLog.event("[steam-input] layout journal unavailable")
        }
        do {
            selection = try DockSteamInputSelection.load(in: storage, accountID: accountID, appID: appID, controllerID: controllerID)
        } catch {
            // Do not replace an incompatible/corrupt record with an empty one.
            SteamLog.event("[steam-input] saved selection unavailable")
        }
    }
    static func end() {
        do { try journal?.interrupt() }
        catch { SteamLog.event("[steam-input] layout interruption not saved") }
        journal = nil; recovery = nil; prepared = nil; submission = nil; receipt = nil
        preparedChoice = nil; preparedReapplication = false; preparedClearOverride = false; activeChoice = nil
        updateInputQuiesced()
#if DEBUG
        diagnosticSequence = 0
        try? FileManager.default.removeItem(at: MadeiraDock.drive.appendingPathComponent("madeira-steam-input-local-test.bin"))
#endif
        restartAttempted = false; restartEpoch = nil; restartWaitStarted = nil
        unsetenv("MADEIRA_DOCK_INPUT_SESSION")
        session = []; snapshot = nil; selection = nil; pending = nil
        sequence = 0; epoch = nil; attempts = 0; appID = 0; accountID = 0
        try? FileManager.default.removeItem(at: feed)
        try? FileManager.default.removeItem(at: command)
        try? FileManager.default.removeItem(at: payloadFile)
        try? FileManager.default.removeItem(at: receiptFile)
        try? FileManager.default.removeItem(at: baselineFile)
    }
    /// Stage an explicit local template/personal choice without touching Steam.
    /// The caller supplies source and observed baseline bytes, never paths. Live
    /// submission will require the matching session-scoped transaction bridge.
    static func prepareLocal(source: Data, baseline: Data, choice: DockSteamInputSelection.Revision) throws -> DockSteamInputJournal.Pending {
        guard let snapshot, snapshot.connected, snapshot.flags & 1 != 0,
              pending == nil, recovery == nil, prepared == nil,
              let journal, var saved = selection,
              choice.source == .template || choice.source == .personal else { throw DockSteamInputJournal.Failure.busy }
        let hash = DockSteamInputNative.contentHash(source)
        if let expected = choice.contentHash, expected != hash { throw DockSteamInputJournal.Failure.invalid }
        let resolved = DockSteamInputSelection.Revision(source: choice.source, identity: choice.identity, contentHash: hash)
        let captureBaseline = saved.requested == nil
        try saved.request(resolved)
        let work = try journal.prepareLocal(source: source, baseline: baseline, captureSteamBaseline: captureBaseline)
        do { try saved.save(in: storage) }
        catch {
            try? journal.finish(work.reservation, phase: .failed, hash: nil, revision: nil)
            throw error
        }
        selection = saved; prepared = work; receipt = nil
        preparedChoice = resolved; preparedReapplication = false; preparedClearOverride = false; restartAttempted = true
        updateInputQuiesced()
        return work
    }
    /// Stage restoring the captured Steam baseline without mutating saved user
    /// intent before confirmation. Only a confirmed receipt clears the override.
    static func prepareBaselineRestore(baseline: Data) throws -> DockSteamInputJournal.Pending {
        guard let snapshot, snapshot.connected, snapshot.flags & 1 != 0,
              pending == nil, recovery == nil, prepared == nil,
              let journal, let saved = selection, saved.requested != nil else { throw DockSteamInputJournal.Failure.busy }
        let original = try journal.steamBaseline()
        let hash = DockSteamInputNative.contentHash(original)
        let resolved = DockSteamInputSelection.Revision(source: .personal, identity: baselineRestoreIdentity, contentHash: hash)
        let work = try journal.prepareLocal(source: original, baseline: baseline, captureSteamBaseline: false)
        prepared = work; receipt = nil
        preparedChoice = resolved; preparedReapplication = false; preparedClearOverride = true; restartAttempted = true
        updateInputQuiesced()
        return work
    }
    /// Submit only to a host advertising the gated local-apply capability. The
    /// journal is durable before the command can be consumed. Acceptance alone
    /// never updates lastActivated; only a matching hash-bound receipt can.
    static func submitPrepared() throws {
        guard let current = snapshot, current.connected, current.flags & 16 != 0,
              pending == nil, submission == nil, recovery == nil,
              let work = prepared, let journal, let saved = selection, let choice = preparedChoice,
              let content = work.content, choice.contentHash == content.sourceHash,
              (preparedReapplication ? saved.lastActivated == choice : (preparedClearOverride ? saved.requested != nil : saved.requested == choice)) else { throw DockSteamInputJournal.Failure.busy }
        sequence = max(sequence, current.sequence)
        guard sequence < UInt32.max else { throw DockSteamInputJournal.Failure.exhausted }
        sequence += 1
        let request = DockSteamInputJournal.Request(session: session.map { String(format: "%02x", $0) }.joined(),
                                                   epoch: current.epoch, sequence: sequence)
        let bytes = try DockSteamInputTransport.envelope(session: session, appID: appID, epoch: current.epoch,
            sequence: sequence, reservation: work.reservation, apply: journal.content(content.applyHash), rollback: journal.content(content.rollbackHash))
        guard let commandBytes = DockSteamInputWire.command(.apply, snapshot: current, sequence: sequence) else { throw DockSteamInputJournal.Failure.invalid }
        try journal.markQueued(work.reservation, request: request)
        receipt = nil
        submission = Submission(work: work, request: request, choice: choice, generation: saved.generation,
            reapplication: preparedReapplication, clearOverride: preparedClearOverride, previousChoice: activeChoice, sent: Date())
        activeChoice = nil
        updateInputQuiesced()
        do {
            try bytes.write(to: payloadFile, options: .atomic)
            try commandBytes.write(to: command, options: .atomic)
        } catch {
            try? journal.interrupt()
            recovery = try? journal.snapshot().pending
            prepared = nil; submission = nil
            updateInputQuiesced()
            throw error
        }
    }
    private static func refreshSubmission(_ current: DockSteamInputWire.Snapshot) {
        guard let sent = submission, let journal else { return }
        if current.sequence == sent.request.sequence, current.result != 0, current.result != 1 {
            do {
                try journal.finish(sent.work.reservation, phase: .failed, hash: nil, revision: nil)
                activeChoice = sent.previousChoice
                submission = nil; prepared = nil; preparedChoice = nil
                updateInputQuiesced()
            } catch { SteamLog.event("[steam-input] rejected layout result not saved") }
            return
        }
        if let file = try? FileHandle(forReadingFrom: receiptFile) {
            defer { try? file.close() }
            if let bytes = try? file.read(upToCount: 97), let value = DockSteamInputTransport.receipt(bytes),
               value.session == session, value.appID == appID, value.epoch == sent.request.epoch,
               value.sequence == sent.request.sequence,
               value.applyRevision == sent.work.reservation.applyRevision,
               value.rollbackRevision == sent.work.reservation.rollbackRevision {
                if value.phase == .confirmed || value.phase == .rolledBack {
                    let rolledBack = value.phase == .rolledBack
                    guard let content = sent.work.content,
                          value.workingHash == (rolledBack ? content.rollbackHash : content.applyHash) else { return }
                    receipt = value
                    do {
                        var updated = selection
                        guard var saved = updated, saved.generation == sent.generation else { return }
                        if !rolledBack {
                            if sent.reapplication {
                                guard saved.lastActivated == sent.choice else { return }
                            } else if sent.clearOverride {
                                try saved.request(sent.choice)
                                try saved.acknowledge(sent.choice, generation: saved.generation)
                                try saved.clearRequest()
                            } else {
                                try saved.acknowledge(sent.choice, generation: sent.generation)
                            }
                            updated = saved
                        }
                        try journal.finish(sent.work.reservation, phase: rolledBack ? .rolledBack : .confirmed,
                            hash: value.workingHash, revision: value.workingRevision, request: sent.request)
                        activeChoice = rolledBack ? sent.previousChoice : (sent.clearOverride ? nil : sent.choice)
                        submission = nil; prepared = nil; preparedChoice = nil
                        updateInputQuiesced()
                        if !rolledBack, !sent.reapplication, let saved = updated {
                            try saved.save(in: storage); selection = saved
                        }
                    } catch { SteamLog.event("[steam-input] layout receipt not saved") }
                    return
                } else if value.phase == .failed {
                    receipt = value
                    do {
                        try journal.finish(sent.work.reservation, phase: .failed, hash: nil, revision: nil)
                        activeChoice = sent.previousChoice
                        submission = nil; prepared = nil; preparedChoice = nil
                        updateInputQuiesced()
                    } catch { SteamLog.event("[steam-input] layout failure not saved") }
                    return
                } else { receipt = value }
            }
        }
        if Date().timeIntervalSince(sent.sent) > 60 {
            try? journal.interrupt()
            recovery = try? journal.snapshot().pending
            submission = nil; prepared = nil; preparedChoice = nil
            updateInputQuiesced()
        }
    }
    private static func refreshRestart(_ current: DockSteamInputWire.Snapshot) {
        guard !restartAttempted, attempts == 3, pending == nil, submission == nil, prepared == nil,
              current.connected, current.flags & 48 == 48,
              let journal, let saved = selection else { return }
        guard (saved.requested != nil && saved.lastActivated != nil) || recovery != nil else { restartAttempted = true; return }
        if restartWaitStarted == nil { restartWaitStarted = Date() }
        guard let file = try? FileHandle(forReadingFrom: baselineFile) else {
            expireRestartWait(); return
        }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: (1 << 20) + 44),
              let baseline = DockSteamInputTransport.baseline(bytes, session: session, appID: appID, epoch: current.epoch) else {
            expireRestartWait(); return
        }
        do {
            if let interrupted = recovery {
                try journal.abandonInterrupted(interrupted.reservation,
                    newSession: session.map { String(format: "%02x", $0) }.joined(),
                    newEpoch: current.epoch)
                recovery = nil
            }
            restartAttempted = true
            guard saved.requested != nil, let choice = saved.lastActivated, let hash = choice.contentHash else { return }
            let source = try journal.reapplicationSource(hash: hash)
            let work = try journal.prepareLocal(source: source, baseline: baseline)
            prepared = work; preparedChoice = choice; preparedReapplication = true; preparedClearOverride = false
            updateInputQuiesced()
            try submitPrepared()
        } catch { restartAttempted = true; SteamLog.event("[steam-input] confirmed layout restart unavailable") }
    }
    private static func expireRestartWait() {
        if let started = restartWaitStarted, Date().timeIntervalSince(started) > 30 {
            restartAttempted = true
            SteamLog.event("[steam-input] working baseline unavailable for restart")
        }
    }
#if DEBUG
    /// Scoped test mailbox for exercising the real app journal/submit/restart
    /// path before the layout UI exists. No arbitrary source names or paths.
    /// Action 1 selects the fixed synthetic fixture only with no explicit choice;
    /// action 2 restores the captured Steam baseline and clears the test override
    /// only after its exact successful receipt. Release builds omit this code.
    private static func refreshLocalDiagnostic(_ current: DockSteamInputWire.Snapshot) {
        guard attempts == 3, pending == nil, submission == nil, prepared == nil, recovery == nil,
              current.connected, current.flags & 48 == 48, let journal, let saved = selection else { return }
        let marker = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-local-test.bin")
        guard let markerFile = try? FileHandle(forReadingFrom: marker) else { return }
        let bytes = try? markerFile.read(upToCount: 45); try? markerFile.close()
        guard let bytes, bytes.count == 44 else { try? FileManager.default.removeItem(at: marker); return }
        var request = sh_input_command()
        let valid = bytes.withUnsafeBytes { sh_input_command_parse($0.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count, &request) }
        let nonce = withUnsafeBytes(of: request.session) { Array($0) }
        guard valid, nonce == session, request.appid == appID, request.controller == 0,
              request.epoch == current.epoch, request.sequence > diagnosticSequence else {
            try? FileManager.default.removeItem(at: marker); return
        }
        guard let file = try? FileHandle(forReadingFrom: baselineFile) else { return }
        let frame = try? file.read(upToCount: (1 << 20) + 44); try? file.close()
        guard let frame, let baseline = DockSteamInputTransport.baseline(frame, session: session, appID: appID, epoch: current.epoch) else { return }
        diagnosticSequence = request.sequence
        try? FileManager.default.removeItem(at: marker)
        do {
            if request.action == 1 {
                guard saved.requested == nil else { throw DockSteamInputJournal.Failure.busy }
                let fixture = MadeiraDock.clientRoot.appendingPathComponent("controller_base/templates/madeira_m1_revision_probe.vdf")
                let sourceFile = try FileHandle(forReadingFrom: fixture); defer { try? sourceFile.close() }
                guard let source = try sourceFile.read(upToCount: 1 << 20), source.count < 1 << 20 else { throw DockSteamInputJournal.Failure.invalid }
                _ = try prepareLocal(source: source, baseline: baseline,
                    choice: .init(source: .template, identity: "madeira_m1_revision_probe.vdf", contentHash: nil))
            } else if request.action == 2 {
                guard saved.requested?.identity == "madeira_m1_revision_probe.vdf",
                      activeChoice?.identity == "madeira_m1_revision_probe.vdf" else { throw DockSteamInputJournal.Failure.stale }
                _ = try prepareBaselineRestore(baseline: baseline)
            } else if request.action == 3 {
                guard saved.requested?.identity == "madeira_m1_revision_probe.vdf",
                      activeChoice?.identity == "madeira_m1_revision_probe.vdf" else { throw DockSteamInputJournal.Failure.stale }
                _ = try prepareBaselineRestore(baseline: Data("controller_mappings { revision 0 wrong baseline }".utf8))
            } else if request.action == 4 {
                guard saved.requested?.identity == "madeira_m1_revision_probe.vdf",
                      activeChoice?.identity == "madeira_m1_revision_probe.vdf" else { throw DockSteamInputJournal.Failure.stale }
                _ = try prepareBaselineRestore(baseline: baseline)
                try journal.interrupt()
                recovery = try journal.snapshot().pending
                prepared = nil; preparedChoice = nil; preparedReapplication = false; preparedClearOverride = false
                updateInputQuiesced()
                restartAttempted = false; restartWaitStarted = nil
                return
            } else { throw DockSteamInputJournal.Failure.invalid }
            try submitPrepared()
        } catch { SteamLog.event("[steam-input] local diagnostic request unavailable") }
    }
#endif
    static func refresh() {
        guard session.count == 16, let file = try? FileHandle(forReadingFrom: feed) else { return }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: DockSteamInputWire.maxFeedSize + 1),
              let current = DockSteamInputWire.parse(data), current.session == session,
              current.appID == appID else { return }
        snapshot = current
        if !current.connected || current.state == .failed { activeChoice = nil; receipt = nil }
        if epoch != current.epoch {
            if prepared != nil || submission != nil {
                do {
                    try journal?.interrupt()
                    recovery = try journal?.snapshot().pending
                } catch {
                    journal = nil
                    SteamLog.event("[steam-input] layout connection recovery unavailable")
                }
                prepared = nil; preparedChoice = nil; submission = nil; receipt = nil
                updateInputQuiesced()
            }
            activeChoice = nil
            if current.connected {
                restartAttempted = false
                restartEpoch = current.epoch
                restartWaitStarted = nil
            }
            epoch = current.epoch; attempts = 0; pending = nil
        }
        sequence = max(sequence, current.sequence)
        refreshSubmission(current)
        if let request = pending {
            if current.sequence == request.sequence {
                pending = nil
                if current.result == 1, current.connected, current.flags & 8 == 0,
                   (!current.selection.isEmpty || current.workshopID != 0), var saved = selection {
                    saved.retainSteamSelection(.init(key: current.selection, workshopID: current.workshopID))
                    do { try saved.save(in: storage); selection = saved }
                    catch { SteamLog.event("[steam-input] selection migration not saved") }
                }
                // A successful empty selection is also a finished query. Failure
                // is explicit; do not repeatedly enumerate or alter the choice.
                attempts = 3
            } else if Date().timeIntervalSince(request.sent) > 10 { pending = nil }
        }
        refreshRestart(current)
#if DEBUG
        refreshLocalDiagnostic(current)
#endif
        guard pending == nil, submission == nil, attempts < 3, current.connected, current.flags & 1 != 0,
              sequence < UInt32.max else { return }
        sequence += 1; attempts += 1
        guard let bytes = DockSteamInputWire.command(.query, snapshot: current, sequence: sequence) else { return }
        do {
            try bytes.write(to: command, options: .atomic)
            pending = (sequence, Date())
        } catch { SteamLog.event("[steam-input] query not written") }
    }
}

/// Persisted Steam Input choices are independent of ControllerSetup and Steam's
/// own selection. This store does not claim that queuing a layout activates it.
struct DockSteamInputSelection: Codable, Equatable {
    enum Source: String, Codable { case gameDefault, community, personal, template }
    struct Revision: Codable, Equatable {
        let source: Source
        /// Workshop ID, personal UUID or template key; nil for Game default.
        let identity: String?
        /// SHA-256 of the exact VDF bytes, absent until a source is resolved.
        let contentHash: String?
    }
    struct SteamSelection: Codable, Equatable {
        let key: String
        let workshopID: UInt64
    }
    let version: Int
    let accountID: UInt32
    let appID: UInt32
    /// Stable Madeira controller identity, never a transient Steam slot index.
    let controllerID: UUID
    private(set) var generation: UInt64
    private(set) var requested: Revision?
    private(set) var observedSteamSelection: SteamSelection?
    private(set) var lastActivated: Revision?

    init(accountID: UInt32, appID: UInt32, controllerID: UUID) {
        version = 1
        self.accountID = accountID
        self.appID = appID
        self.controllerID = controllerID
        generation = 0
    }

    /// Migration records what Steam selected without manufacturing a Madeira
    /// choice or overwriting an earlier observation.
    mutating func retainSteamSelection(_ selection: SteamSelection) {
        if observedSteamSelection == nil { observedSteamSelection = selection }
    }

    mutating func request(_ revision: Revision) throws {
        guard Self.valid(revision), generation < UInt64.max else { throw StoreError.invalid }
        generation += 1
        requested = revision
    }

    /// Relinquish an explicit override after a verified restoration. Historical
    /// acknowledgement remains separate; nil intent does not reapply on restart.
    mutating func clearRequest() throws {
        guard generation < UInt64.max else { throw StoreError.invalid }
        generation += 1; requested = nil
    }

    /// Only a verified active-revision response may call this. A generic cache
    /// hit or ActivateConfig invocation is insufficient. Stale replies cannot
    /// change the last working revision.
    mutating func acknowledge(_ revision: Revision, generation: UInt64) throws {
        guard generation == self.generation, requested == revision,
              revision.contentHash != nil else { throw StoreError.stale }
        lastActivated = revision
    }

    enum StoreError: Error { case invalid, stale, unsupportedVersion }

    private static func valid(_ revision: Revision) -> Bool {
        if let hash = revision.contentHash {
            guard hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        }
        if revision.source == .gameDefault { return revision.identity == nil }
        guard let identity = revision.identity, !identity.isEmpty,
              identity.utf8.count <= 256,
              !identity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        if revision.source == .community {
            guard let id = UInt64(identity), id > 0, String(id) == identity else { return false }
        }
        if revision.source == .personal { return UUID(uuidString: identity) != nil }
        return true
    }

    private func validate() throws {
        guard version == 1 else { throw StoreError.unsupportedVersion }
        guard accountID > 0, appID > 0,
              requested.map(Self.valid) ?? true,
              lastActivated.map({ Self.valid($0) && $0.contentHash != nil }) ?? true,
              observedSteamSelection.map({ $0.key.utf8.count <= 4096 }) ?? true else { throw StoreError.invalid }
    }

    /// Caller supplies a private app storage root. Scope is encoded in the
    /// filename; no layout keys or externally supplied paths are used as paths.
    private func file(in root: URL) -> URL {
        root.appendingPathComponent("steam-input-selections", isDirectory: true)
            .appendingPathComponent("\(accountID)-\(appID)-\(controllerID.uuidString).json")
    }

    func save(in root: URL) throws {
        try validate()
        let url = file(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func load(in root: URL, accountID: UInt32, appID: UInt32, controllerID: UUID) throws -> Self {
        let empty = Self(accountID: accountID, appID: appID, controllerID: controllerID)
        try empty.validate()
        let url = empty.file(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 16384 else { throw StoreError.invalid }
        let stored = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try stored.validate()
        guard stored.accountID == accountID, stored.appID == appID,
              stored.controllerID == controllerID else { throw StoreError.invalid }
        return stored
    }
}

/// Steam Input's PlayStation setting for a Dock launch (docs/STEAM_INPUT.md).
/// Valve's client reads `SteamController_PSSupport` from the account's
/// localconfig.vdf (top level of UserLocalConfigStore: 1 games without
/// PlayStation support, the default; 2 every game) when it starts, and only
/// with 2 does it open a PlayStation pad. Before a Steam Input launch the
/// key is set to 2; when the Dock session ends the line is put back as it
/// was. The previous state is noted in Documents, so a crash is undone at
/// the next launch. Only this one line of the file changes.
enum DockSteamInput {
    static let key = "SteamController_PSSupport"
    private static let every = "2"
    private static var note: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-steam-input.json")
    }
    private struct Note: Codable { var file: String; var previous: String? }

    static func localConfig(steamID: UInt64) -> URL {
        MadeiraDock.clientRoot.appendingPathComponent("userdata/\(steamID & 0xffff_ffff)/config/localconfig.vdf")
    }

    /// The key's value at the top level of UserLocalConfigStore, nil when absent.
    /// Throws when the file is not laid out as expected.
    static func value(in text: String) throws -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let (open, close) = try block(lines)
        return top(lines, open: open, close: close).lazy.compactMap { entry(lines[$0]) }.first
    }

    /// The text with the key set to `value` (nil removes the line).
    static func setting(_ value: String?, in text: String) throws -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let (open, close) = try block(lines)
        if let at = top(lines, open: open, close: close).first(where: { entry(lines[$0]) != nil }) {
            if let value { lines[at] = "\t\"\(key)\"\t\t\"\(value)\"" } else { lines.remove(at: at) }
        } else if let value {
            lines.insert("\t\"\(key)\"\t\t\"\(value)\"", at: open + 1)
        }
        return lines.joined(separator: newline)
    }

    /// Before the launch: the key goes to 2 when `enabled`; any earlier change
    /// still noted (a crash) is undone first.
    static func prepare(steamID: UInt64, enabled: Bool) throws {
        guard restore() else { throw Layout() }
        guard enabled else { return }
        let url = localConfig(steamID: steamID)
        let fm = FileManager.default
        let text = fm.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8) : "\"UserLocalConfigStore\"\n{\n}\n"
        let previous = try value(in: text)
        guard previous != every else { return }
        let changed = try setting(every, in: text)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Persist recovery before touching the client's settings. Failed writes
        // keep the note so the next launch can finish restoring the old value.
        try JSONEncoder().encode(Note(file: url.path, previous: previous)).write(to: note, options: .atomic)
        try changed.write(to: url, atomically: true, encoding: .utf8)
        SteamLog.event("[steam-input] PlayStation support enabled for this launch")
    }

    /// After the client has shut down. Keep recovery information if it fails.
    @discardableResult static func restore() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: note.path) else { return true }
        do {
            let saved = try JSONDecoder().decode(Note.self, from: Data(contentsOf: note))
            let url = URL(fileURLWithPath: saved.file)
            // A first-account write can fail after journaling but before the
            // file exists. The previous absent key is already restored then.
            if saved.previous == nil && !fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: note)
                return true
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            try setting(saved.previous, in: text).write(to: url, atomically: true, encoding: .utf8)
            try fm.removeItem(at: note)
            SteamLog.event("[steam-input] PlayStation setting restored")
            return true
        } catch {
            SteamLog.event("[steam-input] PlayStation setting restoration pending")
            return false
        }
    }

    private struct Layout: Error, LocalizedError { var errorDescription: String? { "unexpected localconfig.vdf layout" } }

    /// The `{` and matching `}` line indices of UserLocalConfigStore.
    private static func block(_ lines: [String]) throws -> (Int, Int) {
        guard let name = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "\"UserLocalConfigStore\"" }),
              name + 1 < lines.count, lines[name + 1].trimmingCharacters(in: .whitespaces) == "{" else { throw Layout() }
        var level = 0
        for i in (name + 1)..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "{" { level += 1 } else if t == "}" { level -= 1; if level == 0 { return (name + 1, i) } }
        }
        throw Layout()
    }

    /// The indices of the block's top-level lines (not inside a nested block).
    private static func top(_ lines: [String], open: Int, close: Int) -> [Int] {
        var level = 0, out: [Int] = []
        for i in (open + 1)..<close {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "{" { level += 1 } else if t == "}" { level -= 1 } else if level == 0 { out.append(i) }
        }
        return out
    }

    /// The value when `line` is `"SteamController_PSSupport" "v"`.
    private static func entry(_ line: String) -> String? {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "\"")
        // "", key, whitespace, "", value, ""
        guard parts.count == 5, parts[0].isEmpty, parts[1] == key, parts[2].trimmingCharacters(in: .whitespaces).isEmpty,
              parts[4].isEmpty else { return nil }
        return parts[3]
    }
}
