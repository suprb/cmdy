import AppKit
import CmdyKit
import ProductIdentity

/// Owns application quit protection and automatic recovery. Window controllers
/// expose the same close policy and plugin checks for their narrower routes.
@MainActor
final class SessionLifecycle {
    private let controllers: () -> [TerminalWindowController]
    private let capture: () -> [[String: Any]]
    private let persistenceEnabled: () -> Bool
    private lazy var writer = SessionCheckpointWriter(onError: { [weak self] error in
        DispatchQueue.main.async { self?.showCheckpointFailure(error) }
    })
    private var observers: [NSObjectProtocol] = []
    private var transcriptTimer: Timer?
    private var checkpointWork: DispatchWorkItem?
    private var checkpointSchedule = SessionCheckpointSchedule()
    private var pauseDepth = 0
    private var hasStarted = false
    private var hasStopped = false
    private var quitPending = false
    private var recoveryNotice: SessionStore.RecoveryNotice?
    private var hasShownWriteFailure = false

    init(
        controllers: @escaping () -> [TerminalWindowController],
        capture: @escaping () -> [[String: Any]],
        persistenceEnabled: @escaping () -> Bool
    ) {
        self.controllers = controllers
        self.capture = capture
        self.persistenceEnabled = persistenceEnabled
    }

    func loadSavedLayouts() -> [[String: Any]]? {
        let result = SessionStore.loadWithRecovery()
        recoveryNotice = result.notice
        return result.layouts
    }

    /// Start after the initial restore has built its complete window tree.
    func startCheckpoints() {
        guard !hasStarted else { return }
        hasStarted = true
        hasStopped = false
        let events: [Notification.Name] = [
            .cmdySessionStateChanged, .cmdyWorkspaceFrameChanged,
            .cmdyPreferencesChanged, NSWindow.didMoveNotification,
            NSWindow.didResizeNotification, NSWindow.willCloseNotification,
        ]
        for name in events {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                if let window = notification.object as? NSWindow,
                   !(window.windowController is TerminalWindowController) { return }
                MainActor.assumeIsolated { self?.requestCheckpoint() }
            })
        }
        // The transcript capture is bounded by each pane's existing 300-line
        // export. A periodic backstop also covers output without OSC markers.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureCheckpoint() }
        }
        transcriptTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        requestCheckpoint()
        if let notice = recoveryNotice {
            recoveryNotice = nil
            DispatchQueue.main.async { [weak self] in self?.showRecoveryNotice(notice) }
        }
    }

    func requestCheckpoint() {
        guard hasStarted, !hasStopped, pauseDepth == 0 else { return }
        guard persistenceEnabled() else {
            checkpointWork?.cancel()
            checkpointWork = nil
            checkpointSchedule.captured()
            writer.discardPending()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let due = checkpointSchedule.changed(at: now)
        checkpointWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.captureCheckpoint() }
        checkpointWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - now), execute: work)
    }

    func pauseCheckpoints() {
        pauseDepth += 1
        checkpointWork?.cancel()
        checkpointWork = nil
        checkpointSchedule.captured()
        writer.discardPending()
    }

    func resumeCheckpoints() {
        pauseDepth = max(0, pauseDepth - 1)
        if pauseDepth == 0 { requestCheckpoint() }
    }

    func stopAndFlush() {
        hasStopped = true
        checkpointWork?.cancel()
        checkpointWork = nil
        transcriptTimer?.invalidate()
        transcriptTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard persistenceEnabled() else {
            writer.discardPending()
            return
        }
        do { try writer.flush(layouts: capture()) }
        catch {
            NSLog("%@: final recovery checkpoint failed: %@",
                  ProductIdentity.current.slug, error.localizedDescription)
        }
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        if quitPending { return .terminateLater }
        // Do not stack a quit sheet onto an unresolved window/pane close sheet.
        if controllers().contains(where: \.hasPendingCloseConfirmation)
            || NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
            NSSound.beep()
            PluginsWindow.shared.applicationTerminationWasCancelled()
            return .terminateCancel
        }
        let states = terminalStates()
        let assessment = SessionClosePolicy.assess(
            orderedStates(states),
            dirtyDocumentCount: CmdyEditorManager.shared.dirtyDocumentCount)
        if !assessment.requiresTerminalConfirmation,
           !CmdyEditorManager.shared.hasDirtyDocuments {
            guard approvePluginCloseChecks() else {
                PluginsWindow.shared.applicationTerminationWasCancelled()
                return .terminateCancel
            }
            return .terminateNow
        }

        quitPending = true
        // AppKit may enter a nested termination run loop before terminate()
        // returns. If the request came from the main dispatch queue (for
        // example an extension action), another main-queue block cannot run
        // inside that stack. Run-loop work can present the confirmation in
        // both normal and modal modes after .terminateLater is returned.
        RunLoop.main.perform(inModes: [.common, .modalPanel]) { [weak self] in
            MainActor.assumeIsolated {
                self?.confirmTermination(states: states) { [weak self] approved in
                    self?.quitPending = false
                    // A Browser component switch may have initiated this quit.
                    // Keep its progress/rollback UI accurate for terminal and
                    // plugin vetoes as well as cancelled editor save decisions.
                    if !approved { PluginsWindow.shared.applicationTerminationWasCancelled() }
                    application.reply(toApplicationShouldTerminate: approved)
                }
            }
        }
        return .terminateLater
    }

    private func confirmTermination(
        states: [String: SessionCloseState], completion: @escaping (Bool) -> Void
    ) {
        let assessment = SessionClosePolicy.assess(
            orderedStates(states),
            dirtyDocumentCount: CmdyEditorManager.shared.dirtyDocumentCount)
        let confirmDocuments: (Bool) -> Void = { [weak self] approved in
            guard approved, let self else { completion(false); return }
            CmdyEditorManager.shared.confirmAllDirty { [weak self] approved in
                guard approved, let self else { completion(false); return }
                let latest = self.terminalStates()
                // Other windows remain usable while a sheet is open. A new
                // pane or newly started command needs its own informed approval.
                if latest.contains(where: { id, state in
                    guard state.requiresConfirmation else { return false }
                    guard let previous = states[id] else { return true }
                    return !state.isCovered(by: previous)
                }) {
                    self.confirmTermination(states: latest, completion: completion)
                    return
                }
                completion(self.approvePluginCloseChecks())
            }
        }
        guard assessment.requiresTerminalConfirmation else {
            confirmDocuments(true)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit \(ProductIdentity.current.titleName)?"
        alert.informativeText = assessment.explanation
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        present(alert) { confirmDocuments($0 == .alertFirstButtonReturn) }
    }

    private func terminalStates() -> [String: SessionCloseState] {
        Dictionary(uniqueKeysWithValues: controllers().flatMap(\.panes).map {
            ($0.paneId, $0.closeState)
        })
    }

    private func orderedStates(_ states: [String: SessionCloseState]) -> [SessionCloseState] {
        controllers().flatMap(\.panes).compactMap { states[$0.paneId] }
    }

    private func approvePluginCloseChecks() -> Bool {
        let current = controllers()
        guard current.allSatisfy({ $0.pluginAllowsWindowClose(applicationQuit: true) }) else {
            return false
        }
        current.forEach { $0.approveCloseForApplicationTermination() }
        return true
    }

    private func captureCheckpoint() {
        checkpointWork?.cancel()
        checkpointWork = nil
        checkpointSchedule.captured()
        guard hasStarted, !hasStopped, pauseDepth == 0, persistenceEnabled() else { return }
        writer.submit(layouts: capture())
    }

    private func showCheckpointFailure(_ error: Error) {
        guard !hasStopped, !hasShownWriteFailure else { return }
        hasShownWriteFailure = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Session Recovery Is Not Updating"
        alert.informativeText = "The previous checkpoint has been kept. \(ProductIdentity.current.titleName) will keep trying to save your current layout and transcript.\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    private func showRecoveryNotice(_ notice: SessionStore.RecoveryNotice) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = notice.title
        alert.informativeText = notice.message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let window = NSApp.keyWindow ?? NSApp.orderedWindows.first {
            $0.isVisible && $0.windowController is TerminalWindowController
        }
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
