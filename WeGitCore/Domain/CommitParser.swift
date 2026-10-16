import CoreFoundation
import Foundation

public enum CommitParser {
    public static func batch(_ data: Data, expected: [String], shallow: Set<String> = []) throws
        -> [GitCommit]
    {
        var offset = 0
        var commits: [GitCommit] = []
        for oid in expected {
            try Task.checkCancellation()
            guard offset < data.count, let newline = data[offset...].firstIndex(of: 10),
                let header = String(data: data[offset..<newline], encoding: .utf8)
            else { throw ModelFailure.invalidOutput(L10n.text("提交对象记录被截断")) }
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[0] == oid, fields[1] == "commit",
                let count = Int(fields[2]), count >= 0, count < data.count - newline - 1
            else { throw ModelFailure.invalidOutput(L10n.text("提交对象类型、标识或长度无效")) }
            let end = newline + 1 + count
            guard data[end] == 10 else { throw ModelFailure.invalidOutput(L10n.text("提交对象缺少结束分隔符")) }
            commits.append(
                try parse(Data(data[(newline + 1)..<end]), id: oid, shallow: shallow.contains(oid)))
            offset = end + 1
        }
        guard offset == data.count else { throw ModelFailure.invalidOutput(L10n.text("提交对象输出包含额外记录")) }
        return commits
    }

    public static func parse(_ data: Data, id: String, shallow: Bool = false) throws -> GitCommit {
        guard GitObjectID.valid(id), let separator = data.range(of: Data([10, 10])) else {
            throw ModelFailure.invalidOutput(L10n.text("提交对象头信息无效"))
        }
        let headerData = data[..<separator.lowerBound]
        let encodingLine = headerData.split(separator: 10).first { $0.starts(with: Data("encoding ".utf8)) }
        let encodingName = encodingLine.flatMap { String(data: $0.dropFirst(9), encoding: .utf8) } ?? "UTF-8"
        let encoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
        guard encoding != kCFStringEncodingInvalidId else {
            throw ModelFailure.unsupported(L10n.text("提交使用不受支持的文本编码：\(encodingName)"))
        }
        let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        guard let rawHeader = String(data: headerData, encoding: stringEncoding) else {
            throw ModelFailure.invalidOutput(L10n.text("提交身份信息编码无效"))
        }
        let header = rawHeader.split(separator: "\n")
        guard let tree = header.first(where: { $0.hasPrefix("tree ") }),
            GitObjectID.valid(String(tree.dropFirst(5)))
        else {
            throw ModelFailure.invalidOutput(L10n.text("提交缺少有效的文件树标识"))
        }
        let parents = header.filter { $0.hasPrefix("parent ") }.map { String($0.dropFirst(7)) }
        guard parents.allSatisfy(GitObjectID.valid) else {
            throw ModelFailure.invalidOutput(L10n.text("父提交标识无效"))
        }
        let author = try person(header.first { $0.hasPrefix("author ") }.map { String($0.dropFirst(7)) })
        let committer = try person(
            header.first { $0.hasPrefix("committer ") }.map { String($0.dropFirst(10)) })
        guard let message = String(data: data[separator.upperBound...], encoding: stringEncoding)
        else { throw ModelFailure.unsupported(L10n.text("提交使用不受支持或无效的文本编码：\(encodingName)")) }
        return GitCommit(
            id: id, parents: parents, author: author.name, date: author.date, message: message,
            authorEmail: author.email, committer: committer.name, committerEmail: committer.email,
            committedAt: committer.date, shallowBoundary: shallow && !parents.isEmpty)
    }

    private static func person(_ value: String?) throws -> (name: String, email: String, date: Date) {
        guard let value, let open = value.range(of: " <", options: .backwards),
            let close = value[open.upperBound...].firstIndex(of: ">")
        else { throw ModelFailure.invalidOutput(L10n.text("提交身份信息缺失")) }
        let suffix = value[value.index(after: close)...].split(separator: " ")
        guard suffix.count == 2, let seconds = Int64(suffix[0]),
            suffix[1].count == 5, ["+", "-"].contains(suffix[1].first),
            suffix[1].dropFirst().allSatisfy(\.isNumber)
        else { throw ModelFailure.invalidOutput(L10n.text("提交时间信息无效")) }
        return (
            String(value[..<open.lowerBound]), String(value[open.upperBound..<close]),
            Date(timeIntervalSince1970: TimeInterval(seconds))
        )
    }
}
