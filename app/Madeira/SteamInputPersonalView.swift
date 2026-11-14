// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

/// One personal layout: apply it through the same layout service as every
/// other choice, see whether Steam Input confirmed it, and export its VDF.
/// The stored bytes are read and checked again on every apply.
struct SteamInputPersonalDetail: View {
    let appID: UInt32
    let copy: SteamInputPersonalCopy
    @State private var compatibility: SteamInputCompatibility?
    @State private var problem: String?
    @State private var failure: String?
    @State private var message: String?
    private var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    var body: some View {
        Form {
            Section {
                Text(copy.title).font(.headline)
                Text("Copied from " + copy.origin.attribution).font(.caption).foregroundStyle(.secondary)
                Text("The downloaded community original is separate and is not changed by applying this copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Compatibility") {
                if let compatibility {
                    Text(compatibility.description)
                        .foregroundStyle(compatibility.canApply ? Color.secondary : Color.orange)
                } else if let problem {
                    Text(problem).foregroundStyle(.red)
                } else {
                    Text("Checking the stored layout…").foregroundStyle(.secondary)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let current = DockSteamInputService.snapshot?.appID == appID
                let active = current ? DockSteamInputService.activeChoice : nil
                let isActive = active?.source == .personal && active?.identity == copy.id.uuidString && active?.contentHash == copy.hash
                Section {
                    Button(isActive ? "Active personal layout" : "Apply this personal layout") { apply() }
                        .disabled(isActive || compatibility?.canApply != true || !current ||
                            !(DockSteamInputService.canChange || DockSteamInputService.canBootstrap))
                    ForEach(Array(DockSteamInputPresentation.lines(appID: appID, snapshot: DockSteamInputService.snapshot,
                        active: DockSteamInputService.activeChoice, selection: DockSteamInputService.selection).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                    if current, let receipt = DockSteamInputService.receipt {
                        if receipt.phase == .rolledBack { Text("The change failed. Steam Input restored the previous working layout.").foregroundStyle(.orange) }
                        if receipt.phase == .failed { Text("Steam Input could not confirm the change. Your saved layout is retained; relaunch to recover.").foregroundStyle(.red) }
                    }
                    Text("Once confirmed, this layout is applied again each time the game starts. Return to the Steam Input controls to use Game default again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Export") {
                if let url = try? copy.source(root: support) { ShareLink("Export VDF", item: url) }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Personal layout")
        .task {
            do { compatibility = try copy.applyRequest(root: support).compatibility }
            catch SteamInputPersonalCopy.ApplyFailure.incompatible {
                // Unforwarded inputs: say which, as a community layout's page does.
                compatibility = try? SteamInputCompatibility(copy.bytes(root: support), tags: copy.origin.item.tags ?? [])
            } catch { problem = error.localizedDescription }
        }
    }

    private func apply() {
        do {
            let request = try copy.applyRequest(root: support)
            try DockSteamInputService.requestPersonal(appID: request.appID, accountID: request.accountID,
                source: request.source, id: request.id, detail: request.detail)
            failure = nil; message = "Layout change requested. Waiting for Steam Input to confirm it."
        } catch is DockSteamInputJournal.Failure {
            message = nil; failure = "The layout change could not start. Wait for the current layout to settle, then retry."
        } catch {
            message = nil; failure = error.localizedDescription
        }
    }
}
