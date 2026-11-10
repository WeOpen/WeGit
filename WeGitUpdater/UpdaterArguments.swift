import Darwin
import Foundation
import WeGitCore

struct UpdaterArguments {
    let ticketURL: URL
    let recover: Bool

    init(_ arguments: [String]) throws {
        var values = Array(arguments.dropFirst())
        recover = values.first == "--recover"
        if recover { values.removeFirst() }
        guard values.count == 2, values[0] == "--ticket", values[1].hasPrefix("/"),
            values[1].utf8.count <= 4096, !values[1].contains("\0")
        else { throw UpdateFailure.invalidManifest }
        let url = URL(fileURLWithPath: values[1])
        guard url.standardizedFileURL.path == values[1], url.lastPathComponent == "ticket.json" else {
            throw UpdateFailure.invalidManifest
        }
        ticketURL = url
    }

    func tokenFromPipe(descriptor: Int32 = STDIN_FILENO, timeout: TimeInterval = 5) throws -> String {
        var info = stat()
        guard timeout > 0, timeout <= 5, fstat(descriptor, &info) == 0,
            isatty(descriptor) == 0
        else { throw UpdateFailure.invalidManifest }
        let kind = info.st_mode & mode_t(S_IFMT)
        guard
            kind == mode_t(S_IFIFO) || kind == mode_t(S_IFSOCK)
                || (kind == mode_t(S_IFREG) && info.st_uid == getuid()
                    && info.st_mode & 0o077 == 0 && (0...130).contains(info.st_size))
        else { throw UpdateFailure.invalidManifest }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 131)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw UpdateFailure.exceeded }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let count = poll(&event, 1, Int32(min(250, ceil(remaining * 1000))))
            if count < 0, errno == EINTR { continue }
            guard count >= 0, event.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                throw UpdateFailure.invalidManifest
            }
            if count == 0 { continue }
            let received = Darwin.read(descriptor, &buffer, buffer.count)
            if received < 0, errno == EINTR { continue }
            guard received >= 0 else { throw UpdateFailure.invalidManifest }
            if received == 0 { break }
            bytes.append(contentsOf: buffer.prefix(received))
            guard bytes.count <= 130 else { throw UpdateFailure.invalidManifest }
        }
        // CRLF is one Swift Character; trim its protocol bytes before decoding.
        if bytes.last == 10 {
            bytes.removeLast()
            if bytes.last == 13 { bytes.removeLast() }
        }
        guard let token = String(data: bytes, encoding: .utf8) else { throw UpdateFailure.invalidManifest }
        guard !token.isEmpty, token.count <= 128,
            token.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-") })
        else { throw UpdateFailure.invalidManifest }
        return token
    }
}
