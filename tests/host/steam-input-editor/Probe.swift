// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// Only the Steam network, logging and the Dock drive are stubbed. The editor,
// store, live-edit coordinator, layout service and C transaction code are the
// production sources.
enum MadeiraDock {
    static var drive: URL { FileManager.default.temporaryDirectory.appendingPathComponent("drive") }
    static var clientRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("client") }
}
enum SteamLog { static func event(_ text: String) {}; static func trace(_ text: @autoclosure () -> String) {} }
enum VDFParser { static func parseTextVDF(from: Data, sectionOrder: (([String], [String]) -> Void)? = nil) -> [String: Any] { [:] } }
enum MadeiraConfig { static func get(_ key: String) -> String? { nil }; static func set(_ key: String, _ value: String?) {} }
@MainActor final class SteamSession {
    enum Method { case workshopGetDetails, workshopQueryFiles }
    init(anonymous: Bool) {}
    func ensureConnected() async throws { throw CancellationError() }
    func callServiceMethodWithResult(method: Method, body: Data, timeout: TimeInterval) async throws -> (eresult: Int32, body: Data) { throw CancellationError() }
}
@MainActor final class SteamLibraryFetcher {
    init(session: SteamSession) {}
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? { nil }
}

func probeLayout(title: String, binding: String = "xinput_button A, Jump, ") -> Data {
    Data("""
    "controller_mappings"
    {
    \t"version"\t\t"3"
    \t"revision"\t\t"4"
    \t"title"\t\t"\(title)"
    \t"controller_type"\t\t"controller_ps5"
    \t"future_block" { "kept" "exactly" }
    \t"group"
    \t{
    \t\t"id"\t\t"0"
    \t\t"mode"\t\t"four_buttons"
    \t\t"inputs"
    \t\t{
    \t\t\t"button_a" { "activators" { "Full_Press" { "bindings" { "binding" "\(binding)" } } } }
    \t\t}
    \t}
    \t"group"
    \t{
    \t\t"id"\t\t"1"
    \t\t"mode"\t\t"joystick_move"
    \t\t"inputs" { }
    \t}
    \t"preset" { "id" "0" "name" "Default" "group_source_bindings" { "0" "button_diamond active" "1" "joystick active" } }
    }

    """.utf8)
}

@MainActor func seed() {
    let arguments = ProcessInfo.processInfo.arguments
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    guard arguments.contains("reset") else { return }
    try? FileManager.default.removeItem(at: support.appendingPathComponent("SteamInputPersonal"))
    try? FileManager.default.removeItem(at: support.appendingPathComponent("MadeiraDock"))
    let seedCopy = try! SteamInputPersonalCopy.create(from: probeLayout(title: "Seed"), title: "Seed", creation: .init(kind: .template, detail: "Gamepad"),
                                                      accountID: 24, appID: 480, root: support)
    if arguments.contains("selected") {
        // The saved selection names Seed: it must not be deletable.
        var selection = DockSteamInputSelection(accountID: 24, appID: 480, controllerID: DockSteamInputService.controllerID)
        try! selection.request(.init(source: .personal, identity: seedCopy.id.uuidString, contentHash: seedCopy.hash, detail: "Seed"))
        try! selection.save(in: support.appendingPathComponent("MadeiraDock"))
    }
    if arguments.contains("damaged") {
        let broken = try! SteamInputPersonalCopy.create(from: probeLayout(title: "Broken"), title: "Broken", creation: .init(kind: .template, detail: "Gamepad"),
                                                        accountID: 24, appID: 480, root: support)
        try! Data("{".utf8).write(to: broken.directory(support).appendingPathComponent("layout.json"))
    }
}

@main struct EditorProbe: App {
    init() { seed() }
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    SteamInputPersonalLayoutsSection(appID: 480, accountID: 24,
                        gameDefault: { (probeLayout(title: "Default"), "the layout bundled with this game") },
                        templates: { [SteamInputTemplates.Template(name: "controller_ps5_gamepad_joystick.vdf", title: "Gamepad", bytes: probeLayout(title: "Gamepad"))] })
                }
                .navigationTitle("Layouts")
            }
        }
    }
}
