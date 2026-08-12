import Foundation
import CoreServices

public final class Debouncer: @unchecked Sendable {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: DispatchWorkItem?

    public init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    public func schedule(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        pending?.cancel()
        let item = DispatchWorkItem(block: work)
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// Retained by the FSEventStream as its context info pointer.
/// Holds the debouncer and onChange closure so that if ScriptWatcher is
/// released while the stream is still live, the callback can never touch
/// a freed object — the stream keeps this box alive until invalidation.
private final class WatcherContext: @unchecked Sendable {
    let debouncer: Debouncer
    let onChange: @Sendable () -> Void

    init(debounce: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        self.debouncer = Debouncer(delay: debounce, queue: .main)
        self.onChange = onChange
    }
}

public final class ScriptWatcher: @unchecked Sendable {
    private let directory: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private let lock = NSLock()

    public init(directory: URL, debounce: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        guard stream == nil else { lock.unlock(); return }
        lock.unlock()

        // The stream retains the context box via passRetained (+1).
        // The release callback balances that +1 when the stream is torn down.
        let context = WatcherContext(debounce: debounce, onChange: onChange)
        let rawContext = Unmanaged.passRetained(context).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // takeUnretainedValue: the stream still holds the +1; we don't own it here.
            let ctx = Unmanaged<WatcherContext>.fromOpaque(info).takeUnretainedValue()
            ctx.debouncer.schedule { ctx.onChange() }
        }

        var ctx = FSEventStreamContext(
            version: 0,
            info: rawContext,
            retain: nil,
            release: { rawPtr in
                // Called by FSEvents when the stream is released; balances passRetained.
                Unmanaged<WatcherContext>.fromOpaque(rawPtr!).release()
            },
            copyDescription: nil
        )

        let paths = [directory.path] as CFArray
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else {
            // FSEventStreamCreate won't call release if it returns nil, so balance manually.
            Unmanaged<WatcherContext>.fromOpaque(rawContext).release()
            return
        }

        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        FSEventStreamStart(newStream)

        lock.lock()
        // Re-check under lock: if another thread raced start() and won, tear down ours.
        if stream == nil {
            stream = newStream
            lock.unlock()
        } else {
            lock.unlock()
            FSEventStreamStop(newStream)
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
        }
    }

    public func stop() {
        lock.lock()
        let captured = stream
        stream = nil
        lock.unlock()

        guard let captured else { return }
        FSEventStreamStop(captured)
        FSEventStreamInvalidate(captured)
        // FSEventStreamRelease triggers the context release callback, freeing the box.
        FSEventStreamRelease(captured)
    }
}
