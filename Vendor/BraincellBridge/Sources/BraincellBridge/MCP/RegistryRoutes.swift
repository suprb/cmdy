import Foundation
import Darwin
import NIOHTTP1

/// Wires session registry endpoints onto the shared HTTP server.
///
/// Endpoints:
///   POST   /sessions                      → register, returns { id }
///   DELETE /sessions/<id>                 → unregister, returns { ok: true }
///   POST   /sessions/<id>/heartbeat       → touch lastSeen, 404 if unknown
///   POST   /sessions/<id>/inject          → paste text into the session's terminal
///                                           (used by the in-page inspector toolbar)
///   PATCH  /sessions/<id>                 → update projectPath/windowTitle (cd-aware hook)
///   GET    /sessions                      → list all sessions (debug)
///   GET    /sessions/<id>/binding         → { bound: bool, target: ... } — used by stdio bridges
///                                           to decide whether to advertise tools
///
/// All registry mutations hop to the main actor since `TerminalRegistry` is `@MainActor`.
extension Notification.Name {
    /// Fires when an inspector inject hits /sessions/<id>/inject. UserInfo carries
    /// "sessionId" so the wire-overlay observer can pulse the right session inbound.
    static let braincellBridgeInjectPulse = Notification.Name("braincellBridgeInjectPulse")

    /// Host/plugin UI requested a direct bind for an already registered
    /// terminal session.
    static let bridgeBindRequested = Notification.Name("bridgeBindRequested")

}

enum RegistryRoutes {
    /// Shared by the route and tests so no external registration can silently
    /// widen Bridge back to other terminal applications.
    static func hostIdentityError(terminalApp: String, windowId: UInt32?) -> String? {
        guard terminalApp.caseInsensitiveCompare(
                BridgeHostIdentity.slug) == .orderedSame else {
            return "Bridge accepts \(BridgeHostIdentity.displayName) sessions only."
        }
        guard let windowId, windowId != 0 else {
            return "Missing \(BridgeHostIdentity.displayName) windowId."
        }
        return nil
    }

    /// `proxyPort` is queried lazily so cmdy receives the current stream
    /// proxy endpoint even if it started after these routes were registered.
    static func register(on http: HTTPServer, registry: TerminalRegistry, bindings: BindingStore, proxyPort: @escaping () -> Int) {

        // MARK: POST /sessions
        http.route(.POST, "/sessions") { req in
            guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
                return .badRequest("Invalid JSON body")
            }

            // pid may arrive as Int, Int32, NSNumber, or String — normalize.
            let pid: Int32
            if let n = json["pid"] as? NSNumber {
                let raw = n.int64Value
                guard raw > 1, raw <= Int64(Int32.max) else {
                    return .badRequest("Missing or invalid 'pid'")
                }
                pid = Int32(raw)
            } else if let s = json["pid"] as? String, let v = Int32(s) {
                guard v > 1 else { return .badRequest("Missing or invalid 'pid'") }
                pid = v
            } else {
                return .badRequest("Missing or invalid 'pid'")
            }

            // Reject registrations for dead PIDs — closes the loophole where an orphan
            // heartbeat subshell (whose parent shell already died) re-registers via 404
            // fallback and creates a session that immediately gets purged. The visible
            // symptom: a session "appears then vanishes" in the popover.
            if kill(pid, 0) != 0 && errno != EPERM {
                return HTTPServer.HTTPResponse(
                    status: .gone,
                    body: ["error": "Registering process \(pid) is not alive."]
                )
            }

            guard let tty = json["tty"] as? String,
                  !tty.isEmpty, tty.utf8.count <= 1_024 else {
                return .badRequest("Missing or invalid 'tty'")
            }
            let terminalApp = (json["terminalApp"] as? String) ?? "unknown"
            let windowId: UInt32? = {
                guard let number = json["windowId"] as? NSNumber else { return nil }
                let raw = number.int64Value
                guard raw > 0, raw <= Int64(UInt32.max) else { return nil }
                return UInt32(raw)
            }()
            if let error = hostIdentityError(terminalApp: terminalApp,
                                             windowId: windowId) {
                return .badRequest(error)
            }
            let windowTitle = json["windowTitle"] as? String
            let projectPath = json["projectPath"] as? String
            let paneId = json["paneId"] as? String
            guard (windowTitle?.utf8.count ?? 0) <= 4_096,
                  (projectPath?.utf8.count ?? 0) <= 16_384,
                  (paneId?.utf8.count ?? 0) <= 512 else {
                return .badRequest("Session metadata is too large")
            }
            let paneFocused = json["paneFocused"] as? Bool ?? false

            let session: TerminalSession? = await MainActor.run {
                let id = TerminalSession.deterministicId(pid: pid, tty: tty)
                if registry.sessions.count >= 1_024, registry.session(id: id) == nil {
                    registry.purgeStale()
                    guard registry.sessions.count < 1_024 else { return nil }
                }
                return registry.register(
                    pid: pid,
                    tty: tty,
                    terminalApp: terminalApp,
                    windowId: windowId,
                    paneId: paneId,
                    paneFocused: paneFocused,
                    windowTitle: (windowTitle?.isEmpty == true) ? nil : windowTitle,
                    projectPath: (projectPath?.isEmpty == true) ? nil : projectPath
                )
            }
            guard let session else {
                return HTTPServer.HTTPResponse(
                    status: .tooManyRequests,
                    body: ["error": "Bridge session limit reached"])
            }

            // The plugin currently uses the id; proxy_port remains available
            // for cmdy-owned stream integration without any shell mutation.
            return .ok(["id": session.id, "proxy_port": proxyPort()])
        }

        // MARK: DELETE /sessions/<id>
        http.routePrefix(.DELETE, "/sessions/") { req in
            let id = req.pathTail
            if id.isEmpty || id.utf8.count > 128 || id.contains("/") {
                return .badRequest("Invalid session id")
            }
            await MainActor.run {
                registry.unregister(id: id)
            }
            return .ok(["ok": true])
        }

        // MARK: POST /sessions/<id>/{heartbeat,inject}
        http.routePrefix(.POST, "/sessions/") { req in
            let parts = req.pathTail.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return .badRequest("Expected /sessions/<id>/<action>")
            }
            let id = String(parts[0])
            let action = String(parts[1])
            if id.isEmpty || id.utf8.count > 128 {
                return .badRequest("Missing session id")
            }

            switch action {
            case "heartbeat":
                let ok: Bool = await MainActor.run {
                    guard registry.session(id: id) != nil else { return false }
                    registry.touch(id: id)
                    return true
                }
                if !ok {
                    return HTTPServer.HTTPResponse(status: .notFound, body: ["error": "Unknown session"])
                }
                return .ok(["ok": true])

            case "inject":
                // In-page inspector → terminal-side Claude. Body: { text, pressReturn? }.
                guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                      let text = json["text"] as? String, !text.isEmpty,
                      text.utf8.count <= 4 * 1024 * 1024 else {
                    return .badRequest("Body must be { text: String, pressReturn?: Bool }")
                }
                let pressReturn = (json["pressReturn"] as? Bool) ?? false
                let session: TerminalSession? = await MainActor.run { registry.session(id: id) }
                guard let s = session else {
                    return HTTPServer.HTTPResponse(status: .notFound, body: ["error": "Unknown session"])
                }
                // Resolve appState via the session id → registry; the registry doesn't hold
                // it, so we use a Notification trick: post a pulse via a key on UserDefaults?
                // Cleaner: have register() take an `onInject` callback. For now, the wire
                // overlay polls bindings + activity directly via the shared appState that
                // the BridgeAppDelegate owns — we route the pulse there from the delegate
                // by walking through a static notification name. Simpler: post Notification
                // and let BridgeAppDelegate observe it.
                NotificationCenter.default.post(
                    name: .braincellBridgeInjectPulse,
                    object: nil,
                    userInfo: ["sessionId": id]
                )
                Task { @MainActor in
                    await TextInjection.send(text, to: s, pressReturn: pressReturn)
                }
                return .ok(["ok": true])

            default:
                return .badRequest("Unknown action: \(action)")
            }
        }

        // MARK: PATCH /sessions/<id>
        http.routePrefix(.PATCH, "/sessions/") { req in
            let id = req.pathTail
            if id.isEmpty || id.utf8.count > 128 || id.contains("/") {
                return .badRequest("Invalid session id")
            }
            let json = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            let projectPath = json["projectPath"] as? String
            let windowTitle = json["windowTitle"] as? String
            let windowId: UInt32? = {
                guard let number = json["windowId"] as? NSNumber else { return nil }
                let raw = number.int64Value
                guard raw > 0, raw <= Int64(UInt32.max) else { return nil }
                return UInt32(raw)
            }()
            let paneId = json["paneId"] as? String
            let paneFocused = json["paneFocused"] as? Bool
            guard (projectPath?.utf8.count ?? 0) <= 16_384,
                  (windowTitle?.utf8.count ?? 0) <= 4_096,
                  (paneId?.utf8.count ?? 0) <= 512 else {
                return .badRequest("Session metadata is too large")
            }
            let updated: TerminalSession? = await MainActor.run {
                registry.update(id: id, projectPath: projectPath,
                                windowTitle: windowTitle, windowId: windowId,
                                paneId: paneId, paneFocused: paneFocused)
            }
            if updated == nil {
                return HTTPServer.HTTPResponse(status: .notFound, body: ["error": "Unknown session"])
            }
            return .ok(["ok": true])
        }

        // MARK: GET /sessions/<id>/binding
        http.routePrefix(.GET, "/sessions/") { req in
            let parts = req.pathTail.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1] == "binding" else {
                return .badRequest("Expected /sessions/<id>/binding")
            }
            let id = String(parts[0])
            if id.isEmpty || id.utf8.count > 128 {
                return .badRequest("Missing session id")
            }
            let payload = await MainActor.run { () -> JSONDictionaryTransfer in
                guard let binding = bindings.get(sessionId: id) else {
                    return JSONDictionaryTransfer(["bound": false])
                }
                var target: [String: Any] = ["kind": binding.target.label]
                switch binding.target {
                case .chrome(_, let port):
                    target["cdpPort"] = port
                case .macAppProject(let path):
                    target["projectPath"] = path
                case .simulator(let udid):
                    target["udid"] = udid
                case .nativeApp(let bundleId):
                    target["bundleId"] = bundleId
                }
                return JSONDictionaryTransfer(["bound": true, "target": target])
            }
            return .ok(payload.value)
        }

        // MARK: GET /sessions  (debug)
        http.route(.GET, "/sessions") { _ in
            let snapshot: [TerminalSession] = await MainActor.run { registry.sessions }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var dicts: [[String: Any]] = []
            dicts.reserveCapacity(snapshot.count)
            for s in snapshot {
                if let data = try? encoder.encode(s),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    dicts.append(obj)
                }
            }
            return .ok(["sessions": dicts])
        }
    }
}
