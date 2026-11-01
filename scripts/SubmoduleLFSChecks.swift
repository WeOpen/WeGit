import CryptoKit
import Foundation
import WeGitCore

@main struct SubmoduleLFSChecks {
    enum Failure: Error { case assertion(String) }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitNested-\(UUID())")
        let child = root.appending(path: "child")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(environment: env)
        @discardableResult func git(
            _ args: [String], _ dir: URL = root, configuration: [(key: String, value: String)] = []
        ) async throws -> ProcessResult {
            try await engine.run(args, in: dir, timeout: 30, configuration: configuration)
        }
        try await git(["init", "-b", "main"])
        try await git(["config", "user.name", "Nested Check"])
        try await git(["config", "user.email", "nested@example.invalid"])
        mark("parent initialized")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try await git(["init", "-b", "main"], child)
        try await git(["config", "user.name", "Nested Check"], child)
        try await git(["config", "user.email", "nested@example.invalid"], child)
        mark("child initialized")
        try Data("child\n".utf8).write(to: child.appending(path: "file.txt"))
        try await git(["add", "."], child)
        try await git(["commit", "-m", "Child"], child)
        try await git(
            ["submodule", "add", child.path, "modules/child"],
            configuration: [("protocol.file.allow", "always")])
        mark("submodule added")
        try await git(["commit", "-am", "Add submodule"])
        mark("parent commit")
        let location = try await RepositoryService.discover(root, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        let modules = try await service.submodules()
        mark("submodules listed")
        try require(modules.count == 1, "submodule was not discovered")
        let module = try requireValue(modules.first, "missing submodule")
        print("stage clean state=\(module.state) path=\(root.path)")
        try require(
            module.recordedOID == module.actualOID && module.initialized && !module.dirty,
            "clean submodule state mismatch")
        let moduleWorktree = root.appending(path: "modules/child")
        mark("before child local config")
        try await git(["config", "user.name", "Nested Check"], moduleWorktree)
        mark("after child user config")
        try await git(["config", "user.email", "nested@example.invalid"], moduleWorktree)
        mark("after child email config")
        try Data("later\n".utf8).write(to: moduleWorktree.appending(path: "later.txt"))
        mark("after child file write")
        mark("before child git add")
        try await git(["add", "later.txt"], moduleWorktree)
        mark("after child git add")
        mark("before child commit")
        try await git(["commit", "-m", "Later"], moduleWorktree)
        mark("after child commit")
        mark("before changed submodule scan")
        let changed = try await service.submodules().first!
        mark("after changed submodule scan")
        print("stage changed state=\(changed.state)")
        try require(changed.state == .childChanged, "child commit drift was not detected")
        mark("before restore")
        try await service.initializeOrUpdateSubmodule(path: "modules/child", expectedOID: module.recordedOID!)
        mark("after restore")
        print("stage restored")
        try require(
            try await git(["rev-parse", "HEAD"], moduleWorktree).text.trimmingCharacters(
                in: .whitespacesAndNewlines) == module.recordedOID,
            "submodule update did not restore the recorded gitlink")
        try Data("dirty\n".utf8).write(to: moduleWorktree.appending(path: "file.txt"))
        mark("before dirty scan")
        let dirty = try await service.submodules().first!
        mark("after dirty scan")
        print("stage dirty state=\(dirty.state)")
        try require(dirty.dirty, "dirty child was not detected")
        do {
            try await service.initializeOrUpdateSubmodule(
                path: "modules/child", expectedOID: module.recordedOID!)
            throw Failure.assertion("dirty submodule was overwritten")
        } catch is ModelFailure {}
        _ = try await git(["submodule", "deinit", "-f", "--", "modules/child"])
        print("stage deinit")
        mark("before uninitialized scan")
        try require(
            try await service.submodules().first!.state == .uninitialized, "deinit state not detected")
        mark("after uninitialized scan")
        try FileManager.default.createDirectory(at: moduleWorktree, withIntermediateDirectories: true)
        try Data("foreign\n".utf8).write(to: moduleWorktree.appending(path: "foreign.txt"))
        do {
            try await service.initializeOrUpdateSubmodule(
                path: "modules/child", expectedOID: module.recordedOID!)
            throw Failure.assertion("uninitialized module overwrote foreign directory")
        } catch is ModelFailure {}
        try FileManager.default.removeItem(at: moduleWorktree)
        mark("before initialize")
        let beforeUpdateIndex = try await git(["ls-files", "--stage", "-z"]).stdout
        let beforeUpdateHead = try await service.head()
        try await service.initializeOrUpdateSubmodule(path: "modules/child", expectedOID: module.recordedOID!)
        mark("after initialize")
        try require(
            try await git(["ls-files", "--stage", "-z"]).stdout == beforeUpdateIndex,
            "submodule update changed parent index")
        try require(try await service.head() == beforeUpdateHead, "submodule update changed parent HEAD")
        mark("before final clean scan")
        try require(try await service.submodules().first!.state == .clean, "module was not initialized")
        mark("after final clean scan")
        let excludesPath = try await git(["rev-parse", "--git-path", "info/exclude"], moduleWorktree)
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        let excludes = URL(fileURLWithPath: excludesPath, relativeTo: moduleWorktree).standardizedFileURL
        try Data("ignored.txt\n".utf8).write(to: excludes)
        try Data("ignored\n".utf8).write(to: moduleWorktree.appending(path: "ignored.txt"))
        try require(try await service.submodules().first!.dirty, "ignored child content was not detected")
        try FileManager.default.removeItem(at: moduleWorktree.appending(path: "ignored.txt"))
        try Data("\n".utf8).write(to: excludes)
        let gitmodules = root.appending(path: ".gitmodules")
        let originalGitmodules = try Data(contentsOf: gitmodules)
        try Data("[submodule \"broken\"\n".utf8).write(to: gitmodules)
        do {
            _ = try await service.submodules()
            throw Failure.assertion("malformed .gitmodules was accepted")
        } catch is GitFailure {}
        try FileManager.default.removeItem(at: gitmodules)
        let missingModules = try await service.submodules()
        try require(
            missingModules.count == 1 && missingModules[0].url == nil,
            "missing .gitmodules was not reported")
        try originalGitmodules.write(to: gitmodules)
        try Data(
            "version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "a", count: 64))\nsize 12\n"
                .utf8
        )
        .write(to: root.appending(path: "large.bin"))
        mark("before parent lfs add")
        try await git(["add", "large.bin"])
        mark("after parent lfs add")
        mark("before parent lfs commit")
        try await git(["commit", "-m", "Pointer"])
        mark("after parent lfs commit")
        mark("before lfs scan")
        let lfs = try await service.lfsObjects()
        mark("after lfs scan")
        try require(lfs.count == 1 && lfs[0].isPointer && lfs[0].size == 12, "LFS pointer was not parsed")
        try require(
            lfs[0].workingTreeHydrated == false && !lfs[0].objectAvailable,
            "missing LFS object state mismatch")
        let hydratedData = Data("hydrated\n".utf8)
        let hydratedOID = SHA256.hash(data: hydratedData).map { String(format: "%02x", $0) }.joined()
        let hydratedPointer =
            "version https://git-lfs.github.com/spec/v1\noid sha256:\(hydratedOID)\nsize \(hydratedData.count)\n"
        try Data(hydratedPointer.utf8).write(to: root.appending(path: "hydrated.bin"))
        try await git(["add", "hydrated.bin"])
        try await git(["commit", "-m", "Hydrated pointer"])
        let objectDirectory = root.appending(
            path: ".git/lfs/objects/\(hydratedOID.prefix(2))/\(hydratedOID.dropFirst(2).prefix(2))")
        try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
        try hydratedData.write(to: objectDirectory.appending(path: hydratedOID))
        try hydratedData.write(to: root.appending(path: "hydrated.bin"))
        let hydrated = try await service.lfsObjects().first { $0.path == "hydrated.bin" }
        try require(
            hydrated?.isPointer == true && hydrated?.objectAvailable == true
                && hydrated?.workingTreeHydrated == true,
            "hydrated LFS object state mismatch")
        let malformed = "version https://git-lfs.github.com/spec/v1\noid sha256:not-an-oid\nsize 2\n"
        try Data(malformed.utf8).write(to: root.appending(path: "malformed.bin"))
        try await git(["add", "malformed.bin"])
        try await git(["commit", "-m", "Malformed pointer"])
        let malformedStatus = try await service.lfsObjects().first { $0.path == "malformed.bin" }
        try require(
            malformedStatus?.isPointer == false && malformedStatus?.detail != nil,
            "malformed LFS pointer was accepted")
        do {
            try await service.fetchLFS(path: "large.bin", timeout: 1)
            throw Failure.assertion("LFS fetch succeeded without Git LFS")
        } catch is ModelFailure {}
        let installation = try await service.lfsInstallation()
        print(
            "PASS submodule discovery/dirty state and LFS pointer/tool probe (15 checks; lfs=\(installation.available))"
        )
    }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
    }
    static func mark(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure.assertion(message) }
        return value
    }
}
