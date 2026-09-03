import AppKit
import ProductIdentity

/// Ghostty-style plain-text configuration at ~/.config/cmdy/config:
/// one `key = value` per line, `#` comments. Values apply into Preferences
/// (so the menus and the file always agree), and a directory watcher re-applies
/// the file live on every save — edit, save, watch every open terminal update.
public enum ConfigFile {
    private static let retiredKeys: Set<String> = [
        "use-gpu", "hide-toolbar", "window-buttons", "banner",
    ]

    public static var directory: URL {
        // <PRODUCT>_CONFIG_DIR isolates a whole instance — config, session,
        // plugins, themes, discovery file all derive from here. Test gates
        // (perf gate, zoo) use it to run beside a live app untouched.
        if let override = ProductIdentity.current.environmentValue("CONFIG_DIR"),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return ProductIdentity.current.configurationDirectory()
    }
    public static var url: URL { directory.appendingPathComponent("config") }

    /// One-time migration from every previous public name into the current
    /// configuration directory. Old directories stay untouched so downgrade
    /// and rename rollback remain safe.
    public static func migrateLegacyDirectoriesIfNeeded() {
        // Sandboxed instances (perf gate, zoo) stay hermetic — no migration.
        guard ProductIdentity.current.environmentValue("CONFIG_DIR") == nil else { return }
        let fm = FileManager.default
        for old in ProductIdentity.current.legacyConfigurationDirectories() {
            guard fm.fileExists(atPath: old.path) else { continue }
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // Item-wise: anything the new home doesn't have yet comes over
            // (the destination may already exist because the runtime creates it).
            guard let entries = try? fm.contentsOfDirectory(
                at: old, includingPropertiesForKeys: nil) else { continue }
            var migrated = 0
            for entry in entries {
                let dest = directory.appendingPathComponent(entry.lastPathComponent)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                try? fm.copyItem(at: entry, to: dest)
                migrated += 1
            }
            if migrated > 0 {
                NSLog("%@: migrated %d item(s) from %@",
                      ProductIdentity.current.slug, migrated, old.path)
            }
        }
    }

    nonisolated(unsafe) private static var watcher: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private static var watchedFD: Int32 = -1
    nonisolated(unsafe) private static var pendingApply: DispatchWorkItem?
    nonisolated(unsafe) private static var lastApplied: Data?

    // MARK: - Parsing

    /// Parse `key = value` lines. Unknown keys are ignored (forward compatible).
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Allow quoted values (for font names with spaces, etc.)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            out[key] = value
        }
        return out
    }

    private static func bool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    // MARK: - Apply

    /// Read the file (if present) and push its values into Preferences.
    /// Returns true if a config file was found and applied.
    @discardableResult
    public static func applyIfPresent() -> Bool {
        guard let data = try? BoundedFileReader.data(
            at: url, maxBytes: 4 * 1024 * 1024) else { return false }
        if data == lastApplied { return true }   // editor event, no content change
        lastApplied = data
        Theme.reloadUserThemes()                 // themes dir may have changed too
        apply(parse(String(decoding: data, as: UTF8.self)))
        return true
    }

    /// True while the file's values are being pushed into Preferences —
    /// stops the setters' write-back from echoing into the file.
    nonisolated(unsafe) private(set) static var isApplying = false

    /// Apply config key/values from outside the file-watch path — the
    /// marketplace uses this to apply rigs (whole-look presets).
    public static func applyValues(_ kv: [String: String]) { apply(kv) }

    private static func apply(_ kv: [String: String]) {
        isApplying = true
        defer { isApplying = false }
        let p = Preferences.shared
        if let v = kv["marketplace-registry"], !v.isEmpty { p.marketplaceRegistry = v }
        if let v = kv["marketplace-update-checks"].flatMap(bool) {
            p.marketplaceUpdateChecks = v
        }
        if let v = kv["editor"], !v.isEmpty { p.editor = v }
        if let v = kv["theme"] {
            if Theme.names.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) {
                p.themeName = Theme.names.first { $0.caseInsensitiveCompare(v) == .orderedSame }!
            } else {
                NSLog("cmdy config: unknown theme '%@'", v)
            }
        }
        if let v = kv["cursor-color"] {
            p.cursorColorOverrideHex = ["theme", "auto"].contains(v.lowercased()) ? nil : v
        }
        if let v = kv["font-family"] {
            p.fontName = v.lowercased() == "system" ? "System" : v
        }
        if let v = kv["font-size"], let n = Double(v), (6...72).contains(n) { p.fontSize = CGFloat(n) }
        if let v = kv["line-height"], let n = Double(v), (0.5...2.0).contains(n) { p.lineHeight = CGFloat(n) }
        if let v = kv["text-rendering"], Preferences.textRenderingModes.contains(v.lowercased()) {
            p.textRenderingMode = v.lowercased()
        }
        if let v = kv["scroll-speed"], let n = Double(v), (0.2...5.0).contains(n) { p.scrollSpeed = CGFloat(n) }

        // cursor-style = block | bar | underline, cursor-blink = true/false —
        // combined into the single stored style name.
        let styleWord = kv["cursor-style"]
        let blink = kv["cursor-blink"].flatMap(bool)
        if styleWord != nil || blink != nil {
            let current = p.cursorStyleName
            let base = styleWord?.lowercased() ??
                (current.lowercased().contains("bar") ? "bar" :
                 current.lowercased().contains("underline") ? "underline" : "block")
            let blinks = blink ?? current.hasPrefix("blink")
            let cap = base.prefix(1).uppercased() + base.dropFirst()
            if ["block", "bar", "underline"].contains(base) {
                p.cursorStyleName = (blinks ? "blink" : "steady") + cap
            }
        }

        if let v = kv["use-gpu"].flatMap(bool), v == false {
            // GPU-only since the CmdyCore migration; the key is retired.
            NSLog("cmdy: use-gpu = false is no longer supported — rendering is always Metal")
        }
        if let v = kv["option-as-meta"].flatMap(bool) { p.optionAsMeta = v }
        if let v = kv["attention-signals"].flatMap(bool) { p.attentionSignals = v }
        if let v = kv["shell-integration"].flatMap(bool) { p.shellIntegration = v }
        if let v = kv["clean-prompt"].flatMap(bool) { p.cleanPrompt = v }
        if let v = kv["hide-traffic-lights"].flatMap(bool) { p.hideTrafficLights = v }
        if let v = kv["margin"], let n = Double(v), (0...60).contains(n) { p.contentMargin = CGFloat(n) }
        if let v = kv["window-grid"].flatMap(bool) { p.windowGridEnabled = v }
        if let v = kv["workspace-navigator"].flatMap(bool) { p.workspaceNavigatorVisible = v }
        if let v = kv["workspace-inspector"].flatMap(bool) { p.workspaceInspectorVisible = v }
        if let v = kv["opacity"], let n = Double(v) { p.opacity = min(1.0, max(0.3, n)) }
        if let v = kv["blur"].flatMap(bool) { p.blur = v }
        if let v = kv["ghost-text"].flatMap(bool) { p.ghostText = v }
        if let v = kv["shader"] {
            if let match = Preferences.shaderNames.first(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) {
                p.shaderName = match
            } else if bool(v) == false {
                p.shaderName = "None"
            } else {
                NSLog("cmdy config: unknown shader '%@'", v)
            }
        }
        // Back-compat: `crt = true` from older configs selects the CRT shader —
        // but only when no explicit `shader` key is present.
        if kv["shader"] == nil, let v = kv["crt"].flatMap(bool) {
            p.shaderName = v ? "CRT" : "None"
        }
        if let v = kv["core"], v.lowercased() == "swiftterm" {
            // Retired with the legacy engine adapter — CmdyCore is the engine.
            NSLog("cmdy: core = swiftterm is gone; running CmdyCore")
        }
        if let v = kv["smooth-cursor"].flatMap(bool) { p.smoothCursor = v }
        if let v = kv["cursor-glide-speed"], let n = Double(v), (0.1...8).contains(n) {
            p.cursorGlideSpeed = CGFloat(n)
        }
        if let v = kv["cursor-glide-max-distance"], let n = Double(v), (0...100).contains(n) {
            p.cursorGlideMaxDistance = CGFloat(n)
        }
        if let v = kv["smooth-scroll"].flatMap(bool) { p.smoothScroll = v }
        if let v = kv["sounds"].flatMap(bool) { p.sounds = v }
        if let v = kv["restore-session"].flatMap(bool) { p.restoreSession = v }
        if let v = kv["automatic-error-help"].flatMap(bool) { p.automaticErrorHelp = v }
        if let v = kv["anthropic-api-key"] { p.anthropicKey = v.isEmpty ? nil : v }
        if let v = kv["ai-model"], !v.isEmpty { p.aiModel = v }
    }

    // MARK: - Write-back

    /// Persist one setting back into the config file, so changes made in the
    /// menus/palette survive a relaunch (the file wins at launch — without
    /// this, every restart reverted them to whatever the file said).
    /// Rewrites the key's line in place, preserving comments and layout;
    /// appends the key if the file doesn't mention it. No file, no write —
    /// then UserDefaults is the only store and persists by itself.
    public static func writeBack(key: String, value: String) {
        guard !isApplying else { return }
        guard let text = try? BoundedFileReader.utf8String(
            at: url, maxBytes: 4 * 1024 * 1024) else { return }
        let data = Data(rewriting(text, key: key, value: value).utf8)
        lastApplied = data   // the watcher's re-apply becomes a no-op
        try? data.write(to: url, options: .atomic)
    }

    /// Pure text transform behind `writeBack` (covered by --selftest).
    public static func rewriting(_ text: String, key: String, value: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            if k == key {
                lines[i] = "\(key) = \(value)"
                return lines.joined(separator: "\n")
            }
        }
        if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false { lines.append("") }
        lines.append("\(key) = \(value)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Watching

    /// Watch ~/.config/cmdy for writes (editors replace files atomically, so
    /// watch the directory, not the file) and re-apply after a short debounce.
    public static func startWatching() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler {
            pendingApply?.cancel()
            let work = DispatchWorkItem { applyIfPresent() }
            pendingApply = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        src.setCancelHandler { close(watchedFD); watchedFD = -1 }
        src.resume()
        watcher = src

        // Hot-reload user shaders: save a .metal file → panes recompile live.
        let shadersDir = UserShaders.directory
        try? FileManager.default.createDirectory(at: shadersDir, withIntermediateDirectories: true)
        let sfd = open(shadersDir.path, O_EVTONLY)
        guard sfd >= 0 else { return }
        let shaderSrc = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: sfd, eventMask: [.write, .rename, .delete], queue: .main)
        shaderSrc.setEventHandler {
            pendingShaderApply?.cancel()
            let work = DispatchWorkItem {
                guard Preferences.shared.shaderName.hasPrefix("user/") else { return }
                NotificationCenter.default.post(name: .cmdyPreferencesChanged, object: nil)
            }
            pendingShaderApply = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        shaderSrc.setCancelHandler { close(sfd) }
        shaderSrc.resume()
        shaderWatcher = shaderSrc
    }

    nonisolated(unsafe) private static var shaderWatcher: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private static var pendingShaderApply: DispatchWorkItem?

    // MARK: - Template / open

    /// Ensure the config exists and is current, then return it to the app's
    /// editor router. Kept separate from opening so Cmdy can use its native
    /// editor without CmdyKit depending on app-layer UI.
    @discardableResult
    public static func prepareForEditing() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? template().write(to: url, atomically: true, encoding: .utf8)
            lastApplied = try? BoundedFileReader.data(
                at: url, maxBytes: 4 * 1024 * 1024)   // don't re-apply what we just wrote
        } else if isStale() {
            regenerate()   // refresh an old/incomplete config to the current, fully-commented layout
        }
        return url
    }

    /// Compatibility entry point for callers that explicitly want the macOS
    /// default editor rather than Cmdy's app-layer editor router.
    public static func openInEditor() {
        NSWorkspace.shared.open(prepareForEditing())
    }

    /// True when the config predates the current template — missing any key it
    /// documents, or carrying a retired one. Such files get a full refresh.
    private static func isStale() -> Bool {
        guard let existing = try? BoundedFileReader.utf8String(
            at: url, maxBytes: 4 * 1024 * 1024) else { return false }
        let have = Set(parse(existing).keys)
        let templateKeys = Set(parse(template()).keys)
        return !templateKeys.isSubset(of: have)
            || !have.isDisjoint(with: retiredKeys)
    }

    /// Rewrite the config to the current, fully-commented template — filled with
    /// the user's CURRENT values (they live in Preferences, so nothing is lost)
    /// and with any custom keys the template doesn't cover (an API key, a custom
    /// registry) preserved at the end. The previous file is backed up to
    /// `config.bak` first, so a hand-tuned layout is never gone for good.
    private static func regenerate() {
        guard let existing = try? BoundedFileReader.utf8String(
            at: url, maxBytes: 4 * 1024 * 1024) else { return }
        try? existing.write(to: url.appendingPathExtension("bak"), atomically: true, encoding: .utf8)

        let templateKeys = Set(parse(template()).keys)
        let extras = parse(existing)
            .filter {
                !templateKeys.contains($0.key)
                    && !retiredKeys.contains($0.key)
            }
            .sorted { $0.key < $1.key }
            .map { "\($0.key) = \($0.value)" }

        var out = template()
        if !extras.isEmpty {
            out += "\n\n# ── your other settings (kept from the previous config) ──\n"
                 + extras.joined(separator: "\n") + "\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
        lastApplied = try? BoundedFileReader.data(
            at: url, maxBytes: 4 * 1024 * 1024)   // values are unchanged; don't re-apply
    }

    public static func template() -> String {
        let p = Preferences.shared
        let themes = Theme.names.joined(separator: ", ")
        let identity = ProductIdentity.current
        let configHome = "~/.config/\(identity.configurationDirectoryName)"
        // Reflect the user's actual cursor so a regenerate doesn't reset it.
        let cn = p.cursorStyleName.lowercased()
        let cursorStyle = cn.contains("bar") ? "bar" : (cn.contains("underline") ? "underline" : "block")
        let cursorBlink = cn.hasPrefix("blink")
        return """
        # \(identity.displayName) configuration — save this file and every open terminal updates live.
        # Lines are `key = value`; quotes are optional. `#` starts a comment.

        theme = \(p.themeName)
        # Available: \(themes)
        # Drop your own JSON themes into \(configHome)/themes/ — see the README.
        # Cursor color follows the theme, or accepts #RRGGBB.
        cursor-color = \(p.cursorColorOverrideHex ?? "theme")

        # Font. font-family: any installed or bundled font (`--fonts` lists them),
        # or "System". font-size in points; line-height is a multiplier (1.0 =
        # snug, higher = airier).
        font-family = \(p.fontName)
        font-size = \(Int(p.fontSize))
        line-height = \(p.lineHeight)

        # GPU text rasterization preset. Appearance > Text Rendering Lab previews
        # each mode live: current | y-snap | atlas-padding | nearest |
        # high-contrast | crisp.
        text-rendering = \(p.textRenderingMode)

        # Editor used for config, Markdown and text files opened by \(identity.titleName).
        # \(identity.slug) = the built-in editor; system = macOS default; or a command
        # such as `code --wait`. Use {file} to place the path explicitly.
        editor = \(p.editor)

        # Marketplace Extensions carry install receipts. When any exist,
        # \(identity.titleName) checks this registry at most once daily and announces new
        # versions once. Disable the check to keep marketplace access manual.
        marketplace-update-checks = \(p.marketplaceUpdateChecks)
        # marketplace-registry = https://raw.githubusercontent.com/\(identity.repositoryOwner)/\(identity.slug)-registry/main/registry.json

        # Scroll speed multiplier — >1 scrolls further per gesture, <1 less.
        # Range 0.2–5.0. Applies to trackpad, wheel, and TUI scrolling alike.
        scroll-speed = \(p.scrollSpeed)

        # Cursor. cursor-style: block | bar | underline. cursor-blink: true/false.
        cursor-style = \(cursorStyle)
        cursor-blink = \(cursorBlink)

        # Send Option as Meta/Esc (for emacs, tmux prefixes, etc.).
        option-as-meta = \(p.optionAsMeta)
        # OSC 133 shell integration: command blocks, durations, jump-to-command,
        # finished-while-away notifications. Off = a plain terminal.
        shell-integration = \(p.shellIntegration)
        # A minimal, hostname-free prompt (drops user@host, keeps the folder) in
        # every \(identity.displayName) pane; at filesystem root it shows only %. Nice for
        # screen-shares and recordings. Turn it off to preserve a custom prompt
        # (starship, powerlevel10k, …).
        clean-prompt = \(p.cleanPrompt)
        # ── Window chrome ──────────────────────────────────────────────
        # hide-traffic-lights: remove the red/yellow/green window buttons for a
        #   distraction-free look (close/minimize/zoom still work from the menu
        #   and ⌘W / ⌘M).
        hide-traffic-lights = \(p.hideTrafficLights)
        # margin: the complete window inset. Presets are Small 6, Medium 10,
        #   and Large 18 points. Small/Medium use compact native chrome; Large
        #   uses unified chrome. Custom values remain valid from 0–60 points.
        #   Window Grid uses this same value once between adjacent windows.
        margin = \(Int(p.contentMargin))
        # Recursively tile visible \(identity.displayName) terminal windows. New
        # windows split right, then down; moving reorders and resizing adjusts
        # the surrounding split. Hold Option while dragging to merge windows.
        window-grid = \(p.windowGridEnabled)

        # Adaptive Frame: the current tab group and extension navigation live
        # on the left; command, selection and project tools live on the right.
        # Both rails start hidden; the left sidebar replaces the native tab bar
        # when explicitly shown.
        workspace-navigator = \(p.workspaceNavigatorVisible)
        workspace-inspector = \(p.workspaceInspectorVisible)

        # Window transparency: 0.3 (glass) … 1.0 (solid). blur frosts what's behind.
        opacity = \(p.opacity)
        blur = \(p.blur)

        # Inline history suggestion (fish-style), accepted with the right arrow.
        ghost-text = \(p.ghostText)

        # Post-process shader (GPU renderer only). Try View ▸ Shader ▸ Browse
        # with Preview… — ↑↓ previews each one live.
        # None | CRT | Scanlines | Glow | VHS | Dither | Neon | Plasma | Glitch
        # | Ripple | Copper | Starfield | Matrix | Fire | Grid | Tunnel
        # | Rotozoom | Wobble | Aurora | Lava | Boot | Snow
        # Responsive ones: Ripple (typing shockwaves), Starfield (typing = warp),
        # Rotozoom (typing pumps zoom), Boot (keypress fires a raster beam),
        # Snow (static grows while idle — typing clears it), Databloom
        # (chromatic text fragments while scrolling; background stays exact).
        shader = \(p.shaderName)

        # smooth-cursor: the cursor glides between cells instead of teleporting.
        smooth-cursor = \(p.smoothCursor)
        # Chase-rate multiplier: 0.1 (slow) ... 8.0 (nearly instant).
        cursor-glide-speed = \(p.cursorGlideSpeed)
        # Largest jump to animate, in cells. 0 = unlimited.
        cursor-glide-max-distance = \(p.cursorGlideMaxDistance)
        # smooth-scroll: eased, line-snapped scrolling (lands on a line, glides
        #   there). Off = instant line-by-line. GPU renderer only.
        smooth-scroll = \(p.smoothScroll)

        # SID-flavored keypress blips + error buzz.
        sounds = \(p.sounds)

        # Bring back windows, splits, working directories and scrollback on launch.
        restore-session = \(p.restoreSession)

        # Automatically explain failed commands inline. A suggested command is
        # inserted only after ⌘Return and still requires Return to run.
        automatic-error-help = \(p.automaticErrorHelp)

        # Error help starts with built-in diagnostics, then Apple Intelligence
        # on-device. This optional key is the cloud fallback and is required for
        # Agent. A key here also works for Finder and Dock launches;
        # ANTHROPIC_API_KEY only reaches \(identity.displayName) when it is started from a shell.
        # anthropic-api-key = sk-ant-…
        ai-model = \(p.aiModel)
        """
    }
}
