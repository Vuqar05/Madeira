// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import CryptoKit
import Darwin

/// Durable local preparation only. This does not send a command or claim that
/// Steam activated anything. A single scoped journal serializes reservations;
/// immutable objects retain source bytes separately from revision-tagged copies.
@MainActor struct DockSteamInputJournal {
    enum Failure: Error { case invalid, corrupt, busy, exhausted, stale }
    struct Scope: Codable, Equatable {
        let accountID: UInt32
        let appID: UInt32
        let controllerID: UUID
    }
    struct Reservation: Codable, Equatable {
        let id: UUID
        let applyRevision: UInt32
        let rollbackRevision: UInt32
    }
    struct Content: Codable, Equatable {
        let sourceHash: String
        let baselineHash: String
        let applyHash: String
        let rollbackHash: String
    }
    struct Request: Codable, Equatable {
        let session: String // launch nonce, not a credential; never logged
        let epoch: UInt32
        let sequence: UInt32
    }
    enum Phase: String, Codable { case reserved, prepared, queued, interrupted, confirmed, rolledBack, failed }
    struct Pending: Codable, Equatable {
        let reservation: Reservation
        var content: Content?
        var request: Request?
        var phase: Phase
    }
    struct Working: Codable, Equatable {
        let hash: String
        let revision: UInt32
    }
    struct Record: Codable, Equatable {
        let version: Int
        let scope: Scope
        var highWater: UInt32
        var pending: Pending?
        /// Historical receipt, never evidence that a new game session is active.
        var lastWorking: Working?
        /// Bounded historical confirmations survive a later restart rollback
        /// to Steam's baseline, which is not an explicit confirmed choice.
        var confirmedSources: [String: Working]?
        var steamBaselineHash: String?
    }
    let root: URL
    let scope: Scope
    private var directory: URL {
        root.appendingPathComponent("steam-input-transactions", isDirectory: true)
            .appendingPathComponent("\(scope.accountID)-\(scope.appID)-\(scope.controllerID.uuidString)", isDirectory: true)
    }
    private var recordURL: URL { directory.appendingPathComponent("journal.json") }
    private static let limit = 1 << 20
    private static let revisionLimit = UInt32(Int32.max)

    init(root: URL, scope: Scope) throws {
        guard scope.accountID > 0, scope.appID > 0 else { throw Failure.invalid }
        self.root = root; self.scope = scope
    }
    private static func digest(_ data: Data) -> String {
        DockSteamInputNative.contentHash(data)
    }
    private static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure.corrupt }
        return false
    }
    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.corrupt }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.corrupt }
    }
    private func ensureDirectory(_ url: URL) throws {
        if try exists(url) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.corrupt }
            return
        }
        let parent = url.deletingLastPathComponent()
        guard parent != url else { throw Failure.corrupt }
        try ensureDirectory(parent)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try syncDirectory(parent)
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectory(directory)
        let descriptor = open(directory.appendingPathComponent("journal.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.corrupt }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
    private func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.corrupt }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= limit,
              let bytes = try file.read(upToCount: limit + 1), bytes.count <= limit else { throw Failure.corrupt }
        return bytes
    }
    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        try syncDirectory(url.deletingLastPathComponent())
    }
    private func readRecord() throws -> Record {
        guard try exists(recordURL) else {
            return Record(version: 1, scope: scope, highWater: 0)
        }
        let record = try JSONDecoder().decode(Record.self, from: boundedRead(recordURL, limit: 16384))
        guard record.version == 1, record.scope == scope, record.highWater <= Self.revisionLimit else { throw Failure.corrupt }
        if let working = record.lastWorking {
            guard Self.validHash(working.hash), working.revision > 0, working.revision <= record.highWater else { throw Failure.corrupt }
        }
        if let baseline = record.steamBaselineHash, !Self.validHash(baseline) { throw Failure.corrupt }
        if let confirmations = record.confirmedSources {
            guard confirmations.count <= 8 else { throw Failure.corrupt }
            for (source, working) in confirmations {
                guard Self.validHash(source), Self.validHash(working.hash), working.revision > 0,
                      working.revision <= record.highWater else { throw Failure.corrupt }
            }
        }
        if let pending = record.pending {
            let r = pending.reservation
            guard r.applyRevision > 0, r.applyRevision < Self.revisionLimit,
                  r.rollbackRevision == r.applyRevision + 1, r.rollbackRevision == record.highWater else { throw Failure.corrupt }
            if let content = pending.content {
                guard Self.validHash(content.sourceHash), Self.validHash(content.baselineHash), Self.validHash(content.applyHash),
                      Self.validHash(content.rollbackHash), content.applyHash != content.rollbackHash else { throw Failure.corrupt }
            }
            if [.prepared, .queued, .confirmed, .rolledBack].contains(pending.phase) {
                guard pending.content != nil else { throw Failure.corrupt }
            }
            if let request = pending.request {
                guard Self.validRequest(request) else { throw Failure.corrupt }
            }
            if [.queued, .confirmed, .rolledBack].contains(pending.phase) {
                guard pending.request != nil else { throw Failure.corrupt }
            } else if [.reserved, .prepared].contains(pending.phase), pending.request != nil { throw Failure.corrupt }
            if pending.phase == .confirmed {
                guard record.lastWorking == Working(hash: pending.content!.applyHash, revision: r.applyRevision) else { throw Failure.corrupt }
            } else if pending.phase == .rolledBack {
                guard record.lastWorking == Working(hash: pending.content!.rollbackHash, revision: r.rollbackRevision) else { throw Failure.corrupt }
            }
        }
        return record
    }
    private func writeRecord(_ record: Record) throws {
        try durableWrite(JSONEncoder().encode(record), to: recordURL)
    }
    func snapshot() throws -> Record { try locked { try readRecord() } }
    private func rememberSource(_ source: String, working: Working, in record: inout Record) {
        var confirmations = record.confirmedSources ?? [:]
        confirmations[source] = working
        while confirmations.count > 8 {
            guard let oldest = confirmations.min(by: { $0.value.revision < $1.value.revision })?.key else { break }
            confirmations.removeValue(forKey: oldest)
        }
        record.confirmedSources = confirmations
    }
    private func rememberConfirmation(_ record: inout Record) {
        guard let pending = record.pending, pending.phase == .confirmed, let content = pending.content,
              let working = record.lastWorking, working.hash == content.applyHash else { return }
        rememberSource(content.sourceHash, working: working, in: &record)
    }

    /// Reserve before preparing or queueing either copy. An interrupted pending
    /// transaction blocks new work until explicitly recovered; revisions are
    /// consumed even if preparation fails or the process terminates.
    func reserve(sourceFloor: UInt32) throws -> Reservation {
        try locked {
            var record = try readRecord()
            if let phase = record.pending?.phase, [.reserved, .prepared, .queued, .interrupted].contains(phase) { throw Failure.busy }
            let floor = max(record.highWater, sourceFloor)
            guard floor <= Self.revisionLimit - 2 else { throw Failure.exhausted }
            let reservation = Reservation(id: UUID(), applyRevision: floor + 1, rollbackRevision: floor + 2)
            rememberConfirmation(&record)
            record.highWater = reservation.rollbackRevision
            record.pending = Pending(reservation: reservation, phase: .reserved)
            try writeRecord(record)
            return reservation
        }
    }
    private func objectURL(_ hash: String) throws -> URL {
        guard Self.validHash(hash) else { throw Failure.invalid }
        return directory.appendingPathComponent("objects", isDirectory: true).appendingPathComponent(hash + ".vdf")
    }
    private func readObject(_ hash: String) throws -> Data {
        let bytes = try boundedRead(objectURL(hash), limit: Self.limit - 1)
        guard Self.digest(bytes) == hash else { throw Failure.corrupt }
        return bytes
    }
    private func putObject(_ bytes: Data) throws -> String {
        guard !bytes.isEmpty, bytes.count < Self.limit, !bytes.contains(0) else { throw Failure.invalid }
        let hash = Self.digest(bytes), url = try objectURL(hash)
        try ensureDirectory(url.deletingLastPathComponent())
        if try exists(url) {
            guard try readObject(hash) == bytes else { throw Failure.corrupt }
        } else { try durableWrite(bytes, to: url) }
        return hash
    }
    /// Verify both copies against the shared bounded native materializer before
    /// binding their hashes. Source revisions must be below the reservation.
    /// This does not validate binding semantics or accept supplied file paths.
    func prepare(_ reservation: Reservation, source: Data, baseline: Data, apply: Data, rollback: Data, captureSteamBaseline: Bool = false) throws -> Content {
        try locked {
            var record = try readRecord()
            guard record.pending?.reservation == reservation, record.pending?.phase == .reserved else { throw Failure.stale }
            guard apply != rollback,
                  reservation.applyRevision > max(try DockSteamInputNative.revision(source), try DockSteamInputNative.revision(baseline)),
                  apply == (try DockSteamInputNative.materialize(source, revision: reservation.applyRevision)),
                  rollback == (try DockSteamInputNative.materialize(baseline, revision: reservation.rollbackRevision)) else { throw Failure.invalid }
            let content = try Content(sourceHash: putObject(source), baselineHash: putObject(baseline), applyHash: putObject(apply), rollbackHash: putObject(rollback))
            record.pending?.content = content; record.pending?.phase = .prepared
            if captureSteamBaseline { record.steamBaselineHash = content.baselineHash }
            try writeRecord(record)
            return content
        }
    }
    /// Complete local preparation uses the SAME native metadata parser and
    /// materializer as Dock. Failure consumes the reserved numbers but never
    /// mutates Steam or replaces a working selection. No binding reserialization.
    func prepareLocal(source: Data, baseline: Data, captureSteamBaseline: Bool = false) throws -> Pending {
        let sourceRevision = try DockSteamInputNative.revision(source)
        let baselineRevision = try DockSteamInputNative.revision(baseline)
        let reservation = try reserve(sourceFloor: max(sourceRevision, baselineRevision))
        do {
            let apply = try DockSteamInputNative.materialize(source, revision: reservation.applyRevision)
            let rollback = try DockSteamInputNative.materialize(baseline, revision: reservation.rollbackRevision)
            let content = try prepare(reservation, source: source, baseline: baseline, apply: apply, rollback: rollback, captureSteamBaseline: captureSteamBaseline)
            return Pending(reservation: reservation, content: content, phase: .prepared)
        } catch {
            // A failed cleanup intentionally leaves a blocking pending record.
            // It must never permit the reserved revisions to be reused.
            try? finish(reservation, phase: .failed, hash: nil, revision: nil)
            throw error
        }
    }
    /// Rehash on every read; a corrupt object is never silently overwritten.
    func content(_ hash: String) throws -> Data { try locked { try readObject(hash) } }

    /// Baseline captured before the first explicit override, independent of
    /// subsequent fresh-launch baselines used for transactional rollback.
    func steamBaseline() throws -> Data {
        try locked {
            guard let hash = try readRecord().steamBaselineHash else { throw Failure.stale }
            return try readObject(hash)
        }
    }
    /// Recover source bytes only when they reproduce the historical working
    /// queue exactly. A newer unconfirmed candidate is never a restart source.
    func reapplicationSource(hash: String) throws -> Data {
        try locked {
            var record = try readRecord()
            guard let working = record.confirmedSources?[hash] ?? record.lastWorking else { throw Failure.stale }
            let source = try readObject(hash), queued = try readObject(working.hash)
            guard try DockSteamInputNative.materialize(source, revision: working.revision) == queued else { throw Failure.stale }
            if record.confirmedSources?[hash] == nil {
                // Preserve a proven legacy receipt before a new reservation can
                // overwrite its old pending entry or a rollback changes working.
                rememberSource(hash, working: working, in: &record)
                try writeRecord(record)
            }
            return source
        }
    }
    /// Called only after a fresh launch or newer virtual-controller lease
    /// native baseline proves the old request is no longer in flight. Keep
    /// history/content and consume the old reservation; never accept its
    /// delayed receipt or retry its unconfirmed candidate.
    func abandonInterrupted(_ reservation: Reservation, newSession: String, newEpoch: UInt32 = 1) throws {
        try locked {
            guard Self.validRequest(.init(session: newSession, epoch: newEpoch, sequence: 1)) else { throw Failure.invalid }
            var record = try readRecord()
            guard let pending = record.pending, pending.reservation == reservation, pending.phase == .interrupted,
                  pending.request.map({ $0.session != newSession || newEpoch > $0.epoch }) ?? true else { throw Failure.stale }
            record.pending?.phase = .failed
            try writeRecord(record)
        }
    }
    private static func validRequest(_ request: Request) -> Bool {
        request.epoch > 0 && request.sequence > 0 && request.session.utf8.count == 32 &&
            request.session.utf8.contains(where: { $0 != 48 }) &&
            request.session.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// Durably record the exact launch/connection/request before submitting to
    /// Dock. A receipt from an earlier launch cannot finish interrupted work.
    func markQueued(_ reservation: Reservation, request: Request) throws {
        try locked {
            guard Self.validRequest(request) else { throw Failure.invalid }
            var record = try readRecord()
            guard record.pending?.reservation == reservation, record.pending?.phase == .prepared else { throw Failure.stale }
            guard let content = record.pending?.content else { throw Failure.corrupt }
            _ = try readObject(content.applyHash); _ = try readObject(content.rollbackHash)
            record.pending?.request = request; record.pending?.phase = .queued
            try writeRecord(record)
        }
    }
    /// A restart never resumes an unacknowledged apply automatically. Recovery
    /// must explicitly inspect the saved rollback object and native state.
    func interrupt() throws {
        try locked {
            var record = try readRecord()
            guard let phase = record.pending?.phase, [.reserved, .prepared, .queued].contains(phase) else { return }
            record.pending?.phase = .interrupted
            try writeRecord(record)
        }
    }
    /// Only the bridge's verified transaction receipt may call this method.
    /// Hash, native revision and reservation identity must all match the journal.
    func finish(_ reservation: Reservation, phase: Phase, hash: String?, revision: UInt32?, request: Request? = nil) throws {
        try locked {
            var record = try readRecord()
            guard let pending = record.pending, pending.reservation == reservation,
                  [.prepared, .queued, .interrupted, .reserved].contains(pending.phase),
                  [.confirmed, .rolledBack, .failed].contains(phase) else { throw Failure.stale }
            if phase != .failed {
                guard pending.phase == .queued, let request, request == pending.request,
                      let content = pending.content,
                      hash == (phase == .confirmed ? content.applyHash : content.rollbackHash),
                      revision == (phase == .confirmed ? reservation.applyRevision : reservation.rollbackRevision) else { throw Failure.stale }
                _ = try readObject(hash!)
                record.lastWorking = Working(hash: hash!, revision: revision!)
            } else if hash != nil || revision != nil || request != nil { throw Failure.invalid }
            record.pending?.phase = phase
            rememberConfirmation(&record)
            try writeRecord(record)
        }
    }
}

/// Narrow Swift wrapper over the shared portable C metadata implementation.
/// This does not claim that a structurally valid native document has usable
/// bindings; only Valve's load result and an in-game check can establish that.
enum DockSteamInputNative {
    static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func revision(_ data: Data) throws -> UInt32 {
        guard !data.isEmpty, data.count < 1 << 20 else { throw DockSteamInputJournal.Failure.invalid }
        var revision: UInt32 = 0
        let valid = data.withUnsafeBytes { bytes in
            sh_input_vdf_revision(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), data.count, &revision)
        }
        guard valid else { throw DockSteamInputJournal.Failure.invalid }
        return revision
    }
    /// Nil only when the manifest has no usable controller entry at all; the
    /// portable reader follows SteamUI's exact-then-compatible-then-first order.
    static func manifestPS5Path(_ data: Data, device: DockSteamInputContext? = nil) throws -> String? {
        guard !data.isEmpty, data.count < 1 << 20 else { throw DockSteamInputJournal.Failure.invalid }
        var path = [CChar](repeating: 0, count: 1024)
        let result = data.withUnsafeBytes { bytes in
            path.withUnsafeMutableBufferPointer { target in
                sh_input_manifest_ps5_device_path(bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                    data.count, device?.vendor ?? UInt32.max, device?.product ?? UInt32.max,
                    target.baseAddress!, target.count)
            }
        }
        if result == SH_INPUT_MANIFEST_ABSENT { return nil }
        guard result == SH_INPUT_MANIFEST_FOUND, let value = String(validatingUTF8: path) else {
            throw DockSteamInputJournal.Failure.invalid
        }
        return value
    }
    static func materialize(_ data: Data, revision: UInt32) throws -> Data {
        guard !data.isEmpty, data.count < 1 << 20 else { throw DockSteamInputJournal.Failure.invalid }
        let capacity = data.count + 48
        var output = [UInt8](repeating: 0, count: capacity), written = 0
        let valid = data.withUnsafeBytes { bytes in
            output.withUnsafeMutableBytes { target in
                sh_input_vdf_materialize(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), data.count,
                    revision, target.baseAddress!.assumingMemoryBound(to: CChar.self), capacity, &written)
            }
        }
        guard valid else { throw DockSteamInputJournal.Failure.invalid }
        return Data(output.prefix(written))
    }
}

/// Reads depot-bundled candidates without following links or allowing a
/// manifest path to escape the supplied installed game directory. A nil result
/// only means no exact DualSense entry was present in this manifest.
struct DockSteamInputContext: Equatable {
    let capabilities: UInt32
    let vendor: UInt32
    let product: UInt32
    let rawType: UInt32
    let manifestPath: String?
    /// Context is useful only for the virtual DualSense bridge the resolver
    /// supports. Never reinterpret another physical controller as this bridge.
    var isDualSense: Bool { vendor == 0x054c && product == 0x0ce6 }

    static func parse(_ data: Data, session: [UInt8], appID: UInt32, epoch: UInt32) -> Self? {
        let bytes = [UInt8](data)
        guard bytes.count >= 56, bytes.count <= 56 + 4096,
              Array(bytes[0..<8]) == Array("MSICTX01".utf8), session.count == 16,
              session.contains(where: { $0 != 0 }), Array(bytes[8..<24]) == session else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        let flags = u32(32), count = Int(u32(52))
        guard appID > 0, epoch > 0, u32(24) == appID, u32(28) == epoch,
              flags == 3, u32(40) <= 65535, u32(44) <= 65535,
              count <= 4096, bytes.count == 56 + count, flags & 2 != 0 || count == 0,
              let path = String(bytes: bytes[56...], encoding: .utf8),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return Self(capabilities: u32(36), vendor: u32(40), product: u32(44), rawType: u32(48),
                    manifestPath: path.isEmpty ? nil : path)
    }
}

enum DockSteamInputBundledManifest {
    struct Candidate {
        let manifest: Data
        let layout: Data
        let relativePath: String
    }
    private static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count < 1024, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DockSteamInputJournal.Failure.invalid
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DockSteamInputJournal.Failure.invalid
        }
        return parts
    }
    private static func directory(root: Int32, components: ArraySlice<String>) throws -> Int32 {
        var parent = dup(root)
        guard parent >= 0 else { throw DockSteamInputJournal.Failure.corrupt }
        for part in components {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { close(parent); throw DockSteamInputJournal.Failure.corrupt }
            close(parent); parent = next
        }
        return parent
    }
    private static func read(root: Int32, components: [String]) throws -> Data {
        guard let last = components.last else { throw DockSteamInputJournal.Failure.invalid }
        let parent = try directory(root: root, components: components.dropLast())
        defer { close(parent) }
        let fd = openat(parent, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DockSteamInputJournal.Failure.corrupt }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size < 1 << 20,
              let bytes = try file.read(upToCount: 1 << 20), bytes.count == Int(info.st_size) else {
            throw DockSteamInputJournal.Failure.corrupt
        }
        var after = stat()
        guard fstat(fd, &after) == 0, info.st_dev == after.st_dev, info.st_ino == after.st_ino,
              info.st_size == after.st_size, info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DockSteamInputJournal.Failure.corrupt
        }
        return bytes
    }
    static func candidate(gameDirectory: URL, manifestPath: String, device: DockSteamInputContext? = nil) throws -> Candidate? {
        let manifestParts = try components(manifestPath)
        let root = open(gameDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw DockSteamInputJournal.Failure.corrupt }
        defer { close(root) }
        let parent = try directory(root: root, components: manifestParts.dropLast())
        defer { close(parent) }
        let manifest = try read(root: parent, components: [manifestParts.last!])
        guard let relative = try DockSteamInputNative.manifestPS5Path(manifest, device: device) else { return nil }
        let candidateParts = try components(relative)
        let layoutParts = Array(manifestParts.dropLast()) + candidateParts
        let layout = try read(root: parent, components: candidateParts)
        return Candidate(manifest: manifest, layout: layout, relativePath: layoutParts.joined(separator: "/"))
    }
#if DEBUG
    /// Debug builds only: a fixed, clearly different template used to exercise
    /// "Use game default" as a restore. Never offered as a product choice.
    /// Steam's PS5 "Gamepad" joystick template with the A and B bindings
    /// exchanged, so the output stays on the verified virtual-pad path. The swap
    /// needs both bindings to appear exactly once, or the template is refused.
    static let debugOverrideTemplate = "controller_ps5_gamepad_joystick.vdf"
    static func debugOverride(clientRoot: URL) throws -> Data {
        let root = open(clientRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw DockSteamInputJournal.Failure.corrupt }
        defer { close(root) }
        let original = try read(root: root, components: ["controller_base", "templates", debugOverrideTemplate])
        guard let text = String(data: original, encoding: .utf8) else { throw DockSteamInputJournal.Failure.invalid }
        let a = "\"xinput_button A\"", b = "\"xinput_button B\"", mark = "\"xinput_button @@\""
        guard text.components(separatedBy: a).count == 2, text.components(separatedBy: b).count == 2,
              !text.contains(mark) else { throw DockSteamInputJournal.Failure.invalid }
        let swapped = text.replacingOccurrences(of: a, with: mark)
            .replacingOccurrences(of: b, with: a)
            .replacingOccurrences(of: mark, with: b)
        let data = Data(swapped.utf8)
        _ = try DockSteamInputNative.revision(data)
        guard data != original else { throw DockSteamInputJournal.Failure.invalid }
        return data
    }
#endif
    /// A pinned January client template candidate, not proof that cached PICS
    /// data is current. The caller must establish client and metadata scope.
    static func januaryPS5Template(clientRoot: URL, index: UInt32) throws -> Data? {
        guard let name = sh_input_january_ps5_template(index), let filename = String(validatingUTF8: name) else { return nil }
        let root = open(clientRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw DockSteamInputJournal.Failure.corrupt }
        defer { close(root) }
        return try read(root: root, components: ["controller_base", "templates", filename])
    }
}

/// Read-only manifest/template resolution in the pinned January SteamUI order.
/// Runtime manifest paths precede PICS hints; capability bits resolve indices
/// 2/3, and controller_support supplies the absent-index fallback. Index 1
/// delegates to the ordered Workshop resolver in SteamInputDefaultSources.
/// Submission and receipts remain exclusively in DockSteamInputService.
enum DockSteamInputDefault {
    static let genericTemplate = "controller_ps5_gamepad_joystick.vdf"
    struct Recommendation: Equatable {
        enum Origin: Equatable { case actionManifest, steamTemplate, workshop }
        let source: Data
        let origin: Origin
        /// A Steam template whose bindings send keyboard or mouse input, which
        /// Madeira does not deliver to games yet. False for a bundled layout:
        /// its bindings are not interpreted here.
        let mouseOrKeyboard: Bool
        /// SHA-256 of `source`, computed once; the status UI compares it every second.
        let contentHash: String
        var attribution: String? = nil
        var sourceDescription: String {
            switch origin {
            case .actionManifest: return "Bundled with the game"
            case .steamTemplate: return "Steam template"
            case .workshop: return attribution ?? "Recommended Workshop layout"
            }
        }
        init(source: Data, origin: Origin, mouseOrKeyboard: Bool = false) {
            self.source = source; self.origin = origin; self.mouseOrKeyboard = mouseOrKeyboard
            contentHash = DockSteamInputNative.contentHash(source)
        }
    }
    enum Reason: String, Equatable {
        case dataUnavailable, notInstalled, manifestUnreadable, manifestUnsupported
        case workshopSource, templateUnsupported, templateUnavailable
        case workshopUnavailable, workshopIncompatible
        case contextUnavailable
        /// Index 2 or 3: SteamUI keeps it or uses index 4 depending on the
        /// connected controller's capability bits, read from the current Dock context.
        case templateControllerDependent
    }
    enum Resolution: Equatable {
        case recommended(Recommendation)
        case noRecommendation
        /// Well-formed metadata lists neither a manifest nor a template (index
        /// 0 is the same to SteamUI). Not proof that Steam chooses no layout.
        case noHint
        case unresolved(Reason)
    }

    /// Well-formed app metadata. Nil hints mean the app data lists none.
    struct Hints: Equatable {
        let templateIndex: UInt32?
        let manifestPath: String?
        var controllerSupport: UInt32? = nil
    }
    /// `hints` is nil when the metadata was never read; `gameDirectory` is nil
    /// when the game is not installed.
    static func resolve(hints metadata: Hints?, gameDirectory: URL?, clientRoot: URL,
                        context: DockSteamInputContext? = nil, windowsDirectory: String? = nil) -> Resolution {
        var path = metadata?.manifestPath
        if let runtimePath = context?.manifestPath {
            guard let confined = relativeManifestPath(runtimePath, windowsDirectory: windowsDirectory) else {
                return .unresolved(.manifestUnsupported)
            }
            path = confined
        }
        if let path {
            guard let gameDirectory else { return .unresolved(.notInstalled) }
            do {
                if let candidate = try DockSteamInputBundledManifest.candidate(gameDirectory: gameDirectory, manifestPath: path,
                    device: context?.isDualSense == true ? context : nil) {
                    _ = try DockSteamInputNative.revision(candidate.layout)
                    return .recommended(.init(source: candidate.layout, origin: .actionManifest))
                }
                // No usable controller entry: SteamUI's resolver reports failure.
            } catch DockSteamInputJournal.Failure.invalid { return .unresolved(.manifestUnsupported) }
            catch { return .unresolved(.manifestUnreadable) }
        }
        guard let metadata else { return .unresolved(.dataUnavailable) }
        var template = metadata.templateIndex ?? 0
        if template == 0 {
            // A launched, owned Steam app is subscribed and is not a shortcut.
            // January's remaining app predicate is common.controller_support.
            guard let support = metadata.controllerSupport else { return .noHint }
            guard support != 0 else { return .noRecommendation }
            template = 2
        }
        if template == 2 || template == 3 {
            guard let context, context.isDualSense else { return .unresolved(.templateControllerDependent) }
            if context.capabilities & 0x1800 == 0 { template = 4 }
        }
        switch template {
        case 1: return .unresolved(.workshopSource)
        case let index:
            guard sh_input_january_ps5_template(index) != nil else { return .unresolved(.templateUnsupported) }
            guard let data = try? DockSteamInputBundledManifest.januaryPS5Template(clientRoot: clientRoot, index: index),
                  (try? DockSteamInputNative.revision(data)) != nil else { return .unresolved(.templateUnavailable) }
            return .recommended(.init(source: data, origin: .steamTemplate,
                                      mouseOrKeyboard: sh_input_january_ps5_template_mouse_or_keyboard(index)))
        }
    }

    /// After the legacy index-1 list has no compatible layout, January's
    /// template resolver picks 2 for controller-supporting apps, otherwise 6.
    /// Rich config details suppress this fallback, even when their list is empty.
    static func workshopFallback(controllerSupport: UInt32?, clientRoot: URL, context: DockSteamInputContext?) -> Resolution {
        guard let support = controllerSupport else { return .unresolved(.dataUnavailable) }
        return resolve(hints: .init(templateIndex: support == 0 ? 6 : 2, manifestPath: nil),
                       gameDirectory: nil, clientRoot: clientRoot, context: context)
    }

    /// A client-supplied Windows absolute path is accepted only beneath this
    /// installed game's directory. File reads still use openat/O_NOFOLLOW.
    static func relativeManifestPath(_ path: String, windowsDirectory: String?) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, normalized.utf8.count < 4096,
              !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var relative = normalized
        if normalized.contains(":") {
            guard let windowsDirectory else { return nil }
            let root = windowsDirectory.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            guard normalized.lowercased().hasPrefix(root.lowercased()) else { return nil }
            relative = String(normalized.dropFirst(root.count))
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.contains(":"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return relative
    }

    /// Steam's PS5 "Gamepad" template as an explicit, clearly generic choice.
    static func genericTemplate(clientRoot: URL) throws -> Data {
        guard let data = try DockSteamInputBundledManifest.januaryPS5Template(clientRoot: clientRoot, index: 4) else {
            throw DockSteamInputJournal.Failure.invalid
        }
        _ = try DockSteamInputNative.revision(data)
        return data
    }

    static func explanation(_ resolution: Resolution) -> String {
        switch resolution {
        case .recommended(let value):
            let source: String
            switch value.origin {
            case .actionManifest: source = "Game default: the layout bundled with this game."
            case .steamTemplate: source = "Game default: Steam's template for this game and controller."
            case .workshop: source = "Game default: the recommended Workshop layout." + (value.attribution.map { " " + $0 } ?? "")
            }
            return value.mouseOrKeyboard
                ? source + " It sends keyboard or mouse input, which Madeira does not pass to games yet, so the controller may do nothing."
                : source
        case .noHint:
            return "The cached game data does not identify a default. Retry to refresh it from Steam."
        case .noRecommendation:
            return "This game has no recommended Steam Input layout."
        case .unresolved(let reason):
            switch reason {
            case .dataUnavailable: return "The game default could not be determined: Steam's game data is not cached."
            case .notInstalled: return "The game default could not be read: the game is not installed."
            case .manifestUnreadable: return "The game default could not be read from the game's files."
            case .manifestUnsupported: return "The game default uses controller matching Madeira does not support yet."
            case .workshopSource: return "Steam names a Workshop recommendation, but its item list is unavailable. Retry to refresh the game's data."
            case .workshopUnavailable: return "The recommended Workshop layout could not be downloaded or verified. Retry when Steam is reachable; the previous layout is kept."
            case .workshopIncompatible: return "The recommended Workshop layouts do not support this controller."
            case .contextUnavailable: return "Waiting for Steam's controller and layout-source details. Retry after the controller is connected."
            case .templateUnsupported: return "The game default uses a Steam template Madeira cannot identify yet."
            case .templateUnavailable: return "The game default's template is missing from Steam's files."
            case .templateControllerDependent:
                return "The game default needs current controller details. Reconnect the controller and retry."
            }
        }
    }
}

/// Local submission/receipt wire format. The query feed remains version 1;
/// payload and receipt version 2 carry exact native queue content identities.
enum DockSteamInputTransport {
    enum Phase: UInt32 { case idle, prepared, applying, confirmed, rollingBack, rolledBack, failed, cancelled }
    struct Receipt: Equatable {
        let session: [UInt8]
        let appID: UInt32
        let epoch: UInt32
        let sequence: UInt32
        let phase: Phase
        let highWater: UInt32
        let applyRevision: UInt32
        let rollbackRevision: UInt32
        let workingRevision: UInt32
        let workingHash: String
        let workingKnown: Bool
    }
    static func envelope(session: [UInt8], appID: UInt32, epoch: UInt32, sequence: UInt32,
                         reservation: DockSteamInputJournal.Reservation, apply: Data, rollback: Data) throws -> Data {
        guard session.count == 16, session.contains(where: { $0 != 0 }), appID > 0, epoch > 0, sequence > 0,
              !apply.isEmpty, !rollback.isEmpty, apply.count < 1 << 20, rollback.count < 1 << 20 else { throw DockSteamInputJournal.Failure.invalid }
        var data = Data("MSITXN02".utf8); data.append(contentsOf: session)
        func append(_ value: UInt32) { for shift in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) } }
        for value in [appID, 0, epoch, sequence, reservation.applyRevision, reservation.rollbackRevision] { append(value) }
        data.append(contentsOf: SHA256.hash(data: apply)); data.append(contentsOf: SHA256.hash(data: rollback))
        append(UInt32(apply.count)); append(UInt32(rollback.count)); data.append(apply); data.append(rollback)
        var parsed = sh_input_apply()
        let valid = data.withUnsafeBytes { bytes in
            sh_input_apply_parse(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, &parsed)
        }
        guard valid else { throw DockSteamInputJournal.Failure.invalid }
        return data
    }
    /// The one layout Dock may load when Steam has no saved selection for the
    /// game (BOOTSTRAP). Scoped to this launch and connection; no paths.
    static func initialFrame(layout: Data, session: [UInt8], appID: UInt32, epoch: UInt32) -> Data? {
        guard session.count == 16, !layout.isEmpty, layout.count < 1 << 20 else { return nil }
        var out = [UInt8](repeating: 0, count: Int(SH_INPUT_BASELINE_HEADER) + layout.count)
        let capacity = out.count
        let size = session.withUnsafeBufferPointer { scope in
            layout.withUnsafeBytes { bytes in
                sh_input_initial_frame(scope.baseAddress!, appID, epoch,
                                       bytes.baseAddress!.assumingMemoryBound(to: CChar.self), layout.count, &out, capacity)
            }
        }
        return size == capacity ? Data(out) : nil
    }
    static func baseline(_ data: Data, session: [UInt8], appID: UInt32, epoch: UInt32) -> Data? {
        guard session.count == 16 else { return nil }
        return data.withUnsafeBytes { bytes in
            var value = sh_input_baseline()
            guard let address = bytes.baseAddress,
                  sh_input_baseline_parse(address.assumingMemoryBound(to: UInt8.self), data.count, &value),
                  value.appid == appID, value.epoch == epoch,
                  withUnsafeBytes(of: value.session, { Array($0) }) == session,
                  let source = value.data else { return nil }
            return Data(bytes: source, count: value.size)
        }
    }
    static func receipt(_ data: Data) -> Receipt? {
        guard data.count == 96 else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<8]) == Array("MSITXFD2".utf8) else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        guard bytes[8..<24].contains(where: { $0 != 0 }), u32(24) > 0, u32(28) == 0,
              u32(32) > 0, u32(36) > 0, let phase = Phase(rawValue: u32(40)),
              u32(44) <= Int32.max, u32(48) > 0, u32(48) < Int32.max,
              u32(52) == u32(48) + 1, u32(52) <= u32(44), u32(92) <= 1 else { return nil }
        let known = u32(92) == 1
        if known {
            guard phase == .confirmed || phase == .rolledBack,
                  u32(56) == (phase == .confirmed ? u32(48) : u32(52)),
                  bytes[60..<92].contains(where: { $0 != 0 }) else { return nil }
        } else if phase == .confirmed || phase == .rolledBack { return nil }
        return Receipt(session: Array(bytes[8..<24]), appID: u32(24), epoch: u32(32), sequence: u32(36), phase: phase,
                       highWater: u32(44), applyRevision: u32(48), rollbackRevision: u32(52), workingRevision: u32(56),
                       workingHash: bytes[60..<92].map { String(format: "%02x", $0) }.joined(), workingKnown: known)
    }
}
