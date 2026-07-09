#if os(macOS)
import CoreServices
import Foundation

/// Coalesced filesystem observation over a set of paths, via FSEvents.
///
/// Folders are watched recursively; per-file events are requested, so the
/// callback receives the concrete file paths that changed (created, written,
/// renamed, or removed — atomic-replace regeneration shows up as events on
/// the destination path). Works under `~/Library/Mobile Documents`: iCloud
/// changes land through fileproviderd as ordinary file writes.
///
/// Lifecycle: the stream's context retains the watcher, so it stays alive —
/// and keeps delivering — until `stop()` is called. Owners replacing a
/// watcher must `stop()` the old one or it leaks.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    let onChange: @Sendable ([String]) -> Void

    /// Starts watching immediately. Returns nil when the stream can't be
    /// created (e.g. no paths). `onChange` is invoked on `queue` with the
    /// coalesced changed paths; `latency` is FSEvents' coalescing window.
    public init?(
        paths: [String],
        latency: TimeInterval = 1.0,
        queue: DispatchQueue = .main,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        guard !paths.isEmpty else { return nil }
        self.queue = queue
        self.onChange = onChange

        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(self).toOpaque()
        context.release = { info in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).release()
        }

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String],
                  cfPaths.count == count
            else { return }
            watcher.onChange(cfPaths)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        ) else {
            Unmanaged.passUnretained(self).release()  // undo the context retain
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stops delivery and releases the stream (and its retain on the
    /// watcher). Idempotent.
    public func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)  // runs the context release callback
        FSEventStreamRelease(stream)
    }
}
#endif
