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

public final class ScriptWatcher: @unchecked Sendable {
    private let directory: URL
    private let onChange: @Sendable () -> Void
    private let debouncer: Debouncer
    private var stream: FSEventStreamRef?

    public init(directory: URL, debounce: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.onChange = onChange
        self.debouncer = Debouncer(delay: debounce, queue: .main)
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ScriptWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.debouncer.schedule { watcher.onChange() }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let paths = [directory.path] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
