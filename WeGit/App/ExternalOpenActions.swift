import AppKit
import Foundation
import UniformTypeIdentifiers
import WeGitCore

extension AppState {
    var xcodeURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") }

    func fileURL(_ path: String, in session: RepositorySession) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
            !path.split(separator: "/").contains("..")
        else { return nil }
        return session.location.root.appending(path: path)
    }

    func canOpenFile(_ path: String, in session: RepositorySession) -> Bool {
        guard let url = fileURL(path, in: session), FileManager.default.fileExists(atPath: url.path),
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        if values.isRegularFile == true { return true }
        if values.isSymbolicLink == true {
            return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true
        }
        return false
    }

    func openFile(_ path: String, in session: RepositorySession, withXcode: Bool = false) {
        guard self.session === session else { return }
        do {
            try session.location.validateIdentity()
            guard canOpenFile(path, in: session), let file = fileURL(path, in: session) else {
                throw ModelFailure.unsupported("文件不存在或不是可以打开的普通文件。")
            }
            let application =
                withXcode
                ? xcodeURL : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            guard let application else { throw ModelFailure.unsupported("找不到相应编辑器，请在 Finder 中选择打开方式。") }
            NSWorkspace.shared.open(
                [file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error { Task { @MainActor in session.show(error) } }
            }
        } catch { session.show(error) }
    }

    func revealFile(_ path: String, in session: RepositorySession) {
        do {
            try session.location.validateIdentity()
            guard var file = fileURL(path, in: session) else { throw ModelFailure.invalidPath }
            while !FileManager.default.fileExists(atPath: file.path), file != session.location.root {
                file.deleteLastPathComponent()
            }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch { session.show(error) }
    }

    func copyFilePath(_ path: String, in session: RepositorySession, absolute: Bool) {
        guard let file = fileURL(path, in: session) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(absolute ? file.path : path, forType: .string)
    }

    func openRepositoryInXcode() {
        guard let session else { return }
        openRepositoryInXcode(at: session.location.root)
    }

    func openRepositoryInXcode(at root: URL) {
        guard let xcode = xcodeURL else { return }
        let pinned = session?.location.root == root ? session?.location : nil
        Task {
            do {
                let location: RepositoryLocation
                if let pinned {
                    try pinned.validateIdentity()
                    location = pinned
                } else {
                    location = try await RepositoryService.discover(root, engine: engine)
                }
                let projects = try await Self.xcodeProjects(in: location)
                var selected: URL?
                if projects.count == 1 {
                    selected = projects[0]
                } else {
                    let panel = NSOpenPanel()
                    panel.directoryURL = location.root
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = [
                        UTType(filenameExtension: "xcodeproj"), UTType(filenameExtension: "xcworkspace"),
                        .swiftSource,
                    ].compactMap { $0 }
                    panel.message = "选择此仓库的 Xcode 工程、工作区或 Package.swift"
                    if panel.runModal() == .OK { selected = panel.url }
                }
                guard let selected else { return }
                try location.validateIdentity()
                NSWorkspace.shared.open(
                    [selected], withApplicationAt: xcode, configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error { Task { @MainActor in self.error = error.localizedDescription } }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    @concurrent private static func xcodeProjects(in location: RepositoryLocation) async throws -> [URL] {
        try location.validateIdentity()
        return try FileManager.default.contentsOfDirectory(
            at: location.root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        .filter {
            ["xcodeproj", "xcworkspace"].contains($0.pathExtension) || $0.lastPathComponent == "Package.swift"
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
