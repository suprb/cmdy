/// Coalesces manual draw service without consuming a newer request when an
/// older frame commits. The renderer owns visibility, pacing and GPU gates;
/// this state never starts a timer or schedules work by itself.
struct InteractiveDrawRequests {
    private(set) var generation: UInt64 = 0
    private var committedGeneration: UInt64 = 0
    private(set) var serviceIsQueued = false
    private(set) var isDrawing = false

    var isPending: Bool { generation != committedGeneration }

    mutating func request() {
        generation &+= 1
    }

    mutating func queueServiceIfNeeded(blocked: Bool) -> Bool {
        guard isPending, !serviceIsQueued, !isDrawing, !blocked else { return false }
        serviceIsQueued = true
        return true
    }

    mutating func beginService() -> Bool {
        serviceIsQueued = false
        return isPending
    }

    mutating func beginDraw() -> UInt64? {
        guard !isDrawing else { return nil }
        isDrawing = true
        return generation
    }

    mutating func finishDraw(committed generation: UInt64?) {
        // Cancellation during a draw must not be undone by its completion.
        if let generation, isPending { committedGeneration = generation }
        isDrawing = false
    }

    mutating func cancel() {
        committedGeneration = generation
        // An already queued closure can service a later request. Keeping its
        // ownership avoids enqueueing a second closure before it runs.
    }
}
