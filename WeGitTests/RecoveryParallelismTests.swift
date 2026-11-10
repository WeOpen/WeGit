import Darwin
import Foundation
import Testing

@testable import WeGitCore

private actor RecoveryCheckoutArguments: ProcessRunning {
    private(set) var resets: [[String]] = []
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("reset") { resets.append(request.arguments) }
        return try await ProcessRunner().run(request)
    }
}

struct RecoveryParallelismTests {
    @Test func substantialHardResetRetainsExplicitWorkersAndRestoresOriginalBytes() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let paths = (0..<128).map { "file-\($0)" }
        let targetBytes = Data(repeating: 65, count: 128 * 1024)
        let currentBytes = Data(repeating: 66, count: 128 * 1024)
        let workingBytes = Data(repeating: 67, count: 128 * 1024)
        for path in paths { try targetBytes.write(to: fixture.root.appending(path: path)) }
        let target = try await fixture.commit("Target")
        for path in paths { try currentBytes.write(to: fixture.root.appending(path: path)) }
        _ = try await fixture.commit("Current")
        for path in paths { try workingBytes.write(to: fixture.root.appending(path: path)) }
        _ = try await fixture.engine.run(["add", "--"] + Array(paths.prefix(64)), in: fixture.root)
        _ = try await fixture.engine.run(["config", "checkout.workers", "2"], in: fixture.root)
        let configURL = fixture.service.location.commonDirectory.appending(path: "config")
        let configBytes = try Data(contentsOf: configURL)
        let indexURL = fixture.service.location.gitDirectory.appending(path: "index")
        let indexBytes = try Data(contentsOf: indexURL)
        let runner = RecoveryCheckoutArguments()
        let service = RepositoryService(
            location: fixture.service.location,
            engine: TestGit.engine(runner: runner, environment: fixture.engine.environment))
        let record = try await service.executeReset(service.prepareReset(target: target, mode: .hard))
        let reset = try #require(await runner.resets.first)
        #expect(!reset.contains(where: { $0.hasPrefix("checkout.workers=") }))
        #expect(reset.contains("--no-recurse-submodules"))
        #expect(try await service.head() == target)
        for path in paths { #expect(try Data(contentsOf: fixture.root.appending(path: path)) == targetBytes) }
        _ = try await service.executeRecoveryRestore(service.prepareRecoveryRestore(record, layer: .both))
        #expect(try Data(contentsOf: indexURL) == indexBytes)
        #expect(try Data(contentsOf: configURL) == configBytes)
        for path in paths {
            #expect(try Data(contentsOf: fixture.root.appending(path: path)) == workingBytes)
        }
    }
}
