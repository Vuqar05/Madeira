// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UniformTypeIdentifiers

/// The personal layouts of one account and game: open, create, import and
/// recover them. Damaged layouts are listed with a way to recover or delete
/// them rather than hiding the rest.
struct SteamInputPersonalLayoutsSection: View {
    let appID: UInt32
    let accountID: UInt32
    /// The game's own default layout and where it came from, resolved on request.
    var gameDefault: () async throws -> (bytes: Data, detail: String) = { throw SteamInputPersonalCopy.ImportFailure.notALayout }
    /// Steam's templates the installed client has.
    var templates: () -> [SteamInputTemplates.Template] = { [] }
    @State private var listings: [SteamInputPersonalCopy.Listing] = []
    @State private var importing = false
    @State private var creating = false
    @State private var importMessage: String?
    @State private var importFailure: String?
    private var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    var body: some View {
        Section {
            ForEach(listings) { listing in
                if let copy = listing.copy, listing.problem == nil {
                    NavigationLink {
                        SteamInputPersonalDetail(appID: appID, copy: copy, onChange: reload)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(copy.title)
                            Text(copy.provenance).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("personal.\(copy.title)")
                } else {
                    NavigationLink {
                        SteamInputPersonalRecoveryView(appID: appID, accountID: accountID, listing: listing, onChange: reload)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(listing.title, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(listing.problem ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("personal.damaged.\(listing.title)")
                }
            }
            // Each presentation hangs on its own row: modifiers on a Section inside a List are not presented.
            Button("New layout…") { creating = true }.disabled(accountID == 0).accessibilityIdentifier("personal.new")
                .sheet(isPresented: $creating, onDismiss: reload) {
                    NavigationStack {
                        SteamInputCreateLayoutView(appID: appID, accountID: accountID, existing: listings.compactMap { $0.problem == nil ? $0.copy : nil },
                                                   gameDefault: gameDefault, templates: templates)
                    }
                }
            Button("Import VDF file…") { importing = true }.disabled(accountID == 0)
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { importLayout($0) }
            if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
            if let importFailure { Text(importFailure).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Personal layouts · local")
        } footer: {
            Text(SteamInputPersonalCopy.storageNote)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        do {
            listings = try SteamInputPersonalCopy.inventory(root: support, accountID: accountID, appID: appID)
        } catch { importFailure = error.localizedDescription }
    }

    /// Keeps the picked file's exact bytes as a personal layout. Nothing is applied.
    @MainActor private func importLayout(_ result: Result<[URL], Error>) {
        importing = false
        importMessage = nil; importFailure = nil
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copy = try SteamInputPersonalCopy.importVDF(SteamInputPersonalCopy.readImport(url), fileName: url.lastPathComponent,
                                                            accountID: accountID, appID: appID, root: support)
            reload()
            importMessage = "Imported “\(copy.title)”. It is kept on this device; open it to apply or export it."
        } catch {
            importFailure = error.localizedDescription
        }
    }
}

/// A new personal layout from the game's default, a Steam template or an
/// existing personal layout. Community copies are made from a community
/// layout's page, and VDF files are imported from the list.
struct SteamInputCreateLayoutView: View {
    let appID: UInt32
    let accountID: UInt32
    let existing: [SteamInputPersonalCopy]
    let gameDefault: () async throws -> (bytes: Data, detail: String)
    let templates: () -> [SteamInputTemplates.Template]
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My layout"
    @State private var available: [SteamInputTemplates.Template] = []
    @State private var working = false
    @State private var failure: String?
    private var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Layout name", text: $name).accessibilityIdentifier("create.name")
            }
            Section {
                Button("Start from the game default") { Task { await fromDefault() } }.disabled(working).accessibilityIdentifier("create.default")
            } footer: {
                Text("The layout this game recommends for this controller, as Steam Input would load it.")
            }
            Section("Start from a Steam template") {
                if available.isEmpty { Text("No Steam templates were found in the installed Steam client.").foregroundStyle(.secondary) }
                ForEach(available) { template in
                    Button(template.title) { create(template.bytes, .init(kind: .template, detail: template.title)) }
                        .disabled(working).accessibilityIdentifier("create.template.\(template.title)")
                }
            }
            if !existing.isEmpty {
                Section("Start from a personal layout") {
                    ForEach(existing) { copy in
                        Button(copy.title) {
                            do { _ = try copy.duplicate(title: name, root: support); dismiss() }
                            catch { failure = error.localizedDescription }
                        }.disabled(working).accessibilityIdentifier("create.copy.\(copy.title)")
                    }
                }
            }
            if working { ProgressView("Checking the game default…") }
            if let failure { Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("create.failure") } }
            Section { Text(SteamInputPersonalCopy.storageNote).font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("New layout")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear { available = templates() }
    }

    private func create(_ bytes: Data, _ creation: SteamInputPersonalCopy.Creation) {
        do {
            _ = try SteamInputPersonalCopy.create(from: bytes, title: name, creation: creation, accountID: accountID, appID: appID, root: support)
            dismiss()
        } catch { failure = error.localizedDescription }
    }

    @MainActor private func fromDefault() async {
        working = true; failure = nil
        defer { working = false }
        do {
            let value = try await gameDefault()
            create(value.bytes, .init(kind: .gameDefault, detail: String(value.detail.prefix(120))))
        } catch { failure = "The game default is not available: " + error.localizedDescription }
    }
}

/// One personal layout: apply it through the same layout service as every
/// other choice, see whether Steam Input confirmed it, and export its VDF.
/// The stored bytes are read and checked again on every apply. It is also
/// where the layout is edited, renamed, duplicated, restored or deleted.
struct SteamInputPersonalDetail: View {
    let appID: UInt32
    @State var copy: SteamInputPersonalCopy
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var compatibility: SteamInputCompatibility?
    @State private var problem: String?
    @State private var failure: String?
    @State private var message: String?
    @State private var exportURL: URL?
    @State private var name = ""
    @State private var confirmingDelete = false
    private var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    var body: some View {
        Form {
            Section {
                Text(copy.title).font(.headline).accessibilityIdentifier("detail.title")
                Text(copy.provenance).font(.caption).foregroundStyle(.secondary)
                if copy.origin != nil {
                    Text("The downloaded community original is separate and is not changed by applying this copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Edit") {
                NavigationLink("Edit layout") {
                    SteamInputLayoutEditorView(appID: appID, copy: copy, root: support) { saved in copy = saved; refresh(); onChange() }
                }.accessibilityIdentifier("detail.edit")
                NavigationLink("Revision history (\(copy.revisions.count))") {
                    SteamInputRevisionHistoryView(copy: $copy, onChange: { refresh(); onChange() })
                }.accessibilityIdentifier("detail.history")
                HStack {
                    TextField("Name", text: $name).accessibilityIdentifier("detail.name")
                    Button("Rename") {
                        do { copy = try copy.renamed(name, root: support); failure = nil; message = "Renamed."; onChange() }
                        catch { failure = error.localizedDescription }
                    }.disabled(name == copy.title).accessibilityIdentifier("detail.rename")
                }
                Button("Duplicate") {
                    do { let twin = try copy.duplicate(root: support); failure = nil; message = "Made “\(twin.title)”, a separate layout."; onChange() }
                    catch { failure = error.localizedDescription }
                }.accessibilityIdentifier("detail.duplicate")
                Button("Delete layout…", role: .destructive) { confirmingDelete = true }.accessibilityIdentifier("detail.delete")
            }
            Section("Storage") {
                Label("Local to this device", systemImage: "internaldrive")
                Text(SteamInputPersonalCopy.storageNote).font(.caption).foregroundStyle(.secondary)
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
                if let exportURL {
                    ShareLink("Export VDF file", item: exportURL)
                    Text("The exported file holds this layout's exact bytes. Import it on another device, or here again, from Personal layouts.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The stored layout cannot be exported.").foregroundStyle(.secondary)
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("detail.failure") } }
            if let message { Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("detail.message") } }
        }
        .navigationTitle("Personal layout")
        .confirmationDialog("Delete “\(copy.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete layout and its history", role: .destructive) { delete() }
        } message: {
            Text("This removes the layout from this device. Export it first to keep a copy.")
        }
        .task { refresh() }
    }

    private func refresh() {
        name = copy.title
        // A copy under the layout's own name, made in the temporary folder for the share sheet.
        exportURL = try? copy.exportFile(root: support,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("SteamInputExport", isDirectory: true))
        compatibility = nil; problem = nil
        do { compatibility = try copy.applyRequest(root: support).compatibility }
        catch SteamInputPersonalCopy.ApplyFailure.incompatible {
            // Unforwarded inputs: say which, as a community layout's page does.
            compatibility = try? SteamInputCompatibility(copy.bytes(root: support), tags: copy.origin?.item.tags ?? [])
        } catch { problem = error.localizedDescription }
    }

    private func delete() {
        do {
            try SteamInputPersonalCopy.delete(copy.id, accountID: copy.accountID, appID: copy.appID,
                                              references: DockSteamInputService.personalReferences(accountID: copy.accountID, appID: copy.appID), root: support)
            onChange()
            dismiss()
        } catch { failure = error.localizedDescription }
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

/// Every saved revision of a layout, newest first; any one can be made current again.
struct SteamInputRevisionHistoryView: View {
    @Binding var copy: SteamInputPersonalCopy
    var onChange: () -> Void = {}
    @State private var failure: String?
    private var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    var body: some View {
        List {
            Section {
                ForEach(Array(copy.revisions.enumerated().reversed()), id: \.element.id) { index, entry in
                    let readable = (try? copy.bytes(of: entry.hash, root: support)) != nil
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.note)
                            Text("\(entry.saved.formatted(date: .abbreviated, time: .shortened)) · \(entry.hash.prefix(8))")
                                .font(.caption).foregroundStyle(.secondary)
                            if !readable { Text("No longer stored on this device").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        if entry.hash == copy.hash && index == copy.revisions.count - 1 {
                            Text("Current").font(.caption).foregroundStyle(.secondary)
                        } else if readable {
                            Button("Restore") { restore(entry) }.buttonStyle(.borderless).accessibilityIdentifier("history.restore.\(index)")
                        }
                    }
                }
            } footer: {
                Text("Restoring makes a revision current again as a new entry; later revisions are kept. The most recent \(SteamInputPersonalCopy.historyLimit) revisions are kept, and the one the game last confirmed is kept until another is confirmed.")
            }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
        }
        .navigationTitle("Revision history")
    }

    private func restore(_ entry: SteamInputPersonalCopy.HistoryEntry) {
        do {
            copy = try copy.restoring(entry, references: DockSteamInputService.personalReferences(accountID: copy.accountID, appID: copy.appID), root: support)
            failure = nil
            onChange()
        } catch { failure = error.localizedDescription }
    }
}

/// A layout that cannot be read: recover its newest readable revision, or delete it.
struct SteamInputPersonalRecoveryView: View {
    let appID: UInt32
    let accountID: UInt32
    let listing: SteamInputPersonalCopy.Listing
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var recovered: SteamInputPersonalCopy?
    private var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    var body: some View {
        Form {
            Section {
                Text(listing.title).font(.headline)
                Text(listing.problem ?? "").foregroundStyle(.orange)
                Text("Recovery keeps this layout's identity and makes its newest readable revision current. Nothing is applied.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Recover layout") {
                    do {
                        recovered = try SteamInputPersonalCopy.recover(listing.id, accountID: accountID, appID: appID, root: support)
                        failure = nil
                        onChange()
                    } catch { failure = error.localizedDescription }
                }.accessibilityIdentifier("recovery.recover")
                Button("Delete layout", role: .destructive) {
                    do {
                        try SteamInputPersonalCopy.delete(listing.id, accountID: accountID, appID: appID,
                                                          references: DockSteamInputService.personalReferences(accountID: accountID, appID: appID), root: support)
                        onChange()
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }.accessibilityIdentifier("recovery.delete")
            }
            if let recovered {
                Section { Text("Recovered “\(recovered.title)” with \(recovered.revisions.count) revision(s). Open it from Personal layouts.").accessibilityIdentifier("recovery.done") }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("recovery.failure") } }
        }
        .navigationTitle("Recover layout")
    }
}
