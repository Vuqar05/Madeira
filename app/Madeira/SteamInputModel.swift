// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Structured domain model representing a Steam Input layout evaluated from a VDFDocument.
public struct SteamInputLayoutModel: Equatable, Sendable {
    /// Unrecognized blocks or properties preserved with exact raw content, span, and child tree.
    public struct UnrecognizedEntry: Equatable, Identifiable, Sendable {
        public let id: String
        public let path: String
        public let key: String
        public let rawContent: String
        public let span: SourceSpan
        public let children: [UnrecognizedEntry]

        public init(id: String, path: String, key: String, rawContent: String, span: SourceSpan, children: [UnrecognizedEntry] = []) {
            self.id = id
            self.path = path
            self.key = key
            self.rawContent = rawContent
            self.span = span
            self.children = children
        }

        public var valueDescription: String {
            rawContent
        }
    }

    /// A platform condition exactly as written, with the structure that carries it.
    /// The preview never evaluates one and never infers how nested conditions combine.
    public struct Condition: Equatable, Hashable, Sendable {
        /// The node the condition is written on, e.g. "Bindings Container" or "Input 'button_a'".
        public let scope: String
        /// Verbatim source text, brackets included, e.g. "[$WIN32]".
        public let expression: String

        public init(scope: String, expression: String) {
            self.scope = scope
            self.expression = expression
        }
    }

    /// One condition token of the source and where it sits. Each token in an
    /// interpreted part of the layout yields exactly one site, including one on
    /// a container with no children or on a property the model does not carry.
    public struct ConditionSite: Equatable, Sendable {
        /// Stable fragment for diagnostic identifiers, e.g. "set-Game".
        public let slug: String
        /// Enclosing structure, outermost first; empty directly under the root.
        public let location: String
        public let condition: Condition

        public init(slug: String, location: String, condition: Condition) {
            self.slug = slug
            self.location = location
            self.condition = condition
        }
    }

    public struct ParsedBinding: Equatable, Sendable {
        public enum LayerOperation: String, Equatable, Sendable {
            case add = "add_layer", remove = "remove_layer", hold = "hold_layer"
        }
        public enum Verb: Equatable, Sendable {
            case xinputButton(String)
            case keyPress(String)
            case mouseButton(String)
            case mouseWheel(String)
            case gameAction(setID: String, actionID: String)
            /// `mode_shift <source> <group>`: while the input is held, `source` uses that group.
            case modeShift(source: String, groupID: String)
            /// `controller_action CHANGE_PRESET <n> …`. Steam counts presets from 1,
            /// so `n` names the preset whose `id` is `n - 1`.
            case actionSetChange(preset: Int)
            /// `controller_action add_layer|remove_layer|hold_layer <n> …`, counted the same way.
            case layerChange(LayerOperation, preset: Int)
            /// Any other `controller_action`: something Steam itself carries out.
            case steamAction(command: String, arguments: [String])
            case unverified(verb: String, arguments: [String])
        }

        public let verb: Verb
        public let label: String?
        /// The third field Steam writes after the label: an icon file and colours.
        public let icon: String?
        /// Conditions on the enclosing `bindings` block, then on this binding.
        public let conditions: [Condition]
        public let rawString: String

        private static let recognizedPadButtons: Set<String> = [
            "a", "b", "x", "y",
            "shoulder_left", "shoulder_right",
            "trigger_left", "trigger_right",
            "joystick_left", "joystick_right",
            "start", "select", "back",
            "dpad_up", "dpad_down", "dpad_left", "dpad_right"
        ]

        private static let recognizedMouseButtons: Set<String> = [
            "left", "right", "middle", "forward", "back", "mouse4", "mouse5"
        ]

        /// Steam writes `command[, label[, icon]]`. The command ends at the first
        /// comma. A trailing field is the icon only when it is empty or names an
        /// image, so a label that itself contains a comma is kept whole.
        static func fields(_ raw: String) -> (command: String, label: String?, icon: String?) {
            guard let first = raw.firstIndex(of: ",") else { return (raw, nil, nil) }
            var rest = raw[raw.index(after: first)...]
            var icon: String?
            if let last = rest.lastIndex(of: ",") {
                let tail = rest[rest.index(after: last)...].trimmingCharacters(in: .whitespaces)
                let file = tail.split(separator: " ").first.map { $0.lowercased() } ?? ""
                if tail.isEmpty || file.hasSuffix(".png") || file.hasSuffix(".svg") {
                    icon = tail.isEmpty ? nil : tail
                    rest = rest[..<last]
                }
            }
            let label = rest.trimmingCharacters(in: .whitespaces)
            return (String(raw[..<first]), label.isEmpty ? nil : label, icon)
        }

        public init(raw: String, conditions: [Condition] = []) {
            self.rawString = raw
            self.conditions = conditions
            let fields = Self.fields(raw)
            self.label = fields.label
            self.icon = fields.icon

            let words = fields.command.split(separator: " ").map(String.init)
            let rawVerb = words.first?.lowercased() ?? ""
            let args = Array(words.dropFirst())
            let unverified = Verb.unverified(verb: rawVerb, arguments: args)

            switch rawVerb {
            case "xinput_button":
                verb = args.count == 1 && Self.recognizedPadButtons.contains(args[0].lowercased()) ? .xinputButton(args[0]) : unverified
            case "key_press":
                verb = args.count == 1 ? .keyPress(args[0]) : unverified
            case "mouse_button":
                verb = args.count == 1 && Self.recognizedMouseButtons.contains(args[0].lowercased()) ? .mouseButton(args[0]) : unverified
            case "mouse_wheel":
                let direction = args.first?.uppercased() ?? ""
                verb = args.count == 1 && ["SCROLL_UP", "SCROLL_DOWN"].contains(direction) ? .mouseWheel(direction) : unverified
            case "game_action":
                verb = args.count == 2 ? .gameAction(setID: args[0], actionID: args[1]) : unverified
            case "mode_shift":
                verb = args.count == 2 ? .modeShift(source: args[0].lowercased(), groupID: args[1]) : unverified
            case "controller_action":
                guard let command = args.first else { verb = unverified; break }
                let rest = Array(args.dropFirst())
                switch command.lowercased() {
                case "change_preset":
                    if let number = Self.presetNumber(rest.first) { verb = .actionSetChange(preset: number) } else { verb = unverified }
                case "add_layer", "remove_layer", "hold_layer":
                    if let number = Self.presetNumber(rest.first), let operation = LayerOperation(rawValue: command.lowercased()) {
                        verb = .layerChange(operation, preset: number)
                    } else { verb = unverified }
                default:
                    verb = .steamAction(command: command, arguments: rest)
                }
            default:
                verb = unverified
            }
        }

        private static func presetNumber(_ text: String?) -> Int? {
            guard let text, let number = Int(text), number >= 1, String(number) == text else { return nil }
            return number
        }

        /// What the binding does, without resolving the names of anything it refers to.
        public var displayText: String {
            var text: String
            switch verb {
            case .xinputButton(let btn):
                text = Self.formatPadButton(btn)
            case .keyPress(let key):
                text = Self.formatKey(key)
            case .mouseButton(let btn):
                text = "\(btn.capitalized) Click"
            case .mouseWheel(let dir):
                text = dir.uppercased() == "SCROLL_UP" ? "Wheel Up" : "Wheel Down"
            case .gameAction(let setID, let actionID):
                text = "Game action \(setID) › \(actionID)"
            case .modeShift(let source, let group):
                text = "Mode shift: \(Self.formatSource(source)) uses group \(group)"
            case .actionSetChange(let preset):
                text = "Change action set (preset \(preset))"
            case .layerChange(let operation, let preset):
                text = "\(Self.formatLayerOperation(operation)) (preset \(preset))"
            case .steamAction(let command, let args):
                text = "Steam: " + ([command] + args).joined(separator: " ").replacingOccurrences(of: "_", with: " ").capitalized
            case .unverified(let verb, let args):
                let argStr = args.joined(separator: " ")
                text = "Unverified: \(verb)\(argStr.isEmpty ? "" : " " + argStr) (\(rawString))"
            }
            if let label, !label.isEmpty {
                text += " (\(label))"
            }
            return text
        }

        public static func formatLayerOperation(_ operation: LayerOperation) -> String {
            switch operation {
            case .add: return "Add layer"
            case .remove: return "Remove layer"
            case .hold: return "Hold layer"
            }
        }

        public static func formatSource(_ source: String) -> String {
            switch source.lowercased() {
            case "button_diamond": return "Face buttons"
            case "dpad": return "D-pad"
            case "joystick": return "Left stick"
            case "right_joystick": return "Right stick"
            case "left_trigger": return "Left trigger"
            case "right_trigger": return "Right trigger"
            case "switch": return "Bumpers and menu buttons"
            case "left_trackpad": return "Left trackpad"
            case "right_trackpad": return "Right trackpad"
            case "center_trackpad": return "Touchpad"
            case "gyro": return "Gyro"
            default: return source.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        public var outputCategory: OutputCategory {
            switch verb {
            case .xinputButton: return .gamepad
            case .keyPress: return .keyboard
            case .mouseButton, .mouseWheel: return .mouse
            case .gameAction: return .action
            case .modeShift, .actionSetChange, .layerChange: return .layout
            case .steamAction: return .steam
            case .unverified: return .unverified
            }
        }

        public static func formatPadButton(_ btn: String) -> String {
            switch btn.lowercased() {
            case "a": return "A (Cross)"
            case "b": return "B (Circle)"
            case "x": return "X (Square)"
            case "y": return "Y (Triangle)"
            case "shoulder_left": return "LB (L1)"
            case "shoulder_right": return "RB (R1)"
            case "trigger_left": return "LT (L2)"
            case "trigger_right": return "RT (R2)"
            case "joystick_left": return "L3 (Left Stick Click)"
            case "joystick_right": return "R3 (Right Stick Click)"
            case "start": return "Menu (Options)"
            case "select", "back": return "View (Create/Share)"
            case "dpad_up": return "D-Pad Up"
            case "dpad_down": return "D-Pad Down"
            case "dpad_left": return "D-Pad Left"
            case "dpad_right": return "D-Pad Right"
            default: return "Controller: " + btn.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        public static func formatKey(_ key: String) -> String {
            switch key.uppercased() {
            case "SPACE": return "Space"
            case "LEFT_SHIFT": return "Left Shift"
            case "RIGHT_SHIFT": return "Right Shift"
            case "LEFT_CONTROL", "LEFT_CTRL": return "Left Ctrl"
            case "RIGHT_CONTROL", "RIGHT_CTRL": return "Right Ctrl"
            case "LEFT_ALT": return "Left Alt"
            case "RIGHT_ALT": return "Right Alt"
            case "ESCAPE": return "Escape"
            case "TAB": return "Tab"
            case "RETURN", "ENTER": return "Return"
            case "BACKSPACE": return "Backspace"
            case "UP_ARROW": return "↑"
            case "DOWN_ARROW": return "↓"
            case "LEFT_ARROW": return "←"
            case "RIGHT_ARROW": return "→"
            case let k where k.hasPrefix("KEY_"): return String(k.dropFirst(4)).uppercased()
            default: return key.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    public enum OutputCategory: Equatable, Sendable {
        case gamepad
        case keyboard
        case mouse
        case action
        /// Switches what the layout itself does: a mode shift, action set or layer.
        case layout
        /// Carried out by Steam, not sent to the game as input.
        case steam
        case unverified
    }

    public struct Activator: Equatable, Sendable {
        public let kind: String
        public let bindings: [ParsedBinding]
        public let toggle: Bool
        public let turbo: Bool
        /// Conditions on the enclosing `activators` block, then on this activator.
        public let conditions: [Condition]
        public let settings: [String: String]

        public var humanKind: String {
            switch kind.lowercased() {
            case "full_press": return "Regular Press"
            case "long_press": return "Long Press"
            case "double_press": return "Double Press"
            case "soft_press": return "Soft Press"
            case "start_press": return "Start Press"
            case "release": return "Release Press"
            case "chord": return "Chord Press"
            default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    public struct Input: Equatable, Sendable {
        public let name: String
        public let activators: [Activator]
        /// Conditions on the enclosing `inputs` block, then on this input.
        public let conditions: [Condition]

        public var isBound: Bool { activators.contains { !$0.bindings.isEmpty } }

        public var humanName: String {
            switch name.lowercased() {
            case "button_a": return "Cross (A)"
            case "button_b": return "Circle (B)"
            case "button_x": return "Square (X)"
            case "button_y": return "Triangle (Y)"
            // The names Steam writes for the bumper and menu inputs of the `switch` source.
            case "left_bumper", "shoulder_left": return "L1 (LB)"
            case "right_bumper", "shoulder_right": return "R1 (RB)"
            case "trigger_left": return "L2 (LT)"
            case "trigger_right": return "R2 (RT)"
            case "joystick_left": return "Left Stick Click (L3)"
            case "joystick_right": return "Right Stick Click (R3)"
            case "button_escape", "start": return "Options (Menu)"
            case "button_menu", "select", "back": return "Create / Share (View)"
            case "button_back_left": return "Rear Left"
            case "button_back_right": return "Rear Right"
            case "button_back_left_upper": return "Rear Left Upper"
            case "button_back_right_upper": return "Rear Right Upper"
            case "button_capture": return "Capture"
            case "edge": return "Outer Ring"
            case "dpad_north", "dpad_up": return "D-Pad Up"
            case "dpad_south", "dpad_down": return "D-Pad Down"
            case "dpad_west", "dpad_left": return "D-Pad Left"
            case "dpad_east", "dpad_right": return "D-Pad Right"
            case "click": return "Click"
            case "touch": return "Touch"
            case "gyro": return "Gyroscope Motion"
            default: return name.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    /// One `gameactions` entry of a group: the analog game action the whole
    /// group feeds, such as a stick bound to "Move".
    public struct GameActionReference: Equatable, Sendable {
        public let setID: String
        public let actionID: String
        /// Conditions on the enclosing `gameactions` block, then on this entry.
        public let conditions: [Condition]
    }

    public struct Group: Equatable, Sendable {
        public let id: String
        public let mode: String
        public let inputs: [Input]
        /// Conditions on the `group` block itself.
        public let conditions: [Condition]
        public let settings: [String: String]
        public let gameActions: [GameActionReference]

        public func input(_ name: String) -> Input? {
            inputs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        public var humanMode: String {
            switch mode.lowercased() {
            case "four_buttons": return "Face Buttons"
            case "dpad": return "Directional Pad"
            case "joystick", "joystick_move": return "Analog Joystick"
            case "joystick_mouse": return "Joystick Mouse"
            case "trigger": return "Analog Trigger"
            case "trigger_threshold": return "Threshold Trigger"
            case "absolute_mouse": return "Mouse"
            case "relative_mouse": return "Relative Mouse"
            case "scrollwheel": return "Scroll Wheel"
            case "radial_menu": return "Radial Menu"
            case "touch_menu": return "Touch Menu"
            case "mouse_joystick": return "Mouse Joystick"
            default: return mode.isEmpty ? "Direct Inputs" : mode.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    public struct SourceBinding: Equatable, Sendable {
        public let groupID: String
        public let source: String
        public let flags: Set<String>
        /// Conditions on the enclosing `group_source_bindings` block, then on this entry.
        public let conditions: [Condition]

        public var isActive: Bool { flags.contains("active") }
        public var isModeShift: Bool { flags.contains("modeshift") }
    }

    public struct Preset: Equatable, Sendable {
        public let id: String
        public let name: String
        public let bindings: [SourceBinding]
        /// Conditions on the `preset` block itself.
        public let conditions: [Condition]
        public let settings: [String: String]
    }

    public struct ActionSet: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let isNative: Bool
        /// Conditions on the enclosing `actions` block, then on this set.
        public let conditions: [Condition]

        public init(id: String, title: String, isNative: Bool, conditions: [Condition] = []) {
            self.id = id
            self.title = title
            self.isNative = isNative
            self.conditions = conditions
        }
    }

    public struct ActionLayer: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let parentSetID: String
        /// Conditions on the enclosing `action_layers` block, then on this layer.
        public let conditions: [Condition]

        public init(id: String, title: String, parentSetID: String, conditions: [Condition] = []) {
            self.id = id
            self.title = title
            self.parentSetID = parentSetID
            self.conditions = conditions
        }
    }

    public let title: String
    public let description: String
    public let version: Int
    public let revision: UInt32
    public let controllerType: String
    public let actionSets: [ActionSet]
    public let actionLayers: [ActionLayer]
    public let presets: [Preset]
    /// Every `group` block in source order. Two blocks may carry the same id;
    /// neither is dropped, and `lookup(group:)` reports that as ambiguous.
    public let groupDefinitions: [Group]
    /// False when the layout has no `actions` block and `actionSets` was derived from its presets.
    public let declaresActionSets: Bool
    /// Conditions on the `controller_mappings` block itself.
    public let conditions: [Condition]
    /// Every condition in the interpreted layout, once each, in source order.
    public let conditionSites: [ConditionSite]
    public let unrecognizedEntries: [UnrecognizedEntry]

    private static func buildUnrecognized(node: VDFNode, parentPath: String, document: VDFDocument) -> UnrecognizedEntry {
        let span = node.fullSpan
        let rawBytes = document.sourceData[span.lower..<span.upper]
        let rawString = String(decoding: rawBytes, as: UTF8.self)
        let id = "\(parentPath)@\(span.lower)"

        switch node {
        case .leaf(let key, _, _):
            let keyStr = document.stringValue(for: key)
            let path = "\(parentPath)/\(keyStr)"
            return UnrecognizedEntry(id: id, path: path, key: keyStr, rawContent: rawString, span: span, children: [])
        case .block(let key, _, let children, _, _):
            let keyStr = document.stringValue(for: key)
            let path = "\(parentPath)/\(keyStr)"
            let subEntries = children.compactMap { child -> UnrecognizedEntry? in
                switch child {
                case .leaf, .block:
                    return buildUnrecognized(node: child, parentPath: path, document: document)
                case .standaloneComment, .directive:
                    return nil
                }
            }
            return UnrecognizedEntry(id: id, path: path, key: keyStr, rawContent: rawString, span: span, children: subEntries)
        case .standaloneComment, .directive:
            return UnrecognizedEntry(id: id, path: parentPath, key: "trivia", rawContent: rawString, span: span, children: [])
        }
    }

    /// Walks the CST once. Each condition token on an interpreted node passes
    /// through `conditions(_:scope:slug:in:)` exactly once, which records its
    /// site. A domain value then carries the conditions of its container block
    /// followed by its own; nothing here selects one condition over another.
    /// Uninterpreted nodes keep their conditions inside their raw source text.
    private struct Builder {
        let document: VDFDocument
        var sites: [ConditionSite] = []
        var unrecognized: [UnrecognizedEntry] = []

        func text(_ token: VDFToken) -> String { document.stringValue(for: token) }
        func key(_ token: VDFToken) -> String { text(token).lowercased() }

        /// The value of the last leaf named `name`, matching how repeated `id`/`name` leaves resolve.
        func lastLeaf(_ name: String, in nodes: [VDFNode]) -> String? {
            var value: String?
            for case .leaf(let leafKey, let leafValue, _) in nodes where key(leafKey) == name { value = text(leafValue) }
            return value
        }

        mutating func conditions(_ tokens: [VDFToken], scope: String, slug: String, in location: String) -> [Condition] {
            let found = tokens.map { Condition(scope: scope, expression: text($0)) }
            sites += found.map { ConditionSite(slug: slug, location: location, condition: $0) }
            return found
        }

        /// A recognized property or block whose condition no domain value carries.
        mutating func note(_ node: VDFNode, as kind: String, in location: String) {
            switch node {
            case .leaf(let nodeKey, _, let tokens), .block(let nodeKey, _, _, _, let tokens):
                _ = conditions(tokens, scope: "\(kind) '\(text(nodeKey))'", slug: "property", in: location)
            case .standaloneComment, .directive:
                break
            }
        }

        mutating func uninterpreted(_ node: VDFNode, under path: String) {
            if case .standaloneComment = node { return }
            unrecognized.append(SteamInputLayoutModel.buildUnrecognized(node: node, parentPath: path, document: document))
        }

        mutating func actionSets(_ children: [VDFNode], container: [Condition]) -> [ActionSet] {
            var sets: [ActionSet] = []
            for child in children {
                guard case .block(let setKey, _, let props, _, let tokens) = child else {
                    uninterpreted(child, under: "controller_mappings/actions")
                    continue
                }
                let id = text(setKey)
                let scope = "Action Set '\(id)'"
                let own = conditions(tokens, scope: scope, slug: "set-\(id)", in: "")
                var title = id
                var isNative = false
                for prop in props {
                    guard case .leaf(let propKey, let propValue, _) = prop else {
                        uninterpreted(prop, under: "controller_mappings/actions/\(id)")
                        continue
                    }
                    switch key(propKey) {
                    case "title": title = text(propValue)
                    case "legacy_set": isNative = text(propValue) == "0"
                    default:
                        uninterpreted(prop, under: "controller_mappings/actions/\(id)")
                        continue
                    }
                    note(prop, as: "Property", in: scope)
                }
                sets.append(ActionSet(id: id, title: title, isNative: isNative, conditions: container + own))
            }
            return sets
        }

        mutating func actionLayers(_ children: [VDFNode], container: [Condition]) -> [ActionLayer] {
            var layers: [ActionLayer] = []
            for child in children {
                guard case .block(let layerKey, _, let props, _, let tokens) = child else {
                    uninterpreted(child, under: "controller_mappings/action_layers")
                    continue
                }
                let id = text(layerKey)
                let scope = "Action Layer '\(id)'"
                let own = conditions(tokens, scope: scope, slug: "layer-\(id)", in: "")
                var title = id
                var parentSet = ""
                for prop in props {
                    guard case .leaf(let propKey, let propValue, _) = prop else {
                        uninterpreted(prop, under: "controller_mappings/action_layers/\(id)")
                        continue
                    }
                    switch key(propKey) {
                    case "title": title = text(propValue)
                    case "parent_set_name": parentSet = text(propValue)
                    default:
                        uninterpreted(prop, under: "controller_mappings/action_layers/\(id)")
                        continue
                    }
                    note(prop, as: "Property", in: scope)
                }
                layers.append(ActionLayer(id: id, title: title, parentSetID: parentSet, conditions: container + own))
            }
            return layers
        }

        /// Nil for a group without an `id`: no preset can refer to it.
        mutating func group(_ children: [VDFNode], tokens: [VDFToken]) -> Group? {
            let id = lastLeaf("id", in: children) ?? ""
            let name = id.isEmpty ? "unnamed" : id
            let scope = "Group \(name)"
            let path = "controller_mappings/group[\(name)]"
            let own = conditions(tokens, scope: scope, slug: "group-\(name)", in: "")
            var mode = ""
            var inputs: [Input] = []
            var settings: [String: String] = [:]
            var gameActions: [GameActionReference] = []
            for child in children {
                switch child {
                case .leaf(let leafKey, let leafValue, _):
                    switch key(leafKey) {
                    case "id": break
                    case "mode": mode = text(leafValue)
                    default:
                        uninterpreted(child, under: path)
                        continue
                    }
                    note(child, as: "Property", in: scope)
                case .block(let blockKey, _, let entries, _, let blockTokens):
                    switch key(blockKey) {
                    case "inputs":
                        let container = conditions(blockTokens, scope: "Inputs Container", slug: "inputs-\(name)", in: scope)
                        for entry in entries {
                            guard case .block(let inputKey, _, let body, _, let inputTokens) = entry else {
                                uninterpreted(entry, under: "\(path)/inputs")
                                continue
                            }
                            inputs.append(input(text(inputKey), body, tokens: inputTokens, container: container,
                                                groupScope: scope, groupPath: path, groupSlug: name))
                        }
                    case "settings":
                        note(child, as: "Block", in: scope)
                        for entry in entries {
                            guard case .leaf(let settingKey, let settingValue, _) = entry else {
                                uninterpreted(entry, under: "\(path)/settings")
                                continue
                            }
                            settings[key(settingKey)] = text(settingValue)
                            note(entry, as: "Setting", in: scope)
                        }
                    case "gameactions":
                        let container = conditions(blockTokens, scope: "Game Actions Container", slug: "gameactions-\(name)", in: scope)
                        for entry in entries {
                            guard case .leaf(let setKey, let actionValue, let entryTokens) = entry else {
                                uninterpreted(entry, under: "\(path)/gameactions")
                                continue
                            }
                            let leaf = conditions(entryTokens, scope: "Game Action '\(text(actionValue))'", slug: "gameaction-\(name)", in: scope)
                            gameActions.append(GameActionReference(setID: text(setKey), actionID: text(actionValue), conditions: container + leaf))
                        }
                    default:
                        uninterpreted(child, under: path)
                    }
                case .standaloneComment, .directive:
                    break
                }
            }
            guard !id.isEmpty else { return nil }
            return Group(id: id, mode: mode, inputs: inputs, conditions: own, settings: settings, gameActions: gameActions)
        }

        mutating func input(_ name: String, _ body: [VDFNode], tokens: [VDFToken], container: [Condition],
                            groupScope: String, groupPath: String, groupSlug: String) -> Input {
            let scope = "Input '\(name)'"
            let location = "\(groupScope) › \(scope)"
            let path = "\(groupPath)/inputs[\(name)]"
            let slug = "\(groupSlug)-\(name)"
            let own = conditions(tokens, scope: scope, slug: "input-\(slug)", in: groupScope)
            var activators: [Activator] = []
            for child in body {
                guard case .block(let blockKey, _, let entries, _, let blockTokens) = child, key(blockKey) == "activators" else {
                    uninterpreted(child, under: path)
                    continue
                }
                let activatorContainer = conditions(blockTokens, scope: "Activators Container", slug: "activators-\(slug)", in: location)
                for entry in entries {
                    guard case .block(let kindKey, _, let props, _, let kindTokens) = entry else {
                        uninterpreted(entry, under: "\(path)/activators")
                        continue
                    }
                    activators.append(activator(text(kindKey), props, tokens: kindTokens, container: activatorContainer,
                                                inputLocation: location, inputPath: path, inputSlug: slug))
                }
            }
            return Input(name: name, activators: activators, conditions: container + own)
        }

        mutating func activator(_ kind: String, _ props: [VDFNode], tokens: [VDFToken], container: [Condition],
                                inputLocation: String, inputPath: String, inputSlug: String) -> Activator {
            let scope = "Activator '\(kind)'"
            let location = "\(inputLocation) › \(scope)"
            let path = "\(inputPath)/\(kind)"
            let slug = "\(inputSlug)-\(kind)"
            let own = conditions(tokens, scope: scope, slug: "activator-\(slug)", in: inputLocation)
            var bindings: [ParsedBinding] = []
            var settings: [String: String] = [:]
            for prop in props {
                guard case .block(let propKey, _, let entries, _, let propTokens) = prop else {
                    uninterpreted(prop, under: path)
                    continue
                }
                switch key(propKey) {
                case "bindings":
                    let bindingContainer = conditions(propTokens, scope: "Bindings Container", slug: "bindings-\(slug)", in: location)
                    for entry in entries {
                        guard case .leaf(let bindingKey, let bindingValue, let bindingTokens) = entry, key(bindingKey) == "binding" else {
                            uninterpreted(entry, under: "\(path)/bindings")
                            continue
                        }
                        let leaf = conditions(bindingTokens, scope: "Binding", slug: "binding-\(slug)", in: location)
                        bindings.append(ParsedBinding(raw: text(bindingValue), conditions: bindingContainer + leaf))
                    }
                case "settings":
                    note(prop, as: "Block", in: location)
                    for entry in entries {
                        guard case .leaf(let settingKey, let settingValue, _) = entry else {
                            uninterpreted(entry, under: "\(path)/settings")
                            continue
                        }
                        settings[key(settingKey)] = text(settingValue)
                        note(entry, as: "Setting", in: location)
                    }
                default:
                    uninterpreted(prop, under: path)
                }
            }
            return Activator(kind: kind, bindings: bindings, toggle: settings["toggle"] == "1", turbo: settings["turbo"] == "1",
                             conditions: container + own, settings: settings)
        }

        mutating func preset(_ children: [VDFNode], tokens: [VDFToken]) -> Preset {
            let id = lastLeaf("id", in: children) ?? ""
            let name = lastLeaf("name", in: children) ?? ""
            let scope = "Preset '\(name.isEmpty ? id : name)'"
            let path = "controller_mappings/preset[\(id.isEmpty ? "unnamed" : id)]"
            let own = conditions(tokens, scope: scope, slug: "preset-\(id)", in: "")
            var bindings: [SourceBinding] = []
            var settings: [String: String] = [:]
            for child in children {
                switch child {
                case .leaf(let leafKey, let leafValue, _):
                    let property = key(leafKey)
                    if property != "id", property != "name" { settings[property] = text(leafValue) }
                    note(child, as: "Property", in: scope)
                case .block(let blockKey, _, let entries, _, let blockTokens):
                    guard key(blockKey) == "group_source_bindings" else {
                        uninterpreted(child, under: path)
                        continue
                    }
                    let container = conditions(blockTokens, scope: "Source Bindings Container", slug: "srcbinds-\(id)", in: scope)
                    for entry in entries {
                        guard case .leaf(let groupKey, let sourceValue, let sourceTokens) = entry else {
                            uninterpreted(entry, under: "\(path)/group_source_bindings")
                            continue
                        }
                        let words = text(sourceValue).split(separator: " ").map { $0.lowercased() }
                        guard let source = words.first else {
                            uninterpreted(entry, under: "\(path)/group_source_bindings")
                            continue
                        }
                        let leaf = conditions(sourceTokens, scope: "Source Binding '\(source)'", slug: "srcbind-\(id)-\(source)", in: scope)
                        bindings.append(SourceBinding(groupID: text(groupKey), source: source, flags: Set(words.dropFirst()),
                                                      conditions: container + leaf))
                    }
                case .standaloneComment, .directive:
                    break
                }
            }
            return Preset(id: id, name: name, bindings: bindings, conditions: own, settings: settings)
        }
    }

    public init(document: VDFDocument) throws {
        guard let rootIndex = document.rootNodes.firstIndex(where: { node in
            if case .block(let key, _, _, _, _) = node {
                return document.stringValue(for: key).caseInsensitiveCompare("controller_mappings") == .orderedSame
            }
            return false
        }), case .block(_, _, let mappingChildren, _, let rootTokens) = document.rootNodes[rootIndex] else {
            throw VDFParseError.missingIdentifier
        }

        var builder = Builder(document: document)
        self.conditions = builder.conditions(rootTokens, scope: "Root", slug: "root", in: "")

        var parsedTitle = ""
        var parsedDesc = ""
        var parsedVersion = 3
        var parsedRevision: UInt32 = 0
        var parsedControllerType = ""
        var parsedSets: [ActionSet] = []
        var parsedLayers: [ActionLayer] = []
        var parsedPresets: [Preset] = []
        var parsedGroups: [Group] = []
        var declaresSets = false

        for child in mappingChildren {
            switch child {
            case .leaf(let key, let val, _):
                let v = builder.text(val)
                switch builder.key(key) {
                case "title": parsedTitle = v
                case "description": parsedDesc = v
                case "version": parsedVersion = Int(v) ?? 3
                case "revision": parsedRevision = UInt32(v) ?? 0
                case "controller_type": parsedControllerType = v
                default:
                    builder.uninterpreted(child, under: "controller_mappings")
                    continue
                }
                builder.note(child, as: "Property", in: "")
            case .block(let key, _, let blockChildren, _, let blockTokens):
                switch builder.key(key) {
                case "actions":
                    declaresSets = true
                    let container = builder.conditions(blockTokens, scope: "Action Sets Container", slug: "sets", in: "")
                    parsedSets += builder.actionSets(blockChildren, container: container)
                case "action_layers":
                    let container = builder.conditions(blockTokens, scope: "Action Layers Container", slug: "layers", in: "")
                    parsedLayers += builder.actionLayers(blockChildren, container: container)
                case "group":
                    if let group = builder.group(blockChildren, tokens: blockTokens) { parsedGroups.append(group) }
                case "preset":
                    parsedPresets.append(builder.preset(blockChildren, tokens: blockTokens))
                default:
                    builder.uninterpreted(child, under: "controller_mappings")
                }
            case .standaloneComment, .directive: break
            }
        }

        // Anything beside the mappings block is shown as uninterpreted rather than ignored.
        for (index, node) in document.rootNodes.enumerated() where index != rootIndex {
            builder.uninterpreted(node, under: "(document)")
        }

        self.title = parsedTitle
        self.description = parsedDesc
        self.version = parsedVersion
        self.revision = parsedRevision
        self.controllerType = parsedControllerType
        if parsedSets.isEmpty {
            if parsedPresets.isEmpty {
                self.actionSets = [ActionSet(id: "Default", title: "Default", isNative: false)]
            } else {
                // A set synthesized from a preset has no block of its own; the
                // preset's conditions stay on the preset it resolves to.
                self.actionSets = parsedPresets.map { p in
                    ActionSet(id: p.id.isEmpty ? p.name : p.id, title: p.name.isEmpty ? "Preset \(p.id)" : p.name, isNative: false)
                }
            }
        } else {
            self.actionSets = parsedSets
        }
        self.actionLayers = parsedLayers
        self.presets = parsedPresets
        self.groupDefinitions = parsedGroups
        self.declaresActionSets = declaresSets
        self.conditionSites = builder.sites
        self.unrecognizedEntries = builder.unrecognized
    }

    /// What an id resolves to. A reference is usable only when exactly one
    /// definition carries the id; the model never picks among several.
    public enum GroupLookup: Equatable, Sendable {
        case defined(Group)
        case missing
        case ambiguous([Group])
    }

    public func lookup(group id: String) -> GroupLookup {
        let found = groupDefinitions.filter { $0.id == id }
        switch found.count {
        case 0: return .missing
        case 1: return .defined(found[0])
        default: return .ambiguous(found)
        }
    }

    /// The presets a `CHANGE_PRESET` or layer binding's number names: Steam
    /// counts from 1, the layout's preset ids from 0.
    public func presets(numbered number: Int) -> [Preset] {
        presets.filter { $0.id == String(number - 1) }
    }

    /// The action set or layer a preset holds the bindings of, matched as `preset(for:)` does.
    public func title(of preset: Preset) -> String? {
        if let layer = actionLayers.first(where: { self.preset(for: $0) == preset }) { return layer.title }
        if let set = actionSets.first(where: { self.preset(for: $0) == preset }) { return set.title }
        return nil
    }

    /// Resolves the corresponding preset for an action set without guessing by array position or sole preset.
    public func preset(for actionSet: ActionSet) -> Preset? {
        // Match ONLY by name/title or exact ID
        if let p = presets.first(where: {
            $0.name.caseInsensitiveCompare(actionSet.id) == .orderedSame ||
            $0.name.caseInsensitiveCompare(actionSet.title) == .orderedSame
        }) {
            return p
        }
        if let p = presets.first(where: { $0.id == actionSet.id }) {
            return p
        }
        return nil
    }

    /// Resolves the corresponding preset for an action layer without guessing.
    public func preset(for actionLayer: ActionLayer) -> Preset? {
        if let p = presets.first(where: {
            $0.name.caseInsensitiveCompare(actionLayer.id) == .orderedSame ||
            $0.name.caseInsensitiveCompare(actionLayer.title) == .orderedSame
        }) {
            return p
        }
        if let p = presets.first(where: { $0.id == actionLayer.id }) {
            return p
        }
        return nil
    }
}
