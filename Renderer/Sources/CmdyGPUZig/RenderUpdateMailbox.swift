import CmdyNative
import Foundation

/// All fields are copied scalars, including the inline error text.
struct SessionUpdate: @unchecked Sendable {
    let value: CmdyRenderSessionUpdate
}

/// Worker-to-UI delivery never waits for the UI. Replaceable state occupies a
/// fixed number of slots. Explicit replies seal a FIFO boundary and require a
/// reservation made before native admission, bounding those boundaries too.
final class RenderUpdateMailbox: @unchecked Sendable {
    static let replyLimit = 64
    private let lock = NSLock()
    private var closed = false
    private var scheduled = false
    private var replies: [UInt64: Bool] = [:] // false: accepted, true: received
    private var sealed: [SessionUpdate] = []
    private var current = State()

    private struct Entry {
        let order: UInt64
        let update: SessionUpdate
    }
    private struct State {
        // READY, four timers, FPS, view/service work, CAPTURE, FRAME, initial/
        // unscoped error, frame error, CAPACITY, zero-ID inspection, latest state.
        var slots: [Entry?] = Array(repeating: nil, count: 14)
        var order: UInt64 = 0
        var occupied: UInt16 = 0
        var count: Int { occupied.nonzeroBitCount }
        mutating func put(_ slot: Int, _ value: CmdyRenderSessionUpdate) {
            slots[slot] = Entry(order: order, update: SessionUpdate(value: value))
            occupied |= UInt16(1) << slot
        }
        mutating func append(_ value: CmdyRenderSessionUpdate) {
            order &+= 1
            switch value.kind {
            case UInt32(CMDY_SESSION_ACTIONS):
                // Keep each timer's original origin and interval. Rebasing all
                // starts onto the latest event changes repeating cadence and
                // can postpone an already expired one-shot deadline.
                // The display lock travels with the animation start it qualifies.
                let pairs = [CMDY_RENDER_STOP_ANIMATION | CMDY_RENDER_START_ANIMATION | CMDY_RENDER_DISPLAY_LOCKED,
                             CMDY_RENDER_STOP_COALESCED | CMDY_RENDER_START_COALESCED,
                             CMDY_RENDER_STOP_KEYBOARD | CMDY_RENDER_START_KEYBOARD,
                             CMDY_RENDER_STOP_RECOVERY | CMDY_RENDER_START_RECOVERY]
                for (index, mask) in pairs.enumerated() where value.actions.flags & UInt32(mask) != 0 {
                    var timer = value
                    timer.actions.flags &= UInt32(mask); timer.actions.preferred_fps = 0
                    put(index + 1, timer)
                }
                if value.actions.preferred_fps > 0 {
                    var fps = value; fps.actions.flags = 0; put(5, fps)
                }
                let workMask = UInt32(CMDY_RENDER_INVALIDATE_VIEW | CMDY_RENDER_QUEUE_SERVICE | CMDY_RENDER_DRAW_MANUAL)
                if value.actions.flags & workMask != 0 {
                    var work = value
                    work.actions.flags = (value.actions.flags | (slots[6]?.update.value.actions.flags ?? 0)) & workMask
                    work.actions.preferred_fps = 0; put(6, work)
                }
                var state = value
                state.actions = CmdyRenderScheduleActions()
                put(13, state)
            case UInt32(CMDY_SESSION_READY): put(0, value)
            case UInt32(CMDY_SESSION_CAPTURE): put(7, value)
            case UInt32(CMDY_SESSION_FRAME): put(8, value)
            case UInt32(CMDY_SESSION_ERROR): put(value.identity.sequence == 0 ? 9 : 10, value)
            case UInt32(CMDY_SESSION_CAPACITY_AVAILABLE): put(11, value)
            case UInt32(CMDY_SESSION_INSPECTION): put(12, value)
            default: assertionFailure("Unknown native renderer update")
            }
        }
        mutating func drain(into result: inout [SessionUpdate]) {
            guard occupied != 0 else { order = 0; return }
            // Reserve an empty batch once. For existing reply boundaries use
            // Array's geometric append growth instead of repeatedly reserving
            // the exact next size, which can cause quadratic copying.
            if result.isEmpty { result.reserveCapacity(count) }
            // At most fourteen occupied slots. Select by the existing order,
            // then slot index, without allocating a sorting or mapping buffer.
            while occupied != 0 {
                var remaining = occupied
                var first = remaining.trailingZeroBitCount
                var firstOrder = slots[first]!.order
                remaining &= remaining - 1
                while remaining != 0 {
                    let index = remaining.trailingZeroBitCount
                    let candidateOrder = slots[index]!.order
                    if candidateOrder < firstOrder {
                        first = index
                        firstOrder = candidateOrder
                    }
                    remaining &= remaining - 1
                }
                result.append(slots[first]!.update)
                slots[first] = nil
                occupied &= ~(UInt16(1) << first)
            }
            order = 0
        }
    }

    func reserveReply(_ request: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, request != 0, replies[request] == nil, replies.count < Self.replyLimit else { return false }
        replies[request] = false
        return true
    }
    func releaseReply(_ request: UInt64) {
        lock.lock(); defer { lock.unlock() }
        replies.removeValue(forKey: request)
    }
    var replyCapacityFull: Bool {
        lock.lock(); defer { lock.unlock() }
        return replies.count == Self.replyLimit
    }
    var retainedUpdateCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sealed.count + current.count
    }
    /// True schedules the single UI wakeup; subsequent producers only update
    /// this mailbox until the UI finishes its current drain.
    func append(_ value: CmdyRenderSessionUpdate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        if value.request_id != 0 {
            guard replies[value.request_id] == false else { return false }
            replies[value.request_id] = true
            current.drain(into: &sealed)
            sealed.append(SessionUpdate(value: value))
        } else { current.append(value) }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }
    /// Keep the wakeup armed while callbacks execute outside the lock. New
    /// worker input is bounded independently and triggers one later drain.
    func take() -> [SessionUpdate] {
        lock.lock(); defer { lock.unlock() }
        var result = sealed
        sealed.removeAll()
        current.drain(into: &result)
        return result
    }
    func finishDrain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !closed && (!sealed.isEmpty || current.count != 0) { return true }
        scheduled = false
        return false
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        sealed.removeAll(); current = State(); replies.removeAll()
    }
}
