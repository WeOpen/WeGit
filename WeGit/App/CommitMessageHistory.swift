import CryptoKit
import Foundation
import WeGitCore

@MainActor final class CommitMessageHistory {
    private struct Payload: Codable {
        let format: Int
        let messages: [String]
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    private func key(_ location: RepositoryLocation) -> String {
        let scope = Data(location.commonDirectory.path.utf8)
        let hash = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        return "commit-message-history-v1:" + hash
    }
    func messages(in location: RepositoryLocation) throws -> [String] {
        guard let data = defaults.data(forKey: key(location)) else { return [] }
        guard data.count <= 512 * 1024,
            let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.format == 1,
            payload.messages.count <= 20, Set(payload.messages).count == payload.messages.count,
            payload.messages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 * 1024 && !$0.contains("\0") })
        else { throw ModelFailure.unsupported(L10n.text("提交消息历史无法读取。当前草稿保留，可清空历史后重新保存。")) }
        return payload.messages
    }
    func append(_ message: String, in location: RepositoryLocation) throws {
        guard !message.isEmpty, message.utf8.count <= 64 * 1024, !message.contains("\0") else { return }
        var values = try messages(in: location).filter { $0 != message }
        values.insert(message, at: 0)
        values = Array(values.prefix(20))
        var data = try JSONEncoder().encode(Payload(format: 1, messages: values))
        while data.count > 512 * 1024, values.count > 1 {
            values.removeLast()
            data = try JSONEncoder().encode(Payload(format: 1, messages: values))
        }
        defaults.set(data, forKey: key(location))
    }
    func hasSavedData(in location: RepositoryLocation) -> Bool { defaults.data(forKey: key(location)) != nil }
    func clear(in location: RepositoryLocation) -> Data? {
        let previous = defaults.data(forKey: key(location))
        defaults.removeObject(forKey: key(location))
        return previous
    }
    func restore(_ data: Data, in location: RepositoryLocation) {
        guard !hasSavedData(in: location) else { return }
        defaults.set(data, forKey: key(location))
    }
}
