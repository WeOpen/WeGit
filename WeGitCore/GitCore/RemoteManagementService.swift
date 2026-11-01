import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func remoteManagement() async throws -> RemoteManagementSnapshot {
        try location.validateIdentity()
        let file = try await SnapshotIO.run { _ in
            try RemoteConfigFile.read(location.commonDirectory.appending(path: "config"))
        }
        let token = try await engine.run(
            ["config", "--includes", "--null", "--show-scope", "--show-origin", "--list"],
            in: location.root, outputLimit: 8 * 1024 * 1024
        ).stdout
        let fields = token.split(separator: 0, omittingEmptySubsequences: false)
        guard token.isEmpty || token.last == 0, (fields.count - 1).isMultiple(of: 3) else {
            throw ModelFailure.changed
        }
        var records: [RemoteConfigValue] = []
        for index in stride(from: 0, to: fields.count - 1, by: 3) {
            guard let scope = String(data: fields[index], encoding: .utf8),
                let origin = String(data: fields[index + 1], encoding: .utf8),
                let pair = String(data: fields[index + 2], encoding: .utf8)
            else { throw ModelFailure.changed }
            let parts = pair.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            records.append(
                RemoteConfigValue(
                    key: String(parts[0]), scope: scope, origin: origin,
                    value: parts.count == 2 ? String(parts[1]) : ""))
        }
        func owned(_ record: RemoteConfigValue) -> Bool {
            guard record.scope == "local", record.origin.hasPrefix("file:") else { return false }
            let path = String(record.origin.dropFirst(5))
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : location.root.appending(path: path)
            return url.standardizedFileURL == file.url.standardizedFileURL
        }
        func remoteName(_ key: String) -> String? {
            guard key.hasPrefix("remote.") else { return nil }
            let rest = key.dropFirst(7)
            guard let dot = rest.lastIndex(of: ".") else { return nil }
            return String(rest[..<dot])
        }
        var byRemote: [String: [RemoteConfigValue]] = [:]
        var byKey: [String: [RemoteConfigValue]] = [:]
        var associations: [String: [RemoteConfigValue]] = [:]
        for record in records {
            byKey[record.key, default: []].append(record)
            if let name = remoteName(record.key) { byRemote[name, default: []].append(record) }
            if (record.key.hasPrefix("branch.")
                && (record.key.hasSuffix(".remote") || record.key.hasSuffix(".pushremote")))
                || record.key == "remote.pushdefault"
            {
                associations[record.value, default: []].append(record)
            }
        }
        let entries = byRemote.keys.sorted().map { name in
            let prefix = "remote.\(name)."
            let values = byRemote[name] ?? []
            let urls = values.filter { $0.key == prefix + "url" }.map(\.value)
            let pushes = values.filter { $0.key == prefix + "pushurl" }.map(\.value)
            let links = associations[name] ?? []
            let branches = Set(
                links.compactMap { record -> String? in
                    guard record.key.hasPrefix("branch."), let dot = record.key.lastIndex(of: ".") else {
                        return nil
                    }
                    return String(record.key[record.key.index(record.key.startIndex, offsetBy: 7)..<dot])
                }
            ).sorted()
            let simple =
                values.allSatisfy(owned) && urls.count <= 1 && pushes.count <= 1
                && (urls + pushes).allSatisfy { Redaction.text($0) == $0 }
            let ownedAssociations = links.allSatisfy { link in
                var keys = [link.key]
                if link.key.hasPrefix("branch."), link.key.hasSuffix(".remote") {
                    keys.append(String(link.key.dropLast(6)) + "merge")
                }
                return keys.flatMap { byKey[$0] ?? [] }.allSatisfy(owned)
            }
            return ManagedRemote(
                name: name, values: values, fetchURLs: urls, pushURLs: pushes,
                upstreamBranches: branches, canEdit: simple, canDelete: simple && ownedAssociations)
        }
        let finalFile = try await SnapshotIO.run { _ in try RemoteConfigFile.read(file.url) }
        guard finalFile == file else { throw ModelFailure.changed }
        try location.validateIdentity()
        return RemoteManagementSnapshot(
            remotes: entries, records: records, token: token, file: file, location: location)
    }

    public func changeRemote(
        _ change: RemoteChange, in snapshot: RemoteManagementSnapshot, expectedHead: String?
    ) async throws {
        try await withSharedOperation {
            guard snapshot.location == location else { throw ModelFailure.changed }
            try await verifyHead(expectedHead)
            let name: String
            let urls: (String, String?)?
            let removing: Bool
            switch change {
            case .add(let value, let fetch, let push):
                name = value
                urls = (fetch, push)
                removing = false
                guard !snapshot.remotes.contains(where: { $0.name == name }) else {
                    throw ModelFailure.changed
                }
            case .update(let value, let fetch, let push):
                name = value
                urls = (fetch, push)
                removing = false
                guard snapshot.remotes.first(where: { $0.name == name })?.canEdit == true else {
                    throw ModelFailure.changed
                }
            case .remove(let value):
                name = value
                urls = nil
                removing = true
                guard snapshot.remotes.first(where: { $0.name == name })?.canDelete == true else {
                    throw ModelFailure.changed
                }
            }
            guard !name.isEmpty, name != ".", !name.hasPrefix("-"), name.utf8.count <= 1024 else {
                throw ModelFailure.invalidPath
            }
            _ = try await engine.run(
                ["check-ref-format", "refs/remotes/" + name + "/wegit-name-check"], in: location.root)
            if let urls {
                for value in [urls.0] + [urls.1].compactMap({ $0 }) {
                    guard !value.isEmpty, !value.hasPrefix("-"), value.utf8.count <= 4096,
                        !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
                    else { throw ModelFailure.invalidPath }
                }
            }
            let lease = try await SnapshotIO.run { _ in
                try RemoteConfigLease(file: snapshot.file, location: location)
            }
            defer { withExtendedLifetime(lease) {} }
            let fresh = try await remoteManagement()
            guard fresh.token == snapshot.token, fresh.file == snapshot.file else {
                throw ModelFailure.changed
            }
            let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
            defer { withExtendedLifetime(directory) {} }
            let candidate = directory.url.appending(path: "config")
            try await SnapshotIO.run { _ in try snapshot.file.bytes.write(to: candidate) }
            func config(_ args: [String], accepted: Set<Int32> = [0]) async throws {
                _ = try await engine.run(
                    ["config", "--file", candidate.path, "--no-includes"] + args,
                    in: location.root, accepted: accepted)
            }
            if removing {
                try await config(["--remove-section", "remote." + name])
                for record in snapshot.records where record.value == name {
                    if record.key.hasPrefix("branch.") && record.key.hasSuffix(".remote") {
                        let prefix = String(record.key.dropLast(6))
                        try await config(["--unset-all", "--", record.key], accepted: [0, 5])
                        try await config(["--unset-all", "--", prefix + "merge"], accepted: [0, 5])
                    } else if (record.key.hasPrefix("branch.") && record.key.hasSuffix(".pushremote"))
                        || record.key == "remote.pushdefault"
                    {
                        try await config(["--unset-all", "--", record.key], accepted: [0, 5])
                    }
                }
            } else if let urls {
                let prefix = "remote.\(name)."
                try await config(["--replace-all", "--", prefix + "url", urls.0])
                if let push = urls.1 {
                    try await config(["--replace-all", "--", prefix + "pushurl", push])
                } else {
                    try await config(["--unset-all", "--", prefix + "pushurl"], accepted: [0, 5])
                }
                if case .add = change {
                    try await config([
                        "--add", "--", prefix + "fetch", "+refs/heads/*:refs/remotes/\(name)/*",
                    ])
                }
            }
            let check = try await remoteManagement()
            guard check.token == snapshot.token, check.file == snapshot.file else {
                throw ModelFailure.changed
            }
            try await verifyHead(expectedHead)
            try await SnapshotIO.run { cancellation in
                try cancellation.check()
                try location.validateIdentity()
                let bytes = try Data(contentsOf: candidate)
                guard bytes.count <= 4 * 1024 * 1024 else { throw ModelFailure.invalidPath }
                try lease.commit(bytes)
            }
        }
    }
}

struct RemoteConfigFile: Equatable, Sendable {
    let url: URL
    let bytes: Data
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    static func read(_ url: URL, parent: Int32? = nil) throws -> Self {
        let fd =
            parent.map { openat($0, "config", O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            ?? Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 4 * 1024 * 1024
        else { throw ModelFailure.changed }
        let bytes = try handle.readToEnd() ?? Data()
        return Self(
            url: url, bytes: bytes, device: info.st_dev, inode: info.st_ino, mode: info.st_mode & 0o777)
    }
}

private final class RemoteConfigLease: @unchecked Sendable {
    let file: RemoteConfigFile
    let directory: Int32
    let descriptor: Int32
    init(file: RemoteConfigFile, location: RepositoryLocation) throws {
        self.file = file
        try location.validateIdentity()
        guard file.url == location.commonDirectory.appending(path: "config") else {
            throw ModelFailure.repositoryReplaced
        }
        let parent = Darwin.open(
            location.commonDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ModelFailure.repositoryReplaced }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_dev == location.commonIdentity.device,
            info.st_ino == location.commonIdentity.inode,
            info.st_birthtimespec.tv_sec == location.commonIdentity.bornSeconds,
            info.st_birthtimespec.tv_nsec == location.commonIdentity.bornNanoseconds
        else {
            Darwin.close(parent)
            throw ModelFailure.repositoryReplaced
        }
        let lock = openat(parent, "config.lock", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            Darwin.close(parent)
            throw ModelFailure.changed
        }
        directory = parent
        descriptor = lock
    }
    deinit {
        var actual = stat()
        var owned = stat()
        if fstat(descriptor, &owned) == 0,
            fstatat(directory, "config.lock", &actual, AT_SYMLINK_NOFOLLOW) == 0,
            owned.st_dev == actual.st_dev, owned.st_ino == actual.st_ino
        {
            unlinkat(directory, "config.lock", 0)
        }
        Darwin.close(descriptor)
        Darwin.close(directory)
    }
    func commit(_ bytes: Data) throws {
        guard try RemoteConfigFile.read(file.url, parent: directory) == file else {
            throw ModelFailure.changed
        }
        var actual = stat()
        var owned = stat()
        guard fstat(descriptor, &owned) == 0,
            fstatat(directory, "config.lock", &actual, AT_SYMLINK_NOFOLLOW) == 0,
            owned.st_dev == actual.st_dev, owned.st_ino == actual.st_ino
        else { throw ModelFailure.changed }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProcessFailure.outputWrite(errno) }
                offset += count
            }
        }
        guard fchmod(descriptor, file.mode) == 0, fsync(descriptor) == 0,
            renameat(directory, "config.lock", directory, "config") == 0
        else { throw ProcessFailure.outputWrite(errno) }
    }
}
