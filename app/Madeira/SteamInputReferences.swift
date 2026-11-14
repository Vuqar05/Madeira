// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// A reference inside a layout that does not resolve to exactly one definition:
/// a group, a preset (an action set or layer) or an action set named by a
/// binding, a preset or a layer.
struct SteamInputReferenceProblem: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case missingGroup, ambiguousGroup
        case missingPreset, ambiguousPreset
        case missingActionSet, ambiguousActionSet
    }
    let id: String
    let kind: Kind
    /// Short heading for a list of diagnostics.
    let title: String
    /// One sentence a player can read without knowing the file format.
    let reason: String
}

/// Why a layout is refused before it is applied. Valve's engine is never asked
/// to resolve a reference this check could not.
struct SteamInputReferenceError: LocalizedError, Equatable {
    let problems: [SteamInputReferenceProblem]
    var errorDescription: String? {
        guard let first = problems.first else { return "This layout cannot be applied." }
        let more = problems.count - 1
        return "This layout cannot be applied. " + first.reason
            + (more == 0 ? "" : more == 1 ? " It has 1 more broken reference." : " It has \(more) more broken references.")
    }
}

/// Checks every reference a version-3 layout makes to its own groups, action
/// sets and layers. Nothing is evaluated or repaired, and no reference is
/// resolved by position or by taking the first or last of several definitions.
///
/// Duplicate group ids: Steam's own `chord_steamcontroller_gordon.vdf` and
/// `basicui_neptune.vdf` each define one id twice with different bindings, so
/// the client does load such files, but which definition it uses is not
/// established for the pinned client. A reference to that id is therefore
/// ambiguous, and the layout is refused rather than applied on a guess. The
/// download check already refused these layouts; this keeps that and says why.
enum SteamInputReferences {
    static func problems(in model: SteamInputLayoutModel) -> [SteamInputReferenceProblem] {
        var found: [SteamInputReferenceProblem] = []
        var reasons = Set<String>()
        func report(_ kind: SteamInputReferenceProblem.Kind, _ title: String, _ reason: String) {
            guard reasons.insert(reason).inserted else { return }
            found.append(.init(id: "reference-\(found.count)", kind: kind, title: title, reason: reason))
        }

        var definitions: [String: Int] = [:]
        for group in model.groupDefinitions { definitions[group.id, default: 0] += 1 }
        for group in model.groupDefinitions {
            guard let count = definitions[group.id], count > 1 else { continue }
            report(.ambiguousGroup, "Group \(group.id) Defined \(count) Times",
                   "Group \(group.id) is defined \(count) times, so the bindings that use it are ambiguous.")
        }
        // An id defined several times is reported once above, not again per reference.
        func group(_ id: String, _ referrer: String) {
            guard definitions[id] == nil else { return }
            report(.missingGroup, "Missing Group \(id)", "\(referrer) group \(id), which the layout does not define.")
        }

        let sets = model.declaresActionSets ? model.actionSets.map(\.id) : []
        let layers = model.actionLayers.map(\.id)
        func actionSet(_ id: String, among names: [String], _ referrer: String) {
            let count = names.filter { $0.caseInsensitiveCompare(id) == .orderedSame }.count
            if count == 0 {
                report(.missingActionSet, "Missing Action Set '\(id)'", "\(referrer) action set '\(id)', which the layout does not define.")
            } else if count > 1 {
                report(.ambiguousActionSet, "Action Set '\(id)' Defined \(count) Times",
                       "\(referrer) action set '\(id)', which the layout defines \(count) times.")
            }
        }
        func preset(_ number: Int, _ referrer: String, _ what: String) {
            let count = model.presets(numbered: number).count
            if count == 0 {
                report(.missingPreset, "Missing Preset \(number)", "\(referrer) \(what) stored as preset \(number), which the layout does not define.")
            } else if count > 1 {
                report(.ambiguousPreset, "Preset \(number) Defined \(count) Times",
                       "\(referrer) \(what) stored as preset \(number), which the layout defines \(count) times.")
            }
        }

        for entry in model.presets {
            let name = entry.name.isEmpty ? entry.id : entry.name
            for binding in entry.bindings {
                group(binding.groupID, "Preset '\(name)' assigns \(SteamInputLayoutModel.ParsedBinding.formatSource(binding.source).lowercased()) to")
            }
        }
        for layer in model.actionLayers where !layer.parentSetID.isEmpty {
            actionSet(layer.parentSetID, among: sets, "Layer '\(layer.title)' extends")
        }
        for definition in model.groupDefinitions {
            for reference in definition.gameActions {
                actionSet(reference.setID, among: sets + layers,
                          "Group \(definition.id) drives the game action \(reference.setID) › \(reference.actionID) in")
            }
            for input in definition.inputs {
                let place = "\(input.humanName) in group \(definition.id)"
                for binding in input.activators.flatMap(\.bindings) {
                    switch binding.verb {
                    case .modeShift(let source, let target):
                        group(target, "A mode shift on \(place) switches \(SteamInputLayoutModel.ParsedBinding.formatSource(source).lowercased()) to")
                    case .actionSetChange(let number):
                        preset(number, "\(place) changes to", "the action set")
                    case .layerChange(let operation, let number):
                        let verb: String
                        switch operation {
                        case .add: verb = "adds"
                        case .remove: verb = "removes"
                        case .hold: verb = "holds"
                        }
                        preset(number, "\(place) \(verb)", "the layer")
                    case .gameAction(let setID, let actionID):
                        actionSet(setID, among: sets + layers, "\(place) triggers the game action \(setID) › \(actionID) in")
                    case .xinputButton, .keyPress, .mouseButton, .mouseWheel, .steamAction, .unverified:
                        break
                    }
                }
            }
        }
        return found
    }

    /// Throws `SteamInputReferenceError` for a layout with a broken reference,
    /// or the parser's own error for bytes that are not a layout.
    static func check(_ bytes: Data) throws {
        let found = problems(in: try SteamInputLayoutModel(document: VDFDocument.parse(bytes)))
        guard found.isEmpty else { throw SteamInputReferenceError(problems: found) }
    }
}
