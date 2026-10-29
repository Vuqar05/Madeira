import Foundation
import SwiftUI

/// The friends list and Invite/Join for a running Madeira Dock session (the
/// in-game menu's Friends page). Dock writes the list to C:\madeira-friends.bin
/// and reads one command at a time from C:\madeira-friends-cmd.bin; both
/// formats are in the madeira-dock README, "Friends". SteamIDs and names stay
/// on the device: logs carry counts and result codes only.
@MainActor final class DockFriends: ObservableObject {
    static let shared = DockFriends()

    enum Action: UInt8 { case invite = 1, join = 2 }

    struct Pending: Equatable {
        let action: Action
        let steamID: UInt64
        let sequence: UInt32
    }

    @Published private(set) var friends: [SteamFriendsPresence.Friend] = []
    /// Dock is running with friends available (its feed exists).
    @Published private(set) var available = false
    @Published private(set) var pending: Pending?
    /// The last finished command, for the row that sent it.
    @Published private(set) var outcome: (steamID: UInt64, action: Action, result: Int)?

    private var sequence = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)) | 1
    private var sentAt = Date.distantPast

    private var feedURL: URL { MadeiraDock.drive.appendingPathComponent("madeira-friends.bin") }
    private var commandURL: URL { MadeiraDock.drive.appendingPathComponent("madeira-friends-cmd.bin") }
    private var reportURL: URL { MadeiraDock.drive.appendingPathComponent("madeira-dock.txt") }

    /// Re-reads the feed and the pending command's result.
    func refresh() {
        let data = try? Data(contentsOf: feedURL)
        available = data != nil
        if let data, let parsed = SteamFriendsPresence.parseFeed(data) {
            friends = parsed.sorted { order($0) != order($1) ? order($0) < order($1)
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if let pending { checkResult(pending) }
    }

    /// Joinable friends in this game first, then this game, other games, online, offline.
    private func order(_ f: SteamFriendsPresence.Friend) -> Int {
        if f.dockFlags & 4 != 0 { return 0 }
        if f.dockFlags & 2 != 0 { return 1 }
        if f.dockFlags & 1 != 0 { return 2 }
        return f.state > 0 ? 3 : 4
    }

    func send(_ action: Action, to friend: SteamFriendsPresence.Friend) {
        guard pending == nil else { return }
        sequence = sequence &+ 1
        if sequence == 0 { sequence = 1 }
        var bytes = [UInt8]("MFCMD001".utf8)
        bytes.append(action.rawValue)
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: friend.steamID >> (8 * UInt64(i)))) }
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: sequence >> (8 * UInt32(i)))) }
        do {
            try Data(bytes).write(to: commandURL, options: .atomic)
        } catch {
            SteamLog.event("[dock-friends] command not written")
            outcome = (friend.steamID, action, 6)
            return
        }
        pending = Pending(action: action, steamID: friend.steamID, sequence: sequence)
        sentAt = Date()
        outcome = nil
        SteamLog.event("[dock-friends] \(action) sent")
    }

    /// Dock answers with friends-cmd-seq (this command's sequence), then
    /// friends-cmd-result; without an answer in 10 s the command lapses.
    private func checkResult(_ pending: Pending) {
        if let data = try? Data(contentsOf: reportURL), data.count <= 1 << 20 {
            var seenSequence = false
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if line.hasSuffix("friends-cmd-seq=\(pending.sequence)") { seenSequence = true }
                else if seenSequence, let value = line.split(separator: "friends-cmd-result=").last.flatMap({ Int($0) }),
                        line.contains("friends-cmd-result=") {
                    finish(pending, result: value)
                    return
                }
            }
        }
        if Date().timeIntervalSince(sentAt) > 10 { finish(pending, result: 0) }
    }

    private func finish(_ pending: Pending, result: Int) {
        self.pending = nil
        outcome = (pending.steamID, pending.action, result)
        SteamLog.event("[dock-friends] \(pending.action) result=\(result)")
    }

    /// Clears the state when a Dock session ends.
    func reset() {
        friends = []
        available = false
        pending = nil
        outcome = nil
    }

    static func message(action: Action, result: Int) -> String {
        switch result {
        case 1: return action == .invite ? "Invite sent" : "Joining…"
        case 2: return action == .invite ? "Start the game to invite" : "Not in a joinable lobby"
        case 3: return "Not on your friends list"
        case 4: return "Steam refused the request"
        case 0: return "No answer from Steam"
        default: return "Friends are unavailable"
        }
    }
}

struct DockFriendRow: View {
    let friend: SteamFriendsPresence.Friend
    @ObservedObject var model: DockFriends

    private var status: String {
        if friend.dockFlags & 4 != 0 { return "In this game · joinable" }
        if friend.dockFlags & 2 != 0 { return "In this game" }
        if friend.dockFlags & 1 != 0 { return "In another game" }
        switch friend.state {
        case 0: return "Offline"
        case 2: return "Busy"
        case 3, 4: return "Away"
        default: return "Online"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(friend.dockFlags & 3 != 0 ? Color.green : friend.state > 0 ? Color.blue : Color.gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name.isEmpty ? "Unknown" : friend.name).lineLimit(1)
                if let outcome = model.outcome, outcome.steamID == friend.steamID {
                    Text(DockFriends.message(action: outcome.action, result: outcome.result))
                        .font(.caption).foregroundStyle(outcome.result == 1 ? .green : .orange)
                } else {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.pending?.steamID == friend.steamID {
                ProgressView()
            } else {
                if friend.dockFlags & 4 != 0 {
                    Button("Join") { model.send(.join, to: friend) }.buttonStyle(.borderedProminent)
                        .disabled(model.pending != nil)
                }
                if friend.state > 0 {
                    Button("Invite") { model.send(.invite, to: friend) }.buttonStyle(.bordered)
                        .disabled(model.pending != nil)
                }
            }
        }
        .frame(minHeight: 44)
    }
}
