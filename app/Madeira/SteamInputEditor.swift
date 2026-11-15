// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// What a binding does, written in the grammar Steam itself writes. The
/// spellings come from Valve's templates and the sampled layouts recorded in
/// docs/STEAM_INPUT_INTEGRATION_PLAN.md (item 5): `xinput_button A`,
/// `key_press SPACE`, `mouse_button LEFT`, `mouse_wheel SCROLL_UP`,
/// `game_action <set> <action>`, `mode_shift <source> <group>`,
/// `controller_action CHANGE_PRESET <n> 1 1` and
/// `controller_action add_layer|remove_layer|hold_layer <n> 0 0`.
enum SteamInputBindingCommand: Equatable, Hashable, Sendable {
    case gamepad(String)
    case key(String)
    case mouseButton(String)
    case mouseWheel(up: Bool)
    case gameAction(set: String, action: String)
    case modeShift(source: String, groupID: String)
    /// Steam counts presets from 1: `preset` is the preset id plus one.
    case changeActionSet(preset: Int)
    case layer(SteamInputLayoutModel.ParsedBinding.LayerOperation, preset: Int)

    var command: String {
        switch self {
        case .gamepad(let button): return "xinput_button " + button.uppercased()
        case .key(let key): return "key_press " + key.uppercased()
        case .mouseButton(let button): return "mouse_button " + button.uppercased()
        case .mouseWheel(let up): return "mouse_wheel " + (up ? "SCROLL_UP" : "SCROLL_DOWN")
        case .gameAction(let set, let action): return "game_action \(set) \(action)"
        case .modeShift(let source, let group): return "mode_shift \(source) \(group)"
        case .changeActionSet(let preset): return "controller_action CHANGE_PRESET \(preset) 1 1"
        case .layer(let operation, let preset): return "controller_action \(operation.rawValue) \(preset) 0 0"
        }
    }

    /// The editable command a parsed binding carries, or nil when the binding
    /// is something the editor keeps as written (another Steam action or an
    /// unverified verb).
    init?(_ verb: SteamInputLayoutModel.ParsedBinding.Verb) {
        switch verb {
        case .xinputButton(let button): self = .gamepad(button.uppercased())
        case .keyPress(let key): self = .key(key.uppercased())
        case .mouseButton(let button): self = .mouseButton(button.uppercased())
        case .mouseWheel(let direction): self = .mouseWheel(up: direction.uppercased() == "SCROLL_UP")
        case .gameAction(let set, let action): self = .gameAction(set: set, action: action)
        case .modeShift(let source, let group): self = .modeShift(source: source, groupID: group)
        case .actionSetChange(let preset): self = .changeActionSet(preset: preset)
        case .layerChange(let operation, let preset): self = .layer(operation, preset: preset)
        case .steamAction, .unverified: return nil
        }
    }

    /// Every argument is one word of identifier characters, as the grammar needs.
    var isWellFormed: Bool {
        func word(_ text: String) -> Bool {
            !text.isEmpty && text.utf8.count <= 64 && text.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
            } && text.unicodeScalars.allSatisfy(\.isASCII)
        }
        switch self {
        case .gamepad(let value): return SteamInputEditorCatalog.gamepadButtons.contains { $0.value == value.uppercased() }
        case .key(let value): return word(value)
        case .mouseButton(let value): return SteamInputEditorCatalog.mouseButtons.contains { $0.value == value.uppercased() }
        case .mouseWheel: return true
        case .gameAction(let set, let action): return word(set) && word(action)
        case .modeShift(let source, let group): return word(source) && word(group)
        case .changeActionSet(let preset), .layer(_, let preset): return preset >= 1 && preset <= 4096
        }
    }
}

/// The choices the editor offers. Names are Steam's own spellings; titles are
/// what a player reads.
enum SteamInputEditorCatalog {
    struct Choice: Hashable, Identifiable, Sendable {
        let value: String
        let title: String
        var id: String { value }
    }

    static let gamepadButtons: [Choice] = [
        .init(value: "A", title: "A (Cross)"), .init(value: "B", title: "B (Circle)"),
        .init(value: "X", title: "X (Square)"), .init(value: "Y", title: "Y (Triangle)"),
        .init(value: "SHOULDER_LEFT", title: "LB (L1)"), .init(value: "SHOULDER_RIGHT", title: "RB (R1)"),
        .init(value: "TRIGGER_LEFT", title: "LT (L2)"), .init(value: "TRIGGER_RIGHT", title: "RT (R2)"),
        .init(value: "JOYSTICK_LEFT", title: "L3 (Left Stick Click)"), .init(value: "JOYSTICK_RIGHT", title: "R3 (Right Stick Click)"),
        .init(value: "START", title: "Menu (Options)"), .init(value: "SELECT", title: "View (Create/Share)"),
        .init(value: "DPAD_UP", title: "D-Pad Up"), .init(value: "DPAD_DOWN", title: "D-Pad Down"),
        .init(value: "DPAD_LEFT", title: "D-Pad Left"), .init(value: "DPAD_RIGHT", title: "D-Pad Right"),
    ]

    static let mouseButtons: [Choice] = [
        .init(value: "LEFT", title: "Left Click"), .init(value: "RIGHT", title: "Right Click"),
        .init(value: "MIDDLE", title: "Middle Click"), .init(value: "BACK", title: "Back Button"),
        .init(value: "FORWARD", title: "Forward Button"),
    ]

    /// Keys seen in Valve's templates and the sampled layouts, plus the rest
    /// of the letters, digits and function keys in the same spelling.
    static let keys: [Choice] = {
        var names = ["SPACE", "RETURN", "ESCAPE", "TAB", "BACKSPACE", "LEFT_SHIFT", "RIGHT_SHIFT", "LEFT_CONTROL", "RIGHT_CONTROL",
                     "LEFT_ALT", "RIGHT_ALT", "LEFT_WINDOWS", "UP_ARROW", "DOWN_ARROW", "LEFT_ARROW", "RIGHT_ARROW",
                     "PAGE_UP", "PAGE_DOWN", "HOME", "END", "INSERT", "DELETE"]
        names += (65...90).map { String(UnicodeScalar(UInt8($0))) }
        names += (0...9).map(String.init)
        names += (1...12).map { "F\($0)" }
        return names.map { Choice(value: $0, title: SteamInputLayoutModel.ParsedBinding.formatKey($0)) }
    }()

    /// Activator block names as Steam writes them.
    static let activators: [Choice] = [
        .init(value: "Full_Press", title: "Regular Press"), .init(value: "Long_Press", title: "Long Press"),
        .init(value: "Double_Press", title: "Double Press"), .init(value: "Soft_Press", title: "Soft Press"),
        .init(value: "Start_Press", title: "Start Press"), .init(value: "release", title: "Release Press"),
        .init(value: "chord", title: "Chord Press"),
    ]

    /// Physical sources of the virtual DualSense and the modes Steam writes for each.
    static let sources: [Choice] = [
        .init(value: "button_diamond", title: "Face buttons"), .init(value: "dpad", title: "D-pad"),
        .init(value: "joystick", title: "Left stick"), .init(value: "right_joystick", title: "Right stick"),
        .init(value: "left_trigger", title: "Left trigger"), .init(value: "right_trigger", title: "Right trigger"),
        .init(value: "switch", title: "Bumpers and menu buttons"), .init(value: "center_trackpad", title: "Touchpad"),
        .init(value: "gyro", title: "Gyro"),
    ]

    static func modes(for source: String) -> [Choice] {
        let buttons: [Choice] = [.init(value: "four_buttons", title: "Buttons"), .init(value: "dpad", title: "Directional Pad")]
        let stick: [Choice] = [.init(value: "joystick_move", title: "Joystick"), .init(value: "dpad", title: "Directional Pad"),
                               .init(value: "joystick_mouse", title: "Joystick Mouse"), .init(value: "flickstick", title: "Flick Stick"),
                               .init(value: "scrollwheel", title: "Scroll Wheel"), .init(value: "single_button", title: "Single Button"),
                               .init(value: "touch_menu", title: "Touch Menu"), .init(value: "radial_menu", title: "Radial Menu")]
        let menus: [Choice] = [.init(value: "touch_menu", title: "Touch Menu"), .init(value: "radial_menu", title: "Radial Menu"),
                               .init(value: "hotbar", title: "Hotbar Menu")]
        switch source.lowercased() {
        case "button_diamond": return buttons + menus
        case "dpad": return [.init(value: "dpad", title: "Directional Pad"), .init(value: "four_buttons", title: "Buttons")] + menus
        case "joystick", "right_joystick": return stick
        case "left_trigger", "right_trigger": return [.init(value: "trigger", title: "Trigger"), .init(value: "single_button", title: "Single Button")]
        case "switch": return [.init(value: "switches", title: "Switches")]
        case "center_trackpad": return [.init(value: "absolute_mouse", title: "Mouse"), .init(value: "dpad", title: "Directional Pad"),
                                        .init(value: "single_button", title: "Single Button"), .init(value: "scrollwheel", title: "Scroll Wheel")] + menus
        case "gyro": return [.init(value: "mouse_joystick", title: "Gyro to Joystick Camera"), .init(value: "gyro_to_mouse", title: "Gyro to Mouse"),
                             .init(value: "joystick_camera", title: "Joystick Camera")]
        default: return []
        }
    }

    /// Inputs each mode has, as Steam names them in its own layouts.
    static func inputs(for mode: String) -> [String] {
        switch mode.lowercased() {
        case "four_buttons": return ["button_a", "button_b", "button_x", "button_y"]
        case "dpad": return ["dpad_north", "dpad_south", "dpad_west", "dpad_east", "click"]
        case "trigger": return ["click", "edge"]
        case "joystick_move": return ["click", "touch"]
        case "scrollwheel": return ["scroll_clockwise", "scroll_counterclockwise", "click"]
        case "switches": return ["left_bumper", "right_bumper", "button_escape", "button_menu", "button_back_left", "button_back_right"]
        case "touch_menu", "radial_menu", "hotbar": return (0..<8).map { "touch_menu_button_\($0)" }
        case "absolute_mouse", "flickstick", "joystick_mouse", "joystick_camera", "mouse_joystick", "single_button": return ["click"]
        default: return []
        }
    }

    /// Group settings the editor offers as numbers, with what they mean.
    /// Every other setting is kept and can be edited as written.
    static let groupSettings: [Choice] = [
        .init(value: "deadzone_inner_radius", title: "Inner dead zone"),
        .init(value: "deadzone_outer_radius", title: "Outer dead zone"),
        .init(value: "anti_deadzone", title: "Anti-dead zone"),
        .init(value: "curve_exponent", title: "Response curve"),
        .init(value: "sensitivity", title: "Sensitivity"),
        .init(value: "edge_binding_radius", title: "Edge radius"),
        .init(value: "output_joystick", title: "Joystick output"),
        .init(value: "output_trigger", title: "Trigger output"),
        .init(value: "touch_menu_button_count", title: "Menu buttons"),
    ]

    static let activatorSettings: [Choice] = [
        .init(value: "long_press_time", title: "Long press time (ms)"),
        .init(value: "double_tap_time", title: "Double tap time (ms)"),
        .init(value: "repeat_rate", title: "Turbo repeat rate"),
        .init(value: "delay_start", title: "Fire start delay (ms)"),
        .init(value: "delay_end", title: "Fire end delay (ms)"),
        .init(value: "haptic_intensity", title: "Haptic intensity"),
        .init(value: "interruptable", title: "Interruptible"),
    ]
}

/// An editable Steam Input layout. It is the parsed document plus the domain
/// model read from it; every edit is a structural patch of the document (see
/// `VDFDocument`), after which both are rebuilt. Nothing is ever serialized
/// from the model, so fields the editor does not understand, repeated keys,
/// ordering, comments and every condition are kept byte for byte.
struct SteamInputLayoutDraft: Equatable {
    let document: VDFDocument
    let model: SteamInputLayoutModel
    var bytes: Data { document.sourceData }

    enum EditError: LocalizedError, Equatable {
        case notEditable(String)
        case notFound(String)
        case invalid(String)
        case referenced(String)

        var errorDescription: String? {
            switch self {
            case .notEditable(let reason), .notFound(let reason), .invalid(let reason), .referenced(let reason): return reason
            }
        }
    }

    init(bytes: Data) throws {
        try self.init(document: VDFDocument.parse(bytes))
    }

    init(document: VDFDocument) throws {
        self.document = document
        self.model = try SteamInputLayoutModel(document: document)
    }

    /// Why the layout cannot be edited, or nil when it can. Version 2 layouts
    /// are shown but not edited: their group-level `bindings` and
    /// `switch_bindings` are not interpreted.
    var notEditableReason: String? {
        model.version == 3 ? nil : "This layout uses Steam's version \(model.version) format. Madeira shows it and keeps it unchanged, but cannot edit it yet."
    }

    /// Broken group, action set and layer references: what blocks applying.
    var referenceProblems: [SteamInputReferenceProblem] { SteamInputReferences.problems(in: model) }

    private func edited(_ change: (VDFDocument) throws -> VDFDocument) throws -> Self {
        if let notEditableReason { throw EditError.notEditable(notEditableReason) }
        let next: VDFDocument
        do { next = try change(document) }
        catch let error as EditError { throw error }
        catch let error as VDFMutationError {
            if case .pathNotFound = error { throw EditError.notFound("That part of the layout changed. Reopen it and try again.") }
            throw EditError.invalid(error.localizedDescription)
        } catch {
            throw EditError.invalid(error.localizedDescription)
        }
        guard next.sourceData.count <= VDFDocument.maxBytes else { throw EditError.invalid("The layout would be too large.") }
        return try Self(document: next)
    }

    private static func text(_ value: String, _ what: String, limit: Int = 160, allowEmpty: Bool = false) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !trimmed.isEmpty else { throw EditError.invalid("Enter a \(what).") }
        guard trimmed.count <= limit, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw EditError.invalid("The \(what) is too long or contains characters a layout cannot hold.")
        }
        return trimmed
    }

    private static func settingValue(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64, trimmed.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }) else {
            throw EditError.invalid("A setting value is a short number or word.")
        }
        return trimmed
    }

    private static func identifier(_ value: String, _ what: String) throws -> String {
        guard !value.isEmpty, value.count <= 64, value.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_")
        }) else { throw EditError.invalid("The \(what) must be letters, digits or underscores.") }
        return value
    }

    // MARK: Lookups

    func group(at path: VDFPath) -> SteamInputLayoutModel.Group? { model.groupDefinitions.first { $0.path == path } }
    func preset(at path: VDFPath) -> SteamInputLayoutModel.Preset? { model.presets.first { $0.path == path } }

    func input(at path: VDFPath) -> SteamInputLayoutModel.Input? {
        model.groupDefinitions.lazy.flatMap(\.inputs).first { $0.path == path }
    }

    func activator(at path: VDFPath) -> SteamInputLayoutModel.Activator? {
        model.groupDefinitions.lazy.flatMap(\.inputs).flatMap { $0.activators + $0.disabledActivators }.first { $0.path == path }
    }

    func binding(at path: VDFPath) -> SteamInputLayoutModel.ParsedBinding? {
        model.groupDefinitions.lazy.flatMap(\.inputs).flatMap { $0.activators + $0.disabledActivators }.flatMap(\.bindings).first { $0.path == path }
    }

    /// A group edits only when its id is defined once: the reference check
    /// refuses an ambiguous id, and an edit must not pick between definitions.
    private func requireUnambiguous(_ group: SteamInputLayoutModel.Group) throws {
        if case .ambiguous = model.lookup(group: group.id) {
            throw EditError.notEditable("Group \(group.id) is defined more than once, so Madeira does not edit it.")
        }
    }

    private func requireGroup(containing path: VDFPath) throws -> SteamInputLayoutModel.Group {
        guard let group = model.groupDefinitions.first(where: { path.steps.starts(with: $0.path.steps) }) else {
            throw EditError.notFound("That part of the layout changed. Reopen it and try again.")
        }
        try requireUnambiguous(group)
        return group
    }

    /// The next free numeric group id, as Steam numbers groups.
    var nextGroupID: String {
        String((model.groupDefinitions.compactMap { Int($0.id) }.max() ?? -1) + 1)
    }

    var nextPresetID: Int {
        (model.presets.compactMap { Int($0.id) }.max() ?? -1) + 1
    }

    // MARK: Layout

    func settingTitle(_ title: String) throws -> Self {
        let value = try Self.text(title, "title")
        return try edited { try $0.settingLeaf("title", to: value, in: model.rootPath) }
    }

    func settingDescription(_ description: String) throws -> Self {
        let value = try Self.text(description, "description", limit: 2000, allowEmpty: true)
        return try edited { try $0.settingLeaf("description", to: value, in: model.rootPath) }
    }

    // MARK: Bindings

    /// `command, label, icon`, the three fields Steam writes. An existing
    /// binding keeps its icon field.
    static func raw(_ command: SteamInputBindingCommand, label: String?, icon: String?) throws -> String {
        guard command.isWellFormed else { throw EditError.invalid("That binding is not one Steam Input accepts.") }
        let label = try text(label ?? "", "label", limit: 120, allowEmpty: true)
        guard !label.contains(",") else { throw EditError.invalid("A binding label cannot contain a comma.") }
        return "\(command.command), \(label), \(icon ?? "")"
    }

    func replacingBinding(at path: VDFPath, with command: SteamInputBindingCommand, label: String?) throws -> Self {
        guard let existing = binding(at: path) else { throw EditError.notFound("That binding no longer exists.") }
        _ = try requireGroup(containing: path)
        let value = try Self.raw(command, label: label, icon: existing.icon)
        return try edited { try $0.updatingValue(at: path, to: value) }
    }

    /// Adds a binding to an activator. Several bindings on one activator fire
    /// together: this is how a button sends a chord such as Ctrl+C.
    func addingBinding(_ command: SteamInputBindingCommand, label: String?, to activatorPath: VDFPath) throws -> Self {
        guard activator(at: activatorPath) != nil else { throw EditError.notFound("That activator no longer exists.") }
        _ = try requireGroup(containing: activatorPath)
        let value = try Self.raw(command, label: label, icon: nil)
        return try edited { document in
            let (withBlock, bindings) = try document.ensuringBlock("bindings", in: activatorPath)
            return try withBlock.inserting(.leaf("binding", value), into: bindings)
        }
    }

    func removingBinding(at path: VDFPath) throws -> Self {
        guard binding(at: path) != nil else { throw EditError.notFound("That binding no longer exists.") }
        _ = try requireGroup(containing: path)
        return try edited { try $0.removing(at: path) }
    }

    // MARK: Activators

    func addingActivator(_ kind: String, to inputPath: VDFPath) throws -> Self {
        guard input(at: inputPath) != nil else { throw EditError.notFound("That input no longer exists.") }
        guard SteamInputEditorCatalog.activators.contains(where: { $0.value == kind }) else { throw EditError.invalid("Choose an activator.") }
        _ = try requireGroup(containing: inputPath)
        return try edited { document in
            let (withBlock, activators) = try document.ensuringBlock("activators", in: inputPath)
            return try withBlock.inserting(.block(kind, [.block("bindings", [])]), into: activators)
        }
    }

    func removingActivator(at path: VDFPath) throws -> Self {
        guard activator(at: path) != nil else { throw EditError.notFound("That activator no longer exists.") }
        _ = try requireGroup(containing: path)
        return try edited { try $0.removing(at: path) }
    }

    func changingActivator(at path: VDFPath, to kind: String) throws -> Self {
        guard activator(at: path) != nil else { throw EditError.notFound("That activator no longer exists.") }
        guard SteamInputEditorCatalog.activators.contains(where: { $0.value == kind }) else { throw EditError.invalid("Choose an activator.") }
        _ = try requireGroup(containing: path)
        return try edited { try $0.renamingKey(at: path, to: kind) }
    }

    /// Sets (or with nil removes) one setting of an activator.
    func settingActivatorSetting(_ key: String, to value: String?, at path: VDFPath) throws -> Self {
        guard activator(at: path) != nil else { throw EditError.notFound("That activator no longer exists.") }
        _ = try requireGroup(containing: path)
        let key = try Self.identifier(key, "setting name")
        let value = try value.map(Self.settingValue)
        return try edited { document in
            if value == nil, document.count("settings", in: path) == 0 { return document }
            let (withBlock, settings) = try document.ensuringBlock("settings", in: path)
            return try withBlock.settingLeaf(key, to: value, in: settings)
        }
    }

    func settingToggle(_ on: Bool, at path: VDFPath) throws -> Self {
        try settingActivatorSetting("toggle", to: on ? "1" : nil, at: path)
    }

    /// Turbo, as Steam writes it: `hold_repeats` with an optional `repeat_rate`.
    func settingTurbo(_ on: Bool, rate: Int? = nil, at path: VDFPath) throws -> Self {
        var draft = try settingActivatorSetting("hold_repeats", to: on ? "1" : nil, at: path)
        if let rate {
            guard (1...9999).contains(rate) else { throw EditError.invalid("The turbo rate is out of range.") }
            draft = try draft.settingActivatorSetting("repeat_rate", to: String(rate), at: path)
        }
        return draft
    }

    // MARK: Inputs and groups

    func addingInput(_ name: String, to groupPath: VDFPath) throws -> Self {
        guard let group = group(at: groupPath) else { throw EditError.notFound("That group no longer exists.") }
        try requireUnambiguous(group)
        let name = try Self.identifier(name.lowercased(), "input name")
        guard group.input(name) == nil else { throw EditError.invalid("This group already has that input.") }
        return try edited { document in
            let (withBlock, inputs) = try document.ensuringBlock("inputs", in: groupPath)
            return try withBlock.inserting(.block(name, [.block("activators", [.block("Full_Press", [.block("bindings", [])])]),
                                                           .block("disabled_activators", [])]), into: inputs)
        }
    }

    func removingInput(at path: VDFPath) throws -> Self {
        guard input(at: path) != nil else { throw EditError.notFound("That input no longer exists.") }
        _ = try requireGroup(containing: path)
        return try edited { try $0.removing(at: path) }
    }

    /// Sets (or with nil removes) one setting of a group: dead zones, curves,
    /// sensitivity, outputs and menu settings.
    func settingGroupSetting(_ key: String, to value: String?, at groupPath: VDFPath) throws -> Self {
        guard let group = group(at: groupPath) else { throw EditError.notFound("That group no longer exists.") }
        try requireUnambiguous(group)
        let key = try Self.identifier(key, "setting name")
        let value = try value.map(Self.settingValue)
        return try edited { document in
            if value == nil, document.count("settings", in: groupPath) == 0 { return document }
            let (withBlock, settings) = try document.ensuringBlock("settings", in: groupPath)
            return try withBlock.settingLeaf(key, to: value, in: settings)
        }
    }

    /// A source binding's value with its `active`/`inactive` flag set and
    /// every other flag kept in place.
    private static func flagged(_ binding: SteamInputLayoutModel.SourceBinding, active: Bool, document: VDFDocument) -> String {
        let written = document.findValueToken(at: binding.path).map(document.stringValue(for:)) ?? binding.source
        var words = written.split(separator: " ").map(String.init)
        if let index = words.firstIndex(where: { ["active", "inactive"].contains($0.lowercased()) }) {
            words[index] = active ? "active" : "inactive"
        } else {
            words.insert(active ? "active" : "inactive", at: min(1, words.count))
        }
        return words.joined(separator: " ")
    }

    /// The group a source uses in a preset: its one active, non-mode-shift binding.
    func activeBinding(for source: String, in preset: SteamInputLayoutModel.Preset) -> SteamInputLayoutModel.SourceBinding? {
        preset.bindings.first { $0.source == source.lowercased() && $0.isActive && !$0.isModeShift }
    }

    /// Changes the mode a source uses in a preset the way Steam does: the
    /// group it used stays in the layout, marked inactive, and a group with the
    /// new mode becomes active. An inactive group already holding that mode is
    /// reused, so switching back restores its bindings. Other presets are not
    /// affected. Assigning a source the preset does not use yet works the same.
    func switchingMode(of source: String, in presetPath: VDFPath, to mode: String) throws -> Self {
        let source = source.lowercased()
        guard let preset = preset(at: presetPath) else { throw EditError.notFound("That action set no longer exists.") }
        guard SteamInputEditorCatalog.modes(for: source).contains(where: { $0.value == mode }) else {
            throw EditError.invalid("That mode is not available for this input.")
        }
        let current = activeBinding(for: source, in: preset)
        if let current, case .defined(let group) = model.lookup(group: current.groupID), group.mode == mode { return self }
        let reusable = preset.bindings.first { binding in
            guard binding.source == source, !binding.isActive, !binding.isModeShift,
                  case .defined(let group) = model.lookup(group: binding.groupID) else { return false }
            return group.mode == mode
        }
        var draft = self
        if let current {
            let value = Self.flagged(current, active: false, document: draft.document)
            draft = try draft.edited { try $0.updatingValue(at: current.path, to: value) }
        }
        if let reusable {
            let value = Self.flagged(reusable, active: true, document: draft.document)
            return try draft.edited { try $0.updatingValue(at: reusable.path, to: value) }
        }
        let id = draft.nextGroupID
        return try draft.addingGroup(id: id, mode: mode)
            .addingSourceBinding(groupID: id, value: "\(source) active", to: presetPath)
    }

    /// Stops a preset using a source: its group is kept, marked inactive.
    func disablingSource(_ source: String, in presetPath: VDFPath) throws -> Self {
        guard let preset = preset(at: presetPath) else { throw EditError.notFound("That action set no longer exists.") }
        guard let current = activeBinding(for: source, in: preset) else { return self }
        let value = Self.flagged(current, active: false, document: document)
        return try edited { try $0.updatingValue(at: current.path, to: value) }
    }

    /// A new, empty group placed after the last group, or at `index` among the root's elements.
    private func addingGroup(id: String, mode: String, at index: Int? = nil) throws -> Self {
        try edited { document in
            try document.inserting(.block("group", [.leaf("id", id), .leaf("mode", mode), .block("inputs", []), .block("settings", [])]),
                                   into: model.rootPath, at: index ?? insertionIndex(after: "group"))
        }
    }

    /// The element index just after the last child named `key` under the root.
    private func insertionIndex(after key: String) -> Int? {
        guard case .block(_, _, let children, _, _)? = document.findNode(at: model.rootPath) else { return nil }
        var last: Int?
        var index = 0
        for child in children {
            switch child {
            case .leaf(let k, _, _), .block(let k, _, _, _, _):
                if document.stringValue(for: k).caseInsensitiveCompare(key) == .orderedSame { last = index }
                index += 1
            default: break
            }
        }
        return last.map { $0 + 1 }
    }

    private func addingSourceBinding(groupID: String, value: String, to presetPath: VDFPath, at index: Int? = nil) throws -> Self {
        try edited { document in
            let (withBlock, sources) = try document.ensuringBlock("group_source_bindings", in: presetPath)
            return try withBlock.inserting(.leaf(groupID, value), into: sources, at: index)
        }
    }

    /// A mode shift, as Steam writes one: a new group with `mode` that the
    /// preset marks `active modeshift` for `source`, and a `mode_shift`
    /// binding on the activator that switches to it while held.
    func addingModeShift(on activatorPath: VDFPath, in presetPath: VDFPath, source: String, mode: String) throws -> Self {
        let source = source.lowercased()
        guard preset(at: presetPath) != nil else { throw EditError.notFound("That action set no longer exists.") }
        guard activator(at: activatorPath) != nil else { throw EditError.notFound("That activator no longer exists.") }
        guard SteamInputEditorCatalog.modes(for: source).contains(where: { $0.value == mode }) else {
            throw EditError.invalid("That mode is not available for this input.")
        }
        let id = nextGroupID
        // Steam resolves a mode shift's group while it reads the binding, so the
        // group must come earlier in the file: placed after it, Steam logs
        // "Invalid mode <id> in mode_shift binding string" and drops the binding.
        // The new group goes directly before the group holding the activator,
        // whose path then moves on by one.
        let depth = model.rootPath.steps.count
        guard activatorPath.steps.count > depth, activatorPath.steps[depth].key.caseInsensitiveCompare("group") == .orderedSame,
              let groupIndex = elementIndex(of: VDFPath(Array(activatorPath.steps.prefix(depth + 1)))) else {
            throw EditError.notFound("That activator no longer exists.")
        }
        var steps = activatorPath.steps
        steps[depth] = .init(steps[depth].key, index: steps[depth].index + 1)
        let movedActivator = VDFPath(steps)
        // Steam writes the shift's entry directly after the entry of the group
        // it shifts from; every layout Steam saves orders them that way.
        let after = preset(at: presetPath).flatMap { activeBinding(for: source, in: $0) }.flatMap { elementIndex(of: $0.path) }
        return try addingGroup(id: id, mode: mode, at: groupIndex)
            .addingSourceBinding(groupID: id, value: "\(source) active modeshift", to: presetPath, at: after.map { $0 + 1 })
            .addingBinding(.modeShift(source: source, groupID: id), label: nil, to: movedActivator)
    }

    /// The position of the node at `path` among its parent's keys and blocks.
    private func elementIndex(of path: VDFPath) -> Int? {
        guard let last = path.steps.last, case .block(_, _, let children, _, _)? = document.findNode(at: VDFPath(Array(path.steps.dropLast()))) else { return nil }
        var index = 0, occurrence = 0
        for child in children {
            switch child {
            case .leaf(let k, _, _), .block(let k, _, _, _, _):
                if document.stringValue(for: k).caseInsensitiveCompare(last.key) == .orderedSame {
                    if occurrence == last.index { return index }
                    occurrence += 1
                }
                index += 1
            default: break
            }
        }
        return nil
    }

    // MARK: Action sets and layers

    /// The key Steam gives a new set or layer: `Preset_` and 1000000 plus
    /// its preset's id, unique among sets, layers and presets.
    private func newKey(presetID: Int) -> String {
        let used = Set((model.actionSets.map(\.id) + model.actionLayers.map(\.id) + model.presets.map(\.name)).map { $0.lowercased() })
        var number = 1_000_000 + presetID
        while used.contains("preset_\(number)") { number += 1 }
        return "Preset_\(number)"
    }

    /// Declares the layout's action sets the way Steam does once a layout for
    /// a game without its own action sets has more than one: an `actions`
    /// block naming each preset, `legacy_set` 1. Without it Steam does not
    /// switch between the presets. A layout that already declares them is
    /// returned unchanged.
    func declaringActionSets() throws -> Self {
        if model.declaresActionSets { return self }
        let layerPresets = model.actionLayers.compactMap { model.preset(for: $0) }
        let sets = model.presets.filter { !layerPresets.contains($0) }
        let names = sets.map(\.name)
        guard !names.isEmpty, names.allSatisfy({ name in
            !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }), Set(names.map { $0.lowercased() }).count == names.count else {
            throw EditError.notEditable("This layout's action sets have no usable names, so Madeira cannot declare them.")
        }
        let actions: VDFNewNode = .block("actions", sets.map { .block($0.name, [.leaf("title", $0.name), .leaf("legacy_set", "1")]) })
        // Steam writes the declaration before the layout's localization and groups.
        guard case .block(_, _, let children, _, _)? = document.findNode(at: model.rootPath) else { throw EditError.notFound("The layout has no mappings.") }
        var index = 0, firstBlock: Int?
        for child in children {
            switch child {
            case .leaf: index += 1
            case .block: if firstBlock == nil { firstBlock = index }; index += 1
            default: break
            }
        }
        return try edited { try $0.inserting(actions, into: model.rootPath, at: firstBlock) }
    }

    /// A new action set. Its preset starts as a copy of `copying`'s groups —
    /// their exact text, under new ids — so the controller works in the new
    /// set, and editing one set never changes another.
    func addingActionSet(title: String, copying sourcePresetPath: VDFPath?) throws -> Self {
        let title = try Self.text(title, "set name")
        if model.actionSets.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })
            || model.actionLayers.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            throw EditError.invalid("An action set already has that name.")
        }
        var draft = try declaringActionSets()
        let key = draft.newKey(presetID: draft.nextPresetID)
        guard let actions = draft.model.actionSets.compactMap(\.path).first.map({ VDFPath(Array($0.steps.dropLast())) }) else {
            throw EditError.notEditable("This layout's action sets cannot be found.")
        }
        draft = try draft.edited { try $0.inserting(.block(key, [.leaf("title", title), .leaf("legacy_set", "1")]), into: actions) }
        return try draft.addingPreset(name: key, copying: sourcePresetPath)
    }

    /// A new layer on `parentSetID`. A layer starts empty: it changes only
    /// what it binds and leaves the rest of its set as it is.
    func addingActionLayer(title: String, parentSetID: String) throws -> Self {
        let title = try Self.text(title, "layer name")
        let parents = model.actionSets.filter { $0.id.caseInsensitiveCompare(parentSetID) == .orderedSame }
        guard parents.count == 1, let parentPreset = model.preset(for: parents[0]) else {
            throw EditError.invalid("Choose the action set this layer belongs to.")
        }
        if model.actionSets.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })
            || model.actionLayers.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            throw EditError.invalid("An action set or layer already has that name.")
        }
        var draft = try declaringActionSets()
        // Declaring the sets gives an undeclared parent its key: its preset's name.
        guard let parentID = draft.model.actionSets.first(where: { draft.model.preset(for: $0)?.id == parentPreset.id })?.id else {
            throw EditError.invalid("Choose the action set this layer belongs to.")
        }
        let key = draft.newKey(presetID: draft.nextPresetID)
        let root = model.rootPath
        draft = try draft.edited { document in
            let (withBlock, layers) = try document.ensuringBlock("action_layers", in: root)
            return try withBlock.inserting(.block(key, [.leaf("title", title), .leaf("legacy_set", "1"), .leaf("set_layer", "1"),
                                                        .leaf("parent_set_name", parentID)]), into: layers)
        }
        return try draft.addingPreset(name: key, copying: nil)
    }

    private func addingPreset(name: String, copying sourcePresetPath: VDFPath?) throws -> Self {
        let presetID = nextPresetID
        var sourceBindings: [(groupID: String, value: String)] = []
        var draft = self
        if let sourcePresetPath {
            guard let source = preset(at: sourcePresetPath) else { throw EditError.notFound("That action set no longer exists.") }
            for binding in source.bindings {
                guard case .defined(let group) = model.lookup(group: binding.groupID) else {
                    throw EditError.notEditable("Group \(binding.groupID) is missing or defined more than once, so this set cannot be copied.")
                }
                let id = draft.nextGroupID
                let previousCount = draft.document.count("group", in: model.rootPath)
                draft = try draft.edited { try $0.insertingCopy(of: group.path, into: model.rootPath) }
                // The copy is the last group; give it its own id.
                let copyPath = VDFPath(model.rootPath.steps + [.init("group", index: previousCount)])
                draft = try draft.edited { try $0.settingLeaf("id", to: id, in: copyPath) }
                let written = document.findValueToken(at: binding.path).map(document.stringValue(for:)) ?? "\(binding.source) active"
                sourceBindings.append((id, written))
            }
        }
        let preset: VDFNewNode = .block("preset", [.leaf("id", String(presetID)), .leaf("name", name),
                                                   .block("group_source_bindings", sourceBindings.map { .leaf($0.groupID, $0.value) })])
        return try draft.edited { try $0.inserting(preset, into: model.rootPath, at: draft.insertionIndex(after: "preset")) }
    }

    /// Renames the set or layer a preset holds. A declared set or layer keeps
    /// its key (references use it) and changes its title; a set synthesized
    /// from a preset changes the preset's name.
    func renamingActionSet(_ presetPath: VDFPath, to title: String) throws -> Self {
        let title = try Self.text(title, "set name")
        guard let preset = preset(at: presetPath) else { throw EditError.notFound("That action set no longer exists.") }
        if let layer = model.actionLayers.first(where: { model.preset(for: $0) == preset }) {
            return try edited { try $0.settingLeaf("title", to: title, in: layer.path) }
        }
        if let set = model.actionSets.first(where: { model.preset(for: $0) == preset }), let path = set.path {
            return try edited { try $0.settingLeaf("title", to: title, in: path) }
        }
        return try edited { try $0.settingLeaf("name", to: title, in: presetPath) }
    }

    /// Removes a set or layer and its preset. Refused for the last set, and
    /// while a binding or layer still refers to it; the groups it used stay.
    func removingActionSet(_ presetPath: VDFPath) throws -> Self {
        guard let preset = preset(at: presetPath), let id = Int(preset.id) else { throw EditError.notFound("That action set no longer exists.") }
        let layer = model.actionLayers.first { model.preset(for: $0) == preset }
        let set = model.actionSets.first { model.preset(for: $0) == preset }
        if layer == nil, model.presets.count - model.actionLayers.count <= 1 {
            throw EditError.referenced("A layout needs at least one action set.")
        }
        let number = id + 1
        for binding in model.groupDefinitions.flatMap(\.inputs).flatMap(\.activators).flatMap(\.bindings) {
            switch binding.verb {
            case .actionSetChange(let preset) where preset == number, .layerChange(_, let preset) where preset == number:
                throw EditError.referenced("A binding still switches to this \(layer == nil ? "set" : "layer"). Change that binding first.")
            default: continue
            }
        }
        if let set, model.actionLayers.contains(where: { $0.parentSetID.caseInsensitiveCompare(set.id) == .orderedSame }) {
            throw EditError.referenced("This set still has layers. Remove them first.")
        }
        var draft = try edited { try $0.removing(at: presetPath) }
        if let path = layer?.path ?? set?.path {
            draft = try draft.edited { try $0.removing(at: path) }
        }
        return draft
    }
}

/// One editing session over a draft: undo and redo of every edit, bounded.
/// The session never writes anything; saving is the store's job.
struct SteamInputEditHistory: Equatable {
    static let limit = 200
    private(set) var current: SteamInputLayoutDraft
    private(set) var undoStack: [SteamInputLayoutDraft] = []
    private(set) var redoStack: [SteamInputLayoutDraft] = []
    /// The bytes of the revision the session started from or last saved.
    private(set) var savedBytes: Data

    init(_ draft: SteamInputLayoutDraft, savedBytes: Data? = nil) {
        current = draft
        self.savedBytes = savedBytes ?? draft.bytes
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasUnsavedChanges: Bool { current.bytes != savedBytes }

    /// Applies an edit. A failed edit leaves the session unchanged; an edit
    /// that changes nothing adds no undo step.
    mutating func apply(_ edit: (SteamInputLayoutDraft) throws -> SteamInputLayoutDraft) throws {
        let next = try edit(current)
        guard next.bytes != current.bytes else { return }
        undoStack.append(current)
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        redoStack.removeAll()
        current = next
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
    }

    mutating func markSaved() { savedBytes = current.bytes }

    /// Starts again from `draft` (a restored revision or a recovered draft) as
    /// one undoable step.
    mutating func replace(with draft: SteamInputLayoutDraft) {
        guard draft.bytes != current.bytes else { return }
        undoStack.append(current)
        redoStack.removeAll()
        current = draft
    }
}
