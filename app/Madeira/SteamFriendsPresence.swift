import Foundation

/// Friends' online status, game and lobby during a Madeira Dock session.
///
/// Dock's headless client gets the friends list but never receives friends'
/// live status, so Madeira asks Steam's Web API instead: the stored refresh
/// token is exchanged for a web access token (IAuthenticationService/
/// GenerateAccessTokenForApp), then ISteamUser/GetPlayerSummaries is asked for
/// the friends Dock listed in C:\madeira-friends.bin. These are plain HTTPS
/// calls, not a second CM sign-in, so Dock's session is not replaced.
/// Logs carry counts and HTTP statuses only, never tokens, SteamIDs or names.
@MainActor
enum SteamFriendsPresence {
    struct Friend: Equatable {
        let steamID: UInt64
        let name: String
        let dockFlags: UInt8
    }

    struct Presence: Equatable {
        /// Steam persona state: 0 offline, 1 online, 2 busy, 3 away, 4 snooze, 5 trade, 6 play.
        var state: Int
        var appID: UInt32
        var lobby: UInt64
    }

    private(set) static var friends: [Friend] = []
    private(set) static var presence: [UInt64: Presence] = [:]
    private static var accessToken: (value: String, expires: Date)?
    private static var nextFetch = Date.distantPast
    private static var running = false
    private static let interval: TimeInterval = 15
    private static var lastEResult = "-"

    /// Called from MadeiraDock.pollReport while Dock reports friends-available=1.
    static func tick(appID: Int) {
        guard !running, Date() >= nextFetch else { return }
        nextFetch = Date().addingTimeInterval(interval)
        guard let feed = try? Data(contentsOf: MadeiraDock.drive.appendingPathComponent("madeira-friends.bin")) else {
            return skip("no feed")
        }
        guard let parsed = parseFeed(feed) else { return skip("feed malformed (\(feed.count) bytes)") }
        friends = parsed
        guard !parsed.isEmpty else { return skip("feed empty") }
        guard let credentials = SteamSignIn.credentialsForDock() else { return skip("no stored sign-in") }
        guard let me = try? MadeiraDock.subject(credentials.refreshToken) else { return skip("no account in token") }
        running = true
        let ids = parsed.map(\.steamID)
        Task { @MainActor in
            defer { running = false }
            do {
                let token = try await webToken(refresh: credentials.refreshToken, steamID: me)
                var result: [UInt64: Presence] = [:]
                for start in stride(from: 0, to: ids.count, by: 100) {
                    let batch = Array(ids[start..<min(start + 100, ids.count)])
                    result.merge(try await summaries(batch, token: token)) { $1 }
                }
                presence = result
                let online = result.values.filter { $0.state > 0 }
                SteamLog.event("[dock-friends] online=\(online.count) playing=\(online.filter { $0.appID != 0 }.count) "
                    + "same-app=\(online.filter { $0.appID == UInt32(appID) }.count) "
                    + "lobbies=\(online.filter { $0.appID == UInt32(appID) && $0.lobby != 0 }.count) of \(ids.count)")
            } catch {
                SteamLog.event("[dock-friends] presence failed: \(error)")
            }
        }
    }

    private static var lastSkip = ""
    /// Logs why a round was skipped, once per reason.
    private static func skip(_ reason: String) {
        if reason != lastSkip { SteamLog.event("[dock-friends] skipped: \(reason)") }
        lastSkip = reason
    }

    /// Clears the state when a Dock session ends.
    static func reset() {
        friends = []
        presence = [:]
        nextFetch = .distantPast
        lastSkip = ""
    }

    // MARK: Feed (format: madeira-dock README, "Friends")

    nonisolated static func parseFeed(_ data: Data) -> [Friend]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes.count <= 12 + 250 * (18 + 64),
              Array(bytes[0..<8]) == Array("MFRND001".utf8) else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[at + $1]) << (8 * $1) } }
        let count = Int(u32(8))
        guard count <= 250 else { return nil }
        var at = 12, result: [Friend] = []
        for _ in 0..<count {
            guard at + 18 <= bytes.count else { return nil }
            let length = Int(bytes[at + 17])
            guard length < 64, at + 18 + length <= bytes.count,
                  let name = String(bytes: bytes[(at + 18)..<(at + 18 + length)], encoding: .utf8) else { return nil }
            result.append(Friend(steamID: u64(at), name: name, dockFlags: bytes[at + 16]))
            at += 18 + length
        }
        return at == bytes.count ? result : nil
    }

    // MARK: Web API

    enum PresenceError: Error, CustomStringConvertible {
        case http(String, Int)
        case malformed(String)
        var description: String {
            switch self {
            case .http(let call, let status): return "\(call) HTTP \(status)"
            case .malformed(let call): return "\(call) unexpected response"
            }
        }
    }

    private static func webToken(refresh: String, steamID: UInt64) async throws -> String {
        if let token = accessToken, token.expires > Date().addingTimeInterval(60) { return token.value }
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/IAuthenticationService/GenerateAccessTokenForApp/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["refresh_token": refresh, "steamid": String(steamID)])
        let json = try await call(request, name: "GenerateAccessTokenForApp")
        guard let response = json["response"] as? [String: Any], let token = response["access_token"] as? String,
              !token.isEmpty else {
            // Field names only: never a token value.
            let keys = ((json["response"] as? [String: Any])?.keys.sorted() ?? json.keys.sorted()).joined(separator: ",")
            throw PresenceError.malformed("GenerateAccessTokenForApp eresult=\(lastEResult) keys=[\(keys)]")
        }
        accessToken = (token, SteamSignIn.expiry(of: token) ?? Date().addingTimeInterval(3600))
        return token
    }

    private static func summaries(_ ids: [UInt64], token: String) async throws -> [UInt64: Presence] {
        var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
        components.queryItems = [URLQueryItem(name: "access_token", value: token),
                                 URLQueryItem(name: "steamids", value: ids.map(String.init).joined(separator: ","))]
        let json = try await call(URLRequest(url: components.url!), name: "GetPlayerSummaries")
        guard let response = json["response"] as? [String: Any], let players = response["players"] as? [[String: Any]] else {
            throw PresenceError.malformed("GetPlayerSummaries")
        }
        var result: [UInt64: Presence] = [:]
        for player in players {
            guard let id = (player["steamid"] as? String).flatMap(UInt64.init) else { continue }
            result[id] = Presence(state: player["personastate"] as? Int ?? 0,
                                  appID: (player["gameid"] as? String).flatMap(UInt32.init) ?? 0,
                                  lobby: (player["lobbysteamid"] as? String).flatMap(UInt64.init) ?? 0)
        }
        return result
    }

    private static func call(_ request: URLRequest, name: String) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lastEResult = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-eresult") ?? "-"
        guard status == 200 else { throw PresenceError.http(name, status) }
        guard data.count <= 4 << 20, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PresenceError.malformed(name)
        }
        return json
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }
}
