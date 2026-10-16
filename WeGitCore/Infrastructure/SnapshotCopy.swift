import Darwin
import Foundation

extension SnapshotFile {
    static func captureWorktree(location: RepositoryLocation, path: String, directory: SnapshotDirectory)
        async throws -> SnapshotFile
    {
        try await SnapshotIO.run { cancellation in
            let reader = try RepositoryFileReader(location: location, path: path, cancellation: cancellation)
            guard reader.size <= DiskDiffBudget.bytes else {
                throw DiffContentLimit.bytes(DiskDiffBudget.bytes)
            }
            let destination = directory.url.appending(path: "content")
            let output = try create(destination)
            defer { Darwin.close(output) }
            try reader.read(limit: DiskDiffBudget.bytes) { try write($0, to: output) }
            return try SnapshotFile(directory: directory, url: destination)
        }
    }

    func copy(ranges: [Range<Int>], to destination: URL) async throws {
        try await SnapshotIO.run { cancellation in
            try cancellation.check()
            let input = try open()
            defer { Darwin.close(input) }
            let output = try Self.create(destination)
            var succeeded = false
            defer {
                var owned = stat()
                let hasIdentity = fstat(output, &owned) == 0
                Darwin.close(output)
                if !succeeded && hasIdentity {
                    var named = stat()
                    if lstat(destination.path, &named) == 0, named.st_dev == owned.st_dev,
                        named.st_ino == owned.st_ino
                    {
                        Darwin.unlink(destination.path)
                    }
                }
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            for range in ranges {
                guard range.lowerBound >= 0, range.upperBound <= stamp.size else {
                    throw ModelFailure.changed
                }
                var offset = range.lowerBound
                while offset < range.upperBound {
                    try cancellation.check()
                    let amount = min(buffer.count, range.upperBound - offset)
                    var count: Int
                    repeat {
                        count = pread(input, &buffer, amount, off_t(offset))
                    } while count < 0 && errno == EINTR
                    guard count > 0 else { throw ModelFailure.changed }
                    try Self.write(Data(buffer.prefix(count)), to: output)
                    offset += count
                }
            }
            try validate(input)
            try cancellation.check()
            succeeded = true
        }
    }

    private static func create(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProcessFailure.outputWrite(errno) }
        return fd
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProcessFailure.outputWrite(count < 0 ? errno : EIO) }
                offset += count
            }
        }
    }
}

extension DiskDiffSnapshot {
    /// Copy a complete standalone hunk patch within the in-memory copy budget.
    /// Larger hunks must use explicit file export instead of an unbounded clipboard allocation.
    public func hunkPatch(_ hunk: DiskDiffHunk, limit: Int = DiffReadBudget.patchBytes) async throws -> Data {
        guard hunks.contains(hunk), limit >= 0, headerEnd <= limit,
            hunk.byteRange.count <= limit - headerEnd
        else { throw ModelFailure.unsupported(L10n.text("此差异块超过复制上限，请导出完整补丁。")) }
        return try await SnapshotIO.run { cancellation in
            let descriptor = try file.open()
            defer { Darwin.close(descriptor) }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            for range in [0..<headerEnd, hunk.byteRange] {
                var offset = range.lowerBound
                while offset < range.upperBound {
                    try cancellation.check()
                    var amount: Int
                    repeat {
                        amount = pread(
                            descriptor, &buffer, min(buffer.count, range.upperBound - offset), off_t(offset))
                    } while amount < 0 && errno == EINTR
                    guard amount > 0 else { throw ModelFailure.changed }
                    result.append(contentsOf: buffer.prefix(amount))
                    offset += amount
                }
            }
            try file.validate(descriptor)
            try cancellation.check()
            return result
        }
    }

    /// Refuses existing destinations. The caller chooses a new export path explicitly.
    public func export(to destination: URL) async throws {
        try await file.copy(ranges: [0..<byteCount], to: destination)
    }
}
