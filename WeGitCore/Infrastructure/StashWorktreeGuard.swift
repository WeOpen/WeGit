import Darwin
import Foundation

/// Git stash may overwrite ignored directories and omit embedded repositories.
/// Probe every materialized path without following links before asking Git to write.
/// File/directory replacements that cannot preserve every unsaved entry are rejected.
enum StashWorktreeGuard {
    static func validate(paths: Set<String>, tracked: Set<String>, location: RepositoryLocation) async throws
    {
        try await SnapshotIO.run { cancellation in
            try location.validateIdentity()
            let root = Darwin.open(location.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw ModelFailure.repositoryReplaced }
            defer { Darwin.close(root) }
            var rootInfo = stat()
            guard fstat(root, &rootInfo) == 0,
                rootInfo.st_dev == location.rootIdentity.device,
                rootInfo.st_ino == location.rootIdentity.inode,
                rootInfo.st_birthtimespec.tv_sec == location.rootIdentity.bornSeconds,
                rootInfo.st_birthtimespec.tv_nsec == location.rootIdentity.bornNanoseconds
            else { throw ModelFailure.repositoryReplaced }
            func reject() -> ModelFailure {
                .unsupported(L10n.text("操作会替换现有目录、未跟踪文件或符号链接父路径，请先处理这些内容。"))
            }
            func probe(_ path: String) throws {
                let components = path.split(separator: "/").map(String.init)
                guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                    !components.contains(".."), !components.contains(".")
                else { throw ModelFailure.invalidPath }
                var parent = root
                defer { if parent != root { Darwin.close(parent) } }
                for (index, component) in components.enumerated() {
                    try cancellation.check()
                    var info = stat()
                    if fstatat(parent, component, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                        if errno == ENOENT { return }
                        throw ModelFailure.changed
                    }
                    let kind = info.st_mode & UInt16(S_IFMT)
                    if index == components.count - 1 {
                        guard tracked.contains(path), [UInt16(S_IFREG), UInt16(S_IFLNK)].contains(kind) else {
                            throw reject()
                        }
                    } else {
                        guard kind == UInt16(S_IFDIR) else { throw reject() }
                        let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard next >= 0 else { throw ModelFailure.changed }
                        if parent != root { Darwin.close(parent) }
                        parent = next
                    }
                }
            }
            for path in paths { try probe(path) }
            try cancellation.check()
            try location.validateIdentity()
        }
    }
}
