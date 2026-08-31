import AppKit

/// Converts the terminal renderer's row baseline into the drawing origin used
/// by AppKit attributed strings. Custom terminal-adjacent surfaces must use
/// this instead of centering a font bounding box inside the row: bounding-box
/// centering drifts as soon as the configured line-height changes.
public final class TerminalRowTextLayout {
    private let layoutManager = NSLayoutManager()

    public init() {}

    public func drawOriginY(
        rowTop: CGFloat,
        baselineFromTop: CGFloat,
        font: NSFont
    ) -> CGFloat {
        rowTop + baselineFromTop
            - layoutManager.defaultBaselineOffset(for: font)
    }

    public func cursorVerticalFrame(
        rowTop: CGFloat,
        rowHeight: CGFloat,
        baselineFromTop: CGFloat,
        font: NSFont
    ) -> NSRect {
        let height = min(
            max(1, rowHeight),
            max(1, layoutManager.defaultLineHeight(for: font)))
        let proposedY = drawOriginY(
            rowTop: rowTop,
            baselineFromTop: baselineFromTop,
            font: font)
        let maximumY = rowTop + max(0, rowHeight - height)
        let y = min(max(rowTop, proposedY), maximumY)
        return NSRect(x: 0, y: y, width: 0, height: height)
    }
}

// The TerminalCore boundary: the exact surface cmdy consumes from its VT
// engine, defined as protocols so engines remain swappable. Everything in the
// app talks to these contracts rather than a concrete engine type.
//
// Coordinate system, used everywhere below: an ABSOLUTE ROW indexes the full
// buffer (scrollback + live screen), 0 = oldest retained line. Rows shift only
// when scrollback trimming drops lines off the top (`scrollbackDroppedLines`
// counts them) or when a reflow rewraps the buffer (bracketed by the
// `willReflowBuffer`/`didReflowBuffer` hooks).

// MARK: - Seam value types (engine-agnostic)

/// The six DECSCUSR cursor shapes.
public enum TermCursorStyle {
    case blinkBlock, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar
}

/// 16-bit-per-channel RGB — the terminal palette's native precision.
public struct TermColor: Equatable, Sendable {
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Buffer text search switches (FindBar assembles one from its toggles).
public struct TermSearchOptions: Equatable {
    public var caseSensitive = false
    public var regex = false
    public var wholeWord = false

    public init(caseSensitive: Bool = false, regex: Bool = false, wholeWord: Bool = false) {
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.wholeWord = wholeWord
    }
}

/// Movement of the active end of an existing terminal selection.
public enum TerminalSelectionAdjustment: Sendable {
    case left, right, up, down, pageUp, pageDown, home, end
}

// MARK: - TerminalEngine

/// The VT state machine + buffer, platform-free: nothing here may require
/// AppKit or Metal. This is the protocol CmdyCore conforms to.
public protocol TerminalEngine: AnyObject {
    var cols: Int { get }
    var rows: Int { get }

    /// Cursor position as an absolute row (yBase + y) — invariant under
    /// scrolling the viewport, shifts only with trims/reflow.
    var scrollInvariantCursorRow: Int { get }
    var cursorColumn: Int { get }

    /// Total buffer rows currently retained (scrollback + live screen).
    var bufferLineCount: Int { get }
    /// Absolute row currently at the top of the viewport (yDisp).
    var currentTopRow: Int { get }
    /// Absolute row where the live screen begins (yBase). Scrolled to the
    /// bottom, currentTopRow == liveScreenTopRow.
    var liveScreenTopRow: Int { get }
    /// Lines dropped off the top since startup (monotonic; blocks rebase on it).
    var scrollbackDroppedLines: Int { get }

    var isCurrentBufferAlternate: Bool { get }
    /// True when this row is a continuation of the previous row (soft wrap).
    /// Logical (unwrapped) lines — the identity block anchors survive reflow
    /// through — are the maximal runs [unwrapped row, wrapped rows...].
    func isBufferRowWrapped(_ row: Int) -> Bool
    /// Right-trimmed text of an absolute buffer row; nil when out of range.
    func scrollbackLineText(row: Int) -> String?
    /// Right-trimmed text for an inclusive row range. Implementations that
    /// serialize access to their buffer can capture the full range atomically.
    func scrollbackLineTexts(rows: ClosedRange<Int>) -> [String]
    /// Text for a terminal-cell range. This preserves the distinction between
    /// Unicode characters and the one or two grid cells they occupy.
    func scrollbackLineText(row: Int, columns: Range<Int>) -> String?

    /// Images retained by the kitty graphics store (id-keyed).
    var kittyImageCount: Int { get }
    /// Buffer lines that have at least one image placement attached.
    var linesWithImagesCount: Int { get }

    /// Current mouse tracking mode's case name (e.g. "off", "vt200").
    /// ABI-frozen: the string is exposed verbatim via /v1 scrollInfo.
    var mouseModeDescription: String { get }

    /// Interpret bytes as if they arrived from the process. Mutates the
    /// buffer only — the surface's `feed` also schedules a repaint.
    func feed(text: String)
    /// Insert host-generated explanatory text at the current semantic output
    /// boundary. This must not re-enter the VT parser from an OSC callback.
    func insertHostMessage(_ text: String)
    /// Install a parser-queue callback for immediate, deterministic command
    /// diagnostics. Returning text inserts it before bytes for the next prompt
    /// in the same PTY burst; returning nil leaves the transcript untouched.
    func setCommandFinishedHostMessageProvider(
        _ provider: ((String, String, Int32?) -> String?)?)
    /// Hook an OSC code (cmdy uses 133 for blocks). May be called off the
    /// main thread; handlers hop to main themselves.
    func registerOscHandler(code: Int, handler: @escaping (ArraySlice<UInt8>) -> Void)
    func setCursorStyle(_ style: TermCursorStyle)
}

public extension TerminalEngine {
    func scrollbackLineTexts(rows: ClosedRange<Int>) -> [String] {
        rows.map { scrollbackLineText(row: $0) ?? "" }
    }
}

// MARK: - TerminalSurface

/// The NSView hosting a terminal: appearance, insets, scrolling, search,
/// shader runtime, and the engine→host event channel. One per pane (and one
/// per headless test harness).
public protocol TerminalSurface: AnyObject {
    /// The actual view — for layout, first responder, and event injection.
    var view: NSView { get }
    var engine: TerminalEngine { get }

    // Bytes in/out
    /// Type into the process (keyboard channel).
    func send(txt: String)
    /// Feed the screen AND schedule a repaint (engine.feed mutates silently).
    func feed(text: String)
    /// Everything the view would write to the process (mouse reports, arrow
    /// keys, typed text). Headless suites capture this to assert routing.
    var onSendToProcess: ((ArraySlice<UInt8>) -> Void)? { get set }
    /// Paste policy hook. Return transformed text, or nil to cancel. It is
    /// invoked only for explicit user paste, never for ordinary PTY output.
    var onPasteRequest: ((String) -> String?)? { get set }
    /// Called when the terminal canvas receives a primary click, before
    /// selection or mouse reporting is processed.
    var onTerminalMouseDown: (() -> Void)? { get set }
    /// Called for a user-activated terminal hyperlink (normally Command-click).
    var onOpenLink: ((URL) -> Void)? { get set }

    // Grid metrics & appearance
    var font: NSFont { get set }
    /// One cell in points, line-height multiplier included.
    var cellSize: CGSize { get }
    /// Text baseline measured down from the top edge of a grid row.
    var textBaselineFromRowTop: CGFloat { get }
    var lineHeightMultiplier: CGFloat { get set }
    /// Install the 16-entry ANSI palette.
    func installColors(_ colors: [TermColor])
    var nativeForegroundColor: NSColor { get set }
    var nativeBackgroundColor: NSColor { get set }
    var caretColor: NSColor { get set }
    /// Color of the character under a block cursor (nil = renderer default).
    var caretTextColor: NSColor? { get set }
    var selectedTextBackgroundColor: NSColor { get set }
    var optionAsMetaKey: Bool { get set }

    // Insets — the grid lends space to UI (inline panels, gutters, chrome).
    // Resize math accounts for reserved space; content reflows, not overlays.
    var topContentInset: CGFloat { get set }
    var bottomContentInset: CGFloat { get set }
    var leftContentInset: CGFloat { get set }
    var rightContentInset: CGFloat { get set }
    /// Where column 0 starts in view coords: left inset + half the wrap
    /// remainder (the spare points when width isn't a whole cell multiple).
    var contentXOrigin: CGFloat { get }
    var showsScroller: Bool { get set }

    // GPU / shader runtime
    func setUseMetal(_ on: Bool) throws
    var isUsingMetalRenderer: Bool { get }
    /// Compile + install a user shader (cmdy_main contract). Returns the
    /// compile error, or nil on success. Passing nil clears it.
    @discardableResult
    func setUserShader(_ source: String?) -> String?
    /// Built-in shader index into Preferences.shaderNames (append-only), or
    /// -1 while a user shader is installed.
    var shaderMode: Int { get set }
    /// Diagnostic GPU glyph rasterization preset.
    var textRenderingModeName: String { get set }
    var smoothCursor: Bool { get set }
    /// Host UI can suppress the shell cursor while a focused inline surface
    /// owns keyboard input. This does not alter the PTY cursor state.
    var hostCursorHidden: Bool { get set }
    /// Cursor chase-rate multiplier. 1.0 preserves the renderer default;
    /// larger values settle faster, smaller values produce a longer glide.
    var cursorGlideSpeed: CGFloat { get set }
    /// Maximum cursor jump to animate, measured in terminal cells. Zero means
    /// unlimited; larger jumps snap immediately to avoid a distracting flyover.
    var cursorGlideMaxDistance: CGFloat { get set }
    var smoothScroll: Bool { get set }
    /// Absolute prompt rows whose command exited unsuccessfully. These rows
    /// are styled in-scene instead of consuming a permanent marker gutter.
    var failedBlockRows: Set<Int> { get set }
    var failedBlockForegroundColor: NSColor { get set }
    var failedBlockBackgroundColor: NSColor { get set }
    /// Activity telemetry driving reactive shaders.
    var activityKeypressTime: Double { get set }
    var activityTypingRate: Float { get set }
    /// Repaint everything now (theme flips, occlusion wake).
    func forceRedraw()

    // Scrolling (absolute rows; clamped by the view)
    func scrollTo(row: Int)
    func scrollUp(lines: Int)
    func scrollDown(lines: Int)
    /// 0…1 within the scrollback; 1.0 = pinned to the tail (following output).
    var scrollPosition: Double { get }
    var canScroll: Bool { get }
    /// Current sub-row visual translation used by smooth scrolling.
    var visualScrollOffset: CGFloat { get }
    /// Content, whole-row viewport, or focus change.
    var onViewportChanged: (() -> Void)? { get set }
    /// Pixel-only smooth-scroll movement. Overlay geometry can follow this
    /// without repeating block, prompt, ghost, and scrollbar bookkeeping.
    var onVisualScrollChanged: (() -> Void)? { get set }
    /// Selection text changed (mouse gesture, search reveal, or keyboard
    /// adjustment). Contextual UI can refresh without polling the renderer.
    var onSelectionChanged: (() -> Void)? { get set }

    // Selection. Adjustment is intentionally performable: callers can let a
    // key fall through to the child process when no selection exists.
    func selectedText() -> String
    func selectAllContent()
    @discardableResult
    func adjustSelection(_ adjustment: TerminalSelectionAdjustment) -> Bool
    @discardableResult
    func scrollSelectionIntoView() -> Bool

    // Search (FindBar)
    @discardableResult
    func findNext(_ term: String, options: TermSearchOptions) -> Bool
    @discardableResult
    func findPrevious(_ term: String, options: TermSearchOptions) -> Bool
    func searchStatus(_ term: String, options: TermSearchOptions) -> (index: Int, total: Int)
    func clearSearch()

    // Reflow hooks — fire around ANY buffer rewrap (both resize routes:
    // live-resize AND font changes). Block anchors snapshot/restore here.
    var willReflowBuffer: (() -> Void)? { get set }
    var didReflowBuffer: (() -> Void)? { get set }

    // Engine/view → host events.
    var onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)? { get set }
    var onTitleChanged: ((String) -> Void)? { get set }
    /// BEL rang in this surface (already audible; hosts use it for attention).
    var onBell: (() -> Void)? { get set }
    /// OSC 9 / OSC 777 notification from the process: (title, body).
    var onNotification: ((String, String) -> Void)? { get set }
    /// OSC 7 — the raw "file://host/path" URL string (or nil).
    var onCwdChanged: ((String?) -> Void)? { get set }
}

// MARK: - TerminalSession

/// PTY lifecycle for a live pane.
public protocol TerminalSession: AnyObject {
    func startProcess(executable: String, args: [String], environment: [String]?,
                      currentDirectory: String?)
    /// SIGTERM the child — don't orphan the shell.
    func terminate()
    var shellPid: pid_t { get }
    var onProcessTerminated: ((Int32?) -> Void)? { get set }
}

/// What a real pane holds: a surface with a live PTY behind it.
public typealias TerminalPaneHost = TerminalSurface & TerminalSession

/// Anything that can dock an InlinePanel at its bottom edge — the plugin
/// bus opens SDK panels through this without knowing about panes.
public protocol InlinePanelHost: AnyObject {
    @discardableResult
    func presentInlinePanel(takeFocus: Bool) -> InlinePanel
    func dismissInlinePanel(refocus: Bool)
}

/// A terminal pane that can reserve one persistent Extension-owned command
/// row beneath the PTY. This is separate from InlinePanel so normal palettes
/// and Surface Protocol documents can temporarily cover it without destroying
/// the companion's navigation state.
public protocol ExtensionControlBarHost: AnyObject {
    /// Stable pane identity used to route Extension callbacks back to the
    /// exact terminal that owns the control row.
    var extensionControlBarTargetID: String { get }
    @discardableResult
    func presentExtensionControlBar() -> ExtensionControlBar
    func focusExtensionControlBar(_ bar: ExtensionControlBar)
    func dismissExtensionControlBar(_ bar: ExtensionControlBar)
}
