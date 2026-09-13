import Foundation

/// Canonicalize a log line into a "signature" — strip variable parts
/// (hex addresses, thread IDs, counts, RIP values) so that semantically
/// identical events bucket together for dedup.
///
/// Example transformations:
///   `0024:trace:file:NtWriteFile = SUCCESS (52)`  → `T:trace:file:NtWriteFile = SUCCESS (#)`
///   `[iOS] CompileBlock: RIP=0x140028d46 MaxInst=0`  → `[iOS] CompileBlock: RIP=0x? MaxInst=#`
///   `[mach_exc] UNHANDLED #1234 pc=0x123abc addr=0x10 ...`  → `[mach_exc] UNHANDLED #_ pc=0x? addr=0x? ...`
///   `[CALLRET_OOB #5] UNDERFLOW callret_sp=0x...` → `[CALLRET_OOB #_] UNDERFLOW callret_sp=0x?`
///
/// ml810: this used to be a chain of seven `replacingOccurrences(options:
/// .regularExpression)` / `range(of:options:)` calls plus `lowercased()`
/// and fourteen `String.contains` probes. Foundation does not cache the
/// pattern for those String conveniences, so every log line compiled seven
/// NSRegularExpressions, ran seven full Unicode scans and allocated six
/// intermediate Strings — and this runs on EVERY line Wine, FEX and DXMT
/// emit, on the tail queue, while the game is running.
///
/// It is now two linear passes over the UTF-8 bytes, no regex, no
/// allocation beyond the byte buffers. Equivalence with the old chain was
/// checked against 3,628 lines built from the real format strings in this
/// tree and 300,000 randomized cases over the alphabet the rules branch on.
struct LogPattern {

    // MARK: byte classification

    @inline(__always) private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) private static func isHex(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
    }
    @inline(__always) private static func isAlpha(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a)
    }
    /// ASCII whitespace. ICU's `\s` also covers the Unicode space separators,
    /// which dprintf-generated log output does not contain.
    @inline(__always) private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || (c >= 0x09 && c <= 0x0d)
    }
    @inline(__always) private static func asciiLower(_ c: UInt8) -> UInt8 {
        (c >= 0x41 && c <= 0x5a) ? c &+ 32 : c
    }
    @inline(__always) private static func isContinuation(_ c: UInt8) -> Bool {
        c >= 0x80 && c <= 0xbf
    }

    /// `\b` word-char test on a single byte.
    ///
    /// ASCII follows `\w` exactly. For UTF-8 lead bytes we approximate:
    /// 0xF0–0xF4 leads a four-byte sequence, i.e. a codepoint in plane 1+,
    /// which in these logs means an emoji — not a word char. Everything
    /// else non-ASCII is a two- or three-byte sequence, i.e. a letter,
    /// which is. That gets both real cases right (`café1234` untouched,
    /// `🎉1234` collapsed) and differs from ICU only on plane-1 *letters*,
    /// which no log line contains.
    @inline(__always) private static func isWordByte(_ c: UInt8) -> Bool {
        if c < 0x80 { return isDigit(c) || isAlpha(c) || c == 0x5f }
        return !(c >= 0xf0 && c <= 0xf4)
    }

    /// ASCII-case-insensitive search for `needle` (which must be lowercase)
    /// in `hay[from...]`. Replaces `lowercased()` + `String.contains`.
    private static func contains(_ hay: [UInt8], _ from: Int, _ needle: [UInt8]) -> Bool {
        let n = hay.count, m = needle.count
        if m == 0 { return true }
        if n - from < m { return false }
        let first = needle[0]
        var p = from
        let limit = n - m
        while p <= limit {
            if asciiLower(hay[p]) == first {
                var k = 1
                while k < m && asciiLower(hay[p + k]) == needle[k] { k += 1 }
                if k == m { return true }
            }
            p += 1
        }
        return false
    }

    private static func hasPrefix(_ hay: [UInt8], _ from: Int, _ pfx: [UInt8]) -> Bool {
        if hay.count - from < pfx.count { return false }
        var k = 0
        while k < pfx.count {
            if hay[from + k] != pfx[k] { return false }
            k += 1
        }
        return true
    }

    /// `hay[from..<to] == tag`, without materializing the slice.
    private static func rangeEquals(_ hay: [UInt8], _ from: Int, _ to: Int, _ tag: [UInt8]) -> Bool {
        if to - from != tag.count { return false }
        var k = 0
        while k < tag.count {
            if hay[from + k] != tag[k] { return false }
            k += 1
        }
        return true
    }

    // Needles, hoisted out of the per-line path.
    private static let nFatal: [UInt8] = Array("fatal".utf8)
    private static let nC1d: [UInt8] = Array("c000001d".utf8)
    private static let nC05: [UInt8] = Array("c0000005".utf8)
    private static let nTerm: [UInt8] = Array("ntterminateprocess".utf8)
    private static let nUnhandled: [UInt8] = Array("unhandled".utf8)
    private static let nSeh: [UInt8] = Array("seh:".utf8)
    private static let nErr: [UInt8] = Array("err:".utf8)
    private static let nOkSp: [UInt8] = Array("ok ".utf8)
    private static let nOkParen: [UInt8] = Array(" ok)".utf8)
    private static let nSucceeded: [UInt8] = Array("succeeded".utf8)
    private static let nSuccess: [UInt8] = Array("success".utf8)
    private static let nPresent: [UInt8] = Array("present #".utf8)
    private static let nParty: [UInt8] = Array("🎉".utf8)
    private static let nWarn: [UInt8] = Array("warn".utf8)
    private static let nDebug: [UInt8] = Array("debug".utf8)
    private static let nTrace: [UInt8] = Array("trace:".utf8)
    private static let pE: [UInt8] = Array("E ".utf8)
    private static let pW: [UInt8] = Array("W ".utf8)
    private static let pD: [UInt8] = Array("D ".utf8)
    private static let levelTags: [[UInt8]] = [
        Array("INFO".utf8), Array("OK".utf8), Array("ERR".utf8),
        Array("DBG".utf8), Array("WARN".utf8), Array("FATAL".utf8),
    ]

    /// Returns (signature, displayLevel) for a raw log line.
    static func canonicalize(_ raw: String) -> (signature: String, level: LogStore.LogEntry.Level) {
        let s = Array(raw.utf8)
        let n = s.count
        var i = 0

        // Strip leading `[HH:MM:SS.mmm]` timestamp prefix from wine_log_write
        if n >= 14, s[0] == 0x5b, s[13] == 0x5d,
           isDigit(s[1]), isDigit(s[2]), s[3] == 0x3a,
           isDigit(s[4]), isDigit(s[5]), s[6] == 0x3a,
           isDigit(s[7]), isDigit(s[8]), s[9] == 0x2e,
           isDigit(s[10]), isDigit(s[11]), isDigit(s[12]) {
            i = 14
            while i < n && isSpace(s[i]) { i += 1 }
        }

        // Level is inferred from the line with the timestamp removed but
        // everything else still in place — same point in the chain as before.
        let level = inferLevel(s, i)

        // Strip top-level `[LEVEL]` if present
        if i < n, s[i] == 0x5b {
            var j = i + 1
            while j < n && s[j] != 0x5d { j += 1 }
            if j < n, levelTags.contains(where: { rangeEquals(s, i + 1, j, $0) }) {
                i = j + 1
                while i < n && isSpace(s[i]) { i += 1 }
            }
        }

        // Strip the `I 24 ` / `E 24 ` / `D 24 ` Wine fixme/err/trace prefix
        // (level letter + thread hex id from wine_log_write/dprintf)
        if i < n, s[i] == 0x49 || s[i] == 0x45 || s[i] == 0x44 || s[i] == 0x57 {
            var j = i + 1
            if j < n, isSpace(s[j]) {
                while j < n && isSpace(s[j]) { j += 1 }
                var k = j
                while k < n && isHex(s[k]) { k += 1 }
                if k > j, k < n, isSpace(s[k]) {
                    while k < n && isSpace(s[k]) { k += 1 }
                    i = k
                }
            }
        }

        var a = [UInt8]()
        a.reserveCapacity(n + 8)

        // Strip wine thread-id prefix `0024:` (4 hex digits + colon)
        if i + 4 < n, s[i + 4] == 0x3a,
           isHex(s[i]), isHex(s[i + 1]), isHex(s[i + 2]), isHex(s[i + 3]) {
            a.append(0x54); a.append(0x3a)      // "T:"
            i += 5
        }

        // ---- pass A: hex literals → `0x?` ------------------------------
        //
        // This has to be its own pass. The old chain ran the hex rule
        // globally BEFORE the others, and the two interact: `240x65535`
        // contains `0x65535` and must become `240x?`, and `#0x12` becomes
        // `#0x?` and only then `#_x?`. Splitting at exactly this boundary
        // preserves that precedence, because nothing pass A emits (`0x?`)
        // can be re-matched by pass A and nothing pass B emits (`#_`, `#`)
        // can be re-matched by pass B.
        while i < n {
            if s[i] == 0x30, i + 2 < n, s[i + 1] == 0x78, isHex(s[i + 2]) {
                var j = i + 2
                while j < n && isHex(s[j]) { j += 1 }
                a.append(0x30); a.append(0x78); a.append(0x3f)   // "0x?"
                i = j
            } else {
                a.append(s[i])
                i += 1
            }
        }

        // ---- pass B: `#N` → `#_`, long numbers → `#`, whitespace -------
        var out = [UInt8]()
        out.reserveCapacity(a.count)
        var lastWord = false            // class of the last sequence emitted
        var pendingSpace = true         // leading whitespace is trimmed
        let m = a.count
        i = 0
        while i < m {
            let c = a[i]
            if isSpace(c) {
                while i < m && isSpace(a[i]) { i += 1 }
                pendingSpace = true
                continue
            }
            if pendingSpace {
                if !out.isEmpty { out.append(0x20); lastWord = false }
                pendingSpace = false
            }
            // `#\d+` → `#_`
            if c == 0x23, i + 1 < m, isDigit(a[i + 1]) {
                var j = i + 1
                while j < m && isDigit(a[j]) { j += 1 }
                out.append(0x23); out.append(0x5f)      // "#_"
                lastWord = true                          // '_' is a word char
                i = j
                continue
            }
            // `\b\d{3,}\b` → `#`
            if isDigit(c), !lastWord {
                var j = i
                while j < m && isDigit(a[j]) { j += 1 }
                if j - i >= 3, j >= m || !isWordByte(a[j]) {
                    out.append(0x23)                     // "#"
                    lastWord = false                     // '#' is not a word char
                } else {
                    out.append(contentsOf: a[i..<j])
                    lastWord = true
                }
                i = j
                continue
            }
            out.append(c)
            // Lead bytes set the class; continuation bytes leave it alone.
            if !isContinuation(c) { lastWord = isWordByte(c) }
            i += 1
        }

        // Cap signature length for display. A string of at most 200 UTF-8
        // bytes has at most 200 Characters, so the grapheme count is only
        // paid for the rare long line.
        var sig = String(decoding: out, as: UTF8.self)
        if out.count > 200, sig.count > 200 {
            sig = String(sig.prefix(200))
        }
        return (sig, level)
    }

    /// Infer log level from raw line content.
    private static func inferLevel(_ s: [UInt8], _ i: Int) -> LogStore.LogEntry.Level {
        if contains(s, i, nFatal) || contains(s, i, nC1d) || contains(s, i, nC05) ||
            contains(s, i, nTerm) || contains(s, i, nUnhandled) ||
            contains(s, i, nSeh) || contains(s, i, nErr) || hasPrefix(s, i, pE) {
            return .error
        }
        if contains(s, i, nOkSp) || contains(s, i, nOkParen) || contains(s, i, nSucceeded) ||
            contains(s, i, nSuccess) || contains(s, i, nPresent) || contains(s, i, nParty) {
            return .success
        }
        if contains(s, i, nWarn) || hasPrefix(s, i, pW) {
            return .info  // shown distinctly via level color anyway
        }
        if hasPrefix(s, i, pD) || contains(s, i, nDebug) || contains(s, i, nTrace) {
            return .debug
        }
        return .info
    }
}
