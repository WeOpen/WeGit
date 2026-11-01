import CryptoKit
import Darwin
import Foundation
import WeGitCore

actor LFSCountedRunner: ProcessRunning {
    private var reads = 0
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("cat-file") { reads += 1 }
        return try await ProcessRunner().run(request)
    }
    func count() -> Int { reads }
}

actor LFSMutatingRunner: ProcessRunning {
    private var mutated = false
    let mutation: @Sendable () async throws -> Void
    init(_ mutation: @escaping @Sendable () async throws -> Void) { self.mutation = mutation }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if !mutated, request.arguments.contains("lfs"), request.arguments.contains("env") {
            mutated = true
            try await mutation()
        }
        return try await ProcessRunner().run(request)
    }
}

@main struct LFSBoundaryChecks {
    enum Failure: Error { case assertion(String) }
    @MainActor static var checks = 0
    @MainActor static func require(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure.assertion(name) }
        checks += 1
    }
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func oid(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func pointer(_ data: Data) -> Data {
        Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(oid(data))\nsize \(data.count)\n".utf8)
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitLFSBoundaries-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var finished = false
        defer { if finished { try? FileManager.default.removeItem(at: root) } }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let counted = LFSCountedRunner()
        let engine = GitEngine(
            executable: URL(fileURLWithPath: environment["WEGIT_TEST_GIT"] ?? "/usr/bin/git"),
            runner: counted, environment: environment)
        @discardableResult func git(_ args: [String]) async throws -> String {
            try await engine.run(args, in: root).text.trimmingCharacters(in: .newlines)
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "LFS Check"), ("user.email", "fixture@example.invalid"),
            ("commit.gpgsign", "false"), ("gc.auto", "0"), ("maintenance.auto", "false"),
            ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] {
            try await git(["config", key, value])
        }
        for index in 0..<5000 {
            try Data("ordinary \(index)\n".utf8).write(to: root.appending(path: "file-\(index)"))
        }
        let payload = Data("selected cache payload\n".utf8)
        let otherPayload = Data("other cache payload\n".utf8)
        let path = "literal,[*]\n中文.bin"
        try pointer(payload).write(to: root.appending(path: path))
        try pointer(otherPayload).write(to: root.appending(path: "other.bin"))
        try Data(repeating: 255, count: 2 * 1024 * 1024).write(to: root.appending(path: "binary.bin"))
        try Data(("version https://git-lfs.github.com/spec/v1\n" + String(repeating: "x", count: 2048)).utf8)
            .write(to: root.appending(path: "big-lookalike.bin"))
        try await git(["add", "."])
        try await git(["commit", "-m", "LFS fixture"])
        let location = try await RepositoryService.discover(root, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        let initialIndex = try Data(contentsOf: location.gitDirectory.appending(path: "index"))
        let initialHead = try await service.head()
        let startReads = await counted.count()
        let objects = try await service.lfsObjects()
        try require(
            objects.count == 2 && objects.contains(where: { $0.path == path && $0.oid == oid(payload) }),
            "literal pointer path and ordinary/binary classification")
        try require(await counted.count() - startReads == 2, "5000-file scan must use two batch processes")
        try require(
            try Data(contentsOf: location.gitDirectory.appending(path: "index")) == initialIndex,
            "read preserves raw index")
        try require(try await service.head() == initialHead, "read preserves HEAD")
        let remote = root.appending(path: ".git/remote.git")
        try await git(["init", "--bare", remote.path])
        try await git(["remote", "add", "origin", remote.path])
        try await git(["config", "lfs.fetchrecentalways", "true"])
        let payloads = location.gitDirectory.appending(path: "fixture-payloads")
        try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: false)
        try payload.write(to: payloads.appending(path: oid(payload)))
        try otherPayload.write(to: payloads.appending(path: oid(otherPayload)))
        let marker = location.gitDirectory.appending(path: "fixture-fetch-called")
        let ready = location.gitDirectory.appending(path: "fixture-fetch-ready")
        let wrapper = location.gitDirectory.appending(path: "fixture-lfs-git")
        let script = """
            #!/bin/bash
            set -eu
            args=("$@")
            index=-1
            for ((n=0; n<${#args[@]}; n++)); do
              if test "${args[$n]}" = lfs; then index=$n; break; fi
            done
            if test "$index" = -1; then exec \(quote(engine.executable.path)) "$@"; fi
            prefix=("${args[@]:0:$index}")
            action="${args[$((index+1))]}"
            case "$action" in
              version) printf 'git-lfs/fixture\\n'; exit 0 ;;
              env) printf 'Endpoint=https://fixture.example.invalid/info/lfs (auth=none)\\n'; exit 0 ;;
              fetch)
                printf called > \(quote(marker.path))
                if test "${LFS_FIXTURE_DELAY:-0}" = 1; then
                  trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 143' TERM
                  /bin/sleep 30 &
                  child=$!
                  printf '%s %s\\n' "$$" "$child" > \(quote(ready.path + ".pending")) || exit 1
                  /bin/mv \(quote(ready.path + ".pending")) \(quote(ready.path)) || exit 1
                  wait "$child"
                fi
                for revision in "$@"; do :; done
                names=$(\(quote(engine.executable.path)) ls-tree --name-only "$revision")
                test "$names" = $'.gitattributes\\nobject.lfs' || exit 42
                recent=$(\(quote(engine.executable.path)) "${prefix[@]}" config --get lfs.fetchrecentalways)
                test "$recent" = false || exit 43
                text=$(\(quote(engine.executable.path)) cat-file blob "$revision:object.lfs")
                object=$(printf '%s\\n' "$text" | awk '/^oid sha256:/ { sub(/^oid sha256:/, ""); print }')
                test -f \(quote(payloads.path))/"$object" || exit 44
                first=${object:0:2}
                second=${object:2:2}
                target=\(quote(location.commonDirectory.appending(path: "lfs/objects").path))/"$first"/"$second"
                mkdir -p "$target"
                cp \(quote(payloads.path))/"$object" "$target/$object"
                exit 0 ;;
              *) exit 45 ;;
            esac
            """
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let fakeEngine = GitEngine(executable: wrapper, environment: environment)
        let fake = RepositoryService(location: location, engine: fakeEngine)
        let objectsBefore = try await git(["count-objects", "-v"])
        try await fake.fetchLFS(path: path, expectedOID: oid(payload))
        let cache = location.commonDirectory.appending(
            path:
                "lfs/objects/\(oid(payload).prefix(2))/\(oid(payload).dropFirst(2).prefix(2))/\(oid(payload))"
        )
        let otherCache = location.commonDirectory.appending(
            path:
                "lfs/objects/\(oid(otherPayload).prefix(2))/\(oid(otherPayload).dropFirst(2).prefix(2))/\(oid(otherPayload))"
        )
        try require(try Data(contentsOf: cache) == payload, "only the fixed object is fetched")
        try require(
            !FileManager.default.fileExists(atPath: otherCache.path), "no other pointer object is fetched")
        try require(
            try Data(contentsOf: root.appending(path: path)) == pointer(payload),
            "cache fetch does not hydrate working file")
        try require(
            try Data(contentsOf: root.appending(path: "other.bin")) == pointer(otherPayload),
            "cache fetch preserves other working files")
        try require(
            try Data(contentsOf: location.gitDirectory.appending(path: "index")) == initialIndex,
            "cache fetch preserves raw index")
        try require(try await service.head() == initialHead, "cache fetch preserves HEAD")
        try require(
            try await git(["count-objects", "-v"]) == objectsBefore,
            "private snapshot does not write user Git objects")
        let observed = try await fake.lfsObjects().first { $0.path == path }
        try require(
            observed?.objectAvailable == true && observed?.workingTreeHydrated == false,
            "cache and working pointer states remain distinct")
        try FileManager.default.removeItem(at: marker)
        do {
            try await fake.fetchLFS(path: path, expectedOID: oid(otherPayload))
            throw Failure.assertion("stale selected pointer was accepted")
        } catch is ModelFailure {}
        try require(
            !FileManager.default.fileExists(atPath: marker.path), "stale pointer refuses before fetch")

        let changedIndex = LFSMutatingRunner {
            try pointer(otherPayload).write(to: root.appending(path: path))
            _ = try await engine.run(["add", "--", path], in: root)
        }
        do {
            try await RepositoryService(
                location: location,
                engine: GitEngine(executable: wrapper, runner: changedIndex, environment: environment)
            ).fetchLFS(path: path, expectedOID: oid(payload))
            throw Failure.assertion("index change during preparation was accepted")
        } catch is ModelFailure {}
        try require(
            !FileManager.default.fileExists(atPath: marker.path), "external index change refuses before fetch"
        )
        try require(
            try Data(contentsOf: root.appending(path: path)) == pointer(otherPayload),
            "external index/content change is preserved")
        try pointer(payload).write(to: root.appending(path: path))
        try await git(["add", "--", path])
        let changedHead = LFSMutatingRunner {
            _ = try await engine.run(["commit", "--allow-empty", "-m", "External HEAD"], in: root)
        }
        do {
            try await RepositoryService(
                location: location,
                engine: GitEngine(executable: wrapper, runner: changedHead, environment: environment)
            ).fetchLFS(path: path, expectedOID: oid(payload))
            throw Failure.assertion("HEAD change during preparation was accepted")
        } catch is ModelFailure {}
        try require(
            !FileManager.default.fileExists(atPath: marker.path), "external HEAD change refuses before fetch")

        var delayedEnvironment = environment
        delayedEnvironment["LFS_FIXTURE_DELAY"] = "1"
        let delayed = RepositoryService(
            location: location, engine: GitEngine(executable: wrapper, environment: delayedEnvironment))
        let indexBeforeCancel = try Data(contentsOf: location.gitDirectory.appending(path: "index"))
        let task = Task { try await delayed.fetchLFS(path: path, expectedOID: oid(payload)) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        do {
            while !FileManager.default.fileExists(atPath: ready.path), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let pids = try String(contentsOf: ready, encoding: .utf8).split(whereSeparator: \.isWhitespace)
                .compactMap { pid_t($0) }
            try require(
                pids.count == 2 && pids.allSatisfy { $0 > 0 && kill($0, 0) == 0 },
                "fetch cancellation reaches live wrapper and child")
            task.cancel()
            do {
                try await task.value
                throw Failure.assertion("cancelled fetch succeeded")
            } catch ProcessFailure.cancelled {} catch is CancellationError {}
            try require(kill(-pids[0], 0) == -1 && errno == ESRCH, "cancelled fetch process group exits")
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        try require(
            try Data(contentsOf: location.gitDirectory.appending(path: "index")) == indexBeforeCancel,
            "fetch cancellation preserves index")
        try FileManager.default.removeItem(at: ready)
        do {
            try await delayed.fetchLFS(path: path, expectedOID: oid(payload), timeout: 0.2)
            throw Failure.assertion("timed out fetch succeeded")
        } catch ProcessFailure.timedOut {}
        let timeoutPids = try String(contentsOf: ready, encoding: .utf8).split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
        try require(
            timeoutPids.count == 2 && kill(-timeoutPids[0], 0) == -1 && errno == ESRCH,
            "timed out fetch process group exits")
        try require(
            try Data(contentsOf: location.gitDirectory.appending(path: "index")) == indexBeforeCancel,
            "fetch timeout preserves index")
        try await fake.fetchLFS(path: path, expectedOID: oid(payload))
        try require(
            try await fake.lfsObjects().first(where: { $0.path == path })?.objectAvailable == true,
            "queue and read recover after cancelled/timed-out fetch")

        for index in 0..<17 {
            let data = Data(repeating: UInt8(index), count: 1024 * 1024)
            let name = "aggregate-\(index).bin"
            try pointer(data).write(to: root.appending(path: name))
            try await git(["add", "--", name])
            try data.write(to: root.appending(path: name))
        }
        let aggregate = try await service.lfsObjects().filter { $0.path.hasPrefix("aggregate-") }
        try require(
            aggregate.filter { $0.workingTreeHydrated == true }.count == 16
                && aggregate.contains(where: { $0.workingTreeHydrated == nil }),
            "aggregate worktree read budget is enforced")
        let empty = pointer(Data())
        for index in 0..<513 { try empty.write(to: root.appending(path: "many-\(index).bin")) }
        try await git(["add", "--"] + (0..<513).map { "many-\($0).bin" })
        do {
            _ = try await service.lfsObjects()
            throw Failure.assertion("unbounded pointer result was accepted")
        } catch is ModelFailure {}
        checks += 1
        print(
            "PASS LFS batching, fixed cache fetch, literal paths, stale state, live cancellation, timeout and aggregate budgets (\(checks) checks; no real LFS service/XCTest)"
        )
        finished = true
    }
}
