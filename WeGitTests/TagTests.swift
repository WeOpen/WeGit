import Foundation
import Testing

@testable import WeGitCore

struct TagTests {
    @Test func exactObjectsAnnotationsAndLiteralSearch() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("a", "base\n")
        let head = try await f.commit()
        let message = "Release\n\n# 用户标题\n正文\n"
        let plan = try await f.service.prepareTagCreation(
            name: "发布/v1.1", target: head, kind: .annotated, message: message, expectedHead: head)
        let tag = try await f.service.createTag(plan)
        #expect(tag.annotated && tag.objectID != head && tag.targetCommit == head)
        #expect(try await f.service.tagMessage(tag) == message)
        #expect(try await f.service.tags(query: "发布/").entries == [tag])
        #expect(try await f.service.tags(query: "*").entries.isEmpty)
        let sameName = try await f.service.prepareTagCreation(
            name: "main", target: head, kind: .lightweight, expectedHead: head)
        let lightweight = try await f.service.createTag(sameName)
        try await f.service.deleteTag(lightweight, expectedHead: head)
        #expect(try await f.service.head() == head)
        #expect(try await f.service.tags().entries == [tag])
    }

    @Test func staleTagAndConfigCannotBeOverwritten() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("a", "base\n")
        let first = try await f.commit()
        let plan = try await f.service.prepareTagCreation(
            name: "v1", target: first, kind: .lightweight, expectedHead: first)
        let tag = try await f.service.createTag(plan)
        try f.write("a", "next\n")
        let next = try await f.commit("Next")
        _ = try await f.engine.run(["update-ref", tag.reference, next], in: f.root)
        do {
            try await f.service.deleteTag(tag, expectedHead: next)
            Issue.record("External tag movement must reject the old object")
        } catch ModelFailure.changed {}
        let current = try await f.service.tags().entries.first
        #expect(current?.objectID == next)
        let pending = try await f.service.prepareTagCreation(
            name: "v2", target: first, kind: .lightweight, expectedHead: next)
        _ = try await f.engine.run(["config", "tag.gpgSign", "true"], in: f.root)
        do {
            _ = try await f.service.createTag(pending)
            Issue.record("Signing configuration changed after preview")
        } catch ModelFailure.changed {}
        #expect(try await f.service.tags().entries.count == 1)
    }

    @Test func danglingAndOrdinarySymbolicTagsAreProtected() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("a", "base\n")
        let head = try await f.commit()
        _ = try await f.engine.run(["symbolic-ref", "refs/tags/dangling", "refs/heads/missing"], in: f.root)
        do {
            _ = try await f.service.prepareTagCreation(
                name: "dangling", target: head, kind: .lightweight, expectedHead: head)
            Issue.record("Dangling alias is an existing name")
        } catch ModelFailure.changed {}
        _ = try await f.engine.run(["symbolic-ref", "refs/tags/alias", "refs/heads/main"], in: f.root)
        let tag = try #require(await f.service.tags(query: "alias").entries.first)
        do {
            try await f.service.deleteTag(tag, expectedHead: head)
            Issue.record("Symbolic tag must not dereference its branch")
        } catch ModelFailure.unsupported {}
        #expect(try await f.service.head() == head)
    }

    @Test func pushPublishesOneRawObjectAndRefusesDifferentAnnotationAtSameCommit() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("a", "base\n")
        let head = try await f.commit()
        let bare = f.root.appending(path: ".git/remote.git")
        _ = try await f.engine.run(["init", "--bare", bare.path], in: f.root)
        _ = try await f.engine.run(["remote", "add", "origin", bare.path], in: f.root)
        _ = try await f.engine.run(["config", "push.followTags", "true"], in: f.root)
        _ = try await f.engine.run(["config", "remote.origin.mirror", "true"], in: f.root)
        let creation = try await f.service.prepareTagCreation(
            name: "selected", target: head, kind: .annotated, message: "Selected", expectedHead: head)
        let selected = try await f.service.createTag(creation)
        let otherPlan = try await f.service.prepareTagCreation(
            name: "other", target: head, kind: .annotated, message: "Other", expectedHead: head)
        let other = try await f.service.createTag(otherPlan)
        let push = try await f.service.prepareTagPush(selected, remote: "origin", expectedHead: head)
        _ = try await f.service.pushTag(push)
        let remoteTags = try await f.engine.run(
            ["for-each-ref", "--format=%(objectname)", "refs/tags/"], in: bare
        ).text
        #expect(remoteTags == selected.objectID + "\n")
        _ = try await f.engine.run(["fetch", "--no-tags", "--", f.root.path, other.reference], in: bare)
        _ = try await f.engine.run(["update-ref", selected.reference, other.objectID], in: bare)
        do {
            _ = try await f.service.prepareTagPush(selected, remote: "origin", expectedHead: head)
            Issue.record("Two annotations at one commit are different tag objects")
        } catch ModelFailure.unsupported {}
        #expect(try await f.service.verifyTagPush(push) == .different)
    }
}
