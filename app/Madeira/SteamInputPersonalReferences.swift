// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// What the layout service and the saved selection say about personal
/// layouts for one account and game: the only things that can make a layout
/// or a revision unsafe to remove. Built from the persisted selection and the
/// live service (DockSteamInputService.personalReferences); a selection that
/// cannot be read makes `known` false, and then nothing is deleted or pruned.
struct SteamInputPersonalReferences: Equatable, Sendable {
    /// Personal layouts the saved selection names, with the content hashes it
    /// names for each: the requested choice and the last confirmed one.
    var selected: [UUID: Set<String>] = [:]
    /// The revision Steam Input last confirmed for each personal layout.
    var confirmed: [UUID: String] = [:]
    /// Personal layouts with a layout change in flight in the running session.
    var inFlight: Set<UUID> = []
    var known = true

    static let unknown = Self(known: false)

    /// Why `id` cannot be deleted now, or nil when it can.
    func blocksDeletion(_ id: UUID) -> String? {
        guard known else {
            return "Madeira could not read this game's saved layout choice, so it cannot confirm the layout is unused. Nothing was deleted."
        }
        if inFlight.contains(id) {
            return "Steam Input is still switching to this layout. Wait until the change finishes, then delete it."
        }
        if selected[id] != nil {
            return "This layout is this game's chosen Steam Input layout. Choose Game default or another layout first, then delete it."
        }
        return nil
    }

    /// Revisions of `id` that must stay on disk whatever the history keeps.
    func retained(_ id: UUID) -> Set<String> {
        (selected[id] ?? []).union(confirmed[id].map { [$0] } ?? [])
    }
}
