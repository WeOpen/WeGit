import Foundation

public enum ChangeKindFilter: String, CaseIterable, Sendable {
    case all
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case untracked = "?"
    case conflicts = "U"
    public var title: String {
        switch self {
        case .all: "全部状态"
        case .modified: "修改 M"
        case .added: "新增 A"
        case .deleted: "删除 D"
        case .renamed: "重命名 R"
        case .copied: "复制 C"
        case .typeChanged: "类型变化 T"
        case .untracked: "未跟踪 ?"
        case .conflicts: "冲突 U"
        }
    }
}

public struct ChangeFilter: Sendable {
    public let query: String
    public let kind: ChangeKindFilter
    public init(query: String = "", kind: ChangeKindFilter = .all) {
        self.query = query
        self.kind = kind
    }

    public func matches(_ file: FileChange, layer: DiffLayer) -> Bool {
        file.layers.contains(layer) && (query.isEmpty || file.path.localizedCaseInsensitiveContains(query))
            && (kind == .all || file.symbol(for: layer) == kind.rawValue)
    }

    public func visiblePathCount(_ files: [FileChange]) -> Int {
        Set(files.filter { file in file.layers.contains { matches(file, layer: $0) } }.map(\.path)).count
    }
}
