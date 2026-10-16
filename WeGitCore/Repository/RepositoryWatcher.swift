import CoreServices
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
        let paths = Array(
            Set([location.root.path, location.gitDirectory.path, location.commonDirectory.path]))
        try self.init(paths: paths) { paths, flags in
            let scope = RepositoryRefreshScope.events(paths: paths, flags: flags, location: location)
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
