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
    /// Called only after a fresh nonce-bound native baseline proves the old
    /// launch has ended. Keep history/content and consume the old reservation;
    /// never accept its delayed receipt or retry its unconfirmed candidate.
    func abandonInterrupted(_ reservation: Reservation, newSession: String) throws {
        try locked {
            guard Self.validRequest(.init(session: newSession, epoch: 1, sequence: 1)) else { throw Failure.invalid }
            var record = try readRecord()
            guard let pending = record.pending, pending.reservation == reservation, pending.phase == .interrupted,
                  pending.request?.session != newSession else { throw Failure.stale }
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
