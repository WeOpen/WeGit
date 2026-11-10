import AppKit
import Darwin
import UniformTypeIdentifiers
import WeGitCore

extension AppState {
    func exportCommitMailPatches(_ commits: [GitCommit], session: RepositorySession) {
        guard let first = commits.first else { return }
        let targets = commits.map(\.id)
        exportPatchFile(
            name: "commits-" + first.id.prefix(12) + ".mbox", session: session, fileExtension: "mbox"
        ) {
            try await $0.exportMailPatches(targets)
        }
    }

    func openMailPatchImport() {
        guard let session, session.canWrite, !session.isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task {
            do {
                let sources = try await Task.detached { () -> [MailPatchSource] in
                    guard urls.count <= 100 else { throw ModelFailure.invalidPath }
                    var total = 0
                    var result: [MailPatchSource] = []
                    for url in urls {
                        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else { throw ModelFailure.invalidPath }
                        defer { Darwin.close(fd) }
                        var before = stat()
                        guard fstat(fd, &before) == 0, before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                            before.st_size > 0, before.st_size <= 32 * 1024 * 1024 - total
                        else {
                            throw ModelFailure.unsupported(L10n.text("提交补丁总量不能超过 32 MiB。"))
                        }
                        let bytes =
                            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(
                                upToCount: 32 * 1024 * 1024 - total + 1) ?? Data()
                        var after = stat()
                        var named = stat()
                        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
                            before.st_dev == named.st_dev, before.st_ino == named.st_ino,
                            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                            bytes.count == before.st_size
                        else { throw ModelFailure.changed }
                        total += bytes.count
                        result.append(MailPatchSource(name: url.lastPathComponent, bytes: bytes))
                    }
                    return result
                }.value
                guard self.session === session else { return }
                mailPatchRequest = MailPatchRequest(session: session, sources: sources)
            } catch { self.error = error.localizedDescription }
        }
    }

    func openPatchImport() {
        guard let session, session.canWrite, !session.isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw ModelFailure.invalidPath }
                    defer { Darwin.close(fd) }
                    var before = stat()
                    guard fstat(fd, &before) == 0, before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                        before.st_size > 0, before.st_size <= 32 * 1024 * 1024
                    else { throw ModelFailure.unsupported(L10n.text("补丁必须是非空普通文件，且不超过 32 MiB。")) }
                    let data =
                        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(
                            upToCount: 32 * 1024 * 1024 + 1) ?? Data()
                    var after = stat()
                    var named = stat()
                    guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
                        before.st_dev == named.st_dev, before.st_ino == named.st_ino,
                        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                        data.count == before.st_size
                    else { throw ModelFailure.changed }
                    return data
                }.value
                guard self.session === session, !Task.isCancelled else { return }
                patchImportRequest = PatchImportRequest(
                    session: session, sourceName: url.lastPathComponent, patch: data)
            } catch { if self.session === session { self.error = error.localizedDescription } }
        }
    }

    func exportWorkspacePatch(layer: DiffLayer, paths: [String]? = nil) {
        guard let session else { return }
        exportPatchFile(name: layer.rawValue + ".patch", session: session) {
            try await $0.exportPatch(layer: layer, paths: paths)
        }
    }

    func exportComparisonPatch(
        _ comparison: CommitComparison, paths: [String]? = nil, session: RepositorySession
    ) {
        exportPatchFile(name: "changes-" + comparison.commit.id.prefix(12) + ".patch", session: session) {
            try await $0.exportPatch(comparison: comparison, paths: paths)
        }
    }

    private func exportPatchFile(
        name: String, session: RepositorySession, fileExtension: String = "patch",
        read: @escaping @Sendable (RepositoryService) async throws -> Data
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await read(session.service)
                guard self.session === session, !Task.isCancelled else { return }
                try data.write(to: url, options: .atomic)
            } catch { if self.session === session { self.error = error.localizedDescription } }
        }
    }
}
