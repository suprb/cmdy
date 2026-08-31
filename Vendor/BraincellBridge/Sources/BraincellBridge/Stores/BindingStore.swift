import Foundation
import Combine

/// Maps sessionId → SessionBinding. One binding per session (a session
/// points at one target).
///
/// **Ephemeral by design.** Bindings live entirely in memory for the life
/// of the bridge process. Quit the bridge → every binding is forgotten.
/// Close a terminal → its binding goes (driven from
/// `TerminalRegistry`'s stale-purge → `BridgeAppDelegate.unbindSession`).
/// Close a target → its binding goes (driven from adapter `onTerminated`
/// callbacks).
///
/// Persisting bindings across restarts was intentionally removed: restored
/// Mac App bindings could not safely recover an externally launched process,
/// while explicit fresh-start semantics guarantee no stale authority. Quit,
/// close, or unbind means gone; the user binds again to reopen the connection.
@MainActor
final class BindingStore: ObservableObject {
    @Published private(set) var bindings: [String: SessionBinding] = [:]

    func bind(sessionId: String, target: Target) {
        bindings[sessionId] = SessionBinding(sessionId: sessionId, target: target, createdAt: Date())
    }

    func unbind(sessionId: String) {
        bindings.removeValue(forKey: sessionId)
    }

    /// Drop every binding. Used by the popover's "Reset all" path.
    func unbindAll() {
        bindings.removeAll()
    }

    func get(sessionId: String) -> SessionBinding? {
        bindings[sessionId]
    }
}
