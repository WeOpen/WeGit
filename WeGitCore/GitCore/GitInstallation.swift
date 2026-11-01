import Foundation

public struct GitInstallation: Sendable {
    public static let minimumVersion = "2.46"
    public let executable: URL
    public let version: String

    /// A read-only probe: unsupported Git must never reach a fixture or a scoped
    /// configuration write. One command checks system, global and runtime precedence.
    static func verifyConfigurationIsolation(
        executable: URL, runner: any ProcessRunning = ProcessRunner()
    ) async throws {
        let directory = try SnapshotDirectory()
        defer { withExtendedLifetime(directory) {} }
        let key = "wegitisolation.probe" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let global = directory.url.appending(path: "global-config")
        let system = directory.url.appending(path: "system-config")
        for (file, value) in [(system, "system"), (global, "global")] {
            try Data("[wegitisolation]\n\(key.split(separator: ".")[1]) = \(value)\n".utf8)
                .write(to: file, options: .withoutOverwriting)
        }
        var environment = GitEngine(executable: executable).environment
        environment["GIT_CONFIG_GLOBAL"] = global.path
        environment["GIT_CONFIG_SYSTEM"] = system.path
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = key
        environment["GIT_CONFIG_VALUE_0"] = "runtime"
        let result = try await runner.run(
            ProcessRequest(
                executable: executable, arguments: ["config", "--get-all", key],
                directory: directory.url, environment: environment, timeout: 5, outputLimit: 4096))
        guard result.exitCode == 0, result.text == "system\nglobal\nruntime\n" else {
            throw ModelFailure.unsupported(L10n.text("所选 Git 不支持隔离的全局、系统及运行时配置。请安装更新版本。"))
        }
    }

    /// Empty URL values must clear inherited lists, otherwise a selected destination
    /// can silently turn into a multi-remote push. This probe never opens a transport.
    static func verifyRemoteURLReset(executable: URL, runner: any ProcessRunning) async throws {
        let directory = try SnapshotDirectory()
        defer { withExtendedLifetime(directory) {} }
        let git = directory.url.appending(path: ".git")
        for name in ["objects", "refs"] {
            try FileManager.default.createDirectory(
                at: git.appending(path: name), withIntermediateDirectories: true)
        }
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appending(path: "HEAD"))
        let name = "wegit-probe-" + UUID().uuidString.lowercased()
        try Data("[remote \"\(name)\"]\nurl = original-fetch\npushurl = original-push\n".utf8)
            .write(to: git.appending(path: "config"))
        var environment = GitEngine(executable: executable).environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(executable: executable, runner: runner, environment: environment)
        let configuration: [(key: String, value: String)] = [
            ("remote.\(name).url", "discarded-fetch"), ("remote.\(name).url", ""),
            ("remote.\(name).url", "confirmed-fetch"),
            ("remote.\(name).pushurl", "discarded-push"), ("remote.\(name).pushurl", ""),
            ("remote.\(name).pushurl", "confirmed-push"),
        ]
        for (options, expected) in [([], "confirmed-fetch\n"), (["--push"], "confirmed-push\n")] {
            let result = try await engine.run(
                ["remote", "get-url", "--all"] + options + [name], in: directory.url,
                timeout: 5, outputLimit: 4096, configuration: configuration)
            guard result.text == expected else {
                throw ModelFailure.unsupported(
                    L10n.text("所选 Git 无法固定单个远端地址。请安装 Git \(minimumVersion) 或更新版本。"))
            }
        }
    }

    public static func detect(preferred: URL? = nil, runner: any ProcessRunning = ProcessRunner())
        async throws -> GitInstallation
    {
        var candidates = [URL(fileURLWithPath: "/usr/bin/git")]
        if let result = try? await runner.run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["--find", "git"], timeout: 5)),
            result.exitCode == 0
        {
            candidates.append(
                URL(fileURLWithPath: result.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git"].map { URL(fileURLWithPath: $0) }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appending(path: "git")
        }
        if let preferred { candidates = [preferred] }
        var preferredFailure: String?
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
                if preferred != nil { preferredFailure = L10n.text("所选文件不存在或没有执行权限。") }
                continue
            }
            do {
                let result = try await runner.run(
                    ProcessRequest(executable: candidate, arguments: ["--version"], timeout: 5))
                guard result.exitCode == 0 else {
                    throw ModelFailure.unsupported(L10n.text("Git 版本查询失败（退出码 \(result.exitCode)）。"))
                }
                let version = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let numbers = version.split { !$0.isNumber }.compactMap { Int($0) }
                guard numbers.count >= 2, numbers[0] > 2 || (numbers[0] == 2 && numbers[1] >= 46) else {
                    throw ModelFailure.unsupported(L10n.text("所选 Git 的版本低于 \(minimumVersion)，或版本信息无法识别。"))
                }
                try await verifyConfigurationIsolation(executable: candidate, runner: runner)
                try await verifyRemoteURLReset(executable: candidate, runner: runner)
                return GitInstallation(executable: candidate, version: version)
            } catch is CancellationError { throw CancellationError() } catch ProcessFailure.cancelled {
                throw ProcessFailure.cancelled
            } catch {
                if preferred != nil { preferredFailure = error.localizedDescription }
            }
        }
        throw ModelFailure.unsupported(
            L10n.text(
                "未找到支持安全配置和远端地址隔离的 Git \(minimumVersion) 或更新版本。请安装新版 Xcode Command Line Tools，或在设置中选择 Git。")
                + (preferredFailure.map { "\n" + $0 } ?? ""))
    }
}
