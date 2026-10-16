import Foundation

public enum GitSettingKey: String, CaseIterable, Sendable, Identifiable {
    case userName = "user.name"
    case userEmail = "user.email"
    case defaultBranch = "init.defaultBranch"
    case pullRebase = "pull.rebase"
    case pullFastForward = "pull.ff"
    case mergeFastForward = "merge.ff"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .userName: L10n.text("提交者姓名")
        case .userEmail: L10n.text("提交邮箱")
        case .defaultBranch: L10n.text("新仓库默认分支")
        case .pullRebase: L10n.text("Pull 整合方式")
        case .pullFastForward: L10n.text("Pull 快进策略")
        case .mergeFastForward: L10n.text("Merge 快进策略")
        }
    }
    public var choices: [String] {
        switch self {
        case .pullRebase: ["false", "true", "merges"]
        case .pullFastForward, .mergeFastForward: ["true", "false", "only"]
        default: []
        }
    }
}

public enum GitSettingScope: String, CaseIterable, Sendable {
    case global, local
    public var title: String { self == .global ? L10n.text("全局") : L10n.text("当前仓库") }
    var argument: String { "--" + rawValue }
}

public struct GitSettingRecord: Equatable, Sendable {
    public let scope: String
    public let origin: String
    public let value: String
}

public struct GitSettingSnapshot: Sendable {
    public let key: GitSettingKey
    public let records: [GitSettingRecord]
    public let globalValues: [String]
    public let localValues: [String]
    public var effective: GitSettingRecord? { records.last }
    public func values(in scope: GitSettingScope) -> [String] { scope == .local ? localValues : globalValues }
}

/// Only exposes P0 identity/strategy settings. Credentials and arbitrary config keys
/// are deliberately not part of this editor's API.
public struct GitConfigurationService: Sendable {
    private static let globalQueue = RepositoryOperationQueue()
    public let engine: GitEngine
    public let location: RepositoryLocation?
    private let queue: RepositoryOperationQueue
    public init(
        engine: GitEngine, location: RepositoryLocation? = nil,
        queue: RepositoryOperationQueue = RepositoryOperationQueue()
    ) {
        self.engine = engine
        self.location = location
        self.queue = queue
    }
    private var directory: URL { location?.root ?? URL(fileURLWithPath: "/") }

    public func read(_ key: GitSettingKey) async throws -> GitSettingSnapshot {
        try location?.validateIdentity()
        let output = try await engine.run(
            ["config", "--null", "--show-scope", "--show-origin", "--get-all", key.rawValue],
            in: directory, accepted: [0, 1])
        let fields = try strings(output.stdout)
        guard fields.count % 3 == 0 else { throw ModelFailure.invalidOutput(L10n.text("配置来源记录被截断")) }
        var records: [GitSettingRecord] = []
        for index in stride(from: 0, to: fields.count, by: 3) {
            records.append(
                GitSettingRecord(scope: fields[index], origin: fields[index + 1], value: fields[index + 2]))
        }
        let global = try await ownValues(key, in: .global)
        let local = location == nil ? [] : try await ownValues(key, in: .local)
        return GitSettingSnapshot(key: key, records: records, globalValues: global, localValues: local)
    }

    public func readAll() async throws -> [GitSettingSnapshot] {
        var result: [GitSettingSnapshot] = []
        for key in GitSettingKey.allCases { result.append(try await read(key)) }
        return result
    }

    public func set(_ value: String?, scope: GitSettingScope, expected: GitSettingSnapshot) async throws
        -> GitSettingSnapshot
    {
        try await queue.perform {
            try await Self.globalQueue.perform {
                try location?.validateIdentity()
                guard scope != .local || location != nil else {
                    throw ModelFailure.unsupported(L10n.text("请先打开需要配置的仓库。"))
                }
                if let value { try await validate(value, for: expected.key) }
                guard try await ownValues(expected.key, in: scope) == expected.values(in: scope) else {
                    throw ModelFailure.changed
                }
                try location?.validateIdentity()
                if let value {
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
        }
    }

    private func ownValues(_ key: GitSettingKey, in scope: GitSettingScope) async throws -> [String] {
        let output = try await engine.run(
            ["config", scope.argument, "--no-includes", "--null", "--get-all", key.rawValue],
            in: directory, accepted: [0, 1])
        return try strings(output.stdout)
    }

    private func validate(_ value: String, for key: GitSettingKey) async throws {
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
        } else {
            guard !value.contains("<"), !value.contains(">") else {
                throw ModelFailure.unsupported(L10n.text("身份字段不能包含尖括号。"))
            }
        }
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
