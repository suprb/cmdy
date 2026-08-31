import XCTest
@testable import CmdyCore

final class CleanRoomLineAndBackspaceTests: XCTestCase {
    private let editFill = Cell(scalar: 0x2605, clusterExtras: [0x0301])

    func testInsertCellsMatchesDeclarativeOracleExhaustively() {
        let margins: [Int?] = [nil, -2, 0, 1, 3, 8]
        for width in 0...5 {
            let input = distinctCells(count: width)
            for margin in margins {
                for position in -2...8 {
                    for count in -2...7 {
                        let line = Line(cells: input, isWrapped: false)
                        let version = line.version
                        let expected = insertOracle(
                            input, at: position, count: count,
                            rightMargin: margin, fill: editFill)

                        line.insertCells(
                            at: position, count: count,
                            rightMargin: margin, fill: editFill)

                        let context = "width=\(width) margin=\(String(describing: margin)) "
                            + "position=\(position) count=\(count)"
                        XCTAssertEqual(line.cells, expected, context)
                        XCTAssertEqual(line.count, width, context)
                        XCTAssertEqual(line.version == version, expected == input, context)
                    }
                }
            }
        }
    }

    func testDeleteCellsMatchesDeclarativeOracleExhaustively() {
        let margins: [Int?] = [nil, -2, 0, 1, 3, 8]
        for width in 0...5 {
            let input = distinctCells(count: width)
            for margin in margins {
                for position in -2...8 {
                    for count in -2...7 {
                        let line = Line(cells: input, isWrapped: false)
                        let version = line.version
                        let expected = deleteOracle(
                            input, at: position, count: count,
                            rightMargin: margin, fill: editFill)

                        line.deleteCells(
                            at: position, count: count,
                            rightMargin: margin, fill: editFill)

                        let context = "width=\(width) margin=\(String(describing: margin)) "
                            + "position=\(position) count=\(count)"
                        XCTAssertEqual(line.cells, expected, context)
                        XCTAssertEqual(line.count, width, context)
                        XCTAssertEqual(line.version == version, expected == input, context)
                    }
                }
            }
        }
    }

    func testLineEditsPreserveCellsPastClampedMarginAndWrapInsertPosition() {
        let input = distinctCells(count: 6)
        let inserted = Line(cells: input, isWrapped: false)
        inserted.insertCells(at: 7, count: 1, rightMargin: 2, fill: editFill)
        XCTAssertEqual(inserted.cells, [input[0], editFill, input[1]] + Array(input[3...]))
        XCTAssertEqual(Array(inserted.cells[3...]), Array(input[3...]))

        let deleted = Line(cells: input, isWrapped: false)
        deleted.deleteCells(at: 1, count: Int.max, rightMargin: 2, fill: editFill)
        XCTAssertEqual(deleted.cells, [input[0], editFill, editFill] + Array(input[3...]))
        XCTAssertEqual(Array(deleted.cells[3...]), Array(input[3...]))

        let clamped = Line(cells: input, isWrapped: false)
        clamped.insertCells(at: 6, count: 1, rightMargin: Int.max, fill: editFill)
        XCTAssertEqual(clamped.cells, [editFill] + Array(input.dropLast()))
    }

    func testLineEditsMaterializeDeferredFillAndPreserveClusterPayloads() {
        let deferred = Cell(scalar: 0x64)
        let line = Line(cols: 5, fill: Cell(scalar: 0x78))
        line.resetDeferred(fill: deferred)
        let version = line.version
        line.insertCells(at: 1, count: 2, fill: editFill)
        XCTAssertEqual(line.cells, [deferred, editFill, editFill, deferred, deferred])
        XCTAssertNotEqual(line.version, version)

        let clustered = [
            Cell(scalar: 0x41, clusterExtras: [0x0300]),
            Cell(scalar: 0x42, clusterExtras: [0x0302]),
            Cell(scalar: 0x43, clusterExtras: [0x0303]),
            Cell(scalar: 0x44, clusterExtras: [0x0304]),
        ]
        let deleted = Line(cells: clustered, isWrapped: false)
        deleted.deleteCells(at: 1, count: Int.max, fill: Cell())
        XCTAssertEqual(deleted.cells[0].clusterExtras, [0x0300])
        XCTAssertTrue(deleted.cells.dropFirst().allSatisfy { $0.clusterExtras == nil })

        let clusterFill = Cell(scalar: 0x5A, clusterExtras: [0x0305, 0x0306])
        let filled = Line(cells: clustered, isWrapped: false)
        filled.deleteCells(at: 2, count: 2, fill: clusterFill)
        XCTAssertEqual(filled.cells[2].clusterExtras, clusterFill.clusterExtras)
        XCTAssertEqual(filled.cells[3].clusterExtras, clusterFill.clusterExtras)
    }

    func testInvalidLineEditsAreVersionPreservingNoOps() {
        let input = distinctCells(count: 4)
        let line = Line(cells: input, isWrapped: false)
        let version = line.version
        line.insertCells(at: -1, count: 1, fill: editFill)
        line.insertCells(at: 0, count: 0, fill: editFill)
        line.insertCells(at: 0, count: 1, rightMargin: -1, fill: editFill)
        line.deleteCells(at: -1, count: 1, fill: editFill)
        line.deleteCells(at: 4, count: 1, fill: editFill)
        line.deleteCells(at: 0, count: -1, fill: editFill)
        XCTAssertEqual(line.cells, input)
        XCTAssertEqual(line.version, version)
    }

    func testBackspaceNormalAndMarginColumns() {
        let normal = CmdyTerminal(cols: 5, rows: 4)
        normal.buffer.x = 4
        normal.buffer.y = 2
        normal.executeControl(0x08)
        XCTAssertEqual(normal.buffer.x, 3)
        XCTAssertEqual(normal.buffer.y, 2)
        normal.buffer.x = 0
        normal.executeControl(0x08)
        XCTAssertEqual(normal.buffer.x, 0)

        let margins = CmdyTerminal(cols: 6, rows: 4)
        margins.marginMode = true
        margins.buffer.marginLeft = 2
        margins.buffer.marginRight = 4
        margins.buffer.x = 2
        margins.buffer.y = 2
        margins.executeControl(0x08)
        XCTAssertEqual(margins.buffer.x, 2)
        margins.buffer.x = 1
        margins.executeControl(0x08)
        XCTAssertEqual(margins.buffer.x, 0)
        XCTAssertEqual(margins.buffer.y, 2)
    }

    func testReverseBackspaceCrossesRowsAndClearsWrappedMarker() {
        let terminal = CmdyTerminal(cols: 5, rows: 4)
        terminal.reverseWraparound = true
        terminal.buffer.x = 0
        terminal.buffer.y = 2
        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 1)

        terminal.buffer.x = 0
        terminal.buffer.y = 2
        terminal.buffer.liveLine(2).isWrapped = true
        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertFalse(terminal.buffer.liveLine(2).isWrapped)
    }

    func testReverseBackspaceUsesMarginsAndPreservesDepartedWrappedFlag() {
        let terminal = CmdyTerminal(cols: 6, rows: 4)
        terminal.reverseWraparound = true
        terminal.marginMode = true
        terminal.buffer.marginLeft = 2
        terminal.buffer.marginRight = 4
        terminal.buffer.x = 1
        terminal.buffer.y = 2
        terminal.buffer.liveLine(2).isWrapped = true
        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.liveLine(2).isWrapped)
    }

    func testReverseBackspaceUsesPhysicalEdgeForDefaultFullWidthMargins() {
        let terminal = CmdyTerminal(cols: 2, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x34, 0x35, 0x68])
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x08])

        XCTAssertTrue(terminal.reverseWraparound)
        XCTAssertTrue(terminal.marginMode)
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [Cell(), Cell()])
    }

    func testReverseBackspaceWrapsScrollTopAndMovesAboveOrBelowRegion() {
        let terminal = CmdyTerminal(cols: 5, rows: 5)
        terminal.reverseWraparound = true
        terminal.buffer.scrollTop = 1
        terminal.buffer.scrollBottom = 3
        terminal.buffer.x = 0
        terminal.buffer.y = 1
        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 3)

        terminal.buffer.x = 0
        terminal.buffer.y = 4
        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 3)
    }

    func testReverseBackspaceIsInertAboveCustomRegionWithAbsoluteAddressing() {
        let above = CmdyTerminal(cols: 3, rows: 3)
        above.feed(text: "\u{1B}[2;3r\u{1B}[?45h\u{8}Z")
        XCTAssertEqual(above.buffer.x, 1)
        XCTAssertEqual(above.buffer.y, 0)
        XCTAssertEqual(above.buffer.liveLine(0).cells, [
            Cell(scalar: 0x5A), Cell(), Cell(),
        ])
        XCTAssertEqual(above.buffer.liveLine(2).cells, [Cell(), Cell(), Cell()])

        let aboveWithMargins = CmdyTerminal(cols: 3, rows: 3)
        aboveWithMargins.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[2;3r" +
            "\u{1B}[?45h\u{8}Z")
        XCTAssertEqual(aboveWithMargins.buffer.x, 1)
        XCTAssertEqual(aboveWithMargins.buffer.y, 0)
        XCTAssertEqual(aboveWithMargins.buffer.liveLine(0).cells, [
            Cell(scalar: 0x5A), Cell(), Cell(),
        ])

        let aboveWithPredecessor = CmdyTerminal(cols: 3, rows: 4)
        aboveWithPredecessor.feed(
            text: "\u{1B}[3;4r\u{1B}[2;1H\u{1B}[?45h\u{8}Z")
        XCTAssertEqual(aboveWithPredecessor.buffer.x, 3)
        XCTAssertEqual(aboveWithPredecessor.buffer.y, 0)
        XCTAssertEqual(aboveWithPredecessor.buffer.liveLine(0).cells, [
            Cell(), Cell(), Cell(scalar: 0x5A),
        ])

        let marginPrefixPredecessor = CmdyTerminal(cols: 4, rows: 4)
        marginPrefixPredecessor.feed(text:
            "\u{1B}[?69h\u{1B}[2;4s\u{1B}[3;4r\u{1B}[2;1H" +
            "\u{1B}[?45h\u{8}Z")
        XCTAssertEqual(marginPrefixPredecessor.buffer.x, 4)
        XCTAssertEqual(marginPrefixPredecessor.buffer.y, 0)
        XCTAssertEqual(marginPrefixPredecessor.buffer.liveLine(0).cells, [
            Cell(), Cell(), Cell(), Cell(scalar: 0x5A),
        ])

        let atTop = CmdyTerminal(cols: 3, rows: 3)
        atTop.feed(text: "\u{1B}[2;3r\u{1B}[2;1H\u{1B}[?45h\u{8}Z")
        XCTAssertEqual(atTop.buffer.x, 3)
        XCTAssertEqual(atTop.buffer.y, 2)
        XCTAssertEqual(atTop.buffer.liveLine(2).cells, [
            Cell(), Cell(), Cell(scalar: 0x5A),
        ])

        let originRelative = CmdyTerminal(cols: 3, rows: 3)
        originRelative.feed(text: "\u{1B}[2;3r\u{1B}[?6h\u{1B}[1;1H\u{1B}[?45h\u{8}Z")
        XCTAssertEqual(originRelative.buffer.x, 3)
        XCTAssertEqual(originRelative.buffer.y, 2)
        XCTAssertEqual(originRelative.buffer.liveLine(2).cells, [
            Cell(), Cell(), Cell(scalar: 0x5A),
        ])
    }

    func testBackspaceClampsForOriginModeAndPendingWrapColumn() {
        let terminal = CmdyTerminal(cols: 5, rows: 5)
        terminal.originMode = true
        terminal.buffer.scrollTop = 1
        terminal.buffer.scrollBottom = 3
        terminal.buffer.x = 99
        terminal.buffer.y = 99
        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.y, 3)

        terminal.reverseWraparound = true
        terminal.buffer.x = 5
        terminal.buffer.y = 2
        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 2)

        terminal.buffer.x = -9
        terminal.buffer.y = -9
        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 3)
    }

    func testBackspaceFromRealPendingWrapUsesLastAddressableColumn() {
        let terminal = CmdyTerminal(cols: 4, rows: 6)
        terminal.feed([
            0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F,
            0x61, 0x30, 0x08,
        ])

        let expected = [
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
            Cell(scalar: 0x61),
            Cell(scalar: 0x30),
        ]
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testBackspaceNormalizesNoWrapCursorPastRightEdgeBeforeMoving() {
        let terminal = CmdyTerminal(cols: 2, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x37, 0x6C])
        terminal.feed([0x09])
        terminal.feed([0x41])
        terminal.feed([0x08])

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testPendingMarginBackspaceUsesCurrentAddressability() {
        let stillOutside = CmdyTerminal(cols: 4, rows: 1)
        stillOutside.feed(text:
            "\u{1B}[?69h\u{1B}[1;3s\u{1B}[1;3HA\u{8}")
        XCTAssertEqual(stillOutside.buffer.x, 2)
        XCTAssertFalse(stillOutside.buffer.wrapPending)
        stillOutside.executeControl(0x08)
        XCTAssertEqual(stillOutside.buffer.x, 1)

        let newlyAddressable = CmdyTerminal(cols: 4, rows: 1)
        newlyAddressable.feed(text:
            "\u{1B}[?69h\u{1B}[1;3s\u{1B}[1;3HA" +
            "\u{1B}[?69l\u{1B}[?45h\u{8}")
        XCTAssertEqual(newlyAddressable.buffer.x, 2)
        XCTAssertFalse(newlyAddressable.buffer.wrapPending)

        let physicalPending = CmdyTerminal(cols: 4, rows: 1)
        physicalPending.feed(text: "\u{1B}[1;4HA\u{8}")
        XCTAssertEqual(physicalPending.buffer.x, 2)

        let noWrapParked = CmdyTerminal(cols: 4, rows: 1)
        noWrapParked.feed(text:
            "\u{1B}[?69h\u{1B}[1;3s\u{1B}[?7l" +
            "\u{1B}[1;3HA\u{8}")
        XCTAssertEqual(noWrapParked.buffer.x, 2)
        XCTAssertFalse(noWrapParked.buffer.wrapPending)
    }

    func testBackspaceWalksSelectorExpandedPendingMarginCoordinate() {
        let terminal = CmdyTerminal(cols: 11, rows: 1)
        terminal.feed(text:
            "\u{1B}[?69h\u{1B}[2;9s" +
            "\u{1B}[1;2HA\u{1B}[1;9H\u{2764}\u{FE0F}")

        XCTAssertEqual(terminal.buffer.x, 10)
        XCTAssertTrue(terminal.buffer.wrapPending)

        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 9)
        XCTAssertFalse(terminal.buffer.wrapPending)

        terminal.executeControl(0x08)
        XCTAssertEqual(terminal.buffer.x, 8)

        for reverseWrap in [false, true] {
            let physicalSpill = CmdyTerminal(cols: 10, rows: 1)
            physicalSpill.feed(text:
                "\u{1B}[?69h\u{1B}[2;9s\u{1B}[1;9H" +
                "\u{2764}\u{FE0F}" +
                (reverseWrap ? "\u{1B}[?45h" : "") + "\u{8}")
            XCTAssertEqual(physicalSpill.buffer.x, reverseWrap ? 9 : 8)
            XCTAssertFalse(physicalSpill.buffer.wrapPending)
        }
    }

    func testReverseIndexRetainsCellsAfterExpandedPendingBackspace() {
        let terminal = CmdyTerminal(cols: 11, rows: 1)
        terminal.feed(text:
            "\u{1B}[?69h\u{1B}[2;9s" +
            "\u{1B}[1;2HA\u{1B}[1;9H\u{2764}\u{FE0F}")
        terminal.executeControl(0x08)
        terminal.executeControl(0x8D)

        XCTAssertEqual(terminal.buffer.liveLine(0)[1].scalar, 0x41)
        XCTAssertEqual(terminal.buffer.liveLine(0)[8], Cell(
            scalar: 0x2764, clusterExtras: [0xFE0F], width: 2))
    }

    func testReverseWrapBackspaceUpdatesReflowBoundaryAndCursorAnchor() {
        func texts(_ terminal: CmdyTerminal) -> [String] {
            guard terminal.buffer.lineCount > 0 else { return [] }
            return terminal.scrollbackLineTexts(
                rows: 0...(terminal.buffer.lineCount - 1))
        }

        let coalesced = CmdyTerminal(cols: 1, rows: 1)
        coalesced.feed(text: "\u{1B}[?45haZ\r\u{8}")
        coalesced.resize(cols: 1, rows: 1)
        XCTAssertEqual(texts(coalesced), ["aZ"])
        XCTAssertEqual(coalesced.buffer.lines.map(\.cells), [[
            Cell(scalar: 0x61), Cell(scalar: 0x5A),
        ]])
        XCTAssertEqual(coalesced.buffer.lineCount, 1)
        XCTAssertEqual(coalesced.buffer.yBase + coalesced.buffer.y, 0)
        XCTAssertEqual(coalesced.buffer.x, 1)

        let noReverse = CmdyTerminal(cols: 1, rows: 1)
        noReverse.feed(text: "aZ\r\u{8}")
        noReverse.resize(cols: 1, rows: 1)
        XCTAssertEqual(texts(noReverse), ["aZ"])

        let noBackspace = CmdyTerminal(cols: 1, rows: 1)
        noBackspace.feed(text: "\u{1B}[?45haZ\r")
        noBackspace.resize(cols: 1, rows: 1)
        XCTAssertEqual(texts(noBackspace), ["aZ"])

        let cycled = CmdyTerminal(cols: 1, rows: 2)
        cycled.feed(text: "\u{1B}[?45hZ\u{8}\u{8}")
        cycled.resize(cols: 1, rows: 1)
        XCTAssertEqual(texts(cycled), ["Z", ""])
        XCTAssertEqual(cycled.buffer.lineCount, 2)
        XCTAssertEqual(cycled.buffer.yBase + cycled.buffer.y, 1)
        XCTAssertEqual(cycled.buffer.x, 0)

        let cursorMovedFromPending = CmdyTerminal(cols: 1, rows: 2)
        cursorMovedFromPending.feed(text: "\u{1B}[?45hZ\u{1B}[D\u{8}")
        XCTAssertEqual(cursorMovedFromPending.buffer.y, 1)
        XCTAssertEqual(cursorMovedFromPending.buffer.x, 0)
        cursorMovedFromPending.resize(cols: 1, rows: 1)
        XCTAssertEqual(texts(cursorMovedFromPending), ["Z", ""])
        XCTAssertEqual(cursorMovedFromPending.buffer.lineCount, 2)
        XCTAssertEqual(
            cursorMovedFromPending.buffer.yBase + cursorMovedFromPending.buffer.y,
            1)

        let unwrappedCyclicSource = CmdyTerminal(cols: 1, rows: 2)
        unwrappedCyclicSource.feed(text: "\u{1B}[?45haZ\u{1B}[H\u{8}")
        unwrappedCyclicSource.resize(cols: 1, rows: 1)
        XCTAssertEqual(texts(unwrappedCyclicSource), ["aZ"])
        XCTAssertEqual(unwrappedCyclicSource.buffer.lineCount, 1)
        XCTAssertEqual(unwrappedCyclicSource.buffer.yBase, 0)
        XCTAssertEqual(unwrappedCyclicSource.buffer.y, 0)
        XCTAssertEqual(unwrappedCyclicSource.buffer.x, 1)

        let pending = CmdyTerminal(cols: 2, rows: 1)
        pending.feed(text: "\u{1B}[?45haZ\u{8}")
        pending.resize(cols: 1, rows: 1)
        XCTAssertEqual(texts(pending), ["aZ"])
        XCTAssertEqual(pending.buffer.lineCount, 1)
        XCTAssertEqual(pending.buffer.x, 1)

        let repartitioned = CmdyTerminal(cols: 1, rows: 2)
        repartitioned.feed(text: "\u{1B}[?45haaZ\u{1B}[H\u{8}")
        repartitioned.resize(cols: 1, rows: 1)
        XCTAssertEqual(texts(repartitioned), ["aa", "Z"])
        XCTAssertEqual(repartitioned.buffer.lines.map(\.cells), [
            [Cell(scalar: 0x61), Cell(scalar: 0x61)],
            [Cell(scalar: 0x5A), Cell()],
        ])
        XCTAssertEqual(repartitioned.buffer.lineCount, 2)
        XCTAssertEqual(repartitioned.buffer.yBase + repartitioned.buffer.y, 1)
        XCTAssertEqual(repartitioned.buffer.x, 0)

        let cyclicMarkerControl = CmdyTerminal(cols: 1, rows: 2)
        cyclicMarkerControl.feed(text: "\u{1B}[?45haaZ\u{1B}[H\u{8}")
        cyclicMarkerControl.resize(cols: 3, rows: 1)
        XCTAssertEqual(texts(cyclicMarkerControl), ["aaZ"])
        XCTAssertEqual(cyclicMarkerControl.buffer.lines.map(\.cells), [[
            Cell(scalar: 0x61), Cell(scalar: 0x61), Cell(scalar: 0x5A),
        ]])
        XCTAssertEqual(cyclicMarkerControl.buffer.lineCount, 1)
        XCTAssertEqual(cyclicMarkerControl.buffer.yBase, 0)
        XCTAssertEqual(cyclicMarkerControl.buffer.y, 0)
        XCTAssertEqual(cyclicMarkerControl.buffer.x, 2)
    }

    func testReverseWrapBackspacePreservesSoftWrapWhileDECLRMMIsActive() {
        let active = CmdyTerminal(cols: 4, rows: 2)
        active.feed(text:
            "\u{1B}[?45h\u{1B}[?69h\u{1B}[1;4s" +
            "AAAA\u{2764}\u{FE0F}\r\u{8}")

        XCTAssertTrue(active.marginMode)
        XCTAssertTrue(active.buffer.liveLine(1).isWrapped)
        active.resize(cols: 5, rows: 1)
        XCTAssertEqual(active.buffer.lineCount, 1)
        XCTAssertEqual(active.buffer.lines[0].usedLength, 5)

        let hidden = CmdyTerminal(cols: 4, rows: 2)
        hidden.feed(text:
            "\u{1B}[?45h\u{1B}[?69h\u{1B}[1;4s" +
            "AAAA\u{2764}\u{FE0F}\u{1B}[?69l\r\u{8}")

        XCTAssertFalse(hidden.marginMode)
        XCTAssertFalse(hidden.buffer.liveLine(1).isWrapped)
        hidden.resize(cols: 5, rows: 1)
        XCTAssertEqual(hidden.buffer.lineCount, 2)
    }

    private func distinctCells(count: Int) -> [Cell] {
        (0..<count).map { Cell(scalar: UInt32(0x41 + $0), linkId: UInt16($0 + 1)) }
    }

    private func insertOracle(_ input: [Cell], at position: Int, count: Int,
                              rightMargin: Int?, fill: Cell) -> [Cell] {
        guard !input.isEmpty, position >= 0, count > 0 else { return input }
        let requestedMargin = rightMargin ?? (input.count - 1)
        guard requestedMargin >= 0 else { return input }
        let activeCount = min(requestedMargin, input.count - 1) + 1
        let insertionIndex = position % activeCount
        let insertedCount = min(count, activeCount - insertionIndex)
        return Array(input.prefix(insertionIndex))
            + Array(repeating: fill, count: insertedCount)
            + Array(input[insertionIndex..<(activeCount - insertedCount)])
            + Array(input.dropFirst(activeCount))
    }

    private func deleteOracle(_ input: [Cell], at position: Int, count: Int,
                              rightMargin: Int?, fill: Cell) -> [Cell] {
        guard !input.isEmpty, position >= 0, count > 0 else { return input }
        let requestedMargin = rightMargin ?? (input.count - 1)
        guard requestedMargin >= 0 else { return input }
        let activeCount = min(requestedMargin, input.count - 1) + 1
        guard position < activeCount else { return input }
        let removedCount = min(count, activeCount - position)
        return Array(input.prefix(position))
            + Array(input[(position + removedCount)..<activeCount])
            + Array(repeating: fill, count: removedCount)
            + Array(input.dropFirst(activeCount))
    }
}
