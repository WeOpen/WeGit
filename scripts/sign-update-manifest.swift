import CryptoKit
import Darwin
import Foundation

/// Offline release-side helper. It accepts an existing raw Ed25519 private key;
/// it does not generate keys or publish anything, and is never bundled in WeGit.
@main struct SignUpdateManifest {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            throw failure("Usage: sign-update-manifest PAYLOAD.json EXISTING-PRIVATE-KEY OUTPUT.json")
        }
        let payloadURL = URL(fileURLWithPath: args[1])
        let keyURL = URL(fileURLWithPath: args[2])
        let outputURL = URL(fileURLWithPath: args[3])
        let payload = try boundedRead(payloadURL, limit: 190 * 1024, privateKey: false)
        let value = try JSONSerialization.jsonObject(with: payload)
        let canonical = try JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard canonical == payload else {
            throw failure("Payload must contain exact canonical UTF-8 JSON bytes")
        }
        let keyBytes = try boundedRead(keyURL, limit: 32, privateKey: true)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes)
        let signature = try key.signature(for: payload)
        let output = try JSONSerialization.data(
            withJSONObject: [
                "payload": payload.base64EncodedString(), "signature": signature.base64EncodedString(),
            ], options: [.sortedKeys, .withoutEscapingSlashes])
        guard output.count <= 256 * 1024 else { throw failure("Signed manifest exceeds its limit") }
        let fd = open(outputURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Output must be a new file") }
        defer { close(fd) }
        try output.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw failure("Unable to write signed manifest") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw failure("Unable to flush signed manifest") }
        print("Signed metadata written; no keys generated and no release published")
    }

    private static func boundedRead(_ url: URL, limit: Int, privateKey: Bool) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            info.st_size > 0, info.st_size <= limit,
            !privateKey || (info.st_uid == getuid() && info.st_mode & 0o077 == 0)
        else { throw failure("Input size, type or private-key permissions are invalid") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Unable to open input") }
        defer { close(fd) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0, result.count + max(0, count) <= limit else { throw failure("Input changed") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == info.st_size else { throw failure("Input changed") }
        return result
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WeGit.UpdateSigning", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
