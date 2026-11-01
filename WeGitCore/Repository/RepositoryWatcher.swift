import CoreServices
import Darwin
import Foundation

private final class WatchCallback: @unchecked Sendable {
    let action: @Sendable ([String], [FSEventStreamEventFlags]) -> Void
    init(_ action: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void) { self.action = action }
}

/// FSEvents owns a retained callback box; no callback dereferences the watcher itself.
public final class RepositoryWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "com.willxue.wegit.fsevents", qos: .utility)

    public convenience init(paths: [String], onChange: @escaping @Sendable () -> Void) throws {
        try self.init(paths: paths) { _, _ in onChange() }
    }

    public convenience init(
        location: RepositoryLocation, onChange: @escaping @Sendable (RepositoryRefreshScope) -> Void
    ) throws {
        let candidates = Set([location.root.path, location.gitDirectory.path, location.commonDirectory.path])
        // FSEvents already watches descendants. Only the active session subscribes;
        // overlapping root/common/private paths must not multiply its event stream.
        let paths = candidates.filter { path in
            !candidates.contains { path.hasPrefix($0 + "/") }
        }.sorted()
        // FSEvents reports POSIX physical paths (/private/var), while Foundation
        // can preserve a system alias (/var). Resolve only at subscription time,
        // then translate event prefixes without a filesystem lookup per event.
        let aliases = candidates.compactMap { path -> (source: String, destination: String)? in
            guard let physical = realpath(path, nil) else { return nil }
            defer { free(physical) }
            let source = String(cString: physical)
            return source == path ? nil : (source, path)
        }.sorted { $0.source.count > $1.source.count }
        try self.init(paths: paths) { paths, flags in
            let normalized = paths.map { path in
                guard
                    let alias = aliases.first(where: { path == $0.source || path.hasPrefix($0.source + "/") })
                else {
                    return path
                }
                return alias.destination + path.dropFirst(alias.source.count)
            }
            let scope = RepositoryRefreshScope.events(paths: normalized, flags: flags, location: location)
            if !scope.isEmpty { onChange(scope) }
        }
    }

    private init(paths: [String], onEvents: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void)
        throws
    {
        let box = Unmanaged.passRetained(WatchCallback(onEvents))
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil,
            release: { pointer in if let pointer { Unmanaged<WatchCallback>.fromOpaque(pointer).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            Unmanaged<WatchCallback>.fromOpaque(info).takeUnretainedValue().action(paths, flags)
        }
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                        | kFSEventStreamCreateFlagUseCFTypes))
        else {
            box.release()
            throw ModelFailure.unsupported(L10n.text("无法创建仓库监听，请使用手动刷新。"))
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw ModelFailure.unsupported(L10n.text("无法启动仓库监听，请使用手动刷新。"))
        }
    }

    public func stop() {
        lock.withLock {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
    deinit { stop() }
}
