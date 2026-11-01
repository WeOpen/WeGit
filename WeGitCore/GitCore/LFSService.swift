import CryptoKit
import Darwin
import Foundation

private struct LFSParsedPointer: Sendable {
    let oid: String
    let size: Int64
}

extension RepositoryService {
    public func lfsInstallation() async throws -> LFSInstallation {
        do {
            let result = try await engine.run(
                ["lfs", "version"], in: location.root, accepted: [0, 1], timeout: 5)
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

    /// Reads the committed pointer from the index, then compares it with the working tree.
    /// This remains useful when Git LFS is not installed, while still reporting local object
    /// availability when the standard object layout is present. Every file read is bounded.
    public func lfsObjects(maxBytes: Int = 4 * 1024 * 1024) async throws -> [LFSObjectStatus] {
        guard (1...16 * 1024 * 1024).contains(maxBytes) else { throw ModelFailure.invalidPath }
        let files = try await engine.run(
            ["ls-files", "--stage", "-z"], in: location.root, outputLimit: maxBytes
        ).stdout
        var result: [LFSObjectStatus] = []
        for raw in files.split(separator: 0) {
            guard let tab = raw.firstIndex(of: 9),
                let header = String(data: Data(raw[..<tab]), encoding: .utf8),
                let path = String(data: Data(raw[raw.index(after: tab)...]), encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[2] == "0", GitObjectID.valid(String(fields[1]))
            else { throw ModelFailure.changed }
            let mode = String(fields[0])
            // A gitlink is a directory in the worktree, and a symlink must never be followed.
            guard mode != "160000", mode != "120000" else { continue }
            try validate(path)

            let indexBytes: Data
            do {
                indexBytes = try await engine.run(
                    ["cat-file", "blob", String(fields[1])], in: location.root,
                    outputLimit: maxBytes
                ).stdout
            } catch ProcessFailure.outputLimit {
                continue
            }
            guard let indexText = String(data: indexBytes, encoding: .utf8),
                indexText.hasPrefix("version https://git-lfs.github.com/spec/v1\n")
            else { continue }

            guard let pointer = parseLFSPointer(indexText) else {
                result.append(
                    .init(
                        path: path, oid: nil, size: nil, isPointer: false, objectAvailable: false,
                        workingTreeHydrated: nil, detail: L10n.text("LFS 指针格式无效")))
                continue
            }

            let objectAvailable = lfsObjectExists(oid: pointer.oid, size: pointer.size)
            let working = try await readWorkingTreeLFS(
                path: path, pointer: pointer, maxBytes: maxBytes)
            result.append(
                .init(
                    path: path, oid: pointer.oid, size: pointer.size, isPointer: true,
                    objectAvailable: objectAvailable, workingTreeHydrated: working.hydrated,
                    detail: working.detail
                        ?? (objectAvailable ? nil : L10n.text("LFS 对象尚未下载"))))
        }
        return result
    }

    public func fetchLFS(path: String, timeout: TimeInterval = 120) async throws {
        try validate(path)
        guard timeout > 0, timeout <= 900 else { throw ModelFailure.invalidPath }
        let installation = try await lfsInstallation()
        guard installation.available else {
            throw ModelFailure.unsupported(L10n.text("当前 Git 未安装 Git LFS。"))
        }
        _ = try await engine.run(
            ["lfs", "pull", "--include", path, "--exclude", ""], in: location.root, timeout: timeout)
    }

    private func parseLFSPointer(_ text: String) -> LFSParsedPointer? {
        let lines = text.split(separator: "\n").map(String.init)
        guard let oidLine = lines.first(where: { $0.hasPrefix("oid sha256:") }),
            let sizeLine = lines.first(where: { $0.hasPrefix("size ") }),
            let rawOID = oidLine.split(separator: ":", maxSplits: 1).last,
            rawOID.count == 64, rawOID.allSatisfy(\.isHexDigit),
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
    ) async throws -> (hydrated: Bool?, detail: String?) {
        do {
            return try await SnapshotIO.run { cancellation in
                let reader = try RepositoryFileReader(
                    location: self.location, path: path, cancellation: cancellation)
                guard !reader.symbolicLink else {
                    return (nil, L10n.text("工作树路径是符号链接，未读取内容"))
                }
                guard reader.size <= Int64(maxBytes) else {
                    return (nil, L10n.text("工作树文件超过读取上限"))
                }
                var data = Data()
                try reader.read(limit: maxBytes) { data.append($0) }
                if let text = String(data: data, encoding: .utf8),
                    text.hasPrefix("version https://git-lfs.github.com/spec/v1\n")
                {
                    guard let workingPointer = self.parseLFSPointer(text) else {
                        return (false, L10n.text("工作树中的 LFS 指针格式无效"))
                    }
                    guard workingPointer.oid == pointer.oid, workingPointer.size == pointer.size else {
                        return (false, L10n.text("工作树中的 LFS 指针与索引不一致"))
                    }
                    return (false, nil)
                }
                guard reader.size == pointer.size else {
                    return (false, L10n.text("工作树文件大小与 LFS 指针不一致"))
                }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == pointer.oid else {
                    return (false, L10n.text("工作树文件与 LFS 对象不一致"))
                }
                return (true, nil)
            }
        } catch ModelFailure.changed {
            return (nil, L10n.text("工作树文件不存在或已变化"))
        } catch CocoaError.fileNoSuchFile {
            return (nil, L10n.text("工作树文件不存在或已变化"))
        }
    }
}
