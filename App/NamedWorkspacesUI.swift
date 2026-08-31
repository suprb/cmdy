import AppKit
import CmdyKit

@MainActor
extension AppDelegate {
    private func namedWorkspaceCoordinator() -> NamedWorkspaceCoordinator {
        NamedWorkspaceCoordinator(
            capture: { [weak self] in
                guard let self else {
                    throw WorkspaceStore.StoreError.invalidSnapshot(
                        "cmdy is no longer available")
                }
                let layouts = self.serializedSessionLayouts()
                guard !layouts.isEmpty else {
                    throw WorkspaceStore.StoreError.invalidSnapshot(
                        "there are no terminal windows to save")
                }
                let preferences = Preferences.shared
                return WorkspaceCapture(
                    layouts: layouts,
                    presentation: WorkspacePresentation(
                        windowGridEnabled: preferences.windowGridEnabled,
                        windowGridState: preferences.windowGridStateData,
                        navigatorVisible: preferences.workspaceNavigatorVisible,
                        inspectorVisible: preferences.workspaceInspectorVisible))
            },
            open: { [weak self] workspace, mode in
                guard let self else {
                    throw WorkspaceStore.StoreError.invalidSnapshot(
                        "cmdy is no longer available")
                }
                guard case .additionalWindows = mode else {
                    throw WorkspaceStore.StoreError.invalidSnapshot(
                        "replace mode must pass cmdy's close confirmation first")
                }

                let (layouts, identifiers) = try self.remappedWorkspaceLayouts(
                    workspace.foundationLayouts())
                let presentation = workspace.presentation
                if let navigatorVisible = presentation.navigatorVisible {
                    Preferences.shared.workspaceNavigatorVisible = navigatorVisible
                }
                if let inspectorVisible = presentation.inspectorVisible {
                    Preferences.shared.workspaceInspectorVisible = inspectorVisible
                }

                self.restoreSession(layouts)

                if let gridData = presentation.windowGridState,
                   presentation.windowGridEnabled == true {
                    self.windowGridCoordinator.importWorkspaceState(
                        gridData, remapping: identifiers)
                }
                if let enabled = presentation.windowGridEnabled {
                    Preferences.shared.windowGridEnabled = enabled
                }
            })
    }

    /// Opening a saved workspace is deliberately additive. Fresh workspace
    /// group identifiers keep a second copy independent from the first while
    /// preserving tab membership and the saved Window Grid topology.
    private func remappedWorkspaceLayouts(
        _ source: [[String: Any]]
    ) throws -> (layouts: [[String: Any]], identifiers: [String: String]) {
        guard !source.isEmpty else {
            throw WorkspaceStore.StoreError.invalidSnapshot(
                "the workspace contains no windows")
        }
        let groupKey = "workspaceTabGroup"
        var identifiers: [String: String] = [:]
        var layouts: [[String: Any]] = []
        layouts.reserveCapacity(source.count)
        for (index, original) in source.enumerated() {
            var layout = original
            let oldIdentifier = (layout[groupKey] as? String)
                ?? "ungrouped-\(index)"
            let newIdentifier = identifiers[oldIdentifier] ?? UUID().uuidString
            identifiers[oldIdentifier] = newIdentifier
            layout[groupKey] = newIdentifier
            layouts.append(layout)
        }
        return (layouts, identifiers)
    }

    @objc func saveNamedWorkspaceAs(_ sender: Any?) {
        guard let name = promptForWorkspaceName(
            title: "Save Workspace",
            message: "Save the current windows, tabs, splits, appearance, directories, and capped scrollback.",
            actionTitle: "Save")
        else { return }
        do {
            let saved = try namedWorkspaceCoordinator().saveAsNew(named: name)
            showWorkspaceNotice(
                title: "Workspace Saved",
                message: "\u{201c}\(saved.name)\u{201d} now contains \(saved.layouts.count) window\(saved.layouts.count == 1 ? "" : "s").")
        } catch {
            showWorkspaceError(error)
        }
    }

    @objc func updateNamedWorkspace(_ sender: Any?) {
        do {
            let saved = try namedWorkspaceCoordinator().updateCurrent()
            showWorkspaceNotice(
                title: "Workspace Updated",
                message: "\u{201c}\(saved.name)\u{201d} now matches the current cmdy workspace.")
        } catch WorkspaceStore.StoreError.invalidSnapshot(_) {
            saveNamedWorkspaceAs(sender)
        } catch {
            showWorkspaceError(error)
        }
    }

    @objc func openNamedWorkspace(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID)
        else { NSSound.beep(); return }
        do {
            try namedWorkspaceCoordinator().open(id: id)
        } catch {
            showWorkspaceError(error)
        }
    }

    @objc func renameNamedWorkspace(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID)
        else { NSSound.beep(); return }
        let coordinator = namedWorkspaceCoordinator()
        guard let current = try? coordinator.list().first(where: { $0.id == id }),
              let name = promptForWorkspaceName(
                title: "Rename Workspace",
                message: "Choose a new name for this saved workspace.",
                actionTitle: "Rename",
                initialValue: current.name)
        else { return }
        do { _ = try coordinator.rename(id: id, to: name) }
        catch { showWorkspaceError(error) }
    }

    @objc func deleteNamedWorkspace(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID)
        else { NSSound.beep(); return }
        let coordinator = namedWorkspaceCoordinator()
        guard let current = try? coordinator.list().first(where: { $0.id == id }) else {
            NSSound.beep(); return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \u{201c}\(current.name)\u{201d}?"
        alert.informativeText = "This removes only the saved snapshot. Open terminal windows are not changed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try coordinator.delete(id: id) }
        catch { showWorkspaceError(error) }
    }

    func rebuildNamedWorkspacesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(workspaceMenuItem(
            "Save Workspace As…", action: #selector(saveNamedWorkspaceAs(_:))))
        menu.addItem(workspaceMenuItem(
            "Update Current Workspace", action: #selector(updateNamedWorkspace(_:))))
        menu.addItem(.separator())

        do {
            let coordinator = namedWorkspaceCoordinator()
            let currentID = coordinator.currentWorkspaceID
            let workspaces = try coordinator.list()
            if workspaces.isEmpty {
                let empty = NSMenuItem(
                    title: "No Saved Workspaces", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            for workspace in workspaces {
                let parent = NSMenuItem(
                    title: workspace.name, action: nil, keyEquivalent: "")
                parent.state = workspace.id == currentID ? .on : .off
                let submenu = NSMenu(title: workspace.name)
                submenu.addItem(workspaceMenuItem(
                    "Open in New Windows",
                    action: #selector(openNamedWorkspace(_:)), id: workspace.id))
                submenu.addItem(.separator())
                submenu.addItem(workspaceMenuItem(
                    "Rename…", action: #selector(renameNamedWorkspace(_:)),
                    id: workspace.id))
                submenu.addItem(workspaceMenuItem(
                    "Delete…", action: #selector(deleteNamedWorkspace(_:)),
                    id: workspace.id))
                parent.submenu = submenu
                menu.addItem(parent)
            }
        } catch {
            let failed = NSMenuItem(
                title: "Could Not Read Workspaces", action: nil, keyEquivalent: "")
            failed.isEnabled = false
            menu.addItem(failed)
        }
    }

    func namedWorkspacePaletteSection() -> PaletteItem {
        let coordinator = namedWorkspaceCoordinator()
        var children: [PaletteItem] = [
            PaletteItem(title: "Save Workspace As…", subtitle: "new named snapshot") {
                [weak self] in self?.saveNamedWorkspaceAs(nil)
            },
            PaletteItem(title: "Update Current Workspace", subtitle: "replace saved snapshot") {
                [weak self] in self?.updateNamedWorkspace(nil)
            },
        ]
        if let workspaces = try? coordinator.list() {
            children.append(contentsOf: workspaces.map { workspace in
                PaletteItem(
                    title: "Open \u{201c}\(workspace.name)\u{201d}",
                    subtitle: "\(workspace.windowCount) window\(workspace.windowCount == 1 ? "" : "s") · opens alongside current") {
                        [weak self] in
                        let menuItem = NSMenuItem()
                        menuItem.representedObject = workspace.id.uuidString
                        self?.openNamedWorkspace(menuItem)
                    }
            })
        }
        return .section("Workspaces", "save · update · reopen", children)
    }

    private func workspaceMenuItem(
        _ title: String,
        action: Selector,
        id: UUID? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id?.uuidString
        return item
    }

    private func promptForWorkspaceName(
        title: String,
        message: String,
        actionTitle: String,
        initialValue: String = ""
    ) -> String? {
        let field = NSTextField(string: initialValue)
        field.placeholderString = "Workspace name"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func showWorkspaceError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Workspace Could Not Be Saved or Opened"
        alert.runModal()
    }

    private func showWorkspaceNotice(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }
}
