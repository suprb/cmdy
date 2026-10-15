import AppKit
import CmdyNative
import Darwin
import MetalKit
@_spi(CmdyApp) import CmdyCore
@_spi(CmdyApp) import CmdyGPU
import CmdyKit

private final class CmdyRenderView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Input-method preedit stays native and separate from process output.
private final class CmdyMarkedTextView: NSView {
    var text = NSAttributedString(string: "")
    var fill = NSColor.textBackgroundColor
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        text.draw(in: bounds.insetBy(dx: 2, dy: 0))
    }
}

/// Active AppKit host for one CmdyCore model and one CmdyGPU renderer.
/// `TerminalEngineFactory` selects this surface for production and headless
/// pane hosts after validation by the independent surface contract harness.
@MainActor
final class CmdyTerminalSurface: NSView,
                                 @preconcurrency NSTextInputClient,
                                 @preconcurrency TerminalSurface,
                                 @preconcurrency TerminalSession {
    struct SelectionPoint: Equatable {
        var row: Int
        var col: Int
    }

    private struct GridPoint {
        let row: Int
        let col: Int
        let absoluteRow: Int
    }

    let terminal: TerminalModel
    private(set) var renderSnapshot: CoreTerminalSnapshot
    var frameSnapshot: CoreTerminalSnapshot
    private var directModelPublication = false

    var onSendToProcess: ((ArraySlice<UInt8>) -> Void)?
    var onTextInputCommitted: ((String) -> Void)?
    var onTextCompositionStarted: (() -> Void)?
    var onPasteRequest: ((String) -> String?)?
    var onTerminalMouseDown: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var onSizeChanged: ((Int, Int) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onNotification: ((String, String) -> Void)?
    var onCwdChanged: ((String?) -> Void)?
    var onProcessTerminated: ((Int32?) -> Void)?
    var willReflowBuffer: (() -> Void)?
    var didReflowBuffer: (() -> Void)?
    var onViewportChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?

    private var storedFont: NSFont
    private var storedLineHeightMultiplier: CGFloat = 1
    private(set) var cellDimension: CGSize
    private var baselineFromRowTop: CGFloat
    private var palette: [NSColor]

    var font: NSFont {
        get { storedFont }
        set {
            guard storedFont != newValue else { return }
            storedFont = newValue
            metricsOrInsetsChanged(recomputeMetrics: true)
        }
    }

    var lineHeightMultiplier: CGFloat {
        get { storedLineHeightMultiplier }
        set {
            let safe = max(0.1, newValue.isFinite ? newValue : 1)
            guard storedLineHeightMultiplier != safe else { return }
            storedLineHeightMultiplier = safe
            metricsOrInsetsChanged(recomputeMetrics: true)
        }
    }

    var cellSize: CGSize { cellDimension }
    var textBaselineFromRowTop: CGFloat { baselineFromRowTop }

    // Preference passes reassign every appearance value (window key changes,
    // coalesced settings notifications). Unchanged values must not discard
    // cached rows or supersede a frame that is already being drawn.
    var nativeForegroundColor = NSColor.textColor {
        didSet { if oldValue != nativeForegroundColor { appearanceChanged() } }
    }
    var nativeBackgroundColor = NSColor.textBackgroundColor {
        didSet { if oldValue != nativeBackgroundColor { appearanceChanged() } }
    }
    var caretColor = NSColor.textColor { didSet { if oldValue != caretColor { appearanceChanged() } } }
    var caretTextColor: NSColor? { didSet { if oldValue != caretTextColor { appearanceChanged() } } }
    var selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor {
        didSet {
            guard oldValue != selectedTextBackgroundColor else { return }
            snapshotRowContext.beginFrame()
            queueDisplay()
        }
    }
    var optionAsMetaKey = false

    private var storedTopInset: CGFloat = 0
    private var storedBottomInset: CGFloat = 0
    private var storedMinimumBottomInset: CGFloat = 0
    private var storedLeftInset: CGFloat = 0
    private var storedRightInset: CGFloat = 0

    var topContentInset: CGFloat {
        get { storedTopInset }
        set {
            let safe = sanitizedInset(newValue)
            guard storedTopInset != safe else { return }
            storedTopInset = safe
            metricsOrInsetsChanged(recomputeMetrics: false)
        }
    }
    var bottomContentInset: CGFloat {
        get { max(storedBottomInset, storedMinimumBottomInset) }
        set {
            let safe = sanitizedInset(newValue)
            guard storedBottomInset != safe else { return }
            let previous = bottomContentInset
            storedBottomInset = safe
            guard bottomContentInset != previous else { return }
            metricsOrInsetsChanged(recomputeMetrics: false)
        }
    }
    /// Keep complete terminal cells clear of the native bottom edge. Panels
    /// reserve their existing height from that same edge, so the two overlap.
    var minimumBottomContentInset: CGFloat {
        get { storedMinimumBottomInset }
        set {
            let safe = sanitizedInset(newValue)
            guard storedMinimumBottomInset != safe else { return }
            let previous = bottomContentInset
            storedMinimumBottomInset = safe
            guard bottomContentInset != previous else { return }
            metricsOrInsetsChanged(recomputeMetrics: false)
        }
    }
    var leftContentInset: CGFloat {
        get { storedLeftInset }
        set {
            let safe = sanitizedInset(newValue)
            guard storedLeftInset != safe else { return }
            storedLeftInset = safe
            metricsOrInsetsChanged(recomputeMetrics: false)
        }
    }
    var rightContentInset: CGFloat {
        get { storedRightInset }
        set {
            let safe = sanitizedInset(newValue)
            guard storedRightInset != safe else { return }
            storedRightInset = safe
            metricsOrInsetsChanged(recomputeMetrics: false)
        }
    }
    var showsScroller = false
    var contentXOrigin: CGFloat { snapToPixel(storedLeftInset) }

    private(set) var metalView: MTKView?
    private(set) var metalRenderer: MetalTerminalRenderer?
    var onRendererError: ((String) -> Void)?
    private var shaderRequestGeneration: UInt64 = 0
    /// The user shader the current renderer is known to have installed. Unknown
    /// (nil) while a load is in flight or after a failure, so only a settled,
    /// identical request is skipped.
    private var installedUserShader: (renderer: ObjectIdentifier, source: String?)?
    var shaderMode = 0 {
        didSet {
            guard oldValue != shaderMode else { return }
            shaderRequestGeneration &+= 1
            metalView?.layer?.isOpaque = nativeBackgroundColor.alphaComponent >= 1 && shaderMode != -1
            metalRenderer?.shaderMode = shaderMode; queueDisplay()
        }
    }
    var textRenderingModeName = TextRenderingMode.current.rawValue {
        didSet {
            guard oldValue != textRenderingModeName else { return }
            guard let mode = TextRenderingMode(rawValue: textRenderingModeName) else {
                textRenderingModeName = oldValue
                return
            }
            metalRenderer?.textRenderingMode = mode
            invalidateRows()
        }
    }
    var smoothCursor = true {
        didSet {
            guard oldValue != smoothCursor else { return }
            metalRenderer?.smoothCursorEnabled = smoothCursor; queueDisplay()
        }
    }
    var hostCursorHidden = false {
        didSet { metalRenderer?.hostCursorHidden = hostCursorHidden; queueDisplay() }
    }
    var cursorGlideSpeed: CGFloat = 1 {
        didSet {
            cursorGlideSpeed = max(0.01, cursorGlideSpeed)
            metalRenderer?.cursorGlideSpeed = Float(cursorGlideSpeed)
        }
    }
    var cursorGlideMaxDistance: CGFloat = 0 {
        didSet {
            cursorGlideMaxDistance = max(0, cursorGlideMaxDistance)
            metalRenderer?.cursorGlideMaxDistance = Float(cursorGlideMaxDistance)
        }
    }
    var smoothScroll = true {
        didSet {
            guard oldValue != smoothScroll else { return }
            metalRenderer?.smoothScrollEnabled = smoothScroll
            if !smoothScroll { resetScrollOffset() }
            queueDisplay()
        }
    }
    var failedBlockRows: Set<Int> = [] { didSet { appearanceChanged() } }
    var failedBlockForegroundColor = NSColor.systemRed {
        didSet { if oldValue != failedBlockForegroundColor { appearanceChanged() } }
    }
    var failedBlockBackgroundColor = NSColor.systemRed.withAlphaComponent(0.16) {
        didSet { if oldValue != failedBlockBackgroundColor { appearanceChanged() } }
    }
    private(set) var visualScrollOffset: CGFloat = 0
    /// The top row of the snapshot the renderer is drawing.
    var displayedTopRowForTesting: Int { renderSnapshot.grid.displayTopRow }
    var onVisualScrollChanged: (() -> Void)?
    var activityKeypressTime: Double = 0 {
        didSet { publishInputActivity() }
    }
    var activityTypingRate: Float = 0 {
        didSet { publishInputActivity() }
    }

    private func publishInputActivity() {
        metalRenderer?.updateInputActivity(keypressTime: activityKeypressTime,
                                          typingRate: activityTypingRate)
    }

    private var pendingDirtyRows: ClosedRange<Int>?
    private var frameContentGeneration: UInt64 = 1
    // Resolved native style survives content publications. UI inputs, including
    // system colors, invalidate it before the next lazy style request.
    private let snapshotRowContext = CmdySnapshotRowContext()
    private var systemColorObserver: NSObjectProtocol?
    private var selectionAnchor: SelectionPoint?
    private var selectionActive: SelectionPoint?
    private var gestureOrigin: GridPoint?
    private var gestureUsesNativeSelection = false
    private var gestureReportsMouse = false
    private var gestureDragged = false
    private var gestureClickCount = 0
    private var scrollAccumulator: CGFloat = 0
    private var routedWheelAccumulator: CGFloat = 0
    private var searchTerm = ""
    private var searchOptions = TermSearchOptions()
    private var searchHits: [TerminalSearchHit] = []
    private var activeSearchIndex: Int?
    private var trackingAreaReference: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    private var terminated = false
    private let markedTextView = CmdyMarkedTextView(frame: .zero)
    private var markedText = NSMutableAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private var interpretingTextEvent: NSEvent?
    private var interpretingComposition = false
    private var compositionCommit = ""
    private var discardingComposition = false

    var scrollAccumulatorForTesting: CGFloat { scrollAccumulator }
    var windowObserverCountForTesting: Int { windowObservers.count }

    func setSelectionForTesting(anchor: SelectionPoint, active: SelectionPoint) {
        setSelection(anchor: anchor, active: active, notify: false)
    }

    static func metricsForTesting(
        font: NSFont, multiplier: CGFloat, scale: CGFloat
    ) -> (size: CGSize, baseline: CGFloat) {
        calculateMetrics(font: font, multiplier: multiplier, scale: scale)
    }

    /// Set by TerminalEngineFactory immediately around one construction.
    @MainActor static var adoptedModelForNextInit = AdoptedModelSlot()
    struct AdoptedModelSlot {
        var model: TerminalModel?
        mutating func take() -> TerminalModel? { defer { model = nil }; return model }
    }

    override init(frame frameRect: NSRect) {
        let initialFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let initialMetrics = Self.calculateMetrics(
            font: initialFont, multiplier: 1,
            scale: NSScreen.main?.backingScaleFactor ?? 1)
        let cols = max(2, Int(floor(max(0, frameRect.width) / initialMetrics.size.width)))
        let rows = max(1, Int(floor(max(0, frameRect.height) / initialMetrics.size.height)))
        let adopted = Self.adoptedModelForNextInit.take()
        let model = adopted ?? TerminalModel(cols: cols, rows: rows)
        holdsGrid = adopted != nil
        terminal = model
        renderSnapshot = model.snapshot
        frameSnapshot = model.snapshot
        storedFont = initialFont
        cellDimension = initialMetrics.size
        baselineFromRowTop = initialMetrics.baseline
        palette = Self.defaultPalette()
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = nativeBackgroundColor.cgColor
        systemColorObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.terminated else { return }
                self.effectiveAppearance.performAsCurrentDrawingAppearance { self.appearanceChanged() }
            }
        }
        terminal.observer = self
        updateTrackingAreas()
        // An adopted model's shell already has its size; this placeholder
        // frame must not reach it (releaseGridHold applies the real one).
        if !holdsGrid { updatePixelMetadataAndPTY(cols: cols, rows: rows) }
    }

    required init?(coder: NSCoder) {
        fatalError("CmdyTerminalSurface must be created programmatically")
    }

    deinit {
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        if let systemColorObserver { NotificationCenter.default.removeObserver(systemColorObserver) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    var view: NSView { self }
    var engine: TerminalEngine { terminal }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalView?.frame = bounds
        resizeGrid(reflowHooks: true)
        resetCursorRects()
        if hasMarkedText() { updateMarkedTextPresentation() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        metalRenderer?.cancelKeyboardInteraction()
        terminal.cancelKeyboardInteraction()
        cancelTextComposition()
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification,
                     NSWindow.didChangeBackingPropertiesNotification] {
            windowObservers.append(center.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if note.name == NSWindow.didResignKeyNotification {
                        self.metalRenderer?.cancelKeyboardInteraction()
                        self.terminal.cancelKeyboardInteraction()
                        self.cancelTextComposition()
                    }
                    if note.name == NSWindow.didChangeBackingPropertiesNotification {
                        self.metricsOrInsetsChanged(recomputeMetrics: true)
                    } else {
                        self.metalRenderer?.noteActivity()
                        self.queueDisplay()
                        self.onViewportChanged?()
                    }
                }
            })
        }
        metricsOrInsetsChanged(recomputeMetrics: true)
        queueDisplay()
    }

    override func becomeFirstResponder() -> Bool {
        if terminal.focusReporting { terminal.send(Array("\u{1b}[I".utf8)) }
        metalRenderer?.noteActivity()
        queueDisplay()
        onViewportChanged?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        metalRenderer?.cancelKeyboardInteraction()
        terminal.cancelKeyboardInteraction()
        cancelTextComposition()
        if terminal.focusReporting { terminal.send(Array("\u{1b}[O".utf8)) }
        queueDisplay()
        onViewportChanged?()
        return true
    }

    func send(txt: String) {
        emitUserInput(Array(txt.utf8))
    }

    func feed(text: String) {
        terminal.feed(text: text)
        queueDisplay()
    }

    func installColors(_ colors: [TermColor]) {
        var changed = false
        for (index, color) in colors.prefix(16).enumerated() {
            let next = NSColor(
                srgbRed: CGFloat(color.red) / CGFloat(UInt16.max),
                green: CGFloat(color.green) / CGFloat(UInt16.max),
                blue: CGFloat(color.blue) / CGFloat(UInt16.max), alpha: 1)
            if palette[index] != next { palette[index] = next; changed = true }
        }
        if changed { appearanceChanged() }
    }

    static func defaultPalette() -> [NSColor] {
        let ansi: [(Int, Int, Int)] = [
            (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
            (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
            (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]
        var result = ansi.map { color($0.0, $0.1, $0.2) }
        let steps = [0, 95, 135, 175, 215, 255]
        for red in steps {
            for green in steps {
                for blue in steps { result.append(color(red, green, blue)) }
            }
        }
        for value in stride(from: 8, through: 238, by: 10) {
            result.append(color(value, value, value))
        }
        return result
    }

    func paletteColor(_ index: Int) -> NSColor {
        palette.indices.contains(index) ? palette[index] : nativeForegroundColor
    }

    func fontVariant(bold: Bool, italic: Bool) -> NSFont {
        withExtendedLifetime(storedFont) {
            let pointer = cmdy_shape_font_variant(Unmanaged.passUnretained(storedFont).toOpaque(),
                bold ? 1 : 0, italic ? 1 : 0)!
            return Unmanaged<NSFont>.fromOpaque(pointer).takeRetainedValue()
        }
    }

    static func needsExplicitBackground(_ attribute: CellAttribute) -> Bool {
        CmdySnapshotShaper.needsExplicitBackground(attribute)
    }

    func setUseMetal(_ on: Bool) throws {
        guard on else { throw MetalError.metalKitUnavailable }
        guard metalRenderer == nil else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalError.deviceUnavailable
        }
        let view = CmdyRenderView(frame: bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        // The drawable carries terminal background alpha; its Metal layer must
        // permit compositing whenever that background is translucent.
        view.layer?.isOpaque = nativeBackgroundColor.alphaComponent >= 1 && shaderMode != -1
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        let renderer = try MetalTerminalRenderer(view: view, source: self)
        renderer.shaderMode = shaderMode
        renderer.textRenderingMode = TextRenderingMode(rawValue: textRenderingModeName) ?? .current
        renderer.smoothCursorEnabled = smoothCursor
        renderer.hostCursorHidden = hostCursorHidden
        renderer.cursorGlideSpeed = Float(cursorGlideSpeed)
        renderer.cursorGlideMaxDistance = Float(cursorGlideMaxDistance)
        renderer.smoothScrollEnabled = smoothScroll
        renderer.onFailure = { [weak self] message in
            guard let self, !self.terminated, let message else { return }
            NSLog("cmdy: renderer failed: %@", message)
            self.onRendererError?(message)
        }
        renderer.onScrollOffsetChanged = { [weak self] offset in
            guard let self else { return }
            let snapped = self.snapToPixel(offset)
            guard snapped != self.visualScrollOffset else { return }
            self.visualScrollOffset = snapped
            self.onVisualScrollChanged?()
        }
        view.delegate = renderer
        addSubview(view, positioned: .below, relativeTo: nil)
        metalView = view
        metalRenderer = renderer
        installedUserShader = (ObjectIdentifier(renderer), nil)
        // Metal owns the pane background; a host fill would composite it twice.
        layer?.backgroundColor = NSColor.clear.cgColor
        publishInputActivity()
        let sink = CmdyModelRenderSink(publisher: renderer.modelPublisher)
        terminal.setRenderPublication { snapshot, generation in sink.publish(snapshot, generation: generation) }
        directModelPublication = true
        queueDisplay()
    }

    var isUsingMetalRenderer: Bool { metalRenderer != nil }

    @discardableResult
    func setUserShader(_ source: String?) async -> String? {
        guard !terminated, !Task.isCancelled else { return nil }
        if let renderer = metalRenderer, let installed = installedUserShader,
           installed.renderer == ObjectIdentifier(renderer), installed.source == source {
            return nil
        }
        installedUserShader = nil
        shaderRequestGeneration &+= 1
        let generation = shaderRequestGeneration
        guard let renderer = metalRenderer else {
            return source == nil ? nil : "Metal renderer is unavailable"
        }
        let result = await renderer.loadUserShader(source: source)
        guard !terminated, !Task.isCancelled, generation == shaderRequestGeneration,
              metalRenderer === renderer else { return nil }
        if result == nil { installedUserShader = (ObjectIdentifier(renderer), source) }
        if result == nil, source != nil { shaderMode = -1 }
        queueDisplay()
        return result
    }

    func forceRedraw() {
        let first = renderSnapshot.grid.displayTopRow
        let last = max(first, first + renderSnapshot.grid.rows - 1)
        pendingDirtyRows = union(pendingDirtyRows, first...last)
        terminal.markViewportDirty()
        invalidateRows()
    }

    func queueDisplay() {
        frameContentGeneration &+= 1
        metalRenderer?.sourceDidChange()
        if let metalView {
            metalView.needsDisplay = true
        } else {
            needsDisplay = true
        }
    }

    func scrollTo(row: Int) {
        resetScrollOffset()
        installViewportUpdate(terminal.scrollViewport(to: row))
    }

    func scrollUp(lines: Int) {
        guard lines > 0 else { return }
        resetScrollOffset()
        installViewportUpdate(terminal.scrollViewport(lines: -lines))
    }

    func scrollDown(lines: Int) {
        guard lines > 0 else { return }
        resetScrollOffset()
        installViewportUpdate(terminal.scrollViewport(lines: lines))
    }

    var scrollPosition: Double {
        let live = renderSnapshot.grid.liveTopRow
        guard live > 0 else { return 1 }
        return min(1, max(0, Double(renderSnapshot.grid.displayTopRow) / Double(live)))
    }

    var canScroll: Bool { renderSnapshot.grid.liveTopRow > 0 }

    func resetScrollOffset() {
        guard scrollAccumulator != 0 || visualScrollOffset != 0 else {
            metalRenderer?.cancelScrollAnimation()
            return
        }
        let hadVisualOffset = visualScrollOffset != 0
        scrollAccumulator = 0
        visualScrollOffset = 0
        metalRenderer?.setScrollHeld(0)
        metalRenderer?.cancelScrollAnimation()
        if hadVisualOffset { onVisualScrollChanged?() }
        queueDisplay()
    }

    func selectedText() -> String {
        guard let range = normalizedSelection() else { return "" }
        let bufferLineCount = renderSnapshot.grid.bufferLineCount
        guard bufferLineCount > 0 else { return "" }
        let firstRow = max(0, range.start.row)
        let lastRow = min(bufferLineCount - 1, range.end.row)
        guard firstRow <= lastRow else { return "" }
        var rows: [String] = []
        for row in firstRow...lastRow {
            guard let line = terminal.lineSnapshot(absolute: row) else {
                rows.append("")
                continue
            }
            guard !line.cells.isEmpty else {
                rows.append("")
                continue
            }
            let requestedLower = row == range.start.row ? range.start.col : 0
            let requestedUpper = row == range.end.row
                ? range.end.col : line.cells.count - 1
            let lower = max(0, requestedLower)
            let upper = min(line.cells.count - 1, requestedUpper)
            var text = ""
            if lower <= upper {
                for column in lower...upper {
                    let cell = line.cells[column]
                    guard cell.width != 0 else { continue }
                    text += snapshotCellText(cell)
                }
            }
            rows.append(text)
        }
        return rows.joined(separator: "\n")
    }

    func selectAllContent() {
        let grid = renderSnapshot.grid
        let first = grid.isAlternateBuffer ? max(0, grid.liveTopRow) : 0
        let last = grid.isAlternateBuffer
            ? min(grid.bufferLineCount - 1, first + max(0, grid.rows - 1))
            : grid.bufferLineCount - 1
        guard first <= last else { clearSelection(notify: true); return }
        // The alternate ring retains a predecessor for internal bookkeeping.
        // Select its live screen; only the primary buffer exposes history.
        setSelection(
            anchor: SelectionPoint(row: first, col: 0),
            active: SelectionPoint(row: last, col: max(0, grid.cols - 1)),
            notify: true)
    }

    @discardableResult
    func adjustSelection(_ adjustment: TerminalSelectionAdjustment) -> Bool {
        guard selectionAnchor != nil, var active = selectionActive else { return false }
        let cols = max(1, renderSnapshot.grid.cols)
        let lastRow = max(0, renderSnapshot.grid.bufferLineCount - 1)
        switch adjustment {
        case .left:
            if active.col > 0 { active.col -= 1 }
            else if active.row > 0 { active.row -= 1; active.col = cols - 1 }
        case .right:
            if active.col + 1 < cols { active.col += 1 }
            else if active.row < lastRow { active.row += 1; active.col = 0 }
        case .up: active.row -= 1
        case .down: active.row += 1
        case .pageUp: active.row -= max(1, renderSnapshot.grid.rows)
        case .pageDown: active.row += max(1, renderSnapshot.grid.rows)
        case .home: active.col = 0
        case .end: active.col = cols - 1
        }
        active.row = min(lastRow, max(0, active.row))
        active.col = min(cols - 1, max(0, active.col))
        guard active != selectionActive else { return true }
        setSelection(anchor: selectionAnchor, active: active, notify: false)
        _ = scrollSelectionIntoView()
        onSelectionChanged?()
        return true
    }

    @discardableResult
    func scrollSelectionIntoView() -> Bool {
        guard let active = selectionActive else { return false }
        let top = renderSnapshot.grid.displayTopRow
        let bottom = top + max(0, renderSnapshot.grid.rows - 1)
        let target: Int
        if active.row < top { target = active.row }
        else if active.row > bottom { target = active.row - renderSnapshot.grid.rows + 1 }
        else { return false }
        let update = terminal.scrollViewport(to: target)
        installViewportUpdate(update)
        return update.after != update.before
    }

    func selectedColumnsForShaping(row: Int) -> ClosedRange<Int>? {
        guard let selection = normalizedSelection(),
              row >= selection.start.row, row <= selection.end.row,
              frameSnapshot.grid.cols > 0 else { return nil }
        // A reflow can narrow the terminal while a selection still carries
        // columns from the preceding grid. Clamp before constructing a range:
        // Swift traps on `oldColumn...newLastColumn` when the old column is now
        // outside the grid (for example when Show Editor docks beside a pane).
        let last = frameSnapshot.grid.cols - 1
        let startColumn = min(last, max(0, selection.start.col))
        let endColumn = min(last, max(0, selection.end.col))
        if selection.start.row == selection.end.row {
            return startColumn...endColumn
        }
        if row == selection.start.row { return startColumn...last }
        if row == selection.end.row { return 0...endColumn }
        return 0...last
    }

    @discardableResult
    func findNext(_ term: String, options: TermSearchOptions) -> Bool {
        prepareSearch(term, options: options)
        guard !searchHits.isEmpty else { return false }
        activeSearchIndex = ((activeSearchIndex ?? -1) + 1) % searchHits.count
        revealSearchHit(searchHits[activeSearchIndex!])
        return true
    }

    @discardableResult
    func findPrevious(_ term: String, options: TermSearchOptions) -> Bool {
        prepareSearch(term, options: options)
        guard !searchHits.isEmpty else { return false }
        let current = activeSearchIndex ?? 0
        activeSearchIndex = (current - 1 + searchHits.count) % searchHits.count
        revealSearchHit(searchHits[activeSearchIndex!])
        return true
    }

    func searchStatus(
        _ term: String, options: TermSearchOptions
    ) -> (index: Int, total: Int) {
        prepareSearch(term, options: options)
        return ((activeSearchIndex ?? -1) + 1, searchHits.count)
    }

    func clearSearch() {
        searchTerm = ""
        searchOptions = TermSearchOptions()
        searchHits.removeAll(keepingCapacity: false)
        activeSearchIndex = nil
        clearSelection(notify: true)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            interpretCompositionKey(event) { inputContext?.handleEvent(event) == true }
            return
        }
        handleUnmarkedKeyEvent(event)
    }

    /// An IME may insert and then delete text within one key event. Keep those
    /// edits local until interpretation finishes; PTY bytes cannot be taken back.
    func interpretCompositionKey(_ event: NSEvent, interpret: () -> Bool) {
        interpretingTextEvent = event
        interpretingComposition = true
        compositionCommit = ""
        defer {
            let text = compositionCommit
            compositionCommit = ""
            interpretingTextEvent = nil
            interpretingComposition = false
            emitCommittedText(text)
        }
        if interpret() { return }
        handleUnhandledCompositionKey(event)
    }

    /// Only called after the input method declines the event. Candidate keys
    /// remain private to composition, but an unhandled interrupt must reach
    /// the terminal through its usual control-byte encoder.
    func handleUnhandledCompositionKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .option, .control, .command])
        if flags.contains(.control), !flags.contains(.command),
           let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           Self.controlByte(for: scalar) == 3 {
            cancelTextComposition()
            handleUnmarkedKeyEvent(event)
        } else if event.keyCode == 53 {
            cancelTextComposition()
        }
    }

    private func handleUnmarkedKeyEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .option, .control, .command])
        guard !modifiers.contains(.command) else { super.keyDown(with: event); return }
        let relevant = modifiers.intersection([.shift, .option, .control])
        let parameter = Self.modifierParameter(relevant)
        let application = terminal.applicationCursorKeys
        let kittyKeyboardFlags = terminal.kittyKeyboardFlags
        var bytes: [UInt8]?

        switch event.keyCode {
        case 123: bytes = specialKey(final: "D", parameter: parameter,
                                     application: application)
        case 124: bytes = specialKey(final: "C", parameter: parameter,
                                     application: application)
        case 125: bytes = specialKey(final: "B", parameter: parameter,
                                     application: application)
        case 126: bytes = specialKey(final: "A", parameter: parameter,
                                     application: application)
        case 115: bytes = homeEndKey(final: "H", parameter: parameter,
                                     application: application)
        case 119: bytes = homeEndKey(final: "F", parameter: parameter,
                                     application: application)
        case 116: bytes = tildeKey(code: 5, parameter: parameter)
        case 121: bytes = tildeKey(code: 6, parameter: parameter)
        case 117: bytes = tildeKey(code: 3, parameter: parameter)
        case 53:
            bytes = (kittyKeyboardFlags & 1) != 0
                ? Array("\u{1b}[27u".utf8) : [0x1B]
        case 48: bytes = modifiers.contains(.shift) ? Array("\u{1b}[Z".utf8) : [0x09]
        case 36, 76:
            bytes = Self.returnKeyBytes(
                modifiers: relevant,
                kittyKeyboardFlags: kittyKeyboardFlags)
        case 51: bytes = modifiers.contains(.option) ? [0x1B, 0x7F] : [0x7F]
        case 122: bytes = functionKey(prefix: "P", tilde: nil, parameter: parameter)
        case 120: bytes = functionKey(prefix: "Q", tilde: nil, parameter: parameter)
        case 99: bytes = functionKey(prefix: "R", tilde: nil, parameter: parameter)
        case 118: bytes = functionKey(prefix: "S", tilde: nil, parameter: parameter)
        case 96: bytes = functionKey(prefix: nil, tilde: 15, parameter: parameter)
        case 97: bytes = functionKey(prefix: nil, tilde: 17, parameter: parameter)
        case 98: bytes = functionKey(prefix: nil, tilde: 18, parameter: parameter)
        case 100: bytes = functionKey(prefix: nil, tilde: 19, parameter: parameter)
        case 101: bytes = functionKey(prefix: nil, tilde: 20, parameter: parameter)
        case 109: bytes = functionKey(prefix: nil, tilde: 21, parameter: parameter)
        case 103: bytes = functionKey(prefix: nil, tilde: 23, parameter: parameter)
        case 111: bytes = functionKey(prefix: nil, tilde: 24, parameter: parameter)
        default: break
        }

        if let bytes { emitUserInput(bytes); return }
        if modifiers.contains(.control),
           let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           let control = Self.controlByte(for: scalar) {
            let prefix: [UInt8] = modifiers.contains(.option) && optionAsMetaKey ? [0x1B] : []
            emitUserInput(prefix + [control])
            return
        }
        if modifiers.contains(.option), optionAsMetaKey {
            guard let text = event.charactersIgnoringModifiers, !text.isEmpty else { return }
            emitUserInput([0x1B] + Array(text.utf8))
            return
        }
        // Printable keys enter AppKit's text system, so dead keys and IME
        // preedit are not emitted as shell input before they are committed.
        interpretingTextEvent = event
        defer { interpretingTextEvent = nil }
        if inputContext?.handleEvent(event) == true { return }
        if let text = event.characters, !text.isEmpty {
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    // MARK: - Native text input

    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !discardingComposition else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if interpretingComposition {
            compositionCommit += text
            return
        }
        emitCommittedText(text)
    }

    private func emitCommittedText(_ text: String) {
        guard !text.isEmpty else { return }
        onTextInputCommitted?(text)
        emitUserInput(Array(text.utf8))
    }

    override func doCommand(by selector: Selector) {
        if interpretingComposition, !hasMarkedText(),
           selector == #selector(NSResponder.deleteBackward(_:)), !compositionCommit.isEmpty {
            compositionCommit.removeLast()
            return
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextComposition()
            return
        }
        // Return used to confirm an IME candidate must not also submit the
        // shell command. Other terminal control keys never enter this path.
        guard !interpretingComposition, !hasMarkedText(),
              let text = interpretingTextEvent?.characters, !text.isEmpty else { return }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !discardingComposition else { return }
        let wasComposing = hasMarkedText()
        let incoming = (string as? NSAttributedString)
            ?? NSAttributedString(string: (string as? String) ?? "")
        let replacement: NSRange
        if replacementRange.location != NSNotFound,
           replacementRange.location <= markedText.length {
            replacement = NSRange(location: replacementRange.location,
                                  length: min(replacementRange.length,
                                              markedText.length - replacementRange.location))
        } else {
            replacement = NSRange(location: 0, length: markedText.length)
        }
        markedText.replaceCharacters(in: replacement, with: incoming)
        let start = selectedRange.location == NSNotFound
            ? incoming.length : min(selectedRange.location, incoming.length)
        markedSelection = NSRange(location: replacement.location + start,
                                  length: min(selectedRange.length, incoming.length - start))
        if !wasComposing, hasMarkedText() { onTextCompositionStarted?() }
        updateMarkedTextPresentation()
    }

    func unmarkText() {
        markedText = NSMutableAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        markedTextView.text = NSAttributedString(string: "")
        markedTextView.removeFromSuperview()
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange {
        NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: markedText.length)
    }
    func selectedRange() -> NSRange { markedSelection }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location <= markedText.length else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let actual = NSRange(location: range.location,
                             length: min(range.length, markedText.length - range.location))
        actualRange?.pointee = actual
        return markedText.attributedSubstring(from: actual)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor, .backgroundColor, .underlineStyle, .markedClauseSegment]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let location = range.location == NSNotFound
            ? markedSelection.location : min(range.location, markedText.length)
        let length = min(range.length, markedText.length - location)
        actualRange?.pointee = NSRange(location: location, length: length)
        let display = markedTextView.text
        let prefix = display.attributedSubstring(from: NSRange(location: 0, length: location)).size().width
        var rect = markedTextFrame
        rect.origin.x += min(prefix + 2, max(0, rect.width - cellDimension.width))
        rect.size.width = cellDimension.width
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard hasMarkedText(), let window else { return NSNotFound }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let x = local.x - markedTextFrame.minX - 2
        guard x >= 0 else { return 0 }
        for index in 1...markedText.length {
            let prefix = markedTextView.text.attributedSubstring(
                from: NSRange(location: 0, length: index)).size().width
            if prefix > x { return index - 1 }
        }
        return markedText.length
    }

    private var markedTextFrame: NSRect {
        let grid = renderSnapshot.grid
        let row = min(max(0, grid.cursorRow - grid.displayTopRow), max(0, grid.rows - 1))
        let column = min(max(0, grid.cursorCol), max(0, grid.cols - 1))
        let size = markedTextView.text.size()
        let width = min(max(cellDimension.width, ceil(size.width) + 4), max(1, bounds.width))
        return NSRect(
            x: min(contentXOrigin + CGFloat(column) * cellDimension.width,
                   max(0, bounds.width - width)),
            y: bounds.maxY - topContentInset - CGFloat(row + 1) * cellDimension.height,
            width: width, height: max(cellDimension.height, ceil(size.height)))
    }

    private func updateMarkedTextPresentation() {
        guard hasMarkedText() else { markedTextView.removeFromSuperview(); return }
        let display = NSMutableAttributedString(attributedString: markedText)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        display.addAttributes([
            .font: storedFont, .foregroundColor: nativeForegroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: display.length))
        if markedSelection.length > 0 {
            display.addAttribute(.backgroundColor, value: selectedTextBackgroundColor,
                                 range: markedSelection)
        }
        markedTextView.text = display
        markedTextView.fill = nativeBackgroundColor
        markedTextView.frame = markedTextFrame
        addSubview(markedTextView, positioned: .above, relativeTo: nil)
        markedTextView.needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    private func cancelTextComposition() {
        compositionCommit = ""
        guard hasMarkedText() else { return }
        discardingComposition = true
        inputContext?.discardMarkedText()
        unmarkText()
        discardingComposition = false
    }

    var markedTextPresentationForTesting: (text: String, frame: NSRect)? {
        guard hasMarkedText(), markedTextView.superview === self else { return nil }
        return (markedTextView.text.string, markedTextView.frame)
    }

    static func returnKeyBytes(
        modifiers: NSEvent.ModifierFlags,
        kittyKeyboardFlags: Int
    ) -> [UInt8] {
        let relevant = modifiers.intersection([.shift, .option, .control])
        if (kittyKeyboardFlags & 1) != 0, !relevant.isEmpty {
            return Array("\u{1b}[13;\(modifierParameter(relevant))u".utf8)
        }
        if relevant.contains(.shift) || relevant.contains(.option) {
            return [0x1B, 0x0D]
        }
        return [0x0D]
    }

    @objc func paste(_ sender: Any?) {
        paste(from: .general)
    }

    func paste(from pasteboard: NSPasteboard) {
        guard let source = pasteboard.string(forType: .string) else { return }
        pasteText(source)
    }

    @objc func pasteSelection(_ sender: Any?) {
        let source = selectedText()
        guard !source.isEmpty else { return }
        pasteText(source)
    }

    @discardableResult func pasteText(_ source: String) -> Bool {
        guard let accepted = onPasteRequest?(source) ?? (onPasteRequest == nil ? source : nil)
        else { return false }
        cancelTextComposition()
        if terminal.bracketedPaste {
            emitUserInput(Array("\u{1b}[200~\(accepted)\u{1b}[201~".utf8))
        } else {
            emitUserInput(Array(accepted.utf8))
        }
        return true
    }

    @objc func copy(_ sender: Any?) {
        let text = selectedText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) { selectAllContent() }

    override func mouseDown(with event: NSEvent) {
        clearGesture()
        let local = convert(event.locationInWindow, from: nil)
        guard let point = gridPoint(at: local, clamp: false) else {
            // A click in the padding outside the grid still dismisses a selection.
            if selectionAnchor != nil { clearSelection(notify: true) }
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        onTerminalMouseDown?()
        if event.modifierFlags.contains(.command), let url = linkURL(at: local) {
            if let onOpenLink { onOpenLink(url) }
            else { NSWorkspace.shared.open(url) }
            return
        }

        gestureOrigin = point
        gestureClickCount = event.clickCount
        let forceSelection = terminal.mouseMode == .off
            || event.modifierFlags.contains(.shift)
            || event.modifierFlags.contains(.option)
            || event.clickCount > 1
        if forceSelection {
            gestureUsesNativeSelection = true
            if event.clickCount >= 3 { selectRow(point.absoluteRow) }
            else if event.clickCount == 2 { selectWord(at: point) }
            else {
                let anchor = SelectionPoint(row: point.absoluteRow, col: point.col)
                setSelection(anchor: anchor, active: anchor, notify: false)
            }
        } else {
            gestureReportsMouse = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = gestureOrigin,
              let point = gridPoint(
                at: convert(event.locationInWindow, from: nil), clamp: true)
        else { return }
        // Trackpad clicks wobble by a pixel or two; staying in the pressed
        // cell is still a click, not the start of a selection.
        if !gestureDragged,
           point.absoluteRow == origin.absoluteRow, point.col == origin.col { return }
        let beganTrackedDrag = gestureReportsMouse
        if gestureReportsMouse {
            gestureReportsMouse = false
            gestureUsesNativeSelection = true
            gestureDragged = true
        }
        guard gestureUsesNativeSelection else { return }
        gestureDragged = true
        let originPoint = SelectionPoint(row: origin.absoluteRow, col: origin.col)
        let anchor = beganTrackedDrag ? originPoint : (selectionAnchor ?? originPoint)
        setSelection(
            anchor: anchor,
            active: SelectionPoint(row: point.absoluteRow, col: point.col),
            notify: false)
    }

    override func mouseUp(with event: NSEvent) {
        defer { clearGesture() }
        guard let origin = gestureOrigin else { return }
        let final = gridPoint(
            at: convert(event.locationInWindow, from: nil), clamp: true) ?? origin
        if gestureReportsMouse && !gestureDragged {
            // A plain click dismisses a selection even when the app tracks the mouse.
            if selectionAnchor != nil { clearSelection(notify: true) }
            let modifiers = mouseModifiers(event.modifierFlags)
            terminal.sendMouseEvent(button: 0, pressed: true, motion: false,
                                    modifiers: modifiers,
                                    col: origin.col, row: origin.row)
            terminal.sendMouseEvent(button: 0, pressed: false, motion: false,
                                    modifiers: modifiers,
                                    col: final.col, row: final.row)
        } else if gestureUsesNativeSelection,
                  gestureClickCount == 1, !gestureDragged {
            clearSelection(notify: true)
        } else if gestureUsesNativeSelection, gestureClickCount == 1 {
            setSelection(
                anchor: selectionAnchor,
                active: SelectionPoint(row: final.absoluteRow, col: final.col),
                notify: true)
            copySelectionIfEnabled()
        } else if gestureUsesNativeSelection {
            onSelectionChanged?()
            copySelectionIfEnabled()
        }
    }

    /// Where copy-on-select writes; tests swap in a private pasteboard.
    var selectionPasteboard: NSPasteboard = .general

    /// Copy-on-select: a finished drag, double- or triple-click selection
    /// goes straight to the clipboard.
    private func copySelectionIfEnabled() {
        guard Preferences.shared.copyOnSelect else { return }
        let text = selectedText()
        guard !text.isEmpty else { return }
        selectionPasteboard.clearContents()
        selectionPasteboard.setString(text, forType: .string)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = gridPoint(
            at: convert(event.locationInWindow, from: nil), clamp: true) else { return }
        let speed = max(0.2, Preferences.shared.scrollSpeed)
        let delta = event.scrollingDeltaY * speed
        guard delta != 0 else { return }

        if terminal.mouseMode != .off {
            let steps = routedWheelSteps(delta: delta, precise: event.hasPreciseScrollingDeltas)
            guard steps != 0 else { return }
            let button = steps > 0 ? 64 : 65
            let modifiers = mouseModifiers(event.modifierFlags)
            for _ in 0..<min(31, abs(steps)) {
                terminal.sendMouseEvent(button: button, pressed: true, motion: false,
                                        modifiers: modifiers, col: point.col, row: point.row)
            }
            return
        }
        if terminal.isAlternateBuffer {
            let steps = routedWheelSteps(delta: delta, precise: event.hasPreciseScrollingDeltas)
            guard steps != 0 else { return }
            let sequence = steps > 0 ? "\u{1b}[A" : "\u{1b}[B"
            emitUserInput(Array(String(repeating: sequence,
                                       count: min(31, abs(steps))).utf8))
            return
        }

        // Fence the previous worker-owned viewport before changing motion.
        // Otherwise the worker can render old rows with the new scroll offset
        // between noteScroll/updateScrollHeld and installViewportUpdate. That
        // frame can look like the final target, then jump back into animation.
        // A fresh host capture cannot run until this main-actor event returns.
        metalRenderer?.sourceDidChange()
        if event.hasPreciseScrollingDeltas, smoothScroll {
            applyPreciseLocalScroll(delta)
        } else {
            scrollAccumulator = 0
            visualScrollOffset = 0
            metalRenderer?.setScrollHeld(0)
            let lines = min(31, max(1, Int(abs(delta).rounded())))
            let update = terminal.scrollViewport(lines: delta > 0 ? -lines : lines)
            if update.after != update.before {
                let glidePoints = Self.discreteScrollGlidePixels(
                    before: update.before, after: update.after,
                    cellHeight: cellDimension.height)
                metalRenderer?.noteScroll(pixels: Self.rendererScrollPixels(
                    points: glidePoints, backingScale: backingScaleFactor()))
            }
            // Fence/capture after the animation control. A READY issued by the
            // old scroll state must not install a new viewport with zero glide
            // and then let the next frame start its animation afterward.
            installViewportUpdate(update)
            if update.after != update.before, let metalView {
                metalRenderer?.requestViewportDraw(in: metalView)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointerCursor(
            at: convert(event.locationInWindow, from: nil),
            modifiers: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func flagsChanged(with event: NSEvent) {
        updatePointerCursor(
            at: convert(event.locationInWindow, from: nil),
            modifiers: event.modifierFlags)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let gridHeight = CGFloat(renderSnapshot.grid.rows) * cellDimension.height
        let gridWidth = CGFloat(renderSnapshot.grid.cols) * cellDimension.width
        let rect = NSRect(
            x: contentXOrigin,
            y: bounds.maxY - topContentInset - gridHeight,
            width: gridWidth, height: gridHeight).intersection(bounds)
        if !rect.isEmpty { addCursorRect(rect, cursor: .iBeam) }
        if topContentInset > 0 {
            addCursorRect(NSRect(x: bounds.minX,
                                 y: bounds.maxY - topContentInset,
                                 width: bounds.width,
                                 height: topContentInset), cursor: .arrow)
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        queueDisplay()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        forceRedraw()
    }

    func linkURL(at point: NSPoint) -> URL? {
        guard let grid = gridPoint(at: point, clamp: false),
              let line = renderSnapshot.line(absolute: grid.absoluteRow),
              grid.col < line.cells.count else { return nil }
        var sourceColumn = grid.col
        while sourceColumn > 0, line.cells[sourceColumn].width == 0 {
            sourceColumn -= 1
        }
        let cell = line.cells[sourceColumn]
        if cell.linkId != 0, let value = terminal.linkURI(id: cell.linkId),
           let url = URL(string: value) { return url }

        var rowText = ""
        var cellRanges: [Int: NSRange] = [:]
        for (column, candidate) in line.cells.enumerated() where candidate.width != 0 {
            let text = snapshotCellText(candidate)
            let start = rowText.utf16.count
            rowText += text
            let range = NSRange(location: start, length: text.utf16.count)
            cellRanges[column] = range
            if candidate.width > 1 {
                for continuation in 1..<Int(candidate.width) {
                    cellRanges[column + continuation] = range
                }
            }
        }
        guard let target = cellRanges[grid.col] else { return nil }
        let pattern = #"(?i)(?:https?://|file://|mailto:|www\.|localhost(?::\d+)?|127\.0\.0\.1(?::\d+)?|\[::1\](?::\d+)?)[^\s<>\"']*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(location: 0, length: rowText.utf16.count)
        for match in expression.matches(in: rowText, range: full)
            where NSIntersectionRange(match.range, target).length > 0 {
            guard let swiftRange = Range(match.range, in: rowText) else { continue }
            var token = String(rowText[swiftRange])
            token = trimURLPunctuation(token)
            if token.lowercased().hasPrefix("www.") { token = "https://" + token }
            else if token.lowercased().hasPrefix("localhost")
                        || token.lowercased().hasPrefix("127.0.0.1")
                        || token.lowercased().hasPrefix("[::1]") {
                token = "http://" + token
            }
            return URL(string: token)
        }
        return nil
    }

    func startProcess(executable: String, args: [String], environment: [String]?,
                      currentDirectory: String?) {
        terminal.startProcess(executable: executable, args: args,
                              environment: environment,
                              currentDirectory: currentDirectory)
    }

    func terminate() {
        guard !terminated else { return }
        cancelTextComposition()
        terminated = true
        terminal.setRenderPublication(nil)
        directModelPublication = false
        terminal.observer = nil
        removeWindowObservers()
        if let systemColorObserver {
            NotificationCenter.default.removeObserver(systemColorObserver)
            self.systemColorObserver = nil
        }
        shaderRequestGeneration &+= 1
        metalRenderer?.onScrollOffsetChanged = nil
        metalRenderer?.close()
        onRendererError = nil
        metalView?.delegate = nil
        metalView?.removeFromSuperview()
        metalView = nil
        metalRenderer = nil
        terminal.terminate()
    }

    var shellPid: pid_t { terminal.shellPid }

    private var shapingStyle: CmdyShapingStyle {
        let traceStarted = CmdyPerformanceTrace.now()
        let style = CmdyShapingStyle(
            palette: palette,
            normalFont: storedFont,
            boldFont: fontVariant(bold: true, italic: false),
            italicFont: fontVariant(bold: false, italic: true),
            boldItalicFont: fontVariant(bold: true, italic: true),
            foreground: nativeForegroundColor,
            background: nativeBackgroundColor,
            selectionBackground: selectedTextBackgroundColor,
            failedRows: failedBlockRows,
            failedForeground: failedBlockForegroundColor,
            failedBackground: failedBlockBackgroundColor)
        CmdyPerformanceTrace.record(event: "surface.shapingStyle", started: traceStarted,
                                    fields: ["source": Int(bitPattern: ObjectIdentifier(self)),
                                             "fontConversions": 3])
        return style
    }

    private func sanitizedInset(_ proposed: CGFloat) -> CGFloat {
        max(0, proposed.isFinite ? proposed : 0)
    }

    private func metricsOrInsetsChanged(recomputeMetrics: Bool) {
        if recomputeMetrics {
            let metrics = Self.calculateMetrics(
                font: storedFont,
                multiplier: storedLineHeightMultiplier,
                scale: backingScaleFactor())
            cellDimension = metrics.size
            baselineFromRowTop = metrics.baseline
        }
        resizeGrid(reflowHooks: true, forceHookPair: recomputeMetrics)
        invalidateRows()
        resetCursorRects()
        if hasMarkedText() { updateMarkedTextPresentation() }
    }

    /// True while an adopted, already running model keeps the grid its shell
    /// started with. Window construction lays this view out at transient
    /// sizes; forwarding them would resize the shell repeatedly before the
    /// window is placed. releaseGridHold() applies the settled geometry once.
    private(set) var holdsGrid = false

    func releaseGridHold() {
        guard holdsGrid else { return }
        holdsGrid = false
        if CmdyPerformanceTrace.enabled {
            let scale = backingScaleFactor()
            CmdyPerformanceTrace.record(event: "startup.grid-hold-release", started: CmdyPerformanceTrace.now(), fields: [
                "pixelWidth": Int((max(0, bounds.width - storedLeftInset - storedRightInset) * scale).rounded(.down)),
                "pixelHeight": Int((max(0, bounds.height - storedTopInset - bottomContentInset) * scale).rounded(.down)),
                "boundsHeight": Int(bounds.height), "topInset": Int(storedTopInset), "bottomInset": Int(bottomContentInset)])
        }
        resizeGrid(reflowHooks: true)
    }

    private func resizeGrid(reflowHooks: Bool, forceHookPair: Bool = false) {
        guard !holdsGrid, cellDimension.width > 0, cellDimension.height > 0 else { return }
        let availableWidth = max(0, bounds.width - storedLeftInset - storedRightInset)
        let availableHeight = max(0, bounds.height - storedTopInset - bottomContentInset)
        let cols = max(2, Int(floor(availableWidth / cellDimension.width)))
        let rows = max(1, Int(floor(availableHeight / cellDimension.height)))
        let changed = cols != renderSnapshot.grid.cols || rows != renderSnapshot.grid.rows
        if changed {
            if reflowHooks { willReflowBuffer?() }
            let scale = backingScaleFactor()
            let snapshot = terminal.resize(
                cols: cols, rows: rows,
                pixelWidth: Int((availableWidth * scale).rounded(.down)),
                pixelHeight: Int((availableHeight * scale).rounded(.down)))
            installSnapshot(snapshot)
            updatePTYWindowSize(cols: cols, rows: rows,
                                pixelWidth: Int((availableWidth * scale).rounded(.down)),
                                pixelHeight: Int((availableHeight * scale).rounded(.down)))
            onSizeChanged?(cols, rows)
            if reflowHooks { didReflowBuffer?() }
            onViewportChanged?()
        } else {
            if reflowHooks && forceHookPair { willReflowBuffer?() }
            updatePixelMetadataAndPTY(cols: cols, rows: rows)
            if reflowHooks && forceHookPair { didReflowBuffer?() }
        }
        queueDisplay()
    }

    private func updatePixelMetadataAndPTY(cols: Int, rows: Int) {
        let scale = backingScaleFactor()
        let availableWidth = max(0, bounds.width - storedLeftInset - storedRightInset)
        let availableHeight = max(0, bounds.height - storedTopInset - bottomContentInset)
        let pixelWidth = Int((availableWidth * scale).rounded(.down))
        let pixelHeight = Int((availableHeight * scale).rounded(.down))
        terminal.updatePixelSize(width: pixelWidth, height: pixelHeight)
        updatePTYWindowSize(cols: cols, rows: rows,
                            pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private func updatePTYWindowSize(
        cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int
    ) {
        let descriptor = terminal.childFileDescriptor
        guard descriptor >= 0 else { return }
        var size = winsize()
        size.ws_col = UInt16(clamping: cols)
        size.ws_row = UInt16(clamping: rows)
        size.ws_xpixel = UInt16(clamping: pixelWidth)
        size.ws_ypixel = UInt16(clamping: pixelHeight)
        _ = ioctl(descriptor, TIOCSWINSZ, &size)
    }

    private func appearanceChanged() {
        layer?.backgroundColor = metalView == nil
            ? nativeBackgroundColor.cgColor : NSColor.clear.cgColor
        metalView?.layer?.isOpaque = nativeBackgroundColor.alphaComponent >= 1 && shaderMode != -1
        invalidateRows()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Appearance can change without assigning any color preference. Clear
        // even clean cached rows, including inverse/semantic palette colors.
        effectiveAppearance.performAsCurrentDrawingAppearance { appearanceChanged() }
    }

    private func invalidateRows() {
        snapshotRowContext.beginFrame()
        metalRenderer?.invalidateRowCache()
        queueDisplay()
    }

    private func installSnapshot(_ snapshot: CoreTerminalSnapshot, notifyRenderer: Bool = true) {
        // Model publication can request renderer activity without queueDisplay.
        frameContentGeneration &+= 1
        let widthChanged = snapshot.grid.cols != renderSnapshot.grid.cols
        renderSnapshot = snapshot
        pendingDirtyRows = union(pendingDirtyRows, snapshot.dirtyRows)
        if notifyRenderer { metalRenderer?.sourceDidChange() }
        if widthChanged {
            // Selection and search hits are physical row/column coordinates.
            // A width reflow can move their cells to different rows, so keeping
            // those coordinates would silently select or copy different text.
            clearSearch()
        }
        if hasMarkedText() { updateMarkedTextPresentation() }
    }

    private func installViewportUpdate(_ update: TerminalViewportUpdate) {
        guard let snapshot = update.snapshot else {
            if update.after == update.before,
               update.after == renderSnapshot.grid.liveTopRow { resetScrollOffset() }
            return
        }
        installSnapshot(snapshot)
        if let damage = update.damage {
            pendingDirtyRows = union(pendingDirtyRows, damage.rows)
            if damage.invalidatesAllRows { metalRenderer?.invalidateRowCache() }
        }
        queueDisplay()
        onViewportChanged?()
    }

    private func emitUserInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let traceStarted = CmdyPerformanceTrace.now()
        defer {
            CmdyPerformanceTrace.record(event: "surface.input", started: traceStarted,
                                        fields: ["source": Int(bitPattern: ObjectIdentifier(self)),
                                                 "model": Int(bitPattern: ObjectIdentifier(terminal)),
                                                 "bytes": bytes.count])
        }
        let currentTop = terminal.currentTopRow
        let liveTop = terminal.liveScreenTopRow
        if currentTop != liveTop {
            installViewportUpdate(terminal.scrollViewport(
                to: liveTop))
        }
        resetScrollOffset()
        activityKeypressTime = CFAbsoluteTimeGetCurrent()
        metalRenderer?.noteKeyboardInteraction()
        terminal.sendUserInput(bytes)
    }

    private func applyPreciseLocalScroll(_ delta: CGFloat) {
        let current = renderSnapshot.grid.displayTopRow
        let live = renderSnapshot.grid.liveTopRow
        if (delta > 0 && current <= 0) || (delta < 0 && current >= live) {
            resetScrollOffset()
            return
        }
        scrollAccumulator += delta
        let wholeRows = Int(scrollAccumulator / cellDimension.height)
        if wholeRows != 0 {
            let update = terminal.scrollViewport(lines: -wholeRows)
            let movedRows = update.before - update.after
            if movedRows != 0 { installViewportUpdate(update) }
            // At either boundary the model may clamp a multi-row request.
            // Consuming the full requested distance in that case reverses the
            // remainder and produces the visible edge jiggle.
            guard movedRows == wholeRows else {
                resetScrollOffset()
                return
            }
            scrollAccumulator -= CGFloat(wholeRows) * cellDimension.height
        }
        let now = renderSnapshot.grid.displayTopRow
        if (delta > 0 && now <= 0) || (delta < 0 && now >= renderSnapshot.grid.liveTopRow) {
            resetScrollOffset()
            return
        }
        if let metalRenderer {
            let scale = backingScaleFactor()
            metalRenderer.updateScrollHeld(
                Self.rendererScrollPixels(
                    points: scrollAccumulator, backingScale: scale),
                activityPixels: Self.rendererScrollPixels(
                    points: delta, backingScale: scale))
        } else {
            let snapped = snapToPixel(scrollAccumulator)
            if visualScrollOffset != snapped {
                visualScrollOffset = snapped
                onVisualScrollChanged?()
            }
            queueDisplay()
        }
    }

    static func discreteScrollGlidePixels(
        before: Int, after: Int, cellHeight: CGFloat
    ) -> CGFloat {
        guard cellHeight.isFinite, cellHeight > 0 else { return 0 }
        // The model moves first. Apply the inverse visual displacement so the
        // old rows begin at their pre-event positions, then glide to the new
        // viewport alignment as this offset decays to zero.
        return CGFloat(after - before) * cellHeight
    }

    /// Metal's frozen scroll contract accepts device pixels with the opposite
    /// sign from AppKit's point-space gesture. Keeping the conversion at the
    /// App boundary preserves live motion while preventing backing scale from
    /// changing the renderer's public-input semantics.
    nonisolated static func rendererScrollPixels(
        points: CGFloat, backingScale: CGFloat
    ) -> CGFloat {
        guard points.isFinite else { return 0 }
        let scale = backingScale.isFinite && backingScale > 0
            ? min(16, max(1, backingScale)) : 1
        let pixels = -(points * scale)
        return pixels.isFinite ? min(1_000_000, max(-1_000_000, pixels)) : 0
    }

    private func routedWheelSteps(delta: CGFloat, precise: Bool) -> Int {
        if precise {
            routedWheelAccumulator += delta
            let steps = Int(routedWheelAccumulator / max(1, cellDimension.height))
            if steps != 0 {
                routedWheelAccumulator -= CGFloat(steps) * cellDimension.height
            }
            return max(-31, min(31, steps))
        }
        routedWheelAccumulator = 0
        let magnitude = min(31, max(1, Int(abs(delta).rounded())))
        return delta > 0 ? magnitude : -magnitude
    }

    private func normalizedSelection() -> (start: SelectionPoint, end: SelectionPoint)? {
        guard let anchor = selectionAnchor, let active = selectionActive else { return nil }
        if anchor.row < active.row || (anchor.row == active.row && anchor.col <= active.col) {
            return (anchor, active)
        }
        return (active, anchor)
    }

    private func setSelection(
        anchor: SelectionPoint?, active: SelectionPoint?, notify: Bool
    ) {
        let oldAnchor = selectionAnchor
        let oldActive = selectionActive
        let changed = oldAnchor != anchor || oldActive != active
        if changed {
            // Selection uses its own renderer interaction path, without a
            // redraw request or any mutation of immutable terminal rows.
            frameContentGeneration &+= 1
            selectionAnchor = anchor
            selectionActive = active
            // Selection is composed as a dynamic Metal overlay. Invalidating
            // immutable row textures here made every drag rerasterize text on
            // the main thread, even though no terminal cell had changed.
            if let metalRenderer {
                metalRenderer.noteSelectionInteraction()
            } else {
                queueDisplay()
            }
        }
        // Drag updates are intentionally silent until mouse-up. Mouse-up may
        // repeat the last drag coordinate, but still completes the selection
        // exactly once for observers such as Copy and the command palette.
        if notify,
           changed || oldAnchor != nil || oldActive != nil
                || anchor != nil || active != nil {
            onSelectionChanged?()
        }
    }

    private func clearSelection(notify: Bool) {
        setSelection(anchor: nil, active: nil, notify: notify)
    }

    private func selectRow(_ row: Int) {
        setSelection(
            anchor: SelectionPoint(row: row, col: 0),
            active: SelectionPoint(
                row: row, col: max(0, renderSnapshot.grid.cols - 1)),
            notify: false)
    }

    private func selectWord(at point: GridPoint) {
        guard let line = renderSnapshot.line(absolute: point.absoluteRow),
              !line.cells.isEmpty else { return }
        func whitespace(_ index: Int) -> Bool {
            guard line.cells.indices.contains(index) else { return true }
            let cell = line.cells[index]
            return cell.width == 0 || snapshotCellText(cell)
                .allSatisfy { $0.isWhitespace }
        }
        var lower = min(point.col, line.cells.count - 1)
        var upper = lower
        let targetWhitespace = whitespace(lower)
        while lower > 0, whitespace(lower - 1) == targetWhitespace { lower -= 1 }
        while upper + 1 < line.cells.count,
              whitespace(upper + 1) == targetWhitespace { upper += 1 }
        setSelection(
            anchor: SelectionPoint(row: point.absoluteRow, col: lower),
            active: SelectionPoint(row: point.absoluteRow, col: upper),
            notify: false)
    }

    private func prepareSearch(_ term: String, options: TermSearchOptions) {
        guard term != searchTerm || options != searchOptions else { return }
        searchTerm = term
        searchOptions = options
        activeSearchIndex = nil
        guard !term.isEmpty else { searchHits = []; return }
        let all = terminal.searchAll(term, options: options)
        searchHits = options.wholeWord
            ? all.filter { wholeWordHit($0) }
            : all
    }

    private func wholeWordHit(_ hit: TerminalSearchHit) -> Bool {
        guard let line = terminal.lineSnapshot(absolute: hit.row) else { return false }
        func isWord(_ column: Int) -> Bool {
            guard line.cells.indices.contains(column) else { return false }
            let text = snapshotCellText(line.cells[column])
            return text.unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0) || $0.value == 0x5F
            }
        }
        return !isWord(hit.col - 1) && !isWord(hit.col + hit.length)
    }

    private func revealSearchHit(_ hit: TerminalSearchHit) {
        setSelection(
            anchor: SelectionPoint(row: hit.row, col: hit.col),
            active: searchHitEnd(hit),
            notify: false)
        let centered = hit.row - renderSnapshot.grid.rows / 2
        installViewportUpdate(terminal.scrollViewport(to: centered))
        onSelectionChanged?()
    }

    private func searchHitEnd(_ hit: TerminalSearchHit) -> SelectionPoint {
        var remaining = max(1, hit.length)
        var row = max(0, hit.row)
        var column = max(0, hit.col)
        let finalRow = max(0, renderSnapshot.grid.bufferLineCount - 1)
        var last = SelectionPoint(row: row, col: column)
        while row <= finalRow, let line = terminal.lineSnapshot(absolute: row) {
            while column < line.cells.count {
                let cell = line.cells[column]
                if cell.width != 0 {
                    last = SelectionPoint(row: row, col: column)
                    remaining -= 1
                    if remaining == 0 { return last }
                }
                column += 1
            }
            row += 1
            column = 0
        }
        return last
    }

    private func gridPoint(at point: NSPoint, clamp: Bool) -> GridPoint? {
        let grid = renderSnapshot.grid
        guard grid.cols > 0, grid.rows > 0 else { return nil }
        let x0 = contentXOrigin
        let yDown = bounds.maxY - point.y
        let gridWidth = CGFloat(grid.cols) * cellDimension.width
        let gridHeight = CGFloat(grid.rows) * cellDimension.height
        if !clamp {
            guard point.x >= x0, point.x < x0 + gridWidth,
                  yDown >= storedTopInset,
                  yDown < storedTopInset + gridHeight else { return nil }
        }
        let x = min(x0 + max(0, gridWidth.nextDown), max(x0, point.x))
        let y = min(storedTopInset + max(0, gridHeight.nextDown),
                    max(storedTopInset, yDown))
        let col = min(grid.cols - 1, max(0, Int((x - x0) / cellDimension.width)))
        let row = min(grid.rows - 1,
                      max(0, Int((y - storedTopInset) / cellDimension.height)))
        return GridPoint(row: row, col: col,
                         absoluteRow: grid.displayTopRow + row)
    }

    private func mouseModifiers(
        _ flags: NSEvent.ModifierFlags
    ) -> CmdyTerminal.MouseModifiers {
        var result: CmdyTerminal.MouseModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.meta) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    private func updatePointerCursor(
        at point: NSPoint, modifiers: NSEvent.ModifierFlags
    ) {
        guard gridPoint(at: point, clamp: false) != nil else {
            NSCursor.arrow.set()
            return
        }
        if modifiers.contains(.command), linkURL(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    private func clearGesture() {
        gestureOrigin = nil
        gestureUsesNativeSelection = false
        gestureReportsMouse = false
        gestureDragged = false
        gestureClickCount = 0
    }

    private func removeWindowObservers() {
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        windowObservers.removeAll(keepingCapacity: false)
    }

    private func specialKey(final: Character, parameter: Int,
                            application: Bool) -> [UInt8] {
        if parameter == 1 {
            return Array((application ? "\u{1b}O\(final)" : "\u{1b}[\(final)").utf8)
        }
        return Array("\u{1b}[1;\(parameter)\(final)".utf8)
    }

    private func homeEndKey(final: Character, parameter: Int,
                            application: Bool) -> [UInt8] {
        specialKey(final: final, parameter: parameter, application: application)
    }

    private func tildeKey(code: Int, parameter: Int) -> [UInt8] {
        Array((parameter == 1
               ? "\u{1b}[\(code)~"
               : "\u{1b}[\(code);\(parameter)~").utf8)
    }

    private func functionKey(prefix: Character?, tilde: Int?,
                             parameter: Int) -> [UInt8] {
        if let prefix {
            return Array((parameter == 1
                          ? "\u{1b}O\(prefix)"
                          : "\u{1b}[1;\(parameter)\(prefix)").utf8)
        }
        return tildeKey(code: tilde ?? 0, parameter: parameter)
    }

    private static func modifierParameter(_ flags: NSEvent.ModifierFlags) -> Int {
        1 + (flags.contains(.shift) ? 1 : 0)
            + (flags.contains(.option) ? 2 : 0)
            + (flags.contains(.control) ? 4 : 0)
    }

    private static func controlByte(for scalar: Unicode.Scalar) -> UInt8? {
        let value = scalar.value
        if value == 0x20 { return 0 }
        if value >= 0x41, value <= 0x5A { return UInt8(value - 0x40) }
        if value >= 0x61, value <= 0x7A { return UInt8(value - 0x60) }
        switch value {
        case 0x5B: return 27
        case 0x5C: return 28
        case 0x5D: return 29
        case 0x5E: return 30
        case 0x5F, 0x2D: return 31
        default: return nil
        }
    }

    /// The grid a fresh first window will lay out to, so a shell started
    /// before that window exists usually needs no resize. A mismatch is
    /// corrected by the ordinary layout pass.
    /// The grid and PTY pixel size of a pane filling `contentSize`, with the
    /// window's top content inset and the margin on the other three sides.
    static func predictedGrid(contentSize: NSSize, font: NSFont, lineHeight: CGFloat,
                              margin: CGFloat, topInset: CGFloat,
                              scale: CGFloat)
        -> (cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        let cell = calculateMetrics(font: font, multiplier: lineHeight, scale: scale).size
        let width = max(0, contentSize.width - margin * 2)
        let height = max(0, contentSize.height - topInset - margin)
        // Same pixel rounding as updatePixelMetadataAndPTY, so the adopted PTY's
        // size is unchanged when the hold is released and the shell is not
        // sent a SIGWINCH that makes it redraw its first prompt.
        let pixelWidth = Int((width * scale).rounded(.down))
        let pixelHeight = Int((height * scale).rounded(.down))
        guard cell.width > 0, cell.height > 0 else { return (80, 24, pixelWidth, pixelHeight) }
        return (max(2, Int(floor(width / cell.width))), max(1, Int(floor(height / cell.height))),
                pixelWidth, pixelHeight)
    }

    private static func calculateMetrics(
        font: NSFont, multiplier: CGFloat, scale: CGFloat
    ) -> (size: CGSize, baseline: CGFloat) {
        withExtendedLifetime(font) {
            let metrics = cmdy_shape_metrics(Unmanaged.passUnretained(font).toOpaque(), multiplier, scale)
            return (CGSize(width: metrics.width, height: metrics.height), metrics.baseline)
        }
    }

    private func snapToPixel(_ value: CGFloat) -> CGFloat {
        let scale = max(1, backingScaleFactor())
        return (value * scale).rounded() / scale
    }

    private static func color(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }

    private func snapshotCellText(_ cell: Cell) -> String {
        guard cell.scalar != 0, let first = Unicode.Scalar(cell.scalar) else { return " " }
        var result = String(first)
        for raw in cell.clusterExtras ?? [] {
            if let scalar = Unicode.Scalar(raw) { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    private func trimURLPunctuation(_ source: String) -> String {
        var result = source
        let trailing = CharacterSet(charactersIn: ".,;:!?)]}'\"")
        while let scalar = result.unicodeScalars.last, trailing.contains(scalar) {
            result.removeLast()
        }
        return result
    }

    private func union(
        _ lhs: ClosedRange<Int>?, _ rhs: ClosedRange<Int>?
    ) -> ClosedRange<Int>? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs.lowerBound, rhs.lowerBound)...max(lhs.upperBound, rhs.upperBound)
    }
}

extension CmdyTerminalSurface: TerminalModelObserver {
    func terminalModel(
        _ model: TerminalModel, didPublish snapshot: CoreTerminalSnapshot,
        damage: SnapshotPublicationDamage
    ) {
        let traceStarted = CmdyPerformanceTrace.now()
        defer {
            CmdyPerformanceTrace.record(event: "surface.publish", started: traceStarted,
                                        fields: ["source": Int(bitPattern: ObjectIdentifier(self)),
                                                 "model": Int(bitPattern: ObjectIdentifier(model)),
                                                 "rows": snapshot.grid.rows,
                                                 "columns": snapshot.grid.cols,
                                                 "dirtyRows": damage.rows?.count ?? 0,
                                                 "invalidatesAllRows": damage.invalidatesAllRows ? 1 : 0])
        }
        let followedTail = renderSnapshot.grid.displayTopRow
            == renderSnapshot.grid.liveTopRow
        let oldLiveTop = renderSnapshot.grid.liveTopRow
        let publishedDirectly = directModelPublication && model.wasPublishedToRenderer(snapshot)
        installSnapshot(snapshot, notifyRenderer: !publishedDirectly)
        pendingDirtyRows = union(pendingDirtyRows, damage.rows)
        if damage.invalidatesAllRows { metalRenderer?.invalidateRowCache() }
        if followedTail, snapshot.grid.liveTopRow != oldLiveTop {
            resetScrollOffset()
        }
        if let metalRenderer {
            if !publishedDirectly { metalRenderer.noteActivity() }
        } else {
            queueDisplay()
        }
        onViewportChanged?()
    }

    func terminalModel(_ model: TerminalModel, didSetTitle title: String) {
        onTitleChanged?(title)
    }

    func terminalModel(
        _ model: TerminalModel, didSetCurrentDirectory directory: String?
    ) {
        onCwdChanged?(directory)
    }

    func terminalModelDidBell(_ model: TerminalModel) {
        NSSound.beep()
        onBell?()
    }

    func terminalModel(
        _ model: TerminalModel, didRequestNotification title: String, body: String
    ) {
        onNotification?(title, body)
    }

    func terminalModel(
        _ model: TerminalModel, didRequestClipboardCopy content: Data
    ) {
        guard let value = String(data: content, encoding: .utf8), !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func terminalModel(_ model: TerminalModel, didSend data: [UInt8]) {
        onSendToProcess?(data[...])
    }

    func terminalModel(
        _ model: TerminalModel, processTerminated exitCode: Int32?
    ) {
        onProcessTerminated?(exitCode)
    }

    func consumePublishedDirtyRows() -> ClosedRange<Int>? {
        let result = pendingDirtyRows
        pendingDirtyRows = nil
        return result
    }
}

extension CmdyTerminalSurface: MetalRenderSource, SnapshotRowRevisionSource, DeferredRowRenderSource, WorkerPublishedRenderSource, NativeViewportRenderSource {
    var frameContentRevision: UInt64 { frameContentGeneration }

    func nativeFrameGraphics() -> NativeFrameGraphics? {
        frameSnapshot.withNativeGraphics { $0.map { NativeFrameGraphics(retaining: $0) } }
    }

    func nativeFrameViewport() throws -> NativeFrameViewport {
        let style = try snapshotRowContext.nativeStyle(shapingStyle, appearance: effectiveAppearance)
        let selection = normalizedSelection().map { ($0.start.row, $0.start.col, $0.end.row, $0.end.col) }
        return frameSnapshot.withNativeRows { NativeFrameViewport(retaining: $0, style: style, selection: selection,
            modelGeneration: frameSnapshot.modelPublicationGeneration) }
    }

    func captureGrid() -> GridSnapshot {
        frameSnapshot = renderSnapshot
        let grid = frameSnapshot.grid
        return GridSnapshot(
            rows: grid.rows, cols: grid.cols,
            bufferLineCount: grid.bufferLineCount,
            retainedRowOrigin: grid.retainedRowOrigin,
            displayTopRow: grid.displayTopRow,
            liveTopRow: grid.liveTopRow,
            cursorRow: grid.cursorRow,
            cursorCol: grid.cursorCol,
            cursorHidden: grid.cursorHidden,
            cursorStyle: renderCursorStyle(grid.cursorStyle),
            isAlternateBuffer: grid.isAlternateBuffer)
    }

    func lineInfo(forRow row: Int) -> ViewLineInfo {
        let traceStarted = CmdyPerformanceTrace.now()
        let info = CmdySnapshotShaper.lineInfo(
            snapshot: frameSnapshot,
            absoluteRow: row,
            style: snapshotRowContext.style(shapingStyle, appearance: effectiveAppearance),
            selectedColumns: nil)
        CmdyPerformanceTrace.record(event: "surface.lineInfo", started: traceStarted,
                                    fields: ["source": Int(bitPattern: ObjectIdentifier(self)),
                                             "row": row, "segments": info.segments.count])
        return info
    }

    func snapshotRowRevision(forRow row: Int) -> SnapshotRowRevision? {
        snapshotRowContext.revision(
            snapshot: frameSnapshot, absoluteRow: row, style: shapingStyle,
            appearance: effectiveAppearance)
    }

    func deferredRenderRow(forRow row: Int, parameters: NativeRowCaptureParameters) throws -> DeferredRenderRow? {
        try snapshotRowContext.deferredRow(snapshot: frameSnapshot, absoluteRow: row,
            style: shapingStyle, appearance: effectiveAppearance, parameters: parameters)
    }

    func lineRenderMode(forRow row: Int) -> CmdyGPU.RenderLineMode {
        guard let line = frameSnapshot.line(absolute: row) else { return .single }
        switch line.renderMode {
        case .single: return .single
        case .doubleWidth: return .doubleWidth
        case .doubledTop: return .doubledTop
        case .doubledDown: return .doubledDown
        }
    }

    func lineVersion(forRow row: Int) -> UInt64 {
        frameSnapshot.line(absolute: row)?.version ?? 0
    }

    func cursorCellAttributedString() -> NSAttributedString? {
        CmdySnapshotShaper.cursorString(
            snapshot: frameSnapshot,
            style: shapingStyle,
            caretColor: caretColor,
            caretTextColor: caretTextColor)
    }

    var kittyStamp: KittyCacheStamp {
        KittyCacheStamp(
            imagesCount: frameSnapshot.kittyImages.count,
            placementsCount: frameSnapshot.kittyPlacements.count,
            nextImageId: frameSnapshot.kittyNextImageId,
            nextPlacementId: frameSnapshot.kittyNextPlacementId)
    }

    func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec] {
        frameSnapshot.kittyPlacements.compactMap { placement in
            guard placement.isVirtual,
                  placement.isAlternateBuffer == alternateBuffer else { return nil }
            return KittyPlacementSpec(
                imageId: placement.imageId,
                placementId: placement.placementId,
                cols: placement.cols, rows: placement.rows,
                pixelOffsetX: placement.pixelOffsetX,
                pixelOffsetY: placement.pixelOffsetY)
        }
    }

    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? {
        guard let image = frameSnapshot.kittyImages[imageId] else { return nil }
        switch image.payload {
        case .png(let data): return .png(data)
        case .rgba(let bytes, let width, let height):
            return .rgba(bytes: bytes, width: width, height: height)
        }
    }

    var kittyLiveImageIds: Set<UInt32> {
        Set(frameSnapshot.kittyImages.keys)
    }

    var viewBounds: CGRect { bounds }
    func backingScaleFactor() -> CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }
    var normalFont: NSFont { storedFont }
    func underlinePosition() -> CGFloat { storedFont.underlinePosition }
    func underlineThickness() -> CGFloat { max(1 / backingScaleFactor(), storedFont.underlineThickness) }
    // The renderer publishes its composed translation into visualScrollOffset
    // for AppKit overlays. It must not be read back as a renderer input or the
    // same trackpad remainder compounds on every frame.
    var scrollContentOffset: CGPoint { .zero }
    func getImageScale() -> CGFloat { backingScaleFactor() }
    var caretFocused: Bool { window?.firstResponder === self }
    var antiAliasCustomBlockGlyphs: Bool { true }
    var metalBufferingMode: MetalBufferingMode { .perRowPersistent }
    func consumeDirtyRows() -> ClosedRange<Int>? { consumePublishedDirtyRows() }

    func mapColor(_ color: CellColor, isFg: Bool, isBold: Bool) -> NSColor {
        CmdySnapshotShaper.mapColor(
            color, isForeground: isFg, isBold: isBold, style: shapingStyle)
    }

    func attributes(
        for attribute: CellAttribute, selected: Bool
    ) -> [NSAttributedString.Key: Any] {
        CmdySnapshotShaper.attributes(
            for: attribute, selected: selected, failed: false,
            style: shapingStyle)
    }

    private func renderCursorStyle(_ style: TermCursorShape) -> RenderCursorStyle {
        switch style {
        case .blinkBlock: return .blinkBlock
        case .steadyBlock: return .steadyBlock
        case .blinkUnderline: return .blinkUnderline
        case .steadyUnderline: return .steadyUnderline
        case .blinkBar: return .blinkBar
        case .steadyBar: return .steadyBar
        }
    }
}

extension CmdyTerminalSurface: MetalSelectionRenderSource {
    func selectionColumns(forRow row: Int) -> ClosedRange<Int>? {
        selectedColumnsForShaping(row: row)
    }

    var selectionBackgroundColor: NSColor { selectedTextBackgroundColor }
}
