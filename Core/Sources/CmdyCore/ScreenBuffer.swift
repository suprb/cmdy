import Foundation

/// The grid + scrollback for one screen (normal or alternate).
///
/// Coordinates:
///  - ABSOLUTE row: index into `lines` (0 = oldest retained scrollback row).
///  - `yBase`: absolute row where the live screen's top sits.
///  - `yDisp`: absolute row at the top of the viewport (scrolled == < yBase).
///  - cursor `(x, y)` is live-screen-relative; absolute row = yBase + y.
///
/// Trimming: when scrollback exceeds `maxScrollback`, rows drop off the top
/// and `droppedLines` counts them forever (block anchors rebase on it).
public final class ScreenBuffer {
    // Swift Array.removeFirst shifts every retained Line reference. Once the
    // scrollback is full that made each ordinary LF O(maxScrollback). Keep a
    // logical start instead; compact only after a sizeable batch of trims so
    // capped scrolling is amortized O(1) and storage remains bounded. Trimmed
    // slots become one shared empty tombstone so their cell payloads die now,
    // rather than surviving until the next prefix compaction.
    nonisolated(unsafe) private static let trimmedLineTombstone = Line(cols: 0)
    private var lineStorage: [Line] = []
    private var lineStart = 0

    /// Snapshot of the retained rows, oldest first. External coordinates stay
    /// local to the retained buffer (row 0 is always the oldest retained row).
    public var lines: [Line] {
        guard lineStart > 0 else { return lineStorage }
        return Array(lineStorage[lineStart...])
    }
    public private(set) var droppedLines = 0
    public var yBase = 0
    public var yDisp = 0
    public var x = 0
    public var y = 0
    public private(set) var cols: Int
    public private(set) var rows: Int
    public let hasScrollback: Bool
    public var maxScrollback: Int

    /// DECSTBM margins, live-screen-relative, inclusive.
    public var scrollTop = 0
    public var scrollBottom: Int

    /// DECSLRM-style horizontal margins. Faithfully to the reference:
    /// they START AT 0 and only a (soft) reset widens them to the full
    /// row — so a never-reset alt buffer scrolls only at column 0.
    public var marginLeft = 0
    public var marginRight = 0

    /// Saved cursor (DECSC) — position + attribute + charset state.
    public struct SavedCursor {
        public var x = 0
        public var y = 0
        public var attribute = CellAttribute.empty
        public var wrapPending = false
        public var originMode = false
        public var autoWrap = false
        public var marginMode = false
        public var reverseWraparound = false
    }
    public var savedCursor: SavedCursor?

    /// Tab stops, absolute columns.
    public private(set) var tabStops: Set<Int> = []

    /// Deferred wrap: after printing into the last column the cursor stays
    /// put and only wraps when the NEXT printable arrives (xterm semantics).
    public var wrapPending = false

    public init(cols: Int, rows: Int, hasScrollback: Bool, maxScrollback: Int = 10_000) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.hasScrollback = hasScrollback
        self.maxScrollback = hasScrollback ? maxScrollback : 0
        self.scrollBottom = self.rows - 1
        for _ in 0..<self.rows { lineStorage.append(Line(cols: self.cols)) }
        resetTabStops()
    }

    public var lineCount: Int { lineStorage.count - lineStart }

    var canAppendFullScreenScrollbackLine: Bool {
        hasScrollback && scrollTop == 0 && scrollBottom == rows - 1
            && lineCount - rows < maxScrollback
    }

    var canScrollFullScreenIntoScrollback: Bool {
        hasScrollback && scrollTop == 0 && scrollBottom == rows - 1
    }

    func appendFullScreenScrollbackLine(_ line: Line) {
        precondition(canAppendFullScreenScrollbackLine)
        let atBottom = yDisp == yBase
        lineStorage.append(line)
        yBase += 1
        if atBottom { yDisp = yBase }
    }

    func scrollUpPopulatedASCII(_ bytes: ArraySlice<UInt8>, fill: Cell,
                                attribute: CellAttribute, linkId: UInt16) {
        precondition(canScrollFullScreenIntoScrollback && bytes.count <= cols)
        clearOverflowLines()
        let atBottom = yDisp == yBase
        if lineCount - rows >= maxScrollback {
            let recycled = lineStorage[lineStart]
            lineStorage[lineStart] = Self.trimmedLineTombstone
            lineStart += 1
            recycled.resetDeferred(fill: fill)
            recycled.writeASCII(bytes, at: 0, attribute: attribute, linkId: linkId)
            lineStorage.append(recycled)
            droppedLines += 1
            yDisp = max(0, yDisp - 1)
            compactDeferredPrefixIfNeeded()
        } else {
            lineStorage.append(Line(ascii: bytes, cols: cols, fill: fill,
                                    attribute: attribute, linkId: linkId,
                                    isWrapped: false))
            yBase += 1
        }
        if atBottom { yDisp = yBase }
    }

    // Test-only observability for the bounded-prefix performance invariant.
    var backingLineSlotCount: Int { lineStorage.count }
    var deferredTrimmedLineCount: Int { lineStart }

    /// The absolute row of the live screen's row `r`.
    public func absoluteRow(_ r: Int) -> Int { yBase + r }

    public func line(absolute row: Int) -> Line? {
        row >= 0 && row < lineCount ? lineStorage[lineStart + row] : nil
    }

    /// Ghost rows past the retained lines: the reference ring auto-vivifies
    /// a STABLE backing slot when code reads/writes beyond count (margin-
    /// mode IL/DL reach there). Bounded; wiped on any structural change.
    var overflowLines: [Int: Line] = [:]

    func lineAutovivified(absolute row: Int) -> Line? {
        guard row >= 0 else { return nil }
        // The reference ring indexes modulo maxLength, so a row past the
        // ring's CAPACITY lands back on a real row (the alt ring is only
        // rows+1 tall — margin-mode IL/DL there wraps onto the screen).
        // Rows within capacity but past the current fill are ghost rows,
        // autovivified on first touch (the DL smear).
        let capacity = rows + maxScrollback
        let wrapped = row % max(1, capacity)
        if wrapped < lineCount { return lineStorage[lineStart + wrapped] }
        guard wrapped < lineCount + 512 else { return nil }
        if let ghost = overflowLines[wrapped] { return ghost }
        let ghost = Line(cols: cols)
        overflowLines[wrapped] = ghost
        return ghost
    }

    func clearOverflowLines() {
        if !overflowLines.isEmpty { overflowLines.removeAll() }
    }

    public func liveLine(_ r: Int) -> Line {
        let idx = yBase + r
        precondition(idx >= 0 && idx < lineCount, "live row \(r) out of range")
        return lineStorage[lineStart + idx]
    }

    public func resetTabStops() {
        tabStops.removeAll()
        var col = 8
        while col < cols { tabStops.insert(col); col += 8 }
    }

    public func setTabStop(at col: Int) { tabStops.insert(col) }
    public func clearTabStop(at col: Int) { tabStops.remove(col) }
    public func clearAllTabStops() { tabStops.removeAll() }

    /// Reference shape: the limit is the right margin whenever DECLRMM is
    /// on (regardless of where the cursor sits), and the result clamps TO
    /// the limit — a cursor already past it moves BACKWARD to the margin.
    public func nextTabStop(from col: Int, marginMode: Bool = false) -> Int {
        guard cols > 0 else { return 0 }

        let requestedLimit = marginMode ? marginRight : cols - 1
        let upperBound = min(cols - 1, max(0, requestedLimit))
        let firstAdvance = min(upperBound, max(0, col + 1))
        let configured = tabStops.lazy
            .filter { $0 >= firstAdvance && $0 <= upperBound }
            .min()

        return configured ?? upperBound
    }
    public func previousTabStop(from col: Int) -> Int {
        let candidates = tabStops.filter { $0 < col }
        return max(candidates.max() ?? 0, 0)
    }

    /// Scroll the region up by one: the top row leaves the region. When the
    /// region is the full screen and scrollback exists, the row moves into
    /// scrollback (growing `lines`); otherwise it is destroyed.
    public func scrollUp(fill: Cell, markNewWrapped: Bool = false,
                         clearRecycledLine: Bool = true) {
        clearOverflowLines()
        let atBottom = yDisp == yBase
        if scrollTop == 0 && hasScrollback {
            // Top-anchored region: the departing top line becomes scrollback
            // even when the region bottom sits above the last row — insert
            // the fresh line after the region and slide the window down.
            let bottomRow = yBase + scrollBottom
            let atStorageTail = bottomRow >= lineCount - 1
            let scrollbackIsFull = lineCount - rows >= maxScrollback
            if atStorageTail && scrollbackIsFull {
                // The oldest row is leaving retention at the same moment a new
                // tail row is needed. Rotate that Line object and its Cell
                // storage instead of allocating ~cols * Cell.stride bytes.
                let recycled = lineStorage[lineStart]
                lineStorage[lineStart] = Self.trimmedLineTombstone
                lineStart += 1
                if clearRecycledLine {
                    recycled.resetDeferred(fill: fill, isWrapped: markNewWrapped)
                } else {
                    recycled.resetMetadata(isWrapped: markNewWrapped)
                }
                lineStorage.append(recycled)
                droppedLines += 1
                yDisp = max(0, yDisp - 1)
                compactDeferredPrefixIfNeeded()
            } else if atStorageTail {
                let newLine = Line(cols: cols, fill: fill)
                newLine.isWrapped = markNewWrapped
                lineStorage.append(newLine)
                yBase += 1
                trimScrollback()
            } else {
                let newLine = Line(cols: cols, fill: fill)
                newLine.isWrapped = markNewWrapped
                lineStorage.insert(newLine, at: lineStart + bottomRow + 1)
                yBase += 1
                trimScrollback()
            }
        } else {
            // Interior region (or no scrollback): rotate in place.
            let top = yBase + scrollTop
            let bottom = yBase + scrollBottom
            guard top >= 0, bottom < lineCount else { return }
            let recycled = lineStorage.remove(at: lineStart + top)
            if clearRecycledLine {
                recycled.resetDeferred(fill: fill, isWrapped: markNewWrapped)
            } else {
                recycled.resetMetadata(isWrapped: markNewWrapped)
            }
            lineStorage.insert(recycled, at: lineStart + bottom)
        }
        if atBottom { yDisp = yBase }
    }

    /// CSI S (SU): rotate the region up — the departing top row is LOST,
    /// never scrolled back (xterm semantics; LF at the bottom differs).
    public func scrollUpRegionOnly(fill: Cell) {
        let top = yBase + scrollTop
        let bottom = yBase + scrollBottom
        guard top >= 0, bottom < lineCount else { return }
        let recycled = lineStorage.remove(at: lineStart + top)
        recycled.reset(fill: fill)
        lineStorage.insert(recycled, at: lineStart + bottom)
    }

    /// Scroll the region down by one (reverse index at the top).
    public func scrollDown(fill: Cell) {
        let top = yBase + scrollTop
        let bottom = yBase + scrollBottom
        guard top >= 0, bottom < lineCount else { return }
        let recycled = lineStorage.remove(at: lineStart + bottom)
        recycled.reset(fill: fill)
        lineStorage.insert(recycled, at: lineStart + top)
    }

    /// Insert `n` blank lines at live row `r` (IL), within the scroll region.
    public func insertLines(at r: Int, count n: Int, fill: Cell) {
        guard r >= scrollTop, r <= scrollBottom else { return }
        for _ in 0..<n {
            let recycled = lineStorage.remove(at: lineStart + yBase + scrollBottom)
            recycled.reset(fill: fill)
            lineStorage.insert(recycled, at: lineStart + yBase + r)
        }
    }

    /// Delete `n` lines at live row `r` (DL), within the scroll region.
    public func deleteLines(at r: Int, count n: Int, fill: Cell) {
        guard r >= scrollTop, r <= scrollBottom else { return }
        for _ in 0..<n {
            let recycled = lineStorage.remove(at: lineStart + yBase + r)
            recycled.reset(fill: fill)
            lineStorage.insert(recycled, at: lineStart + yBase + scrollBottom)
        }
    }

    private func trimScrollback() {
        let excess = (lineCount - rows) - maxScrollback
        guard excess > 0 else { return }
        removeFirstLines(excess)
        droppedLines += excess
        yBase -= excess
        yDisp = max(0, yDisp - excess)
    }

    private func removeFirstLines(_ count: Int) {
        let removed = min(max(0, count), lineCount)
        guard removed > 0 else { return }
        let newStart = lineStart + removed
        for index in lineStart..<newStart {
            lineStorage[index] = Self.trimmedLineTombstone
        }
        lineStart = newStart

        compactDeferredPrefixIfNeeded()
    }

    private func compactDeferredPrefixIfNeeded() {
        // Compact in batches. At steady-state capacity this copies retained
        // references once per roughly one buffer's worth of output, instead of
        // once per row, while keeping stale prefix storage below ~2x live data.
        if lineStart >= max(64, lineCount) {
            lineStorage = Array(lineStorage[lineStart...])
            lineStart = 0
        }
    }

    /// RIS: everything goes — scrollback, dropped-line count, the lot. The
    /// reference engine rebuilds its buffers from scratch on full reset.
    func hardReset() {
        clearOverflowLines()
        lineStorage = (0..<rows).map { _ in Line(cols: cols) }
        lineStart = 0
        droppedLines = 0
        yBase = 0
        yDisp = 0
        x = 0
        y = 0
        scrollTop = 0
        scrollBottom = rows - 1
        marginLeft = 0
        marginRight = cols - 1
        savedCursor = nil
        wrapPending = false
        resetTabStops()
    }

    // Reflow handoff mutators (storage/cols/rows/droppedLines are not
    // externally mutable, so ordinary code can't desync them).
    func replaceLines(_ newLines: [Line]) {
        lineStorage = newLines
        lineStart = 0
    }
    func setGeometry(cols newCols: Int, rows newRows: Int) {
        cols = newCols
        rows = newRows
    }
    func noteDropped(_ n: Int) { if n > 0 { droppedLines += n } }

    /// Wipe scrollback only (ED 3): live screen stays put.
    public func clearScrollback() {
        guard yBase > 0 else { return }
        droppedLines += yBase
        removeFirstLines(yBase)
        yBase = 0
        yDisp = 0
    }

    /// Resize without reflow (alt screen / rows-only component): grow pads
    /// rows at the bottom, shrink prefers eating blank tail rows before
    /// pushing top rows into scrollback.
    public func resizeSimple(newCols: Int, newRows: Int, fill: Cell) {
        clearOverflowLines()
        let atBottom = yDisp == yBase
        if newCols != cols {
            for index in lineStart..<lineStorage.count {
                lineStorage[index].resize(to: newCols, fill: Cell())
            }
            cols = newCols
        }
        if newRows > rows {
            var needed = newRows - rows
            // Reveal scrollback first (xterm behavior: the screen grows up).
            let reveal = min(needed, yBase)
            yBase -= reveal
            needed -= reveal
            for _ in 0..<needed { lineStorage.append(Line(cols: cols)) }
            y += reveal
        } else if newRows < rows {
            var toRemove = rows - newRows
            // Eat blank rows below the cursor from the bottom first.
            while toRemove > 0, lineCount > yBase + y + 1,
                  lineStorage.last?.usedLength == 0, lineStorage.last?.images == nil {
                lineStorage.removeLast()
                toRemove -= 1
            }
            // Remaining rows scroll into scrollback (cursor moves up).
            if toRemove > 0 {
                yBase += toRemove
                y = max(0, y - toRemove)
                if !hasScrollback {
                    removeFirstLines(min(toRemove, lineCount - newRows))
                    yBase = max(0, lineCount - newRows)
                }
            }
        }
        rows = newRows
        scrollTop = 0
        scrollBottom = rows - 1
        if marginRight > cols - 1 { marginRight = cols - 1 }
        if marginLeft >= marginRight { marginLeft = marginRight }
        x = min(x, cols - 1)
        y = min(y, rows - 1)
        yDisp = atBottom ? yBase : min(yDisp, yBase)
        trimScrollback()
        resetTabStops()
    }
}
