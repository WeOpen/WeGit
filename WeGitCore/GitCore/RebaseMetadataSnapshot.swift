import Darwin
import Foundation

struct RebaseMetadataSnapshot: Equatable, Sendable {
    let backend: RebaseBackend
    let identity: RepositoryNodeIdentity
    let files: [String: RebaseStateFile]
    let markers: [String: RebaseStateFile]
}

extension RepositoryService {
    @concurrent
    func rebaseMetadataSnapshot() async throws -> RebaseMetadataSnapshot {
        try await SnapshotIO.run { cancellation in
            try location.validateIdentity()
            var selected: (RebaseBackend, URL, RepositoryNodeIdentity)?
            for backend in [RebaseBackend.merge, .apply] {
                let url = location.gitDirectory.appending(path: backend.rawValue)
                if let identity = try RepositoryNodeIdentity.readIfPresent(url) {
                    guard selected == nil, identity.kind == UInt16(S_IFDIR) else {
                        throw ModelFailure.changed
                    }
                    selected = (backend, url, identity)
                }
            }
            guard let (backend, directory, identity) = selected else { throw ModelFailure.changed }
            func openDirectory(_ url: URL, expected: RepositoryNodeIdentity) throws -> Int32 {
                let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ModelFailure.changed }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_dev == expected.device, info.st_ino == expected.inode,
                    info.st_birthtimespec.tv_sec == expected.bornSeconds,
                    info.st_birthtimespec.tv_nsec == expected.bornNanoseconds
                else {
                    Darwin.close(fd)
                    throw ModelFailure.changed
                }
                return fd
            }
            let descriptor = try openDirectory(directory, expected: identity)
            defer { Darwin.close(descriptor) }
            let git = try openDirectory(location.gitDirectory, expected: location.gitIdentity)
            defer { Darwin.close(git) }
            var total = 0
            func read(_ name: String, in parent: URL, descriptor: Int32) throws -> RebaseStateFile? {
                try cancellation.check()
                let url = parent.appending(path: name)
                guard let before = try RepositoryNodeIdentity.readIfPresent(url) else { return nil }
                guard before.kind == UInt16(S_IFREG), let size = before.markerSize,
                    size >= 0, size <= RebaseBudget.stateFileBytes,
                    size <= RebaseBudget.stateBytes - total
                else { throw RebaseBudget.exceeded }
                let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ModelFailure.changed }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_dev == before.device, info.st_ino == before.inode,
                    info.st_size == size, info.st_nlink == 1
                else { throw ModelFailure.changed }
                let bytes = try handle.read(upToCount: Int(size) + 1) ?? Data()
                try handle.close()
                guard bytes.count == size, try RepositoryNodeIdentity.read(url) == before else {
                    throw ModelFailure.changed
                }
                total += bytes.count
                return RebaseStateFile(identity: before, bytes: bytes)
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            guard names.count <= RebaseBudget.stateFiles else { throw RebaseBudget.exceeded }
            var files: [String: RebaseStateFile] = [:]
            for name in names {
                guard !name.contains("/"), name != ".", name != "..",
                    let file = try read(name, in: directory, descriptor: descriptor)
                else { throw ModelFailure.changed }
                files[name] = file
            }
            var markers: [String: RebaseStateFile] = [:]
            for name in [
                "HEAD", "ORIG_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "MERGE_HEAD", "MERGE_MSG",
                "MERGE_MODE", "AUTO_MERGE",
            ] {
                markers[name] = try read(name, in: location.gitDirectory, descriptor: git)
            }
            guard names == (try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()),
                try RepositoryNodeIdentity.read(directory, directory: true) == identity,
                files["applying"] == nil
            else { throw ModelFailure.changed }
            for (name, file) in files {
                guard try RepositoryNodeIdentity.read(directory.appending(path: name)) == file.identity else {
                    throw ModelFailure.changed
                }
            }
            try cancellation.check()
            try location.validateIdentity()
            return RebaseMetadataSnapshot(
                backend: backend, identity: identity, files: files, markers: markers)
        }
    }

    func rebaseRewrittenLabels() async throws -> [String: String] {
        let bytes = try await singleCommitEngine.run(
            [
                "for-each-ref", "--count=\(RebaseBudget.commits + 1)", "--format=%(refname)%00%(objectname)",
                "refs/rewritten/",
            ],
            in: location.root, outputLimit: RebaseBudget.metadataBytes
        ).stdout
        guard bytes.isEmpty || bytes.last == 10 else { throw ModelFailure.changed }
        var result: [String: String] = [:]
        for row in bytes.split(separator: 10) {
            let fields = row.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 2,
                let ref = String(data: fields[0], encoding: .utf8), ref.hasPrefix("refs/rewritten/"),
                let object = String(data: fields[1], encoding: .utf8), GitObjectID.valid(object)
            else { throw ModelFailure.changed }
            let label = String(ref.dropFirst("refs/rewritten/".count))
            guard Self.rebaseLabelValid(label), result[label] == nil else { throw ModelFailure.changed }
            result[label] = object
        }
        guard result.count <= RebaseBudget.commits else { throw RebaseBudget.exceeded }
        return result
    }

    static func rebaseLabelValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 1024 && !name.hasPrefix("/") && !name.hasSuffix("/")
            && !name.hasSuffix(".") && !name.contains("..") && !name.contains("@{")
            && !name.contains("//")
            && !name.split(separator: "/").contains(where: {
                $0.hasPrefix(".") || $0.hasSuffix(".lock")
            })
            && !name.unicodeScalars.contains(where: {
                $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0)
            })
    }
}
