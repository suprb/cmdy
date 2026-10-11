import Foundation

/// At most one snapshot is being written and one newer snapshot is waiting.
/// JSON encoding, backup rotation, and disk I/O run on a utility queue. The
/// caller captures UI-owned values on the main thread before handing them off.
public final class SessionCheckpointWriter: @unchecked Sendable {
    typealias Writer = (Data) throws -> Void

    private let queue = DispatchQueue(label: "cmdy.session-checkpoints", qos: .utility)
    private let lock = NSLock()
    private let writer: Writer
    private let onError: ((Error) -> Void)?
    private var pending: [[String: Any]]?
    private var workerScheduled = false
    private var lastError: Error?
    // Accessed only by the writer queue.
    private var lastWrittenData: Data?

    public convenience init(
        destination: URL = SessionStore.url,
        onError: ((Error) -> Void)? = nil
    ) {
        self.init(
            writer: { try SessionStore.save(data: $0, to: destination) },
            onError: onError)
    }

    init(writer: @escaping Writer, onError: ((Error) -> Void)? = nil) {
        self.writer = writer
        self.onError = onError
    }

    public func submit(layouts: [[String: Any]]) {
        lock.lock()
        pending = layouts
        let shouldSchedule = !workerScheduled
        workerScheduled = true
        lock.unlock()
        if shouldSchedule { queue.async { [self] in drain() } }
    }

    /// Drop a stale queued snapshot while a workspace is being rebuilt. A
    /// write already in progress is allowed to complete atomically.
    public func discardPending() {
        lock.lock()
        pending = nil
        lock.unlock()
    }

    /// Used at orderly quit: the final capture wins over pending checkpoints,
    /// and the process stays alive until the serial writer has drained it.
    public func flush(layouts: [[String: Any]]) throws {
        submit(layouts: layouts)
        queue.sync {}
        lock.lock()
        let failure = lastError
        lock.unlock()
        if let failure { throw failure }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let snapshot = pending else {
                workerScheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            do {
                let data = try SessionStore.encodedSnapshot(layouts: snapshot)
                if data != lastWrittenData {
                    try writer(data)
                    lastWrittenData = data
                }
                lock.lock()
                lastError = nil
                lock.unlock()
            } catch {
                lock.lock()
                lastError = error
                lock.unlock()
                onError?(error)
            }
        }
    }
}

/// Pure scheduling policy shared by event-driven and transcript checkpoints.
/// Continuous resize/cwd activity cannot indefinitely postpone recovery.
public struct SessionCheckpointSchedule: Sendable {
    public let debounce: TimeInterval
    public let maximumDelay: TimeInterval
    public private(set) var firstChange: TimeInterval?

    public init(debounce: TimeInterval = 1.5, maximumDelay: TimeInterval = 10) {
        self.debounce = max(0, debounce)
        self.maximumDelay = max(0, maximumDelay)
    }

    public mutating func changed(at now: TimeInterval) -> TimeInterval {
        if firstChange == nil { firstChange = now }
        return min(now + debounce, (firstChange ?? now) + maximumDelay)
    }

    public mutating func captured() { firstChange = nil }
}
