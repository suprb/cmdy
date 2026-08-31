import AppKit
import ProductIdentity
import CmdyKit

private final class CmdyActionMenuReference: NSObject {
    let action: CmdyAction
    init(_ action: CmdyAction) { self.action = action }
}

/// Main-app bridge for one-shot Cmdy Actions. Discovery and trust stay
/// outside the project; execution always goes through real TerminalPane input
/// so shell integration, history, hooks, and user-visible output still apply.
private final class CmdyActionsController {
    static let shared = CmdyActionsController()

    private let trustStore = ExtensionTrustStore(
        url: ConfigFile.directory.appendingPathComponent("extension-trust.json"))
    private var promptedRoots = Set<String>()

    func actions(for delegate: AppDelegate, promptForTrust: Bool) -> [CmdyAction] {
        let personalDiscovery = CmdyActionCatalog.discover(
            in: CmdyActionCatalog.personalDirectory)
        for issue in personalDiscovery.issues {
            NSLog("cmdy Action: %@: %@", issue.path, issue.message)
        }
        var actions = personalDiscovery.actions
        guard let cwd = delegate.currentController?.workingDirectory else {
            let context = CmdyActionContext(cwd: NSHomeDirectory())
            return sortedDeduplicated(actions).filter { $0.isAvailable(in: context) }
        }
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        guard let root = ProjectExtensionDiscovery.projectRoot(containing: cwdURL) else {
            let context = CmdyActionContext(cwd: cwd)
            return sortedDeduplicated(actions).filter { $0.isAvailable(in: context) }
        }
        let projectDiscovery = CmdyActionCatalog.discover(
            in: CmdyActionCatalog.projectDirectory(for: root),
            scope: .project(root))
        for issue in projectDiscovery.issues {
            NSLog("cmdy Action: %@: %@", issue.path, issue.message)
        }
        guard !projectDiscovery.actions.isEmpty else {
            let context = CmdyActionContext(cwd: cwd, projectRoot: root)
            return sortedDeduplicated(actions).filter { $0.isAvailable(in: context) }
        }

        if !trustStore.isTrusted(root), promptForTrust {
            requestTrust(for: root, actions: projectDiscovery.actions, delegate: delegate)
        }
        if trustStore.isTrusted(root) {
            // A project Action with the same id deliberately shadows the
            // personal fallback while the project is focused.
            actions.append(contentsOf: projectDiscovery.actions)
        }
        let context = CmdyActionContext(cwd: cwd, projectRoot: root)
        return sortedDeduplicated(actions).filter { $0.isAvailable(in: context) }
    }

    private func requestTrust(for root: URL, actions: [CmdyAction],
                              delegate: AppDelegate) {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard promptedRoots.insert(path).inserted else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let identity = ProductIdentity.current
        alert.messageText =
            "Trust \(identity.titleName) automation in \(root.lastPathComponent)?"
        let names = actions.map { "• \($0.title)" }.joined(separator: "\n")
        alert.informativeText = "This project contains executable Actions. Trusting it also "
            + "allows Extensions under \(identity.projectDirectoryName) now and later. "
            + "Only continue if you know "
            + "the project's source.\n\n\(names)"
        alert.addButton(withTitle: "Trust Project")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try trustStore.trust(root)
                PluginManager.shared.reconcileProjectExtensions()
            } catch {
                delegate.showCmdyActionError(error)
            }
        }
    }

    private func sortedDeduplicated(_ actions: [CmdyAction]) -> [CmdyAction] {
        var byID: [String: CmdyAction] = [:]
        for action in actions { byID[action.id] = action }
        return byID.values.sorted {
            if $0.group.localizedCaseInsensitiveCompare($1.group) != .orderedSame {
                return $0.group.localizedCaseInsensitiveCompare($1.group) == .orderedAscending
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func collectValues(for action: CmdyAction, supplied: [String: String]) throws
        -> [String: String] {
        let missing = action.inputs.filter { supplied[$0.id] == nil }
        guard !missing.isEmpty else { return supplied }

        let alert = NSAlert()
        alert.messageText = action.title
        alert.informativeText = action.description.isEmpty
            ? "Enter the values for this Action." : action.description
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        var readers: [(String, () -> String)] = []

        for input in missing {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            let label = NSTextField(labelWithString: input.label + (input.required ? " *" : ""))
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 128).isActive = true
            row.addArrangedSubview(label)

            switch input.kind {
            case .text, .secure:
                let field: NSTextField = input.kind == .secure
                    ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
                field.stringValue = input.defaultValue ?? ""
                field.placeholderString = input.placeholder
                field.widthAnchor.constraint(equalToConstant: 260).isActive = true
                row.addArrangedSubview(field)
                readers.append((input.id, { field.stringValue }))
            case .toggle:
                let checkbox = NSButton(
                    checkboxWithTitle: "Enabled", target: nil, action: nil)
                let value = (input.defaultValue ?? "false").lowercased()
                checkbox.state = ["true", "1", "yes"].contains(value) ? .on : .off
                row.addArrangedSubview(checkbox)
                readers.append((input.id, { checkbox.state == .on ? "true" : "false" }))
            case .choice:
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: input.options)
                if let value = input.defaultValue,
                   let index = input.options.firstIndex(of: value) {
                    popup.selectItem(at: index)
                }
                popup.widthAnchor.constraint(equalToConstant: 260).isActive = true
                row.addArrangedSubview(popup)
                readers.append((input.id, { popup.titleOfSelectedItem ?? "" }))
            }
            stack.addArrangedSubview(row)
        }

        let accessory = NSView(frame: NSRect(
            x: 0, y: 0, width: 410, height: CGFloat(missing.count * 38 + 16)))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
        ])
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw CmdyActionError.invalid("Action cancelled")
        }
        var values = supplied
        for (id, read) in readers { values[id] = read() }
        return values
    }

    func confirm(_ action: CmdyAction, values: [String: String],
                 context: CmdyActionContext) throws {
        guard var message = action.confirmation, !message.isEmpty else { return }
        message = message.replacingOccurrences(of: "{{cwd}}", with: context.cwd)
        message = message.replacingOccurrences(
            of: "{{project}}", with: context.projectRoot?.path ?? context.cwd)
        for (key, value) in values {
            message = message.replacingOccurrences(of: "{{input.\(key)}}", with: value)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = action.title
        alert.informativeText = message
        alert.addButton(withTitle: "Run Action")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw CmdyActionError.invalid("Action cancelled")
        }
    }
}

extension AppDelegate {
    func availableCmdyActions(promptForTrust: Bool = true) -> [CmdyAction] {
        CmdyActionsController.shared.actions(for: self, promptForTrust: promptForTrust)
    }

    func cmdyActionPayloads() -> [[String: Any]] {
        availableCmdyActions(promptForTrust: false).map { action in
            var payload: [String: Any] = [
                "id": action.id,
                "title": action.title,
                "description": action.description,
                "group": action.group,
                "source": action.sourceURL.path,
                "inputs": action.inputs.map(\.id),
                "steps": action.steps.count,
                "scope": action.projectRoot == nil ? "personal" : "project",
                "guide": action.guide.jsonObject,
            ]
            if let shortcut = action.shortcut { payload["shortcut"] = shortcut.descriptor }
            return payload
        }
    }

    @discardableResult
    func runCmdyAction(id: String, inputs: [String: String] = [:]) throws
        -> [String: Any] {
        guard let action = availableCmdyActions().first(where: { $0.id == id }) else {
            throw CmdyActionError.invalid("no available Action '\(id)'")
        }
        return try runCmdyAction(action, inputs: inputs)
    }

    @discardableResult
    func runCmdyAction(_ action: CmdyAction, inputs: [String: String] = [:]) throws
        -> [String: Any] {
        guard let controller = currentController,
              let originalPane = controller.focusedPane else {
            throw CmdyActionError.invalid("open a terminal pane before running an Action")
        }
        let context = CmdyActionContext(
            cwd: originalPane.currentCwd ?? NSHomeDirectory(),
            projectRoot: action.projectRoot
                ?? originalPane.currentCwd.flatMap {
                    ProjectExtensionDiscovery.projectRoot(
                        containing: URL(fileURLWithPath: $0, isDirectory: true))
                })
        let values = try CmdyActionsController.shared.collectValues(
            for: action, supplied: inputs)
        try CmdyActionsController.shared.confirm(action, values: values, context: context)
        let steps = try action.resolve(in: context, values: values)
        var panes: [String] = []
        for step in steps {
            let pane: TerminalPane
            switch step.pane {
            case .focused:
                pane = originalPane
            case .right:
                guard let split = controller.splitPane(originalPane, vertical: true) else {
                    throw CmdyActionError.invalid("could not create the right pane")
                }
                pane = split
            case .down:
                guard let split = controller.splitPane(originalPane, vertical: false) else {
                    throw CmdyActionError.invalid("could not create the lower pane")
                }
                pane = split
            }
            if step.mode == .run {
                pane.replacePromptInput(with: step.command, submit: true)
            } else {
                pane.replacePromptInput(with: step.command)
            }
            if !panes.contains(pane.paneId) { panes.append(pane.paneId) }
        }
        PluginManager.shared.emit("action-started", [
            "id": action.id, "title": action.title, "panes": panes,
        ])
        return [
            "ok": true, "id": action.id, "title": action.title,
            "panes": panes, "steps": steps.count,
        ]
    }

    @objc func runCmdyActionMenu(_ sender: NSMenuItem) {
        guard let reference = sender.representedObject as? CmdyActionMenuReference else {
            NSSound.beep()
            return
        }
        do { try runCmdyAction(reference.action) }
        catch { showCmdyActionError(error) }
    }

    @objc func showCmdyActionInfo(_ sender: NSMenuItem) {
        guard let reference = sender.representedObject as? CmdyActionMenuReference else {
            NSSound.beep()
            return
        }
        let action = reference.action
        let alert = NSAlert()
        alert.messageText = action.title
        alert.informativeText = action.guide.plainText
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }

    func showCmdyActionError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "\(ProductIdentity.current.titleName) Action could not run"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func refreshActionsMenu() {
        guard let menu = NSApp.mainMenu?.cmdyDescendantMenu(titled: "Actions") else { return }
        rebuildActionsMenu(menu)
    }

    func rebuildActionsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let actions = availableCmdyActions()
        let groups = Dictionary(grouping: actions, by: \.group)
        for group in groups.keys.sorted(by: {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }) {
            let parent = NSMenuItem(title: group, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: group)
            for action in groups[group] ?? [] {
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(runCmdyActionMenu(_:)),
                    keyEquivalent: action.shortcut?.key ?? "")
                item.target = self
                item.representedObject = CmdyActionMenuReference(action)
                if let shortcut = action.shortcut {
                    var flags: NSEvent.ModifierFlags = []
                    if shortcut.modifiers.contains(.command) { flags.insert(.command) }
                    if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
                    if shortcut.modifiers.contains(.option) { flags.insert(.option) }
                    if shortcut.modifiers.contains(.control) { flags.insert(.control) }
                    item.keyEquivalentModifierMask = flags
                }
                item.toolTip = action.guide.plainText
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        if actions.isEmpty {
            let empty = NSMenuItem(
                title: "No Actions for This Context", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let parent = NSMenuItem(title: "Action Details", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Action Details")
            for action in actions {
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(showCmdyActionInfo(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = CmdyActionMenuReference(action)
                item.toolTip = action.guide.whatItDoes.first
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(actionMenuItem(
            "Install Starter Actions…", #selector(installStarterActions(_:))))
        let manage = NSMenuItem(title: "Manage Actions", action: nil, keyEquivalent: "")
        let manageMenu = NSMenu(title: "Manage Actions")
        manageMenu.addItem(actionMenuItem(
            "Save Last Command as Action…", #selector(saveLastCommandAsAction(_:))))
        manageMenu.addItem(actionMenuItem(
            "Create Sample Action", #selector(createSampleAction(_:))))
        manageMenu.addItem(actionMenuItem(
            "Open Actions Folder", #selector(openActionsFolder(_:))))
        manageMenu.addItem(actionMenuItem(
            "Open Actions Guide", #selector(openActionsGuide(_:))))
        manage.submenu = manageMenu
        menu.addItem(manage)
    }

    private func actionMenuItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func createSampleAction(_ sender: Any?) {
        createAction(
            title: "Hello \(ProductIdentity.current.titleName)", command: nil)
    }

    @objc func installStarterActions(_ sender: Any?) {
        let starters = CmdyActionCatalog.starterActions
        let alert = NSAlert()
        alert.messageText = "Install Starter Actions?"
        alert.informativeText = starters.map {
            "• \($0.title) — \($0.description)"
        }.joined(separator: "\n")
            + "\n\nThese become ordinary personal Actions that you can inspect, edit, or delete. Existing Actions and folders are never replaced."
        alert.addButton(withTitle: "Install \(starters.count) Actions")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let result = try CmdyActionCatalog.installStarterActions()
            refreshActionsMenu()
            let resultAlert = NSAlert()
            if result.installed.isEmpty {
                resultAlert.messageText = "Starter Actions are already installed"
            } else {
                resultAlert.messageText = "Installed \(result.installed.count) Starter Action\(result.installed.count == 1 ? "" : "s")"
            }
            var lines = result.installed.map { "✓ \($0.title)" }
            if !result.skipped.isEmpty {
                lines.append("\nKept existing:")
                lines.append(contentsOf: result.skipped.map { "• \($0.title)" })
            }
            resultAlert.informativeText = lines.joined(separator: "\n")
            resultAlert.runModal()
        } catch {
            showCmdyActionError(error)
        }
    }

    @objc func saveLastCommandAsAction(_ sender: Any?) {
        guard let command = currentController?.recentCommands(limit: 1).first?.command,
              !command.isEmpty else {
            showCmdyActionError(
                CmdyActionError.invalid("run a shell command first"))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save Last Command as Action"
        alert.informativeText = command
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = "Run \(command.split(separator: " ").first ?? "Command")"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        createAction(title: field.stringValue, command: command)
    }

    private func createAction(title rawTitle: String, command: String?) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 160 else {
            showCmdyActionError(
                CmdyActionError.invalid("Action title must be 1 to 160 bytes"))
            return
        }
        let root = CmdyActionCatalog.personalDirectory
        let base = title.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber)
                ? character : "-"
        }
        let slug = String(base).split(separator: "-").joined(separator: "-")
        var directory = root.appendingPathComponent(slug.isEmpty ? "action" : slug)
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.path) {
            directory = root.appendingPathComponent("\(slug.isEmpty ? "action" : slug)-\(suffix)")
            suffix += 1
        }
        do {
            let manifest = try CmdyActionCatalog.createSample(
                at: directory, title: title, command: command)
            refreshActionsMenu()
            NSWorkspace.shared.activateFileViewerSelecting([manifest])
        } catch { showCmdyActionError(error) }
    }

    @objc func openActionsFolder(_ sender: Any?) {
        do {
            try FileManager.default.createDirectory(
                at: CmdyActionCatalog.personalDirectory,
                withIntermediateDirectories: true)
            NSWorkspace.shared.open(CmdyActionCatalog.personalDirectory)
        } catch { showCmdyActionError(error) }
    }

    @objc func openActionsGuide(_ sender: Any?) {
        let repoGuide = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ACTIONS.md")
        if FileManager.default.fileExists(atPath: repoGuide.path) {
            NSWorkspace.shared.open(repoGuide)
        } else if let bundled = Bundle.main.url(
            forResource: "ACTIONS", withExtension: "md") {
            NSWorkspace.shared.open(bundled)
        } else {
            AIResponseWindow.shared.show(
                title: "\(ProductIdentity.current.titleName) Actions",
                body: "Drop a script in "
                    + "~/.config/\(ProductIdentity.current.configurationDirectoryName)/actions, "
                    + "or run `\(ProductIdentity.current.executableName) "
                    + "action new <directory>`." )
        }
    }
}
