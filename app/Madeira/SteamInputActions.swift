// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// The names a native Steam Input game gives its action sets and actions, read
/// from its action manifest. Valve documents the format: a root "Action
/// Manifest" block (or the older "In Game Actions") holding `actions`,
/// optional `action_layers` and `localization`. This reads names only; it
/// never selects a configuration and never changes a layout.
struct SteamInputActionManifest: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case analog = "stickpadgyro", trigger = "analogtrigger", button = "button"
    }
    struct Action: Equatable, Sendable {
        let id: String
        let kind: Kind
        /// As written: a `#Token` for the localization block, or literal text.
        let title: String
    }
    struct ActionSet: Equatable, Sendable {
        let id: String
        let title: String
        let isLayer: Bool
        let actions: [Action]
    }
    /// Action sets, then layers, in file order.
    let sets: [ActionSet]
    /// Language → token without its "#", lowercased → text.
    let localization: [String: [String: String]]

    enum Failure: Error { case notAManifest }

    init(_ data: Data) throws {
        let document = try VDFDocument.parse(data)
        func text(_ token: VDFToken) -> String { document.stringValue(for: token) }
        func blocks(_ nodes: [VDFNode], named name: String) -> [[VDFNode]] {
            nodes.compactMap { node in
                guard case .block(let key, _, let children, _, _) = node,
                      text(key).caseInsensitiveCompare(name) == .orderedSame else { return nil }
                return children
            }
        }
        guard let root = blocks(document.rootNodes, named: "Action Manifest").first
                ?? blocks(document.rootNodes, named: "In Game Actions").first else { throw Failure.notAManifest }

        func actionSets(_ container: [VDFNode], isLayer: Bool) -> [ActionSet] {
            container.compactMap { node in
                guard case .block(let setKey, _, let children, _, _) = node else { return nil }
                var title = ""
                var actions: [Action] = []
                for child in children {
                    switch child {
                    case .leaf(let key, let value, _):
                        if text(key).caseInsensitiveCompare("title") == .orderedSame { title = text(value) }
                    case .block(let key, _, let entries, _, _):
                        guard let kind = Kind(rawValue: text(key).lowercased()) else { continue }
                        for entry in entries {
                            switch entry {
                            case .leaf(let name, let value, _):
                                // "#Title" or "#Title, mouse_button LEFT": the title ends at the first comma.
                                let written = text(value)
                                let title = written.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? written
                                actions.append(Action(id: text(name), kind: kind, title: title.trimmingCharacters(in: .whitespaces)))
                            case .block(let name, _, let properties, _, _):
                                var title = ""
                                for case .leaf(let key, let value, _) in properties
                                where text(key).caseInsensitiveCompare("title") == .orderedSame { title = text(value) }
                                actions.append(Action(id: text(name), kind: kind, title: title))
                            case .standaloneComment, .directive:
                                break
                            }
                        }
                    case .standaloneComment, .directive:
                        break
                    }
                }
                return ActionSet(id: text(setKey), title: title, isLayer: isLayer, actions: actions)
            }
        }
        sets = blocks(root, named: "actions").flatMap { actionSets($0, isLayer: false) }
            + blocks(root, named: "action_layers").flatMap { actionSets($0, isLayer: true) }

        var languages: [String: [String: String]] = [:]
        for block in blocks(root, named: "localization") {
            for case .block(let language, _, let entries, _, _) in block {
                var table = languages[text(language).lowercased()] ?? [:]
                for case .leaf(let token, let value, _) in entries where table[text(token).lowercased()] == nil {
                    table[text(token).lowercased()] = text(value)
                }
                languages[text(language).lowercased()] = table
            }
        }
        localization = languages
    }

    func set(_ id: String) -> ActionSet? {
        sets.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
    /// The action as the manifest declares it in that set or layer, or nil.
    func action(_ id: String, in setID: String) -> Action? {
        set(setID)?.actions.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
    /// Literal text as written; a `#Token` through the English block, then the
    /// first other language (by name) that has it. Nil when nothing names it.
    func localized(_ title: String) -> String? {
        guard title.hasPrefix("#") else { return title.isEmpty ? nil : title }
        let token = String(title.dropFirst()).lowercased()
        if let text = localization["english"]?[token], !text.isEmpty { return text }
        for language in localization.keys.sorted() {
            if let text = localization[language]?[token], !text.isEmpty { return text }
        }
        return nil
    }
    func name(of action: Action) -> String { localized(action.title) ?? action.id }
    func name(of set: ActionSet) -> String { localized(set.title) ?? set.id }
}

/// Where a game's action names come from, or why they are not available.
/// Only `.manifest` resolves a name; every other case leaves references
/// unresolved and says why.
enum SteamInputActionNames: Equatable, Sendable {
    case manifest(SteamInputActionManifest)
    /// The game is not installed, so its files cannot be read.
    case notInstalled
    /// Steam's data for the game names no bundled action manifest.
    case notBundled
    /// Steam's data for the game is not cached on this device.
    case dataUnavailable
    /// A manifest is named but could not be read or is not a manifest.
    case unreadable

    var manifest: SteamInputActionManifest? {
        if case .manifest(let value) = self { return value }
        return nil
    }
    /// Why names are unresolved; nil when a manifest was read.
    var explanation: String? {
        switch self {
        case .manifest: return nil
        case .notInstalled: return "The game is not installed, so its action manifest cannot be read."
        case .notBundled: return "Steam's data for this game does not name a bundled action manifest."
        case .dataUnavailable: return "Steam's data for this game is not cached on this device."
        case .unreadable: return "The game's action manifest could not be read."
        }
    }

    /// Reads the manifest the same way the game default does: a path the
    /// running game registered outranks the app-data hint, and every read stays
    /// beneath the installed game directory. Nothing is written or fetched.
    /// `hintKnown` is false when the game's app data was never read.
    static func load(hintKnown: Bool, manifestPath: String?, runtimePath: String? = nil,
                     gameDirectory: URL?, windowsDirectory: String? = nil) -> Self {
        var path = manifestPath
        if let runtimePath {
            guard let confined = DockSteamInputDefault.relativeManifestPath(runtimePath, windowsDirectory: windowsDirectory) else {
                return .unreadable
            }
            path = confined
        }
        guard let path else { return hintKnown ? .notBundled : .dataUnavailable }
        guard let gameDirectory else { return .notInstalled }
        guard let bytes = try? DockSteamInputBundledManifest.manifest(gameDirectory: gameDirectory, manifestPath: path),
              let manifest = try? SteamInputActionManifest(bytes) else { return .unreadable }
        return .manifest(manifest)
    }
}
