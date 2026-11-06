import CryptoKit
import Darwin
import Foundation

public enum UpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable, candidate
}

public enum UpdateVariant: String, Codable, CaseIterable, Sendable {
    case universal, applesilicon, intel
    public var architectures: [String] {
        switch self {
        case .universal: ["arm64", "x86_64"]
        case .applesilicon: ["arm64"]
        case .intel: ["x86_64"]
        }
    }
}

public struct UpdateVersion: Hashable, Comparable, Sendable {
    public let rawValue: String
    public let numbers: [Int]
    public let prerelease: String?
    private let rank: Int
    private let sequence: Int

    public init(_ value: String) throws {
        guard value.utf8.count <= 80,
            value.range(
                of:
                    #"^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-(alpha|beta|rc)\.(0|[1-9][0-9]{0,8}))?$"#,
                options: .regularExpression) != nil
        else { throw UpdateFailure.invalidManifest }
        rawValue = value
        let parts = value.split(separator: "-", maxSplits: 1)
        numbers = parts[0].split(separator: ".").map { Int($0)! }
        prerelease = parts.count == 2 ? String(parts[1]) : nil
        let suffix = prerelease?.split(separator: ".")
        rank = suffix.map { ["alpha": 0, "beta": 1, "rc": 2][String($0[0])]! } ?? 3
        sequence = suffix.map { Int($0[1])! } ?? 0
    }

    public static func < (left: Self, right: Self) -> Bool {
        if left.numbers != right.numbers { return left.numbers.lexicographicallyPrecedes(right.numbers) }
        if left.rank != right.rank { return left.rank < right.rank }
        return left.sequence < right.sequence
    }
}

public enum UpdateFailure: LocalizedError, Sendable {
    case configurationMissing, invalidManifest, signature, expired, downgrade, source
    case channel, incompatible, exceeded, truncated, changed, busy, insufficientSpace, installation
    public var errorDescription: String? {
        switch self {
        case .configurationMissing: L10n.text("更新验证公钥尚未配置，请使用官网下载。")
        case .invalidManifest: L10n.text("更新清单格式无效。")
        case .signature: L10n.text("更新来源签名无效，已停止安装。")
        case .expired: L10n.text("更新清单或验证密钥已过期。")
        case .downgrade: L10n.text("更新版本低于已安装版本，请通过备份执行明确回退。")
        case .source: L10n.text("更新下载来源不受信任。")
        case .channel: L10n.text("更新版本与所选通道不符。")
        case .incompatible: L10n.text("更新包与这台 Mac 或已安装变体不兼容。")
        case .exceeded: L10n.text("更新数据超过大小或时间上限。")
        case .truncated: L10n.text("更新下载不完整或摘要不符。")
        case .changed: L10n.text("更新文件或安装目标已变化，请重新检查。")
        case .busy: L10n.text("请先完成正在运行的任务并保存所有窗口。")
        case .insufficientSpace: L10n.text("空间不足，无法保留旧包和数据备份。")
        case .installation: L10n.text("更新安装未完成，旧包和备份已保留。")
        }
    }
}

public struct UpdateArtifact: Codable, Equatable, Sendable {
    public let variant: UpdateVariant
    public let url: String
    public let sha256: String
    public let downloadBytes: Int64
    public let installedBytes: Int64
    public let manifestURL: String
    public let manifestSHA256: String

    public init(
        variant: UpdateVariant, url: String, sha256: String, downloadBytes: Int64,
        installedBytes: Int64, manifestURL: String, manifestSHA256: String
    ) {
        self.variant = variant
        self.url = url
        self.sha256 = sha256
        self.downloadBytes = downloadBytes
        self.installedBytes = installedBytes
        self.manifestURL = manifestURL
        self.manifestSHA256 = manifestSHA256
    }
}

public struct UpdateManifest: Codable, Sendable {
    public let format: Int
    public let version: String
    public let tag: String
    public let channel: UpdateChannel
    public let build: UInt64
    public let sourceCommit: String
    public let minimumOS: String
    public let publishedAt: String
    public let expiresAt: String
    public let keyID: String
    public let draft: Bool
    public let releaseNotes: String
    public let artifacts: [UpdateArtifact]

    public init(
        version: String, channel: UpdateChannel, build: UInt64, sourceCommit: String,
        minimumOS: String = "26.0", publishedAt: String, expiresAt: String, keyID: String,
        releaseNotes: String, artifacts: [UpdateArtifact]
    ) {
        format = 1
        self.version = version
        tag = "v" + version
        self.channel = channel
        self.build = build
        self.sourceCommit = sourceCommit
        self.minimumOS = minimumOS
        self.publishedAt = publishedAt
        self.expiresAt = expiresAt
        self.keyID = keyID
        draft = false
        self.releaseNotes = releaseNotes
        self.artifacts = artifacts
    }
}

/// The base64 payload contains canonical UTF-8 JSON. Its exact bytes, including keyID,
/// are signed; a checksum or the macOS ad-hoc signature cannot authenticate a release.
public struct SignedUpdateManifest: Codable, Sendable {
    public let payload: Data
    public let signature: Data
    public init(payload: Data, signature: Data) {
        self.payload = payload
        self.signature = signature
    }
}

public struct UpdatePublicKey: Codable, Sendable {
    public let id: String
    public let publicKey: Data
    public let notBefore: Date
    public let notAfter: Date
    public let minimumVersion: String
    public let maximumVersion: String?
    public let channels: [UpdateChannel]
    public init(
        id: String, publicKey: Data, notBefore: Date, notAfter: Date,
        minimumVersion: String, maximumVersion: String? = nil, channels: [UpdateChannel]
    ) {
        self.id = id
        self.publicKey = publicKey
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
        self.channels = channels
    }
}

public struct UpdateKeyRing: Codable, Sendable {
    public let format: Int
    public let keys: [UpdatePublicKey]
    public init(keys: [UpdatePublicKey]) {
        format = 1
        self.keys = keys
    }

    /// Production contains public keys only. An absent resource is a configuration
    /// boundary, never permission to fall back to unsigned installation.
    public static func load(from url: URL?) throws -> Self {
        guard let url else { throw UpdateFailure.configurationMissing }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 64 * 1024 else { throw UpdateFailure.exceeded }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ring = try decoder.decode(Self.self, from: data)
        guard ring.format == 1, !ring.keys.isEmpty, ring.keys.count <= 16,
            Set(ring.keys.map(\.id)).count == ring.keys.count
        else { throw UpdateFailure.configurationMissing }
        return ring
    }
}

public struct InstalledUpdateVersion: Sendable {
    public let version: UpdateVersion
    public let build: UInt64
    public let variant: UpdateVariant
    public init(version: String, build: UInt64, variant: UpdateVariant) throws {
        self.version = try UpdateVersion(version)
        self.build = build
        self.variant = variant
    }
}

public struct UpdateHardware: Sendable {
    public let appleSilicon: Bool
    public let translated: Bool
    public init(appleSilicon: Bool, translated: Bool = false) {
        self.appleSilicon = appleSilicon
        self.translated = translated
    }
    public static func current() -> Self {
        func flag(_ name: String) -> Bool {
            var value: Int32 = 0
            var length = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &length, nil, 0) == 0 && value == 1
        }
        let translated = flag("sysctl.proc_translated")
        return Self(appleSilicon: flag("hw.optional.arm64") || translated, translated: translated)
    }
}

public struct TrustedUpdate: Sendable {
    public let manifest: UpdateManifest
    public let artifact: UpdateArtifact
    public let payloadSHA256: String
    public let expiresAt: Date
    public let installed: InstalledUpdateVersion
    fileprivate init(
        manifest: UpdateManifest, artifact: UpdateArtifact, payload: Data, expiresAt: Date,
        installed: InstalledUpdateVersion
    ) {
        self.manifest = manifest
        self.artifact = artifact
        payloadSHA256 = UpdateManifestValidator.digest(payload)
        self.expiresAt = expiresAt
        self.installed = installed
    }
}

public enum UpdateCheckResult: Sendable {
    case current
    case available(TrustedUpdate)
}

public enum UpdateManifestValidator {
    public static let metadataBytes = 256 * 1024
    public static let downloadBytes: Int64 = 30 * 1024 * 1024
    public static let installedBytes: Int64 = 60 * 1024 * 1024
    public static let requestSeconds: TimeInterval = 15

    public static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func validate(
        _ envelope: Data, ring: UpdateKeyRing, channel: UpdateChannel,
        installed: InstalledUpdateVersion, hardware: UpdateHardware = .current(),
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        now: Date = Date()
    ) throws -> UpdateCheckResult {
        guard ring.format == 1, !ring.keys.isEmpty, ring.keys.count <= 16,
            Set(ring.keys.map(\.id)).count == ring.keys.count
        else { throw UpdateFailure.configurationMissing }
        guard envelope.count <= metadataBytes else { throw UpdateFailure.exceeded }
        let signed = try JSONDecoder().decode(SignedUpdateManifest.self, from: envelope)
        guard signed.payload.count <= metadataBytes, signed.signature.count == 64 else {
            throw UpdateFailure.signature
        }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: signed.payload)
        guard try canonicalJSON(manifest) == signed.payload else { throw UpdateFailure.invalidManifest }
        guard let key = ring.keys.first(where: { $0.id == manifest.keyID }), key.publicKey.count == 32,
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey),
            publicKey.isValidSignature(signed.signature, for: signed.payload)
        else { throw UpdateFailure.signature }
        let version = try UpdateVersion(manifest.version)
        guard let published = date(manifest.publishedAt), let expires = date(manifest.expiresAt),
            published <= now, published < expires, now < expires,
            key.notBefore <= published, published < key.notAfter,
            key.notBefore <= now, now < key.notAfter
        else { throw UpdateFailure.expired }
        let withinMaximum = try key.maximumVersion.map({ version <= (try UpdateVersion($0)) }) ?? true
        guard version >= (try UpdateVersion(key.minimumVersion)), withinMaximum
        else { throw UpdateFailure.signature }
        guard manifest.channel == channel, key.channels.contains(channel), !manifest.draft,
            channel != .stable || version.prerelease == nil
        else { throw UpdateFailure.channel }
        guard manifest.format == 1, manifest.tag == "v" + manifest.version, manifest.build > 0,
            matches(manifest.sourceCommit, #"^[0-9a-f]{40}([0-9a-f]{24})?$"#),
            manifest.keyID.utf8.count <= 80, manifest.releaseNotes.utf8.count <= 64 * 1024,
            manifest.artifacts.count == 3,
            Set(manifest.artifacts.map(\.variant)) == Set(UpdateVariant.allCases),
            matches(manifest.minimumOS, #"^[1-9][0-9]?\.[0-9]{1,2}(\.[0-9]{1,2})?$"#)
        else { throw UpdateFailure.invalidManifest }
        let minimum = manifest.minimumOS.split(separator: ".").map { Int($0)! }
        let actual = [
            operatingSystem.majorVersion, operatingSystem.minorVersion, operatingSystem.patchVersion,
        ]
        guard !actual.lexicographicallyPrecedes(minimum + Array(repeating: 0, count: 3 - minimum.count))
        else {
            throw UpdateFailure.incompatible
        }
        for artifact in manifest.artifacts {
            guard artifact.downloadBytes > 0, artifact.downloadBytes <= downloadBytes,
                artifact.installedBytes > 0, artifact.installedBytes <= installedBytes,
                matches(artifact.sha256, #"^[0-9a-f]{64}$"#),
                matches(artifact.manifestSHA256, #"^[0-9a-f]{64}$"#)
            else { throw UpdateFailure.exceeded }
            let basename = "WeGit-\(manifest.version)-macos-\(artifact.variant.rawValue)-adhoc"
            guard artifact.url == assetURL(tag: manifest.tag, name: basename + ".dmg").absoluteString,
                artifact.manifestURL
                    == assetURL(tag: manifest.tag, name: basename + ".manifest.json").absoluteString
            else { throw UpdateFailure.source }
        }
        guard version >= installed.version, version != installed.version || manifest.build >= installed.build
        else {
            throw UpdateFailure.downgrade
        }
        if version == installed.version, manifest.build == installed.build { return .current }
        let variant = installed.variant
        guard variant != .applesilicon || hardware.appleSilicon,
            variant != .intel || !hardware.appleSilicon || hardware.translated,
            let artifact = manifest.artifacts.first(where: { $0.variant == variant })
        else { throw UpdateFailure.incompatible }
        return .available(
            TrustedUpdate(
                manifest: manifest, artifact: artifact, payload: signed.payload,
                expiresAt: min(expires, key.notAfter), installed: installed))
    }

    public static func metadataURL(channel: UpdateChannel) -> URL {
        URL(string: "https://wegit.willxue.com/updates/\(channel.rawValue).json")!
    }
    static func assetURL(tag: String, name: String) -> URL {
        URL(string: "https://github.com/WeOpen/WeGit/releases/download/\(tag)/\(name)")!
    }
    static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
