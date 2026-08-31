import AppKit
import CmdySDK

// swarm — the colony, at a glance: the session switcher for the agent era. Two surfaces, one truth:
// ⌃⌥A opens an inline list of every pane across every window (which agent
// runs where, who's waiting, which split) — pick one and you're there. And a
// menu-bar item (◆ N, ● N when someone needs you) tracks it all from any app
// or Space; click to jump into cmdy.

final class Swarm: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var cmdy: Cmdy!
    private var panelId: String?
    private var sigTerm: DispatchSourceSignal?
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?
    private var lastPanes: [[String: Any]] = []
    private var compositionSurfaceID: String?
    private var compositionFields: [String: String] = [:]
    private var compositionAgents: [[String: Any]] = []
    private let workspaceContributionID = "swarm-agents"
    private enum WorkspaceContributionState: Equatable {
        case hidden
        case opening
        case visible
        case closing
    }
    private var workspaceContributionState = WorkspaceContributionState.hidden
    private var workspaceContributionSequence = 0
    private var workspaceRefreshWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let sdk = Cmdy() else {
            fputs(
                "swarm: not launched by \(HostProductIdentity.slug) (missing \(HostProductIdentity.environmentPrefix)_* env)\n",
                stderr)
            exit(1)
        }
        cmdy = sdk

        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigTerm = src

        cmdy.registerCommand(id: "swarm.overview", title: "Agent Sessions…", plugin: "Swarm")
        cmdy.registerCommand(id: "swarm.compose", title: "Gather Agent Sessions…", plugin: "Swarm")
        cmdy.registerHotKey(id: "swarm.overview", keyCode: 0 /* A */,
                               modifiers: [.control, .option])
        cmdy.onEvent = { [weak self] event in self?.handle(event) }
        cmdy.listen()
        cmdy.onParentExit = { NSApp.terminate(nil) }

        setupStatusItem()
        scheduleWorkspaceContributionRefresh()
        NSLog("swarm: ready (⌃⌥A — every session, one list; ◆ in the menu bar)")
    }

    private func handle(_ event: [String: Any]) {
        switch event["kind"] as? String {
        case "command", "hotkey":
            switch event["id"] as? String {
            case "swarm.overview": showOverview()
            case "swarm.compose": showCompositionForm()
            default: break
            }
        case "ui":
            if event["contribution"] as? String == workspaceContributionID,
               event["event"] as? String == "action",
               let paneID = event["item"] as? String {
                cmdy.post("/v1/panes/\(paneID)/focus")
                return
            }
            guard event["panel"] as? String == panelId else { return }
            switch event["event"] as? String {
            case "pick":
                let picked = event["value"] as? String
                if let id = panelId { cmdy.dismissPanel(id) }
                panelId = nil
                if picked == "swarm.compose" {
                    showCompositionForm()
                } else if let paneId = picked, !paneId.isEmpty {
                    cmdy.post("/v1/panes/\(paneId)/focus")
                }
            case "dismissed":
                panelId = nil
            default: break
            }
        case "surface-action":
            guard event["surface"] as? String == compositionSurfaceID,
                  let action = event["action"] as? String else { return }
            let selected: [String]
            if action == "combine-all" {
                selected = compositionAgents.compactMap { $0["id"] as? String }
            } else if action == "combine-selected" {
                let values = event["values"] as? [String: Any] ?? [:]
                selected = compositionAgents.compactMap { pane in
                    guard let paneID = pane["id"] as? String,
                          let field = compositionFields.first(where: {
                              $0.value == paneID
                          })?.key,
                          values[field] as? Bool == true else { return nil }
                    return paneID
                }
            } else { return }
            compose(selected)
        case "surface-dismissed":
            if event["surface"] as? String == compositionSurfaceID {
                compositionSurfaceID = nil
                compositionFields = [:]
                compositionAgents = []
            }
        case "pane-opened", "pane-updated", "pane-closed", "attention",
             "command-started", "command-finished":
            scheduleWorkspaceContributionRefresh()
        default: break
        }
    }

    // MARK: - Adaptive Frame Navigator contribution

    private func scheduleWorkspaceContributionRefresh() {
        workspaceRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshWorkspaceContribution() }
        workspaceRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func refreshWorkspaceContribution() {
        cmdy.panes { [weak self] panes in
            guard let self else { return }
            let agents = panes.filter { ($0["ai"] as? String) != nil }
                .sorted { self.rank($0) < self.rank($1) }
            if agents.isEmpty {
                guard self.workspaceContributionState == .visible else { return }
                self.workspaceContributionState = .closing
                self.cmdy.dismissWorkspaceContribution(self.workspaceContributionID) {
                    [weak self] _ in
                    guard let self else { return }
                    self.workspaceContributionState = .hidden
                    self.scheduleWorkspaceContributionRefresh()
                }
                return
            }

            let items = agents.compactMap { pane -> CmdyWorkspaceItem? in
                guard let paneID = pane["id"] as? String else { return nil }
                let name = pane["ai"] as? String ?? "agent"
                let dir = (pane["cwd"] as? String)
                    .map { ($0 as NSString).lastPathComponent } ?? "shell"
                let attention = pane["attention"] as? Bool == true
                let focused = pane["focused"] as? Bool == true
                return CmdyWorkspaceItem(
                    id: paneID, title: name, detail: "\(dir)\(focused ? " · here" : "")",
                    badge: attention ? "WAIT" : "AGENT",
                    status: attention ? .attention : .active,
                    action: "focus")
            }
            if self.workspaceContributionState == .visible {
                self.workspaceContributionSequence += 1
            }
            let contribution = CmdyWorkspaceContribution(
                id: self.workspaceContributionID, location: .navigator,
                title: "Agents", priority: 100,
                sequence: self.workspaceContributionSequence, items: items)
            switch self.workspaceContributionState {
            case .visible:
                self.cmdy.updateWorkspaceContribution(contribution)
            case .hidden:
                self.workspaceContributionState = .opening
                self.cmdy.openWorkspaceContribution(contribution) { [weak self] opened in
                    guard let self else { return }
                    self.workspaceContributionState = opened ? .visible : .hidden
                    self.scheduleWorkspaceContributionRefresh()
                }
            case .opening, .closing:
                break
            }
        }
    }

    // MARK: - Shared shaping

    private func rank(_ p: [String: Any]) -> (Int, Int, Int, Int) {
        ((p["attention"] as? Bool == true) ? 0 : 1,
         (p["ai"] as? String) != nil ? 0 : 1,
         p["windowIndex"] as? Int ?? 99,
         p["paneIndex"] as? Int ?? 99)
    }

    // MARK: - The inline panel (⌃⌥A)

    private func showOverview() {
        cmdy.panes { [weak self] panes in
            guard let self else { return }
            let sorted = panes.sorted { self.rank($0) < self.rank($1) }
            var items: [[String: Any]] = []
            let agents = sorted.filter { ($0["ai"] as? String) != nil }
            if agents.count >= 2 {
                items.append([
                    "id": "swarm.compose",
                    "title": "▦ Gather agent sessions into one window…",
                    "subtitle": "choose agents or combine all · live shells stay running",
                ])
            }
            items.append(contentsOf: sorted.map { p in
                let ai = p["ai"] as? String
                let attention = p["attention"] as? Bool == true
                let focused = p["focused"] as? Bool == true
                let title = p["title"] as? String ?? "shell"
                let dir = (p["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
                let w = p["windowIndex"] as? Int ?? 0
                let s = p["paneIndex"] as? Int ?? 0
                let dot = attention ? "● " : (ai != nil ? "◆ " : "")
                let name = ai ?? title
                var subtitle = "window \(w) · split \(s)"
                if !dir.isEmpty { subtitle += " · \(dir)" }
                if focused { subtitle += " · here" }
                return ["id": p["id"] as? String ?? "",
                        "title": "\(dot)\(name)\(ai != nil && !dir.isEmpty ? " — \(dir)" : "")",
                        "subtitle": subtitle]
            })
            let waiting = sorted.filter { $0["attention"] as? Bool == true }
            let hint = waiting.isEmpty
                ? "\(agents.count) agent\(agents.count == 1 ? "" : "s") · ↩ jump · esc"
                : "● \(waiting.count) waiting for you · ↩ jump · esc"
            self.cmdy.openPanel([
                "mode": "list",
                "title": "agent sessions",
                "items": items,
                "placeholder": "jump to a session…",
                "hint": hint,
            ]) { [weak self] id in self?.panelId = id }
        }
    }

    // MARK: - Agent workspace composition

    private func showCompositionForm() {
        cmdy.panes { [weak self] panes in
            guard let self else { return }
            let agents = panes.filter { ($0["ai"] as? String) != nil }
                .sorted { self.rank($0) < self.rank($1) }
            guard agents.count >= 2 else {
                self.cmdy.notify(
                    title: "Swarm needs two agents",
                    body: "Start at least two agent sessions before gathering them.")
                return
            }
            if let old = self.compositionSurfaceID { self.cmdy.dismissSurface(old) }
            let surfaceID = "swarm-gather-\(UUID().uuidString.lowercased())"
            var fields: [CmdySurfaceField] = []
            var fieldMap: [String: String] = [:]
            var fallback: [String] = []
            for (index, pane) in agents.enumerated() {
                guard let paneID = pane["id"] as? String else { continue }
                let fieldID = "agent-\(index + 1)"
                let ai = pane["ai"] as? String ?? "agent"
                let dir = (pane["cwd"] as? String)
                    .map { ($0 as NSString).lastPathComponent } ?? "shell"
                let window = pane["windowIndex"] as? Int ?? 0
                let split = pane["paneIndex"] as? Int ?? 0
                let waiting = pane["attention"] as? Bool == true
                let label = "\(waiting ? "● " : "◆ ")\(ai) — \(dir) · window \(window), split \(split)"
                fields.append(CmdySurfaceField(
                    id: fieldID, label: label, kind: .toggle,
                    value: .bool(waiting)))
                fieldMap[fieldID] = paneID
                fallback.append("[\(waiting ? "x" : " ")] \(label)")
            }
            guard let hostPane = (agents.first { $0["focused"] as? Bool == true }
                ?? agents.first)?["id"] as? String else { return }
            self.compositionSurfaceID = surfaceID
            self.compositionFields = fieldMap
            self.compositionAgents = agents
            let document = CmdySurfaceDocument(
                id: surfaceID,
                kind: .form,
                title: "Gather Agent Sessions",
                pane: hostPane,
                block: "current",
                summary: "\(agents.count) live agents · select two or more, or gather all",
                fallback: fallback.joined(separator: "\n"),
                fields: fields,
                actions: [
                    CmdySurfaceAction(
                        id: "combine-selected", title: "Gather Selected",
                        effect: .mutate, style: .primary,
                        confirmation: "Move the selected live agent panes into one new terminal window? Their processes keep running."),
                    CmdySurfaceAction(
                        id: "combine-all", title: "Gather All",
                        effect: .mutate,
                        confirmation: "Move every live agent pane into one new terminal window? Their processes keep running."),
                ])
            // Bring the host pane forward so a menu-bar invocation reveals the
            // native form instead of quietly opening it behind another app.
            self.cmdy.post("/v1/panes/\(hostPane)/focus")
            self.cmdy.openSurface(document) { [weak self] response in
                guard response?["surface"] as? String != nil else {
                    let message = response?["error"] as? String
                        ?? "The agent chooser could not attach to the current command block."
                    self?.cmdy.notify(title: "Swarm chooser unavailable", body: message)
                    self?.compositionSurfaceID = nil
                    self?.compositionFields = [:]
                    self?.compositionAgents = []
                    return
                }
            }
        }
    }

    private func compose(_ paneIDs: [String]) {
        guard paneIDs.count >= 2 else {
            cmdy.notify(title: "Choose at least two agents",
                           body: "Select two or more sessions, then gather them.")
            return
        }
        cmdy.composePanes(paneIDs) { [weak self] response in
            guard let self else { return }
            if response?["ok"] as? Bool == true {
                let count = response?["count"] as? Int ?? paneIDs.count
                if let id = self.compositionSurfaceID { self.cmdy.dismissSurface(id) }
                self.compositionSurfaceID = nil
                self.compositionFields = [:]
                self.compositionAgents = []
                self.cmdy.notify(
                    title: "Agent workspace ready",
                    body: "Gathered \(count) live sessions into one window.")
                self.refreshStatus()
            } else {
                self.cmdy.notify(
                    title: "Could not gather agents",
                    body: response?["error"] as? String ?? "One of the panes is no longer available.")
            }
        }
    }

    // MARK: - The menu bar (everywhere else)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item
        refreshStatus()
        // A gentle poll keeps the count honest (attention changes don't
        // stream today); one tiny local JSON GET every few seconds.
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        t.tolerance = 1.0
        statusTimer = t
    }

    private func refreshStatus() {
        cmdy.panes { [weak self] panes in
            DispatchQueue.main.async {
                guard let self, let button = self.statusItem?.button else { return }
                self.lastPanes = panes
                let agents = panes.filter { ($0["ai"] as? String) != nil }
                let waiting = panes.filter { $0["attention"] as? Bool == true }
                if !waiting.isEmpty {
                    button.attributedTitle = NSAttributedString(
                        string: "● \(waiting.count)",
                        attributes: [.foregroundColor: NSColor.systemOrange,
                                     .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)])
                } else if !agents.isEmpty {
                    button.attributedTitle = NSAttributedString(
                        string: "◆ \(agents.count)",
                        attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
                } else {
                    button.attributedTitle = NSAttributedString(
                        string: "◆",
                        attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                                     .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
                }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sorted = lastPanes.sorted { rank($0) < rank($1) }
        if sorted.isEmpty {
            menu.addItem(NSMenuItem(title: "No sessions", action: nil, keyEquivalent: ""))
            return
        }
        for p in sorted {
            let ai = p["ai"] as? String
            let attention = p["attention"] as? Bool == true
            let title = p["title"] as? String ?? "shell"
            let dir = (p["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
            let w = p["windowIndex"] as? Int ?? 0
            let sp = p["paneIndex"] as? Int ?? 0
            let dot = attention ? "● " : (ai != nil ? "◆ " : "    ")
            let name = ai ?? title
            let label = "\(dot)\(name)\(dir.isEmpty ? "" : " — \(dir)")"
            let item = NSMenuItem(title: label, action: #selector(jumpToPane(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p["id"] as? String
            item.toolTip = "window \(w) · split \(sp)"
            if attention {
                item.attributedTitle = NSAttributedString(
                    string: label, attributes: [.foregroundColor: NSColor.systemOrange])
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let agents = sorted.filter { ($0["ai"] as? String) != nil }
        let choose = NSMenuItem(
            title: "Gather Agent Sessions…",
            action: #selector(showCompositionFormFromMenu(_:)), keyEquivalent: "")
        choose.target = self
        choose.isEnabled = agents.count >= 2
        menu.addItem(choose)
        let gatherAll = NSMenuItem(
            title: "Gather All Agents into New Window",
            action: #selector(gatherAllFromMenu(_:)), keyEquivalent: "")
        gatherAll.target = self
        gatherAll.isEnabled = agents.count >= 2
        menu.addItem(gatherAll)
        menu.addItem(.separator())
        let hint = NSMenuItem(
            title: "⌃⌥A in \(HostProductIdentity.titleName) for the full panel",
            action: nil,
            keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        refreshStatus()   // stay fresh while the menu is open
    }

    @objc private func jumpToPane(_ sender: NSMenuItem) {
        guard let paneId = sender.representedObject as? String else { return }
        cmdy.post("/v1/panes/\(paneId)/focus")
    }

    @objc private func showCompositionFormFromMenu(_ sender: NSMenuItem) {
        showCompositionForm()
    }

    @objc private func gatherAllFromMenu(_ sender: NSMenuItem) {
        let agents = lastPanes.filter { ($0["ai"] as? String) != nil }
        compose(agents.compactMap { $0["id"] as? String })
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Swarm()
app.delegate = delegate
app.run()
