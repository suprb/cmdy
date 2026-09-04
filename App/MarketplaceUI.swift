import AppKit
import Darwin
import ProductIdentity
import Security
import CmdyKit

// The marketplace in the terminal: browse = live preview (shaders and themes
// try themselves on as you arrow), ⏎ = keep, esc = everything reverts and
// preview files vanish. Plugins get a consent step — native code.
// The CLI verbs (`cmdy marketplace …`, `cmdy share`) live here too.

/// Panel-session state: what was written to disk for previews, what the user
/// kept, and how to clean up the difference on dismiss.
final class MarketplaceSession {
    let entries: [Marketplace.Entry]
    let sources: [String: Data]
    private var previewShaders: Set<String> = []   // stems written for preview
    private var previewThemes: Set<String> = []
    private var kept: Set<String> = []             // entry ids the user kept

    init(entries: [Marketplace.Entry], sources: [String: Data]) {
        self.entries = entries
        self.sources = sources
    }

    func source(_ entry: Marketplace.Entry) -> String? {
        sources[entry.id].flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Preview = a real install of the file (that's what makes it live),
    /// tracked so dismissal removes everything that wasn't kept.
    func previewShader(_ entry: Marketplace.Entry) {
        guard let src = source(entry),
              let name = try? Marketplace.installShader(entry, source: src) else { return }
        previewShaders.insert(entry.stem)
        Preferences.shared.shaderName = name
    }

    func previewTheme(_ entry: Marketplace.Entry) {
        guard let data = sources[entry.id],
              let name = try? Marketplace.installTheme(entry, json: data) else { return }
        previewThemes.insert(entry.stem)
        Preferences.shared.themeName = name
    }

    /// Rig previews only touch what the panel snapshot can revert.
    func previewRig(_ entry: Marketplace.Entry) {
        guard let src = source(entry) else { return }
        let safe = ["theme", "shader", "font-family", "line-height",
                    "cursor-style", "cursor-blink"]
        let kv = Marketplace.parseRig(src).filter { safe.contains($0.key) }
        ConfigFile.applyValues(kv)
    }

    func keepShader(_ entry: Marketplace.Entry) {
        guard let src = source(entry),
              let name = try? Marketplace.installShader(entry, source: src) else { return }
        kept.insert(entry.id)
        Preferences.shared.shaderName = name
        Notifier.post(title: "marketplace", body: "\(entry.name) installed — shader = user/\(entry.stem)")
    }

    func keepTheme(_ entry: Marketplace.Entry) {
        guard let data = sources[entry.id],
              let name = try? Marketplace.installTheme(entry, json: data) else { return }
        kept.insert(entry.id)
        Preferences.shared.themeName = name
        Notifier.post(title: "marketplace", body: "\(entry.name) installed — theme = \(name)")
    }

    func applyRig(_ entry: Marketplace.Entry) {
        guard let src = source(entry) else { return }
        Marketplace.applyRig(src)
        Notifier.post(title: "marketplace", body: "rig applied: \(entry.name)")
    }

    /// Dismissal: previews that weren't kept disappear again.
    func cleanup() {
        let fm = FileManager.default
        for entry in entries {
            if entry.kind == "shader", previewShaders.contains(entry.stem), !kept.contains(entry.id) {
                try? fm.removeItem(at: UserShaders.directory
                    .appendingPathComponent(entry.stem + ".metal"))
            }
            if entry.kind == "theme", previewThemes.contains(entry.stem), !kept.contains(entry.id) {
                try? fm.removeItem(at: ConfigFile.directory
                    .appendingPathComponent("themes/\(entry.stem).json"))
            }
        }
        if !previewThemes.isEmpty { Theme.reloadUserThemes() }
    }
}

private enum ChannelSetupUIError: LocalizedError {
    case cancelled
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Setup cancelled"
        case .invalid(let message): return message
        }
    }
}

extension AppDelegate {

    /// Persistent setup entry used by Channel Doctor and the Channels manager.
    /// This also covers connectors whose setup was
    /// skipped, so they have no registered Channel runtime yet.
    @objc func configureInstalledChannelConnector(_ sender: Any?) {
        guard let pane = currentController?.focusedPane else { NSSound.beep(); return }
        let panel = pane.presentInlinePanel(takeFocus: true)
        panel.configureText(title: "Channel setup", body: "Loading installed connectors…", hint: "")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let entries = try Marketplace.fetchEntries().filter { entry in
                    guard entry.kind == "channel" else { return false }
                    let directory = PluginManager.pluginsDirectory
                        .appendingPathComponent(entry.folderName)
                    return FileManager.default.fileExists(atPath: directory.path)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    let items = entries.map { entry in
                        let directory = PluginManager.pluginsDirectory
                            .appendingPathComponent(entry.folderName)
                        let status = PluginManager.shared.extensionRuntimeStatus(at: directory)
                        return PaletteItem(
                            title: entry.name,
                            subtitle: "\(entry.setup ?? "No setup described") · \(status.displayText)") {
                                [weak self] in
                                self?.presentChannelConfiguration(
                                    entry, directory: directory, panel: panel)
                            }
                    }
                    if items.isEmpty {
                        panel.configureList(items: [
                            PaletteItem(
                                title: "No installed Channel connectors",
                                subtitle: "Browse the Marketplace to install one"),
                            PaletteItem(title: "Browse Channel Connectors…") {
                                [weak self] in self?.browseMarketplace(nil)
                            },
                        ], placeholder: "", hint: "")
                    } else {
                        panel.configureList(
                            items: items, placeholder: "choose a connector…",
                            hint: "⏎ configure · secrets stay in Keychain",
                            memoryKey: "channel-configuration")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    panel.configureText(
                        title: "Channel setup",
                        body: "Could not load connector setup metadata.\n\(error.localizedDescription)",
                        hint: "The installed connector was not changed.")
                }
            }
        }
    }

    /// Stop before editing configuration, then leave the connector stopped
    /// until its new setup passes a live provider-health test.
    func presentChannelConfiguration(_ entry: Marketplace.Entry,
                                     directory: URL,
                                     panel: InlinePanel? = nil) {
        guard let pane = currentController?.focusedPane else { NSSound.beep(); return }
        let destination = panel ?? pane.presentInlinePanel(takeFocus: true)
        do {
            try PluginManager.shared.setPluginEnabled(false, at: directory)
            presentInstalledChannelSetup(entry, directory: directory, panel: destination)
        } catch {
            destination.configureText(
                title: entry.name,
                body: "Could not enter safe setup mode.\n\(error.localizedDescription)",
                hint: "The connector was not reconfigured.")
        }
    }

    private func channelModeLabel(_ mode: String?) -> String {
        switch mode {
        case "two-way": return "receive + approved replies"
        case "inbound-only": return "receive only"
        case "read-only": return "read only"
        case let value?: return value
        case nil: return "Channel connector"
        }
    }

    @objc func browseMarketplace(_ sender: Any?) {
        guard let pane = currentController?.focusedPane else { NSSound.beep(); return }
        let panel = pane.presentInlinePanel(takeFocus: true)
        panel.configureText(title: "marketplace",
                            body: "Fetching registry…",
                            hint: "")
        DispatchQueue.global().async { [weak self] in
            do {
                let entries = try Marketplace.fetchEntries()
                var sources: [String: Data] = [:]
                for entry in entries where !Marketplace.isExtensionKind(entry.kind) {
                    sources[entry.id] = try? Marketplace.fetchContent(entry)
                }
                DispatchQueue.main.async {
                    MarketplaceUpdateMonitor.shared.refresh(with: entries)
                    self?.presentMarketplace(MarketplaceSession(entries: entries, sources: sources))
                }
            } catch {
                DispatchQueue.main.async {
                    panel.setBody("Could not load the registry.\n\(error.localizedDescription)")
                }
            }
        }
    }

    private func presentMarketplace(_ session: MarketplaceSession) {
        guard let pane = currentController?.focusedPane else { return }

        func mark(_ entry: Marketplace.Entry) -> String {
            switch Marketplace.state(of: entry) {
            case .notInstalled: return ""
            case .installed: return " · installed"
            case .updateAvailable(let v): return " · update \(v) → \(entry.version)"
            }
        }
        func rows(_ kind: String,
                  preview: ((Marketplace.Entry) -> Void)?,
                  keep: @escaping (Marketplace.Entry) -> Void) -> [PaletteItem] {
            session.entries.filter { $0.kind == kind }.map { entry in
                PaletteItem(
                    title: entry.name,
                    subtitle: "\(entry.author) · \(entry.description)\(mark(entry))",
                    action: { keep(entry) },
                    preview: preview.map { p in { p(entry) } })
            }
        }

        let shaders = rows("shader",
                           preview: { [weak session] in session?.previewShader($0) },
                           keep: { [weak session] in session?.keepShader($0) })
        let themes = rows("theme",
                          preview: { [weak session] in session?.previewTheme($0) },
                          keep: { [weak session] in session?.keepTheme($0) })
        let rigs = rows("rig",
                        preview: { [weak session] in session?.previewRig($0) },
                        keep: { [weak session] in session?.applyRig($0) })
        let plugins = session.entries.filter { $0.kind == "plugin" }.map { entry in
            PaletteItem(
                title: entry.name,
                subtitle: "\(entry.author) · \(entry.description)\(mark(entry)) · extension",
                action: { [weak self] in self?.confirmPluginInstall(entry) })
        }
        let channels = session.entries.filter { $0.kind == "channel" }.map { entry in
            let details = [channelModeLabel(entry.channelMode), entry.setup]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return PaletteItem(
                title: entry.name,
                subtitle: "\(entry.author) · \(entry.description)\(mark(entry))"
                    + (details.isEmpty ? "" : " · \(details)"),
                action: { [weak self] in self?.confirmPluginInstall(entry) })
        }

        let root: [PaletteItem] = [
            .section("Shaders", "\(shaders.count) · preview live", shaders),
            .section("Themes", "\(themes.count) · preview live", themes),
            .section("Rigs", "\(rigs.count) · the whole look", rigs),
            .section("Channels", "\(channels.count) · external work connectors", channels),
            .section("Extensions", "\(plugins.count) · native capabilities", plugins),
        ]
        let panel = pane.presentInlinePanel(takeFocus: true)
        marketplaceSession = session
        let previousDismiss = panel.onDismiss
        panel.onDismiss = { [weak self] in
            session.cleanup()
            if self?.marketplaceSession === session { self?.marketplaceSession = nil }
            previousDismiss?()
        }
        panel.configureList(items: root,
                            placeholder: "search the marketplace…",
                            hint: "→ open · ↑↓ preview live · ⏎ install · esc revert",
                            memoryKey: "marketplace")
    }

    /// Native code gets an explicit consent step naming what runs.
    private func confirmPluginInstall(_ entry: Marketplace.Entry) {
        guard let pane = currentController?.focusedPane else { return }
        let panel = pane.presentInlinePanel(takeFocus: true)
        if entry.kind == "channel" {
            let setup = entry.setup ?? "No provider setup described"
            var items: [PaletteItem] = []
            if entry.homepage.flatMap(URL.init(string:)) != nil {
                items.append(PaletteItem(
                    title: "Review Source…",
                    subtitle: "opens the connector project before anything runs") {
                        [weak self] in self?.openMarketplaceSource(entry)
                    })
            }
            items.append(PaletteItem(
                title: "Install & Continue…",
                subtitle: "\(channelModeLabel(entry.channelMode)) · setup: \(setup)") {
                    [weak self] in self?.runPluginInstall(entry)
                })
            items.append(PaletteItem(title: "Cancel"))
            panel.configureList(
                items: items, placeholder: "",
                hint: "pinned archive · native code runs as you · setup remains explicit")
        } else {
            panel.configureList(items: [
                PaletteItem(title: entry.id == BrowserEdition.marketplaceID
                            && BrowserComponentInstaller.currentBundleNeedsBrowserSwitch(
                                requiredBrowserVersion: entry.version)
                            ? "Download & Restart for \(entry.name) \(entry.version)"
                            : "Install \(entry.name) \(entry.version)",
                            subtitle: "by \(entry.author) · native code, runs as you · \(entry.license)",
                            action: { [weak self] in self?.runPluginInstall(entry) }),
                PaletteItem(title: "Cancel", subtitle: ""),
            ], placeholder: "", hint: "extensions run as you — review the source and capabilities")
        }
    }

    private func openMarketplaceSource(_ entry: Marketplace.Entry) {
        guard let raw = entry.homepage, let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func runPluginInstall(_ entry: Marketplace.Entry) {
        guard let pane = currentController?.focusedPane else { return }
        let panel = pane.presentInlinePanel(takeFocus: false)
        panel.configureText(title: "marketplace", body: "installing \(entry.name)…", hint: "")
        let dest = PluginManager.pluginsDirectory.appendingPathComponent(entry.folderName)
        PluginManager.shared.stopPlugin(at: dest)   // release the binary + inode
        DispatchQueue.global().async {
            do {
                let dir = try Marketplace.installPlugin(entry, consented: true) { line in
                    DispatchQueue.main.async { panel.appendLine(line) }
                }
                DispatchQueue.main.async {
                    MarketplaceUpdateMonitor.shared.markInstalled(id: entry.id)
                    if BrowserComponentInstaller.relaunchWasScheduled {
                        panel.appendLine(
                            BrowserComponentInstaller.scheduledDescription
                                ?? "restart required to finish installing Browser")
                        BrowserComponentInstaller.requestRelaunchIfScheduled()
                    } else {
                        Notifier.post(title: "marketplace", body: "\(entry.name) installed")
                    }
                    if entry.kind == "channel" {
                        do {
                            // Installed Channels remain stopped until the user
                            // finishes or explicitly skips the setup step.
                            try PluginManager.shared.setPluginEnabled(false, at: dir)
                            self.presentInstalledChannelSetup(entry, directory: dir, panel: panel)
                        } catch {
                            panel.appendLine("installed, but could not enter safe setup mode: \(error.localizedDescription)")
                        }
                    } else if !BrowserComponentInstaller.relaunchWasScheduled {
                        let launched = PluginManager.shared.launchPlugin(at: dir)
                        let status = PluginManager.shared.extensionRuntimeStatus(at: dir)
                        panel.appendLine(launched
                            ? "installed ✓ · \(status.displayText)"
                            : "installed ✓ (starts with "
                                + ProductIdentity.current.displayName + ")")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    _ = PluginManager.shared.launchPlugin(at: dest)
                    panel.appendLine("failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Prefer explicit registry metadata. Older signed Channel archives can
    /// still offer safe guided setup when their example has no credential-like
    /// keys; this keeps public v1.0 connectors usable without ever guessing how
    /// a token should be stored.
    private func resolvedChannelSetupFields(
        _ entry: Marketplace.Entry, directory: URL
    ) -> [Marketplace.ChannelSetupField] {
        if entry.id != "dev.cmdy.imessage",
           entry.channelConfigurationVersion == 1,
           !entry.channelSetupFields.isEmpty {
            return entry.channelSetupFields
        }
        guard let defaults = try? channelExampleConfiguration(directory),
              !defaults.isEmpty else { return [] }
        let secretMarkers = [
            "token", "secret", "password", "credential", "apikey", "api_key",
            "privatekey", "private_key", "accesskey", "access_key",
        ]
        guard !defaults.keys.contains(where: { key in
            let lower = key.lowercased()
            return secretMarkers.contains(where: lower.contains)
        }) else { return [] }

        let preferred = [
            "enabled", "databasePath", "allowedHandles", "allowedChatGUIDs",
            "sendApprovedReplies", "includeExistingMessages",
            "pollIntervalSeconds", "maxMessagesPerPoll",
        ]
        let rank = Dictionary(uniqueKeysWithValues: preferred.enumerated().map { ($1, $0) })
        return defaults.keys.sorted {
            let left = rank[$0] ?? Int.max
            let right = rank[$1] ?? Int.max
            return left == right ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                : left < right
        }.compactMap { key in
            let value = defaults[key]
            let kind: Marketplace.ChannelSetupFieldKind
            if value is Bool {
                kind = .boolean
            } else if value is NSNumber {
                kind = .integer
            } else if value is String {
                kind = key.lowercased().contains("path") ? .path : .text
            } else if let values = value as? [Any] {
                kind = values.isEmpty || values.allSatisfy({ $0 is String })
                    ? .stringList
                    : values.allSatisfy({ $0 is NSNumber }) ? .integerList : .json
            } else {
                kind = .json
            }
            return Marketplace.ChannelSetupField(
                key: key,
                label: inferredChannelSetupLabel(key),
                kind: kind,
                required: key == "enabled",
                defaultValue: key == "enabled"
                    ? "true" : channelSetupString(value, kind: kind),
                placeholder: inferredChannelSetupPlaceholder(key),
                help: inferredChannelSetupHelp(key))
        }
    }

    private func inferredChannelSetupLabel(_ key: String) -> String {
        let known = [
            "enabled": "Enable Messages access",
            "databasePath": "Messages database",
            "allowedHandles": "Allowed phone numbers or email addresses",
            "allowedChatGUIDs": "Allowed chat GUIDs",
            "sendApprovedReplies": "Allow approved replies",
            "includeExistingMessages": "Include existing messages on first run",
            "pollIntervalSeconds": "Polling interval (seconds)",
            "maxMessagesPerPoll": "Maximum messages per poll",
        ]
        if let label = known[key] { return label }
        var words = ""
        for character in key {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(character)
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func inferredChannelSetupPlaceholder(_ key: String) -> String {
        switch key {
        case "databasePath": return "~/Library/Messages/chat.db"
        case "allowedHandles": return "+46700000000, person@example.com"
        case "allowedChatGUIDs": return "iMessage;-;+46700000000"
        default: return ""
        }
    }

    private func inferredChannelSetupHelp(_ key: String) -> String {
        switch key {
        case "enabled":
            let name = ProductIdentity.current.titleName
            return "Requires Full Disk Access for the \(name) app. "
                + "Restart \(name) after granting it."
        case "allowedHandles":
            return "Only exact allowlisted handles are received. Add a handle here or a chat GUID below."
        case "allowedChatGUIDs":
            return "Optional alternative to handles. At least one of these two allowlists must contain a value."
        case "sendApprovedReplies":
            return "Off by default. When enabled, "
                + "\(ProductIdentity.current.titleName) still sends only replies "
                + "you explicitly approve."
        case "includeExistingMessages":
            return "Off by default so first launch establishes a baseline instead of importing history."
        default: return ""
        }
    }

    private func validateChannelSetupValues(
        _ entry: Marketplace.Entry, values: [String: String]
    ) throws {
        guard entry.id == "dev.cmdy.imessage" else { return }
        let handles = splitChannelSetupList(values["allowedHandles"] ?? "")
        let chats = splitChannelSetupList(values["allowedChatGUIDs"] ?? "")
        guard !handles.isEmpty || !chats.isEmpty else {
            throw ChannelSetupUIError.invalid(
                "Add at least one allowed phone number, email address, or chat GUID. "
                    + "iMessage refuses to run with an empty allowlist.")
        }
    }

    private func openFullDiskAccessSettings() {
        let destinations = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for destination in destinations {
            if let url = URL(string: destination), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func presentInstalledChannelSetup(_ entry: Marketplace.Entry,
                                              directory: URL,
                                              panel: InlinePanel) {
        let example = directory.appendingPathComponent("config.example.json")
        let setupFields = resolvedChannelSetupFields(entry, directory: directory)
        let structured = !setupFields.isEmpty
        var items: [PaletteItem] = []
        if entry.id == "dev.cmdy.imessage" {
            items.append(PaletteItem(
                title: "1. Open Full Disk Access…",
                subtitle: "allow \(ProductIdentity.current.titleName) "
                    + "to read your local Messages database") {
                    [weak self] in self?.openFullDiskAccessSettings()
                })
        }
        if structured {
            items.append(PaletteItem(
                title: entry.id == "dev.cmdy.imessage"
                    ? "2. Configure & Test \(entry.name)…"
                    : "Configure & Test \(entry.name)…",
                subtitle: "save privately · test provider · start only when healthy") {
                    [weak self] in
                    self?.configureInstalledChannel(
                        entry, directory: directory, panel: panel, fields: setupFields)
                })
        } else if !FileManager.default.fileExists(atPath: example.path) {
            items.append(PaletteItem(
                title: "Test & Start \(entry.name)",
                subtitle: "no provider configuration required") { [weak self] in
                    self?.testConfiguredChannel(entry, directory: directory, panel: panel)
                })
        } else {
            items.append(PaletteItem(
                title: "Structured Setup Unavailable",
                subtitle: entry.setup ?? "open the connector folder to configure it manually"))
            items.append(PaletteItem(
                title: "Open Connector Folder…",
                subtitle: "copy config.example.json to config.json; keep secrets in Keychain") {
                    NSWorkspace.shared.open(directory)
                })
        }
        items.append(PaletteItem(
            title: "Skip Setup",
            subtitle: "leave installed and stopped; configure it later in Channels") {
                panel.configureText(
                    title: entry.name,
                    body: "Installed ✓\nSetup skipped. The connector is stopped and no account was contacted.",
                    hint: "open Channels when you are ready")
            })
        if entry.homepage.flatMap(URL.init(string:)) != nil {
            items.append(PaletteItem(title: "Review Source…") { [weak self] in
                self?.openMarketplaceSource(entry)
            })
        }
        panel.configureList(
            items: items, placeholder: "",
            hint: "installed ✓ · configure now or skip safely")
    }

    private func configureInstalledChannel(_ entry: Marketplace.Entry,
                                           directory: URL,
                                           panel: InlinePanel,
                                           fields: [Marketplace.ChannelSetupField]) {
        do {
            let values = try collectChannelSetupValues(
                entry, directory: directory, fields: fields)
            try validateChannelSetupValues(entry, values: values)
            try saveChannelSetup(
                entry, directory: directory, values: values, fields: fields)
            testConfiguredChannel(entry, directory: directory, panel: panel)
        } catch ChannelSetupUIError.cancelled {
            presentInstalledChannelSetup(entry, directory: directory, panel: panel)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not save \(entry.name) setup"
            alert.runModal()
            presentInstalledChannelSetup(entry, directory: directory, panel: panel)
        }
    }

    private func testConfiguredChannel(_ entry: Marketplace.Entry,
                                       directory: URL,
                                       panel: InlinePanel) {
        do {
            try PluginManager.shared.setPluginEnabled(true, at: directory)
            panel.configureText(
                title: entry.name,
                body: "Setup saved ✓\nTesting provider connection…",
                hint: "The connector remains enabled only if it reports healthy.")
            waitForChannelConnectionTest(
                entry, directory: directory, panel: panel, remainingChecks: 40)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not test \(entry.name)"
            alert.runModal()
        }
    }

    private func waitForChannelConnectionTest(_ entry: Marketplace.Entry,
                                              directory: URL,
                                              panel: InlinePanel,
                                              remainingChecks: Int) {
        let runtimes = PluginManager.shared.channelRuntimes.filter {
            $0.extensionID == entry.id
        }
        if let healthy = runtimes.first(where: {
            $0.connected && $0.health.status == .healthy
        }) {
            let account = healthy.channel.account.isEmpty
                ? "provider account verified" : healthy.channel.account
            panel.configureText(
                title: entry.name,
                body: "Setup saved ✓\nConnection healthy ✓\nAccount: \(account)\nConnector enabled ✓",
                hint: "Channels → Channel Doctor shows ongoing health.")
            return
        }

        let process = PluginManager.shared.extensionRuntimeStatus(at: directory)
        if process.phase == .failed || remainingChecks <= 0 {
            try? PluginManager.shared.setPluginEnabled(false, at: directory)
            let provider = runtimes.first?.health
            let detail = provider?.error
                ?? provider?.detail
                ?? process.lastLog
                ?? process.message
                ?? (remainingChecks <= 0
                    ? "The connector did not report healthy within 10 seconds."
                    : process.displayText)
            panel.configureList(items: [
                PaletteItem(title: "Configure Again…", subtitle: detail) {
                    [weak self] in
                    self?.presentInstalledChannelSetup(
                        entry, directory: directory, panel: panel)
                },
                PaletteItem(title: "Open Connector Folder…") {
                    NSWorkspace.shared.open(directory)
                },
                PaletteItem(title: "Leave Stopped", subtitle: "no account polling or replies") {
                    panel.configureText(
                        title: entry.name,
                        body: "Connection test failed.\n\(detail)\n\nThe connector is stopped.",
                        hint: "Run Configure Channel when you are ready to retry.")
                },
            ], placeholder: "", hint: "test failed · connector stopped")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForChannelConnectionTest(
                entry, directory: directory, panel: panel,
                remainingChecks: remainingChecks - 1)
        }
    }

    private func collectChannelSetupValues(
        _ entry: Marketplace.Entry, directory: URL,
        fields: [Marketplace.ChannelSetupField]
    ) throws -> [String: String] {
        let defaults = try channelExampleConfiguration(directory)
        let alert = NSAlert()
        alert.messageText = "Set up \(entry.name)"
        alert.informativeText = "Configuration stays on this Mac. Secret fields are stored in "
            + "macOS Keychain and are never written to config.json. Leave a secret blank to "
            + "keep its existing Keychain value. The test briefly contacts and polls the "
            + "configured provider; it cannot send an unapproved reply."
        alert.addButton(withTitle: "Save & Test")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        var readers: [(Marketplace.ChannelSetupField, () -> String)] = []

        for field in fields {
            let group = NSStackView()
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 4
            let required = field.required ? " *" : ""
            let label = NSTextField(labelWithString: field.label + required)
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize,
                                           weight: .medium)
            group.addArrangedSubview(label)

            let initial = field.defaultValue
                ?? channelSetupString(defaults[field.key], kind: field.kind)
                ?? ""
            switch field.kind {
            case .boolean:
                let checkbox = NSButton(
                    checkboxWithTitle: field.placeholder.isEmpty ? "Enabled" : field.placeholder,
                    target: nil, action: nil)
                checkbox.state = ["true", "1", "yes", "on"].contains(initial.lowercased())
                    ? .on : .off
                checkbox.toolTip = field.help
                group.addArrangedSubview(checkbox)
                readers.append((field, { checkbox.state == .on ? "true" : "false" }))
            case .secret, .text, .integer, .stringList, .integerList, .path, .json:
                let control: NSTextField = field.kind == .secret
                    ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
                control.stringValue = field.kind == .secret ? "" : initial
                if !field.placeholder.isEmpty {
                    control.placeholderString = field.placeholder
                } else {
                    switch field.kind {
                    case .secret:
                        control.placeholderString = field.keychainService.map {
                            channelSecretExists(service: $0)
                                ? "leave blank to keep stored secret"
                                : "stored in Keychain"
                        } ?? "stored in Keychain"
                    case .stringList, .integerList:
                        control.placeholderString = "comma-separated or JSON array"
                    case .json: control.placeholderString = "JSON value"
                    default: break
                    }
                }
                control.toolTip = field.help
                control.widthAnchor.constraint(equalToConstant: 430).isActive = true
                group.addArrangedSubview(control)
                readers.append((field, { control.stringValue }))
            }
            if !field.help.isEmpty {
                let help = NSTextField(wrappingLabelWithString: field.help)
                help.textColor = .secondaryLabelColor
                help.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                help.maximumNumberOfLines = 2
                help.preferredMaxLayoutWidth = 430
                group.addArrangedSubview(help)
            }
            stack.addArrangedSubview(group)
        }

        let estimatedHeight = max(80, fields.reduce(0) {
            $0 + ($1.help.isEmpty ? 54 : 82)
        })
        if estimatedHeight > 460 {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 460))
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            stack.frame = NSRect(x: 0, y: 0, width: 450, height: CGFloat(estimatedHeight))
            scroll.documentView = stack
            alert.accessoryView = scroll
        } else {
            let accessory = NSView(frame: NSRect(
                x: 0, y: 0, width: 460, height: CGFloat(estimatedHeight)))
            accessory.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor),
                stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            ])
            alert.accessoryView = accessory
        }

        guard alert.runModal() == .alertFirstButtonReturn else {
            throw ChannelSetupUIError.cancelled
        }
        var values: [String: String] = [:]
        for (field, read) in readers {
            let value = read()
            guard value.utf8.count <= 64 * 1024 else {
                throw ChannelSetupUIError.invalid("\(field.label) exceeds 64 KiB")
            }
            let keepsStoredSecret = field.kind == .secret
                && field.keychainService.map(channelSecretExists(service:)) == true
            if field.required && field.kind != .boolean && !keepsStoredSecret
                && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ChannelSetupUIError.invalid("\(field.label) is required")
            }
            values[field.key] = value
        }
        return values
    }

    private func channelExampleConfiguration(_ directory: URL) throws -> [String: Any] {
        let url = directory.appendingPathComponent("config.example.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                       .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 1024 * 1024 else {
            throw ChannelSetupUIError.invalid("config.example.json is not a safe bounded file")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChannelSetupUIError.invalid("config.example.json must contain an object")
        }
        return object
    }

    private func channelSetupString(_ value: Any?,
                                    kind: Marketplace.ChannelSetupFieldKind) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let boolean = value as? Bool { return boolean ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return nil
    }

    private func saveChannelSetup(_ entry: Marketplace.Entry,
                                  directory: URL,
                                  values: [String: String],
                                  fields: [Marketplace.ChannelSetupField]) throws {
        var config = try channelExampleConfiguration(directory)
        var secrets: [(service: String, account: String, value: String)] = []
        var services = Set<String>()
        for field in fields {
            let raw = values[field.key] ?? ""
            if field.kind == .secret {
                // Even a legacy example containing an empty token must never
                // copy that key into the generated config.
                config[field.key] = nil
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    if field.required,
                       !(field.keychainService.map(channelSecretExists(service:)) == true) {
                        throw ChannelSetupUIError.invalid("\(field.label) is required")
                    }
                    continue
                }
                guard let service = field.keychainService, !service.isEmpty else {
                    throw ChannelSetupUIError.invalid(
                        "\(field.label) has no declared Keychain service; refusing to store it")
                }
                guard services.insert(service).inserted else {
                    throw ChannelSetupUIError.invalid(
                        "Setup declares Keychain service \(service) more than once")
                }
                secrets.append((service, "\(entry.id).\(field.key)", raw))
                continue
            }
            config[field.key] = try channelSetupJSONValue(raw, field: field)
        }
        if config["enabled"] != nil { config["enabled"] = true }
        guard JSONSerialization.isValidJSONObject(config) else {
            throw ChannelSetupUIError.invalid("Generated config.json is not valid JSON")
        }
        var data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        guard data.count <= 1024 * 1024 else {
            throw ChannelSetupUIError.invalid("Generated config.json exceeds 1 MiB")
        }
        // Commit the non-secret file first. If this fails, no credential has
        // been changed. The connector remains disabled until all setup steps
        // have completed successfully.
        try writePrivateChannelConfig(data, directory: directory)
        do {
            for secret in secrets {
                try storeChannelSecret(secret.value, service: secret.service,
                                       account: secret.account)
            }
        } catch {
            throw ChannelSetupUIError.invalid(
                "config.json was saved, but Keychain setup did not finish. "
                    + "Some secret fields may already be updated; the connector remains stopped. "
                    + "Review the error and run setup again.\n\n\(error.localizedDescription)")
        }
    }

    private func channelSetupJSONValue(_ raw: String,
                                       field: Marketplace.ChannelSetupField) throws -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.kind {
        case .text, .path:
            return raw
        case .boolean:
            if ["true", "1", "yes", "on"].contains(trimmed.lowercased()) { return true }
            if ["false", "0", "no", "off"].contains(trimmed.lowercased()) { return false }
            throw ChannelSetupUIError.invalid("\(field.label) must be true or false")
        case .integer:
            guard let number = Int64(trimmed) else {
                throw ChannelSetupUIError.invalid("\(field.label) must be an integer")
            }
            return number
        case .stringList:
            if trimmed.hasPrefix("[") {
                let value = try channelSetupJSONFragment(trimmed, label: field.label)
                guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else {
                    throw ChannelSetupUIError.invalid("\(field.label) must be a string array")
                }
                if field.required && list.isEmpty {
                    throw ChannelSetupUIError.invalid("\(field.label) requires at least one value")
                }
                return list
            }
            let values = splitChannelSetupList(trimmed)
            if field.required && values.isEmpty {
                throw ChannelSetupUIError.invalid("\(field.label) requires at least one value")
            }
            return values
        case .integerList:
            let parts: [Any]
            if trimmed.hasPrefix("[") {
                guard let list = try channelSetupJSONFragment(
                    trimmed, label: field.label) as? [Any] else {
                    throw ChannelSetupUIError.invalid("\(field.label) must be an integer array")
                }
                parts = list
            } else {
                parts = splitChannelSetupList(trimmed)
            }
            let numbers = try parts.map { value -> Int64 in
                if let number = value as? NSNumber { return number.int64Value }
                guard let number = Int64(String(describing: value)) else {
                    throw ChannelSetupUIError.invalid("\(field.label) contains a non-integer")
                }
                return number
            }
            if field.required && numbers.isEmpty {
                throw ChannelSetupUIError.invalid("\(field.label) requires at least one value")
            }
            return numbers
        case .json:
            return try channelSetupJSONFragment(trimmed, label: field.label)
        case .secret:
            throw ChannelSetupUIError.invalid("Secrets cannot be written to config.json")
        }
    }

    private func splitChannelSetupList(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func channelSetupJSONFragment(_ value: String, label: String) throws -> Any {
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            throw ChannelSetupUIError.invalid("\(label) needs a JSON value")
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ChannelSetupUIError.invalid("\(label) is not valid JSON")
        }
    }

    private func storeChannelSecret(_ value: String,
                                    service: String,
                                    account: String) throws {
        // Connectors intentionally look up credentials by service only. Make
        // that the authoritative unique key so an older item with a different
        // display account can never shadow the newly entered value.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrAccount as String] = account
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String?
            throw ChannelSetupUIError.invalid(
                "Could not store \(service) in Keychain: \(detail ?? "error \(status)")")
        }
    }

    private func channelSecretExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private func writePrivateChannelConfig(_ data: Data, directory: URL) throws {
        let target = directory.appendingPathComponent("config.json")
        let temporary = directory.appendingPathComponent(
            ".config-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            _ = Darwin.unlink(temporary.path)
            throw error
        }
        defer { _ = Darwin.unlink(temporary.path) }
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard Darwin.chmod(target.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            _ = Darwin.fsync(directoryDescriptor)
            _ = Darwin.close(directoryDescriptor)
        }
    }
}

// MARK: - CLI

/// `cmdy marketplace list|install|install-all|update` and `cmdy share` — the same
/// engine, no GUI. Runs before NSApplication exists and exits.
enum MarketplaceCLI {
    private static let identity = ProductIdentity.current

    static func run(_ args: [String]) -> Never {
        var args = args
        var registry: String?
        if let i = args.firstIndex(of: "--registry"), i + 1 < args.count {
            registry = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        let yes = args.contains("--yes")
        args.removeAll { $0 == "--yes" }

        switch args.first {
        case "list", nil:
            list(registry: registry)
        case "install":
            guard args.count >= 2 else {
                die("usage: \(identity.executableName) marketplace install "
                    + "<id> [--yes] [--registry <url>]")
            }
            install(id: args[1], registry: registry, yes: yes)
        case "install-all":
            installAll(registry: registry, yes: yes)
        case "update":
            update(registry: registry, yes: yes)
        default:
            die("usage: \(identity.executableName) marketplace "
                + "list | install <id> | install-all | update")
        }
    }

    private static func entries(_ registry: String?) -> [Marketplace.Entry] {
        do { return try Marketplace.fetchEntries(registry: registry) }
        catch { die("marketplace: \(error.localizedDescription)") }
    }

    private static func list(registry: String?) -> Never {
        let all = entries(registry)
        for kind in ["shader", "theme", "rig", "channel", "plugin"] {
            let group = all.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            print("\(kind)s:")
            for e in group {
                let state: String
                switch Marketplace.state(of: e) {
                case .notInstalled: state = ""
                case .installed: state = "  [installed]"
                case .updateAvailable(let v): state = "  [update \(v) → \(e.version)]"
                }
                print("  \(e.id.padding(toLength: 28, withPad: " ", startingAt: 0))  \(e.description)\(state)")
            }
        }
        exit(0)
    }

    private static func install(id: String, registry: String?, yes: Bool) -> Never {
        guard let entry = entries(registry).first(where: { $0.id == id }) else {
            die("marketplace: no entry '\(id)' — try "
                + "`\(identity.executableName) marketplace list`")
        }
        do {
            switch entry.kind {
            case "shader":
                let data = try Marketplace.fetchContent(entry, registry: registry)
                let name = try Marketplace.installShader(entry, source: String(decoding: data, as: UTF8.self))
                print("installed \(entry.name) — select it with:  shader = \(name)")
            case "theme":
                let data = try Marketplace.fetchContent(entry, registry: registry)
                let name = try Marketplace.installTheme(entry, json: data)
                print("installed \(entry.name) — select it with:  theme = \(name)")
            case "rig":
                let data = try Marketplace.fetchContent(entry, registry: registry)
                Marketplace.applyRig(String(decoding: data, as: UTF8.self))
                print("rig applied: \(entry.name)")
            case "plugin", "channel":
                if !yes {
                    print("\(entry.name) \(entry.version) by \(entry.author) — native code, runs as you.")
                    print("source: \(entry.url ?? entry.file ?? "?")")
                    print("install? [y/N] ", terminator: "")
                    guard readLine()?.lowercased().hasPrefix("y") == true else { die("aborted") }
                }
                let dir = try Marketplace.installPlugin(entry, registry: registry, consented: true) {
                    print("  \($0)")
                }
                if entry.kind == "channel" {
                    try PluginManager.shared.setPluginEnabled(false, at: dir)
                    print("installed to \(dir.path) — stopped until Channels → Configure Installed Channel")
                } else {
                    if BrowserComponentInstaller.relaunchWasScheduled {
                        print("installed activation to \(dir.path)")
                        print(BrowserComponentInstaller.scheduledDescription
                            ?? "restarting to finish installing Browser")
                    } else {
                        print("installed to \(dir.path) — launches with "
                            + "\(identity.displayName) (or toggle in ⇧⌘L)")
                    }
                }
            default:
                die("marketplace: cannot install kind '\(entry.kind)' yet")
            }
            if BrowserComponentInstaller.relaunchWasScheduled {
                MainActor.assumeIsolated {
                    BrowserComponentInstaller.requestRelaunchIfScheduled()
                }
            }
            exit(0)
        } catch {
            die("marketplace: \(error.localizedDescription)")
        }
    }

    private static func installAll(registry: String?, yes: Bool) -> Never {
        let plugins = entries(registry).filter { entry in
            guard Marketplace.isExtensionKind(entry.kind) else { return false }
            if case .installed = Marketplace.state(of: entry) { return false }
            return true
        }.sorted {
            ($0.id == BrowserEdition.marketplaceID ? 1 : 0)
                < ($1.id == BrowserEdition.marketplaceID ? 1 : 0)
        }
        guard !plugins.isEmpty else {
            print("all marketplace extensions are installed")
            exit(0)
        }
        if !yes {
            print("The following Extensions will be installed:")
            plugins.forEach { print("  \($0.name) \($0.version) by \($0.author)") }
            print("Most run as isolated processes under your macOS user.")
            if plugins.contains(where: { $0.id == BrowserEdition.marketplaceID }) {
                print("Browser downloads the notarized Chromium-bearing cmdy build and restarts cmdy last.")
            }
            print("install all? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else { die("aborted") }
        }

        var failures: [String] = []
        for entry in plugins {
            print("installing \(entry.name) \(entry.version)")
            do {
                let dir = try Marketplace.installPlugin(
                    entry, registry: registry, consented: true
                ) { print("  \($0)") }
                if entry.kind == "channel" {
                    try PluginManager.shared.setPluginEnabled(false, at: dir)
                    print("  stopped until guided setup and connection test")
                }
                print("  installed to \(dir.path)")
            } catch {
                let message = "\(entry.name): \(error.localizedDescription)"
                failures.append(message)
                print("  failed: \(error.localizedDescription)")
            }
        }
        if BrowserComponentInstaller.relaunchWasScheduled {
            print(BrowserComponentInstaller.scheduledDescription
                ?? "restarting to finish installing Browser")
            MainActor.assumeIsolated {
                BrowserComponentInstaller.requestRelaunchIfScheduled()
            }
        }
        guard failures.isEmpty else {
            die("marketplace: \(failures.count) extension install\(failures.count == 1 ? "" : "s") failed")
        }
        print("\(plugins.count) extensions installed; enable or disable them in the Extensions panel")
        exit(0)
    }

    private static func update(registry: String?, yes: Bool) -> Never {
        var updated = 0
        for entry in entries(registry) {
            guard case .updateAvailable = Marketplace.state(of: entry) else { continue }
            print("updating \(entry.id) → \(entry.version)")
            do {
                switch entry.kind {
                case "shader":
                    let data = try Marketplace.fetchContent(entry, registry: registry)
                    try Marketplace.installShader(entry, source: String(decoding: data, as: UTF8.self))
                case "theme":
                    let data = try Marketplace.fetchContent(entry, registry: registry)
                    try Marketplace.installTheme(entry, json: data)
                case "plugin", "channel":
                    try Marketplace.installPlugin(entry, registry: registry, consented: yes) { print("  \($0)") }
                default: continue
                }
                updated += 1
            } catch {
                print("  \(entry.id): \(error.localizedDescription)")
            }
        }
        print(updated == 0 ? "everything is current" : "\(updated) updated")
        if BrowserComponentInstaller.relaunchWasScheduled {
            print(BrowserComponentInstaller.scheduledDescription
                ?? "restarting to finish installing Browser")
            MainActor.assumeIsolated {
                BrowserComponentInstaller.requestRelaunchIfScheduled()
            }
        }
        exit(0)
    }

    /// `cmdy share` — publish the current user shader: open a prefilled
    /// new-file PR page on the registry (gh-less, works for anyone).
    static func share() -> Never {
        let name = Preferences.shared.shaderName
        guard name.hasPrefix("user/"), let source = UserShaders.source(named: name) else {
            die("""
            \(ProductIdentity.current.slug) share publishes the CURRENT user shader — none is selected.
            Palette → New User Shader…, make something, then run this again.
            (themes/rigs: PR them at the registry — see MARKETPLACE.md)
            """)
        }
        let stem = String(name.dropFirst("user/".count))
        let repo = Preferences.shared.marketplaceRegistry
            .replacingOccurrences(of: "https://raw.githubusercontent.com/", with: "https://github.com/")
            .replacingOccurrences(of: "/main/registry.json", with: "")
        var comps = URLComponents(string: "\(repo)/new/main")!
        comps.queryItems = [
            URLQueryItem(name: "filename", value: "shaders/YOURNAME/\(stem).metal"),
            URLQueryItem(name: "value", value: source),
        ]
        guard let url = comps.url else { die("could not build the share URL") }
        print("opening PR page for \(name) — set your author folder, add a registry.json entry, submit.")
        NSWorkspace.shared.open(url)
        exit(0)
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
