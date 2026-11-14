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
