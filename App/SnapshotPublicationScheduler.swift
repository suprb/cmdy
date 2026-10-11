import Foundation

/// Worker-queue scheduling policy. A keyboard response may remove the usual
/// 1 ms coalescing wait, but every capture still starts in a later queue turn.
/// No observer, timer, terminal row, or wall-clock read is owned by this value.
struct SnapshotPublicationScheduler: Sendable {
    static let coalescingDelay = 0.001
    static let responseLifetime = 0.15
    // Only the exceptional no-delay path is capped here. Ordinary output and
    // renderer presentation retain their independent, existing budgets.
    static let minimumExpeditedInterval = 1.0 / 120.0

    enum Kind: Equatable, Sendable { case delayed, immediate }

    struct Request: Equatable, Sendable {
        let generation: UInt64
        let kind: Kind
        let readyAt: Double
    }

    struct Service: Equatable, Sendable {
        let generation: UInt64
        let kind: Kind
        let readyAt: Double
    }

    struct Action: Sendable {
        var capture: Request?
        var enqueue: Service?
    }

    private(set) var pending: Request?
    private(set) var responseDeadline: Double?
    private var requestGeneration: UInt64 = 0
    private var serviceGeneration: UInt64 = 0
    private var delayedService: Service?
    private var immediateService: Service?
    private var lastExpeditedPublication: Double?
    var isScheduled: Bool { pending != nil }
    var queuedServiceCount: Int {
        (delayedService == nil ? 0 : 1) + (immediateService == nil ? 0 : 1)
    }

    mutating func noteUserInput(at time: Double) {
        guard time.isFinite else { return }
        responseDeadline = time + Self.responseLifetime
    }

    /// Cancellation removes unused response intent, not already pending
    /// content. A detached view must not cause parser damage to be thrown away.
    mutating func cancelUserInput() { responseDeadline = nil }

    /// `outputContinues`: the PTY already holds more output than this read.
    /// A large response (a paste echo, a full-screen redraw) arrives in
    /// kernel-buffer pieces; capturing its first piece at once would draw a
    /// partial screen and hold the complete one behind it for a refresh. Such
    /// a piece coalesces normally and leaves the input credit to the read
    /// that drains the burst.
    mutating func request(at clock: @autoclosure () -> Double, fromPTYOutput: Bool,
                          outputContinues: Bool = false) -> Service? {
        // Busy PTY callbacks usually only join existing work. Preserve the
        // cheap coalescing path without even evaluating the monotonic clock.
        // Host callbacks cannot promote or consume a keyboard-response credit.
        if pending != nil, !fromPTYOutput || responseDeadline == nil { return nil }
        let time = clock()
        precondition(time.isFinite)
        let withinResponse = responseDeadline.map { time < $0 } == true
        if !withinResponse { responseDeadline = nil }
        let respondsToInput = fromPTYOutput && withinResponse && !outputContinues
        if respondsToInput { responseDeadline = nil }
        let belowCeiling = lastExpeditedPublication.map {
            time >= $0 + Self.minimumExpeditedInterval
        } ?? true
        let expedite = respondsToInput && belowCeiling
        if pending == nil || (expedite && pending?.kind == .delayed) {
            requestGeneration &+= 1
            pending = Request(generation: requestGeneration,
                              kind: expedite ? .immediate : .delayed,
                              readyAt: time + (expedite ? 0 : Self.coalescingDelay))
        }
        return serviceForPending()
    }

    /// A queued service may outlive a synchronous reset. Its ownership is
    /// retained so repeated reset/request cycles cannot accumulate closures.
    /// When it wakes early for a newer request, it rearms exactly one service.
    mutating func fire(_ service: Service, at time: Double) -> Action {
        precondition(time.isFinite)
        switch service.kind {
        case .delayed:
            guard delayedService == service else { return Action() }
            delayedService = nil
        case .immediate:
            guard immediateService == service else { return Action() }
            immediateService = nil
        }
        guard let pending, pending.kind == service.kind else { return Action() }
        guard time >= pending.readyAt else {
            return Action(enqueue: serviceForPending())
        }
        self.pending = nil
        if pending.kind == .immediate { lastExpeditedPublication = time }
        return Action(capture: pending)
    }

    /// A synchronous resize or viewport capture owns the latest parser state.
    /// Old services become inert or honor the next request's explicit deadline;
    /// retaining their ownership prevents duplicate queued callbacks.
    mutating func resetPendingCapture() {
        pending = nil
        responseDeadline = nil
    }

    private mutating func serviceForPending() -> Service? {
        guard let pending else { return nil }
        switch pending.kind {
        case .delayed: guard delayedService == nil else { return nil }
        case .immediate: guard immediateService == nil else { return nil }
        }
        serviceGeneration &+= 1
        let service = Service(generation: serviceGeneration, kind: pending.kind,
                              readyAt: pending.readyAt)
        switch service.kind {
        case .delayed: delayedService = service
        case .immediate: immediateService = service
        }
        return service
    }
}
