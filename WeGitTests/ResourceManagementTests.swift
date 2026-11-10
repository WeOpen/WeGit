import Foundation
import Testing

@testable import WeGitCore

private actor ResourceMissingLFS: ProcessRunning {
    private(set) var lfsCommands: [String] = []
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if let index = request.arguments.firstIndex(of: "lfs") {
            let command = request.arguments.dropFirst(index + 1).first ?? ""
            lfsCommands.append(command)
            guard command == "version" else { throw ModelFailure.changed }
            return ProcessResult(
                stdout: Data(), stderr: Data("simulated missing LFS\n".utf8), exitCode: 1, duration: 0)
        }
        return try await ProcessRunner().run(request)
    }
}

struct ResourceManagementTests {
    @Test func ruleDocumentsPreserveCommentsCRLFAndOtherAttributes() throws {
        let modules = Data(
            "# preserve\r\n[submodule \"child\"]\r\n\tpath = child\r\n\turl = old # URL comment\r\n\tbranch = main\r\n; last"
                .utf8)
        let changed = try ResourceRuleDocument.moduleKeys(modules, name: "child", updates: ["url": "new"])
        #expect(
            String(decoding: changed, as: UTF8.self)
                == "# preserve\r\n[submodule \"child\"]\r\n\tpath = child\r\n\turl = \"new\" # URL comment\r\n\tbranch = main\r\n; last"
        )
        let attributes = Data(
            "# preserve\r\n*.bin filter=lfs diff=lfs merge=lfs -text custom=keep\r\nother linguist-language=Swift"
                .utf8)
        let untracked = try ResourceRuleDocument.lfsRule(attributes, pattern: "*.bin", action: .untrack)
        #expect(
            String(decoding: untracked, as: UTF8.self)
                == "# preserve\r\n*.bin    -text custom=keep\r\nother linguist-language=Swift")
        let appended = try ResourceRuleDocument.lfsRule(
            Data("# no final newline".utf8), pattern: "*.bin", action: .track)
        #expect(
            appended.last != 10 && String(decoding: appended, as: UTF8.self).hasPrefix("# no final newline\n")
        )
    }

    @Test(.timeLimit(.minutes(1))) func lfsRulePreviewHonorsNestedAndInfoSourcesWithoutToolInstallation()
        async throws
    {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "nested"), withIntermediateDirectories: true)
        try fixture.write("root.bin", "root\n")
        try fixture.write("nested/child.bin", "child\n")
        try fixture.write("nested/.gitattributes", "*.bin filter=custom\n")
        _ = try await fixture.commit()
        let beforeIndex = try SelectedIndexSnapshot.read(location: fixture.service.location)
        let runner = ResourceMissingLFS()
        let engine = GitEngine(
            executable: fixture.engine.executable, runner: runner, environment: fixture.engine.environment)
        let service = RepositoryService(location: fixture.service.location, engine: engine)
        let plan = try await service.prepareLFSRule(pattern: "*.bin", action: .track)
        #expect(!plan.installation.available)
        #expect(plan.matchedPaths.first(where: { $0.path == "root.bin" })?.filter == "lfs")
        #expect(plan.matchedPaths.first(where: { $0.path == "nested/child.bin" })?.filter == "custom")
        #expect(
            plan.matchedPaths.first(where: { $0.path == "nested/child.bin" })?.filterSource
                == "nested/.gitattributes:1")
        _ = try await service.executeLFSRule(plan)
        #expect(await runner.lfsCommands == ["version"])
        #expect(try SelectedIndexSnapshot.read(location: fixture.service.location) == beforeIndex)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.service.location.gitDirectory.appending(path: "hooks/pre-push").path))
    }

    @Test(.timeLimit(.minutes(1))) func lfsRuleRefusesChangedAttributeSourcesAndPreservesInputs() async throws
    {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file.bin", "file\n")
        _ = try await fixture.commit()
        let plan = try await fixture.service.prepareLFSRule(pattern: "*.bin", action: .track)
        try fixture.write(".gitattributes", "# external edit\n")
        await #expect(throws: ModelFailure.self) { try await fixture.service.executeLFSRule(plan) }
        #expect(
            try String(contentsOf: fixture.root.appending(path: ".gitattributes"), encoding: .utf8)
                == "# external edit\n")
    }

    @Test(.timeLimit(.minutes(1))) func lfsUntrackKeepsOtherAttributesAndDoesNotStageOrHydrateFiles()
        async throws
    {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write(
            ".gitattributes", "# comment\r\n*.bin filter=lfs diff=lfs merge=lfs -text custom=keep\r\n")
        try fixture.write("file.bin", "original payload\n")
        // Use raw plumbing because tool/filter availability is deliberately independent of rule editing.
        _ = try await fixture.engine.run(["add", "--", ".gitattributes"], in: fixture.root)
        let beforeIndex = try SelectedIndexSnapshot.read(location: fixture.service.location)
        let plan = try await fixture.service.prepareLFSRule(pattern: "*.bin", action: .untrack)
        _ = try await fixture.service.executeLFSRule(plan)
        #expect(try SelectedIndexSnapshot.read(location: fixture.service.location) == beforeIndex)
        #expect(
            try String(contentsOf: fixture.root.appending(path: "file.bin"), encoding: .utf8)
                == "original payload\n")
        #expect(plan.after.contains("custom=keep") && plan.after.contains("-text"))
    }

    private func child() async throws -> Fixture {
        let fixture = try await Fixture.create()
        try fixture.write("child", "child original\n")
        _ = try await fixture.commit()
        return fixture
    }

    @Test(.timeLimit(.minutes(1))) func addPinsObjectAndPreservesUnrelatedIndexAndWorkFiles() async throws {
        let fixture = try await Fixture.create()
        let source = try await child()
        defer {
            fixture.remove()
            source.remove()
        }
        try fixture.write("parent", "parent original\n")
        _ = try await fixture.commit()
        try fixture.write("parent", "draft remains\n")
        let head = try await fixture.service.head()
        let plan = try await fixture.service.prepareSubmoduleChange(
            operation: .add, path: "空间,[*]\nchild", source: source.root.path)
        let receipt = try await fixture.service.executeSubmoduleChange(plan)
        #expect(receipt.phase == .completed && receipt.childInstalled && receipt.indexWritten)
        #expect(try await fixture.service.head() == head)
        #expect(
            try String(contentsOf: fixture.root.appending(path: "parent"), encoding: .utf8)
                == "draft remains\n")
        #expect(try await fixture.service.submodules().first?.indexOID == plan.targetOID)
    }

    @Test(.timeLimit(.minutes(1))) func removalPreviewsAndRetainsDirtyIgnoredUntrackedAndIndependentChild()
        async throws
    {
        let fixture = try await Fixture.create()
        let source = try await child()
        defer {
            fixture.remove()
            source.remove()
        }
        try fixture.write("parent", "parent\n")
        _ = try await fixture.commit()
        let add = try await fixture.service.prepareSubmoduleChange(
            operation: .add, path: "child", source: source.root.path)
        _ = try await fixture.service.executeSubmoduleChange(add)
        let childURL = fixture.root.appending(path: "child")
        _ = try await fixture.engine.run(["config", "user.name", "Tests"], in: childURL)
        _ = try await fixture.engine.run(["config", "user.email", "tests@example.invalid"], in: childURL)
        try Data("later\n".utf8).write(to: childURL.appending(path: "later"))
        _ = try await fixture.engine.run(["add", "later"], in: childURL)
        _ = try await fixture.engine.run(["commit", "-m", "Independent"], in: childURL)
        try Data("dirty\n".utf8).write(to: childURL.appending(path: "child"))
        try Data("*.ignored\n".utf8).write(to: childURL.appending(path: ".gitignore"))
        try Data("keep\n".utf8).write(to: childURL.appending(path: "keep.ignored"))
        let plan = try await fixture.service.prepareSubmoduleChange(operation: .remove, path: "child")
        #expect(plan.retention.dirty && plan.retention.untracked && plan.retention.ignored)
        #expect((plan.retention.independentCommits ?? 0) > 0)
        let receipt = try await fixture.service.executeSubmoduleChange(plan)
        #expect(receipt.phase == .completed)
        #expect(FileManager.default.fileExists(atPath: childURL.appending(path: ".git").path))
        #expect(try String(contentsOf: childURL.appending(path: "keep.ignored"), encoding: .utf8) == "keep\n")
    }

    @Test(.timeLimit(.minutes(1))) func changedURLAndOccupiedDestinationRefuseBeforeWriting() async throws {
        let fixture = try await Fixture.create()
        let source = try await child()
        defer {
            fixture.remove()
            source.remove()
        }
        let add = try await fixture.service.prepareSubmoduleChange(
            operation: .add, path: "child", source: source.root.path)
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "child"), withIntermediateDirectories: false)
        try fixture.write("child/foreign", "keep\n")
        await #expect(throws: ModelFailure.self) { try await fixture.service.executeSubmoduleChange(add) }
        #expect(try await fixture.service.submodules().isEmpty)
        #expect(
            try String(contentsOf: fixture.root.appending(path: "child/foreign"), encoding: .utf8) == "keep\n"
        )
    }

    @Test(.timeLimit(.minutes(1))) func lockedChildRemainsPreviewableAndCannotBeRemoved() async throws {
        let fixture = try await Fixture.create()
        let source = try await child()
        defer {
            fixture.remove()
            source.remove()
        }
        let add = try await fixture.service.prepareSubmoduleChange(
            operation: .add, path: "child", source: source.root.path)
        _ = try await fixture.service.executeSubmoduleChange(add)
        let childURL = fixture.root.appending(path: "child")
        try Data().write(to: childURL.appending(path: ".git/index.lock"))
        let remove = try await fixture.service.prepareSubmoduleChange(operation: .remove, path: "child")
        #expect(!remove.retention.locks.isEmpty)
        await #expect(throws: ModelFailure.self) { try await fixture.service.executeSubmoduleChange(remove) }
        #expect(FileManager.default.fileExists(atPath: childURL.appending(path: ".git/index.lock").path))
    }

    @Test(.timeLimit(.minutes(1))) func sourceChangePreservesRawCommentsIndexAndChildRemote() async throws {
        let fixture = try await Fixture.create()
        let source = try await child()
        defer {
            fixture.remove()
            source.remove()
        }
        let add = try await fixture.service.prepareSubmoduleChange(
            operation: .add, path: "child", source: source.root.path)
        _ = try await fixture.service.executeSubmoduleChange(add)
        _ = try await fixture.engine.run(
            ["config", "submodule.child.url", source.root.path], in: fixture.root)
        try fixture.write(
            ".gitmodules",
            "# retain\r\n[submodule \"child\"] # header\r\n path = child\r\n url = \"" + source.root.path
                + "\" # URL\r\n branch = main\r\n")
        let beforeIndex = try SelectedIndexSnapshot.read(location: fixture.service.location)
        let plan = try await fixture.service.prepareSubmoduleChange(
            operation: .changeSource, path: "child", source: "https://example.invalid/changed.git")
        _ = try await fixture.service.executeSubmoduleChange(plan)
        #expect(try SelectedIndexSnapshot.read(location: fixture.service.location) == beforeIndex)
        #expect(
            plan.gitmodulesPreview.contains("# header\r\n")
                && plan.gitmodulesPreview.contains("# URL\r\n branch = main\r\n"))
        #expect(
            try await fixture.engine.run(["config", "--get", "submodule.child.url"], in: fixture.root).text
                .removingLastNewline == "https://example.invalid/changed.git")
        #expect(
            try await fixture.engine.run(
                ["config", "--get", "remote.origin.url"], in: fixture.root.appending(path: "child")
            ).text.removingLastNewline == source.root.path)
    }

    @Test(.timeLimit(.minutes(1))) func sourceChangeRefusesExternalURLChange() async throws {
        let fixture = try await Fixture.create()
        let source = try await child()
        defer {
            fixture.remove()
            source.remove()
        }
        let add = try await fixture.service.prepareSubmoduleChange(
            operation: .add, path: "child", source: source.root.path)
        _ = try await fixture.service.executeSubmoduleChange(add)
        let plan = try await fixture.service.prepareSubmoduleChange(
            operation: .changeSource, path: "child", source: "https://example.invalid/changed.git")
        _ = try await fixture.engine.run(
            [
                "config", "--file", ".gitmodules", "submodule.child.url",
                "https://example.invalid/external.git",
            ], in: fixture.root)
        await #expect(throws: ModelFailure.self) { try await fixture.service.executeSubmoduleChange(plan) }
        #expect(
            try await fixture.engine.run(
                ["config", "--file", ".gitmodules", "--get", "submodule.child.url"], in: fixture.root
            ).text.removingLastNewline == "https://example.invalid/external.git")
    }

    @Test(.timeLimit(.minutes(1)))
    func optionalChildSourceSyncBacksUpConfigAndPreservesChildIndexFilesAndHead() async throws {
        let fixture = try await Fixture.create()
        let source = try await child()
        defer {
            fixture.remove()
            source.remove()
        }
        let add = try await fixture.service.prepareSubmoduleChange(
            operation: .add, path: "child", source: source.root.path)
        _ = try await fixture.service.executeSubmoduleChange(add)
        let childURL = fixture.root.appending(path: "child")
        let location = try await RepositoryService.discover(childURL, engine: fixture.engine)
        let index = try SelectedIndexSnapshot.read(location: location)
        let oldHead = try await fixture.engine.run(["rev-parse", "HEAD"], in: childURL).text
        let oldConfig = try Data(contentsOf: location.commonDirectory.appending(path: "config"))
        try Data("child draft\n".utf8).write(to: childURL.appending(path: "child"))
        let plan = try await fixture.service.prepareSubmoduleChange(
            operation: .changeSource, path: "child",
            source: "https://example.invalid/new.git", synchronizeChildRemote: true)
        #expect(plan.childRemoteSource == source.root.path)
        let receipt = try await fixture.service.executeSubmoduleChange(plan)
        #expect(receipt.childConfigurationWritten && receipt.childRemoteSyncRequested)
        #expect(try Data(contentsOf: #require(receipt.retainedChildConfiguration)) == oldConfig)
        #expect(try SelectedIndexSnapshot.read(location: location) == index)
        #expect(try await fixture.engine.run(["rev-parse", "HEAD"], in: childURL).text == oldHead)
        #expect(try String(contentsOf: childURL.appending(path: "child"), encoding: .utf8) == "child draft\n")
        #expect(
            try await fixture.engine.run(["config", "--get", "remote.origin.url"], in: childURL).text
                .removingLastNewline == "https://example.invalid/new.git")
        #expect(
            try await fixture.service.submoduleChangeReceipts().contains {
                $0.id == receipt.id && $0.phase == .completed
            })
    }

    @Test(.timeLimit(.minutes(1))) func optionalChildSyncRefusesMultipleURLsWithoutWriting() async throws {
        let fixture = try await Fixture.create()
        let source = try await child()
        defer {
            fixture.remove()
            source.remove()
        }
        let add = try await fixture.service.prepareSubmoduleChange(
            operation: .add, path: "child", source: source.root.path)
        _ = try await fixture.service.executeSubmoduleChange(add)
        let childURL = fixture.root.appending(path: "child")
        _ = try await fixture.engine.run(
            ["config", "--add", "remote.origin.url", "https://example.invalid/second.git"], in: childURL)
        let old = try Data(contentsOf: childURL.appending(path: ".git/config"))
        await #expect(throws: ModelFailure.self) {
            try await fixture.service.prepareSubmoduleChange(
                operation: .changeSource, path: "child",
                source: "https://example.invalid/new.git", synchronizeChildRemote: true)
        }
        #expect(try Data(contentsOf: childURL.appending(path: ".git/config")) == old)
    }

    @Test(.timeLimit(.minutes(1))) func literalOptionLikePathAndDottedModuleNameRemainDistinct() async throws
    {
        let fixture = try await Fixture.create()
        let source = try await child()
        defer {
            fixture.remove()
            source.remove()
        }
        let path = "--module[*]"
        let add = try await fixture.service.prepareSubmoduleChange(
            operation: .add, path: path,
            source: source.root.path, name: ".child..component.")
        _ = try await fixture.service.executeSubmoduleChange(add)
        let change = try await fixture.service.prepareSubmoduleChange(
            operation: .changeSource, path: path,
            source: "https://example.invalid/changed.git")
        #expect(change.name == ".child..component.")
        _ = try await fixture.service.executeSubmoduleChange(change)
        let remove = try await fixture.service.prepareSubmoduleChange(operation: .remove, path: path)
        #expect(remove.name == ".child..component.")
        _ = try await fixture.service.executeSubmoduleChange(remove)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: path + "/.git").path))
    }
}
