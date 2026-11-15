// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Revision history, drafts, the editing lifecycle and recovery of personal
/// layouts. Every write is crash safe: revision bytes are content-addressed
/// files written before `layout.json` names them, and `layout.json` is
/// replaced atomically, so it is the single point at which a save, rename,
/// restore or recovery takes effect. A crash before that leaves the previous
/// state; files it left behind are removed by `cleanUp`.
extension SteamInputPersonalCopy {
    enum LifecycleFailure: LocalizedError, Equatable {
        case notALayout(String)
        case inUse(String)
        case busy
        case missingRevision
        case nothingToRecover
        case invalidTitle
        case tooMany

        var errorDescription: String? {
            switch self {
            case .notALayout(let reason): return "The layout was not saved. " + reason
            case .inUse(let reason): return reason
            case .busy: return "A change to this layout is waiting for Steam Input to confirm it. Try again when it finishes."
            case .missingRevision: return "That revision is no longer stored on this device."
            case .nothingToRecover: return "No readable revision of this layout is left on this device. Export or delete it."
            case .invalidTitle: return "Enter a name of up to 160 characters without control characters."
            case .tooMany: return "This game already has the most personal layouts Madeira keeps."
            }
        }
    }

    /// One entry of the personal layout folder: a usable layout, or a
    /// damaged one with what is wrong and the recovery it offers.
    struct Listing: Identifiable, Equatable {
        let id: UUID
        let copy: SteamInputPersonalCopy?
        /// Nil for a layout that reads and verifies.
        let problem: String?
        var title: String { copy?.title ?? "Damaged layout" }
    }

    /// A draft: edits not yet saved as a revision, kept across restarts.
    struct Draft: Codable, Equatable {
        var version = 1
        /// The revision the edits started from.
        let base: String
        let hash: String
        let saved: Date
    }

    // MARK: Validation and naming

    static func checkedTitle(_ title: String) throws -> String {
        let value = String(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !value.isEmpty, value.count <= 160, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LifecycleFailure.invalidTitle
        }
        return value
    }

    /// Bytes saved as a revision must be a version 3 layout the editor and the
    /// native reader both read. A revision that cannot be applied yet (a broken
    /// reference while editing, an input Madeira cannot forward) can still be
    /// saved: applying it is refused with the reason, as for any layout.
    static func checkedLayout(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= SteamInputCommunitySources.limit else { throw LifecycleFailure.notALayout("It is empty or too large.") }
        do {
            let draft = try SteamInputLayoutDraft(bytes: bytes)
            if let reason = draft.notEditableReason { throw LifecycleFailure.notALayout(reason) }
            // The same refusal as every apply and import: conditions are never evaluated.
            if !draft.model.conditionSites.isEmpty { throw LifecycleFailure.notALayout("Conditional layouts are not supported yet.") }
            _ = try DockSteamInputNative.revision(bytes)
        } catch let failure as LifecycleFailure { throw failure }
        catch { throw LifecycleFailure.notALayout("It is not a Steam Input layout Madeira can read.") }
    }

    /// The history as stored, or the single revision a version 1 record holds.
    var revisions: [HistoryEntry] {
        history ?? [HistoryEntry(hash: hash, saved: imported ?? origin?.downloaded ?? Date(timeIntervalSince1970: 0), note: origin == nil ? "Imported" : "Copied")]
    }

    // MARK: Files

    @MainActor private func writeObject(_ bytes: Data, root: URL) throws -> String {
        let hash = DockSteamInputNative.contentHash(bytes)
        let url = directory(root).appendingPathComponent("revisions/\(hash).vdf")
        if FileManager.default.fileExists(atPath: url.path) || (try? self.bytes(of: hash, root: root)) != nil {
            // Already stored: content-addressed, so the bytes must match.
            guard (try? self.bytes(of: hash, root: root)) == bytes else { throw SteamInputCommunitySources.Failure.invalid }
            return hash
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        guard try self.bytes(of: hash, root: root) == bytes else { throw SteamInputCommunitySources.Failure.invalid }
        return hash
    }

    /// Replaces `layout.json` atomically: the commit point of every change.
    @MainActor func writeRecord(root: URL) throws {
        var record = self
        record.version = 2
        guard record.isValid(id: id, in: shelf(root)) else { throw SteamInputCommunitySources.Failure.invalid }
        let encoded = try JSONEncoder().encode(record)
        guard encoded.count <= 256 << 10 else { throw SteamInputCommunitySources.Failure.invalid }
        try encoded.write(to: directory(root).appendingPathComponent("layout.json"), options: .atomic)
    }

    /// The record as stored now: every change starts from it, so two pages
    /// editing the same layout cannot overwrite each other's work unseen.
    @MainActor func reloaded(root: URL) throws -> Self {
        let url = directory(root).appendingPathComponent("layout.json")
        let value = try JSONDecoder().decode(Self.self, from: SteamInputCommunitySources.read(url, limit: 256 << 10))
        guard value.isValid(id: id, in: shelf(root)) else { throw SteamInputCommunitySources.Failure.invalid }
        return value
    }

    // MARK: Listing

    /// Every personal layout of the account and game, damaged ones included,
    /// so each can be recovered or deleted. Interrupted work is cleaned first.
    @MainActor static func inventory(_ shelf: SteamInputPersonalShelf) throws -> [Listing] {
        guard shelf.accountID > 0, shelf.appID > 0 else { return [] }
        let directory = shelf.folder
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count <= 1024 else { throw SteamInputCommunitySources.Failure.invalid }
        var listings: [Listing] = []
        for url in children {
            let name = url.lastPathComponent
            // Interrupted creations and deletions: never a layout.
            if name.hasPrefix(".") {
                if name.hasSuffix(".tmp") || name.hasPrefix(".deleted-") { try? FileManager.default.removeItem(at: url) }
                continue
            }
            guard let id = UUID(uuidString: name) else { continue }
            do {
                let value = try JSONDecoder().decode(Self.self, from: SteamInputCommunitySources.read(url.appendingPathComponent("layout.json"), limit: 256 << 10))
                guard value.isValid(id: id, in: shelf) else { throw SteamInputCommunitySources.Failure.invalid }
                do { _ = try value.bytes(root: shelf.root) }
                catch {
                    listings.append(Listing(id: id, copy: value, problem: "Its current revision is missing or was changed outside Madeira."))
                    continue
                }
                listings.append(Listing(id: id, copy: value, problem: nil))
            } catch {
                listings.append(Listing(id: id, copy: nil, problem: "Its record cannot be read."))
            }
        }
        return listings.sorted {
            if ($0.problem == nil) != ($1.problem == nil) { return $0.problem == nil }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    // MARK: Creation

    /// A new personal layout from bytes the caller obtained: the game's
    /// default, a Steam template or a recovered file. The bytes must pass the
    /// same check as an import; nothing is selected or applied.
    @MainActor static func create(from bytes: Data, title: String, creation: Creation, in shelf: SteamInputPersonalShelf,
                                  now: Date = Date()) throws -> Self {
        guard shelf.accountID > 0 else { throw ImportFailure.noAccount }
        guard shelf.appID > 0, !bytes.isEmpty else { throw ImportFailure.notALayout }
        guard bytes.count <= SteamInputCommunitySources.limit else { throw ImportFailure.tooLarge }
        do { _ = try SteamInputCompatibility(bytes) }
        catch is SteamInputCommunitySources.Failure { throw ImportFailure.notALayout }
        catch SteamFileError.invalid(let reason) { throw ImportFailure.invalidLayout(reason) }
        let title = try checkedTitle(String(title.prefix(160)))
        guard (try? inventory(shelf).count) ?? limit < limit else { throw LifecycleFailure.tooMany }
        let hash = DockSteamInputNative.contentHash(bytes)
        var copy = Self(id: UUID(), accountID: shelf.accountID, appID: shelf.appID, title: title, origin: nil, hash: hash)
        copy.version = 2
        copy.creation = creation
        copy.history = [HistoryEntry(hash: hash, saved: now, note: "Created")]
        try copy.store(bytes, root: shelf.root)
        return copy
    }

    /// A separate layout with the current revision's exact bytes and a new identity.
    @MainActor func duplicate(title: String? = nil, root: URL, now: Date = Date()) throws -> Self {
        let current = try reloaded(root: root)
        let bytes = try current.bytes(root: root)
        let name = try Self.checkedTitle(String((title ?? current.title + " copy").prefix(160)))
        guard (try? Self.inventory(shelf(root)).count) ?? Self.limit < Self.limit else { throw LifecycleFailure.tooMany }
        var copy = Self(id: UUID(), accountID: accountID, appID: appID, title: name, origin: nil, hash: current.hash)
        copy.version = 2
        copy.creation = Creation(kind: .duplicate, detail: String(current.title.prefix(120)), from: id)
        copy.history = [HistoryEntry(hash: current.hash, saved: now, note: "Duplicated")]
        try copy.store(bytes, root: root)
        return copy
    }

    @MainActor func renamed(_ title: String, root: URL) throws -> Self {
        var value = try reloaded(root: root)
        value.title = try Self.checkedTitle(title)
        try value.writeRecord(root: root)
        return value
    }

    // MARK: Saving and history

    /// Saves `bytes` as the new current revision. Nothing is applied; the
    /// revision the game uses stays as it is until the player applies again.
    @MainActor func saving(_ bytes: Data, note: String = "Saved", references: SteamInputPersonalReferences, root: URL, now: Date = Date()) throws -> Self {
        try Self.checkedLayout(bytes)
        var value = try reloaded(root: root)
        guard value.pending == nil else { throw LifecycleFailure.busy }
        let hash = try value.writeObject(bytes, root: root)
        if hash != value.hash {
            value.history = value.revisions + [HistoryEntry(hash: hash, saved: now, note: String(note.prefix(200)))]
            value.hash = hash
            value.trimHistory()
            try value.writeRecord(root: root)
        }
        if let draft = try? value.draft(root: root), draft.hash == hash { try value.discardDraft(root: root) }
        try value.cleanUp(references: references, root: root)
        return value
    }

    /// Makes an earlier revision current again, as a new history entry; the
    /// revisions after it are kept.
    @MainActor func restoring(_ revision: HistoryEntry, references: SteamInputPersonalReferences, root: URL, now: Date = Date()) throws -> Self {
        let bytes: Data
        do { bytes = try self.bytes(of: revision.hash, root: root) } catch { throw LifecycleFailure.missingRevision }
        return try saving(bytes, note: "Restored revision from " + revision.saved.formatted(date: .abbreviated, time: .shortened),
                          references: references, root: root, now: now)
    }

    private mutating func trimHistory() {
        guard var entries = history, entries.count > Self.historyLimit else { return }
        entries.removeFirst(entries.count - Self.historyLimit)
        history = entries
    }

    /// Removes revision files nothing refers to: not in the history, not the
    /// current or pending revision, not a revision the saved selection names
    /// (the one the game uses stays until a replacement is confirmed), not the
    /// first stored file, not the draft. Does nothing when the selection is unknown.
    @MainActor func cleanUp(references: SteamInputPersonalReferences, root: URL) throws {
        guard references.known else { return }
        let folder = directory(root).appendingPathComponent("revisions")
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        var keep = Set(revisions.map(\.hash)).union([hash]).union(references.retained(id))
        if let pending { keep.insert(pending) }
        if let draft = try? draft(root: root) { keep.insert(draft.base) }
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.hasSuffix(".vdf"), !keep.contains(String(name.dropLast(4))) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Drafts

    private func draftRecordURL(_ root: URL) -> URL { directory(root).appendingPathComponent("draft.json") }

    /// Keeps unsaved edits across restarts. The bytes are written before the
    /// record that names them, so a crash leaves the previous draft or none.
    @MainActor func savingDraft(_ bytes: Data, base: String, root: URL, now: Date = Date()) throws {
        guard Self.validHash(base), !bytes.isEmpty, bytes.count <= SteamInputCommunitySources.limit else { throw SteamInputCommunitySources.Failure.invalid }
        let hash = DockSteamInputNative.contentHash(bytes)
        let url = directory(root).appendingPathComponent("draft-\(hash).vdf")
        try bytes.write(to: url, options: .atomic)
        try JSONEncoder().encode(Draft(base: base, hash: hash, saved: now)).write(to: draftRecordURL(root), options: .atomic)
        for other in try FileManager.default.contentsOfDirectory(at: directory(root), includingPropertiesForKeys: nil)
            where other.lastPathComponent.hasPrefix("draft-") && other.lastPathComponent != url.lastPathComponent {
            try? FileManager.default.removeItem(at: other)
        }
    }

    /// The saved draft, nil when there is none; throws for a damaged one,
    /// which the editor offers to discard.
    @MainActor func draft(root: URL) throws -> Draft? {
        let url = draftRecordURL(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Draft.self, from: SteamInputCommunitySources.read(url, limit: 4096))
        guard value.version == 1, Self.validHash(value.base), Self.validHash(value.hash) else { throw SteamInputCommunitySources.Failure.invalid }
        return value
    }

    @MainActor func draftBytes(_ draft: Draft, root: URL) throws -> Data {
        let bytes = try SteamInputCommunitySources.read(directory(root).appendingPathComponent("draft-\(draft.hash).vdf"), limit: SteamInputCommunitySources.limit)
        guard DockSteamInputNative.contentHash(bytes) == draft.hash else { throw SteamInputCommunitySources.Failure.invalid }
        return bytes
    }

    @MainActor func discardDraft(root: URL) throws {
        try? FileManager.default.removeItem(at: draftRecordURL(root))
        for other in try FileManager.default.contentsOfDirectory(at: directory(root), includingPropertiesForKeys: nil)
            where other.lastPathComponent.hasPrefix("draft-") {
            try FileManager.default.removeItem(at: other)
        }
    }

    // MARK: Deletion

    /// Deletes a layout that nothing uses. The folder is first renamed out of
    /// the listing in one step, so a crash leaves the layout or nothing.
    @MainActor static func delete(_ id: UUID, from shelf: SteamInputPersonalShelf, references: SteamInputPersonalReferences) throws {
        if let reason = references.blocksDeletion(id) { throw LifecycleFailure.inUse(reason) }
        let parent = shelf.folder
        let url = parent.appendingPathComponent(id.uuidString)
        if let record = try? JSONDecoder().decode(Self.self, from: SteamInputCommunitySources.read(url.appendingPathComponent("layout.json"), limit: 256 << 10)),
           record.pending != nil {
            throw LifecycleFailure.busy
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let trash = parent.appendingPathComponent(".deleted-\(id.uuidString)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: trash)
        try? FileManager.default.removeItem(at: trash)
    }

    // MARK: Recovery

    /// Repairs a damaged layout in place, under the same identity: the newest
    /// readable revision becomes current, and every revision that still reads
    /// is kept in the history. A record that cannot be read is rebuilt.
    /// Nothing is applied.
    @MainActor static func recover(_ id: UUID, in shelf: SteamInputPersonalShelf, now: Date = Date()) throws -> Self {
        let root = shelf.root
        let url = shelf.folder.appendingPathComponent(id.uuidString)
        let record = try? JSONDecoder().decode(Self.self, from: SteamInputCommunitySources.read(url.appendingPathComponent("layout.json"), limit: 256 << 10))
        let usable = record.flatMap { $0.isValid(id: id, in: shelf) ? $0 : nil }
        var base = usable ?? Self(id: id, accountID: shelf.accountID, appID: shelf.appID, title: record?.title.isEmpty == false ? String(record!.title.prefix(160)) : "Recovered layout",
                                  origin: nil, hash: String(repeating: "0", count: 64))
        func readable(_ file: URL) -> (hash: String, bytes: Data, date: Date)? {
            guard let bytes = try? SteamInputCommunitySources.read(file, limit: SteamInputCommunitySources.limit),
                  (try? checkedLayout(bytes)) != nil else { return nil }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            return (DockSteamInputNative.contentHash(bytes), bytes, date ?? now)
        }
        // History entries first, in order; then any other stored file, oldest first.
        var found: [(hash: String, bytes: Data, date: Date, note: String)] = []
        for entry in usable?.revisions ?? [] {
            guard !found.contains(where: { $0.hash == entry.hash }), let bytes = try? usable?.bytes(of: entry.hash, root: root) else { continue }
            if (try? checkedLayout(bytes)) != nil { found.append((entry.hash, bytes, entry.saved, entry.note)) }
        }
        var files = [url.appendingPathComponent("source.vdf")]
        files += ((try? FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("revisions"), includingPropertiesForKeys: nil)) ?? [])
        for file in files {
            guard let value = readable(file), !found.contains(where: { $0.hash == value.hash }) else { continue }
            found.append((value.hash, value.bytes, value.date, "Recovered"))
        }
        guard let newest = found.last else { throw LifecycleFailure.nothingToRecover }
        // Keep the recovered bytes where the record can find them.
        try FileManager.default.createDirectory(at: url.appendingPathComponent("revisions"), withIntermediateDirectories: true)
        for item in found {
            let target = url.appendingPathComponent("revisions/\(item.hash).vdf")
            if (try? SteamInputCommunitySources.read(target, limit: SteamInputCommunitySources.limit)) != item.bytes {
                try item.bytes.write(to: target, options: .atomic)
            }
        }
        base.version = 2
        base.pending = nil
        if usable == nil { base.creation = Creation(kind: .recovered, detail: "rebuilt on " + now.formatted(date: .abbreviated, time: .omitted)) }
        base.history = found.suffix(historyLimit).map { HistoryEntry(hash: $0.hash, saved: $0.date, note: $0.note) }
        base.hash = newest.hash
        // A copy keeps its community origin only while its first revision is still there.
        if let origin = base.origin, base.history?.first?.hash != origin.hash {
            base = Self(id: base.id, accountID: base.accountID, appID: base.appID, title: base.title, origin: nil, hash: base.hash,
                        imported: base.imported, sourceName: base.sourceName,
                        creation: Creation(kind: .recovered, detail: "from " + origin.attribution), history: base.history, pending: nil)
            base.version = 2
        }
        try base.writeRecord(root: root)
        return base
    }

    // MARK: Live editing

    /// Stages a revision for a live change: its bytes are stored and the
    /// record names it as pending, while `hash` stays the working revision.
    /// The caller then applies `applyRequest(root:revision:)` through the
    /// layout service and calls `reconciled` as receipts arrive.
    @MainActor func staging(_ bytes: Data, root: URL) throws -> Self {
        try Self.checkedLayout(bytes)
        var value = try reloaded(root: root)
        guard value.pending == nil else { throw LifecycleFailure.busy }
        value.pending = try value.writeObject(bytes, root: root)
        try value.writeRecord(root: root)
        return value
    }

    enum LiveOutcome: Equatable {
        /// Nothing was pending.
        case idle
        /// The change is still in flight.
        case waiting
        /// Steam Input confirmed the pending revision; it is now current.
        case confirmed
        /// It was refused, rolled back, failed or interrupted. The working
        /// revision stays current and active; the edits stay in the draft.
        case reverted
    }

    /// Settles a pending live change from what the layout service reports.
    /// Only a confirmation of exactly the pending revision makes it current.
    @MainActor func reconciled(references: SteamInputPersonalReferences, root: URL, now: Date = Date()) throws -> (Self, LiveOutcome) {
        var value = try reloaded(root: root)
        guard let pending = value.pending else { return (value, .idle) }
        if references.confirmed[id] == pending {
            value.pending = nil
            if pending != value.hash {
                value.history = value.revisions + [HistoryEntry(hash: pending, saved: now, note: "Saved and applied")]
                value.hash = pending
                value.trimHistory()
            }
            try value.writeRecord(root: root)
            if let draft = try? value.draft(root: root), draft.hash == pending { try value.discardDraft(root: root) }
            try value.cleanUp(references: references, root: root)
            return (value, .confirmed)
        }
        if references.inFlight.contains(id) || !references.known { return (value, .waiting) }
        value.pending = nil
        try value.writeRecord(root: root)
        try value.cleanUp(references: references, root: root)
        return (value, .reverted)
    }

    /// Cancels a staged change that was never handed to the layout service.
    @MainActor func unstaged(root: URL) throws -> Self {
        var value = try reloaded(root: root)
        guard value.pending != nil else { return value }
        value.pending = nil
        try value.writeRecord(root: root)
        return value
    }
}

/// Steam's own templates for the player's controller (DualSense or Xbox), as
/// a starting point for a personal layout. They are read from the installed
/// client (the pinned January template table), never bundled, and only the
/// ones present are offered.
enum SteamInputTemplates {
    struct Template: Identifiable, Equatable {
        let name: String
        let title: String
        let bytes: Data
        var id: String { name }
    }

    static let catalog: [(index: UInt32, title: String)] = [
        (4, "Gamepad"), (2, "Gamepad with Camera Controls"), (3, "Gamepad with Mouse Trackpad"),
        (12, "Gamepad with Flick Stick"), (6, "Keyboard (WASD) and Mouse"), (8, "Mouse"), (9, "Relative Mouse"),
    ]

    static func available(clientRoot: URL, controller: SteamInputController = .dualSense) -> [Template] {
        var seen = Set<String>()
        return catalog.compactMap { entry in
            guard let name = sh_input_january_template(controller.steamTypeID, entry.index).flatMap({ String(validatingUTF8: $0) }),
                  seen.insert(name).inserted,
                  let bytes = try? DockSteamInputBundledManifest.januaryTemplate(clientRoot: clientRoot, controller: controller,
                                                                                index: entry.index),
                  (try? DockSteamInputNative.revision(bytes)) != nil else { return nil }
            return Template(name: name, title: entry.title, bytes: bytes)
        }
    }
}
