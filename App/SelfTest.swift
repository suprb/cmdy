import AppKit
import ProductIdentity
import Foundation
import CmdyKit
import CmdyCore

/// Headless sanity checks for the pure logic that can't be eyeballed in the GUI
/// (OSC 133 parsing + BlockStore state machine). Run with: cmdy --selftest
@MainActor
enum SelfTest {
    /// Runs the main run loop until `condition` holds or two seconds pass.
    /// Layout and snapshot publication complete asynchronously, and hosted
    /// CI machines can need more than one short turn to deliver them.
    static func settle(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            print("\(cond ? "ok  " : "FAIL") \(name)")
            if !cond { failures += 1 }
        }

        CmdySurfaceContractHarness.run(check)
        CmdyShaperProceduralColorHarness.run(check)
        CmdyShaperPendingRunHarness.run(check)
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
        // A standalone pane has no window controller to forward preference
        // changes, so apply them directly as the controller would.
        panelPane.applyPreferences()
        check(panelPane.surface.bottomContentInset == Preferences.shared.contentMargin,
              "inline panel: dismissal preserves the edge margin without restoring stale panel height")
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
        check(Preferences.defaultThemeName == "Tokyo Night"
                && Preferences.defaultFontName == "FragmentMono-Regular"
                && Preferences.defaultFontSize == 13,
              "first-launch appearance defaults stay canonical")
        if ProductIdentity.current.environmentValue("DEFAULTS_DOMAIN") != nil {
            let defaults = Preferences.shared
            check(defaults.themeName == "Tokyo Night" && defaults.theme.name == "Tokyo Night",
                  "isolated first launch resolves the Tokyo Night theme")
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
            check(!defaults.workspaceNavigatorVisible
                    && !defaults.workspaceInspectorVisible
                    && !TerminalWindowController.embeddedBrowserStartsVisible,
                  "first launch starts without sidebar, browser, or inspector")
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

        // Pane, tab and window keys (tmux-style, Ctrl+Space prefix).
        func paneRoot(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags,
                         command: Bool = false) -> String {
            PaneKeys.root(keyCode: keyCode, modifiers: modifiers, usesCommand: command)
                .map { String(describing: $0) } ?? "nil"
        }
        func panePrefix(_ characters: String, _ keyCode: UInt16 = 0,
                           _ modifiers: NSEvent.ModifierFlags = []) -> String {
            PaneKeys.afterPrefix(keyCode: keyCode, characters: characters, modifiers: modifiers)
                .map { String(describing: $0) } ?? "nil"
        }
        check(paneRoot(36, [.option]) == "splitDown"
                && paneRoot(36, [.option, .shift]) == "splitRight"
                && paneRoot(53, [.option]) == "closeSurface",
              "pane keys: Alt+Enter splits down, Alt+Shift+Enter right, Alt+Esc closes")
        check(paneRoot(123, [.control, .option]).hasPrefix("focus(")
                && paneRoot(123, [.control, .option]).hasSuffix("left)"),
              "pane keys: Ctrl+Alt+Left focuses the pane on the left")
        check(paneRoot(124, [.control, .option, .shift]).hasPrefix("resizeCells(")
                && paneRoot(124, [.control, .option, .shift]).hasSuffix("right, 5)"),
              "pane keys: Ctrl+Alt+Shift+Right resizes five cells")
        check(paneRoot(20, [.option]) == "tab(2)" && paneRoot(25, [.option]) == "tab(8)"
                && paneRoot(123, [.option]) == "previousTab"
                && paneRoot(124, [.option]) == "nextTab"
                && paneRoot(123, [.option, .shift]) == "moveTab(-1)"
                && paneRoot(124, [.option, .shift]) == "moveTab(1)"
                && paneRoot(126, [.option]) == "switchWindow(-1)"
                && paneRoot(125, [.option]) == "switchWindow(1)",
              "pane keys: Alt+1..9, Alt+arrows and Alt+Shift+arrows drive tabs and windows")
        check(paneRoot(0, [.option]) == "nil" && paneRoot(36, []) == "nil"
                && paneRoot(36, [.command]) == "nil",
              "pane keys: unbound keys still reach the terminal")
        check(paneRoot(36, [.command], command: true) == "splitDown"
                && paneRoot(36, [.command, .shift], command: true) == "splitRight"
                && paneRoot(53, [.command], command: true) == "closeSurface"
                && paneRoot(20, [.command], command: true) == "tab(2)"
                && paneRoot(126, [.command], command: true) == "switchWindow(-1)"
                && paneRoot(123, [.command, .shift], command: true) == "moveTab(-1)"
                && paneRoot(123, [.control, .command], command: true).hasPrefix("focus(")
                && paneRoot(124, [.control, .command, .shift], command: true)
                    .hasPrefix("resizeCells("),
              "pane keys on Cmd: Cmd takes Alt's place")
        check(paneRoot(123, [.command], command: true) == "nil"
                && paneRoot(124, [.command], command: true) == "nil"
                && paneRoot(36, [.option], command: true) == "nil"
                && paneRoot(36, [.command, .option], command: true) == "nil",
              "pane keys on Cmd: Cmd+Left/Right stay line moves and Alt is free")
        // The menu bar shows the pane keys; each shown key must do what the item says.
        for command in [false, true] {
            let keyCodes: [String: UInt16] = ["\r": 36, "\u{1b}": 53,
                "\u{F702}": 123, "\u{F703}": 124, "\u{F700}": 126, "\u{F701}": 125]
            let all = PaneKeyMenu.paneItems() + PaneKeyMenu.windowItems()
            PaneKeyMenu.refresh(usesCommand: command)
            let items = all.filter { !$0.isSeparatorItem && !$0.keyEquivalent.isEmpty }
            let wrong = items.filter { item in
                guard let code = keyCodes[item.keyEquivalent],
                      let action = item.representedObject as? StandardKeybindings.Action
                else { return true }
                return paneRoot(code, item.keyEquivalentModifierMask, command: command)
                    != String(describing: action)
            }.map(\.title)
            check(items.count >= (command ? 11 : 13) && wrong.isEmpty,
                  "pane-key menu items show the key that runs them (\(command ? "Cmd" : "Alt"))"
                    + (wrong.isEmpty ? "" : ": \(wrong)"))
        }
        PaneKeyMenu.refresh()
        check(PaneKeys.isPrefix(keyCode: 49, modifiers: [.control])
                && !PaneKeys.isPrefix(keyCode: 49, modifiers: [.control, .shift])
                && panePrefix(" ", 49, [.control]) == "send(\"\\0\")",
              "pane keys: Ctrl+Space is the prefix and twice sends it through")
        check(panePrefix("h") == "splitDown" && panePrefix("v") == "splitRight"
                && panePrefix("x") == "closeSurface" && panePrefix("z") == "splitZoom"
                && panePrefix(";") == "lastPane"
                && panePrefix("!", 18, [.shift]) == "breakPaneToTab"
                && panePrefix("@", 19, [.shift]) == "joinTabLeft",
              "pane keys: prefix pane keys, break (!) and join (@)")
        check(panePrefix("c") == "newTab" && panePrefix("r") == "renameTab"
                && panePrefix("k") == "closeTab" && panePrefix("9") == "tab(8)"
                && panePrefix("C", 8, [.shift]) == "newWindow"
                && panePrefix("K", 40, [.shift]) == "closeWindow"
                && panePrefix("N", 45, [.shift]) == "switchWindow(1)"
                && panePrefix("?", 44, [.shift]) == "keymapHelp"
                && panePrefix("y") == "nil",
              "pane keys: prefix tab and window keys; unbound prefix keys do nothing")

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
        runTerminalInputChecks(check)
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
        // Captured styles resolve semantic colors to immutable sRGB values.
        // Compare every rendered channel under the same surface appearance;
        // NSDynamicSystemColor object equality is not pixel equality.
        func resolvedFailureColorMatches(_ actual: NSColor?, _ expected: NSColor) -> Bool {
            var matches = false
            failedSurface.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let actual = actual?.usingColorSpace(.sRGB),
                      let expected = expected.usingColorSpace(.sRGB) else { return }
                matches = actual.redComponent == expected.redComponent
                    && actual.greenComponent == expected.greenComponent
                    && actual.blueComponent == expected.blueComponent
                    && actual.alphaComponent == expected.alphaComponent
            }
            return matches
        }
        check(resolvedFailureColorMatches(failedForeground, failedSurface.failedBlockForegroundColor),
              "failed row: text uses failure color")
        check(resolvedFailureColorMatches(failedBackground, failedSurface.failedBlockBackgroundColor),
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
        let selectionPasteboard = NSPasteboard.withUniqueName()
        defer { selectionPasteboard.releaseGlobally() }
        selectionSurface.selectionPasteboard = selectionPasteboard
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
        check(!Preferences.shared.copyOnSelect
                || selectionPasteboard.string(forType: .string) == "alpha",
              "selection: copy-on-select puts a finished drag on the clipboard")

        // A click that wobbles inside the pressed cell is still a click: it
        // dismisses the selection instead of leaving a one-cell selection.
        selectionSurface.mouseDown(with: mouseEvent(
            .leftMouseDown, NSPoint(x: selectionSurface.cellSize.width * 2.3, y: firstRowY)))
        selectionSurface.mouseDragged(with: mouseEvent(
            .leftMouseDragged,
            NSPoint(x: selectionSurface.cellSize.width * 2.6, y: firstRowY + 1)))
        selectionSurface.mouseUp(with: mouseEvent(
            .leftMouseUp,
            NSPoint(x: selectionSurface.cellSize.width * 2.6, y: firstRowY + 1)))
        check(selectionSurface.selectedText().isEmpty,
              "selection: a click that wobbles within one cell clears the selection")

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
        selectionSurface.mouseDragged(with: mouseEvent(
            .leftMouseDragged, NSPoint(x: 2, y: firstRowY + 1)))
        selectionSurface.mouseUp(with: mouseEvent(
            .leftMouseUp, NSPoint(x: 2, y: firstRowY + 1)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let reportedClick = String(decoding: reportedMouseBytes, as: UTF8.self)
        check(reportedClick.contains("\u{1b}[<0;")
                && reportedClick.contains("M")
                && reportedClick.contains("m"),
              "agent mouse mode: a plain click still reaches the TUI")
        check(selectionSurface.selectedText().isEmpty,
              "agent mouse mode: a plain click dismisses the local selection")
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
        let shellLikeNames = ["where git", "who -a", "help set", "show logs",
                              "please deploy", "what time is it", "git status",
                              "echo hello?", "where() { command -v \"$@\"; }"]
        check(shellLikeNames.allSatisfy { TerminalPane.assistantRequest(from: $0) == nil },
              "assistant leaves builtins, aliases, functions, and unprefixed input to the shell")
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
        check(TerminalPane.assistantRequest(from: "# convert this to json")
                    == "convert this to json"
                && TerminalPane.assistantRequest(from: "  # what time is it  ") == "what time is it"
                && TerminalPane.assistantRequest(from: "#") == nil
                && TerminalPane.assistantRequest(from: "# first\nsecond") == nil
                && TerminalPane.assistantRequest(from: "? convert this to json") == nil
                && TerminalPane.assistantRequest(from: "git status") == nil,
              "assistant requires an explicit single-line request")
        let shellFailure = ErrorAssistant.deterministicExplanation(
            command: "where missing", output: "missing not found", exitCode: 1, cwd: nil)
        check(!shellFailure.contains("sentence") && !shellFailure.contains("translate"),
              "automatic error help does not reinterpret a shell command as natural language")
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
        let browserChrome = EmbeddedChromiumViewController()
        browserChrome.applyTheme(.c64)
        check(browserChrome.chromeBackground == Theme.c64.background,
              "embedded browser: chrome inherits the active window theme")
        check(EmbeddedChromiumRuntime.applicationTerminationWaitMilliseconds == 0,
              "embedded browser: app termination never blocks for CEF shutdown")

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

    private static func runTerminalInputChecks(_ check: (Bool, String) -> Void) {
        func flushInput() { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
        func key(_ text: String, code: UInt16, window: NSWindow?,
                 modifiers: NSEvent.ModifierFlags = [], unmodified: String? = nil) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: text, charactersIgnoringModifiers: unmodified ?? text,
                isARepeat: false, keyCode: code)!
        }

        let controller = TerminalWindowController(cwd: "/tmp", startShells: false)
        let pane = controller.panes[0]
        let surface = pane.surface as! CmdyTerminalSurface
        let window = controller.window!
        defer { pane.shutdown(); window.close() }
        var sent: [UInt8] = []
        let observeInput = surface.onSendToProcess
        surface.onSendToProcess = { bytes in observeInput?(bytes); sent.append(contentsOf: bytes) }
        var requests: [String] = []
        pane.onAskRequested = { _, request in requests.append(request) }
        let bar = pane.presentExtensionControlBar()
        var submitted: String?
        bar.configure(actions: [], placeholder: "URL")
        bar.onSubmit = { submitted = $0 }
        surface.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
        flushInput()
        bar.focusInput()
        for character in "# field request" {
            let event = key(String(character), code: 0, window: window)
            if let routed = pane.handleTerminalKeyEvent(event) { bar.keyDown(with: routed) }
        }
        let enter = key("\r", code: 36, window: window)
        if let routed = pane.handleTerminalKeyEvent(enter) { bar.keyDown(with: routed) }
        flushInput()
        check(submitted == "# field request" && requests.isEmpty && sent.isEmpty,
              "input ownership: control-bar typing and Return stay out of shell hooks")
        pane.dismissExtensionControlBar(bar)
        pane.focus()

        // Shell decorations index the normal screen. A full-screen program on
        // the alternate screen (herdr, vim) must not inherit failed-row tints.
        surface.feed(text: "\u{1b}]133;C\u{7}missing\r\n\u{1b}]133;D;1\u{7}\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
        flushInput()
        pane.updateBlockStyles()
        let failedOnShell = !surface.failedBlockRows.isEmpty
        surface.feed(text: "\u{1b}[?1049h")
        flushInput()
        pane.updateBlockStyles()
        pane.blockOverlayForTesting.blockDataChanged()
        check(failedOnShell && surface.failedBlockRows.isEmpty
                && pane.blockOverlayForTesting.visibleSeparatorLayerCountForTesting == 0,
              "blocks: failed rows and separators stay off the alternate screen")

        // A stale/replaced draft cannot turn a TUI's Return into a shell Ask.
        pane.replacePromptInput(with: "# tui request")
        flushInput()
        sent.removeAll()
        if let routed = pane.handleTerminalKeyEvent(enter) { surface.keyDown(with: routed) }
        flushInput()
        check(requests.isEmpty && sent == [0x0D],
              "input ownership: alternate-screen Return reaches the application")
        surface.feed(text: "\u{1b}[?1049l\r\n\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
        flushInput()
        pane.updateBlockStyles()
        check(!surface.failedBlockRows.isEmpty, "blocks: failed rows return with the normal screen")
        sent.removeAll()

        // The physical romanization key is not a committed shell character.
        _ = pane.handleTerminalKeyEvent(key("n", code: 45, window: window))
        let beforeComposition = pane.workspaceResumeInputRevision
        surface.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        let compositionEnter = pane.handleTerminalKeyEvent(enter)
        check(compositionEnter != nil && requests.isEmpty && sent.isEmpty,
              "input ownership: IME Return is left to the input method")
        check(pane.closeState.hasDraftInput && !pane.canSafelyStageAtEmptyPrompt
                && pane.workspaceResumeInputRevision > beforeComposition,
              "IME: preedit protects close and invalidates an earlier Resume handoff")
        surface.insertText("# 日本", replacementRange: surface.markedRange())
        _ = pane.handleTerminalKeyEvent(enter)
        flushInput()
        check(requests == ["日本"] && String(decoding: sent, as: UTF8.self) == "# 日本\u{15}",
              "input ownership: composed text updates the shell draft exactly once")

        let pasteController = TerminalWindowController(cwd: "/tmp", startShells: false)
        let pastePane = pasteController.panes[0]
        let pasteSurface = pastePane.surface as! CmdyTerminalSurface
        let pasteWindow = pasteController.window!
        defer { pastePane.shutdown(); pasteWindow.close() }
        pastePane.focus()
        pasteSurface.feed(text: "first\r\nsecond\u{1b}[?2004h")
        flushInput()
        pasteSurface.setSelectionForTesting(
            anchor: .init(row: 0, col: 0), active: .init(row: 1, col: 5))
        let selectedPaste = pasteSurface.selectedText()
        var pasteBytes: [UInt8] = []
        var pasteInputs: [String] = []
        var pasteCommits: [String] = []
        pasteSurface.onSendToProcess = { pasteBytes.append(contentsOf: $0) }
        pasteSurface.onTextInputCommitted = { pasteCommits.append($0) }
        pasteSurface.onPasteRequest = { pasteInputs.append($0); return "handled\ntext" }
        let delegate = AppDelegate()
        let bindings = StandardKeybindings(delegate: delegate, importedMappings: [:])
        defer { withExtendedLifetime(delegate) { bindings.invalidate() } }
        let pasteSelection = key("v", code: 9, window: pasteWindow, modifiers: [.command, .shift])
        let pasteRouted = bindings.handle(pasteSelection)
        flushInput()
        check(selectedPaste.hasPrefix("first") && selectedPaste.hasSuffix("\nsecond")
                && pasteRouted && pasteInputs == [selectedPaste] && pasteCommits.isEmpty
                && String(decoding: pasteBytes, as: UTF8.self) == "\u{1b}[200~handled\ntext\u{1b}[201~",
              "selection paste: real shortcut applies policy and bracketed-paste framing")
        pasteBytes.removeAll()
        pasteSurface.onPasteRequest = { _ in nil }
        _ = bindings.handle(pasteSelection)
        flushInput()
        check(pasteBytes.isEmpty, "selection paste: a cancelled paste sends no bytes")

        let foreignWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        foreignWindow.isReleasedWhenClosed = false
        defer { foreignWindow.close() }
        let foreignDelete = key("\u{7f}", code: 51, window: foreignWindow, modifiers: [.command])
        check(pastePane.isTerminalFocused
                && StandardKeybindings.terminalController(eventWindow: foreignWindow, keyWindow: pasteWindow) == nil
                && StandardKeybindings.terminalController(eventWindow: nil, keyWindow: pasteWindow) === pasteController
                && !bindings.handle(foreignDelete) && pasteBytes.isEmpty,
              "input ownership: a foreign window cannot edit the retained terminal responder")

        var commits: [String] = []
        pasteSurface.onTextInputCommitted = { commits.append($0) }
        pasteSurface.setMarkedText("日本🙂", selectedRange: NSRange(location: 2, length: 2),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = pasteSurface.markedTextPresentationForTesting
        let candidate = pasteSurface.firstRect(forCharacterRange: NSRange(location: 2, length: 0),
                                               actualRange: nil)
        check(pasteSurface.hasMarkedText() && pasteSurface.markedRange().length == 4
                && pasteSurface.selectedRange() == NSRange(location: 2, length: 2)
                && marked?.text == "日本🙂" && candidate.width > 0 && candidate.height > 0
                && pasteBytes.isEmpty && commits.isEmpty,
              "IME: marked Unicode text is visible with candidate geometry and no PTY bytes")
        pasteSurface.feed(text: "\r\noutput while composing")
        flushInput()
        let preeditMoved = settle {
            let moved = pasteSurface.markedTextPresentationForTesting
            return moved?.frame != marked?.frame && moved?.text == "日本🙂"
        }
        check(preeditMoved,
              "IME: preedit follows the cursor when terminal output moves it")
        pasteSurface.insertText(NSAttributedString(string: "日本🙂"),
                                replacementRange: pasteSurface.markedRange())
        flushInput()
        check(!pasteSurface.hasMarkedText() && pasteSurface.markedTextPresentationForTesting == nil
                && commits == ["日本🙂"] && String(decoding: pasteBytes, as: UTF8.self) == "日本🙂",
              "IME: commit emits Unicode once without submitting a command")
        pasteBytes.removeAll()
        let beforeCancellation = pastePane.workspaceResumeInputRevision
        pasteSurface.setMarkedText("discard", selectedRange: NSRange(location: 7, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: pasteWindow)
        flushInput()
        check(!pasteSurface.hasMarkedText() && pasteBytes.isEmpty
                && pastePane.workspaceResumeInputRevision > beforeCancellation,
              "IME: changing windows cancels composition without typing into the old pane")
        pasteSurface.setMarkedText("discard", selectedRange: NSRange(location: 7, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        pastePane.addSubview(field)
        _ = pasteWindow.makeFirstResponder(field)
        flushInput()
        check(!pasteSurface.hasMarkedText() && pasteBytes.isEmpty,
              "IME: focusing a native field cancels preedit without committing it")
        field.removeFromSuperview()
        pastePane.focus()
        pasteSurface.setMarkedText("interrupt", selectedRange: NSRange(location: 9, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        pasteSurface.handleUnhandledCompositionKey(key("\r", code: 36, window: pasteWindow))
        check(pasteSurface.hasMarkedText() && pasteBytes.isEmpty,
              "IME: an unhandled candidate Return does not submit to the terminal")
        pasteSurface.handleUnhandledCompositionKey(
            key("\u{3}", code: 8, window: pasteWindow, modifiers: [.control], unmodified: "c"))
        flushInput()
        check(!pasteSurface.hasMarkedText() && pasteBytes == [0x03] && commits == ["日本🙂"],
              "IME: an unhandled Ctrl-C cancels preedit and sends exactly one interrupt")
        pasteBytes.removeAll()
        pasteSurface.feed(text: "\u{1b}[\(pasteSurface.engine.cols)G")
        flushInput()
        let cursorRange = NSRange(location: 0, length: 0)
        let unmarkedCursor = pasteSurface.firstRect(forCharacterRange: cursorRange, actualRange: nil)
        pasteSurface.setMarkedText(String(repeating: "candidate", count: 20),
                                   selectedRange: cursorRange,
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        pasteSurface.unmarkText()
        check(pasteSurface.firstRect(forCharacterRange: cursorRange, actualRange: nil) == unmarkedCursor,
              "IME: cancelling long preedit restores the cursor anchor near the right edge")
        pasteSurface.optionAsMetaKey = true
        pasteSurface.keyDown(with: key("å", code: 0, window: pasteWindow,
                                       modifiers: [.option], unmodified: "a"))
        pasteSurface.keyDown(with: key("\u{3}", code: 8, window: pasteWindow,
                                       modifiers: [.control], unmodified: "c"))
        pasteSurface.feed(text: "\u{1b}[>1u")
        pasteSurface.keyDown(with: key("\r", code: 36, window: pasteWindow, modifiers: [.shift]))
        flushInput()
        check(pasteBytes == [0x1B, 0x61, 0x03] + Array("\u{1b}[13;2u".utf8)
                && commits == ["日本🙂"],
              "IME: Meta, control, and enhanced Return keep terminal key encoding")
    }
}
