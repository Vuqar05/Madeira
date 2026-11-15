// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

struct SteamInputUnavailable: LocalizedError { let errorDescription: String? }

/// Native Steam Input layouts; never imports into ControllerSetup or changes
/// the game's controller mode. Download/inspect and apply are separate actions.
struct SteamInputCommunityView: View {
    let appID: UInt32
    @State private var order = SteamInputCommunitySources.Order.played
    @State private var search = ""
    @State private var compatibleOnly = true
    @State private var items: [SteamWorkshopItem] = []
    @State private var page: UInt32 = 0
    @State private var total = 0
    @State private var loading = false
    @State private var failure: String?
    @State private var request: UUID?
    @State private var fetched: Date?
    @State private var downloaded: [SteamInputCommunitySources.Revision] = []
    /// The controller whose layouts this page offers: the running session's,
    /// else the one a launch would present now.
    @State private var controller = SteamInputController.current
    private var accountID: UInt32 {
        SteamOwnedLibrary.shared.personalLayoutAccountID
    }
    private var queryKey: String { "\(order.rawValue):\(SteamInputCommunitySources.search(search))" }
    private var visible: [SteamWorkshopItem] {
        compatibleOnly ? items.filter { ($0.tags ?? []).contains { controller.accepts(type: $0) } } : items
    }
    var body: some View {
        List {
            Section {
                Picker("Sort", selection: $order) {
                    ForEach(SteamInputCommunitySources.Order.allCases) { Text($0.label).tag($0) }
                }
                Toggle(controller == .dualSense ? "DualSense / DualShock layouts only" : "Xbox controller layouts only",
                       isOn: $compatibleOnly).accessibilityIdentifier("community.compatibleOnly")
                Text("Steam sees your controller as \(controller == .dualSense ? "a DualSense" : "an Xbox controller"). "
                     + "Layouts made for it work fully; others need confirmation before they apply.")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("community.controller")
                Text("Valve's Steam Input engine runs these layouts. Compatibility is checked against the downloaded bindings before applying.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !downloaded.isEmpty {
                Section("Downloaded layouts · available offline") {
                    ForEach(downloaded) { revision in
                        NavigationLink(revision.item.title) { SteamInputCommunityDetail(appID: appID, item: revision.item) }
                    }
                }
            }
            SteamInputPersonalLayoutsSection(appID: appID, accountID: accountID, gameDefault: { try await gameDefault() },
                                             templates: { SteamInputTemplates.available(clientRoot: MadeiraDock.clientRoot,
                                                                                        controller: controller) })
            Section("Community layouts") {
                ForEach(visible) { item in
                    NavigationLink {
                        SteamInputCommunityDetail(appID: appID, item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                            if !item.summary.isEmpty { Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Text((item.tags ?? []).filter { $0.hasPrefix("controller_") || $0.hasPrefix("feature_") }
                                .joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                if loading { ProgressView("Loading layouts…") }
                else if visible.isEmpty { Text("No layouts match these filters. Try another search or show all controller types.").foregroundStyle(.secondary) }
                if page > 0, page < 100, Int(page) * 30 < total {
                    Button("Load more") { Task { await load(reset: false) } }.disabled(loading)
                }
            }
            Section {
                Button("Refresh community layouts") { Task { await load(reset: true, refresh: true) } }.disabled(loading)
                if let fetched { Text("Cached listing from \(fetched.formatted(date: .abbreviated, time: .shortened)). Refresh to check for changes.").font(.caption).foregroundStyle(.secondary) }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Community layouts")
        .searchable(text: $search, prompt: "Search Steam layouts")
        .task(id: queryKey) { await load(reset: true) }
        .refreshable { await load(reset: true, refresh: true) }
        .onAppear {
            do {
                downloaded = try SteamInputCommunitySources.shared.downloaded(appID: appID)
            } catch { failure = error.localizedDescription }
        }
    }
    /// The game's own default layout, resolved as the Steam Input controls resolve it.
    @MainActor private func gameDefault() async throws -> (bytes: Data, detail: String) {
        let id = Int(appID)
        let game = await Task.detached { MadeiraDock.games(drive: MadeiraDock.drive).first { $0.id == id } }.value
        guard let game else { throw SteamInputUnavailable(errorDescription: "The game is not installed.") }
        let resolution = await SteamOwnedLibrary.shared.resolveSteamInputDefault(game: game, refresh: false, rememberedContext: true,
                                                                                 controller: controller)
        guard case .recommended(let value) = resolution else {
            if resolution == .unresolved(.contextUnavailable) || resolution == .unresolved(.templateControllerDependent) {
                // Steam's choice depends on the controller, which Dock reports only while the game runs.
                throw SteamInputUnavailable(errorDescription: "Steam chooses this game's default for the connected controller, and Madeira has not seen it yet. Start the game once with the controller connected; after that, this works without the game running.")
            }
            throw SteamInputUnavailable(errorDescription: DockSteamInputDefault.explanation(resolution))
        }
        return (value.source, String(value.sourceDescription.prefix(120)))
    }
    @MainActor private func load(reset: Bool, refresh: Bool = false) async {
        if !reset && loading { return }
        let id = UUID(), key = queryKey, text = search, sort = order
        request = id; loading = true; failure = nil
        if reset && !refresh { items = []; page = 0; total = 0; fetched = nil }
        defer { if request == id { loading = false } }
        do {
            if reset { try await Task.sleep(for: .milliseconds(250)) }
            let value = try await SteamInputCommunitySources.shared.page(appID: appID, order: sort, text: text,
                number: reset ? 1 : page + 1, refresh: refresh)
            try Task.checkCancellation()
            guard request == id, queryKey == key else { return }
            if reset { items = value.items }
            else {
                var seen = Set(items.map(\.id))
                items += value.items.filter { seen.insert($0.id).inserted }
            }
            page = value.number; total = value.total; fetched = value.fetched
        } catch is CancellationError {} catch {
            if request == id { failure = error.localizedDescription }
        }
    }
}

private struct SteamInputCommunityDetail: View {
    let appID: UInt32
    @State var item: SteamWorkshopItem
    @State private var history: [SteamInputCommunitySources.Revision] = []
    @State private var layout: SteamInputCommunitySources.Layout?
    @State private var busy = false
    @State private var failure: String?
    @State private var message: String?
    @State private var copyTitle = ""
    @State private var operation: Task<Void, Never>?
    /// The only preview state: request, loading, error and sheet all live in the model.
    @State private var preview = SteamInputPreviewPresentationModel()
    private var working: Bool { busy || preview.isLoading }
    private var accountID: UInt32 {
        SteamOwnedLibrary.shared.personalLayoutAccountID
    }
    var body: some View {
        Form {
            Section {
                Text(item.title).font(.headline)
                if !item.summary.isEmpty { Text(item.summary) }
                Text("Workshop item \(item.id)").font(.caption).foregroundStyle(.secondary)
                if let url = item.storeURL { Link("View attribution on Steam Workshop", destination: url) }
            }
            Section("Inspection & Download") {
                Button("Preview layout mappings") {
                    failure = nil; message = nil
                    preview.requestPreview(appID: appID, item: item, sources: .shared,
                                           actions: { await SteamOwnedLibrary.shared.steamInputActionNames(appID: $0) })
                }.disabled(working)
                Button(history.isEmpty ? "Download layout" : "Download listed revision") {
                    run {
                        let value = try await SteamInputCommunitySources.shared.download(appID: appID, item: item)
                        layout = value
                        history = try SteamInputCommunitySources.shared.cached(appID: appID, id: item.id)
                    }
                }.disabled(working)
                Button("Check for updates") {
                    run {
                        let latest = try await SteamInputCommunitySources.shared.latest(appID: appID, id: item.id)
                        item = latest
                        message = history.contains { $0.matches(latest) }
                            ? "This revision is cached." : "A revision is available to download. Your active layout is kept until you apply it."
                    }
                }.disabled(working)
                if working { ProgressView("Working…") }
                Button("Cancel download or lookup") { operation?.cancel(); preview.cancel() }.disabled(!working)
            }
            if !history.isEmpty {
                Section("Cached revisions") {
                    ForEach(history) { revision in
                        Button {
                            do { layout = try SteamInputCommunitySources.shared.load(revision); failure = nil }
                            catch { failure = error.localizedDescription }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(revision.item.title)
                                    Text("\(Date(timeIntervalSince1970: TimeInterval(revision.item.timeUpdated)).formatted(date: .abbreviated, time: .shortened)) · \(revision.hash.prefix(8))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if revision.hash == layout?.revision.hash { Image(systemName: "checkmark") }
                            }
                        }.disabled(working)
                    }
                    Text("Cached revisions work offline. A download or update does not apply a layout, and previous revisions remain available for rollback.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let layout {
                Section("Compatibility") {
                    Text(layout.compatibility.description)
                        .foregroundStyle(layout.compatibility.canApply ? Color.secondary : Color.orange)
                    Text(layout.revision.attribution).font(.caption).foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let current = DockSteamInputService.snapshot?.appID == appID
                    let active = current ? DockSteamInputService.activeChoice : nil
                    let isActive = active?.source == .community && active?.identity == String(item.id) && active?.contentHash == layout.revision.hash
                    Section {
                        Button(isActive ? "Active community layout" : "Apply this revision") {
                            do {
                                try DockSteamInputService.requestCommunity(appID: appID, source: layout.bytes,
                                    itemID: layout.revision.item.id, detail: layout.revision.attribution)
                                failure = nil; message = "Layout change requested. Waiting for Steam Input to confirm it."
                            } catch { failure = "The layout change could not start. Wait for the current layout to settle, then retry." }
                        }.disabled(working || isActive || !layout.compatibility.canApply || !current ||
                            !(DockSteamInputService.canChange || DockSteamInputService.canBootstrap))
                        ForEach(Array(DockSteamInputPresentation.lines(appID: appID, snapshot: DockSteamInputService.snapshot,
                            active: DockSteamInputService.activeChoice, selection: DockSteamInputService.selection).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                        if current, let receipt = DockSteamInputService.receipt {
                            if receipt.phase == .rolledBack { Text("The change failed. Steam Input restored the previous working layout.").foregroundStyle(.orange) }
                            if receipt.phase == .failed { Text("Steam Input could not confirm the change. Your saved layout is retained; relaunch to recover.").foregroundStyle(.red) }
                        }
                        Text("Return to the Steam Input controls to use Game default again.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Personal copy") {
                    TextField("Copy name", text: $copyTitle)
                    Button("Copy to personal layouts") {
                        do {
                            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            _ = try SteamInputPersonalCopy.create(layout, title: copyTitle, accountID: accountID, root: support)
                            message = "Saved a personal copy with its community attribution. Find it under Personal layouts, where it can be applied or exported."
                            failure = nil
                        } catch { failure = error.localizedDescription }
                    }.disabled(working || accountID == 0 || copyTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("The downloaded original stays unchanged. " + SteamInputPersonalCopy.storageNote)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure = failure ?? preview.errorMessage { Section { Text(failure).foregroundStyle(.red) } }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Steam Input layout")
        .task {
            copyTitle = item.title + " copy"
            do {
                history = try SteamInputCommunitySources.shared.cached(appID: appID, id: item.id)
                if let latest = history.first { layout = try SteamInputCommunitySources.shared.load(latest) }
            } catch { failure = error.localizedDescription }
        }
        .onDisappear { operation?.cancel(); preview.cancel() }
        .sheet(isPresented: Binding(get: { preview.isPresented }, set: { preview.isPresented = $0 })) {
            if let data = preview.previewData {
                SteamInputPreviewView(preview: data)
            }
        }
    }
    @MainActor private func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        busy = true; failure = nil; message = nil; preview.clearError()
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            do { try await body() }
            catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}
