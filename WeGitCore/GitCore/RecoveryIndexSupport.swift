import Darwin
import Foundation

extension RepositoryService {
    @concurrent func captureRecoverySharedIndex(_ expected: SelectedIndexSnapshot) async throws
        -> RecoverySharedIndexSnapshot?
    {
        guard expected.bytes != nil else { return nil }
        guard try SelectedIndexSnapshot.read(location: location) == expected else {
            throw ModelFailure.changed
        }
        let value = try await recoveryEngine.run(["rev-parse", "--shared-index-path"], in: location.root).text
            .removingLastNewline
        if value.isEmpty { return nil }
        let path = URL(fileURLWithPath: value, relativeTo: location.root).standardizedFileURL
        let name = path.lastPathComponent
        guard path.deletingLastPathComponent().path == location.gitDirectory.path,
            name.hasPrefix("sharedindex."), GitObjectID.valid(String(name.dropFirst("sharedindex.".count)))
        else { throw ModelFailure.changed }
        let result = try await SnapshotIO.run { cancellation in
            try cancellation.check()
            let parent = try SelectedIndexSnapshot.openDirectory(location)
            defer { Darwin.close(parent) }
            let captured = try SelectedIndexSnapshot.read(parent: parent, name: name)
            guard let bytes = captured.bytes else { throw ModelFailure.changed }
            return RecoverySharedIndexSnapshot(
                file: RecoverySharedIndex(
                    name: name, mode: UInt16(captured.mode),
                    bytes: bytes.count, sha256: RecoveryFileIO.hash(bytes)), data: bytes)
        }
        guard try SelectedIndexSnapshot.read(location: location) == expected else {
            throw ModelFailure.changed
        }
        return result
    }

    @concurrent func verifyRecoverySharedIndex(_ expected: RecoverySharedIndexSnapshot?) async throws {
        guard let expected else { return }
        try await SnapshotIO.run { cancellation in
            try cancellation.check()
            let parent = try SelectedIndexSnapshot.openDirectory(location)
            defer { Darwin.close(parent) }
            let current = try SelectedIndexSnapshot.read(parent: parent, name: expected.file.name)
            guard current.bytes == expected.data, current.mode == mode_t(expected.file.mode) else {
                throw ModelFailure.changed
            }
            try location.validateIdentity()
        }
    }

    /// A disposable Git directory reads the exact saved index, including its
    /// split-index companion. Preview trees stay private; protected backup trees
    /// are written into this repository's object store without refreshing its index.
    @concurrent func recoveryIndexTree(_ bytes: Data?, shared: RecoverySharedIndexSnapshot?, persist: Bool)
        async throws -> String?
    {
        guard let bytes else { return nil }
        guard bytes.count <= 32 * 1024 * 1024 else { throw RecoveryBudget.exceeded }
        let format = try await recoveryEngine.run(["rev-parse", "--show-object-format"], in: location.root)
            .text.removingLastNewline
        guard ["sha1", "sha256"].contains(format) else { throw ModelFailure.changed }
        let storage = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        let gitDirectory = storage.url.appending(path: "git", directoryHint: .isDirectory)
        let index = storage.url.appending(path: "index")
        var isolated = recoveryEngine
        isolated.environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        isolated.environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        isolated.environment["GIT_OPTIONAL_LOCKS"] = "0"
        _ = try await isolated.run(
            ["init", "--bare", "--template=", "--object-format=" + format, gitDirectory.path], in: storage.url
        )
        let objects = location.commonDirectory.appending(path: "objects", directoryHint: .isDirectory)
        try await SnapshotIO.run { cancellation in
            func write(_ data: Data, to file: URL) throws {
                let descriptor = Darwin.open(
                    file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw ProcessFailure.outputWrite(errno) }
                defer { Darwin.close(descriptor) }
                try RecoveryFileIO.write(data, descriptor: descriptor, cancellation: cancellation)
            }
            try write(bytes, to: index)
            if let shared {
                guard RecoveryStore.validSharedIndex(shared.file), shared.data.count == shared.file.bytes,
                    RecoveryFileIO.hash(shared.data) == shared.file.sha256
                else { throw ModelFailure.changed }
                try write(shared.data, to: gitDirectory.appending(path: shared.file.name))
            }
            if !persist {
                let alphabet = objects.path.utf8.map { byte -> String in
                    if byte >= 32 && byte < 127 && byte != 34 && byte != 92 {
                        return String(UnicodeScalar(byte))
                    }
                    return String(format: "\\%03o", byte)
                }.joined()
                try write(
                    Data(("\"" + alphabet + "\"\n").utf8),
                    to: gitDirectory.appending(path: "objects/info/alternates"))
            }
            try storage.validate()
            try location.validateIdentity()
        }
        isolated.environment["GIT_DIR"] = gitDirectory.path
        isolated.environment["GIT_INDEX_FILE"] = index.path
        isolated.environment["GIT_WORK_TREE"] = location.root.path
        if persist { isolated.environment["GIT_OBJECT_DIRECTORY"] = objects.path }
        let tree = try await isolated.run(
            ["write-tree"], in: location.root,
            configuration: [(key: "core.fsync", value: "loose-object")]
        ).text.removingLastNewline
        guard GitObjectID.valid(tree) else { throw ModelFailure.changed }
        if persist { try await syncRecoveryIndexObjects(tree, objects: objects) }
        return tree
    }

    private func syncRecoveryIndexObjects(_ tree: String, objects: URL) async throws {
        let rows = try await recoveryEngine.run(
            ["ls-tree", "-r", "-t", "-z", "--format=%(objecttype)%x00%(objectname)", tree],
            in: location.root, outputLimit: 32 * 1024 * 1024
        ).stdout.split(separator: 0)
        guard rows.count % 2 == 0, rows.count <= 2 * RecoveryBudget.metadataFiles else {
            throw ModelFailure.changed
        }
        var identifiers: Set<String> = [tree]
        for offset in stride(from: 0, to: rows.count, by: 2) {
            let kind = String(decoding: rows[offset], as: UTF8.self)
            let object = String(decoding: rows[offset + 1], as: UTF8.self)
            guard GitObjectID.valid(object) else { throw ModelFailure.changed }
            if kind == "tree" || kind == "blob" { identifiers.insert(object) }
        }
        let objectsToSync = identifiers
        try await SnapshotIO.run { cancellation in
            // Existing packed objects were synced by Git's pack writer. New
            // staged loose objects must be durable before their index is replaced.
            let root = Darwin.open(objects.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(root) }
            for identifier in objectsToSync {
                try cancellation.check()
                let folder = openat(
                    root, String(identifier.prefix(2)), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if folder < 0 {
                    if errno == ENOENT { continue }
                    throw ModelFailure.changed
                }
                defer { Darwin.close(folder) }
                let file = openat(folder, String(identifier.dropFirst(2)), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if file < 0 {
                    if errno == ENOENT { continue }
                    throw ModelFailure.changed
                }
                defer { Darwin.close(file) }
                var info = stat()
                guard fstat(file, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                    fsync(file) == 0, fsync(folder) == 0
                else { throw ModelFailure.changed }
            }
            guard fsync(root) == 0 else { throw ModelFailure.changed }
            try location.validateIdentity()
        }
    }
}
