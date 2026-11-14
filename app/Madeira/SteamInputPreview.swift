// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Observation

/// Read-only preview presentation model organizing a Steam Input layout across sets, layers, and regions.
public struct SteamInputPreviewData: Equatable, Sendable {
    public enum DiagnosticCategory: Equatable, Sendable {
        case unavailableHardware
        case viewerOrRuntimeLimitation
        case unresolvedReference

        public var title: String {
            switch self {
            case .unavailableHardware: return "Unavailable Controller Features"
            case .viewerOrRuntimeLimitation: return "Viewer & Runtime Limitations"
            case .unresolvedReference: return "Unresolved References"
            }
        }
    }

    public struct FeatureDiagnosis: Equatable, Identifiable, Sendable {
        public let id: String
        public let category: DiagnosticCategory
        public let title: String
        public let detail: String

        public init(id: String, category: DiagnosticCategory, title: String, detail: String) {
            self.id = id
            self.category = category
            self.title = title
            self.detail = detail
        }
    }

    /// The domain model's condition: verbatim expression plus the node it is written on.
    public typealias SourceCondition = SteamInputLayoutModel.Condition

    /// What a mode shift switches its source to while held: the shifted
    /// group's own mappings, built exactly like any other group's.
    public struct ModeShiftView: Equatable, Sendable {
        public let source: String
        public let groupID: String
        public let groupTitle: String
        public let inputs: [InputMappingView]
    }

    public struct BindingView: Equatable, Identifiable, Sendable {
        public let id: String
        public let displayText: String
        public let rawBinding: String
        public let category: SteamInputLayoutModel.OutputCategory
        public let isUnresolved: Bool
        public let conditions: [SourceCondition]
        /// Present for a mode shift whose group is defined exactly once.
        public let modeShift: ModeShiftView?

        public init(
            id: String,
            displayText: String,
            rawBinding: String,
            category: SteamInputLayoutModel.OutputCategory,
            isUnresolved: Bool = false,
            conditions: [SourceCondition] = [],
            modeShift: ModeShiftView? = nil
        ) {
            self.id = id
            self.displayText = displayText
            self.rawBinding = rawBinding
            self.category = category
            self.isUnresolved = isUnresolved
            self.conditions = conditions
            self.modeShift = modeShift
        }
    }

    public struct ActivatorView: Equatable, Identifiable, Sendable {
        public let id: String
        public let kind: String
        public let bindings: [BindingView]
        public let toggle: Bool
        public let turbo: Bool
        /// Written in the layout's `disabled_activators`: kept, but switched off.
        public let isDisabled: Bool
        public let conditions: [SourceCondition]

        public init(
            id: String,
            kind: String,
            bindings: [BindingView],
            toggle: Bool = false,
            turbo: Bool = false,
            isDisabled: Bool = false,
            conditions: [SourceCondition] = []
        ) {
            self.id = id
            self.kind = kind
            self.bindings = bindings
            self.toggle = toggle
            self.turbo = turbo
            self.isDisabled = isDisabled
            self.conditions = conditions
        }
    }

    public struct InputMappingView: Equatable, Identifiable, Sendable {
        public let id: String
        public let inputName: String
        /// The physical source the row belongs to, such as "Left trigger";
        /// several sources share input names like "Click".
        public let sourceName: String?
        public let activators: [ActivatorView]
        public let settings: [String: String]?
        public let conditions: [SourceCondition]
        public let isLayerOverride: Bool
        public let isInherited: Bool
        public let parentSetName: String?
        public let isMissingReference: Bool
        public let rawContent: String?

        public init(
            id: String,
            inputName: String,
            sourceName: String? = nil,
            activators: [ActivatorView],
            settings: [String: String]? = nil,
            conditions: [SourceCondition] = [],
            isLayerOverride: Bool = false,
            isInherited: Bool = false,
            parentSetName: String? = nil,
            isMissingReference: Bool = false,
            rawContent: String? = nil
        ) {
            self.id = id
            self.inputName = inputName
            self.sourceName = sourceName
            self.activators = activators
            self.settings = settings
            self.conditions = conditions
            self.isLayerOverride = isLayerOverride
            self.isInherited = isInherited
            self.parentSetName = parentSetName
            self.isMissingReference = isMissingReference
            self.rawContent = rawContent
        }
    }

    public struct ControllerRegionView: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let inputs: [InputMappingView]

        public init(id: String, title: String, inputs: [InputMappingView]) {
            self.id = id
            self.title = title
            self.inputs = inputs
        }
    }

    public struct ActionSetView: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let isLayer: Bool
        public let parentSetID: String?
        public let isNative: Bool
        public let conditions: [SourceCondition]
        public let regions: [ControllerRegionView]

        public init(
            id: String,
            title: String,
            isLayer: Bool,
            parentSetID: String? = nil,
            isNative: Bool = false,
            conditions: [SourceCondition] = [],
            regions: [ControllerRegionView]
        ) {
            self.id = id
            self.title = title
            self.isLayer = isLayer
            self.parentSetID = parentSetID
            self.isNative = isNative
            self.conditions = conditions
            self.regions = regions
        }
    }

    /// One layout-wide setting, shown as written. The preview does not interpret its value.
    public struct LayoutSetting: Equatable, Identifiable, Sendable {
        public let key: String
        public let value: String
        public var id: String { key }
    }

    public let title: String
    public let description: String
    public let controllerType: String
    public let actionSets: [ActionSetView]
    public let diagnoses: [FeatureDiagnosis]
    public let uninterpretedEntries: [SteamInputLayoutModel.UnrecognizedEntry]
    /// Every condition in the layout. None is evaluated, so whether the node it
    /// is written on applies is unresolved.
    public let unevaluatedConditions: [SteamInputLayoutModel.ConditionSite]
    /// The layout-wide `settings` block in key order.
    public let layoutSettings: [LayoutSetting]
    /// Where the names of the layout's game actions came from, or why they
    /// are shown unresolved. Nil when the layout binds no game action.
    public let actionNameNote: String?

    public static let conditionWarning = "Condition not evaluated by this preview; current apply validation rejects conditional layouts."

    /// A layout is fully compatible ONLY when it has no hardware gaps, no platform conditions, no unresolved references, and no viewer limitations.
    public var isFullyCompatible: Bool {
        diagnoses.isEmpty && unevaluatedConditions.isEmpty
    }

    /// `actions` is where the game's own action names come from. Only a
    /// manifest resolves a name; any other source leaves every game action
    /// shown as the layout writes it, marked unresolved, with the reason.
    init(model: SteamInputLayoutModel, actions: SteamInputActionNames) {
        let builder = Builder(model: model, names: actions)
        self.title = model.localized(model.title) ?? (model.title.isEmpty ? "Untitled Layout" : model.title)
        self.description = model.localized(model.description) ?? model.description
        self.controllerType = model.controllerType.isEmpty ? "Generic Pad" : model.controllerType
        self.uninterpretedEntries = model.unrecognizedEntries
        self.unevaluatedConditions = model.conditionSites
        self.layoutSettings = model.settings.keys.sorted().map { LayoutSetting(key: $0, value: model.settings[$0] ?? "") }

        var setViews: [ActionSetView] = []
        var detectedDiagnoses: [FeatureDiagnosis] = []

        // 1. Controller Type Diagnosis
        let normalizedType = model.controllerType.lowercased()
        if !["controller_ps5", "controller_ps4", ""].contains(normalizedType) {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-type",
                category: .unavailableHardware,
                title: "Controller Type: \(model.controllerType)",
                detail: "Layout is authored for \(model.controllerType). Madeira uses a virtual DualSense (PS5) bridge."
            ))
        }
        if model.version != 3 {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-version",
                category: .viewerOrRuntimeLimitation,
                title: "Layout Format Version \(model.version)",
                detail: "This preview reads version 3 layouts. Parts written in another format are listed as uninterpreted content."
            ))
        }

        // 2. Platform Conditions: one diagnosis per condition written in the layout, never evaluated.
        for (index, site) in model.conditionSites.enumerated() {
            let place = site.location.isEmpty ? "" : " in \(site.location)"
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-cond-\(site.slug)-\(index)",
                category: .viewerOrRuntimeLimitation,
                title: "\(site.condition.scope) Condition\(place): \(site.condition.expression)",
                detail: Self.conditionWarning
            ))
        }

        // 3. References to groups, action sets and layers: the same check that
        // refuses a layout before it is applied, so the two cannot disagree.
        for problem in SteamInputReferences.problems(in: model) {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-\(problem.id)",
                category: .unresolvedReference,
                title: problem.title,
                detail: problem.reason
            ))
        }

        // 4. Game actions, Steam actions and binding grammar, in source order.
        var gameActions: [(set: String, action: String)] = []
        var steamActions: [String] = []
        var unverified: [String] = []
        for group in model.groupDefinitions {
            gameActions += group.gameActions.map { ($0.setID, $0.actionID) }
            for binding in group.inputs.flatMap({ $0.activators.flatMap(\.bindings) }) {
                switch binding.verb {
                case .gameAction(let setID, let actionID):
                    gameActions.append((setID, actionID))
                case .steamAction(let command, _):
                    // Steam's placeholders for "nothing bound" do nothing to verify.
                    guard !SteamInputLayoutModel.ParsedBinding.emptyCommands.contains(command.lowercased()) else { break }
                    let name = command.replacingOccurrences(of: "_", with: " ").capitalized
                    if !steamActions.contains(name) { steamActions.append(name) }
                case .unverified:
                    if !unverified.contains(binding.rawString) { unverified.append(binding.rawString) }
                case .xinputButton, .keyPress, .mouseButton, .mouseWheel, .modeShift, .actionSetChange, .layerChange:
                    break
                }
            }
        }
        if gameActions.isEmpty {
            actionNameNote = nil
        } else if let manifest = actions.manifest {
            var missing: [String] = []
            for reference in gameActions where manifest.action(reference.action, in: reference.set) == nil {
                let name = "\(reference.set) › \(reference.action)"
                if !missing.contains(name) { missing.append(name) }
            }
            actionNameNote = "Action names come from the game's action manifest."
            if !missing.isEmpty {
                detectedDiagnoses.append(FeatureDiagnosis(
                    id: "diag-actions-undeclared",
                    category: .unresolvedReference,
                    title: missing.count == 1 ? "1 Action Is Not In The Game's Action Manifest" : "\(missing.count) Actions Are Not In The Game's Action Manifest",
                    detail: "The installed game does not declare: " + missing.joined(separator: ", ") + ". The layout may be written for another version of the game."
                ))
            }
        } else {
            let reason = actions.explanation ?? "The game's action manifest is unavailable."
            actionNameNote = "Action names are not resolved. " + reason
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-actions-unresolved",
                category: .unresolvedReference,
                title: "Action Names Not Resolved",
                detail: reason + " The layout's game actions are shown as it writes them."
            ))
        }
        if !steamActions.isEmpty {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-steam-actions",
                category: .viewerOrRuntimeLimitation,
                title: "Steam Actions",
                detail: "Carried out by Steam itself, not sent to the game: " + steamActions.joined(separator: ", ") + ". Madeira has not verified them."
            ))
        }
        for (index, raw) in unverified.enumerated() {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-unverified-\(index)",
                category: .viewerOrRuntimeLimitation,
                title: "Unverified Binding Grammar: \(raw.split(separator: " ").first.map(String.init) ?? raw)",
                detail: "Binding '\(raw)' has unrecognized grammar or unsupported arguments."
            ))
        }

        // 5. Hardware Feature Limitations - detected ONLY from enabled (isActive) bindings and active groups
        var hasPaddles = false
        var hasRadialMenu = false
        var hasGyro = false
        // The same names apply validation treats as rear buttons.
        let rearNames = ["grip", "rear", "paddle"]

        var activeGroupIDs = Set<String>()
        for preset in model.presets {
            for binding in preset.bindings where binding.isActive {
                activeGroupIDs.insert(binding.groupID)
                let src = binding.source.lowercased()
                if src.contains("gyro") {
                    hasGyro = true
                }
                if rearNames.contains(where: { src.contains($0) }) {
                    hasPaddles = true
                }
            }
        }

        for group in model.groupDefinitions where activeGroupIDs.contains(group.id) {
            let mode = group.mode.lowercased()
            if mode.contains("radial") || mode.contains("touch_menu") {
                hasRadialMenu = true
            }
            for input in group.inputs where input.isBound {
                let iname = input.name.lowercased()
                if rearNames.contains(where: { iname.contains($0) }) {
                    hasPaddles = true
                }
                if iname.contains("gyro") {
                    hasGyro = true
                }
            }
        }

        if hasPaddles {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-paddles",
                category: .unavailableHardware,
                title: "Rear Grip / Paddle Buttons",
                detail: "Layout binds rear paddles which are not present on standard DualSense hardware."
            ))
        }
        if hasGyro {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-gyro",
                category: .unavailableHardware,
                title: "Gyroscope Aiming / Motion",
                detail: "Layout binds gyro motion which is not currently forwarded by the virtual pad transport."
            ))
        }
        if hasRadialMenu {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-radial",
                category: .unavailableHardware,
                title: "Radial / Touch Overlay Menus",
                detail: "Layout binds radial overlay menus which require client overlay rendering."
            ))
        }

        // 6. Uninterpreted / Unknown Content Diagnoses (deterministic IDs)
        for entry in model.unrecognizedEntries {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-unrec-\(entry.id)",
                category: .viewerOrRuntimeLimitation,
                title: "Uninterpreted Content: \(entry.key)",
                detail: "Block or property at '\(entry.path)' is not interpreted by this preview viewer (viewer limitation)."
            ))
        }

        // 7. Build Action Set views resolving specific presets
        for actSet in model.actionSets {
            let preset = model.preset(for: actSet)
            if preset == nil && !model.presets.isEmpty {
                detectedDiagnoses.append(FeatureDiagnosis(
                    id: "diag-unres-set-preset-\(actSet.id)",
                    category: .unresolvedReference,
                    title: "Unresolved Preset for Set '\(actSet.id)'",
                    detail: "Could not resolve a matching preset for action set '\(actSet.title)'."
                ))
            }

            let rootSetConditions = model.conditions + actSet.conditions
            setViews.append(ActionSetView(
                id: actSet.id,
                title: builder.title(set: actSet.id, written: actSet.title),
                isLayer: false,
                isNative: actSet.isNative,
                conditions: rootSetConditions,
                regions: builder.regions(preset: preset, isLayer: false, parentSet: nil, parentPreset: nil,
                                         enclosingConditions: rootSetConditions)
            ))
        }

        // 8. Build Action Layer views resolving layer preset & parent set inheritance
        for actLayer in model.actionLayers {
            let layerPreset = model.preset(for: actLayer)
            let parentSet = model.actionSets.first { $0.id.caseInsensitiveCompare(actLayer.parentSetID) == .orderedSame }
            let parentPreset = parentSet.flatMap { model.preset(for: $0) }

            if layerPreset == nil {
                detectedDiagnoses.append(FeatureDiagnosis(
                    id: "diag-unres-layer-preset-\(actLayer.id)",
                    category: .unresolvedReference,
                    title: "Unresolved Preset for Layer '\(actLayer.id)'",
                    detail: "Could not resolve a matching preset for action layer '\(actLayer.title)'."
                ))
            }
            if parentSet == nil && !actLayer.parentSetID.isEmpty {
                detectedDiagnoses.append(FeatureDiagnosis(
                    id: "diag-unres-layer-parent-\(actLayer.id)",
                    category: .unresolvedReference,
                    title: "Unresolved Parent Set '\(actLayer.parentSetID)'",
                    detail: "Layer '\(actLayer.title)' specifies parent set '\(actLayer.parentSetID)' which is not found."
                ))
            }

            let rootLayerConditions = model.conditions + (parentSet?.conditions ?? []) + actLayer.conditions
            setViews.append(ActionSetView(
                id: actLayer.id,
                title: builder.title(set: actLayer.id, written: actLayer.title),
                isLayer: true,
                parentSetID: actLayer.parentSetID,
                conditions: rootLayerConditions,
                regions: builder.regions(preset: layerPreset, isLayer: true, parentSet: parentSet, parentPreset: parentPreset,
                                         enclosingConditions: rootLayerConditions)
            ))
        }

        self.actionSets = setViews
        self.diagnoses = detectedDiagnoses
    }

    /// Turns the domain model into rows. It resolves names and shows what each
    /// reference points at; it never evaluates a condition and never picks
    /// among several definitions of one id.
    private struct Builder {
        let model: SteamInputLayoutModel
        let names: SteamInputActionNames
        typealias Parsed = SteamInputLayoutModel.ParsedBinding

        /// How one group's rows are marked: where they come from in the set.
        struct Placement {
            var prefix = ""
            var isLayerOverride = false
            var isInherited = false
            var parentSetName: String?
        }

        /// A set or layer title: the game's manifest when it declares the set,
        /// otherwise the layout's own localization, otherwise as written.
        func title(set id: String, written: String) -> String {
            if let manifest = names.manifest, let declared = manifest.set(id) { return manifest.name(of: declared) }
            return model.localized(written) ?? written
        }

        func label(_ binding: Parsed) -> String? {
            guard let label = binding.label, !label.isEmpty else { return nil }
            if label.hasPrefix("#") { return names.manifest?.localized(label) ?? model.localized(label) ?? label }
            return label
        }

        /// Text, and whether the name or target could not be resolved.
        func describe(gameAction setID: String, _ actionID: String) -> (text: String, unresolved: Bool) {
            if let manifest = names.manifest {
                if let action = manifest.action(actionID, in: setID) { return (manifest.name(of: action), false) }
                return ("\(setID) › \(actionID) (not in the game's action manifest)", true)
            }
            return ("\(setID) › \(actionID)", true)
        }

        func describe(preset number: Int, what: String) -> (text: String, unresolved: Bool) {
            let found = model.presets(numbered: number)
            guard found.count == 1 else {
                return ("\(what) → preset \(number) (\(found.isEmpty ? "not defined" : "defined more than once"))", true)
            }
            guard let written = model.title(of: found[0]) else { return ("\(what) → preset \(number)", false) }
            let name = found[0].name.isEmpty ? found[0].id : found[0].name
            return ("\(what) → \(title(set: name, written: written))", false)
        }

        func binding(_ parsed: Parsed, id: String, conditions: [SourceCondition], path: [String]) -> BindingView {
            var text: String
            var unresolved = false
            var shift: ModeShiftView?
            switch parsed.verb {
            case .gameAction(let setID, let actionID):
                (text, unresolved) = describe(gameAction: setID, actionID)
            case .modeShift(let source, let groupID):
                let sourceName = Parsed.formatSource(source)
                switch model.lookup(group: groupID) {
                case .defined(let group):
                    text = "Mode shift: \(sourceName) → \(group.humanMode)"
                    // A group already being shown on this path is named, not expanded again.
                    if !path.contains(groupID) {
                        shift = ModeShiftView(source: sourceName, groupID: groupID, groupTitle: group.humanMode,
                                              inputs: rows(for: group, source: source, conditions: conditions,
                                                           placement: Placement(prefix: "\(id)-shift-"), path: path + [groupID]))
                    }
                case .missing:
                    text = "Mode shift: \(sourceName) → group \(groupID) (not defined)"
                    unresolved = true
                case .ambiguous:
                    text = "Mode shift: \(sourceName) → group \(groupID) (defined more than once)"
                    unresolved = true
                }
            case .actionSetChange(let number):
                (text, unresolved) = describe(preset: number, what: "Change action set")
            case .layerChange(let operation, let number):
                (text, unresolved) = describe(preset: number, what: Parsed.formatLayerOperation(operation))
            case .xinputButton, .keyPress, .mouseButton, .mouseWheel, .steamAction:
                text = parsed.baseText
            case .unverified:
                return BindingView(id: id, displayText: parsed.displayText, rawBinding: parsed.rawString,
                                   category: parsed.outputCategory, isUnresolved: true, conditions: conditions)
            }
            if let label = label(parsed), label.caseInsensitiveCompare(text) != .orderedSame { text += " (\(label))" }
            return BindingView(id: id, displayText: text, rawBinding: parsed.rawString, category: parsed.outputCategory,
                               isUnresolved: unresolved, conditions: conditions, modeShift: shift)
        }

        /// Every row one group contributes for one source: its bound inputs,
        /// the analog game action it drives, or its mode when it binds nothing.
        /// `conditions` is the chain down to and including the source binding.
        func rows(for group: SteamInputLayoutModel.Group, source: String, conditions: [SourceCondition],
                  placement: Placement, path: [String]) -> [InputMappingView] {
            let groupConditions = conditions + group.conditions
            let base = "\(placement.prefix)\(source)-g\(group.id)"
            var rows: [InputMappingView] = []

            for input in group.inputs {
                let inputConditions = groupConditions + input.conditions
                var activatorViews: [ActivatorView] = []
                for (isDisabled, activators) in [(false, input.activators), (true, input.disabledActivators)] {
                    for (index, activator) in activators.enumerated() where !activator.bindings.isEmpty {
                        let activatorConditions = inputConditions + activator.conditions
                        let activatorID = "\(base)-\(input.name)-\(isDisabled ? "disabled-" : "")\(activator.kind)-\(index)"
                        activatorViews.append(ActivatorView(
                            id: activatorID,
                            kind: activator.humanKind,
                            bindings: activator.bindings.enumerated().map { offset, parsed in
                                binding(parsed, id: "\(activatorID)-\(offset)", conditions: activatorConditions + parsed.conditions, path: path)
                            },
                            toggle: activator.toggle,
                            turbo: activator.turbo,
                            isDisabled: isDisabled,
                            conditions: activatorConditions
                        ))
                    }
                }
                guard !activatorViews.isEmpty else { continue }
                rows.append(InputMappingView(
                    id: "\(base)-\(input.name)",
                    inputName: input.humanName,
                    sourceName: Parsed.formatSource(source),
                    activators: activatorViews,
                    settings: group.settings.isEmpty ? nil : group.settings,
                    conditions: inputConditions,
                    isLayerOverride: placement.isLayerOverride,
                    isInherited: placement.isInherited,
                    parentSetName: placement.parentSetName
                ))
            }

            // The analog game action the whole group feeds, such as a stick bound to "Move".
            if !group.gameActions.isEmpty {
                let bindings = group.gameActions.enumerated().map { index, reference -> BindingView in
                    let described = describe(gameAction: reference.setID, reference.actionID)
                    return BindingView(id: "\(base)-gameaction-\(index)", displayText: described.text,
                                       rawBinding: "\(reference.setID) \(reference.actionID)", category: .action,
                                       isUnresolved: described.unresolved, conditions: groupConditions + reference.conditions)
                }
                rows.append(InputMappingView(
                    id: "\(base)-gameactions",
                    inputName: "\(group.humanMode) (Analog)",
                    sourceName: Parsed.formatSource(source),
                    activators: [ActivatorView(id: "\(base)-gameactions-analog", kind: "Analog", bindings: bindings, conditions: groupConditions)],
                    settings: group.settings.isEmpty ? nil : group.settings,
                    conditions: groupConditions,
                    isLayerOverride: placement.isLayerOverride,
                    isInherited: placement.isInherited,
                    parentSetName: placement.parentSetName
                ))
            }

            // A group that binds no input and names no action: its mode is what it does.
            if rows.isEmpty {
                var settings = group.settings
                if settings["mode"] == nil && !group.mode.isEmpty {
                    settings["mode"] = group.mode
                }
                rows.append(InputMappingView(
                    id: "\(base)-analog",
                    inputName: "\(group.humanMode) (Analog)",
                    sourceName: Parsed.formatSource(source),
                    activators: [],
                    settings: settings.isEmpty ? nil : settings,
                    conditions: groupConditions,
                    isLayerOverride: placement.isLayerOverride,
                    isInherited: placement.isInherited,
                    parentSetName: placement.parentSetName
                ))
            }
            return rows
        }

        static func categorize(_ source: String) -> (key: String, title: String) {
            let s = source.lowercased()
            if s.contains("diamond") { return ("diamond", "Face Buttons") }
            if s.contains("dpad") { return ("dpad", "D-Pad") }
            if s.contains("trigger") || s.contains("bumper") || s.contains("shoulder") { return ("triggers", "Bumpers & Triggers") }
            if s.contains("joystick") || s.contains("stick") { return ("sticks", "Analog Sticks") }
            if s.contains("trackpad") || s.contains("touchpad") { return ("touchpads", "Touchpads") }
            if s.contains("gyro") { return ("gyro", "Gyroscope & Motion") }
            if s.contains("switch") || s.contains("system") { return ("system", "System & Menu Buttons") }
            return (s, "Source: " + s.replacingOccurrences(of: "_", with: " ").capitalized)
        }

        /// Group ids a mode-shift binding in `rows` expands, at any depth.
        static func shiftedGroups(in rows: [InputMappingView]) -> Set<String> {
            var found = Set<String>()
            for shift in rows.flatMap({ $0.activators.flatMap(\.bindings) }).compactMap(\.modeShift) {
                found.insert(shift.groupID)
                found.formUnion(shiftedGroups(in: shift.inputs))
            }
            return found
        }

        func regions(preset: SteamInputLayoutModel.Preset?, isLayer: Bool,
                     parentSet: SteamInputLayoutModel.ActionSet?, parentPreset: SteamInputLayoutModel.Preset?,
                     enclosingConditions: [SourceCondition]) -> [ControllerRegionView] {
            var buckets: [String: (title: String, inputs: [InputMappingView])] = [:]
            var order: [String] = []
            func add(_ inputs: [InputMappingView], to key: String, title: String) {
                if buckets[key] == nil {
                    buckets[key] = (title: title, inputs: [])
                    order.append(key)
                }
                buckets[key]?.inputs += inputs
            }

            /// The rows of one preset's source bindings. A binding marked
            /// `modeshift` is not a base mapping: it is shown where a mode-shift
            /// binding switches to it, and listed on its own only when none does.
            var expanded = Set<String>()
            var deferred: [() -> Void] = []
            func place(_ entries: [SteamInputLayoutModel.SourceBinding], conditions: [SourceCondition],
                       placement: Placement, suffix: String, skipping: Set<String>) -> Set<String> {
                var sources = Set<String>()
                for (index, entry) in entries.enumerated() where entry.isActive {
                    let source = entry.source.lowercased()
                    guard !skipping.contains(source) else { continue }
                    let (key, title) = Self.categorize(source)
                    if entry.isModeShift {
                        deferred.append {
                            guard !expanded.contains(entry.groupID) else { return }
                            add(entryRows(entry, index: index, conditions: conditions, placement: placement),
                                to: key + "-modeshift", title: title + " (Mode Shift)" + suffix)
                        }
                        continue
                    }
                    sources.insert(source)
                    let built = entryRows(entry, index: index, conditions: conditions, placement: placement)
                    expanded.formUnion(Self.shiftedGroups(in: built))
                    add(built, to: key, title: title + suffix)
                }
                return sources
            }
            func entryRows(_ entry: SteamInputLayoutModel.SourceBinding, index: Int, conditions: [SourceCondition],
                           placement: Placement) -> [InputMappingView] {
                let source = entry.source.lowercased()
                let chain = conditions + entry.conditions
                let lookup = model.lookup(group: entry.groupID)
                guard case .defined(let group) = lookup else {
                    // A missing or ambiguous group is shown as a placeholder, never resolved by guessing.
                    return [InputMappingView(
                        id: "\(placement.prefix)missing-group-\(entry.groupID)-\(source)-\(index)",
                        inputName: "\(lookup == .missing ? "Missing" : "Ambiguous") Group [\(entry.groupID)] (\(source))",
                        activators: [],
                        settings: ["Source": source, "GroupID": entry.groupID, "Status": lookup == .missing ? "Unresolved Reference" : "Defined More Than Once"],
                        conditions: chain,
                        isLayerOverride: placement.isLayerOverride,
                        isInherited: placement.isInherited,
                        parentSetName: placement.parentSetName,
                        isMissingReference: true
                    )]
                }
                return self.rows(for: group, source: source, conditions: chain, placement: placement, path: [group.id])
            }

            // 1. The set's or layer's own preset
            var overridden = Set<String>()
            if let preset {
                overridden = place(preset.bindings, conditions: enclosingConditions + preset.conditions,
                                   placement: Placement(isLayerOverride: isLayer), suffix: isLayer ? " (Layer Overrides)" : "", skipping: [])
            }

            // 2. For Action Layers: what the parent set still supplies for every source the layer leaves alone
            if isLayer, let parentPreset {
                _ = place(parentPreset.bindings, conditions: enclosingConditions + parentPreset.conditions,
                          placement: Placement(prefix: "inherited-", isInherited: true, parentSetName: parentSet?.title),
                          suffix: " (Inherited)", skipping: overridden)
            }
            // Mode-shift groups no shown binding switches to, after everything that could.
            for list in deferred { list() }

            // 3. Append Uninterpreted Content Region if any exists (with rawContent and deterministic IDs)
            if !model.unrecognizedEntries.isEmpty {
                var unrecInputs: [InputMappingView] = []
                func collectUnrec(_ entry: SteamInputLayoutModel.UnrecognizedEntry) {
                    unrecInputs.append(InputMappingView(
                        id: entry.id,
                        inputName: entry.key,
                        activators: [],
                        settings: ["Path": entry.path],
                        conditions: [],
                        isLayerOverride: false,
                        isInherited: false,
                        rawContent: entry.rawContent
                    ))
                    for child in entry.children {
                        collectUnrec(child)
                    }
                }
                for entry in model.unrecognizedEntries {
                    collectUnrec(entry)
                }
                buckets["uninterpreted"] = (title: "Uninterpreted Content (Viewer Limitations)", inputs: unrecInputs)
                order.append("uninterpreted")
            }

            return order.compactMap { key in
                guard let bucket = buckets[key] else { return nil }
                return ControllerRegionView(id: key, title: bucket.title, inputs: bucket.inputs)
            }
        }
    }
}

/// Preview state for one community listing: the request in flight, its result
/// or error, and the sheet. The view reads and drives this model only and keeps
/// no preview state of its own, so the host checks exercise the shipped logic.
///
/// Exactly one request may publish. Starting another request, cancelling or
/// dismissing changes `generation`, so a fetch that finishes late, with a
/// result or an error, finds a different generation and publishes nothing.
@Observable @MainActor final class SteamInputPreviewPresentationModel {
    private(set) var activeItemID: UInt64?
    private(set) var previewData: SteamInputPreviewData?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init() {}

    /// The sheet is up exactly while a preview is held. SwiftUI writes `false`
    /// when the player dismisses it; writing `true` cannot conjure a preview.
    var isPresented: Bool {
        get { previewData != nil }
        set { if !newValue { dismiss() } }
    }

    /// Supersedes any earlier request. The returned task finishes once this
    /// request has either published or been discarded. `actions` supplies the
    /// game's own action names; it must read only, like the fetch itself.
    @discardableResult
    func requestPreview(appID: UInt32, item: SteamWorkshopItem, sources: SteamInputCommunitySources,
                        actions: @escaping @MainActor (UInt32) async -> SteamInputActionNames) -> Task<Void, Never> {
        invalidate()
        let request = generation
        activeItemID = item.id
        previewData = nil
        errorMessage = nil
        isLoading = true
        let task = Task { @MainActor [weak self] in
            let outcome: Result<SteamInputPreviewData, any Error>
            // The game's action names are read first; a superseded request's
            // names are discarded with the rest of its result.
            let names = await actions(appID)
            do { outcome = .success(try await sources.preview(appID: appID, item: item, actions: names)) }
            catch { outcome = .failure(error) }
            guard let self, self.generation == request else { return }
            self.task = nil
            self.isLoading = false
            switch outcome {
            case .success(let data):
                self.previewData = data
            case .failure(let error):
                self.activeItemID = nil
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
        self.task = task
        return task
    }

    /// Stops the request in flight, as when its view goes away or the player
    /// cancels. A preview already on screen and a reported error are kept.
    func cancel() {
        guard isLoading else { return }
        invalidate()
        activeItemID = nil
    }

    /// Closes the sheet and stops any request, so nothing can reopen it.
    func dismiss() {
        invalidate()
        activeItemID = nil
        previewData = nil
        errorMessage = nil
    }

    func clearError() { errorMessage = nil }

    private func invalidate() {
        task?.cancel()
        task = nil
        generation &+= 1
        isLoading = false
    }
}
