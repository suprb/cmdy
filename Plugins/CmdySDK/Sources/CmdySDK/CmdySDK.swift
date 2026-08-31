import Foundation
import CoreGraphics
import ProductIdentity

/// Stable SDK facade for the host app's renameable public identity.
///
/// Extensions should use this instead of spelling the app name, configuration
/// path, MCP namespace, or environment prefix themselves.
public enum HostProductIdentity {
    public static let name = ProductIdentity.current.name
    public static let titleName = ProductIdentity.current.titleName
    public static let slug = ProductIdentity.current.slug
    public static let configDirectoryName =
        ProductIdentity.current.configurationDirectoryName
    public static let environmentPrefix = ProductIdentity.current.environmentPrefix
    public static let legacySlugs = ProductIdentity.current.legacySlugs

    public static var configurationDirectory: URL {
        configurationDirectory(in: ProcessInfo.processInfo.environment)
    }

    public static func configurationDirectory(
        in environment: [String: String]
    ) -> URL {
        if let override = environmentValue("CONFIG_DIR", in: environment),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return ProductIdentity.current.configurationDirectory()
    }

    public static func environmentValue(
        _ suffix: String,
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        ProductIdentity.current.environmentValue(suffix, in: environment)
    }

    public static func mcpServerName(_ component: String) -> String {
        ProductIdentity.current.mcpServerName(component)
    }
}

/// The host's live native palette. Plugins should use `cursor` as the action
/// accent and preserve `background`/`foreground` contrast for glyphs.
public struct CmdyTheme: Equatable, Sendable {
    public let name: String
    public let background: String
    public let foreground: String
    public let cursor: String
    public let border: String
    public let ansi: [String]

    public init?(payload: [String: Any]) {
        guard let name = payload["name"] as? String,
              let background = payload["background"] as? String,
              let foreground = payload["foreground"] as? String,
              let cursor = payload["cursor"] as? String,
              let border = payload["border"] as? String else { return nil }
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.border = border
        ansi = payload["ansi"] as? [String] ?? []
    }
}

/// Carbon-compatible modifier bits for global plugin hotkeys. Keeping these
/// typed prevents values from `NSEvent.ModifierFlags` (or guessed hex values)
/// from silently registering a different shortcut.
public struct CmdyHotKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Self(rawValue: 1 << 8)
    public static let shift = Self(rawValue: 1 << 9)
    public static let option = Self(rawValue: 1 << 11)
    public static let control = Self(rawValue: 1 << 12)
}

/// Keeps an external sidecar attached to one exact Cmdy window. Before a
/// sidecar is visible, key-window frame events update the candidate. Once it
/// is attached, events from other Cmdy windows are deliberately ignored.
public struct CmdySidecarHost: Sendable, Equatable {
    public private(set) var windowNumber: CGWindowID?

    public init(windowNumber: CGWindowID? = nil) {
        self.windowNumber = windowNumber
    }

    /// Observe a key-window event. Returns true when it belongs to the host.
    @discardableResult
    public mutating func observe(_ candidate: CGWindowID, attached: Bool) -> Bool {
        if attached, let windowNumber { return windowNumber == candidate }
        windowNumber = candidate
        return true
    }

    public func matches(_ candidate: CGWindowID) -> Bool {
        windowNumber == candidate
    }

    public mutating func adopt(_ candidate: CGWindowID) {
        windowNumber = candidate
    }

    public mutating func clear() {
        windowNumber = nil
    }
}

public enum CmdySidecarGeometry {
    /// A visible card inside a right-side dock strip. `dockSide` is the
    /// exposed Cmdy window edge, `trailingOffset` is workspace chrome to
    /// the right of the strip, and `padding` is the card's equal inner gap.
    public static func cardFrame(host: CGRect, dockSide: CGFloat,
                                 stripWidth: CGFloat, padding: CGFloat,
                                 trailingOffset: CGFloat = 0) -> CGRect {
        let edge = max(0, dockSide + padding)
        return CGRect(x: host.maxX - max(0, trailingOffset)
                          - dockSide - stripWidth + padding,
                      y: host.minY + edge,
                      width: max(120, stripWidth - 2 * padding),
                      height: max(120, host.height - 2 * edge))
    }
}

/// Serializes a sidecar's dock-width updates so an older HTTP request cannot
/// arrive after a newer one and leave the host laid out for the wrong width.
/// While a request is in flight, callers can keep publishing live values; the
/// latest value is sent immediately after the current request completes.
public struct CmdySidecarInsetSync: Sendable, Equatable {
    public private(set) var desired: CGFloat = 0
    public private(set) var applied: CGFloat?
    public private(set) var isRequestInFlight = false

    private var lastAttempted: CGFloat?
    private var lastRequestAt = Date.distantPast

    public init() {}

    /// Publishes the current sidecar width and returns the value that should be
    /// sent now, or nil when a request is already carrying/coalescing it.
    public mutating func update(to value: CGFloat, now: Date = Date(),
                                heartbeatInterval: TimeInterval = 2) -> CGFloat? {
        desired = Self.normalized(value)
        return beginRequestIfNeeded(now: now, heartbeatInterval: heartbeatInterval)
    }

    /// Completes the single in-flight request. When the width changed while it
    /// was travelling, the returned value is the newest width and must be sent
    /// next. Failed values are retried on a later update instead of spinning.
    public mutating func complete(sent value: CGFloat, succeeded: Bool,
                                  now: Date = Date(),
                                  heartbeatInterval: TimeInterval = 2) -> CGFloat? {
        isRequestInFlight = false
        if succeeded { applied = Self.normalized(value) }
        return beginRequestIfNeeded(now: now, heartbeatInterval: heartbeatInterval)
    }

    private mutating func beginRequestIfNeeded(now: Date,
                                               heartbeatInterval: TimeInterval) -> CGFloat? {
        guard !isRequestInFlight else { return nil }
        let interval = max(0, heartbeatInterval)
        let widthChanged = applied != desired
        let retryDue = lastAttempted != desired
            || now.timeIntervalSince(lastRequestAt) >= interval
        let heartbeatDue = applied == desired
            && now.timeIntervalSince(lastRequestAt) >= interval
        guard (widthChanged && retryDue) || heartbeatDue else { return nil }

        isRequestInFlight = true
        lastAttempted = desired
        lastRequestAt = now
        return desired
    }

    private static func normalized(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}

/// The Swift client for cmdy's Extension SDK. An Extension is a plain process
/// launched with CMDY_PORT + CMDY_TOKEN in its environment (legacy names are
/// accepted). Everything below is sugar over the HTTP API (see EXTENSIONS.md —
/// the HTTP surface is the ABI, so any language can do what this file does).
public final class Cmdy: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    public let port: Int
    public let token: String

    /// Every /v1/events event lands here (already on the main queue).
    public var onEvent: (([String: Any]) -> Void)?

    /// Decode the authoritative AppKit frame pushed by cmdy while its key
    /// window moves or resizes. Coordinates use AppKit's bottom-left origin.
    public static func windowFrame(from event: [String: Any]) -> CGRect? {
        guard event["kind"] as? String == "window-frame" else { return nil }
        func number(_ key: String) -> CGFloat? {
            (event[key] as? NSNumber).map { CGFloat(truncating: $0) }
        }
        guard let x = number("x"), let y = number("y"),
              let width = number("width"), let height = number("height"),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              abs(x) <= 1_000_000, abs(y) <= 1_000_000,
              width > 0, height > 0,
              width <= 1_000_000, height <= 1_000_000 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private lazy var requestSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
    private lazy var eventSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: .main)
    private let registrationLock = NSLock()
    private var startupCommands: [[String: Any]] = []
    private var startupHotKeys: [[String: Any]] = []
    private var startupHooks: [[String: Any]] = []
    private var didBeginListening = false
    private func performRequest(_ request: URLRequest,
                                completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        requestSession.dataTask(with: request) { data, response, error in
            if let error {
                NSLog("cmdy SDK: %@ %@ failed: %@",
                      request.httpMethod ?? "GET", request.url?.path ?? "?",
                      error.localizedDescription)
            } else if let status = (response as? HTTPURLResponse)?.statusCode,
                      !(200..<300).contains(status) {
                NSLog("cmdy SDK: %@ %@ returned HTTP %d",
                      request.httpMethod ?? "GET", request.url?.path ?? "?", status)
            }
            DispatchQueue.main.async { completion(data, response, error) }
        }.resume()
    }
    private var eventBuffer = Data()

    /// nil when not launched by cmdy (missing env).
    private let launchPpid = getppid()
    private var parentWatch: Timer?

    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let p = HostProductIdentity.environmentValue(
                "PORT", in: environment).flatMap(Int.init),
              (1...65_535).contains(p),
              let t = HostProductIdentity.environmentValue("TOKEN", in: environment),
              !t.isEmpty, t.count <= 4_096 else { return nil }
        port = p
        token = t
        super.init()
        startParentWatchdog()
    }

    /// Called when cmdy (our parent) dies, just before we exit — an Extension
    /// sets this to shut down gracefully (release the dock inset, discovery
    /// file, CEF, etc.). If unset, we exit hard.
    public var onParentExit: (() -> Void)?

    /// Exit when cmdy (our parent) dies. An Extension is launched as cmdy's
    /// child; if cmdy quits or crashes without terminating us, we reparent
    /// to launchd (ppid == 1) and would linger as an orphan — holding ports,
    /// discovery files, and profile locks that break the next cmdy launch
    /// (the Chromium CEF-lock trap). This makes every SDK Extension self-clean.
    private func startParentWatchdog() {
        parentWatch = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if getppid() != self.launchPpid || getppid() == 1 {
                self.parentWatch?.invalidate()
                self.onParentExit?()
                exit(0)
            }
        }
    }

    // MARK: - Raw requests

    private func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func encodedRequest(_ method: String, _ path: String, _ body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func perform(_ request: URLRequest,
                         completion: (([String: Any]?) -> Void)? = nil) {
        performRequest(request) { data, _, _ in
            let json = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            completion?(json)
        }
    }

    public func post(_ path: String, _ body: [String: Any] = [:],
                     completion: (([String: Any]?) -> Void)? = nil) {
        performRequest(request("POST", path, body)) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            completion?(json)
        }
    }

    public func patch(_ path: String, _ body: [String: Any] = [:],
                      completion: (([String: Any]?) -> Void)? = nil) {
        performRequest(request("PATCH", path, body)) { data, _, _ in
            let json = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            completion?(json)
        }
    }

    public func delete(_ path: String,
                       completion: (([String: Any]?) -> Void)? = nil) {
        performRequest(request("DELETE", path)) { data, _, _ in
            let json = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            completion?(json)
        }
    }

    public func get(_ path: String, completion: @escaping ([String: Any]?) -> Void) {
        performRequest(request("GET", path)) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            completion(json)
        }
    }

    // MARK: - The SDK surface

    public func registerCommand(id: String, title: String, plugin: String? = nil) {
        var body: [String: Any] = ["id": id, "title": title]
        if let plugin { body["plugin"] = plugin }
        registrationLock.lock()
        let buffer = !didBeginListening
        if buffer { startupCommands.append(body) }
        registrationLock.unlock()
        if !buffer { post("/v1/commands", body) }
    }

    public func registerHotKey(id: String, keyCode: Int, modifiers: Int) {
        let body: [String: Any] = ["id": id, "keyCode": keyCode,
                                   "modifiers": modifiers]
        registrationLock.lock()
        let buffer = !didBeginListening
        if buffer { startupHotKeys.append(body) }
        registrationLock.unlock()
        if !buffer { post("/v1/hotkeys", body) }
    }

    public func registerHotKey(id: String, keyCode: Int, modifiers: CmdyHotKeyModifiers) {
        registerHotKey(id: id, keyCode: keyCode, modifiers: modifiers.rawValue)
    }

    public func notify(title: String, body: String) {
        post("/v1/notify", ["title": title, "body": body])
    }

    public func panes(completion: @escaping ([[String: Any]]) -> Void) {
        get("/v1/panes") { completion($0?["panes"] as? [[String: Any]] ?? []) }
    }

    public func focusedPane(completion: @escaping ([String: Any]?) -> Void) {
        panes { completion($0.first { ($0["focused"] as? Bool) == true }) }
    }

    /// Move existing live panes into one newly arranged terminal window. The
    /// panes and their PTYs keep running; only their AppKit layout changes.
    public func composePanes(_ paneIDs: [String],
                             completion: (([String: Any]?) -> Void)? = nil) {
        post("/v1/windows/compose", ["panes": paneIDs], completion: completion)
    }

    public func theme(completion: @escaping (CmdyTheme?) -> Void) {
        get("/v1/theme") { payload in
            completion(payload.flatMap { CmdyTheme(payload: $0) })
        }
    }

    /// Draw a native inline panel in the terminal. Interactions arrive as
    /// {kind:"ui", panel, event: pick|submit|evaluate|changed|dismissed, value}.
    public func openPanel(_ spec: [String: Any], completion: ((String?) -> Void)? = nil) {
        post("/v1/ui/panel", spec) { completion?($0?["panel"] as? String) }
    }

    public func updatePanel(_ id: String, _ fields: [String: Any]) {
        post("/v1/ui/\(id)/update", fields)
    }

    public func dismissPanel(_ id: String) {
        post("/v1/ui/\(id)/dismiss")
    }

    /// Attach a persistent Extension command row to a terminal window.
    /// Interactions arrive as {kind:"ui", controlBar, event:action|submit, value}.
    public func openControlBar(_ spec: [String: Any],
                               completion: ((String?) -> Void)? = nil) {
        post("/v1/control-bars", spec) {
            completion?($0?["controlBar"] as? String)
        }
    }

    public func updateControlBar(_ id: String, _ fields: [String: Any]) {
        post("/v1/control-bars/\(id)/update", fields)
    }

    public func dismissControlBar(_ id: String) {
        post("/v1/control-bars/\(id)/dismiss")
    }

    /// Freeze a companion window for pixel markup. This is deliberately
    /// separate from semantic UI feedback, which uses `submitFeedback`.
    public func captureMarkup(windowNumber: CGWindowID? = nil) {
        var body: [String: Any] = [:]
        if let windowNumber { body["window"] = windowNumber }
        post("/v1/ui/annotate", body)
    }

    @available(*, deprecated, renamed: "captureMarkup(windowNumber:)")
    public func annotate(windowNumber: CGWindowID? = nil) {
        captureMarkup(windowNumber: windowNumber)
    }

    /// Send structured UI feedback to the paired terminal pane. An active AI
    /// receives it as a prompt; otherwise the record remains available through
    /// the Extension's MCP queue without being executed by the shell.
    public func submitFeedback(_ feedback: [String: Any],
                               windowNumber: CGWindowID? = nil,
                               completion: (([String: Any]?) -> Void)? = nil) {
        var body = feedback
        if let windowNumber { body["window"] = windowNumber }
        post("/v1/ui/feedback", body, completion: completion)
    }

    public func offerAgentAttach(windowNumber: CGWindowID? = nil) {
        var body: [String: Any] = [:]
        if let windowNumber { body["window"] = windowNumber }
        post("/v1/ui/agent-attach", body)
    }

    /// Attach a host-rendered Surface to the current (or specified) command
    /// block. Standard terminal output remains the canonical fallback.
    public func openSurface(_ document: CmdySurfaceDocument,
                            completion: (([String: Any]?) -> Void)? = nil) {
        let data = try? JSONEncoder().encode(document)
        perform(encodedRequest("POST", "/v1/surfaces", data), completion: completion)
    }

    public func updateSurface(_ id: String, patch: CmdySurfacePatch,
                              completion: (([String: Any]?) -> Void)? = nil) {
        let data = try? JSONEncoder().encode(patch)
        perform(encodedRequest("PATCH", "/v1/surfaces/\(id)", data), completion: completion)
    }

    public func dismissSurface(_ id: String,
                               completion: (([String: Any]?) -> Void)? = nil) {
        perform(encodedRequest("DELETE", "/v1/surfaces/\(id)"), completion: completion)
    }

    public func showSurface(_ id: String,
                            completion: (([String: Any]?) -> Void)? = nil) {
        perform(encodedRequest("POST", "/v1/surfaces/\(id)/show", Data("{}".utf8)),
                completion: completion)
    }

    public func registerHook(id: String, boundary: CmdyHookBoundary,
                             priority: Int = 0) {
        let body: [String: Any] = ["id": id, "boundary": boundary.rawValue,
                                   "priority": max(-100, min(100, priority))]
        registrationLock.lock()
        let buffer = !didBeginListening
        if buffer { startupHooks.append(body) }
        registrationLock.unlock()
        if !buffer { post("/v1/hooks", body) }
    }

    /// Answer a private `kind=hook` event before its deadline.
    public func respondToHook(request id: String, decision: CmdyDecision,
                              value: String? = nil, reason: String? = nil) {
        var body: [String: Any] = ["decision": decision.rawValue]
        if let value { body["value"] = value }
        if let reason { body["reason"] = reason }
        post("/v1/hook-responses/\(id)", body)
    }

    // MARK: - Event stream (SSE)

    public func listen() {
        registrationLock.lock()
        if didBeginListening {
            registrationLock.unlock()
            startEventStream()
            return
        }
        didBeginListening = true
        let commands = startupCommands
        let hotkeys = startupHotKeys
        let hooks = startupHooks
        startupCommands.removeAll()
        startupHotKeys.removeAll()
        startupHooks.removeAll()
        registrationLock.unlock()

        guard !commands.isEmpty || !hotkeys.isEmpty || !hooks.isEmpty else {
            startEventStream()
            return
        }
        post("/v1/extensions/register", [
            "commands": commands,
            "hotkeys": hotkeys,
            "hooks": hooks,
        ]) { [weak self] response in
            guard let self else { return }
            if response?["ok"] as? Bool == true {
                self.startEventStream()
                return
            }
            // Compatibility with a pre-batch Cmdy host: replay the same
            // startup registrations one at a time, then attach the stream.
            let legacy = commands.map { ("/v1/commands", $0) }
                + hotkeys.map { ("/v1/hotkeys", $0) }
                + hooks.map { ("/v1/hooks", $0) }
            self.sendLegacyRegistrations(legacy, at: 0)
        }
    }

    private func sendLegacyRegistrations(_ registrations: [(String, [String: Any])],
                                         at index: Int) {
        guard registrations.indices.contains(index) else {
            startEventStream()
            return
        }
        let registration = registrations[index]
        post(registration.0, registration.1) { [weak self] _ in
            self?.sendLegacyRegistrations(registrations, at: index + 1)
        }
    }

    private func startEventStream() {
        eventSession.dataTask(with: request("GET", "/v1/events")).resume()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        eventBuffer.append(data)
        if eventBuffer.count > 4 * 1024 * 1024 {
            eventBuffer.removeAll(keepingCapacity: false)
            dataTask.cancel()
            return
        }
        while let sep = eventBuffer.range(of: Data("\n\n".utf8)) {
            let frame = eventBuffer[..<sep.lowerBound]
            eventBuffer.removeSubrange(..<sep.upperBound)
            guard let text = String(data: frame, encoding: .utf8),
                  let payload = text.split(separator: "\n")
                      .first(where: { $0.hasPrefix("data: ") })?
                      .dropFirst("data: ".count),
                  let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { continue }
            onEvent?(json)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The stream dropped (cmdy quit or restarted) — retry until it's back.
        guard task.originalRequest?.url?.path == "/v1/events" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.listen() }
    }
}
