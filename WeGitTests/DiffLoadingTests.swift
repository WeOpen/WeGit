import Foundation
import Testing

@testable import WeGitCore

private actor RecordingDiffRunner: ProcessRunning {
    private var arguments: [[String]] = []
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        arguments.append(request.arguments)
        return try await ProcessRunner().run(request)
    }
    func patchesRead() -> Int { arguments.count { $0.contains("--patch") } }
}

private actor WaitingPatchRunner: ProcessRunning {
    private var started = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("--patch") {
            started = true
            for observer in observers { observer.resume() }
            observers.removeAll()
            try await Task.sleep(for: .seconds(30))
        }
        return try await ProcessRunner().run(request)
    }
    func waitForPatch() async {
        if !started { await withCheckedContinuation { observers.append($0) } }
    }
}

struct DiffLoadingTests {
    @Test func summaryHandlesSpecialPathsBinaryAndInvalidCounts() throws {
        let summary = try DiffSummary.parse(
            Data("12\t3\tnested/name\twith\nspaces\0".utf8), path: "file", layer: .staged)
        #expect(summary.additions == 12 && summary.deletions == 3)
        #expect(!summary.needsExplicitLoad)
        #expect(try DiffSummary.parse(Data("-\t-\timage\0".utf8), path: "image", layer: .unstaged).binary)
        for invalid in ["1\t2\ttruncated", "1\tfile\0", "-2\t4\tfile\0", "999999999999999999999\t0\tf\0"] {
            #expect(throws: ModelFailure.self) {
                _ = try DiffSummary.parse(Data(invalid.utf8), path: "file", layer: .unstaged)
            }
        }
    }

    @Test func largeDiffIsSummarizedBeforeReadingAnyPatch() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let path = "code\tfile.swift"
        try f.write(path, (1...1_200).map { "let old\($0) = \($0)\n" }.joined())
        _ = try await f.commit()
        try f.write(path, (1...1_200).map { "let new\($0) = \($0)\n" }.joined())
        let runner = RecordingDiffRunner()
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment)
        )
        guard
            case .deferred(let summary, let limit) = try await service.readDiff(path: path, layer: .unstaged)
        else {
            Issue.record("Large diff should initially show a summary")
            return
        }
        #expect(summary.additions == 1_200 && summary.deletions == 1_200 && limit == nil)
        #expect(await runner.patchesRead() == 0)
        guard
            case .loaded(let diff) = try await service.readDiff(path: path, layer: .unstaged, loadLarge: true)
        else {
            Issue.record("Explicit bounded read should succeed")
            return
        }
        #expect(await runner.patchesRead() == 1)
        let clock = ContinuousClock()
        let start = clock.now
        let document = try await DiffDisplayDocument.prepare(diff, split: false)
        let first = try await document.page(from: 0)
        print(
            "Diff fixture: 2,400 changed lines, document and first page in \(start.duration(to: clock.now))")
        #expect(first.rows.count == DiffReadBudget.pageRows)
        #expect(first.highlighting.syntax.count < 400)
        #expect(first.nextOffset < document.rows.count)
        var all = first.rows
        var next = first.nextOffset
        while next < document.rows.count {
            let page = try await document.page(from: next)
            #expect(page.rows.count <= DiffReadBudget.pageRows)
            all += page.rows
            next = page.nextOffset
        }
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.count(where: \.isContent) == 2_400)
        #expect(diff.hunks.flatMap(\.lines).last?.content == "let new1200 = 1200")
        let split = try await DiffDisplayDocument.prepare(diff, split: true)
        #expect(split.contentRows == 1_200)
        #expect(Set(split.rows.map(\.id)).count == split.rows.count)
    }

    @Test func longLineFallsBackToSummaryThenKeepsAnExactPatch() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("line.txt", "old\n")
        _ = try await f.commit()
        let updated = String(repeating: "x", count: DiffReadBudget.automaticBytes + 20) + "\n"
        try f.write("line.txt", updated)
        guard
            case .deferred(let summary, nil) = try await f.service.readDiff(
                path: "line.txt", layer: .unstaged)
        else {
            Issue.record("Byte ceiling should defer even a single changed line")
            return
        }
        #expect(summary.additions == 1 && summary.deletions == 1)
        guard
            case .loaded(let diff) = try await f.service.readDiff(
                path: "line.txt", layer: .unstaged, loadLarge: true)
        else {
            Issue.record("Explicit single-line read should succeed")
            return
        }
        #expect(diff.hunks[0].lines.last?.content == String(updated.dropLast()))
        try await f.service.apply(hunk: diff.hunks[0], from: diff)
        #expect(try await f.engine.run(["show", ":line.txt"], in: f.root).text == updated)
    }

    @Test func memoryCeilingsSwitchToCompleteDiskSnapshots() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("huge.txt", "old\n")
        _ = try await f.commit()
        try f.write("huge.txt", String(repeating: "x", count: DiffReadBudget.patchBytes + 1) + "\n")
        guard
            case .disk(let snapshot) = try await f.service.readDiff(
                path: "huge.txt", layer: .unstaged, loadLarge: true)
        else {
            Issue.record("Explicit reads beyond the memory ceiling must use disk snapshots")
            return
        }
        #expect(snapshot.additions == 1 && snapshot.deletions == 1)
        #expect(snapshot.byteCount > DiffReadBudget.patchBytes)
        await #expect(throws: ProcessFailure.self) {
            _ = try await f.service.diff(path: "huge.txt", layer: .unstaged)
        }
        try f.write("dense.txt", String(repeating: "\n", count: DiffReadBudget.patchLines + 1))
        guard
            case .disk(let dense) = try await f.service.readDiff(
                path: "dense.txt", layer: .untracked, loadLarge: true)
        else {
            Issue.record("Dense previews must switch to bounded disk pages")
            return
        }
        #expect(dense.unifiedRows == DiffReadBudget.patchLines + 1)
        #expect(try await dense.page().rows.count == DiffReadBudget.pageRows)
        #expect(throws: DiffContentLimit.self) {
            _ = try DiffParser.parse(
                Data(String(repeating: "+\n", count: DiffReadBudget.patchLines + 1).utf8),
                path: "dense", layer: .staged, head: nil)
        }
    }

    @Test func untrackedSummaryUsesSizeAndSpillsPastItsMemoryLimit() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let contents = String(repeating: "preview line\n", count: 50_000)
        try f.write("new.txt", contents)
        guard
            case .deferred(let summary, nil) = try await f.service.readDiff(
                path: "new.txt", layer: .untracked)
        else {
            Issue.record("Large untracked content should require explicit loading")
            return
        }
        #expect(summary.fileBytes == Int64(contents.utf8.count))
        guard
            case .loaded(let preview) = try await f.service.readDiff(
                path: "new.txt", layer: .untracked, loadLarge: true)
        else {
            Issue.record("Bounded preview should be readable")
            return
        }
        let document = try await DiffDisplayDocument.prepare(preview, split: false)
        #expect(try await document.page(from: 0).rows.count == 400)
        #expect(document.contentRows == 50_000)
        try f.write("new.txt", String(repeating: "x", count: DiffReadBudget.previewBytes + 1))
        guard
            case .disk(let largePreview) = try await f.service.readDiff(
                path: "new.txt", layer: .untracked, loadLarge: true)
        else {
            Issue.record("Untracked preview must spill to disk beyond its memory ceiling")
            return
        }
        #expect(largePreview.byteCount == DiffReadBudget.previewBytes + 1)
        let sparse = f.root.appending(path: "sparse")
        FileManager.default.createFile(atPath: sparse.path, contents: Data())
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(DiskDiffBudget.bytes + 1))
        try handle.close()
        guard
            case .deferred(let capped, .bytes(DiskDiffBudget.bytes)) = try await f.service.readDiff(
                path: "sparse", layer: .untracked, loadLarge: true)
        else {
            Issue.record("The disk ceiling must still preserve a useful summary")
            return
        }
        #expect(capped.fileBytes == Int64(DiskDiffBudget.bytes + 1))
    }

    @Test func cancelledReadAndPageRequestsThrow() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let read = Task {
            try? await Task.sleep(for: .seconds(10))
            return try await f.service.readDiff(path: "file", layer: .unstaged)
        }
        read.cancel()
        await #expect(throws: CancellationError.self) { _ = try await read.value }
        let diff = try DiffParser.parse(
            Data("@@ -1 +1 @@\n-old\n+new\n".utf8), path: "code.swift", layer: .unstaged, head: nil)
        let document = try await DiffDisplayDocument.prepare(diff, split: false)
        let page = Task {
            try? await Task.sleep(for: .seconds(10))
            return try await document.page(from: 0)
        }
        page.cancel()
        await #expect(throws: CancellationError.self) { _ = try await page.value }
    }

    @Test func cancelsAnExplicitReadAfterTheGitRequestHasStarted() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file.txt", "old\n")
        _ = try await f.commit()
        try f.write("file.txt", "new\n")
        let runner = WaitingPatchRunner()
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment)
        )
        let task = Task { try await service.readDiff(path: "file.txt", layer: .unstaged, loadLarge: true) }
        await runner.waitForPatch()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await f.engine.run(["show", ":file.txt"], in: f.root).text == "old\n")
        #expect(try String(contentsOf: f.root.appending(path: "file.txt"), encoding: .utf8) == "new\n")
    }
}
