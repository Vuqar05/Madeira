// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

/// A layout change waiting for the player's confirmation (milestone 5 item 2):
/// the layout was made for another controller or uses features the player's
/// controller cannot supply. `retry` repeats the request once confirmed.
struct SteamInputPendingConfirmation: Identifiable {
    let id = UUID()
    let needed: SteamInputConfirmationNeeded
    let retry: @MainActor () -> Void
}

extension View {
    /// Lists the missing features and applies only after "Apply anyway",
    /// which records the confirmation for this revision and controller.
    func steamInputConfirmation(_ pending: Binding<SteamInputPendingConfirmation?>) -> some View {
        alert("Made for another controller",
              isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
              presenting: pending.wrappedValue) { value in
            Button("Apply anyway") {
                pending.wrappedValue = nil
                do { try SteamInputConsent.confirm(hash: value.needed.hash, controller: value.needed.controller) } catch { return }
                value.retry()
            }.accessibilityIdentifier("confirmation.apply")
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }.accessibilityIdentifier("confirmation.cancel")
        } message: { value in
            Text((value.needed.errorDescription ?? "") + " You are asked once for each version of a layout.")
        }
    }
}
