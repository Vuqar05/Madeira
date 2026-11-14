// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Applying an edited personal layout while the game runs.
///
/// The edited bytes are stored as a pending revision; the working revision
/// stays current. The pending revision then goes through the same checks as
/// any personal layout (conditional layouts rejected, references resolved,
/// the native reader, forwarded inputs) and, only if it passes, through
/// `DockSteamInputService.requestPersonal`: the common journal, the input
/// quiesce that releases held buttons and keys before the command is written,
/// the hash-bound receipt and Steam Input's own rollback. Only a confirmation
/// of exactly that revision makes it current. A refused check, a rollback, a
/// failed change or an interrupted session leaves the working revision current
/// and active, and the edits stay in the draft.
@MainActor enum SteamInputLiveEdit {
    typealias Request = (SteamInputPersonalCopy.ApplyRequest) throws -> Void

    static let service: Request = { request in
        try DockSteamInputService.requestPersonal(appID: request.appID, accountID: request.accountID,
            source: request.source, id: request.id, detail: request.detail)
    }

    /// Stages `bytes` and asks the layout service to apply them. Returns the
    /// record with the pending revision. On any refusal nothing is sent, the
    /// pending revision is withdrawn and the error says why.
    static func apply(_ bytes: Data, to copy: SteamInputPersonalCopy, root: URL,
                      request: Request = service) throws -> SteamInputPersonalCopy {
        let staged = try copy.staging(bytes, root: root)
        guard let pending = staged.pending else { throw SteamInputPersonalCopy.LifecycleFailure.busy }
        do {
            let checked = try staged.applyRequest(root: root, revision: pending)
            try request(checked)
            return staged
        } catch {
            _ = try? staged.unstaged(root: root)
            throw error
        }
    }

    /// Settles the pending revision from what the service and the saved
    /// selection now report.
    static func settle(_ copy: SteamInputPersonalCopy, root: URL) throws -> (SteamInputPersonalCopy, SteamInputPersonalCopy.LiveOutcome) {
        try copy.reconciled(references: DockSteamInputService.personalReferences(accountID: copy.accountID, appID: copy.appID), root: root)
    }
}
