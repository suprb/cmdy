import AppKit
import CmdyKit
import Darwin
import ProductIdentity

/// Exercises the actual application quit request and its native Cancel button.
/// Kept outside AppDelegate so lifecycle diagnostics do not grow the app shell.
@MainActor
final class SessionLifecycleDiagnostics {
    private let lifecycle: SessionLifecycle
    private let controllers: [TerminalWindowController]
    private let deadline = ProcessInfo.processInfo.systemUptime + 12
    private var pane: TerminalPane?
    private var sleepPID: pid_t?
    private var quitWasPending = false
    private var cancelPreservedChild = false
    private var watchdog: Timer?
    private var phase = "startup"

    static func run(lifecycle: SessionLifecycle, controllers: [TerminalWindowController]) {
        let test = SessionLifecycleDiagnostics(lifecycle: lifecycle, controllers: controllers)
        test.start()
    }

    private init(lifecycle: SessionLifecycle, controllers: [TerminalWindowController]) {
        self.lifecycle = lifecycle
        self.controllers = controllers
    }

    private func start() {
        // Independent of the polling chain, and registered in modal mode as
        // well: a broken quit implementation must fail this test, not hang it.
        let watchdog = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finish(false, reason: "watchdog-\(self.phase)")
            }
        }
        self.watchdog = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        guard ProductIdentity.current.environmentValue("CONFIG_DIR") != nil,
              ProductIdentity.current.environmentValue("DEFAULTS_DOMAIN") != nil,
              let pane = controllers.first?.panes.first else {
            finish(false, reason: "requires-isolated-config-and-defaults")
            return
        }
        self.pane = pane
        Preferences.shared.automaticErrorHelp = false
        pane.window?.makeKeyAndOrderFront(nil)
        poll("shell-ready", until: { pane.surface.shellPid > 0 && !pane.closeState.requiresConfirmation }) {
            pane.replacePromptInput(with: "/bin/sleep 30", submit: true)
            self.waitForChild()
        }
    }

    private func waitForChild() {
        guard let pane else { finish(false, reason: "missing-pane"); return }
        poll("sleep-started", until: {
            self.sleepPID = self.sleepChild(of: pane.surface.shellPid)
            return self.sleepPID != nil && pane.closeState.requiresConfirmation
        }) {
            // Deliberately request quit from the main dispatch queue. AppKit
            // nests a run loop here, so dispatching the confirmation onto that
            // same queue would deadlock. Start UI polling before terminate(),
            // since it need not return until Cancel has been processed.
            DispatchQueue.main.async {
                RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                    MainActor.assumeIsolated { self.waitForQuitSheet() }
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func waitForQuitSheet() {
        poll("quit-sheet", until: {
            guard let sheet = self.pane?.window?.attachedSheet else { return false }
            let buttons = self.buttons(in: sheet.contentView)
            return buttons.contains { $0.title == "Quit" }
                && buttons.contains { $0.title == "Cancel" }
        }) {
            self.quitWasPending = self.lifecycle.applicationShouldTerminate(NSApp) == .terminateLater
            guard let sheet = self.pane?.window?.attachedSheet,
                  let cancel = self.buttons(in: sheet.contentView).first(where: { $0.title == "Cancel" }) else {
                self.finish(false, reason: "missing-cancel")
                return
            }
            cancel.performClick(nil)
            self.waitForCancellation()
        }
    }

    private func waitForCancellation() {
        poll("quit-cancelled", until: { self.pane?.window?.attachedSheet == nil }) {
            guard let pane = self.pane, let sleepPID = self.sleepPID else {
                self.finish(false, reason: "missing-child")
                return
            }
            self.cancelPreservedChild = Darwin.kill(sleepPID, 0) == 0
                && self.sleepChild(of: pane.surface.shellPid) == sleepPID
                && Darwin.kill(pane.surface.shellPid, 0) == 0
            guard self.cancelPreservedChild else {
                self.finish(false, reason: "cancel-killed-child")
                return
            }
            // End only this harness's exact child. The shell stays alive so
            // the final assertion proves a used, now-idle shell is disposable.
            _ = Darwin.kill(sleepPID, SIGTERM)
            self.waitForIdleShell()
        }
    }

    private func waitForIdleShell() {
        poll("idle-shell", until: {
            guard let pane = self.pane else { return false }
            return !pane.closeState.requiresConfirmation
                && !pane.blockStore.isRunning
                && self.sleepChild(of: pane.surface.shellPid) == nil
        }) {
            let idleApproved = self.lifecycle.applicationShouldTerminate(NSApp) == .terminateNow
            let ok = self.quitWasPending && self.cancelPreservedChild && idleApproved
            print("UISESSIONLIFECYCLE quitPending=\(self.quitWasPending) "
                  + "cancelPreservedChild=\(self.cancelPreservedChild) "
                  + "idleApproved=\(idleApproved) ok=\(ok)")
            self.finish(ok)
        }
    }

    private func poll(_ phase: String, until ready: @escaping () -> Bool, then next: @escaping () -> Void) {
        self.phase = phase
        if ready() { next(); return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            finish(false, reason: "timeout-\(phase)")
            return
        }
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                self.poll(phase, until: ready, then: next)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    private func sleepChild(of shellPID: pid_t) -> pid_t? {
        guard shellPID > 0 else { return nil }
        var children = [pid_t](repeating: 0, count: 128)
        let count = children.withUnsafeMutableBytes {
            proc_listchildpids(shellPID, $0.baseAddress, Int32($0.count))
        }
        for pid in children.prefix(max(0, min(Int(count), children.count))) where pid > 0 {
            var name = [CChar](repeating: 0, count: 1024)
            let bytes = name.withUnsafeMutableBytes {
                proc_name(pid, $0.baseAddress, UInt32($0.count))
            }
            if bytes > 0, String(cString: name) == "sleep" { return pid }
        }
        return nil
    }

    private func finish(_ succeeded: Bool, reason: String? = nil) {
        watchdog?.invalidate()
        watchdog = nil
        if let reason { print("UISESSIONLIFECYCLE FAIL \(reason)") }
        if let pane, let sleepPID, sleepChild(of: pane.surface.shellPid) == sleepPID {
            _ = Darwin.kill(sleepPID, SIGTERM)
        }
        controllers.flatMap(\.panes).forEach { $0.shutdown() }
        PluginManager.shared.deactivateAll()
        Preferences.shared.clearIsolatedStorage()
        fflush(stdout)
        exit(succeeded ? 0 : 1)
    }
}
