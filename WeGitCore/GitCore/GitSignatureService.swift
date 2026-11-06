import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func verifySignature(_ objectID: String, object: GitSignatureObject = .commit)
        async throws -> GitSignatureReport
    {
        guard GitObjectID.valid(objectID) else { throw ModelFailure.invalidPath }
        try location.validateIdentity()
        let reader = singleCommitEngine
        let type = try await reader.run(["cat-file", "-t", objectID], in: location.root).text
            .removingLastNewline
        if object == .tag, type == "commit" {
            return GitSignatureReport(
                objectID: objectID, object: object, state: .unsigned, cryptographicallyValid: false,
                identityTrusted: false, format: nil, fingerprint: nil, signer: nil, details: "")
        }
        guard type == object.rawValue else { throw ModelFailure.invalidPath }
        let raw = try await reader.run(
            ["cat-file", object.rawValue, objectID], in: location.root, outputLimit: 2 * 1024 * 1024)
        let rows = raw.stdout.split(separator: 10, omittingEmptySubsequences: false)
        let signed: Bool
        let signature: Data
        if object == .commit {
            let headers = rows.prefix(while: { !$0.isEmpty })
            signed = headers.contains {
                $0.starts(with: Data("gpgsig ".utf8)) || $0.starts(with: Data("gpgsig-sha256 ".utf8))
            }
            signature = headers.reduce(into: Data()) {
                $0.append($1)
                $0.append(10)
            }
        } else {
            signed = rows.contains {
                $0.starts(with: Data("-----BEGIN ".utf8))
                    && String(decoding: $0, as: UTF8.self).contains("SIGNATURE-----")
            }
            signature = raw.stdout
        }
        guard signed else {
            return GitSignatureReport(
                objectID: objectID, object: object, state: .unsigned, cryptographicallyValid: false,
                identityTrusted: false, format: nil, fingerprint: nil, signer: nil, details: "")
        }
        let armored = String(decoding: signature, as: UTF8.self)
        let format =
            armored.contains("-----BEGIN SSH SIGNATURE-----")
            ? "SSH"
            : armored.contains("-----BEGIN PGP SIGNATURE-----") ? "OpenPGP" : nil
        guard let format else {
            return GitSignatureReport(
                objectID: objectID, object: object, state: .unverifiable, cryptographicallyValid: false,
                identityTrusted: false, format: nil, fingerprint: nil, signer: nil,
                details: L10n.text("此签名格式暂不支持验证。"))
        }
        var configuration: [(key: String, value: String)] = []
        var storage: SnapshotDirectory?
        if format == "OpenPGP" {
            let settings = GitConfigurationService(engine: reader, location: location)
            let configured = try await settings.read(.gpgProgram).effective?.value ?? "gpg"
            let program: URL
            do {
                program = try GitProgramPath.resolve(configured, engine: reader, directory: location.root)
            } catch {
                return GitSignatureReport(
                    objectID: objectID, object: object, state: .unverifiable, cryptographicallyValid: false,
                    identityTrusted: false, format: format, fingerprint: nil, signer: nil,
                    details: Redaction.text(error.localizedDescription))
            }
            let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
            storage = directory
            let wrapper = directory.url.appending(path: "verify-gpg")
            let script =
                "#!/bin/sh\nexec " + GitProgramPath.quote(program.path)
                + " --no-auto-key-retrieve --no-auto-key-import --no-auto-check-trustdb \"$@\"\n"
            try await SnapshotIO.run { cancellation in
                let descriptor = Darwin.open(
                    wrapper.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
                guard descriptor >= 0 else { throw ModelFailure.changed }
                defer { Darwin.close(descriptor) }
                try RecoveryFileIO.write(
                    Data(script.utf8), descriptor: descriptor, cancellation: cancellation)
            }
            configuration = [("gpg.program", wrapper.path), ("gpg.openpgp.program", wrapper.path)]
        }
        defer { withExtendedLifetime(storage) {} }
        let result = try await reader.run(
            [object == .commit ? "verify-commit" : "verify-tag", "--raw", objectID],
            in: location.root, accepted: Set((0...255).map(Int32.init)), outputLimit: 64 * 1024,
            configuration: configuration)
        try location.validateIdentity()
        return Self.signatureReport(
            objectID: objectID, object: object, format: format, result: result)
    }

    static func signatureReport(
        objectID: String, object: GitSignatureObject, format: String, result: ProcessResult
    )
        -> GitSignatureReport
    {
        let raw = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        let details = String(Redaction.text(raw).prefix(65536))
        var state = GitSignatureState.unverifiable
        var valid = false
        var trusted = false
        var fingerprint: String?
        var signer: String?
        if format == "OpenPGP" {
            let rows = raw.split(separator: "\n").filter { $0.hasPrefix("[GNUPG:] ") }
                .map { String($0.dropFirst("[GNUPG:] ".count)) }
            let signatures = rows.filter { $0.hasPrefix("VALIDSIG ") }
            let bad = rows.contains {
                ["BADSIG", "NODATA", "BADARMOR"].contains(
                    $0.split(separator: " ").first.map(String.init) ?? "")
            }
            let missing = rows.contains { $0.hasPrefix("NO_PUBKEY ") }
            let expired = rows.contains {
                $0.hasPrefix("EXPSIG ") || $0.hasPrefix("EXPKEYSIG ") || $0.hasPrefix("REVKEYSIG ")
            }
            if let first = signatures.first?.split(separator: " "), first.count >= 10 {
                let value = String(first[1])
                if [40, 64].contains(value.count), value.allSatisfy(\.isHexDigit) { fingerprint = value }
            }
            if let good = rows.first(where: { $0.hasPrefix("GOODSIG ") })?.split(
                separator: " ", maxSplits: 2), good.count == 3
            {
                signer = String(good[2]).removingPercentEncoding ?? String(good[2])
            }
            valid = !bad && !missing && fingerprint != nil && !signatures.isEmpty
            let trustCount = rows.filter { $0.hasPrefix("TRUST_FULLY") || $0.hasPrefix("TRUST_ULTIMATE") }
                .count
            trusted = valid && !expired && result.exitCode == 0 && trustCount >= signatures.count
            if bad {
                state = .invalid
            } else if missing {
                state = .missingPublicKey
            } else if trusted {
                state = .verified
            } else if valid {
                state = .untrusted
            }
        } else {
            valid = result.exitCode == 0 && raw.contains("Good \"git\" signature")
            if let range = raw.range(of: "SHA256:[A-Za-z0-9+/]+={0,2}", options: .regularExpression) {
                fingerprint = String(raw[range])
            }
            if let start = raw.range(of: "signature for "),
                let end = raw.range(of: " with ", range: start.upperBound..<raw.endIndex)
            {
                signer = String(raw[start.upperBound..<end.lowerBound])
            }
            trusted = valid && signer != nil
            if trusted {
                state = .verified
            } else if valid {
                state = .untrusted
            } else if raw.contains("incorrect signature") || raw.contains("Signature verification failed") {
                state = .invalid
            }
        }
        return GitSignatureReport(
            objectID: objectID, object: object, state: state, cryptographicallyValid: valid,
            identityTrusted: trusted, format: format, fingerprint: fingerprint, signer: signer,
            details: details)
    }
}
