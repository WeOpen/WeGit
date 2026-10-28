import Darwin
import Foundation

enum SelectedWorkFile {
    static func read(location: RepositoryLocation, path: String) async throws -> Data? {
        try await SnapshotIO.run { cancellation in
            try cancellation.check()
            try location.validateIdentity()
            let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
            guard let last = parts.last, !path.hasPrefix("/"), !parts.contains(".."), !path.contains("\0")
            else { throw ModelFailure.invalidPath }
            let root = Darwin.open(location.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw ModelFailure.repositoryReplaced }
            var parent = root
            defer {
                if parent != root { Darwin.close(parent) }
                Darwin.close(root)
            }
            var info = stat()
            guard fstat(root, &info) == 0, info.st_dev == location.rootIdentity.device,
                info.st_ino == location.rootIdentity.inode,
                info.st_birthtimespec.tv_sec == location.rootIdentity.bornSeconds,
                info.st_birthtimespec.tv_nsec == location.rootIdentity.bornNanoseconds
            else { throw ModelFailure.repositoryReplaced }
            for part in parts.dropLast() {
                try cancellation.check()
                let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    if errno == ENOENT {
                        try location.validateIdentity()
                        return nil
                    }
                    throw ModelFailure.invalidPath
                }
                if parent != root { Darwin.close(parent) }
                parent = next
            }
            if fstatat(parent, last, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT {
                    try location.validateIdentity()
                    return nil
                }
                throw ModelFailure.changed
            }
            guard info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), info.st_size <= 8 * 1024 * 1024 else {
                throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。"))
            }
            let reader = try RepositoryFileReader(location: location, path: path, cancellation: cancellation)
            guard !reader.symbolicLink, reader.size <= 8 * 1024 * 1024 else {
                throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。"))
            }
            var result = Data()
            try reader.read(limit: 8 * 1024 * 1024) { result.append($0) }
            return result
        }
    }
}
