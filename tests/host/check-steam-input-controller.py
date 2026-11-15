#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Steam Input's per-controller identity (milestone 5 item 1).

The launch's identity rule (a PlayStation pad is the DualSense, the on-screen
controls and other pads the Xbox controller, behind the opt-in switch), each
identity's compatible layout types (January SteamUI 0x731ca0), and the game
default resolved for each identity from a real temporary game and client tree:
a manifest's own entry, a compatible entry, a template, Workshop metadata, and
device details that describe another controller being ignored. Uses the
production Swift and Dock's C resolver; no device, Steam or network.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
cases = r'''
import Foundation
// SteamAppInfo.swift's app-only neighbours, as check-steam-input-metadata.py stubs them.
enum VDFParser { static func parseTextVDF(from: Data, sectionOrder: (([String], [String]) -> Void)? = nil) -> [String: Any] { [:] } }
enum MadeiraConfig {
    static func get(_ key: String) -> String? { nil }
    static func set(_ key: String, _ value: String?) {}
}
enum SteamLog { static func event(_ text: String) {} }
func require(_ value: @autoclosure () throws -> Bool, _ message: String = "") {
    if !(try! value()) { fatalError("FAIL: " + message) }
}
@MainActor func checks() throws {
    // The identity rule. Without the switch every launch keeps the DualSense.
    for physical in [true, false, nil] as [Bool?] {
        require(SteamInputController.choose(physicalIsPlayStation: physical, xboxEnabled: false) == .dualSense, "switch off")
    }
    require(SteamInputController.choose(physicalIsPlayStation: true, xboxEnabled: true) == .dualSense, "PlayStation pad")
    require(SteamInputController.choose(physicalIsPlayStation: false, xboxEnabled: true) == .xbox, "other pad")
    require(SteamInputController.choose(physicalIsPlayStation: nil, xboxEnabled: true) == .xbox, "on-screen controls")
    // The session is decided once; a pad paired later does not change it.
    var paired: Bool? = nil
    SteamInputController.environment = .init(xboxSwitch: { true }, pairedIsPlayStation: { paired }, log: { _ in })
    require(SteamInputController.current == .xbox)
    require(SteamInputController.beginSession() == .xbox)
    paired = true
    require(SteamInputController.session == .xbox && SteamInputController.current == .xbox, "session fixed")
    SteamInputController.endSession()
    require(SteamInputController.session == nil && SteamInputController.current == .dualSense, "prediction follows the pad")

    // Stable, distinct selection identities; the DualSense keeps the old one.
    require(SteamInputController.dualSense.controllerID.uuidString == "77F4893A-244E-4808-994C-617331E9DC25")
    require(SteamInputController.xbox.controllerID != SteamInputController.dualSense.controllerID)
    require(SteamInputController(vendor: 0x054c, product: 0x0ce6) == .dualSense)
    require(SteamInputController(vendor: 0x045e, product: 0x0b13) == .xbox)
    require(SteamInputController(vendor: 0x045e, product: 0x0b12) == nil && SteamInputController(vendor: 0x28de, product: 0x1205) == nil)
    // Compatibility as January's client decides it, case-insensitive.
    for type in ["controller_ps5", "controller_ps4", "CONTROLLER_PS5"] { require(SteamInputController.dualSense.accepts(type: type), type) }
    for type in ["controller_xboxone", "controller_xbox360", "controller_generic", "controller_ps3", "controller_apple",
                 "controller_android"] { require(SteamInputController.xbox.accepts(type: type), type) }
    for type in ["controller_neptune", "controller_steamcontroller_gordon", "controller_xboxelite", "controller_switch_pro", ""] {
        require(!SteamInputController.dualSense.accepts(type: type) && !SteamInputController.xbox.accepts(type: type), type)
    }
    require(!SteamInputController.dualSense.accepts(type: "controller_xboxone") && !SteamInputController.xbox.accepts(type: "controller_ps5"))
    require(SteamInputController.xbox.genericTemplate == "controller_xboxone_gamepad_joystick.vdf")
    require(SteamInputController(layoutType: "controller_neptune") == nil && SteamInputController(layoutType: "controller_ps4") == .dualSense)

    // Defaults from a real tree: the client's templates and a game's manifest.
    let base = URL(fileURLWithPath: CommandLine.arguments[1])
    let client = base.appendingPathComponent("steam")
    let templates = client.appendingPathComponent("controller_base/templates", isDirectory: true)
    try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
    let ps5 = Data("controller_mappings { revision 1 controller_type controller_ps5 }".utf8)
    let xbox = Data("controller_mappings { revision 2 controller_type controller_xboxone }".utf8)
    try ps5.write(to: templates.appendingPathComponent("controller_ps5_gamepad_joystick.vdf"))
    try xbox.write(to: templates.appendingPathComponent("controller_xboxone_gamepad_joystick.vdf"))
    let hints = DockSteamInputDefault.Hints(templateIndex: 4, manifestPath: nil)
    func source(_ r: DockSteamInputDefault.Resolution) -> Data? { if case .recommended(let v) = r { return v.source }; return nil }
    require(source(DockSteamInputDefault.resolve(hints: hints, gameDirectory: nil, clientRoot: client)) == ps5, "DualSense template")
    require(source(DockSteamInputDefault.resolve(hints: hints, gameDirectory: nil, clientRoot: client, controller: .xbox)) == xbox, "Xbox template")
    require(try DockSteamInputDefault.genericTemplate(clientRoot: client, controller: .xbox) == xbox)
    // Index 6 has no Xbox WASD file here: unavailable, never the DualSense's.
    try ps5.write(to: templates.appendingPathComponent("controller_ps5_wasd.vdf"))
    require(DockSteamInputDefault.resolve(hints: .init(templateIndex: 6, manifestPath: nil), gameDirectory: nil, clientRoot: client,
                                          controller: .xbox) == .unresolved(.templateUnavailable), "no cross-controller template")
    // Indices 2/3 need that controller's own details; another controller's do not count.
    let dsContext = DockSteamInputContext(capabilities: 0, vendor: 0x054c, product: 0x0ce6, rawType: 45, manifestPath: nil)
    let xbContext = DockSteamInputContext(capabilities: 0, vendor: 0x045e, product: 0x0b13, rawType: 32, manifestPath: nil)
    require(dsContext.controller == .dualSense && xbContext.controller == .xbox && !xbContext.isDualSense)
    require(DockSteamInputDefault.resolve(hints: .init(templateIndex: 2, manifestPath: nil), gameDirectory: nil, clientRoot: client,
                                          context: dsContext, controller: .xbox) == .unresolved(.templateControllerDependent))
    require(source(DockSteamInputDefault.resolve(hints: .init(templateIndex: 2, manifestPath: nil), gameDirectory: nil,
                                                 clientRoot: client, context: xbContext, controller: .xbox)) == xbox)
    // A manifest with entries for both: each controller gets its own.
    let game = base.appendingPathComponent("game", isDirectory: true)
    try FileManager.default.createDirectory(at: game.appendingPathComponent("layouts"), withIntermediateDirectories: true)
    try Data(("\"Action Manifest\" { configurations { controller_ps4 { 0 { path layouts/ps4.vdf } } "
              + "controller_xbox360 { 0 { path layouts/x360.vdf } } controller_ps5 { 0 { path layouts/ps5.vdf } } } }").utf8)
        .write(to: game.appendingPathComponent("actions.vdf"))
    for (name, bytes) in [("ps4", ps5), ("x360", xbox), ("ps5", ps5)] {
        try bytes.write(to: game.appendingPathComponent("layouts/\(name).vdf"))
    }
    let manifestHints = DockSteamInputDefault.Hints(templateIndex: nil, manifestPath: "actions.vdf")
    let dsCandidate = try DockSteamInputBundledManifest.candidate(gameDirectory: game, manifestPath: "actions.vdf")
    let xbCandidate = try DockSteamInputBundledManifest.candidate(gameDirectory: game, manifestPath: "actions.vdf", controller: .xbox)
    require(dsCandidate?.relativePath == "layouts/ps5.vdf" && xbCandidate?.relativePath == "layouts/x360.vdf", "manifest entries")
    require(source(DockSteamInputDefault.resolve(hints: manifestHints, gameDirectory: game, clientRoot: client, controller: .xbox)) == xbox)

    // Workshop rich metadata: the connected type's entries, then its compatible ones.
    typealias Default = SteamAppInfo.SteamInputMetadata.WorkshopDefault
    let metadata = SteamAppInfo.SteamInputMetadata(templateIndex: 1, manifestPath: nil, workshopDetails: [
        Default(id: 1, controllerType: "controller_neptune", branches: ["default"], useActionBlock: false),
        Default(id: 2, controllerType: "controller_ps5", branches: ["default"], useActionBlock: false),
        Default(id: 3, controllerType: "controller_xbox360", branches: ["default"], useActionBlock: false),
    ])
    require(metadata.workshopRecommendation(branch: "public") == 2, "DualSense rich entry")
    require(metadata.workshopRecommendation(branch: "public", exact: "controller_xboxone",
                                            compatible: SteamInputController.xbox.compatibleTypes) == 3, "Xbox compatible entry")
    print("PASS: identity rule and switch, fixed session identity, distinct selection identities, January compatibility per "
          + "controller, templates, manifest entries, device details and Workshop metadata resolved per controller")
}
try MainActor.assumeIsolated { try checks() }
'''

with tempfile.TemporaryDirectory(prefix='madeira-input-controller-') as temporary:
    tmp = Path(temporary)
    app = root / 'app/Madeira'
    (tmp / 'main.swift').write_text(cases)
    subprocess.run([os.environ.get('HOST_CC') or shutil.which('clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-c',
                    str(root / 'madeira-dock/src/steam_input_service.c'), '-o', str(tmp / 'shared.o')], check=True)
    subprocess.run([os.environ.get('SWIFTC') or shutil.which('swiftc'), '-module-cache-path', str(tmp / 'modules'),
                    '-import-objc-header', str(root / 'madeira-dock/src/steam_input_service.h'),
                    str(app / 'SteamInputTransactions.swift'), str(app / 'SteamInputController.swift'),
                    str(app / 'SwiftSteam/Library/SteamAppInfo.swift'),
                    str(tmp / 'main.swift'), str(tmp / 'shared.o'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(tmp / 'tree')], check=True)
