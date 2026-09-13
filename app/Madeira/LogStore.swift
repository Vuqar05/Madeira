import Foundation
import SwiftUI

final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// One row per unique signature — semantically identical events bucket here.
    @Published var entries: [LogEntry] = []

    private let logFileURL: URL
    // O_APPEND fd for `appendToFile`, opened lazily and held open.
    // Guarded by fileLock: Wine threads log through here too.
    private var logFD: Int32 = -1
    private let fileLock = NSLock()

    // Tail-file reader (background)
    private var tail: LogTail?
    // Signature → index into `entries` so we can update in O(1)
    private var sigToIndex: [String: Int] = [:]
    // Lock for sigToIndex + pending mutations
    private let stateLock = NSLock()
    // Pending batched diffs to apply on main thread
    private var pendingNew: [LogEntry] = []
    private var pendingUpdates: [(index: Int, count: Int, lastRaw: String, lastTimestamp: Date)] = []
    private var flushTimer: Timer?

    /// When true, UI flushes slowly (1.5s) instead of normally (200ms). Used
    /// during Wine runtime so SwiftUI list churn doesn't drag frame pacing.
    /// Tail reader keeps running either way — pending entries just batch up
    /// longer before reaching @Published. Setting this restarts the timer.
    var uiPaused = false {
        didSet { if oldValue != uiPaused { rescheduleFlush() } }
    }

    // Flush intervals (seconds)
    private let fastFlushInterval: TimeInterval = 0.2
    private let slowFlushInterval: TimeInterval = 1.5

    // Cap on distinct entries kept in memory
    private let maxEntries = 200

    struct LogEntry: Identifiable {
        let id = UUID()
        var firstTimestamp: Date
        var lastTimestamp: Date
        var signature: String
        var lastRaw: String
        var count: Int
        var level: Level

        enum Level: String {
            case info = "INFO"
            case success = "OK"
            case error = "ERR"
            case debug = "DBG"
        }
    }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFileURL = docs.appendingPathComponent("madeira-log.txt")

        // ml601: ROTATE, don't destroy.
        //
        // This used to truncate unconditionally, so relaunching the app before
        // pulling wiped the previous run. That cost us the first run in which
        // Steam's Library view actually rendered content (2026-08-09) — a result
        // we had never seen before and could not get back. Runs here are
        // expensive and often not reproducible on demand, so the previous log is
        // worth one file's worth of disk.
        //
        // Pull the previous run with the usual devicectl command, substituting
        // Documents/madeira-log.prev.txt for Documents/madeira-log.txt.
        let prevLogURL = docs.appendingPathComponent("madeira-log.prev.txt")
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            try? FileManager.default.removeItem(at: prevLogURL)
            try? FileManager.default.moveItem(at: logFileURL, to: prevLogURL)
        }
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)

        // Start batch flush timer on main thread. Interval depends on uiPaused.
        DispatchQueue.main.async {
            self.rescheduleFlush()
        }

        // Tail the log file. Reads everything Wine + DXMT + FEX write via
        // dprintf(STDERR_FILENO, ...), wine_log_write, etc.
        tail = LogTail(path: logFileURL.path) { [weak self] line in
            self?.handleRawLine(line)
        }
        tail?.start()

        // Also accept programmatic logs from Swift/ObjC code via existing
        // C callbacks (kept for compatibility with code that doesn't write
        // to the log file).
        wine_set_ui_log_callback { cStr in
            guard let cStr = cStr else { return }
            let message = String(cString: cStr)
            LogStore.shared.handleRawLine(message)
        }
        jit_set_log_callback { cStr in
            guard let cStr = cStr else { return }
            let message = String(cString: cStr)
            LogStore.shared.handleRawLine(message)
            // ml359: also persist — jit_log lines (incl. the [no-footprint]
            // verdict) previously reached only the UI view, which dies with
            // the app; pulled logs never contained them.
            LogStore.shared.appendToFile(message, level: .info)
        }
    }

    /// Public entry point for Swift-side logging (kept for ContentView calls)
    func log(_ message: String, level: LogEntry.Level = .info) {
        handleRawLine(message)
        // Also append to the file so it shows up in pulled logs alongside Wine output
        appendToFile(message, level: level)
    }

    /// Called from tail-file callback (background queue) or C callback.
    private func handleRawLine(_ raw: String) {
        // Filter out lines we never want in UI (excessive byte spam, etc.)
        if shouldDropLine(raw) { return }

        let (sig, level) = LogPattern.canonicalize(raw)
        if sig.isEmpty { return }

        let now = Date()
        stateLock.lock()
        if let idx = sigToIndex[sig] {
            pendingUpdates.append((idx, 1, raw, now))
        } else {
            // Reserve an index slot — actual append happens on flush.
            // We can't know the true index here without holding entries,
            // so we'll resolve indices during flush.
            let entry = LogEntry(
                firstTimestamp: now,
                lastTimestamp: now,
                signature: sig,
                lastRaw: raw,
                count: 1,
                level: level
            )
            pendingNew.append(entry)
            // Map sig → -1 sentinel so subsequent same-sig lines from this
            // batch get treated as new too (will be merged during flush).
            sigToIndex[sig] = -1
        }
        stateLock.unlock()
    }

    /// Needles for `shouldDropLine`, as UTF-8 bytes. ml810: these were eight
    /// `String.contains` calls, each a Unicode-correct substring search over
    /// the whole line, run before anything else on every line the stack
    /// emits — including the high-rate lines they exist to throw away.
    /// Byte search over the UTF-8 view is exact here because every needle is
    /// pure ASCII, and it allocates nothing.
    private static let dropNeedles: [[UInt8]] = [
        // Wine's `trace:file:WriteFile` / `NtWriteFile` / `SysCall` chatter
        // — these are amplified by our own logging path (every dprintf is
        // dup2'd to the log fd, which then goes through Wine's file trace).
        // The signal lives in the original log lines, not these wrappers.
        Array("trace:file:WriteFile".utf8),
        Array("trace:file:NtWriteFile".utf8),
        Array("SysCall  NtWriteFile".utf8),
        Array("SysCall  NtQueryPerformanceCounter".utf8),
        Array("SysRet   NtWriteFile".utf8),
        Array("SysRet   NtQueryPerformanceCounter".utf8),
        // Verbose IR dispatch (already silenced in FEX, but defensive)
        Array("[iOS] Arm64JIT: Dispatching Op".utf8),
        Array("[iOS] Decoder:".utf8),
    ]

    /// Filter rules for raw lines. Anything that returns true is dropped
    /// before signature canonicalization.
    private func shouldDropLine(_ raw: String) -> Bool {
        if let hit = raw.utf8.withContiguousStorageIfAvailable({ LogStore.anyNeedleMatches($0) }) {
            return hit
        }
        // Non-contiguous (a bridged NSString) — copy once, then scan.
        return Array(raw.utf8).withUnsafeBufferPointer { LogStore.anyNeedleMatches($0) }
    }

    private static func anyNeedleMatches(_ hay: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = hay.count
        for needle in dropNeedles {
            let m = needle.count
            if n < m { continue }
            let first = needle[0]
            var p = 0
            let limit = n - m
            while p <= limit {
                if hay[p] == first {
                    var k = 1
                    while k < m && hay[p + k] == needle[k] { k += 1 }
                    if k == m { return true }
                }
                p += 1
            }
        }
        return false
    }

    /// Reschedule flush timer with the appropriate interval for the current
    /// uiPaused state. Always runs on main RunLoop.
    private func rescheduleFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.flushTimer?.invalidate()
            let interval = self.uiPaused ? self.slowFlushInterval : self.fastFlushInterval
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.flushPending()
            }
        }
    }

    /// Apply pending changes to @Published entries (main thread).
    /// Runs on main thread, interval determined by uiPaused.
    private func flushPending() {

        stateLock.lock()
        let newBatch = pendingNew
        let updateBatch = pendingUpdates
        pendingNew.removeAll(keepingCapacity: true)
        pendingUpdates.removeAll(keepingCapacity: true)
        stateLock.unlock()

        if newBatch.isEmpty && updateBatch.isEmpty { return }

        // Apply updates (existing entries: bump count, update timestamp)
        for u in updateBatch {
            // Some indices may have been the -1 sentinel — match by signature
            if u.index < 0 || u.index >= entries.count { continue }
            entries[u.index].count += u.count
            entries[u.index].lastTimestamp = u.lastTimestamp
            entries[u.index].lastRaw = u.lastRaw
        }

        // Apply news: dedup against in-batch sigs (so if 5 same-sig lines
        // arrived in one batch, we get one entry with count=5)
        //
        // ml810: the live-entries check was `entries.firstIndex(where:)`, a
        // linear scan with a String compare per element, run once per new
        // entry in the batch — O(batch x entries) with the list pinned at
        // maxEntries. `entries` is already keyed by signature in
        // sigToIndex, so build the reverse map once and look up in O(1).
        var liveSigToIndex: [String: Int] = [:]
        liveSigToIndex.reserveCapacity(entries.count)
        for (i, e) in entries.enumerated() { liveSigToIndex[e.signature] = i }

        var batchSigToBatchIdx: [String: Int] = [:]
        var collapsedNew: [LogEntry] = []
        for entry in newBatch {
            if let i = batchSigToBatchIdx[entry.signature] {
                collapsedNew[i].count += 1
                collapsedNew[i].lastTimestamp = entry.lastTimestamp
                collapsedNew[i].lastRaw = entry.lastRaw
            } else {
                // Or against the live entries list (race with this same flush)
                if let existing = liveSigToIndex[entry.signature] {
                    entries[existing].count += 1
                    entries[existing].lastTimestamp = entry.lastTimestamp
                    entries[existing].lastRaw = entry.lastRaw
                    continue
                }
                batchSigToBatchIdx[entry.signature] = collapsedNew.count
                collapsedNew.append(entry)
            }
        }

        // Append new entries. sigToIndex is read/written by handleRawLine on
        // Wine threads, so every mutation of it here MUST hold stateLock —
        // the unlocked writes corrupted the dictionary and threw an
        // NSException on the wineserver thread (2026-07-03).
        stateLock.lock()
        for entry in collapsedNew {
            entries.append(entry)
            let newIndex = entries.count - 1
            sigToIndex[entry.signature] = newIndex
        }

        // Reindex if we evicted
        //
        // ml810: this ran two full sorts and THREE dictionary rebuilds of
        // sigToIndex, the first two of which were thrown away by the next
        // line. Once the list is at maxEntries this fires on every flush
        // that adds an entry, i.e. up to 5x a second. Now: one partial
        // selection to find the eviction cutoff, one filter, one rebuild.
        if entries.count > maxEntries {
            let drop = entries.count - maxEntries
            // The `drop` oldest by lastTimestamp are evicted. Sorting the
            // timestamps alone gives the cutoff without sorting (and copying)
            // the entries themselves.
            let cutoff = entries.map { $0.lastTimestamp }.sorted()[drop - 1]
            // Everything strictly below the cutoff goes; the rest of the
            // quota comes from the entries sitting exactly ON it, taken in
            // list order. Doing this with one `<=` counter instead would let
            // a strictly-older entry survive whenever ties filled the quota
            // ahead of it.
            var atCutoffToDrop = drop - entries.reduce(0) {
                $0 + ($1.lastTimestamp < cutoff ? 1 : 0)
            }
            var kept: [LogEntry] = []
            kept.reserveCapacity(maxEntries)
            for e in entries {
                if e.lastTimestamp < cutoff { continue }
                if e.lastTimestamp == cutoff, atCutoffToDrop > 0 {
                    atCutoffToDrop -= 1
                    continue
                }
                kept.append(e)
            }
            // `entries` is already in insertion order (by firstTimestamp)
            // and the filter above preserves it, so no re-sort is needed.
            entries = kept
            sigToIndex.removeAll(keepingCapacity: true)
            for (i, e) in entries.enumerated() { sigToIndex[e.signature] = i }
        }
        stateLock.unlock()
    }

    /// Manual clear (used by UI button)
    func clear() {
        stateLock.lock()
        sigToIndex.removeAll()
        pendingNew.removeAll()
        pendingUpdates.removeAll()
        stateLock.unlock()
        entries.removeAll()
        // Drop the append fd before replacing the file: `write(to:
        // atomically:)` swaps in a new inode, and the old fd would keep
        // appending to the orphaned one.
        fileLock.lock()
        if logFD >= 0 { close(logFD); logFD = -1 }
        fileLock.unlock()
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
    }

    /// Write to file (called from `log()` for Swift-side messages so they
    /// land in the file alongside Wine/FEX output, picked up by the tail
    /// reader).
    ///
    /// ml810: this used to open a FileHandle, seek to end, write and close
    /// on EVERY message — four syscalls per line, and the jit log callback
    /// routes through here. It is now one held-open fd and one write().
    ///
    /// The fd is O_APPEND, which is also a correctness fix: the Wine side
    /// has stderr and stdout dup2'd onto this same file with O_APPEND (see
    /// WineProcessBridge/WineServerBridge), so the old seek-then-write was
    /// racing it — a C-side write landing between the seek and the write
    /// was silently overwritten. O_APPEND makes each write land at the
    /// file's end atomically, so the two writers interleave safely and no
    /// seek is needed at all. `clear()` closes it, since that replaces the
    /// file underneath us.
    ///
    /// `dateFormatter` went too: DateFormatter is not thread-safe and this
    /// is called from Wine threads as well as the main one, so the shared
    /// instance was a latent race as well as the most expensive part of
    /// building the line.
    private func appendToFile(_ message: String, level: LogEntry.Level = .info) {
        let line = "[\(LogStore.timestampNow())] [\(level.rawValue)] \(message)\n"
        let bytes = Array(line.utf8)
        if bytes.isEmpty { return }
        fileLock.lock()
        defer { fileLock.unlock() }
        if logFD < 0 {
            logFD = open(logFileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        guard logFD >= 0 else { return }
        bytes.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = write(logFD, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    /// `HH:mm:ss.SSS` for the current time, without DateFormatter.
    private static func timestampNow() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var t = time_t(tv.tv_sec)
        var tmv = tm()
        localtime_r(&t, &tmv)
        let ms = Int(tv.tv_usec) / 1000
        func pad2(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }
        func pad3(_ v: Int) -> String {
            v < 10 ? "00\(v)" : (v < 100 ? "0\(v)" : "\(v)")
        }
        return "\(pad2(tmv.tm_hour)):\(pad2(tmv.tm_min)):\(pad2(tmv.tm_sec)).\(pad3(ms))"
    }
}
