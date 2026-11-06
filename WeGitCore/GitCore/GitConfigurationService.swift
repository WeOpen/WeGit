import Darwin
import Foundation

public enum GitSettingKey: String, CaseIterable, Sendable, Identifiable {
    case userName = "user.name"
    case userEmail = "user.email"
    case defaultBranch = "init.defaultBranch"
    case pullRebase = "pull.rebase"
    case pullFastForward = "pull.ff"
    case mergeFastForward = "merge.ff"
    case commitSigning = "commit.gpgsign"
    case tagSigning = "tag.gpgsign"
    case signingFormat = "gpg.format"
    case signingKey = "user.signingkey"
    case gpgProgram = "gpg.program"
    case allowedSignersFile = "gpg.ssh.allowedSignersFile"
    case commitTemplate = "commit.template"
    case excludesFile = "core.excludesfile"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .userName: L10n.text("提交者姓名")
        case .userEmail: L10n.text("提交邮箱")
        case .defaultBranch: L10n.text("新仓库默认分支")
        case .pullRebase: L10n.text("Pull 整合方式")
        case .pullFastForward: L10n.text("Pull 快进策略")
        case .mergeFastForward: L10n.text("Merge 快进策略")
        case .commitSigning: L10n.text("提交签名")
        case .tagSigning: L10n.text("Tag 签名")
        case .signingFormat: L10n.text("签名格式")
        case .signingKey: L10n.text("签名密钥标识")
        case .gpgProgram: L10n.text("OpenPGP 工具")
        case .allowedSignersFile: L10n.text("SSH 签名者文件")
        case .commitTemplate: L10n.text("提交消息模板")
        case .excludesFile: L10n.text("额外忽略文件")
        }
    }
    public var choices: [String] {
        switch self {
        case .pullRebase: ["false", "true", "merges"]
        case .pullFastForward, .mergeFastForward: ["true", "false", "only"]
        case .commitSigning, .tagSigning: ["false", "true"]
        case .signingFormat: ["openpgp", "ssh"]
        default: []
        }
    }
    public var isSigning: Bool {
        [.commitSigning, .tagSigning, .signingFormat, .signingKey, .gpgProgram, .allowedSignersFile].contains(
            self)
    }
    public var isFileSetting: Bool {
        [.gpgProgram, .allowedSignersFile, .commitTemplate, .excludesFile, .signingKey].contains(self)
    }
}

public enum GitSettingScope: String, CaseIterable, Sendable {
    case global, local, worktree
    public var title: String {
        switch self {
        case .global: L10n.text("全局")
        case .local: L10n.text("当前仓库")
        case .worktree: L10n.text("当前工作区")
        }
    }
    var argument: String { "--" + rawValue }
}

public struct GitSettingRecord: Equatable, Sendable {
    public let scope: String
    public let origin: String
    public let value: String
    public let sourceKey: String?
    public init(scope: String, origin: String, value: String, sourceKey: String? = nil) {
        self.scope = scope
        self.origin = origin
        self.value = value
        self.sourceKey = sourceKey
    }
}

public struct GitSettingSnapshot: Sendable {
    public let key: GitSettingKey
    public let records: [GitSettingRecord]
    public let globalValues: [String]
    public let localValues: [String]
    public let worktreeValues: [String]
    public let worktreeConfigEnabled: Bool
    public var effective: GitSettingRecord? { records.last }
    public func values(in scope: GitSettingScope) -> [String] {
        switch scope {
        case .global: globalValues
        case .local: localValues
        case .worktree: worktreeValues
        }
    }
}

/// Only exposes the fixed identity/strategy/signing/file whitelist. Credentials and arbitrary config keys
/// are deliberately not part of this editor's API.
public struct GitConfigurationService: Sendable {
    private static let globalQueue = RepositoryOperationQueue()
    public let engine: GitEngine
    public let location: RepositoryLocation?
    private let queue: RepositoryOperationQueue
    private let sharedQueue: RepositoryOperationQueue
    public init(
        engine: GitEngine, location: RepositoryLocation? = nil,
        queue: RepositoryOperationQueue? = nil
    ) {
        self.engine = engine
        self.location = location
        self.queue =
            queue ?? location.map { RepositoryOperationQueue.worktree(for: $0) } ?? RepositoryOperationQueue()
        self.sharedQueue =
            location.map { RepositoryOperationQueue.shared(for: $0) } ?? RepositoryOperationQueue()
    }
    private var directory: URL { location?.root ?? URL(fileURLWithPath: "/") }

    public func read(_ key: GitSettingKey) async throws -> GitSettingSnapshot {
        try await read(key, worktreeEnabled: worktreeConfigurationEnabled())
    }

    private func read(_ key: GitSettingKey, worktreeEnabled: Bool) async throws -> GitSettingSnapshot {
        try location?.validateIdentity()
        let query =
            key == .gpgProgram
            ? ["--get-regexp", #"^gpg\.(program|openpgp\.program)$"#] : ["--get-all", key.rawValue]
        let output = try await engine.run(
            ["config", "--null", "--show-scope", "--show-origin"] + query,
            in: directory, accepted: [0, 1])
        let fields = try strings(output.stdout)
        guard fields.count % 3 == 0 else { throw ModelFailure.invalidOutput(L10n.text("配置来源记录被截断")) }
        var records: [GitSettingRecord] = []
        for index in stride(from: 0, to: fields.count, by: 3) {
            if key == .gpgProgram {
                guard let newline = fields[index + 2].firstIndex(of: "\n") else { throw ModelFailure.changed }
                let key = String(fields[index + 2][..<newline])
                let value = String(fields[index + 2][fields[index + 2].index(after: newline)...])
                records.append(
                    GitSettingRecord(
                        scope: fields[index], origin: fields[index + 1], value: value, sourceKey: key))
            } else {
                records.append(
                    GitSettingRecord(
                        scope: fields[index], origin: fields[index + 1], value: fields[index + 2],
                        sourceKey: key.rawValue))
            }
        }
        let global = try await ownValues(key, in: .global)
        let local = location == nil ? [] : try await ownValues(key, in: .local)
        let worktree = worktreeEnabled ? try await ownValues(key, in: .worktree) : []
        return GitSettingSnapshot(
            key: key, records: records, globalValues: global, localValues: local,
            worktreeValues: worktree, worktreeConfigEnabled: worktreeEnabled)
    }

    public func readAll() async throws -> [GitSettingSnapshot] {
        var result: [GitSettingSnapshot] = []
        let enabled = try await worktreeConfigurationEnabled()
        for key in GitSettingKey.allCases { result.append(try await read(key, worktreeEnabled: enabled)) }
        return result
    }

    public func set(_ value: String?, scope: GitSettingScope, expected: GitSettingSnapshot) async throws
        -> GitSettingSnapshot
    {
        try await sharedQueue.perform {
            try await setUnderSharedPermit(value, scope: scope, expected: expected)
        }
    }

    private func setUnderSharedPermit(_ value: String?, scope: GitSettingScope, expected: GitSettingSnapshot)
        async throws -> GitSettingSnapshot
    {
        let mutate: @Sendable () async throws -> GitSettingSnapshot = {
            try location?.validateIdentity()
            guard scope == .global || location != nil else {
                throw ModelFailure.unsupported(L10n.text("请先打开需要配置的仓库。"))
            }
            if scope == .worktree {
                guard expected.worktreeConfigEnabled, try await worktreeConfigurationEnabled() else {
                    throw ModelFailure.unsupported(L10n.text("此仓库尚未启用工作区配置，请编辑当前仓库设置。"))
                }
            }
            let proposed: String?
            if let value { proposed = try await validate(value, for: expected.key) } else { proposed = nil }
            guard try await ownValues(expected.key, in: scope) == expected.values(in: scope) else {
                throw ModelFailure.changed
            }
            try location?.validateIdentity()
            if let location, scope != .global {
                return try await editRepositoryFile(
                    proposed, scope: scope, expected: expected, location: location)
            }
            if let value = proposed {
                _ = try await engine.run(
                    ["config", scope.argument, "--replace-all", "--", expected.key.rawValue, value],
                    in: directory)
            } else {
                _ = try await engine.run(
                    ["config", scope.argument, "--unset-all", "--", expected.key.rawValue],
                    in: directory, accepted: [0, 5])
            }
            return try await read(expected.key)
        }
        if scope == .global {
            if queue === sharedQueue { return try await Self.globalQueue.perform(mutate) }
            return try await queue.perform { try await Self.globalQueue.perform(mutate) }
        }
        if queue === sharedQueue { return try await mutate() }
        return try await queue.perform(mutate)
    }

    private func editRepositoryFile(
        _ value: String?, scope: GitSettingScope, expected: GitSettingSnapshot,
        location: RepositoryLocation
    ) async throws -> GitSettingSnapshot {
        let lease = try await SnapshotIO.run { _ in
            try RepositoryConfigurationFile(location: location, scope: scope)
        }
        let storage = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        let file = storage.url.appending(path: "config")
        try await SnapshotIO.run { cancellation in
            let descriptor = Darwin.open(
                file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(descriptor) }
            try RecoveryFileIO.write(
                lease.snapshot.bytes ?? Data(), descriptor: descriptor, cancellation: cancellation)
        }
        let current = try await engine.run(
            ["config", "--file", file.path, "--no-includes", "--null", "--get-all", expected.key.rawValue],
            in: directory, accepted: [0, 1])
        guard try strings(current.stdout) == expected.values(in: scope) else { throw ModelFailure.changed }
        if let value, expected.key == .gpgProgram {
            _ = try await engine.run(
                ["config", "--file", file.path, "--unset-all", "--", expected.key.rawValue],
                in: directory, accepted: [0, 5])
            // Both OpenPGP program keys are aliases. A final legacy entry gives
            // the chosen tool precedence without editing an additional key.
            try await SnapshotIO.run { cancellation in
                let descriptor = Darwin.open(file.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw ModelFailure.changed }
                defer { Darwin.close(descriptor) }
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                try RecoveryFileIO.write(
                    Data(("\n[gpg]\n\tprogram = \"" + escaped + "\"\n").utf8), descriptor: descriptor,
                    cancellation: cancellation)
            }
        } else if let value {
            _ = try await engine.run(
                ["config", "--file", file.path, "--replace-all", "--", expected.key.rawValue, value],
                in: directory)
        } else {
            _ = try await engine.run(
                ["config", "--file", file.path, "--unset-all", "--", expected.key.rawValue],
                in: directory, accepted: [0, 5])
        }
        let bytes = try await SnapshotIO.run { _ in try Data(contentsOf: file) }
        do {
            try await lease.install(bytes)
            if scope == .worktree, try await !worktreeConfigurationEnabled() {
                throw ConfigurationWriteOutcomeUnknown(retainedInput: lease.retainedInput)
            }
            let result = try await read(expected.key)
            guard result.values(in: scope) == (value.map({ [$0] }) ?? []) else { throw ModelFailure.changed }
            try await lease.finish()
            return result
        } catch {
            if lease.hasInstalled {
                throw (error as? ConfigurationWriteOutcomeUnknown)
                    ?? ConfigurationWriteOutcomeUnknown(retainedInput: lease.retainedInput)
            }
            throw error
        }
    }

    public func worktreeConfigurationEnabled() async throws -> Bool {
        guard location != nil else { return false }
        let value = try await engine.run(
            ["config", "--local", "--type=bool", "--get", "extensions.worktreeConfig"],
            in: directory, accepted: [0, 1])
        return value.exitCode == 0 && value.text.removingLastNewline == "true"
    }

    private func ownValues(_ key: GitSettingKey, in scope: GitSettingScope) async throws -> [String] {
        if scope == .worktree {
            guard let location, try await worktreeConfigurationEnabled() else { return [] }
            let file = location.gitDirectory.appending(path: "config.worktree")
            guard try RepositoryNodeIdentity.readIfPresent(file) != nil else { return [] }
            let output = try await engine.run(
                ["config", "--file", file.path, "--no-includes", "--null", "--get-all", key.rawValue],
                in: directory, accepted: [0, 1])
            return try strings(output.stdout)
        }
        let output = try await engine.run(
            ["config", scope.argument, "--no-includes", "--null", "--get-all", key.rawValue],
            in: directory, accepted: [0, 1])
        return try strings(output.stdout)
    }

    private func validate(_ value: String, for key: GitSettingKey) async throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 4096,
            !value.contains("\0"), !value.contains("\n"), !value.contains("\r")
        else {
            throw ModelFailure.unsupported(L10n.text("配置值不能为空、过长或包含换行。要使用继承值，请移除此作用域的设置。"))
        }
        if !key.choices.isEmpty {
            guard key.choices.contains(value) else {
                throw ModelFailure.unsupported(L10n.text("请选择支持的 Git 策略值。"))
            }
        } else if key == .defaultBranch {
            guard !value.hasPrefix("-"), !value.contains("@{") else { throw ModelFailure.invalidPath }
            _ = try await engine.run(["check-ref-format", "--branch", value], in: directory)
        } else if key == .gpgProgram {
            return try GitProgramPath.quote(
                GitProgramPath.resolve(value, engine: engine, directory: directory).path)
        } else if [.allowedSignersFile, .commitTemplate, .excludesFile].contains(key) {
            return try GitProgramPath.readableFile(value, directory: directory).path
        } else if key == .userName || key == .userEmail {
            guard !value.contains("<"), !value.contains(">") else {
                throw ModelFailure.unsupported(L10n.text("身份字段不能包含尖括号。"))
            }
        }
        return value
    }

    private func strings(_ bytes: Data) throws -> [String] {
        guard bytes.isEmpty || bytes.last == 0 else {
            throw ModelFailure.invalidOutput(L10n.text("Git 配置记录被截断"))
        }
        return try bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
            guard let value = String(data: $0, encoding: .utf8) else {
                throw ModelFailure.invalidOutput(L10n.text("Git 配置编码不受支持"))
            }
            return value
        }
    }
}
