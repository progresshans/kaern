import CoreServices
import Foundation

/// Watches directories with FSEvents and reports changed paths in batches.
///
/// FSEvents coalesces events for `latency` seconds, which doubles as the refresh debounce.
/// Paths are canonical (symlinks resolved, e.g. `/private/tmp/...`).
public final class FileSystemWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> Void

    private final class CallbackBox {
        let handler: Handler
        init(handler: @escaping Handler) { self.handler = handler }
    }

    private let paths: [String]
    private let latency: TimeInterval
    private let box: CallbackBox
    private let queue = DispatchQueue(label: "com.progresshans.kaern.FileSystemWatcher")
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 0.3, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.box = CallbackBox(handler: handler)
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (array as NSArray).compactMap { $0 as? String }
            box.handler(paths)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Resolves symlinks the way FSEvents reports paths (`/tmp` → `/private/tmp`).
public func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
