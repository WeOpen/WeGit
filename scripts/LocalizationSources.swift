// Read-only localization inventory. Uses SwiftSyntax bundled with the selected Xcode toolchain.
import Foundation
import SwiftParser
import SwiftSyntax

struct Record: Codable {
    let file: String
    let start: Int
    let end: Int
    let key: String
    let source: String
    let context: String
    let skipped: String?
}
final class Visitor: SyntaxVisitor {
    let file: String
    var records: [Record] = []
    init(file: String) {
        self.file = file
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let containsChinese = node.segments.contains { segment in
            guard let text = segment.as(StringSegmentSyntax.self)?.content.text else { return false }
            return text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        var parent = node.parent
        var context = ""
        var skipped: String?
        while let p = parent {
            if p.is(StringLiteralExprSyntax.self) {
                context = "interpolation-data"
                break
            }
            if p.is(EnumCaseElementSyntax.self) {
                skipped = "stable-enum-raw-value"
                break
            }
            if let call = p.as(FunctionCallExprSyntax.self) {
                context = call.calledExpression.trimmedDescription
                if context == "L10n.text" || context == "L10n.key" || context == "L10n.count"
                    || context == "L10n.menuTitle"
                {
                    skipped = "already-localized"
                }
                if context.hasSuffix("accessibilityIdentifier") { skipped = "stable-accessibility-id" }
                if context.hasSuffix("appending") || context.hasSuffix("appendingPathComponent") {
                    skipped = "path-data"
                }
                break
            }
            parent = p.parent
        }
        guard containsChinese || ["L10n.text", "L10n.count", "L10n.key", "L10n.menuTitle"].contains(context)
        else {
            return .visitChildren
        }
        var index = 0
        var copy = node
        copy.segments = StringLiteralSegmentListSyntax(
            node.segments.map { segment in
                if segment.is(ExpressionSegmentSyntax.self) {
                    index += 1
                    return .stringSegment(
                        StringSegmentSyntax(content: .stringSegment("__WEGIT_ARG_\(index)__")))
                }
                return segment
            })
        guard var value = copy.representedLiteralValue else {
            fatalError("Cannot decode " + node.trimmedDescription)
        }
        value = value.replacingOccurrences(of: "%", with: "%%")
        for n in 1..<(index + 1) {
            value = value.replacingOccurrences(of: "__WEGIT_ARG_\(n)__", with: "%\(n)$@")
        }
        records.append(
            Record(
                file: file, start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                end: node.endPositionBeforeTrailingTrivia.utf8Offset, key: value,
                source: node.trimmedDescription, context: context, skipped: skipped))
        return .visitChildren
    }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var all: [Record] = []
for directory in ["WeGit", "WeGitCore", "WeGitAskPass"] {
    let folder = root.appending(path: directory)
    for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!
    where url.pathExtension == "swift" && url.lastPathComponent != "Localization.swift" {
        let source = try String(contentsOf: url, encoding: .utf8)
        let visitor = Visitor(file: String(url.path.dropFirst(root.path.count + 1)))
        visitor.walk(Parser.parse(source: source))
        all += visitor.records

    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(all).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("Scanned localized literals:", all.count)
