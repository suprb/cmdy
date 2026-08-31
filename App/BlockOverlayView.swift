import AppKit
import CmdyKit

/// An inline autocomplete suggestion: the not-yet-typed suffix, positioned at
/// a screen cell.
struct GhostHint: Equatable {
    let text: String
    let screenRow: Int
    let col: Int
}

/// Passive command help attached to an absolute terminal row. It is drawn by
/// the grid overlay instead of being written into the PTY, so shell readline
/// state and canonical scrollback remain untouched.
struct CommandAssistanceOverlay: Equatable {
    let id: String
    var anchorRow: Int
    var body: String
    var hint: String
}

/// Draws ghost text and block separators over the terminal grid. Failed-row
/// status is rendered by Metal, so this view never consumes a left gutter.
final class BlockOverlayView: NSView {
    weak var surface: (any TerminalSurface)? {
        didSet { invalidateSeparatorGeometry() }
    }
    weak var store: BlockStore? {
        didSet { invalidateSeparatorGeometry() }
    }
    /// Insets of the terminal content within this container-sized overlay.
    var contentTopInset: CGFloat = 0 {
        didSet {
            if contentTopInset != oldValue { invalidateSeparatorGeometry() }
        }
    }

    /// Ghost-text autocomplete: dimmed suffix drawn after the cursor.
    var ghost: GhostHint? {
        didSet { if ghost != oldValue { needsDisplay = true } }
    }
    var commandAssistance: CommandAssistanceOverlay? {
        didSet {
            if commandAssistance != oldValue {
                needsDisplay = true
                surface?.forceRedraw()
            }
        }
    }
    var ghostFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var ghostColor: NSColor = NSColor.gray.withAlphaComponent(0.5)
    /// Block separator, derived from the theme foreground (white was invisible
    /// on light themes).
    var separatorColor: NSColor = NSColor.white.withAlphaComponent(0.06) {
        didSet { updateSeparatorColors() }
    }
    private let rowTextLayout = TerminalRowTextLayout()
    private let separatorContainerLayer = CALayer()
    private var separatorLayers: [CALayer] = []
    private var lastTop = Int.min
    private var lastCount = -1
    private var lastRows = -1
    private var lastCellHeight = CGFloat.greatestFiniteMagnitude
    private var lastContentXOrigin = CGFloat.greatestFiniteMagnitude
    private var lastBoundsSize = CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude)
    private var lastVisualOffset = CGFloat.greatestFiniteMagnitude

    var visibleSeparatorLayerCountForTesting: Int {
        separatorLayers.filter { !$0.isHidden }.count
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layerContentsPlacement = .topLeft
        configureSeparatorContainer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layerContentsPlacement = .topLeft
        configureSeparatorContainer()
    }

    override var isFlipped: Bool { true }   // top-left origin → simpler row math

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateSeparatorGeometry()
        if ghost != nil || commandAssistance != nil { needsDisplay = true }
    }

    /// Keep command separators entirely out of the AppKit backing-store draw
    /// path. Pixel scrolling only translates this cached layer tree; whole-row
    /// motion rebuilds at most the few separators intersecting the viewport.
    /// Ghost text and command assistance still use AppKit because they contain
    /// shaped text, but are normally absent while browsing history.
    func refreshIfNeeded() {
        guard let term = surface?.engine, let store = store else { return }
        let top = term.currentTopRow
        let count = store.blocks.count
        let rows = term.rows
        let cellHeight = surface?.cellSize.height ?? 0
        let contentXOrigin = surface?.contentXOrigin ?? 0
        let visualOffset = surface?.visualScrollOffset ?? 0
        let geometryChanged = top != lastTop
            || count != lastCount
            || rows != lastRows
            || abs(cellHeight - lastCellHeight) > 0.001
            || abs(contentXOrigin - lastContentXOrigin) > 0.001
            || bounds.size != lastBoundsSize
        let visualChanged = abs(visualOffset - lastVisualOffset) > 0.01
        if geometryChanged {
            lastTop = top
            lastCount = count
            lastRows = rows
            lastCellHeight = cellHeight
            lastContentXOrigin = contentXOrigin
            lastBoundsSize = bounds.size
            rebuildSeparatorLayers(
                top: top, rows: rows, cellHeight: cellHeight,
                contentXOrigin: contentXOrigin, blocks: store.blocks)
        }
        if geometryChanged || visualChanged {
            setSeparatorTranslation(visualOffset)
            lastVisualOffset = visualOffset
        }
        if (geometryChanged || visualChanged),
           ghost != nil || commandAssistance != nil {
            needsDisplay = true
        }
    }

    /// Block rows can be remapped without changing their count. Invalidate the
    /// cached geometry explicitly instead of using `needsDisplay`, which would
    /// put the full transparent AppKit overlay back on the scrolling hot path.
    func blockDataChanged() {
        lastCount = -1
        refreshIfNeeded()
        if ghost != nil || commandAssistance != nil { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = surface else { return }
        let term = tv.engine
        let cell = tv.cellSize
        guard cell.height > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: NSRect(x: 0, y: contentTopInset,
                                  width: bounds.width,
                                  height: CGFloat(term.rows) * cell.height)).addClip()

        // The grid is centered between the insets — follow the same origin.
        let originX = tv.contentXOrigin
        let visualOffset = tv.visualScrollOffset

        // Ghost suggestion, cell-aligned right after the cursor.
        if let g = ghost, cell.width > 0 {
            let x = originX + CGFloat(g.col) * cell.width
            let y = contentTopInset + CGFloat(g.screenRow) * cell.height + visualOffset
            let attrs: [NSAttributedString.Key: Any] = [
                .font: ghostFont,
                .foregroundColor: ghostColor,
                .ligature: 0,
                .kern: 0,
            ]
            let textY = rowTextLayout.drawOriginY(
                rowTop: y, baselineFromTop: tv.textBaselineFromRowTop,
                font: ghostFont)
            // AppKit's normal whole-string drawing applies contextual font
            // substitutions to runs such as `..`, `...`, and `....` in some
            // coding fonts. Draw each grapheme at an explicit terminal-column
            // origin so ghost text cannot visually compress or drift away from
            // the cursor grid.
            let offsets = Self.ghostColumnOffsets(
                for: g.text, font: ghostFont, cellWidth: cell.width)
            for (character, offset) in zip(g.text, offsets) {
                (String(character) as NSString).draw(
                    at: NSPoint(x: x + CGFloat(offset) * cell.width, y: textY),
                    withAttributes: attrs)
            }
        }
        let top = term.currentTopRow
        drawCommandAssistance(on: tv, topRow: top, originX: originX,
                              visualOffset: visualOffset)
    }

    private func configureSeparatorContainer() {
        separatorContainerLayer.name = "cmdy command separators"
        separatorContainerLayer.isGeometryFlipped = true
        separatorContainerLayer.actions = [
            "bounds": NSNull(), "position": NSNull(), "transform": NSNull(),
            "sublayers": NSNull(),
        ]
        layer?.addSublayer(separatorContainerLayer)
        invalidateSeparatorGeometry()
    }

    private func invalidateSeparatorGeometry() {
        lastTop = Int.min
        lastCount = -1
        lastRows = -1
        lastCellHeight = .greatestFiniteMagnitude
        lastContentXOrigin = .greatestFiniteMagnitude
        lastBoundsSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        refreshIfNeeded()
    }

    private func rebuildSeparatorLayers(
        top: Int, rows: Int, cellHeight: CGFloat,
        contentXOrigin: CGFloat, blocks: [Block]
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separatorContainerLayer.frame = bounds
        let visible = blocks.filter {
            let screenRow = $0.promptRow - top
            return screenRow >= -1 && screenRow <= rows
        }
        while separatorLayers.count < visible.count {
            let separator = CALayer()
            separator.name = "cmdy command separator"
            separator.actions = [
                "backgroundColor": NSNull(), "bounds": NSNull(),
                "hidden": NSNull(), "position": NSNull(),
            ]
            separatorContainerLayer.addSublayer(separator)
            separatorLayers.append(separator)
        }
        let width = max(0, bounds.width - contentXOrigin * 2)
        for (index, block) in visible.enumerated() {
            let screenRow = block.promptRow - top
            let separator = separatorLayers[index]
            separator.backgroundColor = separatorColor.cgColor
            separator.frame = CGRect(
                x: contentXOrigin,
                y: contentTopInset + CGFloat(screenRow) * cellHeight,
                width: width, height: 1)
            separator.isHidden = false
        }
        for separator in separatorLayers.dropFirst(visible.count) {
            separator.isHidden = true
        }
        CATransaction.commit()
    }

    private func setSeparatorTranslation(_ visualOffset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separatorContainerLayer.setAffineTransform(
            CGAffineTransform(translationX: 0, y: visualOffset))
        CATransaction.commit()
    }

    private func updateSeparatorColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for separator in separatorLayers {
            separator.backgroundColor = separatorColor.cgColor
        }
        CATransaction.commit()
    }

    /// Terminal-cell origins for separately shaped ghost graphemes. Measuring
    /// each isolated grapheme preserves reasonable two-cell placement for CJK
    /// and emoji while preventing contextual punctuation substitutions.
    static func ghostColumnOffsets(for text: String, font: NSFont,
                                   cellWidth: CGFloat) -> [Int] {
        guard cellWidth.isFinite, cellWidth > 0 else { return [] }
        let measureAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .ligature: 0,
            .kern: 0,
        ]
        var column = 0
        return text.map { character in
            defer {
                let advance = (String(character) as NSString)
                    .size(withAttributes: measureAttributes).width
                let width = advance.isFinite
                    ? max(1, Int((advance / cellWidth).rounded())) : 1
                column += width
            }
            return column
        }
    }

    private func drawCommandAssistance(on tv: any TerminalSurface, topRow: Int,
                                       originX: CGFloat, visualOffset: CGFloat) {
        guard let assistance = commandAssistance else { return }
        let term = tv.engine
        let cell = tv.cellSize
        guard cell.width > 0, cell.height > 0, term.rows > 0 else { return }

        let columns = max(12, min(term.cols,
            Int(max(0, bounds.width - originX * 2) / cell.width)))
        var lines = Self.wrappedLines(assistance.body, columns: columns)
        if !assistance.hint.isEmpty {
            lines.append(contentsOf: Self.wrappedLines(assistance.hint, columns: columns))
        }

        // Tiny panes still keep the title, the beginning of the answer, and
        // the keyboard contract visible instead of clipping the action row.
        if lines.count > term.rows {
            let bodyCapacity = max(0, term.rows - (assistance.hint.isEmpty ? 0 : 1))
            lines = Array(lines.prefix(bodyCapacity))
            if !assistance.hint.isEmpty {
                lines.append(Self.truncated(assistance.hint, columns: columns))
            }
        }
        guard !lines.isEmpty else { return }

        let requestedRow = assistance.anchorRow - topRow
        // Scrolling away from the command scrolls its help away too. The one
        // exception is an anchor immediately below the last visible row: keep
        // the overlay visible by raising it just enough to fit.
        guard requestedRow >= 0, requestedRow <= term.rows else { return }
        let startRow = min(requestedRow, max(0, term.rows - lines.count))
        let y = contentTopInset + CGFloat(startRow) * cell.height + visualOffset
        let font = tv.font
        for (index, line) in lines.enumerated() {
            let isHint = !assistance.hint.isEmpty && index == lines.count - 1
            let color = tv.nativeForegroundColor.withAlphaComponent(isHint ? 0.45 : 0.72)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            let textY = rowTextLayout.drawOriginY(
                rowTop: y + CGFloat(index) * cell.height,
                baselineFromTop: tv.textBaselineFromRowTop,
                font: font)
            (line as NSString).draw(at: NSPoint(x: originX, y: textY), withAttributes: attrs)
        }
    }

    static func wrappedLines(_ text: String, columns: Int) -> [String] {
        let width = max(1, columns)
        return text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { raw in
            var remaining = Array(raw)
            guard !remaining.isEmpty else { return [""] }
            var result: [String] = []
            while remaining.count > width {
                let prefix = remaining.prefix(width)
                let whitespace = prefix.indices.last(where: { remaining[$0].isWhitespace })
                let split = whitespace.map { max(1, $0) } ?? width
                result.append(String(remaining.prefix(split))
                    .trimmingCharacters(in: .whitespaces))
                remaining.removeFirst(split)
                while remaining.first?.isWhitespace == true { remaining.removeFirst() }
            }
            result.append(String(remaining))
            return result
        }
    }

    private static func truncated(_ text: String, columns: Int) -> String {
        let chars = Array(text.replacingOccurrences(of: "\n", with: " "))
        guard chars.count > columns else { return String(chars) }
        guard columns > 1 else { return String(chars.prefix(columns)) }
        return String(chars.prefix(columns - 1)) + "…"
    }
}
