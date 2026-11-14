// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

/// Read-only preview sheet displaying all sets, layers, bindings, and diagnostics for a community layout.
public struct SteamInputPreviewView: View {
    public let preview: SteamInputPreviewData
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSetID: String = ""

    public init(preview: SteamInputPreviewData) {
        self.preview = preview
        _selectedSetID = State(initialValue: preview.actionSets.first?.id ?? "")
    }

    private var currentSet: SteamInputPreviewData.ActionSetView? {
        preview.actionSets.first { $0.id == selectedSetID } ?? preview.actionSets.first
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(preview.title).font(.headline)
                        if !preview.description.isEmpty {
                            Text(preview.description).font(.callout).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            BadgeView(text: preview.controllerType, color: .secondary)
                            if preview.isFullyCompatible {
                                BadgeView(text: "Compatible with DualSense", color: .green)
                            } else {
                                BadgeView(text: "Limitations / Conditions", color: .orange)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !preview.diagnoses.isEmpty {
                    diagnosticsSection
                }

                if preview.actionSets.count > 1 {
                    Section("Action Sets & Layers") {
                        Picker("Select Set", selection: $selectedSetID) {
                            ForEach(preview.actionSets) { s in
                                Text(s.isLayer ? "\(s.title) (Layer)" : s.title).tag(s.id)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if let set = currentSet {
                    if set.regions.isEmpty {
                        Section {
                            Text("No active bindings defined in this set.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(set.regions) { region in
                            Section(region.title) {
                                ForEach(region.inputs) { input in
                                    inputRow(input)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Layout Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics & Compatibility") {
            ForEach(preview.diagnoses) { diag in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: iconName(for: diag.category))
                            .foregroundStyle(iconColor(for: diag.category))
                        Text(diag.title).font(.subheadline.weight(.semibold))
                    }
                    Text(diag.detail).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func inputRow(_ input: SteamInputPreviewData.InputMappingView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(input.inputName).font(.body.weight(.medium))
                Spacer()
                if input.isMissingReference {
                    BadgeView(text: "Missing Group", color: .red)
                }
                if input.isLayerOverride {
                    BadgeView(text: "Layer Override", color: .purple)
                } else if input.isInherited {
                    BadgeView(text: "Inherited" + (input.parentSetName.map { " (\($0))" } ?? ""), color: .secondary)
                }
            }
            conditionBadges(input.conditions[...])

            if let raw = input.rawContent {
                Text(raw)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }

            if input.activators.isEmpty {
                if let settings = input.settings, !settings.isEmpty {
                    Text(settings.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                // An activator's chain starts with its input's, and a binding's with
                // its activator's, so each row adds only the conditions below its parent.
                ForEach(input.activators) { act in
                    conditionBadges(act.conditions.dropFirst(input.conditions.count))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(act.kind).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if act.toggle { BadgeView(text: "Toggle", color: .secondary) }
                        if act.turbo { BadgeView(text: "Turbo", color: .secondary) }
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(act.bindings) { b in
                                HStack(spacing: 4) {
                                    Text(b.displayText).font(.callout)
                                    outputCategoryBadge(b.category)
                                }
                                conditionBadges(b.conditions.dropFirst(act.conditions.count))
                            }
                        }
                    }
                }
                if let settings = input.settings, !settings.isEmpty {
                    let nonDefault = settings.filter { $0.key.contains("curve") || $0.key.contains("deadzone") || $0.key == "mode" }
                    if !nonDefault.isEmpty {
                        Text("Settings: " + nonDefault.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// One badge per condition, scope first, in nesting order. Conditions are
    /// listed as written: none is evaluated, merged or dropped.
    @ViewBuilder
    private func conditionBadges(_ conditions: ArraySlice<SteamInputPreviewData.SourceCondition>) -> some View {
        ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
            BadgeView(text: "\(condition.scope): \(condition.expression)", color: .orange)
        }
    }

    @ViewBuilder
    private func outputCategoryBadge(_ cat: SteamInputLayoutModel.OutputCategory) -> some View {
        switch cat {
        case .gamepad:
            BadgeView(text: "Pad", color: .blue)
        case .keyboard:
            BadgeView(text: "Key", color: .green)
        case .mouse:
            BadgeView(text: "Mouse", color: .purple)
        case .action:
            BadgeView(text: "Action", color: .orange)
        case .layout:
            BadgeView(text: "Layout", color: .teal)
        case .steam:
            BadgeView(text: "Steam", color: .indigo)
        case .unverified:
            BadgeView(text: "Unverified", color: .gray)
        }
    }

    private func iconName(for category: SteamInputPreviewData.DiagnosticCategory) -> String {
        switch category {
        case .unavailableHardware: return "exclamationmark.triangle.fill"
        case .viewerOrRuntimeLimitation: return "info.circle.fill"
        case .unresolvedReference: return "questionmark.circle.fill"
        }
    }

    private func iconColor(for category: SteamInputPreviewData.DiagnosticCategory) -> Color {
        switch category {
        case .unavailableHardware: return .orange
        case .viewerOrRuntimeLimitation: return .blue
        case .unresolvedReference: return .secondary
        }
    }
}

private struct BadgeView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
