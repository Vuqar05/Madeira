// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

// The layout service, its presentation and the library, reduced to what the
// status view reads. Launch arguments pick the state: "saved" (a chosen
// personal layout, game not running) and "held" (a running game whose saved
// layout waits for confirmation).
struct Snapshot { var appID: UInt32 = 105600; var session: [UInt8] = []; var epoch: UInt32 = 1; var sequence: UInt32 = 1 }
enum DockSteamInputDefault {
    enum Failure { case notInstalled }
    enum Resolution { case recommended(Int); case unresolved(Failure) }
}
enum DockSteamInputJournal { enum Failure: Error { case busy } }
struct DockSteamInputSelection {
    struct Revision: Equatable { var name = "Personal layout" }
    var requested: Revision?
}
@MainActor enum DockSteamInputService {
    static var snapshot: Snapshot? = ProcessInfo.processInfo.arguments.contains("held") ? Snapshot() : nil
    static let activeChoice: Int? = nil
    static let selection: Int? = nil
    static let canChange = false, canBootstrap = false, resolvingWorkshop = false, bootstrapping = false
    static let sourceFailure: String? = nil
    static var saved: DockSteamInputSelection.Revision? = ProcessInfo.processInfo.arguments.contains("saved") ? .init() : nil
    static var held: SteamInputConfirmationNeeded? = ProcessInfo.processInfo.arguments.contains("held")
        ? .init(controller: .dualSense, hash: String(repeating: "a", count: 64), gaps: ["controls made for a Steam Deck", "rear buttons"]) : nil
    static func confirmHeld() throws { held = nil }
    static func savedSelection(accountID: UInt32, appID: UInt32, controller: SteamInputController) -> DockSteamInputSelection? { .init(requested: saved) }
    static func clearSavedOverride(accountID: UInt32, appID: UInt32, controller: SteamInputController) throws { saved = nil }
    static func retrySources(appID: UInt32) {}
    static func requestGameDefault(_ value: Int) throws {}
    static func requestGenericTemplate(clientRoot: URL) throws {}
    static func requestDebugOverride(clientRoot: URL) throws {}
}
enum DockSteamInputPresentation {
    struct Actions { var note = ""; var offerDefault = false; var offerGeneric = false; var offerRetry = false }
    struct State { var text: String; var severity = 0 }
    static func lines(appID: UInt32, snapshot: Snapshot?, active: Int?, selection: Int?) -> [String] { [] }
    static func defaultActions(_ resolution: DockSteamInputDefault.Resolution?, active: Int?) -> Actions { Actions() }
    @MainActor static func state(appID: UInt32, saved: DockSteamInputSelection.Revision?) -> State {
        if DockSteamInputService.snapshot == nil {
            return .init(text: saved.map { "Chosen: \($0.name). It is applied when the game starts." }
                         ?? "Chosen: Game default (Steam's saved layout for this game).")
        }
        return DockSteamInputService.held != nil
            ? .init(text: "Needs your confirmation: the saved layout was made for another controller.", severity: 1)
            : .init(text: "Loading the layout into Steam Input…")
    }
}
enum MadeiraDock {
    struct Game: Sendable { let id: Int }
    static let drive = URL(fileURLWithPath: "/tmp")
    static let clientRoot = drive
    static func games(drive: URL) -> [Game] { [] }
}
@MainActor final class SteamOwnedLibrary {
    static let shared = SteamOwnedLibrary()
    let personalLayoutAccountID: UInt32 = 7
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
