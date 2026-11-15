#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Milestone 4 items 3, 7 and 8 (store side): creating personal layouts from
every source, stable identities and revision history, drafts across restarts,
save, restore, duplicate, rename, safe deletion, recovery of damaged layouts,
retention of the revision the game uses, and staging a live change. Runs the
production store under AddressSanitizer against real files, including
interrupted writes and damaged records."""
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
    do { let result = try body(); precondition(result, message, file: file, line: line) }
    catch { preconditionFailure("\(message): \(error)", file: file, line: line) }
}
func refusal(_ body: () throws -> Any) -> String {
    do { _ = try body(); return "" } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
}
func snapshot(_ url: URL) throws -> [String: String] {
    var out: [String: String] = [:]
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return out }
    for case let entry as URL in walker {
        let path = String(entry.path.dropFirst(url.path.count))
        if (try entry.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            out[path] = SHA256.hash(data: try Data(contentsOf: entry)).map { String(format: "%02x", $0) }.joined()
        } else { out[path] = "-" }
    }
    return out
}

@main struct CheckRevisions {
    @MainActor static func main() async throws {
        typealias Personal = SteamInputPersonalCopy
        typealias Sources = SteamInputCommunitySources
        let temp = URL(fileURLWithPath: CommandLine.arguments[1])
        let support = temp.appendingPathComponent("support", isDirectory: true)
        let communityRoot = temp.appendingPathComponent("community", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let free = SteamInputPersonalReferences()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        func layout(_ binding: String = "xinput_button A, Jump, ", title: String = "Fixture") -> Data {
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
            \t"preset" { "id" "0" "name" "Default" "group_source_bindings" { "0" "button_diamond active" } }
            }

            """.utf8)
        }
        let base = layout()

        // =============================================================
        // 1. Every creation source, with a stable identity of its own
        // =============================================================
        let fromDefault = try Personal.create(from: base, title: "From default", creation: .init(kind: .gameDefault, detail: "the layout bundled with this game"),
                                              in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480), now: t0)
        require(fromDefault.provenance == "Made from the game default · the layout bundled with this game")
        require(fromDefault.detail == "From default · personal layout from the game default" && fromDefault.revisions.map(\.note) == ["Created"])
        require(try fromDefault.applyRequest(root: support).source == base && fromDefault.version == 2)
        let template = try Personal.create(from: layout(title: "Template"), title: "From template", creation: .init(kind: .template, detail: "Gamepad"),
                                           in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480), now: t0)
        require(template.provenance == "Made from Steam's Gamepad template" && template.id != fromDefault.id)
        // A community copy, the original download untouched.
        let item: SteamWorkshopItem = {
            var value = SteamWorkshopItem(id: 77, appID: 241100, result: 1)
            value.title = "Community"; value.fileURL = "https://ugc.steamusercontent.com/fixture"; value.fileSize = UInt64(base.count)
            value.timeUpdated = 1; value.fileType = 12; value.tags = ["controller_ps5"]
            value.kvTags = [.init(key: "app", value: "480"), .init(key: "visibility", value: "public"), .init(key: "deleted", value: "0")]
            return value
        }()
        let sources = Sources(root: communityRoot, query: { _, _, _, _ in fatalError() }, details: { _ in [item] }, download: { _ in base })
        let downloaded = try await sources.download(appID: 480, item: item)
        let communityBefore = try snapshot(communityRoot)
        let community = try Personal.create(downloaded, title: "Community copy", accountID: 24, root: support)
        require(community.version == 1 && community.history == nil, "a community copy is still written as before")
        // An existing VDF and an existing personal layout.
        let imported = try Personal.importVDF(base, fileName: "pad.vdf", into: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480), now: t0)
        let duplicate = try imported.duplicate(root: support, now: t0)
        require(duplicate.id != imported.id && duplicate.hash == imported.hash && duplicate.title == "pad copy" && duplicate.creation?.from == imported.id)
        require(try duplicate.provenance == "Duplicated from pad" && (try duplicate.bytes(root: support)) == base)
        let named = try template.duplicate(title: "  Named  ", root: support)
        require(named.title == "Named")
        // Refusals, with nothing left behind.
        let before = try snapshot(support)
        require(refusal { try Personal.create(from: Data(String(decoding: base, as: UTF8.self).replacingOccurrences(of: "\"0\" \"button_diamond active\"", with: "\"0\" \"button_diamond active\" [$WIN32]").utf8),
                                              title: "x", creation: .init(kind: .template, detail: "x"), in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480)) }.contains("Conditional layouts are not supported yet."))
        require(refusal { try Personal.create(from: layout("mode_shift joystick 9, , "), title: "x", creation: .init(kind: .template, detail: "x"), in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480)) }
                .contains("group 9, which the layout does not define"))
        require(refusal { try Personal.create(from: base, title: "x", creation: .init(kind: .template, detail: "x"), in: SteamInputPersonalShelf(root: support, accountID: 0, appID: 480)) }
                == Personal.ImportFailure.noAccount.errorDescription)
        require(refusal { try Personal.create(from: base, title: " ", creation: .init(kind: .template, detail: "x"), in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480)) }
                == Personal.LifecycleFailure.invalidTitle.errorDescription)
        require(try snapshot(support) == before, "refused creations write nothing")
        var listing = try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480))
        require(listing.count == 6 && listing.allSatisfy { $0.problem == nil }, "\(listing.map(\.title))")
        require(Set(listing.map(\.id)).count == 6, "every layout keeps its own identity")

        // =============================================================
        // 2. Revisions: save, history, restore, unknown fields, the community original
        // =============================================================
        let draft = try SteamInputLayoutDraft(bytes: try community.bytes(root: support))
        let press = draft.model.groupDefinitions[0].input("button_a")!.activators[0]
        let edited = try draft.replacingBinding(at: press.bindings[0].path, with: .gamepad("B"), label: "Swapped")
        let saved = try community.saving(edited.bytes, references: free, root: support, now: t0.addingTimeInterval(60))
        require(saved.id == community.id && saved.hash == DockSteamInputNative.contentHash(edited.bytes) && saved.version == 1, "the in-memory value keeps its decoded version")
        let reread = try saved.reloaded(root: support)
        require(reread.version == 2 && reread.revisions.map(\.hash) == [community.hash, saved.hash] && reread.revisions.map(\.note) == ["Copied", "Saved"])
        require(try reread.bytes(root: support) == edited.bytes && (try reread.bytes(of: community.hash, root: support)) == base, "earlier revisions stay readable")
        require(String(decoding: try reread.bytes(root: support), as: UTF8.self).contains("\"future_block\" { \"kept\" \"exactly\" }"), "unknown fields survive an edit and save")
        require(reread.origin == downloaded.revision && reread.provenance == "Copied from Community · Workshop 77", "a copy keeps its attribution after edits")
        require(try snapshot(communityRoot) == communityBefore && (try sources.load(downloaded.revision).bytes) == base, "editing a community copy leaves the original intact")
        require(try reread.applyRequest(root: support).source == edited.bytes)
        // Saving the same bytes again adds nothing.
        let same = try reread.saving(edited.bytes, references: free, root: support)
        require(same.revisions.count == 2)
        // Restore makes an old revision current as a new entry.
        let restored = try reread.restoring(reread.revisions[0], references: free, root: support, now: t0.addingTimeInterval(120))
        require(restored.hash == community.hash && restored.revisions.count == 3 && restored.revisions[2].note.hasPrefix("Restored revision from "))
        require(try restored.bytes(root: support) == base)
        // Export and import round-trip the saved revision byte for byte under a new identity.
        let exported = try restored.saving(edited.bytes, references: free, root: support).exportFile(root: support, directory: temp.appendingPathComponent("export"))
        let back = try Personal.importVDF(try Personal.readImport(exported), fileName: exported.lastPathComponent, into: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480))
        require(try back.bytes(root: support) == edited.bytes && back.id != community.id)
        // Refused saves change nothing.
        let stateBefore = try snapshot(support)
        require(refusal { try community.saving(Data("not a layout".utf8), references: free, root: support) }.hasPrefix("The layout was not saved."))
        require(refusal { try community.saving(Data(String(decoding: base, as: UTF8.self).replacingOccurrences(of: "\"version\"\t\t\"3\"", with: "\"version\"\t\t\"2\"").utf8), references: free, root: support) }
                .contains("version 2"))
        require(try snapshot(support) == stateBefore)
        // A revision with a broken reference can be saved while editing, but not applied.
        let broken = try fromDefault.saving(layout("mode_shift joystick 9, , "), references: free, root: support)
        require(refusal { try broken.applyRequest(root: support) }.contains("group 9, which the layout does not define"))
        _ = try broken.restoring(broken.revisions[0], references: free, root: support)

        // History is bounded; the revision the game uses is kept beyond it.
        var long = try Personal.create(from: base, title: "Long history", creation: .init(kind: .template, detail: "Gamepad"), in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480), now: t0)
        let firstHash = long.hash
        let retainedRefs = SteamInputPersonalReferences(selected: [long.id: [firstHash]], confirmed: [long.id: firstHash])
        for index in 0..<(Personal.historyLimit + 6) {
            long = try long.saving(layout("key_press F\(index % 12 + 1), Step \(index), "), references: retainedRefs, root: support)
        }
        require(long.revisions.count == Personal.historyLimit && !long.revisions.contains { $0.hash == firstHash })
        require(try long.bytes(of: firstHash, root: support) == base, "the confirmed revision is retained until a replacement is confirmed")
        let dropped = long.revisions.first!.hash
        long = try long.saving(layout("key_press ESCAPE, Last, "), references: free, root: support)
        require(refusal { try long.bytes(of: dropped, root: support) } != "", "a revision no history or selection keeps is pruned")
        require(try long.bytes(of: firstHash, root: support) == base, "the first stored file stays")
        // Unknown references never prune anything.
        let filesBefore = try snapshot(long.directory(support))
        try long.cleanUp(references: .unknown, root: support)
        require(try snapshot(long.directory(support)) == filesBefore)

        // =============================================================
        // 3. Drafts: kept across restarts, cleared by saving, damage detected
        // =============================================================
        let draftBytes = edited.bytes
        try imported.savingDraft(draftBytes, base: imported.hash, root: support, now: t0)
        // A "restart": everything read again from disk.
        let afterRestart = try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480)).first { $0.id == imported.id }!.copy!
        let recoveredDraft = try afterRestart.draft(root: support)!
        require(try recoveredDraft.base == imported.hash && (try afterRestart.draftBytes(recoveredDraft, root: support)) == draftBytes)
        require(try afterRestart.bytes(root: support) == base, "a draft never changes the saved revision")
        // A newer draft replaces the older one; an interrupted draft write leaves the previous draft.
        try afterRestart.savingDraft(layout("key_press Q, , "), base: imported.hash, root: support)
        try layout("key_press Z, , ").write(to: afterRestart.directory(support).appendingPathComponent("draft-" + String(repeating: "e", count: 64) + ".vdf"))
        let latest = try afterRestart.draft(root: support)!
        require(try afterRestart.draftBytes(latest, root: support) == layout("key_press Q, , "), "the record names the draft that was completely written")
        // A damaged draft is reported, then discarded.
        try Data("garbage".utf8).write(to: afterRestart.directory(support).appendingPathComponent("draft-\(latest.hash).vdf"))
        require(refusal { try afterRestart.draftBytes(latest, root: support) } != "")
        try afterRestart.discardDraft(root: support)
        require(try afterRestart.draft(root: support) == nil && !((try FileManager.default.contentsOfDirectory(atPath: afterRestart.directory(support).path)).contains { $0.hasPrefix("draft") }))
        try Data("{".utf8).write(to: afterRestart.directory(support).appendingPathComponent("draft.json"))
        require(refusal { try afterRestart.draft(root: support) } != "", "a damaged draft record is reported, not silently used")
        try afterRestart.discardDraft(root: support)
        // Saving the draft's bytes clears the draft.
        try afterRestart.savingDraft(draftBytes, base: imported.hash, root: support)
        let savedDraft = try afterRestart.saving(draftBytes, references: free, root: support)
        require(try savedDraft.draft(root: support) == nil && (try savedDraft.bytes(root: support)) == draftBytes)

        // An interrupted save (revision written, record not yet replaced) keeps the previous state.
        let interrupted = try template.reloaded(root: support)
        let orphanBytes = layout("key_press O, , ")
        let orphan = interrupted.directory(support).appendingPathComponent("revisions/\(DockSteamInputNative.contentHash(orphanBytes)).vdf")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try orphanBytes.write(to: orphan)
        require(try interrupted.reloaded(root: support).hash == template.hash && (try interrupted.bytes(root: support)) == layout(title: "Template"))
        try interrupted.cleanUp(references: free, root: support)
        require(!FileManager.default.fileExists(atPath: orphan.path), "the unreferenced revision of an interrupted save is removed")

        // =============================================================
        // 4. Rename and duplicate are independent
        // =============================================================
        let renamed = try duplicate.renamed("Renamed pad", root: support)
        require(try renamed.title == "Renamed pad" && renamed.hash == duplicate.hash && (try renamed.reloaded(root: support)).title == "Renamed pad")
        require(refusal { try duplicate.renamed("", root: support) } == Personal.LifecycleFailure.invalidTitle.errorDescription)
        require(refusal { try duplicate.renamed(String(repeating: "x", count: 161), root: support) } == Personal.LifecycleFailure.invalidTitle.errorDescription)
        let editedDuplicate = try renamed.saving(layout("key_press D, , "), references: free, root: support)
        require(try imported.reloaded(root: support).hash == savedDraft.hash && editedDuplicate.hash != savedDraft.hash, "editing a duplicate leaves its original alone")

        // =============================================================
        // 5. Safe deletion
        // =============================================================
        func delete(_ copy: Personal, _ references: SteamInputPersonalReferences) -> String {
            refusal { try Personal.delete(copy.id, from: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480), references: references) }
        }
        let storeBefore = try snapshot(support)
        require(delete(fromDefault, SteamInputPersonalReferences(selected: [fromDefault.id: [fromDefault.hash]])).hasPrefix("This layout is this game's chosen Steam Input layout."))
        require(delete(fromDefault, SteamInputPersonalReferences(inFlight: [fromDefault.id])).hasPrefix("Steam Input is still switching to this layout."))
        require(delete(fromDefault, .unknown).hasPrefix("Madeira could not read this game's saved layout choice"))
        require(try snapshot(support) == storeBefore, "a refused deletion removes nothing")
        // Another layout's selection does not block this one.
        require(delete(named, SteamInputPersonalReferences(selected: [fromDefault.id: [fromDefault.hash]])) == "")
        require(try !(try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480))).contains { $0.id == named.id })
        // An interrupted deletion (renamed out, not yet removed) is cleaned up and is not listed.
        let trash = SteamInputPersonalShelf(root: support, accountID: 24, appID: 480).folder.appendingPathComponent(".deleted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: trash.appendingPathComponent("layout.json"))
        let staging = SteamInputPersonalShelf(root: support, accountID: 24, appID: 480).folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        listing = try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480))
        require(!FileManager.default.fileExists(atPath: trash.path) && !FileManager.default.fileExists(atPath: staging.path))

        // =============================================================
        // 6. Recovery of damaged and incompatible layouts
        // =============================================================
        // The current revision was changed outside Madeira: the newest readable earlier revision returns.
        var damaged = try Personal.create(from: base, title: "Damaged", creation: .init(kind: .template, detail: "Gamepad"), in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480), now: t0)
        damaged = try damaged.saving(layout("key_press K, , "), references: free, root: support, now: t0.addingTimeInterval(10))
        try Data("garbage".utf8).write(to: damaged.directory(support).appendingPathComponent("revisions/\(damaged.hash).vdf"))
        listing = try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480))
        require(listing.first { $0.id == damaged.id }?.problem == "Its current revision is missing or was changed outside Madeira.")
        require(refusal { try damaged.applyRequest(root: support) } == Personal.ApplyFailure.damaged.errorDescription)
        let repaired = try Personal.recover(damaged.id, in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480), now: t0)
        require(try repaired.id == damaged.id && repaired.hash == DockSteamInputNative.contentHash(base) && (try repaired.bytes(root: support)) == base)
        require(try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480)).first { $0.id == damaged.id }?.problem == nil)
        // An unreadable record is rebuilt from the files that remain, under the same identity.
        try Data("{".utf8).write(to: duplicate.directory(support).appendingPathComponent("layout.json"))
        require(try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480)).first { $0.id == duplicate.id }?.problem == "Its record cannot be read.")
        // The strict listing refuses while a record is damaged; the inventory lists it for recovery.
        require(refusal { try Personal.list(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480)) } != "")
        let rebuilt = try Personal.recover(duplicate.id, in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480), now: t0)
        require(rebuilt.id == duplicate.id && rebuilt.title == "Recovered layout" && rebuilt.creation?.kind == .recovered)
        require(Set(rebuilt.revisions.map(\.hash)) == [DockSteamInputNative.contentHash(base), DockSteamInputNative.contentHash(layout("key_press D, , "))])
        require(try rebuilt.applyRequest(root: support).source.isEmpty == false)
        // Nothing readable left: recovery refuses, deletion still works.
        let hopeless = try Personal.create(from: base, title: "Hopeless", creation: .init(kind: .template, detail: "Gamepad"), in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480))
        try Data("garbage".utf8).write(to: hopeless.directory(support).appendingPathComponent("source.vdf"))
        require(refusal { try Personal.recover(hopeless.id, in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480)) } == Personal.LifecycleFailure.nothingToRecover.errorDescription)
        require(delete(hopeless, free) == "")
        // A layout that reads but cannot be applied stays editable: the editor opens it and fixes it.
        let incompatible = try Personal.create(from: layout(), title: "Gyro", creation: .init(kind: .template, detail: "Gamepad"), in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480))
        let gyroDraft = try SteamInputLayoutDraft(bytes: try incompatible.bytes(root: support))
            .switchingMode(of: "gyro", in: VDFPath([.init("controller_mappings"), .init("preset")]), to: "mouse_joystick")
        let gyro = try incompatible.saving(gyroDraft.bytes, references: free, root: support)
        require(refusal { try gyro.applyRequest(root: support) } == "This layout cannot be applied. Unavailable inputs or features: gyro.")
        let fixed = try gyro.saving(try SteamInputLayoutDraft(bytes: gyroDraft.bytes).disablingSource("gyro", in: VDFPath([.init("controller_mappings"), .init("preset")])).bytes,
                                    references: free, root: support)
        require(try fixed.applyRequest(root: support).compatibility.canApply, "disabling the unforwarded source makes it applicable again")
        // Imports count damaged layouts toward the bound, so a damaged one cannot hide space.
        require(try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480)).count == (try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 480))).count)

        // =============================================================
        // 7. Staging a live change: the working revision stays until confirmed
        // =============================================================
        var live = try Personal.create(from: base, title: "Live", creation: .init(kind: .template, detail: "Gamepad"), in: SteamInputPersonalShelf(root: support, accountID: 24, appID: 480), now: t0)
        let working = live.hash
        let next = layout("xinput_button Y, , ")
        let nextHash = DockSteamInputNative.contentHash(next)
        try live.savingDraft(next, base: working, root: support)
        live = try live.staging(next, root: support)
        require(try live.pending == nextHash && live.hash == working && (try live.applyRequest(root: support)).source == base)
        require(try live.applyRequest(root: support, revision: nextHash).source == next)
        require(refusal { try live.staging(next, root: support) } == Personal.LifecycleFailure.busy.errorDescription)
        require(refusal { try live.saving(next, references: free, root: support) } == Personal.LifecycleFailure.busy.errorDescription)
        require(delete(live, free) == Personal.LifecycleFailure.busy.errorDescription, "a layout with a change in flight is not deleted")
        var outcome = try live.reconciled(references: SteamInputPersonalReferences(selected: [live.id: [working, nextHash]], confirmed: [live.id: working], inFlight: [live.id]), root: support)
        require(outcome.1 == .waiting && outcome.0.pending == nextHash)
        outcome = try live.reconciled(references: .unknown, root: support)
        require(outcome.1 == .waiting, "an unreadable selection never settles a change")
        // Rolled back or failed: the working revision stays current; the draft keeps the edits.
        outcome = try live.reconciled(references: SteamInputPersonalReferences(selected: [live.id: [working, nextHash]], confirmed: [live.id: working]), root: support)
        require(outcome.1 == .reverted && outcome.0.hash == working && outcome.0.pending == nil)
        require(try outcome.0.bytes(root: support) == base && (try outcome.0.draft(root: support)).map { $0.hash } == nextHash)
        require(try outcome.0.bytes(of: nextHash, root: support) == next, "the refused revision is kept while the selection names it")
        // Confirmed: exactly the pending revision becomes current and the draft is cleared.
        live = try outcome.0.staging(next, root: support)
        outcome = try live.reconciled(references: SteamInputPersonalReferences(selected: [live.id: [nextHash]], confirmed: [live.id: nextHash]), root: support, now: t0.addingTimeInterval(5))
        require(outcome.1 == .confirmed && outcome.0.hash == nextHash && outcome.0.pending == nil && outcome.0.revisions.last?.note == "Saved and applied")
        require(try outcome.0.draft(root: support) == nil && (try outcome.0.bytes(of: working, root: support)) == base)
        require(try outcome.0.reconciled(references: free, root: support).1 == .idle)
        // A change staged but never sent is withdrawn.
        let unsent = try outcome.0.staging(layout("xinput_button X, , "), root: support).unstaged(root: support)
        require(unsent.pending == nil && unsent.hash == nextHash)
        // A pending revision that is itself damaged on disk is refused before the service is asked.
        let tamper = try unsent.staging(layout("xinput_button B, , "), root: support)
        try Data("garbage".utf8).write(to: tamper.directory(support).appendingPathComponent("revisions/\(tamper.pending!).vdf"))
        require(refusal { try tamper.applyRequest(root: support, revision: tamper.pending!) } == Personal.ApplyFailure.damaged.errorDescription)
        _ = try tamper.unstaged(root: support)

        // Isolation.
        require(try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 25, appID: 480)).isEmpty && (try Personal.inventory(SteamInputPersonalShelf(root: support, accountID: 24, appID: 481))).isEmpty)
        // A touchpad half the layout uses blocks apply; set to Not used in the
        // editor (Steam's "inactive"), the layout applies.
        let halves = try SteamInputLayoutDraft(bytes: base)
        let preset0 = halves.model.presets[0].path
        let withHalves = try halves.switchingMode(of: "left_trackpad", in: preset0, to: "absolute_mouse")
            .switchingMode(of: "right_trackpad", in: preset0, to: "single_button")
        require(try SteamInputCompatibility(withHalves.bytes).unsupported == ["left trackpad", "right trackpad"])
        let halvesOff = try withHalves.disablingSource("left_trackpad", in: preset0).disablingSource("right_trackpad", in: preset0)
        require(try SteamInputCompatibility(halvesOff.bytes).canApply, "touchpad halves set to Not used no longer block apply")
        print("PASS: personal layouts from the game default, templates, community copies, imports and duplicates; stable identities; revision history with save, restore, bounded pruning and retention of the revision the game uses; drafts across restarts; rename; safe deletion; recovery of damaged and incompatible layouts; interrupted writes; live-change staging; touchpad halves set to Not used no longer block apply")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-input-revisions-') as temporary:
    tmp = Path(temporary)
    (tmp / 'main.swift').write_text(program)
    workshop = (app / 'SteamWorkshopFiles.swift').read_text()
    (tmp / 'workshop.swift').write_text(workshop[:workshop.index('/// Valve\'s record of an app\'s installed Workshop items:')])
    header = root / 'madeira-dock/src/steam_input_service.h'
    subprocess.run([shutil.which('clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address', '-c', str(header.with_suffix('.c')), '-o', str(tmp / 'service.o')], check=True)
    subprocess.run([shutil.which('swiftc'), '-parse-as-library', '-sanitize=address', '-module-cache-path', str(tmp / 'modules'), '-import-objc-header', str(header),
                    str(app/'SwiftSteam/Library/SteamAppInfo.swift'), str(app/'SwiftSteam/Proto/SteamProtoMessages.swift'), str(app/'SwiftSteam/Core/SteamError.swift'),
                    str(app/'SteamKeyValues.swift'), str(app/'SteamInputVDF.swift'), str(app/'SteamInputModel.swift'), str(app/'SteamInputReferences.swift'), str(app/'SteamInputActions.swift'),
                    str(app/'SteamInputPreview.swift'), str(app/'SteamInputTransactions.swift'), str(app/'SteamInputController.swift'), str(app/'SteamInputDefaults.swift'),
                    str(app/'SteamInputEditor.swift'), str(app/'SteamInputPersonalReferences.swift'), str(app/'SteamInputPersonalRevisions.swift'),
                    str(app/'SteamInputCommunity.swift'), str(tmp/'workshop.swift'), str(tmp/'main.swift'), str(tmp/'service.o'), '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp/'roots')], check=True)
