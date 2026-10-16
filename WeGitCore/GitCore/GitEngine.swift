import Foundation
import OSLog

public struct GitFailure: Error, LocalizedError, Sendable {
    public let message: String
    public let details: String
    public let exitCode: Int32
    public var rejectedPushRefspec: String? = nil
    public var errorDescription: String? { message }
}

public enum GitActivityState: Sendable {
    case succeeded, failed, cancelled, timedOut
    public var title: String {
        switch self {
        case .succeeded: L10n.text("完成")
        case .failed: L10n.text("失败")
        case .cancelled: L10n.text("已取消")
        case .timedOut: L10n.text("超时")
        }
    }
}

public struct GitActivity: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public let command: String
    public let state: GitActivityState
    public let exitCode: Int32?
    public let duration: TimeInterval
    public let details: String
    public var repository: URL? = nil
}

public actor ActivityStore {
    private var records: [GitActivity] = []
    private var limit: Int
    private var retention: TimeInterval
    public init(limit: Int = 100, retention: TimeInterval = 86400) {
        self.limit = min(1000, max(1, limit))
        self.retention = min(604800, max(60, retention))
    }
    public func append(_ record: GitActivity) {
        records.insert(record, at: 0)
        trim()
    }
    public func all() -> [GitActivity] {
        trim()
        return records
    }
    public func configure(limit: Int, retention: TimeInterval) {
        self.limit = min(1000, max(1, limit))
        self.retention = min(604800, max(60, retention))
        trim()
    }
    public func clear() { records.removeAll() }
    private func trim() {
        records = Array(records.filter { Date().timeIntervalSince($0.date) <= retention }.prefix(limit))
    }
}

public enum Redaction {
    public static func text(_ value: String) -> String {
        var output = value
        for pattern in [#"(?i)(https?://)[^\s/@]+:[^\s/@]+@"#, #"(?i)(https?://)[^\s/@]+@"#] {
            output = output.replacingOccurrences(
                of: pattern, with: "$1[redacted]@", options: .regularExpression)
        }
        // Authentication headers can contain a scheme plus a credential, or folded values.
        // Redacting only the first non-space token would leave the credential behind.
        output = output.replacingOccurrences(
            of: #"(?im)((?:proxy-)?authorization["']?\s*[:=]\s*)[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*"#,
            with: "$1[redacted]", options: .regularExpression)
        output = output.replacingOccurrences(
            of:
                #"(?i)((?:access_token|private_token|client_secret|token|password)["']?\s*[:=]\s*)("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\S+)"#,
            with: "$1[redacted]", options: .regularExpression)
        return output
    }
}

public struct GitEngine: Sendable {
    private static let log = Logger(subsystem: "com.willxue.wegit", category: "git")
    private static let signposter = OSSignposter(subsystem: "com.willxue.wegit", category: "PointsOfInterest")
    public let executable: URL
    public let runner: any ProcessRunning
    public let activity: ActivityStore
    public let authentication: AskPassBridge?
    public var environment: [String: String]

    public init(
        executable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        runner: any ProcessRunning = ProcessRunner(), activity: ActivityStore = ActivityStore(),
        authentication: AskPassBridge? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        self.runner = runner
        self.activity = activity
        self.authentication = authentication
        var env = environment
        for key in Array(env.keys)
        where key.hasPrefix("GIT_")
            && !["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_ASKPASS"].contains(key)
        {
            env.removeValue(forKey: key)
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "/usr/bin/true"
        env["GIT_SEQUENCE_EDITOR"] = "/usr/bin/false"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        self.environment = env
    }

    public func run(
        _ arguments: [String], in directory: URL? = nil, input: Data? = nil,
        accepted: Set<Int32> = [0], timeout: TimeInterval = 30,
        outputLimit: Int = 8 * 1024 * 1024, onStderr: (@Sendable (Data) -> Void)? = nil,
        stdoutFile: URL? = nil, configuration: [(key: String, value: String)] = [],
        activityRepository: URL? = nil
    ) async throws -> ProcessResult {
        let safeCommands: Set<String> = [
            "status", "for-each-ref", "remote", "rev-parse", "symbolic-ref", "diff", "config", "log",
            "show", "cat-file", "add", "commit", "switch", "fetch", "push", "merge", "rebase",
        ]
        let operation = arguments.first.flatMap { safeCommands.contains($0) ? $0 : nil } ?? "git"
        let interval = Self.signposter.beginInterval(
            "Git command", id: Self.signposter.makeSignpostID(), "\(operation, privacy: .public)")
        defer { Self.signposter.endInterval("Git command", interval) }
        let started = Date()
        let result: ProcessResult
        var commandEnvironment = environment
        let command = arguments.first ?? ""
        let mayAuthenticate = [
            "clone", "fetch", "push", "ls-remote", "pull", "commit", "merge", "rebase", "credential",
        ].contains(command)
        let askPass =
            try mayAuthenticate ? authentication?.session(command: command, repository: directory) : nil
        defer { askPass?.close() }
        if let askPass { commandEnvironment = askPass.environment(over: commandEnvironment) }
        if !configuration.isEmpty {
            guard
                configuration.allSatisfy({
                    !$0.key.contains("\0") && !$0.key.contains("\n") && !$0.value.contains("\0")
                })
            else {
                throw ModelFailure.unsupported(L10n.text("命令配置包含无效字符。"))
            }
            commandEnvironment["GIT_CONFIG_COUNT"] = String(configuration.count)
            for (index, value) in configuration.enumerated() {
                commandEnvironment["GIT_CONFIG_KEY_\(index)"] = value.key
                commandEnvironment["GIT_CONFIG_VALUE_\(index)"] = value.value
            }
        }
        do {
            result = try await runner.run(
                ProcessRequest(
                    executable: executable,
                    arguments: ["--no-pager", "--literal-pathspecs", "--no-optional-locks"] + arguments,
                    directory: directory, environment: commandEnvironment, input: input, timeout: timeout,
                    outputLimit: outputLimit, onStderr: onStderr, stdoutFile: stdoutFile))
        } catch {
            let state: GitActivityState
            switch error {
            case is CancellationError, ProcessFailure.cancelled: state = .cancelled
            case ProcessFailure.timedOut: state = .timedOut
            default: state = .failed
            }
            await activity.append(
                GitActivity(
                    command: "git " + (arguments.first ?? ""), state: state,
                    exitCode: nil, duration: Date().timeIntervalSince(started), details: state.title,
                    repository: activityRepository ?? directory))
            throw error
        }
        // Never persist file contents, commit messages, patches or arbitrary hook output.
        // Scrub before truncation: a long echoed secret must not leave a readable prefix.
        let diagnostic = String(decoding: result.stderr, as: UTF8.self)
        let sanitized = Redaction.text(askPass?.redact(diagnostic) ?? diagnostic)
        let details = String(decoding: sanitized.utf8.prefix(8192), as: UTF8.self)
        await activity.append(
            GitActivity(
                command: "git " + (arguments.first ?? ""),
                state: accepted.contains(result.exitCode) ? .succeeded : .failed, exitCode: result.exitCode,
                duration: result.duration,
                details: accepted.contains(result.exitCode) ? L10n.text("完成") : L10n.text("命令失败；请在操作错误中查看详情"),
                repository: activityRepository ?? directory))
        Self.log.debug("Git operation ended with exit code \(result.exitCode) in \(result.duration) seconds")
        guard accepted.contains(result.exitCode) else {
            throw GitFailure(
                message: Self.classify(details), details: details, exitCode: result.exitCode,
                rejectedPushRefspec: command == "push"
                    ? Self.rejectedPushRefspec(result.stdout, requested: arguments.last) : nil)
        }
        return result
    }

    // A single, complete porcelain rejection for the requested ref can be retried
    // through a new confirmation. An exit code alone says nothing about delivery.
    static func rejectedPushRefspec(_ output: Data, requested: String?) -> String? {
        guard let requested, output.last == 10, let text = String(data: output, encoding: .utf8) else {
            return nil
        }
        let lines: [Substring] = text.split(separator: "\n")
        let statuses = lines.filter {
            $0.count > 1 && $0.dropFirst().first == "\t"
        }
        guard statuses.count == 1 else { return nil }
        let fields = statuses[0].split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "!", fields[1] == requested else {
            return nil
        }
        let summary = String(fields[2])
        guard
            ["[rejected]", "[remote rejected]"].contains(where: {
                summary == $0 || summary.hasPrefix($0 + " (") && summary.hasSuffix(")")
            })
        else { return nil }
        return requested
    }

    private static func classify(_ error: String) -> String {
        let diagnostic = error.lowercased()
        if diagnostic.contains("not a git repository") { return L10n.text("请选择有效的 Git 仓库目录。") }
        if diagnostic.contains("repository")
            && (diagnostic.contains("not found") || diagnostic.contains("does not exist"))
        {
            return L10n.text("找不到 Git 仓库，请检查地址、路径或访问权限。")
        }
        if error.contains("Authentication") || error.contains("Permission denied (publickey)")
            || error.contains("could not read Username")
        {
            return L10n.text("Git 认证失败。请检查系统 Credential Helper 或 SSH Agent。")
        }
        if error.contains("CONFLICT") || error.contains("unmerged") {
            return L10n.text("存在未解决的冲突，请检查文件并继续或中止操作。")
        }
        if error.contains("would be overwritten") { return L10n.text("本地改动会被覆盖，请先提交或处理这些文件。") }
        if error.contains("non-fast-forward") || error.contains("rejected") {
            return L10n.text("远端拒绝推送，请先获取最新状态并检查分支差异。")
        }
        if error.contains(".lock") { return L10n.text("仓库正被其他进程使用，请稍后重试。") }
        if error.contains("Author identity unknown") {
            return L10n.text("尚未配置 Git 提交身份，请设置 user.name 和 user.email。")
        }
        return L10n.text("Git 操作未完成，请查看详情。")
    }
}
