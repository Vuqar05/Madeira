#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Community public query contract, immutable revisions and offline/failure cases."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
program = r'''
import Foundation
enum VDFParser { static func parseTextVDF(from: Data, sectionOrder: (([String], [String]) -> Void)? = nil) -> [String: Any] { [:] } }
enum MadeiraConfig { static func get(_ key: String) -> String? { nil }; static func set(_ key: String, _ value: String?) {} }
enum SteamLog { static func event(_ text: String) {}; static func trace(_ text: @autoclosure () -> String) {} }
@MainActor final class SteamSession {
    enum Method { case workshopGetDetails, workshopQueryFiles }
    init(anonymous: Bool) { precondition(anonymous) }
    func ensureConnected() async throws { fatalError("network not injected") }
    func callServiceMethodWithResult(method: Method, body: Data, timeout: TimeInterval) async throws -> (eresult: Int32, body: Data) { fatalError() }
}
@MainActor final class SteamLibraryFetcher {
    init(session: SteamSession) {}
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? { fatalError() }
}
func require(_ body: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) { precondition(try! body(), file: file, line: line) }
@main struct Check {
 @MainActor static func main() async throws {
    typealias Sources = SteamInputCommunitySources
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let bytes = Data(#"controller_mappings { version 3 revision 7 controller_type controller_ps5 unknown { future retained } group { id 1 mode four_buttons inputs { button_a { activators { Full_Press { bindings { binding "key_press SPACE" binding "xinput_button A" } } } } } } preset { id 0 group_source_bindings { 1 "button_diamond active" } } }"#.utf8)
    let updated = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "revision 7", with: "revision 8").utf8)
    func item(_ id: UInt64 = 123, app: UInt32 = 480, source: Data = bytes) -> SteamWorkshopItem {
        var value = SteamWorkshopItem(id: id, appID: 241100, result: 1)
        value.title = "Mixed output fixture"; value.fileURL = "https://ugc.steamusercontent.com/fixture"
        value.fileSize = UInt64(source.count); value.timeUpdated = 1; value.fileType = 12
        value.tags = ["controller_ps5", "controller_native", "feature_keyboard", "feature_gamepad"]
        value.kvTags = [.init(key: "app", value: String(app)), .init(key: "visibility", value: "public"), .init(key: "deleted", value: "0")]
        return value
    }
    var current = item(), fail = false, race = false, cancel = false
    var calls = 0, downloads = 0, queries = 0
    let sources = Sources(root: root, query: { app, order, text, page in
        queries += 1
        require(app == 480 && order == .played && text == "" && page == 1)
        return SteamWorkshopPage(total: 31, items: [item(), item(124, app: 481)])
    }, details: { ids in
        calls += 1
        if fail { throw Sources.Failure.unavailable }
        if race && calls % 2 == 0 { var next = current; next.timeUpdated += 1; return [next] }
        return [current]
    }, download: { _ in
        downloads += 1
        if cancel { throw CancellationError() }
        return current.timeUpdated == 1 ? bytes : updated
    })
    let page = try await sources.page(appID: 480, order: .played, text: "", number: 1)
    require(page.items.map(\.id) == [123] && page.total == 31)
    let offline = Sources(root: root, query: { _,_,_,_ in fatalError("offline query") },
                          details: { _ in fatalError("offline details") }, download: { _ in fatalError("offline download") })
    require(try awaitPage(offline) == page)
    let first = try await sources.download(appID: 480, item: current)
    require(first.bytes == bytes && first.compatibility.canApply && calls == 2 && downloads == 1)
    require(first.revision.item.id == 123 && first.revision.appID == 480)
    require(first.revision.matches(current))
    // Update availability uses the same full content signature as transfer
    // validation, even when Steam's timestamp and content handle are unchanged.
    var relocated = current; relocated.fileURL += "-new"
    var resized = current; resized.fileSize += 1
    var retagged = current; retagged.tags?.append("feature_gyro")
    require(!first.revision.matches(relocated) && !first.revision.matches(resized) && !first.revision.matches(retagged))
    let cached = try await offline.download(appID: 480, item: current)
    require(cached.bytes == bytes && cached.revision.hash == first.revision.hash)
    let selected = try await offline.selectedWorkshop(appID: 480, itemID: current.id)
    require(selected == bytes)
    let copy = try SteamInputPersonalCopy.create(first, title: "My personal copy", accountID: 7, root: root)
    let copyFile = SteamInputPersonalCopy.folder(root: root, accountID: 7, appID: 480).appendingPathComponent(copy.id.uuidString + "/source.vdf")
    require(try Data(contentsOf: copyFile) == bytes && copy.origin == first.revision)
    require(try copy.source(root: root) == copyFile)
    require(try SteamInputPersonalCopy.list(root: root, accountID: 7, appID: 480).map(\.id) == [copy.id])
    require(try SteamInputPersonalCopy.list(root: root, accountID: 8, appID: 480).isEmpty)
    require(try SteamInputPersonalCopy.list(root: root, accountID: 7, appID: 481).isEmpty)
    require(try sources.downloaded(appID: 480).map(\.item.id) == [123])
    try Data("edited personal revision".utf8).write(to: copyFile)
    require(try sources.load(first.revision).bytes == bytes)
    // Neither a failed refresh nor a mid-transfer revision race replaces cache.
    current = item(source: updated); current.timeUpdated = 2
    fail = true
    do { _ = try await sources.download(appID: 480, item: current); fatalError("failed update accepted") } catch Sources.Failure.unavailable {}
    require(try sources.cached(appID: 480, id: 123) == [first.revision])
    fail = false; race = true; calls = 0
    do { _ = try await sources.download(appID: 480, item: current); fatalError("race accepted") } catch Sources.Failure.changed {}
    require(try sources.cached(appID: 480, id: 123) == [first.revision])
    race = false; cancel = true
    do { _ = try await sources.download(appID: 480, item: current); fatalError("cancel accepted") } catch is CancellationError {}
    require(try sources.cached(appID: 480, id: 123) == [first.revision])
    cancel = false
    let next = try await sources.download(appID: 480, item: current)
    require(next.bytes == updated && next.revision.hash != first.revision.hash)
    require(try sources.cached(appID: 480, id: 123).count == 2)
    require(try sources.load(first.revision).bytes == bytes)
    // The response, not just the query's app filter, must prove association.
    var privateItem = item(); privateItem.visibility = 2
    var deleted = item(); deleted.kvTags?.append(.init(key: "deleted", value: "1"))
    var conflicting = item(); conflicting.kvTags?.append(.init(key: "app", value: "481"))
    var wrongType = item(); wrongType.fileType = 15
    var url = item(); url.fileURL = "https://evil.test/layout"
    var unavailable = item(); unavailable.result = 9
    for bad in [item(app: 481), privateItem, deleted, conflicting, wrongType, url, unavailable] {
        do { _ = try await sources.download(appID: 480, item: bad); fatalError("invalid item accepted") } catch Sources.Failure.invalid {}
    }
    let object = root.appendingPathComponent("480/items/123/\(first.revision.hash).vdf")
    try Data("corrupt".utf8).write(to: object)
    do { _ = try sources.load(first.revision); fatalError("corrupt object accepted") } catch Sources.Failure.invalid {}
    let gyro = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "button_diamond active", with: "gyro active").utf8)
    require(try !SteamInputCompatibility(gyro).canApply)
    let inactiveGyro = Data(String(decoding: gyro, as: UTF8.self).replacingOccurrences(of: "gyro active", with: "gyro inactive").utf8)
    require(try SteamInputCompatibility(inactiveGyro).canApply)
    let unusedMenu = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "preset {", with: "group { id 2 mode radial_menu inputs { rear_button {} } } preset {").utf8)
    require(try SteamInputCompatibility(unusedMenu).canApply)
    require(try SteamInputCompatibility(bytes, tags: ["controller_ps5", "feature_radialmenu"]).canApply)
    let activeMenu = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "mode four_buttons", with: "mode radial_menu").utf8)
    require(try !SteamInputCompatibility(activeMenu).canApply)
    require(try !SteamInputCompatibility(Data("controller_mappings { controller_type controller_neptune }".utf8)).canApply)
    do { _ = try SteamInputCompatibility(bytes, tags: ["controller_ps4"]); fatalError("controller mismatch accepted") } catch Sources.Failure.invalid {}
    for invalid in ["controller_mappings { revision 1 } trailing", "controller_mappings { #base secret }", "controller_mappings { revision 1 } [$WIN32]"] {
        do { _ = try SteamInputKV.parse(Data(invalid.utf8)); fatalError("invalid document accepted") } catch {}
    }
    // Actual protobuf request/response, including repeated app tags and public-only filtering.
    let query = SteamWorkshopRequests.controllerQuery(appID: 480, order: 14, text: "layout", page: 2)
    var decoder = ProtobufDecoder(query), numbers: [UInt32: UInt64] = [:], kv: [String: String] = [:]
    while let field = try decoder.readTag() {
        if field.wireType == .varint { numbers[field.fieldNumber] = try decoder.readVarint() }
        else if field.fieldNumber == 34 {
            var nested = ProtobufDecoder(try decoder.readBytes()); var key = "", value = ""
            while let part = try nested.readTag() {
                let text = String(decoding: try nested.readBytes(), as: UTF8.self)
                if part.fieldNumber == 1 { key = text } else { value = text }
            }
            kv[key] = value
        } else { try decoder.skip(wireType: field.wireType) }
    }
    require(numbers[1] == 12 && numbers[2] == 2 && numbers[3] == 30 && numbers[5] == 241100 && numbers[12] == 15)
    require(kv == ["app":"480", "visibility":"public", "deleted":"0"])
    var response = ProtobufEncoder(); response.writeUInt32(fieldNumber: 1, value: 1); response.writeUInt64(fieldNumber: 2, value: 123)
    for (key, value) in [("app","480"), ("app","481"), ("owner","do-not-retain"), ("serial","do-not-retain")] {
        var tag = ProtobufEncoder(); tag.writeString(fieldNumber: 1, value: key); tag.writeString(fieldNumber: 2, value: value)
        response.writeSubmessage(fieldNumber: 54, value: tag.data)
    }
    let parsed = try SteamWorkshopItem.parse(response.data)
    require(parsed.kvTags?.map(\.value) == ["480", "481"])
    // A refresh must not combine a fresh first page with an older second page.
    var generation: UInt64 = 0, listingCalls = 0
    let listings = Sources(root: root.appendingPathComponent("listings"), query: { _, _, _, number in
        listingCalls += 1
        return SteamWorkshopPage(total: 60, items: [item(generation + UInt64(number))])
    })
    _ = try await listings.page(appID: 480, order: .played, text: "", number: 1)
    _ = try await listings.page(appID: 480, order: .played, text: "", number: 2)
    generation = 100
    _ = try await listings.page(appID: 480, order: .played, text: "", number: 1, refresh: true)
    let nextPage = try await listings.page(appID: 480, order: .played, text: "", number: 2)
    require(nextPage.items.map(\.id) == [102] && listingCalls == 4)
    print("PASS: community protobuf filters, anonymous source scope, exact VDF/cache, offline reuse, failed/racing/cancelled updates, compatibility and isolated personal copy")
 }
 @MainActor static func awaitPage(_ sources: SteamInputCommunitySources) async throws -> SteamInputCommunitySources.Page {
    try await sources.page(appID: 480, order: .played, text: "", number: 1)
 }
}
'''
# Async expressions cannot be evaluated in require's synchronous autoclosure.
program = program.replace('    require(try awaitPage(offline) == page)', '    let cachedPage = try await awaitPage(offline)\n    require(cachedPage == page)')
with tempfile.TemporaryDirectory(prefix='madeira-input-community-') as temporary:
    tmp = Path(temporary)
    (tmp / 'main.swift').write_text(program)
    workshop = (app / 'SteamWorkshopFiles.swift').read_text()
    (tmp / 'workshop.swift').write_text(workshop[:workshop.index('/// Valve\'s record of an app\'s installed Workshop items:')])
    header = root / 'madeira-dock/src/steam_input_service.h'
    subprocess.run([shutil.which('clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address', '-c', str(header.with_suffix('.c')), '-o', str(tmp / 'service.o')], check=True)
    subprocess.run([shutil.which('swiftc'), '-parse-as-library', '-sanitize=address', '-module-cache-path', str(tmp / 'modules'), '-import-objc-header', str(header),
                    str(app/'SwiftSteam/Library/SteamAppInfo.swift'), str(app/'SwiftSteam/Proto/SteamProtoMessages.swift'), str(app/'SwiftSteam/Core/SteamError.swift'),
                    str(app/'SteamKeyValues.swift'), str(app/'SteamInputVDF.swift'), str(app/'SteamInputModel.swift'), str(app/'SteamInputReferences.swift'), str(app/'SteamInputActions.swift'),
                    str(app/'SteamInputPreview.swift'),
                    str(app/'SteamInputTransactions.swift'), str(app/'SteamInputDefaults.swift'),
                    str(app/'SteamInputCommunity.swift'), str(tmp/'workshop.swift'), str(tmp/'main.swift'), str(tmp/'service.o'), '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp/'cache')], check=True)
