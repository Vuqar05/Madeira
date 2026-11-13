// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

struct Snapshot { var appID: UInt32 = 105600; var session: [UInt8] = []; var epoch: UInt32 = 1; var sequence: UInt32 = 1 }
enum DockSteamInputDefault {
    enum Failure { case notInstalled }
    enum Resolution { case recommended(Int); case unresolved(Failure) }
}
enum DockSteamInputService {
    static let snapshot: Snapshot? = nil
    static let activeChoice: Int? = nil
    static let selection: Int? = nil
    static let canChange = false, canBootstrap = false, resolvingWorkshop = false, bootstrapping = false
    static let sourceFailure: String? = nil
    static func retrySources(appID: UInt32) {}
    static func requestGameDefault(_ value: Int) throws {}
    static func requestGenericTemplate(clientRoot: URL) throws {}
    static func requestDebugOverride(clientRoot: URL) throws {}
}
enum DockSteamInputPresentation {
    struct Actions { var note = ""; var offerDefault = false; var offerGeneric = false; var offerRetry = false }
    static func lines(appID: UInt32, snapshot: Snapshot?, active: Int?, selection: Int?) -> [String] { [] }
    static func defaultActions(_ resolution: DockSteamInputDefault.Resolution?, active: Int?) -> Actions { Actions() }
}
enum MadeiraDock {
    struct Game: Sendable { let id: Int }
    static let drive = URL(fileURLWithPath: "/tmp")
    static let clientRoot = drive
    static func games(drive: URL) -> [Game] { [] }
}
final class SteamOwnedLibrary {
    static let shared = SteamOwnedLibrary()
    func resolveSteamInputDefault(game: MadeiraDock.Game, refresh: Bool) async -> DockSteamInputDefault.Resolution { .unresolved(.notInstalled) }
}
struct SteamInputCommunityView: View {
    let appID: UInt32
    var body: some View {
        List { NavigationLink("Fixture layout") { Text("Fixture revision").accessibilityIdentifier("revision") } }
            .navigationTitle("Community layouts")
    }
}
@main struct NavigationProbe: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("details") {
                NavigationStack { Form { SteamInputStatusView(appID: 105600) }.navigationTitle("Controls") }
            } else {
                // Session menu: a custom overlay with no navigation container.
                ZStack {
                    Color.black.ignoresSafeArea()
                    ScrollView { VStack { Text("Session"); SteamInputStatusView(appID: 105600) } }
                        .frame(width: 350, height: 500).background(.regularMaterial)
                }
            }
        }
    }
}
