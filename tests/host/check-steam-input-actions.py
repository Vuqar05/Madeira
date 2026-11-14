#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Milestone 4 item 5: action names from the game's action manifest, and
references to groups, action sets and layers checked before a layout is applied."""
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

/// Every regular file beneath `url` with a digest of its bytes, plus every
/// directory and link, so a stray write of any kind changes the snapshot.
func snapshot(_ url: URL) throws -> [String: String] {
    var out: [String: String] = [:]
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return out }
    for case let entry as URL in walker {
        let path = String(entry.path.dropFirst(url.path.count))
        if try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            out[path] = SHA256.hash(data: try Data(contentsOf: entry)).map { String(format: "%02x", $0) }.joined()
        } else { out[path] = "-" }
    }
    return out
}

@main struct CheckActions {
    @MainActor static func main() async throws {
        typealias Model = SteamInputLayoutModel
        typealias Binding = SteamInputLayoutModel.ParsedBinding
        let temp = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        // =============================================================
        // 1. The action manifest, in the format Valve documents
        // =============================================================
        let manifestText = """
        "Action Manifest"
        {
            "configurations"
            {
                "controller_xboxone" { "0" { "path" "xbox.vdf" } }
            }
            "actions"
            {
                "InGameControls"
                {
                    "title" "#Set_Ingame"
                    "StickPadGyro"
                    {
                        "Move" { "title" "#Action_Move" "input_mode" "joystick_move" }
                        "Camera" { "title" "#Action_Camera" "input_mode" "absolute_mouse" "os_mouse" "1" }
                    }
                    "AnalogTrigger"
                    {
                        "Throttle" "#Action_Throttle"
                    }
                    "Button"
                    {
                        "Jump" "#Action_Jump"
                        "fancy_click" "#Action_Click, mouse_button LEFT"
                        "Plain" "Literal name"
                        "Untranslated" "#Action_Missing"
                        "FrenchOnly" "#Action_French"
                    }
                }
                "MenuControls"
                {
                    "title" "Menus"
                    "Button" { "menu_up" "#Menu_Up" }
                }
            }
            "action_layers"
            {
                "DrivingLayer"
                {
                    "title" "#Layer_Driving"
                    "legacy_set" "0"
                    "set_layer" "1"
                    "parent_set_name" "InGameControls"
                    "Button" { "Horn" "#Action_Horn" }
                }
            }
            "localization"
            {
                "french"
                {
                    "Action_Jump" "Sauter"
                    "Action_French" "Seulement"
                }
                "english"
                {
                    "Set_Ingame" "In-Game Controls"
                    "Action_Move" "Move"
                    "Action_Camera" "Camera"
                    "Action_Throttle" "Throttle"
                    "action_jump" "Jump"
                    "Action_Click" "Click"
                    "Menu_Up" "Up"
                    "Layer_Driving" "Driving"
                    "Action_Horn" "Horn"
                }
            }
        }
        """
        let manifest = try SteamInputActionManifest(Data(manifestText.utf8))
        require(manifest.sets.map(\.id) == ["InGameControls", "MenuControls", "DrivingLayer"], "sets then layers, in file order")
        require(manifest.sets.map(\.isLayer) == [false, false, true])
        let ingame = manifest.set("ingamecontrols")!
        require(manifest.name(of: ingame) == "In-Game Controls", "set title token is localized")
        require(manifest.name(of: manifest.set("MenuControls")!) == "Menus", "a literal set title is kept")
        require(manifest.name(of: manifest.set("DrivingLayer")!) == "Driving", "layer title is localized")
        require(ingame.actions.map(\.id) == ["Move", "Camera", "Throttle", "Jump", "fancy_click", "Plain", "Untranslated", "FrenchOnly"])
        require(ingame.actions.map(\.kind) == [.analog, .analog, .trigger, .button, .button, .button, .button, .button])
        func name(_ action: String, _ set: String) -> String? { manifest.action(action, in: set).map(manifest.name(of:)) }
        require(name("Move", "InGameControls") == "Move", "block-form analog action")
        require(name("Throttle", "InGameControls") == "Throttle", "leaf-form trigger action")
        require(name("jump", "INGAMECONTROLS") == "Jump", "ids and tokens are matched without regard to case; English wins over French")
        require(name("fancy_click", "InGameControls") == "Click", "a title ends at the first comma; the native event after it is not a name")
        require(name("Plain", "InGameControls") == "Literal name", "literal titles are used as written")
        require(name("Untranslated", "InGameControls") == "Untranslated", "an unlocalized token falls back to the action's id, never to the token")
        require(name("FrenchOnly", "InGameControls") == "Seulement", "another language is used only when English lacks the token")
        require(name("Horn", "DrivingLayer") == "Horn", "layer actions are declared in the layer")
        require(name("Horn", "InGameControls") == nil, "an action is looked up only in the set that is named")
        require(name("Jump", "NoSuchSet") == nil && manifest.set("NoSuchSet") == nil, "an undeclared set resolves nothing")
        require(name("Fly", "InGameControls") == nil, "an undeclared action resolves nothing")

        // The older In-Game Actions root has the same blocks; a BOM is tolerated.
        let iga = try SteamInputActionManifest(Data([0xef, 0xbb, 0xbf]) + Data(##""In Game Actions" { "actions" { "Set" { "title" "#T" "Button" { "A" "#N" } } } "localization" { "english" { "T" "Title" "N" "Name" } } }"##.utf8))
        require(iga.set("Set").map(iga.name(of:)) == "Title" && iga.action("A", in: "Set").map(iga.name(of:)) == "Name")
        for notManifest in [#""controller_mappings" { "version" "3" }"#, #""Action Manifest" "text""#, "", "\"Action Manifest\" {"] {
            var refused = false
            do { _ = try SteamInputActionManifest(Data(notManifest.utf8)) } catch { refused = true }
            require(refused, "not an action manifest: \(notManifest)")
        }

        // =============================================================
        // 2. Reading it from the installed game, and every way it can be absent
        // =============================================================
        let game = temp.appendingPathComponent("game", isDirectory: true)
        let outside = temp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: game.appendingPathComponent("input"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(manifestText.utf8).write(to: game.appendingPathComponent("input/actions.vdf"))
        try Data(manifestText.replacingOccurrences(of: "In-Game Controls", with: "Runtime Controls").utf8).write(to: game.appendingPathComponent("runtime.vdf"))
        try Data(#""controller_mappings" { "version" "3" }"#.utf8).write(to: game.appendingPathComponent("layout.vdf"))
        try Data(manifestText.utf8).write(to: outside.appendingPathComponent("actions.vdf"))
        try FileManager.default.createSymbolicLink(at: game.appendingPathComponent("link.vdf"), withDestinationURL: outside.appendingPathComponent("actions.vdf"))
        try FileManager.default.createSymbolicLink(at: game.appendingPathComponent("linked"), withDestinationURL: outside)
        let before = try snapshot(temp)

        typealias Names = SteamInputActionNames
        let loaded = Names.load(hintKnown: true, manifestPath: "input/actions.vdf", gameDirectory: game)
        require(loaded.manifest == manifest && loaded.explanation == nil, "the bundled manifest is read from the installed game")
        require(Names.load(hintKnown: true, manifestPath: "input/actions.vdf", gameDirectory: nil) == .notInstalled, "a game that is not installed resolves nothing")
        require(Names.load(hintKnown: true, manifestPath: nil, gameDirectory: game) == .notBundled, "app data that names no manifest")
        require(Names.load(hintKnown: false, manifestPath: nil, gameDirectory: game) == .dataUnavailable, "app data that was never read is not 'no manifest'")
        for path in ["missing.vdf", "layout.vdf", "link.vdf", "linked/actions.vdf", "../outside/actions.vdf", "/etc/hosts", "input", "input/../input/actions.vdf", "C:actions.vdf"] {
            require(Names.load(hintKnown: true, manifestPath: path, gameDirectory: game) == .unreadable, "unreadable or escaping manifest path: \(path)")
        }
        // A path the running game registered outranks the app-data hint and is confined the same way.
        let runtime = Names.load(hintKnown: true, manifestPath: "input/actions.vdf", runtimePath: "C:\\lib\\common\\Game\\runtime.vdf",
                                 gameDirectory: game, windowsDirectory: "C:/lib/common/Game")
        require(runtime.manifest?.set("InGameControls").map { runtime.manifest!.name(of: $0) } == "Runtime Controls", "runtime manifest path outranks the hint")
        require(Names.load(hintKnown: true, manifestPath: "input/actions.vdf", runtimePath: "C:\\elsewhere\\runtime.vdf",
                           gameDirectory: game, windowsDirectory: "C:/lib/common/Game") == .unreadable, "a runtime path outside the game is refused, not replaced by the hint")
        for unresolved in [Names.notInstalled, .notBundled, .dataUnavailable, .unreadable] {
            require(unresolved.manifest == nil && !(unresolved.explanation ?? "").isEmpty, "every unresolved source says why")
        }
        require(try snapshot(temp) == before, "reading action names writes nothing")

        // =============================================================
        // 3. Binding grammar as Steam writes it
        // =============================================================
        func verb(_ raw: String) -> Binding.Verb { Binding(raw: raw).verb }
        require(verb("xinput_button A, , ") == .xinputButton("A"))
        require(verb("key_press SPACE, Jump, ") == .keyPress("SPACE"))
        require(verb("mouse_button LEFT") == .mouseButton("LEFT"))
        require(verb("mouse_wheel SCROLL_UP") == .mouseWheel("SCROLL_UP"))
        require(verb("game_action InGameControls Jump, Jump, ") == .gameAction(setID: "InGameControls", actionID: "Jump"))
        require(verb("mode_shift right_joystick 5, Hold for weapon wheel, ") == .modeShift(source: "right_joystick", groupID: "5"))
        require(verb("mode_shift RIGHT_TRACKPAD 8") == .modeShift(source: "right_trackpad", groupID: "8"))
        require(verb("controller_action CHANGE_PRESET 2 1 1") == .actionSetChange(preset: 2))
        require(verb("controller_action CHANGE_PRESET 2, Menu set, ") == .actionSetChange(preset: 2))
        require(verb("controller_action add_layer 2 0 0, Aim Down Sights (Toggle)") == .layerChange(.add, preset: 2))
        require(verb("controller_action remove_layer 2 0 0, Default") == .layerChange(.remove, preset: 2))
        require(verb("controller_action hold_layer 3, Touchpad grid, ") == .layerChange(.hold, preset: 3))
        require(verb("controller_action SHOW_KEYBOARD") == .steamAction(command: "SHOW_KEYBOARD", arguments: []))
        require(verb("controller_action set_led 0 255 255 100 255 0, , special_blank.png #232323 #E4E4E4") == .steamAction(command: "set_led", arguments: ["0", "255", "255", "100", "255", "0"]))
        // Malformed references are not guessed at.
        for malformed in ["mode_shift 5", "mode_shift a b c", "controller_action CHANGE_PRESET", "controller_action CHANGE_PRESET 0",
                          "controller_action add_layer two", "controller_action hold_layer -1", "controller_action CHANGE_PRESET 02",
                          "game_action OnlySet", "controller_action", "warp_drive 9"] {
            guard case .unverified = verb(malformed) else { fatalError("malformed binding interpreted: \(malformed)") }
        }
        // Three comma-separated fields: command, label, icon.
        func fields(_ raw: String) -> [String?] { let b = Binding(raw: raw); return [b.label, b.icon] }
        require(fields("xinput_button A, , ") == [nil, nil], "empty label and icon")
        require(fields("key_press SPACE, Jump, ") == ["Jump", nil])
        require(fields("key_press SPACE, Jump") == ["Jump", nil])
        require(fields("key_press A, Hello, world") == ["Hello, world", nil], "a comma inside a label is kept")
        require(fields("key_press A, Hello, world, ") == ["Hello, world", nil])
        require(fields("controller_action set_led 0 255 255 100 255 0, , special_blank.png #232323 #E4E4E4") == [nil, "special_blank.png #232323 #E4E4E4"])
        require(fields("key_press Q, Swap, @icon.svg #000000 #FFFFFF") == ["Swap", "@icon.svg #000000 #FFFFFF"])
        require(Binding(raw: "key_press SPACE, Jump, ").displayText == "Space (Jump)", "the label is shown without the field separator")

        // =============================================================
        // 4. References to groups, action sets and layers
        // =============================================================
        /// A version-3 layout in the shape Steam writes: two action sets, one
        /// layer, a mode shift, set and layer changes and named game actions.
        func layout(buttonA: String = "game_action InGame Jump, Jump, ",
                    bumper: String = "mode_shift right_joystick 5, Weapon wheel, ",
                    menu: String = "controller_action CHANGE_PRESET 2 1 1, Menus, ",
                    back: String = "controller_action add_layer 3 0 0, Driving, ",
                    presetZero: String = #""0" "button_diamond active" "1" "joystick active" "3" "switch active" "5" "right_joystick active modeshift""#,
                    layerParent: String = "InGame", moveSet: String = "InGame", extra: String = "", actions: Bool = true) -> Data {
            let declared = actions ? """
                "actions"
                {
                    "InGame" { "title" "In Game" "legacy_set" "0" }
                    "Menu" { "title" "Menu" "legacy_set" "0" }
                }
                "action_layers"
                {
                    "Driving" { "title" "Driving" "legacy_set" "0" "set_layer" "1" "parent_set_name" "\(layerParent)" }
                }
            """ : ""
            return Data("""
            "controller_mappings"
            {
                "version" "3"
                "revision" "6"
                "title" "References"
                "controller_type" "controller_ps5"
                \(declared)
                "group"
                {
                    "id" "0"
                    "mode" "four_buttons"
                    "inputs" { "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "\(buttonA)" } } } } }
                }
                "group"
                {
                    "id" "1"
                    "mode" "joystick_move"
                    "gameactions" { "\(moveSet)" "Move" }
                }
                "group"
                {
                    "id" "3"
                    "mode" "switches"
                    "inputs"
                    {
                        "left_bumper" { "activators" { "Full_Press" { "bindings" { "binding" "\(bumper)" } } } }
                        "button_escape" { "activators" { "Full_Press" { "bindings" { "binding" "\(menu)" } } } }
                        "button_menu" { "activators" { "Full_Press" { "bindings" { "binding" "\(back)" } } } }
                    }
                }
                "group"
                {
                    "id" "5"
                    "mode" "dpad"
                    "inputs" { "dpad_north" { "activators" { "Full_Press" { "bindings" { "binding" "key_press 1, Weapon 1, " } } } } }
                }
                "group"
                {
                    "id" "6"
                    "mode" "four_buttons"
                    "inputs" { "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action CHANGE_PRESET 1 1 1, Back, " } } } } }
                }
                "group"
                {
                    "id" "7"
                    "mode" "four_buttons"
                    "inputs" { "button_b" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action remove_layer 3 0 0, Stop, " } } } } }
                }
                "preset" { "id" "0" "name" "InGame" "group_source_bindings" { \(presetZero) } }
                "preset" { "id" "1" "name" "Menu" "group_source_bindings" { "6" "button_diamond active" } }
                "preset" { "id" "2" "name" "Driving" "group_source_bindings" { "7" "button_diamond active" } }
                \(extra)
            }
            """.utf8)
        }
        func problems(_ bytes: Data) throws -> [SteamInputReferenceProblem] {
            SteamInputReferences.problems(in: try Model(document: try VDFDocument.parse(bytes)))
        }
        /// The reason apply validation gives for refusing, or nil when the layout is accepted.
        func refusal(_ bytes: Data) -> String? {
            do { _ = try SteamInputCompatibility(bytes); return nil }
            catch let error as SteamInputReferenceError { return error.errorDescription }
            catch { return "other: \(error)" }
        }

        let sound = layout()
        require(try problems(sound).isEmpty, "a layout whose references all resolve has no problems")
        require(refusal(sound) == nil, "and apply validation accepts it")
        require(try SteamInputCompatibility(sound).canApply)

        // Each broken reference alone: found, refused before apply, and explained.
        let broken: [(String, Data, SteamInputReferenceProblem.Kind, String)] = [
            ("preset to missing group", layout(presetZero: #""0" "button_diamond active" "12" "joystick active" "3" "switch active" "5" "right_joystick active modeshift""#),
             .missingGroup, "Preset 'InGame' assigns left stick to group 12, which the layout does not define."),
            ("inactive preset entry to missing group", layout(presetZero: #""0" "button_diamond active" "1" "joystick active" "3" "switch active" "5" "right_joystick active modeshift" "13" "gyro inactive""#),
             .missingGroup, "Preset 'InGame' assigns gyro to group 13, which the layout does not define."),
            ("mode shift to missing group", layout(bumper: "mode_shift right_joystick 99, Weapon wheel, "),
             .missingGroup, "A mode shift on L1 (LB) in group 3 switches right stick to group 99, which the layout does not define."),
            ("action set change to missing preset", layout(menu: "controller_action CHANGE_PRESET 7 1 1, Menus, "),
             .missingPreset, "Options (Menu) in group 3 changes to the action set stored as preset 7, which the layout does not define."),
            ("layer change to missing preset", layout(back: "controller_action add_layer 9 0 0, Driving, "),
             .missingPreset, "Create / Share (View) in group 3 adds the layer stored as preset 9, which the layout does not define."),
            ("layer with missing parent set", layout(layerParent: "Nowhere"),
             .missingActionSet, "Layer 'Driving' extends action set 'Nowhere', which the layout does not define."),
            ("game action in undeclared set", layout(buttonA: "game_action Ghost Jump, Jump, "),
             .missingActionSet, "Cross (A) in group 0 triggers the game action Ghost › Jump in action set 'Ghost', which the layout does not define."),
            ("analog game action in undeclared set", layout(moveSet: "Ghost"),
             .missingActionSet, "Group 1 drives the game action Ghost › Move in action set 'Ghost', which the layout does not define."),
            ("group defined twice", layout(extra: #""group" { "id" "5" "mode" "four_buttons" }"#),
             .ambiguousGroup, "Group 5 is defined 2 times, so the bindings that use it are ambiguous."),
            ("unreferenced group defined twice", layout(extra: #""group" { "id" "40" "mode" "dpad" } "group" { "id" "40" "mode" "dpad" }"#),
             .ambiguousGroup, "Group 40 is defined 2 times, so the bindings that use it are ambiguous."),
            ("preset defined twice and referenced", layout(extra: #""preset" { "id" "1" "name" "Menu" "group_source_bindings" { "6" "button_diamond active" } }"#),
             .ambiguousPreset, "Options (Menu) in group 3 changes to the action set stored as preset 2, which the layout defines 2 times."),
            ("action set declared twice and referenced", layout(extra: #""actions" { "InGame" { "title" "Again" "legacy_set" "0" } }"#),
             .ambiguousActionSet, "Layer 'Driving' extends action set 'InGame', which the layout defines 2 times."),
        ]
        for (name, bytes, kind, reason) in broken {
            let found = try problems(bytes)
            require(found.contains { $0.kind == kind && $0.reason == reason }, "\(name): expected \(reason), found \(found.map(\.reason))")
            guard let message = refusal(bytes) else { fatalError("\(name): accepted for apply") }
            require(message.hasPrefix("This layout cannot be applied. "), "\(name): refusal is a reference refusal: \(message)")
            require(message.contains(found[0].reason), "\(name): the player is told why: \(message)")
        }
        // A game action in a layout that declares no action sets at all has nothing to name.
        require(try problems(layout(actions: false)).contains { $0.kind == .missingActionSet }, "no actions block: game actions are dangling")
        // The sets the model derives from presets for display are not declarations a game action can name.
        require(try problems(layout(buttonA: "game_action 0 Jump, Jump, ", moveSet: "0", actions: false)).filter { $0.kind == .missingActionSet }.count == 2,
                "a preset-derived set is not a declared action set")
        // Several problems: each reported once, with distinct identifiers, and the refusal counts the rest.
        let several = layout(buttonA: "game_action Ghost Jump, Jump, ", bumper: "mode_shift right_joystick 99, , ", menu: "controller_action CHANGE_PRESET 7 1 1, , ")
        let severalFound = try problems(several)
        require(severalFound.count == 3 && Set(severalFound.map(\.id)).count == 3 && Set(severalFound.map(\.reason)).count == 3)
        require(refusal(several)?.hasSuffix(" It has 2 more broken references.") == true)
        let repeated = layout(extra: #""group" { "id" "8" "mode" "switches" "inputs" { "left_bumper" { "activators" { "Full_Press" { "bindings" { "binding" "mode_shift joystick 77" "binding" "mode_shift joystick 77" } } } } } }"#)
        require(try problems(repeated).count == 1, "the same broken reference written twice is reported once")

        // What is deliberately not a broken reference.
        let legacyNoSets = Data(#""controller_mappings" { "version" "3" "revision" "2" "controller_type" "controller_ps5" "group" { "id" "0" "mode" "four_buttons" "inputs" { "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "xinput_button A" } } } } } } "preset" { "id" "0" "name" "Default" "group_source_bindings" { "0" "button_diamond active" } } }"#.utf8)
        require(try problems(legacyNoSets).isEmpty && refusal(legacyNoSets) == nil, "a layout with presets and no actions block is sound")
        require(try problems(layout(buttonA: "controller_action SHOW_KEYBOARD")).isEmpty, "a Steam action names nothing in the layout")
        require(try problems(layout(buttonA: "mode_shift 99")).isEmpty, "a binding that is not a readable reference is not reported as one")
        require(try problems(layout(buttonA: "game_action driving Horn, Horn, ")).isEmpty, "a game action may name a layer, matched without regard to case")

        // The existing protections still hold and still come first.
        let conditional = Data(String(decoding: sound, as: UTF8.self).replacingOccurrences(of: #""mode" "dpad""#, with: #""mode" "dpad" [$WIN32]"#).utf8)
        require(conditional != sound)
        do { _ = try SteamInputCompatibility(conditional); fatalError("conditional layout accepted") }
        catch let error as SteamFileError { require(error.localizedDescription.contains("Conditional layouts are not supported yet.")) }
        let conditionalAndBroken = Data(String(decoding: layout(bumper: "mode_shift right_joystick 99"), as: UTF8.self).replacingOccurrences(of: #""mode" "dpad""#, with: #""mode" "dpad" [$WIN32]"#).utf8)
        do { _ = try SteamInputCompatibility(conditionalAndBroken); fatalError("conditional layout accepted") }
        catch let error as SteamFileError { require(error.localizedDescription.contains("Conditional layouts are not supported yet.")) }
        let unsupported = Data(String(decoding: sound, as: UTF8.self).replacingOccurrences(of: #""1" "joystick active""#, with: #""1" "gyro active""#).utf8)
        require(try SteamInputCompatibility(unsupported).canApply == false, "an unforwarded input is still reported as unavailable")

        // =============================================================
        // 5. Refused on the way in: nothing is cached, nothing can be applied
        // =============================================================
        typealias Sources = SteamInputCommunitySources
        let community = temp.appendingPathComponent("community", isDirectory: true)
        var payload = sound
        func item(_ id: UInt64, _ source: Data) -> SteamWorkshopItem {
            var value = SteamWorkshopItem(id: id, appID: 241100, result: 1)
            value.title = "Fixture \(id)"; value.fileURL = "https://ugc.steamusercontent.com/fixture"
            value.fileSize = UInt64(source.count); value.timeUpdated = 1; value.fileType = 12
            value.tags = ["controller_ps5"]
            value.kvTags = [.init(key: "app", value: "480"), .init(key: "visibility", value: "public"), .init(key: "deleted", value: "0")]
            return value
        }
        var current = item(1, sound)
        let sources = Sources(root: community, query: { _, _, _, _ in fatalError("no listing") },
                              details: { _ in [current] }, download: { _ in payload })
        let kept = try await sources.download(appID: 480, item: current)
        require(kept.compatibility.canApply && kept.bytes == sound)
        let cached = try snapshot(community)
        for (name, bytes, _, reason) in broken {
            payload = bytes; current = item(2, bytes)
            do { _ = try await sources.download(appID: 480, item: current); fatalError("\(name): downloaded for apply") }
            catch let error as SteamInputReferenceError { require(error.localizedDescription.contains(reason), "\(name): \(error.localizedDescription)") }
            require(try snapshot(community) == cached, "\(name): a refused layout is not cached")
        }
        require(try sources.cached(appID: 480, id: 2).isEmpty)
        require(try sources.downloaded(appID: 480).map(\.item.id) == [1])
        // Steam's own saved Workshop selection goes through the same gate.
        do { _ = try await sources.selectedWorkshop(appID: 480, itemID: 2); fatalError("broken selected layout supplied as a baseline") }
        catch let error as SteamInputReferenceError { require(!(error.errorDescription ?? "").isEmpty) }
        // A read-only preview of the same broken layout still opens and names every problem.
        payload = several; current = item(3, several)
        let preview = try await sources.preview(appID: 480, item: current, actions: .notInstalled)
        let shown = preview.diagnoses.filter { $0.id.hasPrefix("diag-reference-") }
        require(shown.allSatisfy { $0.category == .unresolvedReference })
        require(shown.map(\.detail) == severalFound.map(\.reason) && Set(shown.map(\.id)).count == 3, "the preview lists the same problems apply validation refuses")
        require(!preview.isFullyCompatible)
        require(try snapshot(community) == cached, "previewing a broken layout writes nothing")

        print("PASS: action manifest names and confinement, real binding grammar, group/action set/layer reference validation, readable refusal before apply, and existing protections retained")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-input-actions-') as temporary:
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
                    str(app/'SteamInputCommunity.swift'), str(tmp/'workshop.swift'), str(tmp/'main.swift'), str(tmp/'service.o'), '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp/'roots')], check=True)
