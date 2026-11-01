import Darwin
import Foundation

extension RepositoryService {
    public func submodules() async throws -> [SubmoduleStatus] {
        try await queue.perform { try await self.readSubmodulesDirect() }
    }

    private func readSubmodulesDirect() async throws -> [SubmoduleStatus] {
        let config = try await self.engine.run(
            [
                "config", "--file", ".gitmodules", "--null", "--get-regexp",
                "^submodule\\..*\\.(path|url)$",
            ],
            in: self.location.root, accepted: [0, 1], outputLimit: 4 * 1024 * 1024)
        var configured: [String: (path: String?, url: String?)] = [:]
        for record in config.stdout.split(separator: 0) {
            guard let text = String(data: Data(record), encoding: .utf8),
                let separator = text.firstIndex(of: "\n")
            else { continue }
            let key = String(text[..<separator])
            let value = String(text[text.index(after: separator)...])
            let keyParts = key.split(separator: ".")
            guard keyParts.count >= 3, let property = keyParts.last else { continue }
            let name = keyParts.dropFirst().dropLast().joined(separator: ".")
            var item = configured[name] ?? (nil, nil)
            if property == "path" { item.path = value }
            if property == "url" { item.url = value }
            configured[name] = item
        }

        let head = try await self.head()
        var headLinks: [String: String] = [:]
        if let head {
            let tree = try await self.engine.run(
                ["ls-tree", "-r", "-z", "--full-tree", head], in: self.location.root,
                outputLimit: 8 * 1024 * 1024
            ).stdout
            for row in tree.split(separator: 0) {
                guard let tab = row.firstIndex(of: 9),
                    let header = String(data: Data(row[..<tab]), encoding: .utf8),
                    let path = String(data: Data(row[row.index(after: tab)...]), encoding: .utf8)
                else { throw ModelFailure.changed }
                let fields = header.split(separator: " ")
                guard fields.count == 3, fields[0] == "160000", fields[1] == "commit",
                    GitObjectID.valid(String(fields[2]))
                else { continue }
                try self.validate(path)
                headLinks[path] = String(fields[2])
            }
        }

        let indexData = try await self.engine.run(
            ["ls-files", "--stage", "-z"], in: self.location.root, outputLimit: 8 * 1024 * 1024
        ).stdout
        var indexLinks: [String: String] = [:]
        for row in indexData.split(separator: 0) {
            guard let tab = row.firstIndex(of: 9),
                let header = String(data: Data(row[..<tab]), encoding: .utf8),
                let path = String(data: Data(row[row.index(after: tab)...]), encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[0] == "160000", GitObjectID.valid(String(fields[1])),
                fields[2] == "0"
            else { continue }
            try self.validate(path)
            indexLinks[path] = String(fields[1])
        }

        let paths = Set(headLinks.keys).union(indexLinks.keys).sorted()
        guard paths.count <= 512 else { throw RebaseBudget.exceeded }
        var result: [SubmoduleStatus] = []
        for path in paths {
            let child = self.location.root.appending(path: path)
            let directoryExists = try self.submoduleDirectoryExists(path: path)
            let marker = child.appending(path: ".git")
            var markerInfo = stat()
            let markerExists = directoryExists && lstat(marker.path, &markerInfo) == 0
            if markerExists && (markerInfo.st_mode & S_IFMT) == S_IFLNK {
                result.append(
                    .init(
                        path: path, url: configured.values.first(where: { $0.path == path })?.url,
                        recordedOID: headLinks[path], indexOID: indexLinks[path], actualOID: nil,
                        initialized: false, dirty: false, state: .invalid))
                continue
            }
            var actual: String?
            var dirty = false
            if markerExists {
                do {
                    let nestedLocation = try await Self.discover(child, engine: self.engine)
                    let nestedEngine = GitEngine(
                        executable: self.engine.executable, runner: self.engine.runner,
                        activity: self.engine.activity, authentication: self.engine.authentication,
                        environment: self.engine.environment)
                    let status = try await nestedEngine.run(
                        [
                            "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all",
                            "--ignored=matching",
                        ],
                        in: nestedLocation.root, outputLimit: 2 * 1024 * 1024)
                    dirty = status.stdout.split(separator: 0).contains {
                        !$0.starts(with: Data("#".utf8))
                    }
                    actual = try await nestedEngine.run(["rev-parse", "HEAD"], in: nestedLocation.root)
                        .text.removingLastNewline
                } catch is CancellationError {
                    throw CancellationError()
                } catch ProcessFailure.cancelled {
                    throw ProcessFailure.cancelled
                } catch {
                    // A malformed child .git marker or an unavailable child repository is an
                    // invalid module, not a reason to hide the other configured modules.
                    actual = nil
                    dirty = false
                }
            }
            let recorded = headLinks[path]
            let indexed = indexLinks[path]
            let state: SubmoduleState
            if recorded != indexed {
                state = .stagedChange
            } else if !markerExists {
                state = .uninitialized
            } else if dirty {
                state = .dirty
            } else if actual == nil {
                state = .invalid
            } else if actual != recorded {
                state = .childChanged
            } else {
                state = .clean
            }
            result.append(
                .init(
                    path: path, url: configured.values.first(where: { $0.path == path })?.url,
                    recordedOID: recorded, indexOID: indexed, actualOID: actual,
                    initialized: markerExists, dirty: dirty, state: state))
        }
        return result
    }

    public func initializeOrUpdateSubmodule(path: String, expectedOID: String) async throws {
        try await withSharedOperation {
            try self.validate(path)
            guard GitObjectID.valid(expectedOID), let beforeHead = try await self.head() else {
                throw ModelFailure.invalidPath
            }
            let beforeIndex = try await self.engine.run(
                ["ls-files", "--stage", "-z"], in: self.location.root, outputLimit: 8 * 1024 * 1024
            ).stdout
            guard let module = try await self.readSubmodulesDirect().first(where: { $0.path == path }),
                module.recordedOID == expectedOID, module.indexOID == expectedOID,
                module.state != .stagedChange, module.state != .invalid
            else { throw ModelFailure.changed }
            guard !module.dirty else {
                throw ModelFailure.unsupported(L10n.text("子模块有未提交或忽略的内容，请先处理后再更新。"))
            }
            if module.state == .clean { return }

            var parentFD = Darwin.open(
                self.location.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { throw ModelFailure.repositoryReplaced }
            defer { Darwin.close(parentFD) }
            for part in path.split(separator: "/").dropLast() {
                let next = openat(parentFD, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ModelFailure.invalidPath }
                Darwin.close(parentFD)
                parentFD = next
            }
            let leaf = String(path.split(separator: "/").last ?? "")
            let childFD = openat(parentFD, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if childFD >= 0 {
                if !module.initialized {
                    let duplicate = dup(childFD)
                    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
                        Darwin.close(childFD)
                        throw ModelFailure.changed
                    }
                    var isEmpty = true
                    while let entry = readdir(directory) {
                        let name = withUnsafePointer(to: &entry.pointee.d_name) {
                            $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) {
                                String(cString: $0)
                            }
                        }
                        if name != "." && name != ".." {
                            isEmpty = false
                            break
                        }
                    }
                    closedir(directory)
                    if !isEmpty {
                        Darwin.close(childFD)
                        throw ModelFailure.unsupported(L10n.text("子模块路径包含未登记内容，拒绝覆盖。"))
                    }
                }
                Darwin.close(childFD)
            } else if errno == ENOENT {
                // Git may create an absent module directory during initialization.
            } else {
                throw ModelFailure.invalidPath
            }

            let config = try await self.engine.run(
                ["config", "--file", ".gitmodules", "--null", "--get-regexp", "^submodule\\..*\\.path$"],
                in: self.location.root, accepted: [0, 1], outputLimit: 2 * 1024 * 1024
            ).stdout
            let name = config.split(separator: 0).compactMap { record -> String? in
                guard let line = String(data: Data(record), encoding: .utf8),
                    let separator = line.firstIndex(of: "\n"),
                    String(line[line.index(after: separator)...]) == path
                else { return nil }
                let key = String(line[..<separator]).split(separator: ".")
                guard key.count >= 3 else { return nil }
                return key.dropFirst().dropLast().joined(separator: ".")
            }.first
            guard let name else { throw ModelFailure.unsupported(L10n.text("父仓库的 .gitmodules 未配置此路径。")) }

            _ = try await self.engine.run(
                ["submodule", "update", "--init", "--checkout", "--", path], in: self.location.root,
                timeout: 120,
                configuration: [("submodule.recurse", "false"), ("submodule.\(name).update", "checkout")])
            guard try await self.head() == beforeHead,
                try await self.engine.run(
                    ["ls-files", "--stage", "-z"], in: self.location.root,
                    outputLimit: 8 * 1024 * 1024
                ).stdout == beforeIndex
            else {
                throw ModelFailure.changed
            }
            let final = try await self.readSubmodulesDirect().first(where: { $0.path == path })
            guard final?.recordedOID == expectedOID, final?.indexOID == expectedOID,
                final?.actualOID == expectedOID, final?.state == .clean
            else { throw ModelFailure.changed }
        }
    }

    private func submoduleDirectoryExists(path: String) throws -> Bool {
        var current = Darwin.open(location.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw ModelFailure.repositoryReplaced }
        defer { Darwin.close(current) }
        for part in path.split(separator: "/") {
            let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ENOENT { return false }
                throw ModelFailure.invalidPath
            }
            Darwin.close(current)
            current = next
        }
        return true
    }
}
