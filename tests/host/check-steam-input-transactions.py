#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Real filesystem checks of scoped revision journals and immutable queue bytes."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
cases = r'''
import Foundation
import Darwin
func require(_ value: @autoclosure () throws -> Bool) { precondition(try! value()) }
@MainActor func checks() throws {
    typealias Journal = DockSteamInputJournal
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let scope = Journal.Scope(accountID: 7, appID: 480, controllerID: UUID())
    let store = try Journal(root: root, scope: scope)
    let source = Data("controller_mappings { revision 7 unknown { binding changed } }".utf8)
    let baseline = Data("controller_mappings { revision 7 unknown { binding value } }".utf8)
    let apply = try DockSteamInputNative.materialize(source, revision: 732)
    let rollback = try DockSteamInputNative.materialize(baseline, revision: 733)
    let r = try store.reserve(sourceFloor: 731)
    require(r.applyRevision == 732 && r.rollbackRevision == 733)
    do { _ = try store.reserve(sourceFloor: 0); fatalError("overlap") } catch Journal.Failure.busy {}
    let content = try store.prepare(r, source: source, baseline: baseline, apply: apply, rollback: rollback)
    require(try store.content(content.sourceHash) == source)
    require(try store.content(content.baselineHash) == baseline)
    require(try store.content(content.applyHash) == apply)
    require(try store.content(content.rollbackHash) == rollback)
    let reloaded = try Journal(root: root, scope: scope)
    require(try reloaded.snapshot().pending?.content == content)
    let request = Journal.Request(session: String(repeating: "a", count: 32), epoch: 1, sequence: 1)
    try reloaded.markQueued(r, request: request)
    require(try store.snapshot().pending?.phase == .queued)
    do { _ = try reloaded.reserve(sourceFloor: 0); fatalError("overlapped queue") } catch Journal.Failure.busy {}
    let staleRequest = Journal.Request(session: String(repeating: "b", count: 32), epoch: 1, sequence: 1)
    do { try store.finish(r, phase: .confirmed, hash: content.applyHash, revision: r.applyRevision, request: staleRequest); fatalError("wrong launch") }
    catch Journal.Failure.stale {}
    for (hash, revision) in [(content.sourceHash, r.applyRevision), (content.applyHash, r.rollbackRevision)] {
        do { try store.finish(r, phase: .confirmed, hash: hash, revision: revision, request: request); fatalError("false receipt") }
        catch Journal.Failure.stale {}
    }
    require(try store.snapshot().lastWorking == nil)
    try store.finish(r, phase: .rolledBack, hash: content.rollbackHash, revision: r.rollbackRevision, request: request)
    require(try store.snapshot().lastWorking?.hash == content.rollbackHash)
    do { try store.finish(r, phase: .confirmed, hash: content.applyHash, revision: r.applyRevision, request: request); fatalError("late receipt") }
    catch Journal.Failure.stale {}
    let second = try store.reserve(sourceFloor: 0)
    require(second.applyRevision == 734)
    // Preparation fails without freeing or reusing a reservation.
    do { _ = try store.prepare(second, source: source, baseline: baseline, apply: apply, rollback: apply); fatalError("same content") }
    catch Journal.Failure.invalid {}
    try store.finish(second, phase: .failed, hash: nil, revision: nil)
    require(try store.snapshot().highWater == 735)
    require(try store.snapshot().lastWorking?.hash == content.rollbackHash)
    let third = try store.reserve(sourceFloor: 0)
    require(third.applyRevision == 736)
    let other = try Journal(root: root, scope: .init(accountID: 7, appID: 481, controllerID: scope.controllerID))
    require(try other.snapshot().highWater == 0)
    let otherAccount = try Journal(root: root, scope: .init(accountID: 8, appID: 480, controllerID: scope.controllerID))
    require(try otherAccount.snapshot().pending == nil)
    let otherPad = try Journal(root: root, scope: .init(accountID: 7, appID: 480, controllerID: UUID()))
    require(try otherPad.snapshot().lastWorking == nil)
    do { _ = try store.content("../journal"); fatalError("path accepted") } catch Journal.Failure.invalid {}
    let directory = root.appendingPathComponent("steam-input-transactions/7-480-\(scope.controllerID.uuidString)")
    let journalURL = directory.appendingPathComponent("journal.json")
    let original = try Data(contentsOf: journalURL)
    // A competing writer cannot reserve while another descriptor owns the lock.
    let descriptor = open(directory.appendingPathComponent("journal.lock").path, O_RDWR)
    require(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    do { _ = try store.snapshot(); fatalError("ignored writer lock") } catch Journal.Failure.busy {}
    flock(descriptor, LOCK_UN); close(descriptor)
    // Tampered objects fail hash verification and cannot be silently repaired.
    let object = directory.appendingPathComponent("objects/\(content.sourceHash).vdf")
    try Data("corrupt".utf8).write(to: object)
    do { _ = try store.content(content.sourceHash); fatalError("bad hash") } catch Journal.Failure.corrupt {}
    let nextApply = try DockSteamInputNative.materialize(source, revision: third.applyRevision)
    let nextRollback = try DockSteamInputNative.materialize(baseline, revision: third.rollbackRevision)
    do { _ = try store.prepare(third, source: source, baseline: baseline, apply: nextApply, rollback: nextRollback); fatalError("overwrote corrupt content") }
    catch Journal.Failure.corrupt {}
    require(try Data(contentsOf: object) == Data("corrupt".utf8))
    require(try Data(contentsOf: journalURL) == original)
    for field in ["version", "highWater"] {
        var json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        json[field] = field == "version" ? 99 : UInt64(UInt32.max)
        let damaged = try JSONSerialization.data(withJSONObject: json)
        try damaged.write(to: journalURL)
        do { _ = try store.reserve(sourceFloor: 0); fatalError("accepted corrupt journal") } catch Journal.Failure.corrupt {}
        require(try Data(contentsOf: journalURL) == damaged)
    }
    try original.write(to: journalURL)
    try store.finish(third, phase: .failed, hash: nil, revision: nil)
    do { _ = try store.reserve(sourceFloor: UInt32(Int32.max)); fatalError("revision wrap") } catch Journal.Failure.exhausted {}
    let final = try store.reserve(sourceFloor: UInt32(Int32.max) - 2)
    require(final.rollbackRevision == UInt32(Int32.max))
    try store.finish(final, phase: .failed, hash: nil, revision: nil)
    do { _ = try store.reserve(sourceFloor: 0); fatalError("reused exhausted range") } catch Journal.Failure.exhausted {}
    let local = try Journal(root: root, scope: .init(accountID: 9, appID: 480, controllerID: UUID()))
    let prepared = try local.prepareLocal(source: apply, baseline: baseline)
    require(prepared.reservation.applyRevision == 733 && prepared.reservation.rollbackRevision == 734)
    let localContent = prepared.content!
    let localApply = try local.content(localContent.applyHash)
    let localRollback = try local.content(localContent.rollbackHash)
    require(try DockSteamInputNative.revision(localApply) == 733)
    require(try DockSteamInputNative.revision(localRollback) == 734)
    require(try local.content(localContent.sourceHash) == apply)
    require(try local.content(localContent.baselineHash) == baseline)
    require(String(data: localRollback, encoding: .utf8)!.contains("unknown { binding value }"))
    try local.markQueued(prepared.reservation, request: request)
    try local.interrupt()
    require(try local.snapshot().pending?.phase == .interrupted)
    do { try local.finish(prepared.reservation, phase: .confirmed, hash: localContent.applyHash,
                          revision: prepared.reservation.applyRevision, request: request); fatalError("old launch acknowledged after interruption") }
    catch Journal.Failure.stale {}
    do { _ = try local.reserve(sourceFloor: 0); fatalError("lost pending recovery") } catch Journal.Failure.busy {}
    let bad = Data("controller_mappings { revision 1 Revision 2 }".utf8)
    do { _ = try local.prepareLocal(source: bad, baseline: source); fatalError("ambiguous native metadata") }
    catch Journal.Failure.invalid {}
    // Exercise the real C coordinator against Swift-generated immutable bytes
    // and persist its receipt through the scoped Swift journal.
    let bridge = try Journal(root: root, scope: .init(accountID: 10, appID: 480, controllerID: UUID()))
    let ready = try bridge.prepareLocal(source: apply, baseline: baseline)
    let payload = ready.content!
    func digestBytes(_ hash: String) -> [UInt8] {
        stride(from: 0, to: 64, by: 2).map { offset in
            let start = hash.index(hash.startIndex, offsetBy: offset)
            return UInt8(hash[start..<hash.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    var transaction = sh_input_transaction()
    require(sh_input_tx_init(&transaction, 480, 1, 732))
    require(sh_input_tx_reserve(&transaction, 1, 1, 732))
    require(transaction.apply_revision == ready.reservation.applyRevision)
    require(transaction.rollback_revision == ready.reservation.rollbackRevision)
    require(sh_input_tx_bind(&transaction, digestBytes(payload.applyHash), digestBytes(payload.rollbackHash)))
    try bridge.markQueued(ready.reservation, request: request)
    require(sh_input_tx_queue(&transaction, 1000))
    var result = sh_input_load_result(controller: 0, appid: 480, revision: transaction.apply_revision, completed: true)
    require(sh_input_tx_completion(&transaction, &result, 1001))
    require(!transaction.working_known)
    require(sh_input_tx_activated(&transaction, transaction.apply_revision, 1002))
    require(transaction.working_known && transaction.working.sequence == request.sequence && transaction.working.epoch == request.epoch)
    let receiptHash = withUnsafeBytes(of: transaction.working.hash) { Data($0).map { String(format: "%02x", $0) }.joined() }
    require(receiptHash == payload.applyHash)
    try bridge.finish(ready.reservation, phase: .confirmed, hash: receiptHash,
                      revision: transaction.working.revision, request: request)
    require(try bridge.snapshot().lastWorking?.hash == payload.applyHash)
    require(try bridge.reapplicationSource(hash: payload.sourceHash) == apply)
    do { _ = try bridge.reapplicationSource(hash: payload.baselineHash); fatalError("unconfirmed source selected for restart") }
    catch Journal.Failure.stale {}
    let retry = try bridge.prepareLocal(source: baseline, baseline: baseline)
    let retryRequest = Journal.Request(session: String(repeating: "c", count: 32), epoch: 1, sequence: 2)
    try bridge.markQueued(retry.reservation, request: retryRequest)
    try bridge.finish(retry.reservation, phase: .rolledBack, hash: retry.content!.rollbackHash,
        revision: retry.reservation.rollbackRevision, request: retryRequest)
    require(try bridge.reapplicationSource(hash: payload.sourceHash) == apply) // prior confirmed choice survives a fresh-launch rollback
    do { try local.abandonInterrupted(prepared.reservation, newSession: request.session); fatalError("same-launch recovery accepted") }
    catch Journal.Failure.stale {}
    let sameLaunchQueued = try bridge.prepareLocal(source: apply, baseline: baseline)
    let sameLaunchReq = Journal.Request(session: String(repeating: "c", count: 32), epoch: 1, sequence: 3)
    try bridge.markQueued(sameLaunchQueued.reservation, request: sameLaunchReq)
    try bridge.interrupt()
    do { try bridge.abandonInterrupted(sameLaunchQueued.reservation, newSession: sameLaunchReq.session, newEpoch: 1); fatalError("same-epoch recovery accepted") }
    catch Journal.Failure.stale {}
    try bridge.abandonInterrupted(sameLaunchQueued.reservation, newSession: sameLaunchReq.session, newEpoch: 3)
    require(try bridge.snapshot().pending?.phase == .failed)
    let oldFloor = try local.snapshot().highWater
    try local.abandonInterrupted(prepared.reservation, newSession: String(repeating: "b", count: 32))
    require(try local.snapshot().pending?.phase == .failed && local.snapshot().highWater == oldFloor)
    require(try local.reserve(sourceFloor: 0).applyRevision > oldFloor)
    print("PASS: durable revision reservations, restart/reconnect recovery, scope isolation, immutable hashed bytes, receipt binding, writer lock, corruption and exhaustion")
}
try MainActor.assumeIsolated { try checks() }
'''
with tempfile.TemporaryDirectory(prefix='madeira-input-transactions-') as temporary:
    tmp = Path(temporary)
    (tmp/'main.swift').write_text(cases)
    subprocess.run([os.environ.get('HOST_CC') or shutil.which('clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-c', str(root/'madeira-dock/src/steam_input_service.c'), '-o', str(tmp/'shared.o')], check=True)
    subprocess.run([os.environ.get('SWIFTC') or shutil.which('swiftc'), '-module-cache-path', str(tmp/'modules'), '-import-objc-header', str(root/'madeira-dock/src/steam_input_service.h'), str(root/'app/Madeira/SteamInputTransactions.swift'), str(tmp/'main.swift'), str(tmp/'shared.o'), '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp/'storage')], check=True)
