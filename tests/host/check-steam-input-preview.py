#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Comprehensive unit and acceptance tests for Steam Input Milestone 4 initial slice."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'

program = r'''
import Foundation
import CryptoKit

enum VDFParser { static func parseTextVDF(from: Data, sectionOrder: (([String], [String]) -> Void)? = nil) -> [String: Any] { [:] } }
enum MadeiraConfig { static func get(_ key: String) -> String? { nil }; static func set(_ key: String, _ value: String?) {} }
enum SteamLog { static func event(_ text: String) {}; static func trace(_ text: @autoclosure () -> String) {} }
@MainActor final class SteamSession {
    enum Method { case workshopGetDetails, workshopQueryFiles }
    init(anonymous: Bool) { precondition(anonymous) }
    func ensureConnected() async throws { fatalError("network not injected") }
    func callServiceMethodWithResult(method: Method, body: Data, timeout: TimeInterval) async throws -> (eresult: Int32, body: Data) { fatalError() }
}
@MainActor final class SteamLibraryFetcher {
    init(session: SteamSession) {}
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? { fatalError() }
}

func require(_ body: @autoclosure () throws -> Bool, _ message: String = "precondition failed", file: StaticString = #file, line: UInt = #line) {
    do {
        let result = try body()
        precondition(result, message, file: file, line: line)
    } catch {
        preconditionFailure("\(message): \(error)", file: file, line: line)
    }
}

/// Yields `total` bytes and counts each one the consumer pulls. `cancelAt`
/// cancels the consuming task while that byte is being produced.
final class ProbeCount: @unchecked Sendable { var pulled = 0 }   // touched by one task at a time
struct ProbeStream: AsyncSequence, Sendable {
    typealias Element = UInt8
    let total: Int
    var cancelAt: Int? = nil
    let count: ProbeCount
    struct AsyncIterator: AsyncIteratorProtocol {
        let total: Int
        let cancelAt: Int?
        let count: ProbeCount
        mutating func next() async throws -> UInt8? {
            guard count.pulled < total else { return nil }
            count.pulled += 1
            if count.pulled == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
            return UInt8(truncatingIfNeeded: count.pulled)
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(total: total, cancelAt: cancelAt, count: count) }
}

/// Answers the production URLSession in-process: no socket is opened.
final class StubTransport: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < Self.body.count {
            let end = min(offset + 64 * 1024, Self.body.count)
            client?.urlProtocol(self, didLoad: Self.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct CheckPreview {
    @MainActor static func main() async throws {
        typealias Sources = SteamInputCommunitySources
        let tempRoot = URL(fileURLWithPath: CommandLine.arguments[1])

        let communityRoot = tempRoot.appendingPathComponent("SteamInputCommunity", isDirectory: true)
        let personalRoot = tempRoot.appendingPathComponent("SteamInputPersonal", isDirectory: true)
        let selectionRoot = tempRoot.appendingPathComponent("SteamInputSelection", isDirectory: true)
        let journalRoot = tempRoot.appendingPathComponent("SteamInputJournal", isDirectory: true)

        try FileManager.default.createDirectory(at: communityRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectionRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)

        // Seed pre-existing files across all isolated roots
        let seed1 = communityRoot.appendingPathComponent("preexisting_comm.bin")
        let seed2 = personalRoot.appendingPathComponent("preexisting_pers.bin")
        let seed3 = selectionRoot.appendingPathComponent("preexisting_sel.bin")
        let seed4 = journalRoot.appendingPathComponent("preexisting_journ.bin")

        try Data("seed_community_data_12345".utf8).write(to: seed1)
        try Data("seed_personal_data_67890".utf8).write(to: seed2)
        try Data("seed_selection_data_abcde".utf8).write(to: seed3)
        try Data("seed_journal_data_fghij".utf8).write(to: seed4)

        func snapshotTree(_ rootURL: URL) throws -> [String: String] {
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
            var snapshot: [String: String] = [:]
            for case let fileURL as URL in enumerator {
                let res = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if res.isRegularFile == true {
                    let relPath = fileURL.path.replacingOccurrences(of: rootURL.path, with: "")
                    let data = try Data(contentsOf: fileURL)
                    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    snapshot[relPath] = hash
                }
            }
            return snapshot
        }

        let baselineSnapshot = try snapshotTree(tempRoot)
        require(baselineSnapshot.count == 4, "baseline snapshot should contain 4 seeded files")

        // -------------------------------------------------------------
        // FIXTURES
        // -------------------------------------------------------------
        // Multi-set fixture: Game maps Cross to A; Menu maps Cross to Escape
        let multiSetVDF = Data("""
        "controller_mappings"
        {
            "version" "3"
            "revision" "10"
            "title" "Multi-Set Game Layout"
            "controller_type" "controller_ps5"
            "actions"
            {
                "Game" { "title" "Game Mode" "legacy_set" "0" }
                "Menu" { "title" "Menu Mode" "legacy_set" "0" }
            }
            "group"
            {
                "id" "0"
                "mode" "four_buttons"
                "inputs"
                {
                    "button_a"
                    {
                        "activators"
                        {
                            "Full_Press" { "bindings" { "binding" "xinput_button A, Jump" } }
                        }
                    }
                }
            }
            "group"
            {
                "id" "1"
                "mode" "four_buttons"
                "inputs"
                {
                    "button_a"
                    {
                        "activators"
                        {
                            "Full_Press" { "bindings" { "binding" "key_press ESCAPE, Cancel" } }
                        }
                    }
                }
            }
            "preset"
            {
                "id" "0"
                "name" "Game"
                "group_source_bindings" { "0" "button_diamond active" }
            }
            "preset"
            {
                "id" "1"
                "name" "Menu"
                "group_source_bindings" { "1" "button_diamond active" }
            }
        }
        """.utf8)

        // Action Layer fixture: Overrides left_trigger and adds gyro while inheriting face buttons
        let layerVDF = Data("""
        "controller_mappings"
        {
            "version" "3"
            "revision" "11"
            "title" "Layer Test Layout"
            "controller_type" "controller_ps5"
            "actions"
            {
                "Game" { "title" "Game" }
            }
            "action_layers"
            {
                "Sniper"
                {
                    "title" "Sniper Layer"
                    "parent_set_name" "Game"
                }
            }
            "group"
            {
                "id" "0"
                "mode" "four_buttons"
                "inputs"
                {
                    "button_a"
                    {
                        "activators" { "Full_Press" { "bindings" { "binding" "xinput_button A" } } }
                    }
                }
            }
            "group"
            {
                "id" "1"
                "mode" "trigger"
                "settings" { "deadzone" "15" }
                "inputs"
                {
                    "trigger_left"
                    {
                        "activators" { "Full_Press" { "bindings" { "binding" "xinput_button trigger_left" } } }
                    }
                }
            }
            "group"
            {
                "id" "2"
                "mode" "trigger"
                "settings" { "deadzone" "5" }
                "inputs"
                {
                    "trigger_left"
                    {
                        "activators" { "Full_Press" { "bindings" { "binding" "mouse_button right, Zoom" } } }
                    }
                }
            }
            "preset"
            {
                "id" "0"
                "name" "Game"
                "group_source_bindings"
                {
                    "0" "button_diamond active"
                    "1" "left_trigger active"
                }
            }
            "preset"
            {
                "id" "2"
                "name" "Sniper"
                "group_source_bindings"
                {
                    "2" "left_trigger active"
                }
            }
        }
        """.utf8)

        // Inactive gyro fixture: group 13 is gyro, but bound as inactive
        let inactiveGyroVDF = Data("""
        "controller_mappings"
        {
            "version" "3"
            "revision" "12"
            "title" "Inactive Gyro Layout"
            "controller_type" "controller_ps5"
            "group"
            {
                "id" "10"
                "mode" "joystick_move"
            }
            "group"
            {
                "id" "13"
                "mode" "joystick_move"
                "settings" { "gyro_sensitivity" "40" }
            }
            "preset"
            {
                "id" "0"
                "name" "Default"
                "group_source_bindings"
                {
                    "10" "joystick active"
                    "13" "gyro inactive"
                }
            }
        }
        """.utf8)

        // Active gyro fixture: group 13 is gyro, bound as active
        let activeGyroVDF = Data("""
        "controller_mappings"
        {
            "version" "3"
            "revision" "12"
            "title" "Active Gyro Layout"
            "controller_type" "controller_ps5"
            "group"
            {
                "id" "10"
                "mode" "joystick_move"
            }
            "group"
            {
                "id" "13"
                "mode" "joystick_move"
                "settings" { "gyro_sensitivity" "40" }
            }
            "preset"
            {
                "id" "0"
                "name" "Default"
                "group_source_bindings"
                {
                    "10" "joystick active"
                    "13" "gyro active"
                }
            }
        }
        """.utf8)

        // Custom blocks, unknown settings, and repeated unknown keys with nested content
        let unknownContentVDF = Data("""
        "controller_mappings"
        {
            "version" "3"
            "revision" "13"
            "title" "Unknown Content Layout"
            "controller_type" "controller_ps5"
            "custom_vendor_block"
            {
                "vendor_id" "0x1234"
                "nested_block"
                {
                    "secret_value" "456"
                }
            }
            "unknown_global_setting" "alpha"
            "unknown_repeated_key" "first_value"
            "unknown_repeated_key" "second_value"
            "group"
            {
                "id" "0"
                "mode" "four_buttons"
                "unknown_group_setting" "gamma"
                "inputs"
                {
                    "button_a"
                    {
                        "activators"
                        {
                            "Full_Press"
                            {
                                "bindings" { "binding" "xinput_button A" }
                                "unknown_activator_prop" "delta"
                            }
                        }
                    }
                }
            }
            "preset"
            {
                "id" "0"
                "name" "Default"
                "unknown_preset_setting" "epsilon"
                "group_source_bindings" { "0" "button_diamond active" }
            }
        }
        """.utf8)

        // Missing group reference fixture: preset references group 999 which does not exist
        let missingGroupVDF = Data("""
        "controller_mappings"
        {
            "version" "3"
            "revision" "15"
            "title" "Missing Group Reference Layout"
            "controller_type" "controller_ps5"
            "preset"
            {
                "id" "0"
                "name" "Default"
                "group_source_bindings"
                {
                    "999" "button_diamond active"
                }
            }
        }
        """.utf8)

        // Strict preset resolution fixture: action set "Other" with no matching preset
        let strictResolutionVDF = Data("""
        "controller_mappings"
        {
            "version" "3"
            "revision" "16"
            "title" "Strict Resolution Layout"
            "controller_type" "controller_ps5"
            "actions"
            {
                "Other" { "title" "Other Mode" }
            }
            "group"
            {
                "id" "0"
                "mode" "four_buttons"
                "inputs"
                {
                    "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "xinput_button A" } } } }
                }
            }
            "preset"
            {
                "id" "0"
                "name" "Game"
                "group_source_bindings" { "0" "button_diamond active" }
            }
        }
        """.utf8)

        // Fixture with ONLY Action Set conditional
        let setOnlyCondVDF = Data("""
        "controller_mappings"
        {
            "version" "3"
            "revision" "17"
            "title" "Conditional Set Only"
            "controller_type" "controller_ps5"
            "actions"
            {
                "Game" { "title" "Game" } [$WIN32]
            }
            "group"
            {
                "id" "0"
                "mode" "four_buttons"
                "inputs"
                {
                    "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "xinput_button A" } } } }
                }
            }
            "preset"
            {
                "id" "0"
                "name" "Game"
                "group_source_bindings" { "0" "button_diamond active" }
            }
        }
        """.utf8)

        // Fixture with ONLY Action Layer conditional
        let layerOnlyCondVDF = Data("""
        "controller_mappings"
        {
            "version" "3"
            "revision" "18"
            "title" "Conditional Layer Only"
            "controller_type" "controller_ps5"
            "actions"
            {
                "Game" { "title" "Game" }
            }
            "action_layers"
            {
                "Sniper"
                {
                    "title" "Sniper"
                    "parent_set_name" "Game"
                } [$OSX]
            }
            "group"
            {
                "id" "0"
                "mode" "four_buttons"
                "inputs"
                {
                    "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "xinput_button A" } } } }
                }
            }
            "preset"
            {
                "id" "0"
                "name" "Game"
                "group_source_bindings" { "0" "button_diamond active" }
            }
            "preset"
            {
                "id" "1"
                "name" "Sniper"
                "group_source_bindings" { "0" "button_diamond active" }
            }
        }
        """.utf8)

        // Comprehensive multi-level conditions fixture
        let multiLevelCondVDF = Data("""
        "controller_mappings" [$GLOBAL]
        {
            "version" "3"
            "revision" "19"
            "title" "Multi-Level Conditions Layout"
            "controller_type" "controller_ps5"
            "actions"
            {
                "Game" { "title" "Game" } [$ACTION_SET]
            }
            "group" [$GROUP_COND]
            {
                "id" "0"
                "mode" "four_buttons"
                "inputs"
                {
                    "button_a" [$INPUT_COND]
                    {
                        "activators"
                        {
                            "Full_Press" [$ACT_COND]
                            {
                                "bindings"
                                {
                                    "binding" "xinput_button A" [$LEAF_COND]
                                }
                            }
                        }
                    }
                }
            }
            "preset" [$PRESET_COND]
            {
                "id" "0"
                "name" "Game"
                "group_source_bindings"
                {
                    "0" "button_diamond active" [$SRC_BIND_COND]
                }
            }
        }
        """.utf8)

        // A distinct condition on every container AND on its child, at each
        // place the domain parser attaches conditions.
        let pairedConditionsText = """
        "controller_mappings"
        {
            "version" "3"
            "revision" "20"
            "title" "Container And Child Conditions"
            "controller_type" "controller_ps5"
            "actions"
            {
                "Game" { "title" "Game" "legacy_set" "1" }
            }
            "group"
            {
                "id" "0"
                "mode" "four_buttons"
                "inputs"
                {
                    "button_a"
                    {
                        "activators"
                        {
                            "Full_Press"
                            {
                                "bindings"
                                {
                                    "binding" "xinput_button A" [$BINDING_LEAF]
                                    "binding" "key_press SPACE"
                                } [$BINDINGS_BOX]
                            } [$ACTIVATOR]
                        } [$ACTIVATORS_BOX]
                    } [$INPUT]
                } [$INPUTS_BOX]
            }
            "preset"
            {
                "id" "0"
                "name" "Game"
                "group_source_bindings"
                {
                    "0" "button_diamond active" [$SOURCE_LEAF]
                } [$SOURCES_BOX]
            }
        }
        """

        // Conditions that no binding carries: on plain properties, on a block
        // from both sides, on a setting and on a container with no children.
        let strayConditionsText = """
        "controller_mappings"
        {
            "title" "Stray Conditions" [$TITLE]
            "controller_type" "controller_ps5"
            "group"
            {
                "id" "0"
                "mode" "four_buttons" [$MODE]
                "inputs"
                {
                    "button_a"
                    {
                        "activators"
                        {
                            "Full_Press"
                            {
                                "bindings" [$PRE] { "binding" "xinput_button A" } [$POST]
                                "settings" { "toggle" "1" [$TOGGLE] }
                            }
                            "Long_Press" { "bindings" { } [$EMPTY_BOX] }
                        }
                    }
                }
            }
            "preset"
            {
                "id" "0"
                "name" "Default"
                "group_source_bindings" { "0" "button_diamond active" }
            }
        }
        "stray_root_block" { "k" "v" }
        """

        func makeItem(id: UInt64, appID: UInt32 = 480, size: Int = multiSetVDF.count, timeUpdated: UInt32 = 100, controllerTag: String = "controller_ps5") -> SteamWorkshopItem {
            var item = SteamWorkshopItem(id: id, appID: 241100, result: 1)
            item.title = "Item \(id)"
            item.fileURL = "https://ugc.steamusercontent.com/test/\(id).vdf"
            item.fileSize = UInt64(size)
            item.timeUpdated = timeUpdated
            item.fileType = 12
            item.tags = [controllerTag, "controller_native"]
            item.kvTags = [
                .init(key: "app", value: String(appID)),
                .init(key: "visibility", value: "public"),
                .init(key: "deleted", value: "0")
            ]
            return item
        }

        var itemLookup: [UInt64: SteamWorkshopItem] = [:]
        var payloadToDownload = multiSetVDF
        let networkFail = false

        let sources = Sources(root: communityRoot, query: { _, _, _, _ in
            fatalError("query not called in preview")
        }, details: { ids in
            return ids.compactMap { itemLookup[$0] }
        }, download: { url in
            if networkFail { throw Sources.Failure.unavailable }
            return payloadToDownload
        })

        // =============================================================
        // TEST 1: Action-Set and Layer Mapping Resolution
        // =============================================================
        payloadToDownload = multiSetVDF
        let itemMulti = makeItem(id: 2001, size: multiSetVDF.count)
        itemLookup[itemMulti.id] = itemMulti
        let previewMulti = try await sources.preview(appID: 480, item: itemMulti)

        require(previewMulti.actionSets.count == 2, "must resolve 2 action sets")
        let gameSet = previewMulti.actionSets.first { $0.id == "Game" }!
        let menuSet = previewMulti.actionSets.first { $0.id == "Menu" }!

        let gameCross = gameSet.regions.first { $0.id == "diamond" }?.inputs.first { $0.inputName.contains("Cross") }
        let menuCross = menuSet.regions.first { $0.id == "diamond" }?.inputs.first { $0.inputName.contains("Cross") }

        require(gameCross != nil, "Game mode has Cross input")
        require(menuCross != nil, "Menu mode has Cross input")
        require(gameCross!.activators.first?.bindings.first?.displayText.contains("A (Cross)") == true, "Game mode maps Cross to A")
        require(menuCross!.activators.first?.bindings.first?.displayText.contains("Escape") == true, "Menu mode maps Cross to Escape")

        // =============================================================
        // TEST 2: Action Layers Overriding Non-Face-Button Regions & Inheriting
        // =============================================================
        payloadToDownload = layerVDF
        let itemLayer = makeItem(id: 2002, size: layerVDF.count)
        itemLookup[itemLayer.id] = itemLayer
        let previewLayer = try await sources.preview(appID: 480, item: itemLayer)

        require(previewLayer.actionSets.count == 2, "has base set and layer")
        let sniperLayer = previewLayer.actionSets.first { $0.id == "Sniper" }!
        require(sniperLayer.isLayer, "sniper view is a layer")
        require(sniperLayer.parentSetID == "Game", "parent set is Game")

        let sniperTriggers = sniperLayer.regions.first { $0.id == "triggers" }
        require(sniperTriggers != nil, "sniper layer has trigger region")
        let sniperLeftTrigger = sniperTriggers?.inputs.first { $0.inputName.contains("L2") || $0.inputName.contains("Trigger") }
        require(sniperLeftTrigger != nil, "sniper overrides left trigger")
        require(sniperLeftTrigger!.isLayerOverride == true, "marked as layer override")
        require(sniperLeftTrigger!.activators.first?.bindings.first?.displayText.contains("Right Click") == true, "overridden to Right Click")

        // Inherited Face Buttons in sniper layer
        let sniperDiamond = sniperLayer.regions.first { $0.id == "diamond" }
        require(sniperDiamond != nil, "inherited diamond region exists")
        let inheritedCross = sniperDiamond?.inputs.first { $0.inputName.contains("Cross") }
        require(inheritedCross != nil, "inherited Cross exists in layer")
        require(inheritedCross!.isInherited == true, "marked as inherited")

        // =============================================================
        // TEST 3: Hardware Limitations exclusively from Enabled (isActive) Bindings
        // =============================================================
        // 3a. Inactive gyro: group defined but preset binds "gyro inactive" -> no gyro diagnosis
        payloadToDownload = inactiveGyroVDF
        let itemInactiveGyro = makeItem(id: 2003, size: inactiveGyroVDF.count)
        itemLookup[itemInactiveGyro.id] = itemInactiveGyro
        let previewInactiveGyro = try await sources.preview(appID: 480, item: itemInactiveGyro)
        require(!previewInactiveGyro.diagnoses.contains { $0.id == "diag-gyro" }, "inactive gyro binding must NOT trigger gyro hardware warning")
        let hwDiags = previewInactiveGyro.diagnoses.filter { $0.category == .unavailableHardware }
        require(hwDiags.isEmpty, "no unavailable hardware diagnoses when gyro is inactive")

        // 3b. Active gyro: preset binds "gyro active" -> diag-gyro generated
        payloadToDownload = activeGyroVDF
        let itemActiveGyro = makeItem(id: 2004, size: activeGyroVDF.count)
        itemLookup[itemActiveGyro.id] = itemActiveGyro
        let previewActiveGyro = try await sources.preview(appID: 480, item: itemActiveGyro)
        require(previewActiveGyro.diagnoses.contains { $0.id == "diag-gyro" }, "active gyro binding MUST trigger gyro hardware diagnosis")

        // =============================================================
        // TEST 4: Unknown Content Fallback with Nested Blocks & Deterministic IDs
        // =============================================================
        payloadToDownload = unknownContentVDF
        let itemUnknown = makeItem(id: 2005, size: unknownContentVDF.count)
        itemLookup[itemUnknown.id] = itemUnknown
        let previewUnknown = try await sources.preview(appID: 480, item: itemUnknown)

        require(previewUnknown.uninterpretedEntries.count >= 4, "captures custom block, settings, and repeated unknown keys")
        let vendorBlock = previewUnknown.uninterpretedEntries.first { $0.key == "custom_vendor_block" }
        require(vendorBlock != nil, "custom block captured in uninterpretedEntries")
        require(vendorBlock!.rawContent.contains("0x1234"), "vendor rawContent contains 0x1234")
        require(vendorBlock!.rawContent.contains("456"), "vendor rawContent contains nested secret 456")
        require(vendorBlock!.children.contains { $0.key == "nested_block" }, "nested unknown block captured in children")

        let repeatedKeys = previewUnknown.uninterpretedEntries.filter { $0.key == "unknown_repeated_key" }
        require(repeatedKeys.count == 2, "repeated unknown keys preserved in order")
        require(repeatedKeys[0].id != repeatedKeys[1].id, "repeated unknown keys have distinct deterministic IDs")
        require(repeatedKeys[0].rawContent.contains("first_value") && repeatedKeys[1].rawContent.contains("second_value"), "repeated keys values preserved")

        let unrecDiags = previewUnknown.diagnoses.filter { $0.title.contains("Uninterpreted Content") }
        require(!unrecDiags.isEmpty, "viewer limitation diagnostics generated for uninterpreted content")
        require(!previewUnknown.isFullyCompatible, "layout with uninterpreted content cannot be fully compatible")

        // =============================================================
        // TEST 5: Missing Group Reference Surface
        // =============================================================
        payloadToDownload = missingGroupVDF
        let itemMissing = makeItem(id: 2006, size: missingGroupVDF.count)
        itemLookup[itemMissing.id] = itemMissing
        let previewMissing = try await sources.preview(appID: 480, item: itemMissing)

        require(!previewMissing.isFullyCompatible, "missing group reference makes layout incompatible")
        let missingDiags = previewMissing.diagnoses.filter { $0.category == .unresolvedReference && $0.id.contains("999") }
        require(!missingDiags.isEmpty, "unresolved reference diagnosis generated for missing group 999")
        let missingInput = previewMissing.actionSets.first?.regions.first { $0.id == "diamond" }?.inputs.first { $0.isMissingReference }
        require(missingInput != nil, "inspectable placeholder input mapping inserted for missing group")
        require(missingInput!.inputName.contains("Missing Group [999]"), "placeholder input displays missing group ID")

        // =============================================================
        // TEST 6: Strict Preset Resolution (No positional fallback)
        // =============================================================
        payloadToDownload = strictResolutionVDF
        let itemStrict = makeItem(id: 2007, size: strictResolutionVDF.count)
        itemLookup[itemStrict.id] = itemStrict
        let previewStrict = try await sources.preview(appID: 480, item: itemStrict)

        require(!previewStrict.isFullyCompatible, "unresolved preset makes layout incompatible")
        let unresPresetDiags = previewStrict.diagnoses.filter { $0.id == "diag-unres-set-preset-Other" }
        require(!unresPresetDiags.isEmpty, "unresolved preset diagnosis generated for unmatched action set 'Other'")
        let otherSet = previewStrict.actionSets.first { $0.id == "Other" }!
        let otherButtons = otherSet.regions.first { $0.id == "diamond" }?.inputs ?? []
        require(otherButtons.isEmpty, "unmatched action set must NOT inherit guessed mappings from Game preset")

        // =============================================================
        // TEST 7: Condition Preservation Context (Set ONLY, Layer ONLY, Nested)
        // =============================================================
        let expectedConditionWarning = "Condition not evaluated by this preview; current apply validation rejects conditional layouts."

        // 7a. ONLY Action Set is conditional
        payloadToDownload = setOnlyCondVDF
        let itemSetCond = makeItem(id: 2008, size: setOnlyCondVDF.count)
        itemLookup[itemSetCond.id] = itemSetCond
        let previewSetCond = try await sources.preview(appID: 480, item: itemSetCond)

        require(!previewSetCond.isFullyCompatible, "conditional action set makes layout incompatible")
        let setDiags = previewSetCond.diagnoses.filter { $0.id.contains("diag-cond-set-Game") }
        require(!setDiags.isEmpty, "action set condition generates diagnosis")
        require(setDiags.first!.detail == expectedConditionWarning, "mandated condition warning wording")
        let setInput = previewSetCond.actionSets.first?.regions.first { $0.id == "diamond" }?.inputs.first
        require(setInput?.conditions.contains { $0.expression == "[$WIN32]" } == true, "action set condition propagated to input mappings")

        // 7b. ONLY Action Layer is conditional
        payloadToDownload = layerOnlyCondVDF
        let itemLayerCond = makeItem(id: 2009, size: layerOnlyCondVDF.count)
        itemLookup[itemLayerCond.id] = itemLayerCond
        let previewLayerCond = try await sources.preview(appID: 480, item: itemLayerCond)

        require(!previewLayerCond.isFullyCompatible, "conditional action layer makes layout incompatible")
        let layerDiags = previewLayerCond.diagnoses.filter { $0.id.contains("diag-cond-layer-Sniper") }
        require(!layerDiags.isEmpty, "action layer condition generates diagnosis")
        require(layerDiags.first!.detail == expectedConditionWarning, "mandated condition warning wording")
        let layerInput = previewLayerCond.actionSets.first { $0.id == "Sniper" }?.regions.first { $0.id == "diamond" }?.inputs.first
        require(layerInput?.conditions.contains { $0.expression == "[$OSX]" } == true, "action layer condition propagated to layer input mappings")

        // 7c. Multi-Level Nested Conditions (No condition lost to ??)
        payloadToDownload = multiLevelCondVDF
        let itemNestedCond = makeItem(id: 2010, size: multiLevelCondVDF.count)
        itemLookup[itemNestedCond.id] = itemNestedCond
        let previewNestedCond = try await sources.preview(appID: 480, item: itemNestedCond)

        require(!previewNestedCond.isFullyCompatible, "multi-level conditional layout is incompatible")
        let nestedDiags = previewNestedCond.diagnoses.filter { $0.title.contains("Condition") }
        require(nestedDiags.count >= 6, "diagnoses generated across all levels")
        for d in nestedDiags {
            require(d.detail == expectedConditionWarning, "mandated warning on all levels")
        }

        let nestedInput = previewNestedCond.actionSets.first?.regions.first { $0.id == "diamond" }?.inputs.first
        require(nestedInput != nil, "nested input exists")
        let nestedBinding = nestedInput!.activators.first?.bindings.first
        require(nestedBinding != nil, "nested binding exists")
        let expressions = Set(nestedBinding!.conditions.map(\.expression))
        require(expressions.contains("[$GLOBAL]"), "global condition preserved")
        require(expressions.contains("[$ACTION_SET]"), "action set condition preserved")
        require(expressions.contains("[$PRESET_COND]"), "preset condition preserved")
        require(expressions.contains("[$SRC_BIND_COND]"), "source binding condition preserved")
        require(expressions.contains("[$GROUP_COND]"), "group condition preserved")
        require(expressions.contains("[$INPUT_COND]"), "input condition preserved")
        require(expressions.contains("[$ACT_COND]"), "activator condition preserved")
        require(expressions.contains("[$LEAF_COND]"), "leaf condition preserved")

        // 7d. Container AND child conditions at every attachment point
        func buildPreview(_ text: String) throws -> SteamInputPreviewData {
            SteamInputPreviewData(model: try SteamInputLayoutModel(document: try VDFDocument.parse(Data(text.utf8))))
        }
        func pairs(_ conditions: [SteamInputPreviewData.SourceCondition]) -> [String] {
            conditions.map { "\($0.scope)=\($0.expression)" }
        }
        func firstInput(_ preview: SteamInputPreviewData) -> SteamInputPreviewData.InputMappingView {
            preview.actionSets[0].regions.first { $0.id == "diamond" }!.inputs[0]
        }
        let pairedChain = [
            "Source Bindings Container=[$SOURCES_BOX]", "Source Binding 'button_diamond'=[$SOURCE_LEAF]",
            "Inputs Container=[$INPUTS_BOX]", "Input 'button_a'=[$INPUT]",
            "Activators Container=[$ACTIVATORS_BOX]", "Activator 'Full_Press'=[$ACTIVATOR]",
            "Bindings Container=[$BINDINGS_BOX]", "Binding=[$BINDING_LEAF]",
        ]
        let pairedExpressions = pairedChain.map { String($0[$0.firstIndex(of: "=")!...].dropFirst()) }

        let pairedModel = try SteamInputLayoutModel(document: try VDFDocument.parse(Data(pairedConditionsText.utf8)))
        let pairedInputModel = pairedModel.groups["0"]!.inputs[0]
        require(pairs(pairedModel.presets[0].bindings[0].conditions) == Array(pairedChain[0..<2]), "domain source binding keeps its container's condition and its own")
        require(pairs(pairedInputModel.conditions) == Array(pairedChain[2..<4]), "domain input keeps the inputs container's condition and its own")
        require(pairs(pairedInputModel.activators[0].conditions) == Array(pairedChain[4..<6]), "domain activator keeps the activators container's condition and its own")
        require(pairs(pairedInputModel.activators[0].bindings[0].conditions) == Array(pairedChain[6..<8]), "domain binding keeps the bindings container's condition and its own")
        require(pairs(pairedInputModel.activators[0].bindings[1].conditions) == [pairedChain[6]], "a sibling binding keeps the container's condition without the other leaf's")
        require(pairedModel.conditionSites.map(\.condition.expression) == [
            "[$INPUTS_BOX]", "[$INPUT]", "[$ACTIVATORS_BOX]", "[$ACTIVATOR]", "[$BINDINGS_BOX]", "[$BINDING_LEAF]", "[$SOURCES_BOX]", "[$SOURCE_LEAF]",
        ], "each condition is recorded once, in source order")

        let pairedPreview = SteamInputPreviewData(model: pairedModel)
        let pairedInput = firstInput(pairedPreview)
        require(pairs(pairedInput.conditions) == Array(pairedChain[0..<4]), "input row carries every enclosing condition with its scope")
        require(pairs(pairedInput.activators[0].conditions) == Array(pairedChain[0..<6]), "activator row carries every enclosing condition with its scope")
        require(pairs(pairedInput.activators[0].bindings[0].conditions) == pairedChain, "binding carries all eight conditions, outermost first, none merged")
        require(pairs(pairedInput.activators[0].bindings[1].conditions) == Array(pairedChain[0..<7]), "unconditional sibling still carries its seven enclosing conditions")
        require(pairedPreview.unevaluatedConditions.count == 8 && !pairedPreview.isFullyCompatible, "eight unevaluated conditions block the compatibility claim")
        for expression in pairedExpressions {
            let matching = pairedPreview.diagnoses.filter { $0.title.hasSuffix(": \(expression)") }
            require(matching.count == 1, "exactly one diagnosis for \(expression)")
            require(matching[0].detail == expectedConditionWarning && matching[0].category == .viewerOrRuntimeLimitation, "mandated wording for \(expression)")
        }
        require(Set(pairedPreview.diagnoses.map(\.id)).count == pairedPreview.diagnoses.count, "condition diagnoses have distinct identifiers")
        require(pairedPreview.diagnoses.count == 8, "conditions are the only diagnoses of this layout")

        // Without its conditions the same layout is compatible, so each single
        // condition below is the sole reason the claim is withheld.
        func keeping(_ kept: String?) -> String {
            pairedExpressions.filter { $0 != kept }.reduce(pairedConditionsText) { $0.replacingOccurrences(of: " " + $1, with: "") }
        }
        let unconditional = try buildPreview(keeping(nil))
        require(unconditional.isFullyCompatible && unconditional.diagnoses.isEmpty && unconditional.unevaluatedConditions.isEmpty,
                "the unconditional layout, including a legacy action set, is fully compatible")
        require(firstInput(unconditional).activators[0].bindings[0].conditions.isEmpty, "no condition is invented")
        for (index, expression) in pairedExpressions.enumerated() {
            let single = try buildPreview(keeping(expression))
            require(!single.isFullyCompatible, "\(expression) alone prevents an unconditional compatibility claim")
            require(single.unevaluatedConditions.map(\.condition.expression) == [expression], "\(expression) alone is recorded once")
            require(single.diagnoses.count == 1 && single.diagnoses[0].detail == expectedConditionWarning, "\(expression) alone yields the mandated diagnosis")
            require(pairs(firstInput(single).activators[0].bindings[0].conditions) == [pairedChain[index]], "\(expression) alone reaches the binding with its scope")
        }

        // 7e. Conditions no binding carries are still recorded, never dropped
        let strayPreview = try buildPreview(strayConditionsText)
        require(strayPreview.unevaluatedConditions.map(\.condition.expression) == ["[$TITLE]", "[$MODE]", "[$PRE]", "[$POST]", "[$TOGGLE]", "[$EMPTY_BOX]"],
                "property, doubled, setting and empty-container conditions are all recorded")
        require(strayPreview.unevaluatedConditions.map(\.condition.scope) == [
            "Property 'title'", "Property 'mode'", "Bindings Container", "Bindings Container", "Setting 'toggle'", "Bindings Container",
        ], "each recorded condition names the node it is written on")
        require(pairs(firstInput(strayPreview).activators[0].bindings[0].conditions) == ["Bindings Container=[$PRE]", "Bindings Container=[$POST]"],
                "a block conditioned on both sides keeps both")
        for site in strayPreview.unevaluatedConditions {
            require(strayPreview.diagnoses.contains { $0.title.hasSuffix(": \(site.condition.expression)") && $0.detail == expectedConditionWarning },
                    "diagnosis for \(site.condition.expression)")
        }
        require(strayPreview.uninterpretedEntries.contains { $0.key == "stray_root_block" }, "content beside controller_mappings is shown as uninterpreted")
        require(!strayPreview.isFullyCompatible, "stray conditions block the compatibility claim")

        // 7f. The apply barrier is untouched: conditional layouts stay rejected
        func applyValidation(_ text: String) -> Bool? {
            do { return try SteamInputCompatibility(Data(text.utf8), tags: ["controller_ps5"]).canApply } catch { return nil }
        }
        require(applyValidation(keeping(nil)) == true, "the unconditional layout passes apply validation")
        require(applyValidation(pairedConditionsText) == nil, "apply validation still rejects the conditional layout")
        for expression in pairedExpressions {
            require(applyValidation(keeping(expression)) == nil, "apply validation still rejects a layout whose only condition is \(expression)")
        }

        // =============================================================
        // TEST 8: Transport Validation Seam (Redirects & Streaming Overflow)
        // =============================================================
        // 8a. SteamInputDefaultRedirects unit test
        let redirectDelegate = SteamInputDefaultRedirects()
        let fakeResponse = HTTPURLResponse(url: URL(string: "https://ugc.steamusercontent.com/original.vdf")!, statusCode: 302, httpVersion: nil, headerFields: nil)!

        var disallowedHandled = false
        redirectDelegate.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "https://example.com")!), willPerformHTTPRedirection: fakeResponse, newRequest: URLRequest(url: URL(string: "http://ugc.steamusercontent.com/downgrade.vdf")!)) { req in
            require(req == nil, "HTTP downgrade redirect MUST pass nil completionHandler")
            disallowedHandled = true
        }
        require(disallowedHandled, "disallowed HTTP redirect callback invoked")

        var nonCDNHandled = false
        redirectDelegate.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "https://example.com")!), willPerformHTTPRedirection: fakeResponse, newRequest: URLRequest(url: URL(string: "https://evil.attacker.com/steal.vdf")!)) { req in
            require(req == nil, "non-CDN redirect MUST pass nil completionHandler")
            nonCDNHandled = true
        }
        require(nonCDNHandled, "non-CDN redirect callback invoked")

        var cdnHandled = false
        let validCDNURL = URL(string: "https://ugc.steamusercontent.com/next.vdf")!
        redirectDelegate.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "https://example.com")!), willPerformHTTPRedirection: fakeResponse, newRequest: URLRequest(url: validCDNURL)) { req in
            require(req?.url == validCDNURL, "valid CDN redirect MUST pass permitted request")
            cdnHandled = true
        }
        require(cdnHandled, "valid CDN redirect callback invoked")

        // 8b. Production bounded consumption: the helper fetchBytes streams through
        let byteLimit = Sources.limit
        require(byteLimit == (1 << 20) - 1 && byteLimit == VDFDocument.maxBytes, "download and parser limits agree")
        func collect(total: Int, limit: Int, cancelAt: Int? = nil) async -> (outcome: String, pulled: Int, bytes: Data?) {
            let count = ProbeCount()
            let work = Task {
                try await SteamInputDefaultSources.collect(ProbeStream(total: total, cancelAt: cancelAt, count: count), limit: limit)
            }
            do { let bytes = try await work.value; return ("ok", count.pulled, bytes) }
            catch SteamInputDefaultSources.Failure.invalid { return ("invalid", count.pulled, nil) }
            catch is CancellationError { return ("cancelled", count.pulled, nil) }
            catch { return ("other: \(error)", count.pulled, nil) }
        }
        for limit in [1, 4096, byteLimit] {
            let exact = await collect(total: limit, limit: limit)
            require(exact.outcome == "ok" && exact.bytes?.count == limit && exact.pulled == limit, "exactly \(limit) bytes are accepted in full")
            require(exact.bytes?.first == 1 && exact.bytes?.last == UInt8(truncatingIfNeeded: limit), "accepted bytes are kept in order")
            let over = await collect(total: limit + 1, limit: limit)
            require(over.outcome == "invalid" && over.pulled == limit + 1, "one byte over \(limit) is rejected on that byte")
            let flood = await collect(total: limit + 100_000, limit: limit)
            require(flood.outcome == "invalid" && flood.pulled == limit + 1, "consumption stops at the first excess byte instead of draining the body")
        }
        let empty = await collect(total: 0, limit: byteLimit)
        require(empty.outcome == "ok" && empty.bytes?.isEmpty == true, "an empty body is passed through for the caller's size check")
        let cancelled = await collect(total: 10_000, limit: byteLimit, cancelAt: 100)
        require(cancelled.outcome == "cancelled" && cancelled.pulled == 100, "cancellation during consumption stops before another byte is read")
        let cancelledAtLimit = await collect(total: 4097, limit: 4096, cancelAt: 4097)
        require(cancelledAtLimit.outcome == "cancelled", "cancellation is reported as cancellation even on the excess byte")

        // 8c. The same limit through the real fetchBytes session, answered in-process
        let stubURL = URL(string: "https://ugc.steamusercontent.com/test/stream.vdf")!
        func fetch(_ url: URL, body: Int, headers: [String: String] = [:]) async -> (outcome: String, bytes: Data?) {
            StubTransport.body = Data((0..<body).map { UInt8(truncatingIfNeeded: $0) })
            StubTransport.headers = headers
            do { return ("ok", try await SteamInputDefaultSources.fetchBytes(url, protocols: [StubTransport.self])) }
            catch SteamInputDefaultSources.Failure.invalid { return ("invalid", nil) }
            catch SteamInputDefaultSources.Failure.unavailable { return ("unavailable", nil) }
            catch { return ("other: \(error)", nil) }
        }
        let wireExact = await fetch(stubURL, body: byteLimit)
        require(wireExact.outcome == "ok" && wireExact.bytes == StubTransport.body, "fetchBytes returns a body of exactly the limit unchanged")
        let wireOver = await fetch(stubURL, body: byteLimit + 1)
        require(wireOver.outcome == "invalid", "fetchBytes rejects an undeclared body one byte over the limit while streaming")
        let wireDeclared = await fetch(stubURL, body: 16, headers: ["Content-Length": String(byteLimit + 1)])
        require(wireDeclared.outcome == "unavailable", "fetchBytes still refuses a declared length over the limit before reading")
        let requestsBefore = StubTransport.requests
        require(requestsBefore == 3, "each stubbed fetch reached the in-process transport once")
        let wireForeign = await fetch(URL(string: "https://example.com/layout.vdf")!, body: 16)
        require(wireForeign.outcome == "invalid" && StubTransport.requests == requestsBefore, "a non-CDN URL is refused before any request is made")

        // =============================================================
        // TEST 9: Preview Presentation State (the model the view binds to)
        // =============================================================
        let slowItem = makeItem(id: 4001, size: layerVDF.count)       // "Layer Test Layout"
        let fastItem = makeItem(id: 4002, size: multiSetVDF.count)    // "Multi-Set Game Layout"
        itemLookup[slowItem.id] = slowItem
        itemLookup[fastItem.id] = fastItem
        let itemPayloads: [UInt64: Data] = [4001: layerVDF, 4002: multiSetVDF]
        var suspended = Set<UInt64>()
        var parked: [CheckedContinuation<Data, Error>] = []
        let presentationSources = Sources(root: communityRoot, query: { _, _, _, _ in fatalError() },
        details: { ids in ids.compactMap { itemLookup[$0] } },
        download: { url in
            let id = UInt64(url.deletingPathExtension().lastPathComponent)!
            if suspended.contains(id) {
                return try await withCheckedThrowingContinuation { parked.append($0) }
            }
            return itemPayloads[id]!
        })
        /// Runs other main-actor work until `reached`; no timing is involved.
        func until(_ what: String, _ reached: () -> Bool) async {
            for _ in 0..<1_000_000 where !reached() { await Task.yield() }
            require(reached(), "never reached: \(what)")
        }
        enum Late { case success, failure }
        func finishParked(_ late: Late) {
            let continuation = parked.removeFirst()
            switch late {
            case .success: continuation.resume(returning: layerVDF)
            case .failure: continuation.resume(throwing: Sources.Failure.unavailable)
            }
        }
        func idle(_ model: SteamInputPreviewPresentationModel) -> Bool {
            !model.isLoading && !model.isPresented && model.previewData == nil && model.activeItemID == nil && model.errorMessage == nil
        }

        // 9a. Slow request A, then faster request B; A finishes late either way
        for late in [Late.success, .failure] {
            let model = SteamInputPreviewPresentationModel()
            require(idle(model), "a new model shows nothing")
            suspended = [4001]
            let requestA = model.requestPreview(appID: 480, item: slowItem, sources: presentationSources)
            require(model.isLoading && model.activeItemID == 4001 && !model.isPresented, "request A is loading")
            await until("A suspended in its download") { parked.count == 1 }
            let requestB = model.requestPreview(appID: 480, item: fastItem, sources: presentationSources)
            require(model.isLoading && model.activeItemID == 4002, "request B supersedes A")
            await requestB.value
            require(model.isPresented && !model.isLoading && model.errorMessage == nil, "B is presented")
            require(model.previewData?.title == "Multi-Set Game Layout", "B's preview is shown")
            let shown = model.previewData
            finishParked(late)
            await requestA.value
            require(model.previewData == shown && model.activeItemID == 4002, "late \(late) of A does not overwrite B")
            require(model.isPresented && !model.isLoading && model.errorMessage == nil, "late \(late) of A leaves B's state alone")
            // Dismissing the sheet through its binding clears the preview.
            model.isPresented = false
            require(idle(model), "dismissal through the sheet binding clears the preview")
            model.isPresented = true
            require(idle(model), "the binding cannot present without a preview")
        }

        // 9b. Dismissal while the request is suspended; late success and late failure
        for late in [Late.success, .failure] {
            let model = SteamInputPreviewPresentationModel()
            suspended = [4001]
            let request = model.requestPreview(appID: 480, item: slowItem, sources: presentationSources)
            await until("request suspended in its download") { parked.count == 1 }
            model.dismiss()
            require(idle(model), "dismissal stops loading at once")
            finishParked(late)
            await request.value
            require(idle(model), "late \(late) after dismissal neither reopens the sheet nor reports an error")
        }

        // 9c. Cancellation (the cancel button or the view disappearing), then retry
        for late in [Late.success, .failure] {
            let model = SteamInputPreviewPresentationModel()
            suspended = [4001]
            let first = model.requestPreview(appID: 480, item: slowItem, sources: presentationSources)
            await until("first request suspended in its download") { parked.count == 1 }
            model.cancel()
            require(idle(model), "cancellation stops loading without presenting or reporting")
            // The cancelled fetch has not unwound yet; the retry must not wait for it or be refused.
            suspended = []
            let retry = model.requestPreview(appID: 480, item: slowItem, sources: presentationSources)
            require(model.isLoading && model.activeItemID == 4001, "retry is loading")
            await retry.value
            require(model.isPresented && model.previewData?.title == "Layer Test Layout" && model.errorMessage == nil, "retry after cancellation presents the preview")
            let shown = model.previewData
            finishParked(late)
            await first.value
            require(model.previewData == shown && model.isPresented && model.errorMessage == nil && !model.isLoading,
                    "late \(late) of the cancelled request changes nothing")
            // With nothing in flight, the view disappearing leaves a presented preview alone.
            model.cancel()
            require(model.isPresented && model.previewData == shown, "cancel with nothing in flight keeps the presented preview")
            model.dismiss()
            require(idle(model), "dismissed")
        }

        // 9d. The view disappears while the request is suspended and nothing follows
        for late in [Late.success, .failure] {
            let model = SteamInputPreviewPresentationModel()
            suspended = [4001]
            let request = model.requestPreview(appID: 480, item: slowItem, sources: presentationSources)
            await until("request suspended in its download") { parked.count == 1 }
            model.cancel()
            require(idle(model), "cancellation stops loading at once")
            finishParked(late)
            await request.value
            require(idle(model), "late \(late) after cancellation neither presents nor reports an error")
        }

        // 9e. A current failure is reported; a new request clears it
        do {
            let model = SteamInputPreviewPresentationModel()
            suspended = [4001]
            let failing = model.requestPreview(appID: 480, item: slowItem, sources: presentationSources)
            await until("failing request suspended in its download") { parked.count == 1 }
            finishParked(.failure)
            await failing.value
            require(model.errorMessage == Sources.Failure.unavailable.errorDescription, "the current request's failure is reported")
            require(!model.isLoading && !model.isPresented && model.activeItemID == nil, "a failed request presents nothing")
            model.cancel()
            require(model.errorMessage != nil, "cancel with nothing in flight keeps the reported error")
            suspended = []
            let retry = model.requestPreview(appID: 480, item: slowItem, sources: presentationSources)
            require(model.errorMessage == nil && model.isLoading, "a new request clears the earlier error")
            await retry.value
            require(model.isPresented && model.errorMessage == nil, "retry after failure presents the preview")
            model.clearError(); model.dismiss()
            require(idle(model), "dismissed")
        }
        require(parked.isEmpty, "every suspended download was resumed")

        // =============================================================
        // TEST 10: Zero-Persistence Guarantee (File content & hash snapshot)
        // =============================================================
        let postPreviewSnapshot = try snapshotTree(tempRoot)
        require(postPreviewSnapshot == baselineSnapshot, "post-preview directory state must be 100% bit-for-bit identical to baseline")

        // =============================================================
        // TEST 11: Actual Task Cancellation while Suspended
        // =============================================================
        var cancelContinuation: CheckedContinuation<Data, Error>?
        let cancelSources = Sources(root: communityRoot, query: { _, _, _, _ in fatalError() },
        details: { ids in return ids.compactMap { itemLookup[$0] } },
        download: { _ in
            return try await withCheckedThrowingContinuation { cont in
                cancelContinuation = cont
            }
        })

        let cancelTask = Task { @MainActor in
            _ = try await cancelSources.preview(appID: 480, item: itemMulti)
        }

        // Allow task to suspend inside download
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelTask.cancel()
        cancelContinuation?.resume(throwing: CancellationError())

        var taskThrewCancellation = false
        do {
            try await cancelTask.value
        } catch is CancellationError {
            taskThrewCancellation = true
        } catch {}
        require(taskThrewCancellation, "task cancellation while suspended must throw CancellationError")

        let postCancelSnapshot = try snapshotTree(tempRoot)
        require(postCancelSnapshot == baselineSnapshot, "post-cancellation directory state must be 100% bit-for-bit identical")

        // =============================================================
        // TEST 12: Pre-fetch and Post-fetch Revision Races
        // =============================================================
        let staleItem = makeItem(id: 3001, timeUpdated: 100)
        let updatedItem = makeItem(id: 3001, timeUpdated: 101)
        itemLookup[staleItem.id] = updatedItem
        var caughtStale = false
        do {
            _ = try await sources.preview(appID: 480, item: staleItem)
        } catch Sources.Failure.changed {
            caughtStale = true
        } catch {}
        require(caughtStale, "pre-fetch revision race rejected with Failure.changed")

        let sizeMismatchListing = makeItem(id: 3002, size: 500, timeUpdated: 100)
        let sizeMismatchDetails = makeItem(id: 3002, size: 600, timeUpdated: 100)
        itemLookup[sizeMismatchListing.id] = sizeMismatchDetails
        var caughtSizeMismatch = false
        do {
            _ = try await sources.preview(appID: 480, item: sizeMismatchListing)
        } catch Sources.Failure.changed {
            caughtSizeMismatch = true
        } catch {}
        require(caughtSizeMismatch, "post-fetch size race with identical timeUpdated rejected with Failure.changed")

        print("PASS: milestone 4 preview resolution, container and child condition preservation, unknown content fallback, grammar validation, production byte-limit and redirect enforcement, preview presentation state, and strict zero-persistence verification")
    }
}
'''

# SwiftUI views are not built on the host, so pin the wiring: the detail view
# drives the presentation model exercised above and keeps no preview state.
view = (app / 'SteamInputCommunityView.swift').read_text()
for needle, why in [
    ('@State private var preview = SteamInputPreviewPresentationModel()', 'the detail view owns one presentation model'),
    ('preview.requestPreview(appID: appID, item: item, sources: .shared)', 'the preview button requests through the model'),
    ('.sheet(isPresented: Binding(get: { preview.isPresented }, set: { preview.isPresented = $0 }))', 'the sheet is bound to the model'),
    ('if let data = preview.previewData {', 'the sheet shows the model\'s preview'),
    ('.onDisappear { operation?.cancel(); preview.cancel() }', 'leaving the view cancels the request in flight'),
    ('Button("Cancel download or lookup") { operation?.cancel(); preview.cancel() }', 'the cancel button cancels the preview request'),
    ('if let failure = failure ?? preview.errorMessage {', 'the model\'s error is shown'),
    ('private var working: Bool { busy || preview.isLoading }', 'the model\'s loading state drives the controls'),
]:
    if view.count(needle) != 1:
        raise SystemExit(f'FAIL: {why}: expected exactly one `{needle}` in SteamInputCommunityView.swift')
for needle, why in [('.preview(appID', 'the view must not fetch previews itself'),
                    ('showingPreview', 'the view must not keep its own sheet flag'),
                    ('SteamInputPreviewData?', 'the view must not keep its own preview result')]:
    if needle in view:
        raise SystemExit(f'FAIL: {why}: found `{needle}` in SteamInputCommunityView.swift')

with tempfile.TemporaryDirectory(prefix='madeira-input-preview-') as temporary:
    tmp = Path(temporary)
    (tmp / 'main.swift').write_text(program)
    workshop = (app / 'SteamWorkshopFiles.swift').read_text()
    (tmp / 'workshop.swift').write_text(workshop[:workshop.index('/// Valve\'s record of an app\'s installed Workshop items:')])
    header = root / 'madeira-dock/src/steam_input_service.h'
    subprocess.run([shutil.which('clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address', '-c', str(header.with_suffix('.c')), '-o', str(tmp / 'service.o')], check=True)
    subprocess.run([shutil.which('swiftc'), '-parse-as-library', '-sanitize=address', '-module-cache-path', str(tmp / 'modules'), '-import-objc-header', str(header),
                    str(app/'SwiftSteam/Library/SteamAppInfo.swift'), str(app/'SwiftSteam/Proto/SteamProtoMessages.swift'), str(app/'SwiftSteam/Core/SteamError.swift'),
                    str(app/'SteamKeyValues.swift'), str(app/'SteamInputVDF.swift'), str(app/'SteamInputModel.swift'), str(app/'SteamInputPreview.swift'),
                    str(app/'SteamInputTransactions.swift'), str(app/'SteamInputDefaults.swift'),
                    str(app/'SteamInputCommunity.swift'), str(tmp/'workshop.swift'), str(tmp/'main.swift'), str(tmp/'service.o'), '-o', str(tmp/'check')], check=True)
    subprocess.run([str(tmp/'check'), str(tmp/'isolated_roots')], check=True)
