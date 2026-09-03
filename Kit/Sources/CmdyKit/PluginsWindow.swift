import AppKit
import ProductIdentity

/// The Extensions panel (⌘⇧L, or View ▸ Extensions…): inspect, enable,
/// disable, install, and scaffold isolated extensions.
/// A real settings surface for the platform, not just the config file.
@MainActor
public final class PluginsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = PluginsWindow()
    private static let identity = ProductIdentity.current

    private var window: NSWindow?
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var installAllButton = NSButton(
        title: "Install All…", target: self, action: #selector(installAllPlugins))
    private var rows: [Row] = []
    private var isInstalling = false
    private var isLoadingRegistry = false
    private var marketplaceEntries: [Marketplace.Entry] = []
    private var registryError: String?
    private var runtimeObserver: NSObjectProtocol?

    private override init() {
        super.init()
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: .cmdyExtensionRuntimeChanged,
            object: PluginManager.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.window?.isVisible == true else { return }
                self?.reload()
            }
        }
    }

    deinit {
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
    }

    private enum RowAction {
        case none(String)
        case downloadBrowserEdition
        case download(Marketplace.Entry)
        case update(Marketplace.Entry, installed: String)
    }

    private struct Row {
        let name: String
        let kind: String        // "built-in" or "external"
        let summary: String
        let detail: String
        let guide: CmdyProductGuide
        var enabled: Bool
        let dir: URL?           // external plugins only (for the toggle)
        let builtinId: String?  // built-in plugins (for the toggle)
        let sourceURL: URL?
        let marketplaceEntry: Marketplace.Entry?
        let canToggle: Bool
        let action: RowAction
    }

    public func show() {
        let w = ensureWindow()
        reload()
        loadMarketplace()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Data

    private func reload() {
        rows.removeAll()
        let marketplacePlugins = marketplaceEntries.filter { $0.kind == "plugin" }
        let browserDistribution = PluginManager.shared.hostComponentDistribution(
            BrowserEdition.hostComponentIdentifier)
        var hasExternalBrowser = false
        var matchedMarketplaceIDs = Set<String>()
        // Built-in plugins.
        for type in PluginManager.builtins {
            let on = Preferences.shared.isPluginEnabled(type.id)
            rows.append(Row(name: type.displayName, kind: "built-in",
                            summary: "Built into \(Self.identity.titleName)", detail: type.id,
                            guide: CmdyProductGuide(
                                whatItDoes: [
                                    "A built-in \(Self.identity.titleName) feature.",
                                ],
                                safety: [
                                    "It is part of the signed \(Self.identity.titleName) app and does not launch an external process.",
                                ],
                                setup: ["Use the Enabled switch to show or hide it."]), enabled: on,
                            dir: nil, builtinId: type.id, sourceURL: nil,
                            marketplaceEntry: nil, canToggle: true,
                            action: .none("Built in")))
        }
        // Installed extensions in ~/.config/cmdy/extensions/.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: PluginManager.pluginsDirectory, includingPropertiesForKeys: nil) {
            for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let manifest = try? ExtensionManifest.load(from: dir) else { continue }
                // Channel connectors share the process sandbox but have their
                // own manager and must not be presented as Extensions.
                guard !manifest.allows(.channels) else { continue }
                let isBrowser = manifest.hostComponent
                    == BrowserEdition.hostComponentIdentifier
                if isBrowser {
                    hasExternalBrowser = true
                    // A Browser-edition app owns its sealed Chromium runtime.
                    // Do not expose a stale legacy Extension copy as removable.
                    if browserDistribution == .bundled { continue }
                }
                let name = manifest.name
                let enabled = manifest.enabled
                let runtime = PluginManager.shared.extensionRuntimeStatus(at: dir)
                let grant = manifest.isLegacy ? "legacy full access"
                    : "\(manifest.capabilities.count) capabilities"
                let marketplaceEntry = marketplacePlugins.first {
                    $0.id == manifest.id || $0.folderName == dir.lastPathComponent
                }
                if let marketplaceEntry { matchedMarketplaceIDs.insert(marketplaceEntry.id) }
                let action: RowAction
                var installedVersion = manifest.version
                if isBrowser {
                    // Legacy local Browser installs remain manageable, while
                    // this action provides their supported signed-edition
                    // upgrade path now that Browser is no longer in Marketplace.
                    action = .downloadBrowserEdition
                } else if let entry = marketplaceEntry {
                    switch Marketplace.state(of: entry) {
                    case .notInstalled:
                        action = .download(entry)
                    case .installed(let version):
                        action = .none("Up to date")
                        installedVersion = version
                    case .updateAvailable(let installed):
                        action = .update(entry, installed: installed)
                        installedVersion = installed
                    }
                } else {
                    action = .none(manifest.isLegacy ? "Legacy" : "Local")
                }
                let summary = marketplaceEntry?.description
                    ?? manifest.description
                    ?? "Local Extension"
                let creator = marketplaceEntry.map {
                    Self.isHostAuthor($0.author)
                        ? Self.identity.titleName : $0.author
                }
                let creatorDetail = creator.map { "by \($0) · " } ?? ""
                let sourceURL = marketplaceEntry.flatMap(Self.sourceURL(for:))
                    ?? Self.webURL(manifest.homepage)
                rows.append(Row(name: name, kind: "installed",
                                summary: summary,
                                detail: "\(creatorDetail)v\(installedVersion) · \(grant) · \(runtime.phase.rawValue.capitalized)",
                                guide: marketplaceEntry?.guide ?? manifest.guide ?? .localExtension(
                                    name: name, description: summary,
                                    capabilities: manifest.capabilities.map(\.rawValue),
                                    channel: false),
                                enabled: enabled,
                                dir: dir, builtinId: nil, sourceURL: sourceURL,
                                marketplaceEntry: marketplaceEntry, canToggle: true,
                                action: action))
            }
        }
        for entry in marketplacePlugins where !matchedMarketplaceIDs.contains(entry.id) {
            rows.append(Row(
                name: entry.name,
                kind: "available",
                summary: entry.description,
                detail: "by \(Self.isHostAuthor(entry.author) ? Self.identity.titleName : entry.author) · v\(entry.version) · available",
                guide: entry.guide,
                enabled: false,
                dir: nil,
                builtinId: nil,
                sourceURL: Self.sourceURL(for: entry),
                marketplaceEntry: entry,
                canToggle: false,
                action: .download(entry)
            ))
        }
        switch BrowserEdition.rowState(
            distribution: browserDistribution,
            hasExternalInstall: hasExternalBrowser
        ) {
        case .included:
            rows.append(browserEditionRow(installed: true))
        case .notInstalled:
            rows.append(browserEditionRow(installed: false))
        case nil:
            break
        }
        rows.sort {
            if $0.kind == "built-in" && $1.kind != "built-in" { return true }
            if $0.kind != "built-in" && $1.kind == "built-in" { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        table.reloadData()

        let extCount = rows.filter { $0.kind == "installed" }.count
        if isLoadingRegistry {
            statusLabel.stringValue = "Loading extension registry…"
        } else if let registryError {
            statusLabel.stringValue = "Extension registry unavailable · \(registryError)"
        } else {
            let available = rows.filter {
                switch $0.action {
                case .download, .update, .downloadBrowserEdition: return true
                case .none: return false
                }
            }.count
            let suffix = available > 0
                ? " · \(available) ready to download or update"
                : " · all extensions are current"
            statusLabel.stringValue = "\(extCount) installed\(suffix)"
        }
    }

    private func browserEditionRow(installed: Bool) -> Row {
        Row(
            name: "Browser",
            kind: "edition",
            summary: installed
                ? "Web browsing is included in this signed app edition."
                : "Web browsing inside cmdy; available in the signed Browser edition.",
            detail: installed
                ? "Browser edition · installed"
                : "Browser edition · not installed",
            guide: BrowserEdition.guide,
            enabled: installed,
            dir: nil,
            builtinId: nil,
            sourceURL: nil,
            marketplaceEntry: nil,
            canToggle: false,
            action: installed ? .none("Included") : .downloadBrowserEdition)
    }

    /// Assembled-app test seam for the exact native Extensions row.
    public func browserEditionDiagnosticForTesting() -> (
        count: Int, detail: String?, action: String?, canToggle: Bool?
    ) {
        _ = ensureWindow()
        reload()
        let browserRows = rows.filter {
            $0.name.caseInsensitiveCompare("Browser") == .orderedSame
        }
        let row = browserRows.first
        let action: String?
        switch row?.action {
        case .some(.downloadBrowserEdition): action = "Download Edition"
        case .some(.none(let label)): action = label
        case .some(.download): action = "Download"
        case .some(.update): action = "Update"
        case nil: action = nil
        }
        return (browserRows.count, row?.detail, action, row?.canToggle)
    }

    /// Activates the same row action as its visible native button.
    @discardableResult
    public func triggerBrowserEditionDownloadForTesting() -> Bool {
        reload()
        guard let index = rows.firstIndex(where: {
            if case .downloadBrowserEdition = $0.action { return true }
            return false
        }) else { return false }
        let sender = NSButton()
        sender.tag = index
        installRow(sender)
        return true
    }

    private static func webURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    private static func sourceURL(for entry: Marketplace.Entry) -> URL? {
        if let homepage = webURL(entry.homepage) { return homepage }
        if isHostAuthor(entry.author) {
            return URL(
                string: "https://github.com/\(identity.githubRepository)/tree/main/Plugins/\(entry.folderName)")
        }
        guard let asset = webURL(entry.url), asset.host?.lowercased() == "github.com" else {
            return nil
        }
        let parts = asset.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
    }

    private static func isHostAuthor(_ author: String) -> Bool {
        ([identity.name, identity.titleName] + identity.legacyNames).contains {
            author.caseInsensitiveCompare($0) == .orderedSame
        }
    }

    private func loadMarketplace() {
        guard !isLoadingRegistry else { return }
        isLoadingRegistry = true
        registryError = nil
        reload()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let entries = try Marketplace.fetchEntries().filter { $0.kind == "plugin" }
                DispatchQueue.main.async {
                    self?.marketplaceEntries = entries
                    self?.isLoadingRegistry = false
                    MarketplaceUpdateMonitor.shared.refresh(with: entries)
                    self?.reload()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isLoadingRegistry = false
                    self?.registryError = error.localizedDescription
                    self?.reload()
                }
            }
        }
    }

    // MARK: - Window

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Extensions"
        w.minSize = NSSize(width: 720, height: 460)
        w.center()
        w.isReleasedWhenClosed = false

        let root = NSView(frame: w.contentView!.bounds)
        root.autoresizingMask = [.width, .height]

        let intro = NSTextField(labelWithString:
            "Add focused capabilities to \(Self.identity.titleName). Review what each Extension does before enabling it.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.translatesAutoresizingMaskIntoConstraints = false

        let list = CmdyInsetListView()
        list.translatesAutoresizingMaskIntoConstraints = false

        let scroll = CmdyTableScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 72
        table.dataSource = self
        table.delegate = self
        table.autoresizingMask = [.width]
        let nameCol = NSTableColumn(identifier: .init("name")); nameCol.width = 406
        nameCol.resizingMask = .autoresizingMask
        let stateCol = NSTableColumn(identifier: .init("state")); stateCol.width = 84
        stateCol.resizingMask = []
        let actionCol = NSTableColumn(identifier: .init("action")); actionCol.width = 230
        actionCol.resizingMask = []
        table.addTableColumn(nameCol)
        table.addTableColumn(stateCol)
        table.addTableColumn(actionCol)
        scroll.documentView = table

        list.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: list.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor),
        ])

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let makeButton = { (title: String, action: Selector) -> NSButton in
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        let createBtn = makeButton("New Extension…", #selector(createSample))
        let guideBtn = makeButton("Author Guide", #selector(openGuide))
        let folderBtn = makeButton("Open Folder", #selector(openFolder))
        installAllButton.bezelStyle = .rounded
        installAllButton.controlSize = .small
        installAllButton.image = nil
        installAllButton.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [installAllButton, createBtn, guideBtn, folderBtn])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(intro)
        root.addSubview(list)
        root.addSubview(statusLabel)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            intro.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            list.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 16),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            list.bottomAnchor.constraint(equalTo: stack.topAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            statusLabel.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        w.contentView = root
        window = w
        return w
    }

    @objc private func createSample() { PluginManager.shared.createSamplePlugin(); reload() }
    @objc private func openGuide() { PluginManager.shared.openAuthorGuide() }
    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: PluginManager.extensionsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PluginManager.extensionsDirectory)
    }

    @objc private func installAllPlugins() {
        guard !isInstalling else { return }
        isInstalling = true
        installAllButton.isEnabled = false
        statusLabel.stringValue = "Loading the extension registry…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let plugins = try Marketplace.fetchEntries().filter { $0.kind == "plugin" }
                DispatchQueue.main.async { self?.confirmInstallAll(plugins) }
            } catch {
                DispatchQueue.main.async { self?.finishInstallAll(error: error) }
            }
        }
    }

    private func confirmInstallAll(_ plugins: [Marketplace.Entry]) {
        let pending = plugins.filter {
            if case .installed = Marketplace.state(of: $0) { return false }
            return true
        }
        guard !pending.isEmpty else {
            isInstalling = false
            installAllButton.isEnabled = true
            reload()
            let alert = NSAlert()
            alert.messageText = "All marketplace extensions are installed"
            alert.informativeText = "Use the Enabled switches to start or stop them immediately."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Install \(pending.count) extension\(pending.count == 1 ? "" : "s")?"
        alert.informativeText = pending.map(\.name).joined(separator: ", ")
            + "\n\nExtensions are isolated native processes and run as your macOS user. Review their capabilities before installing."
        alert.addButton(withTitle: "Install All")
        alert.addButton(withTitle: "Cancel")
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { performInstallAll(pending) }
            else { cancelInstallAll() }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.performInstallAll(pending) }
            else { self?.cancelInstallAll() }
        }
    }

    private func performInstallAll(_ plugins: [Marketplace.Entry]) {
        statusLabel.stringValue = "Installing \(plugins.count) extension\(plugins.count == 1 ? "" : "s")…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            for (index, entry) in plugins.enumerated() {
                let dest = PluginManager.pluginsDirectory.appendingPathComponent(entry.folderName)
                DispatchQueue.main.sync {
                    self?.statusLabel.stringValue = "Installing \(entry.name) (\(index + 1)/\(plugins.count))…"
                    PluginManager.shared.stopPlugin(at: dest)
                }
                do {
                    let dir = try Marketplace.installPlugin(entry, consented: true) { line in
                        DispatchQueue.main.async {
                            self?.statusLabel.stringValue = "\(entry.name): \(line)"
                        }
                    }
                    DispatchQueue.main.sync {
                        _ = PluginManager.shared.launchPlugin(at: dir)
                        MarketplaceUpdateMonitor.shared.markInstalled(id: entry.id)
                    }
                } catch {
                    DispatchQueue.main.sync { _ = PluginManager.shared.launchPlugin(at: dest) }
                    failures.append("\(entry.name): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { self?.finishInstallAll(failures: failures) }
        }
    }

    private func cancelInstallAll() {
        isInstalling = false
        installAllButton.isEnabled = true
        reload()
    }

    private func finishInstallAll(error: Error) {
        finishInstallAll(failures: [error.localizedDescription])
    }

    private func finishInstallAll(failures: [String]) {
        isInstalling = false
        installAllButton.isEnabled = true
        reload()
        let alert = NSAlert()
        alert.messageText = failures.isEmpty ? "Extensions installed" : "Some extensions could not be installed"
        alert.informativeText = failures.isEmpty
            ? "Extensions are running."
            : failures.joined(separator: "\n")
        alert.runModal()
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CmdyManagementRowView()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        if tableColumn?.identifier.rawValue == "state" {
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(toggleRow(_:))
            toggle.state = r.enabled ? .on : .off
            toggle.isEnabled = r.canToggle && !isInstalling
            toggle.tag = row
            toggle.toolTip = r.enabled ? "Disable \(r.name)" : "Enable \(r.name)"
            toggle.setAccessibilityLabel("Enable \(r.name)")
            let container = NSView()
            toggle.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(toggle)
            NSLayoutConstraint.activate([
                toggle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }
        if tableColumn?.identifier.rawValue == "action" {
            return managementView(for: r, row: row)
        }
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: r.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let summary = NSTextField(labelWithString: r.summary)
        summary.font = .systemFont(ofSize: 11.5)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(labelWithString: r.detail)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title)
        cell.addSubview(summary)
        cell.addSubview(detail)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 9),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            summary.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            detail.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 2),
        ])
        return cell
    }

    private func managementView(for row: Row, row index: Int) -> NSView {
        let primary: NSView
        switch row.action {
        case .none(let label):
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 10)
            text.textColor = .secondaryLabelColor
            text.alignment = .left
            primary = text
        case .download:
            primary = actionButton(title: "Download", row: index)
        case .downloadBrowserEdition:
            primary = actionButton(title: "Download Edition", row: index)
        case .update:
            primary = actionButton(title: "Update", row: index)
        }

        var views = [primary]
        let details = NSButton(title: "Details", target: self, action: #selector(showRowGuide(_:)))
        details.bezelStyle = .inline
        details.controlSize = .small
        details.tag = index
        details.toolTip = "What \(row.name) does, its safety boundaries, and setup"
        views.append(details)
        if let more = overflowButton(for: row, index: index) { views.append(more) }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func overflowButton(for row: Row, index: Int) -> NSPopUpButton? {
        guard row.sourceURL != nil || row.dir != nil else { return nil }
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .small
        button.bezelStyle = .inline
        let menu = NSMenu()
        menu.addItem(withTitle: "More", action: nil, keyEquivalent: "")
        if row.sourceURL != nil {
            let source = NSMenuItem(
                title: "View Source", action: #selector(openRowSourceFromMenu(_:)), keyEquivalent: "")
            source.target = self
            source.tag = index
            menu.addItem(source)
        }
        if row.dir != nil {
            let remove = NSMenuItem(
                title: "Remove Extension…", action: #selector(removeRowFromMenu(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = index
            remove.isEnabled = !isInstalling
            menu.addItem(remove)
        }
        button.menu = menu
        button.toolTip = "More actions for \(row.name)"
        button.setAccessibilityLabel("More actions for \(row.name)")
        return button
    }

    @objc private func openRowSourceFromMenu(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag), let url = rows[sender.tag].sourceURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showRowGuide(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]
        CmdyProductGuidePresenter.shared.show(
            title: row.name,
            category: row.kind == "edition"
                ? "Browser Edition"
                : (row.kind == "available" ? "Available Extension" : "Extension"),
            summary: row.summary,
            guide: row.guide,
            relativeTo: window)
    }

    private func actionButton(title: String, row: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(installRow(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = row
        button.isEnabled = !isInstalling
        return button
    }

    @objc private func installRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), !isInstalling else { return }
        let row = rows[sender.tag]
        let entry: Marketplace.Entry
        let verb: String
        switch row.action {
        case .download(let candidate): entry = candidate; verb = "Download"
        case .update(let candidate, _): entry = candidate; verb = "Update"
        case .downloadBrowserEdition:
            BrowserEditionInstaller.presentDownloadPrompt(relativeTo: window)
            return
        case .none: return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(verb) \(entry.name) \(entry.version)?"
        alert.informativeText = entry.guide.plainText
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        let proceed = { [weak self] in self?.performRowInstall(entry, previousRow: row) }
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { proceed() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            proceed()
        }
    }

    @objc private func removeRowFromMenu(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag), !isInstalling else { return }
        let row = rows[sender.tag]
        guard row.builtinId == nil, let dir = row.dir else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(row.name)?"
        alert.informativeText = "This stops the Extension and removes its installed files. "
            + "You can download marketplace Extensions again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let proceed = { [weak self] in self?.performRowRemoval(row, at: dir) }
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { proceed() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            proceed()
        }
    }

    private func performRowRemoval(_ row: Row, at dir: URL) {
        guard !isInstalling else { return }
        isInstalling = true
        installAllButton.isEnabled = false
        PluginManager.shared.stopPlugin(at: dir)
        reload()
        statusLabel.stringValue = "Removing \(row.name)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FileManager.default.removeItem(at: dir) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isInstalling = false
                self.installAllButton.isEnabled = true
                if case .failure = result, row.enabled {
                    _ = PluginManager.shared.launchPlugin(at: dir)
                }
                self.reload()
                switch result {
                case .success:
                    self.statusLabel.stringValue = "\(row.name) removed"
                case .failure(let error):
                    let failure = NSAlert()
                    failure.alertStyle = .warning
                    failure.messageText = "Could not remove \(row.name)"
                    failure.informativeText = error.localizedDescription
                    if let window = self.window { failure.beginSheetModal(for: window) }
                    else { failure.runModal() }
                }
            }
        }
    }

    private func performRowInstall(_ entry: Marketplace.Entry, previousRow: Row) {
        guard !isInstalling else { return }
        isInstalling = true
        installAllButton.isEnabled = false
        reload()
        let dest = PluginManager.pluginsDirectory.appendingPathComponent(entry.folderName)
        let wasInstalled = previousRow.dir != nil
        let shouldEnable = wasInstalled ? previousRow.enabled : true
        statusLabel.stringValue = "\(wasInstalled ? "Updating" : "Downloading") \(entry.name)…"
        PluginManager.shared.stopPlugin(at: dest)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let dir = try Marketplace.installPlugin(entry, consented: true) { line in
                    DispatchQueue.main.async { self?.statusLabel.stringValue = "\(entry.name): \(line)" }
                }
                DispatchQueue.main.sync {
                    if shouldEnable {
                        _ = PluginManager.shared.launchPlugin(at: dir)
                    } else {
                        try? PluginManager.shared.setPluginEnabled(false, at: dir)
                    }
                }
                DispatchQueue.main.async {
                    self?.finishRowInstall(entry: entry, error: nil)
                }
            } catch {
                DispatchQueue.main.sync {
                    if wasInstalled { _ = PluginManager.shared.launchPlugin(at: dest) }
                }
                DispatchQueue.main.async {
                    self?.finishRowInstall(entry: entry, error: error)
                }
            }
        }
    }

    private func finishRowInstall(entry: Marketplace.Entry, error: Error?) {
        isInstalling = false
        installAllButton.isEnabled = true
        if error == nil { MarketplaceUpdateMonitor.shared.markInstalled(id: entry.id) }
        reload()
        let alert = NSAlert()
        alert.messageText = error == nil ? "\(entry.name) is current" : "Could not install \(entry.name)"
        alert.informativeText = error?.localizedDescription
            ?? "Version \(entry.version) is installed\(rows.first(where: { $0.name == entry.name })?.enabled == true ? " and running" : "")."
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    /// Flip a plugin's enabled state. External process changes are immediate.
    @objc private func toggleRow(_ sender: NSSwitch) {
        guard rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]
        let on = (sender.state == .on)
        if let id = row.builtinId {
            Preferences.shared.setPlugin(id, enabled: on)
        } else if let dir = row.dir {
            do {
                try PluginManager.shared.setPluginEnabled(on, at: dir)
            } catch {
                sender.state = on ? .off : .on
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window) }
                else { alert.runModal() }
            }
        }
        reload()
    }
}
