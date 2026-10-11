import Foundation

enum UTF8DisplayPrefix {
    static func decode(_ bytes: Data, truncated: Bool) throws -> String {
        if let text = String(data: bytes, encoding: .utf8) { return text }
        var encoding = UTF8Validation()
        encoding.consume(bytes)
        guard truncated, encoding.valid, encoding.remaining > 0 else {
            throw ModelFailure.invalidOutput("差异行的 UTF-8 编码无效")
        }
        var prefix = bytes
        // A valid UTF-8 stream can lose at most three trailing continuation bytes
        // at the display budget boundary. Invalid interior bytes remain an error.
        for removed in 0...3 {
            if let text = String(data: prefix, encoding: .utf8) { return text }
            guard truncated, removed < 3, !prefix.isEmpty else { break }
            prefix.removeLast()
        }
        throw ModelFailure.invalidOutput("差异行的 UTF-8 编码无效")
    }
}
