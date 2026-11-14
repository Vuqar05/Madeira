#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Milestone 4 item 8: live editing of a personal layout through the real
layout service. Runs the production DockSteamInputService (journal, held-input
quiesce, receipts), the C transaction state machine for confirmed, rolled-back
and failed changes, the personal store and SteamInputLiveEdit together, and
checks safe deletion and retention against the persisted selection, across
an interrupted session and an unreadable selection."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
source = (app / 'MadeiraDock.swift').read_text()
source = 'enum DockSteamInputWire' + source.split('enum DockSteamInputWire', 1)[1].split("/// Steam Input's PlayStation setting", 1)[0]
source = source.replace('FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]', 'testRoot.appendingPathComponent("support")')

c_fixture = r'''
#include "steam_input_service.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* fixture confirm|rollback|fail <payload> <receipt>: what Dock reports for one change. */
int main(int argc, char **argv) {
    assert(argc == 4);
    struct sh_input_service s = {0};
    s.enabled = s.available = true;
    sh_input_service_connection(&s, true);
    uint8_t *bytes = malloc(SH_INPUT_APPLY_LIMIT + 1); assert(bytes);
    FILE *f = fopen(argv[2], "rb"); assert(f);
    size_t size = fread(bytes, 1, SH_INPUT_APPLY_LIMIT + 1, f); fclose(f);
    struct sh_input_apply p; assert(sh_input_apply_parse(bytes, size, &p));
    memcpy(s.session, p.scope.session, 16); s.appid = p.scope.appid; s.epoch = p.scope.epoch;
    struct sh_input_transaction t = {0};
    assert(sh_input_tx_init(&t, s.appid, s.epoch, p.apply_revision - 1));
    assert(sh_input_tx_reserve(&t, s.epoch, p.scope.sequence, p.apply_revision - 1));
    assert(sh_input_tx_bind(&t, p.apply_hash, p.rollback_hash) && sh_input_tx_queue(&t, 100));
    if (!strcmp(argv[1], "confirm")) {
        struct sh_input_load_result result = {.appid=s.appid,.revision=p.apply_revision,.completed=true};
        assert(sh_input_tx_completion(&t, &result, 101) && sh_input_tx_activated(&t, p.apply_revision, 102));
        assert(t.phase == SH_INPUT_TX_CONFIRMED);
    } else if (!strcmp(argv[1], "rollback")) {
        /* Valve did not activate the new layout: Dock submits the rollback copy and it is confirmed. */
        assert(sh_input_tx_fail(&t, 101) && t.phase == SH_INPUT_TX_ROLLING_BACK);
        struct sh_input_load_result result = {.appid=s.appid,.revision=p.rollback_revision,.completed=true};
        assert(sh_input_tx_completion(&t, &result, 102) && sh_input_tx_activated(&t, p.rollback_revision, 103));
        assert(t.phase == SH_INPUT_TX_ROLLED_BACK);
    } else {
        /* Neither the change nor its rollback could be confirmed. */
        assert(sh_input_tx_fail(&t, 101) && !sh_input_tx_fail(&t, 102) && t.phase == SH_INPUT_TX_FAILED);
    }
    uint8_t feed[SH_INPUT_TX_FEED_SIZE]; assert(sh_input_tx_feed(&s, &t, feed, sizeof feed) == sizeof feed);
    f = fopen(argv[3], "wb"); assert(f && fwrite(feed, 1, sizeof feed, f) == sizeof feed); fclose(f); free(bytes);
    return 0;
}
'''

stubs = r'''
let testRoot = URL(fileURLWithPath: CommandLine.arguments[1])
enum MadeiraDock {
    static var drive: URL { testRoot.appendingPathComponent("drive") }
    static var clientRoot: URL { testRoot.appendingPathComponent("client") }
}
enum SteamLog { static func event(_ text: String) {}; static func trace(_ text: @autoclosure () -> String) {} }
enum VDFParser { static func parseTextVDF(from: Data, sectionOrder: (([String], [String]) -> Void)? = nil) -> [String: Any] { [:] } }
enum MadeiraConfig { static func get(_ key: String) -> String? { nil }; static func set(_ key: String, _ value: String?) {} }
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
func require(_ test: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    do { let ok = try test(); precondition(ok, message, file: file, line: line) }
    catch { preconditionFailure("\(message): \(error)", file: file, line: line) }
}
func refusal(_ body: () throws -> Any) -> String {
    do { _ = try body(); return "" } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
}
func put32(_ data: inout Data, _ at: Int, _ value: UInt32) {
    for i in 0..<4 { data[at+i] = UInt8(truncatingIfNeeded: value >> (8*i)) }
}
'''

cases = r'''
@MainActor func checks() async throws {
    typealias Personal = SteamInputPersonalCopy
    let fm = FileManager.default
    try fm.createDirectory(at: MadeiraDock.drive, withIntermediateDirectories: true)
    let personalRoot = testRoot.appendingPathComponent("personal")
    let storage = testRoot.appendingPathComponent("support/MadeiraDock")
    let feedFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input.bin")
    let commandFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-cmd.bin")
    let payloadFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-apply.bin")
    let receiptFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-tx.bin")
    let baselineFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-baseline.bin")

    func layout(_ binding: String) -> Data {
        Data("""
        "controller_mappings"
        {
        \t"version"\t\t"3"
        \t"revision"\t\t"4"
        \t"title"\t\t"Live fixture"
        \t"controller_type"\t\t"controller_ps5"
        \t"future_block" { "kept" "exactly" }
        \t"group"
        \t{
        \t\t"id"\t\t"0"
        \t\t"mode"\t\t"four_buttons"
        \t\t"inputs" { "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "\(binding)" } } } } }
        \t}
        \t"preset" { "id" "0" "name" "Default" "group_source_bindings" { "0" "button_diamond active" } }
        }

        """.utf8)
    }
    let v1 = layout("xinput_button A, , ")
    let h1 = DockSteamInputNative.contentHash(v1)
    var copy = try Personal.create(from: v1, title: "Live", creation: .init(kind: .template, detail: "Gamepad"), accountID: 25, appID: 480, root: personalRoot)
    let spare = try Personal.create(from: v1, title: "Spare", creation: .init(kind: .template, detail: "Gamepad"), accountID: 25, appID: 480, root: personalRoot)

    // A launch whose Steam Input layout has loaded and settled.
    let template = try Data(contentsOf: testRoot.appendingPathComponent("feed.bin"))
    DockSteamInputService.begin(accountID: 25, appID: 480)
    let hex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var feed = template
    for i in 0..<16 {
        let start = hex.index(hex.startIndex, offsetBy: i*2)
        feed[8+i] = UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&feed, 36, 0); put32(&feed, 40, 0); put32(&feed, 52, 179)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    try? fm.removeItem(at: commandFile)
    put32(&feed, 36, 1); put32(&feed, 40, 1)
    let working = Data("controller_mappings { revision 0 native default }".utf8)
    var frame = Data("MSIBAS02".utf8); frame.append(feed[8..<36]); frame.append(Data(repeating: 0, count: 8))
    put32(&frame, 36, try DockSteamInputNative.revision(working)); put32(&frame, 40, UInt32(working.count)); frame.append(working)
    try frame.write(to: baselineFile)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.canChange, "the session is ready for a change")

    // Held output is released before any change is written: the quiesce
    // callback runs while no command exists yet.
    var quiesce: [(on: Bool, commandWritten: Bool)] = []
    DockSteamInputService.onInputQuiescedChanged = { quiesce.append(($0, fm.fileExists(atPath: commandFile.path))) }
    var sequence: UInt32 = 1
    /// Dock's answer to the change just requested: run the C state machine, then report its sequence.
    func answer(_ mode: String, result: UInt32 = 1) throws {
        sequence += 1
        let command = try Data(contentsOf: commandFile)
        require(command[36] == UInt8(sequence) && command[40] == 3, "the change was submitted as sequence \(sequence)")
        try fm.removeItem(at: commandFile)
        if mode != "none" {
            let host = Process(); host.executableURL = testRoot.appendingPathComponent("fixture")
            host.arguments = [mode, payloadFile.path, receiptFile.path]
            try host.run(); host.waitUntilExit(); require(host.terminationStatus == 0)
        }
        put32(&feed, 36, sequence); put32(&feed, 40, result); put32(&feed, 44, 6)
        try feed.write(to: feedFile); DockSteamInputService.refresh()
    }
    func references() -> SteamInputPersonalReferences { DockSteamInputService.personalReferences(accountID: 25, appID: 480) }
    func choice(_ hash: String) -> DockSteamInputSelection.Revision {
        .init(source: .personal, identity: copy.id.uuidString, contentHash: hash, detail: copy.detail)
    }

    // =============================================================
    // 1. The layout is applied and confirmed: it becomes the working revision
    // =============================================================
    try SteamInputLiveEdit.service(copy.applyRequest(root: personalRoot))
    require(quiesce.count == 1 && quiesce[0].on && !quiesce[0].commandWritten, "held output is released before the change is written")
    require(references().inFlight == [copy.id] && references().blocksDeletion(copy.id)?.hasPrefix("Steam Input is still switching") == true)
    try answer("confirm")
    require(DockSteamInputService.activeChoice == choice(h1) && !DockSteamInputService.inputQuiesced)
    require(references().confirmed == [copy.id: h1] && references().selected == [copy.id: [h1]] && references().inFlight.isEmpty)

    // =============================================================
    // 2. A live edit Steam Input rolls back: the working revision stays
    // =============================================================
    let v2 = try SteamInputLayoutDraft(bytes: v1)
    let pressPath = v2.model.groupDefinitions[0].input("button_a")!.activators[0].bindings[0].path
    let edited = try v2.replacingBinding(at: pressPath, with: .gamepad("B"), label: "Swapped")
    let h2 = DockSteamInputNative.contentHash(edited.bytes)
    try copy.savingDraft(edited.bytes, base: copy.hash, root: personalRoot)
    quiesce.removeAll()
    copy = try SteamInputLiveEdit.apply(edited.bytes, to: copy, root: personalRoot)
    require(copy.pending == h2 && copy.hash == h1 && quiesce.first.map { $0.on && !$0.commandWritten } == true)
    require(try SteamInputLiveEdit.settle(copy, root: personalRoot).1 == .waiting)
    require(refusal { try Personal.delete(copy.id, accountID: 25, appID: 480, references: references(), root: personalRoot) }.hasPrefix("Steam Input is still switching"))
    try answer("rollback")
    require(DockSteamInputService.activeChoice == choice(h1), "Steam Input restored the working layout")
    require(!DockSteamInputService.inputQuiesced && DockSteamInputService.receipt?.phase == .rolledBack)
    var settled = try SteamInputLiveEdit.settle(copy, root: personalRoot)
    require(settled.1 == .reverted && settled.0.hash == h1 && settled.0.pending == nil)
    copy = settled.0
    require(try copy.applyRequest(root: personalRoot).source == v1, "the working revision is still the saved one")
    require(try copy.draft(root: personalRoot).map { $0.hash } == h2, "the edits are kept as the draft")
    require(try copy.bytes(of: h2, root: personalRoot) == edited.bytes, "the refused revision stays while the selection names it")

    // =============================================================
    // 3. A live edit that fails validation is never sent
    // =============================================================
    let invalid = try v2.replacingBinding(at: pressPath, with: .modeShift(source: "joystick", groupID: "9"), label: nil)
    let selectionBefore = DockSteamInputService.selection
    quiesce.removeAll()
    require(refusal { try SteamInputLiveEdit.apply(invalid.bytes, to: copy, root: personalRoot) }.contains("group 9, which the layout does not define"))
    require(!fm.fileExists(atPath: commandFile.path) && quiesce.isEmpty && DockSteamInputService.selection == selectionBefore)
    require(try DockSteamInputService.activeChoice == choice(h1) && (try copy.reloaded(root: personalRoot)).pending == nil)
    // A conditional layout is still refused the same way.
    let conditional = Data(String(decoding: v1, as: UTF8.self).replacingOccurrences(of: "\"0\" \"button_diamond active\"", with: "\"0\" \"button_diamond active\" [$WIN32]").utf8)
    let conditionalRefusal = refusal { try SteamInputLiveEdit.apply(conditional, to: copy, root: personalRoot) }
    require(conditionalRefusal.contains("Conditional layouts are not supported yet."), conditionalRefusal)
    require(!fm.fileExists(atPath: commandFile.path) && DockSteamInputService.activeChoice == choice(h1))

    // =============================================================
    // 4. Retried and confirmed: the edit becomes current and active
    // =============================================================
    copy = try SteamInputLiveEdit.apply(edited.bytes, to: copy, root: personalRoot)
    try answer("confirm")
    require(DockSteamInputService.activeChoice == choice(h2))
    settled = try SteamInputLiveEdit.settle(copy, root: personalRoot)
    require(try settled.1 == .confirmed && settled.0.hash == h2 && (try settled.0.draft(root: personalRoot)) == nil)
    copy = settled.0
    require(try copy.revisions.map(\.hash) == [h1, h2] && (try copy.bytes(of: h1, root: personalRoot)) == v1)
    require(String(decoding: try copy.bytes(root: personalRoot), as: UTF8.self).contains("\"future_block\" { \"kept\" \"exactly\" }"))

    // =============================================================
    // 5. Failed outright, and refused by Dock: the working revision stays
    // =============================================================
    let v3 = try edited.replacingBinding(at: pressPath, with: .gamepad("X"), label: nil)
    let h3 = DockSteamInputNative.contentHash(v3.bytes)
    copy = try SteamInputLiveEdit.apply(v3.bytes, to: copy, root: personalRoot)
    try answer("fail")
    require(DockSteamInputService.receipt?.phase == .failed && DockSteamInputService.activeChoice == choice(h2))
    settled = try SteamInputLiveEdit.settle(copy, root: personalRoot)
    require(settled.1 == .reverted && settled.0.hash == h2)
    copy = settled.0
    copy = try SteamInputLiveEdit.apply(v3.bytes, to: copy, root: personalRoot)
    try answer("none", result: 7)
    require(DockSteamInputService.activeChoice == choice(h2) && !DockSteamInputService.inputQuiesced)
    settled = try SteamInputLiveEdit.settle(copy, root: personalRoot)
    require(settled.1 == .reverted && settled.0.hash == h2)
    copy = settled.0

    // =============================================================
    // 6. Interrupted: the session ends before a receipt
    // =============================================================
    copy = try SteamInputLiveEdit.apply(v3.bytes, to: copy, root: personalRoot)
    require(references().inFlight == [copy.id])
    DockSteamInputService.end()
    try? fm.removeItem(at: commandFile)
    // Read again from disk, as after a relaunch: the confirmed revision is h2.
    require(references().confirmed == [copy.id: h2] && references().inFlight.isEmpty && references().selected[copy.id]?.contains(h3) == true)
    settled = try SteamInputLiveEdit.settle(copy, root: personalRoot)
    require(settled.1 == .reverted && settled.0.hash == h2 && settled.0.pending == nil)
    copy = settled.0
    require(try copy.bytes(root: personalRoot) == edited.bytes)

    // =============================================================
    // 7. Deletion and retention against the saved selection, game not running
    // =============================================================
    require(refusal { try Personal.delete(copy.id, accountID: 25, appID: 480, references: references(), root: personalRoot) }
            .hasPrefix("This layout is this game's chosen Steam Input layout."))
    require(try Personal.delete(spare.id, accountID: 25, appID: 480, references: references(), root: personalRoot) == ())
    require(try Personal.inventory(root: personalRoot, accountID: 25, appID: 480).map(\.id) == [copy.id])
    // The revision the game was last confirmed with survives any amount of history pruning.
    var pruned = copy
    for index in 0..<(Personal.historyLimit + 3) {
        pruned = try pruned.saving(layout("key_press F\(index % 12 + 1), , "), references: references(), root: personalRoot)
    }
    require(try !pruned.revisions.contains { $0.hash == h2 } && (try pruned.bytes(of: h2, root: personalRoot)) == edited.bytes,
            "the confirmed revision is retained until a replacement is confirmed")
    // The journal's own copy reapplies it on the next launch regardless.
    // An unreadable selection blocks deletion and settles nothing.
    let target = try fm.subpathsOfDirectory(atPath: storage.path).first { $0.hasSuffix(".json") && $0.contains("480") } ?? ""
    require(!target.isEmpty, "the selection is persisted under the support directory")
    try Data("{".utf8).write(to: storage.appendingPathComponent(target))
    require(references() == .unknown)
    require(refusal { try Personal.delete(copy.id, accountID: 25, appID: 480, references: references(), root: personalRoot) }.hasPrefix("Madeira could not read"))
    let staged = try pruned.staging(v3.bytes, root: personalRoot)
    require(try staged.reconciled(references: references(), root: personalRoot).1 == .waiting)
    print("PASS: live personal-layout editing through the real layout service: held output released before each change, confirmed/rolled-back/failed/refused/interrupted changes, validation and conditional refusal before sending, working revision kept until confirmed, safe deletion and retention against the saved selection")
}
try await checks()
'''

with tempfile.TemporaryDirectory(prefix='madeira-input-live-edit-') as temporary:
    tmp = Path(temporary)
    cc = os.environ.get('HOST_CC') or shutil.which('clang')
    header = root / 'madeira-dock/src/steam_input_service.h'
    (tmp / 'fixture.c').write_text(c_fixture)
    subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-I' + str(root/'madeira-dock/src'),
                    str(root/'madeira-dock/src/steam_input_service.c'), str(tmp/'fixture.c'), '-o', str(tmp/'fixture')], check=True)
    # A feed template written by the C service itself (the service check's own fixture mode).
    feed_c = r'''
#include "steam_input_service.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    (void)argc;
    struct sh_input_service s = {0};
    assert(sh_input_session_parse("0123456789abcdef0123456789abcdef", s.session));
    s.enabled = s.available = true; s.appid = 480;
    sh_input_service_connection(&s, true);
    s.state = SH_INPUT_ACTIVATION_REQUESTED; strcpy(s.selection, "AC-480-controller_ps5");
    uint8_t b[SH_INPUT_FEED_CAP]; size_t n = sh_input_service_feed(&s, b, sizeof b);
    FILE *f = fopen(argv[1], "wb"); assert(f && fwrite(b, 1, n, f) == n); fclose(f);
    return 0;
}
'''
    (tmp / 'feed.c').write_text(feed_c)
    subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-I' + str(root/'madeira-dock/src'),
                    str(root/'madeira-dock/src/steam_input_service.c'), str(tmp/'feed.c'), '-o', str(tmp/'feed')], check=True)
    subprocess.run([str(tmp/'feed'), str(tmp/'feed.bin')], check=True)
    subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-c', str(root/'madeira-dock/src/steam_input_service.c'), '-o', str(tmp/'shared.o')], check=True)
    workshop = (app / 'SteamWorkshopFiles.swift').read_text()
    (tmp / 'workshop.swift').write_text(workshop[:workshop.index('/// Valve\'s record of an app\'s installed Workshop items:')])
    (tmp / 'main.swift').write_text('import Foundation\n' + stubs + source + cases)
    subprocess.run([os.environ.get('SWIFTC') or shutil.which('swiftc'), '-D', 'DEBUG', '-sanitize=address', '-module-cache-path', str(tmp/'modules'),
                    '-import-objc-header', str(header),
                    str(app/'SwiftSteam/Library/SteamAppInfo.swift'), str(app/'SwiftSteam/Proto/SteamProtoMessages.swift'), str(app/'SwiftSteam/Core/SteamError.swift'),
                    str(app/'SteamKeyValues.swift'), str(app/'SteamInputVDF.swift'), str(app/'SteamInputModel.swift'), str(app/'SteamInputReferences.swift'),
                    str(app/'SteamInputActions.swift'), str(app/'SteamInputPreview.swift'), str(app/'SteamInputTransactions.swift'), str(app/'SteamInputDefaults.swift'),
                    str(app/'SteamInputEditor.swift'), str(app/'SteamInputPersonalReferences.swift'), str(app/'SteamInputPersonalRevisions.swift'),
                    str(app/'SteamInputCommunity.swift'), str(app/'SteamInputLiveEdit.swift'), str(tmp/'workshop.swift'), str(tmp/'main.swift'), str(tmp/'shared.o'),
                    '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp)], check=True)
