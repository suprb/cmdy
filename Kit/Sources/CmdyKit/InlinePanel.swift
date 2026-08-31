import AppKit

/// Optional state outside Preferences that participates in the panel's
/// preview transaction. Cmdy uses this for tab-scoped theme/shader choices:
/// selection previews live, Escape restores the tab, and Return advances the
/// baseline so the kept choice survives dismissal.
public struct InlinePanelPreviewHooks {
    public let begin: () -> Void
    public let restore: () -> Void
    public let commit: () -> Void
    public let end: () -> Void

    public init(
        begin: @escaping () -> Void,
        restore: @escaping () -> Void,
        commit: @escaping () -> Void,
        end: @escaping () -> Void = {}
    ) {
        self.begin = begin
        self.restore = restore
        self.commit = commit
        self.end = end
    }
}

/// The in-terminal UI surface — everything that used to float in panels
/// (palette, AI compose, explain output, agent) renders HERE instead: docked
/// at the bottom of the pane, drawn in the terminal's font and theme, part of
/// the terminal rather than a window above it (Claude Code style).
///
/// Anatomy (all separated by thin rules, all monospace):
///   list rows      title (accent when selected) + right-aligned subtitle
///   ❯ input line   type to filter / to write a request
///   hint line      dim: keys, status, errors
///
/// Modes: .list (palette), .input (compose / agent goal), .text (readonly
/// output — explain, agent log). Esc backs out of palette sections and closes
/// at the root (unless busy); ⏎ acts.
public final class InlinePanel: NSView {

    enum Mode {
        case list
        case input
        case text
        case menu     // one horizontal reusable bottom-edge action row
        case tabs     // the Config Mixer: tabbed families, blend accumulates
        case editor   // multi-line live-coding buffer (codio): ⌘⏎ evaluates
    }

    private(set) var mode: Mode = .list

    // list mode — a NAVIGABLE TREE: sections descend (⏎/→), ← backs out,
    // breadcrumb at the prompt. Typing at the root searches every descendant.
    private var navStack: [(title: String, items: [PaletteItem])] = []
    private var allItems: [PaletteItem] { navStack.last?.items ?? [] }
    private var rootItems: [PaletteItem] { navStack.first?.items ?? [] }
    private var filtered: [PaletteItem] = []
    private var selected = 0
    private var listTop = 0   // first visible row — the list scrolls, all matches reachable
    // text mode
    private var textLines: [String] = []
    private var scrollOffset = 0
    private var textTitle = ""
    // input
    private var query = ""
    private var placeholder = ""
    private var hint = ""
    private var busy = false
    private var menuTitle = ""
    private var menuItems: [BottomMenuItem] = []
    private var menuSelection = 0
    private var menuFrames: [NSRect] = []
    public var onMenuAction: ((String) -> Void)?
    private var navigationMemoryKey: String?
    /// Rebuilds dynamic labels (ON/OFF, current values) after returning from a
    /// settings section without closing the palette.
    private var listItemsProvider: (() -> [PaletteItem])?
    /// Settings committed with Return remain visibly pinned while the palette
    /// stays open. The key is the current tree path.
    private var keptListTitles: [String: String] = [:]

    private static let navigationDefaultsKey = "cmdy.inline-panel.navigation.v1"

    private static func rememberedValue(for key: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: navigationDefaultsKey) as? [String: String])?[key]
    }

    private static func remember(_ value: String, for key: String) {
        var values = UserDefaults.standard.dictionary(forKey: navigationDefaultsKey)
            as? [String: String] ?? [:]
        values[key] = value
        UserDefaults.standard.set(values, forKey: navigationDefaultsKey)
    }

    public var onSubmit: ((String) -> Void)?      // input mode ⏎
    public var onPick: ((PaletteItem) -> Void)?   // list mode ⏎ / click
    public var onDismiss: (() -> Void)?
    /// Fired whenever the panel's needed height changes — the host pane
    /// reserves that strip (bottomContentInset) so content pushes up.
    public var onHeightChanged: ((CGFloat) -> Void)?
    /// Extra key hook (agent: ^C stops the session). Return true if handled.
    public var onKey: ((NSEvent) -> Bool)?

    // theme snapshot, taken when presented
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var bg = NSColor.black
    private var fg = NSColor.white
    private var accent = NSColor.systemBlue
    private let rowTextLayout = TerminalRowTextLayout()

    /// The host pane's grid metrics — the panel uses the SAME line height,
    /// left origin, and text baseline as the terminal grid.
    public var metrics: (() -> (
        font: NSFont,
        rowHeight: CGFloat,
        originX: CGFloat,
        baselineFromTop: CGFloat
    ))?
    /// A tab-scoped theme supplied by the host. Nil follows global appearance.
    public var themeOverride: Theme? {
        didSet {
            applyTheme()
            relayout()
        }
    }

    private let maxListRows = 12
    private let maxTextRows = 14
    private var metricRowHeight: CGFloat = 0
    private var metricBaselineFromTop: CGFloat = 0
    private var rowHeight: CGFloat {
        metricRowHeight > 0 ? metricRowHeight : ceil(font.boundingRectForFont.height * 1.15)
    }
    // Horizontal padding follows the terminal grid's true column-zero origin,
    // including its centering remainder. Vertical padding must instead follow
    // the configured window inset exactly; reusing originX made the palette
    // jump vertically whenever a resize changed the column remainder.
    private var padX: CGFloat = 10
    private var padY: CGFloat = 10

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    private var prefsObserver: NSObjectProtocol?
    private var cursorPulseTimer: Timer?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        // Previews restyle the app (theme/font/…) while this panel is up —
        // follow along so the panel itself renders in the previewed look.
        prefsObserver = NotificationCenter.default.addObserver(
            forName: .cmdyPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
            self?.relayout()
        }
    }
    public required init?(coder: NSCoder) { fatalError("not supported") }
    deinit {
        cursorPulseTimer?.invalidate()
        if let o = prefsObserver { NotificationCenter.default.removeObserver(o) }
    }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { updateCursorPulseTimer() }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        cursorPulseTimer?.invalidate()
        cursorPulseTimer = nil
        return super.resignFirstResponder()
    }

    // MARK: - Live preview (settings rows apply while selected; ⏎ keeps, esc reverts)

    private struct PreferencesSnapshot {
        var theme: String
        var font: String
        var shader: String
        var cursor: String
        var lineHeight: CGFloat
        var textRenderingMode: String
        var cursorGlideSpeed: CGFloat
        var cursorGlideMaxDistance: CGFloat
        var contentMargin: CGFloat
        var hideTrafficLights: Bool
        var smoothCursor: Bool
        var smoothScroll: Bool
        var sounds: Bool
        var ghostText: Bool
        var automaticErrorHelp: Bool
        var showBanner: Bool
    }
    private var prefsSnapshot: PreferencesSnapshot?
    private var previewHooks: InlinePanelPreviewHooks?

    private func currentPreferencesSnapshot() -> PreferencesSnapshot {
        let p = Preferences.shared
        return PreferencesSnapshot(
            theme: p.themeName,
            font: p.fontName,
            shader: p.shaderName,
            cursor: p.cursorStyleName,
            lineHeight: p.lineHeight,
            textRenderingMode: p.textRenderingMode,
            cursorGlideSpeed: p.cursorGlideSpeed,
            cursorGlideMaxDistance: p.cursorGlideMaxDistance,
            contentMargin: p.contentMargin,
            hideTrafficLights: p.hideTrafficLights,
            smoothCursor: p.smoothCursor,
            smoothScroll: p.smoothScroll,
            sounds: p.sounds,
            ghostText: p.ghostText,
            automaticErrorHelp: p.automaticErrorHelp,
            showBanner: p.showBanner
        )
    }

    private func snapshotPrefsIfNeeded() {
        guard PaletteItem.flatten(rootItems).contains(where: { $0.preview != nil })
        else { prefsSnapshot = nil; return }
        prefsSnapshot = currentPreferencesSnapshot()
        previewHooks?.begin()
    }

    private func applySnapshot() {
        guard let s = prefsSnapshot else { return }
        let p = Preferences.shared
        p.isPreviewing = true
        if p.themeName != s.theme { p.themeName = s.theme }
        if p.fontName != s.font { p.fontName = s.font }
        if p.shaderName != s.shader { p.shaderName = s.shader }
        if p.cursorStyleName != s.cursor { p.cursorStyleName = s.cursor }
        if abs(p.lineHeight - s.lineHeight) > 0.001 { p.lineHeight = s.lineHeight }
        if p.textRenderingMode != s.textRenderingMode {
            p.textRenderingMode = s.textRenderingMode
        }
        if abs(p.cursorGlideSpeed - s.cursorGlideSpeed) > 0.001 { p.cursorGlideSpeed = s.cursorGlideSpeed }
        if abs(p.cursorGlideMaxDistance - s.cursorGlideMaxDistance) > 0.001 { p.cursorGlideMaxDistance = s.cursorGlideMaxDistance }
        if abs(p.contentMargin - s.contentMargin) > 0.001 { p.contentMargin = s.contentMargin }
        if p.hideTrafficLights != s.hideTrafficLights { p.hideTrafficLights = s.hideTrafficLights }
        if p.smoothCursor != s.smoothCursor { p.smoothCursor = s.smoothCursor }
        if p.smoothScroll != s.smoothScroll { p.smoothScroll = s.smoothScroll }
        if p.sounds != s.sounds { p.sounds = s.sounds }
        if p.ghostText != s.ghostText { p.ghostText = s.ghostText }
        if p.automaticErrorHelp != s.automaticErrorHelp { p.automaticErrorHelp = s.automaticErrorHelp }
        if p.showBanner != s.showBanner { p.showBanner = s.showBanner }
        p.isPreviewing = false
        previewHooks?.restore()
    }

    private func restoreAndForgetSnapshot() {
        applySnapshot()
        prefsSnapshot = nil
        previewHooks?.end()
        previewHooks = nil
    }

    private func previewSelection() {
        guard mode == .list || mode == .tabs, prefsSnapshot != nil, selected < filtered.count else { return }
        if let preview = filtered[selected].preview {
            Preferences.shared.isPreviewing = true
            preview()
            Preferences.shared.isPreviewing = false
        } else if mode == .list {
            applySnapshot()   // browsed onto a plain action — show the saved look
        }
        // .tabs: never restore while mixing — the blend accumulates.
    }

    // MARK: - Configuration

    func applyTheme() {
        let theme = themeOverride ?? Preferences.shared.theme
        if let m = metrics?() {
            font = m.font
            // Match the terminal grid exactly. Tight line spacing may be
            // smaller than the font's bounding box; clamping here made Tight
            // and Snug look identical inside the palette.
            metricRowHeight = max(1, m.rowHeight)
            metricBaselineFromTop = min(
                metricRowHeight,
                max(0, m.baselineFromTop)
            )
            padX = max(0, m.originX)
        } else {
            font = Preferences.shared.resolvedFont()
            metricBaselineFromTop = 0
        }
        padY = max(0, Preferences.shared.contentMargin)
        bg = theme.ns(theme.background)
        fg = theme.ns(theme.foreground)
        // The theme's blue as the accent (Claude Code's slash-command tint).
        accent = theme.ns(theme.ansi[12])
        updateCursorPulseTimer()
        needsDisplay = true
    }

    private func updateCursorPulseTimer() {
        let shouldPulse = Preferences.shared.cursorStyleName.hasPrefix("blink")
            && window?.firstResponder === self
        guard shouldPulse else {
            cursorPulseTimer?.invalidate()
            cursorPulseTimer = nil
            return
        }
        guard cursorPulseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, self.window?.firstResponder === self,
                  self.window?.occlusionState.contains(.visible) == true else { return }
            self.needsDisplay = true
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        cursorPulseTimer = timer
    }

    /// Re-read the host grid after a live font or line-height change.
    public func refreshMetrics() {
        applyTheme()
        relayout()
    }

    public func configureList(
        items: [PaletteItem],
        placeholder: String,
        hint: String,
        memoryKey: String? = nil,
        itemsProvider: (() -> [PaletteItem])? = nil,
        previewHooks: InlinePanelPreviewHooks? = nil
    ) {
        restoreAndForgetSnapshot()
        mode = .list
        self.previewHooks = previewHooks
        navigationMemoryKey = memoryKey
        listItemsProvider = itemsProvider
        navStack = [("", items)]
        filtered = items
        query = ""
        busy = false
        keptListTitles = [:]
        self.placeholder = placeholder
        self.hint = hint
        restoreRememberedSelection()
        snapshotPrefsIfNeeded()
        applyTheme()
        relayout()
    }

    private var breadcrumb: String {
        let path = navStack.dropFirst().map(\.title)
        return path.isEmpty ? "" : path.joined(separator: " › ") + " › "
    }

    private func descend(into item: PaletteItem) {
        guard let kids = item.children else { return }
        rememberCurrentSelection()
        navStack.append((item.title, kids))
        query = ""
        filtered = kids
        restoreRememberedSelection(
            fallback: max(0, kids.firstIndex { $0.subtitle == "current" } ?? 0))
        previewSelection()
        relayout()
    }

    private func popLevel() {
        guard navStack.count > 1 else { return }
        rememberCurrentSelection()
        navStack.removeLast()
        refreshDynamicItemsAtCurrentPath()
        query = ""
        filtered = allItems
        restoreRememberedSelection()
        previewSelection()
        relayout()
    }

    private func refreshDynamicItemsAtCurrentPath() {
        guard let listItemsProvider else { return }
        let path = navStack.dropFirst().map(\.title)
        var items = listItemsProvider()
        var rebuilt: [(title: String, items: [PaletteItem])] = [("", items)]
        for title in path {
            guard let section = items.first(where: { $0.title == title }),
                  let children = section.children else { break }
            rebuilt.append((title, children))
            items = children
        }
        navStack = rebuilt
    }

    private var navigationLevel: String {
        if mode == .tabs, tabs.indices.contains(activeTab) {
            return "tab:\(tabs[activeTab].title)"
        }
        let path = navStack.dropFirst().map(\.title)
        return path.isEmpty ? "root" : path.joined(separator: " › ")
    }

    private func memorySlot(level: String? = nil) -> String? {
        guard let navigationMemoryKey else { return nil }
        return "\(navigationMemoryKey)::\(level ?? navigationLevel)"
    }

    private func rememberCurrentSelection() {
        guard query.isEmpty, filtered.indices.contains(selected),
              let slot = memorySlot() else { return }
        Self.remember(filtered[selected].title, for: slot)
    }

    private func restoreRememberedSelection(fallback: Int = 0) {
        let remembered = memorySlot().flatMap(Self.rememberedValue(for:))
        selected = remembered.flatMap { title in filtered.firstIndex { $0.title == title } }
            ?? min(max(0, fallback), max(0, filtered.count - 1))
        listTop = max(0, min(selected - maxListRows + 1,
                             max(0, filtered.count - maxListRows)))
    }

    // MARK: - Editor (multi-line live coding — codio)

    private var editorLines: [String] = [""]
    private var editorCursor = (row: 0, col: 0)
    private var editorTop = 0                    // first visible line
    private var editorTitle = ""
    private let maxEditorRows = 14
    /// ⌘⏎ hands the whole buffer here (codio evaluates it live).
    public var onEvaluate: ((String) -> Void)?
    /// Buffer changed (host autosaves).
    var onBufferChanged: ((String) -> Void)?

    public func configureEditor(title: String, body: String, hint: String) {
        mode = .editor
        navigationMemoryKey = nil
        listItemsProvider = nil
        editorTitle = title
        editorLines = body.isEmpty ? [""] : body.components(separatedBy: "\n")
        editorCursor = (max(0, editorLines.count - 1), editorLines.last?.count ?? 0)
        editorTop = max(0, editorLines.count - maxEditorRows)
        query = ""
        busy = false
        self.hint = hint
        applyTheme()
        relayout()
    }

    var editorText: String { editorLines.joined(separator: "\n") }

    private func editorInsert(_ s: String) {
        var line = editorLines[editorCursor.row]
        let idx = line.index(line.startIndex, offsetBy: min(editorCursor.col, line.count))
        line.insert(contentsOf: s, at: idx)
        editorLines[editorCursor.row] = line
        editorCursor.col += s.count
        editorEdited()
    }

    private func editorNewline() {
        let line = editorLines[editorCursor.row]
        let idx = line.index(line.startIndex, offsetBy: min(editorCursor.col, line.count))
        editorLines[editorCursor.row] = String(line[..<idx])
        editorLines.insert(String(line[idx...]), at: editorCursor.row + 1)
        editorCursor = (editorCursor.row + 1, 0)
        editorEdited()
    }

    private func editorBackspace() {
        if editorCursor.col > 0 {
            var line = editorLines[editorCursor.row]
            let idx = line.index(line.startIndex, offsetBy: editorCursor.col)
            line.remove(at: line.index(before: idx))
            editorLines[editorCursor.row] = line
            editorCursor.col -= 1
        } else if editorCursor.row > 0 {
            let removed = editorLines.remove(at: editorCursor.row)
            editorCursor.row -= 1
            editorCursor.col = editorLines[editorCursor.row].count
            editorLines[editorCursor.row] += removed
        }
        editorEdited()
    }

    private func editorMove(rows: Int, cols: Int) {
        if rows != 0 {
            editorCursor.row = min(max(0, editorCursor.row + rows), editorLines.count - 1)
            editorCursor.col = min(editorCursor.col, editorLines[editorCursor.row].count)
        }
        if cols != 0 {
            let next = editorCursor.col + cols
            if next < 0, editorCursor.row > 0 {
                editorCursor.row -= 1
                editorCursor.col = editorLines[editorCursor.row].count
            } else if next > editorLines[editorCursor.row].count, editorCursor.row < editorLines.count - 1 {
                editorCursor.row += 1
                editorCursor.col = 0
            } else {
                editorCursor.col = min(max(0, next), editorLines[editorCursor.row].count)
            }
        }
        if editorCursor.row < editorTop { editorTop = editorCursor.row }
        if editorCursor.row >= editorTop + maxEditorRows { editorTop = editorCursor.row - maxEditorRows + 1 }
        needsDisplay = true
    }

    private func editorKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53:   // esc — hide the editor (the host decides if audio keeps playing)
            dismiss()
            return
        case 36, 76:   // return: ⌘⏎ evaluates the buffer, plain ⏎ = newline
            if event.modifierFlags.contains(.command) {
                onEvaluate?(editorText)
            } else {
                editorNewline()
            }
            return
        case 51: editorBackspace(); return
        case 123: editorMove(rows: 0, cols: -1); return
        case 124: editorMove(rows: 0, cols: 1); return
        case 126: editorMove(rows: -1, cols: 0); return
        case 125: editorMove(rows: 1, cols: 0); return
        case 48: editorInsert("  "); return   // tab → two spaces
        default: break
        }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v",
               let s = NSPasteboard.general.string(forType: .string) {
                for (i, part) in s.components(separatedBy: "\n").enumerated() {
                    if i > 0 { editorNewline() }
                    editorInsert(part)
                }
                return
            }
            super.keyDown(with: event)
            return
        }
        if let chars = event.characters, !chars.isEmpty,
           !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            editorInsert(chars)
        }
    }

    private func editorEdited() {
        if editorCursor.row < editorTop { editorTop = editorCursor.row }
        if editorCursor.row >= editorTop + maxEditorRows { editorTop = editorCursor.row - maxEditorRows + 1 }
        onBufferChanged?(editorText)
        relayout()
    }

    // MARK: - Tabs (Config Mixer)

    private var tabs: [(title: String, items: [PaletteItem])] = []
    private var activeTab = 0
    private var tabXRanges: [ClosedRange<CGFloat>] = []   // hit-test, filled in draw
    /// ⏎-pinned picks per tab (title). Pinned families are committed to the
    /// config immediately and survive esc; un-pinned previews revert.
    private var pinnedTitles: [Int: String] = [:]

    public func configureTabs(
        tabs: [(title: String, items: [PaletteItem])],
        hint: String,
        memoryKey: String? = nil,
        previewHooks: InlinePanelPreviewHooks? = nil
    ) {
        restoreAndForgetSnapshot()
        mode = .tabs
        self.previewHooks = previewHooks
        navigationMemoryKey = memoryKey
        listItemsProvider = nil
        self.tabs = tabs
        let rememberedTab = memoryKey.flatMap {
            Self.rememberedValue(for: "\($0)::active-tab")
        }
        activeTab = rememberedTab.flatMap { title in tabs.firstIndex { $0.title == title } } ?? 0
        pinnedTitles = [:]
        query = ""
        busy = false
        placeholder = "filter…"
        self.hint = hint
        navStack = [("", tabs.flatMap { $0.items })]   // snapshot pool
        snapshotPrefsIfNeeded()
        filtered = []
        switchTab(to: activeTab, rememberingCurrent: false)
        applyTheme()
    }

    private func switchTab(to index: Int, rememberingCurrent: Bool = true) {
        guard !tabs.isEmpty else { return }
        if rememberingCurrent { rememberCurrentSelection() }
        activeTab = (index + tabs.count) % tabs.count
        if let navigationMemoryKey {
            Self.remember(tabs[activeTab].title,
                          for: "\(navigationMemoryKey)::active-tab")
        }
        query = ""
        filtered = tabs[activeTab].items
        // Land on the current value so ↑↓ starts from what's active.
        restoreRememberedSelection(
            fallback: max(0, filtered.firstIndex { $0.subtitle == "current" } ?? 0))
        previewSelection()
        relayout()
    }

    /// ⏎ in tabs mode: PIN the selection and stay — the family is committed
    /// to the config right away and the revert snapshot is updated so esc
    /// keeps it. You never leave the mixer by choosing.
    private func pinCurrentSelection() {
        guard selected < filtered.count else { return }
        let p = Preferences.shared
        switch tabs[activeTab].title {
        case "Theme":
            if previewHooks == nil {
                ConfigFile.writeBack(key: "theme", value: p.themeName)
                prefsSnapshot?.theme = p.themeName
            }
        case "Font":
            ConfigFile.writeBack(key: "font-family", value: p.fontName)
            prefsSnapshot?.font = p.fontName
        case "Shader":
            if previewHooks == nil {
                ConfigFile.writeBack(key: "shader", value: p.shaderName)
                prefsSnapshot?.shader = p.shaderName
            }
        case "Cursor":
            let lower = p.cursorStyleName.lowercased()
            ConfigFile.writeBack(key: "cursor-style",
                                 value: lower.contains("bar") ? "bar" : lower.contains("underline") ? "underline" : "block")
            ConfigFile.writeBack(key: "cursor-blink", value: "\(p.cursorStyleName.hasPrefix("blink"))")
            prefsSnapshot?.cursor = p.cursorStyleName
        case "Spacing":
            ConfigFile.writeBack(key: "line-height", value: String(format: "%g", Double(p.lineHeight)))
            prefsSnapshot?.lineHeight = p.lineHeight
        default:
            break
        }
        previewHooks?.commit()
        pinnedTitles[activeTab] = filtered[selected].title
        hint = "✓ \(filtered[selected].title) kept — keep mixing · esc / ← when done"
        needsDisplay = true
    }

    public func configureInput(placeholder: String, hint: String) {
        mode = .input
        navigationMemoryKey = nil
        listItemsProvider = nil
        query = ""
        busy = false
        self.placeholder = placeholder
        self.hint = hint
        applyTheme()
        relayout()
    }

    public func configureText(title: String, body: String, hint: String) {
        mode = .text
        navigationMemoryKey = nil
        listItemsProvider = nil
        textTitle = title
        textLines = []
        scrollOffset = 0
        busy = false
        self.hint = hint
        applyTheme()
        setBody(body)
    }

    /// Configure a compact horizontal action menu at the pane's bottom edge.
    /// ←/→ moves, Return activates, shortcut keys activate directly, and
    /// ↑/Esc returns focus to the terminal by dismissing the menu.
    public func configureMenu(title: String, items: [BottomMenuItem],
                              hint: String = "") {
        mode = .menu
        navigationMemoryKey = nil
        listItemsProvider = nil
        menuTitle = title
        menuItems = items
        menuSelection = items.firstIndex(where: \.isEnabled) ?? 0
        menuFrames = []
        query = ""
        busy = false
        self.hint = hint
        applyTheme()
        relayout()
    }

    /// Replace the text body (streamed updates: Thinking… → result).
    public func setBody(_ body: String) {
        guard mode == .text else { return }
        textLines = Self.wrap(body, font: font, width: max(100, bounds.width - padX * 2))
        scrollOffset = 0
        relayout()
    }

    public func appendLine(_ line: String) {
        guard mode == .text else { return }
        textLines.append(contentsOf: Self.wrap(line, font: font, width: max(100, bounds.width - padX * 2)))
        scrollOffset = max(0, textLines.count - maxTextRows)   // follow the tail
        relayout()
    }

    /// Input mode: waiting on the AI — input freezes, the hint carries status.
    public func setBusy(_ status: String) {
        busy = true
        hint = status
        needsDisplay = true
    }

    public func fail(_ message: String) {
        busy = false
        hint = message
        needsDisplay = true
    }

    public func setHint(_ text: String) {
        let changesSectionHeight = hint.isEmpty != text.isEmpty
        hint = text
        if changesSectionHeight { relayout() } else { needsDisplay = true }
    }

    // MARK: - Sizing

    private var visibleListRows: Int { min(filtered.count, maxListRows) }
    private var renderedListRows: Int { max(1, visibleListRows) } // "no matches" occupies a row
    private var visibleTextRows: Int { min(textLines.count, maxTextRows) }

    public override var intrinsicContentSize: NSSize {
        let bodyHeight: CGFloat
        switch mode {
        case .list:
            // Results and query are independent padded sections separated by
            // a full-width rule.
            bodyHeight = 2 + padY * 4 + (CGFloat(renderedListRows) + 1) * rowHeight
        case .tabs:
            bodyHeight = 2 + padY * 4 + (CGFloat(renderedListRows) + 2) * rowHeight
        case .input:
            bodyHeight = 1 + padY * 2 + rowHeight
        case .text:
            bodyHeight = 1 + padY * 2 + (CGFloat(visibleTextRows) + 1) * rowHeight
        case .menu:
            bodyHeight = 1 + padY * 2 + rowHeight
        case .editor:
            let rows = CGFloat(min(max(editorLines.count, 4), maxEditorRows)) + 1
            bodyHeight = 1 + padY * 2 + rows * rowHeight
        }
        let footerHeight = hint.isEmpty ? 0 : 1 + padY + rowHeight + padY
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: bodyHeight + footerHeight)
    }

    private func relayout() {
        invalidateIntrinsicContentSize()
        onHeightChanged?(intrinsicContentSize.height)
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        if mode == .text, !textLines.isEmpty {
            // re-wrap to the real width once constraints resolve
            let joined = textLines.joined(separator: "\n")
            textLines = Self.wrap(joined, font: font, width: max(100, bounds.width - padX * 2))
        }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        // No opaque card: the terminal reserves this strip (content pushed
        // up), so the live shader shows through — just a light scrim for
        // legibility over busy backdrops.
        bg.withAlphaComponent(0.38).setFill()
        bounds.fill()

        let rule = fg.withAlphaComponent(0.18)
        let dim = fg.withAlphaComponent(0.55)
        let faint = fg.withAlphaComponent(0.38)

        func hline(_ y: CGFloat) {
            rule.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        }
        func text(_ s: String, x: CGFloat, y: CGFloat, color: NSColor,
                  maxWidth: CGFloat? = nil, verticalOffset: CGFloat = 0) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            var str = s
            if let mw = maxWidth {
                while str.count > 1 && (str as NSString).size(withAttributes: attrs).width > mw {
                    str = String(str.dropLast(2)) + "…"
                }
            }
            attrs[.ligature] = 0
            (str as NSString).draw(at: NSPoint(
                x: x,
                y: textOriginY(rowTop: y) + verticalOffset),
                                   withAttributes: attrs)
        }

        // Separators are the palette's edge-to-edge border; content below is
        // padded independently, matching the CSS border-box model.
        hline(0)
        var y: CGFloat = padY + 1

        if mode == .tabs {
            // Tab bar: titles in a row, active one banded + accented.
            tabXRanges = []
            var x = padX
            for (i, tab) in tabs.enumerated() {
                let title = " \(tab.title) "
                let w = (title as NSString).size(withAttributes: [.font: font]).width
                if i == activeTab {
                    let lineFrame = cursorVerticalFrame(rowTop: y)
                    fg.withAlphaComponent(0.14).setFill()
                    NSRect(x: x - 2, y: lineFrame.minY,
                           width: w + 4, height: lineFrame.height).fill()
                }
                text(title, x: x, y: y, color: i == activeTab ? accent : dim)
                tabXRanges.append(x...(x + w))
                x += w + rowHeight * 0.8
            }
            y += rowHeight
        }

        switch mode {
        case .list, .tabs:
            // A stable second column keeps rich descriptions useful without
            // letting every row's text start at a different position.
            let preferredSubtitleX = max(padX + 160, floor(bounds.width * 0.56))
            let subtitleX = min(preferredSubtitleX, max(padX + 80, bounds.width - padX - 80))
            let titleWidth = max(40, subtitleX - padX * 2)
            let sectionArrow = "▸"
            let arrowWidth = subtitleWidth(sectionArrow)
            let arrowX = bounds.width - padX - arrowWidth
            let listStartY = y
            let visible = filtered.dropFirst(listTop).prefix(maxListRows)
            for (offset, item) in visible.enumerated() {
                let isSel = listTop + offset == selected
                if isSel {
                    // Keep the highlight on the same natural line box as the
                    // label. With airy line spacing a full grid-row band makes
                    // the baseline look visibly low inside the selection.
                    let lineFrame = cursorVerticalFrame(rowTop: y)
                    fg.withAlphaComponent(0.14).setFill()
                    NSRect(x: padX, y: lineFrame.minY,
                           width: max(0, bounds.width - padX * 2),
                           height: lineFrame.height).fill()
                }
                text(item.title, x: padX, y: y,
                     color: isSel ? accent : fg,
                     maxWidth: titleWidth)
                var sub = item.subtitle
                if mode == .list, let kept = keptListTitles[navigationLevel] {
                    if kept == item.title { sub = "✓ kept" }
                    else if item.subtitle == "current" { sub = "" }
                }
                if mode == .tabs, pinnedTitles[activeTab] == item.title {
                    sub = "✓ kept"
                }
                let subtitleRight = item.children != nil
                    ? arrowX - max(6, padX * 0.6)
                    : bounds.width - padX
                let subtitleMaxWidth = max(0, subtitleRight - subtitleX)
                if !sub.isEmpty, subtitleMaxWidth > 12 {
                    text(sub, x: subtitleX, y: y,
                         color: isSel ? dim : faint, maxWidth: subtitleMaxWidth)
                }
                if item.children != nil {
                    text(sectionArrow, x: arrowX, y: y,
                         color: isSel ? dim : faint)
                }
                y += rowHeight
            }
            if filtered.isEmpty {
                text("no matches", x: padX, y: y, color: faint)
                y += rowHeight
            }
            if filtered.count > maxListRows {
                drawScrollIndicator(
                    top: listStartY,
                    height: CGFloat(maxListRows) * rowHeight,
                    first: listTop,
                    visible: maxListRows,
                    total: filtered.count,
                    color: faint)
            }
            // More matches than fit → position counter on the input row.
            if filtered.count > maxListRows {
                let counter = "\(selected + 1)/\(filtered.count)"
                text(counter, x: bounds.width - padX - subtitleWidth(counter),
                     y: y + padY + 1, color: faint)
            }
            y += padY
            hline(y)
            y += 1 + padY
            drawInputLine(at: &y, dim: dim, faint: faint)
            y += padY

        case .input:
            drawInputLine(at: &y, dim: dim, faint: faint)
            y += padY

        case .text:
            text(textTitle, x: padX, y: y, color: accent)
            y += rowHeight
            let textStartY = y
            for line in textLines.dropFirst(scrollOffset).prefix(maxTextRows) {
                text(line, x: padX, y: y, color: fg)
                y += rowHeight
            }
            if textLines.count > maxTextRows {
                drawScrollIndicator(
                    top: textStartY,
                    height: CGFloat(maxTextRows) * rowHeight,
                    first: scrollOffset,
                    visible: maxTextRows,
                    total: textLines.count,
                    color: faint)
            }
            y += padY

        case .menu:
            var x = padX
            if !menuTitle.isEmpty {
                text(menuTitle, x: x, y: y, color: dim)
                x += subtitleWidth(menuTitle) + max(8, rowHeight * 0.55)
            }
            menuFrames = []
            for (index, item) in menuItems.enumerated() {
                let label = item.shortcut.map { "[\($0)] \(item.title)" } ?? item.title
                let width = ceil(subtitleWidth(label)) + 12
                let frame = NSRect(x: x, y: y, width: width, height: rowHeight)
                menuFrames.append(frame)
                if index == menuSelection {
                    let lineFrame = cursorVerticalFrame(rowTop: y)
                    fg.withAlphaComponent(0.14).setFill()
                    NSRect(x: frame.minX, y: lineFrame.minY,
                           width: frame.width, height: lineFrame.height).fill()
                }
                text(label, x: x + 6, y: y,
                     color: item.isEnabled
                        ? (index == menuSelection ? accent : fg)
                        : faint)
                x += width + 4
            }
            y += rowHeight + padY

        case .editor:
            text(editorTitle, x: padX, y: y, color: accent)
            y += rowHeight
            let visible = min(max(editorLines.count, 4), maxEditorRows)
            let charW = ("M" as NSString).size(withAttributes: [.font: font]).width
            for offset in 0..<visible {
                let lineIx = editorTop + offset
                if lineIx < editorLines.count {
                    text(editorLines[lineIx], x: padX, y: y, color: fg)
                    if lineIx == editorCursor.row, !busy {
                        let cx = padX + charW * CGFloat(editorCursor.col)
                        let cursorFrame = cursorVerticalFrame(rowTop: y)
                        fg.withAlphaComponent(0.8).setFill()
                        NSRect(x: cx, y: cursorFrame.minY,
                               width: max(6, charW),
                               height: cursorFrame.height).fill()
                        // redraw the character under the block cursor, inverted
                        if editorCursor.col < editorLines[lineIx].count {
                            let ch = String(Array(editorLines[lineIx])[editorCursor.col])
                            (ch as NSString).draw(
                                at: NSPoint(x: cx, y: textOriginY(rowTop: y)),
                                withAttributes: [.font: font, .foregroundColor: bg])
                        }
                    }
                }
                y += rowHeight
            }
            y += padY
        }

        if !hint.isEmpty {
            let footerY = y
            hline(footerY)
            text(hint, x: padX, y: footerY + 1 + padY,
                 color: busy ? dim : faint, maxWidth: bounds.width - padX * 2)
        }
    }

    private func subtitleWidth(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    private func drawScrollIndicator(top: CGFloat, height: CGFloat, first: Int,
                                     visible: Int, total: Int, color: NSColor) {
        guard total > visible, height > 0 else { return }
        let width: CGFloat = 2
        let x = max(padX, bounds.width - padX - width)
        color.withAlphaComponent(0.18).setFill()
        NSRect(x: x, y: top, width: width, height: height).fill()

        let thumbHeight = max(rowHeight, height * CGFloat(visible) / CGFloat(total))
        let travel = max(0, height - thumbHeight)
        let denominator = max(1, total - visible)
        let thumbY = top + travel * CGFloat(first) / CGFloat(denominator)
        color.withAlphaComponent(0.72).setFill()
        NSRect(x: x, y: thumbY, width: width, height: thumbHeight).fill()
    }

    private func drawInputLine(at y: inout CGFloat, dim: NSColor, faint: NSColor) {
        // Breadcrumb shows where you are in the tree: "❯ Appearance › Fonts › "
        let promptStr = "❯ " + (mode == .list ? breadcrumb : "")
        let promptW = (promptStr as NSString).size(withAttributes: [.font: font]).width
        let textY = textOriginY(rowTop: y)
        (promptStr as NSString).draw(
            at: NSPoint(x: padX, y: textY),
            withAttributes: [.font: font, .foregroundColor: accent])
        let cursorW = max(6, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let qw = (query as NSString).size(withAttributes: [.font: font]).width
        if !busy {
            let style = Preferences.shared.cursorStyleName.lowercased()
            let pulse = style.hasPrefix("blink")
                ? CGFloat(0.5 * (1.0 + cos(2.0 * Double.pi
                    * CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1.2) / 1.2)))
                : 1
            fg.withAlphaComponent(0.8 * pulse).setFill()
            let x = padX + promptW + qw + 1
            let cursorFrame = cursorVerticalFrame(rowTop: y)
            if style.contains("bar") {
                NSRect(x: x, y: cursorFrame.minY,
                       width: 2, height: cursorFrame.height).fill()
            } else if style.contains("underline") {
                NSRect(x: x, y: cursorFrame.maxY - 2,
                       width: cursorW, height: 2).fill()
            } else {
                NSRect(x: x, y: cursorFrame.minY,
                       width: cursorW, height: cursorFrame.height).fill()
            }
        }
        let shown = query.isEmpty ? placeholder : query
        let color = query.isEmpty ? faint : fg
        // empty query: the placeholder starts after the cursor, not under it
        let textX = padX + promptW + (query.isEmpty && !busy ? cursorW + 5 : 0)
        (shown as NSString).draw(
            at: NSPoint(x: textX, y: textY),
            withAttributes: [.font: font, .foregroundColor: color])
        y += rowHeight
    }

    private func textOriginY(rowTop: CGFloat) -> CGFloat {
        rowTextLayout.drawOriginY(
            rowTop: rowTop,
            baselineFromTop: textBaselineFromTop,
            font: font)
    }

    private var textBaselineFromTop: CGFloat {
        metricBaselineFromTop > 0
            ? metricBaselineFromTop
            : rowHeight - ceil(abs(font.descender) + font.leading)
    }

    private func cursorVerticalFrame(rowTop: CGFloat) -> NSRect {
        rowTextLayout.cursorVerticalFrame(
            rowTop: rowTop,
            rowHeight: rowHeight,
            baselineFromTop: textBaselineFromTop,
            font: font)
    }

    private static func wrap(_ text: String, font: NSFont, width: CGFloat) -> [String] {
        let charW = ("M" as NSString).size(withAttributes: [.font: font]).width
        let cols = max(20, Int(width / max(1, charW)))
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            if raw.isEmpty { out.append(""); continue }
            var line = Substring(raw)
            while line.count > cols {
                // prefer breaking on a space near the edge
                let hard = line.index(line.startIndex, offsetBy: cols)
                let cut = line[..<hard].lastIndex(of: " ").map(line.index(after:)) ?? hard
                out.append(String(line[..<cut]))
                line = line[cut...]
            }
            out.append(String(line))
        }
        return out
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        if mode == .editor {
            editorKeyDown(event)
            return
        }
        switch event.keyCode {
        case 53:   // esc
            if !busy {
                if mode == .list, !query.isEmpty {
                    query = ""
                    filtered = allItems
                    restoreRememberedSelection()
                    previewSelection()
                    relayout()
                } else if mode == .list, navStack.count > 1 {
                    popLevel()
                } else {
                    dismiss()
                }
            }
            return
        case 36, 76:   // return
            if mode == .menu {
                activateMenuSelection()
                return
            }
            act()
            return
        case 126:  // up
            if mode == .menu {
                dismiss()
                return
            }
            move(-1); return
        case 125:  // down
            if mode == .menu {
                moveMenuSelection(1)
                return
            }
            move(1); return
        case 124:  // right → descend into a section / next tab
            if mode == .menu {
                moveMenuSelection(1)
                return
            }
            if mode == .tabs, query.isEmpty { switchTab(to: activeTab + 1); return }
            if mode == .list, selected < filtered.count, filtered[selected].children != nil {
                descend(into: filtered[selected])
            }
            return
        case 123:  // left → back out of a section / previous tab / exit mixer
            if mode == .menu {
                moveMenuSelection(-1)
                return
            }
            if mode == .tabs, query.isEmpty {
                if activeTab == 0 { dismiss() }        // backing out of the first tab = done
                else { switchTab(to: activeTab - 1) }
                return
            }
            if mode == .list, query.isEmpty { popLevel() }
            return
        case 48:   // tab key cycles mixer tabs
            if mode == .tabs {
                switchTab(to: activeTab + (event.modifierFlags.contains(.shift) ? -1 : 1))
                return
            }
        case 51:   // backspace
            if !busy, !query.isEmpty {
                query.removeLast()
                refilter()
            }
            return
        case 116: move(-maxTextRows); return   // page up
        case 121: move(maxTextRows); return    // page down
        default:
            break
        }
        if mode == .menu,
           let characters = event.charactersIgnoringModifiers?.lowercased(),
           let index = menuItems.firstIndex(where: {
               $0.isEnabled && $0.shortcut?.lowercased() == characters
           }) {
            menuSelection = index
            activateMenuSelection()
            return
        }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v", !busy,
               let s = NSPasteboard.general.string(forType: .string) {
                query += s.replacingOccurrences(of: "\n", with: " ")
                refilter()
                return
            }
            super.keyDown(with: event)   // let other ⌘ shortcuts through
            return
        }
        if !busy, mode != .text, mode != .menu,
           let chars = event.characters, !chars.isEmpty,
           !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            query += chars
            refilter()
        }
    }

    private func move(_ delta: Int) {
        switch mode {
        case .editor:
            break   // the editor has its own cursor movement
        case .list, .tabs:
            guard !filtered.isEmpty else { return }
            // Wheel wrap: ↑ from the first row lands on the last, ↓ from the
            // last comes back around.
            let n = filtered.count
            selected = ((selected + delta) % n + n) % n
            // keep the selection in the visible window
            if selected < listTop { listTop = selected }
            if selected >= listTop + maxListRows { listTop = selected - maxListRows + 1 }
            rememberCurrentSelection()
            previewSelection()
            needsDisplay = true
        case .text:
            scrollOffset = min(max(0, scrollOffset + delta), max(0, textLines.count - maxTextRows))
            needsDisplay = true
        case .input:
            break
        case .menu:
            moveMenuSelection(delta)
        }
    }

    private func moveMenuSelection(_ delta: Int) {
        guard !menuItems.isEmpty else { return }
        var candidate = menuSelection
        for _ in 0..<menuItems.count {
            candidate = (candidate + delta + menuItems.count) % menuItems.count
            if menuItems[candidate].isEnabled {
                menuSelection = candidate
                needsDisplay = true
                return
            }
        }
    }

    private func activateMenuSelection() {
        guard menuItems.indices.contains(menuSelection),
              menuItems[menuSelection].isEnabled else { return }
        let id = menuItems[menuSelection].id
        let handler = onMenuAction
        dismiss()
        DispatchQueue.main.async { handler?(id) }
    }

    public var currentMenuItemID: String? {
        guard menuItems.indices.contains(menuSelection) else { return nil }
        return menuItems[menuSelection].id
    }

    private func refilter() {
        if mode == .list || mode == .tabs {
            let level = mode == .tabs ? tabs[activeTab].items : allItems
            if query.isEmpty {
                filtered = level
            } else {
                // Search runs over the whole subtree — at the root that's the
                // entire palette, flat, no matter how deep the sections go.
                let pool = mode == .tabs ? level : PaletteItem.flatten(allItems)
                filtered = pool
                    .compactMap { item -> (PaletteItem, Int)? in
                        CommandPalette.fuzzyScore(query: query, target: item.title + " " + item.subtitle)
                            .map { (item, $0) }
                    }
                    .sorted { $0.1 > $1.1 }
                    .map { $0.0 }
            }
            if query.isEmpty { restoreRememberedSelection() }
            else { selected = 0; listTop = 0 }
            previewSelection()
            relayout()
        } else {
            needsDisplay = true
        }
    }

    private func act() {
        switch mode {
        case .editor:
            return   // ⏎ is a newline in the editor; ⌘⏎ evaluates (editorKeyDown)
        case .list:
            guard selected < filtered.count else { return }
            let item = filtered[selected]
            rememberCurrentSelection()
            if item.children != nil {
                descend(into: item)
                return
            }
            if item.preview != nil {
                // Preview setters intentionally do not persist. Restore the
                // prior baseline and run the action in the same event turn so
                // its real setter writes the config, then make that result the
                // new Escape baseline. Notifications are deferred/coalesced,
                // so no reverted frame is ever presented.
                applySnapshot()
                item.action()
                prefsSnapshot = currentPreferencesSnapshot()
                previewHooks?.commit()
                keptListTitles[navigationLevel] = item.title
                hint = "✓ \(item.title) kept · keep choosing · esc back"
                onPick?(item)
                needsDisplay = true
                return
            }
            dismiss()
            DispatchQueue.main.async { item.action(); self.onPick?(item) }
        case .tabs:
            pinCurrentSelection()
        case .input:
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !busy, !text.isEmpty else { return }
            onSubmit?(text)
        case .text:
            if !busy { dismiss() }
        case .menu:
            activateMenuSelection()
        }
    }

    func dismiss() {
        rememberCurrentSelection()
        restoreAndForgetSnapshot()   // revert only the uncommitted preview
        onDismiss?()
    }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        if mode == .menu {
            let point = convert(event.locationInWindow, from: nil)
            guard let index = menuFrames.firstIndex(where: { $0.contains(point) }),
                  menuItems.indices.contains(index), menuItems[index].isEnabled else {
                return
            }
            menuSelection = index
            needsDisplay = true
            activateMenuSelection()
            return
        }
        guard mode == .list || mode == .tabs else {
            window?.makeFirstResponder(self)   // passive strips take the keys on click
            return
        }
        var p = convert(event.locationInWindow, from: nil)
        if mode == .tabs {
            if p.y < padY + 1 + rowHeight {   // tab bar
                if let hit = tabXRanges.firstIndex(where: { $0.contains(p.x) }) { switchTab(to: hit) }
                return
            }
            p.y -= rowHeight
        }
        let row = Int((p.y - padY - 1) / rowHeight)
        if row >= 0, row < min(filtered.count - listTop, maxListRows) {
            selected = listTop + row
            rememberCurrentSelection()
            previewSelection()
            needsDisplay = true
            act()
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        move(event.deltaY > 0 ? -1 : 1)
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
