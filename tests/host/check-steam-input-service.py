#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Cross-language protocol and production Swift service/migration checks."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/MadeiraDock.swift').read_text()
source = 'enum DockSteamInputWire' + source.split('enum DockSteamInputWire', 1)[1].split("/// Steam Input's PlayStation setting", 1)[0]
source = source.replace('FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]', 'testRoot.appendingPathComponent("support")')
service_start = source.index('@MainActor enum DockSteamInputService')
service_end = source.index('struct DockSteamInputSelection:')
source = source[:service_start] + source[service_start:service_end].replace('Date()', 'serviceNow()') + source[service_end:]
c_fixture = r'''
#include "steam_input_service.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    struct sh_input_service s = {0};
    assert(sh_input_session_parse("0123456789abcdef0123456789abcdef", s.session));
    s.enabled = s.available = true; s.appid = 480;
    sh_input_service_connection(&s, true);
    if (argc == 4) {
        uint8_t *bytes = malloc(SH_INPUT_APPLY_LIMIT + 1); assert(bytes);
        FILE *f = fopen(argv[2], "rb"); assert(f);
        size_t size = fread(bytes, 1, SH_INPUT_APPLY_LIMIT + 1, f); fclose(f);
        struct sh_input_apply p; assert(sh_input_apply_parse(bytes, size, &p));
        memcpy(s.session, p.scope.session, 16); s.appid = p.scope.appid; s.epoch = p.scope.epoch;
        struct sh_input_transaction t = {0};
        assert(sh_input_tx_init(&t, s.appid, s.epoch, p.apply_revision - 1));
        assert(sh_input_tx_reserve(&t, s.epoch, p.scope.sequence, p.apply_revision - 1));
        assert(sh_input_tx_bind(&t, p.apply_hash, p.rollback_hash) && sh_input_tx_queue(&t, 100));
        struct sh_input_load_result result = {.appid=s.appid,.revision=p.apply_revision,.completed=true};
        assert(sh_input_tx_completion(&t, &result, 101) && sh_input_tx_activated(&t, p.apply_revision, 102));
        uint8_t feed[SH_INPUT_TX_FEED_SIZE]; assert(sh_input_tx_feed(&s, &t, feed, sizeof feed) == sizeof feed);
        f = fopen(argv[3], "wb"); assert(f && fwrite(feed, 1, sizeof feed, f) == sizeof feed); fclose(f); free(bytes);
        return 0;
    }
    if (argc == 3) {
        uint8_t b[SH_INPUT_COMMAND_SIZE + 1]; struct sh_input_command c;
        FILE *f = fopen(argv[2], "rb"); assert(f);
        size_t n = fread(b, 1, sizeof b, f); fclose(f);
        assert(sh_input_command_parse(b, n, &c));
        assert(sh_input_service_accept(&s, &c) == SH_INPUT_OK && c.sequence == 17);
        return 0;
    }
    s.state = SH_INPUT_ACTIVATION_REQUESTED;
    s.workshop = 123; strcpy(s.selection, "AC-480-controller_ps5");
    uint8_t b[SH_INPUT_FEED_CAP]; size_t n = sh_input_service_feed(&s, b, sizeof b);
    FILE *f = fopen(argv[1], "wb"); assert(f && fwrite(b, 1, n, f) == n); fclose(f);
    struct sh_input_context context = {0}; uint8_t actual[0x58] = {0};
    actual[4] = 0x4c; actual[5] = 5; actual[6] = 0xe6; actual[7] = 0x0c;
    actual[9] = 0x18; actual[0x34] = 45; actual[0x40] = 1;
    assert(sh_input_context_details(actual, sizeof actual, &context));
    context.flags |= 2; strcpy(context.manifest, "C:\\steamapps\\common\\fixture\\actions.vdf");
    uint8_t source[SH_INPUT_CONTEXT_CAP]; n = sh_input_context_feed(&s, &context, source, sizeof source); assert(n);
    char path[1024]; assert(snprintf(path, sizeof path, "%s.context", argv[1]) < (int)sizeof path);
    f = fopen(path, "wb"); assert(f && fwrite(source, 1, n, f) == n); fclose(f);
}
'''
cases = r'''
let testRoot = URL(fileURLWithPath: CommandLine.arguments[1])
var serviceTimeOffset: TimeInterval = 0
func serviceNow() -> Date { Date().addingTimeInterval(serviceTimeOffset) }
enum MadeiraDock {
    static var drive: URL { testRoot.appendingPathComponent("drive") }
    static var clientRoot: URL { testRoot.appendingPathComponent("client") }
}
enum SteamLog { static func event(_ text: String) {} }
func require(_ test: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) { precondition(try! test(), file: file, line: line) }
func require(_ test: @autoclosure () throws -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) { precondition(try! test(), message, file: file, line: line) }
func put32(_ data: inout Data, _ at: Int, _ value: UInt32) {
    for i in 0..<4 { data[at+i] = UInt8(truncatingIfNeeded: value >> (8*i)) }
}
@MainActor func checks() async throws {
    let fixture = try Data(contentsOf: testRoot.appendingPathComponent("fixture.bin"))
    let parsed = DockSteamInputWire.parse(fixture)!
    require(parsed.appID == 480 && parsed.epoch == 1 && parsed.workshopID == 123)
    require(parsed.state == .activationRequested && parsed.flags == 3 && parsed.forwardedInputs == 15)
    require(parsed.selection == "AC-480-controller_ps5")
    let contextBytes = try Data(contentsOf: testRoot.appendingPathComponent("fixture.bin.context"))
    let context = DockSteamInputContext.parse(contextBytes, session: parsed.session, appID: 480, epoch: 1)!
    require(context.isDualSense && context.capabilities == 0x1800 && context.rawType == 45)
    require(context.manifestPath == "C:\\steamapps\\common\\fixture\\actions.vdf")
    for size in 0..<contextBytes.count {
        require(DockSteamInputContext.parse(contextBytes.prefix(size), session: parsed.session, appID: 480, epoch: 1) == nil)
    }
    require(DockSteamInputContext.parse(contextBytes, session: parsed.session, appID: 481, epoch: 1) == nil)
    require(DockSteamInputContext.parse(contextBytes, session: parsed.session, appID: 480, epoch: 2) == nil)
    require(DockSteamInputContext.parse(contextBytes, session: Array(repeating: 1, count: 16), appID: 480, epoch: 1) == nil)
    require(DockSteamInputContext.parse(contextBytes + Data([0]), session: parsed.session, appID: 480, epoch: 1) == nil)
    var failedLookup = Data(contextBytes.prefix(56)); put32(&failedLookup, 32, 1); put32(&failedLookup, 52, 0)
    require(DockSteamInputContext.parse(failedLookup, session: parsed.session, appID: 480, epoch: 1) == nil)
    var hostileContext = contextBytes; put32(&hostileContext, 52, UInt32.max)
    require(DockSteamInputContext.parse(hostileContext, session: parsed.session, appID: 480, epoch: 1) == nil)
    let noSession = DockSteamInputPresentation.lines(appID: 481, snapshot: parsed, active: nil, selection: nil)
    require(noSession == ["Launch this game to see its Steam Input status."])
    var statusFeed = fixture; put32(&statusFeed, 40, 1)
    let statusSnapshot = DockSteamInputWire.parse(statusFeed)!
    let pendingStatus = DockSteamInputPresentation.lines(appID: 480, snapshot: statusSnapshot, active: nil, selection: nil)
    require(pendingStatus.contains("No active layout is confirmed for this session."))
    require(pendingStatus.contains("Steam selection: Workshop item 123."))
    let activeDefault = DockSteamInputSelection.Revision(source: .gameDefault, identity: nil, contentHash: String(repeating: "a", count: 64))
    let defaultStatus = DockSteamInputPresentation.lines(appID: 480, snapshot: statusSnapshot, active: activeDefault, selection: nil)
    require(defaultStatus.contains("Active: Game default.") && defaultStatus.contains("Default override: none."))
    var requested = DockSteamInputSelection(accountID: 7, appID: 480, controllerID: UUID())
    try requested.request(.init(source: .template, identity: "template.vdf", contentHash: nil))
    let changeStatus = DockSteamInputPresentation.lines(appID: 480, snapshot: statusSnapshot, active: activeDefault, selection: requested)
    require(changeStatus.contains("Requested: Generic template; not yet confirmed."))
    put32(&statusFeed, 44, 5)
    let failedSnapshot = DockSteamInputWire.parse(statusFeed)!
    let failedStatus = DockSteamInputPresentation.lines(appID: 480, snapshot: failedSnapshot, active: activeDefault, selection: requested)
    require(failedStatus.contains("The layout is unavailable; no active layout is confirmed."))
    require(!failedStatus.contains("Active: Game default."))
    // The reset is offered only for a resolved recommendation; the generic template
    // only when none was resolved, and never as the game's own layout.
    let layoutBytes = Data("controller_mappings { revision 3 }".utf8)
    let recommendation = DockSteamInputDefault.Recommendation(source: layoutBytes, origin: .actionManifest)
    let resolved = DockSteamInputDefault.Resolution.recommended(recommendation)
    require(DockSteamInputPresentation.defaultActions(nil, active: nil) == .init(note: "Checking this game's recommended layout."))
    let offerDefault = DockSteamInputPresentation.defaultActions(resolved, active: nil)
    require(offerDefault.offerDefault && !offerDefault.offerGeneric)
    let sameDefault = DockSteamInputSelection.Revision(source: .gameDefault, identity: nil, contentHash: DockSteamInputNative.contentHash(layoutBytes))
    let alreadyDefault = DockSteamInputPresentation.defaultActions(resolved, active: sameDefault)
    require(!alreadyDefault.offerDefault && alreadyDefault.note.hasSuffix("It is active."))
    let staleDefault = DockSteamInputSelection.Revision(source: .gameDefault, identity: nil, contentHash: String(repeating: "b", count: 64))
    require(DockSteamInputPresentation.defaultActions(resolved, active: staleDefault).offerDefault)
    let override = DockSteamInputSelection.Revision(source: .personal, identity: "custom", contentHash: String(repeating: "c", count: 64))
    let overridden = DockSteamInputPresentation.defaultActions(resolved, active: override)
    require(overridden.offerDefault && overridden.note.hasSuffix("Another layout is active."))
    for fallback in [DockSteamInputDefault.Resolution.noRecommendation, .unresolved(.workshopIncompatible)] {
        let actions = DockSteamInputPresentation.defaultActions(fallback, active: nil)
        require(!actions.offerDefault && actions.offerGeneric && actions.note.contains("not this game's own layout"))
        require(!actions.note.hasPrefix("Game default:"))
    }
    for failure in [DockSteamInputDefault.Resolution.noHint, .unresolved(.dataUnavailable), .unresolved(.manifestUnreadable), .unresolved(.workshopUnavailable)] {
        let actions = DockSteamInputPresentation.defaultActions(failure, active: nil)
        require(actions.offerRetry && !actions.offerDefault && !actions.offerGeneric)
    }
    let generic = DockSteamInputSelection.Revision(source: .template, identity: DockSteamInputDefault.genericTemplate, contentHash: nil)
    require(!DockSteamInputPresentation.defaultActions(.noHint, active: generic).offerGeneric)
    let command = DockSteamInputWire.command(.query, snapshot: parsed, sequence: 17)!
    try command.write(to: testRoot.appendingPathComponent("command.bin"))
    require(command.count == 44 && command[36] == 17 && command[40] == 1)
    for size in 0..<fixture.count { require(DockSteamInputWire.parse(fixture.prefix(size)) == nil) }
    require(DockSteamInputWire.parse(fixture + Data([0])) == nil)
    for offset in [0, 28, 40, 44, 48, 53, 64, 68, 72] {
        var damaged = fixture; damaged[offset] = 0xff
        require(DockSteamInputWire.parse(damaged) == nil)
    }
    let fm = FileManager.default
    try fm.createDirectory(at: MadeiraDock.drive, withIntermediateDirectories: true)
    let storage = testRoot.appendingPathComponent("support/MadeiraDock")
    var original = DockSteamInputSelection(accountID: 7, appID: 480, controllerID: DockSteamInputService.controllerID)
    try original.request(.init(source: .personal, identity: UUID().uuidString, contentHash: String(repeating: "a", count: 64)))
    try original.save(in: storage)
    DockSteamInputService.begin(accountID: 7, appID: 480)
    let hex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var feed = fixture
    for i in 0..<16 {
        let start = hex.index(hex.startIndex, offsetBy: i*2)
        feed[8+i] = UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
    let feedFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input.bin")
    let commandFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-cmd.bin")
    // A feed from another launch cannot trigger a query or migration.
    try fixture.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.snapshot == nil && !fm.fileExists(atPath: commandFile.path))
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    let query = try Data(contentsOf: commandFile)
    require(query.count == 44 && query[36] == 1 && query[32] == 1)
    try fm.removeItem(at: commandFile)
    put32(&feed, 36, 1); put32(&feed, 40, 1)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    let saved = try DockSteamInputSelection.load(in: storage, accountID: 7, appID: 480, controllerID: DockSteamInputService.controllerID)
    require(saved.requested == original.requested && saved.lastActivated == nil)
    require(saved.observedSteamSelection?.key == parsed.selection && saved.observedSteamSelection?.workshopID == 123)
    require(!fm.fileExists(atPath: commandFile.path))
    // Explicit local preparation persists exact source identity but sends no
    // mutation and cannot promote the request to last-activated.
    let localBytes = Data("controller_mappings { revision 7 unknown { binding value } }".utf8)
    let work = try DockSteamInputService.prepareLocal(source: localBytes, baseline: localBytes,
        choice: .init(source: .template, identity: "synthetic.vdf", contentHash: nil))
    require(work.phase == .prepared && work.content != nil)
    require(DockSteamInputService.selection?.requested?.contentHash == DockSteamInputNative.contentHash(localBytes))
    require(DockSteamInputService.selection?.lastActivated == nil)
    require(!fm.fileExists(atPath: commandFile.path))
    do { _ = try DockSteamInputService.prepareLocal(source: localBytes, baseline: localBytes,
        choice: .init(source: .template, identity: "synthetic.vdf", contentHash: nil)); fatalError("overlapping preparation") }
    catch DockSteamInputJournal.Failure.busy {}
    do { try DockSteamInputService.submitPrepared(); fatalError("host capability was not required") }
    catch DockSteamInputJournal.Failure.busy {}
    put32(&feed, 52, 19)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    try DockSteamInputService.submitPrepared()
    let payloadFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-apply.bin")
    let receiptFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-tx.bin")
    require(fm.fileExists(atPath: payloadFile.path))
    let applyCommand = try Data(contentsOf: commandFile)
    require(applyCommand[36] == 2 && applyCommand[40] == 3)
    try fm.removeItem(at: commandFile)
    put32(&feed, 36, 2); put32(&feed, 40, 1); put32(&feed, 44, 6)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.selection?.lastActivated == nil) // accepted/cache state alone cannot ACK
    let host = Process(); host.executableURL = testRoot.appendingPathComponent("fixture")
    host.arguments = ["receipt", payloadFile.path, receiptFile.path]
    try host.run(); host.waitUntilExit(); require(host.terminationStatus == 0)
    let validReceipt = try Data(contentsOf: receiptFile)
    for offset in [8, 24, 32, 36, 48, 60] {
        var wrong = validReceipt; wrong[offset] ^= 1
        try wrong.write(to: receiptFile); DockSteamInputService.refresh()
        require(DockSteamInputService.selection?.lastActivated == nil)
    }
    try validReceipt.write(to: receiptFile); DockSteamInputService.refresh()
    require(DockSteamInputService.selection?.lastActivated?.contentHash == work.content?.sourceHash)
    require(DockSteamInputService.prepared == nil)
    let persisted = try DockSteamInputSelection.load(in: storage, accountID: 7, appID: 480, controllerID: DockSteamInputService.controllerID)
    require(persisted.lastActivated == persisted.requested && !DockSteamInputService.inputQuiesced)
    var quiescedLog: [Bool] = []
    DockSteamInputService.onInputQuiescedChanged = { quiescedLog.append($0) }
    _ = try DockSteamInputService.prepareLocal(source: localBytes, baseline: localBytes,
        choice: .init(source: .template, identity: "next.vdf", contentHash: nil))
    require(DockSteamInputService.inputQuiesced && quiescedLog == [true])
    // Reconnect creates a new lease, invalidating the previous reply and any
    // staged layout prepared from the previous connection's baseline.

    put32(&feed, 32, 3)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    let requery = try Data(contentsOf: commandFile)
    require(requery[36] == 3 && requery[32] == 3)
    require(DockSteamInputService.prepared == nil && !DockSteamInputService.inputQuiesced && quiescedLog == [true, false])
    require(DockSteamInputService.recovery?.phase == .interrupted)
    // Once the new epoch settles and exports a fresh baseline, same-session
    // recovery retires the interrupted work and reapplies the last CONFIRMED
    // choice while preserving the newer unconfirmed request.
    try fm.removeItem(at: commandFile)
    let baselineFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-baseline.bin")
    let freshBaseline = Data("controller_mappings { revision 0 native default }".utf8)
    func baselineFrame(_ scope: Data, source: Data? = nil) -> Data {
        let content = source ?? freshBaseline
        var bytes = Data("MSIBAS02".utf8); bytes.append(scope[8..<36]); bytes.append(Data(repeating: 0, count: 8))
        put32(&bytes, 36, try! DockSteamInputNative.revision(content)); put32(&bytes, 40, UInt32(content.count)); bytes.append(content)
        return bytes
    }
    put32(&feed, 36, 3); put32(&feed, 40, 1); put32(&feed, 52, 51)
    try baselineFrame(feed).write(to: baselineFile)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.recovery == nil && DockSteamInputService.inputQuiesced)
    let reconnectCommand = try Data(contentsOf: commandFile)
    require(reconnectCommand[40] == 3 && reconnectCommand[36] == 4 && reconnectCommand[32] == 3)
    let reconnectHost = Process(); reconnectHost.executableURL = testRoot.appendingPathComponent("fixture")
    reconnectHost.arguments = ["receipt", payloadFile.path, receiptFile.path]
    try reconnectHost.run(); reconnectHost.waitUntilExit(); require(reconnectHost.terminationStatus == 0)
    try fm.removeItem(at: commandFile)
    put32(&feed, 36, 4); put32(&feed, 44, 6)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    require(!DockSteamInputService.inputQuiesced && DockSteamInputService.activeChoice?.identity == "synthetic.vdf")
    require(DockSteamInputService.selection?.requested?.identity == "next.vdf")
    // Prepare another unconfirmed change and interrupt it across launch end.
    _ = try DockSteamInputService.prepareLocal(source: localBytes, baseline: localBytes,
        choice: .init(source: .template, identity: "next.vdf", contentHash: nil))
    DockSteamInputService.onInputQuiescedChanged = nil
    DockSteamInputService.end()
    require(getenv("MADEIRA_DOCK_INPUT_SESSION") == nil)
    require(!fm.fileExists(atPath: feedFile.path) && !fm.fileExists(atPath: commandFile.path))
    // Fresh-launch recovery reapplies the last CONFIRMED choice, retaining a
    // newer unconfirmed request and using the freshly exported native baseline.
    let historical = try DockSteamInputSelection.load(in: storage, accountID: 7, appID: 480, controllerID: DockSteamInputService.controllerID)
    require(historical.lastActivated?.identity == "synthetic.vdf" && historical.requested?.identity == "next.vdf")
    DockSteamInputService.begin(accountID: 7, appID: 480)
    let restartHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var freshFeed = fixture
    for i in 0..<16 {
        let start = restartHex.index(restartHex.startIndex, offsetBy: i*2)
        freshFeed[8+i] = UInt8(restartHex[start..<restartHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&freshFeed, 36, 0); put32(&freshFeed, 40, 0); put32(&freshFeed, 52, 51)
    try freshFeed.write(to: feedFile); DockSteamInputService.refresh()
    try fm.removeItem(at: commandFile)
    put32(&freshFeed, 36, 1); put32(&freshFeed, 40, 1)
    try baselineFrame(feed).write(to: baselineFile) // previous launch nonce
    try freshFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(!fm.fileExists(atPath: commandFile.path) && DockSteamInputService.activeChoice == nil)
    try baselineFrame(freshFeed).write(to: baselineFile); DockSteamInputService.refresh()
    require(DockSteamInputService.recovery == nil)
    let resumed = DockSteamInputService.prepared!
    require(DockSteamInputService.selection == historical) // no request replacement or generation increment
    require(DockSteamInputService.activeChoice == nil) // historical ACK is not a current-launch ACK
    let resumedCommand = try Data(contentsOf: commandFile)
    require(resumedCommand[40] == 3 && resumedCommand[36] == 2)
    let restartJournal = try DockSteamInputJournal(root: storage,
        scope: .init(accountID: 7, appID: 480, controllerID: DockSteamInputService.controllerID))
    require(try restartJournal.content(resumed.content!.sourceHash) == localBytes)
    let expectedRollback = try DockSteamInputNative.materialize(freshBaseline, revision: resumed.reservation.rollbackRevision)
    require(try restartJournal.content(resumed.content!.rollbackHash) == expectedRollback)
    let restoredHost = Process(); restoredHost.executableURL = testRoot.appendingPathComponent("fixture")
    restoredHost.arguments = ["receipt", payloadFile.path, receiptFile.path]
    try restoredHost.run(); restoredHost.waitUntilExit(); require(restoredHost.terminationStatus == 0)
    try fm.removeItem(at: commandFile)
    put32(&freshFeed, 36, 2); put32(&freshFeed, 44, 6)
    try freshFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.activeChoice == historical.lastActivated)
    require(DockSteamInputService.selection == historical && DockSteamInputService.prepared == nil)
    DockSteamInputService.refresh()
    require(!fm.fileExists(atPath: commandFile.path)) // once per launch
    DockSteamInputService.end()
    // A generic template selected by Dock is not a pre-existing Steam choice.
    DockSteamInputService.begin(accountID: 9, appID: 480)
    let fallbackHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    for i in 0..<16 {
        let start = fallbackHex.index(fallbackHex.startIndex, offsetBy: i*2)
        feed[8+i] = UInt8(fallbackHex[start..<fallbackHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&feed, 36, 0); put32(&feed, 40, 0); put32(&feed, 52, 11)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    put32(&feed, 36, 1); put32(&feed, 40, 1)
    try feed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.selection?.observedSteamSelection == nil)
    DockSteamInputService.end()
    // A launch detects unfinished local work, marks it interrupted and never
    // turns it into an active selection or sends an apply command.
    let journal = try DockSteamInputJournal(root: storage,
        scope: .init(accountID: 8, appID: 480, controllerID: DockSteamInputService.controllerID))
    let reservation = try journal.reserve(sourceFloor: 0)
    DockSteamInputService.begin(accountID: 8, appID: 480)
    require(DockSteamInputService.recovery?.reservation == reservation)
    require(DockSteamInputService.recovery?.phase == .interrupted)
    require(!fm.fileExists(atPath: commandFile.path))
    DockSteamInputService.end()
    require(try journal.snapshot().pending?.phase == .interrupted)
    // A new account starts with no observed choice; malformed storage is kept.
    DockSteamInputService.begin(accountID: 8, appID: 480)
    require(DockSteamInputService.selection?.requested == nil)
    DockSteamInputService.end()
    let files = try fm.contentsOfDirectory(at: storage.appendingPathComponent("steam-input-selections"), includingPropertiesForKeys: nil)
    let broken = Data("invalid schema".utf8)
    try broken.write(to: files[0])
    DockSteamInputService.begin(accountID: 7, appID: 480)
    require(DockSteamInputService.selection == nil)
    require(try Data(contentsOf: files[0]) == broken)
    DockSteamInputService.end()
    // Exercise the Debug-only mailbox through the same real app methods used
    // for device persistence/restart testing, including safe override cleanup.
    let fixturePath = MadeiraDock.clientRoot.appendingPathComponent("controller_base/templates/madeira_m1_revision_probe.vdf")
    try fm.createDirectory(at: fixturePath.deletingLastPathComponent(), withIntermediateDirectories: true)
    let diagnosticSource = Data("controller_mappings { revision 731 binding swapped }".utf8)
    try diagnosticSource.write(to: fixturePath)
    func diagnosticLaunch(nativeBaseline: Data? = nil) throws -> Data {
        DockSteamInputService.begin(accountID: 12, appID: 480)
        let nonce = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
        var fresh = fixture
        for i in 0..<16 {
            let start = nonce.index(nonce.startIndex, offsetBy: i*2)
            fresh[8+i] = UInt8(nonce[start..<nonce.index(start, offsetBy: 2)], radix: 16)!
        }
        put32(&fresh, 36, 0); put32(&fresh, 40, 0); put32(&fresh, 52, 51)
        try fresh.write(to: feedFile); DockSteamInputService.refresh()
        try fm.removeItem(at: commandFile)
        put32(&fresh, 36, 1); put32(&fresh, 40, 1)
        try baselineFrame(fresh, source: nativeBaseline).write(to: baselineFile)
        try fresh.write(to: feedFile); DockSteamInputService.refresh()
        return fresh
    }
    func acknowledgeDiagnostic(_ scope: inout Data) throws {
        let applyCommand = try Data(contentsOf: commandFile)
        let seq = UInt32(applyCommand[36]) | UInt32(applyCommand[37]) << 8
        let native = Process(); native.executableURL = testRoot.appendingPathComponent("fixture")
        native.arguments = ["receipt", payloadFile.path, receiptFile.path]
        try native.run(); native.waitUntilExit(); require(native.terminationStatus == 0)
        try fm.removeItem(at: commandFile)
        put32(&scope, 36, seq); put32(&scope, 40, 1); put32(&scope, 44, 6)
        try scope.write(to: feedFile); DockSteamInputService.refresh()
    }
    var diagnosticFeed = try diagnosticLaunch()
    let marker = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-local-test.bin")
    let initialSnapshot = DockSteamInputWire.parse(diagnosticFeed)!
    try DockSteamInputWire.command(.query, snapshot: initialSnapshot, sequence: 1)!.write(to: marker)
    DockSteamInputService.refresh()
    require(DockSteamInputService.prepared?.content?.sourceHash == DockSteamInputNative.contentHash(diagnosticSource))
    try acknowledgeDiagnostic(&diagnosticFeed)
    require(DockSteamInputService.activeChoice?.identity == "madeira_m1_revision_probe.vdf")
    DockSteamInputService.end()
    diagnosticFeed = try diagnosticLaunch(nativeBaseline: Data("controller_mappings { revision 0 native changed }".utf8)) // confirmed override uses new native rollback baseline without losing original restoration source
    let autoWork = DockSteamInputService.prepared!
    try acknowledgeDiagnostic(&diagnosticFeed)
    let diagnosticJournal = try DockSteamInputJournal(root: storage,
        scope: .init(accountID: 12, appID: 480, controllerID: DockSteamInputService.controllerID))
    let activeBytes = try diagnosticJournal.content(autoWork.content!.applyHash)
    try baselineFrame(diagnosticFeed, source: activeBytes).write(to: baselineFile)
    // Action 3 stages a baseline-mismatched submission; host rejection preserves activeChoice and saved intent.
    let faultCmd = DockSteamInputWire.command(.apply, snapshot: DockSteamInputWire.parse(diagnosticFeed)!, sequence: 1)!
    try faultCmd.write(to: marker)
    DockSteamInputService.refresh()
    let rejectedApply = try Data(contentsOf: commandFile)
    let rejectedSeq = UInt32(rejectedApply[36]) | UInt32(rejectedApply[37]) << 8
    try fm.removeItem(at: commandFile)
    put32(&diagnosticFeed, 36, rejectedSeq); put32(&diagnosticFeed, 40, 4)
    try diagnosticFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.activeChoice?.identity == "madeira_m1_revision_probe.vdf")
    require(DockSteamInputService.selection?.requested?.identity == "madeira_m1_revision_probe.vdf")
    require(!DockSteamInputService.inputQuiesced)
    // Action 4 interrupts a staged local preparation and recovers on the next settled poll.
    put32(&diagnosticFeed, 40, 1); try diagnosticFeed.write(to: feedFile); DockSteamInputService.refresh()
    var interruptCmd = DockSteamInputWire.command(.query, snapshot: DockSteamInputWire.parse(diagnosticFeed)!, sequence: 2)!
    interruptCmd[40] = 4
    try interruptCmd.write(to: marker)
    DockSteamInputService.refresh()
    require(DockSteamInputService.recovery?.phase == .interrupted && !DockSteamInputService.inputQuiesced)
    DockSteamInputService.refresh()
    require(DockSteamInputService.recovery == nil && DockSteamInputService.prepared != nil)
    try acknowledgeDiagnostic(&diagnosticFeed)
    require(DockSteamInputService.activeChoice?.identity == "madeira_m1_revision_probe.vdf")
    try baselineFrame(diagnosticFeed, source: activeBytes).write(to: baselineFile)
    // Action 2 restores the original baseline without mutating requested before confirmation.
    try DockSteamInputWire.command(.sources, snapshot: DockSteamInputWire.parse(diagnosticFeed)!, sequence: 3)!.write(to: marker)
    DockSteamInputService.refresh()
    require(DockSteamInputService.selection?.requested?.identity == "madeira_m1_revision_probe.vdf")
    try acknowledgeDiagnostic(&diagnosticFeed)
    require(DockSteamInputService.selection?.requested == nil && DockSteamInputService.activeChoice == nil)
    require(DockSteamInputService.selection?.lastActivated?.contentHash == DockSteamInputNative.contentHash(freshBaseline))
    DockSteamInputService.end()
    diagnosticFeed = try diagnosticLaunch()
    require(!fm.fileExists(atPath: commandFile.path) && DockSteamInputService.activeChoice == nil)
    // Explicit game-default source uses the same durable journal and exact
    // receipt as other choices. Merely preparing or accepting cannot ACK it.
    let oldDefaultSelection = DockSteamInputService.selection!
    let defaultBytes = Data("controller_mappings { revision 21 binding recommended }".utf8)
    let defaultWork = try DockSteamInputService.prepareGameDefault(source: defaultBytes, baseline: freshBaseline)
    require(DockSteamInputService.selection?.requested?.source == .gameDefault)
    require(DockSteamInputService.selection?.lastActivated == oldDefaultSelection.lastActivated)
    try DockSteamInputService.submitPrepared()
    require(DockSteamInputService.selection?.lastActivated == oldDefaultSelection.lastActivated)
    try acknowledgeDiagnostic(&diagnosticFeed)
    let confirmedDefault = DockSteamInputService.selection!
    require(confirmedDefault.lastActivated == confirmedDefault.requested && confirmedDefault.lastActivated?.source == .gameDefault)
    require(confirmedDefault.lastActivated?.contentHash == DockSteamInputNative.contentHash(defaultBytes))
    require(confirmedDefault.observedSteamSelection == oldDefaultSelection.observedSteamSelection)
    require(try DockSteamInputSelection.load(in: storage, accountID: 12, appID: 480, controllerID: DockSteamInputService.controllerID) == confirmedDefault)
    let currentDefaultQueue = try diagnosticJournal.content(defaultWork.content!.applyHash)
    let laterDefault = Data("controller_mappings { revision 22 binding newer }".utf8)
    _ = try DockSteamInputService.prepareGameDefault(source: laterDefault, baseline: currentDefaultQueue)
    try DockSteamInputService.submitPrepared()
    let rejectedDefault = try Data(contentsOf: commandFile)
    try fm.removeItem(at: commandFile)
    put32(&diagnosticFeed, 36, UInt32(rejectedDefault[36])); put32(&diagnosticFeed, 40, 6)
    try diagnosticFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.selection?.lastActivated == confirmedDefault.lastActivated)
    require(DockSteamInputService.activeChoice == confirmedDefault.lastActivated)
    require(DockSteamInputService.selection?.requested?.contentHash == DockSteamInputNative.contentHash(laterDefault))
    DockSteamInputService.end()
    diagnosticFeed = try diagnosticLaunch()
    let restartedDefault = DockSteamInputService.prepared!
    require(try diagnosticJournal.content(restartedDefault.content!.sourceHash) == defaultBytes)
    try acknowledgeDiagnostic(&diagnosticFeed)
    require(DockSteamInputService.activeChoice == confirmedDefault.lastActivated)
    require(DockSteamInputService.selection?.lastActivated == confirmedDefault.lastActivated)
    require(DockSteamInputService.selection?.requested?.contentHash == DockSteamInputNative.contentHash(laterDefault))
    DockSteamInputService.end()
    // An unavailable selection query is retried without migrating the stale
    // selection carried by the feed, and attempts remain bounded.
    DockSteamInputService.begin(accountID: 13, appID: 480)
    let retryHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var retryFeed = fixture
    for i in 0..<16 {
        let start = retryHex.index(retryHex.startIndex, offsetBy: i*2)
        retryFeed[8+i] = UInt8(retryHex[start..<retryHex.index(start, offsetBy: 2)], radix: 16)!
    }
    try retryFeed.write(to: feedFile); DockSteamInputService.refresh()
    for sequence in UInt32(1)...3 {
        let sent = try Data(contentsOf: commandFile)
        require(sent[36] == UInt8(sequence))
        try fm.removeItem(at: commandFile)
        put32(&retryFeed, 36, sequence); put32(&retryFeed, 40, 4)
        try retryFeed.write(to: feedFile); DockSteamInputService.refresh()
        require(DockSteamInputService.selection?.observedSteamSelection == nil)
    }
    require(!fm.fileExists(atPath: commandFile.path))
    DockSteamInputService.end()
    DockSteamInputService.begin(accountID: 14, appID: 480)
    let successHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    retryFeed = fixture
    for i in 0..<16 {
        let start = successHex.index(successHex.startIndex, offsetBy: i*2)
        retryFeed[8+i] = UInt8(successHex[start..<successHex.index(start, offsetBy: 2)], radix: 16)!
    }
    try retryFeed.write(to: feedFile); DockSteamInputService.refresh()
    try fm.removeItem(at: commandFile)
    put32(&retryFeed, 36, 1); put32(&retryFeed, 40, 4)
    try retryFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.selection?.observedSteamSelection == nil)
    require(try Data(contentsOf: commandFile)[36] == 2)
    try fm.removeItem(at: commandFile)
    put32(&retryFeed, 36, 2); put32(&retryFeed, 40, 1)
    try retryFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.selection?.observedSteamSelection?.workshopID == 123)
    require(!fm.fileExists(atPath: commandFile.path))
    DockSteamInputService.end()
    // A game Steam has no saved selection for: three failed queries leave nothing
    // loaded and no baseline. A chosen layout is handed to Dock (BOOTSTRAP) and,
    // once Dock publishes its baseline, recorded through the normal journal.
    DockSteamInputService.begin(accountID: 21, appID: 480)
    let bootHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var bootFeed = fixture
    for i in 0..<16 {
        let start = bootHex.index(bootHex.startIndex, offsetBy: i*2)
        bootFeed[8+i] = UInt8(bootHex[start..<bootHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&bootFeed, 36, 0); put32(&bootFeed, 40, 0); put32(&bootFeed, 44, 5); put32(&bootFeed, 52, 51)
    try bootFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(!DockSteamInputService.canBootstrap) // the query may still succeed
    for sequence in UInt32(1)...3 {
        require(try Data(contentsOf: commandFile)[36] == UInt8(sequence))
        try fm.removeItem(at: commandFile)
        put32(&bootFeed, 36, sequence); put32(&bootFeed, 40, 4)
        try bootFeed.write(to: feedFile); DockSteamInputService.refresh()
    }
    require(DockSteamInputService.canBootstrap && !DockSteamInputService.canChange)
    let initialSource = Data("controller_mappings { revision 69 title \"x\r\ny\" }".utf8)
    try DockSteamInputService.requestGameDefault(.init(source: initialSource, origin: .actionManifest))
    require(DockSteamInputService.bootstrapping && !DockSteamInputService.canBootstrap)
    do { try DockSteamInputService.requestGameDefault(.init(source: initialSource, origin: .actionManifest)); require(false) }
    catch {}
    DockSteamInputService.refresh()
    let bootCommand = try Data(contentsOf: commandFile)
    require(bootCommand[40] == 6 && bootCommand[36] == 4)
    let initialFile = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-initial.bin")
    let initialFrame = try Data(contentsOf: initialFile)
    require(initialFrame.prefix(8) == Data("MSIINI01".utf8) && initialFrame.suffix(initialSource.count) == initialSource)
    require(initialFrame.count == 44 + initialSource.count && initialFrame[36] == 69)
    // Dock refuses until its own retries are exhausted; the app waits and retries.
    try fm.removeItem(at: commandFile)
    put32(&bootFeed, 36, 4); put32(&bootFeed, 40, 4)
    try bootFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.bootstrapping && !fm.fileExists(atPath: commandFile.path)) // paced, not spammed
    // Dock accepts it (a later attempt): the layout is now loading.
    DockSteamInputService.bootstrapPace = 0
    DockSteamInputService.refresh()
    let retried = try Data(contentsOf: commandFile)
    require(retried[40] == 6 && retried[36] == 5)
    try fm.removeItem(at: commandFile)
    put32(&bootFeed, 36, 5); put32(&bootFeed, 40, 1); put32(&bootFeed, 44, 2)
    try bootFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.bootstrapping && !fm.fileExists(atPath: commandFile.path))
    require(DockSteamInputService.selection?.requested == nil) // nothing recorded before the baseline exists
    put32(&bootFeed, 44, 4)
    try bootFeed.write(to: feedFile)
    try baselineFrame(bootFeed, source: initialSource).write(to: baselineFile)
    DockSteamInputService.refresh()
    require(!DockSteamInputService.bootstrapping)
    require(DockSteamInputService.selection?.requested?.source == .gameDefault)
    let bootApply = try Data(contentsOf: commandFile)
    require(bootApply[40] == 3 && fm.fileExists(atPath: payloadFile.path))
    // Dock confirms the choice with its receipt: it is now the player's confirmed choice.
    let bootHost = Process(); bootHost.executableURL = testRoot.appendingPathComponent("fixture")
    bootHost.arguments = ["receipt", payloadFile.path, receiptFile.path]
    try bootHost.run(); bootHost.waitUntilExit(); require(bootHost.terminationStatus == 0)
    try fm.removeItem(at: commandFile)
    put32(&bootFeed, 36, UInt32(bootApply[36])); put32(&bootFeed, 40, 1); put32(&bootFeed, 44, 6)
    try bootFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.selection?.lastActivated?.source == .gameDefault)
    DockSteamInputService.end()
    require(!fm.fileExists(atPath: initialFile.path))
    // Relaunch of a game that still has no Steam selection: the player's own
    // confirmed choice (exact journal bytes) is handed to Dock automatically, and
    // once the baseline exists the ordinary restart path reapplies it.
    DockSteamInputService.begin(accountID: 21, appID: 480)
    let againHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var againFeed = fixture
    for i in 0..<16 {
        let start = againHex.index(againHex.startIndex, offsetBy: i*2)
        againFeed[8+i] = UInt8(againHex[start..<againHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&againFeed, 36, 0); put32(&againFeed, 40, 0); put32(&againFeed, 44, 5); put32(&againFeed, 52, 51)
    try againFeed.write(to: feedFile); DockSteamInputService.refresh()
    for sequence in UInt32(1)...3 {
        try fm.removeItem(at: commandFile)
        put32(&againFeed, 36, sequence); put32(&againFeed, 40, 4)
        try againFeed.write(to: feedFile); DockSteamInputService.refresh()
    }
    DockSteamInputService.bootstrapPace = 0
    DockSteamInputService.refresh()
    let autoCommand = try Data(contentsOf: commandFile)
    require(autoCommand[40] == 6 && DockSteamInputService.bootstrapping)
    let autoFrame = try Data(contentsOf: initialFile)
    require(autoFrame.prefix(8) == Data("MSIINI01".utf8) && autoFrame.count > 44)
    let autoSource = autoFrame.suffix(from: 44)
    try fm.removeItem(at: commandFile)
    put32(&againFeed, 36, autoCommand[36] == 0 ? 1 : UInt32(autoCommand[36])); put32(&againFeed, 40, 1); put32(&againFeed, 44, 2)
    try againFeed.write(to: feedFile); DockSteamInputService.refresh()
    put32(&againFeed, 44, 4)
    try againFeed.write(to: feedFile)
    try baselineFrame(againFeed, source: Data(autoSource)).write(to: baselineFile)
    DockSteamInputService.refresh()
    require(!DockSteamInputService.bootstrapping)
    require(DockSteamInputService.prepared != nil || fm.fileExists(atPath: commandFile.path)) // reapplication started
    DockSteamInputService.end() // the game is quit before that reapplication's receipt
    // That interrupted work must not lock a game with no Steam selection out of
    // its only route to a baseline. The bootstrap provides a fresh native
    // baseline for this launch; the old work is then retired, never replayed.
    DockSteamInputService.begin(accountID: 21, appID: 480)
    require(DockSteamInputService.recovery?.phase == .interrupted)
    let stuckHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var stuckFeed = fixture
    for i in 0..<16 {
        let start = stuckHex.index(stuckHex.startIndex, offsetBy: i*2)
        stuckFeed[8+i] = UInt8(stuckHex[start..<stuckHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&stuckFeed, 36, 0); put32(&stuckFeed, 40, 0); put32(&stuckFeed, 44, 5); put32(&stuckFeed, 52, 51)
    try stuckFeed.write(to: feedFile); DockSteamInputService.refresh()
    for sequence in UInt32(1)...3 {
        try? fm.removeItem(at: commandFile)
        put32(&stuckFeed, 36, sequence); put32(&stuckFeed, 40, 4)
        try stuckFeed.write(to: feedFile); DockSteamInputService.refresh()
    }
    DockSteamInputService.refresh()
    let stuckCommand = try Data(contentsOf: commandFile)
    require(stuckCommand[40] == 6 && DockSteamInputService.bootstrapping)
    require(DockSteamInputService.recovery != nil) // nothing retired before the baseline exists
    let stuckSource = try Data(contentsOf: initialFile).suffix(from: 44)
    try fm.removeItem(at: commandFile)
    put32(&stuckFeed, 36, UInt32(stuckCommand[36])); put32(&stuckFeed, 40, 1); put32(&stuckFeed, 44, 2)
    try stuckFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.recovery != nil && DockSteamInputService.bootstrapping)
    put32(&stuckFeed, 44, 4)
    try stuckFeed.write(to: feedFile)
    try baselineFrame(stuckFeed, source: Data(stuckSource)).write(to: baselineFile)
    DockSteamInputService.refresh()
    require(DockSteamInputService.recovery == nil && !DockSteamInputService.bootstrapping)
    let stuckApply = try Data(contentsOf: commandFile)
    require(stuckApply[40] == 3) // the confirmed choice is reapplied with fresh revisions
    // A query that succeeds but names neither a layout nor a Workshop item also
    // means Steam has no saved selection; a named one never does.
    DockSteamInputService.end()
    DockSteamInputService.begin(accountID: 22, appID: 480)
    let emptyHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var emptyFeed = Data(fixture.prefix(72))
    for i in 0..<16 {
        let start = emptyHex.index(emptyHex.startIndex, offsetBy: i*2)
        emptyFeed[8+i] = UInt8(emptyHex[start..<emptyHex.index(start, offsetBy: 2)], radix: 16)!
    }
    for i in 56..<64 { emptyFeed[i] = 0 }
    put32(&emptyFeed, 68, 0)
    put32(&emptyFeed, 36, 0); put32(&emptyFeed, 40, 0); put32(&emptyFeed, 44, 5); put32(&emptyFeed, 52, 51)
    try emptyFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(!DockSteamInputService.canBootstrap)
    try fm.removeItem(at: commandFile)
    put32(&emptyFeed, 36, 1); put32(&emptyFeed, 40, 1)
    try emptyFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.canBootstrap && !fm.fileExists(atPath: commandFile.path)) // one query is enough
    DockSteamInputService.end()
    DockSteamInputService.begin(accountID: 23, appID: 480)
    let namedHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var namedFeed = fixture
    for i in 0..<16 {
        let start = namedHex.index(namedHex.startIndex, offsetBy: i*2)
        namedFeed[8+i] = UInt8(namedHex[start..<namedHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&namedFeed, 36, 0); put32(&namedFeed, 40, 0); put32(&namedFeed, 44, 5); put32(&namedFeed, 52, 51)
    try namedFeed.write(to: feedFile); DockSteamInputService.refresh()
    try fm.removeItem(at: commandFile)
    put32(&namedFeed, 36, 1); put32(&namedFeed, 40, 1)
    try namedFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(!DockSteamInputService.canBootstrap)
    // Source context does not authorize replacing an unreadable named layout.
    put32(&namedFeed, 52, 115)
    try namedFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(!DockSteamInputService.canBootstrap)
    let beforeDefault = DockSteamInputService.selection!
    do {
        try DockSteamInputService.requestGameDefault(.init(source: initialSource, origin: .steamTemplate))
        fatalError("unreadable named layout was replaced")
    } catch DockSteamInputJournal.Failure.busy {}
    require(DockSteamInputService.selection == beforeDefault && DockSteamInputService.activeChoice == nil)
    DockSteamInputService.end()
    // An explicit community source uses the same real journal and C receipt.
    DockSteamInputService.begin(accountID: 24, appID: 480)
    let communityHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var communityFeed = fixture
    for i in 0..<16 {
        let start = communityHex.index(communityHex.startIndex, offsetBy: i*2)
        communityFeed[8+i] = UInt8(communityHex[start..<communityHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&communityFeed, 36, 0); put32(&communityFeed, 40, 0); put32(&communityFeed, 52, 179)
    try communityFeed.write(to: feedFile); DockSteamInputService.refresh()
    try fm.removeItem(at: commandFile)
    put32(&communityFeed, 36, 1); put32(&communityFeed, 40, 1)
    try baselineFrame(communityFeed).write(to: baselineFile)
    try communityFeed.write(to: feedFile); DockSteamInputService.refresh()
    let beforeCommunity = DockSteamInputService.selection
    do {
        try DockSteamInputService.requestCommunity(appID: 481, source: initialSource, itemID: 123, detail: "Fixture · Workshop 123")
        fatalError("community selection crossed game scope")
    } catch DockSteamInputJournal.Failure.invalid {}
    require(DockSteamInputService.selection == beforeCommunity)
    try DockSteamInputService.requestCommunity(appID: 480, source: initialSource, itemID: 123, detail: "Fixture · Workshop 123")
    require(DockSteamInputService.selection?.requested?.source == .community && DockSteamInputService.activeChoice == nil)
    let communityHost = Process(); communityHost.executableURL = testRoot.appendingPathComponent("fixture")
    communityHost.arguments = ["receipt", payloadFile.path, receiptFile.path]
    try communityHost.run(); communityHost.waitUntilExit(); require(communityHost.terminationStatus == 0)
    try fm.removeItem(at: commandFile)
    put32(&communityFeed, 36, 2); put32(&communityFeed, 44, 6)
    try communityFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.activeChoice?.source == .community && DockSteamInputService.activeChoice?.identity == "123")
    require(DockSteamInputService.activeChoice?.detail == "Fixture · Workshop 123")
    require(DockSteamInputService.selection?.lastActivated == DockSteamInputService.activeChoice)
    let communitySelection = DockSteamInputService.selection!
    DockSteamInputService.end()
    require(try DockSteamInputSelection.load(in: storage, accountID: 24, appID: 480,
        controllerID: DockSteamInputService.controllerID) == communitySelection)
    // A fresh launch reapplies the confirmed community bytes with attribution
    // and a new revision, using the newly scoped native rollback baseline.
    DockSteamInputService.begin(accountID: 24, appID: 480)
    let communityRestartHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    for i in 0..<16 {
        let start = communityRestartHex.index(communityRestartHex.startIndex, offsetBy: i*2)
        communityFeed[8+i] = UInt8(communityRestartHex[start..<communityRestartHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&communityFeed, 36, 0); put32(&communityFeed, 40, 0)
    try communityFeed.write(to: feedFile); DockSteamInputService.refresh()
    try fm.removeItem(at: commandFile)
    put32(&communityFeed, 36, 1); put32(&communityFeed, 40, 1)
    try baselineFrame(communityFeed).write(to: baselineFile)
    try communityFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.prepared != nil && DockSteamInputService.selection == communitySelection)
    let restartCommunityHost = Process(); restartCommunityHost.executableURL = testRoot.appendingPathComponent("fixture")
    restartCommunityHost.arguments = ["receipt", payloadFile.path, receiptFile.path]
    try restartCommunityHost.run(); restartCommunityHost.waitUntilExit(); require(restartCommunityHost.terminationStatus == 0)
    try fm.removeItem(at: commandFile)
    put32(&communityFeed, 36, 2)
    try communityFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.activeChoice == communitySelection.lastActivated)
    DockSteamInputService.end()
    // A slow selected-Workshop lookup must not exhaust confirmed-choice replay.
    var lookup: CheckedContinuation<Data, Error>?
    DockSteamInputService.resolveSelectedWorkshop = { _, _ in
        try await withCheckedThrowingContinuation { lookup = $0 }
    }
    DockSteamInputService.begin(accountID: 24, appID: 480)
    let slowHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var slowFeed = fixture
    for i in 0..<16 {
        let start = slowHex.index(slowHex.startIndex, offsetBy: i*2)
        slowFeed[8+i] = UInt8(slowHex[start..<slowHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&slowFeed, 36, 0); put32(&slowFeed, 40, 0); put32(&slowFeed, 44, 5); put32(&slowFeed, 52, 179)
    try slowFeed.write(to: feedFile); DockSteamInputService.refresh()
    try fm.removeItem(at: commandFile)
    put32(&slowFeed, 36, 1); put32(&slowFeed, 40, 1)
    try slowFeed.write(to: feedFile); DockSteamInputService.refresh()
    for _ in 0..<10 { await Task.yield() }
    require(lookup != nil && DockSteamInputService.resolvingWorkshop)
    serviceTimeOffset = 31
    DockSteamInputService.refresh()
    lookup!.resume(returning: initialSource)
    for _ in 0..<10 { await Task.yield() }
    DockSteamInputService.refresh()
    require(try Data(contentsOf: commandFile)[40] == 7)
    try fm.removeItem(at: commandFile)
    put32(&slowFeed, 36, 2)
    try slowFeed.write(to: feedFile); DockSteamInputService.refresh()
    put32(&slowFeed, 44, 4)
    try baselineFrame(slowFeed).write(to: baselineFile)
    try slowFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.prepared != nil && DockSteamInputService.selection == communitySelection)
    let slowHost = Process(); slowHost.executableURL = testRoot.appendingPathComponent("fixture")
    slowHost.arguments = ["receipt", payloadFile.path, receiptFile.path]
    try slowHost.run(); slowHost.waitUntilExit(); require(slowHost.terminationStatus == 0)
    let replayCommand = try Data(contentsOf: commandFile)
    try fm.removeItem(at: commandFile)
    put32(&slowFeed, 36, UInt32(replayCommand[36])); put32(&slowFeed, 44, 6)
    try slowFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.activeChoice == communitySelection.lastActivated)
    DockSteamInputService.end(); serviceTimeOffset = 0
    print("PASS: delayed selected-Workshop lookup preserves confirmed-choice replay")
    // Saved-Workshop recovery is asynchronous, lease-scoped and read-only with
    // respect to explicit intent. It cannot bootstrap a different layout.
    var resolvedIDs: [UInt64] = []
    DockSteamInputService.resolveSelectedWorkshop = { appID, id in
        require(appID == 480); resolvedIDs.append(id); return initialSource
    }
    DockSteamInputService.begin(accountID: 25, appID: 480)
    let workshopHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var workshopFeed = fixture
    for i in 0..<16 {
        let start = workshopHex.index(workshopHex.startIndex, offsetBy: i*2)
        workshopFeed[8+i] = UInt8(workshopHex[start..<workshopHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&workshopFeed, 36, 0); put32(&workshopFeed, 40, 0); put32(&workshopFeed, 44, 5); put32(&workshopFeed, 52, 179)
    try workshopFeed.write(to: feedFile); DockSteamInputService.refresh()
    try fm.removeItem(at: commandFile)
    put32(&workshopFeed, 36, 1); put32(&workshopFeed, 40, 1)
    try workshopFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.resolvingWorkshop && !DockSteamInputService.canBootstrap)
    for _ in 0..<10 { await Task.yield() }
    DockSteamInputService.refresh()
    require(resolvedIDs == [123] && DockSteamInputService.bootstrapping)
    let workshopCommand = try Data(contentsOf: commandFile)
    require(workshopCommand[40] == 7 && workshopCommand[36] == 2)
    let workshopFrame = try Data(contentsOf: initialFile)
    var parsedWorkshop = sh_input_workshop()
    require(workshopFrame.withUnsafeBytes { sh_input_workshop_parse($0.baseAddress!.assumingMemoryBound(to: UInt8.self), workshopFrame.count, &parsedWorkshop) })
    require(parsedWorkshop.item == 123 && parsedWorkshop.layout.appid == 480 && parsedWorkshop.layout.epoch == 1)
    require(DockSteamInputService.selection?.requested == nil && DockSteamInputService.activeChoice == nil)
    DockSteamInputService.end()
    DockSteamInputService.resolveSelectedWorkshop = nil
    // A personal layout is applied by its local UUID through the same journal
    // and C receipt, in a scope with no earlier choice, and Steam's selection is
    // only observed.
    let personalID = UUID(uuidString: "5B1C3B0E-9B7D-4C55-8C1A-0D6E2A7F4E11")!
    let personalDetail = "My layout · personal copy of Fixture · Workshop 123"
    DockSteamInputService.begin(accountID: 25, appID: 480)
    let personalHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    var personalFeed = fixture
    for i in 0..<16 {
        let start = personalHex.index(personalHex.startIndex, offsetBy: i*2)
        personalFeed[8+i] = UInt8(personalHex[start..<personalHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&personalFeed, 36, 0); put32(&personalFeed, 40, 0); put32(&personalFeed, 52, 179)
    try personalFeed.write(to: feedFile); DockSteamInputService.refresh()
    try fm.removeItem(at: commandFile)
    put32(&personalFeed, 36, 1); put32(&personalFeed, 40, 1)
    try baselineFrame(personalFeed).write(to: baselineFile)
    try personalFeed.write(to: feedFile); DockSteamInputService.refresh()
    let beforePersonal = DockSteamInputService.selection
    require(beforePersonal?.requested == nil && beforePersonal?.lastActivated == nil && DockSteamInputService.canChange)
    let observedSteamSelection = beforePersonal?.observedSteamSelection
    require(observedSteamSelection != nil)
    for (app, account, id) in [(UInt32(481), UInt32(25), personalID), (480, 24, personalID), (480, 0, personalID),
                               (480, 25, UUID(uuidString: DockSteamInputService.baselineRestoreIdentity)!)] {
        do {
            try DockSteamInputService.requestPersonal(appID: app, accountID: account, source: initialSource, id: id, detail: personalDetail)
            fatalError("personal layout crossed its game, account or identity scope")
        } catch DockSteamInputJournal.Failure.invalid {}
        require(DockSteamInputService.selection == beforePersonal && DockSteamInputService.prepared == nil && !fm.fileExists(atPath: commandFile.path))
    }
    try DockSteamInputService.requestPersonal(appID: 480, accountID: 25, source: initialSource, id: personalID, detail: personalDetail)
    require(DockSteamInputService.selection?.requested?.source == .personal && DockSteamInputService.activeChoice == nil)
    require(DockSteamInputService.selection?.lastActivated == nil, "a request alone is not an activation")
    let personalHost = Process(); personalHost.executableURL = testRoot.appendingPathComponent("fixture")
    personalHost.arguments = ["receipt", payloadFile.path, receiptFile.path]
    try personalHost.run(); personalHost.waitUntilExit(); require(personalHost.terminationStatus == 0)
    try fm.removeItem(at: commandFile)
    put32(&personalFeed, 36, 2); put32(&personalFeed, 44, 6)
    try personalFeed.write(to: feedFile); DockSteamInputService.refresh()
    let personalChoice = DockSteamInputSelection.Revision(source: .personal, identity: personalID.uuidString,
        contentHash: DockSteamInputNative.contentHash(initialSource), detail: personalDetail)
    require(DockSteamInputService.activeChoice == personalChoice, "the receipt confirms the personal layout by UUID and content hash")
    require(DockSteamInputService.selection?.lastActivated == personalChoice && DockSteamInputService.selection?.requested == personalChoice)
    require(DockSteamInputService.selection?.observedSteamSelection == observedSteamSelection, "Steam's own selection is observed, never rewritten")
    let personalLines = DockSteamInputPresentation.lines(appID: 480, snapshot: DockSteamInputService.snapshot,
        active: DockSteamInputService.activeChoice, selection: DockSteamInputService.selection)
    require(personalLines.contains("Active: Personal layout.") && personalLines.contains("Source: \(personalDetail).")
        && personalLines.contains("Default override: Personal layout."), "\(personalLines)")
    let personalSelection = DockSteamInputService.selection!
    DockSteamInputService.end()
    require(try DockSteamInputSelection.load(in: storage, accountID: 25, appID: 480,
        controllerID: DockSteamInputService.controllerID) == personalSelection, "the personal choice is persisted")
    require(try DockSteamInputSelection.load(in: storage, accountID: 24, appID: 480,
        controllerID: DockSteamInputService.controllerID).requested?.source != .personal, "another account's choice is untouched")
    // A fresh launch reapplies the confirmed personal bytes from the journal,
    // with a new revision and the new launch's rollback baseline.
    DockSteamInputService.begin(accountID: 25, appID: 480)
    let personalRestartHex = String(cString: getenv("MADEIRA_DOCK_INPUT_SESSION"))
    require(personalRestartHex != personalHex)
    for i in 0..<16 {
        let start = personalRestartHex.index(personalRestartHex.startIndex, offsetBy: i*2)
        personalFeed[8+i] = UInt8(personalRestartHex[start..<personalRestartHex.index(start, offsetBy: 2)], radix: 16)!
    }
    put32(&personalFeed, 36, 0); put32(&personalFeed, 40, 0)
    try personalFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.activeChoice == nil, "a new launch confirms nothing until its own receipt")
    try fm.removeItem(at: commandFile)
    put32(&personalFeed, 36, 1); put32(&personalFeed, 40, 1)
    try baselineFrame(personalFeed).write(to: baselineFile)
    try personalFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.prepared != nil && DockSteamInputService.selection == personalSelection)
    let restartPersonalHost = Process(); restartPersonalHost.executableURL = testRoot.appendingPathComponent("fixture")
    restartPersonalHost.arguments = ["receipt", payloadFile.path, receiptFile.path]
    try restartPersonalHost.run(); restartPersonalHost.waitUntilExit(); require(restartPersonalHost.terminationStatus == 0)
    try fm.removeItem(at: commandFile)
    put32(&personalFeed, 36, 2)
    try personalFeed.write(to: feedFile); DockSteamInputService.refresh()
    require(DockSteamInputService.activeChoice == personalChoice, "the personal layout is active again after a restart")
    require(DockSteamInputService.selection == personalSelection)
    DockSteamInputService.end()
    print("PASS: selected-Workshop resolver, scoped hash-bound recovery command and no manufactured explicit choice")
    print("PASS: personal layout by UUID through journal and receipt, scope refusals, persistence and restart reapplication")
    print("PASS: community scope, raw source, persisted attribution, acceptance versus exact receipt acknowledgement")
    print("PASS: first-use bootstrap after interrupted earlier-launch work, and for an empty successful selection only")
    print("PASS: confirmed-choice restart, same-session reconnect recovery, held-input quiesce, fault/interruption recovery, fresh baseline/nonce validation, preservation of newer intent and C/Swift wire interoperability")
}
try await checks()
'''
with tempfile.TemporaryDirectory(prefix='madeira-input-service-') as temporary:
    tmp = Path(temporary)
    fixture = tmp / 'fixture.c'
    fixture.write_text(c_fixture)
    subprocess.run([os.environ.get('HOST_CC') or shutil.which('clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-I' + str(root/'madeira-dock/src'), str(root/'madeira-dock/src/steam_input_service.c'), str(fixture), '-o', str(tmp/'fixture')], check=True)
    subprocess.run([str(tmp/'fixture'), str(tmp/'fixture.bin')], check=True)
    main = tmp / 'main.swift'
    main.write_text('import Foundation\n' + source + cases)
    subprocess.run([os.environ.get('HOST_CC') or shutil.which('clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-c', str(root/'madeira-dock/src/steam_input_service.c'), '-o', str(tmp/'shared.o')], check=True)
    subprocess.run([os.environ.get('SWIFTC') or shutil.which('swiftc'), '-D', 'DEBUG', '-module-cache-path', str(tmp/'modules'), '-import-objc-header', str(root/'madeira-dock/src/steam_input_service.h'), str(root/'app/Madeira/SteamInputTransactions.swift'), str(root/'app/Madeira/SteamInputPersonalReferences.swift'), str(main), str(tmp/'shared.o'), '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp)], check=True)
    subprocess.run([str(tmp/'fixture'), 'verify', str(tmp/'command.bin')], check=True)
