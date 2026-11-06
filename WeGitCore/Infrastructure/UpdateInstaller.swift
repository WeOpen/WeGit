import CryptoKit
import Darwin
import Foundation
import Security

public struct UpdateDataBackup: Sendable {
    public let originalPreferences: Data
    public let currentPreferences: Data
    public let currentStoreBackup: ApplicationStoreBackup?
    public init(
        originalPreferences: Data, currentPreferences: Data, currentStoreBackup: ApplicationStoreBackup? = nil
    ) throws {
        for data in [originalPreferences, currentPreferences] {
            guard data.count <= 8 * 1024 * 1024,
                let value = try PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                value["format"] as? Int == 1, value["values"] as? [String: Any] != nil
            else { throw UpdateFailure.invalidManifest }
        }
        self.originalPreferences = originalPreferences
        self.currentPreferences = currentPreferences
        self.currentStoreBackup = currentStoreBackup
        if let store = currentStoreBackup {
            guard store.bytes <= 64 * 1024 * 1024, store.data.prefix(16) == Data("SQLite format 3\0".utf8),
                UpdateManifestValidator.digest(store.data) == store.sha256
            else { throw UpdateFailure.invalidManifest }
        }
    }
    public var byteCount: Int64 {
        Int64(originalPreferences.count + currentPreferences.count + (currentStoreBackup?.bytes ?? 0))
    }

    /// A caller restores this explicit original-format snapshot into its isolated
    /// preference domain after exiting v2. A running app's domain is never replaced here.
    public func originalValues() throws -> [String: Any] {
        let value =
            try PropertyListSerialization.propertyList(from: originalPreferences, format: nil)
            as? [String: Any]
        guard let values = value?["values"] as? [String: Any] else { throw UpdateFailure.changed }
        return values
    }
}

public struct UpdateInstallationActivity: Equatable, Sendable {
    public let busyTasks: Int
    public let windowIDs: Set<UUID>
    public let persistedWindowIDs: Set<UUID>
    public let persistenceFlushed: Bool
    public let generation: UInt64
    public init(
        busyTasks: Int, windowIDs: Set<UUID>, persistedWindowIDs: Set<UUID>,
        persistenceFlushed: Bool, generation: UInt64
    ) {
        self.busyTasks = busyTasks
        self.windowIDs = windowIDs
        self.persistedWindowIDs = persistedWindowIDs
        self.persistenceFlushed = persistenceFlushed
        self.generation = generation
    }
    func validate() throws {
        guard busyTasks == 0, windowIDs.count <= 32, windowIDs == persistedWindowIDs, persistenceFlushed
        else {
            throw UpdateFailure.busy
        }
    }
}

/// A write capability available only for a fresh, process-owned test directory.
/// Production target inspection uses the same preflight without this capability;
/// the out-of-process installer handoff remains a separate integration boundary.
public final class UpdateInstallationSandbox: @unchecked Sendable {
    public let root: URL
    public var currentApp: URL { root.appending(path: "WeGit.app") }
    public var replacementApp: URL { root.appending(path: "Replacement.app") }
    private let identity: RepositoryNodeIdentity
    static func canonical(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw UpdateFailure.changed }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
    public init() throws {
        let base = try Self.canonical(FileManager.default.temporaryDirectory)
            .appending(path: "com.willxue.wegit.update-tests")
        if mkdir(base.path, 0o700) != 0 && errno != EEXIST { throw UpdateFailure.changed }
        var info = stat()
        guard lstat(base.path, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
            info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else { throw UpdateFailure.changed }
        var template = Array(base.appending(path: "update-test-\(getpid())-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw UpdateFailure.changed }
        root = URL(
            fileURLWithPath: String(
                decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        identity = try RepositoryNodeIdentity.read(root, directory: true)
    }
    func validate() throws {
        var info = stat()
        guard try RepositoryNodeIdentity.read(root, directory: true) == identity,
            lstat(root.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else { throw UpdateFailure.changed }
    }

    /// Explicit cleanup after an isolated test has retained its evidence. Interrupted
    /// installers keep their packages/journal; general diff-cache cleanup cannot erase them.
    public func removeAfterInspection() throws {
        try validate()
        try FileManager.default.removeItem(at: root)
    }
}

public struct UpdateInstallPlan: Sendable {
    public let id: UUID
    public let currentApp: URL
    public let replacementApp: URL
    public let requiredBytes: Int64
    public let update: TrustedUpdate
    public let packageManifest: Data
    let oldTree: UpdateAppTree
    let newTree: UpdateAppTree
    let parent: RepositoryNodeIdentity
    let activity: UpdateInstallationActivity
    let backup: UpdateDataBackup
}

public struct UpdateInstallReceipt: Sendable {
    public let id: UUID
    public let installedApp: URL
    public let previousApp: URL
    public let originalPreferences: URL
    public let currentPreferences: URL
    public let journal: URL
    public let expectedVersion: String
    public let expectedBuild: UInt64
    fileprivate let sandbox: UpdateInstallationSandbox
    fileprivate let plan: UpdateInstallPlan
}

public enum UpdateInstaller {
    public static func preflight(
        currentApp: URL, replacementApp: URL, update: TrustedUpdate,
        packageManifest: Data, dataBackup: UpdateDataBackup, activity: UpdateInstallationActivity
    ) async throws -> UpdateInstallPlan {
        try activity.validate()
        guard Date() < update.expiresAt else { throw UpdateFailure.expired }
        return try await SnapshotIO.run { cancellation in
            let current = try UpdateInstallationSandbox.canonical(currentApp)
            let replacement = try UpdateInstallationSandbox.canonical(replacementApp)
            try validateParents(current)
            try validateParents(replacement)
            guard access(current.deletingLastPathComponent().path, W_OK | X_OK) == 0 else {
                throw UpdateFailure.changed
            }
            let parent = try RepositoryNodeIdentity.read(current.deletingLastPathComponent(), directory: true)
            let old = try UpdateAppTree.read(current, cancellation: cancellation)
            let new = try UpdateAppTree.read(replacement, cancellation: cancellation)
            try verifySignature(current)
            try validateCurrent(current, update: update)
            try verifySignature(replacement)
            try validatePackage(packageManifest, tree: new, app: replacement, update: update)
            guard old.root.device == new.root.device else { throw UpdateFailure.incompatible }
            let required = old.bytes + new.bytes + dataBackup.byteCount
            var volume = statfs()
            guard statfs(current.deletingLastPathComponent().path, &volume) == 0,
                volume.f_bavail <= UInt64(Int64.max) / UInt64(volume.f_bsize),
                Int64(volume.f_bavail * UInt64(volume.f_bsize)) >= required
            else { throw UpdateFailure.insufficientSpace }
            try cancellation.check()
            guard
                try RepositoryNodeIdentity.read(current.deletingLastPathComponent(), directory: true)
                    == parent
            else {
                throw UpdateFailure.changed
            }
            return UpdateInstallPlan(
                id: UUID(), currentApp: current, replacementApp: replacement,
                requiredBytes: required, update: update, packageManifest: packageManifest, oldTree: old,
                newTree: new, parent: parent,
                activity: activity, backup: dataBackup)
        }
    }

    public static func install(
        _ plan: UpdateInstallPlan, in sandbox: UpdateInstallationSandbox,
        activity: UpdateInstallationActivity
    ) async throws -> UpdateInstallReceipt {
        try activity.validate()
        guard activity == plan.activity, Date() < plan.update.expiresAt,
            plan.currentApp.path == sandbox.currentApp.path,
            plan.replacementApp.path == sandbox.replacementApp.path
        else { throw UpdateFailure.changed }
        return try await SnapshotIO.run { cancellation in
            try sandbox.validate()
            guard try RepositoryNodeIdentity.read(sandbox.root, directory: true) == plan.parent,
                try UpdateAppTree.read(plan.currentApp, cancellation: cancellation) == plan.oldTree,
                try UpdateAppTree.read(plan.replacementApp, cancellation: cancellation) == plan.newTree
            else { throw UpdateFailure.changed }
            let previous = sandbox.root.appending(path: "Previous.app")
            let originalData = sandbox.root.appending(path: "original-preferences.plist")
            let currentData = sandbox.root.appending(path: "current-preferences.plist")
            let journal = sandbox.root.appending(path: "install-journal.json")
            let receipt = UpdateInstallReceipt(
                id: plan.id, installedApp: plan.currentApp, previousApp: previous,
                originalPreferences: originalData, currentPreferences: currentData, journal: journal,
                expectedVersion: plan.update.manifest.version, expectedBuild: plan.update.manifest.build,
                sandbox: sandbox, plan: plan)
            try exclusiveWrite(plan.backup.originalPreferences, to: originalData)
            try exclusiveWrite(plan.backup.currentPreferences, to: currentData)
            try writeJournal(receipt, phase: "prepared", replacing: false)
            try cancellation.check()
            try sandbox.validate()
            guard try UpdateAppTree.read(plan.currentApp, cancellation: cancellation) == plan.oldTree,
                try UpdateAppTree.read(plan.replacementApp, cancellation: cancellation) == plan.newTree
            else { throw UpdateFailure.changed }
            try moveExclusive(plan.currentApp, previous)
            try sync(sandbox.root)
            do {
                try writeJournal(receipt, phase: "previous-saved")
                try cancellation.check()
                try sandbox.validate()
                guard try UpdateAppTree.read(plan.replacementApp, cancellation: cancellation) == plan.newTree
                else {
                    throw UpdateFailure.changed
                }
                try moveExclusive(plan.replacementApp, plan.currentApp)
                try sync(sandbox.root)
                guard try UpdateAppTree.read(plan.currentApp, cancellation: cancellation) == plan.newTree
                else {
                    throw UpdateFailure.changed
                }
                try writeJournal(receipt, phase: "installed-awaiting-launch")
                return receipt
            } catch {
                // Never overwrite an externally changed path. Restore only packages
                // whose complete identities and bytes still match this transaction.
                if !FileManager.default.fileExists(atPath: plan.currentApp.path),
                    (try? UpdateAppTree.read(previous, cancellation: IOCancellation())) == plan.oldTree
                {
                    try moveExclusive(previous, plan.currentApp)
                    try sync(sandbox.root)
                    try writeJournal(receipt, phase: "restored-after-interruption")
                } else if (try? UpdateAppTree.read(plan.currentApp, cancellation: IOCancellation()))
                    == plan.newTree,
                    (try? UpdateAppTree.read(previous, cancellation: IOCancellation())) == plan.oldTree
                {
                    let failed = sandbox.root.appending(path: "FailedReplacement.app")
                    try moveExclusive(plan.currentApp, failed)
                    do { try moveExclusive(previous, plan.currentApp) } catch {
                        if !FileManager.default.fileExists(atPath: plan.currentApp.path) {
                            try moveExclusive(failed, plan.currentApp)
                        }
                        throw error
                    }
                    try sync(sandbox.root)
                    try writeJournal(receipt, phase: "restored-after-interruption")
                }
                throw error
            }
        }
    }

    /// A failed launch restores the byte-identical old package. The rejected new
    /// package and both preference snapshots remain available for inspection.
    public static func rollback(_ receipt: UpdateInstallReceipt) async throws {
        try await SnapshotIO.run { cancellation in
            try receipt.sandbox.validate()
            guard
                try UpdateAppTree.read(receipt.installedApp, cancellation: cancellation)
                    == receipt.plan.newTree,
                try UpdateAppTree.read(receipt.previousApp, cancellation: cancellation)
                    == receipt.plan.oldTree,
                try readSmall(receipt.originalPreferences, limit: 8 * 1024 * 1024)
                    == receipt.plan.backup.originalPreferences,
                try readSmall(receipt.currentPreferences, limit: 8 * 1024 * 1024)
                    == receipt.plan.backup.currentPreferences
            else { throw UpdateFailure.changed }
            try cancellation.check()
            let failed = receipt.sandbox.root.appending(path: "FailedReplacement.app")
            try moveExclusive(receipt.installedApp, failed)
            do {
                try moveExclusive(receipt.previousApp, receipt.installedApp)
            } catch {
                if !FileManager.default.fileExists(atPath: receipt.installedApp.path) {
                    try moveExclusive(failed, receipt.installedApp)
                }
                throw error
            }
            try sync(receipt.sandbox.root)
            guard
                try UpdateAppTree.read(receipt.installedApp, cancellation: cancellation)
                    == receipt.plan.oldTree
            else {
                throw UpdateFailure.changed
            }
            try writeJournal(receipt, phase: "rolled-back")
        }
    }

    public static func confirmLaunch(
        _ receipt: UpdateInstallReceipt, observedVersion: String,
        observedBuild: UInt64
    ) async throws {
        guard observedVersion == receipt.expectedVersion, observedBuild == receipt.expectedBuild else {
            throw UpdateFailure.installation
        }
        try await SnapshotIO.run { cancellation in
            try receipt.sandbox.validate()
            guard
                try UpdateAppTree.read(receipt.installedApp, cancellation: cancellation)
                    == receipt.plan.newTree
            else {
                throw UpdateFailure.changed
            }
            try writeJournal(receipt, phase: "launch-verified")
        }
    }

    static func validatePackage(_ data: Data, tree: UpdateAppTree, app: URL, update: TrustedUpdate)
        throws
    {
        let infoBytes = try readSmall(app.appending(path: "Contents/Info.plist"), limit: 64 * 1024)
        guard data.count <= UpdateManifestValidator.metadataBytes,
            UpdateManifestValidator.digest(data) == update.artifact.manifestSHA256,
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            report["gitCommit"] as? String == update.manifest.sourceCommit,
            report["releaseTag"] as? String == update.manifest.tag,
            report["version"] as? String == String(update.manifest.version.split(separator: "-")[0]),
            report["buildVersion"] as? String == String(update.manifest.build),
            report["bundleIdentifier"] as? String == "com.willxue.wegit",
            report["workspaceDirty"] as? Bool == false,
            report["mode"] as? String == "adhoc", report["signing"] as? String == "ad-hoc",
            report["notarized"] as? Bool == false,
            report["minimumSystemVersion"] as? String == update.manifest.minimumOS,
            let sourceReceipt = tree.files["Contents/Resources/build-source.json"],
            report["buildReceiptSHA256"] as? String == sourceReceipt.hash,
            report["architectures"] as? [String] == update.artifact.variant.architectures,
            report["archiveSHA256"] as? String == update.artifact.sha256,
            report["imageBytes"] as? Int64 == update.artifact.downloadBytes,
            report["bundleBytes"] as? Int64 == tree.bytes, tree.bytes == update.artifact.installedBytes,
            let binaries = report["binaries"] as? [String: [String: Any]],
            Set(binaries.keys).isSuperset(of: ["Contents/MacOS/WeGit", "Contents/Helpers/WeGitAskPass"]),
            let plistData = tree.files["Contents/Info.plist"],
            plistData.hash == UpdateManifestValidator.digest(infoBytes),
            let info = try PropertyListSerialization.propertyList(
                from: infoBytes, format: nil)
                as? [String: Any],
            info["CFBundleIdentifier"] as? String == "com.willxue.wegit",
            info["LSMinimumSystemVersion"] as? String == update.manifest.minimumOS,
            info["CFBundleShortVersionString"] as? String == report["version"] as? String,
            info["CFBundleVersion"] as? String == report["buildVersion"] as? String
        else { throw UpdateFailure.invalidManifest }
        try validateReleaseVersion(info: info, expected: update.manifest.version)
        let sourceData = try readSmall(
            app.appending(path: "Contents/Resources/build-source.json"), limit: 256 * 1024)
        let sourceReport = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any]
        let sources = sourceReport?["sourceFiles"] as? [String: String] ?? [:]
        let declaresUpdater = sources.keys.contains { $0.hasPrefix("WeGitUpdater/") }
        if declaresUpdater {
            guard binaries["Contents/Helpers/WeGitUpdater"] != nil,
                tree.files["Contents/Helpers/WeGitUpdater"] != nil
            else {
                throw UpdateFailure.invalidManifest
            }
        }
        for (path, value) in binaries {
            guard let file = tree.files[path], let expected = value["sha256"] as? String,
                file.hash == expected,
                value["architectures"] as? [String] == update.artifact.variant.architectures
            else { throw UpdateFailure.changed }
            if declaresUpdater {
                guard let minimums = value["minimumSystemVersions"] as? [String: String],
                    Set(minimums.keys) == Set(update.artifact.variant.architectures)
                else { throw UpdateFailure.incompatible }
                for version in minimums.values {
                    guard
                        version.range(of: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil
                    else {
                        throw UpdateFailure.incompatible
                    }
                    let parts = version.split(separator: ".").compactMap { Int($0) }
                    guard parts.count >= 2, parts.count == version.split(separator: ".").count,
                        ![26, 0, 0].lexicographicallyPrecedes(
                            parts + Array(repeating: 0, count: 3 - parts.count))
                    else {
                        throw UpdateFailure.incompatible
                    }
                }
            }
        }
    }

    static func validateCurrent(_ app: URL, update: TrustedUpdate) throws {
        let data = try readSmall(app.appending(path: "Contents/Info.plist"), limit: 64 * 1024)
        guard
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            info["CFBundleIdentifier"] as? String == "com.willxue.wegit",
            info["CFBundleShortVersionString"] as? String
                == String(update.installed.version.rawValue.split(separator: "-")[0]),
            info["CFBundleVersion"] as? String == String(update.installed.build)
        else { throw UpdateFailure.changed }
        try validateReleaseVersion(info: info, expected: update.installed.version.rawValue)
        let source = try readSmall(
            app.appending(path: "Contents/Resources/build-source.json"), limit: 256 * 1024)
        guard let receipt = try JSONSerialization.jsonObject(with: source) as? [String: Any],
            receipt["architectures"] as? [String] == update.installed.variant.architectures
        else { throw UpdateFailure.incompatible }
    }

    static func validateReleaseVersion(info: [String: Any], expected: String) throws {
        if let version = info["WeGitReleaseVersion"] as? String {
            guard version == expected else { throw UpdateFailure.changed }
        } else {
            guard try UpdateVersion(expected).prerelease == nil,
                info["CFBundleShortVersionString"] as? String == expected
            else { throw UpdateFailure.changed }
        }
    }

    static func readSmall(_ url: URL, limit: Int) throws -> Data {
        let identity = try RepositoryNodeIdentity.read(url)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            info.st_size >= 0, info.st_size <= limit
        else { throw UpdateFailure.changed }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UpdateFailure.changed }
        defer { Darwin.close(fd) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit - result.count + 1))
            if count < 0, errno == EINTR { continue }
            guard count >= 0, result.count + max(count, 0) <= limit else { throw UpdateFailure.changed }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == info.st_size, try RepositoryNodeIdentity.read(url) == identity else {
            throw UpdateFailure.changed
        }
        return result
    }

    static func verifySignature(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(
                    rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil
            ) == errSecSuccess
        else { throw UpdateFailure.signature }
    }

    static func validateParents(_ path: URL) throws {
        var parent = path.deletingLastPathComponent()
        while parent.path != "/" {
            _ = try RepositoryNodeIdentity.read(parent, directory: true)
            parent.deleteLastPathComponent()
        }
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_uid == getuid() else { throw UpdateFailure.changed }
    }

    static func moveExclusive(_ source: URL, _ target: URL) throws {
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw UpdateFailure.changed
        }
    }

    static func exclusiveWrite(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UpdateFailure.changed }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw UpdateFailure.changed }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw UpdateFailure.changed }
        try sync(url.deletingLastPathComponent())
    }

    static func sync(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UpdateFailure.changed }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw UpdateFailure.changed }
    }

    private static func writeJournal(_ receipt: UpdateInstallReceipt, phase: String, replacing: Bool = true)
        throws
    {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "format": 1, "id": receipt.id.uuidString, "phase": phase,
                "version": receipt.expectedVersion, "build": receipt.expectedBuild,
                "manifestSHA256": receipt.plan.update.payloadSHA256,
                "originalPreferencesSHA256": UpdateManifestValidator.digest(
                    receipt.plan.backup.originalPreferences),
                "currentPreferencesSHA256": UpdateManifestValidator.digest(
                    receipt.plan.backup.currentPreferences),
            ], options: [.sortedKeys])
        try receipt.sandbox.validate()
        if !replacing {
            try exclusiveWrite(data, to: receipt.journal)
            return
        }
        let oldData = try readSmall(receipt.journal, limit: 16 * 1024)
        guard let oldJournal = try JSONSerialization.jsonObject(with: oldData) as? [String: Any],
            oldJournal["id"] as? String == receipt.id.uuidString,
            oldJournal["manifestSHA256"] as? String == receipt.plan.update.payloadSHA256
        else { throw UpdateFailure.changed }
        let temporary = receipt.sandbox.root.appending(path: "journal-\(UUID().uuidString)")
        try exclusiveWrite(data, to: temporary)
        var info = stat()
        guard lstat(receipt.journal.path, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            info.st_uid == getuid(),
            rename(temporary.path, receipt.journal.path) == 0
        else { throw UpdateFailure.changed }
        try sync(receipt.sandbox.root)
    }
}

struct UpdateAppFile: Equatable, Sendable {
    let identity: RepositoryNodeIdentity
    let hash: String
    let mode: UInt16
}

struct UpdateAppTree: Equatable, Sendable {
    let root: RepositoryNodeIdentity
    let files: [String: UpdateAppFile]
    let bytes: Int64
    let directories: [String: RepositoryNodeIdentity]

    static func read(_ app: URL, cancellation: IOCancellation) throws -> Self {
        let root = try RepositoryNodeIdentity.read(app, directory: true)
        var enumerationFailed = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: app, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                })
        else {
            throw UpdateFailure.changed
        }
        var files: [String: UpdateAppFile] = [:]
        var bytes: Int64 = 0
        var directories: [String: RepositoryNodeIdentity] = [:]
        var entries = 0
        for case let url as URL in enumerator {
            try cancellation.check()
            entries += 1
            guard entries <= 10000 else { throw UpdateFailure.exceeded }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid() else { throw UpdateFailure.changed }
            if info.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) {
                directories[String(url.path.dropFirst(app.path.count + 1))] = try RepositoryNodeIdentity.read(
                    url, directory: true)
                continue
            }
            guard info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), info.st_size >= 0,
                info.st_size <= UpdateManifestValidator.installedBytes - bytes
            else { throw UpdateFailure.exceeded }
            let identity = try RepositoryNodeIdentity.read(url)
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw UpdateFailure.changed }
            let stamp = SnapshotFileStamp(info)
            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var total: Int64 = 0
            do {
                while true {
                    try cancellation.check()
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else { throw UpdateFailure.changed }
                    if count == 0 { break }
                    total += Int64(count)
                    guard total <= info.st_size else { throw UpdateFailure.changed }
                    hash.update(data: Data(buffer.prefix(count)))
                }
                var final = stat()
                guard fstat(fd, &final) == 0, SnapshotFileStamp(final) == stamp, total == info.st_size else {
                    throw UpdateFailure.changed
                }
                Darwin.close(fd)
            } catch {
                Darwin.close(fd)
                throw error
            }
            bytes += total
            files[String(url.path.dropFirst(app.path.count + 1))] = UpdateAppFile(
                identity: identity,
                hash: hash.finalize().map { String(format: "%02x", $0) }.joined(), mode: info.st_mode & 0o777)
        }
        guard !enumerationFailed, try RepositoryNodeIdentity.read(app, directory: true) == root else {
            throw UpdateFailure.changed
        }
        for (path, file) in files {
            guard try RepositoryNodeIdentity.read(app.appending(path: path)) == file.identity else {
                throw UpdateFailure.changed
            }
        }
        for (path, identity) in directories {
            guard try RepositoryNodeIdentity.read(app.appending(path: path), directory: true) == identity
            else { throw UpdateFailure.changed }
        }
        return Self(root: root, files: files, bytes: bytes, directories: directories)
    }
}
