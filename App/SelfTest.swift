import AppKit
import ProductIdentity
import Foundation
import CmdyKit
import CmdyCore

/// Headless sanity checks for the pure logic that can't be eyeballed in the GUI
/// (OSC 133 parsing + BlockStore state machine). Run with: cmdy --selftest
@MainActor
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            print("\(cond ? "ok  " : "FAIL") \(name)")
            if !cond { failures += 1 }
        }

        CmdySurfaceContractHarness.run(check)
        CmdyCellImageHarness.run(check)

        // OSC 133 payload parsing
        check(BlockStore.parse("A")?.kind == "A", "parse A")
        check(BlockStore.parse("B")?.kind == "B", "parse B")
        check(BlockStore.parse("C")?.kind == "C", "parse C")
        check(BlockStore.parse("D")?.kind == "D" && BlockStore.parse("D")?.exit == nil, "parse D (no code)")
        check(BlockStore.parse("D;0")?.exit == 0, "parse D;0")
        check(BlockStore.parse("D;1")?.exit == 1, "parse D;1")
        check(BlockStore.parse("D;130;extra")?.exit == 130, "parse D;130;extra")
        check(BlockStore.parse("") == nil, "parse empty -> nil")

        check(!WindowChromeLayout.isCompact(windowHeight: 132),
              "compact chrome: regular short window keeps its header")
        check(WindowChromeLayout.isCompact(windowHeight: 80),
              "compact chrome: tiny window reclaims its header")
        check(WindowChromeLayout.minimumWindowHeight(
            rowHeight: 16, contentMargin: 10, backingScale: 2) == 36,
              "minimum window height: one complete row plus both margins")

        // A duplicate key equivalent makes AppKit dispatch both menu actions.
        // This previously opened an Untitled editor while hiding the sidebar
        // because both commands claimed Command-Option-N.
        check(AppMenuShortcuts.newTextFile != AppMenuShortcuts.workspaceNavigator,
              "main menu: text file and Navigator shortcuts are distinct")

        check(WorkspaceDividerOverlayView.rememberedRailThickness(
            280, whileVisible: false) == nil,
              "workspace divider: a hidden Inspector has no preservable width")
        check(WorkspaceDividerOverlayView.rememberedRailThickness(
            280, whileVisible: true) == 280,
              "workspace divider: a visible opposite rail keeps its width")

        // Contextual Inspector parsing stays pure and bounded.
        let sampleFontName = TerminalAppearanceFontCatalog.choices
            .first(where: { $0.name != TerminalAppearanceFontCatalog.systemName })?
            .name ?? TerminalAppearanceFontCatalog.systemName
        let tabLook = TerminalTabAppearance.restored(
            themeName: "Nord", shaderName: "Glow",
            fontName: sampleFontName)
        check(tabLook == TerminalTabAppearance(
            themeName: "Nord", shaderName: "Glow",
            fontName: sampleFontName),
              "tab appearance: valid theme, shader, and font restore independently")
        let invalidTabLook = TerminalTabAppearance.restored(
            themeName: "Not a theme", shaderName: "Not a shader",
            fontName: "Not a font")
        check(invalidTabLook == TerminalTabAppearance(),
              "tab appearance: invalid overrides fall back to global")
        let globalLook = TerminalTabAppearance()
        check(tabLook.resolvedThemeName(global: "Dark") == "Nord"
                && globalLook.resolvedThemeName(global: "Dark") == "Dark"
                && tabLook.resolvedShaderName(global: "None") == "Glow"
                && globalLook.resolvedShaderName(global: "None") == "None"
                && tabLook.resolvedFontName(global: "System") == sampleFontName
                && globalLook.resolvedFontName(global: "System") == "System",
              "tab appearance: overrides stay isolated from global-following tabs")

        if let importedShortcut = try? CMDYKeybindingShortcut(
            key: "k", modifiers: [.option]),
           let importedEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "k", charactersIgnoringModifiers: "k",
            isARepeat: false, keyCode: 40) {
            check(StandardKeybindings.importedCommand(
                    for: importedEvent,
                    mappings: [importedShortcut: .action(.newTab)])
                    == .action(.newTab),
                  "keybinding import: normalized event dispatches imported action")
        } else {
            check(false, "keybinding import: deterministic event fixture")
        }

        let unstagedChange = WorkspaceGitChange.parse(
            " M App/WorkspaceFrameView.swift")
        let stagedChange = WorkspaceGitChange.parse(
            "M  App/TerminalWindowController.swift")
        let renamedChange = WorkspaceGitChange.parse(
            "R  old.swift -> App/new.swift")
        check(unstagedChange?.path == "App/WorkspaceFrameView.swift"
                && unstagedChange?.prefersCachedDiff == false,
              "inspector git: unstaged file resolves to working-tree diff")
        check(stagedChange?.prefersCachedDiff == true,
              "inspector git: staged file resolves to cached diff")
        check(renamedChange?.path == "App/new.swift",
              "inspector git: rename targets the destination path")

        let detectedResources = WorkspaceOutputRecognizer.resources(
            in: """
            ready at localhost:4173/preview
            duplicate http://localhost:4173/preview
            generated /bin/zsh
            """,
            cwd: "/tmp")
        check(detectedResources.contains {
            $0.kind == .web && $0.url.host == "localhost"
                && $0.url.port == 4173
        }, "inspector output: localhost becomes an openable web resource")
        check(detectedResources.contains {
            $0.kind == .file && $0.url.path == "/bin/zsh"
        }, "inspector output: existing paths become file resources")
        check(detectedResources.filter { $0.kind == .web }.count == 1,
              "inspector output: duplicate links are collapsed")

        // BlockStore state machine
        let store = BlockStore()
        check(store.commandCount == 0 && !store.isRunning, "store starts empty")
        store.commandStarted(row: 10, promptRow: 9, command: "ls", cwd: "/tmp")
        check(store.commandCount == 1 && store.isRunning, "commandStarted -> running")
        check(store.blocks.first?.commandText == "ls", "block records command text")
        store.commandFinished(row: 15, exitCode: 0)
        check(!store.isRunning && store.lastExit == 0, "commandFinished(0) -> ok")
        check(store.lastCompletedBlock?.endRow == 15, "block records endRow")
        store.commandStarted(row: 16, promptRow: 15, command: "false", cwd: "/tmp")
        store.commandFinished(row: 20, exitCode: 2)
        check(store.commandCount == 2 && store.lastExit == 2, "second command records exit 2")
        store.promptStarted(row: 21)
        check(store.promptRows.last == 21, "promptStarted records row")

        // Repeated empty prompts (holding Return) have no commandStarted marker.
        // Their navigation metadata must stay bounded, and a stray D marker must
        // not report a state change when there is no running block to finish.
        let emptyPrompts = BlockStore()
        var promptChanges = 0
        emptyPrompts.onChange = { promptChanges += 1 }
        for row in 0..<(BlockStore.maxBlocks + 50) { emptyPrompts.promptStarted(row: row) }
        check(emptyPrompts.promptRows.count == BlockStore.maxBlocks,
              "empty prompts: retention stays capped")
        check(emptyPrompts.promptRows.first == 50,
              "empty prompts: oldest rows are discarded")
        let afterPrompts = promptChanges
        emptyPrompts.promptStarted(row: BlockStore.maxBlocks + 49)   // duplicate A
        let unmatchedFinish = emptyPrompts.commandFinished(
            row: BlockStore.maxBlocks + 50, exitCode: 0) // D without C
        check(!unmatchedFinish && promptChanges == afterPrompts,
              "empty prompts: duplicate A / unmatched D do not notify")

        let finishNotifications = BlockStore()
        var finishChanges = 0
        finishNotifications.onChange = { finishChanges += 1 }
        finishNotifications.commandStarted(row: 1, promptRow: 0, command: "true", cwd: nil)
        let firstFinish = finishNotifications.commandFinished(row: 2, exitCode: 0)
        let afterFinish = finishChanges
        let repeatedFinish = finishNotifications.commandFinished(row: 3, exitCode: 0)
        check(firstFinish && !repeatedFinish && finishChanges == afterFinish,
              "command finish: repeated D does not notify")

        let statePane = TerminalPane(cwd: nil)
        var paneStateChanges = 0
        statePane.onStateChanged = { _ in paneStateChanges += 1 }
        statePane.surface.onTitleChanged?("build")
        statePane.surface.onTitleChanged?("build")
        statePane.surface.onCwdChanged?("file:///tmp")
        statePane.surface.onCwdChanged?("/tmp")
        check(paneStateChanges == 2,
              "pane state: duplicate title/cwd callbacks are suppressed")
        statePane.shutdown()

        let panelPane = TerminalPane(cwd: nil)
        let dismissedPanel = panelPane.presentInlinePanel(takeFocus: false)
        dismissedPanel.configureList(
            items: [PaletteItem(title: "Choice", subtitle: "", action: {})],
            placeholder: "", hint: "")
        check(abs((panelPane.inlinePanelBottomConstraint?.constant ?? 0)
                  + Preferences.shared.contentMargin * 2
                  - panelPane.surface.cellSize.height * 1.5) < 0.5,
              "inline panel: full-size block translates down by one and a half rows")
        check(abs((panelPane.inlinePanelHeightConstraint?.constant ?? 0)
                  - dismissedPanel.intrinsicContentSize.height) < 0.5,
              "inline panel: height is pinned to its visible content")
        check(panelPane.surface.bottomContentInset > 0,
              "inline panel: opening reserves grid rows")
        panelPane.surface.lineHeightMultiplier = 1.3
        dismissedPanel.refreshMetrics()
        let relaxedPanelHeight = dismissedPanel.intrinsicContentSize.height
        panelPane.surface.lineHeightMultiplier = 0.7
        dismissedPanel.refreshMetrics()
        check(dismissedPanel.intrinsicContentSize.height < relaxedPanelHeight,
              "inline panel: rows follow terminal line-height metrics")
        panelPane.surface.lineHeightMultiplier = Preferences.shared.lineHeight
        dismissedPanel.refreshMetrics()
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        dismissedPanel.keyDown(with: escape)
        NotificationCenter.default.post(name: .cmdyPreferencesChanged, object: nil)
        check(panelPane.surface.bottomContentInset == 0,
              "inline panel: dismissed preference callbacks cannot restore stale height")
        let controlBar = panelPane.presentExtensionControlBar()
        controlBar.configure(
            actions: [ExtensionControlBarAction(id: "annotate", title: "[ annotate ]")],
            placeholder: "enter URL")
        check(abs((panelPane.extensionControlBarHeightConstraint?.constant ?? 0)
                  - controlBar.preferredHeight) < 0.5,
              "control bar: height is pinned to its visible row")
        panelPane.dismissExtensionControlBar(controlBar)

        panelPane.inheritedAppearanceProvider = {
            ("B/W", "None", Preferences.shared.fontName)
        }
        panelPane.restoreAppearance(TerminalTabAppearance(
            themeName: "Nord", shaderName: "Glow",
            fontName: sampleFontName))
        if let contextMenu = panelPane.menu {
            panelPane.menuNeedsUpdate(contextMenu)
            let themeMenu = contextMenu.items.first { $0.title == "Theme" }?.submenu
            let shaderMenu = contextMenu.items.first { $0.title == "Shader" }?.submenu
            let fontMenu = contextMenu.items.first { $0.title == "Font" }?.submenu
            check(themeMenu?.items.first?.title == "Tab — B/W"
                    && themeMenu?.items.first { $0.title == "Nord" }?.state == .on,
                  "pane menu: theme override and tab inheritance are visible")
            check(shaderMenu?.items.first?.title == "Tab — None"
                    && shaderMenu?.items.first { $0.title == "Glow" }?.state == .on,
                  "pane menu: shader override and tab inheritance are visible")
            check(fontMenu?.items.first?.title.hasPrefix("Tab — ") == true
                    && fontMenu?.items.first {
                        $0.representedObject as? String == sampleFontName
                    }?.state == .on,
                  "pane menu: validated font override and tab inheritance are visible")
        } else {
            check(false, "pane menu: terminal owns a context menu")
        }
        panelPane.shutdown()

        // Pane appearance is a live part of the split tree, not window-global
        // state. These controller fixtures suppress shells so the complete
        // move/serialize/restore path remains deterministic and side-effect free.
        func disposeAppearanceFixture(_ controller: TerminalWindowController) {
            controller.panes.forEach { $0.shutdown() }
            controller.window?.delegate = nil
            controller.close()
        }
        func paneNodes(in node: [String: Any]) -> [[String: Any]] {
            if node["type"] as? String == "pane" { return [node] }
            return (node["children"] as? [[String: Any]] ?? [])
                .flatMap(paneNodes(in:))
        }

        let appearanceSource = TerminalWindowController(
            cwd: "/tmp", startShells: false)
        appearanceSource.setTabTheme("One Dark")
        appearanceSource.setTabShader("CRT")
        appearanceSource.setTabFont(sampleFontName)
        let firstAppearancePane = appearanceSource.panes[0]
        let secondAppearancePane = appearanceSource.splitPane(
            firstAppearancePane, vertical: true)!
        appearanceSource.setPaneAppearanceForTesting(
            firstAppearancePane,
            themeName: "Nord", shaderName: "Glow",
            fontName: TerminalAppearanceFontCatalog.systemName)
        let firstChrome = appearanceSource.resolvedChromeAppearanceForTesting
        check(firstChrome.sourcePaneID == firstAppearancePane.paneId
                && firstChrome.themeName == "Nord"
                && firstChrome.shaderName == "Glow"
                && appearanceSource.lastAppliedChromeAppearanceForTesting
                    == firstChrome,
              "pane appearance: first spatial pane drives applied window chrome")

        appearanceSource.setPaneAppearanceForTesting(
            secondAppearancePane,
            themeName: "Dracula", shaderName: "Neon",
            fontName: sampleFontName)
        check(appearanceSource.resolvedChromeAppearanceForTesting == firstChrome
                && appearanceSource.lastAppliedChromeAppearanceForTesting
                    == firstChrome,
              "pane appearance: non-first overrides do not recolor window chrome")
        check(firstAppearancePane.paneAppearance.fontName
                == TerminalAppearanceFontCatalog.systemName
                && secondAppearancePane.paneAppearance.fontName == sampleFontName,
              "pane appearance: font overrides remain local to their terminal")

        let savedAppearance = appearanceSource.serializeLayout()
        let savedPaneNodes = paneNodes(in: savedAppearance)
        check(savedAppearance["tabTheme"] as? String == "One Dark"
                && savedAppearance["tabShader"] as? String == "CRT"
                && savedAppearance["tabFont"] as? String == sampleFontName,
              "pane appearance: tab theme, shader, and font serialize")
        check(savedPaneNodes.count == 2
                && savedPaneNodes[0]["paneTheme"] as? String == "Nord"
                && savedPaneNodes[0]["paneShader"] as? String == "Glow"
                && savedPaneNodes[0]["paneFont"] as? String
                    == TerminalAppearanceFontCatalog.systemName
                && savedPaneNodes[1]["paneTheme"] as? String == "Dracula"
                && savedPaneNodes[1]["paneShader"] as? String == "Neon"
                && savedPaneNodes[1]["paneFont"] as? String == sampleFontName,
              "pane appearance: every split leaf serializes its complete look")

        let restoredAppearance = TerminalWindowController(
            session: savedAppearance, startShells: false)
        let restoredChrome = restoredAppearance.resolvedChromeAppearanceForTesting
        check(restoredAppearance.tabAppearanceSnapshot == TerminalTabAppearance(
                themeName: "One Dark", shaderName: "CRT",
                fontName: sampleFontName)
                && restoredAppearance.panes.map(\.paneAppearance)
                    == appearanceSource.panes.map(\.paneAppearance)
                && restoredChrome.themeName == "Nord"
                && restoredChrome.shaderName == "Glow",
              "pane appearance: session restore preserves tab, leaves, and chrome source")

        let movedAppearancePane = appearanceSource.releasePaneForMove(
            firstAppearancePane.paneId)!
        let promotedChrome = appearanceSource.resolvedChromeAppearanceForTesting
        check(promotedChrome.sourcePaneID == secondAppearancePane.paneId
                && promotedChrome.themeName == "Dracula"
                && promotedChrome.shaderName == "Neon"
                && appearanceSource.lastAppliedChromeAppearanceForTesting
                    == promotedChrome,
              "pane appearance: removing the first leaf promotes chrome immediately")
        let appearanceDestination = TerminalWindowController(
            cwd: "/tmp", startShells: false)
        appearanceDestination.adopt(movedAppearancePane, side: .left)
        check(appearanceDestination.panes.contains {
                    $0 === movedAppearancePane
                }
                && movedAppearancePane.paneAppearance == TerminalTabAppearance(
                    themeName: "Nord", shaderName: "Glow",
                    fontName: TerminalAppearanceFontCatalog.systemName)
                && appearanceDestination.resolvedChromeAppearanceForTesting
                    .sourcePaneID == movedAppearancePane.paneId,
              "pane appearance: live tear-out/adoption retains identity and complete look")

        // A native tab selection calls windowDidBecomeKey on that tab's
        // backing controller. Make stale applied state visible, then prove the
        // selection hook resolves this tab's own first pane before its frame.
        movedAppearancePane.restoreAppearance(TerminalTabAppearance(
            themeName: "Light", shaderName: "Matrix",
            fontName: TerminalAppearanceFontCatalog.systemName))
        appearanceDestination.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: appearanceDestination.window))
        check(appearanceDestination.lastAppliedChromeAppearanceForTesting
                == appearanceDestination.resolvedChromeAppearanceForTesting
                && appearanceDestination.lastAppliedChromeAppearanceForTesting?
                    .themeName == "Light"
                && appearanceDestination.lastAppliedChromeAppearanceForTesting?
                    .shaderName == "Matrix",
              "tab appearance: native tab selection reapplies that tab's first pane")

        disposeAppearanceFixture(restoredAppearance)
        disposeAppearanceFixture(appearanceDestination)
        disposeAppearanceFixture(appearanceSource)

        // Theme registry
        check(Theme.named("C64").name == "C64", "C64 theme resolves")
        check(Theme.named("nonexistent").name == "C64", "unknown theme -> C64 default")
        check(Theme.c64.ansi.count == 16, "C64 palette has 16 colors")
        check(Theme.builtins.count >= 15, "theme gallery present")
        check(Theme.builtins.allSatisfy { $0.ansi.count == 16 }, "every builtin has 16 ANSI colors")
        check(Theme.hex("#ff8000")?.green == 0x80 * 257, "hex parses")
        check(Theme.hex("nope") == nil, "bad hex -> nil")
        check(Preferences.defaultThemeName == "Light"
                && Preferences.defaultFontName == "FragmentMono-Regular"
                && Preferences.defaultFontSize == 13,
              "first-launch appearance defaults stay canonical")
        if ProductIdentity.current.environmentValue("DEFAULTS_DOMAIN") != nil {
            let defaults = Preferences.shared
            check(defaults.themeName == "Light" && defaults.theme.name == "Light",
                  "isolated first launch resolves the Light theme")
            check(defaults.fontName == "FragmentMono-Regular"
                    && defaults.fontSize == 13
                    && defaults.resolvedFont().fontName == "FragmentMono-Regular",
                  "isolated first launch resolves Fragment Mono at 13 points")
            check(defaults.automaticErrorHelp,
                  "automatic error help is enabled on first launch")
            check(defaults.editor == ProductIdentity.current.slug,
                  "the native text editor is the first-launch default")
            check(defaults.cleanPrompt && defaults.contentMargin == 10
                    && defaults.scrollSpeed == 1.5,
                  "first-launch terminal behavior matches the default config")
            check(!defaults.showBanner
                    && !defaults.workspaceNavigatorVisible
                    && !defaults.workspaceInspectorVisible
                    && !TerminalWindowController.embeddedBrowserStartsVisible,
                  "first launch starts without banner, sidebar, browser, or inspector")
            check(defaults.nativeToolbarStyle == "compact",
                  "the default inset selects AppKit unified compact")
            check(Preferences.nativeToolbarStyle(forContentMargin: 0) == "compact"
                    && Preferences.nativeToolbarStyle(forContentMargin: 6) == "compact"
                    && Preferences.nativeToolbarStyle(forContentMargin: 10) == "compact"
                    && Preferences.nativeToolbarStyle(forContentMargin: 10.01) == "unified"
                    && Preferences.nativeToolbarStyle(forContentMargin: 18) == "unified",
                  "native toolbar density snaps at the Medium/Large inset boundary")
            check(defaults.cursorGlideSpeed == 1.6
                    && defaults.cursorGlideMaxDistance == 0,
                  "cursor glide defaults match the default config")
            check(defaults.lineHeight == 1.15
                    && defaults.textRenderingMode == "high-contrast",
                  "first-launch text rendering matches the default config")
        }

        // Ghostty-compatible standard keybindings. Test physical and textual
        // routes so keyboard layouts cannot silently regress the common set.
        if case .fullscreen? = StandardKeybindings.resolve(
            keyCode: 36, characters: "\r", modifiers: [.command]) {
            check(true, "keybindings: command-return toggles fullscreen")
        } else { check(false, "keybindings: command-return toggles fullscreen") }
        if case .tab(0)? = StandardKeybindings.resolve(
            keyCode: 18, characters: "&", modifiers: [.command]) {
            check(true, "keybindings: physical command-1 selects tab one")
        } else { check(false, "keybindings: physical command-1 selects tab one") }
        if case .focus(.left)? = StandardKeybindings.resolve(
            keyCode: 123, characters: "", modifiers: [.command, .option]) {
            check(true, "keybindings: command-option-left focuses a split")
        } else { check(false, "keybindings: command-option-left focuses a split") }
        if case .adjustSelection(.pageDown)? = StandardKeybindings.resolve(
            keyCode: 121, characters: "", modifiers: [.shift]) {
            check(true, "keybindings: shift-page-down extends selection")
        } else { check(false, "keybindings: shift-page-down extends selection") }
        if case .writeScreen(.open)? = StandardKeybindings.resolve(
            keyCode: 38, characters: "j", modifiers: [.command, .option, .shift]) {
            check(true, "keybindings: command-option-shift-j opens a screen export")
        } else { check(false, "keybindings: command-option-shift-j opens a screen export") }
        if case .send("\u{1b}b")? = StandardKeybindings.resolve(
            keyCode: 123, characters: "", modifiers: [.option]) {
            check(true, "keybindings: option-left keeps natural word editing")
        } else { check(false, "keybindings: option-left keeps natural word editing") }
        if case .send("\u{1b}\u{7f}")? = StandardKeybindings.resolve(
            keyCode: 51, characters: "", modifiers: [.option]) {
            check(true, "keybindings: option-delete removes the previous word")
        } else { check(false, "keybindings: option-delete removes the previous word") }
        if case .cut? = StandardKeybindings.resolve(
            keyCode: 7, characters: "x", modifiers: [.command]) {
            check(true, "keybindings: command-x reaches the focused editor")
        } else { check(false, "keybindings: command-x reaches the focused editor") }
        check(
            CmdyTerminalSurface.returnKeyBytes(
                modifiers: [.option], kittyKeyboardFlags: 0) == [0x1B, 0x0D],
            "keybindings: option-return is legacy Meta-Return")
        check(
            CmdyTerminalSurface.returnKeyBytes(
                modifiers: [.shift], kittyKeyboardFlags: 0) == [0x1B, 0x0D],
            "keybindings: shift-return inserts a legacy agent newline")
        check(
            String(decoding: CmdyTerminalSurface.returnKeyBytes(
                modifiers: [.shift], kittyKeyboardFlags: 1), as: UTF8.self)
                == "\u{1b}[13;2u",
            "keybindings: enhanced shift-return uses CSI-u")
        check(
            String(decoding: CmdyTerminalSurface.returnKeyBytes(
                modifiers: [.option], kittyKeyboardFlags: 1), as: UTF8.self)
                == "\u{1b}[13;3u",
            "keybindings: enhanced option-return uses CSI-u")
        check(
            AppDelegate.scrollSpeedOptions.contains {
                $0.1 == Double(Preferences.shared.scrollSpeed)
            } && AppDelegate.scrollSpeedOptions.allSatisfy {
                (0.2...5.0).contains($0.1)
            },
            "scroll speed: menu exposes the current valid preference")
        let previousResources = WorkspaceOutputRecognizer.resources(
            in: "ready at http://localhost:4173", cwd: "/tmp")
        check(
            TerminalWindowController.calmWorkspaceResources(
                current: [], previous: previousResources,
                commandRunning: true) == previousResources,
            "inspector calm mode: partial running output keeps published resources")
        check(
            TerminalWindowController.calmWorkspaceResources(
                current: [], previous: previousResources,
                commandRunning: false).isEmpty,
            "inspector calm mode: settled replacement clears stale resources")
        check(
            (0.75...1.25).contains(
                TerminalWindowController.workspaceInspectorOutputSettleDelay),
            "inspector calm mode: raw output waits for a quiet interval")
        // The render-pass clear replaces only the ordinary default background.
        // Semantic backgrounds must still produce row geometry.
        check(!CmdyTerminalSurface.needsExplicitBackground(.bufferDefault),
              "renderer background: native default uses clear")
        check(CmdyTerminalSurface.needsExplicitBackground(
            CellAttribute(bg: .ansi256(1))),
              "renderer background: explicit color is retained")
        check(CmdyTerminalSurface.needsExplicitBackground(
            CellAttribute(style: .inverse)),
              "renderer background: inverse default is retained")

        // A resize capture must match the new dimensions immediately. An old
        // main-queue publication must never get a chance to draw into new bounds.
        let resizeModel = TerminalModel(cols: 10, rows: 4)
        let resizeSnapshot = resizeModel.resize(cols: 18, rows: 7,
                                                pixelWidth: 360, pixelHeight: 140)
        check(resizeSnapshot.grid.cols == 18 && resizeSnapshot.grid.rows == 7,
              "resize snapshot: returned grid matches new geometry")
        check(resizeModel.snapshot.grid.cols == 18 && resizeModel.snapshot.grid.rows == 7,
              "resize snapshot: published grid updates synchronously")
        let originSurface = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 321, height: 140))
        originSurface.leftContentInset = 13.25
        let originBefore = originSurface.contentXOrigin
        originSurface.setFrameSize(NSSize(width: 327, height: 140))
        let originAfter = originSurface.contentXOrigin
        check(originBefore == originAfter,
              "resize placement: first terminal column stays fixed horizontally")
        let editorPane = CmdyEditorPane(url: nil, contents: "margin probe")
        let editorController = CmdyEditorWindowController(pane: editorPane)
        editorController.window?.contentView?.layoutSubtreeIfNeeded()
        editorPane.layoutSubtreeIfNeeded()
        let editorTextOrigin = editorController.window?.contentView.map {
            $0.convert(NSPoint(x: editorPane.textView.textContainerOrigin.x, y: 0),
                       from: editorPane.textView).x
        } ?? -1
        let expectedEditorOrigin = Preferences.shared.contentMargin
        check(abs(editorTextOrigin - expectedEditorOrigin) < 0.5,
              "editor placement: text uses the terminal's single horizontal margin")
        check(WindowDock.acceptsDragSource(editorController.window),
              "window docking: editor windows may arm terminal drop zones")
        check(!WindowDock.acceptsDragSource(NSWindow()),
              "window docking: utility windows cannot arm terminal drop zones")
        let tearVisible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let tearFrame = AppDelegate.sidebarTearOutFrame(
            from: NSRect(x: 100, y: 100, width: 860, height: 540),
            drop: NSPoint(x: 1380, y: 860), visibleFrame: tearVisible)
        check(tearVisible.contains(tearFrame)
                && abs(tearFrame.maxX - tearVisible.maxX) < 0.5,
              "sidebar tab drag: torn-out window stays on the destination screen")
        let resizeOverlay = BlockOverlayView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        check(resizeOverlay.layerContentsRedrawPolicy == .duringViewResize
                && resizeOverlay.layerContentsPlacement == .topLeft,
              "resize overlay: redraws instead of stretching cached contents")

        // Failed commands style the prompt row itself; no dot view or left
        // gutter participates in the result.
        let failedSurface = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        failedSurface.feed(text: "failed")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        failedSurface.failedBlockRows = [0]
        _ = failedSurface.captureGrid()
        let failedRun = failedSurface.lineInfo(forRow: 0).segments.first?.attributedString
        let failedForeground = failedRun?.attribute(.foregroundColor, at: 0,
                                                     effectiveRange: nil) as? NSColor
        let failedBackground = failedRun?.attribute(.backgroundColor, at: 0,
                                                     effectiveRange: nil) as? NSColor
        check(failedForeground?.isEqual(failedSurface.failedBlockForegroundColor) == true,
              "failed row: text uses failure color")
        check(failedBackground?.isEqual(failedSurface.failedBlockBackgroundColor) == true,
              "failed row: full background uses failure color")

        check(resizeOverlay.subviews.compactMap { $0 as? NSButton }.isEmpty
                && resizeOverlay.hitTest(NSPoint(x: 12, y: 12)) == nil,
              "block overlay has no mouse controls")
        let separatorStore = BlockStore()
        resizeOverlay.surface = failedSurface
        resizeOverlay.store = separatorStore
        resizeOverlay.needsDisplay = false
        separatorStore.promptStarted(row: 0)
        separatorStore.commandStarted(
            row: 1, promptRow: 0, command: "false", cwd: nil)
        _ = separatorStore.commandFinished(row: 1, exitCode: 1)
        resizeOverlay.refreshIfNeeded()
        check(resizeOverlay.visibleSeparatorLayerCountForTesting == 1
                && !resizeOverlay.needsDisplay,
              "block overlay: separators use cached layers without AppKit redraw")
        check(BlockOverlayView.wrappedLines("one two three", columns: 7)
                == ["one", "two", "three"]
                && BlockOverlayView.wrappedLines("abcdefgh", columns: 4)
                == ["abcd", "efgh"],
              "command assistance wraps on terminal columns")

        // A selection remains visible after mouse-up, but the completed
        // gesture must not remain armed. Window dragging can otherwise route a
        // later mouseDragged event to the focused surface and stretch it.
        let selectionSurface = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        selectionSurface.feed(text: "alpha\r\nbeta")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        func mouseEvent(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let firstRowY = selectionSurface.bounds.height
            - selectionSurface.cellSize.height / 2
        selectionSurface.mouseDown(with: mouseEvent(
            .leftMouseDown, NSPoint(x: 1, y: firstRowY)))
        selectionSurface.mouseDragged(with: mouseEvent(
            .leftMouseDragged,
            NSPoint(x: selectionSurface.cellSize.width * 4.5, y: firstRowY)))
        selectionSurface.mouseUp(with: mouseEvent(
            .leftMouseUp,
            NSPoint(x: selectionSurface.cellSize.width * 4.5, y: firstRowY)))
        let completedSelection = selectionSurface.selectedText()
        selectionSurface.mouseDragged(with: mouseEvent(
            .leftMouseDragged, NSPoint(x: 200, y: 1)))
        check(completedSelection == "alpha"
                && selectionSurface.selectedText() == completedSelection,
              "selection: unrelated window drag cannot extend completed selection")

        // Agent TUIs enable primary-button mouse reporting. A normal click
        // still belongs to the TUI, but a drag must remain the familiar native
        // select/copy gesture instead of disappearing into SGR mouse events.
        var reportedMouseBytes: [UInt8] = []
        selectionSurface.onSendToProcess = {
            reportedMouseBytes.append(contentsOf: $0)
        }
        selectionSurface.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        reportedMouseBytes.removeAll()
        selectionSurface.mouseDown(with: mouseEvent(
            .leftMouseDown, NSPoint(x: 1, y: firstRowY)))
        selectionSurface.mouseDragged(with: mouseEvent(
            .leftMouseDragged,
            NSPoint(x: selectionSurface.cellSize.width * 4.5, y: firstRowY)))
        selectionSurface.mouseUp(with: mouseEvent(
            .leftMouseUp,
            NSPoint(x: selectionSurface.cellSize.width * 4.5, y: firstRowY)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        check(selectionSurface.selectedText() == "alpha"
                && reportedMouseBytes.isEmpty,
              "agent mouse mode: dragging selects locally without reporting")

        reportedMouseBytes.removeAll()
        selectionSurface.mouseDown(with: mouseEvent(
            .leftMouseDown, NSPoint(x: 1, y: firstRowY)))
        selectionSurface.mouseUp(with: mouseEvent(
            .leftMouseUp, NSPoint(x: 1, y: firstRowY)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let reportedClick = String(decoding: reportedMouseBytes, as: UTF8.self)
        check(reportedClick.contains("\u{1b}[<0;")
                && reportedClick.contains("M")
                && reportedClick.contains("m"),
              "agent mouse mode: a plain click still reaches the TUI")
        selectionSurface.feed(text: "\u{1b}[?1000l\u{1b}[?1006l")
        selectionSurface.onSendToProcess = nil

        // Clicking the terminal after using Inspector controls must return the
        // responder chain to the terminal so Command-C/V route there.
        let focusHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let focusSurface = CmdyTerminalSurface(frame: focusHost.bounds)
        focusSurface.autoresizingMask = [.width, .height]
        let inspectorControl = NSTextField(frame: NSRect(x: 4, y: 4, width: 80, height: 22))
        focusHost.addSubview(focusSurface)
        focusHost.addSubview(inspectorControl)
        let focusWindow = NSWindow(
            contentRect: focusHost.bounds, styleMask: [.borderless],
            backing: .buffered, defer: false)
        focusWindow.contentView = focusHost
        _ = focusWindow.makeFirstResponder(inspectorControl)
        let focusClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(
                x: focusSurface.cellSize.width / 2,
                y: focusSurface.bounds.height - focusSurface.cellSize.height / 2),
            modifierFlags: [], timestamp: 0,
            windowNumber: focusWindow.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        focusSurface.mouseDown(with: focusClick)
        check(focusWindow.firstResponder === focusSurface,
              "clipboard shortcuts: a terminal click restores keyboard focus")
        focusWindow.close()

        let chromeSurface = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        chromeSurface.topContentInset = 24
        chromeSurface.feed(text: "chrome must not select")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        chromeSurface.mouseDown(with: mouseEvent(
            .leftMouseDown, NSPoint(x: 100, y: chromeSurface.bounds.height - 2)))
        chromeSurface.mouseDragged(with: mouseEvent(
            .leftMouseDragged, NSPoint(x: 200, y: 20)))
        chromeSurface.mouseUp(with: mouseEvent(
            .leftMouseUp, NSPoint(x: 200, y: 20)))
        check(chromeSurface.selectedText().isEmpty,
              "selection: top chrome drag never clamps to row zero")

        let linkSurface = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 480, height: 120))
        linkSurface.feed(text:
            "\u{1b}]8;;https://example.com/docs\u{7}docs\u{1b}]8;;\u{7} https://localhost:3200/path")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let linkRowY = linkSurface.bounds.height - linkSurface.cellSize.height / 2
        check(linkSurface.linkURL(at: NSPoint(
            x: linkSurface.cellSize.width * 1.5, y: linkRowY))?.absoluteString
                == "https://example.com/docs",
              "links: OSC 8 cells resolve under the pointer")
        check(linkSurface.linkURL(at: NSPoint(
            x: linkSurface.cellSize.width * 12.5, y: linkRowY))?.absoluteString
                == "https://localhost:3200/path",
              "links: printed URLs resolve under the pointer")
        var openedLink: URL?
        linkSurface.onOpenLink = { openedLink = $0 }
        let commandClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: linkSurface.cellSize.width * 1.5, y: linkRowY),
            modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        linkSurface.mouseDown(with: commandClick)
        check(openedLink?.absoluteString == "https://example.com/docs",
              "links: command-click activates the hovered terminal link")

        // Config file parsing
        let kv = ConfigFile.parse("""
        # comment
        theme = Tokyo Night
        font-family = "JetBrains Mono"
        font-size=14
        blur = true
        automatic-error-help = true
        """)
        check(kv["theme"] == "Tokyo Night", "config: spaces in values")
        check(kv["font-family"] == "JetBrains Mono", "config: quoted values unwrapped")
        check(kv["font-size"] == "14", "config: no-space key=value")
        check(kv["blur"] == "true" && kv["comment"] == nil, "config: comments skipped")
        check(kv["automatic-error-help"] == "true", "config: automatic help flag parses")
        let defaultConfig = ConfigFile.parse(ConfigFile.template())
        check(defaultConfig["hide-toolbar"] == nil
                && defaultConfig["window-buttons"] == nil,
              "config: retired toolbar and button-style options stay absent")

        // Config write-back (menu changes persist into the file)
        let cfg = "# header comment\ntheme = One Dark\n\n# shader comment\nshader = CRT"
        let swapped = ConfigFile.rewriting(cfg, key: "shader", value: "Neon")
        check(swapped.contains("shader = Neon") && !swapped.contains("shader = CRT"),
              "writeback: replaces value in place")
        check(swapped.contains("# header comment") && swapped.contains("# shader comment"),
              "writeback: comments survive")
        check(ConfigFile.parse(swapped)["theme"] == "One Dark", "writeback: other keys untouched")
        let appended = ConfigFile.rewriting(cfg, key: "sounds", value: "true")
        check(ConfigFile.parse(appended)["sounds"] == "true", "writeback: missing key appended")
        check(ConfigFile.rewriting("theme=C64", key: "theme", value: "Nord").contains("theme = Nord"),
              "writeback: matches no-space key=value")

        // Session-save sanitizer: no snowballing restores, no saved banner.
        let stale = "old stuff\n── restored session ──\nterm64 v1  ·  (c) 2026\n ██ \nReady!\n\nreal command\noutput"
        let clean = TerminalPane.sanitizeForSave(stale)
        check(!clean.contains("restored session") && !clean.contains("old stuff"),
              "session save: stale restore layers dropped")
        check(!clean.contains("term64 v1") && !clean.contains("Ready!"),
              "session save: banner block dropped")
        check(clean == "real command\noutput", "session save: real content kept")

        // Palette fuzzy matching
        check(CommandPalette.fuzzyScore(query: "thdra", target: "Theme: Dracula") != nil, "fuzzy: subsequence hits")
        check(CommandPalette.fuzzyScore(query: "xyz", target: "Theme: Dracula") == nil, "fuzzy: miss -> nil")
        let sTheme = CommandPalette.fuzzyScore(query: "theme", target: "Theme: Nord") ?? 0
        let sLoose = CommandPalette.fuzzyScore(query: "theme", target: "The Command Palette Elephant") ?? 0
        check(sTheme > sLoose, "fuzzy: word-start beats scattered")

        // Ghost-text history suggestions
        let hist = HistoryStore(commands: [])
        hist.record("git status")
        hist.record("git push origin main")
        hist.record("echo done")
        check(hist.suggestion(for: "git pu") == "git push origin main", "history: prefix match")
        check(hist.suggestion(for: "echo done") == nil, "history: exact match -> nil")
        check(hist.suggestion(for: "g") == nil, "history: 1-char prefix -> nil")
        hist.record("git print")   // newer than push
        check(hist.suggestion(for: "git p") == "git print", "history: most recent wins")
        hist.record("definitely-not-a-real-command")
        hist.reject("definitely-not-a-real-command")
        check(hist.suggestion(for: "definitely") == nil, "history: failed command removed")
        let contextualHistory = HistoryStore(commands: ["cd tmp", "cd _projects"])
        check(contextualHistory.suggestion(for: "cd ", cwd: "/") == "cd tmp",
              "history: invalid cd suggestion skipped for cwd")
        check(TerminalPane.isGhostAcceptanceKey(keyCode: 48, modifiers: [])
              && TerminalPane.isGhostAcceptanceKey(keyCode: 124, modifiers: [])
              && !TerminalPane.isGhostAcceptanceKey(keyCode: 48, modifiers: [.shift]),
              "history: Tab and right arrow accept ghost text")
        let ghostFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let zero = ghostFont.glyph(withName: "zero")
        let ghostCellWidth = ghostFont.advancement(forGlyph: zero).width
        check(BlockOverlayView.ghostColumnOffsets(
            for: "....", font: ghostFont, cellWidth: ghostCellWidth) == [0, 1, 2, 3],
              "ghost text: repeated periods keep one terminal cell each")
        let rowTextLayout = TerminalRowTextLayout()
        let appKitBaselineOffset =
            NSLayoutManager().defaultBaselineOffset(for: ghostFont)
        let rendererBaseline: CGFloat = 23.5
        let rowTop: CGFloat = 7
        let appKitOrigin = rowTextLayout.drawOriginY(
            rowTop: rowTop,
            baselineFromTop: rendererBaseline,
            font: ghostFont)
        check(abs(appKitOrigin + appKitBaselineOffset
                  - (rowTop + rendererBaseline)) < 0.001,
              "row text: overlays preserve the renderer baseline")

        // Agent step parsing
        let step = AgentStep.parse("""
        {"thought": "list files first", "command": "ls -la", "done": false}
        """)
        check(step?.command == "ls -la" && step?.done == false, "agent: parses step JSON")
        let fenced = AgentStep.parse("```json\n{\"thought\": \"t\", \"done\": true, \"summary\": \"all good\"}\n```")
        check(fenced?.done == true && fenced?.summary == "all good" && fenced?.command == nil,
              "agent: fenced final step")
        check(AgentStep.parse("not json") == nil, "agent: garbage -> nil")

        // AI command sanitizing
        check(LLMClient.sanitizeCommand("```sh\nls -la\n```") == "ls -la", "sanitize: fences stripped")
        check(LLMClient.sanitizeCommand("$ git status") == "git status", "sanitize: $-prompt stripped")
        check(LLMClient.sanitizeCommand("  du -sh .  ") == "du -sh .", "sanitize: trimmed")

        // Error help always has a useful, private fallback even when neither
        // an on-device nor configured model is available.
        let missing = ErrorAssistant.deterministicExplanation(
            command: "does-not-exist", output: "zsh: command not found: does-not-exist",
            exitCode: 127, cwd: "/tmp")
        check(missing.contains("does-not-exist") && missing.contains("PATH"),
              "error assistant: command-not-found fallback is actionable")
        let wrappedMissing = ErrorAssistant.deterministicExplanation(
            command: "cmdy_inline_missing_command_xyz",
            output: "zsh: command not found: cmdy_inli\nne_missing_command_xyz",
            exitCode: 127, cwd: nil)
        check(wrappedMissing.contains("cmdy_inline_missing_command_xyz"),
              "error assistant: semantic command survives wrapped diagnostics")
        let occupied = ErrorAssistant.deterministicExplanation(
            command: "npm run dev", output: "Error: listen EADDRINUSE: address already in use :::5173",
            exitCode: 1, cwd: "/tmp")
        check(occupied.contains("5173") && occupied.contains("already in use"),
              "error assistant: occupied port is identified")
        let interrupted = ErrorAssistant.deterministicExplanation(
            command: "make", output: "", exitCode: 130, cwd: nil)
        check(interrupted.contains("Control-C") && interrupted.contains("cancellation"),
              "error assistant: interruption is not mislabeled as failure")
        check(ErrorAssistant.normalizeExplanation("## **Cause**\nRun `git status`")
                == "Run git status",
              "error assistant: model formatting is normalized to plain text")
        check(!ErrorAssistant.hasDiagnosticEvidence("  \n\t"),
              "error assistant: silent failures never invite model speculation")
        check(!ErrorAssistant.isGroundedExplanation(
            "Create a new account and reinstall Xcode.",
            evidence: "Signing requires a development team."),
              "error assistant: unsupported model remediation is rejected")
        check(ErrorAssistant.isGroundedExplanation(
            "The build requires a development team for signing.",
            evidence: "Signing requires a development team."),
              "error assistant: grounded model explanation is accepted")
        check(!ErrorAssistant.isGroundedExplanation(
            "The network connection failed.",
            evidence: "Signing requires a development team."),
              "error assistant: unrelated model explanation is rejected")
        check(!ErrorAssistant.isGroundedExplanation(
            "The diagnostic hint says signing requires a team.",
            evidence: "Signing requires a development team."),
              "error assistant: leaked prompt vocabulary is rejected")
        check(ErrorAssistant.isNaturalLanguageRequest("what time is it")
                && !ErrorAssistant.isNaturalLanguageRequest("git status")
                && !ErrorAssistant.isNaturalLanguageRequest("echo hello?"),
              "assistant router distinguishes natural-language requests")
        check(ErrorAssistant.deterministicCommand(for: "What time is it?") == "date"
                && ErrorAssistant.deterministicCommand(for: "where am I") == "pwd",
              "assistant router keeps universal requests deterministic")
        check(ErrorAssistant.normalizedCommand("zsh: nope: command not found") == nil
                && ErrorAssistant.normalizedCommand("date") == "date",
              "assistant rejects diagnostics masquerading as commands")
        check(ErrorAssistant.deterministicFixCommand(
                command: "gti status", output: "zsh: command not found: gti", exitCode: 127)
                == "git status"
                && ErrorAssistant.deterministicFixCommand(
                    command: "assssssd", output: "zsh: command not found: assssssd",
                    exitCode: 127) == nil,
              "assistant only corrects confident executable typos")
        check(ErrorAssistant.validatedFixCommand(
                "lsof -nP -iTCP:5173 -sTCP:LISTEN", original: "npm run dev",
                evidence: "EADDRINUSE: address already in use :::5173") != nil
                && ErrorAssistant.validatedFixCommand(
                    "ls /definitely-not-a-real-cmdy-dir", original: "make",
                    evidence: "error: build failed") == nil
                && ErrorAssistant.validatedFixCommand(
                    "rm -rf build", original: "make", evidence: "error: build failed") == nil,
              "assistant exposes only grounded non-destructive fixes")
        check(TerminalPane.assistantRequest(from: "what time is it") == "what time is it"
                && TerminalPane.assistantRequest(from: "# convert this to json")
                    == "convert this to json"
                && TerminalPane.assistantRequest(from: "? convert this to json") == nil
                && TerminalPane.assistantRequest(from: "git status") == nil,
              "assistant routes clear natural language without a prefix")
        check(IntegrationDoctor.matches("setup the browser MCP")
                && IntegrationDoctor.matches("fix sim mirror permissions")
                && IntegrationDoctor.matches("check Bridge integration")
                && !IntegrationDoctor.matches("convert this to json"),
              "integration doctor routes setup requests without swallowing normal AI prompts")
        check(IntegrationDoctor.clientForLaunchCommand(" claude ") == .claude
                && IntegrationDoctor.clientForLaunchCommand("codex") == .codex
                && IntegrationDoctor.clientForLaunchCommand("pi") == .pi
                && IntegrationDoctor.clientForLaunchCommand("codex mcp list") == nil,
              "integration preflight recognizes only direct interactive agent launches")
        let permissionFixture: [String: Any] = [
            "permissions": [
                "defaultMode": "dontAsk",
                "allow": ["Bash(git status)"],
            ],
            "theme": "dark",
        ]
        let browserMCP = ProductIdentity.current.mcpServerName("browser")
        let bridgeMCP = ProductIdentity.current.mcpServerName("bridge")
        let browserRegistrationNames = IntegrationDoctor.integrations
            .first(where: { $0.key == "browser" })?.registrationNames ?? []
        let bridgeRegistrationNames = IntegrationDoctor.integrations
            .first(where: { $0.key == "bridge" })?.registrationNames ?? []
        check(browserRegistrationNames == [
                "cmdy-browser", "termite-browser", "term64-browser",
            ]
                && bridgeRegistrationNames == [
                    "cmdy-bridge", "termite-bridge", "term64-bridge", "bridge",
                ],
              "integration doctor replaces legacy MCP registrations after a rename")
        let browserRule = "mcp__\(browserMCP)__*"
        let bridgeRule = "mcp__\(bridgeMCP)__*"
        let permissionUpdated = IntegrationDoctor.addingClaudePermissionRules(
            to: permissionFixture,
            rules: [browserRule, browserRule, bridgeRule])
        let permissionAllow = (permissionUpdated["permissions"] as? [String: Any])?["allow"]
            as? [String] ?? []
        check(permissionAllow.contains("Bash(git status)")
                && permissionAllow.filter { $0 == browserRule }.count == 1
                && permissionAllow.contains(bridgeRule)
                && permissionUpdated["theme"] as? String == "dark",
              "integration doctor preserves Claude settings and adds idempotent allow rules")
        check(IntegrationDoctor.codexRegistrationMatches(
                """
                [mcp_servers.\(browserMCP)]
                command = "node"
                args = ["/tmp/browser/mcp/index.js"]
                [notice]
                hide = true
                """,
                name: browserMCP, shim: "/tmp/browser/mcp/index.js")
                && !IntegrationDoctor.codexRegistrationMatches(
                    "[mcp_servers.\(browserMCP)]\nargs = [\"/old/index.js\"]",
                    name: browserMCP, shim: "/tmp/browser/mcp/index.js"),
              "integration doctor rejects stale Codex MCP paths")

        check(TerminalWindowController.flushTopContentInset(
                measuredChrome: 28, toolbarBand: 28) == 28
                && TerminalWindowController.flushTopContentInset(
                    measuredChrome: 0, toolbarBand: 28) == 28
                && TerminalWindowController.flushTopContentInset(
                    measuredChrome: 28, toolbarBand: 28,
                    contentSpacing: 8) == 36,
              "flush chrome: workspace spacing follows toolbar clearance")
        check(TerminalWindowController.embeddedBrowserTopContentInset(
                toolbarBand: 40, titleBandVisible: true,
                backingScale: 2) == 40.5
                && TerminalWindowController.embeddedBrowserTopContentInset(
                    toolbarBand: 40, titleBandVisible: false,
                    backingScale: 2) == 0,
              "embedded browser: toolbar clearance adds one device pixel")

        let sourceFrame = NSRect(x: 100, y: 200, width: 860, height: 540)
        let nextFrame = AppDelegate.cascadedWindowFrame(
            from: sourceFrame,
            visibleFrame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080))
        check(nextFrame.size == sourceFrame.size
                && nextFrame.origin.x == sourceFrame.origin.x + 24
                && nextFrame.origin.y == sourceFrame.origin.y - 24,
              "new window: inherits size and cascades right/down")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
