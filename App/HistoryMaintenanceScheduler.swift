/// Serial model-queue policy for representation-only retained history work.
/// Busy output only advances an activity generation; it does not read a clock
/// or enqueue another closure. There is no timer after a scan completes.
struct HistoryMaintenanceScheduler: Sendable {
    static let quietDelay = 0.150
    static let batchDelay = 0.002
    static let maximumRows = 32

    struct Service: Equatable, Sendable {
        let generation: UInt64
        let activityGeneration: UInt64
        let delay: Double
    }

    struct Batch: Equatable, Sendable {
        let generation: UInt64
        let activityGeneration: UInt64
        let startingAt: Int
    }

    struct Action: Sendable {
        var batch: Batch?
        var enqueue: Service?
    }

    private(set) var nextAbsoluteRow = 0
    private(set) var enabled = true
    private(set) var needsWork = false
    private(set) var queuedService: Service?
    private(set) var activeBatch: Batch?
    private var activityGeneration: UInt64 = 0
    private var serviceGeneration: UInt64 = 0

    mutating func noteActivity() { activityGeneration &+= 1 }

    mutating func request(restart: Bool = false) -> Service? {
        guard enabled else { return nil }
        noteActivity()
        if restart { nextAbsoluteRow = 0 }
        needsWork = true
        return enqueue(after: Self.quietDelay)
    }

    mutating func fire(_ service: Service) -> Action {
        guard queuedService == service else { return Action() }
        queuedService = nil
        guard enabled, needsWork else { return Action() }
        // An activity change may have happened just before this callback. A
        // fresh quiet interval is required, even for a continuation batch.
        guard service.activityGeneration == activityGeneration else {
            return Action(enqueue: enqueue(after: Self.quietDelay))
        }
        let batch = Batch(generation: service.generation,
                          activityGeneration: activityGeneration,
                          startingAt: nextAbsoluteRow)
        activeBatch = batch
        return Action(batch: batch)
    }

    mutating func finish(_ batch: Batch, nextAbsoluteRow: Int, complete: Bool) -> Service? {
        guard activeBatch == batch else { return nil }
        activeBatch = nil
        guard enabled else { return nil }
        // Ignore stale scan progress if a reset or new activity arrived while
        // work was active. This also keeps a restarted absolute cursor intact.
        guard activityGeneration == batch.activityGeneration else {
            return enqueue(after: Self.quietDelay)
        }
        self.nextAbsoluteRow = max(0, nextAbsoluteRow)
        needsWork = !complete
        return needsWork ? enqueue(after: Self.batchDelay) : nil
    }

    mutating func cancel() {
        enabled = false
        needsWork = false
        activeBatch = nil
        nextAbsoluteRow = 0
        noteActivity()
        // Retain ownership of an already queued callback. A cancel/resume loop
        // cannot accumulate callbacks; the old one will rearm or become inert.
    }

    mutating func resume() {
        enabled = true
        nextAbsoluteRow = 0
        noteActivity()
    }

    private mutating func enqueue(after delay: Double) -> Service? {
        guard enabled, needsWork, queuedService == nil, activeBatch == nil else { return nil }
        serviceGeneration &+= 1
        let service = Service(generation: serviceGeneration,
                              activityGeneration: activityGeneration, delay: delay)
        queuedService = service
        return service
    }
}
