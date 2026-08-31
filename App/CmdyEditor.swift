import AppKit
import ProductIdentity
import CmdyKit

// MARK: - Editor surface

/// TextKit still owns layout and editing. This viewport-sized view performs the
/// visible glyph pass explicitly, which remains reliable when the editor moves
/// between a normal window and Cmdy's layer-backed Metal split hierarchy.
private final class EditorTextOverlayView: NSView {
    private weak var textView: NSTextView?
    private var caretColor = NSColor.textColor
    private var caretVisible = true
    private var blinkTimer: Timer?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.zPosition = 10
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    deinit { blinkTimer?.invalidate() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        blinkTimer?.invalidate()
        guard window != nil else { return }
        blinkTimer = Timer(timeInterval: 0.52, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let textView = self.textView,
                  textView.window?.firstResponder === textView,
                  textView.window?.occlusionState.contains(.visible) == true else { return }
            self.caretVisible.toggle()
            self.needsDisplay = true
        }
        if let blinkTimer { RunLoop.main.add(blinkTimer, forMode: .common) }
    }

    func apply(caretColor: NSColor) {
        self.caretColor = caretColor
        needsDisplay = true
    }

    func resetCaret() {
        caretVisible = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let visible = textView.visibleRect
        let textOrigin = textView.textContainerOrigin
        let containerRect = visible.offsetBy(dx: -textOrigin.x, dy: -textOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: containerRect, in: container)
        let drawingOrigin = NSPoint(x: textOrigin.x - visible.minX,
                                    y: textOrigin.y - visible.minY)
        layout.drawBackground(forGlyphRange: glyphs, at: drawingOrigin)
        layout.drawGlyphs(forGlyphRange: glyphs, at: drawingOrigin)

        let selection = textView.selectedRange()
        guard selection.length == 0, caretVisible,
              textView.window?.firstResponder === textView else { return }
        let length = textView.string.utf16.count
        let location = min(selection.location, length)
        let caretRect: NSRect
        if location < length {
            let glyph = layout.glyphIndexForCharacter(at: location)
            let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let glyphLocation = layout.location(forGlyphAt: glyph)
            caretRect = NSRect(x: line.minX + glyphLocation.x, y: line.minY,
                               width: 1, height: line.height)
        } else if layout.extraLineFragmentRect.height > 0 {
            caretRect = layout.extraLineFragmentRect
        } else if layout.numberOfGlyphs > 0 {
            let glyph = layout.numberOfGlyphs - 1
            let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let glyphBounds = layout.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            caretRect = NSRect(x: glyphBounds.maxX, y: line.minY,
                               width: 1, height: line.height)
        } else {
            caretRect = NSRect(x: 0, y: 0, width: 1,
                               height: textView.font?.boundingRectForFont.height ?? 14)
        }
        caretColor.setFill()
        NSRect(x: drawingOrigin.x + caretRect.minX,
               y: drawingOrigin.y + caretRect.minY,
               width: 1.5, height: max(1, caretRect.height)).fill()
    }
}

/// A deliberately small native text editor that shares Cmdy's visual
/// language and can live either in its own window or in a terminal split.
/// The document stays the same object when it moves between those hosts.
final class CmdyEditorPane: NSView, NSTextViewDelegate {
    let documentID = UUID()
    private(set) var documentURL: URL?
    private(set) var isDirty = false
    private(set) var isAttached = false
    weak var terminalController: TerminalWindowController?

    var onTitleChanged: (() -> Void)?

    let textView: NSTextView
    private let scrollView: NSScrollView
    private var scrollTopConstraint: NSLayoutConstraint?
    private lazy var textOverlay = EditorTextOverlayView(textView: textView)
    private var clipObservation: NSObjectProtocol?
    private var isApplyingStyle = false
    private(set) var topContentInset: CGFloat = 0
    private var appliedThemeOverride: Theme?

    init(url: URL?, contents: String) {
        scrollView = NSScrollView(frame: .zero)
        textView = NSTextView(frame: .zero)
        documentURL = url
        super.init(frame: .zero)
        setup(contents: contents)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let clipObservation { NotificationCenter.default.removeObserver(clipObservation) }
        NotificationCenter.default.removeObserver(self)
    }

    var displayName: String { documentURL?.lastPathComponent ?? "Untitled" }
    var displayTitle: String { isDirty ? "\(displayName) - modified" : displayName }
    var contentLineHeight: CGFloat {
        guard let font = textView.font else { return 1 }
        return textView.layoutManager?.defaultLineHeight(for: font)
            ?? max(1, font.ascender - font.descender + font.leading)
    }
    var wrapsLines: Bool {
        guard scrollView.hasHorizontalScroller == false,
              textView.isHorizontallyResizable == false,
              let container = textView.textContainer,
              container.widthTracksTextView,
              let layout = textView.layoutManager else { return false }
        layout.ensureLayout(for: container)
        let available = max(1, textView.bounds.width - textView.textContainerInset.width * 2)
        return layout.usedRect(for: container).width <= available + 1
    }

    private func setup(contents: String) {
        wantsLayer = true
        layer?.masksToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(textOverlay, positioned: .above, relativeTo: scrollView)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = textView

        textView.wantsLayer = true
        textView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        textView.string = contents
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 1,
            height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scrollTopConstraint = scrollView.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollTopConstraint!,
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        clipObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.textOverlay.needsDisplay = true
            }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .cmdyPreferencesChanged, object: nil)

        applyPreferences()
        DispatchQueue.main.async { [weak self] in self?.resizeDocumentView() }
    }

    override func layout() {
        super.layout()
        textOverlay.frame = convert(scrollView.contentView.bounds, from: scrollView.contentView)
        resizeDocumentView()
    }

    private func resizeDocumentView() {
        guard scrollView.contentSize.width > 0, scrollView.contentSize.height > 0,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let width = floor(scrollView.contentSize.width)
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(
                width: width,
                height: max(scrollView.contentSize.height, textView.frame.height)))
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let contentBottom = max(used.maxY, layout.extraLineFragmentRect.maxY)
        let size = NSSize(
            width: width,
            height: max(scrollView.contentSize.height,
                        ceil(contentBottom + textView.textContainerInset.height * 2)))
        if abs(textView.frame.height - size.height) > 0.5 {
            textView.setFrameSize(size)
        }
    }

    @objc private func preferencesChanged() { applyPreferences() }

    func applyPreferences(theme themeOverride: Theme? = nil) {
        let p = Preferences.shared
        if let themeOverride { appliedThemeOverride = themeOverride }
        let theme = appliedThemeOverride ?? p.theme
        let background = theme.ns(theme.background)
        let foreground = theme.ns(theme.foreground)
        let font = p.resolvedFont()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        // Horizontal padding belongs to the text container, just as it belongs
        // to a terminal surface. Vertical padding is applied asymmetrically by
        // the host via setTopContentInset(_:), because the top edge may need to
        // clear window chrome while the bottom edge is already inset by the
        // shared pane host.
        textView.textContainerInset = NSSize(
            width: p.contentMargin,
            height: 0)

        scrollView.backgroundColor = background
        layer?.backgroundColor = background.cgColor
        textView.backgroundColor = background
        textView.textColor = foreground
        textView.insertionPointColor = theme.ns(theme.cursor)
        textOverlay.apply(caretColor: theme.ns(theme.cursor))
        textView.font = font
        isApplyingStyle = true
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes([
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: paragraph,
            ],
                                  range: NSRange(location: 0, length: storage.length))
        }
        isApplyingStyle = false
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: foreground,
            .paragraphStyle: paragraph,
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: theme.ns(theme.ansi[4]).withAlphaComponent(0.72),
            .foregroundColor: foreground,
        ]
        resizeDocumentView()
        textView.needsDisplay = true
        textOverlay.needsDisplay = true
        scrollView.needsDisplay = true
        needsDisplay = true
    }

    /// Align row zero with an adjacent terminal pane. Attached editors receive
    /// the terminal controller's resolved chrome/margin inset; standalone
    /// editor windows reserve that space in their pane constraint instead.
    func setTopContentInset(_ inset: CGFloat) {
        let resolved = max(0, inset)
        guard abs(topContentInset - resolved) > 0.5 else { return }
        topContentInset = resolved
        scrollTopConstraint?.constant = resolved
        needsLayout = true
        textOverlay.needsDisplay = true
    }

    func setAttached(_ attached: Bool, controller: TerminalWindowController?) {
        isAttached = attached
        terminalController = controller
        onTitleChanged?()
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func refreshDisplay() {
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(invalidate)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        invalidate(self)
        displayIfNeeded()
    }

    func ownsFirstResponder(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder === textView { return true }
        var current: NSView? = responder
        while let view = current {
            if view === self { return true }
            current = view.superview
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingStyle else { return }
        if !isDirty {
            isDirty = true
            onTitleChanged?()
        }
        resizeDocumentView()
        textOverlay.resetCaret()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textOverlay.resetCaret()
    }

    func showFind() {
        performFindAction(.showFindInterface)
    }

    func performFindAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    func save(completion: @escaping (Bool) -> Void) {
        guard let url = documentURL else {
            saveAs(completion: completion)
            return
        }
        do {
            try write(to: url)
            completion(true)
        } catch {
            present(error: error, action: "save")
            completion(false)
        }
    }

    func saveAs(completion: @escaping (Bool) -> Void = { _ in }) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = documentURL?.lastPathComponent ?? "Untitled.txt"
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            do {
                try self.write(to: url)
                completion(true)
            } catch {
                self.present(error: error, action: "save")
                completion(false)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    private func write(to url: URL) throws {
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        try Data(textView.string.utf8).write(to: url, options: .atomic)
        if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        documentURL = url
        isDirty = false
        onTitleChanged?()
    }

    func confirmClose(completion: @escaping (Bool) -> Void) {
        guard isDirty else { completion(true); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to \(displayName)?"
        alert.informativeText = "Your changes will be lost if you close without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.save(completion: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    private func present(error: Error, action: String) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not \(action) \(displayName)"
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

// MARK: - Standalone editor window

final class CmdyEditorWindowController: NSWindowController, NSWindowDelegate {
    private let root = NSView(frame: .zero)
    private let titleBand = TitleBandView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private lazy var nativeToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "cmdy.native.editor")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }()
    private var pane: CmdyEditorPane?
    private var paneConstraints: [NSLayoutConstraint] = []
    private var titleBandHeight: NSLayoutConstraint?
    private var titleLeading: NSLayoutConstraint?
    private var titleTop: NSLayoutConstraint?
    private var titleTrailing: NSLayoutConstraint?
    private var compactChrome = false
    private var closingApproved = false
    private var movingToSplit = false
    private let borderInset: CGFloat = 27
    private var topInset: CGFloat {
        let p = Preferences.shared
        return NativeToolbarPreset.titleBandHeight(p.nativeToolbarStyle)
    }

    var editorPane: CmdyEditorPane? { pane }

    init(pane: CmdyEditorPane) {
        self.pane = pane
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        root.wantsLayer = true
        window.contentView = root
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func setup() {
        guard let window, let pane else { return }
        pane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pane)

        titleBand.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleBand, positioned: .above, relativeTo: pane)
        titleBandHeight = titleBand.heightAnchor.constraint(equalToConstant: topInset)
        NSLayoutConstraint.activate([
            titleBand.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBand.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBand.topAnchor.constraint(equalTo: root.topAnchor),
            titleBandHeight!,
        ])

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.refusesFirstResponder = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLabel, positioned: .above, relativeTo: titleBand)
        titleLeading = titleLabel.leadingAnchor.constraint(
            equalTo: root.leadingAnchor,
            constant: NativeToolbarPreset.titleLeading(
                Preferences.shared.nativeToolbarStyle))
        titleTop = titleLabel.topAnchor.constraint(
            equalTo: root.topAnchor,
            constant: NativeToolbarPreset.titleTop(
                Preferences.shared.nativeToolbarStyle))
        titleTrailing = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: root.trailingAnchor, constant: -borderInset)
        NSLayoutConstraint.activate([titleLeading!, titleTop!, titleTrailing!])

        pane.onTitleChanged = { [weak self] in self?.updateTitle() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .cmdyPreferencesChanged, object: nil)
        applyPreferences()
        updateTitle()
        window.initialFirstResponder = pane.textView
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func preferencesChanged() { applyPreferences() }

    private func applyPreferences() {
        guard let window, let pane else { return }
        let p = Preferences.shared
        let theme = p.theme
        let band = theme.background
        let opacity = CGFloat(p.opacity)
        let translucent = opacity < 0.999
        window.backgroundColor = translucent ? .clear : theme.ns(band)
        window.isOpaque = !translucent
        window.hasShadow = true
        root.layer?.backgroundColor = theme.ns(band)
            .withAlphaComponent(translucent ? opacity : 1).cgColor
        titleLabel.textColor = theme.ns(theme.foreground).withAlphaComponent(0.7)
        updateCompactChrome()
        let showTitle = !compactChrome
        let showButtons = !compactChrome && !p.hideTrafficLights
        titleLabel.isHidden = !showTitle
        if !compactChrome {
            if window.toolbar !== nativeToolbar { window.toolbar = nativeToolbar }
            window.toolbarStyle = NativeToolbarPreset.appKitStyle(p.nativeToolbarStyle)
        } else if window.toolbar === nativeToolbar {
            window.toolbar = nil
        }
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = !showButtons
        }
        let hasChrome = showTitle || showButtons
        titleBand.isHidden = !hasChrome
        pane.applyPreferences()
        pane.setTopContentInset(0)

        NSLayoutConstraint.deactivate(paneConstraints)
        let margin = p.contentMargin
        // TextKit applies `margin` inside the editor pane, matching the
        // terminal surface. Keep the host constraint limited to the border so
        // standalone editors do not count the content margin twice.
        let side: CGFloat = 0
        let chromeMargin = max(0, margin - 6)
        let top = hasChrome ? topInset + chromeMargin : margin
        let bottom = margin
        paneConstraints = [
            pane.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
            pane.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),
            pane.topAnchor.constraint(equalTo: root.topAnchor, constant: top),
            pane.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -bottom),
        ]
        NSLayoutConstraint.activate(paneConstraints)

        titleBandHeight?.constant = topInset
        titleLeading?.constant =
            NativeToolbarPreset.titleLeading(p.nativeToolbarStyle)
        titleTop?.constant = NativeToolbarPreset.titleTop(p.nativeToolbarStyle)
        titleTrailing?.constant = -8
        root.needsLayout = true
    }

    private func updateCompactChrome() {
        guard let window else { return }
        compactChrome = WindowChromeLayout.isCompact(windowHeight: window.frame.height)
    }

    private func updateTitle() {
        guard let pane else { return }
        let title = pane.displayTitle
        window?.title = title
        window?.representedURL = pane.documentURL
        titleLabel.stringValue = title
    }

    func focusEditor() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        pane?.focus()
        DispatchQueue.main.async { [weak pane] in pane?.refreshDisplay() }
    }

    func releaseForAttachment() -> CmdyEditorPane? {
        guard let pane else { return nil }
        movingToSplit = true
        self.pane = nil
        pane.onTitleChanged = nil
        pane.removeFromSuperview()
        window?.orderOut(nil)
        window?.close()
        return pane
    }

    func closeApproved() {
        closingApproved = true
        window?.performClose(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingApproved || movingToSplit { return true }
        if let pane { CmdyEditorManager.shared.requestClose(pane) }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if movingToSplit { return }
        if let pane { CmdyEditorManager.shared.windowDidClose(pane) }
    }

    func windowDidResize(_ notification: Notification) {
        let wasCompact = compactChrome
        updateCompactChrome()
        if compactChrome != wasCompact { applyPreferences() }
    }

}

// MARK: - Editor routing and lifecycle

final class CmdyEditorManager {
    static let shared = CmdyEditorManager()

    private var documents: [CmdyEditorPane] = []
    private var windows: [UUID: CmdyEditorWindowController] = [:]
    private var externalProcesses: [Process] = []

    var focusedEditor: CmdyEditorPane? {
        editor(in: NSApp.keyWindow)
    }

    /// Resolve an editor from its host window before consulting first
    /// responder state. Menu tracking temporarily moves first responder away
    /// from the text view, but commands must still belong to that document.
    func editor(in window: NSWindow?) -> CmdyEditorPane? {
        guard let window else { return nil }
        if let controller = windows.values.first(where: { $0.window === window }) {
            return controller.editorPane
        }
        return documents.first { $0.ownsFirstResponder(in: window) }
    }

    var hasDirtyDocuments: Bool { documents.contains(where: \.isDirty) }
    var documentCountForTesting: Int { documents.count }

    /// Make the editor visible without treating a visibility command as a
    /// request for another untitled document. Prefer the editor already hosted
    /// by the invoking window, then the most recently registered document.
    /// Only a workspace with no editor at all creates a new one.
    @discardableResult
    func showEditor(in sourceWindow: NSWindow?,
                    attachingTo requested: TerminalWindowController?) -> CmdyEditorPane {
        if let sourceWindow,
           let local = editor(in: sourceWindow)
                ?? documents.last(where: { $0.window === sourceWindow }) {
            reveal(local)
            return local
        }
        if let existing = documents.last {
            reveal(existing)
            return existing
        }

        let pane = CmdyEditorPane(url: nil, contents: "")
        register(pane)
        if let requested {
            attachEditor(pane, to: requested)
        } else {
            showWindow(for: pane, near: sourceWindow)
        }
        return pane
    }

    @discardableResult
    func open(_ url: URL, attach: Bool = false,
              respectPreference: Bool = true) -> CmdyEditorPane? {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let builtInEditorNames = Set(
            [ProductIdentity.current.slug] + ProductIdentity.current.legacySlugs)
        if respectPreference,
           !builtInEditorNames.contains(Preferences.shared.editor.lowercased()) {
            openExternally(canonical, choice: Preferences.shared.editor)
            return nil
        }
        if let existing = documents.first(where: {
            $0.documentURL?.standardizedFileURL.resolvingSymlinksInPath() == canonical
        }) {
            reveal(existing)
            if attach, !existing.isAttached { attachEditor(existing) }
            return existing
        }
        do {
            let contents = try BoundedFileReader.utf8String(
                at: canonical, maxBytes: 64 * 1024 * 1024)
            let pane = CmdyEditorPane(url: canonical, contents: contents)
            register(pane)
            attach ? attachEditor(pane) : showWindow(for: pane)
            return pane
        } catch {
            presentOpenError(error, url: canonical)
            return nil
        }
    }

    func newDocument(attach: Bool = false) {
        let pane = CmdyEditorPane(url: nil, contents: "")
        register(pane)
        attach ? attachEditor(pane) : showWindow(for: pane)
    }

    private func register(_ pane: CmdyEditorPane) {
        documents.append(pane)
    }

    private func reveal(_ pane: CmdyEditorPane) {
        if let controller = pane.terminalController {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            pane.focus()
        } else if let controller = windows[pane.documentID] {
            controller.focusEditor()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showWindow(for pane: CmdyEditorPane, near source: NSWindow? = nil) {
        pane.setAttached(false, controller: nil)
        let controller = CmdyEditorWindowController(pane: pane)
        windows[pane.documentID] = controller
        if let source, let target = controller.window {
            var frame = source.frame
            frame.origin.x += 24
            frame.origin.y -= 24
            target.setFrame(frame, display: false)
        } else {
            controller.window?.center()
        }
        controller.focusEditor()
        NSApp.activate(ignoringOtherApps: true)
    }

    func attachEditor(_ pane: CmdyEditorPane,
                      to requested: TerminalWindowController? = nil,
                      side: TerminalWindowController.DockSide = .right) {
        guard !pane.isAttached else { reveal(pane); return }
        guard let target = requested ?? (NSApp.delegate as? AppDelegate)?.currentController else {
            NSSound.beep()
            reveal(pane)
            return
        }
        if let source = windows.removeValue(forKey: pane.documentID) {
            _ = source.releaseForAttachment()
        }
        target.attachEditor(pane, side: side)
    }

    func detachEditor(_ pane: CmdyEditorPane) {
        guard let source = pane.terminalController else { return }
        let sourceWindow = source.window
        source.releaseEditor(pane)
        showWindow(for: pane, near: sourceWindow)
    }

    func requestClose(_ pane: CmdyEditorPane) {
        pane.confirmClose { [weak self, weak pane] approved in
            guard approved, let self, let pane else { return }
            DispatchQueue.main.async { self.closeApproved(pane) }
        }
    }

    private func closeApproved(_ pane: CmdyEditorPane) {
        if let terminal = pane.terminalController {
            terminal.removeEditor(pane)
            forget(pane)
        } else if let controller = windows[pane.documentID] {
            controller.closeApproved()
        } else {
            forget(pane)
        }
    }

    func windowDidClose(_ pane: CmdyEditorPane) { forget(pane) }

    func terminalDidClose(_ pane: CmdyEditorPane) {
        windows.removeValue(forKey: pane.documentID)
        forget(pane)
    }

    private func forget(_ pane: CmdyEditorPane) {
        windows.removeValue(forKey: pane.documentID)
        documents.removeAll { $0 === pane }
        pane.onTitleChanged = nil
    }

    func confirmClosing(_ panes: [CmdyEditorPane], completion: @escaping (Bool) -> Void) {
        let pending = panes.filter(\.isDirty)
        confirmNext(pending[...], completion: completion)
    }

    func confirmAllDirty(completion: @escaping (Bool) -> Void) {
        confirmClosing(documents, completion: completion)
    }

    private func confirmNext(_ pending: ArraySlice<CmdyEditorPane>,
                             completion: @escaping (Bool) -> Void) {
        guard let first = pending.first else { completion(true); return }
        first.confirmClose { [weak self] approved in
            guard approved else { completion(false); return }
            self?.confirmNext(pending.dropFirst(), completion: completion)
        }
    }

    private func openExternally(_ url: URL, choice: String) {
        let trimmed = choice.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "system" {
            let workspace = NSWorkspace.shared
            let ownURL = Bundle.main.bundleURL.standardizedFileURL
            let selected = workspace.urlForApplication(toOpen: url)?.standardizedFileURL
            let application = selected == ownURL
                ? URL(fileURLWithPath: "/System/Applications/TextEdit.app") : selected
            if let application {
                workspace.open([url], withApplicationAt: application,
                               configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.open(url)
            }
            return
        }

        let quoted = Self.shellQuote(url.path)
        let command = trimmed.contains("{file}")
            ? trimmed.replacingOccurrences(of: "{file}", with: quoted)
            : "\(trimmed) \(quoted)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let process else { return }
                self?.externalProcesses.removeAll { $0 === process }
            }
        }
        do {
            externalProcesses.append(process)
            try process.run()
        } catch {
            externalProcesses.removeAll { $0 === process }
            presentOpenError(error, url: url)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func presentOpenError(_ error: Error, url: URL) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not open \(url.lastPathComponent)"
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
