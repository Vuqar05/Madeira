#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Exercise the real PICS input metadata parser without a Steam connection."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
owned = (root / 'app/Madeira/SteamOwnedLibrary.swift').read_text()


def method(header):
    start = owned.index(header)
    opening = owned.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (owned[end] == '{') - (owned[end] == '}')
        end += 1
    return owned[start:end]


program = r'''
import Foundation
enum VDFParser { static func parseTextVDF(from: Data, sectionOrder: (([String], [String]) -> Void)? = nil) -> [String: Any] { [:] } }
enum MadeiraConfig {
    static func get(_ key: String) -> String? { nil }
    static func set(_ key: String, _ value: String?) {}
}
enum SteamLog { static func event(_ text: String) {} }
@main struct Test {
    static func main() throws {
        func app(_ config: [String: Any]) -> SteamAppInfo {
            SteamAppInfo.parse(appID: 480, from: ["common": ["name": "Fixture", "type": "Game"], "config": config])!
        }
        let metadata = app(["steamcontrollertemplateindex": "13", "steaminputmanifestpath": "input\\actions.vdf"]).steamInputMetadata!
        precondition(metadata.templateIndex == 13 && metadata.manifestPath == "input/actions.vdf")
        let decoded = try JSONDecoder().decode(SteamAppInfo.SteamInputMetadata.self, from: JSONEncoder().encode(metadata))
        precondition(decoded == metadata)
        let full = SteamAppInfo.parse(appID: 480, from: ["common": ["name": "Fixture", "type": "game", "controller_support": "full"],
            "config": ["steamcontrollerconfigfileids": "12, 13,12,"]])!.steamInputMetadata!
        precondition(full.controllerSupport == 2 && full.workshopIDs == [12, 13])
        let old = try JSONDecoder().decode(SteamAppInfo.SteamInputMetadata.self, from: Data("{\"templateIndex\":4}".utf8))
        precondition(old.controllerSupport == nil && old.workshopIDs == nil)
        precondition(SteamAppInfo.SteamInputMetadata.parse(["steamcontrollerconfigfileids": "12,wrong"]) == nil)
        precondition(app(["steamcontrollertemplateindex": "1"]).steamInputMetadata?.templateIndex == 1)
        let both = app(["steamcontrollertemplateindex": "4", "steaminputmanifestpath": "input/actions.vdf"]).steamInputMetadata
        precondition(both?.templateIndex == 4 && both?.manifestPath == "input/actions.vdf")
        let pathOnly = app(["steaminputmanifestpath": "input/actions.vdf"]).steamInputMetadata
        precondition(pathOnly != nil && pathOnly?.templateIndex == nil && pathOnly?.manifestPath == "input/actions.vdf")
        let pathOnlyDecoded = try JSONDecoder().decode(SteamAppInfo.SteamInputMetadata.self, from: JSONEncoder().encode(pathOnly!))
        precondition(pathOnlyDecoded == pathOnly)
        for path in ["../escape", "/absolute", "C:/escape", "a//b", "a/./b", ""] {
            precondition(app(["steamcontrollertemplateindex": "13", "steaminputmanifestpath": path]).steamInputMetadata == nil)
            precondition(app(["steamcontrollertemplateindex": "4", "steaminputmanifestpath": path]).steamInputMetadata == nil)
        }
        // Well-formed metadata with neither hint is recorded, so "lists none"
        // differs from "never read". Index 13 needs a path to mean anything.
        let none = app([:]).steamInputMetadata
        precondition(none != nil && none?.templateIndex == nil && none?.manifestPath == nil)
        let bare13 = app(["steamcontrollertemplateindex": "13"]).steamInputMetadata
        precondition(bare13?.templateIndex == 13 && bare13?.manifestPath == nil)
        for config: [String: Any] in [["steamcontrollertemplateindex": "13x"],
                                      ["steamcontrollertemplateindex": "4294967296"],
                                      ["steamcontrollertemplateindex": ""]] {
            precondition(app(config).steamInputMetadata == nil)
        }
    let richInput = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
    "common" { "name" "Input" "type" "Game" }
    "config" { "steamcontrollertemplateindex" "1" "SteamControllerConfigDetails" {
        "99" { "controller_type" "controller_ps4" "enabled_branches" "default,beta" }
        "12" { "controller_type" "controller_ps5" "enabled_branches" "default" "use_action_block" "true" }
        "11" { "controller_type" "controller_ps5" "enabled_branches" "beta" }
        "10" { "controller_type" "controller_ps5" "enabled_branches" "beta" }
    } }
    """#))!.steamInputMetadata!
    require(richInput.workshopDetails?.map(\.id) == [99, 12, 11, 10], "recommendation KeyValues order survives parsing")
    require(richInput.workshopRecommendation(branch: "public") == 12, "exact controller outranks earlier compatible controller")
    require(richInput.workshopRecommendation(branch: "BETA") == 11, "first exact branch match, case insensitive")
    require(richInput.workshopRecommendation(branch: "other") == 12, "exact default branch fallback")
    var compatibleInput = richInput
    compatibleInput.workshopDetails!.removeAll { $0.id == 11 || $0.id == 10 }
    require(compatibleInput.workshopRecommendation(branch: "beta") == 99, "compatible branch match outranks exact default")
    let cachedRich = try JSONDecoder().decode(SteamAppInfo.SteamInputMetadata.self, from: JSONEncoder().encode(richInput))
    require(cachedRich == richInput && cachedRich.workshopRecommendation(branch: "beta") == 11, "ordered recommendations survive offline cache")
    let duplicateRich = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
    "common" { "name" "Input" }
    "config" { "SteamControllerConfigDetails" {
        "11" { "controller_type" "controller_ps5" "enabled_branches" "default" }
        "11" { "controller_type" "controller_ps4" "enabled_branches" "default" }
    } }
    """#))!
    require(duplicateRich.steamInputMetadata == nil, "duplicate recommendation IDs fail closed")
        print("PASS: PICS bundled metadata, legacy mode, cache encoding and unsafe/unresolved values")
    }
}
'''
# Compile the real text parser: dictionary-only fixtures cannot verify order.
fetcher_source = (root / 'app/Madeira/SwiftSteam/Library/SteamLibraryFetcher.swift').read_text()
parser_start = fetcher_source.index('    static func parseTextVDF')
parser_end = fetcher_source.index('    /// Extract app IDs', parser_start)
program = program.replace('enum VDFParser { static func parseTextVDF(from: Data, sectionOrder: (([String], [String]) -> Void)? = nil) -> [String: Any] { [:] } }',
    'enum VDFParser {\n' + fetcher_source[parser_start:parser_end] + '\n}\n' +
    'func appVDF(_ text: String) -> Data { Data(text.utf8) }\n' +
    'func require(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label) }')
service_test = r'''
import Foundation
enum VDFParser { static func parseTextVDF(from: Data, sectionOrder: (([String], [String]) -> Void)? = nil) -> [String: Any] { [:] } }
enum MadeiraConfig { static func get(_ key: String) -> String? { nil }; static func set(_ key: String, _ value: String?) {} }
enum SteamLog { static func event(_ text: String) {} }
struct DockGame { var id: Int; var library: String; var installDir: String; var installed: Bool }
enum ExternalDrives {
    static var root = URL(fileURLWithPath: "/")
    static func nativeURL(_ path: String) throws -> URL { root.appendingPathComponent(path) }
}
enum MadeiraDock { static var clientRoot = URL(fileURLWithPath: "/") }
enum SteamInstallFiles { static func betaKey(appID: Int, steamApps: URL) -> String? { nil } }
@MainActor enum DockSteamInputService {
    static var value: DockSteamInputContext?
    static func context(appID: UInt32) -> DockSteamInputContext? { value }
}
@MainActor final class SteamInputDefaultSources {
    enum Failure: Error { case incompatible }
    static let shared = SteamInputDefaultSources()
    var value: DockSteamInputDefault.Recommendation?
    var calls: [([UInt64], Bool)] = []
    static func metadata(appID: UInt32) async throws -> SteamAppInfo.SteamInputMetadata? { nil }
    func recommendation(appID: UInt32, ids: [UInt64], refresh: Bool, controllerMatched: Bool) async throws -> DockSteamInputDefault.Recommendation {
        calls.append((ids, controllerMatched))
        guard let value else { throw Failure.incompatible }
        return value
    }
}
struct Game { var id: Int; var steamInputMetadata: SteamAppInfo.SteamInputMetadata? }
@MainActor final class Fetcher {
    var calls = 0
    var value: SteamAppInfo?
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? { calls += 1; return value }
}
@MainActor final class Library {
    static var enabled = true
    var signedIn = true, inSession = false, writes = 0
    var owned = [Game(id: 480)]
    var fetcher = Fetcher()
    func game(_ id: Int) -> Game? { owned.first { $0.id == id } }
    func writeCache() { writes += 1 }
    func handleSessionError(_ error: Error, context: String, report: Bool) {}
__METADATA_METHOD__
__RESOLVER_METHOD__
}
@main struct Test {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        ExternalDrives.root = root
        MadeiraDock.clientRoot = root.appendingPathComponent("client")
        let folder = root.appendingPathComponent("steamapps/common/game/input")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = Data("\"Action Manifest\" { configurations { controller_ps5 { 0 { path pad.vdf } } } }".utf8)
        let layout = Data("controller_mappings { revision 1 }".utf8)
        try manifest.write(to: folder.appendingPathComponent("actions.vdf"))
        try layout.write(to: folder.appendingPathComponent("pad.vdf"))
        let library = Library()
        library.fetcher.value = SteamAppInfo.parse(appID: 480, from: ["common": ["name": "Fixture", "type": "game"],
            "config": ["steamcontrollertemplateindex": "13", "steaminputmanifestpath": "input/actions.vdf"]])
        let game = DockGame(id: 480, library: "steamapps", installDir: "game", installed: true)
        func recommended(_ r: DockSteamInputDefault.Resolution) -> DockSteamInputDefault.Recommendation? {
            if case .recommended(let value) = r { return value } else { return nil }
        }
        let first = await library.resolveSteamInputDefault(game: game)
        precondition(recommended(first)?.source == layout && recommended(first)?.origin == .actionManifest)
        precondition(library.fetcher.calls == 1 && library.writes == 1)
        // A running session cannot reach Steam: cached metadata is reused offline.
        library.inSession = true; library.fetcher.value = nil
        DockSteamInputService.value = .init(capabilities: 0, vendor: 0x054c, product: 0x0ce6, rawType: 45, manifestPath: nil)
        let cached = await library.resolveSteamInputDefault(game: game)
        precondition(recommended(cached)?.source == layout && library.fetcher.calls == 1)
        library.inSession = false
        DockSteamInputService.value = nil
        // KeyValues order, not numeric order, selects the entry.
        let alternate = Data("controller_mappings { revision 2 }".utf8)
        try alternate.write(to: folder.appendingPathComponent("alternate.vdf"))
        let unordered = Data("\"Action Manifest\" { configurations { controller_ps5 { 9 { path pad.vdf } 0 { path alternate.vdf } } } }".utf8)
        try unordered.write(to: folder.appendingPathComponent("actions.vdf"))
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == layout) }
        // The manifest outranks the template index (SteamUI tries it first).
        let templateFolder = MadeiraDock.clientRoot.appendingPathComponent("controller_base/templates")
        try FileManager.default.createDirectory(at: templateFolder, withIntermediateDirectories: true)
        let templateBytes = Data("controller_mappings { revision 4 }".utf8)
        try templateBytes.write(to: templateFolder.appendingPathComponent("controller_ps5_gamepad_joystick.vdf"))
        library.owned[0].steamInputMetadata = .init(templateIndex: 4, manifestPath: "input/actions.vdf")
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == layout) }
        library.owned[0].steamInputMetadata = .init(templateIndex: nil, manifestPath: "input/actions.vdf")
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == layout) }
        // A manifest with no usable entry falls through to the template.
        try Data("\"Action Manifest\" { configurations { } }".utf8).write(to: folder.appendingPathComponent("actions.vdf"))
        library.owned[0].steamInputMetadata = .init(templateIndex: 4, manifestPath: "input/actions.vdf")
        let fallthrough_ = recommended(await library.resolveSteamInputDefault(game: game))
        precondition(fallthrough_?.source == templateBytes && fallthrough_?.origin == .steamTemplate)
        library.owned[0].steamInputMetadata = .init(templateIndex: nil, manifestPath: "input/actions.vdf")
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .noHint) }
        // Device-specific matching is unsupported, a missing manifest unreadable:
        // neither may become a recommendation or "no recommendation".
        try Data("\"Action Manifest\" { configurations { controller_ps5 { 0 { path pad.vdf device_specific \"054c/0ce6,\" } } } }".utf8)
            .write(to: folder.appendingPathComponent("actions.vdf"))
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.manifestUnsupported)) }
        library.owned[0].steamInputMetadata = .init(templateIndex: 4, manifestPath: "input/missing.vdf")
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.manifestUnreadable)) }
        // Template-only metadata: the fixed DualSense indices are verified (5
        // becomes 4); the others are not guessed.
        library.owned[0].steamInputMetadata = .init(templateIndex: 4, manifestPath: nil)
        let template = recommended(await library.resolveSteamInputDefault(game: game))
        precondition(template?.source == templateBytes && template?.origin == .steamTemplate && template?.mouseOrKeyboard == false)
        library.owned[0].steamInputMetadata = .init(templateIndex: 5, manifestPath: nil)
        let platformer = recommended(await library.resolveSteamInputDefault(game: game))
        precondition(platformer?.source == templateBytes)
        // A fixed keyboard/mouse template is the game's default but says so.
        library.owned[0].steamInputMetadata = .init(templateIndex: 6, manifestPath: nil)
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.templateUnavailable)) }
        let wasdBytes = Data("controller_mappings { revision 6 }".utf8)
        try wasdBytes.write(to: templateFolder.appendingPathComponent("controller_ps5_wasd.vdf"))
        let wasd = await library.resolveSteamInputDefault(game: game)
        precondition(recommended(wasd)?.source == wasdBytes && recommended(wasd)?.mouseOrKeyboard == true)
        precondition(DockSteamInputDefault.explanation(wasd).contains("keyboard or mouse"))
        for index: UInt32 in [2, 3] {
            library.owned[0].steamInputMetadata = .init(templateIndex: index, manifestPath: nil)
            do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.templateControllerDependent)) }
        }
        // The live bridge's capability bits decide whether indices 2/3 stay
        // mixed-output templates or become the pure Gamepad template.
        let noMouse = DockSteamInputContext(capabilities: 0, vendor: 0x054c, product: 0x0ce6, rawType: 45, manifestPath: nil)
        DockSteamInputService.value = noMouse
        library.owned[0].steamInputMetadata = .init(templateIndex: 2, manifestPath: nil)
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == templateBytes) }
        let mouse = DockSteamInputContext(capabilities: 0x1800, vendor: 0x054c, product: 0x0ce6, rawType: 45, manifestPath: nil)
        DockSteamInputService.value = mouse
        try wasdBytes.write(to: templateFolder.appendingPathComponent("controller_ps5_gamepad_fps.vdf"))
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == wasdBytes && recommended(r)?.mouseOrKeyboard == true) }
        library.owned[0].steamInputMetadata = .init(templateIndex: 0, manifestPath: nil, controllerSupport: 2)
        DockSteamInputService.value = noMouse
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == templateBytes) }
        library.owned[0].steamInputMetadata = .init(templateIndex: nil, manifestPath: nil, controllerSupport: 0)
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .noRecommendation) }
        // The running game's manifest wins over both the cached path and index.
        try manifest.write(to: folder.appendingPathComponent("actions.vdf"))
        library.owned[0].steamInputMetadata = .init(templateIndex: 4, manifestPath: "missing.vdf")
        DockSteamInputService.value = .init(capabilities: 0, vendor: 0x054c, product: 0x0ce6, rawType: 45,
            manifestPath: "C:\\steamapps\\common\\game\\input\\actions.vdf")
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == layout) }
        library.owned[0].steamInputMetadata = nil
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == layout) }
        DockSteamInputService.value = .init(capabilities: 0, vendor: 0x054c, product: 0x0ce6, rawType: 45,
            manifestPath: "C:\\other-game\\actions.vdf")
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.manifestUnsupported)) }
        DockSteamInputService.value = nil
        for index: UInt32 in [7, 13, 14, 15, 99] {
            library.owned[0].steamInputMetadata = .init(templateIndex: index, manifestPath: nil)
            do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.templateUnsupported)) }
        }
        // Index 0 is the same as no index to SteamUI.
        library.owned[0].steamInputMetadata = .init(templateIndex: 0, manifestPath: nil)
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .noHint) }
        library.owned[0].steamInputMetadata = .init(templateIndex: 1, manifestPath: nil)
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.workshopSource)) }
        library.owned[0].steamInputMetadata = .init(templateIndex: nil, manifestPath: nil)
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .noHint) }
        try FileManager.default.removeItem(at: templateFolder.appendingPathComponent("controller_ps5_gamepad_joystick.vdf"))
        library.owned[0].steamInputMetadata = .init(templateIndex: 4, manifestPath: nil)
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.templateUnavailable)) }
        let uninstalled = DockGame(id: 480, library: "steamapps", installDir: "game", installed: false)
        library.owned[0].steamInputMetadata = .init(templateIndex: 4, manifestPath: "input/actions.vdf")
        do { let r = await library.resolveSteamInputDefault(game: uninstalled); precondition(r == .unresolved(.notInstalled)) }
        library.owned[0].steamInputMetadata = nil
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.dataUnavailable)) }
        let previousCalls = library.fetcher.calls
        library.signedIn = false
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .unresolved(.dataUnavailable) && library.fetcher.calls == previousCalls) }
        // No legacy item/compatible file uses the pinned template fallback.
        try templateBytes.write(to: templateFolder.appendingPathComponent("controller_ps5_gamepad_joystick.vdf"))
        library.inSession = false
        DockSteamInputService.value = noMouse
        library.owned[0].steamInputMetadata = .init(templateIndex: 1, manifestPath: nil, controllerSupport: 2, workshopIDs: [])
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == templateBytes) }
        library.owned[0].steamInputMetadata!.workshopDetails = []
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(r == .noRecommendation) }
        library.owned[0].steamInputMetadata!.workshopDetails = [.init(id: 22, controllerType: "controller_ps5", branches: ["default"], useActionBlock: true)]
        SteamInputDefaultSources.shared.value = .init(source: layout, origin: .workshop)
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == layout) }
        precondition(SteamInputDefaultSources.shared.calls.last!.0 == [22] && SteamInputDefaultSources.shared.calls.last!.1)
        SteamInputDefaultSources.shared.value = nil
        library.owned[0].steamInputMetadata = .init(templateIndex: 1, manifestPath: nil, controllerSupport: 2, workshopIDs: [22])
        do { let r = await library.resolveSteamInputDefault(game: game); precondition(recommended(r)?.source == templateBytes) }
        precondition(!SteamInputDefaultSources.shared.calls.last!.1)
        print("PASS: game-default resolution order, fail-closed classes, scoped cache and offline reuse")
    }
}
'''.replace('__METADATA_METHOD__', method('    func steamInputMetadata(appID:')) \
   .replace('__RESOLVER_METHOD__', method('    func resolveSteamInputDefault(game:'))
with tempfile.TemporaryDirectory(prefix='madeira-input-pics-') as temporary:
    tmp = Path(temporary)
    main = tmp / 'main.swift'
    main.write_text(program)
    compiler = shutil.which('swiftc')
    subprocess.run([compiler, '-parse-as-library', '-module-cache-path', str(tmp / 'modules'),
                    str(root / 'app/Madeira/SwiftSteam/Library/SteamAppInfo.swift'), str(main),
                    '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check')], check=True)
    source = root / 'madeira-dock/src/steam_input_service.c'
    header = root / 'madeira-dock/src/steam_input_service.h'
    subprocess.run([shutil.which('clang'), '-std=c11', '-I' + str(header.parent), '-c', str(source), '-o', str(tmp / 'service.o')], check=True)
    main.write_text(service_test)
    subprocess.run([compiler, '-parse-as-library', '-module-cache-path', str(tmp / 'modules'),
                    '-import-objc-header', str(header), str(root / 'app/Madeira/SwiftSteam/Library/SteamAppInfo.swift'),
                    str(root / 'app/Madeira/SteamInputTransactions.swift'), str(main), str(tmp / 'service.o'),
                    '-o', str(tmp / 'service-check')], check=True)
    subprocess.run([str(tmp / 'service-check'), str(tmp)], check=True)
