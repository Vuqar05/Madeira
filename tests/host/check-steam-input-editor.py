#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Milestone 4 items 1 and 6: the editable Steam Input layout model and the
structural lossless VDF writer. Every edit runs through the production
`SteamInputLayoutDraft` and `VDFDocument` code under AddressSanitizer and is
checked to change only its own bytes: unknown fields, repeated keys, comments,
ordering and every condition elsewhere stay byte for byte.

Optional: MADEIRA_STEAM_LAYOUT_CORPUS=<dir> also sweeps every .vdf beneath a
local directory of real layouts (read only; nothing is copied or written).
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
probe_fixture = root / 'madeira-dock/tests/fixtures/steam-input-revision-probe.vdf'

program = r'''
import Foundation

func require(_ body: @autoclosure () throws -> Bool, _ message: String = "precondition failed", file: StaticString = #file, line: UInt = #line) {
    do { let result = try body(); precondition(result, message, file: file, line: line) }
    catch { preconditionFailure("\(message): \(error)", file: file, line: line) }
}
func refusal(_ body: () throws -> Any) -> String {
    do { _ = try body(); return "" } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
}
func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
func occurrences(_ needle: String, _ data: Data) -> Int { text(data).components(separatedBy: needle).count - 1 }

/// The bytes that differ between two versions form one contiguous region:
/// everything before and after it is identical. Returns (prefix, removed, inserted).
func splice(_ old: Data, _ new: Data) -> (prefix: Int, removed: String, inserted: String) {
    let a = [UInt8](old), b = [UInt8](new)
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
    return (prefix, String(decoding: a[prefix..<(a.count - suffix)], as: UTF8.self), String(decoding: b[prefix..<(b.count - suffix)], as: UTF8.self))
}

/// Every condition, unknown field and the comment in the fixture, with their counts.
let preserved = ["[$WIN32]", "[$OSX]", "[$LINUX]", "[!$PS3]", "\"future_block\"", "\"kept\" \"exactly\"",
                 "// trailing comment", "\"unknown_leaf\" \"x\"", "\"mystery_activator_field\" \"9\"",
                 "\"repeated\" \"1\"", "\"repeated\" \"2\"", "\"group_extra\" { \"nested\" \"value\" }"]

@main struct CheckEditor {
    static func main() throws {
        let probe = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let corpus = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

        // =============================================================
        // 1. Structural writer: insert, remove, rename and set, each one splice
        // =============================================================
        let tabs = Data("\"root\"\n{\n\t\"a\"\t\t\"1\"\n\t\"block\"\n\t{\n\t\t\"x\"\t\t\"y\" [$WIN32]\n\t}\n\t\"empty\"\n\t{\n\t}\n\t\"inline\" { \"k\" \"v\" }\n\t\"bare\" { }\n}\n".utf8)
        let doc = try VDFDocument.parse(tabs)
        let rootPath = VDFPath([.init("root")])
        let appended = try doc.inserting(.leaf("b", "2"), into: rootPath)
        require(text(appended.sourceData) == text(tabs).replacingOccurrences(of: "\t\"bare\" { }\n}", with: "\t\"bare\" { }\n\t\"b\"\t\t\"2\"\n}"),
                "an appended leaf gets its own line with the siblings' indentation: \(text(appended.sourceData))")
        let first = try doc.inserting(.leaf("z", "0"), into: rootPath, at: 0)
        require(text(first.sourceData).hasPrefix("\"root\"\n{\n\t\"z\"\t\t\"0\"\n\t\"a\""), "inserting before the first child")
        let intoEmpty = try doc.inserting(.block("new", [.leaf("k", "v")]), into: VDFPath([.init("root"), .init("empty")]))
        require(text(intoEmpty.sourceData).contains("\t\"empty\"\n\t{\n\t\t\"new\"\n\t\t{\n\t\t\t\"k\"\t\t\"v\"\n\t\t}\n\t}"), "a block in an empty block")
        let intoInline = try doc.inserting(.leaf("k2", "v2"), into: VDFPath([.init("root"), .init("inline")]))
        require(intoInline.findValueToken(at: VDFPath([.init("root"), .init("inline"), .init("k2")])).map(intoInline.stringValue(for:)) == "v2")
        require(intoInline.findValueToken(at: VDFPath([.init("root"), .init("inline"), .init("k")])).map(intoInline.stringValue(for:)) == "v", "an inline block keeps its leaf")
        let intoBare = try doc.inserting(.leaf("k", "v"), into: VDFPath([.init("root"), .init("bare")]))
        require(intoBare.count("k", in: VDFPath([.init("root"), .init("bare")])) == 1)
        let removed = try doc.removing(at: VDFPath([.init("root"), .init("block")]))
        require(text(removed.sourceData) == text(tabs).replacingOccurrences(of: "\t\"block\"\n\t{\n\t\t\"x\"\t\t\"y\" [$WIN32]\n\t}\n", with: ""),
                "a removed block takes its whole lines and its own condition")
        let renamed = try doc.renamingKey(at: VDFPath([.init("root"), .init("block"), .init("x")]), to: "w")
        require(splice(tabs, renamed.sourceData) == (splice(tabs, renamed.sourceData).prefix, "x", "w") && occurrences("[$WIN32]", renamed.sourceData) == 1,
                "renaming changes the key only, keeping the value and its condition")
        let set = try doc.settingLeaf("x", to: "z", in: VDFPath([.init("root"), .init("block")]))
        require(text(set.sourceData).contains("\"x\"\t\t\"z\" [$WIN32]"), "setting a conditional leaf keeps its condition")
        let unset = try doc.settingLeaf("a", to: nil, in: rootPath)
        require(text(unset.sourceData) == text(tabs).replacingOccurrences(of: "\t\"a\"\t\t\"1\"\n", with: ""))
        // Repeated keys: the last occurrence is the one read, so it is the one set; removal takes all.
        let repeated = try VDFDocument.parse(Data("\"r\" { \"k\" \"1\" \"k\" \"2\" }".utf8))
        let r2 = try repeated.settingLeaf("k", to: "3", in: VDFPath([.init("r")]))
        require(text(r2.sourceData) == "\"r\" { \"k\" \"1\" \"k\" \"3\" }", text(r2.sourceData))
        require(try repeated.settingLeaf("k", to: nil, in: VDFPath([.init("r")])).count("k", in: VDFPath([.init("r")])) == 0)
        // Line endings and indentation follow the source.
        let crlf = try VDFDocument.parse(Data("\"root\"\r\n{\r\n    \"a\" \"1\"\r\n}\r\n".utf8))
        let crlfAdded = try crlf.inserting(.leaf("b", "2"), into: rootPath)
        require(text(crlfAdded.sourceData) == "\"root\"\r\n{\r\n    \"a\" \"1\"\r\n    \"b\"\t\t\"2\"\r\n}\r\n", "CRLF and four-space indentation are kept")
        let noNewline = try VDFDocument.parse(Data("\"root\" {\n\"a\" \"1\"\n}".utf8))
        require(try noNewline.inserting(.leaf("b", "2"), into: rootPath).count("b", in: rootPath) == 1)
        // A value with quotes, backslashes and newlines round-trips through escapes.
        let escaped = try doc.settingLeaf("a", to: "say \"hi\"\\\nnext", in: rootPath)
        require(escaped.findValueToken(at: VDFPath([.init("root"), .init("a")])).map(escaped.stringValue(for:)) == "say \"hi\"\\\nnext")
        // Refusals.
        require(refusal { try doc.inserting(.leaf("k", "v"), into: VDFPath([.init("root"), .init("a")])) } != "", "a leaf has no children")
        require(refusal { try doc.inserting(.leaf("k", "v"), into: VDFPath([.init("missing")])) } != "")
        require(refusal { try doc.inserting(.leaf("", "v"), into: rootPath) } != "")
        require(refusal { try doc.inserting(.leaf("k", "v"), into: rootPath, at: 99) } != "")
        require(refusal { try doc.removing(at: VDFPath([.init("root"), .init("nothing")])) } != "")
        require(refusal { try doc.renamingKey(at: rootPath, to: "") } != "")
        // A copy of a node is its exact source text, conditions included.
        let copied = try doc.insertingCopy(of: VDFPath([.init("root"), .init("block")]), into: rootPath)
        require(occurrences("[$WIN32]", copied.sourceData) == 2 && copied.count("block", in: rootPath) == 2)

        // =============================================================
        // 2. Editable model: every edit is one splice; nothing else changes
        // =============================================================
        let fixture = """
        // header comment
        "controller_mappings" [!$PS3]
        {
        \t"version"\t\t"3"
        \t"revision"\t\t"5"
        \t"title"\t\t"Editor fixture"
        \t"controller_type"\t\t"controller_ps5"
        \t"future_block" { "kept" "exactly" }
        \t"unknown_leaf" "x"
        \t"actions"
        \t{
        \t\t"Default"
        \t\t{
        \t\t\t"title"\t\t"Default"
        \t\t\t"legacy_set"\t\t"1"
        \t\t}
        \t}
        \t"group"
        \t{
        \t\t"id"\t\t"0"
        \t\t"mode"\t\t"four_buttons"
        \t\t"group_extra" { "nested" "value" }
        \t\t"inputs"
        \t\t{
        \t\t\t"button_a"
        \t\t\t{
        \t\t\t\t"activators"
        \t\t\t\t{
        \t\t\t\t\t"Full_Press"
        \t\t\t\t\t{
        \t\t\t\t\t\t"bindings"
        \t\t\t\t\t\t{
        \t\t\t\t\t\t\t"binding"\t\t"xinput_button A, Jump, icon.png"
        \t\t\t\t\t\t\t"binding"\t\t"key_press SPACE, , " [$WIN32]
        \t\t\t\t\t\t}
        \t\t\t\t\t\t"mystery_activator_field" "9"
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t\t"disabled_activators"
        \t\t\t\t{
        \t\t\t\t}
        \t\t\t}
        \t\t\t"button_b" [$OSX]
        \t\t\t{
        \t\t\t\t"activators"
        \t\t\t\t{
        \t\t\t\t\t"Full_Press"
        \t\t\t\t\t{
        \t\t\t\t\t\t"bindings"
        \t\t\t\t\t\t{
        \t\t\t\t\t\t\t"binding"\t\t"xinput_button B, , "
        \t\t\t\t\t\t}
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t\t"settings"
        \t\t{
        \t\t\t"repeated" "1"
        \t\t\t"repeated" "2"
        \t\t}
        \t}
        \t"group"
        \t{
        \t\t"id"\t\t"1"
        \t\t"mode"\t\t"joystick_move"
        \t\t"inputs"
        \t\t{
        \t\t}
        \t\t"settings" [$LINUX]
        \t\t{
        \t\t\t"deadzone_inner_radius"\t\t"1000"
        \t\t}
        \t}
        \t"preset"
        \t{
        \t\t"id"\t\t"0"
        \t\t"name"\t\t"Default"
        \t\t"group_source_bindings"
        \t\t{
        \t\t\t"0"\t\t"button_diamond active"
        \t\t\t"1"\t\t"joystick active"
        \t\t}
        \t}
        } // trailing comment

        """
        let original = Data(fixture.utf8)
        let draft = try SteamInputLayoutDraft(bytes: original)
        require(draft.bytes == original && draft.notEditableReason == nil && draft.referenceProblems.isEmpty)
        let conditionSites = draft.model.conditionSites.count
        require(conditionSites == 4, "fixture conditions: \(conditionSites)")
        let unknownRaw = Set(draft.model.unrecognizedEntries.map(\.rawContent))
        require(unknownRaw.contains("\"future_block\" { \"kept\" \"exactly\" }") && unknownRaw.contains("\"unknown_leaf\" \"x\"")
                && unknownRaw.contains("\"mystery_activator_field\" \"9\"") && unknownRaw.contains("\"group_extra\" { \"nested\" \"value\" }"),
                "unsupported fields are listed with their exact text: \(unknownRaw)")
        require(draft.model.unrecognizedEntries.allSatisfy { $0.nodePath != nil }, "each unsupported field is addressable, so it can be shown in place")

        func check(_ name: String, _ before: SteamInputLayoutDraft, _ after: SteamInputLayoutDraft, removing: [String] = []) {
            for needle in preserved {
                let expected = occurrences(needle, before.bytes) - (removing.contains(needle) ? 1 : 0)
                // Copying a set copies its groups, so a count can grow; it never shrinks.
                require(occurrences(needle, after.bytes) >= expected, "\(name): `\(needle)` must be preserved (\(occurrences(needle, after.bytes)) vs \(expected))")
                if removing.contains(needle) {
                    require(occurrences(needle, after.bytes) == expected, "\(name): `\(needle)` goes with the removed node")
                }
            }
            require(Set(after.model.unrecognizedEntries.map(\.rawContent)).isSuperset(of: Set(before.model.unrecognizedEntries.map(\.rawContent)).subtracting(removing)),
                    "\(name): no unsupported field is lost")
            require(after.model.conditionSites.count >= before.model.conditionSites.count - removing.filter { $0.hasPrefix("[") }.count,
                    "\(name): conditions are kept")
        }

        let group0 = draft.model.groupDefinitions[0], group1 = draft.model.groupDefinitions[1]
        let buttonA = group0.input("button_a")!, buttonB = group0.input("button_b")!
        let press = buttonA.activators[0]
        let preset = draft.model.presets[0]

        // Title and description.
        var next = try draft.settingTitle("Renamed layout")
        check("title", draft, next)
        require(next.model.title == "Renamed layout" && splice(draft.bytes, next.bytes).removed == "Editor fixture")
        let described = try next.settingDescription("My notes")
        require(described.model.description == "My notes")
        check("description", next, described)
        require(refusal { try draft.settingTitle("  ") } == "Enter a title.")
        require(refusal { try draft.settingTitle("a\u{7}b") }.contains("cannot hold"))

        // Binding replacement keeps the icon field and the other binding's condition.
        next = try draft.replacingBinding(at: press.bindings[0].path, with: .key("E"), label: "Use")
        check("replace binding", draft, next)
        require(next.binding(at: press.bindings[0].path)?.rawString == "key_press E, Use, icon.png", "the icon field is kept")
        require(next.binding(at: press.bindings[0].path)?.verb == .keyPress("E"))
        require(next.binding(at: press.bindings[1].path)?.conditions.map(\.expression) == ["[$WIN32]"], "the neighbouring conditional binding is untouched")
        // Every editable command round-trips through the model.
        let commands: [SteamInputBindingCommand] = [.gamepad("TRIGGER_LEFT"), .key("LEFT_SHIFT"), .mouseButton("MIDDLE"), .mouseWheel(up: false),
            .gameAction(set: "Default", action: "Jump"), .modeShift(source: "joystick", groupID: "1"), .changeActionSet(preset: 1), .layer(.hold, preset: 1)]
        for command in commands {
            let edited = try draft.replacingBinding(at: press.bindings[0].path, with: command, label: nil)
            let parsed = edited.binding(at: press.bindings[0].path)!
            require(SteamInputBindingCommand(parsed.verb) == command, "\(command) round-trips: \(parsed.rawString)")
            check("command \(command)", draft, edited)
        }
        require(SteamInputBindingCommand.layer(.add, preset: 3).command == "controller_action add_layer 3 0 0")
        require(SteamInputBindingCommand.changeActionSet(preset: 2).command == "controller_action CHANGE_PRESET 2 1 1")
        require(refusal { try draft.replacingBinding(at: press.bindings[0].path, with: .gamepad("Z"), label: nil) } == "That binding is not one Steam Input accepts.")
        require(refusal { try draft.replacingBinding(at: press.bindings[0].path, with: .key("A B"), label: nil) } == "That binding is not one Steam Input accepts.")
        require(refusal { try draft.replacingBinding(at: press.bindings[0].path, with: .key("A"), label: "a,b") } == "A binding label cannot contain a comma.")

        // Chords: several bindings on one activator fire together.
        next = try draft.addingBinding(.key("LEFT_CONTROL"), label: "Copy", to: press.path).addingBinding(.key("C"), label: nil, to: press.path)
        check("chord", draft, next)
        require(next.activator(at: press.path)?.bindings.map(\.rawString) == ["xinput_button A, Jump, icon.png", "key_press SPACE, , ", "key_press LEFT_CONTROL, Copy, ", "key_press C, , "])
        let unbound = try next.removingBinding(at: next.activator(at: press.path)!.bindings[1].path)
        check("remove conditional binding", next, unbound, removing: ["[$WIN32]"])
        require(unbound.activator(at: press.path)?.bindings.count == 3)

        // Activators: add, change kind, toggle, turbo, settings, remove.
        next = try draft.addingActivator("Long_Press", to: buttonA.path)
        check("add activator", draft, next)
        let long = next.input(at: buttonA.path)!.activators.last!
        require(long.kind == "Long_Press" && long.bindings.isEmpty)
        next = try next.addingBinding(.gamepad("Y"), label: nil, to: long.path)
        next = try next.changingActivator(at: long.path, to: "Double_Press")
        // A renamed activator has a new path: the editor reads it back from the model.
        let double = next.input(at: buttonA.path)!.activators.last!
        require(next.activator(at: long.path) == nil && double.kind == "Double_Press" && double.bindings.first?.verb == .xinputButton("Y"))
        next = try next.settingToggle(true, at: double.path).settingTurbo(true, rate: 50, at: double.path)
        var activator = next.activator(at: double.path)!
        require(activator.toggle && activator.turbo && activator.settings["repeat_rate"] == "50", "toggle and turbo read back: \(activator.settings)")
        next = try next.settingTurbo(false, at: double.path).settingActivatorSetting("double_tap_time", to: "300", at: double.path)
        activator = next.activator(at: double.path)!
        require(!activator.turbo && activator.settings["double_tap_time"] == "300")
        check("activator settings", draft, next)
        let withoutLong = try next.removingActivator(at: double.path)
        require(withoutLong.input(at: buttonA.path)!.activators.count == 1)
        require(withoutLong.bytes == draft.bytes, "adding then removing an activator restores the original bytes exactly")
        // The original activator's unknown field survives editing its settings.
        let pressSettings = try draft.settingToggle(true, at: press.path)
        require(occurrences("\"mystery_activator_field\" \"9\"", pressSettings.bytes) == 1 && pressSettings.activator(at: press.path)!.toggle)
        require(refusal { try draft.addingActivator("Mega_Press", to: buttonA.path) } == "Choose an activator.")

        // Inputs and group settings: dead zones, curves.
        next = try draft.addingInput("button_x", to: group0.path)
        check("add input", draft, next)
        require(next.group(at: group0.path)?.input("button_x")?.activators.first?.kind == "Full_Press")
        require(refusal { try draft.addingInput("button_a", to: group0.path) } == "This group already has that input.")
        next = try draft.settingGroupSetting("deadzone_inner_radius", to: "2000", at: group1.path)
            .settingGroupSetting("curve_exponent", to: "2", at: group1.path)
        check("group settings", draft, next)
        require(next.group(at: group1.path)?.settings == ["deadzone_inner_radius": "2000", "curve_exponent": "2"])
        require(occurrences("[$LINUX]", next.bytes) == 1, "a conditional settings block keeps its condition when its values change")
        next = try draft.settingGroupSetting("repeated", to: "3", at: group0.path)
        require(text(next.bytes).contains("\"repeated\" \"1\"") && next.group(at: group0.path)?.settings["repeated"] == "3",
                "a repeated setting changes where it is read (the last) and the first is kept")
        require(refusal { try draft.settingGroupSetting("bad key", to: "1", at: group0.path) }.contains("letters, digits or underscores"))
        require(refusal { try draft.settingGroupSetting("x", to: "\n", at: group0.path) }.contains("short number"))

        // Modes switch as Steam does: the old group is kept inactive and switching back restores it.
        next = try draft.switchingMode(of: "button_diamond", in: preset.path, to: "dpad")
        check("switch mode", draft, next)
        var sources = next.preset(at: preset.path)!.bindings.filter { $0.source == "button_diamond" }
        require(sources.map(\.groupID) == ["0", "2"] && sources.map(\.isActive) == [false, true], "\(sources)")
        require(next.group(at: VDFPath(draft.model.rootPath.steps + [.init("group", index: 2)]))?.mode == "dpad")
        require(next.referenceProblems.isEmpty)
        let back = try next.switchingMode(of: "button_diamond", in: preset.path, to: "four_buttons")
        sources = back.preset(at: preset.path)!.bindings.filter { $0.source == "button_diamond" }
        require(sources.map(\.isActive) == [true, false], "switching back reactivates the original group with its bindings")
        require(back.group(at: group0.path)?.input("button_a")?.activators.first?.bindings.count == 2)
        require(try next.switchingMode(of: "button_diamond", in: preset.path, to: "dpad").bytes == next.bytes, "the current mode is a no-op")
        require(refusal { try draft.switchingMode(of: "button_diamond", in: preset.path, to: "flickstick") } == "That mode is not available for this input.")
        // Gyro and touchpad are sources too; assigning one adds its group.
        next = try draft.switchingMode(of: "gyro", in: preset.path, to: "mouse_joystick")
            .switchingMode(of: "center_trackpad", in: preset.path, to: "touch_menu")
        require(next.preset(at: preset.path)!.bindings.filter(\.isActive).map(\.source).sorted() == ["button_diamond", "center_trackpad", "gyro", "joystick"])
        let menuGroup = next.model.groupDefinitions.first { $0.mode == "touch_menu" }!
        next = try next.settingGroupSetting("touch_menu_button_count", to: "4", at: menuGroup.path).addingInput("touch_menu_button_0", to: menuGroup.path)
        let menuInput = next.group(at: menuGroup.path)!.input("touch_menu_button_0")!
        next = try next.addingBinding(.key("1"), label: "Slot 1", to: menuInput.activators[0].path)
        require(next.group(at: menuGroup.path)?.input("touch_menu_button_0")?.activators[0].bindings.first?.label == "Slot 1", "menu bindings are edited like any other")
        let disabled = try next.disablingSource("gyro", in: preset.path)
        require(!disabled.preset(at: preset.path)!.bindings.contains { $0.source == "gyro" && $0.isActive })
        check("gyro and touchpad", draft, next)

        // Mode shift: a new group the preset marks `active modeshift`, and a binding that switches to it.
        next = try draft.addingModeShift(on: press.path, in: preset.path, source: "joystick", mode: "dpad")
        check("mode shift", draft, next)
        // Steam resolves the target while it reads the binding: the new group
        // comes before the group holding the button (it logs "Invalid mode" otherwise).
        require(next.model.groupDefinitions.map(\.id) == ["2", "0", "1"], "\(next.model.groupDefinitions.map(\.id))")
        guard case .defined(let holder) = next.model.lookup(group: "0") else { fatalError("group 0") }
        let shift = holder.input("button_a")!.activators[0].bindings.last!
        require(shift.verb == .modeShift(source: "joystick", groupID: "2"), "\(shift.verb)")
        require(holder.input("button_a")!.activators[0].bindings.count == press.bindings.count + 1, "the button keeps its bindings")
        require(next.preset(at: preset.path)!.bindings.contains { $0.groupID == "2" && $0.isModeShift && $0.isActive && $0.source == "joystick" })
        require(next.referenceProblems.isEmpty, "a new mode shift resolves")
        // Steam writes a shift's entry directly after the entry of the group it shifts from.
        let faceShift = try draft.addingModeShift(on: press.path, in: preset.path, source: "button_diamond", mode: "dpad")
        require(faceShift.preset(at: preset.path)!.bindings.map(\.groupID) == ["0", "2", "1"],
                "the shift follows its source's entry: \(faceShift.preset(at: preset.path)!.bindings.map(\.groupID))")
        require(text(faceShift.bytes).contains("\"0\"\t\t\"button_diamond active\"\n\t\t\t\"2\"\t\t\"button_diamond active modeshift\"\n\t\t\t\"1\""))

        // Action sets and layers.
        next = try draft.addingActionSet(title: "Driving", copying: preset.path)
        check("add action set", draft, next)
        require(next.model.actionSets.map(\.title) == ["Default", "Driving"] && next.model.presets.count == 2)
        let driving = next.model.presets[1]
        require(driving.id == "1" && driving.bindings.map(\.groupID) == ["2", "3"] && next.referenceProblems.isEmpty)
        require(next.model.groupDefinitions.count == 4 && occurrences("\"group_extra\" { \"nested\" \"value\" }", next.bytes) == 2
                && occurrences("[$LINUX]", next.bytes) == 2 && occurrences("[$OSX]", next.bytes) == 2,
                "a copied set's groups are exact copies, unknown fields and conditions included")
        // Editing the copy leaves the original set's group alone.
        let copyA = next.model.groupDefinitions[2].input("button_a")!.activators[0].bindings[0]
        let editedCopy = try next.replacingBinding(at: copyA.path, with: .gamepad("X"), label: nil)
        require(editedCopy.group(at: group0.path)?.input("button_a")?.activators[0].bindings[0].verb == .xinputButton("A"))
        next = try next.replacingBinding(at: press.bindings[0].path, with: .changeActionSet(preset: 2), label: "Drive")
        require(next.referenceProblems.isEmpty)
        require(refusal { try next.removingActionSet(driving.path) } == "A binding still switches to this set. Change that binding first.")
        let renamedSet = try next.renamingActionSet(driving.path, to: "Car")
        require(renamedSet.model.actionSets.map(\.title) == ["Default", "Car"])
        next = try next.addingActionLayer(title: "Aim", parentSetID: "Default")
        let aim = next.model.actionLayers.first!
        require(aim.title == "Aim" && aim.parentSetID == "Default" && next.model.preset(for: aim)?.id == "2" && next.referenceProblems.isEmpty)
        require(refusal { try next.removingActionSet(draft.model.presets[0].path) } == "This set still has layers. Remove them first.")
        let noLayer = try next.removingActionSet(next.model.preset(for: aim)!.path)
        require(noLayer.model.actionLayers.isEmpty && noLayer.model.presets.count == 2 && noLayer.referenceProblems.isEmpty)
        require(refusal { try draft.removingActionSet(preset.path) } == "A layout needs at least one action set.")
        require(refusal { try draft.addingActionLayer(title: "X", parentSetID: "Nope") } == "Choose the action set this layer belongs to.")
        require(refusal { try draft.addingActionSet(title: "default", copying: nil) } == "An action set already has that name.")

        // A layout that does not declare its sets (Steam's templates) gets them
        // declared as Steam does when a second set or a layer is added:
        // `actions` naming each preset with `legacy_set` 1, new keys `Preset_100000N`.
        let declaration = "\t\"actions\"\n\t{\n\t\t\"Default\"\n\t\t{\n\t\t\t\"title\"\t\t\"Default\"\n\t\t\t\"legacy_set\"\t\t\"1\"\n\t\t}\n\t}\n"
        require(fixture.contains(declaration))
        let undeclared = try SteamInputLayoutDraft(bytes: Data(fixture.replacingOccurrences(of: declaration, with: "").utf8))
        require(!undeclared.model.declaresActionSets && undeclared.model.actionSets.map(\.title) == ["Default"])
        let declared = try undeclared.addingActionSet(title: "Inventory", copying: undeclared.model.presets[0].path)
        check("declare sets", undeclared, declared)
        require(declared.model.declaresActionSets && declared.model.actionSets.map(\.id) == ["Default", "Preset_1000001"]
                && declared.model.actionSets.map(\.title) == ["Default", "Inventory"], "\(declared.model.actionSets)")
        require(declared.model.presets.map(\.name) == ["Default", "Preset_1000001"] && declared.referenceProblems.isEmpty)
        require(declared.model.preset(for: declared.model.actionSets[1])?.id == "1")
        let declaredText = text(declared.bytes)
        require(declaredText.range(of: "\"actions\"")!.lowerBound < declaredText.range(of: "\"future_block\"")!.lowerBound,
                "the declaration goes before the layout's blocks")
        let switching = try declared.replacingBinding(at: press.bindings[0].path, with: .changeActionSet(preset: 2), label: nil)
        require(switching.referenceProblems.isEmpty, "a switch to the new set resolves")
        // A layer on an undeclared layout: the sets are declared and its parent is the preset's name.
        let layered = try undeclared.addingActionLayer(title: "Hotbar", parentSetID: undeclared.model.actionSets[0].id)
        require(layered.model.declaresActionSets && layered.model.actionLayers.map(\.id) == ["Preset_1000001"]
                && layered.model.actionLayers[0].parentSetID == "Default" && layered.model.preset(for: layered.model.actionLayers[0])?.id == "1"
                && layered.referenceProblems.isEmpty, "\(layered.model.actionLayers)")
        require(try declared.declaringActionSets().bytes == declared.bytes, "declaring declared sets changes nothing")

        // =============================================================
        // 3. Unsupported surface: shown, kept, and never edited by accident
        // =============================================================
        let ambiguous = try SteamInputLayoutDraft(bytes: Data(fixture.replacingOccurrences(of: "\"id\"\t\t\"1\"", with: "\"id\"\t\t\"0\"").utf8))
        let twin = ambiguous.model.groupDefinitions[0]
        require(refusal { try ambiguous.replacingBinding(at: twin.input("button_a")!.activators[0].bindings[0].path, with: .gamepad("B"), label: nil) }
                == "Group 0 is defined more than once, so Madeira does not edit it.")
        require(refusal { try ambiguous.settingGroupSetting("x", to: "1", at: twin.path) } == "Group 0 is defined more than once, so Madeira does not edit it.")
        let version2 = try SteamInputLayoutDraft(bytes: Data(fixture.replacingOccurrences(of: "\"version\"\t\t\"3\"", with: "\"version\"\t\t\"2\"").utf8))
        require(version2.notEditableReason?.contains("version 2") == true)
        require(refusal { try version2.settingTitle("x") } == version2.notEditableReason!)
        require(refusal { try draft.replacingBinding(at: VDFPath([.init("nowhere")]), with: .gamepad("A"), label: nil) } == "That binding no longer exists.")

        // A long series of unrelated edits leaves every unsupported byte where it was.
        var series = draft
        series = try series.settingTitle("Series")
        series = try series.replacingBinding(at: buttonB.activators[0].bindings[0].path, with: .mouseButton("LEFT"), label: nil)
        series = try series.addingActivator("release", to: buttonB.path)
        series = try series.settingGroupSetting("sensitivity", to: "150", at: group1.path)
        series = try series.switchingMode(of: "joystick", in: preset.path, to: "flickstick")
        series = try series.addingActionSet(title: "Menus", copying: nil)
        check("series", draft, series)
        for entry in draft.model.unrecognizedEntries {
            require(series.model.unrecognizedEntries.contains { $0.rawContent == entry.rawContent }, "\(entry.path) survives the series")
        }
        require(series.model.conditionSites.map(\.condition.expression).sorted() == draft.model.conditionSites.map(\.condition.expression).sorted(),
                "every condition survives the series")
        require(text(series.bytes).hasPrefix("// header comment\n\"controller_mappings\" [!$PS3]") && text(series.bytes).hasSuffix("} // trailing comment\n"))

        // =============================================================
        // 4. Undo and redo
        // =============================================================
        var history = SteamInputEditHistory(draft)
        require(!history.canUndo && !history.canRedo && !history.hasUnsavedChanges)
        try history.apply { try $0.settingTitle("One") }
        try history.apply { try $0.settingTitle("Two") }
        try history.apply { try $0.settingTitle("Two") }   // no change: no step
        require(history.undoStack.count == 2 && history.current.model.title == "Two" && history.hasUnsavedChanges)
        do { try history.apply { try $0.settingTitle("") }; fatalError("empty title accepted") } catch {}
        require(history.current.model.title == "Two" && history.undoStack.count == 2, "a refused edit changes nothing")
        history.undo(); require(history.current.model.title == "One" && history.canRedo)
        history.undo(); require(history.current.bytes == original && !history.hasUnsavedChanges)
        history.undo(); require(history.current.bytes == original, "undo past the start is a no-op")
        history.redo(); history.redo(); require(history.current.model.title == "Two")
        history.undo(); try history.apply { try $0.settingTitle("Three") }
        require(!history.canRedo && history.current.model.title == "Three", "a new edit drops the redo branch")
        history.markSaved(); require(!history.hasUnsavedChanges)
        for index in 0..<(SteamInputEditHistory.limit + 5) { try history.apply { try $0.settingTitle("T\(index)") } }
        require(history.undoStack.count == SteamInputEditHistory.limit, "undo is bounded")
        history.replace(with: draft); require(history.current.bytes == original && history.canUndo && !history.canRedo)

        // =============================================================
        // 5. The probe fixture and an optional local corpus of real layouts
        // =============================================================
        let probeDraft = try SteamInputLayoutDraft(bytes: probe)
        let probeA = probeDraft.model.groupDefinitions[0].input("button_a")!.activators[0]
        let probeEdited = try probeDraft.replacingBinding(at: probeA.bindings[0].path, with: .gamepad("A"), label: nil)
        let probeSplice = splice(probe, probeEdited.bytes)
        require(probeSplice.removed == "B" && probeSplice.inserted == "A, , ", "the probe edit changes only that binding's value: \(probeSplice)")
        require(probeEdited.model.groupDefinitions[0].input("button_a")!.activators[0].bindings[0].verb == .xinputButton("A"))
        var swept = 0
        if !corpus.isEmpty, let walker = FileManager.default.enumerator(atPath: corpus) {
            for case let relative as String in walker where relative.lowercased().hasSuffix(".vdf") {
                let url = URL(fileURLWithPath: corpus).appendingPathComponent(relative)
                guard let bytes = try? Data(contentsOf: url), let layout = try? SteamInputLayoutDraft(bytes: bytes),
                      layout.notEditableReason == nil, let target = layout.model.groupDefinitions.first(where: {
                          if case .defined = layout.model.lookup(group: $0.id) { return !$0.inputs.isEmpty }; return false }),
                      let anActivator = target.inputs.first?.activators.first else { continue }
                var edited = try layout.addingBinding(.key("F9"), label: "corpus", to: anActivator.path)
                edited = try edited.settingGroupSetting("sensitivity", to: "123", at: target.path)
                // A set whose groups are missing or ambiguous is refused, not copied on a guess.
                if let firstPreset = layout.model.presets.first {
                    do { edited = try edited.addingActionSet(title: "Corpus copy", copying: firstPreset.path) }
                    catch SteamInputLayoutDraft.EditError.notEditable { require(!layout.referenceProblems.isEmpty, "\(relative): copy refused without a broken reference") }
                    catch SteamInputLayoutDraft.EditError.invalid(let reason) { require(reason == "An action set already has that name.", reason) }
                }
                require(edited.model.conditionSites.count >= layout.model.conditionSites.count, "\(relative): conditions kept")
                for entry in layout.model.unrecognizedEntries {
                    require(occurrences(entry.rawContent, edited.bytes) >= occurrences(entry.rawContent, layout.bytes), "\(relative): \(entry.path) kept")
                }
                require(edited.referenceProblems.count <= layout.referenceProblems.count, "\(relative): no new broken reference")
                swept += 1
            }
            print("corpus: edited \(swept) real layouts read-only")
        }
        print("PASS: structural lossless VDF writer, editable layout model (bindings, chords, activators, toggle/turbo, dead zones and curves, modes, gyro, touchpad, menus, mode shifts, action sets and layers), preservation of unsupported fields, repeated keys and every condition, refusals, and bounded undo/redo")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-input-editor-') as temporary:
    tmp = Path(temporary)
    (tmp / 'main.swift').write_text(program)
    subprocess.run([shutil.which('swiftc'), '-parse-as-library', '-sanitize=address', '-module-cache-path', str(tmp / 'modules'),
                    str(app / 'SteamInputVDF.swift'), str(app / 'SteamInputModel.swift'), str(app / 'SteamInputReferences.swift'),
                    str(app / 'SteamInputEditor.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(probe_fixture)] + ([os.environ['MADEIRA_STEAM_LAYOUT_CORPUS']] if os.environ.get('MADEIRA_STEAM_LAYOUT_CORPUS') else []), check=True)
