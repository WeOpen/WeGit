import Foundation
import Testing

@testable import WeGitCore

private final class ReadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.withLock { data.append(value) } }
    var value: Data { lock.withLock { data } }
}

struct RepositoryFileTests {
    @Test func allPreviewPathsRejectSymlinkedParentDirectories() async throws {
        let f = try await Fixture.create()
        let outside = f.root.appendingPathExtension("outside")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = Data(repeating: 83, count: DiffReadBudget.automaticBytes + 1)
        try secret.write(to: outside.appending(path: "private.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: "link").path, withDestinationPath: outside.path)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.diff(path: "link/private.txt", layer: .untracked)
        }
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.readDiff(path: "link/private.txt", layer: .untracked)
        }
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.diskDiff(path: "link/private.txt", layer: .untracked)
        }
        #expect(try await f.service.diff(path: "link", layer: .untracked).preview == outside.path)
        #expect(try Data(contentsOf: outside.appending(path: "private.txt")) == secret)
    }

    @Test func deepPathsAndLiteralNamesUseTheSameBoundedReader() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let folders = Array(repeating: "d", count: 140).joined(separator: "/")
        try FileManager.default.createDirectory(
            at: f.root.appending(path: folders), withIntermediateDirectories: true)
        let path = folders + "/:(literal)\n测试.swift"
        let text = "let message = \"Hello 👩🏽‍💻\"\r\nlast line"
        try f.write(path, text)
        #expect(try await f.service.diff(path: path, layer: .untracked).preview == text)
        let snapshot = try await f.service.diskDiff(path: path, layer: .untracked)
        let output = f.root.appending(path: "copied.txt")
        try await snapshot.export(to: output)
        #expect(try String(contentsOf: output, encoding: .utf8) == text)
    }

    @Test(arguments: [true, false]) func replacingAnAncestorOrLeafDuringReadCannotRedirectContent(
        replaceParent: Bool
    ) async throws {
        let f = try await Fixture.create()
        let outside = f.root.appendingPathExtension("outside")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: outside)
        }
        let folder = f.root.appending(path: "nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let original = Data(repeating: 65, count: 160_000)
        try original.write(to: folder.appending(path: "data"))
        try Data("outside private contents".utf8).write(to: outside.appending(path: "data"))
        let captured = ReadCapture()
        await #expect(throws: ModelFailure.self) {
            try await SnapshotIO.run { cancellation in
                let reader = try RepositoryFileReader(
                    location: f.service.location, path: "nested/data", cancellation: cancellation)
                var replaced = false
                try reader.read(limit: 200_000) { chunk in
                    captured.append(chunk)
                    if !replaced {
                        replaced = true
                        if replaceParent {
                            try FileManager.default.moveItem(at: folder, to: f.root.appending(path: "moved"))
                            try FileManager.default.createSymbolicLink(
                                atPath: folder.path, withDestinationPath: outside.path)
                        } else {
                            try FileManager.default.moveItem(
                                at: folder.appending(path: "data"), to: folder.appending(path: "original"))
                            try Data("replacement".utf8).write(to: folder.appending(path: "data"))
                        }
                    }
                }
            }
        }
        #expect(captured.value == original)
        #expect(
            try String(contentsOf: outside.appending(path: "data"), encoding: .utf8)
                == "outside private contents")
    }

    @Test func cancellingAWorktreeReadStopsBeforeTheNextChunk() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("data", String(repeating: "x", count: 160_000))
        let captured = ReadCapture()
        await #expect(throws: CancellationError.self) {
            try await SnapshotIO.run { cancellation in
                let reader = try RepositoryFileReader(
                    location: f.service.location, path: "data", cancellation: cancellation)
                try reader.read(limit: 200_000) { chunk in
                    captured.append(chunk)
                    cancellation.cancel()
                }
            }
        }
        #expect(captured.value.count == 64 * 1024)
        #expect(try Data(contentsOf: f.root.appending(path: "data")).count == 160_000)
    }
}
