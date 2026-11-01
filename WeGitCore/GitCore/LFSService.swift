import CryptoKit
import Darwin
import Foundation

private struct LFSParsedPointer: Sendable {
    let oid: String
    let size: Int64
}

private enum LFSReadBudget {
    static let pointerBytes = 1023
    static let aggregateBytes = 16 * 1024 * 1024
    static let metadataBytes = 8 * 1024 * 1024
    static let entries = 100_000
    static let objects = 512
    static var exceeded: ModelFailure {
        .unsupported(L10n.text("LFS 状态读取超过上限，请在 Terminal 核对。"))
    }
}

private struct LFSIndexEntry: Sendable {
    let path: String
    let oid: String
}

extension RepositoryService {
    @concurrent public func lfsInstallation() async throws -> LFSInstallation {
        try location.validateIdentity()
        do {
            let result = try await engine.run(
                ["lfs", "version"], in: location.root, accepted: [0, 1], timeout: 5,
                outputLimit: 64 * 1024)
            guard result.exitCode == 0 else {
                return .init(
                    available: false, version: nil,
                    detail: String(decoding: result.stderr, as: UTF8.self).removingLastNewline)
            }
            return .init(available: true, version: result.text.removingLastNewline, detail: nil)
        } catch let failure as ProcessFailure {
            guard case .launch = failure else { throw failure }
            return .init(available: false, version: nil, detail: L10n.text("无法启动 Git LFS。"))
        }
    }

    /// Uses two batched object queries instead of starting Git for each tracked file.
    /// The LFS specification limits pointers to less than 1024 bytes; content and
    /// worktree reads also have aggregate budgets, independent of the file count.
    @concurrent public func lfsObjects(maxBytes: Int = 4 * 1024 * 1024) async throws -> [LFSObjectStatus] {
        try await queue.perform { try await self.readLFSObjects(maxBytes: maxBytes) }
    }

    private func lfsIndexEntries(_ data: Data) throws -> [LFSIndexEntry] {
        guard data.isEmpty || data.last == 0 else { throw ModelFailure.changed }
        var result: [LFSIndexEntry] = []
        for raw in data.split(separator: 0) {
            try Task.checkCancellation()
            guard let tab = raw.firstIndex(of: 9),
                let header = String(data: Data(raw[..<tab]), encoding: .utf8),
                let path = String(data: Data(raw[raw.index(after: tab)...]), encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[2] == "0", GitObjectID.valid(String(fields[1]))
            else { throw ModelFailure.changed }
            guard fields[0] != "160000", fields[0] != "120000" else { continue }
            try validate(path)
            result.append(LFSIndexEntry(path: path, oid: String(fields[1])))
            guard result.count <= LFSReadBudget.entries else { throw LFSReadBudget.exceeded }
        }
        return result
    }

    private func readLFSObjects(maxBytes: Int) async throws -> [LFSObjectStatus] {
        guard (1...16 * 1024 * 1024).contains(maxBytes) else { throw ModelFailure.invalidPath }
        try location.validateIdentity()
        let beforeIndex = try lfsIndexBytes()
        var reader = engine
        reader.environment["GIT_NO_LAZY_FETCH"] = "1"
        let files = try await reader.run(
            ["ls-files", "--stage", "-z"], in: location.root, outputLimit: maxBytes
        ).stdout
        let entries = try lfsIndexEntries(files)
        var seen: Set<String> = []
        let identifiers = entries.map(\.oid).filter { seen.insert($0).inserted }
        let blobs = try await lfsSmallBlobs(identifiers, reader: reader)
        var result: [LFSObjectStatus] = []
        var remainingWorkingBytes = LFSReadBudget.aggregateBytes
        for entry in entries {
            try Task.checkCancellation()
            guard let indexBytes = blobs[entry.oid],
                let indexText = String(data: indexBytes, encoding: .utf8),
                indexText.hasPrefix("version https://git-lfs.github.com/spec/v1\n")
            else { continue }
            guard result.count < LFSReadBudget.objects else { throw LFSReadBudget.exceeded }
            guard let pointer = parseLFSPointer(indexText) else {
                result.append(
                    .init(
                        path: entry.path, oid: nil, size: nil, isPointer: false, objectAvailable: false,
                        workingTreeHydrated: nil, detail: L10n.text("LFS 指针格式无效")))
                continue
            }

            let objectAvailable = lfsObjectExists(oid: pointer.oid, size: pointer.size)
            let working = try await readWorkingTreeLFS(
                path: entry.path, pointer: pointer, maxBytes: min(maxBytes, remainingWorkingBytes))
            remainingWorkingBytes -= working.bytesRead
            result.append(
                .init(
                    path: entry.path, oid: pointer.oid, size: pointer.size, isPointer: true,
                    objectAvailable: objectAvailable, workingTreeHydrated: working.hydrated,
                    detail: working.detail
                        ?? (objectAvailable ? nil : L10n.text("LFS 对象尚未下载"))))
        }
        try Task.checkCancellation()
        try location.validateIdentity()
        guard try lfsIndexBytes() == beforeIndex else { throw ModelFailure.changed }
        return result
    }

    private func lfsSmallBlobs(_ identifiers: [String], reader: GitEngine) async throws -> [String: Data] {
        guard !identifiers.isEmpty else { return [:] }
        let metadata = try await reader.run(
            ["cat-file", "--batch-check"], in: location.root,
            input: Data((identifiers.joined(separator: "\n") + "\n").utf8),
            outputLimit: LFSReadBudget.metadataBytes
        ).text.split(separator: "\n")
        guard metadata.count == identifiers.count else { throw ModelFailure.changed }
        var small: [(oid: String, size: Int)] = []
        var totalBytes = 0
        for (identifier, row) in zip(identifiers, metadata) {
            try Task.checkCancellation()
            let fields = row.split(separator: " ")
            guard fields.count == 3, fields[0] == identifier, fields[1] == "blob",
                let size = Int(fields[2]), size >= 0
            else { throw ModelFailure.changed }
            guard size <= LFSReadBudget.pointerBytes else { continue }
            totalBytes += size + identifier.utf8.count + 32
            guard totalBytes <= LFSReadBudget.aggregateBytes else { throw LFSReadBudget.exceeded }
            small.append((identifier, size))
        }
        guard !small.isEmpty else { return [:] }
        let contents = try await reader.run(
            ["cat-file", "--batch"], in: location.root,
            input: Data((small.map(\.oid).joined(separator: "\n") + "\n").utf8),
            outputLimit: LFSReadBudget.aggregateBytes
        ).stdout
        var cursor = contents.startIndex
        var result: [String: Data] = [:]
        for item in small {
            try Task.checkCancellation()
            guard cursor < contents.endIndex, let newline = contents[cursor...].firstIndex(of: 10),
                let header = String(data: contents[cursor..<newline], encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[0] == item.oid, fields[1] == "blob", Int(fields[2]) == item.size
            else { throw ModelFailure.changed }
            cursor = contents.index(after: newline)
            guard item.size < contents.endIndex - cursor else { throw ModelFailure.changed }
            let end = cursor + item.size
            guard contents[end] == 10 else { throw ModelFailure.changed }
            result[item.oid] = Data(contents[cursor..<end])
            cursor = end + 1
        }
        guard cursor == contents.endIndex else { throw ModelFailure.changed }
        return result
    }

    @concurrent public func fetchLFS(path: String, expectedOID: String? = nil, timeout: TimeInterval = 120)
        async throws
    {
        try validate(path)
        guard timeout.isFinite, timeout > 0, timeout <= 900 else { throw ModelFailure.invalidPath }
        try await withSharedOperation {
            let installation = try await lfsInstallation()
            guard installation.available else {
                throw ModelFailure.unsupported(L10n.text("当前 Git 未安装 Git LFS。"))
            }
            let originalHead = try await head()
            try await verifyHead(originalHead)
            let index = try lfsIndexBytes()
            let staged = try await engine.run(
                ["ls-files", "--stage", "-z", "--", path], in: location.root,
                outputLimit: 16 * 1024
            ).stdout
            let entries = try lfsIndexEntries(staged)
            guard entries.count == 1, let entry = entries.first, entry.path == path else {
                throw ModelFailure.changed
            }
            var source = engine
            source.environment["GIT_NO_LAZY_FETCH"] = "1"
            let pointerBytes = try await source.run(
                ["cat-file", "blob", entry.oid], in: location.root, outputLimit: LFSReadBudget.pointerBytes
            ).stdout
            guard let text = String(data: pointerBytes, encoding: .utf8), let pointer = parseLFSPointer(text),
                expectedOID == nil || expectedOID == pointer.oid
            else { throw ModelFailure.changed }
            let branch = try await engine.run(
                ["symbolic-ref", "--quiet", "--short", "HEAD"], in: location.root, accepted: [0, 1]
            ).text.removingLastNewline
            let configured =
                branch.isEmpty
                ? ""
                : try await engine.run(
                    ["config", "--get", "branch.\(branch).remote"], in: location.root, accepted: [0, 1]
                ).text.removingLastNewline
            let remote = try await remoteDetails(name: configured.isEmpty ? "origin" : configured)
            let environment = try await engine.run(
                ["lfs", "env"], in: location.root, timeout: 5, outputLimit: 64 * 1024
            ).text
            let endpointPrefix = "Endpoint (\(remote.name))="
            let endpointLine =
                environment.split(separator: "\n").first(where: { $0.hasPrefix(endpointPrefix) })
                ?? environment.split(separator: "\n").first(where: { $0.hasPrefix("Endpoint=") })
            guard let endpointLine, let equals = endpointLine.firstIndex(of: "=") else {
                throw ModelFailure.changed
            }
            let endpoint =
                String(endpointLine[endpointLine.index(after: equals)...]).components(separatedBy: " (auth=")
                .first ?? ""
            guard !endpoint.isEmpty, endpoint.utf8.count <= 16 * 1024, !endpoint.contains("\0") else {
                throw ModelFailure.changed
            }
            let directory = try SnapshotDirectory()
            defer { withExtendedLifetime(directory) {} }
            var scratch = source
            scratch.environment["GIT_OBJECT_DIRECTORY"] = directory.url.path
            scratch.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = singleCommitAlternatePath(
                location.commonDirectory.appending(path: "objects").path)
            for role in ["AUTHOR", "COMMITTER"] {
                scratch.environment["GIT_\(role)_NAME"] = "WeGit LFS Snapshot"
                scratch.environment["GIT_\(role)_EMAIL"] = "lfs-snapshot@example.invalid"
                scratch.environment["GIT_\(role)_DATE"] = "2000-01-01T00:00:00 +0000"
            }
            let blob = try await scratch.run(
                ["hash-object", "-w", "--stdin"], in: location.root, input: pointerBytes
            ).text.removingLastNewline
            guard blob == entry.oid else { throw ModelFailure.changed }
            let attributes = try await scratch.run(
                ["hash-object", "-w", "--stdin"], in: location.root,
                input: Data("object.lfs filter=lfs diff=lfs merge=lfs -text\n".utf8)
            ).text.removingLastNewline
            let tree = try await scratch.run(
                ["mktree", "-z"], in: location.root,
                input: Data("100644 blob \(attributes)\t.gitattributes\0".utf8)
                    + Data("100644 blob \(blob)\tobject.lfs\0".utf8)
            ).text.removingLastNewline
            let revision = try await scratch.run(
                ["commit-tree", tree], in: location.root,
                input: Data("Pinned LFS object\n".utf8), configuration: [("commit.gpgsign", "false")]
            ).text.removingLastNewline
            guard GitObjectID.valid(revision) else { throw ModelFailure.changed }
            scratch.environment["GIT_ATTR_SOURCE"] = revision
            try await verifyHead(originalHead)
            try await verifyRemote(remote)
            guard try lfsIndexBytes() == index else { throw ModelFailure.changed }
            var configuration = try pinnedRemote(remote)
            configuration += [
                ("lfs.url", endpoint), ("lfs.fetchinclude", ""), ("lfs.fetchexclude", ""),
                ("lfs.fetchrecentalways", "false"), ("lfs.fetchprune", "false"),
                ("lfs.fetchrecentrefsdays", "0"),
                ("lfs.fetchrecentcommitsdays", "0"),
            ]
            _ = try await scratch.run(
                ["lfs", "fetch", "--", remote.name, revision], in: location.root,
                timeout: timeout, configuration: configuration)
            try await verifyHead(originalHead)
            try location.validateIdentity()
            guard try lfsIndexBytes() == index else { throw ModelFailure.changed }
            guard lfsObjectExists(oid: pointer.oid, size: pointer.size) else {
                throw ModelFailure.unsupported(L10n.text("无法确认 LFS 对象已进入缓存，请刷新后核对。"))
            }
        }
    }

    private func lfsIndexBytes() throws -> Data {
        try location.validateIdentity()
        let url = location.gitDirectory.appending(path: "index")
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return Data()
        }
        guard info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), info.st_size >= 0,
            info.st_size <= LFSReadBudget.aggregateBytes
        else { throw LFSReadBudget.exceeded }
        let identity = try RepositoryNodeIdentity.read(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
            opened.st_size == info.st_size, opened.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG)
        else { throw ModelFailure.changed }
        let data = try handle.read(upToCount: LFSReadBudget.aggregateBytes + 1) ?? Data()
        guard data.count == info.st_size, try RepositoryNodeIdentity.read(url) == identity else {
            throw ModelFailure.changed
        }
        return data
    }

    private func parseLFSPointer(_ text: String) -> LFSParsedPointer? {
        guard text.hasPrefix("version https://git-lfs.github.com/spec/v1\n") else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard let oidLine = lines.first(where: { $0.hasPrefix("oid sha256:") }),
            let sizeLine = lines.first(where: { $0.hasPrefix("size ") }),
            let rawOID = oidLine.split(separator: ":", maxSplits: 1).last,
            text.utf8.count <= LFSReadBudget.pointerBytes,
            text.utf8.allSatisfy({ $0 < 128 }), rawOID.count == 64,
            rawOID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            let size = Int64(sizeLine.dropFirst(5)), size >= 0
        else { return nil }
        return LFSParsedPointer(oid: String(rawOID), size: size)
    }

    private func lfsObjectExists(oid: String, size: Int64) -> Bool {
        let prefix = String(oid.prefix(2))
        let middle = String(oid.dropFirst(2).prefix(2))
        let object = location.commonDirectory.appending(path: "lfs/objects/\(prefix)/\(middle)/\(oid)")
        var info = stat()
        return lstat(object.path, &info) == 0
            && (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG) && info.st_size == size
    }

    private func readWorkingTreeLFS(
        path: String, pointer: LFSParsedPointer, maxBytes: Int
    ) async throws -> (hydrated: Bool?, detail: String?, bytesRead: Int) {
        do {
            return try await SnapshotIO.run { cancellation in
                let reader = try RepositoryFileReader(
                    location: self.location, path: path, cancellation: cancellation)
                guard !reader.symbolicLink else {
                    return (nil, L10n.text("工作树路径是符号链接，未读取内容"), 0)
                }
                guard reader.size <= Int64(maxBytes) else {
                    return (nil, L10n.text("工作树文件超过读取上限"), 0)
                }
                var data = Data()
                try reader.read(limit: maxBytes) { data.append($0) }
                if let text = String(data: data, encoding: .utf8),
                    text.hasPrefix("version https://git-lfs.github.com/spec/v1\n")
                {
                    guard let workingPointer = self.parseLFSPointer(text) else {
                        return (false, L10n.text("工作树中的 LFS 指针格式无效"), data.count)
                    }
                    guard workingPointer.oid == pointer.oid, workingPointer.size == pointer.size else {
                        return (false, L10n.text("工作树中的 LFS 指针与索引不一致"), data.count)
                    }
                    return (false, nil, data.count)
                }
                guard reader.size == pointer.size else {
                    return (false, L10n.text("工作树文件大小与 LFS 指针不一致"), data.count)
                }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == pointer.oid else {
                    return (false, L10n.text("工作树文件与 LFS 对象不一致"), data.count)
                }
                return (true, nil, data.count)
            }
        } catch ModelFailure.changed {
            return (nil, L10n.text("工作树文件不存在或已变化"), maxBytes)
        } catch CocoaError.fileNoSuchFile {
            return (nil, L10n.text("工作树文件不存在或已变化"), 0)
        }
    }
}
