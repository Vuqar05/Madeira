#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Exercise recommendation downloads and offline recovery without contacting Steam."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
program = r'''
import Foundation
enum VDFParser { static func parseTextVDF(from: Data, sectionOrder: (([String], [String]) -> Void)? = nil) -> [String: Any] { [:] } }
enum MadeiraConfig { static func get(_ key: String) -> String? { nil }; static func set(_ key: String, _ value: String?) {} }
enum SteamLog { static func event(_ text: String) {} }
struct SteamWorkshopItem {
    var id: UInt64; var appID: UInt32 = 241100; var result: UInt32 = 1
    var title = "Fixture layout"; var banned = false; var fileType: UInt32 = 12
    var fileSize: UInt64; var fileURL: String; var timeUpdated: UInt32 = 1
}
enum SteamWorkshopRequests {
    static func details(appID: UInt32, ids: [UInt64]) -> Data { Data() }
    static func page(_ bytes: Data, itemsField: UInt32, totalField: UInt32?) throws -> Page { fatalError() }
    struct Page { let items: [SteamWorkshopItem] }
}
@MainActor final class SteamSession {
    enum Method { case workshopGetDetails }
    init(anonymous: Bool) { precondition(anonymous) }
    func ensureConnected() async throws { fatalError("network not injected") }
    func callServiceMethodWithResult(method: Method, body: Data, timeout: TimeInterval) async throws -> (eresult: Int32, body: Data) { fatalError() }
}
@MainActor final class SteamLibraryFetcher {
    init(session: SteamSession) {}
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? { fatalError() }
}
func require(_ body: @autoclosure () throws -> Bool) { precondition(try! body()) }
@main struct Check {
    @MainActor static func main() async throws {
        typealias Sources = SteamInputDefaultSources
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let xbox = Data("controller_mappings { controller_type controller_xboxone revision 1 }".utf8)
        let layout = Data("controller_mappings { controller_type controller_ps4 revision 2 group { future yes } group { future retained } }".utf8)
        let updated = Data("controller_mappings { controller_type controller_ps5 revision 3 group { future changed } }".utf8)
        var downloads = 0, calls = 0
        var failing = false, invalidFirst = false, update = false
        let sources = Sources(root: root, details: { ids in
            calls += 1
            return ids.map { id in
                SteamWorkshopItem(id: id, fileSize: UInt64(id == 11 ? xbox.count : (update ? updated.count : layout.count)),
                    fileURL: "https://ugc.steamusercontent.com/" + String(id))
            }
        }, download: { url in
            downloads += 1
            if failing { throw Sources.Failure.unavailable }
            if invalidFirst { return Data("invalid".utf8) }
            return url.lastPathComponent == "11" ? xbox : (update ? updated : layout)
        })
        let first = try await sources.recommendation(appID: 480, ids: [11, 12])
        require(first.source == layout && first.origin == .workshop && downloads == 2 && calls == 1)
        require(first.attribution?.contains("12") == true)
        let record = root.appendingPathComponent("480/default.json")
        let before = try Data(contentsOf: record)
        let offline = Sources(root: root, details: { _ in throw Sources.Failure.unavailable },
                              download: { _ in fatalError("offline cache attempted a download") })
        let cached = try await offline.recommendation(appID: 480, ids: [11, 12])
        require(cached == first && downloads == 2 && calls == 1)
        failing = true
        do { _ = try await sources.recommendation(appID: 480, ids: [11, 12], refresh: true); fatalError("failed refresh accepted") }
        catch Sources.Failure.unavailable {}
        require(try Data(contentsOf: record) == before)
        let preserved = try await awaitCached(offline, appID: 480, ids: [11, 12], expected: layout)
        require(preserved)
        failing = false; invalidFirst = true
        let attempts = downloads
        do { _ = try await sources.recommendation(appID: 480, ids: [11, 12], refresh: true); fatalError("invalid earlier recommendation skipped") }
        catch Sources.Failure.invalid {}
        require(downloads == attempts + 1)
        require(try Data(contentsOf: record) == before)
        invalidFirst = false; update = true
        let newest = try await sources.recommendation(appID: 480, ids: [11, 12], refresh: true)
        require(newest.source == updated && newest.contentHash != first.contentHash)
        require(try Data(contentsOf: root.appendingPathComponent("480/" + first.contentHash + ".vdf")) == layout)
        for (appID, ids) in [(UInt32(481), [UInt64(11), 12]), (480, [12, 11])] {
            do { _ = try await offline.recommendation(appID: appID, ids: ids); fatalError("cache reused for another game/list order") }
            catch Sources.Failure.unavailable {}
        }
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("480/" + newest.contentHash + ".vdf"))
        do { _ = try await offline.recommendation(appID: 480, ids: [11, 12]); fatalError("corrupt cache accepted") }
        catch Sources.Failure.invalid {}
        let rich = try await sources.recommendation(appID: 482, ids: [11], controllerMatched: true)
        require(rich.source == xbox)
        let richOffline = try await offline.recommendation(appID: 482, ids: [11], controllerMatched: true)
        require(richOffline == rich)
        do { _ = try await offline.recommendation(appID: 482, ids: [11]); fatalError("rich selection proof reused for legacy compatibility") }
        catch Sources.Failure.unavailable {}
        // Older original bindings omit controller_type. Rich PICS entries
        // supply the selection type; missing type cannot prove compatibility
        // in the legacy ID-only path.
        let legacy = Data("controller_mappings { version 2 group { future retained } }".utf8)
        let legacySources = Sources(root: root, details: { ids in
            ids.map { SteamWorkshopItem(id: $0, fileSize: UInt64(legacy.count), fileURL: "https://ugc.steamusercontent.com/legacy") }
        }, download: { _ in legacy })
        let old = try await legacySources.recommendation(appID: 483, ids: [13], controllerMatched: true)
        require(old.source == legacy)
        let oldOffline = try await offline.recommendation(appID: 483, ids: [13], controllerMatched: true)
        require(oldOffline == old)
        do { _ = try await legacySources.recommendation(appID: 484, ids: [13]); fatalError("unspecified controller accepted as compatible") }
        catch Sources.Failure.incompatible {}
        require(Sources.downloadURL("http://ugc.steamusercontent.com/a")?.scheme == "https")
        require(Sources.downloadURL("http://steamusercontent.com.evil.test/a") == nil)
        for value in ["http://ugc.steamusercontent.com/a", "https://steamusercontent.com.evil.test/a",
                      "https://user:password@ugc.steamusercontent.com/a", "https://127.0.0.1/a",
                      "https://ugc.steamusercontent.com:8080/a"] {
            require(!Sources.allowed(URL(string: value)!))
        }
        require(Sources.allowed(URL(string: "https://ugc.steamusercontent.com/a")!))
        require(Sources.controllerType(Data("controller_mappings { controller_type controller_ps5 Controller_Type controller_ps4 }".utf8)) == nil)
        print("PASS: ordered compatible recommendations, raw VDF preservation, attribution, offline cache, failed update, scope/order isolation, corruption and HTTPS policy")
    }
    @MainActor static func awaitCached(_ sources: SteamInputDefaultSources, appID: UInt32, ids: [UInt64], expected: Data) async throws -> Bool {
        try await sources.recommendation(appID: appID, ids: ids).source == expected
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-input-defaults-') as temporary:
    tmp = Path(temporary)
    (tmp / 'main.swift').write_text(program)
    header = root / 'madeira-dock/src/steam_input_service.h'
    subprocess.run([shutil.which('clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-c',
                    str(header.with_suffix('.c')), '-o', str(tmp / 'service.o')], check=True)
    subprocess.run([shutil.which('swiftc'), '-parse-as-library', '-module-cache-path', str(tmp / 'modules'),
                    '-import-objc-header', str(header), str(root / 'app/Madeira/SwiftSteam/Library/SteamAppInfo.swift'),
                    str(root / 'app/Madeira/SteamInputTransactions.swift'), str(root / 'app/Madeira/SteamInputDefaults.swift'),
                    str(tmp / 'main.swift'), str(tmp / 'service.o'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(tmp / 'cache')], check=True)
