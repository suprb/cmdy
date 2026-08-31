import AppKit
import ProductIdentity

// cmdy plugin system — the seam a third-party world plugs into.
//
// TWO kinds of plugins, one API surface:
//
//  1. Built-in plugins are Swift objects conforming to `CmdyPlugin`,
//     activated at launch with a `PluginHost` (enumerate panes, type at a
//     prompt, add palette commands, global hotkeys, and HTTP routes.
//
//  2. External plugins are ANY program, in any language. cmdy launches
//     them from ~/.config/cmdy/plugins/<name>/ (a `manifest.json` + an
//     executable) and hands them the local server port + an auth token via
//     the environment. They drive cmdy entirely over the HTTP API — the
//     same API the built-in host exposes. The HTTP surface IS the plugin ABI,
//     so no linking against cmdy's Swift types is ever required.
//
// See PLUGINS.md for the author's guide.

/// A terminal pane, as a plugin sees it. Opaque handle + safe operations.
public struct PluginPane: Identifiable {
    public let id: String
    public let title: String
    public let cwd: String?
    /// Shell pid + tty name — external integrations (like the Bridge engine)
    /// identify sessions by these.
    public let pid: Int32
    public let tty: String?
    /// Name of an AI CLI running on this pane's tty (claude, aider…), if any.
    public let aiTool: String?
    /// True while the pane shows the amber attention dot (BEL/OSC 9/777
    /// arrived while the user wasn't looking).
    public let attention: Bool
    /// Most recent semantic OSC 133 command block, running or complete.
    public let currentBlockID: String?
    /// Which window the pane lives in (1-based, in window order) and its
    /// position among that window's splits (1-based) — so overview UIs can
    /// say "window 2 · split 3".
    public var windowIndex: Int = 0
    public var paneIndex: Int = 0
    public var windowTitle: String? = nil
    /// Exact AppKit/CGWindow number for integrations that attach UI to a
    /// specific Cmdy window. This avoids title and Accessibility guesses.
    public var windowNumber: Int = 0
    /// Type text at the prompt WITHOUT running it (bracketed-paste for
    /// multi-line so shells and CLI agents receive it as one block).
    public let type: (String) -> Void
    /// Replace the current prompt input WITHOUT pressing Enter.
    public let stage: (String) -> Void
    /// Type + press Enter.
    public let run: (String) -> Void
    /// Bring the pane's window forward and focus it.
    public let focus: () -> Void
    /// Last N lines of the pane's scrollback as plain text.
    public let output: (Int) -> String
    /// Live scroll/viewport state — diagnostic surface (yDisp, canScroll, …).
    public let scrollInfo: () -> [String: Any]
    /// Scroll the pane's view by N lines (negative = up). Same path the wheel uses.
    public let scrollBy: (Int) -> Void
    /// DISPLAY-ONLY injection: text/escapes render like program output on the
    /// pane's screen (colors, kitty images…). Never touches the shell input.
    public let feed: (String) -> Void

    public init(id: String, title: String, cwd: String?, pid: Int32, tty: String?, aiTool: String?, attention: Bool = false, currentBlockID: String? = nil, windowNumber: Int = 0, type: @escaping (String) -> Void, stage: @escaping (String) -> Void, run: @escaping (String) -> Void, focus: @escaping () -> Void, output: @escaping (Int) -> String, scrollInfo: @escaping () -> [String: Any], scrollBy: @escaping (Int) -> Void, feed: @escaping (String) -> Void) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.pid = pid
        self.tty = tty
        self.aiTool = aiTool
        self.attention = attention
        self.currentBlockID = currentBlockID
        self.windowNumber = windowNumber
        self.type = type
        self.stage = stage
        self.run = run
        self.focus = focus
        self.output = output
        self.scrollInfo = scrollInfo
        self.scrollBy = scrollBy
        self.feed = feed
    }
}

/// Minimal HTTP request/response the host hands to plugin route handlers.
public struct PluginHTTPRequest {
    let method: String
    let path: String
    let pathTail: String          // for prefix routes: the part after the prefix
    let body: Data
    /// Set by LocalHTTPServer from the per-launch bearer token. These are not
    /// accepted from request JSON, so one plugin cannot claim another's UI.
    let pluginOwner: String?
    let pluginID: String?
    let pluginName: String?
    /// nil identifies the user-owned discovery credential, which has full
    /// local authority. Launched extensions carry an exact manifest grant.
    let extensionCapabilities: Set<ExtensionCapability>?
    var isDiscoveryClient: Bool { pluginOwner == nil }
    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
}

public struct PluginHTTPResponse {
    var status: Int = 200
    var json: Any

    static func ok(_ json: Any) -> PluginHTTPResponse { .init(status: 200, json: json) }
    static func badRequest(_ message: String) -> PluginHTTPResponse { .init(status: 400, json: ["error": message]) }
    static func forbidden(_ message: String) -> PluginHTTPResponse { .init(status: 403, json: ["error": message]) }
    static func notFound(_ message: String) -> PluginHTTPResponse { .init(status: 404, json: ["error": message]) }
    static func conflict(_ message: String) -> PluginHTTPResponse { .init(status: 409, json: ["error": message]) }
    static func tooManyRequests(_ message: String) -> PluginHTTPResponse { .init(status: 429, json: ["error": message]) }
}

/// The API a plugin is given on activation.
protocol PluginHost: AnyObject {
    /// Every open pane across all windows/tabs.
    var panes: [PluginPane] { get }
    /// The focused pane, if any.
    var focusedPane: PluginPane? { get }

    /// Add a command that shows up in the command palette (and can be invoked
    /// by id). `title` is what the user sees.
    func addCommand(id: String, title: String, run: @escaping () -> Void)

    /// Serve an HTTP endpoint on cmdy's local plugin server. `path` ending
    /// in "/" is a prefix route (the tail arrives in `request.pathTail`).
    func addRoute(_ method: String, _ path: String, _ handler: @escaping (PluginHTTPRequest) -> PluginHTTPResponse)

    /// Register a global (system-wide) hotkey.
    func registerHotKey(keyCode: UInt32, modifiers: UInt32, _ handler: @escaping () -> Void)

    /// The port the plugin HTTP server is listening on (0 until it binds).
    var serverPort: Int { get }

    /// Structured log line, prefixed with the plugin under a shared tag.
    func log(_ message: String)
}

/// A cmdy plugin. Implementors are registered in `PluginManager.builtins`.
protocol CmdyPlugin: AnyObject {
    static var id: String { get }            // reverse-DNS, e.g. "com.cmdy.conduit"
    static var displayName: String { get }
    init()
    func activate(host: PluginHost)
    func deactivate()
}

/// A process being alive is not enough to call an Extension healthy. Runtime
/// state becomes `ready` only after that exact launch authenticates back to the
/// local API; unexpected exits retain their reason and last bounded log line.
public enum ExtensionRuntimePhase: String {
    case starting
    case ready
    case failed
    case stopped
}

public struct ExtensionRuntimeStatus {
    public let directory: URL
    public let id: String
    public let name: String
    public let phase: ExtensionRuntimePhase
    public let processIdentifier: Int32?
    public let message: String?
    public let lastLog: String?

    public var displayText: String {
        switch phase {
        case .starting:
            return processIdentifier.map { "starting (pid \($0))" } ?? "starting"
        case .ready:
            return processIdentifier.map { "ready (pid \($0))" } ?? "ready"
        case .stopped:
            return "stopped"
        case .failed:
            let reason = message ?? "process stopped unexpectedly"
            guard let lastLog, !lastLog.isEmpty, lastLog != reason else {
                return "failed: \(reason)"
            }
            return "failed: \(reason) — \(lastLog)"
        }
    }
}

extension Notification.Name {
    /// Posted on the main thread whenever an Extension changes runtime phase.
    public static let cmdyExtensionRuntimeChanged = Notification.Name(
        "cmdy.extensionRuntimeChanged")
}

/// Owns the plugin lifecycle and the shared services (HTTP server, hotkeys,
/// command registry) that back the host API.
public final class PluginManager: PluginHost {
    nonisolated(unsafe) public static let shared = PluginManager()

    /// Panes provider — set by AppDelegate so the host stays decoupled from it.
    public var panesProvider: () -> [PluginPane] = { [] }
    /// Fast identity lookup for hot single-pane routes. Falling back to the
    /// snapshot provider keeps standalone Kit hosts source-compatible.
    public var paneProvider: (_ id: String) -> PluginPane? = { _ in nil }
    public var focusedPaneProvider: () -> PluginPane? = { nil }
    /// User-owned, context-sensitive one-shot Actions. They are intentionally
    /// exposed only through the discovery credential; an Extension cannot use
    /// its own token to invoke arbitrary personal automation.
    public var actionsProvider: () -> [[String: Any]] = { [] }
    public var runActionProvider: (_ id: String, _ inputs: [String: String]) throws
        -> [String: Any] = { id, _ in
            throw CmdyActionError.invalid("Action host unavailable for '\(id)'")
        }
    /// Current pane working directories drive trusted project-local extension
    /// discovery. The host supplies them so CmdyKit stays window-agnostic.
    public var projectDirectoriesProvider: () -> [String] = { [] }
    /// One clear trust prompt per project root. The callback persists approval
    /// outside the repository before anything executable is launched.
    public var requestProjectTrust: (_ projectRoot: URL,
                                     _ extensions: [ExtensionManifest],
                                     _ completion: @escaping (Bool) -> Void) -> Void = {
        _, _, completion in completion(false)
    }

    private(set) var plugins: [CmdyPlugin] = []
    private var activeHostComponents: [URL: ExtensionManifest] = [:]
    private let server = LocalHTTPServer()
    /// Durable host-owned Inbox/Outbox state. Channel connectors are ordinary
    /// capability-scoped Extensions; their per-launch tokens only attach to
    /// records owned by the same stable Extension id.
    public let channelRegistry = CmdyChannelRegistry(
        storageURL: ConfigFile.directory.appendingPathComponent("channels/state.json"))
    private let marketplaceQueue = DispatchQueue(label: "cmdy.marketplace",
                                                 qos: .utility)
    // Must be the SHARED instance: the process-global Carbon event handler
    // dispatches to HotKeyCenter.shared.fire(). Registering on a separate
    // instance left every global hotkey dead (they fired only as menu/palette
    // commands) — see the audit.
    private let hotKeys = HotKeyCenter.shared
    /// Host hook for informational popovers (the app routes to its AI window).
    public var showInfo: (String, String) -> Void = { _, _ in }
    /// Commands contributed by plugins, tagged with the owning plugin so the
    /// Plugins menu can group them.
    private(set) var commands: [(id: String, title: String, plugin: String,
                                owner: String?, run: () -> Void)] = []
    /// The plugin currently being activated (for command attribution).
    private var activatingPlugin: String = "Plugin"

    /// The set of plugins compiled into this build. Adding a plugin = one line.
    /// Nothing is compiled in anymore — Bridge and Codio ship as external
    /// plugins built on the public SDK (Plugins/ in the repo, installed to
    /// ~/.config/cmdy/plugins/ by plugins.sh). Built-in slots remain for
    /// anything that truly needs in-process access.
    nonisolated(unsafe) static let builtins: [CmdyPlugin.Type] = []

    private struct ExternalProcess {
        let dir: URL
        let manifest: ExtensionManifest
        let scope: String
        /// Unique bearer token and resource owner for this exact launch.
        let owner: String
        let process: Process
        let outputPipe: Pipe?
    }
    private struct HookRegistration {
        let id: String
        let kind: ExtensionHookKind
        let priority: Int
        let owner: String
        let extensionID: String
    }
    private final class PendingHook {
        let owner: String
        private let condition = NSCondition()
        private var decision: ExtensionDecision?

        init(owner: String) { self.owner = owner }

        func resolve(_ decision: ExtensionDecision) {
            condition.lock()
            guard self.decision == nil else { condition.unlock(); return }
            self.decision = decision
            condition.broadcast()
            condition.unlock()
        }

        func wait(until deadline: Date) -> ExtensionDecision? {
            condition.lock()
            while decision == nil, deadline.timeIntervalSinceNow > 0 {
                _ = condition.wait(until: deadline)
            }
            let result = decision
            condition.unlock()
            return result
        }
    }
    private var externalProcesses: [ExternalProcess] = []
    private var readyExternalOwners = Set<String>()
    private var extensionFailures: [URL: String] = [:]
    private var extensionLogTails: [URL: String] = [:]
    private var hooks: [HookRegistration] = []
    private var pendingHooks: [String: PendingHook] = [:]
    private let pendingHookLock = NSLock()
    private var externalHotKeys: [String: (owner: String, registration: UInt32)] = [:]
    /// Main-thread-owned replacement state. A marketplace install may finish
    /// before a stubborn old process exits; launch that replacement only after
    /// every terminating process for the same directory is gone.
    private var stoppingProcessIDs: Set<ObjectIdentifier> = []
    private var pendingProcessLaunches: [URL: URL] = [:]
    private var isDeactivating = false
    private lazy var trustStore = ExtensionTrustStore(
        url: ConfigFile.directory.appendingPathComponent("extension-trust.json"))
    private var promptedProjectRoots = Set<String>()
    private var projectExtensionReconcileWorkItem: DispatchWorkItem?
    private struct DevelopmentSession {
        let id: String
        let source: URL
        let launchDirectory: URL
        let temporary: Bool
        var signature: String
        var heartbeat: Date
        var nextLogSequence: Int
        var logs: [[String: Any]]
    }
    private var developmentSessions: [String: DevelopmentSession] = [:]
    private var developmentTimer: DispatchSourceTimer?

    /// The pane that hosts SDK-driven inline panels (set by AppDelegate).
    public var panelPaneProvider: () -> (any InlinePanelHost)? = { nil }
    /// Resolve an inline-panel host in one exact terminal window. Extensions
    /// with companion windows must not send their agent chooser to whichever
    /// unrelated Cmdy window happened to become key most recently.
    public var panelPaneForWindowProvider: (_ windowNumber: Int?) -> (any InlinePanelHost)? = { _ in nil }
    /// Resolve the terminal pane that owns a persistent Extension control row.
    /// A window number keeps companion controls paired with the exact window
    /// even when another Cmdy window becomes key.
    public var controlBarHostProvider: (_ windowNumber: Int?) -> (any ExtensionControlBarHost)? = { _ in nil }
    /// Genuine in-window native views must be created in the app process.
    /// CmdyKit owns the manifest/toggle lifecycle and delegates only this
    /// narrow, allow-listed component activation boundary to the app.
    public var hostComponentLifecycle:
        (_ identifier: String, _ directory: URL, _ enabled: Bool) -> Bool = {
            _, _, _ in false
        }
    /// App-owned setup gate for agent launches requested by an Extension.
    /// The default preserves the protocol's standalone behavior; Cmdy's app
    /// installs a deterministic MCP/permission preflight before launching.
    public var agentLaunchPreflight: (
        _ command: String,
        _ displayName: String,
        _ sourceExtensionID: String?,
        _ pane: PluginPane,
        _ host: any InlinePanelHost,
        _ alreadyRunning: Bool
    ) -> Void = { command, _, _, pane, _, alreadyRunning in
        if !alreadyRunning { pane.run(command) }
    }
    /// Resolve a pane-specific (or focused, for nil) host for Surface Protocol
    /// documents. The host remains App-owned; the manager retains it weakly.
    public var surfaceHostProvider: (_ paneID: String?) -> (any ExtensionSurfaceHost)? = { _ in nil }
    /// Split the pane with the given id ("right" → vertical divider, else
    /// "down"); returns the new pane's id. Set by the app.
    public var splitProvider: (_ paneId: String, _ vertical: Bool) -> String? = { _, _ in nil }
    /// Close the pane with the given id; returns whether it existed. Set by the app.
    public var closeProvider: (_ paneId: String) -> Bool = { _ in false }
    /// Move several existing live panes into one newly arranged window.
    public var composePanesProvider: (_ paneIDs: [String]) throws -> [String: Any] = { _ in
        throw NSError(
            domain: "CmdyKit.PluginHost", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "pane composition is unavailable"])
    }
    /// Renderer frame counter for the perf gate (set by the app).
    public var frameStatsProvider: () -> [String: Any] = { [:] }
    /// Applies a plugin-reserved right inset to one terminal window, or every
    /// window when `windowNumber` is nil, and returns its pane-area geometry
    /// {top, bottom, side} (set by AppDelegate).
    /// `minHeight` > 0 makes cmdy GROW to fit a fixed-size docked window
    /// (the iOS Simulator) instead of squeezing it into the strip.
    public var applyDockInset: (_ inset: CGFloat, _ minHeight: CGFloat,
                                _ windowNumber: Int?) -> [String: Any] = { _, _, _ in [:] }
    private final class SDKPanelRecord {
        let panel: InlinePanel
        let owner: String?
        var textBytes: Int

        init(panel: InlinePanel, owner: String?, textBytes: Int) {
            self.panel = panel
            self.owner = owner
            self.textBytes = textBytes
        }
    }
    /// SDK panels created over HTTP, by id and process owner.
    private var sdkPanels: [String: SDKPanelRecord] = [:]
    private final class SDKControlBarRecord {
        let owner: String?
        weak var host: (any ExtensionControlBarHost)?
        weak var bar: ExtensionControlBar?
        var actions: [ExtensionControlBarAction]
        var placeholder: String

        init(owner: String?, host: any ExtensionControlBarHost,
             bar: ExtensionControlBar, actions: [ExtensionControlBarAction],
             placeholder: String) {
            self.owner = owner
            self.host = host
            self.bar = bar
            self.actions = actions
            self.placeholder = placeholder
        }
    }
    private struct SDKControlBarKey: Hashable {
        let owner: String?
        let id: String
    }
    private var sdkControlBars: [SDKControlBarKey: SDKControlBarRecord] = [:]
    private struct SDKWorkspaceKey: Hashable {
        let owner: String
        let id: String
    }
    /// Declarative, bounded contributions to the Adaptive Frame. The app asks
    /// for context-matched snapshots; Extensions never receive an AppKit view.
    private var sdkWorkspaceContributions: [SDKWorkspaceKey: ExtensionWorkspaceContribution] = [:]
    private final class SDKSurfaceRecord {
        var document: SurfaceDocument
        let owner: String?
        let extensionID: String?
        weak var host: (any ExtensionSurfaceHost)?
        weak var view: NativeSurfaceView?
        var patchTimes: [Date] = []

        init(document: SurfaceDocument, owner: String?, extensionID: String?,
             host: any ExtensionSurfaceHost, view: NativeSurfaceView) {
            self.document = document
            self.owner = owner
            self.extensionID = extensionID
            self.host = host
            self.view = view
        }
    }
    private struct SDKSurfaceKey: Hashable {
        let owner: String?
        let id: String
    }
    private var sdkSurfaces: [SDKSurfaceKey: SDKSurfaceRecord] = [:]

    private struct DockTarget: Hashable {
        let windowNumber: Int?
    }
    private struct DockReservation {
        let right: CGFloat
        let minHeight: CGFloat
    }
    /// One external companion owns a window's right dock at a time. Different
    /// windows can host different companions concurrently.
    private var dockReservations: [String: [DockTarget: DockReservation]] = [:]

    private struct FeedbackSteeringItem {
        let id: String
        let prompt: String
    }
    private struct FeedbackSteeringState {
        var active: FeedbackSteeringItem? = nil
        var activeIsStaged = false
        var pending: [FeedbackSteeringItem] = []

        var depth: Int { (active == nil ? 0 : 1) + pending.count }
    }
    struct FeedbackSteeringReceipt {
        let delivery: String
        let position: Int
        let depth: Int
    }
    /// Agent feedback is intentionally staged one prompt at a time. Return
    /// submits the active item; only then is the next item placed in input.
    private var feedbackSteeringQueues: [String: FeedbackSteeringState] = [:]

    func enqueueFeedbackSteering(id: String, prompt: String,
                                 in pane: PluginPane) -> FeedbackSteeringReceipt {
        let item = FeedbackSteeringItem(id: id, prompt: prompt)
        var state = feedbackSteeringQueues[pane.id] ?? FeedbackSteeringState()
        let receipt: FeedbackSteeringReceipt
        if state.active == nil {
            state.active = item
            state.activeIsStaged = true
            receipt = FeedbackSteeringReceipt(delivery: "staged", position: 1, depth: 1)
        } else {
            state.pending.append(item)
            receipt = FeedbackSteeringReceipt(
                delivery: "queued",
                position: state.pending.count + 1,
                depth: state.depth)
        }
        feedbackSteeringQueues[pane.id] = state
        if receipt.delivery == "staged" {
            pane.stage(prompt)
        }
        emit("feedback-queue", [
            "pane": pane.id,
            "active": state.active?.id ?? "",
            "depth": state.depth,
        ])
        return receipt
    }

    /// Called by the terminal key path after a real, unmodified Return. The
    /// current annotation is considered submitted and the next one is staged
    /// after the agent TUI has had a moment to clear its input line.
    @discardableResult
    public func feedbackPromptDidSubmit(in paneID: String) -> Bool {
        feedbackPromptDidSubmit(in: paneID, stageDelay: 0.12)
    }

    @discardableResult
    func feedbackPromptDidSubmit(in paneID: String, stageDelay: TimeInterval) -> Bool {
        guard var state = feedbackSteeringQueues[paneID],
              state.active != nil, state.activeIsStaged else { return false }
        state.active = nil
        state.activeIsStaged = false
        guard !state.pending.isEmpty else {
            feedbackSteeringQueues[paneID] = nil
            emit("feedback-queue", ["pane": paneID, "active": "", "depth": 0])
            return true
        }

        let next = state.pending.removeFirst()
        state.active = next
        feedbackSteeringQueues[paneID] = state
        emit("feedback-queue", [
            "pane": paneID,
            "active": next.id,
            "depth": state.depth,
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + stageDelay) { [weak self] in
            guard let self,
                  var current = self.feedbackSteeringQueues[paneID],
                  current.active?.id == next.id,
                  !current.activeIsStaged else { return }
            guard let pane = self.pane(withID: paneID),
                  pane.aiTool != nil else {
                self.feedbackSteeringQueues[paneID] = nil
                self.emit("feedback-queue", ["pane": paneID, "active": "", "depth": 0])
                return
            }
            pane.stage(next.prompt)
            current.activeIsStaged = true
            self.feedbackSteeringQueues[paneID] = current
        }
        return true
    }

    func feedbackSteeringDepth(in paneID: String) -> Int {
        feedbackSteeringQueues[paneID]?.depth ?? 0
    }

    /// Push an event to every /v1/events subscriber (the SDK's nervous system).
    public func emit(_ kind: String, _ payload: [String: Any] = [:]) {
        var event = payload
        event["kind"] = kind
        server.broadcast(event)
    }

    private func emit(_ kind: String, _ payload: [String: Any] = [:],
                      toOwner owner: String?) {
        var event = payload
        event["kind"] = kind
        server.broadcast(event, toOwner: owner, privateDelivery: true)
    }

    public var channelRuntimes: [CmdyChannelRuntime] {
        channelRegistry.channelRuntimes()
    }

    public func channelWorkItems(includeTerminal: Bool = true) -> [CmdyWorkItem] {
        channelRegistry.visibleWorkItems(includeTerminal: includeTerminal)
    }

    public var channelReplies: [CmdyChannelReply] {
        channelRegistry.visibleReplies()
    }

    public func setChannelWorkItemStatus(channelID: String, workItemID: String,
                                         status: CmdyWorkItemStatus) throws {
        try channelRegistry.setStatus(channelID: channelID, workItemID: workItemID,
                                      status: status)
    }

    public func removeChannel(id: String) throws {
        try channelRegistry.removeChannel(id: id, owner: nil)
    }

    @discardableResult
    public func draftChannelReply(channelID: String, workItemID: String,
                                  kind: CmdyChannelReplyKind,
                                  body: String) throws -> CmdyChannelReply {
        try channelRegistry.createDraft(channelID: channelID, workItemID: workItemID,
                                        kind: kind, body: body)
    }

    /// A deliberate host/user action moves a private draft into the connector
    /// outbox. If the connector is offline it remains queued and is returned
    /// by its next registration; it is never broadcast to another Extension.
    @discardableResult
    public func sendChannelReply(id: String,
                                 confirmVerificationNeeded: Bool = false) throws
        -> CmdyChannelReply {
        let queued = try channelRegistry.queueReply(
            id: id, confirmVerificationNeeded: confirmVerificationNeeded)
        if let owner = queued.owner {
            var payload = channelRegistry.payload(for: queued.reply)
            // `kind` is reserved for the SSE event discriminator.
            payload["replyKind"] = queued.reply.kind.rawValue
            emit("channel-reply", payload, toOwner: owner)
        }
        return queued.reply
    }

    public func discardChannelReply(id: String) throws {
        try channelRegistry.discardReply(id: id)
    }

    public func beginChannelShellResult(channelID: String, workItemID: String,
                                        paneID: String) throws {
        try channelRegistry.beginShellResult(channelID: channelID,
                                             workItemID: workItemID, paneID: paneID)
    }

    public func cancelChannelShellResult(channelID: String, workItemID: String,
                                         paneID: String) {
        channelRegistry.cancelShellResult(channelID: channelID,
                                          workItemID: workItemID, paneID: paneID)
    }

    public func cancelChannelShellResult(paneID: String) {
        channelRegistry.cancelShellResult(paneID: paneID)
    }

    public func channelCommandStarted(paneID: String, blockID: String) {
        channelRegistry.commandStarted(paneID: paneID, blockID: blockID)
    }

    @discardableResult
    public func channelCommandFinished(paneID: String, blockID: String,
                                       command: String, exitCode: Int,
                                       output: String) -> CmdyChannelReply? {
        channelRegistry.commandFinished(paneID: paneID, blockID: blockID,
                                        command: command, exitCode: exitCode,
                                        output: output)
    }

    private func require(_ capability: ExtensionCapability,
                         for request: PluginHTTPRequest) -> PluginHTTPResponse? {
        guard let granted = request.extensionCapabilities,
              !granted.contains(capability) else { return nil }
        return .forbidden("extension capability required: \(capability.rawValue)")
    }

    private static func isValidResourceID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "."
                || $0 == "-" || $0 == "_")
        }
    }

    static func decodeWorkspaceContribution(
        _ json: [String: Any], id: String, owner: String,
        extensionID: String, extensionName: String,
        replacing old: ExtensionWorkspaceContribution? = nil
    ) throws -> ExtensionWorkspaceContribution {
        func invalid(_ message: String) -> NSError {
            NSError(domain: "CmdyKit.WorkspaceContribution", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard isValidResourceID(id) else {
            throw invalid("contribution id must be 1-128 ASCII letters, numbers, '.', '-', or '_'")
        }
        let locationText = json["location"] as? String ?? old?.location.rawValue
        guard let locationText,
              let location = ExtensionWorkspaceLocation(rawValue: locationText) else {
            throw invalid("location must be navigator or inspector")
        }
        let title = json["title"] as? String ?? old?.title ?? ""
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 128 else {
            throw invalid("title must be non-empty and at most 128 bytes")
        }
        let windowNumber = (json["window"] as? NSNumber)?.intValue ?? old?.windowNumber
        if let windowNumber, windowNumber <= 0 { throw invalid("window must be positive") }
        let paneID = json.keys.contains("pane") ? json["pane"] as? String : old?.paneID
        if let paneID, paneID.utf8.count > 128 { throw invalid("pane id is too long") }
        let priority = (json["priority"] as? NSNumber)?.intValue ?? old?.priority ?? 0
        guard (-1_000...1_000).contains(priority) else {
            throw invalid("priority must be between -1000 and 1000")
        }
        let contexts: Set<ExtensionWorkspaceContext>
        if let raw = json["contexts"] as? [String] {
            guard raw.count <= ExtensionWorkspaceContext.allCases.count else {
                throw invalid("too many contexts")
            }
            let decoded = raw.compactMap(ExtensionWorkspaceContext.init(rawValue:))
            guard decoded.count == raw.count else {
                throw invalid("contexts may contain pane, command, selection, or surface")
            }
            contexts = Set(decoded)
        } else {
            contexts = old?.contexts ?? []
        }

        let items: [ExtensionWorkspaceItem]
        if let rawItems = json["items"] as? [[String: Any]] {
            guard !rawItems.isEmpty, rawItems.count <= 64 else {
                throw invalid("a contribution needs 1-64 items")
            }
            var decoded: [ExtensionWorkspaceItem] = []
            var seen = Set<String>()
            for raw in rawItems {
                guard let itemID = raw["id"] as? String, isValidResourceID(itemID),
                      seen.insert(itemID).inserted,
                      let itemTitle = raw["title"] as? String,
                      !itemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      itemTitle.utf8.count <= 256 else {
                    throw invalid("each item needs a unique valid id and a title up to 256 bytes")
                }
                let detail = raw["detail"] as? String
                let badge = raw["badge"] as? String
                let action = raw["action"] as? String
                guard (detail?.utf8.count ?? 0) <= 2_048,
                      (badge?.utf8.count ?? 0) <= 64,
                      (action == nil || isValidResourceID(action!)) else {
                    throw invalid("item detail, badge, or action exceeds its resource budget")
                }
                let statusText = raw["status"] as? String ?? "neutral"
                guard let status = ExtensionWorkspaceItemStatus(rawValue: statusText) else {
                    throw invalid("item status must be neutral, active, attention, success, or failure")
                }
                decoded.append(ExtensionWorkspaceItem(
                    id: itemID, title: itemTitle, detail: detail, badge: badge,
                    status: status, action: action,
                    isEnabled: raw["enabled"] as? Bool ?? true))
            }
            items = decoded
        } else if let old {
            items = old.items
        } else {
            throw invalid("items are required")
        }

        let sequence = (json["sequence"] as? NSNumber)?.intValue
            ?? old.map { $0.sequence + 1 } ?? 0
        guard sequence >= 0 else { throw invalid("sequence cannot be negative") }
        if let old, sequence <= old.sequence {
            throw invalid("stale sequence \(sequence); next must exceed \(old.sequence)")
        }
        return ExtensionWorkspaceContribution(
            owner: owner, extensionID: extensionID, extensionName: extensionName,
            id: id, location: location, title: title,
            windowNumber: windowNumber, paneID: paneID, priority: priority,
            contexts: contexts, sequence: sequence, items: items)
    }

    /// Current native palette exposed to external UI so companion surfaces use
    /// the same colors as the Cmdy window instead of inventing a brand blue.
    public func themePayload() -> [String: Any] {
        let theme = Preferences.shared.theme
        func hex(_ color: TermColor) -> String {
            let r = min(255, (Int(color.red) + 128) / 257)
            let g = min(255, (Int(color.green) + 128) / 257)
            let b = min(255, (Int(color.blue) + 128) / 257)
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return [
            "name": theme.name,
            "background": hex(theme.background),
            "foreground": hex(theme.foreground),
            "cursor": hex(theme.cursor),
            "border": hex(theme.border),
            "ansi": theme.ansi.map(hex),
        ]
    }

    public func emitThemeChanged() {
        emit("theme-changed", themePayload())
    }

    public func workspaceContributions(
        location: ExtensionWorkspaceLocation,
        windowNumber: Int?, paneID: String?,
        contexts: Set<ExtensionWorkspaceContext>
    ) -> [ExtensionWorkspaceContribution] {
        sdkWorkspaceContributions.values.filter { contribution in
            guard contribution.location == location else { return false }
            if let target = contribution.windowNumber, target != windowNumber { return false }
            if let target = contribution.paneID, target != paneID { return false }
            return contribution.contexts.isEmpty
                || !contribution.contexts.isDisjoint(with: contexts)
        }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.extensionName != $1.extensionName {
                return $0.extensionName.localizedCaseInsensitiveCompare($1.extensionName) == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    /// Route one row activation privately to its owning Extension.
    @discardableResult
    public func activateWorkspaceContribution(owner: String, id: String,
                                              itemID: String) -> Bool {
        let key = SDKWorkspaceKey(owner: owner, id: id)
        guard let contribution = sdkWorkspaceContributions[key],
              let item = contribution.items.first(where: { $0.id == itemID }),
              item.isEnabled, let action = item.action, !action.isEmpty else { return false }
        emit("ui", [
            "event": "action", "contribution": id,
            "item": itemID, "action": action,
        ], toOwner: owner)
        return true
    }

    private func notifyWorkspaceContributionsChanged() {
        NotificationCenter.default.post(
            name: .cmdyWorkspaceContributionsChanged, object: self)
    }

    public func activateAll() {
        precondition(Thread.isMainThread, "plugin lifecycle is main-thread owned")
        isDeactivating = false
        server.onPluginAuthenticated = { [weak self] owner in
            DispatchQueue.main.async {
                self?.markExtensionReady(owner: owner)
            }
        }
        server.route("GET", "/health") { _ in
            .ok(["ok": true, "app": ProductIdentity.current.slug])
        }
        server.streamRoute("/v1/events", capability: .events)
        registerCoreRoutes()
        registerSDKRoutes()
        server.start()
        writeDiscoveryFile()
        for type in Self.builtins {
            guard Preferences.shared.isPluginEnabled(type.id) else {
                log("[\(type.displayName)] disabled — skipped")
                continue
            }
            let plugin = type.init()
            activatingPlugin = type.displayName
            plugin.activate(host: self)
            plugins.append(plugin)
            log("[\(type.displayName)] activated")
        }
        launchExternalPlugins()
    }

    public func deactivateAll() {
        precondition(Thread.isMainThread, "plugin lifecycle is main-thread owned")
        isDeactivating = true
        projectExtensionReconcileWorkItem?.cancel()
        projectExtensionReconcileWorkItem = nil
        pendingProcessLaunches.removeAll()
        plugins.forEach { $0.deactivate() }
        plugins.removeAll()
        var changedDirectories = Set(externalProcesses.map { $0.dir.standardizedFileURL })
        changedDirectories.formUnion(activeHostComponents.keys)
        for (directory, manifest) in activeHostComponents {
            if let identifier = manifest.hostComponent {
                _ = hostComponentLifecycle(identifier, directory, false)
            }
        }
        activeHostComponents.removeAll()
        let processesToStop = externalProcesses
        for external in processesToStop {
            external.outputPipe?.fileHandleForReading.readabilityHandler = nil
            cleanupPluginResources(owner: external.owner)
            server.revokePluginCredential(external.owner)
            if external.process.isRunning { external.process.terminate() }
        }
        // Extension helpers are children of the app. Give cooperative clients
        // one short grace period, then kill any holdout before relinquishing
        // Process ownership; otherwise an extension that ignores SIGTERM can
        // survive app quit with its pipes and host resources still active.
        var deadline = Date(timeIntervalSinceNow: 0.15)
        while Date() < deadline,
              processesToStop.contains(where: { $0.process.isRunning }) {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
        }
        for external in processesToStop where external.process.isRunning {
            kill(external.process.processIdentifier, SIGKILL)
        }
        deadline = Date(timeIntervalSinceNow: 0.05)
        while Date() < deadline,
              processesToStop.contains(where: { $0.process.isRunning }) {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
        }
        externalProcesses.removeAll()
        readyExternalOwners.removeAll()
        for (_, hotKey) in externalHotKeys {
            hotKeys.unregister(hotKey.registration)
        }
        externalHotKeys.removeAll()
        sdkPanels.values.forEach { $0.panel.dismiss() }
        sdkPanels.removeAll()
        sdkControlBars.values.forEach { record in
            if let bar = record.bar { record.host?.dismissExtensionControlBar(bar) }
        }
        sdkControlBars.removeAll()
        sdkWorkspaceContributions.removeAll()
        notifyWorkspaceContributionsChanged()
        sdkSurfaces.values.forEach { record in
            if let view = record.view { record.host?.dismissExtensionSurface(view) }
        }
        sdkSurfaces.removeAll()
        commands.removeAll { $0.owner != nil }
        dockReservations.removeAll()
        feedbackSteeringQueues.removeAll()
        stoppingProcessIDs.removeAll()
        developmentTimer?.cancel()
        developmentTimer = nil
        for directory in changedDirectories {
            notifyExtensionRuntimeChanged(at: directory)
        }
        let temporaryDevDirectories = developmentSessions.values
            .filter(\.temporary).map(\.launchDirectory)
        developmentSessions.removeAll()
        temporaryDevDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        Self.discoveryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        server.stop()
    }

    private func setDockReservation(owner: String?, right: CGFloat,
                                    minHeight: CGFloat,
                                    windowNumber: Int?) -> [String: Any] {
        guard let owner else {
            return applyDockInset(right, minHeight, windowNumber)
        }
        let target = DockTarget(windowNumber: windowNumber)
        if right > 0 {
            let displaced = dockReservations.compactMap { existingOwner, reservations in
                existingOwner != owner && reservations[target] != nil ? existingOwner : nil
            }
            for existingOwner in displaced {
                dockReservations[existingOwner]?[target] = nil
                if dockReservations[existingOwner]?.isEmpty == true {
                    dockReservations[existingOwner] = nil
                }
                var payload: [String: Any] = ["by": owner]
                if let windowNumber { payload["window"] = windowNumber }
                emit("companion-replaced", payload, toOwner: existingOwner)
            }
            dockReservations[owner, default: [:]][target] = DockReservation(
                right: right, minHeight: minHeight)
        } else {
            dockReservations[owner]?[target] = nil
            if dockReservations[owner]?.isEmpty == true { dockReservations[owner] = nil }
        }
        return applyAggregateDockReservation(for: target)
    }

    @discardableResult
    private func applyAggregateDockReservation(for target: DockTarget) -> [String: Any] {
        let reservations = dockReservations.values.compactMap { $0[target] }
        let right = reservations.map(\.right).max() ?? 0
        let minHeight = reservations.map(\.minHeight).max() ?? 0
        return applyDockInset(right, minHeight, target.windowNumber)
    }

    private func cleanupPluginResources(owner: String) {
        commands.removeAll { $0.owner == owner }
        hooks.removeAll { $0.owner == owner }
        channelRegistry.disconnect(owner: owner)

        pendingHookLock.lock()
        let abandoned = pendingHooks.filter { $0.value.owner == owner }
        abandoned.keys.forEach { pendingHooks[$0] = nil }
        pendingHookLock.unlock()
        abandoned.values.forEach { $0.resolve(ExtensionDecision(.continue)) }

        let hotKeyIDs = externalHotKeys.compactMap { key, value in
            value.owner == owner ? key : nil
        }
        for id in hotKeyIDs {
            if let registration = externalHotKeys.removeValue(forKey: id)?.registration {
                hotKeys.unregister(registration)
            }
        }

        let panelIDs = sdkPanels.compactMap { key, value in
            value.owner == owner ? key : nil
        }
        for id in panelIDs {
            sdkPanels.removeValue(forKey: id)?.panel.dismiss()
        }

        let controlBarKeys = sdkControlBars.compactMap { key, value in
            value.owner == owner ? key : nil
        }
        for key in controlBarKeys {
            if let record = sdkControlBars.removeValue(forKey: key),
               let bar = record.bar {
                record.host?.dismissExtensionControlBar(bar)
            }
        }

        let workspaceKeys = sdkWorkspaceContributions.keys.filter { $0.owner == owner }
        if !workspaceKeys.isEmpty {
            workspaceKeys.forEach { sdkWorkspaceContributions[$0] = nil }
            notifyWorkspaceContributionsChanged()
        }

        let surfaceKeys = sdkSurfaces.compactMap { key, value in
            value.owner == owner ? key : nil
        }
        for key in surfaceKeys {
            if let record = sdkSurfaces.removeValue(forKey: key) {
                if let view = record.view { record.host?.dismissExtensionSurface(view) }
            }
        }

        let targets = Set(dockReservations[owner]?.keys.map { $0 } ?? [])
        dockReservations[owner] = nil
        for target in targets { applyAggregateDockReservation(for: target) }
    }

    /// Run registered decision hooks in a stable order. The first non-continue
    /// answer wins. Every boundary has one short shared deadline; a crashed or
    /// slow extension therefore degrades to normal terminal behavior.
    public func decide(_ kind: ExtensionHookKind, payload: [String: Any],
                       budget: TimeInterval = 0.12) -> ExtensionDecision {
        precondition(Thread.isMainThread, "extension decisions are main-thread owned")
        let candidates = hooks.filter { $0.kind == kind }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.extensionID != $1.extensionID { return $0.extensionID < $1.extensionID }
            return $0.id < $1.id
        }
        guard !candidates.isEmpty else { return ExtensionDecision(.continue) }

        let overallDeadline = Date(timeIntervalSinceNow: max(0, min(0.5, budget)))
        for registration in candidates where overallDeadline.timeIntervalSinceNow > 0 {
            let requestID = UUID().uuidString
            let pending = PendingHook(owner: registration.owner)
            pendingHookLock.lock()
            pendingHooks[requestID] = pending
            pendingHookLock.unlock()

            var event = payload
            event["request"] = requestID
            event["hook"] = registration.id
            event["boundary"] = kind.rawValue
            event["deadlineMs"] = max(1, Int(overallDeadline.timeIntervalSinceNow * 1_000))
            emit("hook", event, toOwner: registration.owner)

            let perHook = min(overallDeadline,
                              Date(timeIntervalSinceNow: min(0.06,
                                  max(0, overallDeadline.timeIntervalSinceNow))))
            let answer = pending.wait(until: perHook)
            pendingHookLock.lock()
            pendingHooks[requestID] = nil
            pendingHookLock.unlock()
            guard let answer, answer.action != .continue else { continue }
            if answer.action == .replace, answer.value == nil { continue }
            return answer
        }
        return ExtensionDecision(.continue)
    }

    private func wireSurfaceCallbacks(_ record: SDKSurfaceRecord) {
        let key = SDKSurfaceKey(owner: record.owner, id: record.document.id)
        let id = record.document.id
        record.view?.onDismiss = { [weak self] in
            self?.removeSurface(key: key, notifyOwner: true)
        }
        record.view?.onAction = { [weak self, weak record] action, itemID, values in
            guard let self, let record,
                  self.sdkSurfaces[key] === record else { return }
            var payload: [String: Any] = [
                "surface": id,
                "action": action.id,
                "effect": action.effect.rawValue,
                "values": values.mapValues(Self.surfaceJSONValue),
                "sequence": record.document.sequence,
            ]
            if let itemID { payload["item"] = itemID }
            self.emit("surface-action", payload, toOwner: record.owner)
        }
    }

    private func removeSurface(key: SDKSurfaceKey, notifyOwner: Bool) {
        guard let record = sdkSurfaces.removeValue(forKey: key) else { return }
        if let view = record.view { record.host?.dismissExtensionSurface(view) }
        if notifyOwner {
            emit("surface-dismissed", ["surface": key.id], toOwner: record.owner)
        }
    }

    private static func surfaceJSONValue(_ value: SurfaceValue) -> Any {
        switch value {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }

    // MARK: - Core HTTP API (the plugin ABI — see PLUGINS.md)

    // MARK: - SDK routes (build Bridge-scale plugins in any language)

    private func registerSDKCommand(_ json: [String: Any]?, request req: PluginHTTPRequest)
        -> PluginHTTPResponse {
        guard let id = json?["id"] as? String,
              let title = json?["title"] as? String else {
            return .badRequest("need {id, title}")
        }
        if let denied = require(.commands, for: req) { return denied }
        guard Self.isValidResourceID(id), !title.isEmpty, title.utf8.count <= 512 else {
            return .badRequest("command id or title exceeds its resource budget")
        }
        if commands.contains(where: { $0.id == id && $0.owner != req.pluginOwner }) {
            return .badRequest("command id is already registered by another plugin")
        }
        let isNew = !commands.contains { $0.id == id && $0.owner == req.pluginOwner }
        guard !isNew || commands.lazy.filter({ $0.owner == req.pluginOwner }).count < 256 else {
            return .tooManyRequests("an Extension may register at most 256 commands")
        }
        let plugin = req.pluginName ?? json?["plugin"] as? String ?? "SDK"
        commands.removeAll { $0.id == id && $0.owner == req.pluginOwner }
        commands.append((id: id, title: title, plugin: plugin,
                         owner: req.pluginOwner,
                         run: { [weak self] in
                             guard let self else { return }
                             var payload: [String: Any] = ["id": id]
                             if let windowNumber = self.focusedPane?.windowNumber,
                                windowNumber > 0 {
                                 payload["window"] = windowNumber
                             }
                             self.emit(
                                "command", payload,
                                toOwner: req.pluginOwner)
                         }))
        return .ok(["ok": true])
    }

    private func registerSDKHotKey(_ json: [String: Any]?, request req: PluginHTTPRequest)
        -> PluginHTTPResponse {
        guard let id = json?["id"] as? String,
              let keyCode = json?["keyCode"] as? Int,
              let modifiers = json?["modifiers"] as? Int else {
            return .badRequest("need {id, keyCode, modifiers} (Carbon codes)")
        }
        if let denied = require(.hotkeys, for: req) { return denied }
        let owner = req.pluginOwner ?? "discovery"
        guard Self.isValidResourceID(id),
              let carbonKeyCode = UInt32(exactly: keyCode), carbonKeyCode <= 255,
              let carbonModifiers = UInt32(exactly: modifiers) else {
            return .badRequest("hotkey id, keyCode, or modifiers are out of range")
        }
        let isNew = externalHotKeys[id] == nil
        guard !isNew || externalHotKeys.values.lazy.filter({ $0.owner == owner }).count < 64 else {
            return .tooManyRequests("an Extension may register at most 64 hotkeys")
        }
        if let previous = externalHotKeys[id] {
            guard previous.owner == owner else {
                return .badRequest("hotkey id is already registered by another plugin")
            }
            hotKeys.unregister(previous.registration)
            externalHotKeys[id] = nil
        }
        let registration = hotKeys.register(
            keyCode: carbonKeyCode, modifiers: carbonModifiers
        ) { [weak self] in
            guard let self else { return }
            var payload: [String: Any] = ["id": id]
            if let windowNumber = self.focusedPane?.windowNumber,
               windowNumber > 0 {
                payload["window"] = windowNumber
            }
            self.emit("hotkey", payload, toOwner: req.pluginOwner)
        }
        guard let registration else { return .badRequest("hotkey registration failed") }
        externalHotKeys[id] = (owner: owner, registration: registration)
        return .ok(["ok": true])
    }

    private func registerSDKHook(_ json: [String: Any]?, request req: PluginHTTPRequest)
        -> PluginHTTPResponse {
        guard let owner = req.pluginOwner,
              let extensionID = req.pluginID,
              let id = json?["id"] as? String,
              let name = json?["boundary"] as? String,
              let kind = ExtensionHookKind(rawValue: name) else {
            return .badRequest("need {id, boundary}; hooks require a launched extension")
        }
        if let denied = require(.hooks, for: req) { return denied }
        guard Self.isValidResourceID(id) else {
            return .badRequest("hook id must be a stable ASCII id")
        }
        let isNew = !hooks.contains { $0.owner == owner && $0.id == id }
        guard !isNew || hooks.lazy.filter({ $0.owner == owner }).count < 64 else {
            return .tooManyRequests("an Extension may register at most 64 hooks")
        }
        let priority = max(-100, min(100, json?["priority"] as? Int ?? 0))
        hooks.removeAll { $0.owner == owner && $0.id == id }
        hooks.append(HookRegistration(id: id, kind: kind, priority: priority,
                                      owner: owner, extensionID: extensionID))
        return .ok(["ok": true, "boundary": kind.rawValue,
                    "budgetMs": 120, "priority": priority])
    }

    private static func channelErrorResponse(_ error: Error) -> PluginHTTPResponse {
        let message = error.localizedDescription
        guard let channelError = error as? CmdyChannelError else {
            return .badRequest(message)
        }
        switch channelError {
        case .forbidden: return .forbidden(message)
        case .notFound: return .notFound(message)
        case .conflict: return .conflict(message)
        case .invalid, .unavailable: return .badRequest(message)
        }
    }

    /// Channel connectors are a distinct product surface implemented by the
    /// capability-scoped Extension host with a `channels` grant. Discovery
    /// clients represent explicit host/user actions. In particular,
    /// a connector can ingest its own Work Items but can only read replies
    /// after the host has moved a private draft into the queued state.
    private func registerChannelRoutes() {
        server.route("POST", "/v1/channels") { [weak self] req in
            guard let self, let owner = req.pluginOwner,
                  let extensionID = req.pluginID, let payload = req.json else {
                return .badRequest("Channel registration requires a launched Extension")
            }
            if let denied = self.require(.channels, for: req) { return denied }
            do {
                let channel = try CmdyChannelRegistry.channel(from: payload)
                let runtime = try self.channelRegistry.register(
                    channel, extensionID: extensionID, owner: owner)
                let pending = self.channelRegistry.visibleReplies(
                    owner: owner, states: [.queued]).filter {
                        $0.channelID == channel.id
                    }
                return .ok([
                    "ok": true,
                    "channel": self.channelRegistry.payload(for: runtime),
                    "pendingReplies": pending.map(self.channelRegistry.payload(for:)),
                ])
            } catch { return Self.channelErrorResponse(error) }
        }

        server.route("GET", "/v1/channels") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.channels, for: req) { return denied }
            let channels = self.channelRegistry.channelRuntimes(owner: req.pluginOwner)
            return .ok(["channels": channels.map(self.channelRegistry.payload(for:))])
        }

        server.route("GET", "/v1/channels/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.channels, for: req) { return denied }
            let parts = req.pathTail.split(separator: "/")
            guard parts.count == 2, parts[1] == "health",
                  Self.isValidResourceID(String(parts[0])) else {
                return .notFound("expected /v1/channels/<id>/health")
            }
            guard let runtime = self.channelRegistry.channelRuntime(
                id: String(parts[0]), owner: req.pluginOwner) else {
                return .notFound("Channel not found")
            }
            return .ok([
                "channel": self.channelRegistry.payload(for: runtime),
                "health": self.channelRegistry.payload(for: runtime.health),
            ])
        }

        server.route("DELETE", "/v1/channels/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.channels, for: req) { return denied }
            guard Self.isValidResourceID(req.pathTail) else {
                return .badRequest("missing or invalid Channel id")
            }
            do {
                try self.channelRegistry.removeChannel(
                    id: req.pathTail, owner: req.pluginOwner)
                return .ok(["ok": true])
            } catch { return Self.channelErrorResponse(error) }
        }

        server.route("POST", "/v1/channels/") { [weak self] req in
            guard let self, let owner = req.pluginOwner, let payload = req.json else {
                return .badRequest("Channel updates require a launched Extension")
            }
            if let denied = self.require(.channels, for: req) { return denied }
            let parts = req.pathTail.split(separator: "/")
            guard parts.count == 2, Self.isValidResourceID(String(parts[0])) else {
                return .notFound("expected /v1/channels/<id>/work-items|health")
            }
            let channelID = String(parts[0])
            do {
                switch parts[1] {
                case "work-items":
                    guard let extensionID = req.pluginID else {
                        return .badRequest(
                            "Work Item ingestion requires a launched Extension")
                    }
                    let item = try CmdyChannelRegistry.workItem(
                        from: payload, channelID: channelID)
                    let result = try self.channelRegistry.ingest(
                        item, owner: owner, extensionID: extensionID)
                    return .ok([
                        "ok": true,
                        "deduplicated": result.deduplicated,
                        "workItem": self.channelRegistry.payload(for: result.item),
                    ])
                case "health":
                    let health = try CmdyChannelRegistry.health(from: payload)
                    let reported = try self.channelRegistry.reportHealth(
                        channelID: channelID, owner: owner, health: health)
                    return .ok([
                        "ok": true,
                        "health": self.channelRegistry.payload(for: reported),
                    ])
                default:
                    return .notFound("unknown Channel update operation")
                }
            } catch { return Self.channelErrorResponse(error) }
        }

        server.route("GET", "/v1/channel-work-items") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.channels, for: req) { return denied }
            let items = self.channelRegistry.visibleWorkItems(owner: req.pluginOwner)
            return .ok(["workItems": items.map(self.channelRegistry.payload(for:))])
        }

        server.route("PATCH", "/v1/channel-work-items/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.channels, for: req) { return denied }
            let parts = req.pathTail.split(separator: "/")
            guard parts.count == 2,
                  let raw = req.json?["status"] as? String,
                  let status = CmdyWorkItemStatus(rawValue: raw) else {
                return .badRequest("need /<channel>/<work-item> and a valid {status}")
            }
            let channelID = String(parts[0])
            let workItemID = String(parts[1])
            guard Self.isValidResourceID(channelID), Self.isValidResourceID(workItemID) else {
                return .badRequest("invalid Channel or Work Item id")
            }
            do {
                if let owner = req.pluginOwner {
                    try self.channelRegistry.connectorSetStatus(
                        channelID: channelID, workItemID: workItemID,
                        status: status, owner: owner)
                } else {
                    try self.channelRegistry.setStatus(
                        channelID: channelID, workItemID: workItemID, status: status)
                }
                return .ok(["ok": true, "status": status.rawValue])
            } catch { return Self.channelErrorResponse(error) }
        }

        server.route("POST", "/v1/channel-work-items/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            guard req.isDiscoveryClient else {
                return .forbidden("reply drafts require the discovery credential")
            }
            let parts = req.pathTail.split(separator: "/")
            guard parts.count == 3, parts[2] == "replies",
                  let body = req.json?["body"] as? String else {
                return .badRequest(
                    "need /<channel>/<work-item>/replies and {body, kind?, send?}")
            }
            let channelID = String(parts[0])
            let workItemID = String(parts[1])
            guard Self.isValidResourceID(channelID), Self.isValidResourceID(workItemID),
                  let kind = CmdyChannelReplyKind(
                    rawValue: req.json?["kind"] as? String ?? "result") else {
                return .badRequest("invalid Channel, Work Item, or reply kind")
            }
            do {
                var reply = try self.channelRegistry.createDraft(
                    channelID: channelID, workItemID: workItemID,
                    kind: kind, body: body)
                if req.json?["send"] as? Bool == true {
                    reply = try self.sendChannelReply(id: reply.id)
                }
                return .ok(["ok": true,
                            "reply": self.channelRegistry.payload(for: reply)])
            } catch { return Self.channelErrorResponse(error) }
        }

        server.route("GET", "/v1/channel-replies") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.channels, for: req) { return denied }
            let states: Set<CmdyChannelReplyState>? = req.isDiscoveryClient
                ? nil : [.queued]
            let replies = self.channelRegistry.visibleReplies(
                owner: req.pluginOwner, states: states)
            return .ok(["replies": replies.map(self.channelRegistry.payload(for:))])
        }

        server.route("DELETE", "/v1/channel-replies/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            guard req.isDiscoveryClient else {
                return .forbidden("discarding a reply requires the discovery credential")
            }
            guard Self.isValidResourceID(req.pathTail) else {
                return .badRequest("invalid reply id")
            }
            do {
                try self.channelRegistry.discardReply(id: req.pathTail)
                return .ok(["ok": true])
            } catch { return Self.channelErrorResponse(error) }
        }

        server.route("POST", "/v1/channel-replies/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            let parts = req.pathTail.split(separator: "/")
            guard parts.count == 2 else {
                return .notFound("expected /v1/channel-replies/<id>/send|attempt|ack")
            }
            let replyID = String(parts[0])
            guard Self.isValidResourceID(replyID) else {
                return .badRequest("invalid reply id")
            }
            do {
                switch parts[1] {
                case "send":
                    guard req.isDiscoveryClient else {
                        return .forbidden("sending a reply requires the discovery credential")
                    }
                    let reply = try self.sendChannelReply(
                        id: replyID,
                        confirmVerificationNeeded:
                            req.json?["confirmVerificationNeeded"] as? Bool == true)
                    return .ok(["ok": true,
                                "reply": self.channelRegistry.payload(for: reply)])
                case "attempt":
                    guard let owner = req.pluginOwner else {
                        return .badRequest(
                            "delivery attempt requires a launched Extension")
                    }
                    if let denied = self.require(.channels, for: req) { return denied }
                    let reply = try self.channelRegistry.beginReplyDelivery(
                        id: replyID, owner: owner)
                    return .ok(["ok": true,
                                "reply": self.channelRegistry.payload(for: reply)])
                case "ack":
                    guard let owner = req.pluginOwner else {
                        return .badRequest(
                            "acknowledgement requires a launched Extension")
                    }
                    if let denied = self.require(.channels, for: req) { return denied }
                    let acknowledgement = try CmdyChannelRegistry
                        .replyAcknowledgement(from: req.json ?? [:])
                    let reply: CmdyChannelReply
                    switch acknowledgement {
                    case .delivered:
                        reply = try self.channelRegistry.acknowledgeReply(
                            id: replyID, owner: owner, delivered: true)
                    case .failed(let error):
                        reply = try self.channelRegistry.acknowledgeReply(
                            id: replyID, owner: owner, delivered: false, error: error)
                    case .verificationNeeded(let detail):
                        reply = try self.channelRegistry.markReplyVerificationNeeded(
                            id: replyID, owner: owner, detail: detail)
                    }
                    return .ok(["ok": true,
                                "reply": self.channelRegistry.payload(for: reply)])
                default:
                    return .notFound("unknown Channel reply operation")
                }
            } catch { return Self.channelErrorResponse(error) }
        }
    }

    private func registerSDKRoutes() {
        registerChannelRoutes()

        // Adaptive Frame contributions are host-rendered, declarative rows.
        // They are deliberately not arbitrary views: this keeps theme,
        // keyboard behavior, responsive collapse, and cleanup deterministic.
        server.route("POST", "/v1/ui/contributions") { [weak self] req in
            guard let self, let owner = req.pluginOwner,
                  let json = req.json, let id = json["id"] as? String else {
                return .badRequest("need a launched Extension and {id, location, title, items}")
            }
            if let denied = self.require(.panels, for: req) { return denied }
            guard req.body.count <= 128 * 1_024 else {
                return .badRequest("contribution exceeds 128 KB")
            }
            let key = SDKWorkspaceKey(owner: owner, id: id)
            guard self.sdkWorkspaceContributions[key] == nil else {
                return .conflict("contribution '\(id)' already exists; use /update")
            }
            guard self.sdkWorkspaceContributions.keys.lazy.filter({ $0.owner == owner }).count < 16 else {
                return .tooManyRequests("an Extension may own at most 16 workspace contributions")
            }
            do {
                let contribution = try Self.decodeWorkspaceContribution(
                    json, id: id, owner: owner,
                    extensionID: req.pluginID ?? "extension",
                    extensionName: req.pluginName ?? req.pluginID ?? "Extension")
                self.sdkWorkspaceContributions[key] = contribution
                self.notifyWorkspaceContributionsChanged()
                return .ok(["ok": true, "contribution": id,
                            "sequence": contribution.sequence])
            } catch { return .badRequest(error.localizedDescription) }
        }

        server.route("GET", "/v1/ui/contributions") { [weak self] req in
            guard let self, let owner = req.pluginOwner else {
                return .badRequest("workspace contributions require a launched Extension")
            }
            if let denied = self.require(.panels, for: req) { return denied }
            let values = self.sdkWorkspaceContributions.values
                .filter { $0.owner == owner }
                .sorted { $0.id < $1.id }
                .map { contribution -> [String: Any] in
                    [
                        "id": contribution.id,
                        "location": contribution.location.rawValue,
                        "title": contribution.title,
                        "sequence": contribution.sequence,
                        "items": contribution.items.count,
                    ]
                }
            return .ok(["contributions": values])
        }

        server.route("POST", "/v1/ui/contributions/") { [weak self] req in
            let parts = req.pathTail.split(separator: "/")
            guard let self, let owner = req.pluginOwner, parts.count == 2,
                  parts[1] == "update" else {
                return .notFound("expected /v1/ui/contributions/<id>/update")
            }
            if let denied = self.require(.panels, for: req) { return denied }
            guard req.body.count <= 128 * 1_024 else {
                return .badRequest("contribution exceeds 128 KB")
            }
            let id = String(parts[0])
            let key = SDKWorkspaceKey(owner: owner, id: id)
            guard let old = self.sdkWorkspaceContributions[key] else {
                return .notFound("no such workspace contribution")
            }
            do {
                let contribution = try Self.decodeWorkspaceContribution(
                    req.json ?? [:], id: id, owner: owner,
                    extensionID: old.extensionID, extensionName: old.extensionName,
                    replacing: old)
                self.sdkWorkspaceContributions[key] = contribution
                self.notifyWorkspaceContributionsChanged()
                return .ok(["ok": true, "contribution": id,
                            "sequence": contribution.sequence])
            } catch { return .badRequest(error.localizedDescription) }
        }

        server.route("DELETE", "/v1/ui/contributions/") { [weak self] req in
            guard let self, let owner = req.pluginOwner else {
                return .badRequest("workspace contributions require a launched Extension")
            }
            if let denied = self.require(.panels, for: req) { return denied }
            let key = SDKWorkspaceKey(owner: owner, id: req.pathTail)
            guard self.sdkWorkspaceContributions.removeValue(forKey: key) != nil else {
                return .notFound("no such workspace contribution")
            }
            self.notifyWorkspaceContributionsChanged()
            return .ok(["ok": true])
        }

        // SDK launch batching avoids a burst of short TCP connections while
        // preserving the individual endpoints for dynamic/non-SDK clients.
        server.route("POST", "/v1/extensions/register") { [weak self] req in
            guard let self, req.pluginOwner != nil, let json = req.json else {
                return .badRequest("registration batches require a launched extension")
            }
            let commands = json["commands"] as? [[String: Any]] ?? []
            let hotkeys = json["hotkeys"] as? [[String: Any]] ?? []
            let hooks = json["hooks"] as? [[String: Any]] ?? []
            guard commands.count <= 256, hotkeys.count <= 64, hooks.count <= 64 else {
                return .tooManyRequests("registration batch exceeds Extension limits")
            }
            for command in commands {
                let response = self.registerSDKCommand(command, request: req)
                if response.status != 200 { return response }
            }
            for hotkey in hotkeys {
                let response = self.registerSDKHotKey(hotkey, request: req)
                if response.status != 200 { return response }
            }
            for hook in hooks {
                let response = self.registerSDKHook(hook, request: req)
                if response.status != 200 { return response }
            }
            return .ok(["ok": true, "commands": commands.count,
                        "hotkeys": hotkeys.count, "hooks": hooks.count])
        }

        // Register a palette/menu command; invocations arrive on /v1/events.
        server.route("POST", "/v1/commands") { [weak self] req in
            self?.registerSDKCommand(req.json, request: req)
                ?? .badRequest("shutting down")
        }

        // Register a global hotkey; presses arrive on /v1/events.
        server.route("POST", "/v1/hotkeys") { [weak self] req in
            self?.registerSDKHotKey(req.json, request: req)
                ?? .badRequest("shutting down")
        }

        // Decision hooks are deliberately small and bounded. Registration is
        // main-thread-owned; replies use a background route so they can wake a
        // boundary while the AppKit thread is waiting on its short deadline.
        server.route("POST", "/v1/hooks") { [weak self] req in
            self?.registerSDKHook(req.json, request: req)
                ?? .badRequest("shutting down")
        }

        server.route("DELETE", "/v1/hooks/") { [weak self] req in
            guard let self, let owner = req.pluginOwner else {
                return .badRequest("hooks require a launched extension")
            }
            if let denied = self.require(.hooks, for: req) { return denied }
            let id = req.pathTail
            let before = self.hooks.count
            self.hooks.removeAll { $0.owner == owner && $0.id == id }
            return before == self.hooks.count
                ? .notFound("no such hook") : .ok(["ok": true])
        }

        server.backgroundRoute("POST", "/v1/hook-responses/") { [weak self] req in
            guard let self, let owner = req.pluginOwner else {
                return .badRequest("hook responses require a launched extension")
            }
            if let denied = self.require(.hooks, for: req) { return denied }
            guard let raw = req.json?["decision"] as? String,
                  let action = ExtensionDecisionAction(rawValue: raw) else {
                return .badRequest("need {decision: continue|replace|cancel, value?, reason?}")
            }
            self.pendingHookLock.lock()
            let pending = self.pendingHooks[req.pathTail]
            self.pendingHookLock.unlock()
            guard let pending, pending.owner == owner else {
                return .notFound("hook request expired or belongs to another extension")
            }
            pending.resolve(ExtensionDecision(
                action, value: req.json?["value"] as? String,
                reason: req.json?["reason"] as? String))
            return .ok(["ok": true])
        }

        // The development controller is intentionally available only through
        // the user-owned discovery credential. An installed extension cannot
        // use its token to execute a second arbitrary program.
        server.route("POST", "/v1/extensions/dev") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            guard req.isDiscoveryClient else {
                return .forbidden("development sessions require the discovery credential")
            }
            guard let path = req.json?["path"] as? String else {
                return .badRequest("need {path, capabilities?}")
            }
            let capabilities: Set<ExtensionCapability>
            if let names = req.json?["capabilities"] as? [String] {
                let decoded = names.compactMap(ExtensionCapability.init(rawValue:))
                guard decoded.count == names.count else {
                    return .badRequest("capabilities contains an unknown value")
                }
                capabilities = Set(decoded)
            } else {
                capabilities = [.events, .panesRead, .commands, .panels,
                                .surfaces, .notifications]
            }
            do {
                let id = try self.startDevelopmentExtension(
                    at: URL(fileURLWithPath: path), capabilities: capabilities)
                return .ok(["ok": true, "session": id])
            } catch {
                return .badRequest(error.localizedDescription)
            }
        }

        server.route("GET", "/v1/extensions/dev/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            guard req.isDiscoveryClient else {
                return .forbidden("development sessions require the discovery credential")
            }
            let parts = req.pathTail.split(separator: "/")
            guard let id = parts.first.map(String.init), parts.count == 1 else {
                return .notFound("no such development session")
            }
            let after = req.json?["after"] as? Int ?? 0
            guard let status = self.developmentStatus(id: id, after: after) else {
                return .notFound("no such development session")
            }
            return .ok(status)
        }

        server.route("POST", "/v1/extensions/dev/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            guard req.isDiscoveryClient else {
                return .forbidden("development sessions require the discovery credential")
            }
            let parts = req.pathTail.split(separator: "/")
            guard parts.count == 2, parts[1] == "heartbeat",
                  self.heartbeatDevelopmentExtension(id: String(parts[0])) else {
                return .notFound("no such development session")
            }
            return .ok(["ok": true])
        }

        server.route("DELETE", "/v1/extensions/dev/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            guard req.isDiscoveryClient else {
                return .forbidden("development sessions require the discovery credential")
            }
            let id = req.pathTail
            guard self.developmentStatus(id: id) != nil else {
                return .notFound("no such development session")
            }
            self.stopDevelopmentExtension(id: id)
            return .ok(["ok": true])
        }

        server.route("POST", "/v1/extensions/reload") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            guard req.isDiscoveryClient else {
                return .forbidden("Extension reload requires the discovery credential")
            }
            guard let id = req.json?["id"] as? String else {
                return .badRequest("need {id}")
            }
            let directories = (try? FileManager.default.contentsOfDirectory(
                at: Self.extensionsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            guard let directory = directories.first(where: {
                (try? ExtensionManifest.load(from: $0).id) == id
            }) else { return .notFound("no installed Extension '\(id)'") }
            if self.isPluginRunning(at: directory) {
                return .ok(["ok": true, "running": true, "alreadyRunning": true])
            }
            guard self.launchPlugin(at: directory) else {
                return .badRequest("Extension is disabled or could not be launched")
            }
            return .ok(["ok": true, "running": true])
        }

        server.route("POST", "/v1/extensions/state") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            guard req.isDiscoveryClient else {
                return .forbidden("Extension lifecycle changes require the discovery credential")
            }
            guard let id = req.json?["id"] as? String,
                  let enabled = req.json?["enabled"] as? Bool else {
                return .badRequest("need {id, enabled}")
            }
            let directories = (try? FileManager.default.contentsOfDirectory(
                at: Self.extensionsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            guard let directory = directories.first(where: {
                (try? ExtensionManifest.load(from: $0).id) == id
            }) else { return .notFound("no installed Extension '\(id)'") }
            do {
                try self.setPluginEnabled(enabled, at: directory)
                return .ok(["ok": true, "enabled": enabled,
                            "running": self.isPluginRunning(at: directory)])
            } catch { return .badRequest(error.localizedDescription) }
        }

        // Install a marketplace entry — the agent-facing side of the
        // marketplace (MARKETPLACE.md). Plugins are native code, so they
        // demand {"consent": true}; without it the response says what to ask
        // the user. Long downloads run off-main; progress and the outcome
        // stream as {kind:"marketplace", event, id, message} events.
        server.backgroundRoute("POST", "/v1/marketplace/install") { [weak self] req in
            guard let self, let json = req.json, let id = json["id"] as? String else {
                return .badRequest("need {id, consent?}")
            }
            if let denied = self.require(.marketplace, for: req) { return denied }
            let registry = json["registry"] as? String
            let entries = marketplaceQueue.sync {
                (try? Marketplace.fetchEntries(registry: registry)) ?? []
            }
            guard let entry = entries.first(where: { $0.id == id }) else {
                return .notFound("no marketplace entry '\(id)'")
            }
            if Marketplace.isExtensionKind(entry.kind),
               json["consent"] as? Bool != true {
                return .ok(["ok": false, "needsConsent": true,
                            "message": "\(entry.name) by \(entry.author) is native code — ask the user, then repeat with {\"consent\": true}"])
            }
            let pluginsDirectory = PluginManager.pluginsDirectory
            marketplaceQueue.async { [weak self] in
                func report(_ event: String, _ message: String) {
                    DispatchQueue.main.async {
                        self?.emit("marketplace", ["event": event, "id": id, "message": message],
                                   toOwner: req.pluginOwner)
                    }
                }
                do {
                    switch entry.kind {
                    case "shader":
                        let data = try Marketplace.fetchContent(entry, registry: registry)
                        let name = try Marketplace.installShader(entry, source: String(decoding: data, as: UTF8.self))
                        report("installed", "shader = \(name)")
                    case "theme":
                        let data = try Marketplace.fetchContent(entry, registry: registry)
                        // Theme's registry is shared with AppKit menu/render code.
                        let name = try DispatchQueue.main.sync {
                            try Marketplace.installTheme(entry, json: data)
                        }
                        report("installed", "theme = \(name)")
                    case "rig":
                        let data = try Marketplace.fetchContent(entry, registry: registry)
                        DispatchQueue.main.sync {
                            Marketplace.applyRig(String(decoding: data, as: UTF8.self))
                        }
                        report("installed", "rig applied")
                    case "plugin", "channel":
                        let dest = pluginsDirectory.appendingPathComponent(entry.folderName)
                        DispatchQueue.main.sync { self?.stopPlugin(at: dest) }
                        let dir = try Marketplace.installPlugin(entry, registry: registry, consented: true) {
                            report("progress", $0)
                        }
                        DispatchQueue.main.sync { _ = self?.launchPlugin(at: dir) }
                        report("installed", "running")
                    default:
                        report("failed", "cannot install kind '\(entry.kind)'")
                    }
                } catch {
                    if Marketplace.isExtensionKind(entry.kind) {
                        let dest = pluginsDirectory.appendingPathComponent(entry.folderName)
                        DispatchQueue.main.sync { _ = self?.launchPlugin(at: dest) }
                    }
                    report("failed", error.localizedDescription)
                }
            }
            return .ok(["ok": true, "started": true, "id": id,
                        "note": "outcome arrives on /v1/events as kind=marketplace"])
        }

        // Reserve a right-edge strip for a plugin's docked companion window:
        // panes reflow so text never runs behind it. {right: points, window:
        // WindowServerID} targets one Cmdy window; omitting `window` keeps
        // the legacy app-wide behavior. 0 releases the strip.
        server.route("POST", "/v1/ui/inset") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.companion, for: req) { return denied }
            let right = (req.json?["right"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
            let minHeight = (req.json?["minHeight"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
            let windowNumber = (req.json?["window"] as? NSNumber)?.intValue
            let geometry = self.setDockReservation(
                owner: req.pluginOwner,
                right: max(0, min(4000, right)),
                minHeight: max(0, min(4000, minHeight)),
                windowNumber: windowNumber)
            return .ok(["ok": true].merging(geometry) { a, _ in a })
        }

        // Semantic feedback from a live Extension surface. The Extension owns
        // the durable queue exposed by its MCP server; the host's job is only
        // to route the note to the correct terminal pane without ever feeding
        // natural language to a shell.
        server.route("POST", "/v1/ui/feedback") { [weak self] req in
            guard let self, let payload = req.json else {
                return .badRequest("feedback must be a JSON object")
            }
            if let denied = self.require(.panesType, for: req) { return denied }
            guard let source = payload["source"] as? String, !source.isEmpty,
                  let comment = payload["comment"] as? String,
                  !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .badRequest("feedback needs non-empty source and comment")
            }
            guard comment.utf8.count <= 8_000,
                  let encoded = try? JSONSerialization.data(withJSONObject: payload),
                  encoded.count <= 128_000 else {
                return .badRequest("feedback is too large")
            }

            let requestedWindow = (payload["window"] as? NSNumber)?.intValue
            let windowPanes = requestedWindow.map { number in
                self.panes.filter { $0.windowNumber == number }
            } ?? []
            let requestedPaneID = payload["pane"] as? String
            let explicitPane = requestedPaneID.flatMap { id in
                self.pane(withID: id)
            }
            let controlBarPane = self.sdkControlBars.values.lazy.compactMap { record -> PluginPane? in
                guard record.owner == req.pluginOwner,
                      let targetID = record.host?.extensionControlBarTargetID,
                      let candidate = self.pane(withID: targetID),
                      requestedWindow == nil || candidate.windowNumber == requestedWindow else {
                    return nil
                }
                return candidate
            }.first
            let focused = self.focusedPane
            let pane = explicitPane
                ?? controlBarPane
                ?? windowPanes.first(where: { $0.aiTool != nil })
                ?? focused.flatMap { candidate in
                    requestedWindow == nil || candidate.windowNumber == requestedWindow
                        ? candidate : nil
                }
                ?? windowPanes.first
            guard let pane else { return .badRequest("no paired terminal pane") }

            let id = payload["id"] as? String ?? "unknown"
            let context = payload["context"] as? [String: Any] ?? [:]
            let normalizedComment = comment
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            func firstString(_ keys: [String]) -> String? {
                for key in keys {
                    if let value = context[key] as? String, !value.isEmpty { return value }
                    if let value = payload[key] as? String, !value.isEmpty { return value }
                }
                return nil
            }
            let mcp: String
            switch source {
            case "sim":
                mcp = ProductIdentity.current.mcpServerName("sim")
            case "bridge":
                mcp = ProductIdentity.current.mcpServerName("bridge")
            default:
                mcp = ProductIdentity.current.mcpServerName("browser")
            }
            var lines = [
                "A \(ProductIdentity.current.titleName) UI feedback queue item "
                    + "was added in \(source).",
                "Treat this and other \(ProductIdentity.current.titleName) "
                    + "feedback items cumulatively in arrival order; "
                    + "do not replace earlier items.",
                "Feedback: \(normalizedComment)",
            ]
            if let element = firstString(["element", "role", "tag"]) {
                lines.append("Element: \(element)")
            }
            if let label = firstString(["label", "text", "title"]) {
                lines.append("Label: \(label)")
            }
            if let path = firstString(["selector", "elementPath", "path"]) {
                lines.append("Selector/path: \(path)")
            }
            if let url = firstString(["url"]) { lines.append("URL: \(url)") }
            lines += [
                "Feedback id: \(id)",
                "Use the \(mcp) MCP get_feedback tool for full structured context, then resolve_feedback when the work is complete.",
            ]
            // Keep each note atomic, but do not submit it automatically. One
            // note is staged in the agent input while later notes wait in the
            // per-pane steering queue. Each real Return advances one item.
            let prompt = lines.joined(separator: " ")
            if let aiTool = pane.aiTool {
                pane.focus()
                let receipt = self.enqueueFeedbackSteering(
                    id: id, prompt: prompt, in: pane)
                return .ok([
                    "ok": true, "id": id, "delivery": receipt.delivery,
                    "agent": aiTool, "pane": pane.id,
                    "position": receipt.position, "queueDepth": receipt.depth,
                ])
            }

            let notice = "\r\n\u{1b}[2m\(ProductIdentity.current.titleName) \(source) feedback \(id): \(normalizedComment)\r\nNo agent is attached; use \(mcp) get_feedback when one starts.\u{1b}[0m\r\n"
            pane.feed(notice)
            pane.focus()
            return .ok(["ok": true, "id": id, "delivery": "queue", "pane": pane.id])
        }

        // Freeze a companion (or the current display), let the user drag one
        // or more highlighted regions, then type the resulting PNG path at
        // the originating prompt. Return attaches; Cmd+Z undoes; Esc cancels.
        server.route("POST", "/v1/ui/annotate") { [weak self] req in
            guard let self, let pane = self.focusedPane else {
                return .badRequest("a focused pane is required")
            }
            if let denied = self.require(.panesType, for: req) { return denied }
            let requested = (req.json?["window"] as? NSNumber).map { CGWindowID($0.uint32Value) }
            let number = requested ?? (pane.windowNumber > 0 ? CGWindowID(pane.windowNumber) : nil)
            DispatchQueue.main.async {
                AnnotationOverlay.shared.present(windowNumber: number) { path in
                    guard let path else { return }
                    pane.type("'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' ")
                }
            }
            return .ok(["ok": true, "state": "annotating"])
        }

        server.route("POST", "/v1/ui/agent-attach") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            let requestedWindow = (req.json?["window"] as? NSNumber)?.intValue
            guard let host = self.panelPaneForWindowProvider(requestedWindow)
                    ?? (requestedWindow == nil ? self.panelPaneProvider() : nil) else {
                return .badRequest("a focused pane is required")
            }
            if let denied = self.require(.panesType, for: req) { return denied }

            func resolvePane() -> PluginPane? {
                let windowPanes = requestedWindow.map { number in
                    self.panes.filter { $0.windowNumber == number }
                } ?? []
                let focused = self.focusedPane
                return windowPanes.first(where: { $0.aiTool != nil })
                    ?? focused.flatMap { candidate in
                        requestedWindow == nil || candidate.windowNumber == requestedWindow
                            ? candidate : nil
                    }
                    ?? windowPanes.first
            }

            guard let initialPane = resolvePane() else {
                return .badRequest("a focused pane is required")
            }
            let sourceExtensionID = req.pluginID

            func offerChooser(_ pane: PluginPane) {
                let panel = host.presentInlinePanel(takeFocus: true)
                panel.configureMenu(
                    title: "Work with:",
                    items: [
                        BottomMenuItem(id: "pi", title: "Pi", shortcut: "1"),
                        BottomMenuItem(id: "codex", title: "Codex", shortcut: "2"),
                        BottomMenuItem(id: "claude", title: "Claude", shortcut: "3"),
                        BottomMenuItem(id: "other", title: "Other", shortcut: "4"),
                    ],
                    hint: "←/→ choose · return select · ↑/esc skip")
                panel.onMenuAction = { choice in
                    if choice == "other" {
                        DispatchQueue.main.async {
                            let input = host.presentInlinePanel(takeFocus: true)
                            input.configureInput(placeholder: "agent command…",
                                                 hint: "return checks setup, then launches · esc cancels")
                            input.onSubmit = { value in
                                input.dismiss()
                                let firstWord = value.split(whereSeparator: \.isWhitespace)
                                    .first.map(String.init) ?? value
                                let name = (firstWord as NSString).lastPathComponent
                                self.agentLaunchPreflight(
                                    value, name, sourceExtensionID, pane, host, false)
                            }
                        }
                        return
                    }
                    let agent: (command: String, name: String)
                    switch choice {
                    case "pi": agent = ("pi", "Pi")
                    case "codex": agent = ("codex", "Codex")
                    case "claude": agent = ("claude", "Claude")
                    default: return
                    }
                    self.agentLaunchPreflight(
                        agent.command, agent.name, sourceExtensionID, pane, host, false)
                }
            }

            // Process discovery is asynchronous. If an agent is already
            // running, use it and preflight that exact client instead of
            // offering to start a second one. A short first-use retry lets the
            // tty scan populate without blocking the local HTTP route.
            if let running = initialPane.aiTool {
                self.agentLaunchPreflight(
                    running, running.capitalized, sourceExtensionID,
                    initialPane, host, true)
                return .ok(["ok": true, "state": "attached", "agent": running])
            }
            let paneID = initialPane.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let refreshed = self.pane(withID: paneID) ?? resolvePane()
                guard let pane = refreshed else { return }
                if let running = pane.aiTool {
                    self.agentLaunchPreflight(
                        running, running.capitalized, sourceExtensionID,
                        pane, host, true)
                } else {
                    offerChooser(pane)
                }
            }
            return .ok(["ok": true, "state": "checking"])
        }

        // Surface Protocol v1: durable, sequenced documents rendered entirely
        // by Cmdy. stdout remains in the terminal buffer as the canonical
        // fallback; this channel carries only bounded structured state.
        server.route("POST", "/v1/surfaces") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.surfaces, for: req) { return denied }
            let document: SurfaceDocument
            do { document = try SurfaceDocument.decode(req.body) }
            catch { return .badRequest(error.localizedDescription) }

            guard let host = self.surfaceHostProvider(document.pane) else {
                return .badRequest("surface pane is unavailable")
            }
            guard let block = host.resolveSurfaceBlock(document.block) else {
                return .badRequest("surface needs a current, last, or existing command block")
            }
            let key = SDKSurfaceKey(owner: req.pluginOwner, id: document.id)
            let isNew = self.sdkSurfaces[key] == nil
            guard !isNew || self.sdkSurfaces.keys.lazy.filter({ $0.owner == req.pluginOwner }).count < 64 else {
                return .tooManyRequests("an Extension may own at most 64 Surfaces")
            }
            if let existing = self.sdkSurfaces.removeValue(forKey: key) {
                if let view = existing.view { existing.host?.dismissExtensionSurface(view) }
            }
            var attached = document
            attached.pane = host.extensionSurfacePaneID
            attached.block = block
            let view = host.presentExtensionSurface(attached)
            let record = SDKSurfaceRecord(document: attached, owner: req.pluginOwner,
                                          extensionID: req.pluginID,
                                          host: host, view: view)
            self.sdkSurfaces[key] = record
            self.wireSurfaceCallbacks(record)
            return .ok([
                "ok": true, "surface": attached.id,
                "pane": host.extensionSurfacePaneID, "block": block,
                "sequence": attached.sequence,
            ])
        }

        server.route("GET", "/v1/surfaces") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.surfaces, for: req) { return denied }
            let records = self.sdkSurfaces.filter {
                req.isDiscoveryClient || $0.key.owner == req.pluginOwner
            }.sorted {
                ($0.value.extensionID ?? "", $0.key.id)
                    < ($1.value.extensionID ?? "", $1.key.id)
            }
            let objects: [Any] = records.compactMap { _, record in
                guard let data = try? record.document.encoded(),
                      var object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { return nil }
                if req.isDiscoveryClient {
                    object["extension"] = record.extensionID ?? "user"
                }
                return object
            }
            return .ok(["surfaces": objects])
        }

        server.route("PATCH", "/v1/surfaces/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            let key = SDKSurfaceKey(owner: req.pluginOwner, id: req.pathTail)
            guard let record = self.sdkSurfaces[key] else {
                return .notFound("no such surface")
            }
            if let denied = self.require(.surfaces, for: req) { return denied }
            let now = Date()
            record.patchTimes.removeAll { now.timeIntervalSince($0) > 1 }
            guard record.patchTimes.count < 120 else {
                return .tooManyRequests("surface update budget is 120 patches per second")
            }
            let patch: SurfacePatch
            do { patch = try JSONDecoder().decode(SurfacePatch.self, from: req.body) }
            catch { return .badRequest("invalid surface patch: \(error.localizedDescription)") }
            do { try record.document.apply(patch) }
            catch let error as SurfaceProtocolError {
                if case .sequence = error { return .conflict(error.localizedDescription) }
                return .badRequest(error.localizedDescription)
            } catch { return .badRequest(error.localizedDescription) }
            record.patchTimes.append(now)
            if let view = record.view { view.update(record.document) }
            else if let host = record.host {
                record.view = host.presentExtensionSurface(record.document)
                self.wireSurfaceCallbacks(record)
            }
            return .ok(["ok": true, "sequence": record.document.sequence])
        }

        server.route("POST", "/v1/surfaces/") { [weak self] req in
            let parts = req.pathTail.split(separator: "/")
            guard let self, parts.count == 2, parts[1] == "show" else {
                return .notFound("no such surface operation")
            }
            if let denied = self.require(.surfaces, for: req) { return denied }
            let key = SDKSurfaceKey(owner: req.pluginOwner, id: String(parts[0]))
            guard let record = self.sdkSurfaces[key] else { return .notFound("no such surface") }
            guard let host = record.host else { return .notFound("surface pane has closed") }
            record.view = host.presentExtensionSurface(record.document)
            self.wireSurfaceCallbacks(record)
            return .ok(["ok": true, "surface": record.document.id])
        }

        server.route("DELETE", "/v1/surfaces/") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            let key = SDKSurfaceKey(owner: req.pluginOwner, id: req.pathTail)
            guard self.sdkSurfaces[key] != nil else {
                return .notFound("no such surface")
            }
            if let denied = self.require(.surfaces, for: req) { return denied }
            self.removeSurface(key: key, notifyOwner: false)
            return .ok(["ok": true])
        }

        // Keep one Extension-owned command row below the PTY. It coexists
        // with normal shell input and yields temporarily to palettes/Surfaces.
        server.route("POST", "/v1/control-bars") { [weak self] req in
            guard let self, let json = req.json else {
                return .badRequest("need {id, actions, placeholder, value}")
            }
            if let denied = self.require(.panels, for: req) { return denied }
            let id = json["id"] as? String ?? UUID().uuidString
            guard Self.isValidResourceID(id) else {
                return .badRequest("control bar id must be 1-128 ASCII letters, numbers, '.', '-', or '_'")
            }
            let rawActions = json["actions"] as? [[String: Any]] ?? []
            guard rawActions.count <= 12 else {
                return .badRequest("a control bar supports at most 12 actions")
            }
            let actions = rawActions.compactMap { raw -> ExtensionControlBarAction? in
                guard let actionID = raw["id"] as? String,
                      let title = raw["title"] as? String,
                      Self.isValidResourceID(actionID), title.utf8.count <= 128 else { return nil }
                return ExtensionControlBarAction(
                    id: actionID, title: title,
                    isEnabled: raw["enabled"] as? Bool ?? true)
            }
            guard actions.count == rawActions.count else {
                return .badRequest("invalid control bar action")
            }
            let placeholder = json["placeholder"] as? String ?? ""
            let value = json["value"] as? String ?? ""
            let inputFirst = json["inputFirst"] as? Bool ?? false
            guard placeholder.utf8.count <= 512, value.utf8.count <= 16_384 else {
                return .badRequest("control bar text exceeds its resource budget")
            }
            let windowNumber = (json["window"] as? NSNumber)?.intValue
            guard let host = self.controlBarHostProvider(windowNumber) else {
                return .badRequest("the target terminal window is unavailable")
            }
            let key = SDKControlBarKey(owner: req.pluginOwner, id: id)
            if let old = self.sdkControlBars[key], let oldBar = old.bar,
               old.host !== host {
                old.host?.dismissExtensionControlBar(oldBar)
                self.sdkControlBars[key] = nil
            }
            let bar = host.presentExtensionControlBar()
            // A pane exposes one persistent row. If another Extension owned
            // that exact view, retire the stale record before reconfiguring it.
            let displaced = self.sdkControlBars.compactMap { existingKey, record in
                existingKey != key && record.bar === bar ? existingKey : nil
            }
            displaced.forEach { self.sdkControlBars[$0] = nil }
            bar.configure(
                actions: actions, placeholder: placeholder, value: value,
                inputFirst: inputFirst)
            bar.onAction = { [weak self] action in
                self?.emit("ui", ["controlBar": id, "event": "action", "value": action],
                           toOwner: req.pluginOwner)
            }
            bar.onSubmit = { [weak self] text in
                self?.emit("ui", ["controlBar": id, "event": "submit", "value": text],
                           toOwner: req.pluginOwner)
            }
            self.sdkControlBars[key] = SDKControlBarRecord(
                owner: req.pluginOwner, host: host, bar: bar,
                actions: actions, placeholder: placeholder)
            if json["focus"] as? Bool == true { host.focusExtensionControlBar(bar) }
            return .ok([
                "ok": true, "controlBar": id,
                "pane": host.extensionControlBarTargetID,
            ])
        }

        server.route("POST", "/v1/control-bars/") { [weak self] req in
            let parts = req.pathTail.split(separator: "/")
            guard let self, parts.count == 2 else {
                return .notFound("no such control bar operation")
            }
            if let denied = self.require(.panels, for: req) { return denied }
            let key = SDKControlBarKey(owner: req.pluginOwner, id: String(parts[0]))
            guard let record = self.sdkControlBars[key], let bar = record.bar else {
                return .notFound("no such control bar")
            }
            switch String(parts[1]) {
            case "update":
                let json = req.json ?? [:]
                if let value = json["value"] as? String {
                    guard value.utf8.count <= 16_384 else {
                        return .badRequest("control bar value exceeds 16 KB")
                    }
                    bar.setValue(value)
                }
                if let placeholder = json["placeholder"] as? String {
                    guard placeholder.utf8.count <= 512 else {
                        return .badRequest("control bar placeholder exceeds 512 bytes")
                    }
                    record.placeholder = placeholder
                    bar.setPlaceholder(placeholder)
                }
                if json["focus"] as? Bool == true {
                    record.host?.focusExtensionControlBar(bar)
                }
                return .ok(["ok": true])
            case "dismiss":
                self.sdkControlBars[key] = nil
                record.host?.dismissExtensionControlBar(bar)
                return .ok(["ok": true])
            default:
                return .notFound("unknown control bar operation")
            }
        }

        // Drive cmdy's inline panel from outside: list / input / text /
        // editor, docked in the focused pane. Interactions stream back as
        // {kind:"ui", panel, event, value} events.
        server.route("POST", "/v1/ui/panel") { [weak self] req in
            guard let self, let json = req.json,
                  let mode = json["mode"] as? String else {
                return .badRequest("need {mode: list|input|text|editor}")
            }
            if let denied = self.require(.panels, for: req) { return denied }
            let requestedWindow = (json["window"] as? NSNumber)?.intValue
            guard let pane = self.panelPaneForWindowProvider(requestedWindow)
                    ?? (requestedWindow == nil
                        ? self.panelPaneProvider() : nil) else {
                return .badRequest("a focused pane is required")
            }
            guard ["list", "input", "text", "editor"].contains(mode) else {
                return .badRequest("unknown mode \(mode)")
            }
            guard self.sdkPanels.values.lazy.filter({ $0.owner == req.pluginOwner }).count < 16 else {
                return .tooManyRequests("an Extension may own at most 16 panels")
            }
            let title = json["title"] as? String ?? ""
            let body = json["body"] as? String ?? ""
            let hint = json["hint"] as? String ?? ""
            let placeholder = json["placeholder"] as? String ?? ""
            let items = json["items"] as? [[String: Any]] ?? []
            guard title.utf8.count <= 512, body.utf8.count <= 2_000_000,
                  hint.utf8.count <= 4_096, placeholder.utf8.count <= 512,
                  items.count <= 2_000 else {
                return .badRequest("panel content exceeds its resource budget")
            }
            guard items.allSatisfy({
                ($0["id"] as? String ?? "").utf8.count <= 128
                    && ($0["title"] as? String ?? "").utf8.count <= 512
                    && ($0["subtitle"] as? String ?? "").utf8.count <= 1_024
            }) else { return .badRequest("panel item exceeds its resource budget") }
            let panelId = UUID().uuidString
            let panel = pane.presentInlinePanel(takeFocus: true)
            switch mode {
            case "list":
                let items = items.map { raw -> PaletteItem in
                    let itemId = raw["id"] as? String ?? UUID().uuidString
                    return PaletteItem(title: raw["title"] as? String ?? "?",
                                       subtitle: raw["subtitle"] as? String ?? "",
                                       action: { [weak self] in
                                           self?.emit("ui", ["panel": panelId, "event": "pick", "value": itemId],
                                                      toOwner: req.pluginOwner)
                                       })
                }
                panel.configureList(items: items,
                                    placeholder: json["placeholder"] as? String ?? "filter…",
                                    hint: hint)
            case "input":
                panel.configureInput(placeholder: placeholder, hint: hint)
                panel.onSubmit = { [weak self] text in
                    self?.emit("ui", ["panel": panelId, "event": "submit", "value": text],
                               toOwner: req.pluginOwner)
                }
            case "text":
                panel.configureText(title: title, body: body, hint: hint)
            case "editor":
                panel.configureEditor(title: title, body: body, hint: hint)
                panel.onEvaluate = { [weak self] text in
                    self?.emit("ui", ["panel": panelId, "event": "evaluate", "value": text],
                               toOwner: req.pluginOwner)
                }
                // Debounced keystroke-level sync, so external plugins can
                // autosave the buffer without waiting for ⌘⏎.
                var pendingChange: DispatchWorkItem?
                panel.onBufferChanged = { [weak self] (text: String) in
                    guard text.utf8.count <= 2_000_000 else { return }
                    pendingChange?.cancel()
                    let work = DispatchWorkItem {
                        self?.emit("ui", ["panel": panelId, "event": "changed", "value": text],
                                   toOwner: req.pluginOwner)
                    }
                    pendingChange = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                }
            default: break
            }
            let previousDismiss = panel.onDismiss
            panel.onDismiss = { [weak self] in
                self?.emit("ui", ["panel": panelId, "event": "dismissed"],
                           toOwner: req.pluginOwner)
                self?.sdkPanels[panelId] = nil
                previousDismiss?()
            }
            self.sdkPanels[panelId] = SDKPanelRecord(
                panel: panel, owner: req.pluginOwner, textBytes: body.utf8.count)
            return .ok(["ok": true, "panel": panelId])
        }

        // Update or dismiss an SDK panel: /v1/ui/<panelId>/{update|dismiss}
        server.route("POST", "/v1/ui/") { [weak self] req in
            let parts = req.pathTail.split(separator: "/")
            guard let self, parts.count == 2,
                  let record = self.sdkPanels[String(parts[0])] else {
                return .notFound("no such panel")
            }
            if let denied = self.require(.panels, for: req) { return denied }
            if let caller = req.pluginOwner, record.owner != caller {
                return .notFound("no such panel")
            }
            let panel = record.panel
            switch String(parts[1]) {
            case "update":
                let body = req.json?["body"] as? String
                let line = req.json?["appendLine"] as? String
                let hint = req.json?["hint"] as? String
                let nextBytes = (body?.utf8.count ?? record.textBytes)
                    + (line.map { $0.utf8.count + 1 } ?? 0)
                guard nextBytes <= 2_000_000 else {
                    return .tooManyRequests("panel body exceeds 2 MB")
                }
                guard (hint?.utf8.count ?? 0) <= 4_096 else {
                    return .badRequest("panel hint exceeds 4096 bytes")
                }
                if let body { panel.setBody(body) }
                if let line { panel.appendLine(line) }
                if let hint { panel.setHint(hint) }
                record.textBytes = nextBytes
                return .ok(["ok": true])
            case "dismiss":
                panel.dismiss()
                return .ok(["ok": true])
            default:
                return .notFound("unknown op")
            }
        }
    }

    private func registerCoreRoutes() {
        // Self-describing API index — a plugin author's first stop.
        server.route("GET", "/v1") { [weak self] request in
            let endpoints: [[String: Any]] = [
                ["method": "GET", "path": "/health", "about": "unauthenticated process health check"],
                ["method": "GET", "path": "/v1", "about": "this self-describing API index"],
                ["method": "GET", "path": "/v1/theme", "about": "current native theme colors"],
                ["method": "GET", "path": "/v1/panes", "about": "every pane: id, title, cwd, pid, tty, ai"],
                ["method": "GET", "path": "/v1/actions", "about": "discovery credential: Actions available in the focused context"],
                ["method": "POST", "path": "/v1/actions/run", "body": ["id": "…", "inputs": [String: String]()], "about": "discovery credential: run a reviewed Action in terminal panes"],
                ["method": "POST", "path": "/v1/channels", "about": "channels capability: register or reconnect an owned Channel"],
                ["method": "GET", "path": "/v1/channels", "about": "list visible Channel connections"],
                ["method": "POST", "path": "/v1/channels/<id>/work-items", "about": "channels capability: idempotently ingest external work"],
                ["method": "GET", "path": "/v1/channel-work-items", "about": "list the durable Work Inbox"],
                ["method": "PATCH", "path": "/v1/channel-work-items/<channel>/<item>", "about": "update Work Item status"],
                ["method": "POST", "path": "/v1/channel-work-items/<channel>/<item>/replies", "about": "discovery credential: draft or explicitly queue a reply"],
                ["method": "GET", "path": "/v1/channel-replies", "about": "connectors see only queued, host-approved replies"],
                ["method": "DELETE", "path": "/v1/channel-replies/<id>", "about": "discovery credential: discard a private draft or completed record"],
                ["method": "POST", "path": "/v1/channel-replies/<id>/send", "about": "discovery credential: queue a draft or retry a failed reply"],
                ["method": "POST", "path": "/v1/channel-replies/<id>/ack", "about": "channels capability: acknowledge provider delivery"],
                ["method": "POST", "path": "/v1/panes/<id>/type", "body": ["text": "…"], "about": "type at the prompt, never runs"],
                ["method": "POST", "path": "/v1/panes/<id>/run", "body": ["command": "…"], "about": "type + Enter"],
                ["method": "POST", "path": "/v1/panes/<id>/focus", "about": "bring the pane forward"],
                ["method": "POST", "path": "/v1/panes/<id>/split", "body": ["direction": "right|down"], "about": "split the pane; returns the new pane id"],
                ["method": "POST", "path": "/v1/panes/<id>/close", "about": "close the pane"],
                ["method": "POST", "path": "/v1/windows/compose", "body": ["panes": ["…"]], "about": "gather selected live panes into one new window"],
                ["method": "POST", "path": "/v1/panes/<id>/scroll", "body": ["lines": 0], "about": "scroll by logical lines"],
                ["method": "POST", "path": "/v1/panes/<id>/feed", "body": ["text": "…"], "about": "display-only VT input"],
                ["method": "GET", "path": "/v1/panes/<id>/output", "about": "recent scrollback as text"],
                ["method": "GET", "path": "/v1/panes/<id>/scrollinfo", "about": "current scroll position and limits"],
                ["method": "POST", "path": "/v1/notify", "body": ["title": "…", "body": "…"], "about": "banner + dock bounce"],
                ["method": "GET", "path": "/v1/events", "about": "SSE stream: semantic events and private callbacks"],
                ["method": "POST", "path": "/v1/extensions/register", "about": "batch startup commands, hotkeys, and hooks"],
                ["method": "POST", "path": "/v1/commands", "body": ["id": "…", "title": "…"], "about": "register a palette command"],
                ["method": "POST", "path": "/v1/hotkeys", "body": ["id": "…", "keyCode": 0, "modifiers": 0], "about": "register a global hotkey"],
                ["method": "POST", "path": "/v1/ui/panel", "body": ["mode": "list|input|text|editor"], "about": "draw a transient native panel"],
                ["method": "POST", "path": "/v1/ui/<panel>/update", "about": "update an owned panel"],
                ["method": "POST", "path": "/v1/ui/<panel>/dismiss", "about": "close an owned panel"],
                ["method": "POST", "path": "/v1/control-bars", "about": "attach a persistent Extension command row"],
                ["method": "POST", "path": "/v1/control-bars/<id>/update", "about": "update or focus an owned command row"],
                ["method": "POST", "path": "/v1/control-bars/<id>/dismiss", "about": "remove an owned command row"],
                ["method": "POST", "path": "/v1/ui/contributions", "about": "add a declarative Navigator or Inspector section"],
                ["method": "POST", "path": "/v1/ui/contributions/<id>/update", "about": "replace fields or items in an owned section"],
                ["method": "DELETE", "path": "/v1/ui/contributions/<id>", "about": "remove an owned Adaptive Frame section"],
                ["method": "POST", "path": "/v1/ui/inset", "body": ["right": 0, "window": 0], "about": "reserve an edge for a companion app"],
                ["method": "POST", "path": "/v1/ui/feedback", "body": ["source": "browser", "comment": "…", "context": [:]], "about": "route structured UI feedback to the paired agent"],
                ["method": "POST", "path": "/v1/ui/annotate", "body": ["window": 0], "about": "annotate a companion screenshot and attach its PNG path"],
                ["method": "POST", "path": "/v1/ui/agent-attach", "about": "offer Pi, Codex, Claude, another agent, or skip"],
                ["method": "POST", "path": "/v1/surfaces", "about": "attach a bounded native Surface Protocol v1 document"],
                ["method": "GET", "path": "/v1/surfaces", "about": "list owned Surface documents"],
                ["method": "PATCH", "path": "/v1/surfaces/<id>", "about": "apply the next sequenced Surface patch"],
                ["method": "POST", "path": "/v1/surfaces/<id>/show", "about": "show an owned Surface again"],
                ["method": "DELETE", "path": "/v1/surfaces/<id>", "about": "dismiss an owned Surface"],
                ["method": "POST", "path": "/v1/hooks", "about": "register a bounded decision hook"],
                ["method": "POST", "path": "/v1/hook-responses/<request>", "about": "answer a private hook request"],
                ["method": "POST", "path": "/v1/extensions/reload", "about": "discovery credential: launch a newly installed Extension"],
                ["method": "POST", "path": "/v1/extensions/state", "about": "discovery credential: enable or disable an installed Extension"],
                ["method": "POST", "path": "/v1/marketplace/install", "body": ["id": "…", "consent": false], "about": "install a marketplace entry"],
            ]
            let identity: [String: Any] = [
                "id": request.pluginID ?? NSNull(),
                "name": request.pluginName ?? NSNull(),
                "discovery": request.isDiscoveryClient,
                "capabilities": request.extensionCapabilities?.map(\.rawValue).sorted()
                    ?? ExtensionCapability.allCases.map(\.rawValue).sorted(),
            ]
            let response: [String: Any] = [
                "app": ProductIdentity.current.slug,
                "api": "v1",
                "port": self?.serverPort ?? 0,
                "docs": "https://github.com/"
                    + "\(ProductIdentity.current.githubRepository)"
                    + "/blob/main/EXTENSIONS.md",
                "endpoints": endpoints,
                "auth": "Authorization: Bearer <token> — token in "
                    + "\(ProductIdentity.current.environmentKey("TOKEN")) or "
                    + "~/.config/\(ProductIdentity.current.configurationDirectoryName)"
                    + "/extension-api.json",
                "identity": identity,
            ]
            return .ok(response)
        }
        server.route("GET", "/v1/theme") { [weak self] _ in
            .ok(self?.themePayload() ?? [:])
        }
        server.route("GET", "/v1/actions") { [weak self] request in
            guard request.isDiscoveryClient else {
                return .forbidden("Actions require the discovery credential")
            }
            return .ok(["actions": self?.actionsProvider() ?? []])
        }
        server.route("POST", "/v1/actions/run") { [weak self] request in
            guard request.isDiscoveryClient else {
                return .forbidden("Actions require the discovery credential")
            }
            guard let id = request.json?["id"] as? String,
                  Self.isValidResourceID(id) else {
                return .badRequest("missing or invalid Action id")
            }
            let rawInputs = request.json?["inputs"] as? [String: Any] ?? [:]
            guard rawInputs.count <= 32 else {
                return .badRequest("an Action accepts at most 32 inputs")
            }
            var inputs: [String: String] = [:]
            for (key, value) in rawInputs {
                guard Self.isValidResourceID(key), let text = value as? String,
                      text.utf8.count <= 16 * 1024 else {
                    return .badRequest("Action inputs must be bounded strings")
                }
                inputs[key] = text
            }
            do {
                return .ok(try self?.runActionProvider(id, inputs)
                    ?? ["ok": false, "error": "shutting down"])
            } catch {
                return .badRequest(error.localizedDescription)
            }
        }
        server.route("GET", "/v1/panes") { [weak self] request in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.panesRead, for: request) { return denied }
            let focusedId = self.focusedPane?.id
            let list = self.panes.map { p -> [String: Any] in
                var d: [String: Any] = ["id": p.id, "title": p.title, "pid": p.pid,
                                        "focused": p.id == focusedId,
                                        "windowIndex": p.windowIndex, "paneIndex": p.paneIndex,
                                        "windowNumber": p.windowNumber]
                if let cwd = p.cwd { d["cwd"] = cwd }
                if let tty = p.tty { d["tty"] = tty }
                if let ai = p.aiTool { d["ai"] = ai }
                if let w = p.windowTitle { d["window"] = w }
                if p.attention { d["attention"] = true }
                if let block = p.currentBlockID { d["block"] = block }
                return d
            }
            return .ok(["panes": list])
        }
        server.route("POST", "/v1/windows/compose") { [weak self] request in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.panesManage, for: request) { return denied }
            guard let paneIDs = request.json?["panes"] as? [String],
                  (2...64).contains(paneIDs.count),
                  Set(paneIDs).count == paneIDs.count,
                  paneIDs.allSatisfy(Self.isValidResourceID) else {
                return .badRequest("panes must contain 2 to 64 unique pane ids")
            }
            do { return .ok(try self.composePanesProvider(paneIDs)) }
            catch { return .badRequest(error.localizedDescription) }
        }
        server.route("POST", "/v1/panes/") { [weak self] req in
            // /v1/panes/<id>/<action>
            let parts = req.pathTail.split(separator: "/")
            guard parts.count == 2 else { return .badRequest("expected /v1/panes/<id>/<action>") }
            guard let pane = self?.pane(withID: String(parts[0])) else {
                return .notFound("no pane \(parts[0])")
            }
            let action = String(parts[1])
            let capability: ExtensionCapability = ["type", "run", "feed"].contains(action)
                ? .panesType : .panesManage
            if let self, let denied = self.require(capability, for: req) { return denied }
            switch action {
            case "type":
                guard let text = req.json?["text"] as? String else { return .badRequest("missing 'text'") }
                pane.type(text)
                return .ok(["ok": true])
            case "run":
                guard let cmd = req.json?["command"] as? String else { return .badRequest("missing 'command'") }
                pane.run(cmd)
                return .ok(["ok": true])
            case "focus":
                pane.focus()
                return .ok(["ok": true])
            case "scroll":
                guard let lines = req.json?["lines"] as? Int else { return .badRequest("missing 'lines'") }
                pane.scrollBy(lines)
                return .ok(["ok": true, "state": pane.scrollInfo()])
            case "feed":
                guard let text = req.json?["text"] as? String else { return .badRequest("missing 'text'") }
                pane.feed(text)
                return .ok(["ok": true])
            case "split":
                let vertical = (req.json?["direction"] as? String ?? "right") != "down"
                guard let newId = self?.splitProvider(pane.id, vertical) else {
                    return .badRequest("split unavailable")
                }
                return .ok(["ok": true, "pane": newId])
            case "close":
                return (self?.closeProvider(pane.id) ?? false)
                    ? .ok(["ok": true]) : .badRequest("close unavailable")
            default:
                return .notFound("unknown action \(parts[1])")
            }
        }
        server.route("GET", "/v1/panes/") { [weak self] req in
            // /v1/panes/<id>/output
            let parts = req.pathTail.split(separator: "/")
            guard parts.count == 2 else { return .notFound("expected /v1/panes/<id>/<info>") }
            guard let pane = self?.pane(withID: String(parts[0])) else {
                return .notFound("no pane \(parts[0])")
            }
            if let self, let denied = self.require(.panesRead, for: req) { return denied }
            switch String(parts[1]) {
            case "output":     return .ok(["text": pane.output(200)])
            case "scrollinfo": return .ok(pane.scrollInfo())
            default:           return .notFound("unknown info \(parts[1])")
            }
        }
        server.route("GET", "/v1/debug/framestats") { [weak self] request in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.debug, for: request) { return denied }
            return .ok(self.frameStatsProvider())
        }
        server.route("POST", "/v1/debug/hittest") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.debug, for: req) { return denied }
            // Diagnostic: which view claims a point (CG/Quartz screen coords,
            // top-left origin), and what its superview + responder chains are.
            guard let cgX = req.json?["x"] as? Double, let cgY = req.json?["y"] as? Double else {
                return .badRequest("missing x/y")
            }
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            let screenPoint = NSPoint(x: cgX, y: screenH - cgY)
            guard let window = NSApp.windows.first(where: { w in
                w.isVisible && w.frame.contains(screenPoint) && w.contentView != nil
            }) else { return .ok(["error": "no visible window at point"]) }
            let base = window.convertPoint(fromScreen: screenPoint)
            let frameView = window.contentView!.superview ?? window.contentView!
            let hit = frameView.hitTest(base)
            var chain: [String] = []
            var v: NSView? = hit
            while let cur = v { chain.append("\(type(of: cur))"); v = cur.superview }
            var responders: [String] = []
            var r: NSResponder? = hit
            var hops = 0
            while let cur = r, hops < 12 { responders.append("\(type(of: cur))"); r = cur.nextResponder; hops += 1 }
            return .ok([
                "window": window.title,
                "windowClass": "\(type(of: window))",
                "basePoint": ["x": base.x, "y": base.y],
                "hitView": hit.map { "\(type(of: $0))" } ?? "nil",
                "superviewChain": chain,
                "responderChain": responders,
            ])
        }
        server.route("POST", "/v1/notify") { [weak self] req in
            guard let self else { return .badRequest("shutting down") }
            if let denied = self.require(.notifications, for: req) { return denied }
            Notifier.post(
                title: req.json?["title"] as? String
                    ?? ProductIdentity.current.displayName,
                          body: req.json?["body"] as? String ?? "")
            return .ok(["ok": true])
        }
    }

    // MARK: - External extensions (~/.config/cmdy/extensions/<name>/manifest.json)

    public static var extensionsDirectory: URL {
        let destination = ConfigFile.directory.appendingPathComponent("extensions", isDirectory: true)
        let legacy = ConfigFile.directory.appendingPathComponent("plugins", isDirectory: true)
        let fm = FileManager.default
        // Remove the scaffold created by pre-Cmdy development builds. It is
        // identified by both its retired folder and legacy manifest name so a
        // user's unrelated legacy Extension is never deleted by migration.
        for root in [destination, legacy] {
            let sample = root.appendingPathComponent("hello-cmdy", isDirectory: true)
            let manifest = sample.appendingPathComponent("manifest.json")
            if let data = try? BoundedFileReader.data(
                at: manifest, maxBytes: 1024 * 1024),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["name"] as? String)?.caseInsensitiveCompare("Hello cmdy") == .orderedSame {
                try? fm.removeItem(at: sample)
            }
        }
        if fm.fileExists(atPath: legacy.path) {
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(
                at: legacy, includingPropertiesForKeys: nil)) ?? [] {
                let target = destination.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: item, to: target) }
            }
            if ((try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []).isEmpty {
                try? fm.removeItem(at: legacy)
            }
        }
        return destination
    }

    /// Source compatibility for existing integrations. New product language
    /// and filesystem paths use “Extension” consistently.
    public static var pluginsDirectory: URL { extensionsDirectory }

    static var discoveryURLs: [URL] {
        [ConfigFile.directory.appendingPathComponent("extension-api.json"),
         ConfigFile.directory.appendingPathComponent("plugin-api.json")]
    }

    /// Written at startup so ANY process (not just launched plugins) can find
    /// the API: {"port": …, "token": "…"} — file readable by the user only.
    private func writeDiscoveryFile() {
        let info: [String: Any] = ["port": server.port, "token": server.authToken, "api": "v1"]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? FileManager.default.createDirectory(at: ConfigFile.directory, withIntermediateDirectories: true)
            for url in Self.discoveryURLs {
                try? data.write(to: url)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: url.path)
            }
        }
    }

    /// Each plugin directory holds a manifest.json:
    ///   {"name": "My Plugin", "exec": "run.sh", "enabled": true}
    /// The executable is launched with TERM64_PORT and TERM64_TOKEN in its
    /// environment and lives for the app's lifetime (terminated on quit).
    private func launchExternalPlugins() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.extensionsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        for dir in entries {
            _ = launchPlugin(at: dir)
        }
    }

    /// Reconcile `.cmdy/extensions` against every open pane. Untrusted
    /// projects are surfaced once and never auto-execute; trusted project
    /// processes stop when the last pane leaves their project.
    public func reconcileProjectExtensions() {
        precondition(Thread.isMainThread, "project extension lifecycle is main-thread owned")
        projectExtensionReconcileWorkItem?.cancel()
        projectExtensionReconcileWorkItem = nil
        var discovered: [String: [ProjectExtension]] = [:]
        for cwd in Set(projectDirectoriesProvider()) {
            let url = URL(fileURLWithPath: cwd, isDirectory: true)
            guard let root = ProjectExtensionDiscovery.projectRoot(containing: url),
                  let extensions = try? ProjectExtensionDiscovery.extensions(in: root),
                  !extensions.isEmpty else { continue }
            discovered[root.standardizedFileURL.path] = extensions
        }

        var desired = Set<URL>()
        for (rootPath, extensions) in discovered {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard trustStore.isTrusted(root) else {
                if promptedProjectRoots.insert(rootPath).inserted {
                    requestProjectTrust(root, extensions.map(\.manifest)) { [weak self] trusted in
                        guard let self else { return }
                        if trusted {
                            try? self.trustStore.trust(root)
                            self.reconcileProjectExtensions()
                        }
                    }
                }
                continue
            }
            for item in extensions where item.manifest.enabled {
                desired.insert(item.directory.standardizedFileURL)
                if !isPluginRunning(at: item.directory) {
                    _ = launchPlugin(at: item.directory, scope: "project:\(rootPath)")
                }
            }
        }

        let obsolete = externalProcesses.filter {
            $0.scope.hasPrefix("project:")
                && !desired.contains($0.dir.standardizedFileURL)
        }.map(\.dir)
        for directory in Set(obsolete) { stopPlugin(at: directory) }
    }

    /// Pane CWD and lifecycle updates arrive in bursts while windows are being
    /// created, restored, split, or closed. Reconcile the final directory set
    /// once instead of rescanning every open project for every intermediate
    /// pane event on the main thread.
    public func scheduleProjectExtensionReconcile(
        after delay: TimeInterval = 0.08
    ) {
        precondition(Thread.isMainThread, "project extension lifecycle is main-thread owned")
        guard !isDeactivating else { return }
        projectExtensionReconcileWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDeactivating else { return }
            self.projectExtensionReconcileWorkItem = nil
            self.reconcileProjectExtensions()
        }
        projectExtensionReconcileWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay), execute: work)
    }

    public func trustProject(at root: URL) throws {
        try trustStore.trust(root)
        promptedProjectRoots.remove(root.standardizedFileURL.path)
        reconcileProjectExtensions()
    }

    public func revokeProjectTrust(at root: URL) throws {
        try trustStore.revoke(root)
        promptedProjectRoots.remove(root.standardizedFileURL.path)
        reconcileProjectExtensions()
    }

    public enum ExtensionDevelopmentError: LocalizedError {
        case missingPath(String)
        case unsupportedFile(String)
        case preparation(String)
        case launchFailed

        public var errorDescription: String? {
            switch self {
            case .missingPath(let path): return "No extension source exists at \(path)"
            case .unsupportedFile(let path):
                return "Cannot run \(path); add a shebang or use .sh, .py, .js, .mjs, or .swift"
            case .preparation(let detail): return "Could not prepare development extension: \(detail)"
            case .launchFailed: return "The development extension could not be launched"
            }
        }
    }

    /// Start a temporary, watched extension. A single source file needs no
    /// manifest; directories use their checked-in manifest. The heartbeat is
    /// owned by `cmdy extension dev` so Ctrl-C and crashed clients clean up.
    public func startDevelopmentExtension(
        at source: URL,
        capabilities: Set<ExtensionCapability> = [
            .events, .panesRead, .commands, .panels, .surfaces, .notifications,
        ]
    ) throws -> String {
        precondition(Thread.isMainThread, "development lifecycle is main-thread owned")
        let source = source.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ExtensionDevelopmentError.missingPath(source.path)
        }

        let id = UUID().uuidString
        let launchDirectory: URL
        let temporary: Bool
        if isDirectory.boolValue {
            _ = try ExtensionManifest.load(from: source)
            launchDirectory = source
            temporary = false
        } else {
            let root = ConfigFile.directory.appendingPathComponent(".extension-dev", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: root,
                                                        withIntermediateDirectories: true)
                let invocation = try Self.developmentInvocation(for: source)
                let wrapper = "#!/bin/sh\nexec \(invocation)\n"
                let wrapperURL = root.appendingPathComponent("run.sh")
                try wrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: wrapperURL.path)
                let component = Self.extensionIDComponent(source.deletingPathExtension()
                    .lastPathComponent)
                let manifest = try ExtensionManifest(
                    id: "dev.local.\(component)",
                    name: "Dev \(source.deletingPathExtension().lastPathComponent)",
                    version: "0.0.0-dev", entrypoint: "run.sh",
                    capabilities: capabilities.sorted { $0.rawValue < $1.rawValue },
                    description: "Temporary live development extension")
                try manifest.encoded().write(to: root.appendingPathComponent("manifest.json"),
                                             options: Data.WritingOptions.atomic)
                launchDirectory = root
                temporary = true
            } catch let error as ExtensionDevelopmentError {
                throw error
            } catch {
                throw ExtensionDevelopmentError.preparation(error.localizedDescription)
            }
        }

        let session = DevelopmentSession(
            id: id, source: source, launchDirectory: launchDirectory,
            temporary: temporary, signature: Self.developmentSignature(source),
            heartbeat: Date(), nextLogSequence: 1, logs: [])
        developmentSessions[id] = session
        ensureDevelopmentTimer()
        guard launchPlugin(at: launchDirectory, scope: "dev:\(id)") else {
            developmentSessions[id] = nil
            if temporary { try? FileManager.default.removeItem(at: launchDirectory) }
            throw ExtensionDevelopmentError.launchFailed
        }
        appendDevelopmentLog(id: id, stream: "host",
                             text: "watching \(source.path)")
        return id
    }

    public func heartbeatDevelopmentExtension(id: String) -> Bool {
        guard var session = developmentSessions[id] else { return false }
        session.heartbeat = Date()
        developmentSessions[id] = session
        return true
    }

    public func developmentStatus(id: String, after sequence: Int = 0) -> [String: Any]? {
        guard let session = developmentSessions[id] else { return nil }
        return [
            "id": id,
            "source": session.source.path,
            "running": isPluginRunning(at: session.launchDirectory),
            "logs": session.logs.filter { ($0["sequence"] as? Int ?? 0) > sequence },
        ]
    }

    public func stopDevelopmentExtension(id: String) {
        guard let session = developmentSessions.removeValue(forKey: id) else { return }
        pendingProcessLaunches[session.launchDirectory.standardizedFileURL] = nil
        stopPlugin(at: session.launchDirectory)
        if session.temporary {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                try? FileManager.default.removeItem(at: session.launchDirectory)
            }
        }
        if developmentSessions.isEmpty {
            developmentTimer?.cancel()
            developmentTimer = nil
        }
    }

    private func ensureDevelopmentTimer() {
        guard developmentTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4, leeway: .milliseconds(80))
        timer.setEventHandler { [weak self] in self?.tickDevelopmentSessions() }
        timer.resume()
        developmentTimer = timer
    }

    private func tickDevelopmentSessions() {
        let now = Date()
        let expired = developmentSessions.values
            .filter { now.timeIntervalSince($0.heartbeat) > 4.0 }.map(\.id)
        for id in expired { stopDevelopmentExtension(id: id) }

        for id in Array(developmentSessions.keys) {
            guard var session = developmentSessions[id] else { continue }
            let signature = Self.developmentSignature(session.source)
            guard signature != session.signature else { continue }
            session.signature = signature
            developmentSessions[id] = session
            appendDevelopmentLog(id: id, stream: "host", text: "change detected; restarting")
            let directory = session.launchDirectory.standardizedFileURL
            if isPluginRunning(at: directory) {
                pendingProcessLaunches[directory] = directory
                stopPlugin(at: directory)
            } else {
                _ = launchPlugin(at: directory, scope: "dev:\(id)")
            }
        }
    }

    private func appendDevelopmentLog(id: String, stream: String, text: String) {
        guard var session = developmentSessions[id] else { return }
        for line in text.split(whereSeparator: \.isNewline).map(String.init) where !line.isEmpty {
            session.logs.append([
                "sequence": session.nextLogSequence,
                "stream": stream,
                "text": line,
            ])
            session.nextLogSequence += 1
        }
        if session.logs.count > 500 { session.logs.removeFirst(session.logs.count - 500) }
        developmentSessions[id] = session
    }

    private static func developmentInvocation(for source: URL) throws -> String {
        let quoted = shellQuote(source.path)
        if FileManager.default.isExecutableFile(atPath: source.path) { return quoted }
        switch source.pathExtension.lowercased() {
        case "sh", "bash", "zsh": return "/bin/sh \(quoted)"
        case "py": return "/usr/bin/env python3 \(quoted)"
        case "js", "mjs": return "/usr/bin/env node \(quoted)"
        case "swift": return "/usr/bin/env swift \(quoted)"
        default: throw ExtensionDevelopmentError.unsupportedFile(source.path)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func extensionIDComponent(_ value: String) -> String {
        let mapped = value.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "-" || character == "_") ? character : "-"
        }
        let text = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return text.isEmpty ? "extension" : text
    }

    private static func developmentSignature(_ source: URL) -> String {
        var paths: [URL] = []
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           let enumerator = FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey,
                                              .isRegularFileKey],
                options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let relative = url.path.replacingOccurrences(of: source.path + "/", with: "")
                if relative.hasPrefix(".build/") || relative.hasPrefix(".git/") {
                    enumerator.skipDescendants()
                    continue
                }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    paths.append(url)
                }
            }
        } else {
            paths = [source]
        }
        var hasher = Hasher()
        for url in paths.sorted(by: { $0.path < $1.path }) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            hasher.combine(url.path)
            hasher.combine(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            hasher.combine(values?.fileSize ?? -1)
        }
        return String(hasher.finalize())
    }

    private func appendExtensionOutput(_ text: String, at directory: URL) {
        let key = directory.standardizedFileURL
        let combined = (extensionLogTails[key] ?? "") + text
        extensionLogTails[key] = String(combined.suffix(8_192))
    }

    private func lastExtensionLogLine(at directory: URL) -> String? {
        guard let tail = extensionLogTails[directory.standardizedFileURL] else { return nil }
        let line = tail.split(whereSeparator: { $0.isNewline }).last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else { return nil }
        return String(line.suffix(240))
    }

    private func recordExtensionFailure(at directory: URL, message: String) {
        let key = directory.standardizedFileURL
        extensionFailures[key] = message
        notifyExtensionRuntimeChanged(at: key)
    }

    private func clearExtensionFailure(at directory: URL) {
        extensionFailures[directory.standardizedFileURL] = nil
    }

    private func notifyExtensionRuntimeChanged(at directory: URL) {
        NotificationCenter.default.post(
            name: .cmdyExtensionRuntimeChanged,
            object: self,
            userInfo: ["directory": directory.standardizedFileURL])
    }

    private func markExtensionReady(owner: String) {
        precondition(Thread.isMainThread, "extension readiness is main-thread owned")
        guard let external = externalProcesses.first(where: {
            $0.owner == owner && $0.process.isRunning
                && !stoppingProcessIDs.contains(ObjectIdentifier($0.process))
        }), readyExternalOwners.insert(owner).inserted else { return }
        clearExtensionFailure(at: external.dir)
        log("[\(external.manifest.name)] ready (pid \(external.process.processIdentifier))")
        notifyExtensionRuntimeChanged(at: external.dir)
    }

    /// Authoritative state for an installed Extension. `ready` means this exact
    /// child process has successfully used its per-launch API credential.
    public func extensionRuntimeStatus(at directory: URL) -> ExtensionRuntimeStatus {
        let key = directory.standardizedFileURL
        if let manifest = activeHostComponents[key] {
            return ExtensionRuntimeStatus(
                directory: key,
                id: manifest.id,
                name: manifest.name,
                phase: .ready,
                processIdentifier: nil,
                message: nil,
                lastLog: lastExtensionLogLine(at: key))
        }
        let external = externalProcesses.first {
            $0.dir.standardizedFileURL == key && $0.process.isRunning
                && !stoppingProcessIDs.contains(ObjectIdentifier($0.process))
        }
        let manifest = external?.manifest ?? (try? ExtensionManifest.load(from: key))
        let id = manifest?.id ?? key.lastPathComponent
        let name = manifest?.name ?? key.lastPathComponent
        if let external {
            return ExtensionRuntimeStatus(
                directory: key,
                id: id,
                name: name,
                phase: readyExternalOwners.contains(external.owner) ? .ready : .starting,
                processIdentifier: external.process.processIdentifier,
                message: nil,
                lastLog: lastExtensionLogLine(at: key))
        }
        if let failure = extensionFailures[key] {
            return ExtensionRuntimeStatus(
                directory: key,
                id: id,
                name: name,
                phase: .failed,
                processIdentifier: nil,
                message: failure,
                lastLog: lastExtensionLogLine(at: key))
        }
        return ExtensionRuntimeStatus(
            directory: key,
            id: id,
            name: name,
            phase: .stopped,
            processIdentifier: nil,
            message: nil,
            lastLog: lastExtensionLogLine(at: key))
    }

    /// Every launch or failure known to this manager, sorted for deterministic
    /// diagnostics such as `--plugin-menu`.
    public var externalExtensionStatuses: [ExtensionRuntimeStatus] {
        var directories = Set(externalProcesses.map { $0.dir.standardizedFileURL })
        directories.formUnion(activeHostComponents.keys)
        directories.formUnion(extensionFailures.keys)
        return directories.map(extensionRuntimeStatus(at:)).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public enum PluginLifecycleError: LocalizedError {
        case invalidManifest(String)
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidManifest(let message): return message
            case .launchFailed(let name): return "\(name) is enabled but could not be launched"
            }
        }
    }

    /// The Plugins panel's authoritative lifecycle operation. The manifest is
    /// persisted atomically, then the process is started or stopped now.
    public func setPluginEnabled(_ enabled: Bool, at dir: URL) throws {
        precondition(Thread.isMainThread, "plugin processes are main-thread owned")
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? BoundedFileReader.data(
                at: manifestURL, maxBytes: 1024 * 1024),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ((manifest["entrypoint"] as? String) ?? (manifest["exec"] as? String)) != nil else {
            throw PluginLifecycleError.invalidManifest(
                "Invalid plugin manifest in \(dir.lastPathComponent)")
        }
        manifest["enabled"] = enabled
        let encoded = try JSONSerialization.data(withJSONObject: manifest,
                                                  options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: manifestURL, options: .atomic)

        if enabled {
            if !isPluginRunning(at: dir), !launchPlugin(at: dir) {
                manifest["enabled"] = false
                if let rollback = try? JSONSerialization.data(
                    withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                    try? rollback.write(to: manifestURL, options: .atomic)
                }
                let name = manifest["name"] as? String ?? dir.lastPathComponent
                throw PluginLifecycleError.launchFailed(name)
            }
        } else {
            clearExtensionFailure(at: dir)
            pendingProcessLaunches[dir.standardizedFileURL] = nil
            stopPlugin(at: dir)
            notifyExtensionRuntimeChanged(at: dir)
        }
    }

    public func isPluginRunning(at dir: URL) -> Bool {
        let key = dir.standardizedFileURL
        if activeHostComponents[key] != nil { return true }
        return externalProcesses.contains {
            $0.dir.standardizedFileURL == key && $0.process.isRunning
                && !stoppingProcessIDs.contains(ObjectIdentifier($0.process))
        }
    }

    /// Launch one plugin directory (skips disabled/malformed ones). Public so
    /// the marketplace can start a plugin right after installing it.
    @discardableResult
    public func launchPlugin(at dir: URL, scope: String = "global") -> Bool {
        precondition(Thread.isMainThread, "plugin processes are main-thread owned")
        let pluginKey = dir.standardizedFileURL
        let manifest: ExtensionManifest
        do {
            manifest = try ExtensionManifest.load(from: dir)
        } catch {
            let message = "invalid manifest: \(error.localizedDescription)"
            recordExtensionFailure(at: pluginKey, message: message)
            log("[\(dir.lastPathComponent)] \(message)")
            return false
        }
        if !manifest.enabled {
            clearExtensionFailure(at: pluginKey)
            return false
        }
        let name = manifest.name
        let pluginID = manifest.id
        let execURL = dir.appendingPathComponent(manifest.entrypoint).standardizedFileURL
        let root = dir.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard execURL.resolvingSymlinksInPath().path.hasPrefix(root) else {
            let message = "entrypoint escapes extension directory"
            recordExtensionFailure(at: pluginKey, message: message)
            log("[\(name)] \(message)")
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: execURL.path) else {
            let message = "entrypoint not found or executable: \(execURL.lastPathComponent)"
            recordExtensionFailure(at: pluginKey, message: message)
            log("[\(name)] \(message)")
            return false
        }
        if let component = manifest.hostComponent {
            if activeHostComponents[pluginKey] != nil {
                log("[\(name)] embedded component already active")
                return false
            }
            if let existing = activeHostComponents.first(where: {
                $0.value.id == pluginID && $0.key != pluginKey
            }) {
                let message = "id \(pluginID) is already active from \(existing.key.path)"
                recordExtensionFailure(at: pluginKey, message: message)
                log("[\(name)] \(message)")
                return false
            }
            guard hostComponentLifecycle(component, pluginKey, true) else {
                let message = "host component '\(component)' is unavailable"
                recordExtensionFailure(at: pluginKey, message: message)
                log("[\(name)] \(message)")
                return false
            }
            activeHostComponents[pluginKey] = manifest
            clearExtensionFailure(at: pluginKey)
            log("[\(name)] embedded component ready")
            notifyExtensionRuntimeChanged(at: pluginKey)
            return true
        }
        let runningForDirectory = externalProcesses.filter {
            $0.dir.standardizedFileURL == pluginKey && $0.process.isRunning
        }
        if !runningForDirectory.isEmpty {
            let allStopping = runningForDirectory.allSatisfy {
                stoppingProcessIDs.contains(ObjectIdentifier($0.process))
            }
            guard allStopping else {
                log("[\(name)] already running")
                return false
            }
            pendingProcessLaunches[pluginKey] = dir
            log("[\(name)] launch deferred until previous process exits")
            return true
        }
        if let existing = externalProcesses.first(where: {
            $0.manifest.id == pluginID && $0.process.isRunning
                && $0.dir.standardizedFileURL != pluginKey
        }) {
            let message = "id \(pluginID) is already running from \(existing.dir.path)"
            recordExtensionFailure(at: pluginKey, message: message)
            log("[\(name)] \(message)")
            return false
        }
        let process = Process()
        process.executableURL = execURL
        process.currentDirectoryURL = dir
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let developmentSessionID = scope.hasPrefix("dev:")
            ? String(scope.dropFirst("dev:".count)) : nil
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.appendExtensionOutput(text, at: pluginKey)
                if let developmentSessionID {
                    self?.appendDevelopmentLog(id: developmentSessionID,
                                               stream: "extension", text: text)
                }
            }
        }
        var env = ProcessInfo.processInfo.environment
        let owner = UUID().uuidString
        let capabilities = manifest.effectiveCapabilities
            .map(\.rawValue).sorted().joined(separator: ",")
        let identity = ProductIdentity.current
        for prefix in identity.compatibleEnvironmentPrefixes {
            env["\(prefix)_PORT"] = String(server.port)
            env["\(prefix)_TOKEN"] = owner
            env["\(prefix)_EXTENSION_ID"] = pluginID
            env["\(prefix)_EXTENSION_NAME"] = name
            env["\(prefix)_EXTENSION_VERSION"] = manifest.version
            env["\(prefix)_EXTENSION_SCOPE"] = scope
            env["\(prefix)_MANIFEST_VERSION"] = String(manifest.manifestVersion)
            env["\(prefix)_CAPABILITIES"] = capabilities
            // Deprecated aliases retained through the v1 compatibility window.
            env["\(prefix)_PLUGIN_ID"] = pluginID
            env["\(prefix)_PLUGIN_NAME"] = name
        }
        process.environment = env
        server.registerPluginCredential(owner, id: pluginID, name: name,
                                        capabilities: manifest.effectiveCapabilities)
        // A dying plugin must not leave its reserved dock strip behind
        // (toggle-off is a SIGTERM — the plugin may not get to clean up).
        process.terminationHandler = { [weak self] terminated in
            let processID = ObjectIdentifier(terminated)
            DispatchQueue.main.async {
                guard let self else { return }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let wasStopping = self.stoppingProcessIDs.remove(processID) != nil
                self.externalProcesses.removeAll {
                    ObjectIdentifier($0.process) == processID
                }
                self.readyExternalOwners.remove(owner)
                self.cleanupPluginResources(owner: owner)
                self.server.revokePluginCredential(owner)
                if !self.isDeactivating, !wasStopping {
                    let message: String
                    switch terminated.terminationReason {
                    case .exit:
                        message = "exited with status \(terminated.terminationStatus)"
                    case .uncaughtSignal:
                        message = "terminated by signal \(terminated.terminationStatus)"
                    @unknown default:
                        message = "process stopped unexpectedly"
                    }
                    self.extensionFailures[pluginKey] = message
                }
                self.notifyExtensionRuntimeChanged(at: pluginKey)
                let replacementIsRunning = self.externalProcesses.contains {
                    $0.dir.standardizedFileURL == pluginKey && $0.process.isRunning
                }
                guard !self.isDeactivating, !replacementIsRunning,
                      let pending = self.pendingProcessLaunches.removeValue(forKey: pluginKey)
                else { return }
                _ = self.launchPlugin(at: pending, scope: scope)
            }
        }
        do {
            extensionLogTails[pluginKey] = ""
            clearExtensionFailure(at: pluginKey)
            try process.run()
            externalProcesses.append(ExternalProcess(dir: dir, manifest: manifest,
                                                       scope: scope, owner: owner,
                                                       process: process,
                                                       outputPipe: outputPipe))
            let compatibility = manifest.isLegacy ? ", legacy full access" : ""
            log("[\(name)] launched (pid \(process.processIdentifier), \(scope)\(compatibility))")
            notifyExtensionRuntimeChanged(at: pluginKey)
            return true
        } catch {
            server.revokePluginCredential(owner)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let message = "failed to launch: \(error.localizedDescription)"
            recordExtensionFailure(at: pluginKey, message: message)
            log("[\(name)] \(message)")
            return false
        }
    }

    /// Terminate the running process of a plugin directory, if any — the
    /// marketplace stops a plugin before replacing its folder (fresh inode).
    public func stopPlugin(at dir: URL) {
        precondition(Thread.isMainThread, "plugin processes are main-thread owned")
        clearExtensionFailure(at: dir)
        let key = dir.standardizedFileURL
        if let manifest = activeHostComponents.removeValue(forKey: key),
           let component = manifest.hostComponent {
            _ = hostComponentLifecycle(component, key, false)
            log("[\(manifest.name)] embedded component stopped")
            notifyExtensionRuntimeChanged(at: key)
        }
        for external in externalProcesses
        where external.dir.standardizedFileURL == key
            && external.process.isRunning {
            let process = external.process
            let processID = ObjectIdentifier(process)
            guard stoppingProcessIDs.insert(processID).inserted else { continue }
            cleanupPluginResources(owner: external.owner)
            server.revokePluginCredential(external.owner)
            readyExternalOwners.remove(external.owner)
            notifyExtensionRuntimeChanged(at: dir)
            let pid = process.processIdentifier
            process.terminate()
            // Keep all Process inspection on its owning queue. The termination
            // handler removes this exact process without touching a replacement.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let process = self?.externalProcesses.first(where: {
                    ObjectIdentifier($0.process) == processID
                })?.process else { return }
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    // MARK: - PluginHost

    var panes: [PluginPane] { panesProvider() }
    private func pane(withID id: String) -> PluginPane? {
        paneProvider(id) ?? panes.first { $0.id == id }
    }
    var focusedPane: PluginPane? { focusedPaneProvider() }
    var serverPort: Int { server.port }

    func addCommand(id: String, title: String, run: @escaping () -> Void) {
        commands.append((id: id, title: title, plugin: activatingPlugin,
                         owner: nil, run: run))
    }

    /// Commands grouped by plugin, in activation order — for the Plugins menu.
    public var commandsByPlugin: [(plugin: String, commands: [(title: String, run: () -> Void)])] {
        var order: [String] = []
        var grouped: [String: [(String, () -> Void)]] = [:]
        for c in commands {
            if grouped[c.plugin] == nil { order.append(c.plugin) }
            grouped[c.plugin, default: []].append((c.title, c.run))
        }
        return order.map { ($0, grouped[$0]!.map { (title: $0.0, run: $0.1) }) }
    }

    func addRoute(_ method: String, _ path: String, _ handler: @escaping (PluginHTTPRequest) -> PluginHTTPResponse) {
        server.route(method, path, handler)
    }

    public func registerHotKey(keyCode: UInt32, modifiers: UInt32, _ handler: @escaping () -> Void) {
        _ = hotKeys.register(keyCode: keyCode, modifiers: modifiers, handler)
    }

    func log(_ message: String) { NSLog("cmdy plugin: %@", message) }

    // MARK: - Author on-ramp (palette commands)

    /// Write a runnable sample extension into the extensions folder and reveal it —
    /// the "how do I build for cmdy?" answer in one keystroke.
    public func createSamplePlugin() {
        let identity = ProductIdentity.current
        let sampleName = "hello-\(identity.slug)"
        let dir = Self.extensionsDirectory.appendingPathComponent(sampleName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        {
          "manifestVersion": 1,
          "id": "local.\(sampleName)",
          "name": "Hello \(identity.titleName)",
          "version": "0.1.0",
          "entrypoint": "run.sh",
          "enabled": true,
          "capabilities": ["panes.read", "panes.type", "notifications"]
        }
        """
        let script = """
        #!/bin/bash
        # A complete \(identity.titleName) extension. Full API: GET /v1 or EXTENSIONS.md.
        auth="Authorization: Bearer $\(identity.environmentKey("TOKEN"))"
        base="http://127.0.0.1:$\(identity.environmentKey("PORT"))"

        sleep 2   # let the first pane open
        pane=$(curl -s -H "$auth" $base/v1/panes | python3 -c 'import json,sys; print(json.load(sys.stdin)["panes"][0]["id"])')
        curl -s -H "$auth" -X POST -d '{"title":"Hello \(identity.titleName)","body":"Your first extension is alive — edit ~/.config/\(identity.configurationDirectoryName)/extensions/\(sampleName)/run.sh"}' $base/v1/notify > /dev/null
        curl -s -H "$auth" -X POST -d '{"text":"echo hello from my first \(identity.titleName) extension"}' $base/v1/panes/$pane/type > /dev/null
        """
        try? manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let scriptURL = dir.appendingPathComponent("run.sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        NSWorkspace.shared.activateFileViewerSelecting([scriptURL])
        _ = launchPlugin(at: dir)
        Notifier.post(title: "Sample extension created",
                      body: "\(sampleName) is enabled and running. "
                        + "Edit run.sh to make it yours.")
    }

    /// Open the shipped author guide.
    public func openAuthorGuide() {
        // Prefer the repo copy when running from a checkout; else the bundled one.
        let repoDoc = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("EXTENSIONS.md")
        if FileManager.default.fileExists(atPath: repoDoc.path) {
            NSWorkspace.shared.open(repoDoc)
        } else if let bundled = Bundle.main.url(forResource: "EXTENSIONS", withExtension: "md") {
            NSWorkspace.shared.open(bundled)
        } else {
            showInfo("Extension API", apiCheatSheet())
        }
    }

    private func apiCheatSheet() -> String {
        let identity = ProductIdentity.current
        return """
        \(identity.titleName) Extension SDK (v1) — 127.0.0.1:\(serverPort)
        Token: ~/.config/\(identity.configurationDirectoryName)/extension-api.json (or \(identity.environmentKey("TOKEN")) when launched by \(identity.titleName))

        Panes
        GET  /v1                      API index (self-describing)
        GET  /v1/panes                every pane: id, title, cwd, pid, tty, ai, focused
        POST /v1/panes/<id>/type      {"text": …}     type at the prompt (never runs)
        POST /v1/panes/<id>/run       {"command": …}  type + Enter
        POST /v1/panes/<id>/focus     bring the pane forward
        POST /v1/panes/<id>/split     {"direction":"right"|"down"}
        POST /v1/panes/<id>/close
        POST /v1/windows/compose       {"panes":["id", "id"]} gather live panes
        POST /v1/panes/<id>/scroll    {"lines": …}
        GET  /v1/panes/<id>/output    recent scrollback
        GET  /v1/panes/<id>/scrollinfo
        POST /v1/panes/<id>/feed      {"text": …}     display-only (colors, kitty images)
        POST /v1/notify               {"title","body"}

        The SDK — build Bridge-scale extensions in any language
        GET  /v1/events               SSE stream: pane-opened/closed, command-finished,
                                      your command/hotkey invocations, ui callbacks
        POST /v1/commands             {"id","title"} → palette + Extensions submenu
        POST /v1/hotkeys              {"id","keyCode","modifiers"}   (Carbon codes)
        POST /v1/ui/panel             {"mode": list|input|text|editor, …} → native inline
                                      panel in the terminal; interactions stream back
        POST /v1/ui/<panel>/update    {"body" | "appendLine" | "hint"}
        POST /v1/ui/<panel>/dismiss
        POST /v1/ui/inset             {"right": points, "window": WindowServerID}
        POST /v1/surfaces             Surface Protocol v1 document
        PATCH /v1/surfaces/<id>       sequenced Surface patch
        POST /v1/hooks                bounded decision hook registration
        POST /v1/marketplace/install  {"id": …, "consent": true|false}

        Install: ~/.config/\(identity.configurationDirectoryName)/extensions/<name>/manifest.json
        + executable (fresh-copy the binary on reinstall — never overwrite in place).

        Learn: Author Guide (EXTENSIONS.md) — protocol docs, examples, and the
        reference implementations: Plugins/detox (read first), Plugins/bridge,
        Plugins/CmdySDK (the Swift client library).
        """
    }
}
