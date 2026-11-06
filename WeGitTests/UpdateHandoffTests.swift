import Darwin
import Foundation
import Testing

@testable import WeGitCore

struct UpdateHandoffTests {
    @Test func processIdentityRoundTripsPIDStartAndExecutableNode() throws {
        let identity = try UpdateProcessIdentity.capture()
        let decoded = try JSONDecoder().decode(
            UpdateProcessIdentity.self, from: JSONEncoder().encode(identity))
        #expect(identity == decoded)
        #expect(identity.pid == getpid())
        #expect(identity.owner == getuid())
        #expect(identity.stillRunning())
    }

    @Test func absentProcessCannotBeArmedAsNormalExitEvidence() throws {
        #expect(throws: UpdateFailure.self) { try UpdateProcessIdentity.capture(pid: -1) }
    }

    @Test func kernelNormalExitIsObservedBeforeAllowingReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "WeGit.UpdateHandoffTests." + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "source")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: executable)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let source = try UpdateProcessIdentity.capture(pid: process.processIdentifier)
        let monitor = try UpdateSourceProcessMonitor(identity: source)
        try pipe.fileHandleForWriting.close()
        let permit = try await monitor.waitForNormalExit(timeout: 2)
        process.waitUntilExit()
        #expect(permit.source == source)
        #expect(permit.exitStatus == 0)
        #expect(!source.stillRunning())
    }

    @Test func signalExitDoesNotAuthorizeTheOriginalApp() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "WeGit.UpdateHandoffTests." + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "source")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let monitor = try UpdateSourceProcessMonitor(
            identity: UpdateProcessIdentity.capture(pid: process.processIdentifier))
        process.terminate()
        process.waitUntilExit()
        await #expect(throws: UpdateFailure.self) { try await monitor.waitForNormalExit(timeout: 2) }
    }

    @Test func prereleaseEvidenceCannotBeReplacedWithBaseVersion() throws {
        let stable: [String: Any] = ["CFBundleShortVersionString": "2.0.0"]
        try UpdateInstaller.validateReleaseVersion(info: stable, expected: "2.0.0")
        #expect(throws: UpdateFailure.self) {
            try UpdateInstaller.validateReleaseVersion(info: stable, expected: "2.0.0-rc.2")
        }
        try UpdateInstaller.validateReleaseVersion(
            info: ["CFBundleShortVersionString": "2.0.0", "WeGitReleaseVersion": "2.0.0-rc.2"],
            expected: "2.0.0-rc.2")
        #expect(throws: UpdateFailure.self) {
            try UpdateInstaller.validateReleaseVersion(
                info: ["CFBundleShortVersionString": "2.0.0", "WeGitReleaseVersion": "2.0.0-rc.1"],
                expected: "2.0.0-rc.2")
        }
    }
}
