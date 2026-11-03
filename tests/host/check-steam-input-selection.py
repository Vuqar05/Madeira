#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Exercise production selection persistence with synthetic account/layout data."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/MadeiraDock.swift').read_text()
source = 'struct DockSteamInputSelection' + source.split('struct DockSteamInputSelection', 1)[1].split("/// Steam Input's PlayStation setting", 1)[0]
cases = r'''
let root = URL(fileURLWithPath: CommandLine.arguments[1])
typealias Selection = DockSteamInputSelection
let controller = UUID()
var state = try Selection.load(in: root, accountID: 7, appID: 42, controllerID: controller)
assert(state.requested == nil && state.lastActivated == nil)
let steam = Selection.SteamSelection(key: "existing-autosave", workshopID: 0)
state.retainSteamSelection(steam)
state.retainSteamSelection(.init(key: "replacement", workshopID: 12))
let first = Selection.Revision(source: .template, identity: "gamepad", contentHash: String(repeating: "a", count: 64))
try state.request(first)
try state.acknowledge(first, generation: 1)
let next = Selection.Revision(source: .community, identity: "123", contentHash: String(repeating: "b", count: 64))
try state.request(next)
do { try state.acknowledge(first, generation: 1); fatalError("accepted stale response") }
catch Selection.StoreError.stale {}
assert(state.lastActivated == first && state.requested == next)
try state.save(in: root)
let restored = try Selection.load(in: root, accountID: 7, appID: 42, controllerID: controller)
assert(restored == state && restored.observedSteamSelection == steam)
for (account, app, pad) in [(UInt32(8), UInt32(42), controller), (7, 43, controller), (7, 42, UUID())] {
    let other = try Selection.load(in: root, accountID: account, appID: app, controllerID: pad)
    assert(other.requested == nil)
}
for invalid in [Selection.Revision(source: .community, identity: "../123", contentHash: nil),
                .init(source: .personal, identity: "bad", contentHash: nil),
                .init(source: .template, identity: "pad", contentHash: "not-a-hash"),
                .init(source: .gameDefault, identity: "pad", contentHash: nil)] {
    do { try state.request(invalid); fatalError("accepted invalid revision") }
    catch Selection.StoreError.invalid {}
}
assert(state == restored)
try state.request(.init(source: .gameDefault, identity: nil, contentHash: nil))
do { try state.acknowledge(state.requested!, generation: state.generation); fatalError("acknowledged unresolved source") }
catch Selection.StoreError.stale {}
assert(state.lastActivated == first)
// Unknown schemas and scope tampering fail without replacing saved bytes.
let file = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("steam-input-selections"), includingPropertiesForKeys: nil)[0]
let original = try Data(contentsOf: file)
for field in ["version", "accountID"] {
    var json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    json[field] = 999
    let damaged = try JSONSerialization.data(withJSONObject: json)
    try damaged.write(to: file, options: .atomic)
    do { _ = try Selection.load(in: root, accountID: 7, appID: 42, controllerID: controller); fatalError("accepted incompatible record") }
    catch Selection.StoreError.invalid {} catch Selection.StoreError.unsupportedVersion {}
    assert(try Data(contentsOf: file) == damaged)
}
let beforeClear = state.generation
try state.clearRequest()
assert(state.requested == nil && state.lastActivated == first && state.generation == beforeClear + 1)
do { try state.acknowledge(first, generation: beforeClear); fatalError("acknowledged after explicit clear") }
catch Selection.StoreError.stale {}
print("PASS: selection round trip, migration, scope isolation, stale acknowledgement, rollback retention and validation")
'''
# Swift assert's autoclosure cannot throw.
cases = cases.replace('assert(', 'require(')
with tempfile.TemporaryDirectory(prefix='madeira-input-selection-') as temporary:
    tmp = Path(temporary)
    main = tmp / 'main.swift'
    main.write_text('import Foundation\nfunc require(_ value: @autoclosure () throws -> Bool) { precondition(try! value()) }\n' + source + cases)
    compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
    subprocess.run([compiler, '-module-cache-path', str(tmp/'modules'), str(main), '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp)], check=True)
