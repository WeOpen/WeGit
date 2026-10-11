import CryptoKit
import Darwin
import Foundation
import Testing

@testable import WeGitCore

struct DiskDiffTests {
    private func signature(_ line: DiffLine?) -> String {
        guard let line else { return "nil" }
        return "\(line.kind)|\(line.oldLine ?? -1)|\(line.newLine ?? -1)|\(line.content)"
    }

    @Test func cancellingDiskCapturePreservesAReplacementAtItsOriginalPath() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let output = f.root.appending(path: "stream")
        let task = Task {
            try await ProcessRunner().run(
                ProcessRequest(
                    executable: URL(fileURLWithPath: "/usr/bin/perl"),
                    arguments: ["-e", "$|=1; print 'x' x 100000; sleep 30"], stdoutFile: output))
        }
        defer { task.cancel() }
        var ready = false
        for _ in 0..<200 {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
                (attributes[.size] as? NSNumber)?.intValue == 100_000
            {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready)
        try FileManager.default.moveItem(at: output, to: f.root.appending(path: "original-stream"))
        try Data("replacement owned by the user".utf8).write(to: output)
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(try String(contentsOf: output, encoding: .utf8) == "replacement owned by the user")
    }

    @Test func releasedSnapshotsRemoveTheirPrivateFiles() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("new.txt", "snapshot contents\n")
        func readAndRelease() async throws -> URL {
            let snapshot = try await f.service.diskDiff(path: "new.txt", layer: .untracked)
            #expect(FileManager.default.fileExists(atPath: snapshot.file.url.path))
            return snapshot.file.url
        }
        let path = try await readAndRelease()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: path.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func abandonedCleanupPreservesLiveUnknownAndSymlinkEntries() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let cache = f.root.appending(path: "cache")
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let live = cache.appending(path: "snapshot-\(getpid())-live00")
        let dead = cache.appending(path: "snapshot-2147483647-dead00")
        let unknown = cache.appending(path: "user-folder")
        for directory in [live, dead, unknown] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("keep when live or unknown".utf8).write(to: directory.appending(path: "content"))
        }
        let symlink = cache.appending(path: "snapshot-2147483647-link00")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: unknown.path)
        try await DiffSnapshotStorage.removeAbandoned(in: cache)
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(FileManager.default.fileExists(atPath: unknown.appending(path: "content").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == unknown.path)
    }

    @Test func diskPagesMatchUnifiedAndSplitAcrossHunksAndPageBoundaries() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let original = (1...60).map { "line \($0)" }.joined(separator: "\r\n")
        try f.write("file.swift", original)
        _ = try await f.commit()
        let updated = original.replacingOccurrences(of: "line 5", with: "edited 5")
            .replacingOccurrences(of: "line 30\r\n", with: "new 30\r\nnew 31\r\n")
            .replacingOccurrences(of: "line 60", with: "end")
        try f.write("file.swift", updated)
        let memory = try await f.service.diff(path: "file.swift", layer: .unstaged)
        let disk = try await f.service.diskDiff(path: "file.swift", layer: .unstaged)
        #expect(disk.hunks.map(\.header) == memory.hunks.map(\.header))
        #expect(disk.additions == memory.additions && disk.deletions == memory.deletions)
        #expect(disk.canApplyHunk)
        var cursor: DiskDiffCursor?
        var unified: [DiffLine] = []
        repeat {
            let page = try await disk.page(from: cursor, count: 5)
            unified += page.rows.compactMap { if case .line(let line) = $0 { line } else { nil } }
            #expect(Set(page.rows.map(\.id)).count == page.rows.count)
            cursor = page.next
        } while cursor != nil
        #expect(unified.map { signature($0) } == memory.hunks.flatMap(\.lines).map { signature($0) })
        #expect(Set(unified.map(\.id)).count == unified.count)
        var splitRows: [SplitDiffRow] = []
        repeat {
            let page = try await disk.page(from: cursor, split: true, count: 5)
            splitRows += page.rows.compactMap { if case .split(let row) = $0 { row } else { nil } }
            cursor = page.next
        } while cursor != nil
        let expected = memory.hunks.flatMap { DiffAlignment.rows($0.lines) }
        #expect(
            splitRows.map { signature($0.old) + "\0" + signature($0.new) }
                == expected.map { signature($0.old) + "\0" + signature($0.new) })
        #expect(disk.splitRows == splitRows.count && disk.unifiedRows == unified.count)
    }

    @Test func largePatchReadsOnlyRequestedPagesAndExportsExactBytes() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let padding = String(repeating: "x", count: 240)
        func contents(_ prefix: String) -> String {
            (1...20_000).map { "let \(prefix)\($0) = \"\(padding)\"\n" }.joined()
        }
        try f.write("large.swift", contents("old"))
        _ = try await f.commit()
        try f.write("large.swift", contents("new"))
        let disk = try await f.service.diskDiff(path: "large.swift", layer: .unstaged)
        #expect(disk.byteCount > DiffReadBudget.patchBytes && disk.hunks.count == 1)
        #expect(disk.unifiedRows == 40_000 && disk.splitRows == 20_000)
        #expect(disk.regions.count == 2)
        let first = try await disk.page(split: true)
        #expect(first.firstLine == 1 && first.lastLine == 399)
        #expect(first.bytesRead < 512 * 1024)
        #expect(first.rows.count == 400 && first.completedHunks.isEmpty)
        let second = try await disk.page(from: first.next, split: true)
        #expect(second.firstLine == 400 && second.lastLine == 798)
        #expect(second.bytesRead < 1024 * 1024)
        let exported = f.root.appending(path: "exported.patch")
        try await disk.export(to: exported)
        let bytes = try Data(contentsOf: exported)
        #expect(bytes.count == disk.byteCount)
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == disk.digest)
        await #expect(throws: ProcessFailure.self) { try await disk.export(to: exported) }
        #expect(try Data(contentsOf: exported) == bytes)
        // A different snapshot or layout cannot consume a stale cursor.
        let cursor = try #require(first.next)
        await #expect(throws: ModelFailure.self) { _ = try await disk.page(from: cursor, split: false) }
        try f.write("large.swift", "changed after reading\n")
        await #expect(throws: ModelFailure.self) {
            try await f.service.apply(hunk: disk.hunks[0], from: disk)
        }
        #expect(try await f.engine.run(["show", ":large.swift"], in: f.root).text.hasPrefix("let old1"))
    }

    @Test func fileBackedHunkStageUnstageAndDiscardPreserveOtherChanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let original = (1...80).map { "line \($0)\n" }.joined()
        try f.write("file.txt", original)
        _ = try await f.commit()
        let first = original.replacingOccurrences(of: "line 20\n", with: "first\n")
        let updated = first.replacingOccurrences(of: "line 60\n", with: "second\n")
        try f.write("file.txt", updated)
        let disk = try await f.service.diskDiff(path: "file.txt", layer: .unstaged)
        try await f.service.apply(hunk: disk.hunks[0], from: disk)
        #expect(try await f.engine.run(["show", ":file.txt"], in: f.root).text == first)
        let staged = try await f.service.diskDiff(path: "file.txt", layer: .staged)
        try await f.service.apply(hunk: staged.hunks[0], from: staged)
        #expect(try await f.engine.run(["show", ":file.txt"], in: f.root).text == original)
        let current = try await f.service.diskDiff(path: "file.txt", layer: .unstaged)
        try await f.service.apply(hunk: current.hunks[0], from: current, discard: true)
        #expect(
            try String(contentsOf: f.root.appending(path: "file.txt"), encoding: .utf8)
                == original.replacingOccurrences(of: "line 60\n", with: "second\n"))
        #expect(try await f.engine.run(["show", ":file.txt"], in: f.root).text == original)
    }

    @Test func previewHandlesLongUTF8LinesBinaryAndFileChanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let value = String(repeating: "a", count: 65_535) + "👩🏽‍💻\r\n尾行"
        try f.write("new.txt", value)
        let snapshot = try await f.service.diskDiff(path: "new.txt", layer: .untracked)
        #expect(snapshot.rawPreview && !snapshot.binary && !snapshot.canApplyHunk)
        let page = try await snapshot.page()
        let lines = page.rows.compactMap { if case .line(let line) = $0 { line } else { nil } }
        #expect(lines.count == 2 && lines[0].truncated && lines[0].content.utf8.count <= 8192)
        #expect(lines[1].content == "尾行")
        try f.write("new.txt", "new live file")
        #expect(try await snapshot.page().lastLine == 2)
        let corrupt = f.root.appending(path: "binary")
        try Data([0xE0, 0x80, 0x80]).write(to: corrupt)
        #expect(try await f.service.diskDiff(path: "binary", layer: .untracked).binary)
        try Data("tampered".utf8).write(to: snapshot.file.url)
        await #expect(throws: ModelFailure.self) { _ = try await snapshot.page() }
    }

    @Test func diskCaptureRetainsSymlinkSafetyAndRejectsFIFOAndOversizedFiles() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("target", "private target")
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: "link").path, withDestinationPath: "target")
        let link = try await f.service.diskDiff(path: "link", layer: .untracked)
        if case .line(let line) = try await link.page().rows[0] {
            #expect(line.content == "target")
        } else {
            Issue.record("Symlink target name should be previewed")
        }
        #expect(mkfifo(f.root.appending(path: "pipe").path, 0o600) == 0)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.diskDiff(path: "pipe", layer: .untracked)
        }
        let large = f.root.appending(path: "sparse")
        FileManager.default.createFile(atPath: large.path, contents: Data())
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(DiskDiffBudget.bytes + 1))
        try handle.close()
        await #expect(throws: DiffContentLimit.bytes(DiskDiffBudget.bytes)) {
            _ = try await f.service.diskDiff(path: "sparse", layer: .untracked)
        }
    }

    @Test func outputFileCaptureDoesNotBufferStdoutOrOverwriteExistingFiles() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let output = f.root.appending(path: "stdout")
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "print 'x' x 200000"],
                stdoutFile: output))
        #expect(result.stdout.isEmpty && result.stdoutByteCount == 200_000)
        #expect(try Data(contentsOf: output).count == 200_000)
        await #expect(throws: ProcessFailure.self) {
            _ = try await ProcessRunner().run(
                ProcessRequest(
                    executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], stdoutFile: output))
        }
        #expect(try Data(contentsOf: output).count == 200_000)
        let limited = f.root.appending(path: "limited")
        await #expect(throws: ProcessFailure.self) {
            _ = try await ProcessRunner().run(
                ProcessRequest(
                    executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], outputLimit: 4096,
                    stdoutFile: limited))
        }
        #expect(!FileManager.default.fileExists(atPath: limited.path))
    }
}
