private final class Pane { let id: Int; init(_ id: Int) { self.id = id } }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

@main
@MainActor
private enum InitialShellLaunchesTests {
    static func main() {
        let first = Pane(1), second = Pane(2)
        do {
            let gate = InitialShellLaunches<Pane>(enabled: true, deferred: false)
            var started: [Int] = []
            gate.schedule([first, second]) { started.append($0.id) }
            check(started == [1, 2], "existing eager restore/tab ordering changed")
            gate.finish(prepareLayout: { preconditionFailure("eager gate has no pending layout") },
                        stillOwned: { _ in true }, launch: { _ in preconditionFailure("eager shell repeated") })
        }
        for deferred in [false, true] {
            let gate = InitialShellLaunches<Pane>(enabled: false, deferred: deferred)
            gate.schedule([first]) { _ in preconditionFailure("no-shell mode started a process") }
            gate.finish(prepareLayout: { preconditionFailure("no-shell mode queued layout") },
                        stillOwned: { _ in true }, launch: { _ in preconditionFailure("no-shell mode started late") })
        }
        do {
            let gate = InitialShellLaunches<Pane>(enabled: true, deferred: true)
            var started: [Int] = [], grid = 31
            gate.schedule([first, first, second]) { _ in preconditionFailure("deferred shell started early") }
            gate.finish(prepareLayout: { grid = 29 }, stillOwned: { _ in true }, launch: {
                check(grid == 29, "PTY started before final layout/inset grid")
                started.append($0.id)
            })
            check(started == [1, 2], "initial order/deduplication differs")
            gate.finish(prepareLayout: { preconditionFailure("second finish repeated layout") },
                        stillOwned: { _ in true }, launch: { _ in preconditionFailure("second finish repeated launch") })
        }
        do {
            let gate = InitialShellLaunches<Pane>(enabled: true, deferred: true)
            var started: [Int] = []
            gate.schedule([first, second]) { _ in preconditionFailure("started early") }
            gate.finish(prepareLayout: {
                gate.finish(prepareLayout: { preconditionFailure("layout reentered") },
                            stillOwned: { _ in true }, launch: { _ in preconditionFailure("reentrant early start") })
            }, stillOwned: { _ in true }, launch: { pane in
                started.append(pane.id)
                gate.finish(prepareLayout: { preconditionFailure("launch reentered layout") },
                            stillOwned: { _ in true }, launch: { _ in preconditionFailure("reentrant duplicate") })
            })
            check(started == [1, 2], "reentrancy changed launch order")
        }
        do {
            let gate = InitialShellLaunches<Pane>(enabled: true, deferred: true)
            var owned = true, started: [Int] = []
            gate.schedule([first, second]) { _ in preconditionFailure("started early") }
            gate.finish(prepareLayout: {}, stillOwned: { _ in owned }, launch: { pane in
                started.append(pane.id)
                owned = false // a startup callback closed/reparented the window
            })
            check(started == [1], "a pane removed during reentrant launch was started")
        }
        do {
            let gate = InitialShellLaunches<Pane>(enabled: true, deferred: true)
            gate.schedule([first]) { _ in preconditionFailure("started early") }
            gate.finish(prepareLayout: {}, stillOwned: { _ in false },
                        launch: { _ in preconditionFailure("unowned pane started") })
        }
        print("PASS 7 initial-shell launch cases: eager order, two no-shell modes, layout-before-grid, idempotence/reentrancy, ownership")
    }
}
