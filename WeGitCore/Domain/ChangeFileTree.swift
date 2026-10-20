import Foundation

/// A display row retains exact file paths for operations, including renames and
/// filtered descendants. Folder names are never used as Git pathspecs.
public struct ChangeFileTreeRow: Identifiable, Sendable {
    public var id: String { (file == nil ? "folder:" : "file:") + path }
    public let path: String
    public let depth: Int
    public let file: FileChange?
    public let files: [FileChange]
    public var name: String { (path as NSString).lastPathComponent }
}

public enum ChangeFileTree {
    public static func rows(_ files: [FileChange], collapsedFolders: Set<String> = []) -> [ChangeFileTreeRow]
    {
        let root = Folder(path: "")
        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            var parent = root
            for component in components.dropLast() {
                let path = parent.path.isEmpty ? component : parent.path + "/" + component
                if parent.folders[component] == nil { parent.folders[component] = Folder(path: path) }
                parent = parent.folders[component]!
            }
            parent.files.append(file)
        }
        var result: [ChangeFileTreeRow] = []
        func append(_ folder: Folder, depth: Int) {
            for child in folder.folders.values.sorted(by: { ordered($0.path, $1.path) }) {
                result.append(
                    ChangeFileTreeRow(path: child.path, depth: depth, file: nil, files: child.allFiles))
                if !collapsedFolders.contains(child.path) { append(child, depth: depth + 1) }
            }
            for file in folder.files.sorted(by: { ordered($0.path, $1.path) }) {
                result.append(ChangeFileTreeRow(path: file.path, depth: depth, file: file, files: [file]))
            }
        }
        append(root, depth: 0)
        return result
    }

    private static func ordered(_ a: String, _ b: String) -> Bool {
        let order = a.localizedStandardCompare(b)
        return order == .orderedSame ? a < b : order == .orderedAscending
    }

    private final class Folder {
        let path: String
        var folders: [String: Folder] = [:]
        var files: [FileChange] = []
        init(path: String) { self.path = path }
        var allFiles: [FileChange] {
            files + folders.values.flatMap(\.allFiles)
        }
    }
}
