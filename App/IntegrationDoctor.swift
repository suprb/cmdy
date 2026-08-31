import AppKit
import Foundation
import ProductIdentity
@preconcurrency import CmdyKit

/// Deterministic setup and health checks for the first-party agent surfaces.
///
/// The built-in assistant routes setup questions here, but an LLM never edits
/// MCP or permission files itself. Every mutation is named in a user-selected
/// action, preserves existing configuration, and writes a backup first.
enum IntegrationDoctor {
    enum Client: Equatable, Sendable {
        case claude
        case codex
        case pi
        case other(String)

        init(tool: String) {
            let firstWord = tool.split(whereSeparator: \.isWhitespace)
                .first.map(String.init) ?? tool
            let raw = (firstWord as NSString).lastPathComponent.lowercased()
            if raw == "claude" || raw.contains("claude") { self = .claude }
            else if raw == "codex" || raw.contains("codex") { self = .codex }
            else if raw == "pi" { self = .pi }
            else { self = .other(raw.isEmpty ? tool : raw) }
        }

        var command: String {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            case .pi: return "pi"
            case .other(let command): return command
            }
        }

        var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .pi: return "Pi"
            case .other(let command): return command.isEmpty ? "agent" : command
            }
        }

        var supportsManagedSetup: Bool {
            if case .other = self { return false }
            return true
        }
    }

    struct Integration: Hashable, Sendable {
        let key: String
        let name: String
        let folder: String
        let mcpName: String
        let shimComponents: [String]
        let discoveryFile: String?
        let sourceHints: [String]

        var directory: URL {
            PluginManager.extensionsDirectory.appendingPathComponent(folder, isDirectory: true)
        }

        var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

        var shimURL: URL {
            shimComponents.reduce(directory) { $0.appendingPathComponent($1) }
        }

        var discoveryURL: URL? {
            discoveryFile.map {
                ConfigFile.directory.appendingPathComponent($0)
            }
        }

        var permissionRule: String { "mcp__\(mcpName)__*" }

        var registrationNames: [String] {
            var names = ProductIdentity.current.compatibleMCPServerNames(key)
            if key == "bridge" { names.append("bridge") }
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }
        }
    }

    struct Check: Sendable {
        let integration: Integration
        let client: Client
        let installed: Bool
        let enabled: Bool
        let running: Bool
        let apiReady: Bool
        let shimExists: Bool
        let registered: Bool
        let permissionReady: Bool
        let permissionExplicitlyDenied: Bool
        let piAdapterReady: Bool
    }

    static let integrations: [Integration] = [
        Integration(
            key: "browser", name: "Browser", folder: "chromium",
            mcpName: ProductIdentity.current.mcpServerName("browser"),
            shimComponents: ["mcp", "index.js"],
            discoveryFile: "browser-api.json",
            sourceHints: ["chromium", "browser"]),
        Integration(
            key: "sim", name: "Sim / Sim Mirror", folder: "sim",
            mcpName: ProductIdentity.current.mcpServerName("sim"),
            shimComponents: ["mcp", "index.js"],
            discoveryFile: "sim-api.json",
            sourceHints: ["sim"]),
        Integration(
            key: "bridge", name: "Bridge", folder: "bridge",
            mcpName: ProductIdentity.current.mcpServerName("bridge"),
            shimComponents: [
                "BraincellBridge_BraincellBridgeKit.bundle", "mcp", "index.js",
            ],
            discoveryFile: nil,
            sourceHints: ["bridge"]),
    ]

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var claudeConfigURL: URL { home.appendingPathComponent(".claude.json") }
    private static var claudeSettingsURL: URL {
        home.appendingPathComponent(".claude/settings.json")
    }
    private static var codexConfigURL: URL {
        home.appendingPathComponent(".codex/config.toml")
    }
    private static var piSettingsURL: URL {
        home.appendingPathComponent(".pi/agent/settings.json")
    }
    private static var piGlobalConfigURL: URL {
        home.appendingPathComponent(".pi/agent/mcp.json")
    }
    private static var sharedMCPConfigURL: URL {
        home.appendingPathComponent(".config/mcp/mcp.json")
    }

    @MainActor
    private static func presentPanel(
        in host: any InlinePanelHost, takeFocus: Bool
    ) -> InlinePanel {
        if let pane = host as? TerminalPane,
           let controller = pane.window?.windowController as? TerminalWindowController {
            return controller.presentWindowInlinePanel(
                from: pane, takeFocus: takeFocus)
        }
        return host.presentInlinePanel(takeFocus: takeFocus)
    }

    @MainActor
    private static func dismissPanel(
        in host: any InlinePanelHost, refocus: Bool
    ) {
        if let pane = host as? TerminalPane,
           let controller = pane.window?.windowController as? TerminalWindowController {
            controller.dismissWindowInlinePanel(from: pane, refocus: refocus)
        } else {
            host.dismissInlinePanel(refocus: refocus)
        }
    }

    // MARK: - Routing

    static func matches(_ request: String) -> Bool {
        let text = request.lowercased()
        if text.contains("integration doctor") { return true }
        let subjects = ["browser", "sim", "simulator", "mirror", "bridge", "mcp", "integration"]
        let intents = [
            "setup", "set up", "fix", "check", "doctor", "install",
            "connect", "permission", "access", "configure", "not working",
        ]
        return subjects.contains(where: text.contains)
            && intents.contains(where: text.contains)
    }

    static func clientForLaunchCommand(_ command: String) -> Client? {
        switch command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        case "pi": return .pi
        default: return nil
        }
    }

    /// Intercept only unhealthy direct interactive launches. Healthy launches
    /// keep their ordinary zero-latency Return path.
    @MainActor
    static func interceptAgentLaunch(_ command: String, in pane: TerminalPane) -> Bool {
        guard let client = clientForLaunchCommand(command) else { return false }
        let required = requiredIntegrations(sourceExtensionID: nil)
        guard !required.isEmpty else { return false }
        let checks = required.map { check($0, for: client, cwd: pane.currentCwd) }
        guard !issues(for: checks, client: client, alreadyRunning: false).isEmpty else {
            return false
        }

        preflight(
            agentCommand: command,
            displayName: client.displayName,
            sourceExtensionID: nil,
            cwd: pane.currentCwd,
            host: pane,
            alreadyRunning: false
        ) { [weak pane] in
            pane?.replacePromptInput(with: command, submit: true)
            pane?.focus()
        }
        return true
    }

    // MARK: - Presentation

    @MainActor
    static func preflight(
        agentCommand: String,
        displayName: String,
        sourceExtensionID: String?,
        cwd: String?,
        host: any InlinePanelHost,
        alreadyRunning: Bool,
        launch: @escaping () -> Void
    ) {
        let client = Client(tool: agentCommand)
        let required = requiredIntegrations(sourceExtensionID: sourceExtensionID)
        guard !required.isEmpty else {
            if !alreadyRunning { launch() }
            return
        }
        let checks = required.map { check($0, for: client, cwd: cwd) }
        let problems = issues(for: checks, client: client, alreadyRunning: alreadyRunning)
        guard !problems.isEmpty else {
            if !alreadyRunning { launch() }
            return
        }

        let integrationNames = checks.map(\.integration.name).joined(separator: ", ")
        var items: [PaletteItem] = []
        if canFix(checks, client: client, alreadyRunning: alreadyRunning) {
            items.append(PaletteItem(
                title: alreadyRunning
                    ? "Fix setup for the current \(client.displayName) session"
                    : "Fix setup, then start \(displayName)",
                subtitle: fixDescription(checks, client: client),
                action: {
                    fix(
                        checks, client: client, cwd: cwd, host: host,
                        alreadyRunning: alreadyRunning,
                        reopenDoctor: false,
                        launch: alreadyRunning ? nil : launch)
                }))
        }
        items.append(PaletteItem(
            title: "Open Integration Doctor",
            subtitle: problems.joined(separator: " · "),
            action: { present(in: host, cwd: cwd) }))
        items.append(PaletteItem(
            title: alreadyRunning
                ? "Keep current \(client.displayName) session"
                : "Continue without \(integrationNames) tools",
            subtitle: alreadyRunning
                ? "the integration stays open, but MCP tools remain unavailable"
                : "start the agent without repairing its "
                    + "\(ProductIdentity.current.titleName) access",
            action: {
                if !alreadyRunning { launch() }
            }))
        items.append(PaletteItem(title: "Cancel"))

        presentPanel(in: host, takeFocus: true).configureList(
            items: items,
            placeholder: "",
            hint: "\(integrationNames) needs agent setup before its tools can be used")
    }

    @MainActor
    static func present(in host: any InlinePanelHost, cwd: String? = nil) {
        let provider = { @MainActor in doctorItems(host: host, cwd: cwd) }
        presentPanel(in: host, takeFocus: true).configureList(
            items: provider(),
            placeholder: "filter integration checks…",
            hint: "↑↓ select · → details · return fix · esc close",
            memoryKey: "integration-doctor",
            itemsProvider: provider)
    }

    @MainActor
    private static func doctorItems(
        host: any InlinePanelHost, cwd: String?
    ) -> [PaletteItem] {
        let installed = integrations.filter { manifestExists($0) && manifestEnabled($0) }
        var root: [PaletteItem] = []

        if installed.isEmpty {
            root.append(PaletteItem(
                title: "Install first-party integrations",
                subtitle: "Browser · Sim / Sim Mirror · Bridge",
                action: { (NSApp.delegate as? AppDelegate)?.browseMarketplace(nil) }))
        } else {
            for client in [Client.claude, .codex, .pi] {
                let checks = installed.map { check($0, for: client, cwd: cwd) }
                let problems = issues(for: checks, client: client, alreadyRunning: false)
                let fixable = canFix(checks, client: client, alreadyRunning: false)
                let title = problems.isEmpty
                    ? "✓ \(client.displayName): all enabled integrations ready"
                    : fixable
                        ? "Fix all for \(client.displayName)"
                        : "⚠ \(client.displayName): setup needs attention"
                let subtitle = problems.isEmpty
                    ? "\(checks.count) integration\(checks.count == 1 ? "" : "s")"
                    : fixable
                        ? fixDescription(checks, client: client)
                        : problems.joined(separator: " · ")
                root.append(PaletteItem(
                    title: title,
                    subtitle: subtitle,
                    action: {
                        guard !checks.isEmpty, !problems.isEmpty else {
                            present(in: host, cwd: cwd)
                            return
                        }
                        guard fixable else {
                            presentProblems(
                                problems, title: "\(client.displayName) setup", in: host)
                            return
                        }
                        fix(
                            checks, client: client, cwd: cwd, host: host,
                            alreadyRunning: false, reopenDoctor: true, launch: nil)
                    }))
            }
        }

        for integration in integrations {
            let runtime = runtimeSubtitle(integration)
            let children: [PaletteItem]
            if !manifestExists(integration) {
                children = [
                    PaletteItem(
                        title: "Open Marketplace",
                        subtitle: "install \(integration.name) before configuring its MCP",
                        action: {
                            (NSApp.delegate as? AppDelegate)?.browseMarketplace(nil)
                        }),
                ]
            } else {
                children = [Client.claude, .codex, .pi].map { client in
                    let checks = [check(integration, for: client, cwd: cwd)]
                    let problems = issues(
                        for: checks, client: client, alreadyRunning: false)
                    let fixable = canFix(
                        checks, client: client, alreadyRunning: false)
                    return PaletteItem(
                        title: problems.isEmpty
                            ? "✓ \(client.displayName)"
                            : fixable
                                ? "Fix for \(client.displayName)"
                                : "⚠ \(client.displayName)",
                        subtitle: problems.isEmpty
                            ? "MCP and permissions ready"
                            : fixable
                                ? fixDescription(checks, client: client)
                                : problems.joined(separator: " · "),
                        action: {
                            if problems.isEmpty {
                                present(in: host, cwd: cwd)
                            } else if fixable {
                                fix(
                                    checks, client: client, cwd: cwd, host: host,
                                    alreadyRunning: false,
                                    reopenDoctor: true, launch: nil)
                            } else {
                                presentProblems(
                                    problems,
                                    title: "\(integration.name) · \(client.displayName)",
                                    in: host)
                            }
                        })
                }
            }
            root.append(.section(integration.name, runtime, children))
        }

        root.append(PaletteItem(
            title: "Open Extensions",
            subtitle: "enable, disable, or inspect first-party processes",
            action: { (NSApp.delegate as? AppDelegate)?.showPlugins(nil) }))
        root.append(PaletteItem(
            title: "Browse the Marketplace",
            subtitle: "install missing first-party integrations",
            action: { (NSApp.delegate as? AppDelegate)?.browseMarketplace(nil) }))
        return root
    }

    @MainActor
    private static func presentProblems(
        _ problems: [String], title: String, in host: any InlinePanelHost
    ) {
        presentPanel(in: host, takeFocus: true).configureText(
            title: title,
            body: problems.map { "• \($0)" }.joined(separator: "\n"),
            hint: "return or esc closes")
    }

    // MARK: - Checks

    @MainActor
    private static func requiredIntegrations(sourceExtensionID: String?) -> [Integration] {
        if let source = sourceExtensionID?.lowercased(),
           let exact = integrations.first(where: { integration in
               integration.sourceHints.contains(where: source.contains)
           }) {
            return [exact]
        }
        return integrations.filter { manifestExists($0) && manifestEnabled($0) }
    }

    @MainActor
    private static func check(
        _ integration: Integration, for client: Client, cwd: String?
    ) -> Check {
        let fm = FileManager.default
        let permission = client == .claude
            ? claudePermissionState(integration, cwd: cwd)
            : (ready: true, denied: false)
        return Check(
            integration: integration,
            client: client,
            installed: manifestExists(integration),
            enabled: manifestEnabled(integration),
            running: PluginManager.shared.isPluginRunning(at: integration.directory),
            apiReady: integration.discoveryURL.map {
                fm.fileExists(atPath: $0.path)
            } ?? true,
            shimExists: fm.fileExists(atPath: integration.shimURL.path),
            registered: registrationMatches(client, integration: integration, cwd: cwd),
            permissionReady: permission.ready,
            permissionExplicitlyDenied: permission.denied,
            piAdapterReady: piAdapterInstalled())
    }

    private static func manifestExists(_ integration: Integration) -> Bool {
        FileManager.default.fileExists(atPath: integration.manifestURL.path)
    }

    private static func manifestEnabled(_ integration: Integration) -> Bool {
        guard let data = try? BoundedFileReader.data(
                at: integration.manifestURL, maxBytes: 1024 * 1024),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["enabled"] as? Bool ?? true
    }

    @MainActor
    private static func runtimeSubtitle(_ integration: Integration) -> String {
        guard manifestExists(integration) else { return "not installed" }
        guard manifestEnabled(integration) else { return "disabled" }
        guard PluginManager.shared.isPluginRunning(at: integration.directory) else {
            return "installed · not running"
        }
        if integration.discoveryURL != nil,
           integration.discoveryURL.map({
               !FileManager.default.fileExists(atPath: $0.path)
           }) == true {
            return "running · API starting"
        }
        return "running · API ready"
    }

    private static func issues(
        for checks: [Check], client: Client, alreadyRunning: Bool
    ) -> [String] {
        var out: [String] = []
        if !alreadyRunning, resolveExecutable(client.command) == nil {
            out.append("\(client.displayName) is not installed")
        }
        if !client.supportsManagedSetup {
            out.append("MCP setup for \(client.displayName) cannot be verified yet")
        }
        for check in checks {
            let name = check.integration.name
            if !check.installed {
                out.append("\(name) is not installed")
                continue
            }
            if !check.enabled {
                out.append("\(name) is disabled")
            } else if !check.running {
                out.append("\(name) is not running")
            } else if !check.apiReady {
                out.append("\(name) API is not ready")
            }
            if !check.shimExists {
                out.append("\(name) MCP shim is missing")
                continue
            }
            if case .other = client { continue }
            if client == .pi, !check.piAdapterReady {
                out.append("Pi MCP adapter is not installed")
            }
            if !check.registered {
                out.append("\(check.integration.mcpName) is not registered")
            }
            if client == .claude, !check.permissionReady {
                out.append(check.permissionExplicitlyDenied
                    ? "Claude deny rule blocks \(check.integration.mcpName)"
                    : "Claude dontAsk blocks \(check.integration.mcpName)")
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private static func canFix(
        _ checks: [Check], client: Client, alreadyRunning: Bool
    ) -> Bool {
        guard client.supportsManagedSetup,
              alreadyRunning || resolveExecutable(client.command) != nil,
              checks.allSatisfy({
                  $0.installed && $0.shimExists && !$0.permissionExplicitlyDenied
              }) else {
            return false
        }
        if checks.contains(where: { !$0.registered }) && resolveExecutable("node") == nil {
            return false
        }
        if checks.contains(where: { !$0.registered })
            && resolveExecutable(client.command) == nil {
            return false
        }
        return true
    }

    private static func fixDescription(_ checks: [Check], client: Client) -> String {
        var actions: [String] = []
        if checks.contains(where: { !$0.running || !$0.enabled || !$0.apiReady }) {
            actions.append(checks.contains(where: { $0.running && !$0.apiReady })
                ? "restart Extension"
                : "start Extension")
        }
        if client == .pi, checks.contains(where: { !$0.piAdapterReady }) {
            actions.append("install npm:pi-mcp-adapter")
        }
        if checks.contains(where: { !$0.registered }) {
            actions.append(client == .pi ? "write shared MCP config" : "register MCP")
        }
        if client == .claude, checks.contains(where: { !$0.permissionReady }) {
            actions.append("add explicit dontAsk allow rule")
        }
        return actions.isEmpty ? "repair verified configuration" : actions.joined(separator: " · ")
    }

    // MARK: - Repairs

    @MainActor
    private static func fix(
        _ checks: [Check],
        client: Client,
        cwd: String?,
        host: any InlinePanelHost,
        alreadyRunning: Bool,
        reopenDoctor: Bool,
        launch: (() -> Void)?
    ) {
        let panel = presentPanel(in: host, takeFocus: false)
        var plan = ["Repairing \(client.displayName) access:"]
        if checks.contains(where: { !$0.running || !$0.enabled || !$0.apiReady }) {
            plan.append(
                "• enable and start the selected "
                    + "\(ProductIdentity.current.titleName) Extension")
        }
        if client == .pi, checks.contains(where: { !$0.piAdapterReady }) {
            plan.append("• run: pi install npm:pi-mcp-adapter")
        }
        if checks.contains(where: { !$0.registered }) {
            let target = client == .pi
                ? "~/.config/mcp/mcp.json"
                : client == .claude ? "Claude user MCP config" : "Codex user MCP config"
            plan.append("• update \(target)")
        }
        if client == .claude, checks.contains(where: { !$0.permissionReady }) {
            plan.append("• add selected mcp__…__* rules to ~/.claude/settings.json")
        }
        panel.configureText(
            title: "Integration Doctor",
            body: plan.joined(separator: "\n"),
            hint: "updating only the selected MCP and permission entries")

        var immediateErrors: [String] = []
        let restartsExtension = checks.contains {
            !$0.enabled || !$0.running || !$0.apiReady
        }
        for check in checks
        where check.installed && (!check.enabled || !check.running || !check.apiReady) {
            do {
                if check.running && !check.apiReady {
                    try PluginManager.shared.setPluginEnabled(
                        false, at: check.integration.directory)
                }
                try PluginManager.shared.setPluginEnabled(true, at: check.integration.directory)
                panel.appendLine(
                    "\(check.running ? "restarted" : "started") \(check.integration.name) ✓")
            } catch {
                immediateErrors.append(
                    "\(check.integration.name): \(error.localizedDescription)")
            }
        }

        let integrationsToRegister = checks.filter { !$0.registered }.map(\.integration)
        let permissionIntegrations = checks.filter { !$0.permissionReady }.map(\.integration)
        let needsPiAdapter = client == .pi && checks.contains { !$0.piAdapterReady }

        DispatchQueue.global(qos: .userInitiated).async {
            var errors = immediateErrors
            do {
                if needsPiAdapter {
                    try installPiMCPAdapter()
                }
                if !integrationsToRegister.isEmpty {
                    try register(
                        integrationsToRegister, for: client, cwd: cwd)
                }
                if client == .claude, !permissionIntegrations.isEmpty {
                    try addClaudePermissions(
                        permissionIntegrations.map(\.permissionRule))
                }
            } catch {
                errors.append(error.localizedDescription)
            }

            DispatchQueue.main.async {
                if !errors.isEmpty {
                    panel.setBody(
                        "Setup could not be completed:\n"
                        + errors.map { "• \($0)" }.joined(separator: "\n"))
                    panel.setHint("return or esc closes · open Integration Doctor to retry")
                    return
                }

                if alreadyRunning {
                    panel.setBody(
                        "Setup fixed ✓\n\nRestart \(client.displayName) so the running "
                        + "agent reloads its MCP and permission configuration.")
                    panel.setHint("the integration can stay open · return or esc closes")
                    return
                }
                if let launch {
                    panel.setBody("Setup fixed ✓\n\nStarting \(client.displayName)…")
                    panel.setHint("")
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + (restartsExtension ? 0.8 : 0.25)) {
                        dismissPanel(in: host, refocus: false)
                        launch()
                    }
                    return
                }
                if reopenDoctor {
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + (restartsExtension ? 0.8 : 0)) {
                        present(in: host, cwd: cwd)
                    }
                } else {
                    panel.setBody("Setup fixed ✓")
                    panel.setHint("return or esc closes")
                }
            }
        }
    }

    private static func register(
        _ integrations: [Integration], for client: Client, cwd: String?
    ) throws {
        guard let node = resolveExecutable("node") else {
            throw DoctorError(
                "Node.js is required for "
                    + "\(ProductIdentity.current.titleName) MCP shims")
        }
        switch client {
        case .claude:
            guard let executable = resolveExecutable("claude") else {
                throw DoctorError("Claude CLI was not found")
            }
            try backupFileIfPresent(claudeConfigURL)
            for integration in integrations {
                for name in integration.registrationNames {
                    _ = try? run(executable, [
                        "mcp", "remove", name, "-s", "local",
                    ])
                    _ = try? run(executable, [
                        "mcp", "remove", name, "-s", "user",
                    ])
                }
                _ = try run(executable, [
                    "mcp", "add", "--scope", "user", integration.mcpName,
                    "--", node.path, integration.shimURL.path,
                ])
            }
        case .codex:
            guard let executable = resolveExecutable("codex") else {
                throw DoctorError("Codex CLI was not found")
            }
            try backupFileIfPresent(codexConfigURL)
            for integration in integrations {
                for name in integration.registrationNames {
                    _ = try? run(executable, ["mcp", "remove", name])
                }
                _ = try run(executable, [
                    "mcp", "add", integration.mcpName,
                    "--", node.path, integration.shimURL.path,
                ])
            }
        case .pi:
            try addSharedMCPServers(integrations, node: node)
        case .other(let name):
            throw DoctorError(
                "\(ProductIdentity.current.titleName) cannot configure MCP "
                    + "for \(name) yet")
        }
    }

    private static func installPiMCPAdapter() throws {
        guard let executable = resolveExecutable("pi") else {
            throw DoctorError("Pi CLI was not found")
        }
        _ = try run(executable, ["install", "npm:pi-mcp-adapter"])
    }

    // MARK: - Configuration readers

    private static func registrationMatches(
        _ client: Client, integration: Integration, cwd: String?
    ) -> Bool {
        switch client {
        case .claude:
            guard let root = readJSONObject(claudeConfigURL),
                  let servers = root["mcpServers"] as? [String: Any],
                  let server = servers[integration.mcpName] as? [String: Any]
            else { return false }
            return serverPointsToShim(server, shim: integration.shimURL)
        case .codex:
            guard let text = try? BoundedFileReader.utf8String(
                at: codexConfigURL, maxBytes: 16 * 1024 * 1024)
            else { return false }
            return codexRegistrationMatches(
                text, name: integration.mcpName, shim: integration.shimURL.path)
        case .pi:
            return piConfigURLs(cwd: cwd).contains { url in
                guard let root = readJSONObject(url),
                      let servers = root["mcpServers"] as? [String: Any],
                      let server = servers[integration.mcpName] as? [String: Any]
                else { return false }
                return serverPointsToShim(server, shim: integration.shimURL)
            }
        case .other:
            return false
        }
    }

    static func codexRegistrationMatches(
        _ text: String, name: String, shim: String
    ) -> Bool {
        let header = "[mcp_servers.\(name)]"
        guard let start = text.range(of: header) else { return false }
        let tail = text[start.upperBound...]
        let end = tail.range(of: "\n[")?.lowerBound ?? tail.endIndex
        let block = String(tail[..<end])
        return block.contains(shim)
    }

    private static func serverPointsToShim(
        _ server: [String: Any], shim: URL
    ) -> Bool {
        guard let args = server["args"] as? [String] else { return false }
        let expected = shim.standardizedFileURL.path
        return args.contains { raw in
            URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                .standardizedFileURL.path == expected
        }
    }

    private static func claudePermissionState(
        _ integration: Integration, cwd: String?
    ) -> (ready: Bool, denied: Bool) {
        let settings = mergedClaudePermissions(cwd: cwd)
        let denied = settings.deny.contains(integration.permissionRule)
            || settings.deny.contains("mcp__*")
        if denied { return (false, true) }
        guard settings.mode?.lowercased() == "dontask" else { return (true, false) }
        let allowed = settings.allow.contains(integration.permissionRule)
            || settings.allow.contains("mcp__*")
        return (allowed, false)
    }

    private static func mergedClaudePermissions(
        cwd: String?
    ) -> (mode: String?, allow: Set<String>, deny: Set<String>) {
        var urls = [claudeSettingsURL]
        urls.append(contentsOf: nearestClaudeProjectSettings(cwd: cwd))
        var mode: String?
        var allow = Set<String>()
        var deny = Set<String>()
        for url in urls {
            guard let root = readJSONObject(url),
                  let permissions = root["permissions"] as? [String: Any] else { continue }
            if let value = permissions["defaultMode"] as? String { mode = value }
            for value in permissions["allow"] as? [String] ?? [] { allow.insert(value) }
            for value in permissions["deny"] as? [String] ?? [] { deny.insert(value) }
        }
        return (mode, allow, deny)
    }

    private static func nearestClaudeProjectSettings(cwd: String?) -> [URL] {
        guard let cwd, !cwd.isEmpty else { return [] }
        var cursor = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let userHome = home.standardizedFileURL
        while true {
            // ~/.claude/settings.json is already loaded as the global file.
            // A settings.local.json beside it is not a project override for
            // every repository nested somewhere below the user's home.
            if cursor == userHome { break }
            let directory = cursor.appendingPathComponent(".claude", isDirectory: true)
            let normal = directory.appendingPathComponent("settings.json")
            let local = directory.appendingPathComponent("settings.local.json")
            if FileManager.default.fileExists(atPath: normal.path)
                || FileManager.default.fileExists(atPath: local.path) {
                return [normal, local]
            }
            if cursor == root { break }
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor { break }
            cursor = parent
        }
        return []
    }

    private static func piConfigURLs(cwd: String?) -> [URL] {
        var urls = [sharedMCPConfigURL, piGlobalConfigURL]
        if let cwd, !cwd.isEmpty {
            var cursor = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
            let root = URL(fileURLWithPath: "/", isDirectory: true)
            let userHome = home.standardizedFileURL
            while true {
                if cursor == userHome { break }
                let shared = cursor.appendingPathComponent(".mcp.json")
                let pi = cursor.appendingPathComponent(".pi/mcp.json")
                if FileManager.default.fileExists(atPath: shared.path)
                    || FileManager.default.fileExists(atPath: pi.path) {
                    urls += [shared, pi]
                    break
                }
                if cursor == root { break }
                let parent = cursor.deletingLastPathComponent()
                if parent == cursor { break }
                cursor = parent
            }
        }
        return urls
    }

    private static func piAdapterInstalled() -> Bool {
        guard let root = readJSONObject(piSettingsURL) else { return false }
        let packages = root["packages"] as? [Any] ?? []
        for package in packages {
            if let value = package as? String,
               value.lowercased().contains("pi-mcp-adapter") {
                return true
            }
            if let value = package as? [String: Any],
               (value["source"] as? String)?.lowercased()
                    .contains("pi-mcp-adapter") == true {
                return true
            }
        }
        return false
    }

    // MARK: - Configuration writers

    static func addingClaudePermissionRules(
        to root: [String: Any], rules: [String]
    ) -> [String: Any] {
        var updated = root
        var permissions = updated["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        for rule in rules where !allow.contains(rule) { allow.append(rule) }
        permissions["allow"] = allow
        updated["permissions"] = permissions
        return updated
    }

    private static func addClaudePermissions(_ rules: [String]) throws {
        let root: [String: Any]
        if FileManager.default.fileExists(atPath: claudeSettingsURL.path) {
            guard let existing = readJSONObject(claudeSettingsURL) else {
                throw DoctorError("Claude settings JSON is invalid; it was not changed")
            }
            root = existing
        } else {
            root = [:]
        }
        let updated = addingClaudePermissionRules(to: root, rules: rules)
        try writeJSONObject(updated, to: claudeSettingsURL, backup: true)
    }

    private static func addSharedMCPServers(
        _ integrations: [Integration], node: URL
    ) throws {
        let root: [String: Any]
        if FileManager.default.fileExists(atPath: sharedMCPConfigURL.path) {
            guard let existing = readJSONObject(sharedMCPConfigURL) else {
                throw DoctorError("Shared MCP config is invalid; it was not changed")
            }
            root = existing
        } else {
            root = [:]
        }
        var updated = root
        var servers = updated["mcpServers"] as? [String: Any] ?? [:]
        for integration in integrations {
            for name in integration.registrationNames {
                servers.removeValue(forKey: name)
            }
            servers[integration.mcpName] = [
                "command": node.path,
                "args": [integration.shimURL.path],
            ]
        }
        updated["mcpServers"] = servers
        try writeJSONObject(updated, to: sharedMCPConfigURL, backup: true)
    }

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? BoundedFileReader.data(
            at: url, maxBytes: 16 * 1024 * 1024) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeJSONObject(
        _ object: [String: Any], to url: URL, backup: Bool
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backup { try backupFileIfPresent(url) }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func backupFileIfPresent(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let suffix = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent
                + ".\(ProductIdentity.current.slug)-backup-" + suffix)
        try fm.copyItem(at: url, to: backupURL)
    }

    // MARK: - Processes

    private static func resolveExecutable(_ name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let fm = FileManager.default
        for directory in executableSearchDirectories() {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func executableSearchDirectories() -> [String] {
        let homePath = home.path
        var values = [
            "\(homePath)/.local/bin",
            "\(homePath)/.npm-global/bin",
            "\(homePath)/.local/share/mise/shims",
            "\(homePath)/.asdf/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        values += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executableSearchDirectories().joined(separator: ":")
        let result = try ProcessCapture.run(
            executable,
            arguments: arguments,
            environment: environment,
            timeout: 600,
            outputLimit: 1_048_576)
        let output = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.terminationStatus == 0 else {
            throw DoctorError(output.isEmpty
                ? "\(executable.lastPathComponent) exited \(result.terminationStatus)"
                : output)
        }
        return output
    }

    private struct DoctorError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
