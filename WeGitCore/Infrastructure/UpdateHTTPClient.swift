import CryptoKit
import Darwin
import Foundation

public struct UpdateDownload: Sendable {
    public let url: URL
    public let sha256: String
    public let byteCount: Int64
    private let file: SnapshotFile

    fileprivate init(file: SnapshotFile, sha256: String, byteCount: Int64) {
        self.file = file
        url = file.url
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public func validate() async throws {
        try await SnapshotIO.run { cancellation in
            try file.directory.validate()
            let descriptor = try file.open()
            defer { Darwin.close(descriptor) }
            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var total: Int64 = 0
            while true {
                try cancellation.check()
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count >= 0 else { throw UpdateFailure.changed }
                if count == 0 { break }
                total += Int64(count)
                guard total <= byteCount else { throw UpdateFailure.changed }
                hash.update(data: Data(buffer.prefix(count)))
            }
            try file.validate(descriptor)
            guard total == byteCount,
                hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256
            else { throw UpdateFailure.changed }
        }
    }
}

public struct UpdateHTTPClient: Sendable {
    private let testingProtocol: URLProtocol.Type?
    public init() { testingProtocol = nil }
    init(testingProtocol: URLProtocol.Type) { self.testingProtocol = testingProtocol }

    public func check(
        channel: UpdateChannel, ring: UpdateKeyRing, installed: InstalledUpdateVersion,
        hardware: UpdateHardware = .current()
    ) async throws -> UpdateCheckResult {
        guard !ring.keys.isEmpty else { throw UpdateFailure.configurationMissing }
        let url = UpdateManifestValidator.metadataURL(channel: channel)
        let download = try await UpdateTransfer(
            url: url, limit: Int64(UpdateManifestValidator.metadataBytes),
            expectedBytes: nil, expectedSHA256: nil, metadata: true, progress: nil,
            testingProtocol: testingProtocol
        ).run()
        try Task.checkCancellation()
        let data = try Data(contentsOf: download.url)
        return try UpdateManifestValidator.validate(
            data, ring: ring, channel: channel,
            installed: installed, hardware: hardware)
    }

    public func download(
        _ update: TrustedUpdate,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> UpdateDownload {
        guard Date() < update.expiresAt else { throw UpdateFailure.expired }
        return try await UpdateTransfer(
            url: URL(string: update.artifact.url)!,
            limit: UpdateManifestValidator.downloadBytes, expectedBytes: update.artifact.downloadBytes,
            expectedSHA256: update.artifact.sha256, metadata: false, progress: progress,
            testingProtocol: testingProtocol
        ).run()
    }

    public func packageManifest(_ update: TrustedUpdate) async throws -> Data {
        guard Date() < update.expiresAt else { throw UpdateFailure.expired }
        let download = try await UpdateTransfer(
            url: URL(string: update.artifact.manifestURL)!,
            limit: Int64(UpdateManifestValidator.metadataBytes), expectedBytes: nil,
            expectedSHA256: update.artifact.manifestSHA256, metadata: false, progress: nil,
            testingProtocol: testingProtocol
        ).run()
        try Task.checkCancellation()
        return try Data(contentsOf: download.url)
    }
}

/// A serial delegate writes 64 KiB-or-smaller network chunks directly into private
/// storage. No credentials, cookies, shared cache or unbounded response buffer exists.
private final class UpdateTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let initialURL: URL
    private let limit: Int64
    private let expectedBytes: Int64?
    private let expectedSHA256: String?
    private let metadata: Bool
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private let testingProtocol: URLProtocol.Type?
    private let directory: SnapshotDirectory
    private let destination: URL
    private let descriptor: Int32
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UpdateDownload, any Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false
    private var failure: (any Error)?
    private var received: Int64 = 0
    private var responseHash = SHA256()
    private var redirects = 0
    private var lastProgressTime: TimeInterval = 0
    private var descriptorClosed = false

    init(
        url: URL, limit: Int64, expectedBytes: Int64?, expectedSHA256: String?, metadata: Bool,
        progress: (@Sendable (Int64, Int64) -> Void)?, testingProtocol: URLProtocol.Type?
    ) throws {
        initialURL = url
        self.limit = limit
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256
        self.metadata = metadata
        self.progress = progress
        self.testingProtocol = testingProtocol
        directory = try SnapshotDirectory()
        destination = directory.url.appending(path: "update-download")
        descriptor = Darwin.open(
            destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UpdateFailure.changed }
        super.init()
    }

    deinit { if !descriptorClosed { Darwin.close(descriptor) } }

    func run() async throws -> UpdateDownload {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                if let testingProtocol { configuration.protocolClasses = [testingProtocol] }
                configuration.timeoutIntervalForRequest = UpdateManifestValidator.requestSeconds
                configuration.timeoutIntervalForResource = UpdateManifestValidator.requestSeconds
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: initialURL)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.dataTask(with: request)
                let stop = lock.withLock {
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return cancelled
                }
                task.resume()
                if stop { task.cancel() }
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirects += 1
        guard redirects <= 3, let url = request.url, allowedRedirect(url) else {
            failure = UpdateFailure.source
            completionHandler(nil)
            task.cancel()
            return
        }
        var clean = URLRequest(url: url)
        clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(clean)
    }

    private func allowedRedirect(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil,
            url.port == nil || url.port == 443
        else { return false }
        if metadata { return url == initialURL }
        if url.host == "github.com" { return url.path == initialURL.path && url.query == nil }
        return ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(
            url.host ?? "")
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.expectedContentLength == -1 || response.expectedContentLength <= limit,
            expectedBytes == nil || response.expectedContentLength == -1
                || response.expectedContentLength == expectedBytes,
            response.value(forHTTPHeaderField: "Content-Encoding") == nil
                || response.value(forHTTPHeaderField: "Content-Encoding") == "identity"
        else {
            failure = UpdateFailure.truncated
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard !lock.withLock({ cancelled }), Int64(data.count) <= limit - received else {
            failure = lock.withLock({ cancelled }) ? CancellationError() : UpdateFailure.exceeded
            dataTask.cancel()
            return
        }
        do {
            try directory.validate()
            try data.withUnsafeBytes { buffer in
                var written = 0
                while written < buffer.count {
                    let count = Darwin.write(
                        descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw UpdateFailure.changed }
                    written += count
                }
            }
            responseHash.update(data: data)
            received += Int64(data.count)
            let currentTime = ProcessInfo.processInfo.systemUptime
            if currentTime - lastProgressTime >= 0.1 || received == expectedBytes {
                lastProgressTime = currentTime
                progress?(received, expectedBytes ?? limit)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        var outcome: Result<UpdateDownload, any Error>
        do {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            if let error = failure ?? error { throw error }
            guard received > 0, expectedBytes == nil || received == expectedBytes else {
                throw UpdateFailure.truncated
            }
            let digest = responseHash.finalize().map { String(format: "%02x", $0) }.joined()
            guard expectedSHA256 == nil || expectedSHA256 == digest else { throw UpdateFailure.truncated }
            guard fsync(descriptor) == 0 else { throw UpdateFailure.changed }
            Darwin.close(descriptor)
            descriptorClosed = true
            try directory.validate()
            let file = try SnapshotFile(directory: directory, url: destination, verifiedSHA256: digest)
            outcome = .success(UpdateDownload(file: file, sha256: digest, byteCount: received))
        } catch { outcome = .failure(error) }
        let continuation = lock.withLock {
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(with: outcome)
        session.finishTasksAndInvalidate()
        lock.withLock {
            self.task = nil
            self.session = nil
        }
    }
}
