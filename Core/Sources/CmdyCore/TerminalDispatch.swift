import Foundation

// CSI / ESC dispatch — the command set a modern xterm-compatible needs.
// Anything exotic lands in the differential harness as a divergence first
// and gets implemented second; nothing fails silently on main paths.
extension CmdyTerminal {

    func param(_ params: [Int], _ index: Int, default def: Int = 0) -> Int {
        guard index < params.count else { return def }
        let v = params[index]
        return v == 0 ? def : v
    }

    // MARK: - CSI

    func dispatchCSI(final: UInt8, params rawParams: [Int], collect: [UInt8]) {
        // Colon-separated SGR params keep their sentinel; strip it for
        // everything except SGR.
        let isPrivate = collect.first == UInt8(ascii: "?")
        let params = final == UInt8(ascii: "m")
            ? rawParams
            : rawParams.filter { $0 != VTParser.colonSeparator }
        let buf = buffer

        switch (final, isPrivate) {
        case (UInt8(ascii: "@"), _):    // ICH — insert blank chars. The raw
            // (possibly pending-wrap) x goes in; insertCells wraps it modulo
            // the margin width, faithfully to the reference.
            if marginMode && (buf.x < buf.marginLeft || buf.x > buf.marginRight) { break }
            let rightMargin = marginMode ? buf.marginRight : buf.cols - 1
            let insertionColumn = buf.x % (rightMargin + 1)
            preservingClusterOwnerCoordinateThroughCellEdit(
                rows: buf.y...buf.y,
                columns: insertionColumn...rightMargin,
                refreshSelectorMotion: true,
                preserveBackwardAttachmentCoordinateOnInvalidation: true
            ) {
                buf.liveLine(buf.y).insertCells(
                    at: buf.x,
                    count: param(params, 0, default: 1),
                    rightMargin: rightMargin,
                    fill: Cell.blank(attribute: eraseAttribute))
            }
        case (UInt8(ascii: "A"), _):    // CUU
            let oldY = buf.y
            let oldAbsoluteRow = buf.yBase + buf.y
            let wasPending = buf.wrapPending
            let wasNoWrapParked = noWrapParkedAfterPrint
            let top = buf.y >= buf.scrollTop ? buf.scrollTop : 0
            buf.y = max(buf.y - param(params, 0, default: 1), top)
            if (wasPending || wasNoWrapParked), buf.y < oldY {
                pendingCursorUpMoved = true
            }
            recordSelectorOwnerVerticalMotion(from: oldAbsoluteRow)
        case (UInt8(ascii: "B"), _):    // CUD
            let oldAbsoluteRow = buf.yBase + buf.y
            let bottom = buf.y <= buf.scrollBottom
                ? buf.scrollBottom
                : buf.rows - 1
            buf.y = min(
                buf.y + param(params, 0, default: 1),
                bottom)
            if buf.x >= buf.cols { buf.x -= 1 }   // pending wrap dies on CUD
            buf.wrapPending = false
            recordSelectorOwnerVerticalMotion(from: oldAbsoluteRow)
        case (UInt8(ascii: "C"), _):    // CUF
            let oldX = buf.x
            var right = marginMode ? buf.marginRight : buf.cols - 1
            if buf.x > right { right = buf.cols - 1 }
            buf.x = min(buf.x + param(params, 0, default: 1), right)
            buf.wrapPending = false
            recordSelectorOwnerRelativeForwardMotion(from: oldX)
        case (UInt8(ascii: "D"), _):    // CUB
            let oldX = buf.x
            let oldY = buf.y
            noWrapParkedAfterPrint = false
            var left = marginMode ? buf.marginLeft : 0
            if buf.x < left { left = 0 }
            buf.x = max(buf.x - param(params, 0, default: 1), left)
            buf.wrapPending = false
            recordSelectorOwnerRelativeBackwardMotion(from: oldX, oldY: oldY)
        case (UInt8(ascii: "E"), _):    // CNL = CUD + left margin
            buf.y = min(
                buf.y + param(params, 0, default: 1),
                buf.rows - 1)
            if buf.x >= buf.cols { buf.x -= 1 }
            buf.x = buf.marginLeft
            buf.wrapPending = false
        case (UInt8(ascii: "F"), _):    // CPL = CUU + left margin
            buf.y = max(buf.y - param(params, 0, default: 1), 0)
            buf.x = buf.marginLeft
            buf.wrapPending = false
        case (UInt8(ascii: "G"), _):    // CHA
            let oldX = buf.x
            let oldY = buf.y
            buf.x = min(max(param(params, 0, default: 1) - 1, 0), buf.cols - 1)
            recordSelectorOwnerAbsoluteMotion(from: oldX, oldY: oldY)
        case (UInt8(ascii: "H"), _):    // CUP — origin-region confined
            setCursorPosition(row: param(params, 0, default: 1) - 1,
                              col: param(params, 1, default: 1) - 1)
        case (UInt8(ascii: "f"), _):    // HVP — origin OFFSET only; clamps
            // to the screen, NOT the region (reference asymmetry with CUP)
            buf.y = param(params, 0, default: 1) - 1 + (originMode ? buf.scrollTop : 0)
            if buf.y >= buf.rows { buf.y = buf.rows - 1 }
            buf.x = param(params, 1, default: 1) - 1 + (usingMargins ? buf.marginLeft : 0)
            if buf.x >= buf.cols { buf.x = buf.cols - 1 }
        case (UInt8(ascii: "I"), _):    // CHT — forward tabs
            let oldX = buf.x
            for _ in 0..<min(buf.cols - 1, param(params, 0, default: 1)) {
                buf.x = buf.nextTabStop(from: buf.x, marginMode: marginMode)
                // A real tab traversal normalizes pending wrap even when the
                // cursor clamps back onto the same visible right-edge cell.
                // A one-column screen performs no traversal and retains it.
                buf.wrapPending = false
            }
            recordSelectorOwnerRelativeForwardMotion(from: oldX)
        case (UInt8(ascii: "J"), false):
            eraseInDisplay(mode: params.first ?? 0)
        case (UInt8(ascii: "J"), true): // DECSED — treat as ED
            eraseInDisplay(mode: params.first ?? 0)
        case (UInt8(ascii: "K"), false):
            eraseInLine(mode: params.first ?? 0)
        case (UInt8(ascii: "K"), true): // DECSEL — treat as EL
            eraseInLine(mode: params.first ?? 0)
        case (UInt8(ascii: "L"), _):    // IL
            guard buf.y >= buf.scrollTop, buf.y <= buf.scrollBottom else { break }
            if marginMode,
               buf.wrapPending || buf.x < buf.marginLeft || buf.x > buf.marginRight {
                break
            }
            let ilCount = min(buf.rows * 2, param(params, 0, default: 1))
            let replacedColumns = marginMode
                ? buf.marginLeft...buf.marginRight
                : 0...(buf.cols - 1)
            let affectedBottom = marginMode
                ? min(
                    buf.rows - 1,
                    buf.y + (buf.scrollBottom - buf.scrollTop + 1) - 1)
                : buf.scrollBottom
            preservingClusterOwnerCoordinateThroughCellEdit(
                rows: buf.y...affectedBottom,
                columns: replacedColumns,
                preserveLineRotationOwnerOnInvalidation: true
            ) {
                if marginMode {
                    marginModeShift(insert: true, at: buf.y, count: ilCount)
                } else {
                    let previousBottom = buf.liveLine(buf.scrollBottom)
                    buf.insertLines(at: buf.y, count: ilCount,
                                    fill: Cell.blank(attribute: eraseAttribute))
                    rebindMarginDeleteGenerationWitnesses(
                        afterRotating: previousBottom)
                }
            }
        case (UInt8(ascii: "M"), _):    // DL — clamps the cursor first
            if marginMode {
                // Pending and DECAWM-off prints can leave x one cell beyond
                // the physical screen.  That position still denotes the
                // physical last column for DL eligibility.  Every other
                // cursor outside the active horizontal region makes DL a
                // complete no-op.
                let effectiveX = min(buf.x, buf.cols - 1)
                if effectiveX < buf.marginLeft || effectiveX > buf.marginRight {
                    if buf.x >= buf.cols {
                        buf.x = buf.cols - 1
                    }
                    if originMode {
                        buf.y = Self.clamped(
                            buf.y, to: buf.scrollTop...buf.scrollBottom)
                    }
                    break
                }
            }
            restrictCursor()
            let dlCount = min(buf.rows + 1, param(params, 0, default: 1))
            let previousBottom = buf.liveLine(buf.scrollBottom)
            if !marginMode,
               (buf.y < buf.scrollTop || buf.y > buf.scrollBottom) {
                break
            }
            let replacedColumns = marginMode
                ? buf.marginLeft...buf.marginRight
                : 0...(buf.cols - 1)
            let affectedBottom = marginMode
                ? min(
                    buf.rows - 1,
                    buf.y + (buf.scrollBottom - buf.scrollTop + 1) - 1)
                : buf.scrollBottom
            preservingClusterOwnerCoordinateThroughCellEdit(
                rows: buf.y...affectedBottom,
                columns: replacedColumns,
                preserveBackwardAttachmentCoordinateOnInvalidation: true
            ) {
                if marginMode {
                    // NOTE: the margin branch has NO region guard (reference
                    // asymmetry with IL, kept faithfully).
                    marginModeShift(insert: false, at: buf.y, count: dlCount)
                } else {
                    buf.deleteLines(
                        at: buf.y, count: dlCount,
                        fill: Cell.blank(attribute: eraseAttribute))
                }
            }
            if !marginMode {
                rebindMarginDeleteGenerationWitnesses(
                    afterRotating: previousBottom)
            }
            // IL leaves its prior owner dormant at a fixed coordinate. DL is
            // an upward row rotation just like SU/IND: if it brings a real
            // lead back to that coordinate, that lead becomes authoritative
            // for a following combining mark or joiner.
            refreshInsertLineOwnerAfterUpwardLineRotation()
            retireKittyDisplayReflowClaimDisplacedFromBottom(
                previousBottom, in: buf)
        case (UInt8(ascii: "P"), _):    // DCH
            if marginMode && (buf.x < buf.marginLeft || buf.x > buf.marginRight) { break }
            let rightMargin = marginMode ? buf.marginRight : buf.cols - 1
            if buf.x > rightMargin { break }
            preservingClusterOwnerCoordinateThroughCellEdit(
                rows: buf.y...buf.y,
                columns: buf.x...rightMargin,
                preserveBackwardAttachmentCoordinateOnInvalidation: true
            ) {
                buf.liveLine(buf.y).deleteCells(
                    at: buf.x,
                    count: param(params, 0, default: 1),
                    rightMargin: rightMargin,
                    fill: Cell.blank(attribute: eraseAttribute))
            }
        case (UInt8(ascii: "S"), _):        // SU — scrolls regardless of a
            // private marker (reference dispatch never checks); fills with
            // the DEFAULT attr, not the erase attr
            let suCount = min(buf.rows * 2, param(params, 0, default: 1))
            if marginMode {
                for _ in 0..<suCount { marginModeScroll(up: true) }
            } else {
                let previousBottom = buf.liveLine(buf.scrollBottom)
                for _ in 0..<suCount {
                    buf.scrollUpRegionOnly(fill: Cell.blank(attribute: .bufferDefault))
                }
                rebindMarginDeleteGenerationWitnesses(
                    afterRotating: previousBottom)
            }
            refreshInsertLineOwnerAfterUpwardLineRotation()
        case (UInt8(ascii: "T"), false):    // SD — plain collect only; ALWAYS
            // margin-column-scoped (reference cmdScrollDown never checks
            // marginMode — in a never-reset alt buffer that means col 0 only)
            if collect.isEmpty {
                let sdCount = min(buf.rows, param(params, 0, default: 1))
                for _ in 0..<sdCount { marginModeScroll(up: false) }
            }
        case (UInt8(ascii: "T"), true):     // ?T — title-mode reset, inert
            break
        case (UInt8(ascii: "X"), _):    // ECH — erase chars
            let n = param(params, 0, default: 1)
            buf.liveLine(buf.y).fill(with: Cell.blank(attribute: eraseAttribute),
                                     from: buf.x, to: min(buf.x + n, buf.cols))
        case (UInt8(ascii: "Z"), _):    // CBT — backward tabs
            let oldX = buf.x
            let oldY = buf.y
            for _ in 0..<param(params, 0, default: 1) { buf.x = buf.previousTabStop(from: buf.x) }
            buf.wrapPending = false
            recordSelectorOwnerRelativeBackwardMotion(from: oldX, oldY: oldY)
        case (UInt8(ascii: "a"), _):    // HPR
            buf.x = min(buf.x + param(params, 0, default: 1), buf.cols - 1)
        case (UInt8(ascii: "b"), _):    // REP — repeat the cell left of the cursor
            repeatPrecedingCharacter(param(params, 0, default: 1))
        case (UInt8(ascii: "c"), _):    // DA1 / DA2
            if collect.first == UInt8(ascii: ">") {
                sendResponse("\u{1b}[>0;10;1c")          // VT100-family, xterm-ish
            } else if params.first ?? 0 == 0 {
                sendResponse("\u{1b}[?62;1;6;9;22c")     // VT220 w/ color
            }
        case (UInt8(ascii: "d"), _):    // VPA — origin/region-BLIND
            let oldAbsoluteRow = buf.yBase + buf.y
            buf.y = min(max(param(params, 0, default: 1) - 1, 0), buf.rows - 1)
            recordSelectorOwnerVerticalMotion(from: oldAbsoluteRow)
        case (UInt8(ascii: "e"), _):    // VPR — region-blind, plain clamp
            buf.y = min(buf.y + param(params, 0, default: 1), buf.rows - 1)
            if buf.x >= buf.cols { buf.x -= 1 }
        case (UInt8(ascii: "g"), _):    // TBC
            switch params.first ?? 0 {
            case 0: buf.clearTabStop(at: buf.x)
            case 3: buf.clearAllTabStops()
            default: break
            }
        case (UInt8(ascii: "h"), _):
            setModes(params, collect: collect, value: true)
        case (UInt8(ascii: "l"), _):
            setModes(params, collect: collect, value: false)
        case (UInt8(ascii: "m"), _):
            if collect.isEmpty {
                applySGR(rawParams)
            }
            // ">m" (XTMODKEYS) / "?m" — ignored
        case (UInt8(ascii: "n"), false):    // DSR
            switch params.first ?? 0 {
            case 5: sendResponse("\u{1b}[0n")
            case 6:
                let row = originMode ? buf.y - buf.scrollTop + 1 : buf.y + 1
                sendResponse("\u{1b}[\(row);\(buf.x + 1)R")
            default: break
            }
        case (UInt8(ascii: "n"), true):     // DECDSR ?6n
            if params.first == 6 {
                sendResponse("\u{1b}[?\(buf.y + 1);\(buf.x + 1)R")
            }
        case (UInt8(ascii: "p"), _):
            if collect.last == UInt8(ascii: "$") {       // DECRQM
                reportMode(params.first ?? 0, isPrivate: isPrivate)
            } else if collect.first == UInt8(ascii: "!") {  // DECSTR soft reset
                softReset()
            }
        case (UInt8(ascii: "q"), _):
            if collect.last == UInt8(ascii: " ") {       // DECSCUSR
                setCursorStyleParam(params.first ?? 0)
            }
        case (UInt8(ascii: "r"), false):    // DECSTBM
            if collect.isEmpty {
                let top = params.count > 0 ? max(params[0] - 1, 0) : 0
                var bottom = buf.rows
                if params.count > 1, params[1] != 0 {
                    bottom = min(params[1], buf.rows)
                }
                bottom -= 1
                if top < bottom {
                    buf.scrollBottom = bottom
                    buf.scrollTop = top
                }
                // The home happens even when the region was rejected.
                setCursorPosition(row: 0, col: 0)
            }
        case (UInt8(ascii: "r"), true):     // CSI ? Ps r — the reference's
            // DECSTBM handler bails on any collect: a total no-op (there is
            // no XTRESTORE).
            break
        case (UInt8(ascii: "s"), false):    // DECSLRM in margin mode,
            // ANSI save cursor otherwise
            if collect.isEmpty {
                if marginMode {
                    let requestedLeft = params.first.map { $0 == 0 ? 1 : $0 } ?? 1
                    let requestedRight = params.dropFirst().first
                        .map { $0 == 0 ? 1 : $0 } ?? buf.cols
                    let first = min(buf.cols, max(1, requestedLeft)) - 1
                    let second = min(buf.cols, max(1, requestedRight)) - 1
                    // The two endpoints are not sorted.  A reversed request
                    // collapses onto its requested right endpoint, leaving a
                    // one-column region whose wrap boundary remains active
                    // across later cursor addressing.  Only an omitted right
                    // endpoint defaults to the physical edge; an explicit
                    // zero denotes column one.
                    buf.marginLeft = min(first, second)
                    buf.marginRight = second
                } else {
                    saveCursor()
                }
            }
        case (UInt8(ascii: "s"), true):     // CSI ? Ps s — same: the save-
            // cursor handler guards on collect, so no XTSAVE either.
            break
        case (UInt8(ascii: "t"), _):        // XTWINOPS
            windowOps(params)
        case (UInt8(ascii: "u"), false):
            if collect.isEmpty { restoreCursor() }       // ANSI restore
            else { kittyKeyboardCSIu(final: final, params: params, collect: collect) }
        case (UInt8(ascii: "u"), true):     // kitty ?u query
            kittyKeyboardCSIu(final: final, params: params, collect: collect)
        default:
            if collect.first == UInt8(ascii: ">") || collect.first == UInt8(ascii: "=") {
                kittyKeyboardCSIu(final: final, params: params, collect: collect)
            }
        }
    }

    private struct TerminalRegion {
        let rows: ClosedRange<Int>
        let columns: ClosedRange<Int>
    }

    private enum VerticalSliceShift {
        case towardTop
        case towardBottom
    }

    func setCursorPosition(row: Int, col: Int) {
        let buf = buffer
        let oldX = buf.x
        let oldY = buf.y
        let rowBounds = originMode
            ? buf.scrollTop...buf.scrollBottom
            : 0...(buf.rows - 1)
        // Origin mode offsets CUP from the active left margin, but the
        // horizontal region is not its upper addressability boundary.
        // Requests that resolve beyond a clipped right margin can still land
        // in the physical suffix; only the physical screen edge clamps them.
        let columnBounds = originMode && marginMode
            ? buf.marginLeft...(buf.cols - 1)
            : 0...(buf.cols - 1)

        let translatedRow = row + (originMode ? buf.scrollTop : 0)
        let translatedColumn = col + (originMode && marginMode ? buf.marginLeft : 0)
        buf.y = Self.clamped(translatedRow, to: rowBounds)
        buf.x = Self.clamped(translatedColumn, to: columnBounds)
        buf.wrapPending = false
        noWrapParkedAfterPrint = false
        pendingCursorUpMoved = false
        recordSelectorOwnerAbsoluteMotion(from: oldX, oldY: oldY)
    }

    private func columnIndex(back: Bool) {
        let buf = buffer
        let oldX = buf.x
        let oldY = buf.y
        var preserveSelectorWitnessOnInertExteriorMove = false
        defer {
            if back {
                recordSelectorOwnerRelativeBackwardMotion(
                    from: oldX, oldY: oldY)
            } else if !preserveSelectorWitnessOnInertExteriorMove {
                recordSelectorOwnerRelativeForwardMotion(from: oldX)
            }
        }
        if marginMode,
           !(buf.marginLeft...buf.marginRight).contains(buf.x) {
            let consumedPendingAtPhysicalOnePast =
                !back && buf.wrapPending && buf.x >= buf.cols
            if back, buf.x > 0 {
                buf.x -= 1
            } else if !back, buf.x < buf.cols - 1 {
                buf.x += 1
            }
            preserveSelectorWitnessOnInertExteriorMove = !back && buf.x == oldX
            buf.wrapPending = false
            if consumedPendingAtPhysicalOnePast {
                noWrapParkedAfterPrint = true
            }
            return
        }
        // DECBI always keeps using stored bounds after DECLRMM is disabled.
        // DECFI does so only while sitting on an internal stored-right edge;
        // all other mode-off cursor relations remain physical.
        let useStoredColumns = back || (!marginMode && buf.x >= buf.marginRight)
        guard let region = activeRegion(useStoredColumns: useStoredColumns) else { return }
        let boundary = back ? region.columns.lowerBound : region.columns.upperBound

        if !back, buf.x > region.columns.upperBound {
            if buf.x < buf.cols - 1 {
                buf.x += 1
                buf.wrapPending = false
            }
            return
        }
        if back, buf.x < region.columns.lowerBound {
            if !marginMode, buf.x > 0 {
                buf.x -= 1
                buf.wrapPending = false
            }
            return
        }

        if buf.x == boundary {
            guard region.rows.contains(buf.y) else { return }
            if !back, boundary > 0,
               !marginMode, !useStoredColumns {
                let line = buf.liveLine(buf.y)
                if line[boundary].width == 0, line[boundary - 1].width == 2 {
                    return
                }
            }
            if !back,
               lastPrintedScalar != nil,
               lastWrite.rows == buf.rows,
               lastWrite.cols == buf.cols,
               lastWrite.row == buf.yBase + buf.y,
               lastWrite.x < region.columns.lowerBound {
                // The boundary shift cannot touch an owner to the left of
                // its slice. Preserve any earlier real-movement witness.
                preserveSelectorWitnessOnInertExteriorMove = true
            }
            let forwardTail = back ? nil : buf.liveLine(buf.y)[buf.cols - 1]
            if back {
                let shiftedColumns = region.columns.lowerBound...(buf.cols - 1)
                trackingClusterOwnerThroughBackwardColumnShift(
                    rows: region.rows,
                    columns: shiftedColumns
                ) {
                    columnScroll(
                        back: true, at: boundary,
                        useStoredColumns: useStoredColumns)
                }
            } else {
                let shiftedColumns = region.columns.lowerBound...(buf.cols - 1)
                let ownerCoordinateHandled =
                    preservingClusterOwnerCoordinateThroughCellEdit(
                        rows: region.rows,
                        columns: shiftedColumns,
                        refreshSelectorMotion: true,
                        preserveBackwardAttachmentCoordinateOnInvalidation:
                            true,
                        refreshLineRotationOwnerAtSavedCoordinate: true
                    ) {
                        columnScroll(
                            back: false, at: boundary,
                            useStoredColumns: useStoredColumns)
                    }
                if ownerCoordinateHandled {
                    // The edit helper has recomputed selector motion against
                    // the post-shift owner.  DECFI itself leaves the cursor
                    // stationary, so do not replace that logical offset with
                    // the generic no-movement result in the defer above.
                    preserveSelectorWitnessOnInertExteriorMove = true
                }
                if let forwardTail, !ownerCoordinateHandled {
                    retainForwardColumnShiftTail(
                        forwardTail,
                        sourceColumn: buf.cols - 1,
                        destinationColumn: buf.cols - 2,
                        row: buf.y,
                        minimumColumn: region.columns.lowerBound)
                }
            }
        } else {
            let step = back ? -1 : 1
            let movementBounds = back && buf.x > region.columns.upperBound
                ? 0...(buf.cols - 1)
                : region.columns
            buf.x = Self.clamped(buf.x + step, to: movementBounds)
        }
        buf.wrapPending = false
    }

    private func columnScroll(
        back: Bool,
        at _: Int,
        useStoredColumns: Bool
    ) {
        guard let region = activeRegion(useStoredColumns: useStoredColumns) else { return }
        let fill = back
            ? Cell(scalar: UnicodeScalar(" ").value, attribute: Self.stubAttribute)
            : Cell.blank(attribute: eraseAttribute)
        let shiftedColumns = region.columns.lowerBound...(buffer.cols - 1)
        for row in region.rows {
            let line = buffer.liveLine(row)
            if back {
                line.insertCells(at: shiftedColumns.lowerBound, count: 1,
                                 rightMargin: shiftedColumns.upperBound, fill: fill)
            } else {
                line.deleteCells(at: shiftedColumns.lowerBound, count: 1,
                                 rightMargin: shiftedColumns.upperBound, fill: fill)
            }
        }
        let dirtyRows = (buffer.yBase + region.rows.lowerBound)...(buffer.yBase + region.rows.upperBound)
        markDirty(absoluteRows: dirtyRows)
    }

    private static func applyingMarginDelete(
        to original: [MarginDeleteVirtualCell: CellAttribute],
        cursorRow: Int,
        columns: ClosedRange<Int>,
        count: Int,
        verticalRegionHeight: Int,
        eraseAttribute: CellAttribute
    ) -> [MarginDeleteVirtualCell: CellAttribute] {
        guard count > 0, verticalRegionHeight > 0 else { return original }
        let shift = min(count, verticalRegionHeight)
        var result = original

        for column in columns {
            for offset in 0..<(verticalRegionHeight - shift) {
                let destination = MarginDeleteVirtualCell(
                    row: cursorRow + offset,
                    column: column)
                let source = MarginDeleteVirtualCell(
                    row: cursorRow + offset + shift,
                    column: column)
                if let attribute = original[source] {
                    result[destination] = attribute
                } else {
                    result.removeValue(forKey: destination)
                }
            }
            for offset in (verticalRegionHeight - shift)..<verticalRegionHeight {
                let destination = MarginDeleteVirtualCell(
                    row: cursorRow + offset,
                    column: column)
                result[destination] = eraseAttribute
            }
        }
        return result
    }

    private static func applyingMarginInsert(
        to original: [MarginDeleteVirtualCell: CellAttribute],
        cursorRow: Int,
        columns: ClosedRange<Int>,
        count: Int,
        verticalRegionHeight: Int,
        eraseAttribute: CellAttribute
    ) -> [MarginDeleteVirtualCell: CellAttribute] {
        guard count > 0, verticalRegionHeight > 0 else { return original }
        let shift = min(count, verticalRegionHeight)
        var result = original

        for column in columns {
            for offset in shift..<verticalRegionHeight {
                let destination = MarginDeleteVirtualCell(
                    row: cursorRow + offset,
                    column: column)
                let source = MarginDeleteVirtualCell(
                    row: cursorRow + offset - shift,
                    column: column)
                if let attribute = original[source] {
                    result[destination] = attribute
                } else {
                    result.removeValue(forKey: destination)
                }
            }
            for offset in 0..<shift {
                let destination = MarginDeleteVirtualCell(
                    row: cursorRow + offset,
                    column: column)
                result[destination] = eraseAttribute
            }
        }
        return result
    }

    private static func applyingMarginDeleteContent(
        to original: [MarginDeleteVirtualCell: Cell],
        cursorRow: Int,
        columns: ClosedRange<Int>,
        count: Int,
        verticalRegionHeight: Int
    ) -> [MarginDeleteVirtualCell: Cell] {
        guard count > 0, verticalRegionHeight > 0 else { return original }
        let shift = min(count, verticalRegionHeight)
        var result = original

        for column in columns {
            for offset in 0..<(verticalRegionHeight - shift) {
                let destination = MarginDeleteVirtualCell(
                    row: cursorRow + offset,
                    column: column)
                let source = MarginDeleteVirtualCell(
                    row: cursorRow + offset + shift,
                    column: column)
                if let cell = original[source] {
                    result[destination] = cell
                } else {
                    result.removeValue(forKey: destination)
                }
            }
            for offset in (verticalRegionHeight - shift)..<verticalRegionHeight {
                result.removeValue(forKey: MarginDeleteVirtualCell(
                    row: cursorRow + offset,
                    column: column))
            }
        }
        return result
    }

    private static func applyingMarginInsertContent(
        to original: [MarginDeleteVirtualCell: Cell],
        cursorRow: Int,
        columns: ClosedRange<Int>,
        count: Int,
        verticalRegionHeight: Int
    ) -> [MarginDeleteVirtualCell: Cell] {
        guard count > 0, verticalRegionHeight > 0 else { return original }
        let shift = min(count, verticalRegionHeight)
        var result = original

        for column in columns {
            for offset in shift..<verticalRegionHeight {
                let destination = MarginDeleteVirtualCell(
                    row: cursorRow + offset,
                    column: column)
                let source = MarginDeleteVirtualCell(
                    row: cursorRow + offset - shift,
                    column: column)
                if let cell = original[source] {
                    result[destination] = cell
                } else {
                    result.removeValue(forKey: destination)
                }
            }
            for offset in 0..<shift {
                result.removeValue(forKey: MarginDeleteVirtualCell(
                    row: cursorRow + offset,
                    column: column))
            }
        }
        return result
    }

    private func repaintBlankCells(
        rows: ClosedRange<Int>,
        columns: ClosedRange<Int>,
        attribute: CellAttribute
    ) {
        var changedRows: ClosedRange<Int>?
        for row in rows {
            let line = buffer.liveLine(row)
            var changed = false
            for column in columns {
                let cell = line[column]
                if cell.scalar == 0,
                   cell.clusterExtras == nil,
                   cell.width == 1,
                   cell.linkId == 0 {
                    line[column] = Cell.blank(attribute: attribute)
                    changed = true
                }
            }
            if changed {
                changedRows = changedRows.map {
                    min($0.lowerBound, row)...max($0.upperBound, row)
                } ?? row...row
            }
        }
        if let changedRows {
            let absoluteRows = (buffer.yBase + changedRows.lowerBound)...(buffer.yBase + changedRows.upperBound)
            markDirty(absoluteRows: absoluteRows)
        }
    }

    private func capturingMarginDeleteBlankCells(
        in virtualCells: [MarginDeleteVirtualCell: CellAttribute],
        columns: ClosedRange<Int>
    ) -> [MarginDeleteVirtualCell: CellAttribute] {
        var result = virtualCells
        for row in 0..<buffer.rows {
            let line = buffer.liveLine(row)
            for column in columns {
                let position = MarginDeleteVirtualCell(row: row, column: column)
                let cell = line[column]
                if cell.scalar == 0,
                   cell.clusterExtras == nil,
                   cell.width == 1,
                   cell.linkId == 0 {
                    result[position] = cell.attribute
                } else {
                    result.removeValue(forKey: position)
                }
            }
        }
        return result
    }

    private func capturingMarginDeleteContentCells(
        in virtualCells: [MarginDeleteVirtualCell: Cell],
        columns: ClosedRange<Int>
    ) -> [MarginDeleteVirtualCell: Cell] {
        var result = virtualCells
        for row in 0..<buffer.rows {
            let line = buffer.liveLine(row)
            for column in columns {
                let position = MarginDeleteVirtualCell(row: row, column: column)
                let cell = line[column]
                if cell.scalar != 0 ||
                    cell.clusterExtras != nil ||
                    cell.width != 1 ||
                    cell.linkId != 0 {
                    result[position] = cell
                } else {
                    result.removeValue(forKey: position)
                }
            }
        }
        return result
    }

    private func repaintMarginDeleteVirtualCells(
        _ virtualCells: [MarginDeleteVirtualCell: CellAttribute],
        columns: ClosedRange<Int>
    ) {
        var firstChangedRow: Int?
        var lastChangedRow: Int?
        for row in 0..<buffer.rows {
            let line = buffer.liveLine(row)
            for column in columns {
                let position = MarginDeleteVirtualCell(row: row, column: column)
                let attribute = virtualCells[position] ?? .bufferDefault
                let cell = line[column]
                guard cell.scalar == 0,
                      cell.clusterExtras == nil,
                      cell.width == 1,
                      cell.linkId == 0,
                      cell.attribute != attribute else {
                    continue
                }
                line[column] = Cell.blank(attribute: attribute)
                firstChangedRow = min(firstChangedRow ?? row, row)
                lastChangedRow = max(lastChangedRow ?? row, row)
            }
        }
        if let firstChangedRow, let lastChangedRow {
            markDirty(absoluteRows:
                (buffer.yBase + firstChangedRow)...(buffer.yBase + lastChangedRow))
        }
    }

    private func repaintMarginDeleteVirtualContent(
        _ virtualCells: [MarginDeleteVirtualCell: Cell],
        columns: ClosedRange<Int>
    ) {
        var firstChangedRow: Int?
        var lastChangedRow: Int?
        for row in 0..<buffer.rows {
            let line = buffer.liveLine(row)
            for column in columns {
                let position = MarginDeleteVirtualCell(row: row, column: column)
                guard let cell = virtualCells[position], line[column] != cell else {
                    continue
                }
                line[column] = cell
                firstChangedRow = min(firstChangedRow ?? row, row)
                lastChangedRow = max(lastChangedRow ?? row, row)
            }
        }
        if let firstChangedRow, let lastChangedRow {
            markDirty(absoluteRows:
                (buffer.yBase + firstChangedRow)...(buffer.yBase + lastChangedRow))
        }
    }

    func marginModeShift(insert: Bool, at y: Int, count: Int) {
        let buf = buffer
        let columns = buf.marginLeft...buf.marginRight
        guard count > 0,
              y >= 0, y < buf.rows,
              columns.lowerBound >= 0,
              columns.upperBound < buf.cols,
              columns.lowerBound <= columns.upperBound else {
            return
        }

        if insert && !(buf.scrollTop...buf.scrollBottom).contains(y) { return }

        let regionHeight = buf.scrollBottom - buf.scrollTop + 1
        let witnessLine = buf.liveLine(buf.rows - 1)
        let retainedBottomRow = buf.droppedLines + buf.yBase + buf.rows - 1
        let generationIndex = marginDeleteGenerations.firstIndex {
            $0.witnessLine === witnessLine &&
                $0.retainedBottomRow == retainedBottomRow
        }
        let retainedVirtualCells = generationIndex.map {
            marginDeleteGenerations[$0].virtualCells
        } ?? [:]
        let retainedVirtualContentCells = generationIndex.map {
            marginDeleteGenerations[$0].virtualContentCells
        } ?? [:]
        let previousVirtualCells = capturingMarginDeleteBlankCells(
            in: retainedVirtualCells,
            columns: columns)
        let previousVirtualContentCells = capturingMarginDeleteContentCells(
            in: retainedVirtualContentCells,
            columns: columns)
        let nextVirtualCells = insert
            ? Self.applyingMarginInsert(
                to: previousVirtualCells,
                cursorRow: y,
                columns: columns,
                count: count,
                verticalRegionHeight: regionHeight,
                eraseAttribute: eraseAttribute)
            : Self.applyingMarginDelete(
                to: previousVirtualCells,
                cursorRow: y,
                columns: columns,
                count: count,
                verticalRegionHeight: regionHeight,
                eraseAttribute: eraseAttribute)
        let nextVirtualContentCells = insert
            ? Self.applyingMarginInsertContent(
                to: previousVirtualContentCells,
                cursorRow: y,
                columns: columns,
                count: count,
                verticalRegionHeight: regionHeight)
            : Self.applyingMarginDeleteContent(
                to: previousVirtualContentCells,
                cursorRow: y,
                columns: columns,
                count: count,
                verticalRegionHeight: regionHeight)

        if insert {
            let virtualBottom = min(buf.rows - 1, y + regionHeight - 1)
            let region = TerminalRegion(rows: y...virtualBottom, columns: columns)
            shiftSlices(
                in: region,
                by: min(count, region.rows.count),
                direction: .towardBottom,
                fill: Cell.blank(attribute: eraseAttribute))
        } else {
            let virtualBottom = min(buf.rows - 1, y + regionHeight - 1)
            let region = TerminalRegion(rows: y...virtualBottom, columns: columns)
            shiftSlices(
                in: region,
                by: min(count, region.rows.count),
                direction: .towardTop,
                fill: Cell.blank(attribute: .bufferDefault))
        }
        repaintMarginDeleteVirtualCells(nextVirtualCells, columns: columns)
        repaintMarginDeleteVirtualContent(nextVirtualContentCells, columns: columns)

        let nextGeneration = MarginDeleteGeneration(
            witnessLine: buf.liveLine(buf.rows - 1),
            retainedBottomRow: buf.droppedLines + buf.yBase + buf.rows - 1,
            virtualCells: nextVirtualCells,
            virtualContentCells: nextVirtualContentCells)
        if let generationIndex {
            marginDeleteGenerations[generationIndex] = nextGeneration
        } else {
            marginDeleteGenerations.append(nextGeneration)
        }
        if marginDeleteGenerations.count > 32 {
            marginDeleteGenerations.removeFirst(marginDeleteGenerations.count - 32)
        }
    }

    func marginModeScroll(up: Bool) {
        guard let region = activeRegion() else { return }
        shiftSlices(
            in: region,
            by: 1,
            direction: up ? .towardTop : .towardBottom,
            fill: Cell.blank(attribute: .bufferDefault))
    }

    func restrictCursor() {
        let buf = buffer
        guard buf.rows > 0, buf.cols > 0 else {
            buf.x = 0
            buf.y = 0
            buf.wrapPending = false
            return
        }

        let rows = originMode ? buf.scrollTop...buf.scrollBottom : 0...(buf.rows - 1)
        let columns = originMode && marginMode
            ? buf.marginLeft...buf.marginRight
            : 0...(buf.cols - 1)
        buf.y = Self.clamped(buf.y, to: rows)
        buf.x = Self.clamped(buf.x, to: columns)
        buf.wrapPending = false
    }

    private func activeRegion(
        rows requestedRows: ClosedRange<Int>? = nil,
        useStoredColumns: Bool = false
    ) -> TerminalRegion? {
        let buf = buffer
        guard buf.rows > 0, buf.cols > 0 else { return nil }

        let availableRows = buf.scrollTop...buf.scrollBottom
        let rows: ClosedRange<Int>
        if let requestedRows {
            let lower = max(availableRows.lowerBound, requestedRows.lowerBound)
            let upper = min(availableRows.upperBound, requestedRows.upperBound)
            guard lower <= upper else { return nil }
            rows = lower...upper
        } else {
            rows = availableRows
        }

        let columns = marginMode || useStoredColumns
            ? buf.marginLeft...buf.marginRight
            : 0...(buf.cols - 1)
        guard columns.lowerBound >= 0,
              columns.upperBound < buf.cols,
              columns.lowerBound <= columns.upperBound else {
            return nil
        }
        return TerminalRegion(rows: rows, columns: columns)
    }

    private func shiftSlices(
        in region: TerminalRegion,
        by requestedCount: Int,
        direction: VerticalSliceShift,
        fill: Cell
    ) {
        let count = min(max(0, requestedCount), region.rows.count)
        guard count > 0 else { return }

        let sourceRows = Array(region.rows)
        let snapshots = sourceRows.map { row in
            Array(buffer.liveLine(row).cells[region.columns])
        }

        for (destinationIndex, row) in sourceRows.enumerated() {
            let sourceIndex: Int
            switch direction {
            case .towardTop:
                sourceIndex = destinationIndex + count
            case .towardBottom:
                sourceIndex = destinationIndex - count
            }

            let line = buffer.liveLine(row)
            if snapshots.indices.contains(sourceIndex) {
                for (offset, cell) in snapshots[sourceIndex].enumerated() {
                    line[region.columns.lowerBound + offset] = cell
                }
            } else {
                line.fillColumns(region.columns, with: fill)
            }
        }

        let dirtyRows = (buffer.yBase + region.rows.lowerBound)...(buffer.yBase + region.rows.upperBound)
        markDirty(absoluteRows: dirtyRows)
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private func repeatPrecedingCharacter(_ count: Int) {
        let buf = buffer
        let maxRepeat = buf.cols * buf.rows * 2
        let p = min(maxRepeat, max(count, 1))
        let line = buf.liveLine(buf.y)
        let source: Cell = buf.x - 1 < 0
            ? Cell.blank(attribute: .bufferDefault)
            : line[buf.x - 1]
        for _ in 0..<p { insertCellDirect(source) }
    }

    // MARK: - Erase

    func eraseInDisplay(mode: Int) {
        let buf = buffer
        let blank = Cell.blank(attribute: eraseAttribute)
        switch mode {
        case 0:   // cursor → end
            eraseInLine(mode: 0)
            for r in (buf.y + 1)..<buf.rows { buf.liveLine(r).fill(with: blank) }
        case 1:   // start → cursor
            eraseInLine(mode: 1)
            for r in 0..<buf.y { buf.liveLine(r).fill(with: blank) }
        case 2:   // whole screen
            for r in 0..<buf.rows {
                let line = buf.liveLine(r)
                line.fill(with: blank)
                line.isWrapped = false
                line.images = nil
            }
            clearKittyDisplayReflowClaims(in: buf)
            clearActiveReverseIndexOwnerRefreshWitness()
        case 3:   // scrollback too (xterm)
            buf.clearScrollback()
            blocks.handleScrollbackCleared()
            if buf === normalBuffer {
                blocksDroppedLineCheckpoint = normalBuffer.droppedLines
            }
        default:
            break
        }
    }

    func eraseInLine(mode: Int) {
        let buf = buffer
        let line = buf.liveLine(buf.y)
        let blank = Cell.blank(attribute: eraseAttribute)
        switch mode {
        case 0: line.fill(with: blank, from: buf.x)
        case 1: line.fill(with: blank, from: 0, to: buf.x + 1)
        case 2: line.fill(with: blank)
        default: break
        }
    }

    // MARK: - ESC

    func dispatchESC(final: UInt8, collect: [UInt8]) {
        let buf = buffer
        switch (final, collect.first) {
        case (UInt8(ascii: "7"), nil): saveCursor()          // DECSC
        case (UInt8(ascii: "8"), nil): restoreCursor()       // DECRC
        case (UInt8(ascii: "8"), UInt8(ascii: "#")):         // DECALN
            let e = Cell(scalar: UnicodeScalar("E").value, width: 1, attribute: .empty)
            for r in 0..<buf.rows { buf.liveLine(r).fill(with: e) }
            buf.scrollTop = 0
            buf.scrollBottom = buf.rows - 1
            buf.x = 0; buf.y = 0
        case (UInt8(ascii: "6"), nil):                       // DECBI
            columnIndex(back: true)
        case (UInt8(ascii: "9"), nil):                       // DECFI
            columnIndex(back: false)
        case (UInt8(ascii: "D"), nil):                       // IND
            indexLineFeed()
        case (UInt8(ascii: "E"), nil):                       // NEL
            let oldX = buf.x
            let oldY = buf.y
            buf.x = 0
            indexLineFeed()
            // NEL's carriage-return half can be the only real movement: at a
            // stored internal margin it may leave the cursor left of a
            // surviving owner while the index half is gated at the bottom.
            recordSelectorOwnerAbsoluteMotion(from: oldX, oldY: oldY)
        case (UInt8(ascii: "H"), nil):                       // HTS
            buf.setTabStop(at: buf.x)
        case (UInt8(ascii: "M"), nil): reverseLineFeed()     // RI
        case (UInt8(ascii: "Z"), nil):                       // DECID
            sendResponse("\u{1b}[?62;1;6;9;22c")
        case (UInt8(ascii: "c"), nil): fullReset()           // RIS
        case (UInt8(ascii: "="), nil), (UInt8(ascii: ">"), nil):
            break                                            // DECKPAM/DECKPNM
        case (_, UInt8(ascii: "(")), (_, UInt8(ascii: ")")),
             (_, UInt8(ascii: "*")), (_, UInt8(ascii: "+")):
            break        // charset designation — UTF-8 only (declared non-goal)
        case (UInt8(ascii: "\\"), _):
            break        // ST after an aborted string
        default:
            break
        }
    }

    // MARK: - Cursor save/restore

    func saveCursor() {
        let buf = buffer
        buf.savedCursor = ScreenBuffer.SavedCursor(
            x: buf.x, y: buf.y,
            attribute: currentAttribute,
            wrapPending: buf.wrapPending,
            originMode: originMode,
            autoWrap: autoWrap,
            marginMode: marginMode,
            reverseWraparound: reverseWraparound)
    }

    func restoreCursor() {
        let buf = buffer
        // No saved state restores the buffer's INITIAL save slots — which
        // includes autoWrap = false (the reference engine's savedWraparound
        // starts false; DECRC without DECSC really does disable wrapping).
        let saved = buf.savedCursor ?? ScreenBuffer.SavedCursor()
        buf.x = min(max(0, saved.x), buf.cols - 1)
        buf.y = min(max(0, saved.y), buf.rows - 1)
        currentAttribute = saved.attribute
        originMode = saved.originMode
        autoWrap = saved.autoWrap
        marginMode = saved.marginMode
        reverseWraparound = saved.reverseWraparound
    }

    // MARK: - Resets

    func softReset() {
        let buf = buffer
        cursorHidden = false
        originMode = false
        autoWrap = true
        insertMode = false
        applicationCursorKeys = false
        buf.scrollTop = 0
        buf.scrollBottom = buf.rows - 1
        buf.marginLeft = 0
        buf.marginRight = buf.cols - 1
        currentAttribute = .empty
        buf.savedCursor = nil
        buf.wrapPending = false
        noWrapParkedAfterPrint = false
        pendingCursorUpMoved = false
    }

    func fullReset() {
        // RIS preserves cursor visibility (reference-engine behavior:
        // resetToInitialState saves and restores it around the reset) —
        // and, because setup(isReset:) never touches it, ALSO preserves
        // reverseWraparound (soak-fuzzer finding: ?45h, RIS, BS
        // reverse-wraps to the bottom-right corner). LNM does NOT survive
        // (seed-424242 finding: 20h, RIS, print, LF keeps the column).
        let savedHidden = cursorHidden
        let savedReverseWrap = reverseWraparound
        softReset()
        cursorHidden = savedHidden
        // The reference rebuilds the NORMAL buffer and then activates it —
        // and activation copies the ALT buffer's (stale) cursor into it.
        // The alt buffer itself survives (cleared on next entry anyway).
        let altX = altBuffer.x
        let altY = altBuffer.y
        isAlternateBuffer = false
        normalBuffer.hardReset()
        activeMarginReflowBoundaries.removeAll(keepingCapacity: true)
        kittyDisplayReflowClaims.removeAll(keepingCapacity: true)
        kittyDisplayReflowBoundaries.removeAll(keepingCapacity: true)
        kittyDisplayReflowImages.removeAll(keepingCapacity: true)
        kittyDisplayReflowImageTransfers.removeAll(keepingCapacity: true)
        blocks.reset()
        blocksDroppedLineCheckpoint = 0
        // cols (not cols-1): the pending-wrap park at x == cols survives
        // the copy — the reference never clamps it.
        normalBuffer.x = min(max(0, altX), normalBuffer.cols)
        normalBuffer.y = min(max(0, altY), normalBuffer.rows - 1)
        reverseVideo = false
        marginMode = false
        reverseWraparound = savedReverseWrap
        mouseMode = .off
        mouseProtocol = .x10
        bracketedPaste = false
        lineFeedMode = false
        focusReporting = false
        synchronizedUpdates = false
        glLevel = 0
        kittyKeyboardStackNormal = []
        kittyKeyboardStackAlt = []
        resetGraphics()
        cursorStyle = .blinkBlock
        title = ""
        clearBackwardColumnAttachmentWitness()
        clearReverseIndexOwnerRefreshWitnesses()
        lastPrintedScalar = nil
        // NOTE: cursorHidden deliberately survives RIS — observable behavior
        // of the reference engine, confirmed by the differential harness.
    }

    // MARK: - DECSCUSR

    func setCursorStyleParam(_ p: Int) {
        switch p {
        case 0, 1: cursorStyle = .blinkBlock
        case 2: cursorStyle = .steadyBlock
        case 3: cursorStyle = .blinkUnderline
        case 4: cursorStyle = .steadyUnderline
        case 5: cursorStyle = .blinkBar
        case 6: cursorStyle = .steadyBar
        default: break
        }
    }

    public func setCursorStyle(_ style: TermCursorShape) {
        cursorStyle = style
    }

    // MARK: - XTWINOPS (title stack + size report only)

    private func windowOps(_ params: [Int]) {
        switch params.first ?? 0 {
        case 18:
            sendResponse("\u{1b}[8;\(buffer.rows);\(buffer.cols)t")
        case 22:
            titleStack.append(title)
        case 23:
            if let t = titleStack.popLast() {
                title = t
                delegate?.setTitle(self, title: t)
            }
        default:
            break
        }
    }

}
