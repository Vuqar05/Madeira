import Foundation

/// Tails a file: opens it, seeks to end, watches for appends via DispatchSource,
/// reads new bytes on a background queue, splits into lines, and passes each
/// line to a callback. Callback runs on the tail's background queue, not main.
final class LogTail {
    private let path: String
    private let onLine: (String) -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.madeira.logtail", qos: .utility)
    private var lineBuffer = Data()
    /// Reused read staging buffer — reallocating 64 KB per readAvailable()
    /// call was pure garbage for the allocator to chase.
    private var readBuf = [UInt8](repeating: 0, count: 64 * 1024)
    private var lastSize: off_t = 0

    init(path: String, onLine: @escaping (String) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    func start() {
        queue.async { [weak self] in
            self?.openAndWatch()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
            if let fd = self?.fd, fd >= 0 {
                close(fd)
                self?.fd = -1
            }
        }
    }

    private func openAndWatch() {
        // Open for reading; allow blocking but we'll read incrementally
        fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd < 0 {
            // File may not exist yet — retry after delay
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openAndWatch()
            }
            return
        }

        // Seek to start so we get the whole log (so the UI matches the file)
        lseek(fd, 0, SEEK_SET)
        lastSize = 0

        // Watch for size growth via DispatchSource (kqueue under the hood)
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        s.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 {
                close(fd)
                self?.fd = -1
            }
        }
        s.resume()
        source = s

        // Initial drain
        readAvailable()

        // Also poll every 250ms as a backup — DispatchSource on iOS sometimes
        // misses appends across processes (Wine writes the file, we read it)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        t.resume()
        pollTimer = t
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        readBuf.withUnsafeMutableBytes { ptr in
            while true {
                let n = read(fd, ptr.baseAddress, ptr.count)
                if n <= 0 { break }
                // ml810: append the raw bytes in one memcpy. `append(
                // contentsOf: buf[0..<n])` went through the Sequence
                // overload, which walks the slice element by element.
                lineBuffer.append(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                  count: n)
                flushLines()
            }
        }
    }

    /// ml810: this used to call `lineBuffer.removeSubrange(0...nlIdx)` once
    /// PER LINE. Each of those shifts the whole remaining buffer down, so
    /// draining a 64 KB read of ~600 log lines cost ~600 memmoves averaging
    /// 32 KB — quadratic in the chunk size, on the queue that feeds every
    /// line the Wine/FEX/DXMT stack emits.
    ///
    /// Now the buffer is scanned once, each line is handed off from a slice
    /// in place, and exactly one removal compacts whatever partial line is
    /// left at the end.
    private func flushLines() {
        var lineStart = lineBuffer.startIndex
        let end = lineBuffer.endIndex
        var i = lineStart

        while i < end {
            guard let nl = lineBuffer[i..<end].firstIndex(of: 0x0A) else { break }
            if nl > lineStart,
               let line = String(data: lineBuffer[lineStart..<nl], encoding: .utf8),
               !line.isEmpty {
                onLine(line)
            }
            lineStart = nl + 1
            i = lineStart
        }

        if lineStart > lineBuffer.startIndex {
            lineBuffer.removeSubrange(lineBuffer.startIndex..<lineStart)
        }
        // Don't let the buffer grow unbounded if a single "line" is huge
        if lineBuffer.count > 1024 * 1024 {
            lineBuffer.removeAll(keepingCapacity: true)
        }
    }
}
