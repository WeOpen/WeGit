import Darwin
import Foundation

public struct ProcessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var directory: URL?
    public var environment: [String: String]
    public var input: Data?
    public var timeout: TimeInterval
    public var outputLimit: Int
    /// Create a new private file for stdout instead of retaining it in memory. Existing paths
    /// are never overwritten. A failed/cancelled capture removes only the file it created.
    public var stdoutFile: URL?
    public var onStderr: (@Sendable (Data) -> Void)?

    public init(
        executable: URL, arguments: [String], directory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: Data? = nil, timeout: TimeInterval = 30, outputLimit: Int = 8 * 1024 * 1024,
        onStderr: (@Sendable (Data) -> Void)? = nil, stdoutFile: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.input = input
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.onStderr = onStderr
        self.stdoutFile = stdoutFile
    }
}

public struct ProcessResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let duration: TimeInterval
    public var stdoutByteCount = 0
    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public enum ProcessFailure: Error, LocalizedError, Sendable {
    case launch(Int32)
    case outputWrite(Int32)
    case cancelled, timedOut, outputLimit
    public var errorDescription: String? {
        switch self {
        case .launch(let code): L10n.text("无法启动进程（系统错误 \(code)）。")
        case .outputWrite(let code): L10n.text("无法保存命令输出（系统错误 \(code)）。请检查磁盘空间和目录权限。")
        case .cancelled: L10n.text("操作已取消。写入结果可能已生效，请刷新仓库核对。")
        case .timedOut: L10n.text("操作超时。请检查认证或外部工具，并刷新仓库核对结果。")
        case .outputLimit: L10n.text("输出超过安全读取上限，请缩小读取范围或在外部工具中查看。")
        }
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

// Reserve capacity asynchronously before using blocking POSIX I/O. Each process needs a
// waiter and up to three pipe workers; unbounded waiters can starve their own pipe readers
// on Dispatch's shared thread pool. Queued requests occupy no worker threads.
public struct ProcessRunner: ProcessRunning {
    private let capacity: ProcessCapacity
    public init() { capacity = .shared }

    init(capacity: ProcessCapacity) { self.capacity = capacity }

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try await capacity.perform { try await Self.runWithCapacity(request) }
    }

    private static func runWithCapacity(_ request: ProcessRequest) async throws -> ProcessResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try Self.execute(request, control: control)) } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            control.stop(.cancelled)
        }
    }

    private static func execute(_ request: ProcessRequest, control: ProcessControl) throws -> ProcessResult {
        guard request.outputLimit > 0 else { throw ProcessFailure.outputLimit }
        let started = Date()
        let stdout = try OutputCapture(file: request.stdoutFile)
        let stderr = try OutputCapture()
        var captured = false
        defer {
            stdout.finish(keepFile: captured)
            stderr.finish(keepFile: false)
        }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let pipes = [input, output, errors]
        for pipe in pipes {
            _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        for pipe in pipes {
            posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
            posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
        }
        if let directory = request.directory {
            directory.path.withCString { _ = posix_spawn_file_actions_addchdir(&actions, $0) }
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ([request.executable.path] + request.arguments).map { strdup($0) }
        let environment = request.environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            for argument in arguments { free(argument) }
            for entry in environment { free(entry) }
        }
        var argv = arguments + [nil]
        var envp = environment + [nil]
        var pid: pid_t = 0
        try control.check()
        let code = posix_spawn(&pid, request.executable.path, &actions, &attributes, &argv, &envp)
        guard code == 0 else { throw ProcessFailure.launch(code) }
        control.started(pid)
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let readers = DispatchGroup()
        for (handle, buffer, isStderr) in [
            (output.fileHandleForReading, stdout, false), (errors.fileHandleForReading, stderr, true),
        ] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    try? handle.close()
                    readers.leave()
                }
                var bytes = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                    if count == -1 && errno == EINTR { continue }
                    if count < 0 {
                        control.stop(.outputWrite(errno))
                        break
                    }
                    if count == 0 { break }
                    let chunk = Data(bytes.prefix(count))
                    do {
                        let limit = isStderr ? min(request.outputLimit, 8 * 1024 * 1024) : request.outputLimit
                        try buffer.append(chunk, limit: limit)
                        if isStderr { request.onStderr?(chunk) }
                    } catch let failure as ProcessFailure {
                        control.stop(failure)
                    } catch {
                        control.stop(.outputWrite(EIO))
                    }
                }
            }
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                try? input.fileHandleForWriting.close()
                readers.leave()
            }
            let fd = input.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            if let data = request.input {
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = Darwin.write(
                            fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if count == -1 && errno == EINTR { continue }
                        guard count > 0 else { break }
                        offset += count
                    }
                }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + request.timeout)
        timer.setEventHandler { control.stop(.timedOut) }
        timer.resume()
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        let waitError = errno
        // Descendants may still hold pipes open. Keep cancellation/timeout active until they close.
        readers.wait()
        timer.cancel()
        control.finished()
        try control.check()
        guard waited == pid else { throw ProcessFailure.launch(waitError) }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        captured = true
        return ProcessResult(
            stdout: stdout.value, stderr: stderr.value, exitCode: exitCode,
            duration: Date().timeIntervalSince(started), stdoutByteCount: stdout.byteCount)
    }
}

/// A process-wide FIFO limit, held until the child exits AND all of its pipes close.
/// Cancellation removes a queued request without launching it or blocking a thread.
actor ProcessCapacity {
    static let shared = ProcessCapacity(limit: 8)
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }

    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().1.resume() }
    }
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var count = 0
    private let destination: URL?
    private let descriptor: Int32?
    private let identity: stat?

    init(file: URL? = nil) throws {
        destination = file
        guard let file else {
            descriptor = nil
            identity = nil
            return
        }
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProcessFailure.outputWrite(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ProcessFailure.outputWrite(code)
        }
        descriptor = fd
        identity = info
    }

    var value: Data { lock.withLock { data } }
    var byteCount: Int { lock.withLock { count } }
    func append(_ chunk: Data, limit: Int) throws {
        try lock.withLock {
            guard chunk.count <= limit - count else { throw ProcessFailure.outputLimit }
            if let descriptor {
                try chunk.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = Darwin.write(
                            descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw ProcessFailure.outputWrite(written < 0 ? errno : EIO) }
                        offset += written
                    }
                }
            } else {
                data.append(chunk)
            }
            count += chunk.count
        }
    }

    func finish(keepFile: Bool) {
        if let descriptor { Darwin.close(descriptor) }
        guard !keepFile, let destination, let identity else { return }
        var current = stat()
        if lstat(destination.path, &current) == 0, current.st_dev == identity.st_dev,
            current.st_ino == identity.st_ino
        {
            Darwin.unlink(destination.path)
        }
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var failure: ProcessFailure?
    func check() throws { if let error = lock.withLock({ failure }) { throw error } }
    func started(_ value: pid_t) {
        lock.withLock {
            pid = value
            if failure != nil {
                kill(-value, SIGTERM)
                scheduleKill(value)
            }
        }
    }
    func stop(_ reason: ProcessFailure) {
        lock.withLock {
            guard failure == nil else { return }
            failure = reason
            if let pid {
                kill(-pid, SIGTERM)
                scheduleKill(pid)
            }
        }
    }
    private func scheduleKill(_ value: pid_t) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.withLock { if pid == value { kill(-value, SIGKILL) } }
        }
    }
    func finished() { lock.withLock { pid = nil } }
}
