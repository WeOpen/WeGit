import Darwin
import Foundation

public struct AskPassBridge: Sendable {
    public typealias Prompt = @Sendable (AuthenticationRequest) async throws -> String?
    public let helper: URL
    private let prompt: Prompt

    public init(helper: URL, prompt: @escaping Prompt) {
        self.helper = helper
        self.prompt = prompt
    }

    func session(command: String, repository: URL?) throws -> AskPassSession {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AuthenticationFailure.unavailable
        }
        return try AskPassSession(helper: helper, command: command, repository: repository, prompt: prompt)
    }
}

/// Per-command capability and private Unix socket. No credential or reply touches a file.
final class AskPassSession: @unchecked Sendable {
    private static let listenerQueue = DispatchQueue(label: "com.willxue.wegit.askpass-listener")
    private static let ioQueue = DispatchQueue(
        label: "com.willxue.wegit.askpass-io", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private let listener: DispatchSourceRead
    private let directory: String
    let socketPath: String
    private let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    private let helper: URL
    private let command: String
    private let repository: URL?
    private let prompt: AskPassBridge.Prompt
    private let promptTimeout: Duration
    private var connections: [UUID: AskPassConnection] = [:]
    private var secrets: [String] = []
    private var requestCount = 0
    private var stopped = false

    init(
        helper: URL, command: String, repository: URL?, promptTimeout: Duration = .seconds(120),
        prompt: @escaping AskPassBridge.Prompt
    ) throws {
        self.helper = helper
        self.command = command
        self.repository = repository
        self.prompt = prompt
        self.promptTimeout = promptTimeout
        var template = Array("/tmp/wegit-auth.XXXXXX".utf8CString)
        guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) != nil else {
            throw AuthenticationFailure.unavailable
        }
        directory = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        socketPath = directory + "/s"
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            rmdir(directory)
            throw AuthenticationFailure.unavailable
        }
        do {
            AskPassSocket.configure(descriptor, timeout: 5)
            guard try AskPassSocket.address(socketPath, { bind(descriptor, $0, $1) }) == 0,
                chmod(socketPath, 0o600) == 0, listen(descriptor, 8) == 0,
                fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
            else {
                throw AuthenticationFailure.unavailable
            }
        } catch {
            Darwin.close(descriptor)
            unlink(socketPath)
            rmdir(directory)
            throw error
        }
        listener = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: Self.listenerQueue)
        listener.setEventHandler { [weak self] in self?.acceptConnections(descriptor) }
        listener.setCancelHandler { Darwin.close(descriptor) }
        listener.resume()
    }

    func environment(over base: [String: String]) -> [String: String] {
        var result = base
        // Git and OpenSSH execute these paths directly. Shell quoting would become
        // part of the filename; spaces and quotes must remain literal path bytes.
        if result["GIT_ASKPASS"] == nil {
            result["GIT_ASKPASS"] = helper.path
        }
        if result["SSH_ASKPASS"] == nil {
            result["SSH_ASKPASS"] = helper.path
            result["SSH_ASKPASS_REQUIRE"] = "force"
            if result["DISPLAY"] == nil { result["DISPLAY"] = "WeGit" }
        }
        result["WEGIT_ASKPASS_SOCKET"] = socketPath
        result["WEGIT_ASKPASS_TOKEN"] = token
        return result
    }

    func redact(_ text: String) -> String {
        lock.withLock {
            secrets.sorted { $0.count > $1.count }.reduce(text) {
                $0.replacingOccurrences(of: $1, with: "[redacted]")
            }
        }
    }

    private func acceptConnections(_ descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 && errno == EINTR { continue }
            guard client >= 0 else { return }
            guard AskPassSocket.sameUser(client), AskPassConnection.reserve() else {
                Darwin.close(client)
                continue
            }
            AskPassSocket.configure(client, timeout: 5)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            let connection = AskPassConnection(client)
            let added = lock.withLock {
                guard !stopped else { return false }
                connections[connection.id] = connection
                return true
            }
            guard added else {
                connection.cancel()
                continue
            }
            Self.ioQueue.async { [self] in readRequest(connection) }
        }
    }

    private func readRequest(_ connection: AskPassConnection) {
        do {
            let payload = try AskPassSocket.receive(connection.descriptor)
            let request = try JSONDecoder().decode(AskPassWireRequest.self, from: payload)
            let available = lock.withLock {
                guard !stopped, requestCount < 32 else { return false }
                requestCount += 1
                return true
            }
            guard request.token == token, request.prompt.utf8.count <= 16 * 1024,
                !request.prompt.contains("\0"), available
            else {
                throw AuthenticationFailure.invalidRequest
            }
            let prompt = AuthenticationRequest(
                command: command, repository: repository,
                prompt: request.prompt, confirmation: request.confirmation)
            let task = Task { [self] in
                var answer: String?
                do {
                    answer = try await withThrowingTaskGroup(of: String?.self) { group in
                        group.addTask { try await self.prompt(prompt) }
                        group.addTask {
                            try await Task.sleep(for: self.promptTimeout)
                            throw AuthenticationFailure.timedOut
                        }
                        defer { group.cancelAll() }
                        return try await group.next() ?? nil
                    }
                    try Task.checkCancellation()
                    if let value = answer {
                        guard value.utf8.count <= 64 * 1024, !value.contains("\n"),
                            !value.contains("\r"), !value.contains("\0")
                        else {
                            throw AuthenticationFailure.invalidRequest
                        }
                        if prompt.kind == .secret, !value.isEmpty {
                            lock.withLock { secrets.append(value) }
                        }
                    }
                } catch { answer = nil }
                let response = AskPassWireResponse(answer: answer)
                await withCheckedContinuation { continuation in
                    Self.ioQueue.async {
                        if let data = try? JSONEncoder().encode(response) {
                            try? AskPassSocket.send(data, to: connection.descriptor)
                        }
                        continuation.resume()
                    }
                }
                finish(connection)
            }
            connection.attach(task)
        } catch { finish(connection) }
    }

    private func finish(_ connection: AskPassConnection) {
        _ = lock.withLock { connections.removeValue(forKey: connection.id) }
        connection.cancel()
    }

    func close() {
        let active: [AskPassConnection]? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            let active = Array(connections.values)
            connections.removeAll()
            secrets.removeAll()
            return active
        }
        guard let active else { return }
        listener.cancel()
        for connection in active { connection.cancel() }
        unlink(socketPath)
        rmdir(directory)
    }

    deinit { close() }
}

/// Globally bound untrusted socket clients, independent of the Git process permits.
private final class AskPassConnection: @unchecked Sendable {
    private final class Quota: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
    }
    private static let quota = Quota()
    static func reserve() -> Bool {
        quota.lock.withLock {
            guard quota.count < 16 else { return false }
            quota.count += 1
            return true
        }
    }

    let id = UUID()
    let descriptor: Int32
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    init(_ descriptor: Int32) { self.descriptor = descriptor }

    func attach(_ task: Task<Void, Never>) {
        lock.withLock {
            if cancelled { task.cancel() } else { self.task = task }
        }
    }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            task?.cancel()
            task = nil
            shutdown(descriptor, SHUT_RDWR)
        }
    }

    deinit {
        Darwin.close(descriptor)
        Self.quota.lock.withLock { Self.quota.count -= 1 }
    }
}
