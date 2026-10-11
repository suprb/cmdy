import CmdyCore

/// Damage belongs to the interval since the last delivery, not just to the
/// newest parser capture. A capture may supersede another capture's contents,
/// but it cannot discard that capture's invalidation work.
struct SnapshotPublicationDamage: Equatable, Sendable {
    var rows: ClosedRange<Int>?
    var invalidatesAllRows: Bool

    init(rows: ClosedRange<Int>?, invalidatesAllRows: Bool = false) {
        self.rows = rows
        self.invalidatesAllRows = invalidatesAllRows
    }

    mutating func include(_ other: Self) {
        if let otherRows = other.rows {
            if let rows {
                self.rows = min(rows.lowerBound, otherRows.lowerBound)...max(rows.upperBound, otherRows.upperBound)
            } else {
                rows = otherRows
            }
        }
        invalidatesAllRows = invalidatesAllRows || other.invalidatesAllRows
    }
}

/// Main/worker handoff policy. TerminalModel holds its snapshot lock for every
/// operation. One queued main callback owns the mailbox, irrespective of how
/// many captures replace its pending value. An executing callback may be
/// followed by at most one queued callback; callbacks never invoke each other.
struct SnapshotPublicationMailbox {
    struct Publication {
        let snapshot: CoreTerminalSnapshot
        let damage: SnapshotPublicationDamage
        let generation: UInt64
        let deliveryEpoch: UInt64
        let started: UInt64
        fileprivate let coordinates: Coordinates
    }

    fileprivate struct Coordinates: Equatable {
        let rows: Int
        let cols: Int
        let retainedRowOrigin: Int
        let alternate: Bool
        let reflowEpoch: UInt64

        init(_ snapshot: CoreTerminalSnapshot, reflowEpoch: UInt64) {
            let grid = snapshot.grid
            rows = grid.rows
            cols = grid.cols
            retainedRowOrigin = grid.retainedRowOrigin
            alternate = grid.isAlternateBuffer
            self.reflowEpoch = reflowEpoch
        }
    }

    private(set) var pending: Publication?
    private(set) var callbackQueued = false
    private(set) var deliveryEpoch: UInt64 = 0

    /// Returns true only when the caller must enqueue a new main callback.
    mutating func offer(_ snapshot: CoreTerminalSnapshot, generation: UInt64,
                        reflowEpoch: UInt64, started: UInt64) -> Bool {
        let coordinates = Coordinates(snapshot, reflowEpoch: reflowEpoch)
        let damage = damageIncludingPending(snapshot, coordinates: coordinates)
        pending = Publication(snapshot: snapshot, damage: damage,
                              generation: generation, deliveryEpoch: deliveryEpoch,
                              started: started, coordinates: coordinates)
        guard !callbackQueued else { return false }
        callbackQueued = true
        return true
    }

    /// Called only by the already queued main callback. Taking the value hands
    /// its damage to that callback; a newer asynchronous capture must not make
    /// this value stale after its damage has left the mailbox.
    mutating func take() -> Publication? {
        precondition(callbackQueued)
        callbackQueued = false
        defer { pending = nil }
        return pending
    }

    /// A synchronous viewport installation takes ownership of pending damage
    /// too. Moving yDisp or appending history preserves retained-local row
    /// indices, so those operations do not require a full row-cache clear.
    mutating func replaceSynchronously(_ snapshot: CoreTerminalSnapshot,
                                      reflowEpoch: UInt64) -> SnapshotPublicationDamage {
        let coordinates = Coordinates(snapshot, reflowEpoch: reflowEpoch)
        let damage = damageIncludingPending(snapshot, coordinates: coordinates)
        discardPending()
        return damage
    }

    /// A synchronously installed snapshot or a detached observer supersedes
    /// pending delivery. Keep ownership of an already queued callback: it will
    /// either do nothing or service the next offered value in its own turn.
    @discardableResult
    mutating func discardPending() -> Bool {
        let discarded = pending != nil
        pending = nil
        deliveryEpoch &+= 1
        return discarded
    }

    func accepts(_ publication: Publication) -> Bool {
        publication.deliveryEpoch == deliveryEpoch
    }

    private func damageIncludingPending(
        _ snapshot: CoreTerminalSnapshot, coordinates: Coordinates
    ) -> SnapshotPublicationDamage {
        var damage = SnapshotPublicationDamage(rows: snapshot.dirtyRows)
        if let pending {
            damage.include(pending.damage)
            // Ordinary buffer growth and viewport motion leave row indices
            // valid. Remaps, dropped origins and shrink/reset may not. Keep
            // this fallback sticky across A/B/A transitions before delivery.
            if pending.coordinates != coordinates
                || snapshot.grid.bufferLineCount < pending.snapshot.grid.bufferLineCount {
                damage.invalidatesAllRows = true
            }
        }
        return damage
    }
}
