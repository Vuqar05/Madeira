#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Unit and round-trip tests for lossless VDF CST, mutation patches and bounds."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
probe_fixture = root / 'madeira-dock/tests/fixtures/steam-input-revision-probe.vdf'

program = r'''
import Foundation

func require(_ body: @autoclosure () throws -> Bool, _ message: String = "precondition failed", file: StaticString = #file, line: UInt = #line) {
    do {
        let result = try body()
        precondition(result, message, file: file, line: line)
    } catch {
        preconditionFailure("\(message): \(error)", file: file, line: line)
    }
}

@main struct CheckVDF {
    static func main() throws {
        let fixturePath = CommandLine.arguments[1]
        let probeBytes = try Data(contentsOf: URL(fileURLWithPath: fixturePath))

        // 1. Unchanged byte round-trip on real fixture
        let probeDoc = try VDFDocument.parse(probeBytes)
        require(probeDoc.serialize() == probeBytes, "probe fixture round-trip must be byte-identical")

        // 2. Unchanged byte round-trip on synthetic fixture with comments, conditions and bare tokens
        let synthetic = """
        // Header comment with symbols: !@#$%^&*()
        "controller_mappings"
        {
            version 3 // inline comment
            "title" "Synthetic Layout"
            "group"
            {
                id 0
                mode four_buttons
                inputs
                {
                    button_a
                    {
                        activators
                        {
                            Full_Press
                            {
                                bindings
                                {
                                    binding "xinput_button A"
                                    binding "key_press SPACE" [$WIN32]
                                }
                            }
                        }
                    }
                }
            }
        }
        // Trailing trivia
        """
        let syntheticBytes = Data(synthetic.utf8)
        let syntheticDoc = try VDFDocument.parse(syntheticBytes)
        require(syntheticDoc.serialize() == syntheticBytes, "synthetic fixture round-trip must be byte-identical")

        // 3. Targeted edit: update title and assert surrounding byte content remains 100% bit-for-bit identical
        let titlePath = VDFPath([.init("controller_mappings"), .init("title")])
        let updatedDoc = try probeDoc.updatingValue(at: titlePath, to: "Modified Probe Title")
        require(updatedDoc.findValueToken(at: titlePath).map { updatedDoc.stringValue(for: $0) } == "Modified Probe Title", "title should be updated")

        // Verify that outside the title token, byte content before and after is bit-for-bit identical
        let oldToken = probeDoc.findValueToken(at: titlePath)!
        let newToken = updatedDoc.findValueToken(at: titlePath)!
        let beforeEditOld = probeBytes.prefix(oldToken.span.lower)
        let beforeEditNew = updatedDoc.sourceData.prefix(newToken.span.lower)
        require(beforeEditOld == beforeEditNew, "bytes before targeted edit must be identical")

        let afterEditOld = probeBytes.suffix(from: oldToken.span.upper)
        let afterEditNew = updatedDoc.sourceData.suffix(from: newToken.span.upper)
        require(afterEditOld == afterEditNew, "bytes after targeted edit must be identical")

        // 4. Sequential edits with reparse rebasing
        let groupModePath = VDFPath([.init("controller_mappings"), .init("group"), .init("mode")])
        let secondEditDoc = try updatedDoc.updatingValue(at: groupModePath, to: "dpad")
        require(secondEditDoc.findValueToken(at: titlePath).map { secondEditDoc.stringValue(for: $0) } == "Modified Probe Title", "edit 1 preserved")
        require(secondEditDoc.findValueToken(at: groupModePath).map { secondEditDoc.stringValue(for: $0) } == "dpad", "edit 2 applied")

        // 5. Duplicate path resolution with occurrence indices
        let multiGroupDoc = try VDFDocument.parse(syntheticBytes)
        let binding0Path = VDFPath([.init("controller_mappings"), .init("group"), .init("inputs"), .init("button_a"),
                                    .init("activators"), .init("Full_Press"), .init("bindings"), .init("binding", index: 0)])
        let binding1Path = VDFPath([.init("controller_mappings"), .init("group"), .init("inputs"), .init("button_a"),
                                    .init("activators"), .init("Full_Press"), .init("bindings"), .init("binding", index: 1)])
        let b0 = multiGroupDoc.findValueToken(at: binding0Path)
        let b1 = multiGroupDoc.findValueToken(at: binding1Path)
        require(b0 != nil && multiGroupDoc.stringValue(for: b0!) == "xinput_button A", "binding[0] resolved")
        require(b1 != nil && multiGroupDoc.stringValue(for: b1!) == "key_press SPACE", "binding[1] resolved")

        // 6. Patch collision and boundary validation
        let patchA = BytePatch(range: 10..<20, replacement: Data("hello".utf8))
        let patchOverlapping = BytePatch(range: 15..<25, replacement: Data("world".utf8))
        require(patchA.conflicts(with: patchOverlapping), "overlapping ranges must conflict")

        let patchInsertSame1 = BytePatch(offset: 30, replacement: Data("a".utf8))
        let patchInsertSame2 = BytePatch(offset: 30, replacement: Data("b".utf8))
        require(patchInsertSame1.conflicts(with: patchInsertSame2), "insertions at same offset must conflict")

        let patchInside = BytePatch(offset: 15, replacement: Data("c".utf8))
        require(patchA.conflicts(with: patchInside), "insertion inside replacement range must conflict")

        let patchBoundary = BytePatch(offset: 20, replacement: Data("d".utf8))
        require(patchA.conflicts(with: patchBoundary), "insertion at upper boundary of replacement range must conflict")

        let patchDisjoint = BytePatch(range: 25..<35, replacement: Data("ok".utf8))
        require(!patchA.conflicts(with: patchDisjoint), "disjoint patches must not conflict")

        // 7. Strict limits and error conditions
        // Oversized (> 1 MB - 1)
        let oversizedData = Data(repeating: 0x20, count: 1 << 20)
        var caughtOversized = false
        do { _ = try VDFDocument.parse(oversizedData) } catch VDFParseError.oversized { caughtOversized = true } catch {}
        require(caughtOversized, "oversized document must throw VDFParseError.oversized")

        // Binary null byte
        let nullByteData = Data([0x22, 0x61, 0x22, 0x00, 0x22, 0x62, 0x22])
        var caughtBinary = false
        do { _ = try VDFDocument.parse(nullByteData) } catch VDFParseError.binaryContent { caughtBinary = true } catch {}
        require(caughtBinary, "null byte must throw VDFParseError.binaryContent")

        // Invalid UTF-8
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
        var caughtUTF8 = false
        do { _ = try VDFDocument.parse(invalidUTF8) } catch VDFParseError.invalidUTF8 { caughtUTF8 = true } catch {}
        require(caughtUTF8, "invalid UTF-8 must throw VDFParseError.invalidUTF8")

        // Unsupported directive
        let directiveData = Data("#include \"base.vdf\"\n\"root\" { \"k\" \"v\" }".utf8)
        var caughtDirective = false
        do { _ = try VDFDocument.parse(directiveData) } catch VDFParseError.unsupportedDirective { caughtDirective = true } catch {}
        require(caughtDirective, "#include must throw VDFParseError.unsupportedDirective")

        // Unclosed quoted string reaching EOF
        let unclosedData = Data("\"root\" { \"k\" \"unclosed".utf8)
        var caughtUnclosed = false
        do { _ = try VDFDocument.parse(unclosedData) } catch VDFParseError.unclosedString { caughtUnclosed = true } catch {}
        require(caughtUnclosed, "unclosed string reaching EOF must throw VDFParseError.unclosedString")

        // Literal newline inside quoted string: allowed and preserved!
        let multiline = "\"root\" {\n\"description\" \"Line 1\nLine 2\r\nLine 3\"\n}"
        let multilineBytes = Data(multiline.utf8)
        let multilineDoc = try VDFDocument.parse(multilineBytes)
        require(multilineDoc.serialize() == multilineBytes, "multiline string with literal newlines must round-trip exactly")
        let descToken = multilineDoc.findValueToken(at: VDFPath([.init("root"), .init("description")]))!
        require(multilineDoc.stringValue(for: descToken) == "Line 1\nLine 2\r\nLine 3", "multiline string must decode literal newlines")

        // Unknown escape preserves both backslash and character
        let unknownEscape = "\"root\" { \"escaped\" \"value\\qwith\\unknown\" }"
        let unknownEscapeDoc = try VDFDocument.parse(Data(unknownEscape.utf8))
        let escToken = unknownEscapeDoc.findValueToken(at: VDFPath([.init("root"), .init("escaped")]))!
        require(unknownEscapeDoc.stringValue(for: escToken) == "value\\qwith\\unknown", "unknown escape must preserve backslash and char")

        // Excessive nesting (>= 64)
        var deep = ""
        for i in 0..<65 { deep += "\"block\(i)\" { " }
        deep += "\"k\" \"v\""
        for _ in 0..<65 { deep += " }" }
        var caughtDeep = false
        do { _ = try VDFDocument.parse(Data(deep.utf8)) } catch VDFParseError.excessiveNesting { caughtDeep = true } catch {}
        require(caughtDeep, "nesting >= 64 must throw VDFParseError.excessiveNesting")

        // 8. Platform conditions: malformed condition rejection and valid condition preservation
        let malformedCondNewline = "\"root\" {\n\"key\" \"val\" [$WIN32\n\"key2\" \"val2\"\n}"
        var caughtMalformedNewline = false
        do { _ = try VDFDocument.parse(Data(malformedCondNewline.utf8)) } catch VDFParseError.malformedCondition { caughtMalformedNewline = true } catch {}
        require(caughtMalformedNewline, "unterminated condition before newline must throw VDFParseError.malformedCondition")

        let malformedCondEOF = "\"root\" {\n\"key\" \"val\" [$WIN32"
        var caughtMalformedEOF = false
        do { _ = try VDFDocument.parse(Data(malformedCondEOF.utf8)) } catch VDFParseError.malformedCondition { caughtMalformedEOF = true } catch {}
        require(caughtMalformedEOF, "unterminated condition at EOF must throw VDFParseError.malformedCondition")

        // Valid conditions on block heads and leaf nodes round-trip byte-for-byte
        let validConditions = "\"root\" [$WIN32] {\n  \"group\" [$OSX] {\n    \"binding\" \"xinput_button A\" [$LINUX]\n  }\n}"
        let validCondBytes = Data(validConditions.utf8)
        let validCondDoc = try VDFDocument.parse(validCondBytes)
        require(validCondDoc.serialize() == validCondBytes, "valid conditions on block head and leaves must round-trip bit-for-bit")
        guard case .block(_, _, let rchildren, _, let rcond) = validCondDoc.rootNodes.first else {
            fatalError("root node should be block")
        }
        require(rcond.map { validCondDoc.stringValue(for: $0) } == ["[$WIN32]"], "root block pre-condition captured")
        guard case .block(_, _, let gchildren, _, let gcond) = rchildren.first else {
            fatalError("group node should be block")
        }
        require(gcond.map { validCondDoc.stringValue(for: $0) } == ["[$OSX]"], "child block pre-condition captured")
        guard case .leaf(_, _, let lcond) = gchildren.first else {
            fatalError("binding should be leaf")
        }
        require(lcond.map { validCondDoc.stringValue(for: $0) } == ["[$LINUX]"], "leaf condition captured")
        require(validCondDoc.rootNodes[0].fullSpan == SourceSpan(lower: 0, upper: validCondBytes.count),
                "a block with a leading condition spans through its closing brace")

        // A node keeps a condition written before AND after its value or body; neither replaces the other.
        let bothConditions = "\"root\" {\n  \"bindings\" [$PRE] {\n    \"binding\" [$LEAF_PRE] \"xinput_button A\" [$LEAF_POST]\n  } [$POST]\n}"
        let bothBytes = Data(bothConditions.utf8)
        let bothDoc = try VDFDocument.parse(bothBytes)
        require(bothDoc.serialize() == bothBytes, "doubled conditions round-trip bit-for-bit")
        guard case .block(_, _, let bothRoot, _, let bothRootCond) = bothDoc.rootNodes.first,
              case .block(_, _, let bothLeaves, _, let bothBlockCond) = bothRoot.first,
              case .leaf(_, _, let bothLeafCond) = bothLeaves.first else {
            fatalError("doubled-condition fixture shape")
        }
        require(bothRootCond.isEmpty, "unconditional block has no conditions")
        require(bothBlockCond.map { bothDoc.stringValue(for: $0) } == ["[$PRE]", "[$POST]"], "block keeps leading and trailing conditions in source order")
        require(bothLeafCond.map { bothDoc.stringValue(for: $0) } == ["[$LEAF_PRE]", "[$LEAF_POST]"], "leaf keeps leading and trailing conditions in source order")
        require(bothRoot[0].conditionTokens.count == 2 && bothLeaves[0].conditionTokens.count == 2, "conditionTokens exposes every condition")
        let blockRaw = String(decoding: bothBytes[bothRoot[0].fullSpan.lower..<bothRoot[0].fullSpan.upper], as: UTF8.self)
        require(blockRaw.hasPrefix("\"bindings\" [$PRE] {") && blockRaw.hasSuffix("} [$POST]"), "block span covers both conditions")
        let leafRaw = String(decoding: bothBytes[bothLeaves[0].fullSpan.lower..<bothLeaves[0].fullSpan.upper], as: UTF8.self)
        require(leafRaw == "\"binding\" [$LEAF_PRE] \"xinput_button A\" [$LEAF_POST]", "leaf span covers both conditions")

        print("PASS: lossless VDF CST round-trip, targeted edit preservation, sequential rebasing, patch interval validation, and strict error limits")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-input-vdf-') as temporary:
    tmp = Path(temporary)
    (tmp / 'main.swift').write_text(program)
    subprocess.run([shutil.which('swiftc'), '-parse-as-library', '-sanitize=address', '-module-cache-path', str(tmp / 'modules'),
                    str(app / 'SteamInputVDF.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(probe_fixture)], check=True)
