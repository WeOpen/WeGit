import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func worktrees() async throws -> [GitWorktree] {
        try await sharedQueue.perform { try WorktreeParser.parse(await worktreeListBytes()) }
    }

    private func worktreeListBytes() async throws -> Data {
        try location.validateIdentity()
        return try await engine.run(
            ["worktree", "list", "--porcelain", "-z"], in: location.root,
            outputLimit: 4 * 1024 * 1024
        ).stdout
    }

    @concurrent public func prepareWorktreeCreation(at proposed: URL, kind: WorktreeCreationKind)
        async throws -> WorktreeCreationPlan
    {
        try await withSharedOperation {
            let state = try await status()
            guard state.sequencer == .none, let head = state.head else {
                throw ModelFailure.unsupported(L10n.text("创建工作树需要现有提交且没有进行中的 Git 操作。"))
            }
            let list = try await worktreeListBytes()
            let trees = try WorktreeParser.parse(list)
            guard trees.count < 256 else { throw ModelFailure.unsupported(L10n.text("工作树列表超出读取上限。")) }
            let destination = try worktreeDestination(proposed, trees: trees)
            let target = try await worktreeCreationTarget(kind, current: head, trees: trees)
            let modes = try await engine.run(
                ["ls-tree", "-r", "--format=%(objectmode)", target], in: location.root,
                outputLimit: 4 * 1024 * 1024
            ).text
            guard !modes.components(separatedBy: "\n").contains("160000") else {
                throw ModelFailure.unsupported(L10n.text("此入口暂不移动含子模块的工作树。"))
            }
            return WorktreeCreationPlan(
                destination: destination, kind: kind, target: target, location: location,
                head: head, list: list,
                parentIdentity: try RepositoryNodeIdentity.read(
                    destination.deletingLastPathComponent(), directory: true))
        }
    }

    private func worktreeDestination(_ value: URL, trees: [GitWorktree]) throws -> URL {
        guard value.isFileURL, value.path.hasPrefix("/"), !value.path.contains("\0"),
            !value.path.split(separator: "/").contains(".."), !value.lastPathComponent.isEmpty
        else {
            throw ModelFailure.invalidPath
        }
        let parent = value.deletingLastPathComponent().resolvingSymlinksInPath()
        _ = try RepositoryNodeIdentity.read(parent, directory: true)
        let destination = parent.appending(path: value.lastPathComponent, directoryHint: .isDirectory)
        guard try RepositoryNodeIdentity.readIfPresent(destination) == nil else {
            throw ModelFailure.unsupported(L10n.text("工作树目标必须是尚不存在的目录。"))
        }
        let protected = trees.map { $0.url.resolvingSymlinksInPath().path } + [location.commonDirectory.path]
        guard !protected.contains(where: { destination.path == $0 || destination.path.hasPrefix($0 + "/") })
        else {
            throw ModelFailure.unsupported(L10n.text("工作树目录不能嵌套在仓库或 Git 数据目录中。"))
        }
        return destination
    }

    private func worktreeCreationTarget(_ kind: WorktreeCreationKind, current: String, trees: [GitWorktree])
        async throws -> String
    {
        guard let name = kind.branch else { return current }
        _ = try await engine.run(["check-ref-format", "--branch", name], in: location.root)
        let ref = "refs/heads/" + name
        let result = try await engine.run(
            ["rev-parse", "--verify", ref + "^{commit}"], in: location.root, accepted: [0, 128])
        switch kind {
        case .newBranch:
            guard result.exitCode != 0 else { throw ModelFailure.unsupported(L10n.text("同名分支已存在。")) }
            return current
        case .existingBranch:
            guard result.exitCode == 0, !trees.contains(where: { $0.branch == ref }) else {
                throw ModelFailure.unsupported(L10n.text("分支不存在或已被其他工作树使用。"))
            }
            return result.text.removingLastNewline
        case .detached: return current
        }
    }

    @concurrent public func executeWorktreeCreation(_ plan: WorktreeCreationPlan) async throws
        -> WorktreeCreationReceipt
    {
        try await withSharedOperation {
            guard location == plan.location else { throw ModelFailure.changed }
            try await verifyHead(plan.head)
            let list = try await worktreeListBytes()
            guard list == plan.list else { throw ModelFailure.changed }
            let trees = try WorktreeParser.parse(list)
            guard try worktreeDestination(plan.destination, trees: trees) == plan.destination,
                try RepositoryNodeIdentity.read(plan.destination.deletingLastPathComponent(), directory: true)
                    == plan.parentIdentity,
                try await worktreeCreationTarget(plan.kind, current: plan.head, trees: trees) == plan.target
            else {
                throw ModelFailure.changed
            }
            let saved = try WorktreePreservationDirectory(
                parent: plan.destination.deletingLastPathComponent())
            var checkoutFD: Int32 = -1
            defer { if checkoutFD >= 0 { Darwin.close(checkoutFD) } }
            var args = ["worktree", "add", "--no-guess-remote"]
            switch plan.kind {
            case .newBranch(let name): args += ["-b", name, saved.checkout.path, plan.target]
            case .existingBranch(let name): args += [saved.checkout.path, name]
            case .detached: args += ["--detach", saved.checkout.path, plan.target]
            }
            do {
                try saved.validate()
                _ = try await engine.run(args, in: location.root, timeout: 180)
                let created = try await verifiedCreatedWorktree(saved.checkout, plan: plan)
                checkoutFD = try WorktreePreservationDirectory.pin(created)
                try saved.validate()
                guard
                    try RepositoryNodeIdentity.read(
                        plan.destination.deletingLastPathComponent(), directory: true) == plan.parentIdentity,
                    try RepositoryNodeIdentity.readIfPresent(plan.destination) == nil
                else { throw ModelFailure.changed }
                _ = try await engine.run(
                    ["worktree", "move", created.root.path, plan.destination.path], in: location.root)
                let final = try await verifiedCreatedWorktree(plan.destination, plan: plan)
                return WorktreeCreationReceipt(location: final)
            } catch {
                let preserved =
                    checkoutFD >= 0
                    ? WorktreePreservationDirectory.path(for: checkoutFD, fallback: saved.recoveryURL)
                    : saved.recoveryURL
                throw WorktreeOutcomeUnknown(
                    preservedDirectory: preserved, details: error.localizedDescription)
            }
        }
    }

    private func verifiedCreatedWorktree(_ url: URL, plan: WorktreeCreationPlan) async throws
        -> RepositoryLocation
    {
        let target = try await Self.discover(url, engine: engine)
        guard target.commonIdentity == location.commonIdentity else { throw ModelFailure.changed }
        let service = RepositoryService(location: target, engine: engine)
        let state = try await service.status()
        guard state.head == plan.target, state.files.isEmpty, state.sequencer == .none,
            state.branch == (plan.kind.branch ?? "(detached)")
        else { throw ModelFailure.changed }
        return target
    }

    @concurrent public func prepareWorktreeRemoval(_ value: GitWorktree) async throws -> WorktreeRemovalPlan {
        try await withSharedOperation {
            let list = try await worktreeListBytes()
            let trees = try WorktreeParser.parse(list)
            guard trees.contains(value), !value.primary, !value.bare, value.locked == nil,
                value.prunable == nil
            else {
                throw ModelFailure.unsupported(L10n.text("主工作树、锁定或陈旧登记不能从此入口移除。"))
            }
            let target = try await Self.discover(value.url, engine: engine)
            guard target.commonIdentity == location.commonIdentity, target.gitIdentity != location.gitIdentity
            else {
                throw ModelFailure.unsupported(L10n.text("不能移除当前工作树。"))
            }
            let other = trees.filter { $0.id != value.id }.map { $0.url.resolvingSymlinksInPath().path }
            guard
                !other.contains(where: {
                    target.root.path.hasPrefix($0 + "/") || $0.hasPrefix(target.root.path + "/")
                })
            else {
                throw ModelFailure.unsupported(L10n.text("工作树目录不能嵌套在仓库或 Git 数据目录中。"))
            }
            let service = RepositoryService(location: target, engine: engine)
            return try await service.queue.perform {
                try await validateRemovableWorktree(value, service: service)
                return WorktreeRemovalPlan(
                    worktree: value, location: location, targetLocation: target,
                    head: try await head(), list: list, index: try worktreeIndex(target))
            }
        }
    }

    private func validateRemovableWorktree(_ value: GitWorktree, service: RepositoryService) async throws {
        let state = try await service.status()
        guard state.head == value.head, state.branch == (value.branchName ?? "(detached)"),
            state.files.isEmpty, state.sequencer == .none
        else {
            throw ModelFailure.unsupported(L10n.text("工作树有未保存内容或进行中的操作，请先处理。"))
        }
        let entries = try await engine.run(
            ["ls-files", "-v", "--stage", "-z"], in: service.location.root, outputLimit: 4 * 1024 * 1024
        ).stdout
        guard
            entries.split(separator: 0).allSatisfy({
                $0.first == 72 && !String(decoding: $0, as: UTF8.self).hasPrefix("H 160000 ")
            })
        else {
            throw ModelFailure.unsupported(L10n.text("此工作树包含特殊索引标记或子模块，已停止移除。"))
        }
        if value.branch == nil, let head = value.head {
            let refs = try await engine.run(
                ["for-each-ref", "--contains=" + head, "--count=1", "--format=%(refname)"], in: location.root
            ).stdout
            guard !refs.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("Detached HEAD 含没有引用保护的提交，请先创建分支或标签。"))
            }
        }
    }

    private func worktreeIndex(_ target: RepositoryLocation) throws -> Data? {
        try target.validateIdentity()
        let url = target.gitDirectory.appending(path: "index")
        guard let node = try RepositoryNodeIdentity.readIfPresent(url) else { return nil }
        guard node.kind == UInt16(S_IFREG) else { throw ModelFailure.changed }
        return try Data(contentsOf: url)
    }

    @concurrent public func executeWorktreeRemoval(_ plan: WorktreeRemovalPlan) async throws
        -> WorktreeRemovalReceipt
    {
        try await withSharedOperation {
            guard location == plan.location else { throw ModelFailure.changed }
            let service = RepositoryService(location: plan.targetLocation, engine: engine)
            return try await service.queue.perform {
                try await verifyHead(plan.head)
                guard try await worktreeListBytes() == plan.list,
                    try worktreeIndex(plan.targetLocation) == plan.index
                else { throw ModelFailure.changed }
                try await validateRemovableWorktree(plan.worktree, service: service)
                let saved = try WorktreePreservationDirectory(
                    parent: plan.targetLocation.root.deletingLastPathComponent())
                do {
                    _ = try await engine.run(
                        ["worktree", "move", plan.targetLocation.root.path, saved.checkout.path],
                        in: location.root)
                    let moved = try await Self.discover(saved.checkout, engine: engine)
                    guard moved.rootIdentity == plan.targetLocation.rootIdentity,
                        moved.gitIdentity == plan.targetLocation.gitIdentity
                    else { throw ModelFailure.changed }
                    let registered = try WorktreeParser.parse(await worktreeListBytes()).first {
                        $0.url.path == saved.checkout.path
                    }
                    guard let registered, registered.locked == nil, registered.prunable == nil,
                        registered.head == plan.worktree.head, registered.branch == plan.worktree.branch
                    else { throw ModelFailure.changed }
                    try await validateRemovableWorktree(
                        registered, service: RepositoryService(location: moved, engine: engine))
                    // Retain private index, local config and reflog in addition to all working files.
                    try FileManager.default.copyItem(
                        at: moved.gitDirectory, to: saved.url.appending(path: "git-state"))
                    try saved.preserve(moved)
                    try saved.validateMissingCheckout()
                    _ = try await engine.run(["worktree", "remove", saved.checkout.path], in: location.root)
                    let remaining = try WorktreeParser.parse(await worktreeListBytes())
                    guard !remaining.contains(where: { $0.url.path == saved.checkout.path }),
                        try RepositoryNodeIdentity.read(saved.files, directory: true)
                            == plan.targetLocation.rootIdentity
                    else { throw ModelFailure.changed }
                    return WorktreeRemovalReceipt(preservedDirectory: saved.files)
                } catch {
                    throw WorktreeOutcomeUnknown(
                        preservedDirectory: saved.recoveryURL, details: error.localizedDescription)
                }
            }
        }
    }
}
