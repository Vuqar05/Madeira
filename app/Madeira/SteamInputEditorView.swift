// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

/// The state of one editing session of a personal layout. Every change goes
/// through `SteamInputLayoutDraft` (structural, lossless edits) and
/// `SteamInputEditHistory` (undo and redo); unsaved edits are kept as the
/// layout's draft after every change, so they survive a crash or a restart.
/// Saving makes a new revision; "Save and apply" goes through
/// `SteamInputLiveEdit` while the game runs.
@MainActor final class SteamInputEditorModel: ObservableObject {
    let appID: UInt32
    let root: URL
    @Published private(set) var copy: SteamInputPersonalCopy
    @Published private(set) var history: SteamInputEditHistory?
    @Published var failure: String?
    @Published var message: String?
    @Published private(set) var loadFailure: String?
    /// Unsaved edits found on opening, offered before anything else.
    @Published private(set) var recoveredDraft: (bytes: Data, saved: Date, olderBase: Bool)?
    @Published private(set) var damagedDraft = false
    /// The preset (action set or layer) whose sources are shown.
    @Published var presetPath: VDFPath?
    var onSaved: (SteamInputPersonalCopy) -> Void = { _ in }

    init(appID: UInt32, copy: SteamInputPersonalCopy, root: URL) {
        self.appID = appID
        self.copy = copy
        self.root = root
    }

    var draft: SteamInputLayoutDraft? { history?.current }
    var references: SteamInputPersonalReferences {
        DockSteamInputService.personalReferences(accountID: copy.accountID, appID: copy.appID)
    }

    func load() {
        guard history == nil else { return }
        do {
            copy = try copy.reloaded(root: root)
            let saved = try SteamInputLayoutDraft(bytes: copy.bytes(root: root))
            history = SteamInputEditHistory(saved)
            presetPath = saved.model.presets.first?.path
            if copy.pending != nil { _ = try? settle() }
        } catch {
            loadFailure = "This layout cannot be opened for editing. " + error.localizedDescription
            return
        }
        do {
            if let found = try copy.draft(root: root) {
                let bytes = try copy.draftBytes(found, root: root)
                _ = try SteamInputLayoutDraft(bytes: bytes)
                if bytes != history?.savedBytes {
                    recoveredDraft = (bytes, found.saved, found.base != copy.hash)
                }
            }
        } catch {
            damagedDraft = true
        }
    }

    /// Runs one edit. A refused edit changes nothing and says why.
    func perform(_ edit: (SteamInputLayoutDraft) throws -> SteamInputLayoutDraft) {
        guard var value = history else { return }
        do {
            try value.apply(edit)
            history = value
            failure = nil
            message = nil
            keepDraft()
        } catch {
            failure = error.localizedDescription
        }
    }

    func undo() { history?.undo(); keepDraft() }
    func redo() { history?.redo(); keepDraft() }

    private func keepDraft() {
        guard let history else { return }
        do {
            if history.hasUnsavedChanges { try copy.savingDraft(history.current.bytes, base: copy.hash, root: root) }
            else { try copy.discardDraft(root: root) }
        } catch {
            failure = "Your edits could not be kept as a draft: " + error.localizedDescription
        }
    }

    func resumeDraft() {
        guard let recovered = recoveredDraft, let draft = try? SteamInputLayoutDraft(bytes: recovered.bytes) else { return }
        history?.replace(with: draft)
        recoveredDraft = nil
        message = recovered.olderBase ? "Unsaved edits restored. They began from an earlier revision; saving makes them the current revision." : "Unsaved edits restored."
    }

    func discardDraft() {
        try? copy.discardDraft(root: root)
        recoveredDraft = nil
        damagedDraft = false
        message = "The unsaved edits were discarded."
    }

    /// Back to the saved revision, as one undoable step.
    func revert() {
        guard let saved = try? SteamInputLayoutDraft(bytes: copy.bytes(root: root)) else { return }
        history?.replace(with: saved)
        keepDraft()
    }

    func save() {
        guard var value = history else { return }
        do {
            copy = try copy.saving(value.current.bytes, references: references, root: root)
            value.markSaved()
            history = value
            failure = nil
            message = "Saved as a new revision. Apply it to use it in the game."
            onSaved(copy)
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: Live editing

    var gameRunning: Bool { DockSteamInputService.snapshot?.appID == appID }
    var canApplyLive: Bool {
        gameRunning && copy.pending == nil && (DockSteamInputService.canChange || DockSteamInputService.canBootstrap)
    }

    /// Saves the edits as a pending revision and asks Steam Input to use it.
    /// The working revision stays current until Steam Input confirms the new one.
    func saveAndApply() {
        guard let value = history else { return }
        do {
            copy = try SteamInputLiveEdit.apply(value.current.bytes, to: copy, root: root)
            failure = nil
            message = "Applying… Held buttons and keys were released. Waiting for Steam Input to confirm the change."
        } catch {
            failure = error.localizedDescription + " The layout in use is unchanged."
        }
    }

    /// Called every second while a change is pending.
    @discardableResult func settle() throws -> SteamInputPersonalCopy.LiveOutcome {
        let (value, outcome) = try SteamInputLiveEdit.settle(copy, root: root)
        copy = value
        switch outcome {
        case .confirmed:
            if var history, history.current.bytes == (try? value.bytes(root: root)) { history.markSaved(); self.history = history }
            message = "Steam Input confirmed the change. It is saved and in use."
            onSaved(value)
        case .reverted:
            message = nil
            failure = "Steam Input did not use the change, so the previous revision is still in use. Your edits are kept as a draft."
        case .waiting, .idle:
            break
        }
        return outcome
    }
}

/// Edits one personal layout. Unsupported content is listed and kept as written.
struct SteamInputLayoutEditorView: View {
    @StateObject private var model: SteamInputEditorModel
    @State private var title = ""
    @State private var notes = ""
    @State private var newSetName = ""
    @State private var newLayerName = ""

    init(appID: UInt32, copy: SteamInputPersonalCopy, root: URL, onSaved: @escaping (SteamInputPersonalCopy) -> Void = { _ in }) {
        let model = SteamInputEditorModel(appID: appID, copy: copy, root: root)
        model.onSaved = onSaved
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Form {
            if let loadFailure = model.loadFailure {
                Section { Text(loadFailure).foregroundStyle(.red) }
            } else if let draft = model.draft {
                recovery
                if let failure = model.failure { Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("editor.failure") } }
                if let message = model.message { Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("editor.message") } }
                if let reason = draft.notEditableReason {
                    Section { Text(reason).foregroundStyle(.orange) }
                }
                layoutSection(draft)
                statusSection(draft)
                setsSection(draft)
                sourcesSection(draft)
                SteamInputUnsupportedSection(draft: draft)
            } else {
                ProgressView("Opening layout…")
            }
        }
        .navigationTitle("Edit layout")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(model.history?.canUndo != true).accessibilityIdentifier("editor.undo")
                Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(model.history?.canRedo != true).accessibilityIdentifier("editor.redo")
                Button("Save") { model.save() }
                    .disabled(model.history?.hasUnsavedChanges != true || model.copy.pending != nil).accessibilityIdentifier("editor.save")
            }
        }
        .task {
            model.load()
            title = model.copy.title
            if let draft = model.draft { notes = draft.model.description }
        }
    }

    @ViewBuilder private var recovery: some View {
        if let recovered = model.recoveredDraft {
            Section("Unsaved edits") {
                Text("Edits from \(recovered.saved.formatted(date: .abbreviated, time: .shortened)) were not saved. Restore them, or discard them and keep the saved revision.")
                Button("Restore unsaved edits") { model.resumeDraft() }.accessibilityIdentifier("editor.resumeDraft")
                Button("Discard unsaved edits", role: .destructive) { model.discardDraft() }
            }
        } else if model.damagedDraft {
            Section("Unsaved edits") {
                Text("Unsaved edits were found but cannot be read. The saved revision is unchanged.").foregroundStyle(.orange)
                Button("Discard the damaged edits", role: .destructive) { model.discardDraft() }
            }
        }
    }

    private func layoutSection(_ draft: SteamInputLayoutDraft) -> some View {
        Section {
            TextField("Layout title", text: $title)
                .onSubmit { model.perform { try $0.settingTitle(title) } }
                .accessibilityIdentifier("editor.title")
            TextField("Notes", text: $notes, axis: .vertical)
                .onSubmit { model.perform { try $0.settingDescription(notes) } }
            Button("Update title and notes") {
                model.perform { try $0.settingTitle(title).settingDescription(notes) }
            }.disabled(draft.model.title == title.trimmingCharacters(in: .whitespacesAndNewlines) && draft.model.description == notes)
            if model.history?.hasUnsavedChanges == true {
                Button("Revert to the saved revision", role: .destructive) { model.revert() }
            }
        } header: {
            Text("Layout")
        } footer: {
            Text("The title inside the layout file. The name in your list is changed with Rename.")
        }
    }

    private func statusSection(_ draft: SteamInputLayoutDraft) -> some View {
        Section("Before applying") {
            let problems = draft.referenceProblems
            if problems.isEmpty {
                Label("Every group, action set and layer reference resolves.", systemImage: "checkmark.circle")
            } else {
                ForEach(problems) { problem in
                    Label(problem.reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            if let compatibility = try? SteamInputCompatibility(draft.bytes) {
                Text(compatibility.description).foregroundStyle(compatibility.canApply ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("editor.compatibility")
            }
            if !draft.model.conditionSites.isEmpty {
                Text("This layout has \(draft.model.conditionSites.count) platform condition(s). They are kept exactly as written, and conditional layouts cannot be applied yet.")
                    .foregroundStyle(.orange)
            }
            if model.gameRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let pending = model.copy.pending != nil
                    VStack(alignment: .leading, spacing: 6) {
                        Button(pending ? "Waiting for Steam Input…" : "Save and apply now") { model.saveAndApply() }
                            .disabled(!model.canApplyLive || !problems.isEmpty).accessibilityIdentifier("editor.saveAndApply")
                        Text("Held buttons and keys are released before the switch. If Steam Input cannot use the change, the layout in use stays as it is.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .task(id: pending) {
                        while model.copy.pending != nil, !Task.isCancelled {
                            _ = try? model.settle()
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                }
            } else {
                Text("Start the game to apply changes while it runs. Saved revisions are applied from the layout's page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func presetTitle(_ draft: SteamInputLayoutDraft, _ preset: SteamInputLayoutModel.Preset) -> String {
        let isLayer = draft.model.actionLayers.contains { draft.model.preset(for: $0) == preset }
        let title = draft.model.title(of: preset).flatMap { draft.model.localized($0) ?? $0 } ?? (preset.name.isEmpty ? "Preset \(preset.id)" : preset.name)
        return isLayer ? "Layer: " + title : title
    }

    private func setsSection(_ draft: SteamInputLayoutDraft) -> some View {
        Section {
            Picker("Editing", selection: $model.presetPath) {
                ForEach(draft.model.presets, id: \.path) { preset in
                    Text(presetTitle(draft, preset)).tag(Optional(preset.path))
                }
            }.accessibilityIdentifier("editor.preset")
            if let path = model.presetPath, let preset = draft.preset(at: path) {
                SteamInputRenameRow(title: presetTitle(draft, preset).replacingOccurrences(of: "Layer: ", with: "")) { name in
                    model.perform { try $0.renamingActionSet(path, to: name) }
                }
                Button("Remove this set or layer", role: .destructive) {
                    model.perform { try $0.removingActionSet(path) }
                    if draft.preset(at: path) == nil || model.draft?.preset(at: path) == nil { model.presetPath = model.draft?.model.presets.first?.path }
                }
            }
            HStack {
                TextField("New action set", text: $newSetName)
                Button("Add") {
                    model.perform { try $0.addingActionSet(title: newSetName, copying: model.presetPath) }
                    newSetName = ""
                }.disabled(newSetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if draft.model.declaresActionSets {
                HStack {
                    TextField("New layer", text: $newLayerName)
                    Button("Add") {
                        let parent = draft.model.actionSets.first { set in model.presetPath.flatMap(draft.preset(at:)) == draft.model.preset(for: set) }?.id
                            ?? draft.model.actionSets.first?.id ?? ""
                        model.perform { try $0.addingActionLayer(title: newLayerName, parentSetID: parent) }
                        newLayerName = ""
                    }.disabled(newLayerName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Action sets and layers")
        } footer: {
            Text("A new action set starts as a copy of the one being edited. A layer starts empty and changes only what it binds. Switch sets and layers with a binding.")
        }
    }

    @ViewBuilder private func sourcesSection(_ draft: SteamInputLayoutDraft) -> some View {
        if let path = model.presetPath, let preset = draft.preset(at: path) {
            Section {
                ForEach(SteamInputEditorCatalog.sources) { source in
                    SteamInputSourceRow(model: model, presetPath: path, source: source)
                }
                let known = Set(SteamInputEditorCatalog.sources.map(\.value))
                ForEach(preset.bindings.filter { !known.contains($0.source) && $0.isActive }, id: \.path) { binding in
                    if case .defined(let group) = draft.model.lookup(group: binding.groupID) {
                        NavigationLink {
                            SteamInputGroupEditor(model: model, groupPath: group.path, source: binding.source)
                        } label: {
                            LabeledContent(SteamInputLayoutModel.ParsedBinding.formatSource(binding.source), value: group.humanMode)
                        }
                    }
                }
                ForEach(preset.bindings.filter { $0.isModeShift && $0.isActive }, id: \.path) { binding in
                    if case .defined(let group) = draft.model.lookup(group: binding.groupID) {
                        NavigationLink {
                            SteamInputGroupEditor(model: model, groupPath: group.path, source: binding.source)
                        } label: {
                            LabeledContent("Mode shift · " + SteamInputLayoutModel.ParsedBinding.formatSource(binding.source), value: group.humanMode)
                        }
                    }
                }
            } header: {
                Text("Controls")
            } footer: {
                Text("Changing a mode keeps the previous one in the layout, so switching back restores its bindings. Gyro and touchpad can be edited; Madeira cannot forward them yet, so a layout that uses them cannot be applied.")
            }
        }
    }
}

/// One physical source in the preset being edited: its mode and its bindings.
private struct SteamInputSourceRow: View {
    @ObservedObject var model: SteamInputEditorModel
    let presetPath: VDFPath
    let source: SteamInputEditorCatalog.Choice

    var body: some View {
        if let draft = model.draft, let preset = draft.preset(at: presetPath) {
            let active = draft.activeBinding(for: source.value, in: preset)
            let group: SteamInputLayoutModel.Group? = active.flatMap {
                if case .defined(let group) = draft.model.lookup(group: $0.groupID) { return group }
                return nil
            }
            // Separate rows: a picker and a link in one form row would both take the tap.
            Group {
                Picker(source.title, selection: Binding(get: { group?.mode ?? "" }, set: { mode in
                    model.perform { mode.isEmpty ? try $0.disablingSource(source.value, in: presetPath)
                                                 : try $0.switchingMode(of: source.value, in: presetPath, to: mode) }
                })) {
                    Text("Not used").tag("")
                    if let group, !SteamInputEditorCatalog.modes(for: source.value).contains(where: { $0.value == group.mode }) {
                        Text(group.humanMode).tag(group.mode)
                    }
                    ForEach(SteamInputEditorCatalog.modes(for: source.value)) { Text($0.title).tag($0.value) }
                }
                .accessibilityIdentifier("source.\(source.value)")
                if let group {
                    NavigationLink("Edit \(source.title.lowercased())") {
                        SteamInputGroupEditor(model: model, groupPath: group.path, source: source.value)
                    }.accessibilityIdentifier("source.\(source.value).edit")
                }
            }
        }
    }
}

/// A group: its settings and every input's activators and bindings.
struct SteamInputGroupEditor: View {
    @ObservedObject var model: SteamInputEditorModel
    let groupPath: VDFPath
    let source: String
    @State private var bindingTarget: SteamInputBindingTarget?
    @State private var shiftTarget: VDFPath?

    var body: some View {
        Form {
            if let failure = model.failure { Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("group.failure") } }
            if let draft = model.draft, let group = draft.group(at: groupPath) {
                Section {
                    LabeledContent("Input", value: SteamInputLayoutModel.ParsedBinding.formatSource(source))
                    LabeledContent("Mode", value: group.humanMode)
                    if !group.name.isEmpty { LabeledContent("Name", value: group.name) }
                }
                ForEach(group.inputs, id: \.path) { input in
                    inputSection(draft, group, input)
                }
                let missing = SteamInputEditorCatalog.inputs(for: group.mode).filter { group.input($0) == nil }
                if !missing.isEmpty {
                    Section {
                        Menu("Add input") {
                            ForEach(missing, id: \.self) { name in
                                Button(SteamInputLayoutModel.Input(name: name, activators: [], disabledActivators: [], conditions: []).humanName) {
                                    model.perform { try $0.addingInput(name, to: groupPath) }
                                }
                            }
                        }.accessibilityIdentifier("group.addInput")
                    }
                }
                SteamInputSettingsSection(title: "Behavior", choices: SteamInputEditorCatalog.groupSettings, values: group.settings,
                                          footer: "Dead zones, response curve, sensitivity and outputs, in Steam's own units. Leave a value empty to use Steam's default.") { key, value in
                    model.perform { try $0.settingGroupSetting(key, to: value, at: groupPath) }
                }
            }
            if model.draft?.group(at: groupPath) == nil {
                Section { Text("This part of the layout changed. Go back and open it again.") }
            }
        }
        .navigationTitle(SteamInputLayoutModel.ParsedBinding.formatSource(source))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(model.history?.canUndo != true)
                Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(model.history?.canRedo != true)
            }
        }
        .sheet(item: $bindingTarget) { target in
            NavigationStack {
                SteamInputBindingEditor(target: target, draft: model.draft) { command, label in
                    model.perform { draft in
                        if let path = target.binding { return try draft.replacingBinding(at: path, with: command, label: label) }
                        return try draft.addingBinding(command, label: label, to: target.activator)
                    }
                    if model.failure == nil { bindingTarget = nil }
                }
            }
        }
        .sheet(isPresented: Binding(get: { shiftTarget != nil }, set: { if !$0 { shiftTarget = nil } })) {
            NavigationStack {
                SteamInputModeShiftEditor(presets: model.draft?.model.presets ?? [], initialPreset: model.presetPath) { preset, shiftSource, mode in
                    if let activator = shiftTarget {
                        model.perform { try $0.addingModeShift(on: activator, in: preset, source: shiftSource, mode: mode) }
                    }
                    if model.failure == nil { shiftTarget = nil }
                }
            }
        }
    }

    private func inputSection(_ draft: SteamInputLayoutDraft, _ group: SteamInputLayoutModel.Group, _ input: SteamInputLayoutModel.Input) -> some View {
        Section {
            ForEach(input.activators, id: \.path) { activator in
                activatorRows(draft, input, activator)
            }
            ForEach(input.disabledActivators, id: \.path) { activator in
                Text("\(activator.humanKind) · switched off in Steam, kept as written").font(.caption).foregroundStyle(.secondary)
            }
            Menu("Add activator") {
                ForEach(SteamInputEditorCatalog.activators) { kind in
                    Button(kind.title) { model.perform { try $0.addingActivator(kind.value, to: input.path) } }
                }
            }.accessibilityIdentifier("input.\(input.name).addActivator")
            Button("Remove input", role: .destructive) { model.perform { try $0.removingInput(at: input.path) } }
        } header: {
            Text(input.humanName)
        }
    }

    @ViewBuilder private func activatorRows(_ draft: SteamInputLayoutDraft, _ input: SteamInputLayoutModel.Input, _ activator: SteamInputLayoutModel.Activator) -> some View {
        let id = "\(input.name).\(activator.kind)"
        Picker("Activator", selection: Binding(get: { activator.kind }, set: { kind in
            model.perform { try $0.changingActivator(at: activator.path, to: kind) }
        })) {
            if !SteamInputEditorCatalog.activators.contains(where: { $0.value == activator.kind }) { Text(activator.humanKind).tag(activator.kind) }
            ForEach(SteamInputEditorCatalog.activators) { Text($0.title).tag($0.value) }
        }.accessibilityIdentifier("activator.\(id).kind")
        ForEach(Array(activator.bindings.enumerated()), id: \.element.path) { index, binding in
            HStack {
                VStack(alignment: .leading) {
                    Text(binding.displayText).accessibilityIdentifier("binding.\(id).\(index)")
                    if SteamInputBindingCommand(binding.verb) == nil {
                        Text("Kept as written; Madeira cannot edit this binding.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !binding.conditions.isEmpty {
                        Text("Condition kept: " + binding.conditions.map(\.expression).joined(separator: " ")).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if SteamInputBindingCommand(binding.verb) != nil {
                    Button("Edit") { bindingTarget = .init(activator: activator.path, binding: binding.path, current: binding) }
                        .buttonStyle(.borderless).accessibilityIdentifier("binding.\(id).\(index).edit")
                }
                Button(role: .destructive) { model.perform { try $0.removingBinding(at: binding.path) } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove binding").accessibilityIdentifier("binding.\(id).\(index).remove")
            }
        }
        HStack {
            Button("Add binding") { bindingTarget = .init(activator: activator.path, binding: nil, current: nil) }
                .buttonStyle(.borderless).accessibilityIdentifier("activator.\(id).addBinding")
            Spacer()
            Button("Add mode shift") { shiftTarget = activator.path }.buttonStyle(.borderless)
        }
        Toggle("Toggle", isOn: Binding(get: { activator.toggle }, set: { on in model.perform { try $0.settingToggle(on, at: activator.path) } }))
            .accessibilityIdentifier("activator.\(id).toggle")
        Toggle("Turbo", isOn: Binding(get: { activator.turbo }, set: { on in model.perform { try $0.settingTurbo(on, at: activator.path) } }))
            .accessibilityIdentifier("activator.\(id).turbo")
        DisclosureGroup("Timing and feedback") {
            SteamInputSettingsRows(choices: SteamInputEditorCatalog.activatorSettings, values: activator.settings) { key, value in
                model.perform { try $0.settingActivatorSetting(key, to: value, at: activator.path) }
            }
        }
        Button("Remove \(activator.humanKind.lowercased())", role: .destructive) { model.perform { try $0.removingActivator(at: activator.path) } }
    }
}

struct SteamInputBindingTarget: Identifiable {
    let activator: VDFPath
    /// Nil when adding a binding.
    let binding: VDFPath?
    let current: SteamInputLayoutModel.ParsedBinding?
    var id: String { (binding ?? activator).description }
}

/// Chooses what one binding does.
struct SteamInputBindingEditor: View {
    enum Kind: String, CaseIterable, Identifiable {
        case gamepad = "Gamepad button", key = "Keyboard key", mouse = "Mouse button", wheel = "Mouse wheel"
        case action = "Game action", set = "Change action set", layer = "Layer"
        var id: String { rawValue }
    }
    let target: SteamInputBindingTarget
    let draft: SteamInputLayoutDraft?
    let onSave: (SteamInputBindingCommand, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.gamepad
    @State private var gamepad = "A"
    @State private var key = "SPACE"
    @State private var mouse = "LEFT"
    @State private var wheelUp = true
    @State private var actionSet = ""
    @State private var action = ""
    @State private var preset = 1
    @State private var layerOperation = SteamInputLayoutModel.ParsedBinding.LayerOperation.hold
    @State private var label = ""

    private var command: SteamInputBindingCommand {
        switch kind {
        case .gamepad: return .gamepad(gamepad)
        case .key: return .key(key)
        case .mouse: return .mouseButton(mouse)
        case .wheel: return .mouseWheel(up: wheelUp)
        case .action: return .gameAction(set: actionSet, action: action)
        case .set: return .changeActionSet(preset: preset)
        case .layer: return .layer(layerOperation, preset: preset)
        }
    }

    private var presets: [(number: Int, title: String, layer: Bool)] {
        guard let model = draft?.model else { return [] }
        return model.presets.compactMap { preset in
            guard let id = Int(preset.id) else { return nil }
            let layer = model.actionLayers.contains { model.preset(for: $0) == preset }
            let title = model.title(of: preset).flatMap { model.localized($0) ?? $0 } ?? preset.name
            return (id + 1, title.isEmpty ? "Preset \(id)" : title, layer)
        }
    }

    var body: some View {
        Form {
            Picker("Type", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                .accessibilityIdentifier("bindingEditor.kind")
            switch kind {
            case .gamepad:
                Picker("Button", selection: $gamepad) { ForEach(SteamInputEditorCatalog.gamepadButtons) { Text($0.title).tag($0.value) } }
                    .accessibilityIdentifier("bindingEditor.gamepad")
            case .key:
                Picker("Key", selection: $key) { ForEach(SteamInputEditorCatalog.keys) { Text($0.title).tag($0.value) } }
                    .accessibilityIdentifier("bindingEditor.key")
                Text("Madeira does not deliver keyboard input to games yet; Steam Input still receives the binding.").font(.caption).foregroundStyle(.secondary)
            case .mouse:
                Picker("Button", selection: $mouse) { ForEach(SteamInputEditorCatalog.mouseButtons) { Text($0.title).tag($0.value) } }
            case .wheel:
                Picker("Direction", selection: $wheelUp) { Text("Wheel up").tag(true); Text("Wheel down").tag(false) }
            case .action:
                let sets = draft?.model.actionSets ?? []
                TextField("Action set", text: $actionSet).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Action", text: $action).textInputAutocapitalization(.never).autocorrectionDisabled()
                let declared = sets.flatMap { set in set.declaredActions.map { (set.id, $0) } }
                if !declared.isEmpty {
                    Menu("Choose a declared action") {
                        ForEach(Array(declared.enumerated()), id: \.offset) { _, entry in
                            Button("\(entry.0) › \(draft?.model.localized(entry.1.title) ?? entry.1.id)") { actionSet = entry.0; action = entry.1.id }
                        }
                    }
                }
            case .set, .layer:
                let choices = presets.filter { kind == .layer ? $0.layer : !$0.layer }
                if choices.isEmpty {
                    Text(kind == .layer ? "This layout has no layers. Add one under Action sets and layers." : "This layout has one action set.").foregroundStyle(.secondary)
                } else {
                    Picker(kind == .layer ? "Layer" : "Action set", selection: $preset) {
                        ForEach(choices, id: \.number) { Text($0.title).tag($0.number) }
                    }
                }
                if kind == .layer {
                    Picker("Operation", selection: $layerOperation) {
                        Text("Hold layer").tag(SteamInputLayoutModel.ParsedBinding.LayerOperation.hold)
                        Text("Add layer").tag(SteamInputLayoutModel.ParsedBinding.LayerOperation.add)
                        Text("Remove layer").tag(SteamInputLayoutModel.ParsedBinding.LayerOperation.remove)
                    }
                }
            }
            TextField("Label (optional)", text: $label).accessibilityIdentifier("bindingEditor.label")
            if let current = target.current { Text("Currently: " + current.displayText).font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle(target.binding == nil ? "Add binding" : "Edit binding")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onSave(command, label.isEmpty ? nil : label) }
                    .disabled(!command.isWellFormed).accessibilityIdentifier("bindingEditor.done")
            }
        }
        .onAppear(perform: start)
    }

    private func start() {
        guard let current = target.current else { return }
        label = current.label ?? ""
        switch SteamInputBindingCommand(current.verb) {
        case .gamepad(let value)?: kind = .gamepad; gamepad = value
        case .key(let value)?: kind = .key; key = SteamInputEditorCatalog.keys.contains { $0.value == value } ? value : "SPACE"
        case .mouseButton(let value)?: kind = .mouse; mouse = value
        case .mouseWheel(let up)?: kind = .wheel; wheelUp = up
        case .gameAction(let set, let name)?: kind = .action; actionSet = set; action = name
        case .changeActionSet(let number)?: kind = .set; preset = number
        case .layer(let operation, let number)?: kind = .layer; layerOperation = operation; preset = number
        case .modeShift?, nil: break
        }
    }
}

/// Picks the source and mode a new mode shift switches to.
private struct SteamInputModeShiftEditor: View {
    let presets: [SteamInputLayoutModel.Preset]
    let initialPreset: VDFPath?
    let onSave: (VDFPath, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source = "right_joystick"
    @State private var mode = ""

    var body: some View {
        Form {
            Picker("While held, change", selection: $source) {
                ForEach(SteamInputEditorCatalog.sources) { Text($0.title).tag($0.value) }
            }
            Picker("To", selection: $mode) {
                Text("Choose a mode").tag("")
                ForEach(SteamInputEditorCatalog.modes(for: source)) { Text($0.title).tag($0.value) }
            }
            Text("A mode shift adds a new group for the chosen input. Edit its bindings from the Controls list.").font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Add mode shift")
        .onChange(of: source) { mode = "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { if let preset = initialPreset ?? presets.first?.path { onSave(preset, source, mode) } }.disabled(mode.isEmpty)
            }
        }
    }
}

/// Number-like settings with a field each; values outside the list are shown too.
private struct SteamInputSettingsSection: View {
    let title: String
    let choices: [SteamInputEditorCatalog.Choice]
    let values: [String: String]
    let footer: String
    let onChange: (String, String?) -> Void

    var body: some View {
        Section {
            SteamInputSettingsRows(choices: choices, values: values, onChange: onChange)
        } header: { Text(title) } footer: { Text(footer) }
    }
}

private struct SteamInputSettingsRows: View {
    let choices: [SteamInputEditorCatalog.Choice]
    let values: [String: String]
    let onChange: (String, String?) -> Void

    var body: some View {
        let known = Set(choices.map(\.value))
        let others = values.keys.filter { !known.contains($0) }.sorted().map { SteamInputEditorCatalog.Choice(value: $0, title: $0.replacingOccurrences(of: "_", with: " ").capitalized) }
        ForEach(choices + others) { choice in
            SteamInputSettingField(choice: choice, value: values[choice.value] ?? "", onChange: onChange)
        }
    }
}

private struct SteamInputSettingField: View {
    let choice: SteamInputEditorCatalog.Choice
    let value: String
    let onChange: (String, String?) -> Void
    @State private var text = ""

    var body: some View {
        LabeledContent(choice.title) {
            TextField("Default", text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .onSubmit { onChange(choice.value, text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text) }
                .accessibilityIdentifier("setting.\(choice.value)")
        }
        .onAppear { text = value }
        .onChange(of: value) { text = value }
    }
}

struct SteamInputRenameRow: View {
    let title: String
    let onRename: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            TextField("Name", text: $text)
            Button("Rename") { onRename(text) }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || text == title)
        }
        .onAppear { text = title }
        .onChange(of: title) { text = title }
    }
}

/// Everything the editor keeps but cannot edit yet, as written.
struct SteamInputUnsupportedSection: View {
    let draft: SteamInputLayoutDraft

    var body: some View {
        let entries = draft.model.unrecognizedEntries
        Section {
            if entries.isEmpty {
                Text("Everything in this layout can be edited here.").foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.path).font(.caption.bold())
                    Text(entry.rawContent).font(.caption.monospaced()).lineLimit(6).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("unsupported.\(entry.key)")
            }
        } header: {
            Text("Kept unchanged · not editable yet")
        } footer: {
            Text("Madeira saves these settings exactly as written. Edits elsewhere never change or remove them.")
        }
    }
}
