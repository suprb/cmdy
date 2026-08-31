import AppKit
import ProductIdentity

extension Notification.Name {
    /// Posted whenever any user preference changes; open terminals re-apply live.
    public static let cmdyPreferencesChanged = Notification.Name("cmdy.preferencesChanged")
}

/// App-wide settings, persisted in UserDefaults. All terminals share these and
/// re-apply on change, so tweaking font/theme updates every open tab at once.
public final class Preferences {
    nonisolated(unsafe) public static let shared = Preferences()
    public static let defaultThemeName = "Light"
    public static let defaultFontName = "FragmentMono-Regular"
    public static let defaultFontSize: CGFloat = 13
    public static let defaultShowBanner = false
    public static let defaultWorkspaceNavigatorVisible = false
    public static let defaultWorkspaceInspectorVisible = false
    private let d: UserDefaults
    private let isolatedDefaultsDomain: String?

    private enum Key {
        static let themeName = "themeName"
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let cursorStyle = "cursorStyle"
        static let cursorColorOverride = "cursorColorOverride"
        static let optionAsMeta = "optionAsMeta"
        static let attentionSignals = "attentionSignals"
        static let showBanner = "showBanner"
        static let shellIntegration = "shellIntegration"
        static let cleanPrompt = "cleanPrompt"
        static let lineHeight = "lineHeight"
        static let textRenderingMode = "textRenderingMode"
        static let hideTrafficLights = "hideTrafficLights"
        static let contentMargin = "contentMargin"
        static let windowGridEnabled = "windowGridEnabled"
        static let windowGridState = "windowGridState"
        static let opacity = "opacity"
        static let scrollSpeed = "scrollSpeed"
        static let blur = "blur"
        static let ghostText = "ghostText"
        static let shader = "shader"
        static let smoothCursor = "smoothCursor"
        static let cursorGlideSpeed = "cursorGlideSpeed"
        static let cursorGlideMaxDistance = "cursorGlideMaxDistance"
        static let smoothScroll = "smoothScroll"
        static let sounds = "sounds"
        static let restoreSession = "restoreSession"
        static let automaticErrorHelp = "automaticErrorHelp"
        static let disabledPlugins = "disabledPlugins"
        static let anthropicKey = "anthropicKey"
        static let aiModel = "aiModel"
        static let marketplaceRegistry = "marketplaceRegistry"
        static let marketplaceUpdateChecks = "marketplaceUpdateChecks"
        static let editor = "editor"
        static let workspaceNavigator = "workspaceNavigator"
        static let workspaceInspector = "workspaceInspector"
    }

    private init() {
        if let domain = ProductIdentity.current.environmentValue("DEFAULTS_DOMAIN"),
           !domain.isEmpty {
            isolatedDefaultsDomain = domain
            d = UserDefaults(suiteName: domain) ?? .standard
            d.removePersistentDomain(forName: domain)
        } else {
            isolatedDefaultsDomain = nil
            d = .standard
        }
        d.register(defaults: [
            Key.themeName: Self.defaultThemeName,
            Key.fontName: Self.defaultFontName,
            Key.fontSize: Double(Self.defaultFontSize),
            Key.lineHeight: 1.15,
            Key.textRenderingMode: "high-contrast",
            Key.cursorStyle: "blinkBlock",
            // GPU is the point. CmdyGPU keeps glyphs and the cursor snapped to
            // the terminal grid so GPU output is crisper than a generic text view.
            Key.optionAsMeta: true,
            Key.showBanner: Self.defaultShowBanner,
            Key.shellIntegration: true,
            Key.cleanPrompt: true,
            Key.contentMargin: 10.0,
            Key.windowGridEnabled: false,
            Key.opacity: 1.0,
            Key.scrollSpeed: 1.5,
            Key.ghostText: true,
            Key.smoothCursor: true,
            Key.cursorGlideSpeed: 1.6,
            Key.cursorGlideMaxDistance: 0.0,
            Key.smoothScroll: true,
            Key.restoreSession: true,
            Key.automaticErrorHelp: true,
            Key.marketplaceUpdateChecks: true,
            Key.editor: ProductIdentity.current.slug,
            Key.workspaceNavigator: Self.defaultWorkspaceNavigatorVisible,
            Key.workspaceInspector: Self.defaultWorkspaceInspectorVisible,
        ])
    }

    public func clearIsolatedStorage() {
        guard let isolatedDefaultsDomain else { return }
        d.removePersistentDomain(forName: isolatedDefaultsDomain)
    }

    public var themeName: String {
        get { d.string(forKey: Key.themeName) ?? Self.defaultThemeName }
        set { guard newValue != themeName else { return }
              d.set(newValue, forKey: Key.themeName); sync("theme", newValue); changed() }
    }
    public var theme: Theme {
        let base = Theme.named(themeName)
        guard let hex = cursorColorOverrideHex, let cursor = Theme.hex(hex) else {
            return base
        }
        return Theme(name: base.name, ansi: base.ansi,
                     background: base.background, foreground: base.foreground,
                     cursor: cursor, border: base.border)
    }

    /// Optional cursor ink selected from the native inspector ColorPicker.
    /// Nil follows the active theme.
    public var cursorColorOverrideHex: String? {
        get {
            guard let value = d.string(forKey: Key.cursorColorOverride),
                  Theme.hex(value) != nil else { return nil }
            return value
        }
        set {
            let value = newValue.flatMap { raw -> String? in
                var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                if !normalized.hasPrefix("#") { normalized = "#" + normalized }
                return Theme.hex(normalized) == nil ? nil : normalized
            }
            guard value != cursorColorOverrideHex else { return }
            if let value {
                d.set(value, forKey: Key.cursorColorOverride)
            } else {
                d.removeObject(forKey: Key.cursorColorOverride)
            }
            sync("cursor-color", value ?? "theme")
            changed()
        }
    }

    public var fontName: String {
        get { d.string(forKey: Key.fontName) ?? Self.defaultFontName }
        set { guard newValue != fontName else { return }
              d.set(newValue, forKey: Key.fontName); sync("font-family", newValue); changed() }
    }
    public var fontSize: CGFloat {
        get {
            let v = d.double(forKey: Key.fontSize)
            return v > 0 ? CGFloat(v) : Self.defaultFontSize
        }
        set { guard newValue != fontSize else { return }
              d.set(Double(newValue), forKey: Key.fontSize); sync("font-size", num(newValue)); changed() }
    }
    /// Scroll wheel/trackpad multiplier — higher = more sensitive (default 1.5).
    public var scrollSpeed: CGFloat {
        get { let v = d.double(forKey: Key.scrollSpeed); return v > 0 ? CGFloat(v) : 1.5 }
        set { guard newValue != scrollSpeed else { return }
              d.set(Double(newValue), forKey: Key.scrollSpeed); sync("scroll-speed", num(newValue)); changed() }
    }
    public var lineHeight: CGFloat {
        get { let v = d.double(forKey: Key.lineHeight); return v > 0 ? CGFloat(v) : 1.15 }
        set { guard newValue != lineHeight else { return }
              d.set(Double(newValue), forKey: Key.lineHeight); sync("line-height", num(newValue)); changed() }
    }
    public static let textRenderingModes = [
        "current", "y-snap", "atlas-padding", "nearest", "high-contrast", "crisp"
    ]
    public var textRenderingMode: String {
        get {
            let value = d.string(forKey: Key.textRenderingMode) ?? "high-contrast"
            return Self.textRenderingModes.contains(value) ? value : "high-contrast"
        }
        set {
            let value = Self.textRenderingModes.contains(newValue) ? newValue : "high-contrast"
            guard value != textRenderingMode else { return }
            d.set(value, forKey: Key.textRenderingMode)
            sync("text-rendering", value); changed()
        }
    }
    public var cursorStyleName: String {
        get { d.string(forKey: Key.cursorStyle) ?? "blinkBlock" }
        set {
            guard newValue != cursorStyleName else { return }
            d.set(newValue, forKey: Key.cursorStyle)
            let lower = newValue.lowercased()
            sync("cursor-style", lower.contains("bar") ? "bar" : lower.contains("underline") ? "underline" : "block")
            sync("cursor-blink", "\(newValue.hasPrefix("blink"))")
            changed()
        }
    }
    /// Amber-dot attention signals (BEL / OSC 9 / OSC 777 from unfocused
    /// panes). On unless the config says otherwise.
    public var attentionSignals: Bool {
        get { d.object(forKey: Key.attentionSignals) == nil ? true : d.bool(forKey: Key.attentionSignals) }
        set { guard newValue != attentionSignals else { return }
              d.set(newValue, forKey: Key.attentionSignals); sync("attention-signals", "\(newValue)"); changed() }
    }
    public var optionAsMeta: Bool {
        get { d.bool(forKey: Key.optionAsMeta) }
        set { guard newValue != optionAsMeta else { return }
              d.set(newValue, forKey: Key.optionAsMeta); sync("option-as-meta", "\(newValue)"); changed() }
    }
    public var showBanner: Bool {
        get { d.bool(forKey: Key.showBanner) }
        set { guard newValue != showBanner else { return }
              d.set(newValue, forKey: Key.showBanner); sync("banner", "\(newValue)"); changed() }
    }
    public var shellIntegration: Bool {
        get { d.bool(forKey: Key.shellIntegration) }
        set { guard newValue != shellIntegration else { return }
              d.set(newValue, forKey: Key.shellIntegration); sync("shell-integration", "\(newValue)"); changed() }
    }
    /// Minimal prompt (drops user@host, keeps the folder) installed by the
    /// shell integration. Users with a custom prompt can turn it off; changes
    /// take effect in newly opened panes.
    public var cleanPrompt: Bool {
        get { d.bool(forKey: Key.cleanPrompt) }
        set { guard newValue != cleanPrompt else { return }
              d.set(newValue, forKey: Key.cleanPrompt); sync("clean-prompt", "\(newValue)"); changed() }
    }
    /// Hide AppKit's native close/minimize/zoom controls.
    public var hideTrafficLights: Bool {
        get { d.bool(forKey: Key.hideTrafficLights) }
        set { guard newValue != hideTrafficLights else { return }
              d.set(newValue, forKey: Key.hideTrafficLights); sync("hide-traffic-lights", "\(newValue)"); changed() }
    }
    /// Native AppKit chrome follows the window inset: the tight presets use
    /// unifiedCompact, while roomier presets use unified. Keeping this derived
    /// prevents two appearance controls from contradicting one another.
    public static func nativeToolbarStyle(forContentMargin margin: CGFloat) -> String {
        margin <= 10 ? "compact" : "unified"
    }
    public var nativeToolbarStyle: String {
        Self.nativeToolbarStyle(forContentMargin: contentMargin)
    }
    /// Complete inset between the window edge and the terminal, in points
    /// (`margin` in the config). Small and Medium use compact native chrome;
    /// Large uses unified chrome. Native tab-row geometry remains AppKit-owned.
    public var contentMargin: CGFloat {
        get {
            guard d.object(forKey: Key.contentMargin) != nil else { return 10 }
            return CGFloat(min(60.0, max(0.0, d.double(forKey: Key.contentMargin))))
        }
        set { guard newValue != contentMargin else { return }
              d.set(Double(newValue), forKey: Key.contentMargin); sync("margin", num(newValue)); changed() }
    }
    /// Arrange visible terminal workspaces as recursive native window splits.
    /// The existing Window Inset is also the single gap between window frames.
    public var windowGridEnabled: Bool {
        get { d.bool(forKey: Key.windowGridEnabled) }
        set { guard newValue != windowGridEnabled else { return }
              d.set(newValue, forKey: Key.windowGridEnabled)
              sync("window-grid", "\(newValue)")
              changed() }
    }
    /// App-owned layout state. This intentionally does not post a preference
    /// notification: drag/resize persistence must not start another layout pass.
    public var windowGridStateData: Data? {
        get { d.data(forKey: Key.windowGridState) }
        set {
            if let newValue {
                d.set(newValue, forKey: Key.windowGridState)
            } else {
                d.removeObject(forKey: Key.windowGridState)
            }
        }
    }
    /// Window transparency, 0.3 (glass) … 1.0 (solid).
    public var opacity: Double {
        get { let v = d.double(forKey: Key.opacity); return v > 0 ? min(1.0, max(0.3, v)) : 1.0 }
        set { guard newValue != opacity else { return }
              d.set(newValue, forKey: Key.opacity); sync("opacity", num(CGFloat(newValue))); changed() }
    }
    /// Frost (blur) whatever is behind the window when it's translucent.
    public var blur: Bool {
        get { d.bool(forKey: Key.blur) }
        set { guard newValue != blur else { return }
              d.set(newValue, forKey: Key.blur); sync("blur", "\(newValue)"); changed() }
    }
    /// Fish-style inline history suggestion, accepted with →.
    public var ghostText: Bool {
        get { d.bool(forKey: Key.ghostText) }
        set { guard newValue != ghostText else { return }
              d.set(newValue, forKey: Key.ghostText); sync("ghost-text", "\(newValue)"); changed() }
    }
    /// Where the marketplace fetches its registry: an https URL, a file://
    /// URL, or a local path (MARKETPLACE.md; gates point this at a checkout).
    public static var defaultMarketplaceRegistry: String {
        ProductIdentity.current.marketplaceRegistryURL.absoluteString
    }

    public var marketplaceRegistry: String {
        get { d.string(forKey: Key.marketplaceRegistry)
                ?? Self.defaultMarketplaceRegistry }
        set { guard newValue != marketplaceRegistry else { return }
              d.set(newValue, forKey: Key.marketplaceRegistry)
              sync("marketplace-registry", newValue); changed() }
    }

    /// Daily registry checks only run when a marketplace receipt exists.
    public var marketplaceUpdateChecks: Bool {
        get { d.bool(forKey: Key.marketplaceUpdateChecks) }
        set { guard newValue != marketplaceUpdateChecks else { return }
              d.set(newValue, forKey: Key.marketplaceUpdateChecks)
              sync("marketplace-update-checks", "\(newValue)"); changed() }
    }

    /// Text editor used by app-owned open actions. The product slug selects the
    /// built-in editor, `system` asks macOS, and any other value is launched as
    /// a command with the file path appended (or substituted for `{file}`).
    public var editor: String {
        get { d.string(forKey: Key.editor) ?? ProductIdentity.current.slug }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = value.isEmpty ? ProductIdentity.current.slug : value
            guard normalized != editor else { return }
            d.set(normalized, forKey: Key.editor)
            sync("editor", normalized)
            changed()
        }
    }

    /// Left alternative presentation of the current native tab group.
    public var workspaceNavigatorVisible: Bool {
        get { d.bool(forKey: Key.workspaceNavigator) }
        set { guard newValue != workspaceNavigatorVisible else { return }
              d.set(newValue, forKey: Key.workspaceNavigator)
              sync("workspace-navigator", "\(newValue)"); changed() }
    }

    /// Right contextual tool inspector in the Adaptive Frame.
    public var workspaceInspectorVisible: Bool {
        get { d.bool(forKey: Key.workspaceInspector) }
        set { guard newValue != workspaceInspectorVisible else { return }
              d.set(newValue, forKey: Key.workspaceInspector)
              sync("workspace-inspector", "\(newValue)"); changed() }
    }

    /// Post-process shader gallery (GPU renderer only). Order = renderer mode
    /// number — append only, never reorder.
    public static let shaderNames = ["None", "CRT", "Scanlines", "Glow", "VHS",
                              "Dither", "Neon", "Plasma", "Glitch", "Ripple",
                              "Copper", "Starfield", "Matrix", "Fire", "Grid",
                              "Tunnel", "Rotozoom", "Wobble", "Aurora", "Lava",
                              "Boot", "Snow",
                              "Bubbles", "Rain", "Tron", "Radar", "Maze",
                              "Waves", "Plexus", "Vortex", "Blocks", "Lightning",
                              "Scroller", "Rasterbars", "ANSI", "Floor",
                              "Twister", "Moire",
                              // the calm set — slow, muted, ambient
                              "Drift", "Breath", "Lagoon", "Silk", "Ember",
                              "Fireflies", "Clouds", "Mist", "Deep", "Tide",
                              "Zen", "Lanterns", "Snowfall", "Petals", "Koi",
                              "Moss", "Dunes", "Horizon", "Rainfall", "Nebula",
                              "Comet", "Meadow", "Ink", "Marble", "Prism",
                              "Halo", "Waterline", "Slowscan", "Voronoi", "Eclipse",
                              // Text-only and scroll-reactive; idle is unchanged.
                              "Databloom"]
    public var shaderName: String {
        get {
            let v = d.string(forKey: Key.shader) ?? "None"
            if Self.shaderNames.contains(v) { return v }
            if v.hasPrefix("user/"), UserShaders.source(named: v) != nil { return v }
            return "None"
        }
        set { guard newValue != shaderName else { return }
              d.set(newValue, forKey: Key.shader); sync("shader", newValue); changed() }
    }
    /// The renderer's mode number for the current shader (0 = off,
    /// -1 = a runtime-compiled user shader).
    public var shaderMode: Int {
        if shaderName.hasPrefix("user/") { return -1 }
        return Self.shaderNames.firstIndex(of: shaderName) ?? 0
    }
    /// Neovide-style cursor glide — GPU renderer only.
    public var smoothCursor: Bool {
        get { d.bool(forKey: Key.smoothCursor) }
        set { guard newValue != smoothCursor else { return }
              d.set(newValue, forKey: Key.smoothCursor); sync("smooth-cursor", "\(newValue)"); changed() }
    }
    /// Multiplier for the cursor's exponential glide rate (0.1...8.0).
    public var cursorGlideSpeed: CGFloat {
        get {
            let value = d.double(forKey: Key.cursorGlideSpeed)
            return CGFloat(value > 0 ? min(8, max(0.1, value)) : 1.6)
        }
        set {
            let value = min(8, max(0.1, newValue))
            guard value != cursorGlideSpeed else { return }
            d.set(Double(value), forKey: Key.cursorGlideSpeed)
            sync("cursor-glide-speed", num(value)); changed()
        }
    }
    /// Maximum animated jump in cells. Zero disables the distance limit.
    public var cursorGlideMaxDistance: CGFloat {
        get { CGFloat(min(100, max(0, d.double(forKey: Key.cursorGlideMaxDistance)))) }
        set {
            let value = min(100, max(0, newValue))
            guard value != cursorGlideMaxDistance else { return }
            d.set(Double(value), forKey: Key.cursorGlideMaxDistance)
            sync("cursor-glide-max-distance", num(value)); changed()
        }
    }
    /// Animated scrollback scrolling — the content slides instead of jumping.
    /// Only the local scrollback path; TUIs (alt-screen/mouse) are unaffected.
    public var smoothScroll: Bool {
        get { d.bool(forKey: Key.smoothScroll) }
        set { guard newValue != smoothScroll else { return }
              d.set(newValue, forKey: Key.smoothScroll); sync("smooth-scroll", "\(newValue)"); changed() }
    }
    /// SID-flavored keypress blips + error buzz (off by default).
    public var sounds: Bool {
        get { d.bool(forKey: Key.sounds) }
        set { guard newValue != sounds else { return }
              d.set(newValue, forKey: Key.sounds); sync("sounds", "\(newValue)"); changed() }
    }
    /// Built-in plugin ids the user has switched off (skipped at launch).
    public var disabledPlugins: Set<String> {
        get { Set(d.stringArray(forKey: Key.disabledPlugins) ?? []) }
        set { guard newValue != disabledPlugins else { return }
              d.set(Array(newValue), forKey: Key.disabledPlugins); changed() }
    }
    func isPluginEnabled(_ id: String) -> Bool { !disabledPlugins.contains(id) }
    func setPlugin(_ id: String, enabled: Bool) {
        var set = disabledPlugins
        if enabled { set.remove(id) } else { set.insert(id) }
        disabledPlugins = set
    }

    /// Save windows/panes/cwd/scrollback on quit and restore them on launch.
    public var restoreSession: Bool {
        get { d.bool(forKey: Key.restoreSession) }
        set { guard newValue != restoreSession else { return }
              d.set(newValue, forKey: Key.restoreSession); sync("restore-session", "\(newValue)"); changed() }
    }
    /// Automatically explain failed semantic command blocks and offer a
    /// keyboard-reviewable next command. Explicit `# request` stays available
    /// when automatic help is disabled.
    public var automaticErrorHelp: Bool {
        get { d.bool(forKey: Key.automaticErrorHelp) }
        set { guard newValue != automaticErrorHelp else { return }
              d.set(newValue, forKey: Key.automaticErrorHelp)
              sync("automatic-error-help", "\(newValue)")
              changed() }
    }
    /// Anthropic key from the config file — Finder/Dock launches have no
    /// shell environment, so the env var alone is not enough.
    public var anthropicKey: String? {
        get { d.string(forKey: Key.anthropicKey) }
        set { guard newValue != anthropicKey else { return }
              d.set(newValue, forKey: Key.anthropicKey); changed() }
    }
    /// Model for all AI features (`ai-model` in the config).
    public var aiModel: String {
        get { d.string(forKey: Key.aiModel) ?? "claude-sonnet-4-6" }
        set { guard newValue != aiModel else { return }
              d.set(newValue, forKey: Key.aiModel); changed() }
    }

    public func resolvedFont() -> NSFont {
        if let f = NSFont(name: fontName, size: fontSize) { return f }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    public var cursorStyle: TermCursorStyle {
        switch cursorStyleName {
        case "steadyBlock": return .steadyBlock
        case "blinkUnderline": return .blinkUnderline
        case "steadyUnderline": return .steadyUnderline
        case "blinkBar": return .blinkBar
        case "steadyBar": return .steadyBar
        default: return .blinkBlock
        }
    }

    /// True while a menu is live-previewing values on hover — changes apply
    /// to the UI but are NOT persisted to the config file until committed.
    var isPreviewing = false

    /// Mirror a change into ~/.config/cmdy/config. The file wins at launch,
    /// so without this every menu/palette change was reverted on relaunch.
    /// (No-op while the config file itself is being applied, if none exists,
    /// or during menu hover previews.)
    private func sync(_ configKey: String, _ value: String) {
        guard !isPreviewing else { return }
        ConfigFile.writeBack(key: configKey, value: value)
    }

    /// Compact number formatting for the config file: 12, 0.85, 1.15.
    private func num(_ v: CGFloat) -> String {
        String(format: "%g", Double(v))
    }

    private var changeNotificationPending = false

    private func changed() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                Preferences.shared.scheduleChangeNotification()
            }
            return
        }
        scheduleChangeNotification()
    }

    private func scheduleChangeNotification() {
        guard !changeNotificationPending else { return }
        changeNotificationPending = true
        // Post on the next runloop tick: when a preference changes from a menu
        // item, the observers mutate the terminal view AND the menu — doing that
        // synchronously mid-menu-tracking can crash. Deferring runs them after
        // the menu dismisses. Coalescing also makes a multi-key config reload one
        // app-wide pane update instead of one full reflow per key.
        DispatchQueue.main.async {
            Preferences.shared.changeNotificationPending = false
            NotificationCenter.default.post(name: .cmdyPreferencesChanged, object: nil)
        }
    }
}
