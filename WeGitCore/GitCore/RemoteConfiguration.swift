import Foundation

extension RepositoryService {
    public func upstreamTarget() async throws -> RemoteBranchTarget? {
        let state = try await status()
        guard !state.isDetached else { return nil }
        let targets = try await configValues("branch.\(state.branch).merge")
        guard targets.count == 1,
            let remote = try await configValues("branch.\(state.branch).remote").last,
            let ref = targets.first,
            ref.hasPrefix("refs/heads/")
        else { return nil }
        return RemoteBranchTarget(remote: remote, branch: String(ref.dropFirst("refs/heads/".count)))
    }

    func configValues(_ key: String) async throws -> [String] {
        let output = try await engine.run(
            ["config", "--null", "--get-all", key], in: location.root, accepted: [0, 1])
        guard output.stdout.isEmpty || output.stdout.last == 0 else {
            throw ModelFailure.invalidOutput(L10n.text("Git 配置记录被截断"))
        }
        return try output.stdout.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
            guard let value = String(data: $0, encoding: .utf8) else {
                throw ModelFailure.invalidOutput(L10n.text("Git 配置编码不受支持"))
            }
            return value
        }
    }

    public func remoteDetails() async throws -> [GitRemote] {
        var result: [GitRemote] = []
        for name in try await remotes() { result.append(try await remoteDetails(name: name)) }
        return result
    }

    public func remoteDetails(name: String) async throws -> GitRemote {
        try location.validateIdentity()
        guard try await remotes().contains(name), !name.hasPrefix("-"), !name.contains("\0") else {
            throw ModelFailure.invalidPath
        }
        let rawURLs = try await configValues("remote.\(name).url")
        let rawPushURLs = try await configValues("remote.\(name).pushurl")
        func effectiveList(_ values: [String]) -> [String] {
            values.reduce(into: []) { result, value in
                if value.isEmpty { result.removeAll() } else { result.append(value) }
            }
        }
        let urls = effectiveList(rawURLs)
        let configuredPushURLs = effectiveList(rawPushURLs)
        guard !urls.isEmpty else {
            throw ModelFailure.unsupported(L10n.text("远端没有有效的获取地址。"))
        }
        let fetchURL = try await engine.run(["remote", "get-url", name], in: location.root).text
            .removingLastNewline
        var pushURLs: [String] = []
        for raw in configuredPushURLs.isEmpty ? urls : configuredPushURLs {
            var configuration: [(key: String, value: String)] = [
                ("remote.\(name).url", ""), ("remote.\(name).url", raw), ("remote.\(name).pushurl", ""),
            ]
            if !configuredPushURLs.isEmpty { configuration.append(("remote.\(name).pushurl", raw)) }
            let value = try await engine.run(
                ["remote", "get-url", "--push", name], in: location.root, configuration: configuration
            ).text.removingLastNewline
            pushURLs.append(value)
        }
        guard !fetchURL.isEmpty, !pushURLs.isEmpty, pushURLs.allSatisfy({ !$0.isEmpty }) else {
            throw ModelFailure.invalidOutput(L10n.text("远端地址为空"))
        }
        let refspecs = try await configValues("remote.\(name).fetch")
        return GitRemote(
            name: name, fetchURL: fetchURL, pushURLs: pushURLs, rawURLs: rawURLs, rawPushURLs: rawPushURLs,
            fetchRefspecs: refspecs)
    }

    func pinnedRemote(_ remote: GitRemote, pushIndex: Int? = nil) throws -> [(key: String, value: String)] {
        var destination = remote.fetchURL
        if let pushIndex {
            guard remote.pushURLs.indices.contains(pushIndex) else { throw ModelFailure.invalidPath }
            destination = remote.pushURLs[pushIndex]
        }
        guard !destination.isEmpty, !destination.contains("\0") else { throw ModelFailure.invalidPath }
        if destination.contains("\n") || destination.contains("\r") {
            // Config keys cannot contain newlines. File URLs preserve literal local
            // path bytes without introducing a newline into the rewrite key.
            let colon = destination.firstIndex(of: ":")
            let slash = destination.firstIndex(of: "/")
            let isLocal = colon.map { colon in slash.map { $0 < colon } ?? false } ?? true
            guard isLocal else {
                throw ModelFailure.unsupported(L10n.text("此远端地址包含无法安全固定的换行符，请使用编码后的 URL。"))
            }
            let file =
                destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : location.root.appending(path: destination)
            destination = file.standardizedFileURL.absoluteString
        }
        // Git rewrites URLs once. An unpredictable, full-length alias wins over
        // existing prefix rules, then resolves directly to the confirmed destination.
        // Explicit pushurl also prevents pushInsteadOf from selecting a new target.
        let alias = "wegit-confirmed-" + UUID().uuidString.lowercased() + ":"
        return [
            ("url.\(destination).insteadOf", alias),
            ("remote.\(remote.name).url", ""), ("remote.\(remote.name).url", alias),
            ("remote.\(remote.name).pushurl", ""), ("remote.\(remote.name).pushurl", alias),
        ]
    }

    func verifyRemote(_ remote: GitRemote) async throws {
        guard try await remoteDetails(name: remote.name) == remote else { throw ModelFailure.changed }
    }

    public func pullPreference() async throws -> PullPreference {
        let state = try await status()
        func setting(_ key: String) async throws -> (String, String)? {
            let values = try await configValues(key)
            guard let value = values.last else { return nil }
            let source = try await engine.run(
                ["config", "--show-scope", "--show-origin", "--get", key], in: location.root
            ).text.removingLastNewline
            return (value, key + " · " + source)
        }
        let pullFF = try await setting("pull.ff")
        if let ff = pullFF, ff.0.lowercased() == "only" {
            return PullPreference(
                strategy: .fastForwardOnly, preserveMerges: false, source: ff.1, warning: nil)
        }
        let falseValues = ["false", "0", "no", "off"]
        let trueValues = ["true", "1", "yes", "on"]
        if let ff = pullFF, !(falseValues + trueValues).contains(ff.0.lowercased()) {
            return PullPreference(
                strategy: nil, preserveMerges: false, source: ff.1,
                warning: L10n.text("无法识别 pull.ff，请明确选择本次拉取策略。"))
        }
        var effectiveFF = pullFF
        if effectiveFF == nil { effectiveFF = try await setting("merge.ff") }
        let createMerge = effectiveFF.map { falseValues.contains($0.0.lowercased()) } ?? false
        let local = state.isDetached ? nil : try await setting("branch.\(state.branch).rebase")
        var value = local
        if value == nil { value = try await setting("pull.rebase") }
        guard let value else {
            if let ff = pullFF {
                return PullPreference(
                    strategy: .merge, preserveMerges: false, source: ff.1,
                    warning: nil, createMergeCommit: createMerge)
            }
            return PullPreference(
                strategy: .fastForwardOnly, preserveMerges: false,
                source: L10n.text("未配置 Pull 策略，建议仅快进")
                    + (effectiveFF.map { L10n.text("；合并时使用 ") + $0.1 } ?? ""),
                warning: nil, createMergeCommit: createMerge)
        }
        switch value.0.lowercased() {
        case "true", "1", "yes", "on":
            return PullPreference(strategy: .rebase, preserveMerges: false, source: value.1, warning: nil)
        case "merges", "m":
            return PullPreference(strategy: .rebase, preserveMerges: true, source: value.1, warning: nil)
        case "false", "0", "no", "off":
            let source = value.1 + (effectiveFF.map { "；" + $0.1 } ?? "")
            return PullPreference(
                strategy: effectiveFF?.0.lowercased() == "only" ? .fastForwardOnly : .merge,
                preserveMerges: false, source: source, warning: nil, createMergeCommit: createMerge)
        default:
            return PullPreference(
                strategy: nil, preserveMerges: false, source: value.1,
                warning: L10n.text("当前 Git 配置要求其他变基方式，请明确选择本次拉取策略。"))
        }
    }
}
