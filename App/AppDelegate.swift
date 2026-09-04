import AppKit
import ProductIdentity
import SwiftUI
import CmdyKit
import CmdyGPU

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [TerminalWindowController] = []
    lazy var windowGridCoordinator = WindowGridCoordinator(appDelegate: self)
    /// AppKit windows remain the durable tab/session owners, but while the
    /// left sidebar is visible they are temporarily ungrouped so macOS does
    /// not draw a second tab strip. This set preserves ordering and selection
    /// across that presentation switch.
    private final class WorkspaceTabSet {
        let identifier: String
        var controllers: [TerminalWindowController]
        weak var selected: TerminalWindowController?
        var usesSidebar = false
        var isTransitioning = false

        init(controllers: [TerminalWindowController],
             selected: TerminalWindowController?,
             identifier: String = UUID().uuidString) {
            self.identifier = identifier
            self.controllers = controllers
            self.selected = selected
        }
    }
    private enum WorkspaceSessionKey {
        static let group = "workspaceTabGroup"
        static let index = "workspaceTabIndex"
        static let selected = "workspaceTabSelected"
        static let sidebar = "workspaceTabSidebar"
    }
    private struct RestoredSessionEntry {
        let originalIndex: Int
        let controller: TerminalWindowController
        let groupIdentifier: String
        let tabIndex: Int
        let wasSelected: Bool
    }
    private var workspaceTabSets: [WorkspaceTabSet] = []
    private var isTerminating = false
    private var sidebarCloseHandoffSuppressionDepth = 0
    private var editorTerminationApproved = false
    private var standardKeybindings: StandardKeybindings?
    private struct ClosedLayout {
        let layout: [String: Any]
        let closedAt: Date
    }
    private var closedLayouts: [ClosedLayout] = []
    private weak var reopenedController: TerminalWindowController?
    private var suppressClosedCapture = Set<ObjectIdentifier>()
    /// Live marketplace browse session (preview bookkeeping) — see MarketplaceUI.
    var marketplaceSession: MarketplaceSession?
    /// `--ui-test-merge`: self-driving smoke test (two windows → merge into
    /// splits → report → exit). Disables session restore/save for the run.
    private let uiTestMerge = CommandLine.arguments.contains("--ui-test-merge")
    /// `--ui-test-compose`: move three live PTYs from two donor windows into
    /// one grid and prove pane identity/process continuity.
    private let uiTestCompose = CommandLine.arguments.contains("--ui-test-compose")
    /// `--ui-test-workspace-tabs`: create a sidebar workspace, switch it to
    /// native tabs and back, then prove no tab owner was lost in the handoff.
    private let uiTestWorkspaceTabs =
        CommandLine.arguments.contains("--ui-test-workspace-tabs")
    /// `--ui-test-workspace-dock`: reserve a companion strip on only the
    /// selected sidebar tab. Navigator and Inspector must remain visible while
    /// the strip compresses only the terminal column.
    private let uiTestWorkspaceDock =
        CommandLine.arguments.contains("--ui-test-workspace-dock")
    /// `--ui-test-sidebar-resize`: drag the real Navigator divider while the
    /// Inspector is disabled and prove the hidden trailing rail stays hidden.
    private let uiTestSidebarResize =
        CommandLine.arguments.contains("--ui-test-sidebar-resize")
    /// `--ui-test-sidebar-close`: close the selected sidebar tab through the
    /// real Command-W route and prove its replacement is visible immediately.
    private let uiTestSidebarClose =
        CommandLine.arguments.contains("--ui-test-sidebar-close")
    /// `--ui-test-sidebar-tab-drag`: tear a hidden Navigator tab into its own
    /// window, then route the same live pane through a directional area drop.
    private let uiTestSidebarTabDrag =
        CommandLine.arguments.contains("--ui-test-sidebar-tab-drag")
    /// `--ui-test-split-affordance`: verify the pane-local close and detach
    /// chrome without recreating the live terminal process.
    private let uiTestSplitAffordance =
        CommandLine.arguments.contains("--ui-test-split-affordance")
            || CommandLine.arguments.contains(
                "--ui-test-split-affordance-hold")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: .cmdyPreferencesChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(marketplaceUpdatesDidChange),
            name: .cmdyMarketplaceUpdatesChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appUpdateDidChange),
            name: .cmdyAppUpdateChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(channelsDidChange(_:)),
            name: .cmdyChannelsChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(channelExtensionRuntimeDidChange(_:)),
            name: .cmdyExtensionRuntimeChanged, object: nil)
        ConfigFile.migrateLegacyDirectoriesIfNeeded()
        ConfigFile.applyIfPresent()   // config file wins at launch…
        ConfigFile.startWatching()    // …and re-applies live on every save
        standardKeybindings = StandardKeybindings(delegate: self)
        ShellIntegration.cleanupStaleDirectories()
        WindowDock.shared.start()   // drag a window/tab over another → dock zones

        // Extension system: isolated programs speaking the public HTTP API.
        PluginManager.shared.panesProvider = { [weak self] in
            self?.pluginPanes() ?? []
        }
        PluginManager.shared.paneProvider = { [weak self] paneID in
            guard let self else { return nil }
            for controller in self.controllers {
                if let pane = controller.panes.first(where: {
                    $0.paneId == paneID
                }) {
                    return self.pluginPane(for: pane, in: controller)
                }
            }
            return nil
        }
        PluginManager.shared.focusedPaneProvider = { [weak self] in
            guard let self, let c = self.currentController, let p = c.focusedPane else { return nil }
            return self.pluginPane(for: p, in: c)
        }
        PluginManager.shared.actionsProvider = { [weak self] in
            self?.cmdyActionPayloads() ?? []
        }
        PluginManager.shared.runActionProvider = { [weak self] id, inputs in
            guard let self else {
                throw CmdyActionError.invalid(
                    "\(ProductIdentity.current.titleName) is shutting down")
            }
            return try self.runCmdyAction(id: id, inputs: inputs)
        }
        PluginManager.shared.projectDirectoriesProvider = { [weak self] in
            self?.controllers.flatMap { $0.panes.compactMap(\.currentCwd) } ?? []
        }
        PluginManager.shared.requestProjectTrust = { [weak self] root, extensions, completion in
            let alert = NSAlert()
            alert.alertStyle = .warning
            let product = ProductIdentity.current.titleName
            alert.messageText = "Trust \(product) automation in \(root.lastPathComponent)?"
            let descriptions = extensions.map { manifest in
                let capabilities = manifest.effectiveCapabilities.map(\.rawValue).sorted()
                    .joined(separator: ", ")
                return "\(manifest.name): \(capabilities)"
            }.joined(separator: "\n")
            alert.informativeText = "This project contains executable \(product) Extensions. "
                + "Trusting it also allows Actions under .\(ProductIdentity.current.slug) now and later. "
                + "Only continue if you know its source.\n\n\(descriptions)"
            alert.addButton(withTitle: "Trust Project")
            alert.addButton(withTitle: "Not Now")
            if let window = self?.currentController?.window {
                alert.beginSheetModal(for: window) { response in
                    completion(response == .alertFirstButtonReturn)
                }
            } else {
                completion(alert.runModal() == .alertFirstButtonReturn)
            }
        }
        PluginManager.shared.panelPaneProvider = { [weak self] in
            self?.currentController?.focusedPane
        }
        PluginManager.shared.panelPaneForWindowProvider = { [weak self] windowNumber in
            guard let self else { return nil }
            if let windowNumber,
               let controller = self.controllers.first(where: { $0.window?.windowNumber == windowNumber }) {
                return controller.focusedPane ?? controller.panes.first
            }
            return self.currentController?.focusedPane
        }
        PluginManager.shared.controlBarHostProvider = { [weak self] windowNumber in
            guard let self else { return nil }
            if let windowNumber,
               let controller = self.controllers.first(where: { $0.window?.windowNumber == windowNumber }) {
                return controller.focusedPane ?? controller.panes.first
            }
            return self.currentController?.focusedPane
        }
        PluginManager.shared.agentLaunchPreflight = {
            command, displayName, sourceExtensionID, pane, host, alreadyRunning in
            IntegrationDoctor.preflight(
                agentCommand: command,
                displayName: displayName,
                sourceExtensionID: sourceExtensionID,
                cwd: pane.cwd,
                host: host,
                alreadyRunning: alreadyRunning
            ) {
                pane.run(command)
            }
        }
        PluginManager.shared.surfaceHostProvider = { [weak self] paneID in
            guard let self else { return nil }
            if let paneID {
                return self.controllers.flatMap(\.panes).first { $0.paneId == paneID }
            }
            return self.currentController?.focusedPane
        }
        PluginManager.shared.splitProvider = { [weak self] paneId, vertical in
            guard let self else { return nil }
            for c in self.controllers {
                if let pane = c.panes.first(where: { $0.paneId == paneId }) {
                    return c.splitPane(pane, vertical: vertical)?.paneId
                }
            }
            return nil
        }
        PluginManager.shared.closeProvider = { [weak self] paneId in
            guard let self else { return false }
            for c in self.controllers where c.panes.contains(where: { $0.paneId == paneId }) {
                return c.closePaneById(paneId)
            }
            return false
        }
        PluginManager.shared.composePanesProvider = { [weak self] ids in
            guard let self else {
                throw PaneCompositionError.invalidSelection
            }
            return try self.composePanes(ids: ids)
        }
        PluginManager.shared.frameStatsProvider = { [weak self] in
            let win = self?.controllers.first?.window
            return ["frames": MetalTerminalRenderer.framesPresented,
                    "rowsRebuilt": MetalTerminalRenderer.rowsRebuilt,
                    "rowsReused": MetalTerminalRenderer.rowsReused,
                    "visible": win?.occlusionState.contains(.visible) ?? false,
                    "key": win?.isKeyWindow ?? false]
        }
        PluginManager.shared.showInfo = { title, body in
            AIResponseWindow.shared.show(title: title, body: body)
        }
        PluginManager.shared.applyDockInset = { [weak self] inset, minHeight, windowNumber in
            guard let self else { return [:] }
            if let windowNumber {
                guard let controller = self.controllers.first(where: {
                    $0.window?.windowNumber == windowNumber
                }) else { return [:] }
                controller.pluginDockMinHeight = minHeight
                controller.pluginDockInset = inset
                return controller.dockGeometry
            }
            TerminalWindowController.sharedDockInset = inset
            for c in self.controllers {
                c.pluginDockMinHeight = minHeight   // set first so the resize uses the new inset
                c.pluginDockInset = inset
            }
            let key = self.controllers.first { $0.window?.isKeyWindow == true }
            return (key ?? self.currentController ?? self.controllers.first)?.dockGeometry ?? [:]
        }
        PluginManager.shared.hostComponentLifecycle = {
            [weak self] identifier, directory, enabled in
            guard let manifest = try? ExtensionManifest.load(from: directory),
                  BrowserEdition.authorizesHostComponent(
                    identifier, manifest: manifest) else {
                return false
            }
            if !enabled {
                self?.controllers.forEach { $0.hideEmbeddedBrowser() }
            }
            return EmbeddedChromiumRuntime.shared.setEnabled(
                enabled, directory: directory)
        }
        let browserSmoke = CommandLine.arguments.contains(
            "--ui-test-embedded-browser")
        _ = BrowserEdition.ensureBundledActivationInstalled(force: browserSmoke)
        PluginManager.shared.activateAll()
        // If a legacy Browser-edition app cannot create its migration record,
        // preserve Browser for this launch. Normal installs always activate
        // through the removable Extension record above.
        if BrowserEdition.isBundledEnabledByDefault
            && !BrowserEdition.isActivationInstalled {
            EmbeddedChromiumRuntime.shared.enableBundledRuntimeIfPresent()
        }
        // Beam is app UI (chips drawn on panes) — its global hotkeys live
        // here now that Bridge runs as an external plugin.
        PluginManager.shared.registerHotKey(keyCode: UInt32(11) /* B */, modifiers: UInt32(4352) /* ⌃⌘ */) {
            BeamManager.shared.beamSelection()
        }
        PluginManager.shared.registerHotKey(keyCode: UInt32(1) /* S */, modifiers: UInt32(4352)) {
            BeamManager.shared.beamScreenshot()
        }
        // Restore any cached app release before constructing windows so the
        // optional fourth traffic-light slot is correct on the first frame.
        // A fresh network result is delivered to existing windows afterward.
        AppUpdateMonitor.shared.startMonitoring()
        if CommandLine.arguments.contains("--ui-test-show-editor") {
            newWindow(nil)
            runShowEditorSmokeTest()
        } else if CommandLine.arguments.contains("--ui-test-editor") {
            newWindow(nil)
            runEditorSmokeTest()
        } else if CommandLine.arguments.contains("--ui-test-new-window") {
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, let first = self.controllers.first?.window else { exit(1) }
                let source = first.frame
                self.newWindow(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let second = self.controllers.last?.window else { exit(1) }
                    let target = second.frame
                    let sameSize = target.size == source.size
                    let cascaded = abs(target.origin.x - source.origin.x - 24) < 0.5
                        && abs(target.origin.y - source.origin.y + 24) < 0.5
                    print("UIWINDOW source=\(NSStringFromRect(source)) target=\(NSStringFromRect(target)) sameSize=\(sameSize) cascaded=\(cascaded)")
                    fflush(stdout)
                    exit(sameSize && cascaded ? 0 : 1)
                }
            }
        } else if CommandLine.arguments.contains(
                    "--ui-test-window-grid-conversion-stress") {
            runWindowGridConversionStressSmokeTest()
        } else if CommandLine.arguments.contains("--ui-test-window-grid-conversion") {
            runWindowGridConversionSmokeTest()
        } else if CommandLine.arguments.contains("--ui-test-window-grid-add-stress") {
            runWindowGridAddStressSmokeTest()
        } else if CommandLine.arguments.contains("--ui-test-window-grid-nested") {
            runWindowGridNestedDragSmokeTest()
        } else if CommandLine.arguments.contains("--ui-test-window-grid-stress") {
            runWindowGridStressSmokeTest()
        } else if CommandLine.arguments.contains("--ui-test-window-grid") {
            runWindowGridSmokeTest()
        } else if uiTestMerge {
            newWindow(nil)
            runMergeSmokeTest()
        } else if uiTestCompose {
            newWindow(nil)
            runPaneCompositionSmokeTest()
        } else if CommandLine.arguments.contains("--ui-test-overlay") {
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let w = self?.controllers.first?.window else { return }
                WindowDock.shared.showTestOverlay(over: w)
            }
        } else if CommandLine.arguments.contains("--ui-test-tabs") {
            // Deterministic two-tab window for dock-drag experiments.
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let host = self.controllers.first?.window else { return }
                let c = TerminalWindowController(cwd: nil)
                self.controllers.append(c)
                host.addTabbedWindow(c.window!, ordered: .above)
                c.window?.makeKeyAndOrderFront(nil)
                print("UITABS ready tabs=\(host.tabGroup?.windows.count ?? -1)")
            }
        } else if uiTestWorkspaceTabs {
            Preferences.shared.workspaceNavigatorVisible = true
            newWindow(nil)
            runWorkspaceTabPresentationSmokeTest()
        } else if uiTestWorkspaceDock {
            Preferences.shared.workspaceNavigatorVisible = true
            Preferences.shared.workspaceInspectorVisible = true
            newWindow(nil)
            runWorkspaceDockPresentationSmokeTest()
        } else if uiTestSidebarResize {
            Preferences.shared.workspaceNavigatorVisible = true
            Preferences.shared.workspaceInspectorVisible = false
            newWindow(nil)
            runSidebarResizeSmokeTest()
        } else if uiTestSidebarClose {
            Preferences.shared.workspaceNavigatorVisible = true
            newWindow(nil)
            runSidebarCloseSmokeTest()
        } else if uiTestSidebarTabDrag {
            Preferences.shared.workspaceNavigatorVisible = true
            Preferences.shared.workspaceInspectorVisible = true
            newWindow(nil)
            runSidebarTabDragSmokeTest()
        } else if uiTestSplitAffordance {
            Preferences.shared.workspaceNavigatorVisible = false
            Preferences.shared.workspaceInspectorVisible = false
            newWindow(nil)
            runSplitAffordanceSmokeTest()
        } else if CommandLine.arguments.contains("--ui-test-tab-theme") {
            // Reproduce a real restored tab that explicitly pinned Dracula,
            // then drive the same menu action a user invokes. The new choice
            // must replace that tab override without mutating the global theme.
            let node: [String: Any] = [
                "type": "pane",
                "cwd": "/",
                "scrollback": "",
                "tabTheme": "Dracula",
                "frame": NSStringFromRect(
                    NSRect(x: 120, y: 120, width: 860, height: 540)),
            ]
            let globalTheme = Preferences.shared.themeName
            restoreSession([node])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                [weak self] in
                guard let self, let controller = self.currentController else {
                    exit(1)
                }
                let restored = controller.selectedThemeName
                let nord = NSMenuItem(
                    title: "Nord", action: #selector(self.setThemeMenu(_:)),
                    keyEquivalent: "")
                nord.representedObject = "Nord"
                self.setThemeMenu(nord)
                DispatchQueue.main.async {
                    let layout = controller.serializeLayout()
                    let persisted = layout["tabTheme"] as? String
                    let selected = controller.selectedThemeName
                    let globalUnchanged =
                        Preferences.shared.themeName == globalTheme
                    _ = self.validateMenuItem(nord)
                    let checked = nord.state == .on
                    let ok = restored == "Dracula"
                        && selected == "Nord"
                        && persisted == "Nord"
                        && globalUnchanged
                        && checked
                    print(
                        "UITHEME restored=\(restored) selected=\(selected) "
                            + "persisted=\(persisted ?? "nil") "
                            + "global=\(Preferences.shared.themeName) "
                            + "globalUnchanged=\(globalUnchanged) "
                            + "checked=\(checked) ok=\(ok)")
                    fflush(stdout)
                    exit(ok ? 0 : 1)
                }
            }
        } else if CommandLine.arguments.contains(
            "--ui-test-browser-install-recovery") {
            Preferences.shared.workspaceNavigatorVisible = false
            Preferences.shared.workspaceInspectorVisible = false
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                [weak self] in
                guard let self, let controller = self.controllers.first,
                      let viewMenu = NSApp.mainMenu?.items.compactMap(\.submenu)
                        .first(where: { $0.title == "View" }),
                      let browserItem = viewMenu.items.first(where: {
                        $0.action == #selector(self.toggleEmbeddedBrowser(_:))
                      })
                else { exit(1) }

                let unavailable = !EmbeddedChromiumRuntime.shared.isAvailable
                    && !PluginManager.shared.hasCommand(id: "chromium.toggle")
                let menuEnabled = self.validateMenuItem(browserItem)
                let menuCorrect = menuEnabled
                    && browserItem.state == .off
                    && browserItem.title == "Install Browser…"
                self.toggleEmbeddedBrowser(browserItem)

                let promptIsCorrect = {
                    guard let prompt = BrowserEditionInstaller
                        .promptDiagnosticForTesting() else { return false }
                    return prompt.message == "Browser isn't installed"
                        && prompt.information.contains("visible browser is built into")
                        && prompt.buttons
                            == ["Install Browser", "Cancel"]
                        && prompt.marketplaceID == BrowserEdition.marketplaceID
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let menuPrompt = promptIsCorrect()
                    let menuCancelled = BrowserEditionInstaller
                        .pressPromptButtonForTesting(at: 1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        let toolbar = controller
                            .browserInstallToolbarDiagnosticForTesting()
                        let expectedToolbarText =
                            "Browser is not installed — click to install"
                        let toolbarCorrect = toolbar.present
                            && !toolbar.toggled
                            && toolbar.tooltip == expectedToolbarText
                            && toolbar.accessibilityLabel == expectedToolbarText
                        let toolbarActivated = controller
                            .activateBrowserToolbarForTesting()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            let toolbarPrompt = promptIsCorrect()
                            let toolbarCancelled = BrowserEditionInstaller
                                .pressPromptButtonForTesting(at: 1)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                let ok = unavailable && menuCorrect
                                    && menuPrompt && menuCancelled
                                    && toolbarCorrect && toolbarActivated
                                    && toolbarPrompt && toolbarCancelled
                                print(
                                    "UIBROWSERINSTALL unavailable=\(unavailable) "
                                        + "menu=\(menuCorrect) "
                                        + "menuPrompt=\(menuPrompt) "
                                        + "toolbar=\(toolbarCorrect) "
                                        + "toolbarPrompt=\(toolbarPrompt) ok=\(ok)")
                                fflush(stdout)
                                exit(ok ? 0 : 1)
                            }
                        }
                    }
                }
            }
        } else if CommandLine.arguments.contains("--ui-test-embedded-browser") {
            let checksToolbarContrast = CommandLine.arguments.contains(
                "--ui-test-embedded-browser-toolbar-contrast")
            Preferences.shared.workspaceNavigatorVisible = true
            Preferences.shared.workspaceInspectorVisible = !checksToolbarContrast
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                [weak self] in
                guard let controller = self?.currentController else { exit(1) }
                // Pin a per-tab color that differs from the fresh global
                // default. Browser chrome must inherit this exact active-tab
                // theme rather than falling back to Preferences.shared.
                controller.setTabTheme("C64")
                let shown = controller.showEmbeddedBrowser()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    let checksDoctorWidth = CommandLine.arguments.contains(
                        "--ui-test-embedded-browser-doctor")
                    if checksDoctorWidth, let pane = controller.focusedPane {
                        IntegrationDoctor.present(in: pane, cwd: pane.currentCwd)
                        controller.window?.contentView?.layoutSubtreeIfNeeded()
                    }
                    let diagnostic = controller.embeddedBrowserDiagnostic
                    let doctorLayout = controller.windowInlinePanelDiagnostic
                    let doctorIsWindowWide = !checksDoctorWidth || doctorLayout.map {
                        abs($0.panelWidth - $0.windowWidth) < 0.5
                            && $0.panelHeight > 20
                            && $0.isFrontmost
                    } == true
                    let rect = controller.embeddedBrowserCaptureRect ?? .zero
                    let browserIsFlush =
                        diagnostic.cornerRadius < 0.01
                        && !diagnostic.masksToBounds
                        && diagnostic.chromePassthrough
                        && diagnostic.chromeOverlap < 0.5
                        && abs(diagnostic.topGap
                            - TerminalWindowController
                                .embeddedBrowserTopContentInset(
                                    toolbarBand: NativeToolbarPreset
                                        .titleBandHeight(Preferences.shared
                                            .nativeToolbarStyle),
                                    titleBandVisible: true,
                                    backingScale: controller.window?
                                        .backingScaleFactor ?? 2)) < 0.25
                        && diagnostic.bottomGap < 0.5
                        && diagnostic.horizontalGap < 0.5
                    let toolbarContrastIsCorrect = !checksToolbarContrast
                        || !diagnostic.toolbarOverlapsBrowser
                    controller.hideEmbeddedBrowser()
                    controller.window?.contentView?.layoutSubtreeIfNeeded()
                    let closedDiagnostic = controller.embeddedBrowserDiagnostic
                    let browserChromeFollowsTheme =
                        diagnostic.browserChromeMatchesTheme
                        && diagnostic.toolbarTintMatchesTheme
                        && closedDiagnostic.browserChromeMatchesTheme
                        && closedDiagnostic.toolbarTintMatchesTheme
                        && !closedDiagnostic.toolbarOverlapsBrowser
                    let browserMenu = self?.extensionCommandGroups.contains {
                        $0.plugin.caseInsensitiveCompare("Browser") == .orderedSame
                    } ?? false
                    let toolsMenu = NSApp.mainMenu?.items
                        .compactMap(\.submenu)
                        .first { $0.title == "Tools" }
                    let extensionsMenu = toolsMenu?
                        .item(withTitle: "Extensions")?.submenu
                    if let extensionsMenu {
                        self?.menuNeedsUpdate(extensionsMenu)
                    }
                    let browserMenuItem =
                        extensionsMenu?.item(withTitle: "Browser") != nil
                    let ok = shown && diagnostic.handle && diagnostic.attached
                        && diagnostic.nativeSubviews > 0
                        && diagnostic.pageLoaded && browserIsFlush
                        && toolbarContrastIsCorrect
                        && browserChromeFollowsTheme
                        && doctorIsWindowWide
                        && rect.width >= 240
                        && rect.height >= 200 && browserMenu && browserMenuItem
                    print(
                        "UIBROWSER shown=\(shown) handle=\(diagnostic.handle) "
                            + "attached=\(diagnostic.attached) "
                            + "nativeSubviews=\(diagnostic.nativeSubviews) "
                            + "pageLoaded=\(diagnostic.pageLoaded) "
                            + "radius=\(diagnostic.cornerRadius) "
                            + "masked=\(diagnostic.masksToBounds) "
                            + "overlap=\(diagnostic.chromeOverlap) "
                            + "passthrough=\(diagnostic.chromePassthrough) "
                            + "toolbarOverlap=\(diagnostic.toolbarOverlapsBrowser) "
                            + "toolbarBrightness=\(diagnostic.toolbarTintBrightness) "
                            + "toolbarTheme=\(diagnostic.toolbarTintMatchesTheme) "
                            + "browserChromeTheme=\(diagnostic.browserChromeMatchesTheme) "
                            + "closedToolbarTheme=\(closedDiagnostic.toolbarTintMatchesTheme) "
                            + "topGap=\(diagnostic.topGap) "
                            + "bottomGap=\(diagnostic.bottomGap) "
                            + "horizontalGap=\(diagnostic.horizontalGap) "
                            + "doctorWide=\(doctorIsWindowWide) "
                            + "doctorWidth=\(doctorLayout?.panelWidth ?? 0) "
                            + "windowWidth=\(doctorLayout?.windowWidth ?? 0) "
                            + "doctorHeight=\(doctorLayout?.panelHeight ?? 0) "
                            + "doctorFront=\(doctorLayout?.isFrontmost ?? false) "
                            + "menu=\(browserMenu) "
                            + "menuItem=\(browserMenuItem) "
                            + "window=\(controller.window?.windowNumber ?? 0) "
                            + "rect=\(NSStringFromRect(rect)) ok=\(ok)")
                    fflush(stdout)
                    if CommandLine.arguments.contains(
                        "--ui-test-embedded-browser-hold") {
                        return
                    }
                    guard ok else { exit(1) }
                    // Exercise the user's real Cmd-W path: the only window is
                    // disposable, so closing it must tear down Browser and
                    // terminate without blocking AppKit's main thread.
                    controller.window?.performClose(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        // A successful last-window close terminates the process
                        // before this watchdog can fire.
                        exit(1)
                    }
                }
            }
        } else if CommandLine.arguments.contains("--ui-test-dense-scroll-profile") {
            runDenseScrollPerformanceProfile()
        } else if CommandLine.arguments.contains("--ui-test-dense-selection-profile") {
            runDenseSelectionPerformanceProfile()
        } else if CommandLine.arguments.contains("--ui-test-maximized-perf") {
            // Deterministic real-window performance fixture. This uses the
            // screen's full visible frame so row/column costs match a maximized
            // interactive terminal instead of the small background perf gate.
            newWindow(nil)
            DispatchQueue.main.async { [weak self] in
                guard let controller = self?.controllers.first,
                      let window = controller.window,
                      let screen = window.screen ?? NSScreen.main else { return }
                window.setFrame(screen.visibleFrame, display: true)
                window.makeKeyAndOrderFront(nil)
                let rows = controller.panes.first?.surface.engine.rows ?? 0
                let cols = controller.panes.first?.surface.engine.cols ?? 0
                print("UIPERF ready frame=\(NSStringFromRect(window.frame)) grid=\(cols)x\(rows)")
            }
        } else if CommandLine.arguments.contains("--ui-test-databloom") {
            // Visual fixture for the glyph-only scroll shader. It uses an
            // isolated config/defaults domain in the caller, feeds enough real
            // terminal text to create scrollback, and drives the same viewport
            // method as the scrollbar. Hold briefly for screenshot inspection.
            Preferences.shared.shaderName = "Databloom"
            Preferences.shared.workspaceNavigatorVisible = false
            Preferences.shared.workspaceInspectorVisible = false
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let controller = self?.controllers.first,
                      let pane = controller.focusedPane ?? controller.panes.first else { exit(1) }
                let swatches = [31, 33, 35, 36, 32, 34]
                let lines = (1...90).map { index in
                    let color = swatches[index % swatches.count]
                    return "\u{1b}[\(color)m[\(String(format: "%02d", index))]\u{1b}[0m  "
                        + "scroll-reactive glyph fragments stay on text only  "
                        + "0123456789  ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n"
                }.joined()
                // Window controllers keep a per-tab appearance snapshot; set
                // the fixture directly so it cannot inherit a stale override.
                pane.surface.shaderMode = Preferences.shaderNames.firstIndex(of: "Databloom") ?? 68
                pane.surface.feed(text: lines)
                pane.surface.scrollTo(row: 0)
                controller.window?.setFrame(
                    NSRect(x: 160, y: 160, width: 980, height: 620), display: true)
                controller.window?.makeKeyAndOrderFront(nil)
                print("UIDATABLOOM ready window=\(controller.window?.windowNumber ?? 0)")
                fflush(stdout)
                // Leave a short capture window before motion, then keep real
                // scrolling active long enough for visual regression checks.
                let scrollStart = 1.0
                for step in 0..<58 {
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + scrollStart + Double(step) * 0.08) {
                        pane.surface.scrollDown(lines: 1)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { exit(0) }
            }
        } else if CommandLine.arguments.contains("--ui-test-window-close-confirmation")
                    || CommandLine.arguments.contains(
                        "--ui-test-window-close-confirmation-hold") {
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self,
                      let activeController = self.controllers.first else { exit(1) }
                self.newWindow(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard let emptyController = self.controllers.last,
                          emptyController !== activeController,
                          let emptyWindow = emptyController.window else { exit(1) }
                    emptyWindow.setFrame(
                        NSRect(x: 180, y: 180, width: 760, height: 480),
                        display: true)
                    emptyWindow.makeKeyAndOrderFront(nil)
                    emptyWindow.performClose(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        let emptyDiagnostic = emptyController
                            .windowCloseConfirmationDiagnostic()
                        let emptyImmediate = !emptyWindow.isVisible
                            && !emptyDiagnostic.pending
                        guard let activeWindow = activeController.window,
                              let pane = activeController.panes.first else {
                            exit(1)
                        }
                        // Keep one inert controller alive so accepting the
                        // active window's sheet cannot terminate the test app
                        // before its close result is observed.
                        self.newWindow(nil)
                        self.controllers.last?.window?.orderOut(nil)
                        pane.blockStore.commandStarted(
                            row: 1, promptRow: 0,
                            command: "printf activity", cwd: nil)
                        _ = pane.blockStore.commandFinished(
                            row: 2, exitCode: 0)
                        activeWindow.performClose(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            let diagnostic = activeController
                                .windowCloseConfirmationDiagnostic()
                            let activeProtected = diagnostic.pending
                                && diagnostic.message == "Close this window?"
                                && diagnostic.buttons == ["Close Window", "Cancel"]
                                && activeWindow.isVisible
                            activeController.acceptWindowCloseConfirmationForTesting()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                let activeClosed = !activeWindow.isVisible
                                    && !self.controllers.contains {
                                        $0 === activeController
                                    }
                                let ok = emptyImmediate && activeProtected && activeClosed
                                print("UICLOSE emptyImmediate=\(emptyImmediate) "
                                      + "activeProtected=\(activeProtected) "
                                      + "activeClosed=\(activeClosed) "
                                      + "pending=\(diagnostic.pending) "
                                      + "visible=\(activeWindow.isVisible) ok=\(ok)")
                                fflush(stdout)
                                if CommandLine.arguments.contains(
                                    "--ui-test-window-close-confirmation-hold") {
                                    DispatchQueue.main.asyncAfter(
                                        deadline: .now() + 30) {
                                        exit(ok ? 0 : 1)
                                    }
                                } else {
                                    exit(ok ? 0 : 1)
                                }
                            }
                        }
                    }
                }
            }
        } else if CommandLine.arguments.contains("--ui-test-custom-toolbar-visual")
                    || CommandLine.arguments.contains("--ui-test-custom-toolbar-palette")
                    || CommandLine.arguments.contains("--ui-test-custom-toolbar-customizer")
                    || CommandLine.arguments.contains("--ui-test-custom-toolbar-customizer-hold") {
            Preferences.shared.workspaceNavigatorVisible = false
            Preferences.shared.workspaceInspectorVisible = true
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let controller = self?.controllers.first,
                      let window = controller.window else { exit(1) }
                window.setFrame(
                    NSRect(x: 180, y: 180, width: 920, height: 560), display: true)
                controller.installNativeToolbarVisualFixture()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                if CommandLine.arguments.contains("--ui-test-custom-toolbar-palette") {
                    controller.runNativeToolbarCustomizationPaletteForTest()
                } else if CommandLine.arguments.contains(
                            "--ui-test-custom-toolbar-customizer")
                            || CommandLine.arguments.contains(
                                "--ui-test-custom-toolbar-customizer-hold") {
                    controller.routeNativeToolbarCustomizationForTest()
                }
                print("UITOOLBARVISUAL ready window=\(window.windowNumber)")
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    print("UITOOLBARVISUAL \(controller.nativeToolbarVisualDiagnostic())")
                    if CommandLine.arguments.contains(
                        "--ui-test-custom-toolbar-customizer")
                        || CommandLine.arguments.contains(
                            "--ui-test-custom-toolbar-customizer-hold") {
                        guard let diagnostic = controller
                            .toolbarCustomizationMutationDiagnostic()
                        else { exit(1) }
                        let ok = diagnostic.panelVisible
                            && diagnostic.afterAdd == diagnostic.before + 1
                            && diagnostic.afterRemove == diagnostic.before
                            && diagnostic.compactVisible
                            && diagnostic.maximumGap <= 6
                            && diagnostic.modelMatches
                            && diagnostic.panelHeight >= 380
                            && diagnostic.recommendedDefaults
                        print("UITOOLBARMUTATION panel=\(diagnostic.panelVisible) "
                              + "before=\(diagnostic.before) "
                              + "add=\(diagnostic.afterAdd) "
                              + "remove=\(diagnostic.afterRemove) "
                              + "compact=\(diagnostic.compactVisible) "
                              + "gap=\(diagnostic.maximumGap) "
                              + "model=\(diagnostic.modelMatches) "
                              + "height=\(diagnostic.panelHeight) "
                              + "defaults=\(diagnostic.recommendedDefaults) "
                              + "ok=\(ok)")
                        fflush(stdout)
                        if !CommandLine.arguments.contains(
                            "--ui-test-custom-toolbar-customizer-hold") {
                            exit(ok ? 0 : 1)
                        }
                    }
                    fflush(stdout)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
            }
        } else if CommandLine.arguments.contains("--ui-test-custom-toolbar") {
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let controller = self?.controllers.first else { exit(1) }
                controller.installNativeToolbarVisualFixture()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let diagnostic = controller.nativeToolbarDiagnostic()
                    let ok = diagnostic.customizable && diagnostic.autosaves
                        && diagnostic.allowed >= 40
                        && diagnostic.instantiated == diagnostic.allowed - 2
                        && diagnostic.trailingAligned
                        && diagnostic.compactSpacing
                        && diagnostic.iconPointSize == 13
                        && diagnostic.buttonSide == 28
                        && diagnostic.visibleGap <= 6
                    print("UITOOLBAR customizable=\(diagnostic.customizable) "
                          + "autosaves=\(diagnostic.autosaves) "
                          + "allowed=\(diagnostic.allowed) "
                          + "instantiated=\(diagnostic.instantiated) "
                          + "trailing=\(diagnostic.trailingAligned) "
                          + "compact=\(diagnostic.compactSpacing) "
                          + "icon=\(diagnostic.iconPointSize) "
                          + "side=\(diagnostic.buttonSide) "
                          + "factory=\(diagnostic.factoryWidths) "
                          + "gap=\(diagnostic.visibleGap) ok=\(ok)")
                    fflush(stdout)
                    exit(ok ? 0 : 1)
                }
            }
        } else if CommandLine.arguments.contains(
                    "--ui-test-custom-toolbar-click") {
            Preferences.shared.workspaceNavigatorVisible = false
            Preferences.shared.workspaceInspectorVisible = true
            newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                [weak self] in
                guard let controller = self?.controllers.first,
                      let window = controller.window else { exit(1) }
                window.setFrame(
                    NSRect(x: 180, y: 180, width: 920, height: 560),
                    display: true)
                controller.installNativeToolbarVisualFixture()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let target = controller
                        .compactToolbarPointerTestTarget()
                    else {
                        print("UITOOLBARCLICK FAIL target")
                        fflush(stdout)
                        exit(1)
                    }
                    let windowPoint = window.convertPoint(
                        fromScreen: target.screenPoint)
                    if let hoverEvent = NSEvent.mouseEvent(
                        with: .mouseMoved,
                        location: windowPoint,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 0,
                        pressure: 0) {
                        NSApp.postEvent(hoverEvent, atStart: false)
                    }
                    controller.driveCompactToolbarHoverSmokeTest()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        let activationDeadline =
                            ProcessInfo.processInfo.systemUptime + 3.0
                        var activationAttempts = 0
                        var pointerPairSent = false

                        func finish() {
                            let after = controller.panes.count
                            let opacity = controller
                                .compactToolbarInteractionOpacityDiagnostic()
                            let history = opacity?.history ?? []
                            let hasRest = history.contains {
                                abs($0 - TerminalWindowController
                                    .compactToolbarRestingOpacityForTesting) < 0.001
                            }
                            let hasHover = history.contains {
                                abs($0 - 0.8) < 0.001
                            }
                            let hasPress = history.contains {
                                abs($0 - 1.0) < 0.001
                            }
                            let ok = pointerPairSent
                                && after == target.paneCount + 1
                                && hasRest && hasHover && hasPress
                            let historyText = history.map {
                                String(format: "%.1f", $0)
                            }.joined(separator: ",")
                            print("UITOOLBARCLICK before=\(target.paneCount) "
                                  + "after=\(after) "
                                  + "activationAttempts=\(activationAttempts) "
                                  + "pairSent=\(pointerPairSent) "
                                  + "opacity=\(opacity?.current ?? -1) "
                                  + "history=[\(historyText)] ok=\(ok)")
                            fflush(stdout)
                            exit(ok ? 0 : 1)
                        }

                        func awaitActiveWindowAndClick() {
                            guard ProcessInfo.processInfo.systemUptime
                                    < activationDeadline
                            else {
                                finish()
                                return
                            }
                            activationAttempts += 1
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)

                            // Concurrent smoke processes cannot all own
                            // foreground activation. Vary both by PID and wave
                            // so they do not keep stealing it in lockstep.
                            let phase = (Int(getpid())
                                         + activationAttempts * 7) % 17
                            let settleDelay = 0.035
                                + Double(phase) / 1_000.0
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + settleDelay) {
                                guard NSApp.isActive, window.isKeyWindow else {
                                    awaitActiveWindowAndClick()
                                    return
                                }
                                window.contentView?.layoutSubtreeIfNeeded()
                                window.displayIfNeeded()
                                guard let clickTarget = controller
                                    .compactToolbarPointerTestTarget()
                                else {
                                    finish()
                                    return
                                }
                                let clickPoint = window.convertPoint(
                                    fromScreen: clickTarget.screenPoint)
                                let timestamp =
                                    ProcessInfo.processInfo.systemUptime
                                guard let down = NSEvent.mouseEvent(
                                    with: .leftMouseDown,
                                    location: clickPoint,
                                    modifierFlags: [],
                                    timestamp: timestamp,
                                    windowNumber: window.windowNumber,
                                    context: nil,
                                    eventNumber: activationAttempts * 2,
                                    clickCount: 1,
                                    pressure: 1),
                                      let up = NSEvent.mouseEvent(
                                        with: .leftMouseUp,
                                        location: clickPoint,
                                        modifierFlags: [],
                                        timestamp: timestamp + 0.001,
                                        windowNumber: window.windowNumber,
                                        context: nil,
                                        eventNumber: activationAttempts * 2 + 1,
                                        clickCount: 1,
                                        pressure: 0)
                                else {
                                    finish()
                                    return
                                }
                                // NSButton's mouseDown runs a tracking loop.
                                // Queue the release first, then route one press
                                // through NSWindow's real titlebar hit-test.
                                pointerPairSent = true
                                NSApp.postEvent(up, atStart: true)
                                window.sendEvent(down)
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.08,
                                    execute: finish)
                            }
                        }

                        awaitActiveWindowAndClick()
                    }
                }
            }
        } else if Preferences.shared.restoreSession, let saved = SessionStore.load() {
            restoreSession(saved)
        } else {
            newWindow(nil)
        }
        refreshActionsMenu()
        refreshChannelsMenu()
        windowGridCoordinator.start()
        refreshMenuStates()
        MarketplaceUpdateMonitor.shared.checkIfDue()
        if CommandLine.arguments.contains("--ui-test-app-update") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let window = self?.controllers.first?.window,
                      AppUpdateMonitor.shared.availableUpdate != nil else {
                    print("UIUPDATE unavailable")
                    return
                }
                AppUpdateWindow.shared.show(relativeTo: window)
                print("UIUPDATE ready")
            }
        }
    }

    /// Real-window native-scroll profiler for dense restored scrollback. This
    /// deliberately measures the same pixel-wheel path as a trackpad instead
    /// of the row-at-a-time plugin API used by the fleet performance gate.
    private func runDenseScrollPerformanceProfile() {
        enum SemanticVariant: String {
            case plain
            case blocks
            case failed
        }
        let variant: SemanticVariant
        if CommandLine.arguments.contains("--ui-test-dense-scroll-failed") {
            variant = .failed
        } else if CommandLine.arguments.contains("--ui-test-dense-scroll-blocks") {
            variant = .blocks
        } else {
            variant = .plain
        }
        let eventPixels = CommandLine.arguments.compactMap { argument -> Int32? in
            let prefix = "--ui-test-dense-scroll-pixels="
            guard argument.hasPrefix(prefix) else { return nil }
            return Int32(argument.dropFirst(prefix.count))
        }.first.map { max(1, min(96, abs($0))) } ?? 3
        let historyCount = eventPixels > 3 ? 1_200 : 180
        Preferences.shared.workspaceNavigatorVisible = false
        Preferences.shared.workspaceInspectorVisible = false
        Preferences.shared.ghostText = false
        Preferences.shared.shaderName = "None"
        Preferences.shared.scrollSpeed = 1
        Preferences.shared.smoothScroll = true
        newWindow(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let controller = self?.controllers.first,
                  let pane = controller.focusedPane ?? controller.panes.first,
                  let surface = pane.surface as? CmdyTerminalSurface,
                  let window = controller.window else { exit(1) }

            window.setFrame(
                NSRect(x: 120, y: 120, width: 854, height: 570),
                display: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            let restored = (0..<historyCount).map { index in
                let command = ["asd", "d", "sa", "as", "%"][index % 5]
                return "% \(command)\r\n"
                    + "zsh: command not found: \(command)\r\n"
                    + "The shell could not find \(command). It may not be installed, or its "
                    + "executable directory may be missing from PATH.\r\n"
            }.joined()
            surface.feed(text: "\u{1b}[2m── restored session ──\r\n"
                + restored + "\u{1b}[0m")
            if variant != .plain {
                let promptRows = (0..<surface.engine.bufferLineCount).filter { row in
                    surface.engine.scrollbackLineText(row: row)?.hasPrefix("% ") == true
                }
                for (index, promptRow) in promptRows.enumerated() {
                    pane.blockStore.promptStarted(row: promptRow)
                    pane.blockStore.commandStarted(
                        row: min(surface.engine.bufferLineCount - 1, promptRow + 1),
                        promptRow: promptRow,
                        command: "profile-\(index)", cwd: nil)
                    _ = pane.blockStore.commandFinished(
                        row: min(surface.engine.bufferLineCount - 1, promptRow + 3),
                        exitCode: variant == .failed ? 127 : 0)
                }
            }
            let liveTop = surface.engine.liveScreenTopRow
            surface.scrollTo(row: eventPixels > 3 ? liveTop / 2 : liveTop)
            surface.forceRedraw()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let eventCount = 720
                let eventRate = 120.0
                let half = eventCount / 2
                let start = ProcessInfo.processInfo.systemUptime
                let framesBefore = MetalTerminalRenderer.framesPresented
                let rebuiltBefore = MetalTerminalRenderer.rowsRebuilt
                let reusedBefore = MetalTerminalRenderer.rowsReused
                let captureBefore = surface.terminal
                    .viewportSnapshotCaptureCountForTesting
                let projectionBefore = surface.terminal
                    .viewportSnapshotReuseCountForTesting
                var handlerDurations: [Double] = []
                var timerLateness: [Double] = []
                handlerDurations.reserveCapacity(eventCount)
                timerLateness.reserveCapacity(eventCount)
                var eventIndex = 0
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(
                    deadline: .now(), repeating: 1 / eventRate,
                    leeway: .milliseconds(1))
                timer.setEventHandler {
                    let eventStart = ProcessInfo.processInfo.systemUptime
                    let expected = start + Double(eventIndex) / eventRate
                    timerLateness.append(max(0, eventStart - expected))
                    let direction: Int32 = eventIndex < half
                        ? eventPixels : -eventPixels
                    guard let cg = CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel,
                        wheelCount: 1, wheel1: direction,
                        wheel2: 0, wheel3: 0),
                          let event = NSEvent(cgEvent: cg) else {
                        timer.cancel()
                        exit(1)
                    }
                    surface.scrollWheel(with: event)
                    handlerDurations.append(
                        ProcessInfo.processInfo.systemUptime - eventStart)
                    eventIndex += 1
                    guard eventIndex == eventCount else { return }
                    timer.cancel()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        func percentile(_ samples: [Double], _ p: Double) -> Double {
                            guard !samples.isEmpty else { return 0 }
                            let sorted = samples.sorted()
                            let index = min(
                                sorted.count - 1,
                                Int((Double(sorted.count - 1) * p).rounded()))
                            return sorted[index]
                        }
                        let elapsed = ProcessInfo.processInfo.systemUptime - start
                        let frames = MetalTerminalRenderer.framesPresented - framesBefore
                        let rebuilt = MetalTerminalRenderer.rowsRebuilt - rebuiltBefore
                        let reused = MetalTerminalRenderer.rowsReused - reusedBefore
                        let captures = surface.terminal
                            .viewportSnapshotCaptureCountForTesting - captureBefore
                        let projections = surface.terminal
                            .viewportSnapshotReuseCountForTesting - projectionBefore
                        let mean = handlerDurations.reduce(0, +)
                            / Double(max(1, handlerDurations.count))
                        let targetFPS = MetalTerminalRenderer
                            .interactiveContentTargetFPS(
                                isKeyWindow: window.isKeyWindow,
                                thermalState: ProcessInfo.processInfo.thermalState,
                                lowPowerMode: ProcessInfo.processInfo
                                    .isLowPowerModeEnabled,
                                maximumFramesPerSecond: max(
                                    60,
                                    window.screen?.maximumFramesPerSecond ?? 60))
                        let activeDuration = Double(eventCount) / eventRate
                        let cadenceRatio = Double(frames)
                            / max(1, targetFPS * activeDuration)
                        // The target accounts for display refresh, Low Power
                        // Mode, and thermal pressure. The remaining checks are
                        // deterministic architecture invariants: a dense wheel
                        // burst must project/reuse the captured viewport,
                        // bound row rebuilding, and return to its start after
                        // the equal forward/backward sequence.
                        let semanticRowsPresent: Bool
                        switch variant {
                        case .plain:
                            semanticRowsPresent = pane.blockStore.blocks.isEmpty
                                && surface.failedBlockRows.isEmpty
                        case .blocks:
                            semanticRowsPresent = !pane.blockStore.blocks.isEmpty
                                && surface.failedBlockRows.isEmpty
                        case .failed:
                            semanticRowsPresent = !pane.blockStore.blocks.isEmpty
                                && !surface.failedBlockRows.isEmpty
                        }
                        let ok = handlerDurations.count == eventCount
                            && semanticRowsPresent
                            && captures > 0
                            && projections > 0
                            && captures < eventCount
                            // A full snapshot may expose at most one grid of
                            // previously unseen rows. Projection-only events
                            // must not multiply that work.
                            && rebuilt <= captures * surface.engine.rows
                            && reused > rebuilt
                            && cadenceRatio >= 0.75
                            && surface.engine.currentTopRow
                                == (eventPixels > 3 ? liveTop / 2 : liveTop)
                        print(String(format:
                            "UIDENSESCROLL variant=%@ pixels=%d blocks=%d failed=%d "
                            + "grid=%dx%d screenHz=%d lowPower=%@ "
                            + "history=%d events=%d elapsed=%.3f "
                            + "fps=%.2f targetFPS=%.0f cadenceRatio=%.3f "
                            + "handlerMeanMs=%.3f handlerP95Ms=%.3f "
                            + "handlerMaxMs=%.3f timerP95Ms=%.3f timerMaxMs=%.3f "
                            + "rebuilt=%d reused=%d captures=%d projections=%d yDisp=%d ok=%@",
                            variant.rawValue, eventPixels,
                            pane.blockStore.blocks.count,
                            surface.failedBlockRows.count,
                            surface.engine.cols, surface.engine.rows,
                            window.screen?.maximumFramesPerSecond ?? 0,
                            ProcessInfo.processInfo.isLowPowerModeEnabled
                                ? "true" : "false",
                            surface.engine.liveScreenTopRow, eventCount, elapsed,
                            Double(frames) / elapsed, targetFPS, cadenceRatio,
                            mean * 1_000,
                            percentile(handlerDurations, 0.95) * 1_000,
                            (handlerDurations.max() ?? 0) * 1_000,
                            percentile(timerLateness, 0.95) * 1_000,
                            (timerLateness.max() ?? 0) * 1_000,
                            rebuilt, reused, captures, projections,
                            surface.engine.currentTopRow,
                            ok ? "true" : "false"))
                        fflush(stdout)
                        if !CommandLine.arguments.contains(
                            "--ui-test-dense-scroll-hold") {
                            exit(ok ? 0 : 1)
                        }
                    }
                }
                timer.resume()
            }
        }
    }

    /// Real-window primary-selection profiler. It drives the exact AppKit
    /// mouseDown/mouseDragged/mouseUp path over failed semantic command blocks
    /// at trackpad/pointer cadence, so row-cache work and presentation lag are
    /// observable together.
    private func runDenseSelectionPerformanceProfile() {
        Preferences.shared.workspaceNavigatorVisible = false
        Preferences.shared.workspaceInspectorVisible = false
        Preferences.shared.ghostText = false
        Preferences.shared.shaderName = "None"
        newWindow(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let controller = self?.controllers.first,
                  let pane = controller.focusedPane ?? controller.panes.first,
                  let surface = pane.surface as? CmdyTerminalSurface,
                  let window = controller.window else { exit(1) }

            window.setFrame(
                NSRect(x: 120, y: 120, width: 854, height: 570),
                display: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            let restored = (0..<180).map { index in
                let command = ["asd", "d", "sa", "as", "%"][index % 5]
                return "% \(command)\r\n"
                    + "zsh: command not found: \(command)\r\n"
                    + "The shell could not find \(command). It may not be installed, or its "
                    + "executable directory may be missing from PATH.\r\n"
            }.joined()
            surface.feed(text: "\u{1b}[2m── restored session ──\r\n"
                + restored + "\u{1b}[0m")
            let promptRows = (0..<surface.engine.bufferLineCount).filter { row in
                surface.engine.scrollbackLineText(row: row)?.hasPrefix("% ") == true
            }
            for (index, promptRow) in promptRows.enumerated() {
                pane.blockStore.promptStarted(row: promptRow)
                pane.blockStore.commandStarted(
                    row: min(surface.engine.bufferLineCount - 1, promptRow + 1),
                    promptRow: promptRow,
                    command: "profile-\(index)", cwd: nil)
                _ = pane.blockStore.commandFinished(
                    row: min(surface.engine.bufferLineCount - 1, promptRow + 3),
                    exitCode: 127)
            }
            surface.scrollTo(row: max(0, surface.engine.liveScreenTopRow - 80))
            surface.forceRedraw()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let eventCount = 720
                let eventRate = 120.0
                let startRow = 3.0
                let endRow = Double(max(4, surface.engine.rows - 4))
                let startCol = 2.0
                let endCol = Double(max(3, surface.engine.cols - 4))
                @MainActor func windowPoint(progress: Double) -> NSPoint {
                    let row = startRow + (endRow - startRow) * progress
                    let col = startCol + (endCol - startCol) * progress
                    let local = NSPoint(
                        x: surface.contentXOrigin
                            + CGFloat(col + 0.5) * surface.cellSize.width,
                        y: surface.bounds.maxY - surface.topContentInset
                            - CGFloat(row + 0.5) * surface.cellSize.height)
                    return surface.convert(local, to: nil)
                }
                @MainActor func mouseEvent(
                    _ type: NSEvent.EventType, progress: Double
                ) -> NSEvent? {
                    NSEvent.mouseEvent(
                        with: type, location: windowPoint(progress: progress),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1)
                }
                guard let down = mouseEvent(.leftMouseDown, progress: 0) else { exit(1) }
                surface.mouseDown(with: down)

                let start = ProcessInfo.processInfo.systemUptime
                let framesBefore = MetalTerminalRenderer.framesPresented
                let rebuiltBefore = MetalTerminalRenderer.rowsRebuilt
                let reusedBefore = MetalTerminalRenderer.rowsReused
                var handlerDurations: [Double] = []
                var timerLateness: [Double] = []
                handlerDurations.reserveCapacity(eventCount)
                timerLateness.reserveCapacity(eventCount)
                var eventIndex = 0
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(
                    deadline: .now(), repeating: 1 / eventRate,
                    leeway: .milliseconds(1))
                timer.setEventHandler {
                    let eventStart = ProcessInfo.processInfo.systemUptime
                    let expected = start + Double(eventIndex) / eventRate
                    timerLateness.append(max(0, eventStart - expected))
                    let halfProgress = Double(eventIndex % (eventCount / 2))
                        / Double(eventCount / 2 - 1)
                    let progress = eventIndex < eventCount / 2
                        ? halfProgress : 1 - halfProgress
                    guard let drag = mouseEvent(
                        .leftMouseDragged, progress: progress) else {
                        timer.cancel()
                        exit(1)
                    }
                    surface.mouseDragged(with: drag)
                    handlerDurations.append(
                        ProcessInfo.processInfo.systemUptime - eventStart)
                    eventIndex += 1
                    guard eventIndex == eventCount else { return }
                    timer.cancel()
                    if let up = mouseEvent(.leftMouseUp, progress: 0) {
                        surface.mouseUp(with: up)
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        func percentile(_ samples: [Double], _ p: Double) -> Double {
                            guard !samples.isEmpty else { return 0 }
                            let sorted = samples.sorted()
                            let index = min(
                                sorted.count - 1,
                                Int((Double(sorted.count - 1) * p).rounded()))
                            return sorted[index]
                        }
                        let elapsed = ProcessInfo.processInfo.systemUptime - start
                        let frames = MetalTerminalRenderer.framesPresented - framesBefore
                        let rebuilt = MetalTerminalRenderer.rowsRebuilt - rebuiltBefore
                        let reused = MetalTerminalRenderer.rowsReused - reusedBefore
                        let mean = handlerDurations.reduce(0, +)
                            / Double(max(1, handlerDurations.count))
                        let targetFPS = MetalTerminalRenderer
                            .interactiveContentTargetFPS(
                                isKeyWindow: window.isKeyWindow,
                                thermalState: ProcessInfo.processInfo.thermalState,
                                lowPowerMode: ProcessInfo.processInfo
                                    .isLowPowerModeEnabled,
                                maximumFramesPerSecond: max(
                                    60,
                                    window.screen?.maximumFramesPerSecond ?? 60))
                        let activeDuration = Double(eventCount) / eventRate
                        let cadenceRatio = Double(frames)
                            / max(1, targetFPS * activeDuration)
                        // Selection is dynamic Metal geometry. Dragging it may
                        // present cached rows, but must never invalidate or
                        // rebuild terminal text rows. The cadence target is
                        // hardware-aware and is reduced by Low Power Mode or
                        // thermal pressure before this ratio is evaluated.
                        let ok = handlerDurations.count == eventCount
                            && !pane.blockStore.blocks.isEmpty
                            && !surface.failedBlockRows.isEmpty
                            && rebuilt == 0
                            && reused > 0
                            && cadenceRatio >= 0.75
                        print(String(format:
                            "UISELECTION grid=%dx%d screenHz=%d lowPower=%@ "
                            + "blocks=%d failed=%d events=%d elapsed=%.3f fps=%.2f "
                            + "targetFPS=%.0f cadenceRatio=%.3f "
                            + "handlerMeanMs=%.3f handlerP95Ms=%.3f handlerMaxMs=%.3f "
                            + "timerP95Ms=%.3f timerMaxMs=%.3f rebuilt=%d reused=%d ok=%@",
                            surface.engine.cols, surface.engine.rows,
                            window.screen?.maximumFramesPerSecond ?? 0,
                            ProcessInfo.processInfo.isLowPowerModeEnabled
                                ? "true" : "false",
                            pane.blockStore.blocks.count,
                            surface.failedBlockRows.count,
                            eventCount, elapsed, Double(frames) / elapsed,
                            targetFPS, cadenceRatio,
                            mean * 1_000,
                            percentile(handlerDurations, 0.95) * 1_000,
                            (handlerDurations.max() ?? 0) * 1_000,
                            percentile(timerLateness, 0.95) * 1_000,
                            (timerLateness.max() ?? 0) * 1_000,
                            rebuilt, reused, ok ? "true" : "false"))
                        fflush(stdout)
                        exit(ok ? 0 : 1)
                    }
                }
                timer.resume()
            }
        }
    }

    /// Drives real NSWindows through create, reorder, animation, and restore.
    /// The pure layout tests cover resize math; this gate proves that AppKit's
    /// visible frames follow the same model in the assembled application.
    private func runWindowGridSmokeTest() {
        Preferences.shared.workspaceNavigatorVisible = false
        Preferences.shared.workspaceInspectorVisible = false
        Preferences.shared.contentMargin = 10
        Preferences.shared.windowGridStateData = nil
        Preferences.shared.windowGridEnabled = true
        newWindow(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self?.newWindow(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    guard let self,
                          self.controllers.count == 3,
                          let first = self.controllers[0].window,
                          let second = self.controllers[1].window,
                          let third = self.controllers[2].window,
                          let visible = first.screen?.visibleFrame
                    else {
                        print("UIWINDOWGRID FAIL setup")
                        fflush(stdout)
                        exit(1)
                    }

                    let tolerance: CGFloat = 1
                    let initialFrames = [first.frame, second.frame, third.frame]
                    let left = initialFrames.max { $0.height < $1.height }!
                    let right = initialFrames.filter { $0 != left }
                    let verticalGap = right.count == 2
                        ? abs(right[0].minX - left.maxX - 10) <= tolerance
                            && abs(right[1].minX - left.maxX - 10) <= tolerance
                        : false
                    let orderedRight = right.sorted { $0.minY < $1.minY }
                    let horizontalGap = orderedRight.count == 2
                        ? abs(orderedRight[1].minY - orderedRight[0].maxY - 10)
                            <= tolerance
                        : false
                    let fillsScreen = abs(left.minX - visible.minX) <= tolerance
                        && abs(left.minY - visible.minY) <= tolerance
                        && abs(left.height - visible.height) <= tolerance
                        && orderedRight.last.map {
                            abs($0.maxX - visible.maxX) <= tolerance
                                && abs($0.maxY - visible.maxY) <= tolerance
                        } == true
                        && orderedRight.first.map {
                            abs($0.minY - visible.minY) <= tolerance
                        } == true
                    let initialOK = verticalGap && horizontalGap && fillsScreen

                    let resizeBegan = self.windowGridCoordinator
                        .beginResizeForTesting(
                            self.controllers[0], edge: .right)
                    var draggedFrame = first.frame
                    draggedFrame.size.width =
                        WindowGridLayout.defaultMinimumSize.width
                    first.setFrame(draggedFrame, display: true)
                    // The first pass crosses the narrow-grid breakpoint and
                    // removes titlebar chrome; the continued gesture can then
                    // reach the compact native floor.
                    first.setFrame(draggedFrame, display: true)
                    self.windowGridCoordinator.windowDidResize(
                        self.controllers[0])
                    self.windowGridCoordinator.windowDidEndLiveResize(
                        self.controllers[0])

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let compactWidth = first.frame.width
                        let nativeMinimumWidth = first.minSize.width
                        let compactDiagnostic = self.controllers[0]
                            .compactGridWidthDiagnostic()
                        let resized = resizeBegan
                            && abs(compactWidth
                                - WindowGridLayout.defaultMinimumSize.width)
                                <= tolerance
                            && abs(second.frame.minX - first.frame.maxX - 10)
                                <= tolerance
                            && abs(third.frame.minX - first.frame.maxX - 10)
                                <= tolerance

                        let targetFrame = third.frame
                        let leavesBeforeDrop = self.windowGridCoordinator
                            .leafIDsForTesting(on: first.screen ?? NSScreen.main!)
                        let targetPoint = CGPoint(
                            x: targetFrame.midX, y: targetFrame.midY)
                        let began = self.windowGridCoordinator.updateDrag(
                            window: first, mouse: targetPoint)
                        // Release immediately: a real quick drag/drop must
                        // commit the candidate even before hover preview.
                        self.windowGridCoordinator.endDrag(window: first)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            let leavesAfterDrop = self.windowGridCoordinator
                                .leafIDsForTesting(
                                    on: first.screen ?? NSScreen.main!)
                            let quickReordered = abs(first.frame.minX
                                - targetFrame.minX) <= tolerance
                                && abs(first.frame.minY
                                    - targetFrame.minY) <= tolerance
                                && abs(first.frame.width
                                    - targetFrame.width) <= tolerance
                                && abs(first.frame.height
                                    - targetFrame.height) <= tolerance

                            // Now keep the source visibly off-grid long enough
                            // for hover preview. Only its neighbors may animate;
                            // the held frame must remain native until mouse-up.
                            let heldTargetFrame = second.frame
                            var heldFrame = first.frame
                            heldFrame.origin.x = max(
                                visible.minX, heldFrame.minX - 24)
                            heldFrame.origin.y = min(
                                visible.maxY - heldFrame.height,
                                heldFrame.minY + 24)
                            first.setFrame(heldFrame, display: true)
                            let heldTargetPoint = CGPoint(
                                x: heldTargetFrame.midX,
                                y: heldTargetFrame.midY)
                            let heldBegan = self.windowGridCoordinator.updateDrag(
                                window: first, mouse: heldTargetPoint)
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + 0.08) {
                                let previewed = self.windowGridCoordinator
                                    .updateDrag(
                                        window: first, mouse: heldTargetPoint)
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.28) {
                                    let activeDuringHold = self.windowGridCoordinator
                                        .isDragging(window: first)
                                    let heldActual = NSStringFromRect(first.frame)
                                    let heldExpected = NSStringFromRect(heldFrame)
                                    let held = abs(first.frame.minX
                                        - heldFrame.minX) <= tolerance
                                        && abs(first.frame.minY
                                            - heldFrame.minY) <= tolerance
                                        && abs(first.frame.width
                                            - heldFrame.width) <= tolerance
                                        && abs(first.frame.height
                                            - heldFrame.height) <= tolerance
                                    self.windowGridCoordinator.endDrag(window: first)
                                    DispatchQueue.main.asyncAfter(
                                        deadline: .now() + 0.8) {
                                        let dropDiagnostic = self.windowGridCoordinator
                                            .layoutDiagnosticForTesting()
                                        let actualAtDrop = NSStringFromRect(first.frame)
                                        let dropMismatches = dropDiagnostic.mismatches
                                        let reordered = abs(first.frame.minX
                                            - heldTargetFrame.minX) <= tolerance
                                            && abs(first.frame.minY
                                                - heldTargetFrame.minY) <= tolerance
                                            && abs(first.frame.width
                                                - heldTargetFrame.width) <= tolerance
                                            && abs(first.frame.height
                                                - heldTargetFrame.height) <= tolerance
                                        Preferences.shared.windowGridEnabled = false
                                        DispatchQueue.main.asyncAfter(
                                            deadline: .now() + 0.35) {
                                            let restored = [first, second, third]
                                                .allSatisfy {
                                                    abs($0.frame.width - 860)
                                                        <= tolerance
                                                        && abs($0.frame.height - 540)
                                                            <= tolerance
                                                }
                                            let ok = initialOK && resized
                                                && began && quickReordered
                                                && heldBegan && previewed
                                                && held && reordered && restored
                                            print(
                                                "UIWINDOWGRID count=3 inset=10 "
                                                    + "initial=\(initialOK) "
                                                    + "resize=\(resized) "
                                                    + "compact=\(resized) "
                                                    + "compactWidth=\(compactWidth) "
                                                    + "minWidth=\(nativeMinimumWidth) "
                                                    + compactDiagnostic + " "
                                                    + "quick=\(quickReordered) "
                                                    + "held=\(held) "
                                                    + "holdActive=\(activeDuringHold) "
                                                    + "holdActual=\(heldActual) "
                                                    + "holdExpected=\(heldExpected) "
                                                    + "reorder=\(reordered) "
                                                    + "topology=\(leavesBeforeDrop != leavesAfterDrop) "
                                                    + "dropFrames=\(dropDiagnostic.frames) "
                                                    + "actual=\(actualAtDrop) "
                                                    + "target=\(NSStringFromRect(heldTargetFrame)) "
                                                    + "mismatches=\(dropMismatches) "
                                                    + "restore=\(restored) ok=\(ok)")
                                            fflush(stdout)
                                            exit(ok ? 0 : 1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Reproduces the five-window recursive shape where one half contains two
    /// nested small leaves. Its multiple simultaneous neighbor animations used
    /// to confuse WindowDock's mover heuristic and replace the real source.
    private func runWindowGridNestedDragSmokeTest() {
        Preferences.shared.workspaceNavigatorVisible = false
        Preferences.shared.workspaceInspectorVisible = false
        Preferences.shared.contentMargin = 10
        Preferences.shared.windowGridStateData = nil
        Preferences.shared.windowGridEnabled = true
        newWindow(nil)

        var created = 1
        func addNext() {
            guard created < 5 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    exerciseDrag()
                }
                return
            }
            newWindow(nil)
            created += 1
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.06, execute: addNext)
        }
        func exerciseDrag() {
            // Freeze the lifecycle topology before selecting the nested source
            // and target. The test then starts one deliberate stale animation
            // below, instead of racing whichever create animation happened to
            // be in flight when the fifth window appeared.
            windowGridCoordinator.reconcile(animated: false)
            let participants = windowGridParticipants()
            guard participants.count == 5,
                  let screen = participants.first?.screen,
                  let tree = windowGridCoordinator.treeForConversion(on: screen)
            else { exit(1) }
            let modelFrames = WindowGridLayout.frames(
                for: tree,
                in: screen.visibleFrame,
                gap: Preferences.shared.contentMargin,
                scale: screen.backingScaleFactor)
            guard let sourceParticipant = participants.max(by: {
                    let lhs = modelFrames[$0.id] ?? .zero
                    let rhs = modelFrames[$1.id] ?? .zero
                    return lhs.width * lhs.height < rhs.width * rhs.height
                  }),
                  let targetParticipant = participants.min(by: {
                    let lhs = modelFrames[$0.id] ?? .zero
                    let rhs = modelFrames[$1.id] ?? .zero
                    return lhs.width * lhs.height < rhs.width * rhs.height
                  }),
                  sourceParticipant.id != targetParticipant.id,
                  let targetFrame = modelFrames[targetParticipant.id]
            else { exit(1) }

            let tolerance: CGFloat = 1
            let visible = screen.visibleFrame
            let source = sourceParticipant.window
            let largestFrame = modelFrames[sourceParticipant.id] ?? source.frame
            let largestArea = largestFrame.width * largestFrame.height
            let smallestArea = targetFrame.width * targetFrame.height
            let nested = largestArea >= smallestArea * 1.8
            var heldFrame = source.frame
            heldFrame.origin.x += source.frame.midX < visible.midX ? 24 : -24
            heldFrame.origin.y += source.frame.midY < visible.midY ? 24 : -24
            heldFrame.origin.x = min(
                max(visible.minX, heldFrame.minX),
                visible.maxX - heldFrame.width)
            heldFrame.origin.y = min(
                max(visible.minY, heldFrame.minY),
                visible.maxY - heldFrame.height)
            source.setFrame(heldFrame, display: true)

            let targetPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            // Start the exact pre-fix failure deterministically: a grid frame
            // animation owns all five windows when the native drag begins.
            // updateDrag must cancel it synchronously and preserve the frame
            // that AppKit actually presents at mouse-down. Reduced-motion
            // environments may legally finish this reconcile immediately.
            windowGridCoordinator.reconcile(animated: true)
            let dragStartFrame = source.frame
            let began = windowGridCoordinator.updateDrag(
                window: source, mouse: targetPoint)
            let dockSource = MainActor.assumeIsolated {
                WindowDock.shared.adoptActiveGridSourceForTesting()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                let previewed = self.windowGridCoordinator.updateDrag(
                    window: source, mouse: targetPoint)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    let holdActive = self.windowGridCoordinator
                        .isDragging(window: source)
                    let holdActual = NSStringFromRect(source.frame)
                    let holdExpected = NSStringFromRect(dragStartFrame)
                    let dragTargets = self.windowGridCoordinator
                        .dragTargetsForTesting
                    let sessionOriginalTree = self.windowGridCoordinator
                        .dragOriginalTreeForTesting ?? tree
                    let sameOriginalTree = sessionOriginalTree == tree
                    let expectedMovedTree = WindowGridLayout.moving(
                        sourceParticipant.id,
                        to: targetParticipant.id,
                        in: sessionOriginalTree)
                    let previewTreeMoved = self.windowGridCoordinator
                        .treeForConversion(on: screen) == expectedMovedTree
                    let held = abs(source.frame.minX
                            - dragStartFrame.minX) <= tolerance
                        && abs(source.frame.minY
                            - dragStartFrame.minY) <= tolerance
                        && abs(source.frame.width
                            - dragStartFrame.width) <= tolerance
                        && abs(source.frame.height
                            - dragStartFrame.height) <= tolerance
                    self.windowGridCoordinator.endDrag(window: source)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let diagnostic = self.windowGridCoordinator
                            .layoutDiagnosticForTesting()
                        let finalTreeMoved = self.windowGridCoordinator
                            .treeForConversion(on: screen) == expectedMovedTree
                        let reordered = abs(source.frame.minX
                            - targetFrame.minX) <= tolerance
                            && abs(source.frame.minY
                                - targetFrame.minY) <= tolerance
                            && abs(source.frame.width
                                - targetFrame.width) <= tolerance
                            && abs(source.frame.height
                                - targetFrame.height) <= tolerance
                        let ok = nested && began && dockSource && previewed
                            && held && sameOriginalTree
                            && previewTreeMoved && finalTreeMoved
                            && reordered
                            && diagnostic.participants == 5
                            && diagnostic.leaves == 5
                            && diagnostic.membership && diagnostic.frames
                        print(
                            "UIWINDOWGRIDNESTED count=5 nested=\(nested) "
                                + "source=\(dockSource) held=\(held) "
                                + "holdActive=\(holdActive) "
                                + "holdActual=\(holdActual) "
                                + "holdExpected=\(holdExpected) "
                                + "candidate=\(dragTargets.candidate ?? "nil") "
                                + "preview=\(dragTargets.preview ?? "nil") "
                                + "wanted=\(targetParticipant.id) "
                                + "sameOriginal=\(sameOriginalTree) "
                                + "previewTree=\(previewTreeMoved) "
                                + "finalTree=\(finalTreeMoved) "
                                + "reorder=\(reordered) "
                                + "actual=\(NSStringFromRect(source.frame)) "
                                + "target=\(NSStringFromRect(targetFrame)) "
                                + "frames=\(diagnostic.frames) "
                                + "mismatches=\(diagnostic.mismatches) ok=\(ok)")
                        fflush(stdout)
                        exit(ok ? 0 : 1)
                    }
                }
            }
        }
        addNext()
    }

    /// Reproduces holding Cmd-W while creating windows faster than the grid's
    /// animation duration. The final frame must come from the newest topology,
    /// never from an older AppKit completion handler.
    private func finishWindowGridSmokeTest(_ succeeded: Bool) {
        let holdSeconds = ProductIdentity.current
            .environmentValue("UI_TEST_HOLD_SECONDS")
            .flatMap(Double.init)
            .map { min(max($0, 0), 60) } ?? 0
        guard holdSeconds > 0 else { exit(succeeded ? 0 : 1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
            NSApp.terminate(nil)
        }
    }

    private func runWindowGridStressSmokeTest() {
        Preferences.shared.workspaceNavigatorVisible = false
        Preferences.shared.workspaceInspectorVisible = false
        Preferences.shared.contentMargin = 10
        Preferences.shared.windowGridStateData = nil
        Preferences.shared.windowGridEnabled = true
        newWindow(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let base = self.controllers.first else { exit(1) }
            var closedShellPIDs: [pid_t] = []

            // Interleave create/close pairs while every previous 180 ms frame
            // animation is still active.
            for index in 0..<10 {
                let start = Double(index) * 0.025
                DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                    self.newWindow(nil)
                    if let shellPID = self.controllers
                        .last(where: { $0 !== base })?
                        .panes.first?.surface.shellPid,
                       shellPID > 0 {
                        closedShellPIDs.append(shellPID)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + start + 0.012) {
                    self.controllers.last(where: { $0 !== base })?
                        .window?.performClose(nil)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                let interleavedClosed = self.controllers.count == 1

                // Then create a full burst in one run-loop turn and remove it
                // with Cmd-W-like cadence before its first animation can finish.
                for _ in 0..<8 { self.newWindow(nil) }
                let peakCreated = self.controllers.count == 9
                closedShellPIDs.append(contentsOf: self.controllers
                    .filter { $0 !== base }
                    .compactMap { $0.panes.first?.surface.shellPid }
                    .filter { $0 > 0 })
                for index in 0..<8 {
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Double(index) * 0.012) {
                        self.controllers.last(where: { $0 !== base })?
                            .window?.performClose(nil)
                    }
                }

                // Creating eight native windows in one main-thread turn can
                // itself take more than half a second. Measure from the burst
                // boundary far enough out for the final close event plus its
                // bounded 620 ms chrome/frame settle chain.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    guard let window = base.window,
                          let visible = window.screen?.visibleFrame else { exit(1) }
                    let tolerance: CGFloat = 1
                    let fillsScreen = abs(window.frame.minX - visible.minX)
                            <= tolerance
                        && abs(window.frame.minY - visible.minY) <= tolerance
                        && abs(window.frame.width - visible.width) <= tolerance
                        && abs(window.frame.height - visible.height) <= tolerance
                    let oneWindow = self.controllers.count == 1
                        && self.windowGridParticipants().count == 1
                    let leafIDs = self.windowGridCoordinator
                        .leafIDsForTesting(on: window.screen ?? NSScreen.main!)
                    let uniqueClosedShellPIDs = Set(closedShellPIDs)
                    let closedShellsGone = closedShellPIDs.count == 18
                        && uniqueClosedShellPIDs.count == 18
                        && closedShellPIDs.allSatisfy { pid in
                            kill(pid, 0) == -1 && errno == ESRCH
                        }
                    let ok = interleavedClosed && peakCreated
                        && oneWindow && leafIDs.count == 1 && fillsScreen
                        && closedShellsGone
                    print("UIWINDOWGRIDSTRESS pairs=10 burst=8 "
                          + "interleaved=\(interleavedClosed) "
                          + "peak=\(peakCreated) one=\(oneWindow) "
                          + "shells=\(closedShellsGone) "
                          + "shellCount=\(closedShellPIDs.count) "
                          + "uniqueShellCount=\(uniqueClosedShellPIDs.count) "
                          + "fills=\(fillsScreen) "
                          + "leaves=\(leafIDs.count) "
                          + "frame=\(NSStringFromRect(window.frame)) "
                          + "visible=\(NSStringFromRect(visible)) ok=\(ok)")
                    fflush(stdout)
                    self.finishWindowGridSmokeTest(ok)
                }
            }
        }
    }

    /// Dense add-only burst: unlike the create/close stress gate, this keeps
    /// every new window alive and catches a newest window stranded in its
    /// compact pre-grid frame until a later Cmd-N happens to heal the layout.
    private func runWindowGridAddStressSmokeTest() {
        Preferences.shared.workspaceNavigatorVisible = false
        Preferences.shared.workspaceInspectorVisible = false
        // Keep all 32 leaves feasible on GitHub's 1024x768 virtual display.
        // The regular and nested real-window gates cover the 10-point gap;
        // this profile isolates rapid topology growth without asking AppKit
        // to violate each window's native minimum size.
        Preferences.shared.contentMargin = 0
        Preferences.shared.windowGridStateData = nil
        Preferences.shared.windowGridEnabled = true
        newWindow(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { exit(1) }
            var created = 1
            func addNext() {
                guard created < 32 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        finish()
                    }
                    return
                }
                self.newWindow(nil)
                created += 1
                // Cross run-loop boundaries like real rapid Cmd-N key repeat;
                // a synchronous for-loop misses overlapping presentation and
                // frame-animation callbacks.
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.025, execute: addNext)
            }
            func finish() {
                let diagnostic = self.windowGridCoordinator
                    .layoutDiagnosticForTesting()
                let count = self.controllers.count
                let ok = count == 32
                    && diagnostic.participants == 32
                    && diagnostic.leaves == 32
                    && diagnostic.membership
                    && diagnostic.frames
                print("UIWINDOWGRIDADD count=\(count) "
                      + "participants=\(diagnostic.participants) "
                      + "leaves=\(diagnostic.leaves) "
                      + "membership=\(diagnostic.membership) "
                      + "frames=\(diagnostic.frames) ok=\(ok) "
                      + "mismatches=\(diagnostic.mismatches)")
                fflush(stdout)
                self.finishWindowGridSmokeTest(ok)
            }
            addNext()
        }
    }

    /// Proves the reversible model conversion with real windows and real live
    /// TerminalPane instances: split tree -> grid windows -> split tree.
    private func runWindowGridConversionSmokeTest() {
        Preferences.shared.workspaceNavigatorVisible = false
        Preferences.shared.workspaceInspectorVisible = false
        Preferences.shared.contentMargin = 10
        Preferences.shared.windowGridStateData = nil
        Preferences.shared.windowGridEnabled = false
        newWindow(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self,
                  let host = self.controllers.first,
                  let first = host.panes.first,
                  let second = host.splitPane(first, vertical: true),
                  host.splitPane(second, vertical: false) != nil
            else {
                print("UIWINDOWGRIDCONVERT FAIL setup")
                fflush(stdout)
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard let originalTree = host.paneGridNodeForTesting() else {
                    print("UIWINDOWGRIDCONVERT FAIL source-tree")
                    fflush(stdout)
                    exit(1)
                }
                let originalPanes = Dictionary(uniqueKeysWithValues:
                    host.panes.map { ($0.paneId, $0.surface.shellPid) })
                let broke = host.breakAllSplitsIntoGridWindows()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    let diagnostic = self.windowGridCoordinator
                        .layoutDiagnosticForTesting()
                    let gridOK = broke
                        && self.controllers.count == 3
                        && self.controllers.allSatisfy { $0.panes.count == 1 }
                        && diagnostic.participants == 3
                        && diagnostic.leaves == 3
                        && diagnostic.membership
                        && diagnostic.frames
                    guard let combinedHost = self.currentController else {
                        exit(1)
                    }
                    let conversionTree = combinedHost.window?.screen.flatMap {
                        self.windowGridCoordinator.treeForConversion(on: $0)
                    }
                    let paneIDsByWindowID = Dictionary(uniqueKeysWithValues:
                        self.windowGridParticipants().compactMap { participant
                            -> (String, String)? in
                            guard participant.controller.panes.count == 1,
                                  let paneID = participant.controller.panes.first?.paneId
                            else { return nil }
                            return (participant.id, paneID)
                        })
                    let conversionPaneTree = conversionTree.flatMap {
                        self.replacingGridLeafIDs(in: $0, with: paneIDsByWindowID)
                    }
                    let conversionGeometry = conversionPaneTree.map {
                        self.sameGridGeometry(originalTree, $0)
                    } ?? false
                    self.combineGridWindowsIntoSplits(nil)
                    let deadline = ProcessInfo.processInfo.systemUptime + 3.0
                    func finish() {
                        let finalPanes = Dictionary(uniqueKeysWithValues:
                            combinedHost.panes.map {
                                ($0.paneId, $0.surface.shellPid)
                            })
                        let finalTree = combinedHost.paneGridNodeForTesting()
                        let geometry = finalTree.map {
                            self.sameGridGeometry(originalTree, $0)
                        } ?? false
                        let live = finalPanes == originalPanes
                        let ok = gridOK
                            && conversionGeometry
                            && self.controllers.count == 1
                            && combinedHost.panes.count == 3
                            && live && geometry
                        if !ok,
                           ProcessInfo.processInfo.systemUptime < deadline {
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + 0.05, execute: finish)
                            return
                        }
                        let diagnostic = ok ? "" :
                            " original=\(originalTree)"
                                + " conversionTree=\(String(describing: conversionPaneTree))"
                                + " final=\(String(describing: finalTree))"
                        print("UIWINDOWGRIDCONVERT broke=\(broke) "
                              + "grid=\(gridOK) windows=\(self.controllers.count) "
                              + "panes=\(combinedHost.panes.count) live=\(live) "
                              + "conversion=\(conversionGeometry) "
                              + "geometry=\(geometry) ok=\(ok)"
                              + diagnostic)
                        fflush(stdout)
                        exit(ok ? 0 : 1)
                    }
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + 0.05, execute: finish)
                }
            }
        }
    }

    /// Dense version of the conversion gate. Closing thirty-one donor windows
    /// resizes the surviving host repeatedly; its final internal split ratios
    /// must still describe the original balanced grid rather than squeezed
    /// right-edge slivers.
    private func runWindowGridConversionStressSmokeTest() {
        Preferences.shared.workspaceNavigatorVisible = false
        Preferences.shared.workspaceInspectorVisible = false
        // Match the add-only stress fixture: a zero-gap 32-leaf topology fits
        // the smallest qualified virtual display while preserving the deep
        // conversion and repeated native-resize workload this gate exercises.
        Preferences.shared.contentMargin = 0
        Preferences.shared.windowGridStateData = nil
        Preferences.shared.windowGridEnabled = true
        newWindow(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { exit(1) }
            var created = 1
            func addNext() {
                guard created < 32 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        combine()
                    }
                    return
                }
                self.newWindow(nil)
                created += 1
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.025, execute: addNext)
            }
            func combine() {
                guard let host = self.currentController,
                      let screen = host.window?.screen ?? NSScreen.main,
                      let tree = self.windowGridCoordinator
                        .treeForConversion(on: screen)
                else { exit(1) }
                let leafIDs = Set(WindowGridLayout.leafIDs(in: tree))
                let participants = self.windowGridParticipants().filter {
                    leafIDs.contains($0.id)
                }
                let paneIDsByWindowID = Dictionary(uniqueKeysWithValues:
                    participants.compactMap { participant
                        -> (String, String)? in
                        guard participant.controller.panes.count == 1,
                              let paneID = participant.controller.panes.first?.paneId
                        else { return nil }
                        return (participant.id, paneID)
                    })
                guard participants.count == 32,
                      paneIDsByWindowID.count == 32,
                      let expectedPaneTree = self.replacingGridLeafIDs(
                        in: tree, with: paneIDsByWindowID)
                else { exit(1) }
                let originalPIDs = Dictionary(uniqueKeysWithValues:
                    participants.compactMap { participant
                        -> (String, pid_t)? in
                        guard let pane = participant.controller.panes.first
                        else { return nil }
                        return (pane.paneId, pane.surface.shellPid)
                    })
                let combined = host.combineGridWindowsIntoSplits(
                    tree: tree, participants: participants)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    let finalTree = host.paneGridNodeForTesting()
                    let finalFrames = host.paneFramesForTesting()
                    let finalPIDs = Dictionary(uniqueKeysWithValues:
                        host.panes.map { ($0.paneId, $0.surface.shellPid) })
                    let geometry = finalTree.map {
                        self.sameGridGeometry(
                            expectedPaneTree, $0, tolerance: 0.03)
                    } ?? false
                    let minimumWidth = finalFrames.values.map(\.width).min() ?? 0
                    let minimumHeight = finalFrames.values.map(\.height).min() ?? 0
                    let balanced = minimumWidth >= 100 && minimumHeight >= 60
                    let live = finalPIDs == originalPIDs
                    let ok = combined
                        && self.controllers.count == 1
                        && host.panes.count == 32
                        && geometry && balanced && live
                    print("UIWINDOWGRIDCONVERTSTRESS combined=\(combined) "
                          + "windows=\(self.controllers.count) "
                          + "panes=\(host.panes.count) geometry=\(geometry) "
                          + "minWidth=\(minimumWidth) "
                          + "minHeight=\(minimumHeight) balanced=\(balanced) "
                          + "live=\(live) ok=\(ok)")
                    fflush(stdout)
                    exit(ok ? 0 : 1)
                }
            }
            addNext()
        }
    }

    private func replacingGridLeafIDs(
        in node: WindowGridNode,
        with ids: [String: String]
    ) -> WindowGridNode? {
        switch node {
        case .leaf(let id):
            return ids[id].map(WindowGridNode.leaf)
        case .split(let axis, let ratio, let first, let second):
            guard let mappedFirst = replacingGridLeafIDs(in: first, with: ids),
                  let mappedSecond = replacingGridLeafIDs(in: second, with: ids)
            else { return nil }
            return .split(
                axis: axis, ratio: ratio,
                first: mappedFirst, second: mappedSecond)
        }
    }

    private func sameGridGeometry(
        _ lhs: WindowGridNode,
        _ rhs: WindowGridNode,
        tolerance: CGFloat = 0.03
    ) -> Bool {
        switch (lhs, rhs) {
        case (.leaf(let a), .leaf(let b)):
            return a == b
        case let (.split(aAxis, aRatio, aFirst, aSecond),
                  .split(bAxis, bRatio, bFirst, bSecond)):
            return aAxis == bAxis
                && abs(aRatio - bRatio) <= tolerance
                && sameGridGeometry(aFirst, bFirst, tolerance: tolerance)
                && sameGridGeometry(aSecond, bSecond, tolerance: tolerance)
        default:
            return false
        }
    }

    @objc func openConfig(_ sender: Any?) {
        CmdyEditorManager.shared.open(ConfigFile.prepareForEditing(), respectPreference: true)
    }
    @objc func reloadConfig(_ sender: Any?) {
        Theme.reloadUserThemes()
        ConfigFile.applyIfPresent()
    }

    @objc private func preferencesDidChange() {
        windowGridCoordinator.preferencesDidChange()
        refreshMenuStates()
        PluginManager.shared.emitThemeChanged()
    }

    @objc private func marketplaceUpdatesDidChange() {
        refreshMenuStates()
    }

    @objc private func appUpdateDidChange() {
        refreshMenuStates()
    }

    /// Proactively set checkmarks so the menu reflects state without relying on
    /// validateMenuItem timing (which wasn't showing for the GPU toggle).
    @objc private func refreshMenuStates() {
        guard let menu = NSApp.mainMenu else { return }
        applyStates(in: menu)
        refreshValueLabels(in: menu)
    }

    private func applyStates(in menu: NSMenu) {
        let p = Preferences.shared
        for item in menu.items {
            switch item.action {
            case #selector(setThemeMenu(_:)):
                item.state = (item.representedObject as? String
                    == (currentController?.selectedThemeName ?? p.themeName))
                    ? .on : .off
            case #selector(setCursorMenu(_:)):
                item.state = (item.representedObject as? String == p.cursorStyleName) ? .on : .off
            case #selector(toggleSmoothCursor(_:)): item.state = p.smoothCursor ? .on : .off
            case #selector(setCursorGlideSpeed(_:)):
                if let v = item.representedObject as? Double {
                    item.state = abs(v - Double(p.cursorGlideSpeed)) < 0.001 ? .on : .off
                }
            case #selector(setScrollSpeed(_:)):
                if let v = item.representedObject as? Double {
                    item.state = abs(v - Double(p.scrollSpeed)) < 0.001 ? .on : .off
                }
            case #selector(setCursorGlideDistance(_:)):
                if let v = item.representedObject as? Double {
                    item.state = abs(v - Double(p.cursorGlideMaxDistance)) < 0.001 ? .on : .off
                }
            case #selector(setFontMenu(_:)):
                item.state = (item.representedObject as? String == p.fontName) ? .on : .off
            case #selector(setLineHeightMenu(_:)):
                if let v = item.representedObject as? Double {
                    item.state = abs(v - Double(p.lineHeight)) < 0.001 ? .on : .off
                }
            case #selector(setWindowInsetMenu(_:)):
                if let v = item.representedObject as? Double {
                    item.state = abs(v - Double(p.contentMargin)) < 0.001 ? .on : .off
                }
            case #selector(setOpacityMenu(_:)):
                if let v = item.representedObject as? Double {
                    item.state = abs(v - p.opacity) < 0.001 ? .on : .off
                }
            case #selector(setShaderMenu(_:)):
                item.state = (item.representedObject as? String
                    == (currentController?.selectedShaderName ?? p.shaderName))
                    ? .on : .off
            case #selector(toggleOptionAsMeta(_:)): item.state = p.optionAsMeta ? .on : .off
            case #selector(toggleShellIntegration(_:)): item.state = p.shellIntegration ? .on : .off
            case #selector(toggleAutomaticErrorHelp(_:)): item.state = p.automaticErrorHelp ? .on : .off
            case #selector(toggleCleanPrompt(_:)): item.state = p.cleanPrompt ? .on : .off
            case #selector(toggleHideTrafficLights(_:)): item.state = p.hideTrafficLights ? .on : .off
            case #selector(toggleWindowGrid(_:)): item.state = p.windowGridEnabled ? .on : .off
            case #selector(toggleBlur(_:)): item.state = p.blur ? .on : .off
            case #selector(showPlugins(_:)):
                let count = MarketplaceUpdateMonitor.shared.extensionUpdateCount
                item.title = count == 0 ? "Extensions…"
                    : "Extensions… (\(count) Update\(count == 1 ? "" : "s"))"
            case #selector(showChannelManager(_:)):
                let count = MarketplaceUpdateMonitor.shared.channelUpdateCount
                item.title = count == 0 ? "Channels…"
                    : "Channels… (\(count) Update\(count == 1 ? "" : "s"))"
            default: break
            }
            if let sub = item.submenu { applyStates(in: sub) }
        }
    }

    /// The appearance submenus carry their current value in the title
    /// ("Font — Menlo"), so the selection is visible without opening them.
    private func refreshValueLabels(in menu: NSMenu) {
        let p = Preferences.shared
        for item in menu.items {
            guard let sub = item.submenu else { continue }
            switch sub.title {
            case "Theme":
                item.title = "Theme — \(currentController?.selectedThemeName ?? p.themeName)"
            case "Font": item.title = "Font — \(fontDisplayName(p.fontName))"
            case "Shader":
                item.title = "Shader — \(currentController?.selectedShaderName ?? p.shaderName)"
            case "Cursor": item.title = "Cursor — \(Self.cursorLabel(p.cursorStyleName))"
            case "Glide Speed": item.title = "Glide Speed — \(String(format: "%.2gx", p.cursorGlideSpeed))"
            case "Scroll Speed": item.title = "Scroll Speed — \(Self.scrollSpeedLabel(p.scrollSpeed))"
            case "Glide Distance":
                item.title = p.cursorGlideMaxDistance == 0
                    ? "Glide Distance — Unlimited"
                    : "Glide Distance — \(Int(p.cursorGlideMaxDistance)) cells"
            case "Line Spacing": item.title = "Line Spacing — \(Self.lineSpacingLabel(p.lineHeight))"
            case "Window Inset": item.title = "Window Inset — \(Int(p.contentMargin))pt"
            case "Window Opacity": item.title = "Window Opacity — \(Int((p.opacity * 100).rounded()))%"
            default: refreshValueLabels(in: sub)
            }
        }
    }

    private func fontDisplayName(_ name: String) -> String {
        if name == "System" { return "System Mono" }
        if let bf = bundledFonts.first(where: { $0.fontName == name }) { return bf.displayName }
        return NSFont(name: name, size: 12)?.displayName ?? name
    }

    private static func cursorLabel(_ value: String) -> String {
        switch value {
        case "steadyBlock": return "Block"
        case "blinkBar": return "Bar (blink)"
        case "steadyBar": return "Bar"
        case "blinkUnderline": return "Underline (blink)"
        case "steadyUnderline": return "Underline"
        default: return "Block (blink)"
        }
    }

    static let lineSpacingOptions: [(String, Double)] = [
        ("Tight", 0.8), ("Snug", 0.85), ("Normal", 1.0),
        ("Relaxed", 1.15), ("Loose", 1.3), ("Airy", 1.5),
    ]

    static let scrollSpeedOptions: [(String, Double)] = [
        ("Gentle", 0.5), ("Slow", 0.75), ("Normal", 1.0),
        ("Quick", 1.5), ("Fast", 2.0), ("Very Fast", 3.0),
    ]

    private static func scrollSpeedLabel(_ value: CGFloat) -> String {
        if let match = scrollSpeedOptions.first(where: {
            abs($0.1 - Double(value)) < 0.001
        }) {
            return "\(match.0) · \(String(format: "%.2gx", match.1))"
        }
        return String(format: "%.2gx", Double(value))
    }

    private static func lineSpacingLabel(_ value: CGFloat) -> String {
        if let match = lineSpacingOptions.first(where: { abs($0.1 - Double(value)) < 0.001 }) {
            return match.0
        }
        return String(format: "%.2f×", Double(value))
    }

    private static func textRenderingLabel(_ value: String) -> String {
        switch value {
        case "y-snap": return "Y snap"
        case "atlas-padding": return "atlas padding"
        case "nearest": return "nearest"
        case "high-contrast": return "high contrast"
        case "crisp": return "crisp combined"
        default: return "current"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Sidebar tabs are inactive, ordered-out NSWindows, but they are still
        // live logical terminals. Quit only after the final controller closes,
        // never merely because AppKit temporarily has no visible window.
        controllers.isEmpty
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension.caseInsensitiveCompare("cmdyext") == .orderedSame {
                PluginsWindow.shared.installExtensionPackage(from: url)
                continue
            }
            if let request = Marketplace.extensionInstallRequest(from: url) {
                switch request {
                case .marketplace(let id):
                    PluginsWindow.shared.installMarketplaceExtension(id: id)
                case .package(let packageURL):
                    PluginsWindow.shared.installExtensionPackage(from: packageURL)
                }
                continue
            }
            CmdyEditorManager.shared.open(url, respectPreference: false)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editorTerminationApproved || !CmdyEditorManager.shared.hasDirtyDocuments {
            controllers.forEach { $0.approveNextWindowClose() }
            return .terminateNow
        }
        CmdyEditorManager.shared.confirmAllDirty { [weak self] approved in
            guard let self else { return }
            self.editorTerminationApproved = approved
            if approved { self.controllers.forEach { $0.approveNextWindowClose() } }
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        PluginManager.shared.emit("app-activation", ["active": true])
        refreshActionsMenu()
    }

    func applicationDidResignActive(_ notification: Notification) {
        PluginManager.shared.emit("app-activation", ["active": false])
    }

    func applicationDidHide(_ notification: Notification) {
        PluginManager.shared.emit("app-activation", ["active": false, "hidden": true])
    }

    func applicationDidUnhide(_ notification: Notification) {
        PluginManager.shared.emit("app-activation", ["active": true, "hidden": false])
    }

    /// Regression coverage for the custom rail-divider overlay. A collapsed
    /// Inspector view retains its old AppKit frame; dragging the Navigator
    /// must not reinterpret that stale width as a request to reveal it.
    private func runSidebarResizeSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let controller = currentController,
                  let result =
                    controller.performNavigatorDividerResizeSmokeTest(delta: 32)
            else {
                print("UISIDEBARRESIZE FAIL unavailable")
                fflush(stdout)
                exit(1)
            }
            let resized = result.navigatorAfter > result.navigatorBefore + 20
            let chrome = controller.workspaceChromeVisibility
            let preferenceHidden =
                !Preferences.shared.workspaceInspectorVisible
            let ok = resized
                && !chrome.inspector
                && preferenceHidden
                && result.inspectorCollapsed
                && result.inspectorSplitSubviewHidden
            print(
                "UISIDEBARRESIZE before=\(result.navigatorBefore) "
                    + "after=\(result.navigatorAfter) resized=\(resized) "
                    + "chromeInspector=\(chrome.inspector) "
                    + "preferenceHidden=\(preferenceHidden) "
                    + "collapsed=\(result.inspectorCollapsed) "
                    + "subviewHidden=\(result.inspectorSplitSubviewHidden) "
                    + "ok=\(ok)")
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
    }

    /// Exercise the actual pane callbacks and the same live-pane transfer used
    /// by the drag dropper. The hold variant leaves the first split on-screen
    /// for visual inspection instead of mutating it.
    private func runSplitAffordanceSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let controller = currentController,
                  let window = controller.window,
                  let first = controller.panes.first,
                  let closeCandidate = controller.splitPane(
                    first, vertical: true)
            else {
                print("UISPLITAFFORDANCE FAIL setup")
                fflush(stdout)
                exit(1)
            }
            window.setFrame(
                NSRect(x: 180, y: 180, width: 920, height: 560),
                display: true)
            window.makeKeyAndOrderFront(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                window.contentView?.layoutSubtreeIfNeeded()
                let diagnostics = controller.panes.map {
                    (pane: $0, value: $0.splitAffordanceDiagnostic)
                }
                let alwaysVisible = diagnostics.count == 2
                    && diagnostics.allSatisfy(\.value.visible)
                let cornered = diagnostics.allSatisfy {
                    let gap = $0.pane.bounds.maxX - $0.value.frame.maxX
                    return (5...9).contains(gap)
                        && $0.value.frame.width == 46
                        && $0.value.frame.height == 24
                }
                let bottomRailClear = diagnostics.allSatisfy {
                    let bottomGap = $0.value.frame.minY - $0.pane.bounds.minY
                    return abs(bottomGap - 4) <= 1
                        && $0.value.bottomClearance >= 31
                }
                let bare = diagnostics.allSatisfy(\.value.bare)
                let labelled = diagnostics.allSatisfy {
                    $0.value.dragHelp == "Detach Pane (or drag)"
                        && $0.value.closeHelp == "Close Split"
                }
                let closeTarget = closeCandidate
                    .splitAffordanceClosePointerTestTarget()
                let detachTarget = closeCandidate
                    .splitAffordanceDetachPointerTestTarget()
                let clickable = closeTarget?.receivesHit == true
                let detachClickable = detachTarget?.receivesHit == true
                let expectedHairline = 1 / max(1, window.backingScaleFactor)
                let verticalDividers = controller
                    .paneDividerAppearanceDiagnostic
                    .filter(\.vertical)
                let verticalFinelined = verticalDividers.count == 1
                    && verticalDividers.allSatisfy {
                        abs($0.layoutThickness - 2) < 0.001
                            && abs(($0.hairline ?? 0) - expectedHairline)
                                < 0.001
                    }

                print("UISPLITAFFORDANCE ready alwaysVisible=\(alwaysVisible) "
                      + "cornered=\(cornered) labelled=\(labelled) "
                      + "bottomRail=\(bottomRailClear) bare=\(bare) "
                      + "clickable=\(clickable) "
                      + "detachClickable=\(detachClickable) "
                      + "closeHit=\(closeTarget?.hitView ?? "nil") "
                      + "detachHit=\(detachTarget?.hitView ?? "nil") "
                      + "verticalFinelined=\(verticalFinelined) "
                      + "window=\(window.windowNumber)")
                fflush(stdout)
                if CommandLine.arguments.contains(
                    "--ui-test-split-affordance-hold") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        exit(alwaysVisible && cornered
                             && bottomRailClear && bare && labelled && clickable
                             && detachClickable
                             && verticalFinelined
                             ? 0 : 1)
                    }
                    return
                }

                guard let closeTarget, closeTarget.receivesHit else {
                    print("UISPLITAFFORDANCE FAIL hit-target")
                    fflush(stdout)
                    exit(1)
                }
                let windowPoint = window.convertPoint(
                    fromScreen: closeTarget.screenPoint)
                guard let down = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1),
                      let up = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 0)
                else {
                    print("UISPLITAFFORDANCE FAIL events")
                    fflush(stdout)
                    exit(1)
                }
                // Exercise the real NSButton route. The queued release lets
                // NSButton finish its synchronous tracking loop.
                NSApp.postEvent(up, atStart: true)
                window.sendEvent(down)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard controller.panes.count == 1,
                          let remaining = controller.panes.first,
                          !remaining.splitAffordanceDiagnostic.visible,
                          let moveCandidate = controller.splitPane(
                            remaining, vertical: false)
                    else {
                        print("UISPLITAFFORDANCE FAIL close")
                        fflush(stdout)
                        exit(1)
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        let horizontalDividers = controller
                            .paneDividerAppearanceDiagnostic
                            .filter { !$0.vertical }
                        let horizontalFinelined = horizontalDividers.count == 1
                            && horizontalDividers.allSatisfy {
                                abs($0.layoutThickness - 2) < 0.001
                                    && abs(($0.hairline ?? 0)
                                        - expectedHairline) < 0.001
                            }
                        let identity = ObjectIdentifier(moveCandidate)
                        let pid = moveCandidate.surface.shellPid
                        window.contentView?.layoutSubtreeIfNeeded()
                        guard let detachTarget = moveCandidate
                                .splitAffordanceDetachPointerTestTarget(),
                              detachTarget.receivesHit
                        else {
                            print("UISPLITAFFORDANCE FAIL detach-hit-target")
                            fflush(stdout)
                            exit(1)
                        }
                        let detachPoint = window.convertPoint(
                            fromScreen: detachTarget.screenPoint)
                        guard let detachDown = NSEvent.mouseEvent(
                            with: .leftMouseDown,
                            location: detachPoint,
                            modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber,
                            context: nil,
                            eventNumber: 0,
                            clickCount: 1,
                            pressure: 1),
                              let detachUp = NSEvent.mouseEvent(
                                with: .leftMouseUp,
                                location: detachPoint,
                                modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber,
                                context: nil,
                                eventNumber: 0,
                                clickCount: 1,
                                pressure: 0)
                        else {
                            print("UISPLITAFFORDANCE FAIL detach-events")
                            fflush(stdout)
                            exit(1)
                        }
                        window.sendEvent(detachDown)
                        window.sendEvent(detachUp)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            let destination = self.controllers.first { candidate in
                                candidate !== controller
                                    && candidate.panes.contains { $0 === moveCandidate }
                            }
                            let moved = destination?.panes.first
                            let detachClick = destination != nil
                            let closeOK = controller.panes.count == 1
                            let identityOK = moved.map {
                                ObjectIdentifier($0) == identity
                            } == true
                            let processOK = pid > 0
                                && moved?.surface.shellPid == pid
                            let singleControlsHidden =
                                controller.panes.allSatisfy {
                                    !$0.splitAffordanceDiagnostic.visible
                                }
                                && destination?.panes.allSatisfy {
                                    !$0.splitAffordanceDiagnostic.visible
                                } == true
                            let registered = destination.map { destination in
                                self.controllers.contains {
                                    $0 === destination
                                }
                            } == true
                            let ok = alwaysVisible && cornered
                                && bottomRailClear && bare && labelled
                                && clickable && detachClickable
                                && verticalFinelined
                                && horizontalFinelined
                                && detachClick && closeOK && identityOK && processOK
                                && singleControlsHidden && registered
                            print(
                                "UISPLITAFFORDANCE close=\(closeOK) "
                                    + "detachClick=\(detachClick) "
                                    + "horizontalFinelined=\(horizontalFinelined) "
                                    + "identity=\(identityOK) "
                                    + "process=\(processOK) "
                                    + "controlsHidden=\(singleControlsHidden) "
                                    + "registered=\(registered) ok=\(ok)")
                            fflush(stdout)
                            exit(ok ? 0 : 1)
                        }
                    }
                }
            }
        }
    }

    /// A selected sidebar tab is a visible NSWindow layered over hidden sibling
    /// windows. The replacement must be frontmost before Command-W returns;
    /// waiting for the next run-loop turn exposes the desktop for one frame.
    private func runSidebarCloseSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let first = currentController else {
                print("UISIDEBARCLOSE FAIL initial-window")
                fflush(stdout)
                exit(1)
            }
            newTab(attachedTo: first.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let closing = self.currentController else {
                    print("UISIDEBARCLOSE FAIL selected-tab")
                    fflush(stdout)
                    exit(1)
                }
                let tabs = self.workspaceTabs(containing: closing)
                guard tabs.count == 2,
                      let replacement = tabs.first(where: { $0 !== closing }),
                      let closingFrame = closing.window?.frame else {
                    print("UISIDEBARCLOSE FAIL tab-set")
                    fflush(stdout)
                    exit(1)
                }

                // This is the same route StandardKeybindings uses for Command-W.
                closing.closePaneOrWindow()

                let immediatelyVisible =
                    replacement.window?.isVisible == true
                let immediatelyKey =
                    replacement.window?.isKeyWindow == true
                let immediateFrameMatched =
                    replacement.window?.frame == closingFrame
                let closingRemoved =
                    !self.controllers.contains { $0 === closing }
                let selectedImmediately =
                    self.selectedWorkspaceTab(containing: replacement)
                        === replacement

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let finalTabs =
                        self.workspaceTabs(containing: replacement)
                    let finalVisibleCount = finalTabs.filter {
                        $0.window?.isVisible == true
                    }.count
                    let finalKey =
                        replacement.window?.isKeyWindow == true
                    let appActive = NSApp.isActive
                    let focusSettled = !appActive || finalKey
                    let ok = immediatelyVisible
                        && immediateFrameMatched
                        && closingRemoved
                        && selectedImmediately
                        && finalTabs.count == 1
                        && finalVisibleCount == 1
                        && focusSettled
                    print(
                        "UISIDEBARCLOSE visible=\(immediatelyVisible) "
                            + "immediateKey=\(immediatelyKey) "
                            + "frame=\(immediateFrameMatched) "
                            + "removed=\(closingRemoved) "
                            + "selected=\(selectedImmediately) "
                            + "finalTabs=\(finalTabs.count) "
                            + "finalVisible=\(finalVisibleCount) "
                            + "finalKey=\(finalKey) "
                            + "appActive=\(appActive) "
                            + "ok=\(ok)")
                    fflush(stdout)
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    /// Exercise the structural half of the real card drag without synthesizing
    /// brittle pointer coordinates. This covers both kinds of tear-out (an
    /// inactive card and the selected card), an edge-zone split, and the center
    /// zone's add-as-tab path while checking that the same panes and PTYs survive.
    private func runSidebarTabDragSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let first = currentController else {
                print("UISIDEBARDRAG FAIL initial-window")
                fflush(stdout)
                exit(1)
            }
            newTab(attachedTo: first.window)
            newTab(attachedTo: currentController?.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let selected = self.currentController else {
                    print("UISIDEBARDRAG FAIL selected-tab")
                    fflush(stdout)
                    exit(1)
                }
                let initialTabs = self.workspaceTabs(containing: selected)
                guard initialTabs.count == 3,
                      let source = initialTabs.first(where: { $0 !== selected }),
                      let sourcePane = source.panes.first,
                      let selectedWindow = selected.window else {
                    print("UISIDEBARDRAG FAIL tab-set")
                    fflush(stdout)
                    exit(1)
                }
                WindowDock.shared.beginSidebarTabDrag(source)
                let previewSize = WindowDock.shared
                    .sidebarTabDragPreviewSize(measured: .zero)
                let previewShown = WindowDock.shared
                    .showSidebarTabDragPreview(
                        AnyView(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor)),
                        size: previewSize,
                        anchor: CGPoint(x: 0.5, y: 0.5))
                let previewOK = previewShown
                    && previewSize.width > 100
                    && previewSize.height > 50
                WindowDock.shared.cancelSidebarTabDrag()
                let paneIdentity = ObjectIdentifier(sourcePane)
                let shellPID = sourcePane.surface.shellPid
                let frame = selectedWindow.frame
                let drop = NSPoint(
                    x: frame.maxX + 80,
                    y: frame.maxY - 40)
                let tornOut = self.tearOutWorkspaceTab(source, at: drop)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let sourceSet = self.workspaceTabs(containing: source)
                    let remainingSet = self.workspaceTabs(containing: selected)
                    let tearOutOK = tornOut
                        && sourceSet.count == 1
                        && remainingSet.count == 2
                        && source.window?.isVisible == true
                        && selected.window?.isVisible == true
                        && sourcePane.surface.shellPid == shellPID

                    let split = self.moveWorkspaceTab(
                        source, into: selected, side: .right)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let movedPane = selected.panes.first {
                            ObjectIdentifier($0) == paneIdentity
                        }
                        let finalSet = self.workspaceTabs(containing: selected)
                        let finalVisible = finalSet.filter {
                            $0.window?.isVisible == true
                        }.count
                        let splitOK = split
                            && movedPane?.surface.shellPid == shellPID
                            && selected.panes.count == 2
                            && !self.controllers.contains { $0 === source }
                            && finalSet.count == 2
                            && finalVisible == 1
                        guard let replacement = finalSet.first(where: {
                            $0 !== selected
                        }) else {
                            print("UISIDEBARDRAG FAIL replacement-tab")
                            fflush(stdout)
                            exit(1)
                        }

                        let treeIdentities = Set(selected.panes.map {
                            ObjectIdentifier($0)
                        })
                        let treePIDs = Set(selected.panes.map {
                            $0.surface.shellPid
                        })
                        let selectedDrop = NSPoint(
                            x: frame.maxX + 140,
                            y: frame.maxY - 80)
                        let selectedTornOut = self.tearOutWorkspaceTab(
                            selected, at: selectedDrop)

                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 0.5
                        ) {
                            let selectedSet = self.workspaceTabs(
                                containing: selected)
                            let replacementSet = self.workspaceTabs(
                                containing: replacement)
                            let treeSurvivedTearOut =
                                Set(selected.panes.map {
                                    ObjectIdentifier($0)
                                }) == treeIdentities
                                && Set(selected.panes.map {
                                    $0.surface.shellPid
                                }) == treePIDs
                            let selectedTearOutOK = selectedTornOut
                                && selectedSet.count == 1
                                && replacementSet.count == 1
                                && selected.window?.isVisible == true
                                && replacement.window?.isVisible == true
                                && treeSurvivedTearOut

                            let tabbed = self.moveWorkspaceTab(
                                selected, into: replacement, side: nil)
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + 0.5
                            ) {
                                let tabSet = self.workspaceTabs(
                                    containing: selected)
                                let tabVisible = tabSet.filter {
                                    $0.window?.isVisible == true
                                }.count
                                let treeSurvivedTab =
                                    Set(selected.panes.map {
                                        ObjectIdentifier($0)
                                    }) == treeIdentities
                                    && Set(selected.panes.map {
                                        $0.surface.shellPid
                                    }) == treePIDs
                                let tabOK = tabbed
                                    && tabSet.count == 2
                                    && tabSet.contains(where: {
                                        $0 === replacement
                                    })
                                    && self.selectedWorkspaceTab(
                                        containing: replacement) === selected
                                    && tabVisible == 1
                                    && selected.window?.isVisible == true
                                    && treeSurvivedTab
                                let ok = previewOK && tearOutOK && splitOK
                                    && selectedTearOutOK && tabOK
                                print(
                                    "UISIDEBARDRAG preview=\(previewOK) "
                                        + "tornOut=\(tornOut) "
                                        + "tearOutOK=\(tearOutOK) "
                                        + "split=\(split) splitOK=\(splitOK) "
                                        + "selectedTearOut=\(selectedTornOut) "
                                        + "selectedTearOutOK=\(selectedTearOutOK) "
                                        + "tabbed=\(tabbed) tabOK=\(tabOK) "
                                        + "tabs=\(tabSet.count) "
                                        + "visible=\(tabVisible) "
                                        + "panes=\(selected.panes.count) "
                                        + "pids=\(treePIDs.sorted()) "
                                        + "ok=\(ok)")
                                fflush(stdout)
                                exit(ok ? 0 : 1)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Regression coverage for the presentation-neutral workspace model. The
    /// preference notification reaches every controller, so this deliberately
    /// exercises the same multi-observer timing as the real menu shortcut.
    private func runWorkspaceTabPresentationSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let first = self.currentController else {
                print("UIWORKSPACE FAIL initial-window")
                exit(1)
            }
            for _ in 0..<3 {
                self.newTab(attachedTo: self.currentController?.window)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let sidebarControllers =
                    self.workspaceTabSet(containing: first).controllers
                let sidebarCount = sidebarControllers.count
                Preferences.shared.workspaceNavigatorVisible = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let selected = self.currentController else {
                        print("UIWORKSPACE FAIL native-window")
                        exit(1)
                    }
                    let nativeControllers =
                        self.workspaceTabSet(containing: selected).controllers
                    let nativeSetCount = nativeControllers.count
                    let nativeGroupCount = selected.window?.tabGroup?.windows.count ?? 0
                    let nativeOrderPreserved = zip(
                        sidebarControllers, nativeControllers
                    ).allSatisfy { $0.0 === $0.1 }
                    Preferences.shared.workspaceNavigatorVisible = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard let final = self.currentController else {
                            print("UIWORKSPACE FAIL sidebar-window")
                            exit(1)
                        }
                        let finalSet = self.workspaceTabSet(containing: final)
                        let finalCount = finalSet.controllers.count
                        let visibleCount = finalSet.controllers.filter {
                            $0.window?.isVisible == true
                        }.count
                        let nativeChromeCount =
                            final.window?.tabGroup?.windows.count ?? 0
                        let nativeButtonsVisible =
                            final.window?.standardWindowButton(.closeButton)?
                                .isHidden == false
                        let toolbarVisible = final.window?.toolbar != nil
                        let finalOrderPreserved = zip(
                            sidebarControllers, finalSet.controllers
                        ).allSatisfy { $0.0 === $0.1 }
                        let ok = sidebarCount == 4
                            && nativeSetCount == 4
                            && nativeGroupCount == 4
                            && nativeOrderPreserved
                            && finalCount == 4
                            && visibleCount == 1
                            && nativeChromeCount <= 1
                            && nativeButtonsVisible
                            && toolbarVisible
                            && finalOrderPreserved
                        print(
                            "UIWORKSPACE sidebar=\(sidebarCount) "
                                + "nativeSet=\(nativeSetCount) "
                                + "nativeGroup=\(nativeGroupCount) "
                                + "nativeOrder=\(nativeOrderPreserved) "
                                + "final=\(finalCount) "
                                + "visible=\(visibleCount) "
                                + "nativeChrome=\(nativeChromeCount) "
                                + "nativeButtons=\(nativeButtonsVisible) "
                                + "toolbar=\(toolbarVisible) "
                                + "finalOrder=\(finalOrderPreserved) "
                                + "ok=\(ok)")
                        fflush(stdout)
                        exit(ok ? 0 : 1)
                    }
                }
            }
        }
    }

    /// Regression coverage for per-tab companions such as Browser. Sidebar
    /// tabs are separate NSWindows, so only the selected tab receives the dock
    /// reservation. That reservation must compress terminal content without
    /// replacing the Navigator with native tabs or hiding the Inspector.
    private func runWorkspaceDockPresentationSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let first = self.currentController else {
                print("UIWORKSPACEDOCK FAIL initial-window")
                exit(1)
            }
            for _ in 0..<2 {
                self.newTab(attachedTo: self.currentController?.window)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let selected = self.currentController,
                      let window = selected.window else {
                    print("UIWORKSPACEDOCK FAIL selected-window")
                    exit(1)
                }
                let initialSet = self.workspaceTabSet(containing: first)
                let initialCount = initialSet.controllers.count
                let reservation = max(420, floor(window.frame.width * 0.46))
                selected.pluginDockInset = reservation

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let dockedSet = self.workspaceTabSet(containing: selected)
                    let dockedCount = dockedSet.controllers.count
                    let dockedVisibleCount = dockedSet.controllers.filter {
                        $0.window?.isVisible == true
                    }.count
                    let dockedNativeChromeCount =
                        selected.window?.tabGroup?.windows.count ?? 0
                    let dockedChrome = selected.workspaceChromeVisibility
                    let dockedTrailing =
                        selected.dockGeometry["trailing"] as? Double ?? 0

                    // Hidden tabs still receive AppKit layout callbacks. Their
                    // inset-free geometry must remain an idempotent vote for
                    // the already-visible sidebar presentation.
                    for inactive in dockedSet.controllers where inactive !== selected {
                        inactive.syncTabPresentation(tabSidebarVisible: true)
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let stayedSidebar = dockedSet.usesSidebar
                            && dockedVisibleCount == 1
                            && dockedNativeChromeCount <= 1
                            && dockedChrome.navigator
                            && dockedChrome.inspector
                            && dockedTrailing
                                >= Double(WorkspaceFrameLayout.minimumInspectorWidth)
                        selected.pluginDockInset = 0

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            let finalSet = self.workspaceTabSet(containing: selected)
                            let finalCount = finalSet.controllers.count
                            let visibleCount = finalSet.controllers.filter {
                                $0.window?.isVisible == true
                            }.count
                            let nativeChromeCount =
                                selected.window?.tabGroup?.windows.count ?? 0
                            let ok = initialCount == 3
                                && dockedCount == 3
                                && stayedSidebar
                                && finalSet.usesSidebar
                                && finalCount == 3
                                && visibleCount == 1
                                && nativeChromeCount <= 1
                            print(
                                "UIWORKSPACEDOCK initial=\(initialCount) "
                                    + "docked=\(dockedCount) "
                                    + "sidebar=\(stayedSidebar) "
                                    + "navigator=\(dockedChrome.navigator) "
                                    + "inspector=\(dockedChrome.inspector) "
                                    + "trailing=\(dockedTrailing) "
                                    + "final=\(finalCount) "
                                    + "visible=\(visibleCount) "
                                    + "nativeChrome=\(nativeChromeCount) "
                                    + "ok=\(ok)")
                            fflush(stdout)
                            exit(ok ? 0 : 1)
                        }
                    }
                }
            }
        }
    }

    /// Headless verification of cross-window pane adoption: shells must stay
    /// alive through releasePanes/adopt, and the donor window must close.
    private func runMergeSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let host = self.controllers.first
                host?.mergeAllWindowsIntoSplits()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let paneCount = host?.panes.count ?? -1
                    let shellsAlive = host?.panes.allSatisfy { $0.currentCwd != nil } ?? false
                    print("UITEST windows=\(self.controllers.count) panes=\(paneCount) shellsAlive=\(shellsAlive)")
                    // Directional dock: a third window merged onto the top edge.
                    self.newWindow(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if let donor = self.controllers.first(where: { $0 !== host })?.window {
                            host?.merge(window: donor, side: .top)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            let alive = host?.panes.allSatisfy { $0.currentCwd != nil } ?? false
                            let sizes = (host?.panes ?? []).map {
                                "\(Int($0.frame.width))x\(Int($0.frame.height))"
                            }.joined(separator: ",")
                            print("UITEST2 windows=\(self.controllers.count) panes=\(host?.panes.count ?? -1) shellsAlive=\(alive) sizes=\(sizes)")
                            // Pane breakout: focused pane leaves the split into
                            // its own window, shell intact.
                            host?.breakOutFocusedPane(asTab: false)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                let out = self.controllers.first { $0 !== host }
                                let ok = (out?.panes.count == 1)
                                    && (out?.panes.first?.currentCwd != nil)
                                print("UITEST3 windows=\(self.controllers.count) hostPanes=\(host?.panes.count ?? -1) breakoutOK=\(ok)")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    private func runPaneCompositionSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let first = self.controllers.first,
                  let firstPane = first.panes.first,
                  first.splitPane(firstPane, vertical: true) != nil else {
                print("UICOMPOSE FAIL setup")
                exit(1)
            }
            self.newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let sourcePanes = self.controllers.flatMap(\.panes)
                let ids = sourcePanes.map(\.paneId)
                let pids = Dictionary(uniqueKeysWithValues: sourcePanes.map {
                    ($0.paneId, $0.surface.shellPid)
                })
                guard ids.count == 3 else {
                    print("UICOMPOSE FAIL expected=3 actual=\(ids.count)")
                    exit(1)
                }
                do { _ = try self.composePanes(ids: ids) }
                catch {
                    print("UICOMPOSE FAIL \(error.localizedDescription)")
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let expected = Set(ids)
                    let destination = self.controllers.first {
                        Set($0.panes.map(\.paneId)) == expected
                    }
                    let sameProcesses = destination?.panes.allSatisfy {
                        pids[$0.paneId] == $0.surface.shellPid && $0.surface.shellPid > 0
                    } ?? false
                    let usableFrames = destination?.panes.allSatisfy {
                        $0.frame.width > 100 && $0.frame.height > 100
                    } ?? false
                    let onlyDestination = self.controllers.count == 1
                    let ok = destination?.panes.count == 3 && sameProcesses
                        && usableFrames && onlyDestination
                    let sizes = destination?.panes.map {
                        "\(Int($0.frame.width))x\(Int($0.frame.height))"
                    }.joined(separator: ",") ?? "none"
                    print("UICOMPOSE panes=\(destination?.panes.count ?? -1) sameProcesses=\(sameProcesses) usableFrames=\(usableFrames) windows=\(self.controllers.count) sizes=\(sizes)")
                    fflush(stdout)
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    /// Visibility semantics gate: two Show Editor commands from one terminal
    /// must reveal the same attached document instead of allocating a second
    /// untitled editor.
    private func runShowEditorSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let terminal = self.currentController,
                  let window = terminal.window,
                  let surface = (terminal.focusedPane ?? terminal.panes.first)?.surface
                    as? CmdyTerminalSurface else {
                print("UISHOWEDITOR FAIL no terminal")
                exit(1)
            }
            guard let menuItem = NSApp.mainMenu?
                .cmdyDescendantMenu(titled: "File")?
                .item(withTitle: "Show Editor"),
                  let menuAction = menuItem.action else {
                print("UISHOWEDITOR FAIL no menu item")
                exit(1)
            }
            let manager = CmdyEditorManager.shared
            let before = manager.documentCountForTesting
            let selectionStartRow = surface.renderSnapshot.grid.displayTopRow
            let staleSelectionColumn = max(1, surface.engine.cols - 2)
            surface.setSelectionForTesting(
                anchor: .init(row: selectionStartRow, col: staleSelectionColumn),
                active: .init(row: selectionStartRow + 1, col: 0))
            let routedFirst = NSApp.sendAction(
                menuAction, to: menuItem.target, from: menuItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                _ = surface.captureGrid()
                let resizedColumns = surface.engine.cols
                let selectionClearedOnReflow = staleSelectionColumn >= resizedColumns
                    && surface.selectedColumnsForShaping(row: selectionStartRow) == nil
                    && surface.selectedColumnsForShaping(row: selectionStartRow + 1) == nil
                    && surface.selectedText().isEmpty
                let first = manager.editor(in: window)
                let afterFirst = manager.documentCountForTesting
                let routedSecond = NSApp.sendAction(
                    menuAction, to: menuItem.target, from: menuItem)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let second = manager.editor(in: window)
                    let afterSecond = manager.documentCountForTesting
                    let createdOne = afterFirst == before + 1
                    let reused = first != nil && first === second
                        && afterSecond == afterFirst
                    let attached = first?.isAttached == true
                        && first?.terminalController === terminal
                    let visible = window.isVisible && first?.window === window
                    let focused = first?.ownsFirstResponder(in: window) == true
                    let routed = routedFirst && routedSecond
                    let ok = routed && createdOne && reused && attached
                        && visible && focused && selectionClearedOnReflow
                    print("UISHOWEDITOR before=\(before) afterFirst=\(afterFirst) "
                          + "afterSecond=\(afterSecond) reused=\(reused) "
                          + "attached=\(attached) visible=\(visible) "
                          + "focused=\(focused) routed=\(routed) "
                          + "selectionCleared=\(selectionClearedOnReflow) ok=\(ok)")
                    fflush(stdout)
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    /// Real-window editor gate: prove custom chrome and editing shortcuts in a
    /// standalone window, dock it through the same path as a mouse drop, then
    /// resize, save, detach, reattach, and remove the final shell.
    private func runEditorSmokeTest() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-editor-smoke-\(getpid()).md")
        let longLine = String(repeating: "word ", count: 80)
        try? "# Editor smoke\n\(longLine)\nalpha\nbeta\n"
            .write(to: url, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let terminal = self.currentController, let window = terminal.window else {
                print("UIEDITOR FAIL no terminal")
                exit(1)
            }
            let standalone =
                ProductIdentity.current.environmentValue("UI_TEST_STANDALONE") == "1"
            guard let opened = CmdyEditorManager.shared.open(
                url, attach: false, respectPreference: false) else {
                print("UIEDITOR FAIL open")
                exit(1)
            }
            guard let editorWindow = opened.window else {
                print("UIEDITOR FAIL no editor window")
                exit(1)
            }
            editorWindow.contentView?.layoutSubtreeIfNeeded()
            let topClearance = editorWindow.contentView.map {
                $0.bounds.maxY - opened.frame.maxY
            } ?? 0
            let chrome = editorWindow.titleVisibility == .hidden
                && editorWindow.standardWindowButton(.closeButton)?.isHidden == false
                && editorWindow.toolbar != nil
                && topClearance >= 27
            let wrapped = opened.wrapsLines

            opened.textView.setSelectedRange(
                NSRange(location: opened.textView.string.utf16.count, length: 0))
            opened.textView.insertText("undo-probe", replacementRange: opened.textView.selectedRange())
            let key: (UInt16, String, NSEvent.ModifierFlags) -> NSEvent? = { code, chars, flags in
                NSEvent.keyEvent(with: .keyDown, location: .zero,
                                 modifierFlags: flags, timestamp: 0,
                                 windowNumber: editorWindow.windowNumber,
                                 context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)
            }
            if let undo = key(6, "z", [.command]) { _ = self.standardKeybindings?.handle(undo) }
            let undone = !opened.textView.string.hasSuffix("undo-probe")
            if let redo = key(6, "z", [.command, .shift]) { _ = self.standardKeybindings?.handle(redo) }
            let redone = opened.textView.string.hasSuffix("undo-probe")
            if let undo = key(6, "z", [.command]) { _ = self.standardKeybindings?.handle(undo) }
            if let select = key(0, "a", [.command]) { _ = self.standardKeybindings?.handle(select) }
            let selected = opened.textView.selectedRange().length == opened.textView.string.utf16.count
            let commands = undone && redone && selected
            opened.textView.setSelectedRange(
                NSRange(location: opened.textView.string.utf16.count, length: 0))
            if standalone {
                let delay =
                    ProductIdentity.current.environmentValue("UI_TEST_HOLD") == "1"
                    ? 15.0 : 0.8
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let visible = opened.textView.string.hasPrefix("# Editor")
                    print("UIEDITOR standalone=\(visible) chrome=\(chrome) wrapped=\(wrapped) commands=\(commands)")
                    fflush(stdout)
                    exit(visible && chrome && wrapped && commands ? 0 : 1)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let docked = WindowDock.shared.dockEditorWindow(
                    editorWindow, into: window, zone: .right)
                guard docked, opened.isAttached else {
                    print("UIEDITOR FAIL dock")
                    exit(1)
                }
                let editor = opened
                window.contentView?.layoutSubtreeIfNeeded()
                let attachedWrapped = editor.wrapsLines
                if let select = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    characters: "a", charactersIgnoringModifiers: "a",
                    isARepeat: false, keyCode: 0) {
                    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
                    _ = self.standardKeybindings?.handle(select)
                }
                let attachedCommands = editor.textView.selectedRange().length
                    == editor.textView.string.utf16.count
                editor.textView.setSelectedRange(
                    NSRange(location: editor.textView.string.utf16.count, length: 0))
                let before = editor.frame.width
                var frame = window.frame
                frame.size.width += 180
                window.setFrame(frame, display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let resized = editor.frame.width > before + 40
                    let resizedWrapped = editor.wrapsLines
                    let alignedTopInset = terminal.panes.first.map {
                        abs($0.surface.topContentInset - editor.topContentInset) < 0.5
                    } ?? false
                    let terminalCursorHidden = terminal.panes.allSatisfy {
                        $0.surface.hostCursorHidden
                    }
                    let oneRowMinimum = terminal.panes.first.map {
                        let expected = WindowChromeLayout.minimumWindowHeight(
                            rowHeight: $0.surface.cellSize.height,
                            contentMargin: Preferences.shared.contentMargin,
                            backingScale: window.backingScaleFactor)
                        return abs(window.minSize.height - expected) < 0.5
                    } ?? false
                    editor.textView.setSelectedRange(NSRange(location: editor.textView.string.utf16.count,
                                                             length: 0))
                    editor.textView.insertText("saved\n", replacementRange: editor.textView.selectedRange())
                    editor.save { saved in
                        let disk = (try? BoundedFileReader.utf8String(
                            at: url, maxBytes: 64 * 1024 * 1024)) ?? ""
                        let persisted = saved && disk.hasSuffix("saved\n")
                        CmdyEditorManager.shared.detachEditor(editor)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            let detached = !editor.isAttached && editor.window !== window
                            CmdyEditorManager.shared.attachEditor(editor, to: terminal)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                let reattached = editor.isAttached && editor.window === window
                                let closedShell = terminal.panes.first.map {
                                    terminal.closePaneById($0.paneId)
                                } ?? false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    let editorOnly = closedShell && terminal.panes.isEmpty
                                        && editor.window === window
                                        && editor.ownsFirstResponder(in: window)
                                    let ok = chrome && wrapped && attachedWrapped && resizedWrapped
                                        && commands && attachedCommands && docked && resized && persisted
                                        && alignedTopInset && terminalCursorHidden && oneRowMinimum
                                        && detached && reattached && editorOnly
                                    print("UIEDITOR chrome=\(chrome) wrapped=\(wrapped) attachedWrapped=\(attachedWrapped) resizedWrapped=\(resizedWrapped) commands=\(commands) attachedCommands=\(attachedCommands) docked=\(docked) resized=\(resized) alignedTopInset=\(alignedTopInset) terminalCursorHidden=\(terminalCursorHidden) oneRowMinimum=\(oneRowMinimum) saved=\(persisted) detached=\(detached) reattached=\(reattached) editorOnly=\(editorOnly)")
                                    try? FileManager.default.removeItem(at: url)
                                    fflush(stdout)
                                    exit(ok ? 0 : 1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func pluginPanes() -> [PluginPane] {
        controllers.enumerated().flatMap { wIdx, c in
            c.panes.enumerated().map { pIdx, pane -> PluginPane in
                var p = pluginPane(for: pane, in: c)
                p.windowIndex = wIdx + 1
                p.paneIndex = pIdx + 1
                p.windowTitle = c.window?.title
                return p
            }
        }
    }

    /// ⌘⇧U — cycle through panes that want attention, app-wide (the
    /// keyboard answer to "which pane needs me?").
    @objc func jumpToAttention(_ sender: Any?) {
        let needy = controllers.flatMap { c in c.panes.map { (c, $0) } }
            .filter { $0.1.wantsAttention }
        guard let (controller, pane) = needy.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        pane.focus()
    }

    /// Dock badge = number of panes waiting for the user, app-wide.
    func refreshAttentionBadge() {
        let count = controllers.flatMap { $0.panes }.filter { $0.wantsAttention }.count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func pluginPane(for pane: TerminalPane, in controller: TerminalWindowController) -> PluginPane {
        PluginPane(
            id: pane.paneId,
            title: (pane.currentCwd as NSString?)?.lastPathComponent ?? "shell",
            cwd: pane.currentCwd,
            pid: pane.surface.shellPid,
            tty: pane.ttyName,
            aiTool: BeamManager.aiTool(in: pane),
            attention: pane.wantsAttention,
            currentBlockID: pane.blockStore.blocks.last?.id,
            windowNumber: controller.window?.windowNumber ?? 0,
            type: { [weak pane] text in
                guard let pane else { return }
                BeamManager.beam(text, into: pane)
            },
            stage: { [weak pane] text in
                pane?.stageAgentPromptInput(text)
            },
            run: { [weak pane] command in
                pane?.replacePromptInput(with: command, submit: true)
            },
            focus: { [weak pane] in
                // SDK focus means "bring this to the user's eyes" — that
                // includes activating the app (also lets the attention dot
                // clear itself, since clearing requires being seen).
                NSApp.activate(ignoringOtherApps: true)
                pane?.window?.makeKeyAndOrderFront(nil)
                pane?.focus()
            },
            output: { [weak pane] lines in pane?.recentScrollbackText(maxLines: lines) ?? "" },
            scrollInfo: { [weak pane] in
                guard let tv = pane?.surface else { return [:] }
                let term = tv.engine
                return [
                    "yDisp": term.currentTopRow,
                    "rows": term.rows,
                    "scrollPosition": tv.scrollPosition,
                    "canScroll": tv.canScroll,
                    "isAlternateBuffer": term.isCurrentBufferAlternate,
                    "mouseMode": term.mouseModeDescription,
                ]
            },
            scrollBy: { [weak pane] lines in
                guard let tv = pane?.surface else { return }
                if lines < 0 { tv.scrollUp(lines: -lines) } else { tv.scrollDown(lines: lines) }
            },
            feed: { [weak pane] text in
                DispatchQueue.main.async { pane?.surface.feed(text: text) }
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        standardKeybindings?.invalidate()
        standardKeybindings = nil
        PluginManager.shared.deactivateAll()
        EmbeddedChromiumRuntime.shared.shutdown()
        if Preferences.shared.restoreSession, !uiTestMerge, !uiTestCompose {
            SessionStore.save(layouts: serializedSessionLayouts())
        }
        controllers.forEach { c in c.panes.forEach { $0.shutdown() } }   // kill spawned shells, no orphans
        Preferences.shared.clearIsolatedStorage()
    }

    var currentController: TerminalWindowController? {
        (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? controllers.last
    }

    func reloadImportedKeybindings() {
        standardKeybindings?.reloadImportedMappings()
    }

    /// Persist the presentation-neutral workspace owner for every controller.
    /// A one-tab workspace gets an ID too, so future restores never have to
    /// guess whether two coincidentally overlapping windows are related.
    func serializedSessionLayouts() -> [[String: Any]] {
        controllers.compactMap { controller in
            var node = controller.serializeLayout()
            guard !node.isEmpty else { return nil }
            let set = workspaceTabSet(containing: controller)
            guard let tabIndex = set.controllers.firstIndex(where: {
                $0 === controller
            }) else { return node }
            node[WorkspaceSessionKey.group] = set.identifier
            node[WorkspaceSessionKey.index] = tabIndex
            node[WorkspaceSessionKey.selected] = set.selected === controller
            node[WorkspaceSessionKey.sidebar] = set.usesSidebar
            return node
        }
    }

    /// Rebuild complete workspaces before allowing any controller to present
    /// itself. Older session files flattened sidebar tabs into independent
    /// records. When such a metadata-free session opens with the sidebar, fold
    /// every record into one recoverable workspace: no shell is discarded and
    /// the user gets one window instead of a desktop full of leaked tab owners.
    /// Without the sidebar, identical frames remain the narrow legacy signal.
    func restoreSession(_ saved: [[String: Any]]) {
        let hasExplicitWorkspaceGroups = saved.contains {
            $0[WorkspaceSessionKey.group] as? String != nil
        }
        let consolidateLegacySidebarSession =
            !hasExplicitWorkspaceGroups
            && Preferences.shared.workspaceNavigatorVisible
            && saved.count > 1
        let legacyFrameCounts = Dictionary(
            grouping: saved.enumerated().filter {
                $0.element[WorkspaceSessionKey.group] as? String == nil
            },
            by: { $0.element["frame"] as? String ?? "legacy-window-\($0.offset)" })
            .mapValues(\.count)

        var entries: [RestoredSessionEntry] = []
        for (originalIndex, node) in saved.enumerated() {
            let explicitGroup = node[WorkspaceSessionKey.group] as? String
            let frame = node["frame"] as? String
            let legacyGroup: String?
            if consolidateLegacySidebarSession {
                legacyGroup = "legacy-sidebar-session"
            } else if let frame, legacyFrameCounts[frame, default: 0] > 1 {
                legacyGroup = "legacy-frame:\(frame)"
            } else {
                legacyGroup = nil
            }
            let groupIdentifier = explicitGroup
                ?? legacyGroup
                ?? "legacy-window:\(originalIndex)"
            let controller = TerminalWindowController(
                session: node,
                deferWorkspaceTabPresentation: true)
            controllers.append(controller)
            entries.append(RestoredSessionEntry(
                originalIndex: originalIndex,
                controller: controller,
                groupIdentifier: groupIdentifier,
                tabIndex: node[WorkspaceSessionKey.index] as? Int ?? originalIndex,
                wasSelected: node[WorkspaceSessionKey.selected] as? Bool ?? false))
        }

        // Controller setup emits general workspace refresh notifications. Those
        // may create provisional singleton sets while the remaining saved tabs
        // are still being constructed; the persisted grouping below is the
        // authoritative owner for this restore.
        workspaceTabSets.removeAll()

        var orderedGroupIdentifiers: [String] = []
        for entry in entries where
            !orderedGroupIdentifiers.contains(entry.groupIdentifier) {
            orderedGroupIdentifiers.append(entry.groupIdentifier)
        }

        var restoredSets: [WorkspaceTabSet] = []
        for identifier in orderedGroupIdentifiers {
            let grouped = entries
                .filter { $0.groupIdentifier == identifier }
                .sorted {
                    if $0.tabIndex == $1.tabIndex {
                        return $0.originalIndex < $1.originalIndex
                    }
                    return $0.tabIndex < $1.tabIndex
                }
            let groupedControllers = grouped.map(\.controller)
            guard let fallbackSelection = groupedControllers.last else { continue }
            let selected = grouped.first(where: \.wasSelected)?.controller
                ?? fallbackSelection
            let set = WorkspaceTabSet(
                controllers: groupedControllers,
                selected: selected,
                identifier: identifier)
            set.usesSidebar = Preferences.shared.workspaceNavigatorVisible
            workspaceTabSets.append(set)
            restoredSets.append(set)
        }

        for set in restoredSets {
            set.controllers.forEach {
                $0.finishDeferredWorkspaceTabPresentation()
            }
            presentRestoredWorkspace(set)
        }
        // Every controller built its first rail snapshot while it was still a
        // standalone deferred window. Refresh once after all sets exist so the
        // selected Navigator immediately lists the complete restored group,
        // even when macOS does not deliver a new key-window callback.
        NotificationCenter.default.post(
            name: .cmdyWorkspaceFrameChanged, object: nil)
        restoredSets.last?.selected?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentRestoredWorkspace(_ set: WorkspaceTabSet) {
        guard let selected = set.selected ?? set.controllers.last,
              let selectedWindow = selected.window else { return }

        if set.usesSidebar {
            let frame = selectedWindow.frame
            for member in set.controllers {
                guard let window = member.window else { continue }
                suppressNativeTabBar(for: window)
                window.animationBehavior = .none
                window.setFrame(frame, display: false)
                window.isExcludedFromWindowsMenu = member !== selected
                if member !== selected { window.orderOut(nil) }
            }
            selected.showWindow(nil)
            selectedWindow.makeKeyAndOrderFront(nil)
            let rails = selected.workspaceRailGeometry()
            for member in set.controllers where member !== selected {
                member.applyWorkspaceRailGeometry(rails)
            }
        } else {
            guard let base = set.controllers.first, let baseWindow = base.window else {
                return
            }
            for member in set.controllers {
                member.window?.tabbingMode = .preferred
                member.window?.animationBehavior = .default
                member.window?.isExcludedFromWindowsMenu = false
            }
            base.showWindow(nil)
            // `.above` inserts immediately after the base window. Add from
            // the far end so the durable sidebar order survives the switch.
            for member in set.controllers.dropFirst().reversed() {
                if let window = member.window {
                    baseWindow.addTabbedWindow(window, ordered: .above)
                }
            }
            selectedWindow.makeKeyAndOrderFront(nil)
        }
    }

    /// Reconcile our presentation-neutral tab set with AppKit whenever native
    /// tabs are in use. Native drag/reorder/merge operations therefore remain
    /// authoritative instead of creating a second tab model.
    private func workspaceTabSet(containing controller: TerminalWindowController)
        -> WorkspaceTabSet {
        // Removing or adding native windows changes `tabGroup.windows`
        // incrementally and synchronously calls back into every controller.
        // The durable set must remain frozen until that presentation handoff
        // completes; otherwise each shrinking intermediate group overwrites
        // the full workspace and strands the removed tabs as singletons.
        if let transitioning = workspaceTabSets.first(where: { set in
            set.isTransitioning
                && set.controllers.contains { $0 === controller }
        }) {
            return transitioning
        }

        let nativeControllers = controller.window?.tabGroup?.windows.compactMap {
            $0.windowController as? TerminalWindowController
        } ?? []

        if nativeControllers.count > 1 {
            let intersecting = workspaceTabSets.filter { set in
                set.controllers.contains { candidate in
                    nativeControllers.contains { $0 === candidate }
                }
            }
            let set = intersecting.first
                ?? WorkspaceTabSet(controllers: nativeControllers, selected: controller)
            if intersecting.isEmpty { workspaceTabSets.append(set) }
            for obsolete in intersecting.dropFirst() {
                workspaceTabSets.removeAll { $0 === obsolete }
            }
            set.controllers = nativeControllers
            set.selected = controller.window?.tabGroup?.selectedWindow?.windowController
                as? TerminalWindowController ?? controller
            return set
        }

        if let existing = workspaceTabSets.first(where: {
            $0.controllers.contains { $0 === controller }
        }) {
            // A native tab was dragged out. AppKit briefly reports nil/one-tab
            // groups for background windows while a complete group changes
            // presentation, so treating that transient state as a detach
            // fractures a four-tab workspace into four singleton sidebars.
            // A real tear-off becomes the key native-mode window while at
            // least one sibling still belongs to the old multi-window group.
            let siblingStillGrouped = existing.controllers.contains { candidate in
                candidate !== controller
                    && (candidate.window?.tabGroup?.windows.count ?? 0) > 1
            }
            if !Preferences.shared.workspaceNavigatorVisible,
               !existing.usesSidebar,
               existing.controllers.count > 1,
               controller.window?.isKeyWindow == true,
               nativeControllers.count <= 1,
               siblingStillGrouped {
                existing.controllers.removeAll { $0 === controller }
                if existing.selected === controller {
                    existing.selected = existing.controllers.first
                }
                let detached = WorkspaceTabSet(controllers: [controller],
                                               selected: controller)
                workspaceTabSets.append(detached)
                return detached
            }
            existing.controllers.removeAll { candidate in
                !controllers.contains { $0 === candidate }
            }
            return existing
        }

        let set = WorkspaceTabSet(controllers: [controller], selected: controller)
        workspaceTabSets.append(set)
        return set
    }

    func workspaceTabs(containing controller: TerminalWindowController)
        -> [TerminalWindowController] {
        workspaceTabSet(containing: controller).controllers
    }

    /// Notification filtering must never reconcile/mutate every native tab
    /// set. This read-only identity check is intentionally cheap because each
    /// pane update is observed by every window.
    func controllersShareWorkspace(
        _ lhs: TerminalWindowController,
        _ rhs: TerminalWindowController
    ) -> Bool {
        if lhs === rhs { return true }
        if let lhsGroup = lhs.window?.tabGroup,
           lhsGroup === rhs.window?.tabGroup {
            return true
        }
        return workspaceTabSets.contains { set in
            var hasLHS = false
            var hasRHS = false
            for controller in set.controllers {
                if controller === lhs { hasLHS = true }
                if controller === rhs { hasRHS = true }
                if hasLHS && hasRHS { return true }
            }
            return false
        }
    }

    /// Pane output only needs the cross-window refresh bus when a rail in that
    /// workspace can actually present the changed state. Dense grid tiles
    /// usually collapse both rails; skipping the broadcast there prevents N
    /// pane updates from waking N otherwise idle window controllers.
    func workspaceHasVisibleRails(
        containing source: TerminalWindowController
    ) -> Bool {
        let sourceVisibility = source.workspaceChromeVisibility
        if sourceVisibility.navigator || sourceVisibility.inspector {
            return true
        }
        guard let set = workspaceTabSets.first(where: { set in
            set.controllers.contains { $0 === source }
        }) else { return false }
        return set.controllers.contains { controller in
            let visibility = controller.workspaceChromeVisibility
            return visibility.navigator || visibility.inspector
        }
    }

    func selectedWorkspaceTab(containing controller: TerminalWindowController)
        -> TerminalWindowController? {
        let set = workspaceTabSet(containing: controller)
        if !set.usesSidebar,
           let native = controller.window?.tabGroup?.selectedWindow?.windowController
                as? TerminalWindowController {
            set.selected = native
        }
        return set.selected ?? set.controllers.first
    }

    /// Switch between native top tabs and the left tab sidebar. AppKit's
    /// `isTabBarVisible` cannot suppress the mandatory grouped-window strip,
    /// so sidebar mode temporarily ungroups and hides inactive windows.
    func setWorkspaceTabSidebar(_ visible: Bool,
                                for controller: TerminalWindowController) {
        let set = workspaceTabSet(containing: controller)
        let selected: TerminalWindowController
        if set.usesSidebar {
            selected = set.selected ?? set.controllers.first ?? controller
        } else {
            selected = controller.window?.tabGroup?.selectedWindow?.windowController
                as? TerminalWindowController
                ?? set.selected
                ?? set.controllers.first
                ?? controller
            set.selected = selected
        }
        // Sidebar visibility is presentation for the complete tab set, but
        // companion insets and responsive layout belong to one tab. Hidden
        // sidebar windows (and inactive native tabs) therefore cannot vote on
        // the group-wide presentation with stale, inset-free geometry.
        guard controller === selected else { return }
        let nativeGroupReappeared = visible
            && (controller.window?.tabGroup?.windows.count ?? 0) > 1
        // AppKit may restore a standalone tab bar after the new window has
        // already entered sidebar mode. Enforce the invariant even when the
        // tab-set presentation itself does not need another transition.
        if visible, !set.isTransitioning, !nativeGroupReappeared {
            for member in set.controllers {
                if let window = member.window {
                    suppressNativeTabBar(for: window)
                }
            }
            if let window = controller.window,
               !set.controllers.contains(where: { $0 === controller }) {
                suppressNativeTabBar(for: window)
            }
        }
        guard !set.isTransitioning,
              set.usesSidebar != visible || nativeGroupReappeared else { return }
        set.isTransitioning = true
        defer { set.isTransitioning = false }

        if visible {
            let selected = selectedWorkspaceTab(containing: controller) ?? controller
            let frame = selected.window?.frame
            set.usesSidebar = true
            set.selected = selected

            if let group = selected.window?.tabGroup {
                for member in set.controllers {
                    if let window = member.window, group.windows.contains(window) {
                        group.removeWindow(window)
                    }
                }
            }
            for member in set.controllers {
                guard let window = member.window else { continue }
                suppressNativeTabBar(for: window)
                // Sidebar tabs swap overlapping NSWindows. AppKit's default
                // order-in/out animation scales both windows and makes the
                // entire workspace appear to bounce on every tab click.
                window.animationBehavior = .none
                if member === selected {
                    window.isExcludedFromWindowsMenu = false
                    if let frame { window.setFrame(frame, display: false) }
                    window.makeKeyAndOrderFront(nil)
                } else {
                    window.isExcludedFromWindowsMenu = true
                    window.orderOut(nil)
                }
            }
        } else {
            let ordered = set.controllers.filter { $0.window != nil }
            guard let base = ordered.first else { return }
            let selected = set.selected ?? base
            let frame = selected.window?.frame ?? base.window?.frame
            // Publish the destination state before asking AppKit to mutate the
            // group. contentLayoutRect observers fire during addTabbedWindow;
            // they must see a native-mode set, not restart this handoff.
            set.usesSidebar = false
            for member in ordered {
                member.window?.tabbingMode = .preferred
                member.window?.animationBehavior = .default
                member.window?.isExcludedFromWindowsMenu = false
            }
            if let frame { base.window?.setFrame(frame, display: false) }
            base.showWindow(nil)
            if let baseWindow = base.window {
                // `.above` inserts immediately after the base window. Add from
                // the far end so the durable sidebar order survives the switch.
                for member in ordered.dropFirst().reversed() {
                    if let window = member.window {
                        baseWindow.addTabbedWindow(window, ordered: .above)
                    }
                }
            }
            selected.window?.makeKeyAndOrderFront(nil)
        }

        NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged,
                                        object: controller)
        // Removing/adding native tabs delivers key-window callbacks inside the
        // transition. Refresh once those callbacks have settled so the visible
        // rail reads the final, presentation-neutral set.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cmdyWorkspaceFrameChanged, object: controller)
        }
    }

    /// Removing a window from a native tab group does not always clear
    /// AppKit's standalone `isTabBarVisible` state. Sidebar mode owns the tab
    /// switcher, so clear both sources of native tab chrome explicitly.
    private func suppressNativeTabBar(for window: NSWindow) {
        window.tabbingMode = .disallowed
        if window.tabGroup?.isTabBarVisible == true {
            window.toggleTabBar(nil)
        }
    }

    func activateWorkspaceTab(_ target: TerminalWindowController,
                              from source: TerminalWindowController) {
        let set = workspaceTabSet(containing: source)
        guard set.controllers.contains(where: { $0 === target }) else { return }
        if set.usesSidebar {
            let current = set.selected ?? source
            let frame = current.window?.frame ?? source.window?.frame
            let rails = current.workspaceRailGeometry()
            if current !== target {
                // Prepare the hidden tab completely before exposing it.
                // Showing first and resizing second makes the whole window
                // visibly jump; stale split positions also make both rails
                // snap to a different width.
                target.window?.tabbingMode = .disallowed
                target.window?.animationBehavior = .none
                target.window?.isExcludedFromWindowsMenu = false
                if let frame {
                    target.window?.setFrame(frame, display: false)
                }
                target.applyWorkspaceRailGeometry(rails)
                set.selected = target
                target.window?.makeKeyAndOrderFront(nil)

                // The replacement is already covering the exact same frame,
                // so hiding the previous tab leaves no desktop flash.
                current.window?.isExcludedFromWindowsMenu = true
                current.window?.orderOut(nil)
            } else {
                target.window?.makeKeyAndOrderFront(nil)
            }
        } else {
            target.window?.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged,
                                        object: target)
    }

    /// Place a torn-out sidebar tab so the pointer remains in its title band,
    /// then constrain the complete window to the destination screen. Keeping
    /// this geometry pure makes it directly regression-testable.
    static func sidebarTearOutFrame(
        from source: NSRect, drop: NSPoint, visibleFrame: NSRect?
    ) -> NSRect {
        var result = source
        result.origin.x = drop.x - min(source.width * 0.35, 220)
        result.origin.y = drop.y - source.height + 24
        guard let visibleFrame else { return result }

        if result.width >= visibleFrame.width {
            result.origin.x = visibleFrame.minX
        } else {
            result.origin.x = min(
                max(result.origin.x, visibleFrame.minX),
                visibleFrame.maxX - result.width)
        }
        if result.height >= visibleFrame.height {
            result.origin.y = visibleFrame.minY
        } else {
            result.origin.y = min(
                max(result.origin.y, visibleFrame.minY),
                visibleFrame.maxY - result.height)
        }
        return result
    }

    /// Tear one live sidebar tab out into a standalone window. Sidebar mode
    /// uses overlapping NSWindows, so membership is updated before any key or
    /// visibility callback can observe the move and accidentally recreate the
    /// old tab set.
    @discardableResult
    func tearOutWorkspaceTab(
        _ source: TerminalWindowController, at drop: NSPoint
    ) -> Bool {
        guard controllers.contains(where: { $0 === source }),
              let sourceWindow = source.window else { return false }
        let sourceSet = workspaceTabSet(containing: source)
        let visibleSource = sourceSet.selected ?? source
        let sharedFrame = visibleSource.window?.frame ?? sourceWindow.frame
        let sharedRails = visibleSource.workspaceRailGeometry()

        if sourceSet.controllers.count > 1,
           let index = sourceSet.controllers.firstIndex(where: { $0 === source }) {
            let wasSelected = sourceSet.selected === source
            sourceSet.isTransitioning = true
            sourceSet.controllers.remove(at: index)
            if wasSelected {
                sourceSet.selected = sourceSet.controllers[
                    min(index, sourceSet.controllers.count - 1)]
            }

            let detached = WorkspaceTabSet(
                controllers: [source], selected: source)
            detached.usesSidebar = sourceSet.usesSidebar
            detached.isTransitioning = true
            workspaceTabSets.append(detached)

            if wasSelected, let replacement = sourceSet.selected,
               sourceSet.usesSidebar {
                presentSidebarTabSet(
                    sourceSet, selected: replacement,
                    frame: sharedFrame, rails: sharedRails)
            }
            sourceSet.isTransitioning = false
            detached.isTransitioning = false
        } else {
            sourceSet.selected = source
        }

        suppressNativeTabBar(for: sourceWindow)
        sourceWindow.animationBehavior = .none
        sourceWindow.isExcludedFromWindowsMenu = false
        let screen = NSScreen.screens.first { $0.frame.contains(drop) }
            ?? sourceWindow.screen
        let destinationFrame = Self.sidebarTearOutFrame(
            from: sharedFrame, drop: drop,
            visibleFrame: screen?.visibleFrame)
        sourceWindow.setFrame(destinationFrame, display: false)
        source.applyWorkspaceRailGeometry(sharedRails)
        sourceWindow.makeKeyAndOrderFront(nil)

        NotificationCenter.default.post(
            name: .cmdyWorkspaceFrameChanged, object: source)
        if let remaining = sourceSet.selected, remaining !== source {
            NotificationCenter.default.post(
                name: .cmdyWorkspaceFrameChanged, object: remaining)
        }
        return true
    }

    /// Move a sidebar tab through the same five-zone area dropper used by
    /// native tabs and windows. An edge adopts its entire live pane tree as a
    /// split; the center moves it into the destination's tab set.
    @discardableResult
    func moveWorkspaceTab(
        _ source: TerminalWindowController,
        into destination: TerminalWindowController,
        side: TerminalWindowController.DockSide?
    ) -> Bool {
        guard source !== destination,
              controllers.contains(where: { $0 === source }),
              controllers.contains(where: { $0 === destination }),
              let sourceWindow = source.window else { return false }

        if let side {
            let sourcePaneIDs = Set(source.panes.map(\.paneId))
            guard !sourcePaneIDs.isEmpty else { return false }
            destination.merge(window: sourceWindow, side: side)
            let moved = sourcePaneIDs.isSubset(
                of: Set(destination.panes.map(\.paneId)))
            if moved {
                NotificationCenter.default.post(
                    name: .cmdyWorkspaceFrameChanged,
                    object: destination)
            }
            return moved
        }

        return moveWorkspaceTabAsTab(source, into: destination)
    }

    private func moveWorkspaceTabAsTab(
        _ source: TerminalWindowController,
        into destination: TerminalWindowController
    ) -> Bool {
        let sourceSet = workspaceTabSet(containing: source)
        let destinationSet = workspaceTabSet(containing: destination)
        if sourceSet === destinationSet {
            activateWorkspaceTab(source, from: destination)
            return true
        }
        guard let sourceIndex = sourceSet.controllers.firstIndex(where: {
            $0 === source
        }), let sourceWindow = source.window,
              let destinationWindow = destination.window else { return false }

        let sourceWasSelected = sourceSet.selected === source
        let sourceVisible = sourceSet.selected ?? source
        let sourceFrame = sourceVisible.window?.frame ?? sourceWindow.frame
        let sourceRails = sourceVisible.workspaceRailGeometry()
        let destinationVisible = destinationSet.selected ?? destination
        let destinationFrame = destinationVisible.window?.frame
            ?? destinationWindow.frame
        let destinationRails = destinationVisible.workspaceRailGeometry()

        sourceSet.isTransitioning = true
        destinationSet.isTransitioning = true
        defer {
            sourceSet.isTransitioning = false
            destinationSet.isTransitioning = false
        }

        sourceSet.controllers.remove(at: sourceIndex)
        if sourceWasSelected {
            sourceSet.selected = sourceSet.controllers.isEmpty ? nil
                : sourceSet.controllers[
                    min(sourceIndex, sourceSet.controllers.count - 1)]
        }
        let insertion = min(
            (destinationSet.controllers.firstIndex(where: {
                $0 === destination
            }) ?? destinationSet.controllers.count - 1) + 1,
            destinationSet.controllers.count)
        destinationSet.controllers.insert(source, at: insertion)
        destinationSet.selected = source

        if sourceWasSelected, let replacement = sourceSet.selected,
           sourceSet.usesSidebar {
            presentSidebarTabSet(
                sourceSet, selected: replacement,
                frame: sourceFrame, rails: sourceRails)
        }
        workspaceTabSets.removeAll { $0.controllers.isEmpty }

        if destinationSet.usesSidebar {
            presentSidebarTabSet(
                destinationSet, selected: source,
                frame: destinationFrame, rails: destinationRails)
        } else {
            sourceWindow.tabbingMode = .preferred
            sourceWindow.animationBehavior = .default
            sourceWindow.isExcludedFromWindowsMenu = false
            destinationWindow.addTabbedWindow(sourceWindow, ordered: .above)
            sourceWindow.makeKeyAndOrderFront(nil)
        }

        NotificationCenter.default.post(
            name: .cmdyWorkspaceFrameChanged, object: source)
        if let replacement = sourceSet.selected {
            NotificationCenter.default.post(
                name: .cmdyWorkspaceFrameChanged, object: replacement)
        }
        return true
    }

    private func presentSidebarTabSet(
        _ set: WorkspaceTabSet,
        selected: TerminalWindowController,
        frame: NSRect,
        rails: TerminalWindowController.WorkspaceRailGeometry
    ) {
        set.selected = selected
        for member in set.controllers {
            guard let window = member.window else { continue }
            suppressNativeTabBar(for: window)
            window.animationBehavior = .none
            if member === selected {
                window.isExcludedFromWindowsMenu = false
                window.setFrame(frame, display: false)
                member.applyWorkspaceRailGeometry(rails)
                window.makeKeyAndOrderFront(nil)
            } else {
                window.isExcludedFromWindowsMenu = true
                window.orderOut(nil)
            }
        }
    }

    /// `windowWillClose` runs only after AppKit and Cmdy have approved the
    /// close. Promote the next sidebar-backed NSWindow synchronously here, while
    /// the closing window still covers the screen, so no desktop frame leaks
    /// between the two tab surfaces.
    func prepareWorkspaceTabReplacement(
        beforeClosing closing: TerminalWindowController
    ) {
        let set = workspaceTabSet(containing: closing)
        guard !isTerminating,
              sidebarCloseHandoffSuppressionDepth == 0,
              set.usesSidebar, set.selected === closing,
              set.controllers.count > 1,
              let closingIndex = set.controllers.firstIndex(where: {
                  $0 === closing
              })
        else { return }
        let replacementIndex = closingIndex + 1 < set.controllers.count
            ? closingIndex + 1 : closingIndex - 1
        let replacement = set.controllers[replacementIndex]
        let shouldRestoreKeyboardFocus = NSApp.isActive
        activateWorkspaceTab(replacement, from: closing)
        // AppKit sometimes clears the key-window assignment after returning
        // from `windowWillClose`, even though the replacement was made key
        // inside that callback. Reassert only keyboard focus on the next turn;
        // the window is already visible, so this cannot reintroduce the flash.
        if shouldRestoreKeyboardFocus {
            DispatchQueue.main.async { [weak replacement] in
                guard NSApp.isActive,
                      replacement?.window?.isVisible == true else { return }
                replacement?.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Sidebar tabs are temporarily separate hidden NSWindows. Keep their
    /// geometry and terminal grids in lockstep with the visible tab so every
    /// miniature reflects the size the user is actively shaping.
    func synchronizeWorkspaceTabFrames(from controller: TerminalWindowController) {
        let set = workspaceTabSet(containing: controller)
        guard set.usesSidebar, set.selected === controller,
              let frame = controller.window?.frame else { return }
        let rails = controller.workspaceRailGeometry()
        for member in set.controllers where member !== controller {
            guard let window = member.window else { continue }
            if window.frame != frame {
                window.setFrame(frame, display: false)
            }
            member.applyWorkspaceRailGeometry(rails)
        }
    }

    @discardableResult
    func selectWorkspaceTab(from controller: TerminalWindowController,
                            offset: Int) -> Bool {
        let set = workspaceTabSet(containing: controller)
        guard set.controllers.count > 1 else { return false }
        let selected = selectedWorkspaceTab(containing: controller) ?? controller
        guard let index = set.controllers.firstIndex(where: { $0 === selected }) else {
            return false
        }
        let next = (index + offset % set.controllers.count + set.controllers.count)
            % set.controllers.count
        activateWorkspaceTab(set.controllers[next], from: controller)
        return true
    }

    @discardableResult
    func selectWorkspaceTab(from controller: TerminalWindowController,
                            index: Int) -> Bool {
        let set = workspaceTabSet(containing: controller)
        guard set.controllers.indices.contains(index) else { return false }
        activateWorkspaceTab(set.controllers[index], from: controller)
        return true
    }

    func closeWorkspaceTabGroup(containing controller: TerminalWindowController) {
        let tabs = workspaceTabSet(containing: controller).controllers
        sidebarCloseHandoffSuppressionDepth += 1
        defer { sidebarCloseHandoffSuppressionDepth -= 1 }
        if tabs.isEmpty {
            controller.window?.performClose(nil)
        } else {
            tabs.forEach { $0.window?.performClose(nil) }
        }
    }

    func closeAllTerminalWindows() {
        sidebarCloseHandoffSuppressionDepth += 1
        defer { sidebarCloseHandoffSuppressionDepth -= 1 }
        controllers.forEach { $0.window?.performClose(nil) }
    }

    func remove(_ c: TerminalWindowController) {
        let affected = workspaceTabSets.first {
            $0.controllers.contains { $0 === c }
        }
        let removedIndex = affected?.controllers.firstIndex { $0 === c } ?? 0
        let wasSelected = affected?.selected === c
        let frame = c.window?.frame
        affected?.controllers.removeAll { $0 === c }
        if wasSelected, let affected {
            if affected.controllers.isEmpty {
                affected.selected = nil
            } else {
                affected.selected = affected.controllers[
                    min(removedIndex, affected.controllers.count - 1)]
            }
        }
        workspaceTabSets.removeAll { $0.controllers.isEmpty }
        controllers.removeAll { $0 === c }
        NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged, object: c)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if wasSelected, affected?.usesSidebar == true,
               let replacement = affected?.selected {
                if let frame { replacement.window?.setFrame(frame, display: false) }
                self.activateWorkspaceTab(replacement, from: replacement)
            }
            self.controllers.forEach { $0.syncTabPresentation() }
        }
        windowGridCoordinator.windowLifecycleDidChange()
        if !isTerminating {
            PluginManager.shared.scheduleProjectExtensionReconcile()
        }
    }

    /// Ghostty-compatible short-lived undo for a closed tab/window. Restoring
    /// starts fresh shells with the captured cwd, split tree, and scrollback;
    /// no terminated process is kept alive invisibly.
    func rememberClosedLayout(_ controller: TerminalWindowController) {
        guard !isTerminating else { return }
        let id = ObjectIdentifier(controller)
        if suppressClosedCapture.remove(id) != nil { return }
        let layout = controller.serializeLayout()
        guard !layout.isEmpty else { return }
        let now = Date()
        closedLayouts.removeAll { now.timeIntervalSince($0.closedAt) > 30 }
        closedLayouts.append(ClosedLayout(layout: layout, closedAt: now))
        if closedLayouts.count > 16 { closedLayouts.removeFirst(closedLayouts.count - 16) }
    }

    @discardableResult
    func undoClose() -> Bool {
        let now = Date()
        closedLayouts.removeAll { now.timeIntervalSince($0.closedAt) > 30 }
        guard let entry = closedLayouts.popLast() else { return false }
        let controller = TerminalWindowController(session: entry.layout)
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        reopenedController = controller
        windowGridCoordinator.scheduleReconcile(animated: true)
        return true
    }

    @discardableResult
    func redoClose() -> Bool {
        guard let controller = reopenedController, controller.window?.isVisible == true else { return false }
        let layout = controller.serializeLayout()
        suppressClosedCapture.insert(ObjectIdentifier(controller))
        closedLayouts.append(ClosedLayout(layout: layout, closedAt: Date()))
        controller.window?.performClose(nil)
        reopenedController = nil
        return true
    }

    var allControllers: [TerminalWindowController] { controllers }

    /// Register a controller created outside the App-Delegate paths (pane breakout).
    func adopt(
        controller: TerminalWindowController,
        reconcileWindowGrid: Bool = true
    ) {
        controllers.append(controller)
        if reconcileWindowGrid {
            windowGridCoordinator.scheduleReconcile(animated: true)
        }
    }

    func windowGridIdentifier(
        for controller: TerminalWindowController
    ) -> String? {
        guard controllers.contains(where: { $0 === controller }) else {
            return nil
        }
        return workspaceTabSet(containing: controller).identifier
    }

    /// One visible native window represents one workspace/tab set in the grid.
    /// Hidden sidebar tabs and inactive AppKit tabs keep their live processes,
    /// but do not consume another rectangle.
    func windowGridParticipants() -> [WindowGridParticipant] {
        reconcileWorkspaceTabSetsForGridSnapshot()
        var result: [WindowGridParticipant] = []
        for set in workspaceTabSets {
            let selectedNative = set.controllers.first { candidate in
                guard let window = candidate.window,
                      let group = window.tabGroup else { return false }
                return group.selectedWindow === window
            }
            guard let visibleController = selectedNative
                    ?? set.selected
                    ?? set.controllers.first,
                  let window = visibleController.window,
                  window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  window.isOnActiveSpace,
                  let screen = window.screen ?? NSScreen.main
            else { continue }
            result.append(WindowGridParticipant(
                id: set.identifier,
                controller: visibleController,
                window: window,
                screen: screen,
                minimumSize: CGSize(
                    width: max(
                        WindowGridLayout.defaultMinimumSize.width,
                        window.minSize.width),
                    height: max(
                        WindowGridLayout.defaultMinimumSize.height,
                        window.minSize.height))))
        }
        return result
    }

    /// Grid reconciliation is a read-heavy hot path. Most grid windows are
    /// singleton workspaces, so resolving every controller through the full
    /// mutable native-tab reconciliation made each snapshot quadratic. Prune
    /// and fill singleton membership with identity sets, and invoke the more
    /// expensive AppKit bridge only for actual multi-window native tab groups.
    private func reconcileWorkspaceTabSetsForGridSnapshot() {
        let live = Set(controllers.map(ObjectIdentifier.init))
        for set in workspaceTabSets {
            set.controllers.removeAll {
                !live.contains(ObjectIdentifier($0))
            }
            if let selected = set.selected,
               !live.contains(ObjectIdentifier(selected)) {
                set.selected = set.controllers.first
            }
        }
        workspaceTabSets.removeAll { $0.controllers.isEmpty }

        for controller in controllers
            where (controller.window?.tabGroup?.windows.count ?? 0) > 1 {
            _ = workspaceTabSet(containing: controller)
        }

        var represented = Set<ObjectIdentifier>()
        for set in workspaceTabSets {
            represented.formUnion(set.controllers.map(ObjectIdentifier.init))
        }
        for controller in controllers
            where represented.insert(ObjectIdentifier(controller)).inserted {
            workspaceTabSets.append(WorkspaceTabSet(
                controllers: [controller], selected: controller))
        }
    }

    // MARK: - Window merging / floating

    /// Pull every window's panes into the key window as splits.
    @objc func mergeIntoSplits(_ sender: Any?) { currentController?.mergeAllWindowsIntoSplits() }

    @objc func breakSplitsIntoGridWindows(_ sender: Any?) {
        guard currentController?.breakAllSplitsIntoGridWindows() == true else {
            NSSound.beep()
            return
        }
        refreshMenuStates()
    }

    @objc func combineGridWindowsIntoSplits(_ sender: Any?) {
        guard let host = currentController,
              let screen = host.window?.screen ?? NSScreen.main,
              let tree = windowGridCoordinator.treeForConversion(on: screen)
        else {
            NSSound.beep()
            return
        }
        let screenID = WindowGridCoordinator.identifier(for: screen)
        let leafIDs = Set(WindowGridLayout.leafIDs(in: tree))
        let participants = windowGridParticipants().filter {
            leafIDs.contains($0.id)
                && WindowGridCoordinator.identifier(for: $0.screen) == screenID
        }
        // A workspace containing hidden/native tabs is not one rectangle per
        // controller. Leave it intact rather than silently discarding tabs.
        guard Set(participants.map(\.id)) == leafIDs,
              participants.allSatisfy({
                  workspaceTabSet(containing: $0.controller).controllers.count == 1
              }),
              host.combineGridWindowsIntoSplits(
                tree: tree, participants: participants)
        else {
            NSSound.beep()
            return
        }
        refreshMenuStates()
    }

    /// Keep the key window above everything (toggle).
    @objc func toggleFloat(_ sender: Any?) {
        guard let w = NSApp.keyWindow else { return }
        w.level = w.level == .floating ? .normal : .floating
    }

    /// Menu route for directional merging: representedObject carries
    /// [source window number, side raw value ("tab" = tab).]
    @objc func mergeDirectional(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let number = info["window"] as? Int,
              let source = NSApp.window(withWindowNumber: number),
              let dst = currentController else { return }
        let side = (info["side"] as? String).flatMap {
            TerminalWindowController.DockSide(rawValue: $0)
        }
        dst.merge(window: source, side: side)
    }

    // MARK: - Windows & tabs

    static func cascadedWindowFrame(from source: NSRect, visibleFrame: NSRect?) -> NSRect {
        let step: CGFloat = 24
        var next = source.offsetBy(dx: step, dy: -step)
        guard let visibleFrame else { return next }

        // Keep the exact source size. After enough repeated Cmd+N presses,
        // restart the staircase near the screen's top-left instead of letting
        // most of the next window disappear beyond an edge.
        let visiblePart = next.intersection(visibleFrame)
        let enoughWidth = visiblePart.width >= min(next.width * 0.7, visibleFrame.width)
        let enoughHeight = visiblePart.height >= min(next.height * 0.7, visibleFrame.height)
        if visiblePart.isNull || !enoughWidth || !enoughHeight {
            next.origin = NSPoint(x: visibleFrame.minX + step,
                                  y: visibleFrame.maxY - next.height - step)
        }
        return next
    }

    @objc func newWindow(_ sender: Any?) {
        let source = currentController
        let sourceWindow = source?.window
        let c = TerminalWindowController(
            cwd: source?.workingDirectory,
            appearance: source?.tabAppearanceSnapshot,
            deferWorkspaceTabPresentation: true)
        controllers.append(c)
        let gridFrame = Preferences.shared.windowGridEnabled
            ? windowGridCoordinator.prepareNewWindow(c, source: source)
            : nil
        let desiredFrame: NSRect?
        if let gridFrame, let target = c.window {
            desiredFrame = gridFrame
            target.setFrame(gridFrame, display: false)
        } else if let sourceWindow, let target = c.window {
            let frame = Self.cascadedWindowFrame(
                from: sourceWindow.frame,
                visibleFrame: sourceWindow.screen?.visibleFrame)
            desiredFrame = frame
            target.setFrame(frame, display: false)
        } else {
            desiredFrame = nil
            c.window?.center()
        }
        c.finishDeferredWorkspaceTabPresentation()
        c.showWindow(nil)
        // showWindow can still apply AppKit's initial placement to an unseen
        // window. Reassert Cmdy's geometry before the next display pass.
        if let desiredFrame {
            c.window?.setFrame(desiredFrame, display: false)
        } else {
            c.window?.center()
        }
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Coalesce key-repeat Cmd-N bursts before starting any NSWindow frame
        // animation. Every new window is already presented in its own current
        // target rectangle; after the burst, surrounding windows perform one
        // native movement to the final topology.
        windowGridCoordinator.scheduleReconcile(animated: true, after: 0.08)
    }

    @objc func newTab(_ sender: Any?) {
        newTab(attachedTo: NSApp.keyWindow)
    }

    /// Open a new tab in a specific window group (the tab bar's "+" targets
    /// the window whose bar was clicked, which may not be the key window).
    func newTab(attachedTo target: NSWindow?) {
        let host = controllers.first { $0.window === target } ?? currentController
        let tabSet = host.map { workspaceTabSet(containing: $0) }
        let c = TerminalWindowController(
            cwd: host?.workingDirectory,
            appearance: host?.tabAppearanceSnapshot,
            deferWorkspaceTabPresentation: true)
        controllers.append(c)
        if let tabSet, tabSet.usesSidebar, let host {
            let previous = tabSet.selected ?? host
            let frame = previous.window?.frame
            let rails = previous.workspaceRailGeometry()
            tabSet.controllers.append(c)
            if let window = c.window {
                suppressNativeTabBar(for: window)
            }
            c.window?.animationBehavior = .none
            c.window?.isExcludedFromWindowsMenu = false
            if let frame { c.window?.setFrame(frame, display: false) }
            c.applyWorkspaceRailGeometry(rails)
            tabSet.selected = c
            c.finishDeferredWorkspaceTabPresentation()
            c.window?.makeKeyAndOrderFront(nil)
            previous.window?.isExcludedFromWindowsMenu = true
            previous.window?.orderOut(nil)
            DispatchQueue.main.async { [weak self, weak c] in
                guard let window = c?.window else { return }
                self?.suppressNativeTabBar(for: window)
            }
            NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged,
                                            object: c)
        } else if let hostWindow = target ?? NSApp.keyWindow, let w = c.window {
            hostWindow.addTabbedWindow(w, ordered: .above)
            w.makeKeyAndOrderFront(nil)
            if let host {
                _ = workspaceTabSet(containing: host)
            }
            c.finishDeferredWorkspaceTabPresentation()
            DispatchQueue.main.async { c.scheduleTabPresentationSync() }
        } else {
            c.finishDeferredWorkspaceTabPresentation()
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
        }
        windowGridCoordinator.scheduleReconcile(animated: true)
    }

    // MARK: - Font

    @objc func increaseFontSize(_ sender: Any?) {
        Preferences.shared.fontSize = min(48, Preferences.shared.fontSize + 1)
    }
    @objc func decreaseFontSize(_ sender: Any?) {
        Preferences.shared.fontSize = max(8, Preferences.shared.fontSize - 1)
    }
    @objc func resetFontSize(_ sender: Any?) {
        Preferences.shared.fontSize = Preferences.defaultFontSize
    }

    // MARK: - Appearance / behavior toggles

    @objc func setThemeMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if let controller = currentController {
            controller.setTabTheme(name)
        } else {
            Preferences.shared.themeName = name
        }
        refreshMenuStates()
    }
    @objc func setCursorMenu(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { Preferences.shared.cursorStyleName = name }
    }
    @objc func toggleSmoothCursor(_ sender: Any?) { Preferences.shared.smoothCursor.toggle() }
    @objc func setCursorGlideSpeed(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            Preferences.shared.cursorGlideSpeed = CGFloat(value)
        }
    }
    @objc func setScrollSpeed(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            Preferences.shared.scrollSpeed = CGFloat(value)
        }
    }
    @objc func setCursorGlideDistance(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            Preferences.shared.cursorGlideMaxDistance = CGFloat(value)
        }
    }
    @objc func setFontMenu(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { Preferences.shared.fontName = name }
    }
    @objc func setLineHeightMenu(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { Preferences.shared.lineHeight = CGFloat(v) }
    }
    @objc func setWindowInsetMenu(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { Preferences.shared.contentMargin = CGFloat(v) }
    }
    @objc func setOpacityMenu(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { Preferences.shared.opacity = v }
    }
    @objc func setShaderMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if let controller = currentController {
            controller.setTabShader(name)
        } else {
            Preferences.shared.shaderName = name
        }
        refreshMenuStates()
    }
    @objc func toggleOptionAsMeta(_ sender: Any?) { Preferences.shared.optionAsMeta.toggle() }
    @objc func toggleShellIntegration(_ sender: Any?) { Preferences.shared.shellIntegration.toggle() }
    @objc func toggleAutomaticErrorHelp(_ sender: Any?) { Preferences.shared.automaticErrorHelp.toggle() }
    @objc func toggleCleanPrompt(_ sender: Any?) { Preferences.shared.cleanPrompt.toggle() }
    @objc func toggleHideTrafficLights(_ sender: Any?) { Preferences.shared.hideTrafficLights.toggle() }
    @objc func toggleWindowGrid(_ sender: Any?) {
        Preferences.shared.windowGridEnabled.toggle()
    }
    @objc func toggleBlur(_ sender: Any?) { Preferences.shared.blur.toggle() }

    @objc func toggleWorkspaceNavigator(_ sender: Any?) {
        currentController?.toggleNavigator()
    }
    @objc func toggleWorkspaceInspector(_ sender: Any?) {
        currentController?.showInspector()
    }
    @objc func toggleEmbeddedBrowser(_ sender: Any?) {
        currentController?.toggleEmbeddedBrowser(focusLocation: true)
        refreshMenuStates()
    }
    @objc func toggleWorkspaceFocusMode(_ sender: Any?) {
        currentController?.toggleFocusMode()
    }
    @objc func customizeToolbar(_ sender: Any?) {
        currentController?.customizeNativeToolbar(sender)
    }

    @objc func clearBuffer(_ sender: Any?) { currentController?.clearBuffer() }

    // MARK: - Text editor

    @objc func showEditor(_ sender: Any?) {
        let terminal = currentController
        CmdyEditorManager.shared.showEditor(
            in: NSApp.keyWindow ?? terminal?.window,
            attachingTo: terminal)
    }

    @objc func newTextDocument(_ sender: Any?) {
        CmdyEditorManager.shared.newDocument()
    }

    @objc func openDocument(_ sender: Any?) { chooseDocuments(attach: false) }
    @objc func openDocumentInSplit(_ sender: Any?) { chooseDocuments(attach: true) }

    private func chooseDocuments(attach: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                CmdyEditorManager.shared.open(url, attach: attach, respectPreference: true)
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let editor = CmdyEditorManager.shared.focusedEditor else { NSSound.beep(); return }
        editor.save { _ in }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let editor = CmdyEditorManager.shared.focusedEditor else { NSSound.beep(); return }
        editor.saveAs()
    }

    @objc func toggleEditorAttachment(_ sender: Any?) {
        guard let editor = CmdyEditorManager.shared.focusedEditor else { NSSound.beep(); return }
        if editor.isAttached { CmdyEditorManager.shared.detachEditor(editor) }
        else { CmdyEditorManager.shared.attachEditor(editor) }
    }

    // MARK: - Panes / find

    @objc func splitRight(_ sender: Any?) { currentController?.splitFocusedPane(vertical: true) }
    @objc func splitDown(_ sender: Any?) { currentController?.splitFocusedPane(vertical: false) }
    @objc func focusNextPane(_ sender: Any?) { currentController?.focusNextPane(offset: 1) }
    @objc func focusPreviousPane(_ sender: Any?) { currentController?.focusNextPane(offset: -1) }
    @objc func beamSelection(_ sender: Any?) { BeamManager.shared.beamSelection() }
    @objc func beamScreenshot(_ sender: Any?) { BeamManager.shared.beamScreenshot() }
    @objc func breakPaneOut(_ sender: Any?) { currentController?.breakOutFocusedPane(asTab: false) }
    @objc func breakPaneTab(_ sender: Any?) { currentController?.breakOutFocusedPane(asTab: true) }
    @objc func closePaneOrWindow(_ sender: Any?) {
        if let editor = CmdyEditorManager.shared.focusedEditor {
            CmdyEditorManager.shared.requestClose(editor)
        } else if let c = currentController { c.closePaneOrWindow() }
        else { NSApp.keyWindow?.performClose(sender) }
    }
    @objc func showFind(_ sender: Any?) {
        if let editor = CmdyEditorManager.shared.focusedEditor { editor.showFind() }
        else { currentController?.showFindBar() }
    }
    @objc func findNext(_ sender: Any?) {
        if let editor = CmdyEditorManager.shared.focusedEditor {
            editor.performFindAction(.nextMatch)
        } else { _ = currentController?.stepFind(forward: true) }
    }
    @objc func findPrevious(_ sender: Any?) {
        if let editor = CmdyEditorManager.shared.focusedEditor {
            editor.performFindAction(.previousMatch)
        } else { _ = currentController?.stepFind(forward: false) }
    }

    // MARK: - AI

    @objc func composeAI(_ sender: Any?) { currentController?.composeWithAI() }
    @objc func fixLastAI(_ sender: Any?) { currentController?.fixLastCommand() }
    @objc func startAgent(_ sender: Any?) { currentController?.startAgent() }
    @objc func showIntegrationDoctor(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let pane = self?.currentController?.focusedPane else {
                NSSound.beep()
                return
            }
            IntegrationDoctor.present(in: pane, cwd: pane.currentCwd)
        }
    }

    // MARK: - Command palette

    private func tabAppearancePreviewHooks(
        for controller: TerminalWindowController
    ) -> InlinePanelPreviewHooks {
        var baseline = controller.tabAppearanceSnapshot
        return InlinePanelPreviewHooks(
            begin: { [weak controller] in
                if let controller { baseline = controller.tabAppearanceSnapshot }
            },
            restore: { [weak controller] in
                controller?.restoreTabAppearance(baseline)
            },
            commit: { [weak controller] in
                if let controller { baseline = controller.tabAppearanceSnapshot }
            })
    }

    @objc func showPalette(_ sender: Any?) {
        // In-terminal UI: the palette docks at the bottom of the focused pane,
        // drawn in the terminal's font/theme — not a floating window.
        guard let controller = currentController,
              let pane = controller.focusedPane else { NSSound.beep(); return }
        let itemsProvider = { [weak self] in self?.paletteItems() ?? [] }
        pane.presentInlinePanel().configureList(
            items: itemsProvider(),
            placeholder: "type a command, theme, font, or recent shell command…",
            hint: "↑↓ select · → open · settings preview live · ⏎ keep + stay · esc back",
            memoryKey: "command-palette",
            itemsProvider: itemsProvider,
            previewHooks: tabAppearancePreviewHooks(for: controller))
    }

    @objc func showPlugins(_ sender: Any?) {
        Task { @MainActor in PluginsWindow.shared.show() }
    }

    @objc func showChannelManager(_ sender: Any?) {
        Task { @MainActor [weak self] in
            ChannelManagerWindow.shared.configureHandler = { [weak self] entry, directory in
                self?.presentChannelConfiguration(entry, directory: directory)
            }
            ChannelManagerWindow.shared.show()
        }
    }
    @objc func runPluginCommand(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    /// Everything the palette can do: actions, themes, fonts, cursor styles,
    /// toggles, and the focused pane's recent commands.
    // MARK: - Palette tree (sections; shared with the Config Mixer)

    private func item(_ title: String, _ subtitle: String = "", previews: Bool = false,
                      _ action: @escaping () -> Void) -> PaletteItem {
        PaletteItem(title: title, subtitle: subtitle, action: action,
                    preview: previews ? action : nil)
    }

    private func booleanPaletteItems(current: Bool,
                                     set: @escaping (Bool) -> Void) -> [PaletteItem] {
        [
            item("On", current ? "current" : "", previews: true) { set(true) },
            item("Off", !current ? "current" : "", previews: true) { set(false) },
        ]
    }

    func themePaletteItems() -> [PaletteItem] {
        let p = Preferences.shared
        let controller = currentController
        let selected = controller?.selectedThemeName ?? p.themeName
        return Theme.names.map { name in
            item(name, selected == name ? "current" : "theme", previews: true) {
                [weak controller] in
                if let controller {
                    controller.setTabTheme(name)
                } else {
                    Preferences.shared.themeName = name
                }
            }
        }
    }

    func fontPaletteItems() -> [PaletteItem] {
        let p = Preferences.shared
        var out = [item("System Mono", p.fontName == "System" ? "current" : "font", previews: true) {
            Preferences.shared.fontName = "System"
        }]
        for bf in bundledFonts {
            out.append(item(bf.displayName, p.fontName == bf.fontName ? "current" : "font", previews: true) {
                Preferences.shared.fontName = bf.fontName
            })
        }
        return out
    }

    func shaderPaletteItems() -> [PaletteItem] {
        let p = Preferences.shared
        let controller = currentController
        let selected = controller?.selectedShaderName ?? p.shaderName
        var out = Preferences.shaderNames.map { name in
            item(name, selected == name ? "current" : "shader", previews: true) {
                [weak controller] in
                if let controller {
                    controller.setTabShader(name)
                } else {
                    Preferences.shared.shaderName = name
                }
            }
        }
        for name in UserShaders.names {
            out.append(item(String(name.dropFirst("user/".count)),
                            selected == name ? "current" : "user shader", previews: true) {
                [weak controller] in
                if let controller {
                    controller.setTabShader(name)
                } else {
                    Preferences.shared.shaderName = name
                }
            })
        }
        out.append(item("New User Shader…", "scaffold + live reload") {
            UserShaders.createAndEdit()
        })
        return out
    }

    func cursorPaletteItems() -> [PaletteItem] {
        let p = Preferences.shared
        let styles: [(String, String)] = [
            ("Block (blink)", "blinkBlock"), ("Block", "steadyBlock"),
            ("Bar (blink)", "blinkBar"), ("Bar", "steadyBar"),
            ("Underline (blink)", "blinkUnderline"), ("Underline", "steadyUnderline"),
        ]
        return styles.map { label, value in
            item(label, p.cursorStyleName == value ? "current" : "cursor", previews: true) {
                Preferences.shared.cursorStyleName = value
            }
        }
    }

    func lineSpacingPaletteItems() -> [PaletteItem] {
        let p = Preferences.shared
        return Self.lineSpacingOptions.map { label, v in
            item(label, abs(Double(p.lineHeight) - v) < 0.001 ? "current" : "spacing", previews: true) {
                Preferences.shared.lineHeight = CGFloat(v)
            }
        }
    }

    func textRenderingPaletteItems() -> [PaletteItem] {
        let p = Preferences.shared
        let options: [(String, String, String)] = [
            ("Current Baseline", "current", "linear · X snap · 1.35 contrast"),
            ("Y Pixel Snap", "y-snap", "baseline + vertical pixel snap"),
            ("Atlas Padding", "atlas-padding", "baseline + 1px glyph gutter"),
            ("Nearest Sampling", "nearest", "baseline + nearest texture filter"),
            ("Higher Contrast", "high-contrast", "baseline + 1.55 edge curve"),
            ("Crisp Combined", "crisp", "Y snap + gutter + 1.55 contrast"),
        ]
        return options.map { label, value, detail in
            item(label, p.textRenderingMode == value ? "current" : detail, previews: true) {
                Preferences.shared.textRenderingMode = value
            }
        }
    }

    func windowInsetPaletteItems() -> [PaletteItem] {
        let p = Preferences.shared
        let options: [(String, CGFloat)] = [("Small", 6), ("Medium", 10), ("Large", 18)]
        return options.map { label, v in
            let density = v <= 10 ? "compact" : "unified"
            let detail = abs(p.contentMargin - v) < 0.5
                ? "current · \(density)" : "\(Int(v))pt · \(density)"
            return item(label, detail, previews: true) {
                Preferences.shared.contentMargin = v
            }
        }
    }

    private func paletteItems() -> [PaletteItem] {
        let p = Preferences.shared
        var root: [PaletteItem] = []

        // Recent commands stay flat at the root — the fastest reach.
        if let c = currentController {
            for cmd in c.recentCommands(limit: 5) where !cmd.command.isEmpty {
                root.append(item("Run: \(cmd.command)", "re-run") { [weak self] in
                    self?.currentController?.runCommand(cmd.command)
                })
            }
        }

        root.append(.section("AI", "agent · compose · explain · fix", [
            item("Agent Mode…", "⇧⌘A") { [weak self] in self?.startAgent(nil) },
            item("Integration Doctor…", "Browser · Sim · Bridge · MCP") { [weak self] in
                self?.showIntegrationDoctor(nil)
            },
            item("Compose Command…", "⇧⌘K") { [weak self] in self?.composeAI(nil) },
            item("Explain Last Command", "⇧⌘E") { [weak self] in self?.explainLast(nil) },
            item("Fix Last Failed Command", "⇧⌘X") { [weak self] in self?.fixLastAI(nil) },
        ]))

        root.append(.section("Windows & Panes", "new · split · merge · beam", [
            item("New Window", "⌘N") { [weak self] in self?.newWindow(nil) },
            item("New Tab", "⌘T") { [weak self] in self?.newTab(nil) },
            item("Split Right", "⌘D") { [weak self] in self?.splitRight(nil) },
            item("Split Down", "⇧⌘D") { [weak self] in self?.splitDown(nil) },
            item("Focus Next Pane", "⌘]") { [weak self] in self?.focusNextPane(nil) },
            item("Break Pane into Window", "⇧⌘B") { [weak self] in self?.breakPaneOut(nil) },
            item("Break Pane into Tab", "⌥⌘B") { [weak self] in self?.breakPaneTab(nil) },
            item("Break Splits into Grid Windows") {
                [weak self] in self?.breakSplitsIntoGridWindows(nil)
            },
            item("Combine Grid Windows into Splits") {
                [weak self] in self?.combineGridWindowsIntoSplits(nil)
            },
            item("Merge All Windows into Tabs") { NSApp.keyWindow?.mergeAllWindows(nil) },
            item("Merge All Windows into Splits") { [weak self] in self?.mergeIntoSplits(nil) },
            item("Window Grid", p.windowGridEnabled ? "on" : "off") {
                [weak self] in self?.toggleWindowGrid(nil)
            },
            item("Float Window on Top", "⌥⌘F") { [weak self] in self?.toggleFloat(nil) },
            item("Beam Selected Text to Pane…", "⌃⌘B") { [weak self] in self?.beamSelection(nil) },
            item("Beam Screenshot to Pane…", "⌃⌘S") { [weak self] in self?.beamScreenshot(nil) },
        ]))

        root.append(MainActor.assumeIsolated { namedWorkspacePaletteSection() })
        root.append(keybindingImportPaletteSection())

        root.append(.section("Appearance", "mixer · themes · fonts · shaders", [
            item("Config Mixer…", "blend theme/font/shader/cursor live") { [weak self] in self?.showConfigMixer(nil) },
            .section(
                "Themes", currentController?.selectedThemeName ?? p.themeName,
                themePaletteItems()),
            .section("Fonts", fontDisplayName(p.fontName), fontPaletteItems()),
            .section(
                "Shaders", currentController?.selectedShaderName ?? p.shaderName,
                shaderPaletteItems()),
            .section("Cursors", Self.cursorLabel(p.cursorStyleName), cursorPaletteItems()),
            .section("Cursor Glide Speed", String(format: "%.2gx", p.cursorGlideSpeed), [
                item("Slow", "0.45x", previews: true) { p.cursorGlideSpeed = 0.45 },
                item("Relaxed", "0.7x", previews: true) { p.cursorGlideSpeed = 0.7 },
                item("Balanced", "1x", previews: true) { p.cursorGlideSpeed = 1 },
                item("Fast", "1.6x", previews: true) { p.cursorGlideSpeed = 1.6 },
                item("Very Fast", "2.5x", previews: true) { p.cursorGlideSpeed = 2.5 },
            ]),
            .section("Cursor Glide Distance",
                     p.cursorGlideMaxDistance == 0 ? "unlimited" : "\(Int(p.cursorGlideMaxDistance)) cells", [
                item("Unlimited", previews: true) { p.cursorGlideMaxDistance = 0 },
                item("Up to 8 cells", previews: true) { p.cursorGlideMaxDistance = 8 },
                item("Up to 4 cells", previews: true) { p.cursorGlideMaxDistance = 4 },
                item("Up to 2 cells", previews: true) { p.cursorGlideMaxDistance = 2 },
            ]),
            .section("Line Spacing", Self.lineSpacingLabel(p.lineHeight), lineSpacingPaletteItems()),
            .section("Text Rendering Lab", Self.textRenderingLabel(p.textRenderingMode),
                     textRenderingPaletteItems()),
            item("Increase Font Size", "⌘+") { [weak self] in self?.increaseFontSize(nil) },
            item("Decrease Font Size", "⌘−") { [weak self] in self?.decreaseFontSize(nil) },
            .section("Window Buttons", p.hideTrafficLights ? "off" : "on",
                     booleanPaletteItems(current: !p.hideTrafficLights) { p.hideTrafficLights = !$0 }),
            .section("Window Inset", "\(Int(p.contentMargin))pt", windowInsetPaletteItems()),
        ]))

        root.append(.section("Terminal", "find · clear · blocks", [
            item("Find…", "⌘F") { [weak self] in self?.showFind(nil) },
            item("Clear Buffer", "⌘K") { [weak self] in self?.clearBuffer(nil) },
            item("Copy Last Command Output", "⇧⌘C") { [weak self] in self?.copyLastOutput(nil) },
        ]))

        var actionItems = availableCmdyActions().map { action in
            let shortcut = action.shortcut.map { " · \($0.display)" } ?? ""
            let purpose = action.guide.whatItDoes.first ?? action.group
            return item(action.title, "\(action.group)\(shortcut) · \(purpose)") { [weak self] in
                do { try self?.runCmdyAction(action) }
                catch { self?.showCmdyActionError(error) }
            }
        }
        actionItems.append(item("Install Starter Actions…", "five editable workflows") { [weak self] in
            self?.installStarterActions(nil)
        })
        actionItems.append(item("Save Last Command as Action…", "authoring") { [weak self] in
            self?.saveLastCommandAsAction(nil)
        })
        actionItems.append(item("Create Sample Action", "scaffold") { [weak self] in
            self?.createSampleAction(nil)
        })
        actionItems.append(item(
            "Open Actions Folder",
            "~/.config/\(ProductIdentity.current.configurationDirectoryName)/actions"
        ) { [weak self] in
            self?.openActionsFolder(nil)
        })
        root.append(.section("Actions", "scripts · commands · workflows", actionItems))

        root.append(channelPaletteSection())

        root.append(.section("Settings", "config file · toggles", [
            item("Open Config File", "⌘,") { [weak self] in self?.openConfig(nil) },
            item("Reload Config", "⇧⌘,") { [weak self] in self?.reloadConfig(nil) },
            .section("Smooth Cursor", p.smoothCursor ? "on" : "off",
                     booleanPaletteItems(current: p.smoothCursor) { p.smoothCursor = $0 }),
            .section("Smooth Scroll", p.smoothScroll ? "on" : "off",
                     booleanPaletteItems(current: p.smoothScroll) { p.smoothScroll = $0 }),
            .section("Scroll Speed", Self.scrollSpeedLabel(p.scrollSpeed),
                     Self.scrollSpeedOptions.map { label, value in
                         item(
                            label,
                            abs(value - Double(p.scrollSpeed)) < 0.001
                                ? "current · \(String(format: "%.2gx", value))"
                                : String(format: "%.2gx", value)
                         ) {
                             p.scrollSpeed = CGFloat(value)
                         }
                     }),
            .section("SID Sounds", p.sounds ? "on" : "off",
                     booleanPaletteItems(current: p.sounds) { p.sounds = $0 }),
            .section("Ghost Text", p.ghostText ? "on" : "off",
                     booleanPaletteItems(current: p.ghostText) { p.ghostText = $0 }),
            .section("Automatic Error Help", p.automaticErrorHelp ? "on" : "off",
                     booleanPaletteItems(current: p.automaticErrorHelp) { p.automaticErrorHelp = $0 }),
            .section("Marketplace Update Checks", p.marketplaceUpdateChecks ? "on" : "off",
                     booleanPaletteItems(current: p.marketplaceUpdateChecks) { enabled in
                         p.marketplaceUpdateChecks = enabled
                         if enabled { MarketplaceUpdateMonitor.shared.checkIfDue(force: true) }
                         else { MarketplaceUpdateMonitor.shared.clearKnownUpdates() }
                     }),
        ]))

        let marketplaceUpdateCount = MarketplaceUpdateMonitor.shared.extensionUpdateCount
        var pluginItems: [PaletteItem] = [
            item("Extensions…", marketplaceUpdateCount == 0
                 ? "⇧⌘L" : "\(marketplaceUpdateCount) update\(marketplaceUpdateCount == 1 ? "" : "s") · ⇧⌘L") {
                [weak self] in self?.showPlugins(nil)
            },
            item("Browse the Marketplace…", "shaders · themes · rigs · extensions") { [weak self] in
                self?.browseMarketplace(nil)
            },
        ]
        // Each plugin is its own subsection — scalable, not one long list.
        for group in extensionCommandGroups {
            pluginItems.append(.section(group.plugin, "\(group.commands.count) commands",
                group.commands.map { command in
                    item(Self.trimPluginPrefix(command.title, plugin: group.plugin), group.plugin.lowercased()) {
                        command.run()
                    }
                }))
        }
        pluginItems.append(item("Create Sample Extension", "scaffold") { PluginManager.shared.createSamplePlugin() })
        pluginItems.append(item("Open Author Guide", "EXTENSIONS.md") { PluginManager.shared.openAuthorGuide() })
        pluginItems.append(item("Open Extensions Folder") {
            try? FileManager.default.createDirectory(at: PluginManager.extensionsDirectory,
                                                     withIntermediateDirectories: true)
            NSWorkspace.shared.open(PluginManager.extensionsDirectory)
        })
        let extensionSubtitle = marketplaceUpdateCount == 0
            ? "manage · commands · authoring"
            : "\(marketplaceUpdateCount) update\(marketplaceUpdateCount == 1 ? "" : "s") · manage · commands"
        root.append(.section("Extensions", extensionSubtitle, pluginItems))

        return root
    }

    @objc func previousPrompt(_ sender: Any?) { currentController?.jumpToPreviousPrompt() }
    @objc func nextPrompt(_ sender: Any?) { currentController?.jumpToNextPrompt() }
    @objc func copyLastOutput(_ sender: Any?) { currentController?.copyLastCommandOutput() }
    @objc func explainLast(_ sender: Any?) { currentController?.explainLastCommand() }

    @objc func jumpToBlockMenu(_ sender: NSMenuItem) {
        if let row = sender.representedObject as? Int { currentController?.jumpToRow(row) }
    }

    // MARK: - Inline pickers (deliberate try-before-save, no hover surprises)

    /// Open the palette pre-filtered to one settings family: ↑↓ previews each
    /// candidate live, ⏎ keeps it without closing, esc reverts or backs out.
    /// (Hover-previewing the menus
    /// was tried and felt twitchy — previews now require a selection.)
    @objc func browseThemes(_ sender: Any?) { showPicker("themes", themePaletteItems()) }
    @objc func browseFonts(_ sender: Any?) { showPicker("fonts", fontPaletteItems()) }
    @objc func browseShaders(_ sender: Any?) { showPicker("shaders", shaderPaletteItems()) }
    @objc func browseCursors(_ sender: Any?) { showPicker("cursors", cursorPaletteItems()) }

    private func showPicker(_ label: String, _ items: [PaletteItem]) {
        guard let controller = currentController,
              let pane = controller.focusedPane else { NSSound.beep(); return }
        pane.presentInlinePanel().configureList(
            items: items,
            placeholder: "filter \(label)…",
            hint: "↑↓ preview live · ⏎ keep + stay · esc close",
            memoryKey: "picker.\(label)",
            previewHooks: tabAppearancePreviewHooks(for: controller))
    }

    /// The Config Mixer: Claude Code /config-style tabs — flip between
    /// Theme/Font/Shader/Cursor/Spacing previewing candidates; the blend
    /// ACCUMULATES across tabs. ⏎ keeps the whole blend, esc reverts it all.
    @objc func showConfigMixer(_ sender: Any?) {
        guard let controller = currentController,
              let pane = controller.focusedPane else { NSSound.beep(); return }
        pane.presentInlinePanel().configureTabs(
            tabs: [
                ("Theme", themePaletteItems()),
                ("Font", fontPaletteItems()),
                ("Shader", shaderPaletteItems()),
                ("Cursor", cursorPaletteItems()),
                ("Spacing", lineSpacingPaletteItems()),
            ],
            hint: "⇥/→ tabs · ↑↓ preview · ⏎ keep + stay · esc (or ← from Theme) done",
            memoryKey: "config-mixer",
            previewHooks: tabAppearancePreviewHooks(for: controller))
    }

    /// Rebuild the Blocks menu on open: keep the 4 static items, then list the
    /// key window's recent commands with ✓/✗ status (click to jump).
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Workspaces" {
            MainActor.assumeIsolated { rebuildNamedWorkspacesMenu(menu) }
            return
        }
        if menu.title == "Merge With" {
            // One entry per OTHER window; each expands to a direction picker.
            menu.removeAllItems()
            let current = currentController
            let others = controllers.filter { $0 !== current && $0.window != nil }
            if others.isEmpty {
                let empty = NSMenuItem(title: "No Other Windows", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            for other in others {
                guard let w = other.window else { continue }
                let item = NSMenuItem(title: w.title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: w.title)
                let options: [(String, String?)] = [
                    ("Split Left", "left"), ("Split Right", "right"),
                    ("Split Top", "top"), ("Split Bottom", "bottom"),
                    ("Add as Tab", nil),
                ]
                for (label, side) in options {
                    let it = NSMenuItem(title: label, action: #selector(mergeDirectional(_:)), keyEquivalent: "")
                    var info: [String: Any] = ["window": w.windowNumber]
                    if let side { info["side"] = side }
                    it.representedObject = info
                    it.target = self
                    sub.addItem(it)
                }
                item.submenu = sub
                menu.addItem(item)
            }
            return
        }
        if menu.title == "Extensions" {
            menu.removeAllItems()
            let updateCount = MarketplaceUpdateMonitor.shared.extensionUpdateCount
            let manageTitle = updateCount == 0 ? "Extensions…"
                : "Extensions… (\(updateCount) Update\(updateCount == 1 ? "" : "s"))"
            let manage = NSMenuItem(title: manageTitle, action: #selector(showPlugins(_:)), keyEquivalent: "l")
            manage.keyEquivalentModifierMask = [.command, .shift]
            manage.target = self
            menu.addItem(manage)
            menu.addItem(.separator())
            let groups = extensionCommandGroups
            if groups.isEmpty {
                let none = NSMenuItem(title: "No extension commands", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            // One submenu per plugin — no more one long flat list.
            for group in groups {
                let parent = NSMenuItem(title: group.plugin, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: group.plugin)
                for command in group.commands {
                    let it = NSMenuItem(title: Self.trimPluginPrefix(command.title, plugin: group.plugin),
                                        action: #selector(runPluginCommand(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = command.run
                    sub.addItem(it)
                }
                parent.submenu = sub
                menu.addItem(parent)
            }
            return
        }
        if menu.title == "Actions" {
            rebuildActionsMenu(menu)
            return
        }
        if menu.title == "Channels" {
            rebuildChannelsMenu(menu)
            return
        }
        if menu.title == "Theme" {
            // Rebuild so user themes (~/.config/cmdy/themes) show without relaunch.
            menu.removeAllItems()
            let browse = NSMenuItem(title: "Browse with Preview…", action: #selector(browseThemes(_:)), keyEquivalent: "")
            browse.target = self
            menu.addItem(browse)
            menu.addItem(.separator())
            let selectedTheme = currentController?.selectedThemeName
                ?? Preferences.shared.themeName
            for name in Theme.names {
                let it = NSMenuItem(title: name, action: #selector(setThemeMenu(_:)), keyEquivalent: "")
                it.representedObject = name
                it.state = name == selectedTheme ? .on : .off
                menu.addItem(it)
            }
            return
        }
        guard menu.title == "Blocks" else { return }
        // Keep the static items (nav + AI actions), rebuild only the dynamic
        // recent-commands tail. 8 = everything main.swift adds at launch.
        while menu.items.count > 8 { menu.removeItem(at: menu.items.count - 1) }
        guard let cmds = currentController?.recentCommands(), !cmds.isEmpty else { return }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Recent Commands", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for c in cmds {
            let it = NSMenuItem(title: c.label, action: #selector(jumpToBlockMenu(_:)), keyEquivalent: "")
            it.representedObject = c.promptRow
            it.target = self
            menu.addItem(it)
        }
    }

    /// "Bridge: Engine Status" inside the Bridge submenu reads twice — trim
    /// the plugin's own name prefix for display.
    static func trimPluginPrefix(_ title: String, plugin: String) -> String {
        for sep in [": ", " — ", " "] where title.lowercased().hasPrefix(plugin.lowercased() + sep) {
            return String(title.dropFirst(plugin.count + sep.count))
        }
        return title
    }

    /// External Extensions register commands over the SDK. Embedded native
    /// components have no child process, so the host contributes their narrow
    /// App-owned commands here without reviving the retired Browser sidecar.
    private var extensionCommandGroups:
        [(plugin: String, commands: [(title: String, run: () -> Void)])] {
        var groups = PluginManager.shared.commandsByPlugin
        guard EmbeddedChromiumRuntime.shared.isAvailable,
              !groups.contains(where: {
                  $0.plugin.caseInsensitiveCompare("Browser") == .orderedSame
              }) else {
            return groups
        }
        groups.append((
            plugin: "Browser",
            commands: [
                (title: "Show/Hide", run: { [weak self] in
                    self?.currentController?.toggleEmbeddedBrowser(
                        focusLocation: true)
                    self?.refreshMenuStates()
                }),
                (title: "Open URL…", run: { [weak self] in
                    self?.currentController?.focusEmbeddedBrowserLocation()
                }),
                (title: "Reload", run: { [weak self] in
                    self?.currentController?.reloadEmbeddedBrowser()
                }),
                (title: "Developer Tools", run: { [weak self] in
                    self?.currentController?.openEmbeddedBrowserDevTools()
                }),
            ]
        ))
        return groups
    }

    @objc func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: ProductIdentity.current.displayName,
            .init(rawValue: "Copyright"):
                "Copyright © 2026 Andreas Pihlstrom. MIT licensed.",
        ])
    }

    @objc func showLicensesAndNotices(_ sender: Any?) {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(
                "THIRD_PARTY_NOTICES.md"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("THIRD_PARTY_NOTICES.md"),
        ].compactMap { $0 }
        guard let notices = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            let alert = NSAlert()
            alert.messageText = "Licenses and notices are unavailable"
            alert.informativeText =
                "The distribution is missing THIRD_PARTY_NOTICES.md."
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(notices)
    }

    @objc @MainActor func checkForUpdates(_ sender: Any?) {
        let parent = NSApp.keyWindow ?? currentController?.window
        if AppUpdateMonitor.shared.availableUpdate != nil {
            AppUpdateWindow.shared.show(relativeTo: parent)
            return
        }
        AppUpdateMonitor.shared.checkIfDue(force: true) { update in
            MainActor.assumeIsolated {
                if update != nil {
                    AppUpdateWindow.shared.show(relativeTo: parent)
                    return
                }
                let alert = NSAlert()
                alert.messageText = "No newer stable release found"
                let current = AppUpdateMonitor.shared.currentVersion ?? "this build"
                alert.informativeText =
                    "\(ProductIdentity.current.displayName) \(current) is the newest "
                    + "published version available from GitHub."
                alert.addButton(withTitle: "OK")
                if let parent, parent.isVisible {
                    alert.beginSheetModal(for: parent)
                } else {
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Menu validation (checkmarks)

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let p = Preferences.shared
        if [#selector(saveDocument(_:)), #selector(saveDocumentAs(_:)),
            #selector(toggleEditorAttachment(_:))].contains(item.action) {
            return CmdyEditorManager.shared.focusedEditor != nil
        }
        switch item.action {
        case #selector(checkForUpdates(_:)):
            let monitor = AppUpdateMonitor.shared
            if let release = monitor.availableUpdate {
                switch monitor.downloadState {
                case .idle:
                    let action = release.canDownloadAutomatically ? "Download" : "Open"
                    let suffix = release.canDownloadAutomatically ? "" : " Release"
                    item.title = "\(action) \(ProductIdentity.current.displayName) "
                        + "\(release.version)\(suffix)…"
                case .downloading:
                    item.title = "Downloading \(ProductIdentity.current.displayName) "
                        + "\(release.version)…"
                case .ready:
                    item.title = "Show Downloaded Update…"
                case .failed:
                    item.title = "Retry Update Download…"
                }
                return true
            }
            item.title = monitor.isChecking ? "Checking for Updates…" : "Check for Updates…"
            return !monitor.isChecking
        case #selector(setThemeMenu(_:)):
            item.state = (item.representedObject as? String
                == (currentController?.selectedThemeName ?? p.themeName))
                ? .on : .off
        case #selector(setCursorMenu(_:)):
            item.state = (item.representedObject as? String == p.cursorStyleName) ? .on : .off
        case #selector(toggleSmoothCursor(_:)):
            item.state = p.smoothCursor ? .on : .off
        case #selector(setCursorGlideSpeed(_:)):
            if let value = item.representedObject as? Double {
                item.state = abs(value - Double(p.cursorGlideSpeed)) < 0.001 ? .on : .off
            }
        case #selector(setScrollSpeed(_:)):
            if let value = item.representedObject as? Double {
                item.state = abs(value - Double(p.scrollSpeed)) < 0.001 ? .on : .off
            }
        case #selector(setCursorGlideDistance(_:)):
            if let value = item.representedObject as? Double {
                item.state = abs(value - Double(p.cursorGlideMaxDistance)) < 0.001 ? .on : .off
            }
        case #selector(setFontMenu(_:)):
            item.state = (item.representedObject as? String == p.fontName) ? .on : .off
        case #selector(setLineHeightMenu(_:)):
            if let v = item.representedObject as? Double { item.state = abs(v - Double(p.lineHeight)) < 0.001 ? .on : .off }
        case #selector(setWindowInsetMenu(_:)):
            if let v = item.representedObject as? Double { item.state = abs(v - Double(p.contentMargin)) < 0.001 ? .on : .off }
        case #selector(setOpacityMenu(_:)):
            if let v = item.representedObject as? Double { item.state = abs(v - p.opacity) < 0.001 ? .on : .off }
        case #selector(setShaderMenu(_:)):
            item.state = (item.representedObject as? String
                == (currentController?.selectedShaderName ?? p.shaderName))
                ? .on : .off
        case #selector(toggleFloat(_:)):
            item.state = NSApp.keyWindow?.level == .floating ? .on : .off
        case #selector(toggleOptionAsMeta(_:)):
            item.state = p.optionAsMeta ? .on : .off
        case #selector(toggleShellIntegration(_:)):
            item.state = p.shellIntegration ? .on : .off
        case #selector(toggleAutomaticErrorHelp(_:)):
            item.state = p.automaticErrorHelp ? .on : .off
        case #selector(toggleCleanPrompt(_:)):
            item.state = p.cleanPrompt ? .on : .off
        case #selector(toggleHideTrafficLights(_:)):
            item.state = p.hideTrafficLights ? .on : .off
        case #selector(toggleWindowGrid(_:)):
            item.state = p.windowGridEnabled ? .on : .off
        case #selector(toggleBlur(_:)):
            item.state = p.blur ? .on : .off
        case #selector(toggleWorkspaceNavigator(_:)):
            item.state = p.workspaceNavigatorVisible ? .on : .off
        case #selector(toggleWorkspaceInspector(_:)):
            item.state = p.workspaceInspectorVisible ? .on : .off
        case #selector(toggleEmbeddedBrowser(_:)):
            item.state = currentController?.isEmbeddedBrowserVisible == true ? .on : .off
            if !EmbeddedChromiumRuntime.shared.isAvailable
                && !PluginManager.shared.hasCommand(id: "chromium.toggle") {
                item.state = .off
                item.title = "Install Browser…"
            } else {
                item.title = item.state == .on ? "Hide Browser" : "Show Browser"
            }
            return true
        case #selector(toggleWorkspaceFocusMode(_:)):
            item.state = currentController?.isWorkspaceFocusMode == true ? .on : .off
        default:
            break
        }
        return true
    }

}
