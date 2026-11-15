#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Recovery after Madeira is closed mid-game (Steam Input milestone 5 item 3).

Runs the production DockSessionRecovery against a temporary client tree: a
clean previous session leaves nothing to do; a cut-off one (its record still
present) has the client's crash marker and HTTP cache removed and nothing else;
a link is never followed out of the client folder; the stall diagnostics keep
connection lines and drop Steam IDs, addresses and long numbers.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
cases = r'''
import Foundation
enum SteamLog { nonisolated(unsafe) static var lines: [String] = []; static func event(_ text: String) { lines.append(text) } }
func require(_ value: Bool, _ message: String) { if !value { fatalError("FAIL: " + message) } }
@MainActor func checks() throws {
    let base = URL(fileURLWithPath: CommandLine.arguments[1])
    let fm = FileManager.default
    let client = base.appendingPathComponent("Steam")
    DockSessionRecovery.root = base.appendingPathComponent("support")
    func make(_ path: String, _ text: String = "x") throws {
        let url = client.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    try make(".crash"); try make("appcache/httpcache/index"); try make("config/loginusers.vdf"); try make("appcache/appinfo.vdf")
    // A clean previous session: nothing is removed.
    require(DockSessionRecovery.begin(appID: 480, clientRoot: client).isEmpty, "first start cleans nothing")
    DockSessionRecovery.end()
    require(DockSessionRecovery.begin(appID: 480, clientRoot: client).isEmpty, "after a clean end nothing is removed")
    // This session is cut off (no end): the next start removes the volatile state only.
    let removed = DockSessionRecovery.begin(appID: 620, clientRoot: client)
    require(removed == [".crash", "appcache/httpcache"], "\(removed)")
    require(!fm.fileExists(atPath: client.appendingPathComponent(".crash").path)
            && !fm.fileExists(atPath: client.appendingPathComponent("appcache/httpcache").path), "leftovers removed")
    require(fm.fileExists(atPath: client.appendingPathComponent("config/loginusers.vdf").path)
            && fm.fileExists(atPath: client.appendingPathComponent("appcache/appinfo.vdf").path), "sign-in and app data kept")
    require(SteamLog.lines.contains { $0.contains("previous session app=480 ended without closing") }, "logged")
    // A link in place of the cache is not followed.
    let outside = base.appendingPathComponent("outside")
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: outside.appendingPathComponent("file"))
    try fm.createSymbolicLink(at: client.appendingPathComponent("appcache/httpcache"), withDestinationURL: outside)
    _ = DockSessionRecovery.begin(appID: 620, clientRoot: client)
    require(fm.fileExists(atPath: outside.appendingPathComponent("file").path), "a link out of the client is not followed")
    DockSessionRecovery.end()
    // Stall diagnostics: connection lines only, redacted.
    try make("logs/connection_log.txt", """
    [2026-11-15 12:34:56] Starting connectivity test (test.steampowered.com/204) from 10.0.0.12:27015
    [2026-11-15 12:34:57] unrelated line
    [2026-11-15 12:35:56] Logon for [U:1:12345678] steamid 76561198000000000 via 2001:db8::1 failed
    """)
    let lines = DockSessionRecovery.connectionLines(clientRoot: client)
    require(lines.count == 2 && lines[0].contains("connectivity test") && lines[0].contains("12:34:56"), "\(lines)")
    require(!lines.joined().contains("10.0.0.12") && !lines.joined().contains("12345678")
            && !lines.joined().contains("76561198000000000") && !lines.joined().contains("2001:db8"), "\(lines)")
    DockSessionRecovery.logStall(clientRoot: client, elapsed: 130)
    DockSessionRecovery.logStall(clientRoot: client, elapsed: 131)
    require(SteamLog.lines.filter { $0.contains("sign-in not started") }.count == 1, "logged once per start")
    print("PASS: interrupted Dock session detected, client crash marker and HTTP cache removed (links not followed, account data kept), redacted stall diagnostics once per start")
}
try MainActor.assumeIsolated { try checks() }
'''
with tempfile.TemporaryDirectory(prefix='madeira-dock-recovery-') as temporary:
    tmp = Path(temporary)
    (tmp / 'main.swift').write_text(cases)
    subprocess.run([os.environ.get('SWIFTC') or shutil.which('swiftc'), '-module-cache-path', str(tmp / 'modules'),
                    str(root / 'app/Madeira/DockSessionRecovery.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(tmp / 'tree')], check=True)
