import Foundation

public struct AuthenticationRequest: Identifiable, Sendable {
    public enum Kind: Sendable { case username, secret, hostConfirmation }
    public let id = UUID()
    public let command: String
    public let repository: URL?
    public let prompt: String
    public let kind: Kind

    init(command: String, repository: URL?, prompt: String, confirmation: Bool) {
        self.command = command
        self.repository = repository
        self.prompt = Redaction.text(prompt)
        if confirmation || prompt.contains("yes/no") {
            kind = .hostConfirmation
        } else if prompt.lowercased().hasPrefix("username") {
            kind = .username
        } else {
            kind = .secret
        }
    }
}

public enum AuthenticationFailure: Error, LocalizedError, Sendable {
    case unavailable, invalidRequest, cancelled, timedOut, connection
    public var errorDescription: String? {
        switch self {
        case .unavailable: "无法启动认证辅助工具，请重新构建或安装完整的 WeGit 应用。"
        case .invalidRequest: "认证请求无效或超出长度限制。"
        case .cancelled: "认证已取消。"
        case .timedOut: "认证等待超时，请重试操作。"
        case .connection: "认证通道已关闭，请重试操作。"
        }
    }
}
