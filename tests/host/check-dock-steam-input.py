#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Run DockSteamInput's setting/recovery code against a temporary account tree."""
from pathlib import Path
import os, shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/MadeiraDock.swift').read_text().split('enum DockSteamInput {', 1)[1]
source = 'enum DockSteamInput {' + source
source = source.replace('FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]', 'testRoot')
with tempfile.TemporaryDirectory(prefix='madeira-steam-input-') as tmp:
    tmp = Path(tmp)
    stub = r'''
import Foundation
let testRoot = URL(fileURLWithPath: CommandLine.arguments[1])
enum MadeiraDock { static var clientRoot: URL { testRoot.appendingPathComponent("Steam") } }
enum SteamLog { static func event(_ text: String) { } }
'''
    cases = r'''
let fm = FileManager.default
let empty = "\"UserLocalConfigStore\"\n{\n\t\"Apps\"\n\t{\n\t\t\"SteamController_PSSupport\"\t\"0\"\n\t}\n}\n"
for newline in ["\n", "\r\n"] {
    let original = empty.replacingOccurrences(of: "\n", with: newline)
    assert(try DockSteamInput.value(in: original) == nil)
    let changed = try DockSteamInput.setting("2", in: original)
    assert(try DockSteamInput.value(in: changed) == "2")
    assert(changed.contains("\t\t\"SteamController_PSSupport\"\t\"0\""))
    assert(try DockSteamInput.setting(nil, in: changed) == original)
}
// A new account has no localconfig.vdf yet. It must be created before Steam starts.
let file = DockSteamInput.localConfig(steamID: 7)
try DockSteamInput.prepare(steamID: 7, enabled: true)
assert(try DockSteamInput.value(in: String(contentsOf: file, encoding: .utf8)) == "2")
// Steam may add unrelated settings while it runs; restoration keeps them.
var generated = try String(contentsOf: file, encoding: .utf8)
generated = generated.replacingOccurrences(of: "}\n", with: "\t\"Keep\"\t\"yes\"\n}\n")
try generated.write(to: file, atomically: true, encoding: .utf8)
assert(DockSteamInput.restore())
let restored = try String(contentsOf: file, encoding: .utf8)
assert(try DockSteamInput.value(in: restored) == nil)
assert(restored.contains("\"Keep\""))
// A journal left before a new account's file could be created is recoverable.
try DockSteamInput.prepare(steamID: 7, enabled: true)
try fm.removeItem(at: file)
assert(DockSteamInput.restore())
assert(!fm.fileExists(atPath: file.path))
// Recover a previous setting (including after a failed restore) on the next launch.
let previous = try DockSteamInput.setting("0", in: empty)
try previous.write(to: file, atomically: true, encoding: .utf8)
try DockSteamInput.prepare(steamID: 7, enabled: true)
try "invalid".write(to: file, atomically: true, encoding: .utf8)
assert(!DockSteamInput.restore())
assert(fm.fileExists(atPath: testRoot.appendingPathComponent("madeira-steam-input.json").path))
try DockSteamInput.setting("2", in: empty).write(to: file, atomically: true, encoding: .utf8)
try DockSteamInput.prepare(steamID: 7, enabled: false)
assert(try DockSteamInput.value(in: String(contentsOf: file, encoding: .utf8)) == "0")
assert(!fm.fileExists(atPath: testRoot.appendingPathComponent("madeira-steam-input.json").path))
print("PASS: LF/CRLF, nested keys, first-account setup, unrelated settings and failed-restore recovery")
'''
    cases = cases.replace('assert(', 'require(')
    stub += '\nfunc require(_ body: @autoclosure () throws -> Bool) { precondition(try! body()) }\n'
    swift = tmp / 'main.swift'; swift.write_text(stub + source + '\n' + cases)
    compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
    subprocess.run([compiler, '-module-cache-path', str(tmp/'modules'), str(swift), '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp)], check=True)
