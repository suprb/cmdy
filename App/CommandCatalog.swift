import AppKit
import CmdyKit
import ProductIdentity

/// Remembers only explicit palette picks for this app run, never shell text or
/// action closures. Each reopening resolves the IDs against the focused pane.
enum CommandCatalogHistory {
    private(set) static var identifiers: [String] = []

    static func record(_ item: PaletteItem) {
        guard item.children == nil, item.kind == .action else { return }
        identifiers.removeAll { $0 == item.identifier }
        identifiers.insert(item.identifier, at: 0)
        identifiers = Array(identifiers.prefix(24))
    }
}

/// The command catalog shares previewable settings with the Config Mixer.
/// Keep catalog construction separate from app lifecycle and window routing.
extension AppDelegate {
    /// Everything the palette can do: actions, themes, fonts, cursor styles,
    /// toggles, and the focused pane's recent commands.
    // MARK: - Palette tree (sections; shared with the Config Mixer)

    private func item(_ title: String, _ subtitle: String = "", previews: Bool = false,
                      _ action: @escaping () -> Void) -> PaletteItem {
        PaletteItem(title: title, subtitle: subtitle, action: action,
                    preview: previews ? action : nil)
    }

    private func booleanPaletteItems(current: Bool, previews: Bool = true,
                                     set: @escaping (Bool) -> Void) -> [PaletteItem] {
        [
            item("On", current ? "current" : "", previews: previews) { set(true) },
            item("Off", !current ? "current" : "", previews: previews) { set(false) },
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

    func paletteItems() -> [PaletteItem] {
        let p = Preferences.shared
        var root: [PaletteItem] = []

        root.append(.section("Terminal", "find · copy output · command blocks", [
            item("Find…", "⌘F") { [weak self] in self?.showFind(nil) },
            item("Copy Last Command Output", "⇧⌘C") { [weak self] in self?.copyLastOutput(nil) },
            item("Previous Command", "jump to previous prompt") { [weak self] in self?.previousPrompt(nil) },
            item("Next Command", "jump to next prompt") { [weak self] in self?.nextPrompt(nil) },
            item("Clear Buffer", "⌘K") { [weak self] in self?.clearBuffer(nil) },
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

        root.append(.section("Settings", "preferences · keyboard · assistant", [
            item("Open Settings…", "⌘, · application defaults and pane overrides") { [weak self] in self?.openSettings(nil) },
            item("Open Config File", "edit text configuration") { [weak self] in self?.openConfig(nil) },
            item("Reload Config", "⇧⌘,") { [weak self] in self?.reloadConfig(nil) },
            keybindingImportPaletteSection(),
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
                     booleanPaletteItems(current: p.ghostText) { p.ghostText = $0 },
                     keywords: ["autocomplete", "autosuggestion", "history completion"]),
            .section("Automatic Error Help", p.automaticErrorHelp ? "on" : "off",
                     booleanPaletteItems(current: p.automaticErrorHelp) { p.automaticErrorHelp = $0 },
                     keywords: ["assistant", "explain failures"]),
            .section("Marketplace Update Checks", p.marketplaceUpdateChecks ? "on" : "off",
                     booleanPaletteItems(current: p.marketplaceUpdateChecks, previews: false) { enabled in
                         p.marketplaceUpdateChecks = enabled
                         if enabled { MarketplaceUpdateMonitor.shared.checkIfDue(force: true) }
                         else { MarketplaceUpdateMonitor.shared.clearKnownUpdates() }
                     }),
        ]))

        root.append(.section("Assistant", "agent · compose · explain · fix", [
            item("Agent Mode…", "⇧⌘A") { [weak self] in self?.startAgent(nil) },
            item("Compose Command…", "⇧⌘K · or type # request") { [weak self] in self?.composeAI(nil) },
            item("Explain Last Command", "⇧⌘E") { [weak self] in self?.explainLast(nil) },
            item("Fix Last Failed Command", "⇧⌘X") { [weak self] in self?.fixLastAI(nil) },
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
        root.append(.section("Actions", "scripts · commands · workflows", actionItems))

        if hasChannelContext {
            root.append(channelPaletteSection())
        }

        let marketplaceUpdateCount = MarketplaceUpdateMonitor.shared.extensionUpdateCount
        var pluginItems: [PaletteItem] = [
            item("Extensions…", marketplaceUpdateCount == 0
                 ? "⇧⌘L" : "\(marketplaceUpdateCount) update\(marketplaceUpdateCount == 1 ? "" : "s") · ⇧⌘L") {
                [weak self] in self?.showPlugins(nil)
            },
            item("Browse the Marketplace…", "shaders · themes · rigs · extensions") { [weak self] in
                self?.browseMarketplace(nil)
            },
            item("Set Up Channels…", "browse and connect a work inbox") { [weak self] in
                self?.showChannelManager(nil)
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
        let extensionSubtitle = marketplaceUpdateCount == 0
            ? "installed tools · marketplace"
            : "\(marketplaceUpdateCount) update\(marketplaceUpdateCount == 1 ? "" : "s") · manage · commands"
        root.append(.section("Extensions", extensionSubtitle, pluginItems))

        var developerItems: [PaletteItem] = [
            item("Integration Doctor…", "Browser · Sim · Bridge · MCP") { [weak self] in
                self?.showIntegrationDoctor(nil)
            },
            item("New User Shader…", "scaffold + live reload") { UserShaders.createAndEdit() },
        ]
        developerItems.append(item("Save Last Command as Action…", "authoring") { [weak self] in
            self?.saveLastCommandAsAction(nil)
        })
        developerItems.append(item("Create Sample Action", "scaffold") { [weak self] in
            self?.createSampleAction(nil)
        })
        developerItems.append(item(
            "Open Actions Folder",
            "~/.config/\(ProductIdentity.current.configurationDirectoryName)/actions"
        ) { [weak self] in
            self?.openActionsFolder(nil)
        })
        developerItems.append(item("Create Sample Extension", "scaffold") { PluginManager.shared.createSamplePlugin() })
        developerItems.append(item("Open Author Guide", "EXTENSIONS.md") { PluginManager.shared.openAuthorGuide() })
        developerItems.append(item("Open Extensions Folder") {
            try? FileManager.default.createDirectory(at: PluginManager.extensionsDirectory,
                                                     withIntermediateDirectories: true)
            NSWorkspace.shared.open(PluginManager.extensionsDirectory)
        })
        root.append(.section("Developer", "author actions · extensions · shaders", developerItems))

        if let controller = currentController {
            let commands = controller.recentCommands(limit: 5).filter { !$0.command.isEmpty }
            if !commands.isEmpty {
                root.append(.section("Shell History", "selected commands run immediately",
                    commands.map { command in
                        PaletteItem(title: "Run: \(command.command)",
                                    subtitle: "runs immediately in the focused pane",
                                    action: { [weak self] in
                                        self?.currentController?.runCommand(command.command)
                                    }, kind: .shellCommand)
                    }, keywords: ["recent commands", "rerun"]))
            }
        }

        let recent = CommandPalette.recentActions(
            identifiers: CommandCatalogHistory.identifiers, items: root, limit: 3)
        return recent + root
    }

    /// Connected, stopped, and unconfigured installed connectors all have a
    /// useful management surface. A fresh install gets only the setup entry.
    private var hasChannelContext: Bool {
        if !PluginManager.shared.channelRuntimes.isEmpty { return true }
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: PluginManager.extensionsDirectory,
            includingPropertiesForKeys: nil)) ?? []
        return directories.contains { directory in
            (try? ExtensionManifest.load(from: directory))?.allows(.channels) == true
        }
    }
}
