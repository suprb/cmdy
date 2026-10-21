import AppKit
import ProductIdentity
import CmdyKit
import CmdyNative
import Metal

// The independently signed helper app performs app-bundle replacement before
// AppKit is created. The replacement app acknowledges only after AppDelegate
// finishes launching, so a startup or Browser-runtime failure can still roll back.
if let helperExit = BrowserComponentInstaller.runHelperIfRequested(
    CommandLine.arguments) {
    exit(helperExit)
}

// cmdy — a native macOS GPU terminal turned platform.
// Foundation: the native CmdyCore engine and CmdyGPU renderer.

private enum CmdyTerminalCLI {
    static func run(_ arguments: [String]) -> Never {
        guard let command = arguments.first else {
            usage()
            exit(2)
        }
        switch command {
        case "show", "img":
            let paths = Array(arguments.dropFirst())
            guard !paths.isEmpty else {
                usage()
                exit(2)
            }
            var failed = false
            for rawPath in paths {
                let path = NSString(string: rawPath).expandingTildeInPath
                let url = URL(fileURLWithPath: path)
                do {
                    let data = try Data(contentsOf: url)
                    let name = Data(url.lastPathComponent.utf8).base64EncodedString()
                    write("\u{1B}]1337;File=inline=1;size=\(data.count);name=\(name):\(data.base64EncodedString())\u{7}\n")
                } catch {
                    writeError("cmdy: cannot show \(rawPath): \(error.localizedDescription)\n")
                    failed = true
                }
            }
            exit(failed ? 1 : 0)
        case "notify":
            let message = arguments.dropFirst().joined(separator: " ")
            write("\u{1B}]9;\(message.isEmpty ? "done" : message)\u{7}")
            exit(0)
        default:
            usage()
            exit(2)
        }
    }

    private static func usage() {
        writeError("usage: cmdy show <image...>\n")
        writeError("       cmdy notify [text]\n")
    }

    private static func write(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func writeError(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }
}

struct AppMenuShortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags
}

enum AppMenuShortcuts {
    static let newTextFile = AppMenuShortcut(
        key: "n", modifiers: [.command, .shift])
    static let workspaceNavigator = AppMenuShortcut(
        key: "n", modifiers: [.command, .option])
}

@MainActor
private func item(_ title: String, _ action: Selector?, _ key: String = "",
                  modifiers: NSEvent.ModifierFlags = [.command],
                  represented: Any? = nil, symbol: String? = nil) -> NSMenuItem {
    let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
    it.keyEquivalentModifierMask = modifiers
    it.representedObject = represented
    if let symbol {
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }
    it.target = nil   // route through the responder chain to AppDelegate / first responder
    it.cmdyApplyMenuIcon()
    return it
}

@MainActor
func populateFontMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(item("Browse with Preview…", #selector(AppDelegate.browseFonts(_:)), "", modifiers: []))
    menu.addItem(.separator())
    menu.addItem(item("System Mono", #selector(AppDelegate.setFontMenu(_:)), "", modifiers: [], represented: "System"))
    if !bundledFonts.isEmpty {
        menu.addItem(.separator())
        for bf in bundledFonts {
            menu.addItem(item(bf.displayName, #selector(AppDelegate.setFontMenu(_:)), "", modifiers: [], represented: bf.fontName))
        }
    }
    let systemCandidates = ["Menlo", "Monaco", "SF Mono", "SFMono-Regular", "Courier New", "PT Mono", "Andale Mono"]
    let installed = systemCandidates.filter { NSFont(name: $0, size: 13) != nil }
    if !installed.isEmpty {
        menu.addItem(.separator())
        for name in installed {
            menu.addItem(item(name, #selector(AppDelegate.setFontMenu(_:)), "", modifiers: [], represented: name))
        }
    }
}

@MainActor
private func buildMainMenu(delegate: AppDelegate) -> NSMenu {
    let main = NSMenu()
    let productName = ProductIdentity.current.displayName

    // Application menu
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(item(
        "About \(productName)", #selector(AppDelegate.showAboutPanel(_:))))
    appMenu.addItem(item(
        "Licenses and Notices…", #selector(AppDelegate.showLicensesAndNotices(_:))))
    appMenu.addItem(item(
        "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))))
    appMenu.addItem(.separator())
    appMenu.addItem(item("Settings…", #selector(AppDelegate.openSettings(_:)), ","))
    appMenu.addItem(item("Open Config File…", #selector(AppDelegate.openConfig(_:))))
    appMenu.addItem(item("Reload Config", #selector(AppDelegate.reloadConfig(_:)), ",", modifiers: [.command, .shift]))
    appMenu.addItem(.separator())
    appMenu.addItem(item(
        "Hide \(productName)", #selector(NSApplication.hide(_:)), "h"))
    appMenu.addItem(item(
        "Quit \(productName)", #selector(NSApplication.terminate(_:)), "q"))

    // File
    let fileItem = NSMenuItem()
    main.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    fileItem.submenu = fileMenu
    fileMenu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n",
                          symbol: "macwindow.badge.plus"))
    fileMenu.addItem(item("New Tab", #selector(AppDelegate.newTab(_:)), "t",
                          symbol: "plus.square.on.square"))
    fileMenu.addItem(.separator())
    fileMenu.addItem(item(
        "New Text File", #selector(AppDelegate.newTextDocument(_:)),
        AppMenuShortcuts.newTextFile.key,
        modifiers: AppMenuShortcuts.newTextFile.modifiers,
        symbol: "doc.badge.plus"))
    fileMenu.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o",
                          symbol: "folder"))
    fileMenu.addItem(item("Open in Terminal Split…", #selector(AppDelegate.openDocumentInSplit(_:)), "o",
                          modifiers: [.command, .option], symbol: "rectangle.split.1x2"))
    fileMenu.addItem(item("Save", #selector(AppDelegate.saveDocument(_:)), "s",
                          symbol: "square.and.arrow.down"))
    fileMenu.addItem(item("Save As…", #selector(AppDelegate.saveDocumentAs(_:)), "s",
                          modifiers: [.command, .shift], symbol: "square.and.arrow.down.on.square"))
    fileMenu.addItem(.separator())

    let workspacesItem = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
    workspacesItem.image = NSImage(
        systemSymbolName: "square.grid.2x2", accessibilityDescription: "Workspaces")
    let workspacesMenu = NSMenu(title: "Workspaces")
    workspacesMenu.delegate = delegate
    workspacesItem.submenu = workspacesMenu
    workspacesMenu.addItem(item(
        "Save Workspace As…", #selector(AppDelegate.saveNamedWorkspaceAs(_:))))
    workspacesMenu.addItem(item(
        "Update Current Workspace", #selector(AppDelegate.updateNamedWorkspace(_:))))
    workspacesMenu.addItem(.separator())
    let loadingWorkspaces = NSMenuItem(
        title: "Saved workspaces load when this menu opens",
        action: nil, keyEquivalent: "")
    loadingWorkspaces.isEnabled = false
    workspacesMenu.addItem(loadingWorkspaces)
    fileMenu.addItem(workspacesItem)
    fileMenu.addItem(.separator())

    let paneItem = NSMenuItem(title: "Panes", action: nil, keyEquivalent: "")
    paneItem.image = NSImage(systemSymbolName: "rectangle.split.1x2",
                             accessibilityDescription: "Panes")
    let paneMenu = NSMenu(title: "Panes")
    paneItem.submenu = paneMenu
    // The pane keys (⌘D and ⌘⇧D still split as well).
    for paneKeyItem in PaneKeyMenu.paneItems() { paneMenu.addItem(paneKeyItem) }
    paneMenu.addItem(.separator())
    paneMenu.addItem(item("Focus Next Pane", #selector(AppDelegate.focusNextPane(_:)), "]",
                          symbol: "chevron.right"))
    paneMenu.addItem(item("Focus Previous Pane", #selector(AppDelegate.focusPreviousPane(_:)), "[",
                          symbol: "chevron.left"))
    paneMenu.addItem(.separator())
    paneMenu.addItem(item("Break into Window", #selector(AppDelegate.breakPaneOut(_:)), "b",
                          modifiers: [.command, .shift], symbol: "macwindow"))
    paneMenu.addItem(item("Break into Tab", #selector(AppDelegate.breakPaneTab(_:)), "b",
                          modifiers: [.command, .option], symbol: "square.on.square"))
    fileMenu.addItem(paneItem)

    fileMenu.addItem(item("Show Editor", #selector(AppDelegate.showEditor(_:)),
                          symbol: "square.and.pencil"))
    fileMenu.addItem(item("Attach or Detach Editor",
                          #selector(AppDelegate.toggleEditorAttachment(_:)),
                          symbol: "arrow.left.arrow.right"))
    fileMenu.addItem(.separator())
    fileMenu.addItem(item("Close", #selector(AppDelegate.closePaneOrWindow(_:)), "w",
                          symbol: "xmark"))

    // Edit
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editItem.submenu = editMenu
    editMenu.addItem(item("Undo", Selector(("undo:")), "z"))
    editMenu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
    editMenu.addItem(.separator())
    editMenu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
    editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
    editMenu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
    editMenu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
    editMenu.addItem(.separator())
    editMenu.addItem(item("Find…", #selector(AppDelegate.showFind(_:)), "f"))
    editMenu.addItem(item("Find Next", #selector(AppDelegate.findNext(_:)), "g"))
    editMenu.addItem(item("Find Previous", #selector(AppDelegate.findPrevious(_:)), "g",
                          modifiers: [.command, .shift]))
    editMenu.addItem(.separator())
    editMenu.addItem(item("Clear Buffer", #selector(AppDelegate.clearBuffer(_:)), "k"))

    // View
    let viewItem = NSMenuItem()
    main.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    viewItem.submenu = viewMenu
    viewMenu.addItem(item(
        "Show Tab Sidebar", #selector(AppDelegate.toggleWorkspaceNavigator(_:)),
        AppMenuShortcuts.workspaceNavigator.key,
        modifiers: AppMenuShortcuts.workspaceNavigator.modifiers,
        symbol: "sidebar.left"))
    viewMenu.addItem(item("Show Inspector", #selector(AppDelegate.toggleWorkspaceInspector(_:)), "i",
                          modifiers: [.command, .option], symbol: "sidebar.right"))
    viewMenu.addItem(item(
        "Show Browser", #selector(AppDelegate.toggleEmbeddedBrowser(_:)), "b",
        modifiers: [.command, .option], symbol: "globe"))
    viewMenu.addItem(item("Focus Mode", #selector(AppDelegate.toggleWorkspaceFocusMode(_:)), "f",
                          modifiers: [.command, .option, .shift], symbol: "scope"))
    viewMenu.addItem(.separator())
    viewMenu.addItem(item(
        "Jump to Attention", #selector(AppDelegate.jumpToAttention(_:)), "u",
        modifiers: [.command, .shift], symbol: "bell.badge"))
    viewMenu.addItem(.separator())

    let textSizeItem = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
    textSizeItem.image = NSImage(
        systemSymbolName: "textformat.size", accessibilityDescription: "Text Size")
    let textSizeMenu = NSMenu(title: "Text Size")
    textSizeItem.submenu = textSizeMenu
    textSizeMenu.addItem(item("Increase", #selector(AppDelegate.increaseFontSize(_:)), "+"))
    textSizeMenu.addItem(item("Decrease", #selector(AppDelegate.decreaseFontSize(_:)), "-"))
    textSizeMenu.addItem(item("Reset", #selector(AppDelegate.resetFontSize(_:)), "0"))
    viewMenu.addItem(textSizeItem)

    let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
    appearanceItem.image = NSImage(
        systemSymbolName: "paintpalette", accessibilityDescription: "Appearance")
    let appearanceMenu = NSMenu(title: "Appearance")
    appearanceMenu.delegate = delegate
    appearanceItem.submenu = appearanceMenu
    appearanceMenu.addItem(item("Config Mixer…", #selector(AppDelegate.showConfigMixer(_:)), "m", modifiers: [.command, .shift]))
    appearanceMenu.addItem(.separator())

    let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
    let themeMenu = NSMenu(title: "Theme")
    themeMenu.delegate = delegate   // rebuilt on open so user themes appear live
    themeItem.submenu = themeMenu
    // Keep the entry available without constructing choices that the delegate
    // replaces on every opening to include the user's current themes.
    themeMenu.addItem(item("Browse with Preview…", #selector(AppDelegate.browseThemes(_:)), "", modifiers: []))
    appearanceMenu.addItem(themeItem)

    let cursorItem = NSMenuItem(title: "Cursor", action: nil, keyEquivalent: "")
    let cursorMenu = NSMenu(title: "Cursor")
    cursorItem.submenu = cursorMenu
    cursorMenu.addItem(item("Browse with Preview…", #selector(AppDelegate.browseCursors(_:)), "", modifiers: []))
    cursorMenu.addItem(.separator())
    let cursors: [(String, String)] = [
        ("Block (blink)", "blinkBlock"), ("Block", "steadyBlock"),
        ("Bar (blink)", "blinkBar"), ("Bar", "steadyBar"),
        ("Underline (blink)", "blinkUnderline"), ("Underline", "steadyUnderline"),
    ]
    for (label, value) in cursors {
        cursorMenu.addItem(item(label, #selector(AppDelegate.setCursorMenu(_:)), "", modifiers: [], represented: value))
    }
    cursorMenu.addItem(.separator())
    cursorMenu.addItem(item("Glide", #selector(AppDelegate.toggleSmoothCursor(_:)), "", modifiers: []))
    let glideSpeedItem = NSMenuItem(title: "Glide Speed", action: nil, keyEquivalent: "")
    let glideSpeedMenu = NSMenu(title: "Glide Speed")
    glideSpeedItem.submenu = glideSpeedMenu
    for (label, value) in [("Slow", 0.45), ("Relaxed", 0.7), ("Balanced", 1.0),
                           ("Fast", 1.6), ("Very Fast", 2.5)] {
        glideSpeedMenu.addItem(item(label, #selector(AppDelegate.setCursorGlideSpeed(_:)), "",
                                    modifiers: [], represented: value))
    }
    cursorMenu.addItem(glideSpeedItem)
    let glideDistanceItem = NSMenuItem(title: "Glide Distance", action: nil, keyEquivalent: "")
    let glideDistanceMenu = NSMenu(title: "Glide Distance")
    glideDistanceItem.submenu = glideDistanceMenu
    for (label, value) in [("Unlimited", 0.0), ("Up to 8 cells", 8.0),
                           ("Up to 4 cells", 4.0), ("Up to 2 cells", 2.0)] {
        glideDistanceMenu.addItem(item(label, #selector(AppDelegate.setCursorGlideDistance(_:)), "",
                                       modifiers: [], represented: value))
    }
    cursorMenu.addItem(glideDistanceItem)
    appearanceMenu.addItem(cursorItem)

    // The choices have no keyboard equivalents. Build them on first opening
    // rather than resolving system fonts and allocating every item at launch.
    let fontItem = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
    let fontMenu = NSMenu(title: "Font")
    fontMenu.delegate = delegate
    fontItem.submenu = fontMenu
    fontMenu.addItem(item("Browse with Preview…", #selector(AppDelegate.browseFonts(_:)), "", modifiers: []))
    fontMenu.addItem(.separator())
    fontMenu.addItem(item("System Mono", #selector(AppDelegate.setFontMenu(_:)), "", modifiers: [], represented: "System"))
    appearanceMenu.addItem(fontItem)

    // Shader lives with the other appearance pickers (Theme/Font/Cursor/…).
    let shaderItem = NSMenuItem(title: "Shader", action: nil, keyEquivalent: "")
    let shaderMenu = NSMenu(title: "Shader")
    shaderItem.submenu = shaderMenu
    shaderMenu.addItem(item("Browse with Preview…", #selector(AppDelegate.browseShaders(_:)), "", modifiers: []))
    shaderMenu.addItem(.separator())
    for name in Preferences.shaderNames {
        shaderMenu.addItem(item(name, #selector(AppDelegate.setShaderMenu(_:)), "", modifiers: [], represented: name))
    }
    appearanceMenu.addItem(shaderItem)

    let lhItem = NSMenuItem(title: "Line Spacing", action: nil, keyEquivalent: "")
    let lhMenu = NSMenu(title: "Line Spacing")
    lhItem.submenu = lhMenu
    for (label, v) in AppDelegate.lineSpacingOptions {
        lhMenu.addItem(item(label, #selector(AppDelegate.setLineHeightMenu(_:)), "", modifiers: [], represented: v))
    }
    appearanceMenu.addItem(lhItem)

    let insetItem = NSMenuItem(title: "Window Inset", action: nil, keyEquivalent: "")
    let insetMenu = NSMenu(title: "Window Inset")
    insetItem.submenu = insetMenu
    for (label, value) in [("Small", 6.0), ("Medium", 10.0), ("Large", 18.0)] {
        insetMenu.addItem(item(label, #selector(AppDelegate.setWindowInsetMenu(_:)), "",
                               modifiers: [], represented: value))
    }
    appearanceMenu.addItem(insetItem)

    let opacityItem = NSMenuItem(title: "Window Opacity", action: nil, keyEquivalent: "")
    let opacityMenu = NSMenu(title: "Window Opacity")
    opacityItem.submenu = opacityMenu
    for (label, value) in [("Solid", 1.0), ("95%", 0.95), ("85%", 0.85), ("70%", 0.70)] {
        opacityMenu.addItem(item(label, #selector(AppDelegate.setOpacityMenu(_:)), "",
                                modifiers: [], represented: value))
    }
    appearanceMenu.addItem(opacityItem)
    appearanceMenu.addItem(.separator())
    appearanceMenu.addItem(item("Blur Background", #selector(AppDelegate.toggleBlur(_:)), "", modifiers: []))
    viewMenu.addItem(appearanceItem)

    let terminalItem = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
    terminalItem.image = NSImage(
        systemSymbolName: "terminal", accessibilityDescription: "Terminal")
    let terminalMenu = NSMenu(title: "Terminal")
    terminalItem.submenu = terminalMenu
    terminalMenu.addItem(item("Option as Meta", #selector(AppDelegate.toggleOptionAsMeta(_:)), "", modifiers: []))
    terminalMenu.addItem(item("Copy on Select", #selector(AppDelegate.toggleCopyOnSelect(_:)), "", modifiers: []))
    terminalMenu.addItem(item("Open Links in Browser Split", #selector(AppDelegate.toggleOpenLinksInBrowser(_:)), "", modifiers: []))
    terminalMenu.addItem(item("Shell Integration", #selector(AppDelegate.toggleShellIntegration(_:)), "", modifiers: []))
    terminalMenu.addItem(item("Automatic Error Help", #selector(AppDelegate.toggleAutomaticErrorHelp(_:)), "", modifiers: []))
    terminalMenu.addItem(item("Clean Prompt (no user@host)", #selector(AppDelegate.toggleCleanPrompt(_:)), "", modifiers: []))
    let scrollSpeedItem = NSMenuItem(title: "Scroll Speed", action: nil, keyEquivalent: "")
    let scrollSpeedMenu = NSMenu(title: "Scroll Speed")
    scrollSpeedItem.submenu = scrollSpeedMenu
    for (label, value) in AppDelegate.scrollSpeedOptions {
        scrollSpeedMenu.addItem(item(
            label, #selector(AppDelegate.setScrollSpeed(_:)), "",
            modifiers: [], represented: value))
    }
    terminalMenu.addItem(scrollSpeedItem)
    viewMenu.addItem(terminalItem)

    let chromeItem = NSMenuItem(title: "Window Chrome", action: nil, keyEquivalent: "")
    chromeItem.image = NSImage(
        systemSymbolName: "macwindow", accessibilityDescription: "Window Chrome")
    let chromeMenu = NSMenu(title: "Window Chrome")
    chromeItem.submenu = chromeMenu
    chromeMenu.addItem(item("Hide Window Buttons", #selector(AppDelegate.toggleHideTrafficLights(_:)), "", modifiers: []))
    viewMenu.addItem(chromeItem)
    viewMenu.addItem(.separator())
    let customizeToolbar = item(
        "Customize Toolbar…", #selector(AppDelegate.customizeToolbar(_:)), "",
        modifiers: [])
    customizeToolbar.image = NSImage(
        systemSymbolName: "slider.horizontal.3",
        accessibilityDescription: "Customize Toolbar")
    viewMenu.addItem(customizeToolbar)

    // Tools — advanced surfaces stay available without occupying four
    // permanent slots in the menu bar.
    let toolsItem = NSMenuItem()
    main.addItem(toolsItem)
    let toolsMenu = NSMenu(title: "Tools")
    toolsItem.submenu = toolsMenu
    toolsMenu.addItem(item("Command Palette…", #selector(AppDelegate.showPalette(_:)), "p", modifiers: [.command, .shift]))
    let keybindingsItem = NSMenuItem(
        title: "Keybindings", action: nil, keyEquivalent: "")
    keybindingsItem.image = NSImage(
        systemSymbolName: "keyboard", accessibilityDescription: "Keybindings")
    let keybindingsMenu = NSMenu(title: "Keybindings")
    keybindingsItem.submenu = keybindingsMenu
    for source in CMDYKeybindingImportSource.allCases {
        keybindingsMenu.addItem(item(
            "Import from \(source.displayName)…",
            #selector(AppDelegate.importKeybindings(_:)), "", modifiers: [],
            represented: source.rawValue))
    }
    keybindingsMenu.addItem(.separator())
    keybindingsMenu.addItem(item(
        "Undo Last Import", #selector(AppDelegate.undoKeybindingImport(_:)),
        "", modifiers: []))
    keybindingsMenu.addItem(item(
        "Reset Imported Keybindings…",
        #selector(AppDelegate.resetImportedKeybindings(_:)), "", modifiers: []))
    toolsMenu.addItem(keybindingsItem)
    toolsMenu.addItem(.separator())

    // Blocks — navigate command blocks (shell-integration powered).
    let blocksItem = NSMenuItem(title: "Blocks", action: nil, keyEquivalent: "")
    let blocksMenu = NSMenu(title: "Blocks")
    blocksMenu.delegate = delegate   // repopulates the recent-command list on open
    blocksItem.submenu = blocksMenu
    toolsMenu.addItem(blocksItem)
    let upArrow = String(UnicodeScalar(0xF700)!)    // NSUpArrowFunctionKey
    let downArrow = String(UnicodeScalar(0xF701)!)  // NSDownArrowFunctionKey
    blocksMenu.addItem(item("Previous Command", #selector(AppDelegate.previousPrompt(_:)), upArrow, modifiers: [.command]))
    blocksMenu.addItem(item("Next Command", #selector(AppDelegate.nextPrompt(_:)), downArrow, modifiers: [.command]))
    blocksMenu.addItem(.separator())
    blocksMenu.addItem(item("Copy Last Command Output", #selector(AppDelegate.copyLastOutput(_:)), "c", modifiers: [.command, .shift]))
    blocksMenu.addItem(item("Explain Last Command", #selector(AppDelegate.explainLast(_:)), "e", modifiers: [.command, .shift]))
    blocksMenu.addItem(item("Compose Command…", #selector(AppDelegate.composeAI(_:)), "k", modifiers: [.command, .shift]))
    blocksMenu.addItem(item("Fix Last Failed Command", #selector(AppDelegate.fixLastAI(_:)), "x", modifiers: [.command, .shift]))
    blocksMenu.addItem(item("Agent Mode…", #selector(AppDelegate.startAgent(_:)), "a", modifiers: [.command, .shift]))

    // Actions — one-shot personal/project scripts, commands, and pane workflows.
    let actionsItem = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
    let actionsMenu = NSMenu(title: "Actions")
    actionsMenu.delegate = delegate
    actionsItem.submenu = actionsMenu
    toolsMenu.addItem(actionsItem)

    // Channels — external work sources, one durable Inbox, explicit replies.
    let channelsItem = NSMenuItem(title: "Channels", action: nil, keyEquivalent: "")
    let channelsMenu = NSMenu(title: "Channels")
    channelsMenu.delegate = delegate
    channelsItem.submenu = channelsMenu
    toolsMenu.addItem(channelsItem)

    // Extensions — each extension's commands, grouped and rebuilt on open.
    let pluginsItem = NSMenuItem(title: "Extensions", action: nil, keyEquivalent: "")
    let pluginsMenu = NSMenu(title: "Extensions")
    pluginsMenu.delegate = delegate
    pluginsItem.submenu = pluginsMenu
    toolsMenu.addItem(pluginsItem)
    toolsMenu.addItem(.separator())
    toolsMenu.addItem(item("Browse the Marketplace…", #selector(AppDelegate.browseMarketplace(_:)), "", modifiers: []))

    // Window
    let windowItem = NSMenuItem()
    main.addItem(windowItem)
    let windowMenu = NSMenu(title: "Window")
    windowItem.submenu = windowMenu
    windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
    windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
    windowMenu.addItem(.separator())
    windowMenu.addItem(item(
        "Window Grid", #selector(AppDelegate.toggleWindowGrid(_:)), "g",
        modifiers: [.control, .command], symbol: "rectangle.split.2x2"))
    windowMenu.addItem(item(
        "Break Splits into Grid Windows",
        #selector(AppDelegate.breakSplitsIntoGridWindows(_:)), "b",
        modifiers: [.control, .command]))
    windowMenu.addItem(item(
        "Combine Grid Windows into Splits",
        #selector(AppDelegate.combineGridWindowsIntoSplits(_:)), "j",
        modifiers: [.control, .command]))
    windowMenu.addItem(.separator())
    for paneKeyItem in PaneKeyMenu.windowItems() { windowMenu.addItem(paneKeyItem) }
    windowMenu.addItem(.separator())
    let mergeWithItem = NSMenuItem(title: "Merge With", action: nil, keyEquivalent: "")
    let mergeWithMenu = NSMenu(title: "Merge With")
    mergeWithMenu.delegate = delegate   // rebuilt on open with the live window list
    mergeWithItem.submenu = mergeWithMenu
    windowMenu.addItem(mergeWithItem)
    windowMenu.addItem(item("Merge All Windows into Tabs", #selector(NSWindow.mergeAllWindows(_:))))
    windowMenu.addItem(item("Merge All Windows into Splits", #selector(AppDelegate.mergeIntoSplits(_:))))
    windowMenu.addItem(item("Float on Top", #selector(AppDelegate.toggleFloat(_:)), "f", modifiers: [.command, .option]))
    NSApp.windowsMenu = windowMenu

    return main
}

let bundledFonts = FontLoader.bundledFonts
// Install before any renderer can shape text, including headless capture modes.
precondition(cmdy_render_set_font_fallback_loader {
    FontLoader.ensureFallbackFontsRegistered() ? 1 : 0
} != 0)
CrashLogger.install()       // dump a stack trace to /tmp/cmdy-crash.log on crash
if CommandLine.arguments.contains("--renderer-style-test") {
    MainActor.assumeIsolated {
        CmdyRendererStyleHarness.run(arguments: CommandLine.arguments)
    }
}
if CommandLine.arguments.contains("--renderer-capture-profile") {
    MainActor.assumeIsolated {
        CmdyRendererCaptureProfile.run(arguments: CommandLine.arguments)
    }
}
if CommandLine.arguments.contains("--renderer-window-test") {
    MainActor.assumeIsolated {
        CmdyRendererWindowHarness.run(arguments: CommandLine.arguments)
    }
}
MainActor.assumeIsolated {
    SelfTest.runIfRequested()   // exits early if --selftest was passed
}

// CLI verbs (no GUI): terminal helpers, extension authoring, marketplace, and sharing.
if CommandLine.arguments.count >= 2,
   ["show", "img", "notify"].contains(CommandLine.arguments[1]) {
    CmdyTerminalCLI.run(Array(CommandLine.arguments.dropFirst(1)))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "extension" {
    ExtensionCLI.run(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "action" {
    ActionCLI.run(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "channel" {
    ChannelCLI.run(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "surface" {
    SurfaceCLI.run(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "marketplace" {
    MarketplaceCLI.run(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "share" {
    MarketplaceCLI.share()
}

if CommandLine.arguments.contains("--ai-test") {
    // Headless check of the local-first command explanation chain.
    let sem = DispatchSemaphore(value: 0)
    Task {
        let response = await ErrorAssistant.explain(
            command: "xcodebuild -scheme App",
            output: "error: Signing for App requires a development team. Select a development team in Signing & Capabilities.",
            exitCode: 65, cwd: "/tmp/App")
        print("AI OK [\(response.source.label)]:\n\(response.text)")
        sem.signal()
    }
    sem.wait()
    exit(0)
}
if CommandLine.arguments.contains("--ai-compose-test") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let response = try await ErrorAssistant.composeCommand(
                request: "what time is it", cwd: "/tmp")
            print("AI COMPOSE OK [\(response.source.label)]:\n\(response.text)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            print("AI COMPOSE ERROR: \(message)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

if CommandLine.arguments.contains("--extension-activation-test") {
    ExtensionActivationTest.run()
}

if CommandLine.arguments.contains("--plugin-menu") {
    // Headless dump of the Extensions menu grouping (activates Extensions, no
    // UI). Their HTTP registrations synchronously hop to the main queue, so a
    // main-thread sleep guarantees stale/empty results. Pump the run loop until
    // every launched process authenticates back or the bounded deadline lands.
    PluginManager.shared.activateAll()
    let deadline = Date(timeIntervalSinceNow: 5)
    while Date() < deadline,
          PluginManager.shared.externalExtensionStatuses.contains(where: {
              $0.phase == .starting || $0.phase == .stopped
          }) {
        _ = RunLoop.current.run(
            mode: .default,
            before: min(deadline, Date(timeIntervalSinceNow: 0.05)))
    }
    // "ready" proves the child can use the host, but legacy and dynamic clients
    // may still enqueue several registrations at launch. Drain that bounded
    // burst on the run loop before snapshotting the final menu.
    let registrationDrainSeconds = ProductIdentity.current.environmentValue(
        "PLUGIN_MENU_DRAIN_SECONDS").flatMap(Double.init) ?? 2
    let registrationDrainDeadline = Date(
        timeIntervalSinceNow: max(0, min(30, registrationDrainSeconds)))
    while Date() < registrationDrainDeadline {
        _ = RunLoop.current.run(
            mode: .default,
            before: min(registrationDrainDeadline, Date(timeIntervalSinceNow: 0.05)))
    }
    for group in PluginManager.shared.commandsByPlugin {
        print("▸ \(group.plugin)")
        for c in group.commands { print("    \(c.title)") }
    }
    let statuses = PluginManager.shared.externalExtensionStatuses
    for status in statuses {
        let marker = status.phase == .ready ? "●" : (status.phase == .failed ? "✗" : "…")
        print("\(marker) \(status.name): \(status.displayText)")
    }
    let unhealthy = statuses.contains {
        $0.phase == .failed || $0.phase == .starting || $0.phase == .stopped
    }
    PluginManager.shared.deactivateAll()
    exit(unhealthy ? 1 : 0)
}
if CommandLine.arguments.contains("--fonts") {
    // Headless check that every bundled font registered and resolves.
    _ = FontLoader.registerBundledFonts()
    for bf in bundledFonts {
        let resolves = NSFont(name: bf.fontName, size: 13) != nil
        print("\(resolves ? "ok  " : "FAIL") \(bf.displayName)  (\(bf.fontName))")
    }
    print("\(bundledFonts.count) bundled fonts")
    exit(0)
}

if CommandLine.arguments.contains("--scroll-test") {
    // Headless regression check: scrolling up must survive incoming output.
    // A linefeed must not snap a user-controlled scrollback viewport back to
    // the live screen while a busy TUI continues producing output.
    let tv = TerminalEngineFactory.makeHeadlessSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    for i in 1...300 { tv.feed(text: "history line \(i)\r\n") }
    let term = tv.engine
    let atBottom = term.currentTopRow
    print("after 300 lines: yDisp=\(atBottom) scrollPosition=\(tv.scrollPosition)")

    tv.scrollUp(lines: 40)      // the wheel path
    let scrolledTo = term.currentTopRow
    print("after scrollUp(40): yDisp=\(scrolledTo)")

    for i in 301...340 { tv.feed(text: "tail output \(i)\r\n") }   // TUI keeps printing
    let afterOutput = term.currentTopRow
    print("after 40 more lines: yDisp=\(afterOutput)")

    tv.send(txt: "x")
    let inputReturnsToTail = tv.scrollPosition == 1.0
    print("after input: yDisp=\(term.currentTopRow) scrollPosition=\(tv.scrollPosition)")

    tv.scrollDown(lines: 10_000) // wheel back to the bottom
    for i in 341...345 { tv.feed(text: "tail output \(i)\r\n") }
    let followsAgain = tv.scrollPosition == 1.0   // pinned to the tail again
    print("back at bottom: yDisp=\(term.currentTopRow) scrollPosition=\(tv.scrollPosition)")

    let held = scrolledTo == atBottom - 40 && afterOutput == scrolledTo
    print(held ? "PASS: viewport held while output streamed" : "FAIL: viewport moved (\(scrolledTo) -> \(afterOutput))")
    print(inputReturnsToTail ? "PASS: input returned viewport to bottom" : "FAIL: input left viewport behind")
    print(followsAgain ? "PASS: tail-follow resumes after scrolling back" : "FAIL: still pinned after returning to bottom")
    exit((held && inputReturnsToTail && followsAgain) ? 0 : 1)
}

if CommandLine.arguments.contains("--wheel-test") {
    // Headless regression check: the wheel must reach full-screen TUIs.
    // Claude Code sits in the alternate screen with SGR mouse reporting on —
    // it scrolls its own transcript when the terminal reports buttons 64/65.
    // Lock down both reported mouse-wheel bytes and alternate-screen arrow-key
    // fallback; less/man need the latter while mouse-aware TUIs need the former.
    final class SendCapture {
        var sent: [UInt8] = []
        var asString: String { String(decoding: sent, as: UTF8.self) }
    }
    func wheelEvent(_ lines: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                         wheel1: lines, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }
    func preciseWheelEvent(_ pixels: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                         wheel1: pixels, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }
    func drainWorkerSend() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    let tv = TerminalEngineFactory.makeHeadlessSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let capture = SendCapture()
    tv.onSendToProcess = { capture.sent.append(contentsOf: $0) }
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL"): \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    // 1. Claude Code's exact setup: alt screen + SGR mouse reporting.
    tv.feed(text: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h")
    capture.sent = []
    tv.view.scrollWheel(with: wheelEvent(3))
    drainWorkerSend()
    check("mouse reporting: wheel up -> SGR button 64",
          capture.asString.contains("\u{1b}[<64;"), "got \(capture.asString.debugDescription)")
    capture.sent = []
    tv.view.scrollWheel(with: wheelEvent(-3))
    drainWorkerSend()
    check("mouse reporting: wheel down -> SGR button 65",
          capture.asString.contains("\u{1b}[<65;"), "got \(capture.asString.debugDescription)")

    // 2. Alt screen, mouse reporting off (less/man): wheel -> arrow keys.
    tv.feed(text: "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l")
    capture.sent = []
    tv.view.scrollWheel(with: wheelEvent(1))
    drainWorkerSend()
    check("alt screen: wheel up -> arrow up", capture.asString.contains("\u{1b}[A"),
          "got \(capture.asString.debugDescription)")
    capture.sent = []
    tv.view.scrollWheel(with: wheelEvent(-1))
    drainWorkerSend()
    check("alt screen: wheel down -> arrow down", capture.asString.contains("\u{1b}[B"),
          "got \(capture.asString.debugDescription)")

    // 3. Primary buffer: local scrollback moves, nothing is sent to the app.
    tv.feed(text: "\u{1b}[?1049l")
    for i in 1...300 { tv.feed(text: "history line \(i)\r\n") }
    let term = tv.engine
    let before = term.currentTopRow
    capture.sent = []
    tv.view.scrollWheel(with: wheelEvent(3))
    check("primary buffer: wheel scrolls local scrollback", term.currentTopRow < before,
          "yDisp \(before) -> \(term.currentTopRow)")
    check("primary buffer: nothing sent to the app", capture.sent.isEmpty,
          "got \(capture.asString.debugDescription)")
    if let core = tv as? CmdyTerminalSurface {
        check("primary buffer: renderer snapshot moves in the same turn",
              MainActor.assumeIsolated {
                  core.captureGrid().displayTopRow == term.currentTopRow
              })
    }

    // 4. Smooth scrolling must not retain sub-row motion against a hard
    // boundary. A retained remainder causes the rapid visual jiggle reported
    // when the trackpad keeps sending momentum at the top or bottom.
    if let core = tv as? CmdyTerminalSurface {
        tv.smoothScroll = true
        tv.scrollTo(row: max(1, term.liveScreenTopRow / 2))
        let notificationResult = MainActor.assumeIsolated {
            var wholeRowNotifications = 0
            var visualNotifications = 0
            core.onViewportChanged = { wholeRowNotifications += 1 }
            core.onVisualScrollChanged = { visualNotifications += 1 }
            tv.view.scrollWheel(with: preciseWheelEvent(3))
            return (
                hasRemainder: core.scrollAccumulatorForTesting != 0,
                sourceOffsetIsZero: core.scrollContentOffset == .zero,
                whole: wholeRowNotifications,
                visual: visualNotifications)
        }
        check("smooth scroll: precise input creates a fractional remainder",
              notificationResult.hasRemainder)
        check("smooth scroll: pixel motion skips whole-viewport observers",
              notificationResult.whole == 0 && notificationResult.visual == 1,
              "whole=\(notificationResult.whole) visual=\(notificationResult.visual)")
        check("smooth scroll: rendered offset is not fed back as source input",
              notificationResult.sourceOffsetIsZero)

        tv.scrollTo(row: 0)
        tv.view.scrollWheel(with: preciseWheelEvent(3))
        let topClearedRemainder = MainActor.assumeIsolated {
            core.scrollAccumulatorForTesting == 0
        }
        check("smooth scroll: top clamps fractional motion",
              term.currentTopRow == 0 && topClearedRemainder)

        tv.scrollTo(row: term.liveScreenTopRow)
        tv.view.scrollWheel(with: preciseWheelEvent(-3))
        let bottomClearedRemainder = MainActor.assumeIsolated {
            core.scrollAccumulatorForTesting == 0
        }
        check("smooth scroll: bottom clamps fractional motion",
              term.currentTopRow == term.liveScreenTopRow
                  && bottomClearedRemainder)

        // A partial upward gesture can exist while yDisp is still at the live
        // tail. When new output advances that tail, the old pixel remainder
        // must not lift the first row into window chrome.
        tv.view.scrollWheel(with: preciseWheelEvent(3))
        let tailHasRemainder = MainActor.assumeIsolated {
            core.scrollAccumulatorForTesting != 0
        }
        check("smooth scroll: tail gesture creates a held remainder",
              tailHasRemainder)
        tv.feed(text: "tail advances\r\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        let outputClearedRemainder = MainActor.assumeIsolated {
            core.scrollAccumulatorForTesting == 0
        }
        check("smooth scroll: live output clears the held remainder",
              term.currentTopRow == term.liveScreenTopRow
                  && outputClearedRemainder)

        let discreteGlideMatches = MainActor.assumeIsolated {
            let cellHeight = core.cellDimension.height
            return CmdyTerminalSurface.discreteScrollGlidePixels(
                before: 20, after: 17, cellHeight: cellHeight)
                    == -cellHeight * 3
        }
        check("smooth scroll: discrete glide covers every moved row",
              discreteGlideMatches)
        check("smooth scroll: App points convert once to renderer pixels",
              CmdyTerminalSurface.rendererScrollPixels(
                points: 3, backingScale: 2) == -6)

        let viewportRowsWereReused = MainActor.assumeIsolated {
            core.scrollTo(row: max(8, term.liveScreenTopRow / 2))
            let reuseBefore = core.terminal.viewportSnapshotReuseCountForTesting
            for _ in 0..<4 { core.scrollUp(lines: 1) }
            return core.terminal.viewportSnapshotReuseCountForTesting > reuseBefore
        }
        check("smooth scroll: viewport-only motion reuses captured rows",
              viewportRowsWereReused)
    } else {
        check("smooth scroll: Core surface available", false)
    }

    print(failures == 0 ? "ALL WHEEL TESTS PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--typeahead-blocks-test") {
    MainActor.assumeIsolated {
        // Typed-ahead input reaches the terminal as one chunk: prompt, command,
        // output and the next prompt together. Each block, and each failed-prompt
        // highlight, must still sit on its own prompt row.
        let pane = TerminalPane(cwd: nil)
        pane.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        pane.layoutSubtreeIfNeeded()
        let tv = pane.surface
        let term = tv.engine
        var burst = ""
        for i in 1...20 {
            burst += "\u{1b}]133;A\u{7}PROMPT\(i)> \u{1b}]133;B\u{7}cmd\(i)\r\n\u{1b}]133;C\u{7}"
                + "zsh: command not found: cmd\(i)\r\n\u{1b}]133;D;127\u{7}"
        }
        // Off the main thread, as PTY output is parsed.
        let parsed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { term.feed(text: burst); parsed.signal() }
        parsed.wait()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        pane.updateBlockStyles()
        let store = pane.blockStore
        let bad = store.blocks.compactMap { b -> String? in
            let text = term.scrollbackLineText(row: b.promptRow) ?? ""
            return text.contains("PROMPT\(b.index)>") ? nil : "block \(b.index) -> row \(b.promptRow): '\(text.prefix(30))'"
        }
        let failedRows = (tv as? CmdyTerminalSurface)?.failedBlockRows ?? []
        let highlighted = failedRows.map { term.scrollbackLineText(row: $0) ?? "" }
        let stray = highlighted.filter { !$0.hasPrefix("PROMPT") }
        let ok = store.blocks.count == 20 && bad.isEmpty && failedRows.count == 20 && stray.isEmpty
        print("TYPEAHEAD_BLOCKS blocks=\(store.blocks.count) misanchored=\(bad.count) highlighted=\(failedRows.count) stray=\(stray.count) ok=\(ok)")
        if let first = bad.first { print("  \(first)") }
        if let first = stray.first { print("  highlighted non-prompt row: '\(first.prefix(40))'") }
        exit(ok ? 0 : 1)
    }
}

if CommandLine.arguments.contains("--reflow-test") {
    // Headless regression check: font zoom / pane resize rewraps the buffer,
    // which used to leave block markers pointing at stale rows ("when i zoom
    // text the blocks does not follow"). Anchors now round-trip through
    // logical-line indices across the reflow.
    let pane = TerminalPane(cwd: nil)
    pane.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    pane.layoutSubtreeIfNeeded()
    let tv = pane.surface
    let term = tv.engine
    let filler = String(repeating: "x", count: term.cols * 2 + 7)   // forces wrapping
    // The OSC handler records rows via an async hop to the main queue, so each
    // marker must drain before more output moves the cursor — exactly how
    // incremental PTY reads behave in real use.
    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.003)) }
    for i in 1...30 {
        tv.feed(text: "\u{1b}]133;A\u{7}")
        drain()                                        // A: cursor still on the prompt row
        tv.feed(text: "PROMPT\(i)> \u{1b}]133;B\u{7}cmd\(i)\r\n\u{1b}]133;C\u{7}")
        drain()
        tv.feed(text: filler + "\r\n\u{1b}]133;D;0\u{7}")
        drain()
    }
    let store = pane.blockStore
    func misanchored() -> [String] {
        store.blocks.compactMap { b in
            let text = term.scrollbackLineText(row: b.promptRow) ?? ""
            return text.contains("PROMPT\(b.index)>") ? nil : "block \(b.index) -> row \(b.promptRow): '\(text.prefix(30))'"
        }
    }
    print("blocks recorded: \(store.blocks.count)")
    let beforeBad = misanchored()
    print(beforeBad.isEmpty ? "PASS: anchors correct before resize" : "FAIL before resize: \(beforeBad.first!)")

    pane.frame = NSRect(x: 0, y: 0, width: 500, height: 600)    // narrower -> rewrap
    pane.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let afterNarrow = misanchored()
    print(afterNarrow.isEmpty ? "PASS: anchors follow a narrowing reflow" : "FAIL after narrowing: \(afterNarrow.first!)")

    pane.frame = NSRect(x: 0, y: 0, width: 900, height: 600)    // wider -> rewrap again
    pane.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let afterWide = misanchored()
    print(afterWide.isEmpty ? "PASS: anchors follow a widening reflow" : "FAIL after widening: \(afterWide.first!)")

    // Font zoom takes a different path (resetFont -> resize(cols:rows:), not
    // processSizeChange) — the original bug report was exactly this route.
    tv.font = NSFont.monospacedSystemFont(ofSize: 22, weight: .regular)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let afterZoomIn = misanchored()
    print(afterZoomIn.isEmpty ? "PASS: anchors follow font zoom in" : "FAIL after zoom in: \(afterZoomIn.first!)")
    tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let afterZoomOut = misanchored()
    print(afterZoomOut.isEmpty ? "PASS: anchors follow font zoom out" : "FAIL after zoom out: \(afterZoomOut.first!)")

    // Sparse content + growing rows: zooming OUT (or dragging the window
    // taller) pads the buffer with blank lines at the bottom. Tail-relative
    // anchors shifted markers ~26 rows below their text here — anchors must
    // be cursor-relative to survive.
    let pane2 = TerminalPane(cwd: nil)
    pane2.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    pane2.layoutSubtreeIfNeeded()
    let tv2 = pane2.surface
    tv2.font = NSFont.monospacedSystemFont(ofSize: 22, weight: .regular)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let term2 = tv2.engine
    for i in 1...4 {
        tv2.feed(text: "\u{1b}]133;A\u{7}")
        drain()
        tv2.feed(text: "P\(i)> \u{1b}]133;B\u{7}c\(i)\r\n\u{1b}]133;C\u{7}")
        drain()
        tv2.feed(text: "out\(i)\r\n\u{1b}]133;D;1\u{7}")
        drain()
    }
    func misanchored2() -> [String] {
        pane2.blockStore.blocks.compactMap { b in
            let text = term2.scrollbackLineText(row: b.promptRow) ?? ""
            return text.contains("P\(b.index)>") ? nil : "block \(b.index) -> row \(b.promptRow): '\(text.prefix(20))'"
        }
    }
    tv2.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)   // rows explode -> blank tail padding
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let sparseZoomOut = misanchored2()
    print(sparseZoomOut.isEmpty ? "PASS: sparse content survives zoom out (blank-tail padding)"
                                : "FAIL sparse zoom out: \(sparseZoomOut.first!)")
    pane2.frame = NSRect(x: 0, y: 0, width: 500, height: 900)             // taller window, same effect
    pane2.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let sparseTaller = misanchored2()
    print(sparseTaller.isEmpty ? "PASS: sparse content survives a taller+narrower resize"
                               : "FAIL sparse resize: \(sparseTaller.first!)")

    let ok = store.blocks.count == 30 && beforeBad.isEmpty && afterNarrow.isEmpty && afterWide.isEmpty
        && afterZoomIn.isEmpty && afterZoomOut.isEmpty
        && pane2.blockStore.blocks.count == 4 && sparseZoomOut.isEmpty && sparseTaller.isEmpty
    print(ok ? "ALL REFLOW TESTS PASS" : "REFLOW TESTS FAILED")
    exit(ok ? 0 : 1)
}

if CommandLine.arguments.contains("--graphics-test") {
    // Headless check of the inline-graphics pipeline: kitty APC and sixel DCS
    // must decode and attach images to buffer lines (the Metal renderer draws
    // whatever lands there via its kitty texture cache / image stripes).
    let tv = TerminalEngineFactory.makeHeadlessSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let term = tv.engine
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL"): \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    // A tiny red PNG, generated on the fly.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill()
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!.base64EncodedString()

    // Kitty graphics: transmit + display PNG (f=100, id 7), APC ... ST.
    tv.feed(text: "\u{1b}_Gf=100,a=T,i=7;\(png)\u{1b}\\")
    check("kitty: PNG with id retained in image store", term.kittyImageCount == 1,
          "kittyImageCount=\(term.kittyImageCount)")
    check("kitty: placement attached to a buffer line", term.linesWithImagesCount >= 1,
          "linesWithImages=\(term.linesWithImagesCount)")

    // Sixel: DCS q ... ST — a small red block.
    let before = term.linesWithImagesCount
    tv.feed(text: "\r\n\r\n\u{1b}Pq#0;2;100;0;0#0!30~-!30~-!30~\u{1b}\\\r\n")
    check("sixel: image attached to a buffer line", term.linesWithImagesCount > before,
          "linesWithImages \(before) -> \(term.linesWithImagesCount)")

    print(failures == 0 ? "ALL GRAPHICS TESTS PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--shader-test") {
    // The user-shader template must compile through the runtime pipeline —
    // it's the first thing every author sees.
    let tv = TerminalEngineFactory.makeHeadlessSurface(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    do { try tv.setUseMetal(true) } catch {
        print("SKIP: no Metal device (\(error))")
        exit(0)
    }
    Task { @MainActor in
        var failures = 0
        if let err = await tv.setUserShader(UserShaders.template) {
            print("FAIL: template does not compile — \(err.prefix(400))")
            failures += 1
        } else {
            print("PASS: user shader template compiles")
        }
        if await tv.setUserShader("garbage ((") == nil {
            print("FAIL: broken shader should report an error")
            failures += 1
        } else {
            print("PASS: broken shader reports a compile error")
        }
        if let err = await tv.setUserShader(nil) {
            print("FAIL: clearing shader errored: \(err)")
            failures += 1
        } else {
            print("PASS: clearing the user shader works")
        }
        print(failures == 0 ? "ALL SHADER TESTS PASS" : "\(failures) FAILURE(S)")
        await (tv as? CmdyTerminalSurface)?.metalRenderer?.shutdown()
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
    // This diagnostic must never fall through into normal application launch
    // if the run loop exits before its asynchronous checks finish.
    print("FAIL: shader-test run loop exited before completion")
    exit(1)
}

if CommandLine.arguments.contains("--panel-test") {
    // Headless check of the inline panel's live-preview state machine:
    // selecting a settings row applies it (unpersisted), esc reverts/backs,
    // and ⏎ keeps settings without closing while plain actions do close.
    let saved = Preferences.shared.themeName
    Preferences.shared.themeName = "Dark"
    let panel = InlinePanel(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    var dismissed = false
    panel.onDismiss = { dismissed = true }
    func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL"): \(name)")
        if !ok { failures += 1 }
    }
    let items = [
        PaletteItem(title: "Plain Action", subtitle: "", action: {}, preview: nil),
        PaletteItem(title: "Theme: Nord", subtitle: "",
                    action: { Preferences.shared.themeName = "Nord" },
                    preview: { Preferences.shared.themeName = "Nord" }),
    ]
    panel.configureList(items: items, placeholder: "", hint: "")
    check("open: nothing previewed yet", Preferences.shared.themeName == "Dark")
    panel.keyDown(with: key(125))   // ↓ onto the theme row
    check("select settings row -> previews live", Preferences.shared.themeName == "Nord")
    panel.keyDown(with: key(126))   // ↑ back to the plain row
    check("browse away -> saved look returns", Preferences.shared.themeName == "Dark")
    panel.keyDown(with: key(125))   // ↓ preview again
    panel.keyDown(with: key(53))    // esc
    check("esc -> reverted and closed", Preferences.shared.themeName == "Dark" && dismissed)

    // ⏎ keeps a setting and stays in its section; root esc closes later
    // without reverting that committed choice.
    dismissed = false
    panel.configureList(items: items, placeholder: "", hint: "")
    panel.keyDown(with: key(125))
    panel.keyDown(with: key(36))    // return
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check("return -> setting kept without closing",
          Preferences.shared.themeName == "Nord" && !dismissed)
    panel.keyDown(with: key(53))
    check("root esc -> committed setting survives close",
          Preferences.shared.themeName == "Nord" && dismissed)

    // Tab-scoped appearance participates in the same transaction without
    // rewriting the global preference: preview + Escape restores the tab,
    // while Return advances the tab baseline and survives dismissal.
    var tabTheme = "Dracula"
    var tabThemeBaseline = tabTheme
    let tabThemeHooks = InlinePanelPreviewHooks(
        begin: { tabThemeBaseline = tabTheme },
        restore: { tabTheme = tabThemeBaseline },
        commit: { tabThemeBaseline = tabTheme })
    let tabThemeItems = [
        PaletteItem(title: "Dracula", subtitle: "current",
                    action: { tabTheme = "Dracula" },
                    preview: { tabTheme = "Dracula" }),
        PaletteItem(title: "Dark", subtitle: "theme",
                    action: { tabTheme = "Dark" },
                    preview: { tabTheme = "Dark" }),
    ]
    dismissed = false
    panel.configureList(
        items: tabThemeItems, placeholder: "", hint: "",
        previewHooks: tabThemeHooks)
    panel.keyDown(with: key(125))
    check("tab theme: selection previews outside global preferences",
          tabTheme == "Dark" && Preferences.shared.themeName == "Nord")
    panel.keyDown(with: key(53))
    check("tab theme: escape restores the original override",
          tabTheme == "Dracula" && dismissed)

    dismissed = false
    panel.configureList(
        items: tabThemeItems, placeholder: "", hint: "",
        previewHooks: tabThemeHooks)
    panel.keyDown(with: key(125))
    panel.keyDown(with: key(36))
    panel.keyDown(with: key(53))
    check("tab theme: return commits the override through dismissal",
          tabTheme == "Dark" && Preferences.shared.themeName == "Nord"
              && dismissed)

    // The footer is its own padded section below the body divider.
    let rhythmItems = [PaletteItem(title: "One", action: {})]
    panel.configureList(items: rhythmItems, placeholder: "", hint: "")
    let oneRowHeight = panel.intrinsicContentSize.height
    panel.configureList(items: rhythmItems + [PaletteItem(title: "Two", action: {})],
                        placeholder: "", hint: "")
    let listRowStep = panel.intrinsicContentSize.height - oneRowHeight
    panel.configureList(items: rhythmItems, placeholder: "", hint: "esc back")
    let footerRowStep = panel.intrinsicContentSize.height - oneRowHeight
    check("layout: footer has independent vertical inset",
          footerRowStep > listRowStep)

    // Tree navigation: sections descend on ⏎/→, ← pops, root search is deep.
    dismissed = false
    var ranNested = false
    let tree = [
        PaletteItem.section("Tools", "", [
            PaletteItem(title: "Nested Action", subtitle: "", action: { ranNested = true }),
        ]),
        PaletteItem(title: "Top Action", subtitle: "", action: {}),
    ]
    panel.configureList(items: tree, placeholder: "", hint: "")
    panel.keyDown(with: key(36))    // ⏎ on the section -> descend, not dismiss
    check("tree: enter descends into section", !dismissed)
    panel.keyDown(with: key(53))    // esc -> root, not closed
    check("tree: esc backs out one level", !dismissed)

    var dynamicRefreshes = 0
    let dynamicProvider: () -> [PaletteItem] = {
        dynamicRefreshes += 1
        return [PaletteItem.section("Toggle", dynamicRefreshes > 1 ? "ON" : "OFF", [
            PaletteItem(title: "Enable", action: {}),
        ])]
    }
    panel.configureList(items: dynamicProvider(), placeholder: "", hint: "",
                        itemsProvider: dynamicProvider)
    panel.keyDown(with: key(36))    // enter Toggle
    panel.keyDown(with: key(53))    // return to root and regenerate labels
    check("tree: returning refreshes dynamic setting labels", dynamicRefreshes == 2)

    panel.configureList(items: tree, placeholder: "", hint: "")
    panel.keyDown(with: key(36))    // re-enter Tools
    panel.keyDown(with: key(36))    // ⏎ on Nested Action
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check("tree: nested action runs", ranNested && dismissed)
    // Root search reaches nested items without descending.
    dismissed = false; ranNested = false
    panel.configureList(items: tree, placeholder: "", hint: "")
    for ch in "nested" {
        panel.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             characters: String(ch), charactersIgnoringModifiers: String(ch),
                                             isARepeat: false, keyCode: 0)!)
    }
    panel.keyDown(with: key(36))
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check("tree: root search finds nested items", ranNested)

    // A generic On/Off leaf remains searchable by its setting name, and its
    // preview/commit transaction must survive the contextual search result.
    let savedGhostText = Preferences.shared.ghostText
    let savedSearchTheme = Preferences.shared.themeName
    Preferences.shared.ghostText = true
    var searchTabTheme = "Light"
    var searchTabThemeBaseline = searchTabTheme
    let searchPreviewHooks = InlinePanelPreviewHooks(
        begin: { searchTabThemeBaseline = searchTabTheme },
        restore: { searchTabTheme = searchTabThemeBaseline },
        commit: { searchTabThemeBaseline = searchTabTheme })
    var pickedSettingPath: [String] = []
    let searchableSettings: [PaletteItem] = [
        .section("Themes", "", [
            PaletteItem(title: "Green",
                        action: {
                            Preferences.shared.themeName = "Green"
                            searchTabTheme = "Green"
                        },
                        preview: {
                            Preferences.shared.themeName = "Green"
                            searchTabTheme = "Green"
                        }),
        ]),
        .section("Settings", "", [
            .section("Ghost Text", "on", [
                PaletteItem(title: "On", subtitle: "current",
                            action: { Preferences.shared.ghostText = true },
                            preview: { Preferences.shared.ghostText = true }),
                PaletteItem(title: "Off",
                            action: { Preferences.shared.ghostText = false },
                            preview: { Preferences.shared.ghostText = false }),
            ]),
        ]),
    ]
    dismissed = false
    panel.onPick = { pickedSettingPath = $0.ancestors }
    panel.configureList(items: searchableSettings, placeholder: "", hint: "",
                        previewHooks: searchPreviewHooks)
    func typeSearch(_ text: String) {
        for ch in text {
            panel.keyDown(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: String(ch),
                charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)!)
        }
    }
    typeSearch("g")
    check("search: initial prefix previews an appearance result",
          Preferences.shared.themeName == "Green" && searchTabTheme == "Green")
    typeSearch("host text off")
    check("search: Ghost Text Off restores unrelated previews before previewing the setting",
          !Preferences.shared.ghostText && Preferences.shared.themeName == savedSearchTheme
              && searchTabTheme == "Light")
    panel.keyDown(with: key(53))
    check("search: escape restores the original setting", Preferences.shared.ghostText && !dismissed)
    typeSearch("ghost text off")
    panel.keyDown(with: key(36))
    check("search: return keeps the setting and reports its full path",
          !Preferences.shared.ghostText && !dismissed
              && pickedSettingPath == ["Settings", "Ghost Text"])
    panel.keyDown(with: key(53))
    typeSearch("g")
    typeSearch("zz")
    check("search: no matches restores appearance and preserves committed settings",
          Preferences.shared.themeName == savedSearchTheme && searchTabTheme == "Light"
              && !Preferences.shared.ghostText)
    panel.keyDown(with: key(53))
    panel.keyDown(with: key(53))
    check("search: committed setting survives clearing search and closing",
          !Preferences.shared.ghostText && dismissed)
    panel.onPick = nil
    Preferences.shared.ghostText = savedGhostText

    // Reopening a palette remembers the last row in each section.
    let navigationDefaultsKey = "cmdy.inline-panel.navigation.v1"
    let savedNavigation = UserDefaults.standard.object(forKey: navigationDefaultsKey)
    UserDefaults.standard.removeObject(forKey: navigationDefaultsKey)
    var rememberedPick = ""
    let rememberedTree = [
        PaletteItem.section("Remember", "", [
            PaletteItem(title: "First", action: { rememberedPick = "First" }),
            PaletteItem(title: "Second", action: { rememberedPick = "Second" }),
        ]),
    ]
    dismissed = false
    panel.configureList(items: rememberedTree, placeholder: "", hint: "",
                        memoryKey: "panel-test")
    panel.keyDown(with: key(36))    // enter section
    panel.keyDown(with: key(125))   // leave it on Second
    panel.keyDown(with: key(53))    // back to root
    panel.keyDown(with: key(53))    // close
    dismissed = false
    panel.configureList(items: rememberedTree, placeholder: "", hint: "",
                        memoryKey: "panel-test")
    panel.keyDown(with: key(36))    // section reopens on Second
    panel.keyDown(with: key(36))
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check("tree: each section remembers its last row", rememberedPick == "Second")
    if let savedNavigation { UserDefaults.standard.set(savedNavigation, forKey: navigationDefaultsKey) }
    else { UserDefaults.standard.removeObject(forKey: navigationDefaultsKey) }

    // Non-theme appearance settings participate in the same reversible preview.
    let savedMargin = Preferences.shared.contentMargin
    Preferences.shared.contentMargin = 6
    dismissed = false
    panel.configureList(items: [
        PaletteItem(title: "Plain"),
        PaletteItem(title: "Large inset",
                    action: { Preferences.shared.contentMargin = 24 },
                    preview: { Preferences.shared.contentMargin = 24 }),
    ], placeholder: "", hint: "")
    panel.keyDown(with: key(125))
    check("appearance values preview beyond theme/font", Preferences.shared.contentMargin == 24)
    panel.keyDown(with: key(53))
    check("appearance preview reverts on esc", Preferences.shared.contentMargin == 6)

    // Vertical rhythm follows the configured window inset, never the grid's
    // horizontal centering remainder. A list has four body padding edges and
    // two footer padding edges, hence six times the inset delta.
    var syntheticOriginX: CGFloat = 18
    panel.metrics = {
        (
            NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            18,
            syntheticOriginX,
            14
        )
    }
    panel.configureList(items: rhythmItems, placeholder: "", hint: "esc back")
    let smallInsetHeight = panel.intrinsicContentSize.height
    syntheticOriginX = 72
    panel.refreshMetrics()
    check("layout: horizontal grid remainder cannot move panel bottom",
          abs(panel.intrinsicContentSize.height - smallInsetHeight) < 0.01)
    Preferences.shared.contentMargin = 24
    panel.refreshMetrics()
    check("layout: vertical sections follow window inset exactly",
          abs(panel.intrinsicContentSize.height - smallInsetHeight - (24 - 6) * 6) < 0.01)
    panel.metrics = nil
    Preferences.shared.contentMargin = savedMargin

    // Long lists scroll: every match must be reachable, not just the first 12.
    dismissed = false
    var picked = -1
    let many = (0..<30).map { i in
        PaletteItem(title: "Item \(i)", subtitle: "", action: { picked = i }, preview: nil)
    }
    panel.configureList(items: many, placeholder: "", hint: "")
    for _ in 0..<25 { panel.keyDown(with: key(125)) }   // ↓ far past the visible window
    panel.keyDown(with: key(36))
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check("list scrolls: row 25 reachable and runs", picked == 25)

    // Mixer: ⏎ pins WITHOUT closing; esc keeps pins, reverts the rest.
    dismissed = false
    Preferences.shared.themeName = "Dark"
    let mixTabs: [(String, [PaletteItem])] = [
        ("Theme", [
            PaletteItem(title: "Dark", subtitle: "current",
                        action: { Preferences.shared.themeName = "Dark" },
                        preview: { Preferences.shared.themeName = "Dark" }),
            PaletteItem(title: "Nord", subtitle: "theme",
                        action: { Preferences.shared.themeName = "Nord" },
                        preview: { Preferences.shared.themeName = "Nord" }),
        ]),
    ]
    panel.configureTabs(tabs: mixTabs, hint: "")
    panel.keyDown(with: key(125))   // ↓ onto Nord (previewed)
    panel.keyDown(with: key(36))    // ⏎ pin
    check("mixer: ⏎ pins without closing", !dismissed && Preferences.shared.themeName == "Nord")
    panel.keyDown(with: key(53))    // esc
    check("mixer: esc keeps the pinned pick", dismissed && Preferences.shared.themeName == "Nord")

    // Reusable horizontal bottom menu: arrows wrap between actions, Return
    // activates the highlighted item, and dismissal cannot drop its callback.
    dismissed = false
    var menuPick: String?
    panel.configureMenu(
        title: "Work with:",
        items: [
            BottomMenuItem(id: "pi", title: "Pi", shortcut: "1"),
            BottomMenuItem(id: "codex", title: "Codex", shortcut: "2"),
        ],
        hint: "←/→ choose · return select")
    panel.onMenuAction = { menuPick = $0 }
    check("bottom menu: starts on first enabled action", panel.currentMenuItemID == "pi")
    panel.keyDown(with: key(124))   // → Codex
    check("bottom menu: side arrows move the selection", panel.currentMenuItemID == "codex")
    panel.keyDown(with: key(36))    // ⏎ activate
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check("bottom menu: return dismisses and activates", dismissed && menuPick == "codex")

    Preferences.shared.themeName = saved   // restore the user's real theme
    print(failures == 0 ? "ALL PANEL TESTS PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--make-iconset") {
    let dir = (i + 1 < CommandLine.arguments.count)
        ? CommandLine.arguments[i + 1]
        : "\(ProductIdentity.current.iconBaseName).iconset"
    IconGenerator.writeIconset(to: dir)
    exit(0)
}

// Prepare Metal's device registry while AppKit performs independent startup.
// Keep device selection at its existing renderer call sites; no device array
// or worker is retained after this once-only preparation completes.
private enum InitialMetalDevicePreparation {
    static let prepared: Void = autoreleasepool { _ = MTLCopyAllDevices() }

    static func prepareWhile<T>(_ operation: () throws -> T) rethrows -> T {
        precondition(Thread.isMainThread)
        let preparation = DispatchWorkItem {
            autoreleasepool { _ = prepared }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: preparation)
        // Join before activation, delegate creation or menus, also on error.
        defer { preparation.wait() }
        return try operation()
    }
}

// Drain temporary launch/menu objects before the application event loop.
// The application and delegate remain strongly owned for the complete run.
let (app, delegate) = autoreleasepool {
    let app = InitialMetalDevicePreparation.prepareWhile { NSApplication.shared }
    app.setActivationPolicy(.regular)
    MainActor.assumeIsolated {
        InitialShellPrelaunch.startIfEligible(arguments: CommandLine.arguments)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    MainActor.assumeIsolated {
        // The global tuple is not initialized until this pool returns. Pass
        // its live local delegate so dynamic menus receive their weak owner.
        let mainMenu = buildMainMenu(delegate: delegate)
        app.mainMenu = mainMenu
        PaneKeyMenu.refresh()
        // Install the dynamic icon observer only after AppKit knows which menu is
        // the menu bar. During construction NSApp.mainMenu is nil, so observing
        // item additions early makes the icon installer mistake File/Edit/View
        // and Tools for ordinary submenu commands and replace their titles with
        // the fallback command symbol.
        // Icons are seen only in an open menu, and the installer also applies
        // them when any menu begins tracking. Symbol images for every command
        // cost tens of milliseconds, so a normal launch adds them just after
        // the first window instead of before it.
        let installMenuIcons = {
            CmdyMenuIconInstaller.shared.install()
            mainMenu.cmdyApplyIconsRecursively()
        }
        if CommandLine.arguments.contains("--menu-bar-test") {
            installMenuIcons()
        } else {
            var launched: NSObjectProtocol?
            launched = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { _ in
                if let launched { NotificationCenter.default.removeObserver(launched) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated { installMenuIcons() }
                }
            }
        }

        if CommandLine.arguments.contains("--menu-bar-test") {
            let expectedMenus = ["File", "Edit", "View", "Tools", "Window"]
            let actualMenus = mainMenu.items.dropFirst().compactMap(\.submenu?.title)
            let rootItemsHaveNoIcons = mainMenu.items.allSatisfy { $0.image == nil }
            let fileMenu = mainMenu.cmdyDescendantMenu(titled: "File")
            let beamChoiceHidden = mainMenu.cmdyDescendantMenu(titled: "Beam") == nil
            let showEditor = fileMenu?.item(withTitle: "Show Editor")
            let showEditorRoutesToEditor = showEditor?.action
                == #selector(AppDelegate.showEditor(_:))
            let probe = NSMenuItem(
                title: "Dynamic Icon Probe", action: #selector(NSText.copy(_:)),
                keyEquivalent: "")
            mainMenu.cmdyDescendantMenu(titled: "Actions")?.addItem(probe)
            let dynamicCommandReceivedIcon = probe.image != nil
            let ok = actualMenus == expectedMenus
                && rootItemsHaveNoIcons && dynamicCommandReceivedIcon
                && beamChoiceHidden && showEditorRoutesToEditor
            print("UIMENUBAR \(ok ? "PASS" : "FAIL") "
                  + "menus=\(actualMenus.joined(separator: ",")) "
                  + "rootIcons=\(rootItemsHaveNoIcons ? 0 : 1) "
                  + "dynamicIcon=\(dynamicCommandReceivedIcon ? 1 : 0) "
                  + "beamChoice=\(beamChoiceHidden ? 0 : 1) "
                  + "showEditor=\(showEditorRoutesToEditor ? 1 : 0)")
            exit(ok ? 0 : 1)
        }
    }
    return (app, delegate)
}
withExtendedLifetime(delegate) { app.run() }
