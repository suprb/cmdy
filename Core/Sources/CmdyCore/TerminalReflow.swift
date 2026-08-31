import Foundation

// Resize + reflow. Logical (unwrapped) lines are the invariant: a column
// change rewraps every logical line and produces an EXACT old-row → new-row
// map as a byproduct. Blocks remap through that map — no heuristics, no
// cursor-relative reconstruction; the engine simply never loses the
// correspondence. (This is what "blocks native to the buffer" buys.)
extension CmdyTerminal {

    public func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols)
        let newRows = max(1, newRows)
        let oldNormalCols = normalBuffer.cols
        let oldNormalRows = normalBuffer.rows
        let oldNormalX = normalBuffer.x
        synchronizeBlockRowsToScrollback()

        // Alt screen: no scrollback, no reflow — plain xterm resize. The
        // normal buffer still reflows underneath so the primary screen is
        // correct on return.
        if isAlternateBuffer {
            let suspended = suspendKittyDisplayReflowImages(
                in: altBuffer, materializingTransfers: false)
            altBuffer.resizeSimple(newCols: newCols, newRows: newRows, fill: Cell())
            restoreKittyDisplayReflowImages(
                suspended, toSurvivingLinesIn: altBuffer)
        }

        if newCols != normalBuffer.cols {
            delegate?.willReflow(self)
            reflowNormalBuffer(newCols: newCols, newRows: newRows)
            delegate?.didReflow(self)
        } else {
            let suspended = suspendKittyDisplayReflowImages(
                in: normalBuffer, materializingTransfers: false)
            normalBuffer.resizeSimple(newCols: newCols, newRows: newRows, fill: Cell())
            restoreKittyDisplayReflowImages(
                suspended, toSurvivingLinesIn: normalBuffer)
            // A resize whose effective geometry is unchanged is observationally
            // a no-op for a cursor parked one cell past the right edge.  The
            // ordinary simple-resize clamp is still correct when either axis
            // actually changes.
            if newCols == oldNormalCols, newRows == oldNormalRows {
                normalBuffer.x = oldNormalX
            }
        }

        synchronizeBlockRowsToScrollback()
        delegate?.contentChanged(self)
    }

    private func reflowNormalBuffer(newCols: Int, newRows: Int) {
        let buf = normalBuffer
        reactivateKittyDisplayReflowLines(in: buf)
        let suspendedKittyImages = suspendKittyDisplayReflowImages(
            in: buf, materializingTransfers: true)
        let oldLines = buf.lines
        let cursorAbsRow = buf.yBase + buf.y
        let cursorCol = buf.x
        let oldYBase = buf.yBase
        let oldYDisp = buf.yDisp
        let wasAtBottom = buf.yDisp == buf.yBase

        // A print that wraps at the bottom of an active rectangular region can
        // scroll only the stored columns.  Every exposed physical row is a
        // hard logical boundary when a later column resize reflows the full
        // buffer.  Some aligned cases would happen to wrap at the same cell
        // without the marker, but retaining the actual boundary is required
        // if later erasure or row replacement changes that preceding content.
        let detachedActiveMarginRows: Set<Int> = {
            guard buf.rows > 1, newCols != buf.cols, newCols > 1 else {
                return []
            }
            return Set(activeMarginReflowBoundaries.compactMap { boundary in
                return oldLines.firstIndex(where: { $0 === boundary.line })
            })
        }()
        let kittyClaimedRows: Set<Int> = Set(
            kittyDisplayReflowClaims.compactMap { claim in
                oldLines.firstIndex(where: { $0 === claim.line })
            })
        let kittySemanticRows = Set(blocks.blocks.flatMap {
            [$0.promptRow, $0.commandRow]
        })
        var kittyDisplayBoundaryRows: Set<Int> = Set(
            kittyDisplayReflowBoundaries.compactMap { boundary in
                guard let row = oldLines.firstIndex(where: {
                    $0 === boundary.line
                }), oldLines[row].usedLength > 0 ||
                    kittySemanticRows.contains(row) else {
                    return nil
                }
                return row
            })
        kittyDisplayBoundaryRows.formUnion(
            kittyDisplayClippedTopReflowRanks.compactMap { rank in
                oldLines.firstIndex(where: { $0 === rank.line })
            })

        // A line feed consumed while the cursor is parked on a full final row
        // cannot materialize another row on a one-row screen. A fresh OSC 133
        // prompt at that position nevertheless represents the boundary after
        // the completed logical line. Retain that boundary when a narrower
        // width makes it addressable.
        let trailingSemanticBoundaryOldRow: Int? = {
            guard !oldLines.isEmpty,
                  cursorAbsRow == oldLines.count - 1,
                  cursorCol == buf.cols - 1,
                  oldLines[cursorAbsRow].usedLength == buf.cols,
                  lastPrintedScalar == nil,
                  lastWrite.row == cursorAbsRow,
                  lastWrite.x == cursorCol,
                  lastWrite.cols == buf.cols,
                  lastWrite.rows == buf.rows,
                  let prompt = blocks.blocks.last,
                  prompt.promptRow == cursorAbsRow,
                  prompt.commandRow == cursorAbsRow,
                  prompt.inputStart == nil,
                  prompt.endRow == nil,
                  !prompt.running else { return nil }
            return cursorAbsRow
        }()

        // ── 1. Group rows into logical lines; remember each row's home.
        struct LogicalLine {
            var cells: [Cell] = []
            var firstOldRow: Int
            var rowStartOffsets: [Int] = []   // cell offset where each old row began
            var images: [LineImage]? = nil
            var renderMode: LineRenderMode = .single
            var wrapStyle: Line.WrapStyle = .cells
        }
        var logicals: [LogicalLine] = []
        var rowToLogical: [Int] = []          // old abs row → logical index
        rowToLogical.reserveCapacity(oldLines.count)

        for (rowIndex, line) in oldLines.enumerated() {
            if line.isWrapped, !detachedActiveMarginRows.contains(rowIndex),
               !kittyDisplayBoundaryRows.contains(rowIndex),
               !kittyClaimedRows.contains(rowIndex),
               var current = logicals.popLast() {
                current.rowStartOffsets.append(current.cells.count)
                current.cells.append(contentsOf: line.cells.prefix(line.usedLength))
                if let images = line.images {
                    current.images = (current.images ?? []) + images
                }
                if line.wrapStyle == .words { current.wrapStyle = .words }
                logicals.append(current)
            } else {
                var logical = LogicalLine(firstOldRow: rowIndex)
                logical.rowStartOffsets = [0]
                logical.cells = Array(line.cells.prefix(line.usedLength))
                logical.images = line.images
                logical.renderMode = line.renderMode
                logical.wrapStyle = line.wrapStyle
                logicals.append(logical)
            }
            rowToLogical.append(logicals.count - 1)
        }

        // Cursor's cell offset within its logical line. A cursor past the
        // used length still maps (offset may exceed cells.count — fine).
        let cursorLogical = cursorAbsRow < rowToLogical.count ? rowToLogical[cursorAbsRow] : max(0, logicals.count - 1)
        var cursorOffset = cursorCol
        if cursorAbsRow < oldLines.count, cursorLogical < logicals.count {
            let logical = logicals[cursorLogical]
            // How many rows of this logical line sit above the cursor row?
            var rowWithin = 0
            var probe = cursorAbsRow
            while probe > 0, probe - 1 < rowToLogical.count, rowToLogical[probe - 1] == cursorLogical {
                rowWithin += 1
                probe -= 1
            }
            if rowWithin < logical.rowStartOffsets.count {
                cursorOffset = logical.rowStartOffsets[rowWithin] + cursorCol
            }
        }

        // ── 2. Rewrap each logical line at the new width.
        var newLines: [Line] = []
        var logicalStart: [Int] = []          // logical index → first new row
        var logicalRowStarts: [[Int]] = []    // cell offset where each new row begins
        var remappedKittyClaims: [Line] = []

        func mappedOldRowBeforeCurrentLogical(_ oldRow: Int) -> Int? {
            guard rowToLogical.indices.contains(oldRow) else { return nil }
            let logicalIndex = rowToLogical[oldRow]
            guard logicalStart.indices.contains(logicalIndex),
                  logicalRowStarts.indices.contains(logicalIndex) else {
                return nil
            }
            let logical = logicals[logicalIndex]
            let rowWithin = oldRow - logical.firstOldRow
            let offset = rowWithin < logical.rowStartOffsets.count
                ? logical.rowStartOffsets[rowWithin] : 0
            let starts = logicalRowStarts[logicalIndex]
            guard !starts.isEmpty else { return logicalStart[logicalIndex] }
            // An appended empty physical row begins immediately after all of
            // the preceding logical cells.  Mapping that offset onto the last
            // partially filled output row would collapse the empty row's
            // physical rank.  Keep it one row past the generated content;
            // each additional trailing empty source row consumes one more
            // position.
            if rowWithin > 0,
               oldLines[oldRow].usedLength == 0,
               offset == logical.cells.count {
                if logical.cells.isEmpty {
                    return logicalStart[logicalIndex] + rowWithin
                }
                let priorTrailingEmptyRows = logical.rowStartOffsets[1..<rowWithin]
                    .filter { $0 == logical.cells.count }
                    .count
                return logicalStart[logicalIndex] + starts.count + priorTrailingEmptyRows
            }
            var low = 0
            var high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] <= offset { low = mid + 1 } else { high = mid }
            }
            var row = max(0, low - 1)
            let col = max(0, offset - starts[row])
            if col >= newCols { row += col / newCols }
            return logicalStart[logicalIndex] + row
        }

        for (logicalIndex, logical) in logicals.enumerated() {
            let claimedOldRow = kittyClaimedRows.first { oldRow in
                rowToLogical.indices.contains(oldRow) &&
                    rowToLogical[oldRow] == logicalIndex
            }
            if let claimedOldRow, claimedOldRow > 0,
               let predecessor = mappedOldRowBeforeCurrentLogical(
                   claimedOldRow - 1) {
                // The claim preserves one physical predecessor slot, not the
                // old absolute scrollback row. Older wrapped history may
                // legitimately collapse when the width changes; pinning this
                // line to `claimedOldRow` would turn that released space into
                // an extra blank row.
                let claimedStart = predecessor + 1
                while newLines.count < claimedStart {
                    newLines.append(Line(cols: newCols))
                }
            }
            logicalStart.append(newLines.count)
            if logical.cells.isEmpty {
                let line = Line(cols: newCols)
                line.renderMode = logical.renderMode
                line.images = logical.images
                line.wrapStyle = logical.wrapStyle
                newLines.append(line)
                if claimedOldRow != nil { remappedKittyClaims.append(line) }
                logicalRowStarts.append([0])
                continue
            }
            var offset = 0
            var first = true
            var rowStarts: [Int] = []
            while offset < logical.cells.count {
                rowStarts.append(offset)
                // Never split a wide char across rows: back off one cell if
                // the boundary lands on a continuation.
                var end = min(offset + newCols, logical.cells.count)
                if end < logical.cells.count, logical.cells[end].width == 0 {
                    end -= 1
                }
                // Host explanations are prose, not a fixed terminal grid.
                // Keep the separator at the end of this row so the next word
                // always begins flush-left as the window changes width.
                if logical.wrapStyle == .words, end < logical.cells.count {
                    var probe = end - 1
                    while probe > offset {
                        let scalar = logical.cells[probe].scalar
                        if scalar == 0x20 || scalar == 0x09 {
                            end = probe + 1
                            break
                        }
                        probe -= 1
                    }
                }
                if end <= offset { end = min(offset + newCols, logical.cells.count) }
                var cells = Array(logical.cells[offset..<end])
                cells.append(contentsOf: Array(repeating: Cell(), count: newCols - cells.count))
                let line = Line(cells: cells, isWrapped: !first)
                line.renderMode = logical.renderMode
                line.wrapStyle = logical.wrapStyle
                if first { line.images = logical.images }
                newLines.append(line)
                if first, claimedOldRow != nil {
                    remappedKittyClaims.append(line)
                }
                first = false
                offset = end
            }
            logicalRowStarts.append(rowStarts)
        }

        var trailingSemanticBoundaryNewRow: Int?
        if let oldRow = trailingSemanticBoundaryOldRow,
           rowToLogical.indices.contains(oldRow) {
            let logicalIndex = rowToLogical[oldRow]
            let boundary = logicalStart[logicalIndex] + logicalRowStarts[logicalIndex].count
            while newLines.count <= boundary {
                newLines.append(Line(cols: newCols))
            }
            trailingSemanticBoundaryNewRow = boundary
        }

        func newPosition(logicalIndex: Int, offset: Int) -> (row: Int, col: Int) {
            guard logicalRowStarts.indices.contains(logicalIndex) else { return (0, 0) }
            let starts = logicalRowStarts[logicalIndex]
            var low = 0
            var high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] <= offset { low = mid + 1 } else { high = mid }
            }
            var row = max(0, low - 1)
            var col = max(0, offset - starts[row])
            if col >= newCols {
                row += col / newCols
                col %= newCols
            }
            return (row, col)
        }

        // ── 3. The exact old-row → new-row map (blocks remap through it).
        var rowMap: [Int] = []
        rowMap.reserveCapacity(oldLines.count)
        for (oldRow, logicalIndex) in rowToLogical.enumerated() {
            if oldRow == trailingSemanticBoundaryOldRow,
               let boundary = trailingSemanticBoundaryNewRow {
                rowMap.append(boundary)
                continue
            }
            let logical = logicals[logicalIndex]
            let rowWithin = oldRow - logical.firstOldRow
            let offset = rowWithin < logical.rowStartOffsets.count
                ? logical.rowStartOffsets[rowWithin] : 0
            let position = newPosition(logicalIndex: logicalIndex, offset: offset)
            rowMap.append(logicalStart[logicalIndex] + position.row)
        }

        // A completed OSC 133 block can end on the empty departure row just
        // before a Kitty claim materializes as its own wrapped boundary. The
        // ordinary row map intentionally collapses that empty physical row
        // for cells, cursor, prompt, command, and input anchors. `endRow`,
        // however, denotes the boundary after the completed output and keeps
        // the departure's physical rank. Preserve only this exact Kitty
        // transition with the trailing-empty mapper used by claim placement.
        let kittyCompletedEndRowOverrides: [(
            block: TerminalBlock, mappedRow: Int
        )] = blocks.blocks.compactMap { block in
            guard let oldEndRow = block.endRow,
                  oldLines.indices.contains(oldEndRow),
                  oldLines.indices.contains(oldEndRow + 1),
                  rowMap.indices.contains(oldEndRow),
                  rowToLogical.indices.contains(oldEndRow),
                  rowToLogical.indices.contains(oldEndRow + 1),
                  oldLines[oldEndRow].usedLength == 0,
                  oldLines[oldEndRow + 1].isWrapped,
                  kittyDisplayBoundaryRows.contains(oldEndRow + 1),
                  rowToLogical[oldEndRow] != rowToLogical[oldEndRow + 1],
                  let mapped = mappedOldRowBeforeCurrentLogical(oldEndRow),
                  mapped == rowMap[oldEndRow] + 1 else { return nil }
            return (block, mapped)
        }

        // ── 4. Cursor lands where its logical offset lands.
        let cursorPosition = newPosition(logicalIndex: cursorLogical, offset: cursorOffset)
        var newCursorRow = trailingSemanticBoundaryNewRow
            ?? (logicalStart.indices.contains(cursorLogical)
                ? logicalStart[cursorLogical] + cursorPosition.row
                : max(0, newLines.count - 1))
        let newCursorCol = trailingSemanticBoundaryNewRow == nil ? cursorPosition.col : 0

        // ── 5. Preserve the reflowed live-screen and viewport anchors.
        //
        // The buffer always contains enough blank rows to fill the live
        // screen. Deriving yBase from `newLines.count - newRows` turns those
        // padding rows into fake scrollback whenever a wrapped line gains or
        // loses rows. During a live window resize that made sparse content
        // jump vertically between intermediate widths. Map the old screen
        // top through the exact row map instead; only move it when meaningful
        // content or the cursor would otherwise fall outside the new screen.
        while newLines.count < newRows {
            newLines.append(Line(cols: newCols))
        }
        // A pending-wrap cursor (x == cols) at the very bottom can compute one
        // row PAST the last line, which would push newYBase so that
        // yBase + rows > lines.count and trap liveLine on the next byte. Clamp
        // it onto the last real row — the next output re-wraps normally.
        if newCursorRow >= newLines.count {
            newCursorRow = newLines.count - 1
        }

        let mappedLiveTop = rowMap.indices.contains(oldYBase)
            ? rowMap[oldYBase] : max(0, newLines.count - newRows)
        let mappedViewportTop = rowMap.indices.contains(oldYDisp)
            ? rowMap[oldYDisp] : min(oldYDisp, mappedLiveTop)

        let emptyCell = Cell()
        func hasMeaningfulContent(_ line: Line) -> Bool {
            if line.isWrapped || line.renderMode != .single
                || !(line.images?.isEmpty ?? true) { return true }
            return line.cells.contains { $0 != emptyCell }
        }
        let lastMeaningfulRow = max(
            newCursorRow,
            newLines.lastIndex(where: hasMeaningfulContent) ?? newCursorRow)
        let cursorMinimumBase = max(0, newCursorRow - newRows + 1)
        let cursorMaximumBase = max(0, newCursorRow)
        let contentMinimumBase = max(0, lastMeaningfulRow - newRows + 1)
        // In ordinary terminal state the cursor and last meaningful row fit
        // together. If an application deliberately leaves more than a screen
        // of content below its cursor, cursor visibility remains the invariant.
        let minimumBase = contentMinimumBase <= cursorMaximumBase
            ? max(cursorMinimumBase, contentMinimumBase)
            : cursorMinimumBase
        var newYBase = min(max(mappedLiveTop, minimumBase), cursorMaximumBase)

        // Reflowing meaningful rows can consume or release the old blank tail.
        // Normalize only truly empty overflow, preserving styled blanks,
        // images, and wrapped structural rows.
        let requiredLineCount = newYBase + newRows
        while newLines.count > requiredLineCount,
              let last = newLines.last, !hasMeaningfulContent(last) {
            newLines.removeLast()
        }
        while newLines.count < requiredLineCount {
            newLines.append(Line(cols: newCols))
        }
        var newYDisp = wasAtBottom
            ? newYBase : min(max(0, mappedViewportTop), newYBase)

        // ── 6. Trim to scrollback cap (map shifts along).
        var dropped = 0
        let excess = (newLines.count - newRows) - buf.maxScrollback
        if excess > 0 {
            dropped = min(excess, newYBase)
            if dropped > 0 {
                newLines.removeFirst(dropped)
                newYBase -= dropped
                newYDisp = max(0, newYDisp - dropped)
                newCursorRow -= dropped
            }
        }

        buf.replaceContent(lines: newLines,
                           yBase: newYBase,
                           yDisp: wasAtBottom ? newYBase : min(newYDisp, newYBase),
                           x: min(max(0, newCursorCol), newCols - 1),
                           y: min(max(0, newCursorRow - newYBase), newRows - 1),
                           cols: newCols, rows: newRows,
                           additionalDropped: dropped)

        for entry in suspendedKittyImages {
            guard let oldRow = oldLines.firstIndex(where: {
                $0 === entry.line
            }), rowToLogical.indices.contains(oldRow) else { continue }
            let logicalIndex = rowToLogical[oldRow]
            guard logicalStart.indices.contains(logicalIndex) else { continue }
            let targetRow = logicalStart[logicalIndex] - dropped
            guard normalBuffer.lines.indices.contains(targetRow) else { continue }
            let target = normalBuffer.lines[targetRow]
            if target.images?.contains(where: { $0 === entry.image }) != true {
                target.images = (target.images ?? []) + [entry.image]
            }
        }

        let claimsOutsideNormalBuffer = kittyDisplayReflowClaims.filter {
            claim in !oldLines.contains(where: { $0 === claim.line })
        }
        kittyDisplayReflowClaims = claimsOutsideNormalBuffer +
            remappedKittyClaims.compactMap { line in
                normalBuffer.lines.contains(where: { $0 === line })
                    ? KittyDisplayReflowClaim(line: line)
                    : nil
            }
        kittyDisplayReflowBoundaries.removeAll { boundary in
            oldLines.contains(where: { $0 === boundary.line })
        }
        kittyDisplayClippedTopReflowRanks.removeAll { rank in
            oldLines.contains(where: { $0 === rank.line })
        }
        pruneKittyDisplayReflowImages()

        // Blocks ride the exact map; anything mapped below zero is gone.
        let finalDropped = dropped
        // `BlockTracker.remapRows` normally announces synchronously. Hold that
        // one notification until the end-specific physical-rank override is
        // installed so observers never see an intermediate stale `endRow`.
        let blockChangeObserver = blocks.onChange
        blocks.onChange = nil
        blocks.remapRows { old in
            guard old >= 0, old < rowMap.count else { return -1 }
            let mapped = rowMap[old] - finalDropped
            return mapped >= 0 && mapped < newLines.count ? mapped : -1
        }
        for override in kittyCompletedEndRowOverrides where
            blocks.blocks.contains(where: { $0 === override.block }) {
            let mapped = override.mappedRow - finalDropped
            override.block.endRow = mapped >= 0 && mapped < newLines.count
                ? mapped : -1
        }
        blocks.onChange = blockChangeObserver
        blockChangeObserver?()
        // Reflow has materialized the logical boundary in the newly built
        // line topology.  The old row object is no longer part of the buffer.
        activeMarginReflowBoundaries.removeAll(keepingCapacity: true)
        blocksDroppedLineCheckpoint = normalBuffer.droppedLines
    }
}

extension ScreenBuffer {
    /// Reflow handoff: swap in the rewrapped world atomically.
    func replaceContent(lines newLines: [Line], yBase newYBase: Int, yDisp newYDisp: Int,
                        x newX: Int, y newY: Int, cols newCols: Int, rows newRows: Int,
                        additionalDropped: Int) {
        replaceLines(newLines)
        yBase = newYBase
        yDisp = newYDisp
        x = newX
        y = newY
        setGeometry(cols: newCols, rows: newRows)
        scrollTop = 0
        scrollBottom = newRows - 1
        wrapPending = false
        noteDropped(additionalDropped)
        resetTabStops()
    }
}
