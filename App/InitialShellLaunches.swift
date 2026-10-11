/// Holds only initial shells whose caller must finish native window placement
/// before the PTY captures its first grid. Later splits keep their existing path.
@MainActor
final class InitialShellLaunches<Pane: AnyObject> {
    private let enabled: Bool
    private let deferred: Bool
    private var pending: [Pane] = []

    init(enabled: Bool, deferred: Bool) {
        self.enabled = enabled
        self.deferred = deferred
    }

    func schedule(_ panes: [Pane], launch: (Pane) -> Void) {
        guard enabled else { return }
        guard deferred else {
            panes.forEach(launch)
            return
        }
        for pane in panes where !pending.contains(where: { $0 === pane }) {
            pending.append(pane)
        }
    }

    func finish(prepareLayout: () -> Void, stillOwned: (Pane) -> Bool,
                launch: (Pane) -> Void) {
        guard !pending.isEmpty else { return }
        let initial = pending
        // Layout and process startup can invoke callbacks. A repeated or
        // reentrant finish must not start any initial shell twice.
        pending.removeAll()
        prepareLayout()
        for pane in initial where stillOwned(pane) { launch(pane) }
    }
}
