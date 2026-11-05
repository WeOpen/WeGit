import Darwin
import Foundation

public enum RasterInputKind: String, Sendable {
    case image, absent, oversized, symbolicLink
}

public struct RasterLFSPointer: Sendable, Equatable {
    public let oid: String
    public let bytes: Int64
}

/// Image readers receive an immutable snapshot, never a URL to the working file.
public struct RasterInput: Sendable {
    public let path: String
    public let kind: RasterInputKind
    public let byteCount: Int64
    public let objectID: String?
    let snapshot: SnapshotFile?
    let currentFile: RecoveryFileCapture?

    @concurrent public func readPrefix(limit: Int = 256 * 1024) async throws -> Data {
        guard kind == .image, (1...256 * 1024).contains(limit), let snapshot else {
            throw ModelFailure.unsupported(L10n.text("内容超过预览上限或不是普通文件。"))
        }
        return try await SnapshotIO.run { cancellation in
            let input = try snapshot.open()
            defer { Darwin.close(input) }
            try cancellation.check()
            let data =
                try FileHandle(fileDescriptor: input, closeOnDealloc: false).read(upToCount: limit) ?? Data()
            try snapshot.validate(input)
            guard data.count == min(Int(byteCount), limit) else { throw ModelFailure.changed }
            return data
        }
    }

    @concurrent public func readBytes() async throws -> Data {
        guard kind == .image, (0...RasterReadBudget.bytes).contains(byteCount),
            let snapshot
        else { throw ModelFailure.unsupported(L10n.text("图片超过读取上限或不是普通文件。")) }
        return try await SnapshotIO.run { cancellation in
            let input = try snapshot.open()
            defer { Darwin.close(input) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try cancellation.check()
                let count = Darwin.read(input, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw ModelFailure.changed }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= RasterReadBudget.bytes else { throw ModelFailure.changed }
            }
            try snapshot.validate(input)
            guard data.count == byteCount else { throw ModelFailure.changed }
            if let digest = snapshot.verifiedSHA256 {
                guard RecoveryFileIO.hash(data) == digest else { throw ModelFailure.changed }
            }
            return data
        }
    }
}

public struct RasterComparisonInput: Sendable {
    public let before: RasterInput
    public let after: RasterInput
}

public enum RasterReadBudget {
    public static let bytes: Int64 = 32 * 1024 * 1024
    public static let pixels = 64_000_000
    public static let thumbnailEdge = 2048
    public static let decodedBytes = 512 * 1024 * 1024
}
