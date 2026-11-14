#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Milestone 4 personal layouts: what is checked before one is applied, and
that the community original it was copied from is never touched."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'

program = r'''
import Foundation
import CryptoKit

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

func require(_ body: @autoclosure () throws -> Bool, _ message: String = "precondition failed", file: StaticString = #file, line: UInt = #line) {
    do {
        let result = try body()
        precondition(result, message, file: file, line: line)
    } catch {
        preconditionFailure("\(message): \(error)", file: file, line: line)
    }
}

/// Every file beneath `url` with a digest of its bytes, plus every directory
/// and link, so a write of any kind changes the snapshot.
func snapshot(_ url: URL) throws -> [String: String] {
    var out: [String: String] = [:]
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return out }
    for case let entry as URL in walker {
        let path = String(entry.path.dropFirst(url.path.count))
        let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { out[path] = "link" }
        else if values.isRegularFile == true { out[path] = SHA256.hash(data: try Data(contentsOf: entry)).map { String(format: "%02x", $0) }.joined() }
        else { out[path] = "-" }
    }
    return out
}

@main struct CheckPersonal {
    @MainActor static func main() async throws {
        typealias Sources = SteamInputCommunitySources
        typealias Personal = SteamInputPersonalCopy
        let temp = URL(fileURLWithPath: CommandLine.arguments[1])
        let communityRoot = temp.appendingPathComponent("SteamInputCommunity", isDirectory: true)
        let support = temp.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        func layoutText(binding: String = "key_press SPACE, Jump, ", source: String = "button_diamond", mode: String = "four_buttons") -> String {
            """
            "controller_mappings"
            {
                "version" "3"
                "revision" "7"
                "title" "Personal fixture"
                "controller_type" "controller_ps5"
                "future_block" { "kept" "exactly" }
                "group"
                {
                    "id" "0"
                    "mode" "\(mode)"
                    "inputs" { "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "\(binding)" } } } } }
                }
                "preset" { "id" "0" "name" "Default" "group_source_bindings" { "0" "\(source) active" } }
            }
            """
        }
        let original = Data(layoutText().utf8)
        func item(_ id: UInt64, _ source: Data, title: String = "Community fixture") -> SteamWorkshopItem {
            var value = SteamWorkshopItem(id: id, appID: 241100, result: 1)
            value.title = title; value.fileURL = "https://ugc.steamusercontent.com/fixture"
            value.fileSize = UInt64(source.count); value.timeUpdated = 1; value.fileType = 12
            value.tags = ["controller_ps5"]
            value.kvTags = [.init(key: "app", value: "480"), .init(key: "visibility", value: "public"), .init(key: "deleted", value: "0")]
            return value
        }
        var payload = original
        var current = item(123, original)
        let sources = Sources(root: communityRoot, query: { _, _, _, _ in fatalError("no listing") },
                              details: { _ in [current] }, download: { _ in payload })
        let downloaded = try await sources.download(appID: 480, item: current)
        let communityBefore = try snapshot(communityRoot)
        require(!communityBefore.isEmpty)

        // =============================================================
        // 1. A personal copy can be applied: exact bytes, own identity, attribution
        // =============================================================
        let copy = try Personal.create(downloaded, title: "My jump layout", accountID: 24, root: support)
        let stored = try snapshot(support)
        let request = try copy.applyRequest(root: support)
        require(request.source == original, "the bytes handed to the layout service are the stored copy, byte for byte")
        require(request.appID == 480 && request.accountID == 24 && request.id == copy.id, "the request is scoped to the copy's game, account and UUID")
        require(request.id.uuidString != "\(current.id)", "a personal layout is named by its own UUID, not the Workshop item")
        require(request.detail == "My jump layout · personal copy of Community fixture · Workshop 123", "\(request.detail)")
        require(request.compatibility.canApply)
        require(DockSteamInputNative.contentHash(request.source) == copy.hash && copy.hash == downloaded.revision.hash)
        require(try snapshot(support) == stored, "preparing an apply writes nothing to the personal store")
        require(try snapshot(communityRoot) == communityBefore, "copying and applying a personal layout leaves the community original untouched")
        require(try sources.load(downloaded.revision).bytes == original, "the downloaded original still loads and verifies")
        let listed = try Personal.list(root: support, accountID: 24, appID: 480)
        require(listed.map(\.id) == [copy.id])
        require(try listed[0].applyRequest(root: support) == request, "a listed copy applies the same way")

        // The detail is what the selection store accepts: bounded, no control characters.
        let longTitle = String(repeating: "é", count: 160)
        current = item(124, original, title: String(repeating: "界", count: 100))
        let longLayout = try await sources.download(appID: 480, item: current)
        let longCopy = try Personal.create(longLayout, title: longTitle, accountID: 24, root: support)
        let longDetail = try longCopy.applyRequest(root: support).detail
        require(longDetail.utf8.count <= 512 && longDetail.hasPrefix(longTitle) && !longDetail.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
                "a long title and attribution still fit the selection store: \(longDetail.utf8.count) bytes")

        let communityAfterDownloads = try snapshot(communityRoot)

        // =============================================================
        // 2. Refused before the layout service is asked, with a readable reason
        // =============================================================
        /// Stores `bytes` as a personal layout whose record matches them, as an
        /// older build or a restored backup could have left on disk.
        func storedCopy(_ bytes: Data, id: UInt64) throws -> Personal {
            let revision = Sources.Revision(appID: 480, item: item(id, bytes), hash: DockSteamInputNative.contentHash(bytes), downloaded: Date(timeIntervalSince1970: 1))
            return try Personal.create(Sources.Layout(revision: revision, bytes: bytes, compatibility: downloaded.compatibility), title: "Stored \(id)", accountID: 24, root: support)
        }
        func refusal(_ copy: Personal) -> String {
            do { _ = try copy.applyRequest(root: support); fatalError("\(copy.title): accepted for apply") }
            catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
        let broken = try storedCopy(Data(layoutText(binding: "mode_shift right_joystick 99, , ").utf8), id: 201)
        require(refusal(broken) == "This layout cannot be applied. A mode shift on Cross (A) in group 0 switches right stick to group 99, which the layout does not define.",
                "a broken reference is refused with its reason: \(refusal(broken))")
        let conditional = try storedCopy(Data(layoutText().replacingOccurrences(of: #""mode" "four_buttons""#, with: #""mode" "four_buttons" [$WIN32]"#).utf8), id: 202)
        require(refusal(conditional).contains("Conditional layouts are not supported yet."), "a conditional layout is still refused: \(refusal(conditional))")
        let gyro = try storedCopy(Data(layoutText(source: "gyro").utf8), id: 203)
        require(refusal(gyro) == "This layout cannot be applied. Unavailable inputs or features: gyro.", "an unforwarded input is refused with its name: \(refusal(gyro))")
        let menu = try storedCopy(Data(layoutText(mode: "radial_menu").utf8), id: 204)
        require(refusal(menu).contains("overlay menus"), "\(refusal(menu))")
        // Stored bytes that no longer match the record are never applied.
        let tampered = try storedCopy(original, id: 205)
        let tamperedURL = Personal.folder(root: support, accountID: 24, appID: 480).appendingPathComponent(tampered.id.uuidString + "/source.vdf")
        try Data(layoutText(binding: "key_press ESCAPE, Quit, ").utf8).write(to: tamperedURL)
        require(refusal(tampered) == Personal.ApplyFailure.damaged.errorDescription, "changed bytes are refused: \(refusal(tampered))")
        let linked = try storedCopy(original, id: 206)
        let linkedURL = Personal.folder(root: support, accountID: 24, appID: 480).appendingPathComponent(linked.id.uuidString + "/source.vdf")
        try FileManager.default.removeItem(at: linkedURL)
        // The link's target holds exactly the recorded bytes, so only the link itself can be what is refused.
        let outside = temp.appendingPathComponent("outside.vdf")
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: outside)
        require(try Data(contentsOf: linkedURL) == original && DockSteamInputNative.contentHash(original) == linked.hash)
        require(refusal(linked) == Personal.ApplyFailure.damaged.errorDescription, "a linked file is not followed")
        let missing = try storedCopy(original, id: 207)
        try FileManager.default.removeItem(at: Personal.folder(root: support, accountID: 24, appID: 480).appendingPathComponent(missing.id.uuidString + "/source.vdf"))
        require(refusal(missing) == Personal.ApplyFailure.damaged.errorDescription)
        let notLayout = try storedCopy(Data(#""controller_mappings" { "version" "3" "controller_type" "controller_ps5" } "controller_mappings" { }"#.utf8), id: 208)
        require(refusal(notLayout) == Personal.ApplyFailure.notALayout.errorDescription, "\(refusal(notLayout))")
        let noRevision = try storedCopy(Data(layoutText().replacingOccurrences(of: #""revision" "7""#, with: #""revision" "x""#).utf8), id: 209)
        require(refusal(noRevision) == Personal.ApplyFailure.notALayout.errorDescription, "a layout the native revision reader rejects: \(refusal(noRevision))")
        for message in [Personal.ApplyFailure.damaged, .notALayout, .incompatible("Unavailable inputs or features: gyro.")].map({ $0.errorDescription ?? "" }) {
            require(message.hasPrefix("This layout cannot be applied. ") && message.count > 40, "every refusal reads as a sentence: \(message)")
        }
        require(try snapshot(communityRoot) == communityAfterDownloads, "refused applies leave the community cache untouched")
        require(try sources.load(downloaded.revision).bytes == original)

        // =============================================================
        // 3. Local only: explicit VDF import and export, no cloud claim
        // =============================================================
        require(Personal.storageNote.contains("Stored on this device only") && Personal.storageNote.contains("not synced or backed up to Steam Cloud")
                && Personal.storageNote.contains("export the VDF"), "personal layouts are described as local, with export as the way to keep one")
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let beforeImport = try snapshot(support)
        let imported = try Personal.importVDF(original, fileName: "My pad.vdf", accountID: 24, appID: 480, root: support, now: importedAt)
        require(imported.title == "My pad" && imported.origin == nil && imported.sourceName == "My pad.vdf" && imported.imported == importedAt)
        require(imported.hash == DockSteamInputNative.contentHash(original) && imported.accountID == 24 && imported.appID == 480)
        require(imported.provenance == "Imported from My pad.vdf" && imported.detail == "My pad · imported VDF file")
        require(copy.provenance == "Copied from Community fixture · Workshop 123")
        require(try imported.bytes(root: support) == original, "an imported layout keeps the file's exact bytes, unknown fields included")
        require(String(decoding: try imported.bytes(root: support), as: UTF8.self).contains(#""future_block" { "kept" "exactly" }"#))
        let importedRequest = try imported.applyRequest(root: support)
        require(importedRequest.source == original && importedRequest.id == imported.id && importedRequest.id != copy.id && importedRequest.compatibility.canApply,
                "an imported layout can be applied under its own identity")
        let afterImport = try snapshot(support)
        require(Set(afterImport.keys).subtracting(beforeImport.keys).count == 3 && beforeImport.allSatisfy { afterImport[$0.key] == $0.value },
                "an import adds its own folder and two files and changes nothing else")
        require(try snapshot(communityRoot) == communityAfterDownloads, "importing touches no community download")
        let relisted = try Personal.list(root: support, accountID: 24, appID: 480)
        require(relisted.contains { $0.id == imported.id && $0.origin == nil && $0.imported == importedAt } && relisted.contains { $0.id == copy.id && $0.origin != nil },
                "copies and imports are listed together; records written before imports existed still load")

        // A refused file leaves nothing behind and says why in plain words.
        func importRefusal(_ bytes: Data, account: UInt32 = 24, name: String = "bad.vdf") throws -> String {
            let before = try snapshot(support)
            do { _ = try Personal.importVDF(bytes, fileName: name, accountID: account, appID: 480, root: support); fatalError("\(name): imported") }
            catch {
                require(try snapshot(support) == before, "\(name): a refused import leaves nothing behind")
                guard let reason = (error as? LocalizedError)?.errorDescription, !reason.isEmpty else { fatalError("\(name): unreadable refusal \(error)") }
                require(reason != Sources.Failure.invalid.errorDescription, "\(name): not the community download wording")
                return reason
            }
        }
        require(try importRefusal(Data()) == Personal.ImportFailure.notALayout.errorDescription)
        require(try importRefusal(Data("hello".utf8)) == "The file was not imported. The layout ends after a name.",
                "a malformed file explains the import refusal rather than exposing a generic error")
        require(try importRefusal(Data([0xff])) == "The file was not imported. The layout is not UTF-8 text.")
        require(try importRefusal(Data(#""controller_mappings" { "version" "3" } "controller_mappings" { }"#.utf8)) == Personal.ImportFailure.notALayout.errorDescription)
        require(try importRefusal(Data([0xef, 0xbb, 0xbf]) + original) == Personal.ImportFailure.notALayout.errorDescription, "the native reader's refusal of a byte-order mark is kept")
        require(try importRefusal(original + Data(repeating: 0x20, count: Sources.limit + 1 - original.count)) == "The file is too large to be a Steam Input layout.")
        require(try importRefusal(original, account: 0) == Personal.ImportFailure.noAccount.errorDescription)
        require(try importRefusal(Data(layoutText().replacingOccurrences(of: #""mode" "four_buttons""#, with: #""mode" "four_buttons" [$WIN32]"#).utf8)).contains("Conditional layouts are not supported yet."))
        require(try importRefusal(Data(layoutText(binding: "mode_shift right_joystick 99, , ").utf8))
                == "This layout cannot be applied. A mode shift on Cross (A) in group 0 switches right stick to group 99, which the layout does not define.",
                "a file with a broken reference is refused at import, with the reference named")
        // A layout that only needs an input Madeira cannot forward is kept, like a download, and cannot be applied.
        let importedGyro = try Personal.importVDF(Data(layoutText(source: "gyro").utf8), fileName: "gyro.vdf", accountID: 24, appID: 480, root: support)
        require(refusal(importedGyro) == "This layout cannot be applied. Unavailable inputs or features: gyro.")

        // Names taken from files.
        require(Personal.importTitle(fileName: "pad.VDF") == "pad" && Personal.importTitle(fileName: ".vdf") == "Imported layout" && Personal.importTitle(fileName: "") == "Imported layout")
        require(Personal.importTitle(fileName: "../../etc/Layout one.vdf") == "Layout one" && Personal.importTitle(fileName: "a\u{7}b\n.vdf") == "ab")
        require(Personal.importTitle(fileName: String(repeating: "x", count: 400) + ".vdf").count == 160)

        // Export, then import: the same bytes come back under a new identity.
        let scratch = temp.appendingPathComponent("export", isDirectory: true)
        let storeBeforeExport = try snapshot(support)
        let exported = try copy.exportFile(root: support, directory: scratch)
        require(exported.lastPathComponent == "My jump layout.vdf" && exported.path.hasPrefix(scratch.path), "the exported file carries the layout's name: \(exported.lastPathComponent)")
        require(try Data(contentsOf: exported) == original, "the exported file is the stored layout, byte for byte")
        require(try snapshot(support) == storeBeforeExport, "exporting changes nothing in the store")
        let picked = try Personal.readImport(exported)
        require(picked == original)
        let roundTrip = try Personal.importVDF(picked, fileName: exported.lastPathComponent, accountID: 24, appID: 480, root: support)
        require(roundTrip.hash == copy.hash && roundTrip.id != copy.id && roundTrip.title == "My jump layout" && roundTrip.origin == nil)
        require(try roundTrip.bytes(root: support) == (try copy.bytes(root: support)), "export then import preserves every byte")
        require(try roundTrip.applyRequest(root: support).source == request.source, "and what it applies")
        require(try copy.applyRequest(root: support) == request, "the layout that was exported is unchanged")
        let unsafeName = try storedCopy(original, id: 301)
        _ = unsafeName
        let slashes = try Personal.importVDF(original, fileName: "a:b.vdf", accountID: 24, appID: 480, root: support)
        require(slashes.title == "a:b")
        require(try slashes.exportFile(root: support, directory: scratch).lastPathComponent == "a b.vdf", "characters a file name cannot hold are replaced")
        require(try longCopy.exportFile(root: support, directory: scratch).lastPathComponent == String(repeating: "é", count: 80) + ".vdf")
        do { _ = try tampered.exportFile(root: support, directory: scratch); fatalError("changed bytes exported") } catch {}

        // Reading a picked file is bounded and never follows into a directory.
        do { _ = try Personal.readImport(temp.appendingPathComponent("absent.vdf")); fatalError("absent file read") } catch Personal.ImportFailure.unreadable {}
        do { _ = try Personal.readImport(scratch); fatalError("directory read") } catch Personal.ImportFailure.unreadable {}
        let big = temp.appendingPathComponent("big.vdf")
        try Data(repeating: 0x41, count: Sources.limit + 1).write(to: big)
        do { _ = try Personal.readImport(big); fatalError("oversized file read") } catch Personal.ImportFailure.tooLarge {}
        try Data(repeating: 0x41, count: Sources.limit).write(to: big)
        require(try Personal.readImport(big).count == Sources.limit, "a file at the limit is read; whether it is a layout is decided afterwards")
        try Data().write(to: big)
        do { _ = try Personal.readImport(big); fatalError("empty file read") } catch Personal.ImportFailure.unreadable {}

        // The count kept per account and game is bounded.
        for index in 0..<Personal.limit {
            _ = try Personal.importVDF(original, fileName: "fill \(index).vdf", accountID: 26, appID: 480, root: support)
        }
        require(try Personal.list(root: support, accountID: 26, appID: 480).count == Personal.limit)
        let full = try snapshot(support)
        do { _ = try Personal.importVDF(original, fileName: "one more.vdf", accountID: 26, appID: 480, root: support); fatalError("limit exceeded") }
        catch Personal.ImportFailure.tooMany {}
        require(try snapshot(support) == full)
        // A record whose hash is not a hash is not listed as a usable layout.
        let brokenRecord = Personal.folder(root: support, accountID: 27, appID: 480).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: brokenRecord, withIntermediateDirectories: true)
        let json = String(decoding: try JSONEncoder().encode(imported), as: UTF8.self)
            .replacingOccurrences(of: imported.id.uuidString, with: brokenRecord.lastPathComponent)
            .replacingOccurrences(of: "\"accountID\":24", with: "\"accountID\":27").replacingOccurrences(of: imported.hash, with: "not-a-hash")
        try Data(json.utf8).write(to: brokenRecord.appendingPathComponent("layout.json"))
        do { _ = try Personal.list(root: support, accountID: 27, appID: 480); fatalError("invalid record listed") } catch Sources.Failure.invalid {}
        require(try snapshot(communityRoot) == communityAfterDownloads, "nothing in this check changed a community download")

        // Another account or game never sees the layout.
        require(try Personal.list(root: support, accountID: 25, appID: 480).isEmpty)
        require(try Personal.list(root: support, accountID: 24, appID: 481).isEmpty)
        _ = payload; payload = original

        print("PASS: personal layout apply request, exact stored bytes, UUID identity, attribution, refusals before apply, untouched community original, local-only labelling, and byte-exact VDF import and export")
    }
}
'''

# SwiftUI views are not built on the host, so pin the wiring: the personal
# layout page applies only what the checked request returns. The list, the
# page and the editor share a file, so each view is checked in its own body.
whole = (app / 'SteamInputPersonalView.swift').read_text()
def view_body(text, name):
    start = text.index(f'struct {name}: View {{')
    following = [text.find('\nstruct ', start + 1), text.find('\nprivate struct ', start + 1)]
    following = [index for index in following if index > 0]
    return text[start:min(following)] if following else text[start:]
view = view_body(whole, 'SteamInputPersonalDetail')
listing = view_body(whole, 'SteamInputPersonalLayoutsSection')
for needle, why in [
    ('let request = try copy.applyRequest(root: support)', 'apply reads and checks the stored bytes first'),
    ('try DockSteamInputService.requestPersonal(appID: request.appID, accountID: request.accountID,', 'the checked request goes to the layout service'),
    ('source: request.source, id: request.id, detail: request.detail)', 'with the checked bytes, UUID and attribution'),
    ('let isActive = active?.source == .personal && active?.identity == copy.id.uuidString && active?.contentHash == copy.hash', 'active means confirmed for this UUID and content'),
    ('.disabled(isActive || compatibility?.canApply != true || !current ||', 'apply is offered only for a checked layout in a running session'),
    ('references: DockSteamInputService.personalReferences(accountID: copy.accountID, appID: copy.appID), root: support)', 'deletion is checked against the saved selection and the service'),
]:
    if view.count(needle) != 1:
        raise SystemExit(f'FAIL: {why}: expected exactly one `{needle}` in SteamInputPersonalDetail')
if whole.count('requestPersonal(') != 1 or 'requestCommunity(' in whole:
    raise SystemExit('FAIL: the personal layout pages must apply a saved revision through requestPersonal exactly once')
editor = (app / 'SteamInputEditorView.swift').read_text()
if 'requestPersonal(' in editor or editor.count('SteamInputLiveEdit.apply(') != 1 or editor.count('SteamInputLiveEdit.settle(') != 1:
    raise SystemExit('FAIL: the editor must apply live edits only through SteamInputLiveEdit')
if listing.count('importing = false') != 2:
    raise SystemExit('FAIL: the picker must reset its presentation state after every result, including refused imports')
if listing.count('SteamInputPersonalDetail(appID: appID, copy: copy, onChange: reload)') != 1:
    raise SystemExit('FAIL: each personal layout must open its own page')
if 'SteamInputPersonalCopy.inventory(' not in listing or 'SteamInputPersonalCopy.list(' in whole:
    raise SystemExit('FAIL: the list must show damaged layouts for recovery instead of failing as a whole')
community = (app / 'SteamInputCommunityView.swift').read_text()
if community.count('SteamInputPersonalLayoutsSection(appID: appID, accountID: accountID,') != 1:
    raise SystemExit('FAIL: the community page must show the personal layouts section')

# Item 10: personal layouts are labelled local, import and export are wired,
# and no screen or message claims cloud sync or backup.
import re
store = (app / 'SteamInputCommunity.swift').read_text()
for needle, why, text in [
    ('Text(SteamInputPersonalCopy.storageNote)', 'the personal layout page says where the layout is stored', view),
    ('Label("Local to this device", systemImage: "internaldrive")', 'the personal layout page labels the layout local', view),
    ('ShareLink("Export VDF file", item: exportURL)', 'the page exports the named copy', view),
    ('exportURL = try? copy.exportFile(root: support,', 'the export file is made from the checked stored bytes', view),
    ('Text(SteamInputPersonalCopy.storageNote)', 'the list says where personal layouts are stored', listing),
    ('Text("Personal layouts · local")', 'the list labels personal layouts local', listing),
    ('Button("Import VDF file…") { importing = true }.disabled(accountID == 0)', 'the list offers import', listing),
    ('.fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { importLayout($0) }', 'the picker hands the file to the import', listing),
    ('let copy = try SteamInputPersonalCopy.importVDF(SteamInputPersonalCopy.readImport(url), fileName: url.lastPathComponent,', 'the import reads bounded bytes and validates them', listing),
]:
    if text.count(needle) != 1:
        raise SystemExit(f'FAIL: {why}: expected exactly one `{needle}`')
# Code lines only (comments may explain why nothing is synced); `async` is not a claim.
wording = re.compile(r'cloud|\bsync|backed up|backup', re.I)
claims = {}
for name, text in [('SteamInputPersonalView.swift', whole), ('SteamInputCommunityView.swift', community + editor), ('SteamInputCommunity.swift', store)]:
    claims[name] = [line.strip() for line in text.splitlines() if not line.strip().startswith('//') and wording.search(line)]
if claims['SteamInputPersonalView.swift'] or claims['SteamInputCommunityView.swift']:
    raise SystemExit(f'FAIL: storage wording in the views must come from SteamInputPersonalCopy.storageNote only: {claims}')
if len(claims['SteamInputCommunity.swift']) != 1 or 'static let storageNote = ' not in claims['SteamInputCommunity.swift'][0] \
        or 'not synced or backed up to Steam Cloud' not in claims['SteamInputCommunity.swift'][0]:
    raise SystemExit(f"FAIL: the only cloud wording may be the statement that layouts are not synced or backed up: {claims['SteamInputCommunity.swift']}")

with tempfile.TemporaryDirectory(prefix='madeira-input-personal-') as temporary:
    tmp = Path(temporary)
    (tmp / 'main.swift').write_text(program)
    workshop = (app / 'SteamWorkshopFiles.swift').read_text()
    (tmp / 'workshop.swift').write_text(workshop[:workshop.index('/// Valve\'s record of an app\'s installed Workshop items:')])
    header = root / 'madeira-dock/src/steam_input_service.h'
    subprocess.run([shutil.which('clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address', '-c', str(header.with_suffix('.c')), '-o', str(tmp / 'service.o')], check=True)
    subprocess.run([shutil.which('swiftc'), '-parse-as-library', '-sanitize=address', '-module-cache-path', str(tmp / 'modules'), '-import-objc-header', str(header),
                    str(app/'SwiftSteam/Library/SteamAppInfo.swift'), str(app/'SwiftSteam/Proto/SteamProtoMessages.swift'), str(app/'SwiftSteam/Core/SteamError.swift'),
                    str(app/'SteamKeyValues.swift'), str(app/'SteamInputVDF.swift'), str(app/'SteamInputModel.swift'), str(app/'SteamInputReferences.swift'), str(app/'SteamInputActions.swift'),
                    str(app/'SteamInputPreview.swift'), str(app/'SteamInputTransactions.swift'), str(app/'SteamInputDefaults.swift'),
                    str(app/'SteamInputEditor.swift'), str(app/'SteamInputPersonalReferences.swift'), str(app/'SteamInputPersonalRevisions.swift'),
                    str(app/'SteamInputCommunity.swift'), str(tmp/'workshop.swift'), str(tmp/'main.swift'), str(tmp/'service.o'), '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp/'roots')], check=True)
