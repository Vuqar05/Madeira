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

    public struct BindingView: Equatable, Identifiable, Sendable {
        public let id: String
        public let displayText: String
        public let rawBinding: String
        public let category: SteamInputLayoutModel.OutputCategory
        public let isUnresolved: Bool
        public let conditions: [SourceCondition]

        public init(
            id: String,
            displayText: String,
            rawBinding: String,
            category: SteamInputLayoutModel.OutputCategory,
            isUnresolved: Bool = false,
            conditions: [SourceCondition] = []
        ) {
            self.id = id
            self.displayText = displayText
            self.rawBinding = rawBinding
            self.category = category
            self.isUnresolved = isUnresolved
            self.conditions = conditions
        }
    }

    public struct ActivatorView: Equatable, Identifiable, Sendable {
        public let id: String
        public let kind: String
        public let bindings: [BindingView]
        public let toggle: Bool
        public let turbo: Bool
        public let conditions: [SourceCondition]

        public init(
            id: String,
            kind: String,
            bindings: [BindingView],
            toggle: Bool = false,
            turbo: Bool = false,
            conditions: [SourceCondition] = []
        ) {
            self.id = id
            self.kind = kind
            self.bindings = bindings
            self.toggle = toggle
            self.turbo = turbo
            self.conditions = conditions
        }
    }

    public struct InputMappingView: Equatable, Identifiable, Sendable {
        public let id: String
        public let inputName: String
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

    public let title: String
    public let description: String
    public let controllerType: String
    public let actionSets: [ActionSetView]
    public let diagnoses: [FeatureDiagnosis]
    public let uninterpretedEntries: [SteamInputLayoutModel.UnrecognizedEntry]
    /// Every condition in the layout. None is evaluated, so whether the node it
    /// is written on applies is unresolved.
    public let unevaluatedConditions: [SteamInputLayoutModel.ConditionSite]

    public static let conditionWarning = "Condition not evaluated by this preview; current apply validation rejects conditional layouts."

    /// A layout is fully compatible ONLY when it has no hardware gaps, no platform conditions, no unresolved references, and no viewer limitations.
    public var isFullyCompatible: Bool {
        diagnoses.isEmpty && unevaluatedConditions.isEmpty
    }

    public init(model: SteamInputLayoutModel) {
        self.title = model.title.isEmpty ? "Untitled Layout" : model.title
        self.description = model.description
        self.controllerType = model.controllerType.isEmpty ? "Generic Pad" : model.controllerType
        self.uninterpretedEntries = model.unrecognizedEntries
        self.unevaluatedConditions = model.conditionSites

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

        // References to groups, action sets and layers: the same check that
        // refuses a layout before it is applied, so the two cannot disagree.
        for problem in SteamInputReferences.problems(in: model) {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-\(problem.id)",
                category: .unresolvedReference,
                title: problem.title,
                detail: problem.reason
            ))
        }

        // Binding semantics, in source order
        for group in model.groupDefinitions {
            let gid = group.id
            for input in group.inputs {
                for act in input.activators {
                    for b in act.bindings {
                        if case .gameAction(let sid, let aid) = b.verb {
                            detectedDiagnoses.append(FeatureDiagnosis(
                                id: "diag-unresolved-action-\(sid)-\(aid)",
                                category: .unresolvedReference,
                                title: "Action Manifest Reference: [\(sid):\(aid)]",
                                detail: "Shown as the layout writes it; this preview does not look up the game's name for the action."
                            ))
                        }
                        if case .unverified(let verb, _) = b.verb {
                            detectedDiagnoses.append(FeatureDiagnosis(
                                id: "diag-unverified-verb-\(verb)-\(gid)-\(input.name)",
                                category: .viewerOrRuntimeLimitation,
                                title: "Unverified Binding Grammar: \(verb)",
                                detail: "Binding '\(b.rawString)' has unrecognized grammar or unsupported arguments."
                            ))
                        }
                    }
                }
            }
        }

        // 3. Hardware Feature Limitations - detected ONLY from enabled (isActive) bindings and active groups
        var hasPaddles = false
        var hasRadialMenu = false
        var hasGyro = false

        var activeGroupIDs = Set<String>()
        for preset in model.presets {
            for binding in preset.bindings where binding.isActive {
                activeGroupIDs.insert(binding.groupID)
                let src = binding.source.lowercased()
                if src.contains("gyro") {
                    hasGyro = true
                }
                if ["grip", "rear", "paddle"].contains(where: { src.contains($0) }) {
                    hasPaddles = true
                }
            }
        }

        for group in model.groupDefinitions where activeGroupIDs.contains(group.id) {
            let mode = group.mode.lowercased()
            if mode.contains("radial") || mode.contains("touch_menu") {
                hasRadialMenu = true
            }
            for input in group.inputs {
                let iname = input.name.lowercased()
                if ["grip", "rear", "paddle"].contains(where: { iname.contains($0) }) {
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

        // 4. Uninterpreted / Unknown Content Diagnoses (deterministic IDs)
        for entry in model.unrecognizedEntries {
            detectedDiagnoses.append(FeatureDiagnosis(
                id: "diag-unrec-\(entry.id)",
                category: .viewerOrRuntimeLimitation,
                title: "Uninterpreted Content: \(entry.key)",
                detail: "Block or property at '\(entry.path)' is not interpreted by this preview viewer (viewer limitation)."
            ))
        }

        // 5. Build Action Set views resolving specific presets
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

            let regions = Self.buildRegions(
                preset: preset,
                model: model,
                isLayer: false,
                parentSet: nil,
                parentPreset: nil,
                enclosingConditions: rootSetConditions
            )
            setViews.append(ActionSetView(
                id: actSet.id,
                title: actSet.title,
                isLayer: false,
                isNative: actSet.isNative,
                conditions: rootSetConditions,
                regions: regions
            ))
        }

        // 6. Build Action Layer views resolving layer preset & parent set inheritance
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

            let regions = Self.buildRegions(
                preset: layerPreset,
                model: model,
                isLayer: true,
                parentSet: parentSet,
                parentPreset: parentPreset,
                enclosingConditions: rootLayerConditions
            )
            setViews.append(ActionSetView(
                id: actLayer.id,
                title: actLayer.title,
                isLayer: true,
                parentSetID: actLayer.parentSetID,
                conditions: rootLayerConditions,
                regions: regions
            ))
        }

        self.actionSets = setViews
        self.diagnoses = detectedDiagnoses
    }

    private static func buildRegions(
        preset: SteamInputLayoutModel.Preset?,
        model: SteamInputLayoutModel,
        isLayer: Bool,
        parentSet: SteamInputLayoutModel.ActionSet?,
        parentPreset: SteamInputLayoutModel.Preset?,
        enclosingConditions: [SourceCondition]
    ) -> [ControllerRegionView] {
        var regionBuckets: [String: (title: String, inputs: [InputMappingView])] = [:]
        var regionOrder: [String] = []

        func addInput(_ input: InputMappingView, to regionKey: String, title: String) {
            if regionBuckets[regionKey] == nil {
                regionBuckets[regionKey] = (title: title, inputs: [])
                regionOrder.append(regionKey)
            }
            regionBuckets[regionKey]?.inputs.append(input)
        }

        func categorizeSource(_ src: String) -> (key: String, title: String) {
            let s = src.lowercased()
            if s.contains("diamond") { return ("diamond", "Face Buttons") }
            if s.contains("dpad") { return ("dpad", "D-Pad") }
            if s.contains("trigger") || s.contains("bumper") || s.contains("shoulder") { return ("triggers", "Bumpers & Triggers") }
            if s.contains("joystick") || s.contains("stick") { return ("sticks", "Analog Sticks") }
            if s.contains("trackpad") || s.contains("touchpad") { return ("touchpads", "Touchpads") }
            if s.contains("gyro") { return ("gyro", "Gyroscope & Motion") }
            if s.contains("switch") || s.contains("system") { return ("system", "System & Menu Buttons") }
            return (s, "Source: " + s.replacingOccurrences(of: "_", with: " ").capitalized)
        }

        // Each level appends what the model carries for it, outermost first.
        let presetConditions = enclosingConditions + (preset?.conditions ?? [])

        // 1. Process Preset Bindings
        var processedSources = Set<String>()
        if let p = preset {
            for binding in p.bindings where binding.isActive {
                let src = binding.source.lowercased()
                processedSources.insert(src)
                let (regKey, regTitle) = categorizeSource(src)

                let srcBindingConditions = presetConditions + binding.conditions

                let lookup = model.lookup(group: binding.groupID)
                guard case .defined(let group) = lookup else {
                    // A missing or ambiguous group is shown as a placeholder, never resolved by guessing.
                    addInput(
                        InputMappingView(
                            id: "missing-group-\(binding.groupID)-\(src)",
                            inputName: "\(lookup == .missing ? "Missing" : "Ambiguous") Group [\(binding.groupID)] (\(src))",
                            activators: [],
                            settings: ["Source": src, "GroupID": binding.groupID, "Status": lookup == .missing ? "Unresolved Reference" : "Defined More Than Once"],
                            conditions: srcBindingConditions,
                            isLayerOverride: isLayer,
                            isInherited: false,
                            isMissingReference: true
                        ),
                        to: regKey,
                        title: isLayer ? "\(regTitle) (Layer Overrides)" : regTitle
                    )
                    continue
                }

                let groupConditions = srcBindingConditions + group.conditions

                var mappedAnyInput = false
                for input in group.inputs where input.isBound {
                    mappedAnyInput = true
                    let inputConditions = groupConditions + input.conditions

                    var actViews: [ActivatorView] = []
                    for act in input.activators where !act.bindings.isEmpty {
                        let actConditions = inputConditions + act.conditions

                        var bviews: [BindingView] = []
                        for b in act.bindings {
                            bviews.append(BindingView(
                                id: "\(src)-\(input.name)-\(act.kind)-\(b.rawString)",
                                displayText: b.displayText,
                                rawBinding: b.rawString,
                                category: b.outputCategory,
                                isUnresolved: b.outputCategory == .action || b.outputCategory == .unverified,
                                conditions: actConditions + b.conditions
                            ))
                        }
                        actViews.append(ActivatorView(
                            id: "\(src)-\(input.name)-\(act.kind)",
                            kind: act.humanKind,
                            bindings: bviews,
                            toggle: act.toggle,
                            turbo: act.turbo,
                            conditions: actConditions
                        ))
                    }

                    addInput(
                        InputMappingView(
                            id: "\(src)-\(input.name)",
                            inputName: input.humanName,
                            activators: actViews,
                            settings: group.settings.isEmpty ? nil : group.settings,
                            conditions: inputConditions,
                            isLayerOverride: isLayer,
                            isInherited: false
                        ),
                        to: regKey,
                        title: isLayer ? "\(regTitle) (Layer Overrides)" : regTitle
                    )
                }

                // If group has mode or settings but no bound button inputs (e.g. analog joystick/trigger):
                if !mappedAnyInput {
                    var settings = group.settings
                    if settings["mode"] == nil && !group.mode.isEmpty {
                        settings["mode"] = group.mode
                    }
                    addInput(
                        InputMappingView(
                            id: "\(src)-analog",
                            inputName: "\(group.humanMode) (Analog)",
                            activators: [],
                            settings: settings.isEmpty ? nil : settings,
                            conditions: groupConditions,
                            isLayerOverride: isLayer,
                            isInherited: false
                        ),
                        to: regKey,
                        title: isLayer ? "\(regTitle) (Layer Overrides)" : regTitle
                    )
                }
            }
        }

        // 2. For Action Layers: Process Inherited Bindings from Parent Set
        if isLayer, let parentPreset = parentPreset {
            let parentPresetConditions = enclosingConditions + parentPreset.conditions

            for binding in parentPreset.bindings where binding.isActive {
                let src = binding.source.lowercased()
                if processedSources.contains(src) {
                    continue // Overridden by layer
                }
                let (regKey, regTitle) = categorizeSource(src)

                let srcBindingConditions = parentPresetConditions + binding.conditions

                let lookup = model.lookup(group: binding.groupID)
                guard case .defined(let group) = lookup else {
                    addInput(
                        InputMappingView(
                            id: "inherited-missing-group-\(binding.groupID)-\(src)",
                            inputName: "\(lookup == .missing ? "Missing" : "Ambiguous") Group [\(binding.groupID)] (\(src))",
                            activators: [],
                            settings: ["Source": src, "GroupID": binding.groupID, "Status": lookup == .missing ? "Unresolved Reference" : "Defined More Than Once"],
                            conditions: srcBindingConditions,
                            isLayerOverride: false,
                            isInherited: true,
                            parentSetName: parentSet?.title,
                            isMissingReference: true
                        ),
                        to: regKey,
                        title: "\(regTitle) (Inherited)"
                    )
                    continue
                }

                let groupConditions = srcBindingConditions + group.conditions

                var mappedAnyInput = false
                for input in group.inputs where input.isBound {
                    mappedAnyInput = true
                    let inputConditions = groupConditions + input.conditions

                    var actViews: [ActivatorView] = []
                    for act in input.activators where !act.bindings.isEmpty {
                        let actConditions = inputConditions + act.conditions

                        var bviews: [BindingView] = []
                        for b in act.bindings {
                            bviews.append(BindingView(
                                id: "inherited-\(src)-\(input.name)-\(act.kind)-\(b.rawString)",
                                displayText: b.displayText,
                                rawBinding: b.rawString,
                                category: b.outputCategory,
                                isUnresolved: b.outputCategory == .action || b.outputCategory == .unverified,
                                conditions: actConditions + b.conditions
                            ))
                        }
                        actViews.append(ActivatorView(
                            id: "inherited-\(src)-\(input.name)-\(act.kind)",
                            kind: act.humanKind,
                            bindings: bviews,
                            toggle: act.toggle,
                            turbo: act.turbo,
                            conditions: actConditions
                        ))
                    }

                    addInput(
                        InputMappingView(
                            id: "inherited-\(src)-\(input.name)",
                            inputName: input.humanName,
                            activators: actViews,
                            settings: group.settings.isEmpty ? nil : group.settings,
                            conditions: inputConditions,
                            isLayerOverride: false,
                            isInherited: true,
                            parentSetName: parentSet?.title
                        ),
                        to: regKey,
                        title: "\(regTitle) (Inherited)"
                    )
                }

                if !mappedAnyInput {
                    var settings = group.settings
                    if settings["mode"] == nil && !group.mode.isEmpty {
                        settings["mode"] = group.mode
                    }
                    addInput(
                        InputMappingView(
                            id: "inherited-\(src)-analog",
                            inputName: "\(group.humanMode) (Analog)",
                            activators: [],
                            settings: settings.isEmpty ? nil : settings,
                            conditions: groupConditions,
                            isLayerOverride: false,
                            isInherited: true,
                            parentSetName: parentSet?.title
                        ),
                        to: regKey,
                        title: "\(regTitle) (Inherited)"
                    )
                }
            }
        }

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
            regionBuckets["uninterpreted"] = (title: "Uninterpreted Content (Viewer Limitations)", inputs: unrecInputs)
            regionOrder.append("uninterpreted")
        }

        return regionOrder.compactMap { key in
            guard let bucket = regionBuckets[key] else { return nil }
            return ControllerRegionView(id: key, title: bucket.title, inputs: bucket.inputs)
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
    /// request has either published or been discarded.
    @discardableResult
    func requestPreview(appID: UInt32, item: SteamWorkshopItem, sources: SteamInputCommunitySources) -> Task<Void, Never> {
        invalidate()
        let request = generation
        activeItemID = item.id
        previewData = nil
        errorMessage = nil
        isLoading = true
        let task = Task { @MainActor [weak self] in
            let outcome: Result<SteamInputPreviewData, any Error>
            do { outcome = .success(try await sources.preview(appID: appID, item: item)) }
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
