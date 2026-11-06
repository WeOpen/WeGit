import Darwin
import Foundation

extension GitConfigurationService {
    @concurrent public func readCommitMessageTemplate() async throws -> CommitMessageTemplate? {
        let snapshot = try await read(.commitTemplate)
        guard let source = snapshot.effective else { return nil }
        let directory = location?.root ?? URL(fileURLWithPath: "/")
        let file = try GitProgramPath.readableFile(source.value, directory: directory)
        return try await SnapshotIO.run { cancellation in
            try cancellation.check()
            let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0,
                before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                before.st_size >= 0, before.st_size <= 64 * 1024
            else { throw ModelFailure.unsupported(L10n.text("提交消息模板需要是 64 KiB 以内的普通文件。")) }
            let bytes =
                try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                .read(upToCount: 64 * 1024 + 1) ?? Data()
            try cancellation.check()
            var after = stat()
            var named = stat()
            guard fstat(descriptor, &after) == 0, lstat(file.path, &named) == 0,
                SnapshotFileStamp(before) == SnapshotFileStamp(after),
                SnapshotFileStamp(after) == SnapshotFileStamp(named), bytes.count == before.st_size
            else { throw ModelFailure.changed }
            return CommitMessageTemplate(
                source: source, url: file, bytes: bytes, sha256: RecoveryFileIO.hash(bytes),
                text: bytes.contains(0) ? nil : String(data: bytes, encoding: .utf8))
        }
    }
}
