import Testing

@testable import WeGitCore

struct ChangeFilterTests {
    @Test func statusFilteringMatchesTheDisplayedLayerAndCountsEachPathOnce() {
        let dual = FileChange(
            path: "src/Code.swift", oldPath: nil, index: "A", worktree: "M", conflict: false, untracked: false
        )
        let modified = ChangeFilter(query: "code", kind: .modified)
        #expect(!modified.matches(dual, layer: .staged))
        #expect(modified.matches(dual, layer: .unstaged))
        #expect(modified.visiblePathCount([dual]) == 1)
        #expect(ChangeFilter().visiblePathCount([dual, dual]) == 1)
        #expect(ChangeFilter(kind: .added).matches(dual, layer: .staged))
        #expect(!ChangeFilter(query: "other").matches(dual, layer: .unstaged))
    }

    @Test func conflictAndUntrackedStatesRemainDistinctFromAddedFiles() {
        let conflict = FileChange(
            path: "conflict", oldPath: nil, index: "U", worktree: "U", conflict: true, untracked: false)
        let untracked = FileChange(
            path: "new", oldPath: nil, index: "?", worktree: "?", conflict: false, untracked: true)
        #expect(ChangeFilter(kind: .conflicts).matches(conflict, layer: .conflict))
        #expect(!ChangeFilter(kind: .conflicts).matches(conflict, layer: .staged))
        #expect(ChangeFilter(kind: .untracked).matches(untracked, layer: .untracked))
        #expect(!ChangeFilter(kind: .added).matches(untracked, layer: .untracked))
        let copy = FileChange(
            path: "copy", oldPath: "source", index: "C", worktree: ".", conflict: false, untracked: false)
        #expect(ChangeFilter(kind: .copied).matches(copy, layer: .staged))
        #expect(!ChangeFilter(kind: .conflicts).matches(copy, layer: .staged))
    }
}
