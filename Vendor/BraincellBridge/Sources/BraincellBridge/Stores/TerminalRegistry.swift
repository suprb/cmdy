import Foundation
import Darwin
import Combine

/// Live registry of terminal sessions. Mutations land on the main actor so SwiftUI views
/// observing `sessions` stay consistent. The HTTP server bounces calls into the main queue
/// before invoking these methods.
@MainActor
final class TerminalRegistry: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []

    private var sweepTimer: Timer?

    init() {
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.purgeStale() }
        }
    }

    deinit {
        sweepTimer?.invalidate()
    }

    /// Register a new session — or update the existing one if a session
    /// with the same deterministic id already exists. Returns the session.
    /// IDs are derived from `(pid, tty)` so a shell re-registering after a
    /// bridge restart gets the SAME id and any persisted bindings still
    /// resolve (eliminates the "restart Claude Code after bridge restart"
    /// tax). See `TerminalSession.deterministicId(pid:tty:)`.
    @discardableResult
    func register(pid: Int32, tty: String, terminalApp: String, windowId: UInt32?,
                  paneId: String?, paneFocused: Bool,
                  windowTitle: String?, projectPath: String?) -> TerminalSession {
        let now = Date()
        let id = TerminalSession.deterministicId(pid: pid, tty: tty)
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            // Idempotent re-register: refresh mutable fields, keep id.
            if let projectPath = projectPath, !projectPath.isEmpty {
                sessions[idx].projectPath = projectPath
            }
            if let windowTitle = windowTitle, !windowTitle.isEmpty {
                sessions[idx].windowTitle = windowTitle
            }
            if let windowId { sessions[idx].windowId = windowId }
            if let paneId, !paneId.isEmpty { sessions[idx].paneId = paneId }
            sessions[idx].paneFocused = paneFocused
            sessions[idx].lastSeen = now
            return sessions[idx]
        }
        let session = TerminalSession(
            id: id,
            pid: pid,
            tty: tty,
            terminalApp: terminalApp,
            windowId: windowId,
            paneId: paneId,
            paneFocused: paneFocused,
            windowTitle: windowTitle,
            projectPath: projectPath,
            registeredAt: now,
            lastSeen: now
        )
        sessions.append(session)
        return session
    }

    func unregister(id: String) {
        let before = sessions.count
        sessions.removeAll { $0.id == id }
        let removed = before - sessions.count
        if removed > 0 {
            NSLog("[Registry] unregister id=%@ (DELETE /sessions) — removed=%d remaining=%d",
                  id, removed, sessions.count)
        }
    }

    func touch(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].lastSeen = Date()
    }

    /// Patch mutable fields published by cmdy as panes move, focus, or
    /// change cwd. Returns the updated session or nil if the id is unknown.
    @discardableResult
    func update(id: String, projectPath: String? = nil, windowTitle: String? = nil,
                windowId: UInt32? = nil, paneId: String? = nil,
                paneFocused: Bool? = nil) -> TerminalSession? {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        if let projectPath = projectPath {
            sessions[idx].projectPath = projectPath.isEmpty ? nil : projectPath
        }
        if let windowTitle = windowTitle {
            sessions[idx].windowTitle = windowTitle.isEmpty ? nil : windowTitle
        }
        if let windowId { sessions[idx].windowId = windowId }
        if let paneId { sessions[idx].paneId = paneId.isEmpty ? nil : paneId }
        if let paneFocused { sessions[idx].paneFocused = paneFocused }
        sessions[idx].lastSeen = Date()
        return sessions[idx]
    }

    func session(id: String) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    /// Evict sessions whose cmdy shell process no longer exists. Quiet
    /// sessions remain valid indefinitely; direct plugin registration has no
    /// heartbeat and pane-close events handle the normal path immediately.
    func purgeStale() {
        var removed: [(id: String, pid: Int32)] = []
        sessions.removeAll { session in
            let dead = !Self.isPidAlive(session.pid)
            if dead {
                removed.append((session.id, session.pid))
                return true
            }
            return false
        }
        for r in removed {
            NSLog("[Registry] purgeStale removed id=%@ pid=%d (process exited)", r.id, r.pid)
        }
    }

    /// Drop every session. Used by the popover's "Reset all" path; the
    /// cmdy plugin republishes its live pane list.
    func removeAll() {
        sessions.removeAll()
    }

    /// `kill(pid, 0)` is a permission probe — returns 0 if the process exists,
    /// -1 with errno=ESRCH otherwise. Owned by another user → errno=EPERM, treat as alive.
    private static func isPidAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
