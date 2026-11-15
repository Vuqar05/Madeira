// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

// Madeira's half of Dock's Steam Input integration: the layout service's
// wire format, transactions and recovery, the per-game selection, its
// presentation and the PlayStation setting for a Dock launch
// (docs/STEAM_INPUT.md, docs/STEAM_INPUT_INTEGRATION_PLAN.md).

import Foundation
import Darwin

/// Version 1 of Dock's bounded, session-scoped read-only layout service.
/// Wire integers are little endian; native memory layouts are never serialized.
enum DockSteamInputWire {
    static let headerSize = 72
    static let maxFeedSize = headerSize + 4096
    enum Action: UInt32 { case query = 1, sources, apply, restoreDefault, revisionProbe, bootstrap, workshop }
    enum State: UInt32 { case idle, disconnected, queued, cached, activationRequested, failed, active }
    struct Snapshot: Equatable {
        let session: [UInt8]
        let appID: UInt32
        let epoch: UInt32
        let sequence: UInt32
        let result: UInt32
        let state: State
        let sources: UInt32
        let flags: UInt32
        let workshopID: UInt64
        /// Supported transport groups: buttons, sticks, triggers, touch click.
        /// Motion, touch positions and extra Deck/Steam Controller inputs absent.
        let forwardedInputs: UInt32
        let selection: String
        var connected: Bool { flags & 2 != 0 }
        /// Cache presence for the game, independent of the selected revision.
        var mappingCached: Bool { flags & 4 != 0 }
    }
    static func parse(_ data: Data) -> Snapshot? {
        guard data.count >= headerSize, data.count <= maxFeedSize else { return nil }
        let b = [UInt8](data)
        guard Array(b[0..<8]) == Array("MSIFEED1".utf8) else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[at + $1]) << (8 * $1) } }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[at + $1]) << (8 * $1) } }
        let length = Int(u32(68))
        guard u32(24) > 0, u32(28) == 0, u32(40) <= 8,
              u32(48) & ~UInt32(1) == 0, u32(52) & ~UInt32(255) == 0,
              u32(64) & ~UInt32(15) == 0,
              let state = State(rawValue: u32(44)), length <= 4096,
              b.count == headerSize + length,
              b[8..<24].contains(where: { $0 != 0 }),
              let key = String(bytes: b[headerSize...], encoding: .utf8),
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return Snapshot(session: Array(b[8..<24]), appID: u32(24), epoch: u32(32),
                        sequence: u32(36), result: u32(40), state: state, sources: u32(48),
                        flags: u32(52), workshopID: u64(56), forwardedInputs: u32(64), selection: key)
    }
    static func command(_ action: Action, snapshot: Snapshot, sequence: UInt32) -> Data? {
        guard snapshot.session.count == 16, snapshot.session.contains(where: { $0 != 0 }),
              snapshot.appID > 0, sequence > 0 else { return nil }
        var bytes = Array("MSICMD01".utf8) + snapshot.session
        for value in [snapshot.appID, 0, snapshot.epoch, sequence, action.rawValue] {
            for shift in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
        }
        return Data(bytes)
    }
}

/// One Madeira virtual controller occupies Steam's slot 0: the DualSense or
/// the Xbox controller the launch chose (SteamInputController). Selections,
/// journals and remembered details are kept per identity, never per physical
/// pad, so each controller type keeps its own layouts.
@MainActor enum DockSteamInputService {
    /// The identity this launch's selection and journal belong to.
    private(set) static var controller: SteamInputController = .dualSense
    static var controllerID: UUID { controller.controllerID }
    /// What this launch's controller supplies beyond buttons, sticks and triggers.
    private(set) static var hardware: SteamInputHardware = .none
    /// A layout Steam Input would have re-applied at this launch (the last
    /// confirmed choice, or Steam's own saved one) that was made for another
    /// controller and was never confirmed for this one. Nothing was applied;
    /// `confirmHeld` records the confirmation and lets it load.
    private(set) static var held: SteamInputConfirmationNeeded?
    private(set) static var snapshot: DockSteamInputWire.Snapshot?
    private(set) static var selection: DockSteamInputSelection?
    /// Pending journal work requires explicit recovery; never reapply it just
    /// because a new launch or controller connection appeared.
    private(set) static var recovery: DockSteamInputJournal.Pending?
    private(set) static var prepared: DockSteamInputJournal.Pending?
    private static var journal: DockSteamInputJournal?
    private static var preparedChoice: DockSteamInputSelection.Revision?
    private static var preparedReapplication = false
    private static var preparedClearOverride = false
#if DEBUG
    private static var diagnosticSequence: UInt32 = 0
#endif
    private static var restartAttempted = false
    /// Steam has no saved selection for this connection: the query failed on
    /// every attempt, or it succeeded and named neither a layout nor a
    /// Workshop item. Nothing is loaded and no baseline exists.
    private static var noSavedSelection = false
    private static var bootstrapAutoTried = false
    static var resolveSelectedWorkshop: ((UInt32, UInt64) async throws -> Data)?
    private static var workshopTask: Task<Void, Never>?
    private static var workshopAttempted = false
    private(set) static var sourceFailure: String?
    static var resolvingWorkshop: Bool { workshopTask != nil }
    /// One explicit layout handed to Dock so the game gets a working baseline.
    private struct Bootstrap {
        enum Phase { case sending, loading }
        enum Purpose {
            case requested(DockSteamInputSelection.Revision)
            case replay
            case selectedWorkshop(UInt64)
            var workshopID: UInt64? {
                if case .selectedWorkshop(let item) = self { return item }
                return nil
            }
        }
        let source: Data
        /// A player's request is applied through the normal journal once the
        /// baseline exists; a restored choice is reapplied by the restart path.
        let purpose: Purpose
        var phase = Phase.sending
        var tries = 0
        var sent: (sequence: UInt32, at: Date)?
        let started = Date()
    }
    private static var bootstrap: Bootstrap?
    private static var restartEpoch: UInt32?
    private static var restartWaitStarted: Date?
    private(set) static var activeChoice: DockSteamInputSelection.Revision?
    private(set) static var inputQuiesced = false
    static var onInputQuiescedChanged: ((Bool) -> Void)?
    static let baselineRestoreIdentity = "0EBD445F-87AE-46F2-96BB-042CB53B35E1"

    private static func updateInputQuiesced() {
        let next = prepared != nil || submission != nil || bootstrap != nil
        guard next != inputQuiesced else { return }
        inputQuiesced = next
        onInputQuiescedChanged?(next)
    }
    private struct Submission {
        let work: DockSteamInputJournal.Pending
        let request: DockSteamInputJournal.Request
        let choice: DockSteamInputSelection.Revision
        let generation: UInt64
        let reapplication: Bool
        let clearOverride: Bool
        let previousChoice: DockSteamInputSelection.Revision?
        let sent: Date
    }
    private static var submission: Submission?
    /// The choice being applied now, if any (for the status headline).
    static var submittingChoice: DockSteamInputSelection.Revision? { submission?.choice ?? preparedChoice }
    private(set) static var receipt: DockSteamInputTransport.Receipt?
    private static var session: [UInt8] = []
    private static var appID: UInt32 = 0
    private static var accountID: UInt32 = 0
    private static var sequence: UInt32 = 0
    private static var epoch: UInt32?
    private static var attempts = 0
    private static var pending: (sequence: UInt32, sent: Date)?
    private static var storage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MadeiraDock", isDirectory: true)
    }
    private static var feed: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input.bin") }
    private static var command: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-cmd.bin") }

    private static var payloadFile: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-apply.bin") }
    private static var initialFile: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-initial.bin") }
    private static var bootstrapLastSend: Date?
    /// Seconds between BOOTSTRAP attempts; Dock accepts one only after its own retries fail.
    static var bootstrapPace: TimeInterval = 5
    private static var receiptFile: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-tx.bin") }
    private static var baselineFile: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-baseline.bin") }
    private static var contextFile: URL { MadeiraDock.drive.appendingPathComponent("madeira-steam-input-context.bin") }

    static func context(appID: UInt32) -> DockSteamInputContext? {
        guard let snapshot, snapshot.appID == appID, snapshot.connected,
              let file = try? FileHandle(forReadingFrom: contextFile) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 56 + 4097) else { return nil }
        let value = DockSteamInputContext.parse(bytes, session: session, appID: appID, epoch: snapshot.epoch)
        if let value { remember(value, appID: appID) }
        return value
    }
    /// Where the controller details Dock last reported for each game and
    /// controller are kept (the DualSense's under the name it always had).
    private static func rememberedURL(appID: UInt32, controller: SteamInputController) -> URL {
        storage.appendingPathComponent("SteamInputContext/\(appID)\(controller == .dualSense ? "" : "-" + controller.rawValue).json")
    }
    private struct RememberedKey: Hashable { let appID: UInt32; let controller: SteamInputController }
    private static var rememberedCache: [RememberedKey: DockSteamInputContext] = [:]
    /// Keeps what Dock reported for the virtual controller in this game's
    /// session, so a personal layout can be started from the game default
    /// while the game is not running. Written only when it changes.
    private static func remember(_ value: DockSteamInputContext, appID: UInt32) {
        guard let controller = value.controller, rememberedCache[.init(appID: appID, controller: controller)] != value else { return }
        rememberedCache[.init(appID: appID, controller: controller)] = value
        let url = rememberedURL(appID: appID, controller: controller)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch { SteamLog.event("[steam-input] controller details not kept") }
    }
    /// The details Dock reported for `controller` in this game's most recent
    /// session with it, or nil when it never has. Never used to apply a
    /// layout: only to choose the starting point of a new personal layout.
    static func rememberedContext(appID: UInt32, controller: SteamInputController) -> DockSteamInputContext? {
        let key = RememberedKey(appID: appID, controller: controller)
        if let cached = rememberedCache[key] { return cached }
        guard appID > 0, let data = try? Data(contentsOf: rememberedURL(appID: appID, controller: controller)), data.count <= 8192,
              let value = try? JSONDecoder().decode(DockSteamInputContext.self, from: data), value.controller == controller,
              value.vendor <= 65535, value.product <= 65535, (value.manifestPath?.utf8.count ?? 0) <= 4096,
              !(value.manifestPath ?? "").unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        rememberedCache[key] = value
        return value
    }
    /// An explicit retry refreshes read-only source context; it never applies a
    /// fallback or changes persisted intent. Reuses the bounded query loop.
    static func retrySources(appID: UInt32) {
        guard snapshot?.appID == appID, pending == nil, submission == nil, prepared == nil, bootstrap == nil else { return }
        attempts = 0; workshopAttempted = false; sourceFailure = nil
    }

    static func begin(accountID: UInt32, appID: UInt32) {
        end()
        self.accountID = accountID; self.appID = appID
        controller = SteamInputController.current
        hardware = SteamInputController.sessionHardware ?? SteamInputController.currentHardware
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        session = stride(from: 0, to: 32, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        // This random launch identifier is not a credential. Never log it.
        setenv("MADEIRA_DOCK_INPUT_SESSION", hex, 1)
        do {
            let store = try DockSteamInputJournal(root: storage,
                scope: .init(accountID: accountID, appID: appID, controllerID: controllerID))
            try store.interrupt()
            let record = try store.snapshot()
            journal = store
            if record.pending?.phase == .interrupted { recovery = record.pending }
        } catch {
            SteamLog.event("[steam-input] layout journal unavailable")
        }
        do {
            selection = try DockSteamInputSelection.load(in: storage, accountID: accountID, appID: appID, controllerID: controllerID)
        } catch {
            // Do not replace an incompatible/corrupt record with an empty one.
            SteamLog.event("[steam-input] saved selection unavailable")
        }
    }
    static func end() {
        do { try journal?.interrupt() }
        catch { SteamLog.event("[steam-input] layout interruption not saved") }
        journal = nil; recovery = nil; prepared = nil; submission = nil; receipt = nil; held = nil
        preparedChoice = nil; preparedReapplication = false; preparedClearOverride = false; activeChoice = nil
        updateInputQuiesced()
#if DEBUG
        diagnosticSequence = 0
        try? FileManager.default.removeItem(at: MadeiraDock.drive.appendingPathComponent("madeira-steam-input-local-test.bin"))
#endif
        restartAttempted = false; restartEpoch = nil; restartWaitStarted = nil
        noSavedSelection = false; bootstrapAutoTried = false; bootstrap = nil; bootstrapLastSend = nil
        workshopTask?.cancel(); workshopTask = nil; workshopAttempted = false; sourceFailure = nil
        updateInputQuiesced()
        unsetenv("MADEIRA_DOCK_INPUT_SESSION")
        session = []; snapshot = nil; selection = nil; pending = nil
        sequence = 0; epoch = nil; attempts = 0; appID = 0; accountID = 0
        try? FileManager.default.removeItem(at: feed)
        try? FileManager.default.removeItem(at: command)
        try? FileManager.default.removeItem(at: payloadFile)
        try? FileManager.default.removeItem(at: initialFile)
        try? FileManager.default.removeItem(at: receiptFile)
        try? FileManager.default.removeItem(at: baselineFile)
        try? FileManager.default.removeItem(at: contextFile)
    }
    /// Stage an explicit local template/personal choice without touching Steam.
    /// The caller supplies source and observed baseline bytes, never paths. Live
    /// submission will require the matching session-scoped transaction bridge.
    static func prepareLocal(source: Data, baseline: Data, choice: DockSteamInputSelection.Revision) throws -> DockSteamInputJournal.Pending {
        guard choice.source == .template || choice.source == .personal else { throw DockSteamInputJournal.Failure.invalid }
        return try prepareChoice(source: source, baseline: baseline, choice: choice)
    }
    /// Stage an explicitly requested game default whose source has already been
    /// resolved and validated by the caller. A candidate or stale metadata is
    /// not sufficient evidence of Valve's current recommendation. The default
    /// uses the same receipt and rollback path as every other live change.
    static func prepareGameDefault(source: Data, baseline: Data, detail: String? = nil) throws -> DockSteamInputJournal.Pending {
        try prepareChoice(source: source, baseline: baseline,
                          choice: .init(source: .gameDefault, identity: nil, contentHash: nil, detail: detail))
    }
    /// True when a user-requested layout change can start now: a connected pad,
    /// a gated host with a settled working baseline, and no change in flight.
    static var canChange: Bool {
        guard let snapshot, snapshot.connected, snapshot.flags & 48 == 48, snapshot.state != .failed,
              pending == nil, submission == nil, prepared == nil, recovery == nil,
              journal != nil, selection != nil, workingBaseline() != nil else { return false }
        return true
    }
    /// The host's current exact working layout, bound to this launch and epoch.
    private static func workingBaseline() -> Data? {
        guard let snapshot, let file = try? FileHandle(forReadingFrom: baselineFile) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: (1 << 20) + 44) else { return nil }
        return DockSteamInputTransport.baseline(bytes, session: session, appID: appID, epoch: snapshot.epoch)
    }
    /// An explicit user request. The caller obtained the recommendation from
    /// DockSteamInputDefault; submission and activation follow the common
    /// receipt path, so the choice is shown active only after its receipt.
    static func requestGameDefault(_ recommendation: DockSteamInputDefault.Recommendation) throws {
        try checkFit(recommendation.source)
        if !canChange, canBootstrap {
            try startBootstrap(source: recommendation.source,
                choice: .init(source: .gameDefault, identity: nil, contentHash: recommendation.contentHash,
                              detail: String(recommendation.sourceDescription.prefix(120))))
            return
        }
        guard canChange, let baseline = workingBaseline() else { throw DockSteamInputJournal.Failure.busy }
        _ = try prepareGameDefault(source: recommendation.source, baseline: baseline,
                                   detail: String(recommendation.sourceDescription.prefix(120)))
        try submitPrepared()
    }
    /// The caller validated the exact game's raw public layout. Community
    /// selections share journal reservations, rollback and restart with defaults.
    static func requestCommunity(appID: UInt32, source: Data, itemID: UInt64, detail: String) throws {
        guard appID == self.appID, itemID > 0 else { throw DockSteamInputJournal.Failure.invalid }
        try checkFit(source)
        let choice = DockSteamInputSelection.Revision(source: .community, identity: String(itemID),
            contentHash: DockSteamInputNative.contentHash(source), detail: detail)
        if !canChange, canBootstrap {
            try startBootstrap(source: source, choice: choice)
            return
        }
        guard canChange, let baseline = workingBaseline() else { throw DockSteamInputJournal.Failure.busy }
        _ = try prepareChoice(source: source, baseline: baseline, choice: choice)
        try submitPrepared()
    }

    /// A personal layout is the player's own stored bytes, named by its local
    /// UUID. The caller read and validated them. It shares the journal
    /// reservations, receipts, rollback and restart of every other choice;
    /// Steam's own saved selection is never written, and no Steam selection key
    /// is made up for it.
    static func requestPersonal(appID: UInt32, accountID: UInt32, source: Data, id: UUID, detail: String) throws {
        guard appID == self.appID, accountID == self.accountID, accountID > 0,
              id.uuidString != baselineRestoreIdentity else { throw DockSteamInputJournal.Failure.invalid }
        try checkFit(source)
        let choice = DockSteamInputSelection.Revision(source: .personal, identity: id.uuidString,
            contentHash: DockSteamInputNative.contentHash(source), detail: detail)
        if !canChange, canBootstrap {
            try startBootstrap(source: source, choice: choice)
            return
        }
        guard canChange, let baseline = workingBaseline() else { throw DockSteamInputJournal.Failure.busy }
        _ = try prepareChoice(source: source, baseline: baseline, choice: choice)
        try submitPrepared()
    }

    /// What the saved selection and this launch's layout service say about
    /// personal layouts of one account and game: which are chosen (and which
    /// of their revisions), which revision Steam Input last confirmed, and
    /// which have a change in flight. Personal layouts are deleted and their
    /// old revisions pruned only against this. A selection that cannot be
    /// read is reported as unknown, so nothing is deleted on a guess.
    static func personalReferences(accountID: UInt32, appID: UInt32) -> SteamInputPersonalReferences {
        let live = accountID == self.accountID && appID == self.appID && accountID > 0
        // Every controller's selection counts: a layout chosen for the Xbox
        // controller is in use even while the DualSense plays.
        var selections: [DockSteamInputSelection] = []
        for identity in SteamInputController.allCases {
            if live, identity == controller, let selection { selections.append(selection); continue }
            guard accountID > 0, appID > 0,
                  let loaded = try? DockSteamInputSelection.load(in: storage, accountID: accountID, appID: appID,
                                                                  controllerID: identity.controllerID)
            else { return .unknown }
            selections.append(loaded)
        }
        func personal(_ revision: DockSteamInputSelection.Revision?) -> (UUID, String?)? {
            guard let revision, revision.source == .personal, let identity = revision.identity,
                  identity != baselineRestoreIdentity, let id = UUID(uuidString: identity) else { return nil }
            return (id, revision.contentHash)
        }
        var references = SteamInputPersonalReferences()
        for saved in selections {
            for revision in [saved.requested, saved.lastActivated] {
                guard let (id, hash) = personal(revision) else { continue }
                references.selected[id, default: []].formUnion(hash.map { [$0] } ?? [])
            }
            if let (id, hash) = personal(saved.lastActivated), let hash { references.confirmed[id] = hash }
        }
        if live {
            var flight = [preparedChoice, submission?.choice]
            if case .requested(let choice)? = bootstrap?.purpose { flight.append(choice) }
            for choice in flight { if let (id, _) = personal(choice) { references.inFlight.insert(id) } }
        }
        return references
    }

    /// Milestone 5 item 2: every source (game default, community, personal,
    /// imported, live edit, template) passes here before anything is staged.
    /// A layout that fits this launch's controller goes ahead. One made for
    /// another controller, or using features it cannot supply, goes ahead only
    /// once the player has confirmed that revision for this controller;
    /// otherwise SteamInputConfirmationNeeded lists the gaps and nothing changes.
    /// Conditional, broken and malformed layouts are refused (the evaluator throws).
    static func checkFit(_ source: Data) throws {
        let gaps = try SteamInputController.environment.gaps(source, controller, hardware)
        guard !gaps.isEmpty else { return }
        let hash = DockSteamInputNative.contentHash(source)
        guard SteamInputConsent.isConfirmed(hash: hash, controller: controller) else {
            throw SteamInputConfirmationNeeded(controller: controller, hash: hash, gaps: gaps)
        }
    }
    /// For re-applying at launch: nil when the layout may load, else what
    /// must be confirmed first. A layout the evaluator cannot read keeps the
    /// earlier milestones' behaviour (it was applied before) and loads.
    private static func unconfirmed(_ source: Data) -> SteamInputConfirmationNeeded? {
        do { try checkFit(source); return nil }
        catch let needed as SteamInputConfirmationNeeded { return needed }
        catch { return nil }
    }
    /// The player confirmed the held layout: remember it and let the launch's
    /// restart or replay path load it on its next pass.
    static func confirmHeld() throws {
        guard let held else { return }
        try SteamInputConsent.confirm(hash: held.hash, controller: held.controller)
        self.held = nil
        restartAttempted = false; bootstrapAutoTried = false
        SteamLog.event("[steam-input] held layout confirmed for \(held.controller.rawValue)")
    }

    /// The saved choice for one account, game and controller while that game
    /// is not running (Game details). Nil when it cannot be read.
    static func savedSelection(accountID: UInt32, appID: UInt32, controller: SteamInputController) -> DockSteamInputSelection? {
        guard accountID > 0, appID > 0 else { return nil }
        if accountID == self.accountID, appID == self.appID, controller == self.controller, let selection { return selection }
        return try? DockSteamInputSelection.load(in: storage, accountID: accountID, appID: appID, controllerID: controller.controllerID)
    }
    /// Game details, game not running: from the next launch Steam's own
    /// saved layout (the game default unless the player chose one in Steam)
    /// is used instead of Madeira's override. Nothing else changes: the
    /// override's revisions stay in the journal and personal layouts are kept.
    static func clearSavedOverride(accountID: UInt32, appID: UInt32, controller: SteamInputController) throws {
        guard snapshot?.appID != appID, accountID > 0, appID > 0 else { throw DockSteamInputJournal.Failure.busy }
        var saved = try DockSteamInputSelection.load(in: storage, accountID: accountID, appID: appID, controllerID: controller.controllerID)
        guard saved.requested != nil else { return }
        try saved.clearRequest()
        try saved.save(in: storage)
        SteamLog.event("[steam-input] saved override cleared for the next launch")
    }

    /// An explicit, clearly generic choice; never labelled as the game's own.
    static func requestGenericTemplate(clientRoot: URL) throws {
        if !canChange, canBootstrap {
            let source = try DockSteamInputDefault.genericTemplate(clientRoot: clientRoot, controller: controller)
            try checkFit(source)
            try startBootstrap(source: source,
                choice: .init(source: .template, identity: controller.genericTemplate,
                              contentHash: DockSteamInputNative.contentHash(source)))
            return
        }
        guard canChange, let baseline = workingBaseline() else { throw DockSteamInputJournal.Failure.busy }
        let source = try DockSteamInputDefault.genericTemplate(clientRoot: clientRoot, controller: controller)
        try checkFit(source)
        _ = try prepareLocal(source: source, baseline: baseline,
                             choice: .init(source: .template, identity: controller.genericTemplate, contentHash: nil))
        try submitPrepared()
    }
#if DEBUG
    /// Debug builds only: apply a different real Steam template so restoring the
    /// game default can be tested on a device. Same journal and receipt path.
    static func requestDebugOverride(clientRoot: URL) throws {
        guard canChange, let baseline = workingBaseline() else { throw DockSteamInputJournal.Failure.busy }
        let source = try DockSteamInputBundledManifest.debugOverride(clientRoot: clientRoot)
        _ = try prepareLocal(source: source, baseline: baseline,
                             choice: .init(source: .template, identity: "debug-ab-swapped-" + DockSteamInputBundledManifest.debugOverrideTemplate, contentHash: nil))
        try submitPrepared()
    }
#endif
    private static func prepareChoice(source: Data, baseline: Data, choice: DockSteamInputSelection.Revision) throws -> DockSteamInputJournal.Pending {
        guard let snapshot, snapshot.connected, snapshot.flags & 1 != 0,
              pending == nil, recovery == nil, prepared == nil,
              let journal, var saved = selection else { throw DockSteamInputJournal.Failure.busy }
        let hash = DockSteamInputNative.contentHash(source)
        if let expected = choice.contentHash, expected != hash { throw DockSteamInputJournal.Failure.invalid }
        let resolved = DockSteamInputSelection.Revision(source: choice.source, identity: choice.identity, contentHash: hash, detail: choice.detail)
        let captureBaseline = saved.requested == nil
        try saved.request(resolved)
        let work = try journal.prepareLocal(source: source, baseline: baseline, captureSteamBaseline: captureBaseline)
        do { try saved.save(in: storage) }
        catch {
            try? journal.finish(work.reservation, phase: .failed, hash: nil, revision: nil)
            throw error
        }
        selection = saved; prepared = work; receipt = nil
        preparedChoice = resolved; preparedReapplication = false; preparedClearOverride = false; restartAttempted = true
        updateInputQuiesced()
        return work
    }
    /// Stage restoring the captured Steam baseline without mutating saved user
    /// intent before confirmation. Only a confirmed receipt clears the override.
    static func prepareBaselineRestore(baseline: Data) throws -> DockSteamInputJournal.Pending {
        guard let snapshot, snapshot.connected, snapshot.flags & 1 != 0,
              pending == nil, recovery == nil, prepared == nil,
              let journal, let saved = selection, saved.requested != nil else { throw DockSteamInputJournal.Failure.busy }
        let original = try journal.steamBaseline()
        let hash = DockSteamInputNative.contentHash(original)
        let resolved = DockSteamInputSelection.Revision(source: .personal, identity: baselineRestoreIdentity, contentHash: hash)
        let work = try journal.prepareLocal(source: original, baseline: baseline, captureSteamBaseline: false)
        prepared = work; receipt = nil
        preparedChoice = resolved; preparedReapplication = false; preparedClearOverride = true; restartAttempted = true
        updateInputQuiesced()
        return work
    }
    /// Submit only to a host advertising the gated local-apply capability. The
    /// journal is durable before the command can be consumed. Acceptance alone
    /// never updates lastActivated; only a matching hash-bound receipt can.
    static func submitPrepared() throws {
        guard let current = snapshot, current.connected, current.flags & 16 != 0,
              pending == nil, submission == nil, recovery == nil,
              let work = prepared, let journal, let saved = selection, let choice = preparedChoice,
              let content = work.content, choice.contentHash == content.sourceHash,
              (preparedReapplication ? saved.lastActivated == choice : (preparedClearOverride ? saved.requested != nil : saved.requested == choice)) else { throw DockSteamInputJournal.Failure.busy }
        sequence = max(sequence, current.sequence)
        guard sequence < UInt32.max else { throw DockSteamInputJournal.Failure.exhausted }
        sequence += 1
        let request = DockSteamInputJournal.Request(session: session.map { String(format: "%02x", $0) }.joined(),
                                                   epoch: current.epoch, sequence: sequence)
        let bytes = try DockSteamInputTransport.envelope(session: session, appID: appID, epoch: current.epoch,
            sequence: sequence, reservation: work.reservation, apply: journal.content(content.applyHash), rollback: journal.content(content.rollbackHash))
        guard let commandBytes = DockSteamInputWire.command(.apply, snapshot: current, sequence: sequence) else { throw DockSteamInputJournal.Failure.invalid }
        try journal.markQueued(work.reservation, request: request)
        receipt = nil
        submission = Submission(work: work, request: request, choice: choice, generation: saved.generation,
            reapplication: preparedReapplication, clearOverride: preparedClearOverride, previousChoice: activeChoice, sent: Date())
        activeChoice = nil
        updateInputQuiesced()
        do {
            try bytes.write(to: payloadFile, options: .atomic)
            try commandBytes.write(to: command, options: .atomic)
        } catch {
            try? journal.interrupt()
            recovery = try? journal.snapshot().pending
            prepared = nil; submission = nil
            updateInputQuiesced()
            throw error
        }
    }
    private static func refreshSubmission(_ current: DockSteamInputWire.Snapshot) {
        guard let sent = submission, let journal else { return }
        if current.sequence == sent.request.sequence, current.result != 0, current.result != 1 {
            do {
                try journal.finish(sent.work.reservation, phase: .failed, hash: nil, revision: nil)
                activeChoice = sent.previousChoice
                submission = nil; prepared = nil; preparedChoice = nil
                updateInputQuiesced()
            } catch { SteamLog.event("[steam-input] rejected layout result not saved") }
            return
        }
        if let file = try? FileHandle(forReadingFrom: receiptFile) {
            defer { try? file.close() }
            if let bytes = try? file.read(upToCount: 97), let value = DockSteamInputTransport.receipt(bytes),
               value.session == session, value.appID == appID, value.epoch == sent.request.epoch,
               value.sequence == sent.request.sequence,
               value.applyRevision == sent.work.reservation.applyRevision,
               value.rollbackRevision == sent.work.reservation.rollbackRevision {
                if value.phase == .confirmed || value.phase == .rolledBack {
                    let rolledBack = value.phase == .rolledBack
                    guard let content = sent.work.content,
                          value.workingHash == (rolledBack ? content.rollbackHash : content.applyHash) else { return }
                    receipt = value
                    do {
                        var updated = selection
                        guard var saved = updated, saved.generation == sent.generation else { return }
                        if !rolledBack {
                            if sent.reapplication {
                                guard saved.lastActivated == sent.choice else { return }
                            } else if sent.clearOverride {
                                try saved.request(sent.choice)
                                try saved.acknowledge(sent.choice, generation: saved.generation)
                                try saved.clearRequest()
                            } else {
                                try saved.acknowledge(sent.choice, generation: sent.generation)
                            }
                            updated = saved
                        }
                        try journal.finish(sent.work.reservation, phase: rolledBack ? .rolledBack : .confirmed,
                            hash: value.workingHash, revision: value.workingRevision, request: sent.request)
                        activeChoice = rolledBack ? sent.previousChoice : (sent.clearOverride ? nil : sent.choice)
                        submission = nil; prepared = nil; preparedChoice = nil
                        updateInputQuiesced()
                        if !rolledBack, !sent.reapplication, let saved = updated {
                            try saved.save(in: storage); selection = saved
                        }
                    } catch { SteamLog.event("[steam-input] layout receipt not saved") }
                    return
                } else if value.phase == .failed {
                    receipt = value
                    do {
                        try journal.finish(sent.work.reservation, phase: .failed, hash: nil, revision: nil)
                        activeChoice = sent.previousChoice
                        submission = nil; prepared = nil; preparedChoice = nil
                        updateInputQuiesced()
                    } catch { SteamLog.event("[steam-input] layout failure not saved") }
                    return
                } else { receipt = value }
            }
        }
        if Date().timeIntervalSince(sent.sent) > 60 {
            try? journal.interrupt()
            recovery = try? journal.snapshot().pending
            submission = nil; prepared = nil; preparedChoice = nil
            updateInputQuiesced()
        }
    }
    private static func refreshRestart(_ current: DockSteamInputWire.Snapshot) {
        guard !restartAttempted, attempts == 3, pending == nil, submission == nil, prepared == nil,
              current.connected, current.flags & 48 == 48,
              let journal, let saved = selection else { return }
        guard (saved.requested != nil && saved.lastActivated != nil) || recovery != nil else { restartAttempted = true; return }
        if restartWaitStarted == nil { restartWaitStarted = Date() }
        guard let file = try? FileHandle(forReadingFrom: baselineFile) else {
            expireRestartWait(); return
        }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: (1 << 20) + 44),
              let baseline = DockSteamInputTransport.baseline(bytes, session: session, appID: appID, epoch: current.epoch) else {
            expireRestartWait(); return
        }
        do {
            if let interrupted = recovery {
                try journal.abandonInterrupted(interrupted.reservation,
                    newSession: session.map { String(format: "%02x", $0) }.joined(),
                    newEpoch: current.epoch)
                recovery = nil
            }
            restartAttempted = true
            guard saved.requested != nil, let choice = saved.lastActivated, let hash = choice.contentHash else { return }
            let source = try journal.reapplicationSource(hash: hash)
            if let needed = unconfirmed(source) {
                held = needed
                SteamLog.event("[steam-input] confirmed layout held: made for another controller, not confirmed")
                return
            }
            let work = try journal.prepareLocal(source: source, baseline: baseline)
            prepared = work; preparedChoice = choice; preparedReapplication = true; preparedClearOverride = false
            updateInputQuiesced()
            try submitPrepared()
        } catch { restartAttempted = true; SteamLog.event("[steam-input] confirmed layout restart unavailable") }
    }
    /// True when Steam has no saved layout for this game, so nothing is loaded
    /// and no baseline exists, and the player may start from an explicit layout.
    /// Interrupted work does not block a bootstrap when it belongs to an earlier
    /// launch or connection lease: the bootstrapped layout's baseline is then a
    /// fresh native baseline, which is what retiring it requires. Without this a
    /// game with no saved selection could never get a baseline again.
    static var canBootstrap: Bool {
        noSavedSelection && bootstrapReady
    }
    private static var bootstrapReady: Bool {
        guard bootstrap == nil, let snapshot, snapshot.connected,
              snapshot.flags & 16 != 0, snapshot.state == .failed,
              pending == nil, submission == nil, prepared == nil, recoveryRetirable(epoch: snapshot.epoch),
              journal != nil, selection != nil, workingBaseline() == nil else { return false }
        return true
    }
    private static var sessionHex: String { session.map { String(format: "%02x", $0) }.joined() }
    /// Mirrors DockSteamInputJournal.abandonInterrupted: work from this launch
    /// and connection lease may still be in flight and is never retired.
    private static func recoveryRetirable(epoch: UInt32) -> Bool {
        guard let request = recovery?.request else { return true }
        return request.session != sessionHex || epoch > request.epoch
    }
    /// A bootstrap is in flight: the layout is being handed to Dock or loading.
    static var bootstrapping: Bool { bootstrap != nil }
    private static func startBootstrap(source: Data, choice: DockSteamInputSelection.Revision) throws {
        guard canBootstrap else { throw DockSteamInputJournal.Failure.busy }
        _ = try DockSteamInputNative.revision(source)
        bootstrap = Bootstrap(source: source, purpose: .requested(choice))
        updateInputQuiesced()
    }
    private static func refreshBootstrap(_ current: DockSteamInputWire.Snapshot) {
        // A persisted, confirmed choice is the player's own: hand its exact
        // bytes over so the restart path can reapply it with a baseline.
        if bootstrap == nil, !bootstrapAutoTried, current.connected,
           current.flags & 16 != 0, current.state == .failed, submission == nil, prepared == nil,
           recoveryRetirable(epoch: current.epoch),
           let saved = selection, saved.requested != nil, let choice = saved.lastActivated,
           let hash = choice.contentHash, let journal,
           noSavedSelection {
            bootstrapAutoTried = true
            if let source = try? journal.reapplicationSource(hash: hash),
               (try? DockSteamInputNative.revision(source)) != nil {
                if let needed = unconfirmed(source) {
                    held = needed
                    SteamLog.event("[steam-input] saved layout held: made for another controller, not confirmed")
                } else {
                    bootstrap = Bootstrap(source: source, purpose: .replay)
                }
            }
        }
        guard var work = bootstrap else { return }
        guard current.connected, current.flags & 16 != 0,
              work.purpose.workshopID == nil || work.purpose.workshopID == current.workshopID,
              Date().timeIntervalSince(work.started) < 120 else {
            bootstrap = nil
            if case .selectedWorkshop = work.purpose { sourceFailure = "Steam's selected layout did not finish loading. Its saved selection is preserved; retry or relaunch." }
            SteamLog.event("[steam-input] initial layout not completed")
            return
        }
        switch work.phase {
        case .sending:
            if let sent = work.sent {
                if current.sequence == sent.sequence {
                    if current.result == 1 { work.phase = .loading; work.sent = nil; bootstrap = work; return }
                    work.sent = nil // refused for now; Dock retries until it is ready
                } else if Date().timeIntervalSince(sent.at) > 10 { work.sent = nil }
            }
            guard work.sent == nil, work.tries < 12 else {
                if work.tries >= 12, work.sent == nil { bootstrap = nil } else { bootstrap = work }
                return
            }
            // Dock accepts this only after its own retries have failed, so pace it.
            if let last = bootstrapLastSend, Date().timeIntervalSince(last) < bootstrapPace { bootstrap = work; return }
            sequence = max(sequence, current.sequence)
            let initial: Data?
            let action: DockSteamInputWire.Action
            switch work.purpose {
            case .selectedWorkshop(let item):
                initial = DockSteamInputTransport.workshopFrame(layout: work.source, itemID: item,
                    session: session, appID: appID, epoch: current.epoch)
                action = .workshop
            case .requested, .replay:
                initial = DockSteamInputTransport.initialFrame(layout: work.source, session: session, appID: appID, epoch: current.epoch)
                action = .bootstrap
            }
            guard sequence < UInt32.max, let frame = initial,
                  let bytes = DockSteamInputWire.command(action, snapshot: current, sequence: sequence + 1) else {
                bootstrap = nil; return
            }
            sequence += 1; work.tries += 1
            do {
                try frame.write(to: initialFile, options: .atomic)
                try bytes.write(to: command, options: .atomic)
                work.sent = (sequence, Date()); bootstrapLastSend = Date()
            } catch { SteamLog.event("[steam-input] initial layout not written") }
            bootstrap = work
        case .loading:
            // The layout is now Dock's loaded layout. Once it has settled and
            // published its baseline, the normal journal records the choice.
            // That baseline is fresh native evidence for this launch, so older
            // interrupted work is retired here; the restart path may already
            // have given up waiting for a baseline and would never do it.
            if let interrupted = recovery, let journal, workingBaseline() != nil {
                do {
                    try journal.abandonInterrupted(interrupted.reservation, newSession: sessionHex, newEpoch: current.epoch)
                    recovery = nil
                } catch {
                    bootstrap = nil
                    SteamLog.event("[steam-input] interrupted layout change not retired")
                    return
                }
            }
            guard canChange, let baseline = workingBaseline() else { bootstrap = work; return }
            bootstrap = nil
            guard case .requested(let choice) = work.purpose else { return }
            do {
                if choice.source == .gameDefault {
                    _ = try prepareGameDefault(source: work.source, baseline: baseline, detail: choice.detail)
                } else {
                    _ = try prepareChoice(source: work.source, baseline: baseline, choice: choice)
                }
                try submitPrepared()
            } catch { SteamLog.event("[steam-input] initial layout choice not recorded") }
        }
    }
    private static func refreshSelectedWorkshop(_ current: DockSteamInputWire.Snapshot) {
        guard attempts == 3, pending == nil, current.result == 1, !noSavedSelection,
              current.connected, current.flags & 128 != 0,
              current.state == .failed, current.workshopID > 0, bootstrapReady,
              !workshopAttempted, workshopTask == nil, let resolveSelectedWorkshop else { return }
        workshopAttempted = true
        let launch = current.session, lease = current.epoch, game = current.appID, item = current.workshopID
        workshopTask = Task { @MainActor in
            defer { if snapshot?.session == launch, snapshot?.epoch == lease { workshopTask = nil } }
            do {
                let bytes = try await resolveSelectedWorkshop(game, item)
                try Task.checkCancellation()
                guard let latest = snapshot, latest.session == launch, latest.epoch == lease,
                      latest.appID == game, latest.workshopID == item, bootstrapReady else { return }
                _ = try DockSteamInputNative.revision(bytes)
                bootstrap = Bootstrap(source: bytes, purpose: .selectedWorkshop(item))
                updateInputQuiesced()
            } catch is CancellationError {} catch {
                if snapshot?.session == launch, snapshot?.epoch == lease {
                    sourceFailure = (error as? LocalizedError)?.errorDescription ?? "Steam's selected Workshop layout could not be loaded. Retry when Steam is reachable; the selection is preserved."
                }
            }
        }
    }
    private static func expireRestartWait() {
        // The selected-item lookup is part of baseline recovery too. Keep the
        // same bounded recovery budget while its network work is still pending.
        let recovering = bootstrap != nil || workshopTask != nil
        if let started = restartWaitStarted, Date().timeIntervalSince(started) > (recovering ? 120 : 30) {
            restartAttempted = true
            SteamLog.event("[steam-input] working baseline unavailable for restart")
        }
    }
#if DEBUG
    /// Scoped test mailbox for exercising the real app journal/submit/restart
    /// path before the layout UI exists. No arbitrary source names or paths.
    /// Action 1 selects the fixed synthetic fixture only with no explicit choice;
    /// action 2 restores the captured Steam baseline and clears the test override
    /// only after its exact successful receipt. Release builds omit this code.
    private static func refreshLocalDiagnostic(_ current: DockSteamInputWire.Snapshot) {
        guard attempts == 3, pending == nil, submission == nil, prepared == nil, recovery == nil,
              current.connected, current.flags & 48 == 48, let journal, let saved = selection else { return }
        let marker = MadeiraDock.drive.appendingPathComponent("madeira-steam-input-local-test.bin")
        guard let markerFile = try? FileHandle(forReadingFrom: marker) else { return }
        let bytes = try? markerFile.read(upToCount: 45); try? markerFile.close()
        guard let bytes, bytes.count == 44 else { try? FileManager.default.removeItem(at: marker); return }
        var request = sh_input_command()
        let valid = bytes.withUnsafeBytes { sh_input_command_parse($0.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count, &request) }
        let nonce = withUnsafeBytes(of: request.session) { Array($0) }
        guard valid, nonce == session, request.appid == appID, request.controller == 0,
              request.epoch == current.epoch, request.sequence > diagnosticSequence else {
            try? FileManager.default.removeItem(at: marker); return
        }
        guard let file = try? FileHandle(forReadingFrom: baselineFile) else { return }
        let frame = try? file.read(upToCount: (1 << 20) + 44); try? file.close()
        guard let frame, let baseline = DockSteamInputTransport.baseline(frame, session: session, appID: appID, epoch: current.epoch) else { return }
        diagnosticSequence = request.sequence
        try? FileManager.default.removeItem(at: marker)
        do {
            if request.action == 1 {
                guard saved.requested == nil else { throw DockSteamInputJournal.Failure.busy }
                let fixture = MadeiraDock.clientRoot.appendingPathComponent("controller_base/templates/madeira_m1_revision_probe.vdf")
                let sourceFile = try FileHandle(forReadingFrom: fixture); defer { try? sourceFile.close() }
                guard let source = try sourceFile.read(upToCount: 1 << 20), source.count < 1 << 20 else { throw DockSteamInputJournal.Failure.invalid }
                _ = try prepareLocal(source: source, baseline: baseline,
                    choice: .init(source: .template, identity: "madeira_m1_revision_probe.vdf", contentHash: nil))
            } else if request.action == 2 {
                guard saved.requested?.identity == "madeira_m1_revision_probe.vdf",
                      activeChoice?.identity == "madeira_m1_revision_probe.vdf" else { throw DockSteamInputJournal.Failure.stale }
                _ = try prepareBaselineRestore(baseline: baseline)
            } else if request.action == 3 {
                guard saved.requested?.identity == "madeira_m1_revision_probe.vdf",
                      activeChoice?.identity == "madeira_m1_revision_probe.vdf" else { throw DockSteamInputJournal.Failure.stale }
                _ = try prepareBaselineRestore(baseline: Data("controller_mappings { revision 0 wrong baseline }".utf8))
            } else if request.action == 4 {
                guard saved.requested?.identity == "madeira_m1_revision_probe.vdf",
                      activeChoice?.identity == "madeira_m1_revision_probe.vdf" else { throw DockSteamInputJournal.Failure.stale }
                _ = try prepareBaselineRestore(baseline: baseline)
                try journal.interrupt()
                recovery = try journal.snapshot().pending
                prepared = nil; preparedChoice = nil; preparedReapplication = false; preparedClearOverride = false
                updateInputQuiesced()
                restartAttempted = false; restartWaitStarted = nil
                return
            } else { throw DockSteamInputJournal.Failure.invalid }
            try submitPrepared()
        } catch { SteamLog.event("[steam-input] local diagnostic request unavailable") }
    }
#endif
    static func refresh() {
        guard session.count == 16, let file = try? FileHandle(forReadingFrom: feed) else { return }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: DockSteamInputWire.maxFeedSize + 1),
              let current = DockSteamInputWire.parse(data), current.session == session,
              current.appID == appID else { return }
        snapshot = current
        if !current.connected || current.state == .failed { activeChoice = nil; receipt = nil }
        if epoch != current.epoch {
            if prepared != nil || submission != nil {
                do {
                    try journal?.interrupt()
                    recovery = try journal?.snapshot().pending
                } catch {
                    journal = nil
                    SteamLog.event("[steam-input] layout connection recovery unavailable")
                }
                prepared = nil; preparedChoice = nil; submission = nil; receipt = nil
                updateInputQuiesced()
            }
            activeChoice = nil
            if current.connected {
                restartAttempted = false
                restartEpoch = current.epoch
                restartWaitStarted = nil
            }
            epoch = current.epoch; attempts = 0; pending = nil
            noSavedSelection = false; bootstrapAutoTried = false; bootstrap = nil
            workshopTask?.cancel(); workshopTask = nil; workshopAttempted = false; sourceFailure = nil
        }
        sequence = max(sequence, current.sequence)
        refreshSubmission(current)
        if let request = pending {
            if current.sequence == request.sequence {
                pending = nil
                if current.result == 1, current.connected, current.flags & 8 == 0,
                   (!current.selection.isEmpty || current.workshopID != 0), var saved = selection {
                    saved.retainSteamSelection(.init(key: current.selection, workshopID: current.workshopID))
                    do { try saved.save(in: storage); selection = saved }
                    catch { SteamLog.event("[steam-input] selection migration not saved") }
                }
                // A successful empty selection is still a completed query.
                // An unavailable client answer may be transient; retry within
                // the existing three-attempt bound without migrating its data.
                if current.result != 4 && !(current.result == 1 && current.flags & 64 != 0 && context(appID: appID) == nil) { attempts = 3 }
                if current.result == 4, attempts >= 3 { noSavedSelection = true }
                // A named layout or Workshop item that Dock cannot read is still
                // Steam's selection; only an empty answer means there is none.
                if current.result == 1 { noSavedSelection = current.selection.isEmpty && current.workshopID == 0 }
            } else if Date().timeIntervalSince(request.sent) > 10 { pending = nil }
        }
        refreshSelectedWorkshop(current)
        refreshBootstrap(current)
        updateInputQuiesced()
        refreshRestart(current)
#if DEBUG
        refreshLocalDiagnostic(current)
#endif
        guard pending == nil, submission == nil, attempts < 3, current.connected, current.flags & 1 != 0,
              sequence < UInt32.max else { return }
        sequence += 1; attempts += 1
        guard let bytes = DockSteamInputWire.command(.query, snapshot: current, sequence: sequence) else { return }
        do {
            try bytes.write(to: command, options: .atomic)
            pending = (sequence, Date())
        } catch { SteamLog.event("[steam-input] query not written") }
    }
}

/// Persisted Steam Input choices are independent of ControllerSetup and Steam's
/// own selection. This store does not claim that queuing a layout activates it.
struct DockSteamInputSelection: Codable, Equatable {
    enum Source: String, Codable { case gameDefault, community, personal, template }
    struct Revision: Codable, Equatable {
        let source: Source
        /// Workshop ID, personal UUID or template key; nil for Game default.
        let identity: String?
        /// SHA-256 of the exact VDF bytes, absent until a source is resolved.
        let contentHash: String?
        /// Display provenance is retained alongside the hash-bound choice.
        /// Older version-1 records decode without it; no paths or account data.
        var detail: String? = nil
    }
    struct SteamSelection: Codable, Equatable {
        let key: String
        let workshopID: UInt64
    }
    let version: Int
    let accountID: UInt32
    let appID: UInt32
    /// Stable Madeira controller identity, never a transient Steam slot index.
    let controllerID: UUID
    private(set) var generation: UInt64
    private(set) var requested: Revision?
    private(set) var observedSteamSelection: SteamSelection?
    private(set) var lastActivated: Revision?

    init(accountID: UInt32, appID: UInt32, controllerID: UUID) {
        version = 1
        self.accountID = accountID
        self.appID = appID
        self.controllerID = controllerID
        generation = 0
    }

    /// Migration records what Steam selected without manufacturing a Madeira
    /// choice or overwriting an earlier observation.
    mutating func retainSteamSelection(_ selection: SteamSelection) {
        if observedSteamSelection == nil { observedSteamSelection = selection }
    }

    mutating func request(_ revision: Revision) throws {
        guard Self.valid(revision), generation < UInt64.max else { throw StoreError.invalid }
        generation += 1
        requested = revision
    }

    /// Relinquish an explicit override after a verified restoration. Historical
    /// acknowledgement remains separate; nil intent does not reapply on restart.
    mutating func clearRequest() throws {
        guard generation < UInt64.max else { throw StoreError.invalid }
        generation += 1; requested = nil
    }

    /// Only a verified active-revision response may call this. A generic cache
    /// hit or ActivateConfig invocation is insufficient. Stale replies cannot
    /// change the last working revision.
    mutating func acknowledge(_ revision: Revision, generation: UInt64) throws {
        guard generation == self.generation, requested == revision,
              revision.contentHash != nil else { throw StoreError.stale }
        lastActivated = revision
    }

    enum StoreError: Error { case invalid, stale, unsupportedVersion }

    private static func valid(_ revision: Revision) -> Bool {
        if let detail = revision.detail {
            guard !detail.isEmpty, detail.utf8.count <= 512,
                  !detail.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        }
        if let hash = revision.contentHash {
            guard hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        }
        if revision.source == .gameDefault { return revision.identity == nil }
        guard let identity = revision.identity, !identity.isEmpty,
              identity.utf8.count <= 256,
              !identity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        if revision.source == .community {
            guard let id = UInt64(identity), id > 0, String(id) == identity else { return false }
        }
        if revision.source == .personal { return UUID(uuidString: identity) != nil }
        return true
    }

    private func validate() throws {
        guard version == 1 else { throw StoreError.unsupportedVersion }
        guard accountID > 0, appID > 0,
              requested.map(Self.valid) ?? true,
              lastActivated.map({ Self.valid($0) && $0.contentHash != nil }) ?? true,
              observedSteamSelection.map({ $0.key.utf8.count <= 4096 }) ?? true else { throw StoreError.invalid }
    }

    /// Caller supplies a private app storage root. Scope is encoded in the
    /// filename; no layout keys or externally supplied paths are used as paths.
    private func file(in root: URL) -> URL {
        root.appendingPathComponent("steam-input-selections", isDirectory: true)
            .appendingPathComponent("\(accountID)-\(appID)-\(controllerID.uuidString).json")
    }

    func save(in root: URL) throws {
        try validate()
        let url = file(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func load(in root: URL, accountID: UInt32, appID: UInt32, controllerID: UUID) throws -> Self {
        let empty = Self(accountID: accountID, appID: appID, controllerID: controllerID)
        try empty.validate()
        let url = empty.file(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 16384 else { throw StoreError.invalid }
        let stored = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try stored.validate()
        guard stored.accountID == accountID, stored.appID == appID,
              stored.controllerID == controllerID else { throw StoreError.invalid }
        return stored
    }
}

/// Human-readable state for one game. Only a current-session, hash-bound
/// receipt can describe a Madeira choice as active; Steam's saved selection
/// and cache/activation requests are reported separately.
enum DockSteamInputPresentation {
    static func name(_ choice: DockSteamInputSelection.Revision) -> String {
        switch choice.source {
        case .gameDefault: return "Game default"
        case .community: return "Community layout"
        case .personal: return "Personal layout"
        case .template: return "Generic template"
        }
    }
    static func lines(appID: UInt32, snapshot: DockSteamInputWire.Snapshot?,
                      active: DockSteamInputSelection.Revision?, selection: DockSteamInputSelection?) -> [String] {
        guard let snapshot, snapshot.appID == appID else { return ["Launch this game to see its Steam Input status."] }
        guard snapshot.connected else { return ["Controller disconnected."] }
        var lines: [String] = []
        let confirmed = snapshot.state == .failed ? nil : active
        if let confirmed {
            lines.append("Active: \(name(confirmed)).")
            if let detail = confirmed.detail { lines.append("Source: \(detail).") }
            lines.append(confirmed.source == .gameDefault ? "Default override: none." : "Default override: \(name(confirmed)).")
        } else if snapshot.state == .failed {
            lines.append("The layout is unavailable; no active layout is confirmed.")
        } else {
            lines.append("No active layout is confirmed for this session.")
        }
        if snapshot.result == 1 {
            if snapshot.workshopID != 0 { lines.append("Steam selection: Workshop item \(snapshot.workshopID).") }
            else if !snapshot.selection.isEmpty {
                let source = snapshot.selection.hasPrefix("AC-") ? "personal layout" :
                    (snapshot.selection.hasPrefix("template://") || snapshot.selection.hasSuffix(".vdf") ? "saved layout" : "saved selection")
                lines.append("Steam selection: \(source); active revision not confirmed.")
            }
        }
        if let selection, selection.appID == appID, let requested = selection.requested, requested != confirmed {
            lines.append("Requested: \(name(requested)); not yet confirmed.")
        }
        return lines
    }
}

extension DockSteamInputPresentation {
    /// One headline for the Steam Input controls (milestone 5 item 4), the
    /// same in Game details and the session menu.
    enum State: Equatable {
        case notRunning(saved: DockSteamInputSelection.Revision?)
        case disconnected
        case loading
        case downloading
        case held
        case applying(DockSteamInputSelection.Revision?)
        case active(DockSteamInputSelection.Revision)
        case rolledBack
        case failed
        case noLayout
        case unconfirmed

        var text: String {
            switch self {
            case .notRunning(let saved?):
                return "Chosen: \(DockSteamInputPresentation.name(saved)). It is applied when the game starts."
            case .notRunning(nil): return "Chosen: Game default (Steam's saved layout for this game)."
            case .disconnected: return "Controller disconnected. The layout comes back when it reconnects."
            case .loading: return "Loading the layout into Steam Input…"
            case .downloading: return "Downloading Steam's selected Workshop layout…"
            case .held: return "Needs your confirmation: the saved layout was made for another controller."
            case .applying(let choice?): return "Applying \(DockSteamInputPresentation.name(choice))… waiting for Steam Input to confirm."
            case .applying(nil): return "Applying a layout… waiting for Steam Input to confirm."
            case .active(let choice): return "Active: \(DockSteamInputPresentation.name(choice))."
            case .rolledBack: return "The change failed. Steam Input restored the previous layout."
            case .failed: return "The layout could not be applied. Your saved choice is kept; retry or relaunch."
            case .noLayout: return "No layout is loaded yet. Choose one below."
            case .unconfirmed: return "Steam's own layout is loaded."
            }
        }
        /// Attention states read in orange or red.
        var severity: Int {
            switch self {
            case .held, .rolledBack: return 1
            case .failed: return 2
            default: return 0
            }
        }
    }
    @MainActor static func state(appID: UInt32, saved: DockSteamInputSelection.Revision?) -> State {
        let service = DockSteamInputService.self
        guard let snapshot = service.snapshot, snapshot.appID == appID else { return .notRunning(saved: saved) }
        guard snapshot.connected else { return .disconnected }
        if service.held != nil { return .held }
        if service.resolvingWorkshop { return .downloading }
        if service.bootstrapping { return .loading }
        if service.prepared != nil || service.submittingChoice != nil { return .applying(service.submittingChoice) }
        // A receipt lasts until the next change is sent.
        if let receipt = service.receipt {
            if receipt.phase == .rolledBack { return .rolledBack }
            if receipt.phase == .failed { return .failed }
        }
        if let active = service.activeChoice, snapshot.state != .failed { return .active(active) }
        if service.sourceFailure != nil { return .failed }
        // Dock's own load did not produce a layout: either nothing is saved
        // (choose one) or the saved one is still being re-applied.
        if snapshot.state == .failed { return service.canBootstrap ? .noLayout : .loading }
        return .unconfirmed
    }
}

extension DockSteamInputPresentation {
    struct DefaultActions: Equatable {
        var note: String
        var offerDefault = false
        var offerGeneric = false
        var offerRetry = false
    }
    /// What the player may do about the game's default. A generic template is
    /// offered only when no recommendation was resolved, never as the game's own.
    static func defaultActions(_ resolution: DockSteamInputDefault.Resolution?,
                               active: DockSteamInputSelection.Revision?) -> DefaultActions {
        guard let resolution else { return .init(note: "Checking this game's recommended layout.") }
        var actions = DefaultActions(note: DockSteamInputDefault.explanation(resolution))
        switch resolution {
        case .recommended(let value):
            let current = active?.source == .gameDefault && active?.contentHash == value.contentHash
            actions.offerDefault = !current
            if current { actions.note += " It is active." }
            else if active != nil { actions.note += " Another layout is active." }
        case .noRecommendation:
            actions.offerGeneric = !(active?.source == .template && SteamInputController.allCases.contains { $0.genericTemplate == active?.identity })
            actions.note += " Steam's generic Gamepad template is available, but it is not this game's own layout."
        case .noHint:
            actions.offerRetry = true
        case .unresolved(let reason):
            actions.offerRetry = true
            if [.manifestUnsupported, .templateUnsupported, .workshopIncompatible].contains(reason) {
                actions.offerGeneric = !(active?.source == .template && SteamInputController.allCases.contains { $0.genericTemplate == active?.identity })
                actions.note += " Steam's generic Gamepad template is available, but it is not this game's own layout."
            }
        }
        return actions
    }
}

/// Steam Input's controller settings for a Dock launch (docs/STEAM_INPUT.md).
/// Valve's client reads `SteamController_PSSupport` from the account's
/// localconfig.vdf (top level of UserLocalConfigStore: 1 games without
/// PlayStation support, the default; 2 every game) when it starts, and only
/// with 2 does it open a PlayStation pad. For the Xbox identity it also needs
/// `SteamController_XBoxSupport`, which January reads as a boolean (the
/// client-wide controller mask gains bit 2 when it is true; steamclient64
/// 0x5d38c6). Before a Steam Input launch the keys are set; when the Dock
/// session ends each line is put back as it was. The previous state is noted
/// in Documents, so a crash is undone at the next launch. Only these lines
/// of the file change.
enum DockSteamInput {
    static let key = "SteamController_PSSupport"
    static let xboxKey = "SteamController_XBoxSupport"
    private static let every = "2"
    private static var note: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-steam-input.json")
    }
    /// `previous` is the PlayStation key's earlier value (the note's original
    /// shape); `others` holds any other key changed for the same launch.
    private struct Note: Codable {
        var file: String
        var previous: String?
        var others: [Other]? = nil
        struct Other: Codable { var key: String; var previous: String? }
    }

    static func localConfig(steamID: UInt64) -> URL {
        MadeiraDock.clientRoot.appendingPathComponent("userdata/\(steamID & 0xffff_ffff)/config/localconfig.vdf")
    }

    /// The key's value at the top level of UserLocalConfigStore, nil when absent.
    /// Throws when the file is not laid out as expected.
    static func value(in text: String, key: String = key) throws -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let (open, close) = try block(lines)
        return top(lines, open: open, close: close).lazy.compactMap { entry(lines[$0], key: key) }.first
    }

    /// The text with the key set to `value` (nil removes the line).
    static func setting(_ value: String?, in text: String, key: String = key) throws -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let (open, close) = try block(lines)
        if let at = top(lines, open: open, close: close).first(where: { entry(lines[$0], key: key) != nil }) {
            if let value { lines[at] = "\t\"\(key)\"\t\t\"\(value)\"" } else { lines.remove(at: at) }
        } else if let value {
            lines.insert("\t\"\(key)\"\t\t\"\(value)\"", at: open + 1)
        }
        return lines.joined(separator: newline)
    }

    /// Before the launch: the PlayStation key goes to 2 when `enabled`, and
    /// the Xbox key to 1 when the launch presents the Xbox identity; any
    /// earlier change still noted (a crash) is undone first.
    static func prepare(steamID: UInt64, enabled: Bool, controller: SteamInputController = .dualSense) throws {
        guard restore() else { throw Layout() }
        guard enabled else { return }
        let url = localConfig(steamID: steamID)
        let fm = FileManager.default
        var text = fm.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8) : "\"UserLocalConfigStore\"\n{\n}\n"
        let previous = try value(in: text)
        var others: [Note.Other] = []
        var changed = false
        if previous != every { text = try setting(every, in: text); changed = true }
        if controller == .xbox {
            let earlier = try value(in: text, key: xboxKey)
            if earlier != "1" {
                text = try setting("1", in: text, key: xboxKey); changed = true
                others.append(.init(key: xboxKey, previous: earlier))
            }
        }
        guard changed else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Persist recovery before touching the client's settings. Failed writes
        // keep the note so the next launch can finish restoring the old value.
        try JSONEncoder().encode(Note(file: url.path, previous: previous, others: others.isEmpty ? nil : others))
            .write(to: note, options: .atomic)
        try text.write(to: url, atomically: true, encoding: .utf8)
        SteamLog.event("[steam-input] PlayStation support enabled for this launch"
                       + (others.isEmpty ? "" : "; Xbox support enabled for this launch"))
    }

    /// After the client has shut down. Keep recovery information if it fails.
    @discardableResult static func restore() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: note.path) else { return true }
        do {
            let saved = try JSONDecoder().decode(Note.self, from: Data(contentsOf: note))
            let url = URL(fileURLWithPath: saved.file)
            // A first-account write can fail after journaling but before the
            // file exists. The previous absent keys are already restored then.
            if saved.previous == nil, (saved.others ?? []).allSatisfy({ $0.previous == nil }),
               !fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: note)
                return true
            }
            var text = try String(contentsOf: url, encoding: .utf8)
            text = try setting(saved.previous, in: text)
            for other in saved.others ?? [] where [xboxKey].contains(other.key) {
                text = try setting(other.previous, in: text, key: other.key)
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fm.removeItem(at: note)
            SteamLog.event("[steam-input] PlayStation setting restored")
            return true
        } catch {
            SteamLog.event("[steam-input] PlayStation setting restoration pending")
            return false
        }
    }

    private struct Layout: Error, LocalizedError { var errorDescription: String? { "unexpected localconfig.vdf layout" } }

    /// The `{` and matching `}` line indices of UserLocalConfigStore.
    private static func block(_ lines: [String]) throws -> (Int, Int) {
        guard let name = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "\"UserLocalConfigStore\"" }),
              name + 1 < lines.count, lines[name + 1].trimmingCharacters(in: .whitespaces) == "{" else { throw Layout() }
        var level = 0
        for i in (name + 1)..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "{" { level += 1 } else if t == "}" { level -= 1; if level == 0 { return (name + 1, i) } }
        }
        throw Layout()
    }

    /// The indices of the block's top-level lines (not inside a nested block).
    private static func top(_ lines: [String], open: Int, close: Int) -> [Int] {
        var level = 0, out: [Int] = []
        for i in (open + 1)..<close {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "{" { level += 1 } else if t == "}" { level -= 1 } else if level == 0 { out.append(i) }
        }
        return out
    }

    /// The value when `line` is `"<key>" "v"`.
    private static func entry(_ line: String, key: String) -> String? {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "\"")
        // "", key, whitespace, "", value, ""
        guard parts.count == 5, parts[0].isEmpty, parts[1] == key, parts[2].trimmingCharacters(in: .whitespaces).isEmpty,
              parts[4].isEmpty else { return nil }
        return parts[3]
    }
}
