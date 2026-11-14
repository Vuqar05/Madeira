// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Exact byte span [lower, upper) within immutable sourceData.
public struct SourceSpan: Equatable, Hashable, Sendable {
    public let lower: Int
    public let upper: Int
    public var count: Int { upper - lower }
    public var isEmpty: Bool { lower >= upper }

    public init(lower: Int, upper: Int) {
        precondition(lower <= upper, "lower bound must not exceed upper bound")
        self.lower = lower
        self.upper = upper
    }
}

/// Token in the Concrete Syntax Tree (CST), retaining source position and trivia.
public struct VDFToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case string(isQuoted: Bool)
        case openBrace           // {
        case closeBrace          // }
        case condition(String)   // [$WIN32]
        case directive(String)   // #include, #base
        case comment(String)     // // ...
    }

    public let kind: Kind
    public let span: SourceSpan
    public let leadingTriviaSpan: SourceSpan?

    public init(kind: Kind, span: SourceSpan, leadingTriviaSpan: SourceSpan? = nil) {
        self.kind = kind
        self.span = span
        self.leadingTriviaSpan = leadingTriviaSpan
    }
}

/// Node in the Concrete Syntax Tree.
public indirect enum VDFNode: Equatable, Sendable {
    /// `conditions` holds every condition written on the node, in source order:
    /// one before the value or brace, one after it, or both. None is evaluated.
    case leaf(key: VDFToken, value: VDFToken, conditions: [VDFToken])
    case block(key: VDFToken, openBrace: VDFToken, children: [VDFNode], closeBrace: VDFToken, conditions: [VDFToken])
    case standaloneComment(VDFToken)
    case directive(VDFToken)

    public var conditionTokens: [VDFToken] {
        switch self {
        case .leaf(_, _, let conditions): return conditions
        case .block(_, _, _, _, let conditions): return conditions
        case .standaloneComment, .directive: return []
        }
    }

    public var fullSpan: SourceSpan {
        switch self {
        case .leaf(let key, let val, let conditions):
            // A condition may precede the value, so the node ends at whichever comes last.
            let upper = conditions.reduce(val.span.upper) { max($0, $1.span.upper) }
            return SourceSpan(lower: key.span.lower, upper: upper)
        case .block(let key, _, _, let close, let conditions):
            let upper = conditions.reduce(close.span.upper) { max($0, $1.span.upper) }
            return SourceSpan(lower: key.span.lower, upper: upper)
        case .standaloneComment(let token), .directive(let token):
            return token.span
        }
    }
}

/// Parse errors with explicit failure conditions.
public enum VDFParseError: LocalizedError, Equatable {
    case oversized
    case excessiveNesting
    case excessiveTokens
    case binaryContent
    case invalidUTF8
    case unclosedString
    case unmatchedBrace
    case missingIdentifier
    case unsupportedDirective(String)
    case malformedCondition

    public var errorDescription: String? {
        switch self {
        case .oversized: return "The layout is too large."
        case .excessiveNesting: return "The layout nests too deeply."
        case .excessiveTokens: return "The layout has too many entries."
        case .binaryContent: return "The layout contains binary content."
        case .invalidUTF8: return "The layout is not valid UTF-8 text."
        case .unclosedString: return "The layout ends inside a string."
        case .unmatchedBrace: return "The layout has an unmatched brace."
        case .missingIdentifier: return "The layout has an element without an identifier."
        case .unsupportedDirective(let name): return "Directives like \(name) are not supported."
        case .malformedCondition: return "The layout contains a malformed or unterminated platform condition."
        }
    }
}

/// Mutation error conditions.
public enum VDFMutationError: LocalizedError, Equatable {
    case conflictingPatch
    case pathNotFound(VDFPath)
    case invalidValue

    public var errorDescription: String? {
        switch self {
        case .conflictingPatch: return "Mutation rejected: overlapping or ambiguous patches."
        case .pathNotFound(let path): return "Path not found: \(path)."
        case .invalidValue: return "Invalid replacement value."
        }
    }
}

/// Deterministic path targeting duplicate keys via 0-based sibling occurrence index.
public struct VDFPath: Equatable, Hashable, CustomStringConvertible, Sendable {
    public struct Step: Equatable, Hashable, Sendable {
        public let key: String
        public let index: Int

        public init(_ key: String, index: Int = 0) {
            self.key = key
            self.index = index
        }
    }

    public let steps: [Step]

    public init(_ steps: [Step]) {
        self.steps = steps
    }

    public var description: String {
        steps.map { "\($0.key)[\($0.index)]" }.joined(separator: "/")
    }
}

/// Non-overlapping byte replacement patch against immutable sourceData.
public struct BytePatch: Equatable, Sendable {
    public let range: Range<Int>
    public let replacement: Data

    public init(range: Range<Int>, replacement: Data) {
        self.range = range
        self.replacement = replacement
    }

    public init(offset: Int, replacement: Data) {
        self.range = offset..<offset
        self.replacement = replacement
    }

    /// Explicit interval conflict logic covering replacements, deletions, and zero-length insertions.
    public func conflicts(with other: BytePatch) -> Bool {
        // Two non-empty replacement/deletion ranges conflict if their intervals overlap
        if !self.range.isEmpty && !other.range.isEmpty {
            return max(self.range.lowerBound, other.range.lowerBound) < min(self.range.upperBound, other.range.upperBound)
        }
        // Two zero-length insertions at the exact same byte offset conflict
        if self.range.isEmpty && other.range.isEmpty {
            return self.range.lowerBound == other.range.lowerBound
        }
        // One zero-length insertion and one non-empty replacement/deletion:
        // The insertion conflicts if it falls inside or on the boundary of the replaced range
        let (empty, nonEmpty) = self.range.isEmpty ? (self.range.lowerBound, other.range) : (other.range.lowerBound, self.range)
        return nonEmpty.contains(empty) || empty == nonEmpty.upperBound
    }
}

/// Source-preserving Concrete Syntax Tree document for Valve KeyValues text (VDF).
public struct VDFDocument: Equatable, @unchecked Sendable {
    public static let maxBytes = (1 << 20) - 1   // 1 MB - 1 (1,048,575 bytes)
    public static let maxDepth = 63               // depth < 64
    public static let maxTokens = 100_000

    public let sourceData: Data
    public let rootNodes: [VDFNode]
    public let trailingTriviaSpan: SourceSpan?

    public init(sourceData: Data, rootNodes: [VDFNode], trailingTriviaSpan: SourceSpan? = nil) {
        self.sourceData = sourceData
        self.rootNodes = rootNodes
        self.trailingTriviaSpan = trailingTriviaSpan
    }

    /// Unmodified documents serialize bit-for-bit identically to sourceData.
    public func serialize() -> Data {
        sourceData
    }

    /// Extract decoded string value from a token, resolving standard escapes.
    /// Unknown escapes preserve both backslash and character (\x).
    public func stringValue(for token: VDFToken) -> String {
        let slice = sourceData[token.span.lower..<token.span.upper]
        if case .string(let isQuoted) = token.kind {
            if isQuoted {
                // Strip outer quotes
                guard slice.count >= 2, slice.first == 0x22, slice.last == 0x22 else {
                    return String(decoding: slice, as: UTF8.self)
                }
                let inner = slice.dropFirst().dropLast()
                return decodeEscapes(inner)
            } else {
                return String(decoding: slice, as: UTF8.self)
            }
        }
        return String(decoding: slice, as: UTF8.self)
    }

    private func decodeEscapes(_ bytes: Data.SubSequence) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let b = bytes[i]
            if b == 0x5C, bytes.index(after: i) < bytes.endIndex { // '\'
                let next = bytes[bytes.index(after: i)]
                switch next {
                case 0x6E: out.append(0x0A)       // \n
                case 0x74: out.append(0x09)       // \t
                case 0x22: out.append(0x22)       // \"
                case 0x5C: out.append(0x5C)       // \\
                default:
                    // Unknown escape: preserve both backslash and character
                    out.append(0x5C)
                    out.append(next)
                }
                i = bytes.index(i, offsetBy: 2)
                continue
            }
            out.append(b)
            i = bytes.index(after: i)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Locate a node's leaf value token at the specified path.
    public func findValueToken(at path: VDFPath) -> VDFToken? {
        guard let node = findNode(at: path) else { return nil }
        if case .leaf(_, let value, _) = node { return value }
        return nil
    }

    /// Locate a node at the specified path.
    public func findNode(at path: VDFPath) -> VDFNode? {
        guard !path.steps.isEmpty else { return nil }
        var currentChildren = rootNodes
        for (stepIndex, step) in path.steps.enumerated() {
            var matches: [VDFNode] = []
            for child in currentChildren {
                switch child {
                case .leaf(let key, _, _), .block(let key, _, _, _, _):
                    if stringValue(for: key).caseInsensitiveCompare(step.key) == .orderedSame {
                        matches.append(child)
                    }
                case .standaloneComment, .directive:
                    continue
                }
            }
            guard step.index >= 0, step.index < matches.count else { return nil }
            let matched = matches[step.index]
            if stepIndex == path.steps.count - 1 {
                return matched
            }
            if case .block(_, _, let children, _, _) = matched {
                currentChildren = children
            } else {
                return nil
            }
        }
        return nil
    }

    /// Apply a set of non-conflicting byte patches to sourceData.
    public func applying(patches: [BytePatch]) throws -> Data {
        // Validate interval disjointness & zero-length collision rules
        for i in 0..<patches.count {
            for j in (i + 1)..<patches.count {
                if patches[i].conflicts(with: patches[j]) {
                    throw VDFMutationError.conflictingPatch
                }
            }
        }
        // Sort patches in strictly descending order of lowerBound
        let sorted = patches.sorted { $0.range.lowerBound > $1.range.lowerBound }
        var result = sourceData
        for patch in sorted {
            guard patch.range.lowerBound >= 0, patch.range.upperBound <= result.count else {
                throw VDFMutationError.conflictingPatch
            }
            result.replaceSubrange(patch.range, with: patch.replacement)
        }
        return result
    }

    /// Mutate a leaf value at path, returning a newly parsed and re-based VDFDocument.
    public func updatingValue(at path: VDFPath, to newValue: String) throws -> VDFDocument {
        guard let token = findValueToken(at: path) else {
            throw VDFMutationError.pathNotFound(path)
        }
        let escaped = Self.formatQuotedString(newValue)
        let patch = BytePatch(range: token.span.lower..<token.span.upper, replacement: Data(escaped.utf8))
        let patchedBytes = try applying(patches: [patch])
        return try Self.parse(patchedBytes)
    }

    /// Format a string with standard Valve escapes for serialization.
    public static func formatQuotedString(_ text: String) -> String {
        var out = "\""
        for char in text {
            switch char {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            default: out.append(char)
            }
        }
        out.append("\"")
        return out
    }
}

// MARK: - Parser Implementation

extension VDFDocument {
    public static func parse(_ data: Data) throws -> VDFDocument {
        guard data.count <= maxBytes else { throw VDFParseError.oversized }
        guard !data.contains(0x00) else { throw VDFParseError.binaryContent }
        guard String(data: data, encoding: .utf8) != nil else { throw VDFParseError.invalidUTF8 }

        let lexer = VDFLexer(data: data)
        var parser = VDFDocumentParser(lexer: lexer)
        return try parser.parseDocument()
    }
}

struct VDFLexer {
    let data: Data
    var index: Int = 0
    var tokenCount: Int = 0

    init(data: Data) {
        self.data = data
        // Skip UTF-8 BOM if present
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            self.index = 3
        }
    }

    var isAtEnd: Bool { index >= data.count }

    mutating func scanTrivia() -> SourceSpan? {
        let start = index
        while index < data.count {
            let b = data[index]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                index += 1
                continue
            }
            if b == 0x2F, index + 1 < data.count, data[index + 1] == 0x2F { // //
                index += 2
                while index < data.count && data[index] != 0x0A {
                    index += 1
                }
                if index < data.count && data[index] == 0x0A {
                    index += 1
                }
                continue
            }
            break
        }
        return index > start ? SourceSpan(lower: start, upper: index) : nil
    }

    mutating func nextToken() throws -> VDFToken? {
        let trivia = scanTrivia()
        guard index < data.count else { return nil }

        tokenCount += 1
        guard tokenCount <= VDFDocument.maxTokens else { throw VDFParseError.excessiveTokens }

        let start = index
        let b = data[index]

        if b == 0x7B { // {
            index += 1
            return VDFToken(kind: .openBrace, span: SourceSpan(lower: start, upper: index), leadingTriviaSpan: trivia)
        }
        if b == 0x7D { // }
            index += 1
            return VDFToken(kind: .closeBrace, span: SourceSpan(lower: start, upper: index), leadingTriviaSpan: trivia)
        }
        if b == 0x5B { // [ (condition)
            index += 1
            while index < data.count && data[index] != 0x5D && data[index] != 0x0A && data[index] != 0x0D {
                index += 1
            }
            guard index < data.count, data[index] == 0x5D else {
                throw VDFParseError.malformedCondition
            }
            index += 1
            let conditionString = String(decoding: data[start..<index], as: UTF8.self)
            return VDFToken(kind: .condition(conditionString), span: SourceSpan(lower: start, upper: index), leadingTriviaSpan: trivia)
        }
        if b == 0x23 { // # (directive)
            index += 1
            while index < data.count {
                let c = data[index]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x7B || c == 0x7D || c == 0x22 { break }
                index += 1
            }
            let directiveName = String(decoding: data[start..<index], as: UTF8.self)
            throw VDFParseError.unsupportedDirective(directiveName)
        }

        if b == 0x22 { // Quoted string
            index += 1
            while index < data.count {
                let c = data[index]
                if c == 0x22 { // Closing quote
                    index += 1
                    return VDFToken(kind: .string(isQuoted: true), span: SourceSpan(lower: start, upper: index), leadingTriviaSpan: trivia)
                }
                if c == 0x5C, index + 1 < data.count { // Escape
                    index += 2
                    continue
                }
                // Literal newlines inside quotes are allowed (Valve description blocks)
                index += 1
            }
            // Reaching EOF without closing quote
            throw VDFParseError.unclosedString
        }

        // Bare token
        while index < data.count {
            let c = data[index]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x7B || c == 0x7D || c == 0x22 || c == 0x5B || c == 0x5D {
                break
            }
            index += 1
        }
        guard index > start else { throw VDFParseError.missingIdentifier }
        return VDFToken(kind: .string(isQuoted: false), span: SourceSpan(lower: start, upper: index), leadingTriviaSpan: trivia)
    }
}

struct VDFDocumentParser {
    var lexer: VDFLexer
    var currentToken: VDFToken?

    init(lexer: VDFLexer) {
        self.lexer = lexer
    }

    mutating func advance() throws {
        currentToken = try lexer.nextToken()
    }

    mutating func parseDocument() throws -> VDFDocument {
        try advance()
        var nodes: [VDFNode] = []
        var depth = 0

        while let token = currentToken {
            if token.kind == .closeBrace {
                throw VDFParseError.unmatchedBrace
            }
            let node = try parseNode(depth: &depth)
            nodes.append(node)
        }

        let trailingTrivia = lexer.scanTrivia()
        return VDFDocument(sourceData: lexer.data, rootNodes: nodes, trailingTriviaSpan: trailingTrivia)
    }

    mutating func parseNode(depth: inout Int) throws -> VDFNode {
        guard let keyToken = currentToken else { throw VDFParseError.missingIdentifier }
        guard case .string = keyToken.kind else { throw VDFParseError.missingIdentifier }

        try advance()
        guard var next = currentToken else { throw VDFParseError.missingIdentifier }

        var preConditionToken: VDFToken? = nil
        if case .condition = next.kind {
            preConditionToken = next
            try advance()
            guard let afterCond = currentToken else { throw VDFParseError.missingIdentifier }
            next = afterCond
        }

        if next.kind == .openBrace {
            let openBraceToken = next
            depth += 1
            guard depth < VDFDocument.maxDepth else { throw VDFParseError.excessiveNesting }

            try advance()
            var children: [VDFNode] = []
            while let childToken = currentToken, childToken.kind != .closeBrace {
                let childNode = try parseNode(depth: &depth)
                children.append(childNode)
            }
            guard let closeBraceToken = currentToken, closeBraceToken.kind == .closeBrace else {
                throw VDFParseError.unmatchedBrace
            }
            depth -= 1
            try advance()

            var postConditionToken: VDFToken? = nil
            if let cond = currentToken, case .condition = cond.kind {
                postConditionToken = cond
                try advance()
            }
            let conditionTokens = [preConditionToken, postConditionToken].compactMap { $0 }
            return .block(key: keyToken, openBrace: openBraceToken, children: children, closeBrace: closeBraceToken, conditions: conditionTokens)
        } else if case .string = next.kind {
            let valueToken = next
            try advance()

            var postConditionToken: VDFToken? = nil
            if let cond = currentToken, case .condition = cond.kind {
                postConditionToken = cond
                try advance()
            }
            let conditionTokens = [preConditionToken, postConditionToken].compactMap { $0 }
            return .leaf(key: keyToken, value: valueToken, conditions: conditionTokens)
        } else {
            throw VDFParseError.missingIdentifier
        }
    }
}

// MARK: - Structural writer

/// A node to be written into a document: a leaf or a block of nodes.
public indirect enum VDFNewNode: Equatable, Sendable {
    case leaf(String, String)
    case block(String, [VDFNewNode])
}

/// Structural edits. Every edit is one byte patch against `sourceData`, and the
/// result is parsed again, so bytes outside the patched range stay identical:
/// unknown fields, repeated keys, comments, ordering and every condition
/// written anywhere else are kept. A removed node takes its own conditions
/// with it; nothing else is ever removed. Inserted text follows the style of
/// the surrounding source: its newline and its indentation unit.
extension VDFDocument {
    /// "\r\n" when the source uses it, otherwise "\n".
    var newline: String {
        sourceData.range(of: Data("\r\n".utf8)) != nil ? "\r\n" : "\n"
    }

    /// One indentation step: a tab unless the source indents with spaces only.
    private var indentUnit: String {
        let text = String(decoding: sourceData, as: UTF8.self)
        if text.contains("\n\t") { return "\t" }
        for width in [4, 2] where text.contains("\n" + String(repeating: " ", count: width) + "\"") {
            return String(repeating: " ", count: width)
        }
        return "\t"
    }

    /// Spaces and tabs at the start of the line holding `offset`.
    private func indentation(ofLineAt offset: Int) -> String {
        var start = offset
        while start > 0, sourceData[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < sourceData.count, sourceData[end] == 0x20 || sourceData[end] == 0x09 { end += 1 }
        return String(decoding: sourceData[start..<end], as: UTF8.self)
    }

    /// True when only spaces and tabs precede `offset` on its line.
    private func startsLine(_ offset: Int) -> Bool {
        var index = offset
        while index > 0 {
            let byte = sourceData[index - 1]
            if byte == 0x0A { return true }
            if byte != 0x20 && byte != 0x09 { return false }
            index -= 1
        }
        return true
    }

    /// The offset just after the line break ending the line at `offset`, when
    /// only spaces, tabs or a `//` comment follow `offset` on it; else nil.
    private func endOfLine(after offset: Int) -> Int? {
        var index = offset
        while index < sourceData.count, sourceData[index] == 0x20 || sourceData[index] == 0x09 || sourceData[index] == 0x0D { index += 1 }
        if index + 1 < sourceData.count, sourceData[index] == 0x2F, sourceData[index + 1] == 0x2F {
            while index < sourceData.count, sourceData[index] != 0x0A { index += 1 }
        }
        if index == sourceData.count { return index }
        return sourceData[index] == 0x0A ? index + 1 : nil
    }

    private func render(_ node: VDFNewNode, indent: String, unit: String, newline: String) -> String {
        switch node {
        case .leaf(let key, let value):
            return indent + Self.formatQuotedString(key) + "\t\t" + Self.formatQuotedString(value)
        case .block(let key, let children):
            var text = indent + Self.formatQuotedString(key) + newline + indent + "{" + newline
            for child in children { text += render(child, indent: indent + unit, unit: unit, newline: newline) + newline }
            return text + indent + "}"
        }
    }

    private static func validate(_ node: VDFNewNode) throws {
        switch node {
        case .leaf(let key, let value):
            guard !key.isEmpty, !key.contains("\0"), !value.contains("\0") else { throw VDFMutationError.invalidValue }
        case .block(let key, let children):
            guard !key.isEmpty, !key.contains("\0") else { throw VDFMutationError.invalidValue }
            try children.forEach(validate)
        }
    }

    /// Element children (leaves and blocks) of a block.
    private static func elements(_ children: [VDFNode]) -> [VDFNode] {
        children.filter { if case .standaloneComment = $0 { return false }; if case .directive = $0 { return false }; return true }
    }

    private func rebuilt(_ patch: BytePatch) throws -> VDFDocument {
        try Self.parse(try applying(patches: [patch]))
    }

    /// Inserts `node` into the block at `parent`, before its element child at
    /// `index` (counted over leaves and blocks), or after the last one.
    public func inserting(_ node: VDFNewNode, into parent: VDFPath, at index: Int? = nil) throws -> VDFDocument {
        try Self.validate(node)
        let nl = newline, unit = indentUnit
        return try insertText(into: parent, at: index) { indent in self.render(node, indent: indent, unit: unit, newline: nl) }
    }

    /// Inserts a copy of the exact source text of the node at `source`
    /// (its conditions, comments inside it, unknown fields and repeated keys
    /// included) into `parent`, after its last element child.
    public func insertingCopy(of source: VDFPath, into parent: VDFPath) throws -> VDFDocument {
        guard let node = findNode(at: source) else { throw VDFMutationError.pathNotFound(source) }
        let span = node.fullSpan
        let raw = String(decoding: sourceData[span.lower..<span.upper], as: UTF8.self)
        return try insertText(into: parent, at: nil) { indent in indent + raw }
    }

    private func insertText(into parent: VDFPath, at index: Int?, render: (String) -> String) throws -> VDFDocument {
        guard case .block(_, let open, let allChildren, let close, _)? = findNode(at: parent) else {
            throw VDFMutationError.pathNotFound(parent)
        }
        let children = Self.elements(allChildren)
        let nl = newline, unit = indentUnit
        let parentIndent = indentation(ofLineAt: open.span.lower)
        let indent: String
        if let first = children.first, startsLine(first.fullSpan.lower) {
            indent = indentation(ofLineAt: first.fullSpan.lower)
        } else {
            indent = parentIndent + unit
        }
        if let index, index < 0 || index > children.count { throw VDFMutationError.pathNotFound(parent) }
        if let index, index < children.count {
            let before = children[index].fullSpan.lower
            if startsLine(before) {
                var lineStart = before
                while lineStart > 0, sourceData[lineStart - 1] != 0x0A { lineStart -= 1 }
                return try rebuilt(BytePatch(offset: lineStart, replacement: Data((render(indent) + nl).utf8)))
            }
            return try rebuilt(BytePatch(offset: before, replacement: Data((render("") + " ").utf8)))
        }
        let anchor = children.last?.fullSpan.upper ?? open.span.upper
        if let lineEnd = endOfLine(after: anchor), lineEnd <= close.span.lower {
            // The anchor ends its line: the new node gets lines of its own.
            let text = render(indent) + nl
            if lineEnd == sourceData.count, sourceData.last != 0x0A {
                return try rebuilt(BytePatch(offset: lineEnd, replacement: Data((nl + text).utf8)))
            }
            return try rebuilt(BytePatch(offset: lineEnd, replacement: Data(text.utf8)))
        }
        // Inline block such as `{ "a" "b" }`: break the line before the new node.
        let tail = children.isEmpty ? nl + parentIndent : ""
        return try rebuilt(BytePatch(offset: anchor, replacement: Data((nl + render(indent) + tail).utf8)))
    }

    /// Removes the node at `path`, with its own conditions. When it is alone
    /// on its lines, those lines go with it; anything else is untouched.
    public func removing(at path: VDFPath) throws -> VDFDocument {
        guard let node = findNode(at: path) else { throw VDFMutationError.pathNotFound(path) }
        var lower = node.fullSpan.lower
        var upper = node.fullSpan.upper
        if startsLine(lower), let lineEnd = endOfLine(after: upper),
           !(upper..<lineEnd).contains(where: { sourceData[$0] == 0x2F }) {
            while lower > 0, sourceData[lower - 1] == 0x20 || sourceData[lower - 1] == 0x09 { lower -= 1 }
            upper = lineEnd
        }
        return try rebuilt(BytePatch(range: lower..<upper, replacement: Data()))
    }

    /// Replaces the key of the node at `path`; its value or body and its
    /// conditions are unchanged.
    public func renamingKey(at path: VDFPath, to key: String) throws -> VDFDocument {
        guard !key.isEmpty, !key.contains("\0") else { throw VDFMutationError.invalidValue }
        guard let node = findNode(at: path) else { throw VDFMutationError.pathNotFound(path) }
        let token: VDFToken
        switch node {
        case .leaf(let k, _, _), .block(let k, _, _, _, _): token = k
        case .standaloneComment, .directive: throw VDFMutationError.pathNotFound(path)
        }
        return try rebuilt(BytePatch(range: token.span.lower..<token.span.upper, replacement: Data(Self.formatQuotedString(key).utf8)))
    }

    /// How many element children named `key` the block at `parent` has.
    public func count(_ key: String, in parent: VDFPath) -> Int {
        guard case .block(_, _, let children, _, _)? = findNode(at: parent) else { return 0 }
        return children.filter { child in
            switch child {
            case .leaf(let k, _, _), .block(let k, _, _, _, _): return stringValue(for: k).caseInsensitiveCompare(key) == .orderedSame
            default: return false
            }
        }.count
    }

    /// Sets the leaf `key` in the block at `parent`. Where the key is repeated,
    /// the last occurrence is the one read, so it is the one changed; when the
    /// key is absent a leaf is appended. `nil` removes every occurrence.
    public func settingLeaf(_ key: String, to value: String?, in parent: VDFPath) throws -> VDFDocument {
        let existing = count(key, in: parent)
        guard let value else {
            var document = self
            for index in stride(from: existing - 1, through: 0, by: -1) {
                document = try document.removing(at: VDFPath(parent.steps + [.init(key, index: index)]))
            }
            return document
        }
        if existing > 0 {
            let path = VDFPath(parent.steps + [.init(key, index: existing - 1)])
            guard case .leaf? = findNode(at: path) else { throw VDFMutationError.pathNotFound(path) }
            return try updatingValue(at: path, to: value)
        }
        return try inserting(.leaf(key, value), into: parent)
    }

    /// The path of the last block named `key` in `parent`, creating an empty
    /// one at the end when there is none.
    public func ensuringBlock(_ key: String, in parent: VDFPath) throws -> (VDFDocument, VDFPath) {
        let existing = count(key, in: parent)
        if existing > 0 {
            let path = VDFPath(parent.steps + [.init(key, index: existing - 1)])
            if case .block? = findNode(at: path) { return (self, path) }
            throw VDFMutationError.pathNotFound(path)
        }
        let document = try inserting(.block(key, []), into: parent)
        return (document, VDFPath(parent.steps + [.init(key, index: 0)]))
    }
}
