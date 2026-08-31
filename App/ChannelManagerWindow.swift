import AppKit
import CmdyKit

/// Channel connectors are distributed through the marketplace and execute in
/// the capability-scoped Extension host, but they are a distinct user concept.
/// This window owns their install/configure/test/lifecycle surface so they do
/// not leak into the Extensions manager.
@MainActor
final class ChannelManagerWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ChannelManagerWindow()

    var configureHandler: ((Marketplace.Entry, URL) -> Void)?

    private enum Action {
        case none(String)
        case install(Marketplace.Entry)
        case update(Marketplace.Entry)
    }

    private struct Row {
        let name: String
        let summary: String
        let detail: String
        let guide: CmdyProductGuide
        let entry: Marketplace.Entry?
        let directory: URL?
        let sourceURL: URL?
        let enabled: Bool
        let action: Action
    }

    private var window: NSWindow?
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var refreshButton: NSButton!
    private var rows: [Row] = []
    private var entries: [Marketplace.Entry] = []
    private var registryError: String?
    private var isBusy = false
    private var isLoading = false
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
                self?.rebuildRows()
            }
        }
    }

    deinit {
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
    }

    func show() {
        let window = ensureWindow()
        rebuildRows()
        refreshRegistry()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Data

    private func rebuildRows() {
        var next: [Row] = []
        var matched = Set<String>()

        if let directories = try? FileManager.default.contentsOfDirectory(
            at: PluginManager.pluginsDirectory, includingPropertiesForKeys: nil) {
            for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let manifest = try? ExtensionManifest.load(from: directory),
                      manifest.allows(.channels) else { continue }
                let entry = entries.first {
                    $0.id == manifest.id || $0.folderName == directory.lastPathComponent
                }
                if let entry { matched.insert(entry.id) }
                let runtime = PluginManager.shared.extensionRuntimeStatus(at: directory)
                let action: Action
                if let entry {
                    switch Marketplace.state(of: entry) {
                    case .updateAvailable: action = .update(entry)
                    case .installed, .notInstalled: action = .none("Installed")
                    }
                } else {
                    action = .none("Local")
                }
                let mode = channelModeLabel(entry?.channelMode)
                let setup = entry?.setup.flatMap { $0.isEmpty ? nil : $0 }
                let description = entry?.description
                    ?? manifest.description
                    ?? "Local Channel connector"
                next.append(Row(
                    name: entry?.name ?? manifest.name,
                    summary: description,
                    detail: [mode, setup, runtime.phase.rawValue.capitalized].compactMap { $0 }
                        .joined(separator: " · "),
                    guide: entry?.guide ?? manifest.guide ?? .localExtension(
                        name: manifest.name, description: description,
                        capabilities: manifest.capabilities.map(\.rawValue), channel: true),
                    entry: entry,
                    directory: directory,
                    sourceURL: entry.flatMap(sourceURL),
                    enabled: manifest.enabled,
                    action: action))
            }
        }

        for entry in entries where !matched.contains(entry.id) {
            next.append(Row(
                name: entry.name,
                summary: entry.description,
                detail: [channelModeLabel(entry.channelMode), entry.setup, "v\(entry.version)"]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                guide: entry.guide,
                entry: entry,
                directory: nil,
                sourceURL: sourceURL(entry),
                enabled: false,
                action: .install(entry)))
        }

        rows = next.sorted {
            if ($0.directory != nil) != ($1.directory != nil) { return $0.directory != nil }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        table.reloadData()
        refreshButton?.isEnabled = !isLoading && !isBusy

        let installed = rows.filter { $0.directory != nil }.count
        let available = rows.count - installed
        if isLoading {
            statusLabel.stringValue = "Loading Channel registry…"
        } else if let registryError {
            statusLabel.stringValue = "Channel registry unavailable · \(registryError)"
        } else {
            statusLabel.stringValue = "\(installed) installed · \(available) available · connections are tested before they start"
        }
    }

    private func refreshRegistry() {
        guard !isLoading, !isBusy else { return }
        isLoading = true
        registryError = nil
        rebuildRows()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let channels = try Marketplace.fetchEntries().filter { $0.kind == "channel" }
                DispatchQueue.main.async {
                    self?.entries = channels
                    self?.isLoading = false
                    MarketplaceUpdateMonitor.shared.refresh(with: channels)
                    self?.rebuildRows()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isLoading = false
                    self?.registryError = error.localizedDescription
                    self?.rebuildRows()
                }
            }
        }
    }

    private func channelModeLabel(_ mode: String?) -> String {
        switch mode {
        case "two-way": return "receive + approved replies"
        case "inbound-only": return "receive only"
        case "read-only": return "read only"
        case let mode? where !mode.isEmpty: return mode
        default: return "Channel connector"
        }
    }

    private func sourceURL(_ entry: Marketplace.Entry) -> URL? {
        guard let raw = entry.homepage, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    // MARK: - Window

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Channels"
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.isReleasedWhenClosed = false

        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]

        let intro = NSTextField(labelWithString:
            "Connect external work to one reviewed Inbox. Replies are sent only after approval.")
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
        let channel = NSTableColumn(identifier: .init("channel"))
        channel.width = 406
        channel.resizingMask = .autoresizingMask
        let state = NSTableColumn(identifier: .init("state"))
        state.width = 84
        state.resizingMask = []
        let manage = NSTableColumn(identifier: .init("manage"))
        manage.width = 230
        manage.resizingMask = []
        table.addTableColumn(channel)
        table.addTableColumn(state)
        table.addTableColumn(manage)
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

        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPressed))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.image = nil
        let folder = NSButton(title: "Open Folder", target: self, action: #selector(openFolder))
        folder.bezelStyle = .rounded
        folder.controlSize = .small
        let stack = NSStackView(views: [refreshButton, folder])
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
        window.contentView = root
        self.window = window
        return window
    }

    @objc private func refreshPressed() { refreshRegistry() }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(
            at: PluginManager.extensionsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PluginManager.extensionsDirectory)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CmdyManagementRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rowValue = rows[row]
        switch tableColumn?.identifier.rawValue {
        case "state":
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(toggleRow(_:))
            toggle.state = rowValue.enabled ? .on : .off
            toggle.isEnabled = rowValue.directory != nil && rowValue.entry != nil && !isBusy
            toggle.tag = row
            toggle.toolTip = rowValue.enabled ? "Stop connector" : "Configure, test, and start connector"
            toggle.setAccessibilityLabel("Enable \(rowValue.name)")
            let container = NSView()
            toggle.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(toggle)
            NSLayoutConstraint.activate([
                toggle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        case "manage":
            return managementView(rowValue, index: row)
        default:
            let cell = NSTableCellView()
            let title = NSTextField(labelWithString: rowValue.name)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let summary = NSTextField(labelWithString: rowValue.summary)
            summary.font = .systemFont(ofSize: 11.5)
            summary.textColor = .secondaryLabelColor
            summary.lineBreakMode = .byTruncatingTail
            let detail = NSTextField(labelWithString: rowValue.detail)
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .tertiaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            for view in [title, summary, detail] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
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
    }

    private func managementView(_ row: Row, index: Int) -> NSView {
        var views: [NSView] = []
        var configureIsPrimary = false
        switch row.action {
        case .install:
            views.append(actionButton("Install", index: index))
        case .update:
            views.append(actionButton("Update", index: index))
        case .none(let label):
            if row.directory != nil, row.entry != nil {
                let configure = NSButton(
                    title: "Configure", target: self, action: #selector(configureRow(_:)))
                configure.bezelStyle = .rounded
                configure.controlSize = .small
                configure.tag = index
                configure.isEnabled = !isBusy
                views.append(configure)
                configureIsPrimary = true
            } else {
                let status = NSTextField(labelWithString: label)
                status.font = .systemFont(ofSize: 10)
                status.textColor = .secondaryLabelColor
                views.append(status)
            }
        }
        let details = NSButton(title: "Details", target: self, action: #selector(showRowGuide(_:)))
        details.bezelStyle = .inline
        details.controlSize = .small
        details.tag = index
        details.toolTip = "What \(row.name) does, its safety boundaries, and setup"
        views.append(details)
        if let more = overflowButton(row, index: index, includesConfigure: !configureIsPrimary) {
            views.append(more)
        }
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

    private func actionButton(_ title: String, index: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(installRow(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = index
        button.isEnabled = !isBusy
        return button
    }

    private func overflowButton(_ row: Row, index: Int, includesConfigure: Bool) -> NSPopUpButton? {
        let canConfigure = includesConfigure && row.directory != nil && row.entry != nil
        guard canConfigure || row.sourceURL != nil || row.directory != nil else { return nil }
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .small
        button.bezelStyle = .inline
        let menu = NSMenu()
        menu.addItem(withTitle: "More", action: nil, keyEquivalent: "")
        if canConfigure {
            let configure = NSMenuItem(
                title: "Configure and Test…",
                action: #selector(configureRowFromMenu(_:)), keyEquivalent: "")
            configure.target = self
            configure.tag = index
            menu.addItem(configure)
        }
        if row.sourceURL != nil {
            let source = NSMenuItem(
                title: "View Source", action: #selector(openSourceFromMenu(_:)), keyEquivalent: "")
            source.target = self
            source.tag = index
            menu.addItem(source)
        }
        if row.directory != nil {
            let remove = NSMenuItem(
                title: "Remove Channel…", action: #selector(removeRowFromMenu(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = index
            remove.isEnabled = !isBusy
            menu.addItem(remove)
        }
        button.menu = menu
        button.toolTip = "More actions for \(row.name)"
        button.setAccessibilityLabel("More actions for \(row.name)")
        return button
    }

    // MARK: - Actions

    @objc private func openSourceFromMenu(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag), let url = rows[sender.tag].sourceURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showRowGuide(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]
        CmdyProductGuidePresenter.shared.show(
            title: row.name,
            category: row.directory == nil ? "Available Channel" : "Channel",
            summary: row.summary,
            guide: row.guide,
            relativeTo: window)
    }

    @objc private func configureRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag),
              let entry = rows[sender.tag].entry,
              let directory = rows[sender.tag].directory else { return }
        window?.orderOut(nil)
        configureHandler?(entry, directory)
    }

    @objc private func configureRowFromMenu(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag),
              let entry = rows[sender.tag].entry,
              let directory = rows[sender.tag].directory else { return }
        window?.orderOut(nil)
        configureHandler?(entry, directory)
    }

    @objc private func toggleRow(_ sender: NSSwitch) {
        guard rows.indices.contains(sender.tag),
              let entry = rows[sender.tag].entry,
              let directory = rows[sender.tag].directory else { return }
        if sender.state == .on {
            // Starting a provider connector is a setup operation: test it and
            // keep it enabled only after healthy provider access is reported.
            window?.orderOut(nil)
            configureHandler?(entry, directory)
        } else {
            do { try PluginManager.shared.setPluginEnabled(false, at: directory) }
            catch { showError("Could not stop \(rows[sender.tag].name)", error) }
            rebuildRows()
        }
    }

    @objc private func installRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), !isBusy else { return }
        let row = rows[sender.tag]
        let entry: Marketplace.Entry
        let verb: String
        switch row.action {
        case .install(let value): entry = value; verb = "Install"
        case .update(let value): entry = value; verb = "Update"
        case .none: return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(verb) \(entry.name) \(entry.version)?"
        alert.informativeText = entry.guide.plainText
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        let proceed = { [weak self] in self?.performInstall(entry, replacing: row.directory) }
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { proceed() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            proceed()
        }
    }

    private func performInstall(_ entry: Marketplace.Entry, replacing oldDirectory: URL?) {
        guard !isBusy else { return }
        isBusy = true
        if let oldDirectory { PluginManager.shared.stopPlugin(at: oldDirectory) }
        rebuildRows()
        statusLabel.stringValue = "Installing \(entry.name)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let directory = try Marketplace.installPlugin(entry, consented: true) { line in
                    DispatchQueue.main.async { self?.statusLabel.stringValue = "\(entry.name): \(line)" }
                }
                DispatchQueue.main.sync {
                    try? PluginManager.shared.setPluginEnabled(false, at: directory)
                    MarketplaceUpdateMonitor.shared.markInstalled(id: entry.id)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBusy = false
                    self.rebuildRows()
                    self.window?.orderOut(nil)
                    self.configureHandler?(entry, directory)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.rebuildRows()
                    self?.showError("Could not install \(entry.name)", error)
                }
            }
        }
    }

    @objc private func removeRowFromMenu(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag), !isBusy,
              let directory = rows[sender.tag].directory else { return }
        let row = rows[sender.tag]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(row.name)?"
        alert.informativeText = "This stops the connector and removes its installed files. Host-owned Inbox and Outbox history remain available until the offline Channel is forgotten."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let proceed = { [weak self] in self?.performRemoval(row, directory: directory) }
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { proceed() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            proceed()
        }
    }

    private func performRemoval(_ row: Row, directory: URL) {
        isBusy = true
        PluginManager.shared.stopPlugin(at: directory)
        rebuildRows()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FileManager.default.removeItem(at: directory) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.rebuildRows()
                switch result {
                case .success:
                    self.statusLabel.stringValue = "\(row.name) removed"
                case .failure(let error):
                    self.showError("Could not remove \(row.name)", error)
                }
            }
        }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window, window.isVisible { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
