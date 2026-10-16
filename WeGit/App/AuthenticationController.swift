import AppKit
import Observation
import SwiftUI
import WeGitCore

@Observable @MainActor
final class AuthenticationController {
    weak var presentationPreferences: AppPreferences?
    private(set) var request: AuthenticationRequest?
    @ObservationIgnored private var waiters: [(AuthenticationRequest, CheckedContinuation<String?, Error>)] =
        []
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var panelDelegate: AuthenticationPanelDelegate?
    @ObservationIgnored private weak var previousWindow: NSWindow?

    func respond(to request: AuthenticationRequest) async throws -> String? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((request, continuation))
                presentNext()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(request.id) }
        }
    }

    func answer(_ value: String?) {
        guard let request, let index = waiters.firstIndex(where: { $0.0.id == request.id }) else { return }
        let continuation = waiters.remove(at: index).1
        self.request = nil
        continuation.resume(returning: value)
        presentNext()
    }

    func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        request = nil
        panel?.orderOut(nil)
        for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0.id == id }) else { return }
        let continuation = waiters.remove(at: index).1
        if request?.id == id { request = nil }
        continuation.resume(throwing: CancellationError())
        presentNext()
    }

    private func presentNext() {
        guard request == nil else { return }
        guard let first = waiters.first else {
            panel?.orderOut(nil)
            if let previousWindow, previousWindow.isVisible { previousWindow.makeKeyAndOrderFront(nil) }
            previousWindow = nil
            return
        }
        if previousWindow == nil { previousWindow = NSApp.keyWindow }
        request = first.0
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = L10n.text("Git 认证")
            panel.isFloatingPanel = true
            panel.worksWhenModal = true
            panel.level = .modalPanel
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            if let preferences = presentationPreferences {
                panel.contentView = NSHostingView(
                    rootView: AuthenticationView(controller: self).workbenchAppearance(preferences))
            } else {
                panel.contentView = NSHostingView(rootView: AuthenticationView(controller: self))
            }
            let delegate = AuthenticationPanelDelegate(controller: self)
            panel.delegate = delegate
            panelDelegate = delegate
            self.panel = panel
            panel.center()
        }
        panel?.appearance = previousWindow?.effectiveAppearance
        panel?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}

@MainActor
private final class AuthenticationPanelDelegate: NSObject, NSWindowDelegate {
    weak var controller: AuthenticationController?
    init(controller: AuthenticationController) { self.controller = controller }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        controller?.answer(nil)
        return false
    }
}
