import Foundation

extension RepositoryService {
    private static var tagFormat: String {
        "%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00%(symref)%00"
    }

    @concurrent public func tags(query: String = "", limit: Int = 200) async throws -> TagList {
        try location.validateIdentity()
        guard (1...10_000).contains(limit), query.utf8.count <= 1024 else { throw ModelFailure.invalidPath }
        let values = try await readTags(pattern: "refs/tags/")
        let matches = values.filter {
            query.isEmpty || $0.name.range(of: query, options: .caseInsensitive) != nil
        }
        try Task.checkCancellation()
        return TagList(entries: Array(matches.prefix(limit)), hasMore: matches.count > limit)
    }

    private func readTags(pattern: String) async throws -> [GitTag] {
        try location.validateIdentity()
        let raw = try await engine.run(
            ["for-each-ref", "--sort=refname", "--format=" + Self.tagFormat, "--", pattern],
            in: location.root, outputLimit: 32 * 1024 * 1024
        ).stdout
        guard raw.isEmpty || raw.last == 10 else { throw ModelFailure.changed }
        var tags: [GitTag] = []
        for row in raw.split(separator: 10) {
            try Task.checkCancellation()
            let fields = row.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 7, fields.last!.isEmpty,
                let ref = String(data: fields[0], encoding: .utf8), ref.hasPrefix("refs/tags/"),
                let object = String(data: fields[1], encoding: .utf8), GitObjectID.valid(object),
                let type = String(data: fields[2], encoding: .utf8),
                let peeled = String(data: fields[3], encoding: .utf8),
                let peeledType = String(data: fields[4], encoding: .utf8),
                let symbolic = String(data: fields[5], encoding: .utf8)
            else { throw ModelFailure.changed }
            var target = type == "commit" ? object : peeledType == "commit" ? peeled : nil
            if type == "tag", peeledType == "tag" {
                let resolved = try await engine.run(
                    ["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"],
                    in: location.root, accepted: [0, 128])
                if resolved.exitCode == 0 { target = resolved.text.removingLastNewline }
            }
            guard target == nil || GitObjectID.valid(target!) else { throw ModelFailure.changed }
            tags.append(
                GitTag(
                    reference: ref, objectID: object, targetCommit: target,
                    annotated: type == "tag", symbolicTarget: symbolic.isEmpty ? nil : symbolic))
        }
        try location.validateIdentity()
        return tags
    }

    @concurrent public func tagMessage(_ tag: GitTag) async throws -> String? {
        guard tag.annotated else { return nil }
        try await verifyTag(tag)
        let bytes = try await engine.run(
            ["cat-file", "tag", tag.objectID], in: location.root, outputLimit: 256 * 1024
        ).stdout
        guard let text = String(data: bytes, encoding: .utf8), let range = text.range(of: "\n\n") else {
            throw ModelFailure.invalidOutput(L10n.text("无法显示此标签的附注内容。"))
        }
        return String(text[range.upperBound...])
    }

    @concurrent public func tagSigningRequired() async throws -> Bool {
        try location.validateIdentity()
        let result = try await engine.run(
            ["config", "--type=bool", "--get", "tag.gpgSign"], in: location.root, accepted: [0, 1])
        return result.exitCode == 0 && result.text.removingLastNewline == "true"
    }

    private func tagConfiguration() async throws -> Data {
        try await engine.run(
            ["config", "--null", "--show-scope", "--show-origin", "--includes", "--list"],
            in: location.root, outputLimit: 8 * 1024 * 1024
        ).stdout
    }

    public func prepareTagCreation(
        name: String, target: String, kind: TagKind, message: String = "", expectedHead: String?
    ) async throws -> TagCreationPlan {
        try await queue.perform {
            try await verifyHead(expectedHead)
            try await validateTagName(name)
            try await verifyCommit(target)
            try await ensureTagAbsent("refs/tags/" + name)
            let configuration = try await tagConfiguration()
            let signing = try await tagSigningRequired()
            guard try await tagConfiguration() == configuration else { throw ModelFailure.changed }
            guard !signing || kind == .annotated else {
                throw ModelFailure.unsupported(L10n.text("当前 Git 签名配置要求创建附注标签。"))
            }
            guard !message.contains("\0"), message.utf8.count <= 64 * 1024,
                kind != .annotated || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ModelFailure.invalidPath }
            return TagCreationPlan(
                name: name, targetCommit: target, kind: kind, message: message,
                signingRequired: signing, head: expectedHead, configuration: configuration, location: location
            )
        }
    }

    public func createTag(_ plan: TagCreationPlan) async throws -> GitTag {
        try await queue.perform {
            guard plan.location == location else { throw ModelFailure.changed }
            try await verifyHead(plan.head)
            try await validateTagName(plan.name)
            try await verifyCommit(plan.targetCommit)
            let reference = "refs/tags/" + plan.name
            try await ensureTagAbsent(reference)
            guard try await tagConfiguration() == plan.configuration else {
                throw ModelFailure.changed
            }
            do {
                if plan.kind == .lightweight {
                    _ = try await engine.run(
                        [
                            "update-ref", "--no-deref", reference, plan.targetCommit,
                            String(repeating: "0", count: plan.targetCommit.count),
                        ], in: location.root)
                } else {
                    _ = try await engine.run(
                        [
                            "tag", "--annotate", "--cleanup=verbatim", "--file", "-", "--", plan.name,
                            plan.targetCommit,
                        ],
                        in: location.root,
                        input: Data(plan.message.utf8), timeout: 120)
                }
            } catch {
                let result = await Task.detached { try await exactTagOID(reference) }.result
                if case .success(.some) = result {
                    throw ModelFailure.unsupported(L10n.text("标签创建结果需要核对，请刷新列表，不要直接重复创建。"))
                }
                throw error
            }
            guard
                let tag = try await readTags(pattern: reference).first(where: { $0.reference == reference }),
                tag.targetCommit == plan.targetCommit, tag.annotated == (plan.kind == .annotated)
            else { throw ModelFailure.changed }
            return tag
        }
    }

    public func deleteTag(_ tag: GitTag, expectedHead: String?) async throws {
        try await queue.perform {
            try await verifyHead(expectedHead)
            try await verifyTag(tag)
            guard tag.symbolicTarget == nil else {
                throw ModelFailure.unsupported(L10n.text("符号引用标签仅供查看，请在 Git 中处理。"))
            }
            do {
                _ = try await engine.run(
                    ["update-ref", "--no-deref", "-d", tag.reference, tag.objectID], in: location.root)
            } catch {
                let probe = Task.detached { try await exactTagOID(tag.reference) }
                if case .success(nil) = await probe.result {
                    return
                }
                throw error
            }
            guard try await exactTagOID(tag.reference) == nil else { throw ModelFailure.changed }
        }
    }

    private func validateTagName(_ name: String) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), name.utf8.count <= 1024, !name.contains("\0") else {
            throw ModelFailure.invalidPath
        }
        _ = try await engine.run(["check-ref-format", "refs/tags/" + name], in: location.root)
    }

    private func exactTagOID(_ reference: String) async throws -> String? {
        guard reference.hasPrefix("refs/tags/"), !reference.contains("\0") else {
            throw ModelFailure.invalidPath
        }
        try location.validateIdentity()
        let value = try await engine.run(
            ["rev-parse", "--verify", "--end-of-options", reference], in: location.root, accepted: [0, 128])
        guard value.exitCode == 0 else { return nil }
        let object = value.text.removingLastNewline
        guard GitObjectID.valid(object) else { throw ModelFailure.changed }
        return object
    }

    private func ensureTagAbsent(_ reference: String) async throws {
        guard try await exactTagOID(reference) == nil else { throw ModelFailure.changed }
        let symbolic = try await engine.run(
            ["symbolic-ref", "--quiet", reference], in: location.root, accepted: [0, 1])
        guard symbolic.exitCode == 1 else { throw ModelFailure.changed }
    }

    private func verifyTag(_ tag: GitTag) async throws {
        try await validateTagName(tag.name)
        guard try await readTags(pattern: tag.reference).contains(tag) else { throw ModelFailure.changed }
    }

    public func prepareTagPush(
        _ tag: GitTag, remote name: String, pushURLIndex: Int = 0, expectedHead: String?
    ) async throws -> TagPushPlan {
        try await queue.perform {
            try await verifyHead(expectedHead)
            try await verifyTag(tag)
            guard tag.targetCommit != nil, tag.symbolicTarget == nil else {
                throw ModelFailure.unsupported(L10n.text("只能推送明确指向提交的普通标签。"))
            }
            let remote = try await remoteDetails(name: name)
            guard remote.pushURLs.indices.contains(pushURLIndex) else { throw ModelFailure.invalidPath }
            let current = try await remoteTagOID(remote, index: pushURLIndex, reference: tag.reference)
            guard current == nil || current == tag.objectID else {
                throw ModelFailure.unsupported(L10n.text("远端同名标签指向其他对象，未执行推送。"))
            }
            return TagPushPlan(
                tag: tag, remote: remote, pushURLIndex: pushURLIndex,
                expectedRemoteObject: current, head: expectedHead, location: location)
        }
    }

    public func pushTag(_ plan: TagPushPlan) async throws -> TagPushResult {
        try await queue.perform {
            guard plan.location == location else { throw ModelFailure.changed }
            try await verifyHead(plan.head)
            try await verifyTag(plan.tag)
            try await verifyRemote(plan.remote)
            let current = try await remoteTagOID(
                plan.remote, index: plan.pushURLIndex, reference: plan.tag.reference)
            if current == plan.tag.objectID { return .alreadyPresent }
            guard current == nil, current == plan.expectedRemoteObject else { throw ModelFailure.changed }
            let refspec = plan.tag.objectID + ":" + plan.tag.reference
            let configuration =
                try pinnedRemote(plan.remote, pushIndex: plan.pushURLIndex)
                + [("push.followTags", "false"), ("remote.\(plan.remote.name).mirror", "false")]
            var replied = false
            do {
                _ = try await engine.run(
                    ["push", "--porcelain", "--recurse-submodules=no", "--", plan.remote.name, refspec],
                    in: location.root, timeout: 300, configuration: configuration)
                replied = true
                guard
                    try await remoteTagOID(
                        plan.remote, index: plan.pushURLIndex, reference: plan.tag.reference)
                        == plan.tag.objectID
                else {
                    throw ModelFailure.changed
                }
            } catch {
                if !replied, case ProcessFailure.launch = error { throw error }
                if !replied, let error = error as? GitFailure, error.rejectedPushRefspec == refspec {
                    throw error
                }
                throw TagPushOutcomeUnknown(
                    plan: plan,
                    details: Redaction.text((error as? GitFailure)?.details ?? error.localizedDescription))
            }
            return .pushed
        }
    }

    public func verifyTagPush(_ plan: TagPushPlan) async throws -> TagPushVerification {
        try await queue.perform {
            guard plan.location == location else { throw ModelFailure.changed }
            try await verifyRemote(plan.remote)
            let current = try await remoteTagOID(
                plan.remote, index: plan.pushURLIndex, reference: plan.tag.reference)
            if current == nil { return .absent }
            return current == plan.tag.objectID ? .matches : .different
        }
    }

    private func remoteTagOID(_ remote: GitRemote, index: Int, reference: String) async throws -> String? {
        guard remote.pushURLs.indices.contains(index) else { throw ModelFailure.invalidPath }
        let bytes = try await engine.run(
            ["ls-remote", "--tags", "--refs", "--", remote.name, reference], in: location.root,
            timeout: 120, outputLimit: 64 * 1024, configuration: pinnedRemote(remote, pushIndex: index)
        ).stdout
        guard bytes.isEmpty || bytes.last == 10 else { throw ModelFailure.changed }
        let rows = bytes.split(separator: 10)
        guard rows.count <= 1 else { throw ModelFailure.changed }
        guard let row = rows.first else { return nil }
        let fields = row.split(separator: 9)
        guard fields.count == 2, String(decoding: fields[1], as: UTF8.self) == reference,
            let object = String(data: fields[0], encoding: .utf8), GitObjectID.valid(object)
        else { throw ModelFailure.changed }
        return object
    }
}
