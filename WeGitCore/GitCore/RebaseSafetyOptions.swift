import Foundation

extension RepositoryService {
    /// merge-tree can launch repository-configured merge drivers. Preview must
    /// never run those programs; the confirmed Git command keeps normal config.
    func rebasePreviewDrivers() async throws -> [String] {
        let bytes = try await singleCommitEngine.run(
            ["config", "-z", "--name-only", "--get-regexp", "^merge\\..*\\.driver$"],
            in: location.root, accepted: [0, 1], outputLimit: 64 * 1024
        ).stdout
        guard bytes.isEmpty || bytes.last == 0 else { throw ModelFailure.changed }
        let keys = try bytes.split(separator: 0).map { bytes -> String in
            guard let key = String(data: bytes, encoding: .utf8), key.hasPrefix("merge."),
                key.hasSuffix(".driver"), !key.contains("\n")
            else { throw ModelFailure.changed }
            return key
        }
        guard keys.count <= RebaseBudget.stateFiles else { throw RebaseBudget.exceeded }
        return Array(Set(keys)).sorted()
    }

    static func rebaseAuthorScriptCompatible(_ bytes: Data, source: GitCommit) -> Bool {
        guard let text = String(data: bytes, encoding: .utf8) else { return false }
        let names: Set<String> = ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_AUTHOR_DATE"]
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equal = line.firstIndex(of: "=") else { return false }
            let name = String(line[..<equal])
            guard names.contains(name), values[name] == nil else { return false }
            let raw = Array(line[line.index(after: equal)...])
            guard raw.first == "'", raw.count >= 2 else { return false }
            var value = ""
            var index = 1
            var finished = false
            while index < raw.count {
                if raw[index] == "'" {
                    if index == raw.count - 1 {
                        finished = true
                        break
                    }
                    // Git sq_quote uses '\'' to encode a literal apostrophe.
                    guard index + 3 < raw.count, raw[index + 1] == "\\", raw[index + 2] == "'",
                        raw[index + 3] == "'"
                    else { return false }
                    value.append("'")
                    index += 4
                } else {
                    value.append(raw[index])
                    index += 1
                }
            }
            guard finished else { return false }
            values[name] = value
        }
        guard Set(values.keys) == names, values["GIT_AUTHOR_NAME"] == source.author,
            values["GIT_AUTHOR_EMAIL"] == source.authorEmail, let date = values["GIT_AUTHOR_DATE"]
        else { return false }
        let fields = date.split(separator: " ")
        guard fields.count == 2,
            let seconds = Int64(fields[0].hasPrefix("@") ? fields[0].dropFirst() : fields[0]),
            Double(seconds) == source.date.timeIntervalSince1970, fields[1].count == 5,
            ["+", "-"].contains(fields[1].first),
            fields[1].dropFirst().utf8.allSatisfy({ (48...57).contains($0) })
        else { return false }
        return true
    }
}
