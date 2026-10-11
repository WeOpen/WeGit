import Darwin
import Foundation

struct AskPassWireRequest: Codable {
    let token: String
    let prompt: String
    let confirmation: Bool
}

struct AskPassWireResponse: Codable {
    let answer: String?
}

enum AskPassSocket {
    static let frameLimit = 128 * 1024

    static func address<T>(_ path: String, _ operation: (UnsafePointer<sockaddr>, socklen_t) throws -> T)
        throws -> T
    {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw AuthenticationFailure.unavailable
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try operation($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func configure(_ descriptor: Int32, timeout: Int) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        _ = setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var value = timeval(tv_sec: timeout, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            _ = setsockopt(
                descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout.size(ofValue: value)))
        }
    }

    static func sameUser(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == geteuid()
    }

    static func receive(_ descriptor: Int32) throws -> Data {
        let header = try read(descriptor, count: 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...frameLimit).contains(count) else { throw AuthenticationFailure.invalidRequest }
        return try read(descriptor, count: count)
    }

    private static func read(_ descriptor: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let size = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw AuthenticationFailure.connection }
                offset += size
            }
        }
        return result
    }

    static func send(_ payload: Data, to descriptor: Int32) throws {
        guard !payload.isEmpty, payload.count <= frameLimit else {
            throw AuthenticationFailure.invalidRequest
        }
        var size = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(payload)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let size = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw AuthenticationFailure.connection }
                offset += size
            }
        }
    }
}

/// Runs in the bundled helper, not on the app's main/cooperative executor.
public enum AskPassClient {
    public static func answer(
        prompt: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        guard let path = environment["WEGIT_ASKPASS_SOCKET"], let token = environment["WEGIT_ASKPASS_TOKEN"],
            !prompt.contains("\0"), prompt.utf8.count <= 16 * 1024, token.count == 64
        else {
            throw AuthenticationFailure.invalidRequest
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
            info.st_mode & S_IFMT == S_IFSOCK
        else { throw AuthenticationFailure.connection }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AuthenticationFailure.connection }
        defer { Darwin.close(descriptor) }
        AskPassSocket.configure(descriptor, timeout: 125)
        guard try AskPassSocket.address(path, { connect(descriptor, $0, $1) }) == 0,
            AskPassSocket.sameUser(descriptor)
        else { throw AuthenticationFailure.connection }
        let request = AskPassWireRequest(
            token: token, prompt: prompt, confirmation: environment["SSH_ASKPASS_PROMPT"] == "confirm")
        try AskPassSocket.send(JSONEncoder().encode(request), to: descriptor)
        let response = try JSONDecoder().decode(
            AskPassWireResponse.self, from: AskPassSocket.receive(descriptor))
        guard let answer = response.answer else { throw AuthenticationFailure.cancelled }
        guard !answer.contains("\n"), !answer.contains("\r"), !answer.contains("\0"),
            answer.utf8.count <= 64 * 1024
        else { throw AuthenticationFailure.invalidRequest }
        return answer
    }
}
