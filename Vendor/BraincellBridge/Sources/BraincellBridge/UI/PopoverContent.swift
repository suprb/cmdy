import SwiftUI
import AppKit

// =============================================================================
// PopoverContent — "cards" redesign.
//
// The popover shows one card per binding, each card laid out as:
//
//   [ source — terminal + project ] ─── wire ─── [ target — Chrome / Sim / … ]
//
// All bind entry points consolidate into a single "+" button at the top of the
// cards section, which drops down a two-column ConnectPicker (Source × Target).
//
// MCP setup state collapses to a single one-line chip at the bottom. cmdy
// registers its panes directly; Bridge never installs a shell hook.
// Click the chip to expand the full install steps; auto-expanded if either
// piece is not yet installed.
//
// Visual language echoes WireOverlayController:
//   - bridge-blue accent (#3B82F6) for wires + the "+" button
//   - 6.5pt endpoint dots, 2.4pt stroke
//   - solid stroke + sliding bright "comet" gradient when active
//
// Frame is the same 380×520 the bridge has always used.
// =============================================================================

/// Root view of the menu bar popover. Cards-style binding list with a
/// consolidated Source × Target picker.
///
/// IMPORTANT: the `init` signature here is the contract with `BridgeAppDelegate`.
/// Do not change which callbacks exist or their types — they are wired in there.
struct PopoverContent: View {
    @ObservedObject var appState: BridgeAppState
    /// Observe the nested stores explicitly — `@ObservedObject var appState` alone won't
    /// receive notifications when `registry.sessions` or `bindings.bindings` change.
    @ObservedObject var registry: TerminalRegistry
    @ObservedObject var bindings: BindingStore

    /// Bind this session to Chrome. Second arg = useMyChrome (true → user's real
    /// profile dir; false → isolated tmp dir).
    let onBindChrome: (String, Bool) -> Void
    /// Bind this session to its current project as a Mac app project (the
    /// MacAppAdapter will own its build/run/observe loop). Only meaningful when
    /// the project's directory looks like a Swift Package or Xcode project.
    let onBindMacApp: (String) -> Void
    /// Bind this session to a booted iOS Simulator. Second arg is the
    /// explicit UDID to bind to; nil picks the first booted (back-compat
    /// with the single-sim case). The popover surfaces a per-sim menu
    /// entry when multiple sims are booted.
    let onBindSimulator: (String, String?) -> Void
    /// Bind this session to an already-running macOS app, identified by
    /// bundle id. Surfaced as a "Bind Native App: <name>" submenu populated
    /// from `appState.runningNativeApps` (refreshed on popover open).
    let onBindNativeApp: (String, String) -> Void

    /// Unbind ALL sessions in a project group. Sessions that share a project
    /// share an adapter (auto-bound siblings); unbind has to drop them all so
    /// the ref count reaches zero and Chrome actually closes.
    let onUnbindGroup: ([String]) -> Void
    let onUnbind: (String) -> Void
    /// Toggle the in-page inspector toolbar in this session's bound Chrome.
    let onToggleInspector: (String, Bool) -> Void
    /// Inject a shell command into the bound session's terminal (presses Return).
    /// Used by the "Start <dev command>" affordance.
    let onRunCommand: (String, String) -> Void
    /// Re-open the bound Chrome window after the user closed it. Reuses the
    /// same profile dir + restores last URL.
    let onReopenChrome: (String) -> Void
    /// Wipe all sessions + bindings + adapters. Useful when stale state
    /// accumulates from dev-cycle terminal churn.
    let onResetAll: () -> Void

    // MARK: - Setup state

    @State private var mcpInstallState: BridgeSetup.SetupResult? = nil
    @State private var mcpAlreadyRegistered = false
    @State private var mcpInstalling = false
    @State private var setupExpanded = false
    @State private var mcpCopied = false

    // MARK: - Picker / menu state

    @State private var showConnectPicker = false
    @State private var confirmingReset = false

    init(
        appState: BridgeAppState,
        onBindChrome: @escaping (String, Bool) -> Void,
        onBindMacApp: @escaping (String) -> Void = { _ in },
        onBindSimulator: @escaping (String, String?) -> Void = { _, _ in },
        onBindNativeApp: @escaping (String, String) -> Void = { _, _ in },
        onUnbind: @escaping (String) -> Void,
        onUnbindGroup: @escaping ([String]) -> Void = { _ in },
        onToggleInspector: @escaping (String, Bool) -> Void = { _, _ in },
        onRunCommand: @escaping (String, String) -> Void = { _, _ in },
        onReopenChrome: @escaping (String) -> Void = { _ in },
        onResetAll: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.registry = appState.registry
        self.bindings = appState.bindings
        self.onBindChrome = onBindChrome
        self.onBindMacApp = onBindMacApp
        self.onBindSimulator = onBindSimulator
        self.onBindNativeApp = onBindNativeApp
        self.onUnbind = onUnbind
        self.onUnbindGroup = onUnbindGroup
        self.onToggleInspector = onToggleInspector
        self.onRunCommand = onRunCommand
        self.onReopenChrome = onReopenChrome
        self.onResetAll = onResetAll
    }

    /// Heuristic: does `projectPath` look like a Mac app project we can build?
    /// Checks for `Package.swift`, `*.xcodeproj`, or `*.xcworkspace` directly
    /// in the directory. Used to gate the "Bind Mac App" popover button.
    static func isMacAppProject(at projectPath: String?) -> Bool {
        guard let path = projectPath, !path.isEmpty,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        for entry in contents {
            if entry == "Package.swift" { return true }
            if entry.hasSuffix(".xcodeproj") || entry.hasSuffix(".xcworkspace") { return true }
        }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    bindingsSection
                    if showSetupExpanded {
                        setupExpandedView
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            Divider().opacity(0.4)
            footerChip
        }
        .frame(width: 380, height: 520, alignment: .topLeading)
        .background(.regularMaterial)
        .onAppear {
            refreshSetupState()
            if appState.connectRequest != nil { showConnectPicker = true }
        }
        .onChange(of: appState.connectRequest?.id) { _, _ in
            guard appState.connectRequest != nil else { return }
            withAnimation(.easeInOut(duration: 0.18)) { showConnectPicker = true }
        }
        // Sheet for the Connect picker — drops over the popover content with
        // a soft material, mirroring the "presented over" feel without
        // requiring a separate NSWindow. A faint dim layer underneath
        // catches outside taps so the user can dismiss without reaching
        // the X button.
        .overlay {
            if showConnectPicker {
                ZStack {
                    Color.black.opacity(0.18)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.connectRequest = nil
                            withAnimation(.easeInOut(duration: 0.18)) { showConnectPicker = false }
                        }
                    VStack {
                        ConnectPicker(
                            sessions: registry.sessions.sorted { $0.registeredAt < $1.registeredAt },
                            bindings: bindings.bindings,
                            bootedSimulators: appState.bootedSimulators,
                            runningNativeApps: appState.runningNativeApps,
                            initialSessionId: appState.connectRequest?.sessionId,
                            onConnectExisting: { sessionId, target in
                                applyBind(sessionId: sessionId, target: target)
                                appState.connectRequest = nil
                                withAnimation(.easeInOut(duration: 0.18)) { showConnectPicker = false }
                            },
                            onCancel: {
                                appState.connectRequest = nil
                                withAnimation(.easeInOut(duration: 0.18)) { showConnectPicker = false }
                            }
                        )
                        .id(appState.connectRequest?.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BridgeStyle.accent)
            Text("Bridge")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            // "..." menu — out-of-the-way home for Reset all + Quit
            Menu {
                Button(confirmingReset ? "Confirm reset?" : "Reset all bindings", role: .destructive) {
                    if confirmingReset {
                        onResetAll()
                        confirmingReset = false
                    } else {
                        confirmingReset = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            confirmingReset = false
                        }
                    }
                }
                Divider()
                Button("Quit Bridge") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Bindings section

    private var bindingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Connections")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(bindingCardModels.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Button(action: openConnectPicker) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(BridgeStyle.accent)
                }
                .buttonStyle(.plain)
                .help("Connect a terminal to a target")
            }

            // Idb missing hint — only when relevant (sim binding or booted sim).
            idbMissingHint

            if bindingCardModels.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(bindingCardModels) { model in
                        BindingCard(
                            model: model,
                            inspectorOn: model.kind == .group
                                ? group(forCard: model).map { anyInspectorOn($0) } ?? false
                                : appState.chromeAdapters[model.primarySessionId]?.inspectorEnabled ?? false,
                            projectInfo: model.kind == .group
                                ? group(forCard: model).flatMap { anyProjectInfo($0) }
                                : appState.projectInfos[model.primarySessionId],
                            launchError: model.kind == .group
                                ? group(forCard: model).flatMap { anyLaunchError($0) }
                                : appState.lastLaunchErrors[model.primarySessionId],
                            activityPulse: appState.activityPulses[model.primarySessionId],
                            onUnbind: {
                                if model.kind == .group, let g = group(forCard: model) {
                                    onUnbindGroup(g.sessions.map { $0.id })
                                } else {
                                    onUnbind(model.primarySessionId)
                                }
                            },
                            onReopenChrome: { onReopenChrome(model.primarySessionId) },
                            onToggleInspector: { enabled in onToggleInspector(model.primarySessionId, enabled) },
                            onRunCommand: { cmd in onRunCommand(model.primarySessionId, cmd) }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: bindingCardModels.map(\.id))
            }
        }
    }

    private var emptyState: some View {
        Button(action: openConnectPicker) {
            VStack(alignment: .center, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(BridgeStyle.accent.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "link")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(BridgeStyle.accent)
                }
                Text("Connect a terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Bind a terminal to your browser, app, or simulator.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var idbMissingHint: some View {
        let hasSimBinding = bindings.bindings.values.contains { binding in
            if case .simulator = binding.target { return true }
            return false
        }
        let hasBootedSim = !appState.bootedSimulators.isEmpty
        if !appState.idbInstalled && (hasSimBinding || hasBootedSim) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulator gestures need idb")
                        .font(.system(size: 11, weight: .medium))
                    Text("brew install idb-companion && pip3 install fb-idb")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Copy") {
                    let cmd = "brew install idb-companion && pip3 install fb-idb"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Card models

    /// One row per logical binding. A "card" is either:
    ///   - one session bound to a target, OR
    ///   - a project group (≥2 sessions sharing the same projectPath + binding)
    /// Pending bindings (saved binding, no live session yet) also surface as
    /// rows — the card paints them faded with a "waiting for shell" hint.
    private var bindingCardModels: [BindingCardModel] {
        var models: [BindingCardModel] = []
        var consumedSessionIds: Set<String> = []

        // 1. Group cards (project with ≥2 live sessions).
        let groups = sessionGroups
        for group in groups where group.sessions.count >= 2 && !group.id.isEmpty {
            // Only build a group card if at least one session in the group is bound.
            // Unbound multi-shell projects render as individual cards (no auto-bound
            // adapter exists yet), so the user binds one and the others auto-cascade.
            guard let binding = anyGroupBinding(group) else { continue }
            consumedSessionIds.formUnion(group.sessions.map { $0.id })
            models.append(BindingCardModel(
                id: "group:\(group.id)",
                kind: .group,
                primarySessionId: group.sessions.first?.id ?? "",
                sourceTitle: group.label,
                sourceSubtitle: "\(group.sessions.count) shells",
                target: binding.target,
                isPending: false,
                isAdapterAlive: anyAdapterAlive(group)
            ))
        }

        // 2. Individual session cards.
        let liveIds = Set(registry.sessions.map { $0.id })
        for session in registry.sessions.sorted(by: { $0.registeredAt < $1.registeredAt }) {
            if consumedSessionIds.contains(session.id) { continue }
            let binding = bindings.get(sessionId: session.id)
            // Only show bound sessions in the cards list. Unbound sessions are
            // selected from the ConnectPicker. (Showing every unbound session
            // here was the busy-ness we're getting away from.)
            guard let binding = binding else { continue }
            models.append(BindingCardModel(
                id: "session:\(session.id)",
                kind: .session,
                primarySessionId: session.id,
                sourceTitle: session.displayName,
                sourceSubtitle: session.subtitle,
                target: binding.target,
                isPending: false,
                isAdapterAlive: isAdapterAlive(sessionId: session.id, target: binding.target)
            ))
        }

        // 3. Pending bindings — saved binding without a live session yet.
        for (sid, binding) in bindings.bindings where !liveIds.contains(sid) {
            models.append(BindingCardModel(
                id: "pending:\(sid)",
                kind: .pending,
                primarySessionId: sid,
                sourceTitle: "Waiting for shell",
                sourceSubtitle: "Hit Return in the bound terminal",
                target: binding.target,
                isPending: true,
                isAdapterAlive: false
            ))
        }
        return models
    }

    private func group(forCard card: BindingCardModel) -> SessionGroup? {
        guard card.kind == .group else { return nil }
        let groupKey = String(card.id.dropFirst("group:".count))
        return sessionGroups.first(where: { $0.id == groupKey })
    }

    private func isAdapterAlive(sessionId: String, target: Target) -> Bool {
        switch target {
        case .chrome:
            return appState.chromeAdapters[sessionId]?.isLaunched ?? false
        case .macAppProject:
            return appState.macAppAdapters[sessionId] != nil
        case .simulator, .nativeApp:
            return true
        }
    }

    // MARK: - Group helpers (carried over)

    private func anyGroupBinding(_ group: SessionGroup) -> SessionBinding? {
        for session in group.sessions {
            if let b = bindings.get(sessionId: session.id) { return b }
        }
        return nil
    }
    private func anyAdapterAlive(_ group: SessionGroup) -> Bool {
        group.sessions.contains { appState.chromeAdapters[$0.id]?.isLaunched == true }
    }
    private func anyInspectorOn(_ group: SessionGroup) -> Bool {
        group.sessions.contains { appState.chromeAdapters[$0.id]?.inspectorEnabled == true }
    }
    private func anyProjectInfo(_ group: SessionGroup) -> ProjectAnalyzer.ProjectInfo? {
        for session in group.sessions {
            if let info = appState.projectInfos[session.id] { return info }
        }
        return nil
    }
    private func anyLaunchError(_ group: SessionGroup) -> String? {
        for session in group.sessions {
            if let err = appState.lastLaunchErrors[session.id] { return err }
        }
        return nil
    }

    struct SessionGroup: Identifiable {
        let id: String       // raw projectPath (or "" for unset)
        let label: String    // basename for display
        let sessions: [TerminalSession]
    }

    private var sessionGroups: [SessionGroup] {
        let buckets = Dictionary(grouping: registry.sessions) { $0.projectPath ?? "" }
        return buckets
            .map { (path, sessions) in
                let label = path.isEmpty ? "Other" : (path as NSString).lastPathComponent
                let sorted = sessions.sorted { $0.registeredAt < $1.registeredAt }
                return SessionGroup(id: path, label: label, sessions: sorted)
            }
            .sorted { a, b in
                if a.id.isEmpty { return false }
                if b.id.isEmpty { return true }
                return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            }
    }

    // MARK: - Apply bind

    /// Dispatch an "existing-session × target" choice from the ConnectPicker
    /// to the right callback. Centralised so the picker doesn't need to know
    /// about the four onBind* callbacks.
    private func applyBind(sessionId: String, target: ConnectTarget) {
        switch target {
        case .chromeIsolated:    onBindChrome(sessionId, false)
        case .chromeMyProfile:   onBindChrome(sessionId, true)
        case .macApp:            onBindMacApp(sessionId)
        case .simulator(let udid):       onBindSimulator(sessionId, udid)
        case .nativeApp(let bundleId):   onBindNativeApp(sessionId, bundleId)
        }
    }

    private func openConnectPicker() {
        appState.connectRequest = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            showConnectPicker = true
        }
    }

    // MARK: - Setup chip / expanded setup

    private var showSetupExpanded: Bool {
        // Auto-expand when something is missing on first launch (so the user
        // sees the install steps without having to discover the chip).
        if !mcpAlreadyRegistered { return true }
        return setupExpanded
    }

    private var setupExpandedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 2)
            mcpInstallSection
        }
    }

    private var footerChip: some View {
        Button {
            if mcpAlreadyRegistered {
                withAnimation(.easeInOut(duration: 0.15)) { setupExpanded.toggle() }
            }
        } label: {
            HStack(spacing: 8) {
                statusDot(installed: mcpAlreadyRegistered)
                Text("MCP")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(mcpAlreadyRegistered ? .secondary : .primary)
                Spacer()
                if let port = appState.httpServer?.port {
                    Text(":\(String(port))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text("built \(BuildInfo.shortStamp)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if mcpAlreadyRegistered {
                    Image(systemName: setupExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mcpAlreadyRegistered
              ? "Setup complete — click to view install steps"
              : "Setup incomplete — see install steps above")
    }

    private func statusDot(installed: Bool) -> some View {
        Circle()
            .fill(installed ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
    }

    private func refreshSetupState() {
        DispatchQueue.global(qos: .userInitiated).async {
            let registered = BridgeSetup.isMCPRegistered()
            DispatchQueue.main.async { self.mcpAlreadyRegistered = registered }
        }
    }

    // MARK: - Setup install sections (carried over, lightly reskinned)

    private var mcpInstallSection: some View {
        installSection(
            title: "Claude Code MCP",
            description: "Lets Claude Code call the bridge's tools.",
            installedTitle: "Claude Code MCP — registered",
            isInstalled: mcpAlreadyRegistered || mcpInstallState == .installed || mcpInstallState == .alreadyDone,
            isInstalling: mcpInstalling,
            state: mcpInstallState,
            snippet: mcpSnippet,
            copied: mcpCopied,
            onInstall: {
                mcpInstalling = true
                let stdioPath = mcpPath
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = BridgeSetup.registerMCP(stdioPath: stdioPath)
                    DispatchQueue.main.async {
                        mcpInstalling = false
                        mcpInstallState = result
                        if case .installed = result { mcpAlreadyRegistered = true }
                        if case .alreadyDone = result { mcpAlreadyRegistered = true }
                    }
                }
            },
            onCopy: { copy(string: mcpSnippet, into: $mcpCopied) }
        )
    }

    private var mcpPath: String {
        Bundle.module.url(forResource: "index", withExtension: "js", subdirectory: "mcp")?.path
            ?? "<mcp/index.js not found in bundle>"
    }

    private var mcpSnippet: String {
        "claude mcp add --scope user bridge node \"\(mcpPath)\""
    }

    @ViewBuilder
    private func installSection(
        title: String,
        description: String,
        installedTitle: String,
        isInstalled: Bool,
        isInstalling: Bool,
        state: BridgeSetup.SetupResult?,
        snippet: String,
        copied: Bool,
        onInstall: @escaping () -> Void,
        onCopy: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.green)
                }
                Text(isInstalled ? installedTitle : title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if !isInstalled {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: onInstall) {
                        HStack(spacing: 6) {
                            if isInstalling {
                                ProgressView()
                                    .controlSize(.mini)
                                    .progressViewStyle(.circular)
                                Text("Installing…")
                                    .font(.system(size: 11, weight: .semibold))
                            } else {
                                Text("Install")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isInstalling)
                    Text("or copy & run yourself")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                snippetCard(text: snippet, copied: copied, onCopy: onCopy)
            }
            if case .failed(let msg) = state {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08))
                    )
            }
        }
    }

    private func snippetCard(text: String, copied: Bool, onCopy: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCopy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Color.green : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied" : "Copy")
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func copy(string: String, into flag: Binding<Bool>) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            flag.wrappedValue = false
        }
    }

}

// =============================================================================
// MARK: - Style tokens
// =============================================================================

/// Centralised visual tokens. Anything that ought to be consistent across the
/// popover (and ideally with the on-screen WireOverlay) lives here.
enum BridgeStyle {
    /// Bridge blue — same hex as `WireOverlayController` (#3B82F6).
    static let accent = Color(red: 0.231, green: 0.510, blue: 0.965)
    static let cardCorner: CGFloat = 10
    static let cardPadding: CGFloat = 10
    static let cardSpacing: CGFloat = 8
}

// =============================================================================
// MARK: - BindingCard
// =============================================================================

/// Display model for one card row. Carries everything the card needs to
/// render itself; computed once per popover refresh from the registry +
/// bindings store.
private struct BindingCardModel: Identifiable, Equatable {
    enum Kind { case session, group, pending }
    let id: String
    let kind: Kind
    /// For .group, the first session's id (binding cascades to siblings).
    /// For .pending, the saved binding's sessionId (no live session exists).
    let primarySessionId: String
    let sourceTitle: String
    let sourceSubtitle: String
    let target: Target
    let isPending: Bool
    /// True when the underlying adapter is still alive (Chrome window open,
    /// Mac app launched, etc). False after a Chrome window was closed —
    /// triggers a "Reopen" affordance.
    let isAdapterAlive: Bool
}

/// One horizontal card. Source on the left, mini animated wire in the middle,
/// target on the right. Hover reveals contextual actions.
private struct BindingCard: View {
    let model: BindingCardModel
    let inspectorOn: Bool
    let projectInfo: ProjectAnalyzer.ProjectInfo?
    let launchError: String?
    let activityPulse: ActivityPulse?
    let onUnbind: () -> Void
    let onReopenChrome: () -> Void
    let onToggleInspector: (Bool) -> Void
    let onRunCommand: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top: source — wire — target row.
            HStack(spacing: 8) {
                sourceColumn
                MiniWire(active: isPulsing,
                         direction: activityPulse?.direction ?? .outbound)
                    .frame(width: 60, height: 22)
                targetColumn
            }
            .padding(.horizontal, BridgeStyle.cardPadding)
            .padding(.top, BridgeStyle.cardPadding)

            // Hover: contextual actions row.
            if isHovered && !model.isPending {
                hoverActions
                    .padding(.horizontal, BridgeStyle.cardPadding)
                    .transition(.opacity)
            }

            // Inspector toggle + Start row, when bound to a live Chrome.
            if !model.isPending,
               case .chrome = model.target,
               model.isAdapterAlive {
                chromeAccessoriesRow
                    .padding(.horizontal, BridgeStyle.cardPadding)
            }

            if let err = launchError {
                errorBanner(err)
                    .padding(.horizontal, BridgeStyle.cardPadding)
            }

            Spacer().frame(height: BridgeStyle.cardPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BridgeStyle.cardCorner)
                .fill(.thinMaterial)
                .opacity(model.isPending ? 0.55 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BridgeStyle.cardCorner)
                .strokeBorder(
                    isPulsing ? BridgeStyle.accent.opacity(0.45) : Color.primary.opacity(0.07),
                    lineWidth: isPulsing ? 1 : 0.5
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
        }
        .opacity(model.isPending ? 0.7 : 1)
    }

    // MARK: - Subviews

    private var sourceColumn: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 26, height: 26)
                Image(systemName: model.kind == .group ? "folder.fill" : "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.sourceTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.sourceSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetColumn: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(targetTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(targetSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(BridgeStyle.accent.opacity(model.isPending ? 0.10 : 0.16))
                    .frame(width: 26, height: 26)
                Image(systemName: model.target.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(BridgeStyle.accent.opacity(model.isPending ? 0.55 : 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            if !model.isAdapterAlive, case .chrome = model.target {
                actionPill(label: "Reopen", systemImage: "arrow.clockwise", prominent: true, action: onReopenChrome)
            }
            actionPill(label: "Unbind", systemImage: "xmark.circle", action: onUnbind)
            Spacer()
            statusBadge
        }
    }

    private func actionPill(label: String,
                            systemImage: String,
                            prominent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(prominent
                               ? BridgeStyle.accent.opacity(0.18)
                               : Color.primary.opacity(0.06))
            )
            .foregroundStyle(prominent ? BridgeStyle.accent : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Tiny live/idle/pending indicator on the right side of the hover row.
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusBadgeColor)
                .frame(width: 6, height: 6)
                .modifier(PulseModifier(active: isPulsing))
            Text(statusBadgeLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var statusBadgeColor: Color {
        if model.isPending { return .orange }
        if isPulsing { return BridgeStyle.accent }
        if !model.isAdapterAlive { return .gray }
        return .green
    }

    private var statusBadgeLabel: String {
        if model.isPending { return "Pending" }
        if isPulsing { return "Active" }
        if !model.isAdapterAlive { return "Closed" }
        return "Idle"
    }

    private var chromeAccessoriesRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Inspector")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { inspectorOn },
                    set: { onToggleInspector($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            if let info = projectInfo, let primary = ProjectAnalyzer.primaryRunCommand(for: info) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.green)
                    Text(primary.command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Run") { onRunCommand(primary.command) }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.top, 4)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.85))
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(Color.red.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08))
        )
        .padding(.top, 4)
    }

    // MARK: - Computed

    private var isPulsing: Bool {
        guard let pulse = activityPulse else { return false }
        return pulse.until > Date()
    }

    private var targetTitle: String {
        switch model.target {
        case .chrome:
            return "Chrome"
        case .macAppProject(let path):
            return (path as NSString).lastPathComponent
        case .simulator:
            return "Simulator"
        case .nativeApp(let bid):
            return bundleIdShortName(bid)
        }
    }

    private var targetSubtitle: String {
        switch model.target {
        case .chrome(_, let port):
            return ":\(port)"
        case .macAppProject:
            return "Mac app"
        case .simulator(let udid):
            return String(udid.prefix(8))
        case .nativeApp(let bid):
            return bid
        }
    }

    private func bundleIdShortName(_ bid: String) -> String {
        // "com.apple.MobileSMS" → "MobileSMS"
        bid.split(separator: ".").last.map(String.init) ?? bid
    }
}

// =============================================================================
// MARK: - MiniWire
// =============================================================================

/// Tiny ~60pt-wide echo of WireOverlay. Solid bridge-blue stroke with
/// endpoint dots, plus a sliding "comet" gradient when activity is firing —
/// the same vocabulary the user sees on screen.
private struct MiniWire: View {
    let active: Bool
    let direction: ActivityDirection

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1/60 : 1/30)) { context in
            Canvas { ctx, size in
                let now = context.date.timeIntervalSinceReferenceDate
                let h = size.height
                let w = size.width
                let mid = h / 2
                let pad: CGFloat = 4
                let start = CGPoint(x: pad, y: mid)
                let end = CGPoint(x: w - pad, y: mid)
                var path = Path()
                path.move(to: start)
                let pull = (w - pad * 2) * 0.3
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x + pull, y: start.y - 1),
                    control2: CGPoint(x: end.x - pull, y: end.y + 1)
                )
                // Solid stroke.
                ctx.stroke(path,
                           with: .color(BridgeStyle.accent.opacity(active ? 0.95 : 0.55)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                // Comet overlay when active — phase slides 0..1 along x axis.
                if active {
                    let speed: CGFloat = direction == .outbound ? 1.3 : -1.3
                    var phase = (CGFloat(now) * speed).truncatingRemainder(dividingBy: 1)
                    if phase < 0 { phase += 1 }
                    let cometX = pad + (w - pad * 2) * phase
                    let gradient = Gradient(stops: [
                        .init(color: BridgeStyle.accent.opacity(0), location: 0),
                        .init(color: Color.white.opacity(0.85), location: 0.5),
                        .init(color: BridgeStyle.accent.opacity(0), location: 1),
                    ])
                    ctx.stroke(path,
                               with: .linearGradient(gradient,
                                                     startPoint: CGPoint(x: cometX - 14, y: mid),
                                                     endPoint: CGPoint(x: cometX + 14, y: mid)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
                // Endpoint dots.
                let r: CGFloat = active ? 3.5 : 2.8
                for p in [start, end] {
                    let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(BridgeStyle.accent))
                }
            }
        }
    }
}

/// Subtle pulsing modifier for the live status dot. 0.6 → 1.0 → 0.6 opacity
/// at ~1.5Hz when active, fully opaque otherwise.
private struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(active ? Double(phase) : 1.0)
            .onChange(of: active) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        phase = 0.55
                    }
                } else {
                    phase = 1.0
                }
            }
    }
}

// =============================================================================
// MARK: - ConnectPicker
// =============================================================================

/// Target choice in the picker — narrower than the full Target enum because
/// some need extra parameters (sim UDID, native bundle id) that the picker
/// resolves itself.
private enum ConnectTarget: Identifiable, Equatable {
    case chromeIsolated
    case chromeMyProfile
    case macApp
    case simulator(udid: String)
    case nativeApp(bundleId: String)

    var id: String {
        switch self {
        case .chromeIsolated:    return "chrome.iso"
        case .chromeMyProfile:   return "chrome.my"
        case .macApp:            return "mac"
        case .simulator(let u):  return "sim.\(u)"
        case .nativeApp(let b):  return "native.\(b)"
        }
    }

    var label: String {
        switch self {
        case .chromeIsolated:        return "Chrome (isolated)"
        case .chromeMyProfile:       return "Chrome (my profile)"
        case .macApp:                return "Mac App project"
        case .simulator:             return "iOS Simulator"
        case .nativeApp:             return "Native app"
        }
    }

    var systemImage: String {
        switch self {
        case .chromeIsolated, .chromeMyProfile: return "globe"
        case .macApp:                            return "hammer"
        case .simulator:                         return "iphone"
        case .nativeApp:                         return "app.dashed"
        }
    }
}

/// Source choice in the picker. Every source is a pane registered directly by
/// cmdy; generic terminal discovery and shell-hook registration are gone.
private enum ConnectSource: Identifiable, Equatable {
    case session(id: String, title: String, subtitle: String, alreadyBoundTargetSymbol: String?)

    var id: String {
        switch self {
        case .session(let id, _, _, _): return "session.\(id)"
        }
    }
}

/// Two-column Source × Target picker. Floats in over the popover content.
/// Filters target options by what makes sense for the chosen source (e.g.
/// "Mac App project" only appears when the source has a Mac-app cwd).
private struct ConnectPicker: View {
    let sessions: [TerminalSession]
    let bindings: [String: SessionBinding]
    let bootedSimulators: [[String: Any]]
    let runningNativeApps: [[String: Any]]
    let onConnectExisting: (String, ConnectTarget) -> Void
    let onCancel: () -> Void

    @State private var selectedSource: ConnectSource?
    @State private var selectedTarget: ConnectTarget?

    init(
        sessions: [TerminalSession],
        bindings: [String: SessionBinding],
        bootedSimulators: [[String: Any]],
        runningNativeApps: [[String: Any]],
        initialSessionId: String?,
        onConnectExisting: @escaping (String, ConnectTarget) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.sessions = sessions
        self.bindings = bindings
        self.bootedSimulators = bootedSimulators
        self.runningNativeApps = runningNativeApps
        self.onConnectExisting = onConnectExisting
        self.onCancel = onCancel

        if let session = sessions.first(where: { $0.id == initialSessionId }) {
            _selectedSource = State(initialValue: .session(
                id: session.id,
                title: session.displayName,
                subtitle: session.subtitle,
                alreadyBoundTargetSymbol: bindings[session.id]?.target.symbolName
            ))
        } else {
            _selectedSource = State(initialValue: nil)
        }
        _selectedTarget = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("New connection")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }

            HStack(alignment: .top, spacing: 10) {
                column(
                    title: "Source",
                    items: sourceItems.map { source in
                        ColumnItem(
                            id: source.id,
                            title: sourceTitle(source),
                            subtitle: sourceSubtitle(source),
                            systemImage: sourceSymbol(source),
                            badge: sourceBadge(source),
                            selected: selectedSource == source,
                            onTap: {
                                selectedSource = source
                                // Drop the target if it isn't valid for the
                                // new source (e.g. picked Mac App, then
                                // switched to a non-buildable session).
                                if let t = selectedTarget, !targetItems.contains(t) {
                                    selectedTarget = nil
                                }
                            }
                        )
                    }
                )
                column(
                    title: "Target",
                    items: targetItems.map { target in
                        ColumnItem(
                            id: target.id,
                            title: targetTitle(target),
                            subtitle: targetSubtitle(target),
                            systemImage: target.systemImage,
                            badge: nil,
                            selected: selectedTarget == target,
                            onTap: { selectedTarget = target }
                        )
                    }
                )
            }
            .frame(height: 220)

            HStack {
                if let s = selectedSource, let t = selectedTarget {
                    Text("\(sourceTitle(s)) → \(targetTitle(t))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Pick a source and a target.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                Button("Connect") { connect() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedSource == nil || selectedTarget == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
        .padding(10)
    }

    // MARK: - Source / Target candidate lists

    private var sourceItems: [ConnectSource] {
        sessions.map { s in
            let bound = bindings[s.id]
            return .session(
                id: s.id,
                title: s.displayName,
                subtitle: s.subtitle,
                alreadyBoundTargetSymbol: bound?.target.symbolName
            )
        }
    }

    /// Targets compatible with the chosen source.
    /// Chrome, Simulator, and native apps work for every cmdy pane; Mac App
    /// appears only when the pane's cwd is a buildable project.
    private var targetItems: [ConnectTarget] {
        var items: [ConnectTarget] = []
        items.append(.chromeIsolated)
        if case .session = selectedSource {
            items.append(.chromeMyProfile)
        }

        // Mac App: only when a real session is selected and its cwd looks
        // buildable. New-terminal can't do Mac App (we'd have no source path).
        if case .session(let id, _, _, _) = selectedSource {
            let session = sessions.first(where: { $0.id == id })
            if PopoverContent.isMacAppProject(at: session?.projectPath) {
                items.append(.macApp)
            }
        }
        for sim in bootedSimulators {
            if let udid = sim["udid"] as? String, !udid.isEmpty {
                items.append(.simulator(udid: udid))
            }
        }
        for app in runningNativeApps {
            if let bid = app["bundleId"] as? String, !bid.isEmpty {
                items.append(.nativeApp(bundleId: bid))
            }
        }
        return items
    }

    // MARK: - Cell labels

    private func sourceTitle(_ source: ConnectSource) -> String {
        switch source {
        case .session(_, let title, _, _): return title
        }
    }

    private func sourceSubtitle(_ source: ConnectSource) -> String {
        switch source {
        case .session(_, _, let subtitle, _): return subtitle
        }
    }

    private func sourceSymbol(_ source: ConnectSource) -> String {
        switch source {
        case .session: return "terminal"
        }
    }

    private func sourceBadge(_ source: ConnectSource) -> String? {
        if case .session(_, _, _, let sym) = source { return sym }
        return nil
    }

    private func targetTitle(_ target: ConnectTarget) -> String {
        switch target {
        case .chromeIsolated:                       return "Chrome"
        case .chromeMyProfile:                      return "Chrome (my profile)"
        case .macApp:                               return "Mac App"
        case .simulator(let udid):
            for sim in bootedSimulators {
                if (sim["udid"] as? String) == udid {
                    return (sim["name"] as? String) ?? "Simulator"
                }
            }
            return "Simulator"
        case .nativeApp(let bid):
            for app in runningNativeApps {
                if (app["bundleId"] as? String) == bid {
                    return (app["name"] as? String) ?? bid
                }
            }
            return bid
        }
    }

    private func targetSubtitle(_ target: ConnectTarget) -> String {
        switch target {
        case .chromeIsolated:        return "Isolated profile"
        case .chromeMyProfile:       return "Real user profile"
        case .macApp:                return "Build, run, drive"
        case .simulator(let udid):   return String(udid.prefix(8))
        case .nativeApp(let bid):    return bid
        }
    }

    // MARK: - Connect

    private func connect() {
        guard let source = selectedSource, let target = selectedTarget else { return }
        switch source {
        case .session(let id, _, _, _):
            onConnectExisting(id, target)
        }
    }

    // MARK: - Column scaffold

    private struct ColumnItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        /// Optional secondary symbol shown on the right of a session row to
        /// indicate "this session is already bound to <target>" — lets the
        /// user avoid stomping a working binding by accident.
        let badge: String?
        let selected: Bool
        let onTap: () -> Void
    }

    private func column(title: String, items: [ColumnItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 2)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        Button(action: item.onTap) {
                            HStack(spacing: 8) {
                                Image(systemName: item.systemImage)
                                    .font(.system(size: 11))
                                    .frame(width: 16)
                                    .foregroundStyle(item.selected ? BridgeStyle.accent : .secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(item.subtitle)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if let badge = item.badge {
                                    Image(systemName: badge)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(item.selected
                                          ? BridgeStyle.accent.opacity(0.16)
                                          : Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(item.selected
                                                  ? BridgeStyle.accent.opacity(0.5)
                                                  : Color.clear,
                                                  lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .frame(maxWidth: .infinity)
    }
}
