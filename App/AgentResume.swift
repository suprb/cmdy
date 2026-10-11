import AppKit
import CmdyKit

/// Immutable evidence from before the palette can resize or preview the pane.
/// A later prompt redraw can invalidate this evidence, but never create it.
struct WorkspaceResumePaletteOrigin {
    let presentationID: UUID
    let promptWasEmpty: Bool
    let inputRevision: UInt64
    let hint: WorkspaceLaunchHint?
    let shellPID: Int32
    let windowID: ObjectIdentifier?
}

extension TerminalPane {
    var workspaceSessionStatus: String? {
        if blockStore.isRunning { return nil }
        if let hint = workspaceLaunchHint { return "\(hint.displayName) session available" }
        return hasRestoredTranscript ? "Restored transcript" : nil
    }

    var canStageWorkspaceResume: Bool {
        workspaceLaunchHint != nil && !blockStore.isRunning
            && !surface.engine.isCurrentBufferAlternate
            && canSafelyStageAtEmptyPrompt
    }

    func setWorkspaceLaunchHint(_ hint: WorkspaceLaunchHint?) {
        workspaceLaunchHint = hint
        onStateChanged?(self)
        NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged, object: self)
    }

    func rememberSubmittedAgentResume(_ command: String) {
        guard !blockStore.isRunning, !surface.engine.isCurrentBufferAlternate,
              let hint = WorkspaceResume.explicitHint(command: command) else { return }
        setWorkspaceLaunchHint(hint)
    }

    func stageWorkspaceResume() {
        guard canStageWorkspaceResume, let hint = workspaceLaunchHint else {
            showWorkspaceResumeUnavailable()
            return
        }
        replacePromptInput(with: hint.resumeCommand)
        focus()
    }

    func captureWorkspaceResumePaletteOrigin() {
        workspaceResumePaletteOrigin = WorkspaceResumePaletteOrigin(
            presentationID: UUID(),
            promptWasEmpty: canPresentAutomaticAssistance && canStageWorkspaceResume,
            inputRevision: workspaceResumeInputRevision,
            hint: workspaceLaunchHint,
            shellPID: surface.shellPid,
            windowID: window.map { ObjectIdentifier($0) })
    }

    /// Palette dismissal can resize the terminal before its prompt redraw.
    /// Never extend this short handoff to a running command or unknown draft.
    func stageWorkspaceResumeFromPalette(
        expectedHint: WorkspaceLaunchHint, origin: WorkspaceResumePaletteOrigin?
    ) {
        guard let window, window.isKeyWindow, window.attachedSheet == nil,
              isTerminalFocused, canPresentAutomaticAssistance,
              workspaceLaunchHint == expectedHint else { return }
        guard let origin else {
            showWorkspaceResumeUnavailable()
            return
        }
        guard workspaceResumePaletteOrigin?.presentationID == origin.presentationID,
              origin.windowID == ObjectIdentifier(window),
              origin.hint == expectedHint, origin.shellPID == surface.shellPid else { return }
        // Check the original prompt before EVERY path, including immediate
        // staging. OSC 133;B during palette reflow resets the live draft and
        // must not turn a pre-existing command or suffix into an empty prompt.
        guard origin.promptWasEmpty,
              origin.inputRevision == workspaceResumeInputRevision else {
            showWorkspaceResumeUnavailable()
            return
        }
        if canStageWorkspaceResume {
            stageWorkspaceResume()
            return
        }
        guard canAwaitWorkspaceResumePromptAfterReflow else {
            showWorkspaceResumeUnavailable()
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        Task { @MainActor [weak self, weak window] in
            while let self, let window,
                  self.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  self.isTerminalFocused, self.canPresentAutomaticAssistance,
                  self.workspaceResumePaletteOrigin?.presentationID == origin.presentationID,
                  self.workspaceLaunchHint == expectedHint,
                  self.workspaceResumeInputRevision == origin.inputRevision,
                  self.surface.shellPid == origin.shellPID {
                guard ProcessInfo.processInfo.systemUptime <= deadline else {
                    self.showWorkspaceResumeUnavailable()
                    return
                }
                if self.canStageWorkspaceResume {
                    self.stageWorkspaceResume()
                    return
                }
                guard self.canAwaitWorkspaceResumePromptAfterReflow else { return }
                do { try await Task.sleep(nanoseconds: 20_000_000) }
                catch { return }
            }
        }
    }

    private func showWorkspaceResumeUnavailable() {
        let alert = NSAlert()
        alert.messageText = "Resume Needs an Empty Shell Prompt"
        alert.informativeText = "Finish the current command and clear any draft input, then try Resume again. The shell must have cmdy shell integration enabled."
        alert.addButton(withTitle: "OK")
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

@MainActor
extension AppDelegate {
    @objc func linkWorkspaceAgentSession(_ sender: Any?) {
        guard let pane = currentController?.focusedPane else { NSSound.beep(); return }
        let tool = NSPopUpButton(frame: NSRect(x: 0, y: 48, width: 340, height: 26))
        tool.addItems(withTitles: ["Codex", "Claude Code", "Pi"])
        let tools = WorkspaceLaunchHint.Tool.allCases
        if let hint = pane.workspaceLaunchHint,
           let index = tools.firstIndex(of: hint.tool) { tool.selectItem(at: index) }
        let identifier = NSTextField(frame: NSRect(x: 0, y: 10, width: 340, height: 26))
        identifier.placeholderString = "Session ID supplied by the agent"
        identifier.stringValue = pane.workspaceLaunchHint?.sessionIdentifier ?? ""
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 84))
        accessory.addSubview(tool)
        accessory.addSubview(identifier)
        let alert = NSAlert()
        alert.messageText = "Remember an Agent Session"
        alert.informativeText = "Enter an ID shown by your agent. This pane's saved workspace will offer a resume command. Opening the workspace starts a fresh shell; resuming is your choice."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Remember Session")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = identifier
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard tools.indices.contains(tool.indexOfSelectedItem),
              let hint = WorkspaceLaunchHint(
                tool: tools[tool.indexOfSelectedItem], sessionIdentifier: identifier.stringValue)
        else {
            let error = NSAlert()
            error.messageText = "Enter a Session ID"
            error.informativeText = "Use an ID beginning with a letter or number, followed by letters, numbers, dots, dashes, underscores, or colons (up to 160 characters)."
            error.runModal()
            return
        }
        pane.setWorkspaceLaunchHint(hint)
    }

    func resumeSessionPaletteItems() -> [PaletteItem] {
        var items = [PaletteItem(
            title: "Remember Agent Session…", subtitle: "link an explicit session ID") {
                [weak self] in self?.linkWorkspaceAgentSession(nil)
            }]
        if let pane = currentController?.focusedPane,
           let hint = pane.workspaceLaunchHint {
            let origin = pane.workspaceResumePaletteOrigin
            items.insert(PaletteItem(
                title: "Resume \(hint.displayName) Session",
                subtitle: "insert command · Return runs it") { [weak pane] in
                    pane?.stageWorkspaceResumeFromPalette(expectedHint: hint, origin: origin)
                }, at: 0)
            items.append(PaletteItem(title: "Forget Agent Session", subtitle: hint.displayName) {
                [weak pane] in pane?.setWorkspaceLaunchHint(nil)
            })
        }
        return items
    }
}
