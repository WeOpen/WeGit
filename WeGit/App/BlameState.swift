import Foundation
import Observation
import WeGitCore

@Observable @MainActor final class BlameState {
    private let service: RepositoryService
    let selection = DiffTextSelection()
    private(set) var document: BlameDocument?
    private(set) var page: BlamePage?
    private(set) var loading = false
    private(set) var cancelled = false
    private(set) var error: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var requestedLine = 1

    init(service: RepositoryService) { self.service = service }

    func open(path: String, revision: String) async {
        cancel()
        document = nil
        page = nil
        selection.replace([:])
        requestedLine = 1
        error = nil
        loading = true
        let token = generation
        let work = Task {
            defer { if generation == token { loading = false } }
            do {
                let document = try await service.blameDocument(path: path, revision: revision)
                let page = try await service.blamePage(document)
                guard !Task.isCancelled, token == generation, page.documentID == document.id else { return }
                self.document = document
                self.page = page
                syncSelection(page, document: document)
            } catch {
                if !Task.isCancelled, token == generation { self.error = error.localizedDescription }
            }
        }
        task = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func loadPage(firstLine: Int) {
        guard let document else { return }
        cancel()
        requestedLine = firstLine
        loading = true
        error = nil
        let token = generation
        task = Task {
            defer { if generation == token { loading = false } }
            do {
                let page = try await service.blamePage(document, firstLine: firstLine)
                guard !Task.isCancelled, token == generation, self.document?.id == page.documentID else {
                    return
                }
                self.page = page
                syncSelection(page, document: document)
            } catch {
                if !Task.isCancelled, token == generation { self.error = error.localizedDescription }
            }
        }
    }

    func retryPage() { loadPage(firstLine: requestedLine) }

    private func syncSelection(_ page: BlamePage, document: BlameDocument) {
        selection.replace([
            .unified: page.lines.map { line in
                DiffLine(
                    id: line.number, kind: " ", content: line.content, oldLine: nil, newLine: line.number,
                    hasNewline: line.number < document.lineCount || document.hasFinalNewline)
            }
        ])
    }

    func cancel(userInitiated: Bool = false) {
        generation = UUID()
        task?.cancel()
        task = nil
        loading = false
        cancelled = userInitiated
    }

    func release() {
        cancel()
        document = nil
        page = nil
        selection.replace([:])
    }
}
