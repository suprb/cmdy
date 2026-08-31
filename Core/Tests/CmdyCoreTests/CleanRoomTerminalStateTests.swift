import XCTest
@testable import CmdyCore

final class CleanRoomTerminalStateTests: XCTestCase {
    private func assertPlainRows(
        _ terminal: CmdyTerminal,
        _ scalars: [[UInt32]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            terminal.buffer.lines.map(\.cells),
            scalars.map { $0.map { Cell(scalar: $0) } },
            file: file,
            line: line)
    }

    func testSGRStyleSelectorsAndResetOperations() {
        let additions: [(Int, CellStyle)] = [
            (1, .bold), (2, .dim), (3, .italic), (5, .blink), (6, .blink),
            (7, .inverse), (8, .invisible), (9, .crossedOut),
        ]
        for (selector, expected) in additions {
            let terminal = CmdyTerminal(cols: 8, rows: 2)
            terminal.applySGR([selector])
            XCTAssertTrue(terminal.currentAttribute.style.contains(expected), "SGR \(selector)")
        }

        let removals: [(Int, CellStyle)] = [
            (23, .italic), (25, .blink), (27, .inverse),
            (28, .invisible), (29, .crossedOut),
        ]
        for (selector, removed) in removals {
            let terminal = CmdyTerminal(cols: 8, rows: 2)
            terminal.currentAttribute.style = [
                .bold, .dim, .italic, .blink, .inverse, .invisible, .crossedOut,
            ]
            terminal.applySGR([selector])
            XCTAssertFalse(terminal.currentAttribute.style.contains(removed), "SGR \(selector)")
        }

        let terminal = CmdyTerminal(cols: 8, rows: 2)
        terminal.currentAttribute = CellAttribute(
            fg: .trueColor(1, 2, 3), bg: .ansi256(12),
            style: [.bold, .dim, .italic], underlineKind: .curly,
            underlineColor: .ansi256(9))
        terminal.applySGR([22])
        XCTAssertFalse(terminal.currentAttribute.style.contains(.bold))
        XCTAssertFalse(terminal.currentAttribute.style.contains(.dim))
        XCTAssertTrue(terminal.currentAttribute.style.contains(.italic))

        terminal.applySGR([])
        XCTAssertEqual(terminal.currentAttribute, .empty)
    }

    func testSGRUnderlineVariantsAreColonScoped() {
        let colon = VTParser.colonSeparator
        let variants: [(Int, UnderlineKind)] = [
            (0, .none), (1, .single), (2, .double), (3, .curly),
            (4, .dotted), (5, .dashed),
        ]
        for (parameter, kind) in variants {
            let terminal = CmdyTerminal(cols: 8, rows: 2)
            terminal.currentAttribute.style.insert(.underline)
            terminal.currentAttribute.underlineKind = .single
            terminal.applySGR([4, colon, parameter])
            XCTAssertEqual(terminal.currentAttribute.underlineKind, kind)
            XCTAssertEqual(
                terminal.currentAttribute.style.contains(.underline),
                kind != .none)
        }

        let semicolon = CmdyTerminal(cols: 8, rows: 2)
        semicolon.applySGR([4, 3])
        XCTAssertEqual(semicolon.currentAttribute.underlineKind, .single)
        XCTAssertTrue(semicolon.currentAttribute.style.contains(.italic))

        semicolon.applySGR([21])
        XCTAssertEqual(semicolon.currentAttribute.underlineKind, .double)
        semicolon.applySGR([24])
        XCTAssertEqual(semicolon.currentAttribute.underlineKind, .none)
        XCTAssertFalse(semicolon.currentAttribute.style.contains(.underline))
    }

    func testSGRNormalAndBrightANSIColorTables() {
        for offset in 0..<8 {
            let terminal = CmdyTerminal(cols: 8, rows: 2)
            terminal.applySGR([30 + offset, 40 + offset])
            XCTAssertEqual(terminal.currentAttribute.fg, .ansi256(UInt8(offset)))
            XCTAssertEqual(terminal.currentAttribute.bg, .ansi256(UInt8(offset)))

            terminal.applySGR([90 + offset, 100 + offset])
            XCTAssertEqual(terminal.currentAttribute.fg, .ansi256(UInt8(offset + 8)))
            XCTAssertEqual(terminal.currentAttribute.bg, .ansi256(UInt8(offset + 8)))
        }

        let terminal = CmdyTerminal(cols: 8, rows: 2)
        terminal.currentAttribute.fg = .ansi256(4)
        terminal.currentAttribute.bg = .ansi256(5)
        terminal.applySGR([39, 49])
        XCTAssertEqual(terminal.currentAttribute.fg, .defaultColor)
        XCTAssertEqual(terminal.currentAttribute.bg, .defaultColor)
    }

    func testSGRExtendedColorsCoverLegacyAndColonForms() {
        let colon = VTParser.colonSeparator
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        terminal.applySGR([38, 5, 201, 48, 2, 10, 20, 30, 58, 5, 17])
        XCTAssertEqual(terminal.currentAttribute.fg, .ansi256(201))
        XCTAssertEqual(terminal.currentAttribute.bg, .trueColor(10, 20, 30))
        XCTAssertEqual(terminal.currentAttribute.underlineColor, .ansi256(17))

        terminal.applySGR([
            38, colon, 5, colon, 42,
            48, colon, 2, colon, 0, colon, 1, colon, 2, colon, 3,
            58, colon, 2, colon, 4, colon, 5, colon, 6,
        ])
        XCTAssertEqual(terminal.currentAttribute.fg, .ansi256(42))
        XCTAssertEqual(terminal.currentAttribute.bg, .trueColor(1, 2, 3))
        XCTAssertEqual(terminal.currentAttribute.underlineColor, .trueColor(4, 5, 6))

        terminal.applySGR([59])
        XCTAssertNil(terminal.currentAttribute.underlineColor)
    }

    func testSGRMalformedConsumptionDoesNotLeakOperandsIntoStyles() {
        let colon = VTParser.colonSeparator

        let truncated = CmdyTerminal(cols: 8, rows: 2)
        truncated.currentAttribute.fg = .ansi256(7)
        truncated.applySGR([38, 2, 255, 1])
        XCTAssertEqual(truncated.currentAttribute.fg, .ansi256(7))
        XCTAssertTrue(truncated.currentAttribute.style.contains(.bold))

        let truncatedForeground = CmdyTerminal(cols: 8, rows: 2)
        truncatedForeground.applySGR([38, 2, 1, 2])
        XCTAssertEqual(truncatedForeground.currentAttribute.fg, .defaultColor)
        XCTAssertEqual(truncatedForeground.currentAttribute.style, [.bold, .dim])

        let truncatedBackground = CmdyTerminal(cols: 8, rows: 2)
        truncatedBackground.applySGR([48, 2, 3])
        XCTAssertEqual(truncatedBackground.currentAttribute.bg, .defaultColor)
        XCTAssertEqual(truncatedBackground.currentAttribute.style, .italic)

        let invalidThenStyle = CmdyTerminal(cols: 8, rows: 2)
        invalidThenStyle.applySGR([38, 5, 999, 1])
        XCTAssertEqual(invalidThenStyle.currentAttribute.fg, .defaultColor)
        XCTAssertTrue(invalidThenStyle.currentAttribute.style.contains(.bold))

        let unknownMode = CmdyTerminal(cols: 8, rows: 2)
        unknownMode.applySGR([38, 99, 3])
        XCTAssertTrue(unknownMode.currentAttribute.style.contains(.italic))

        let malformedColonGroup = CmdyTerminal(cols: 8, rows: 2)
        malformedColonGroup.currentAttribute.fg = .ansi256(5)
        malformedColonGroup.applySGR([38, colon, 2, colon, 1, colon, 2])
        XCTAssertEqual(malformedColonGroup.currentAttribute.fg, .ansi256(5))
        XCTAssertFalse(malformedColonGroup.currentAttribute.style.contains(.bold))
        XCTAssertFalse(malformedColonGroup.currentAttribute.style.contains(.dim))
    }

    func testNextTabStopUsesStrictlyLaterBoundedStops() {
        let buffer = ScreenBuffer(cols: 20, rows: 2, hasScrollback: false)
        buffer.clearAllTabStops()
        [4, 8, 13, 99].forEach { buffer.setTabStop(at: $0) }

        XCTAssertEqual(buffer.nextTabStop(from: 4), 8)
        XCTAssertEqual(buffer.nextTabStop(from: 5), 8)
        XCTAssertEqual(buffer.nextTabStop(from: 8), 13)
        XCTAssertEqual(buffer.nextTabStop(from: 13), 19)
        XCTAssertEqual(buffer.nextTabStop(from: 19), 19)

        buffer.marginLeft = 3
        buffer.marginRight = 11
        XCTAssertEqual(buffer.nextTabStop(from: 8, marginMode: true), 11)
        XCTAssertEqual(buffer.nextTabStop(from: 11, marginMode: true), 11)
        XCTAssertEqual(buffer.nextTabStop(from: -5, marginMode: true), 4)
    }

    func testCursorPositionOriginTranslationAndClamping() {
        let terminal = CmdyTerminal(cols: 10, rows: 6)
        let buffer = terminal.buffer
        buffer.scrollTop = 2
        buffer.scrollBottom = 4
        buffer.marginLeft = 3
        buffer.marginRight = 7

        terminal.setCursorPosition(row: 99, col: -4)
        XCTAssertEqual(buffer.y, 5)
        XCTAssertEqual(buffer.x, 0)

        terminal.setPrivateMode(69, true)
        terminal.setPrivateMode(6, true)
        terminal.setCursorPosition(row: 1, col: 2)
        XCTAssertEqual(buffer.y, 3)
        XCTAssertEqual(buffer.x, 5)

        terminal.setCursorPosition(row: 99, col: 99)
        XCTAssertEqual(buffer.y, 4)
        XCTAssertEqual(buffer.x, 9)
        terminal.setCursorPosition(row: -99, col: -99)
        XCTAssertEqual(buffer.y, 2)
        XCTAssertEqual(buffer.x, 3)

        // The left margin remains the origin, while a request beyond the
        // clipped right margin addresses the physical suffix.
        terminal.setCursorPosition(row: 0, col: 4)
        XCTAssertEqual(buffer.y, 2)
        XCTAssertEqual(buffer.x, 7)
        terminal.setCursorPosition(row: 0, col: 5)
        XCTAssertEqual(buffer.y, 2)
        XCTAssertEqual(buffer.x, 8)
        terminal.setCursorPosition(row: 0, col: 99)
        XCTAssertEqual(buffer.y, 2)
        XCTAssertEqual(buffer.x, 9)
    }

    func testColumnIndexUsesDirectionSpecificShiftRanges() {
        let backward = configuredMarginTerminal()
        let backwardBefore = matrix(backward)
        backward.buffer.y = backward.buffer.scrollTop
        backward.buffer.x = backward.buffer.marginLeft
        backward.dispatchESC(final: UInt8(ascii: "6"), collect: [])
        XCTAssertEqual(backward.buffer.liveLine(0).cells.map(\.scalar), backwardBefore[0])
        XCTAssertEqual(backward.buffer.liveLine(4).cells.map(\.scalar), backwardBefore[4])
        for row in backward.buffer.scrollTop...backward.buffer.scrollBottom {
            XCTAssertEqual(backward.buffer.liveLine(row)[0].scalar, backwardBefore[row][0])
            XCTAssertEqual(backward.buffer.liveLine(row)[1].scalar, 0x20)
            XCTAssertEqual(backward.buffer.liveLine(row)[2].scalar, backwardBefore[row][1])
            XCTAssertEqual(backward.buffer.liveLine(row)[3].scalar, backwardBefore[row][2])
            XCTAssertEqual(backward.buffer.liveLine(row)[4].scalar, backwardBefore[row][3])
            XCTAssertEqual(backward.buffer.liveLine(row)[5].scalar, backwardBefore[row][4])
        }

        let forward = configuredMarginTerminal()
        let forwardBefore = matrix(forward)
        forward.buffer.y = forward.buffer.scrollTop
        forward.buffer.x = forward.buffer.marginRight
        forward.dispatchESC(final: UInt8(ascii: "9"), collect: [])
        XCTAssertEqual(forward.buffer.liveLine(0).cells.map(\.scalar), forwardBefore[0])
        XCTAssertEqual(forward.buffer.liveLine(4).cells.map(\.scalar), forwardBefore[4])
        for row in forward.buffer.scrollTop...forward.buffer.scrollBottom {
            XCTAssertEqual(forward.buffer.liveLine(row)[0].scalar, forwardBefore[row][0])
            XCTAssertEqual(forward.buffer.liveLine(row)[1].scalar, forwardBefore[row][2])
            XCTAssertEqual(forward.buffer.liveLine(row)[2].scalar, forwardBefore[row][3])
            XCTAssertEqual(forward.buffer.liveLine(row)[3].scalar, forwardBefore[row][4])
            XCTAssertEqual(forward.buffer.liveLine(row)[4].scalar, forwardBefore[row][5])
            XCTAssertEqual(forward.buffer.liveLine(row)[5].scalar, 0)
        }
    }

    func testDECBIGeneratedSpaceCarriesGraphemeAttachmentOwnership() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)

        let direct = CmdyTerminal(cols: 1, rows: 1)
        direct.feed(text: "a\r\u{1B}6\u{200D}")
        XCTAssertEqual(
            direct.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x20, clusterExtras: [0x200D],
                attribute: stub))

        let repeated = CmdyTerminal(cols: 3, rows: 1)
        repeated.feed(text: "\u{1B}[1;2Ha\r\u{1B}6\u{1B}6\u{301}")
        XCTAssertEqual(repeated.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, attribute: stub),
            Cell(scalar: 0x20, clusterExtras: [0x301], attribute: stub),
            Cell(),
        ])

        let insufficient = CmdyTerminal(cols: 4, rows: 1)
        insufficient.feed(text: "\u{1B}[1;3Ha\r\u{1B}6\u{200D}")
        XCTAssertEqual(insufficient.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, attribute: stub),
            Cell(),
            Cell(),
            Cell(scalar: 0x61),
        ])

        let hiddenMargin = CmdyTerminal(cols: 3, rows: 1)
        hiddenMargin.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[?69l" +
            "\u{1B}[1;2Ha\u{1B}6\u{1B}6\u{200D}")
        XCTAssertEqual(hiddenMargin.buffer.liveLine(0).cells, [
            Cell(),
            Cell(
                scalar: 0x20, clusterExtras: [0x200D],
                attribute: stub),
            Cell(scalar: 0x61),
        ])
    }

    func testDECBIReactivatesOwnerCoordinateClippedByICH() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)

        let clipped = CmdyTerminal(cols: 1, rows: 1)
        clipped.feed(text: "0\r\u{1B}[2@\u{1B}6\u{200D}")
        XCTAssertEqual(
            clipped.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x20, clusterExtras: [0x200D],
                attribute: stub))

        let widthZeroBetween = CmdyTerminal(cols: 1, rows: 1)
        widthZeroBetween.feed(text:
            "0\r\u{1B}[2@\u{200D}\u{1B}6\u{301}")
        XCTAssertEqual(
            widthZeroBetween.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x20, clusterExtras: [0x301],
                attribute: stub))
    }

    func testDECBIReactivatesDormantCoordinateFromShiftedRealLead() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let terminal = CmdyTerminal(cols: 2, rows: 1)
        terminal.feed(text:
            "AB\u{1B}[2G\u{1B}[@\r\u{1B}6\u{301}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, attribute: stub),
            Cell(scalar: 0x41, clusterExtras: [0x301]),
        ])
    }

    func testICHReactivatesDormantCoordinateFromShiftedRealLead() {
        let oneBlank = CmdyTerminal(cols: 3, rows: 1)
        oneBlank.feed(text:
            "B\u{1B}[1;3H0\r\u{1B}[@\u{1B}[@\u{200D}")
        XCTAssertEqual(oneBlank.buffer.liveLine(0).cells, [
            Cell(),
            Cell(),
            Cell(scalar: UnicodeScalar("B").value, clusterExtras: [0x200D]),
        ])

        let twoBlanks = CmdyTerminal(cols: 4, rows: 1)
        twoBlanks.feed(text:
            "B\u{1B}[1;4H0\r\u{1B}[@\u{1B}[@\u{1B}[@\u{301}")
        XCTAssertEqual(twoBlanks.buffer.liveLine(0).cells, [
            Cell(),
            Cell(),
            Cell(),
            Cell(scalar: UnicodeScalar("B").value, clusterExtras: [0x301]),
        ])
    }

    func testDECBIRefreshesActiveOwnerFromShiftedRealLead() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let terminal = CmdyTerminal(cols: 4, rows: 1)
        terminal.feed(text: "AAA \r\u{1B}6\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, attribute: stub),
            Cell(scalar: 0x41),
            Cell(scalar: 0x41),
            Cell(scalar: 0x41, clusterExtras: [0x200D]),
        ])
    }

    func testDormantBackwardOwnerRequiresDECBIAndExpiresOnReset() {
        let withoutShift = CmdyTerminal(cols: 1, rows: 1)
        withoutShift.feed(text: "0\r\u{1B}[2@\u{200D}")
        XCTAssertEqual(withoutShift.buffer.liveLine(0)[0], Cell())

        let reset = CmdyTerminal(cols: 1, rows: 1)
        reset.feed(text: "0\r\u{1B}[2@")
        reset.fullReset()
        reset.feed(text: "\u{1B}6\u{301}")
        XCTAssertEqual(
            reset.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x20,
                attribute: CellAttribute(
                    fg: .defaultColor, bg: .defaultInverted)))

        let resetAfterPromotion = CmdyTerminal(cols: 1, rows: 1)
        resetAfterPromotion.feed(
            text: "0\r\u{1B}[2@\u{1B}6\r\u{1B}[@\u{301}")
        XCTAssertEqual(resetAfterPromotion.buffer.liveLine(0)[0], Cell())

        let refreshedAfterShift = CmdyTerminal(cols: 2, rows: 1)
        refreshedAfterShift.feed(
            text: "  \r\u{1B}[@\u{1B}6\u{1B}[@\u{301}")
        XCTAssertEqual(refreshedAfterShift.buffer.liveLine(0).cells, [
            Cell(),
            Cell(
                scalar: 0x20,
                clusterExtras: [0x301],
                attribute: CellAttribute(
                    fg: .defaultColor, bg: .defaultInverted)),
        ])

        let resetRefreshedOwner = CmdyTerminal(cols: 2, rows: 1)
        resetRefreshedOwner.feed(
            text: "  \r\u{1B}[@\u{1B}6\u{1B}[@\r\u{1B}[@" +
                "\u{1B}6\u{1B}6\u{301}")
        XCTAssertEqual(resetRefreshedOwner.buffer.liveLine(0).cells, [
            Cell(
                scalar: 0x20,
                attribute: CellAttribute(
                    fg: .defaultColor, bg: .defaultInverted)),
            Cell(
                scalar: 0x20,
                clusterExtras: [0x301],
                attribute: CellAttribute(
                    fg: .defaultColor, bg: .defaultInverted)),
        ])
    }

    func testDormantBackwardOwnerSurvivesRoundTripResizeAndBufferSwitch() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let expected = [
            Cell(scalar: 0x20, attribute: stub),
            Cell(scalar: 0x41, clusterExtras: [0x301]),
        ]

        let resized = CmdyTerminal(cols: 2, rows: 1)
        resized.feed(text: "AB\u{1B}[2G\u{1B}[@")
        resized.resize(cols: 3, rows: 1)
        resized.resize(cols: 2, rows: 1)
        resized.feed(text: "\r\u{1B}6\u{301}")
        XCTAssertEqual(resized.buffer.liveLine(0).cells, expected)

        let switched = CmdyTerminal(cols: 2, rows: 1)
        switched.feed(text: "AB\u{1B}[2G\u{1B}[@")
        switched.setPrivateMode(1049, true)
        switched.setPrivateMode(1049, false)
        switched.feed(text: "\r\u{1B}6\u{301}")
        XCTAssertEqual(switched.buffer.liveLine(0).cells, expected)

        let switchedWithActivity = CmdyTerminal(cols: 2, rows: 1)
        switchedWithActivity.feed(text: "AB\u{1B}[2G\u{1B}[@")
        switchedWithActivity.setPrivateMode(1049, true)
        switchedWithActivity.feed(text: "Z")
        switchedWithActivity.setPrivateMode(1049, false)
        switchedWithActivity.feed(text: "\r\u{1B}6\u{301}")
        XCTAssertEqual(switchedWithActivity.buffer.liveLine(0).cells, expected)
    }

    func testAutowrapReenableConsumesParkedEdgePosition() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x37, 0x6C, 0x41,
                       0x1B, 0x5B, 0x3F, 0x37, 0x68, 0x58])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0].scalar, 0x41)
        XCTAssertEqual(terminal.buffer.liveLine(1)[0].scalar, 0x58)
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testReverseWrapBackspaceCrossesFromSecondRow() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x34, 0x35, 0x68,
                       0x0A, 0x08, 0x51])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0].scalar, 0x51)
        XCTAssertEqual(terminal.buffer.liveLine(1)[0].scalar, 0)
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDECBIAndDECFIExposeLiteralSpacesAndUseDirectionalBounds() {
        let backward = CmdyTerminal(cols: 12, rows: 6)
        backward.feed([0x1B, 0x36])
        XCTAssertEqual(backward.buffer.liveLine(0)[0].scalar, 0x20)
        XCTAssertEqual(backward.buffer.liveLine(0)[0].width, 1)
        XCTAssertEqual(
            backward.buffer.liveLine(0)[0].attribute,
            CellAttribute(fg: .defaultColor, bg: .defaultInverted))
        XCTAssertEqual(backward.buffer.liveLine(0)[0].linkId, 0)

        let forward = CmdyTerminal(cols: 12, rows: 6)
        forward.feed(text: "ABCDEFGHIJKL\u{1B}[?69h\u{1B}[3;10s\u{1B}[1;10H\u{1B}9Y")
        let expected = Array("ABDEFGHIJYL".unicodeScalars.map(\.value)) + [0]
        XCTAssertEqual(forward.buffer.liveLine(0).cells.map(\.scalar), expected)
        XCTAssertEqual(forward.buffer.x, 10)
        XCTAssertEqual(forward.buffer.y, 0)
    }

    func testDECFIVacatesWithNullAndPreservesPendingWrapNoOp() {
        let shifted = CmdyTerminal(cols: 2, rows: 2)
        shifted.feed([0x41, 0x42, 0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x48, 0x1B, 0x39])
        XCTAssertEqual(shifted.buffer.liveLine(0)[0].scalar, 0x42)
        XCTAssertEqual(shifted.buffer.liveLine(0)[1], Cell())
        XCTAssertEqual(shifted.buffer.x, 1)
        XCTAssertEqual(shifted.buffer.y, 0)

        let pending = CmdyTerminal(cols: 1, rows: 2)
        pending.feed([0x41, 0x1B, 0x39])
        XCTAssertEqual(pending.buffer.liveLine(0)[0].scalar, 0x41)
        XCTAssertEqual(pending.buffer.x, 1)
        XCTAssertEqual(pending.buffer.y, 0)
        XCTAssertTrue(pending.buffer.wrapPending)
    }

    func testDECFIAtWideContinuationIsNoOp() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed([
            0x5A, 0x0A,
            0x1B, 0x5B, 0x3F, 0x37, 0x6C,
            0xF0, 0x9F, 0x87, 0xBA,
            0xF0, 0x9F, 0x87, 0xB8,
            0x08, 0x1B, 0x39,
        ])

        let line = terminal.buffer.liveLine(0)
        XCTAssertEqual(line[0], Cell())
        XCTAssertEqual(
            line[1],
            Cell(scalar: 0x1F1FA, clusterExtras: [0x1F1F8], width: 2))
        XCTAssertEqual(
            line[2],
            Cell(
                scalar: 0, width: 0,
                attribute: CellAttribute(fg: .defaultColor, bg: .defaultInverted)))
        XCTAssertEqual(terminal.bufferLineCount, 2)
        XCTAssertEqual(terminal.liveScreenTopRow, 1)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDECFIRemovesWidePairAtActiveRightBoundary() {
        let terminal = CmdyTerminal(cols: 4, rows: 2)
        terminal.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;2H" +
            "\u{2764}\u{FE0F}\u{1B}[2I\u{1B}9")

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0, width: 0), Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIBeyondRightMarginAdvancesWithinPhysicalScreen() {
        let terminal = CmdyTerminal(cols: 12, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x39, 0x73])
        terminal.feed([0x1B, 0x5B, 0x39, 0x47])
        terminal.feed([0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F])
        XCTAssertEqual(terminal.buffer.x, 10)
        XCTAssertTrue(terminal.buffer.wrapPending)

        terminal.feed([0x1B, 0x39])

        var expected = Array(repeating: Cell(), count: 12)
        expected[8] = Cell(
            scalar: 0x2764, clusterExtras: [0xFE0F], width: 2)
        expected[9] = Cell(scalar: 0, width: 0)
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertEqual(terminal.buffer.x, 11)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIShiftsOrphanedContinuationAndUsesCurrentEraseAttribute() {
        let terminal = CmdyTerminal(cols: 3, rows: 2)
        terminal.feed(Array(
            "\u{1B}[48:5:99ma\u{65E5}a\u{1B}[48:2::3:4m\u{1B}Ma\u{1B}9".utf8))

        let rgb = CellAttribute(bg: .trueColor(0, 3, 4))
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [
                Cell(scalar: 0x61, attribute: rgb),
                Cell(scalar: 0, width: 0, attribute: stub),
                Cell.blank(attribute: rgb),
            ])
        XCTAssertEqual(
            terminal.buffer.liveLine(1).cells,
            [Cell(), Cell(), Cell.blank(attribute: rgb)])
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDECFITransfersClusterOwnershipFromShiftedTailCell() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let cases: [(initial: String, expected: [Cell])] = [
            (
                "\u{65E5}\u{65E5}",
                [
                    Cell(scalar: UnicodeScalar("a").value),
                    Cell(scalar: UnicodeScalar("A").value),
                    Cell(scalar: 0, width: 0, attribute: stub),
                    Cell(),
                ]),
            (
                "\u{65E5}aa",
                [
                    Cell(scalar: UnicodeScalar("a").value),
                    Cell(scalar: UnicodeScalar("A").value),
                    Cell(
                        scalar: UnicodeScalar("a").value,
                        clusterExtras: [0x200D]),
                    Cell(),
                ]),
            (
                "\u{65E5}",
                [
                    Cell(scalar: UnicodeScalar("a").value),
                    Cell(scalar: UnicodeScalar("A").value),
                    Cell(),
                    Cell(),
                ]),
        ]

        for testCase in cases {
            let terminal = CmdyTerminal(cols: 4, rows: 1)
            terminal.feed(text: "\u{1B}[?7l" + testCase.initial)
            terminal.feed(text: "\u{1B}[1;1HxaA\u{1B}9")
            terminal.feed(text: "\u{65E5}\u{200D}")

            XCTAssertEqual(terminal.buffer.liveLine(0).cells, testCase.expected)
            XCTAssertEqual(terminal.buffer.x, 3)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
            XCTAssertEqual(terminal.buffer.lineCount, 1)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testDECFIRefreshesAttachmentOwnerAtSavedCoordinate() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed(text: "00\rA\t\u{1B}9\u{200D}")

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [
                Cell(
                    scalar: UnicodeScalar("0").value,
                    clusterExtras: [0x200D]),
                Cell(),
                Cell(),
            ])
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertFalse(terminal.buffer.wrapPending)

        let selector = CmdyTerminal(cols: 6, rows: 2)
        selector.feed(text:
            "X0\rA\u{1B}[1;6H\u{1B}9\u{FE0F}")
        XCTAssertEqual(
            selector.buffer.liveLine(0)[0],
            Cell(
                scalar: UnicodeScalar("0").value,
                clusterExtras: [0xFE0F], width: 2))
        XCTAssertEqual(selector.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(selector.buffer.x, 6)
        XCTAssertTrue(selector.buffer.wrapPending)
    }

    func testDECFIDoesNotFollowOwnerAwayFromSavedCoordinate() {
        let terminal = CmdyTerminal(cols: 6, rows: 2)
        terminal.feed(text: "X0\u{1B}[1;6H\u{1B}9\u{0301}")

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [
                Cell(scalar: UnicodeScalar("0").value),
                Cell(), Cell(), Cell(), Cell(), Cell(),
            ])
        XCTAssertEqual(terminal.buffer.x, 5)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIInsertedRightBlankDoesNotOwnExtenders() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed(text:
            "\u{1B}[?7l\u{1B}[1;3HA\u{1B}[1;3H\u{1B}9\u{0301}")

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: UnicodeScalar("A").value), Cell()])
        XCTAssertNil(terminal.buffer.liveLine(0)[2].clusterExtras)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIPreservesOwnerRetainedByBottomIndex() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed(text: "A\u{1B}D\u{1B}9\u{0301}")

        XCTAssertEqual(
            terminal.buffer.line(absolute: 0)?[0],
            Cell(
                scalar: UnicodeScalar("A").value,
                clusterExtras: [0x0301]))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.lineCount, 2)
        XCTAssertEqual(terminal.buffer.yBase, 1)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIPreservesOwnerOutsideActiveVerticalRegion() {
        for staleTail in [false, true] {
            let terminal = CmdyTerminal(cols: 5, rows: 3)
            if staleTail {
                terminal.feed(text: "\u{1B}[2;5HC")
            }
            terminal.feed(text: "\u{1B}[2rA\t\u{1B}D\u{1B}9\u{1B}m\u{200D}")

            XCTAssertEqual(
                terminal.buffer.liveLine(0)[0],
                Cell(
                    scalar: UnicodeScalar("A").value,
                    clusterExtras: [0x200D]))
            if staleTail {
                XCTAssertEqual(
                    terminal.buffer.liveLine(1)[3],
                    Cell(scalar: UnicodeScalar("C").value))
            }
            XCTAssertEqual(terminal.buffer.x, 4)
            XCTAssertEqual(terminal.buffer.y, 1)
            XCTAssertEqual(terminal.buffer.lineCount, 3)
            XCTAssertEqual(terminal.buffer.yBase, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }
    }

    func testDECFIDoesNotPreserveOwnerAfterNonboundaryIndex() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed(text: "A\u{1B}D\u{1B}9\u{0301}")

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(terminal.buffer.lineCount, 2)
        XCTAssertEqual(terminal.buffer.yBase, 0)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIRealLiveTailClearsRetainedHistoricalOwner() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed(text: "A\u{1B}DQ\r\u{1B}9\u{0301}")

        XCTAssertEqual(
            terminal.buffer.line(absolute: 0)?[0],
            Cell(scalar: UnicodeScalar("A").value))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.lineCount, 2)
        XCTAssertEqual(terminal.buffer.yBase, 1)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIAttachmentRefreshUsesOnlyActuallyShiftedStoredSlice() {
        let active = CmdyTerminal(cols: 6, rows: 2)
        active.feed(text:
            "\u{1B}[?69h\u{1B}[2;6s" +
            "\u{1B}[1;2HX0\u{1B}[1;2HA\u{1B}[1;6H\u{1B}9\u{200D}")
        XCTAssertEqual(
            active.buffer.liveLine(0)[1],
            Cell(
                scalar: UnicodeScalar("0").value,
                clusterExtras: [0x200D]))
        XCTAssertEqual(active.buffer.x, 5)

        let hidden = CmdyTerminal(cols: 6, rows: 2)
        hidden.feed(text:
            "\u{1B}[?69h\u{1B}[2;5s\u{1B}[?69l" +
            "\u{1B}[1;3HA\u{1B}[1;6H\u{1B}9\u{0301}")
        XCTAssertEqual(
            hidden.buffer.liveLine(0)[2],
            Cell(
                scalar: UnicodeScalar("A").value,
                clusterExtras: [0x0301]))
        XCTAssertEqual(hidden.buffer.x, 5)
        XCTAssertFalse(hidden.buffer.wrapPending)
    }

    func testDECFIUsesStoredHorizontalBoundsAfterMarginModeIsDisabled() {
        func configured(_ content: String, disableMargins: Bool = true) -> CmdyTerminal {
            let terminal = CmdyTerminal(cols: 4, rows: 2)
            terminal.feed(text: "\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;1H" + content)
            terminal.feed(text: "\u{1B}[1;3H")
            if disableMargins { terminal.feed(text: "\u{1B}[?69l") }
            terminal.feed(text: "\u{1B}9")
            return terminal
        }

        let shifted = configured("\u{65E5}A")
        XCTAssertEqual(
            shifted.buffer.liveLine(0).cells,
            [Cell(scalar: 0x65E5, width: 2), Cell(scalar: 0x41), Cell(), Cell()])
        XCTAssertEqual(shifted.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell(), Cell()])
        XCTAssertEqual(shifted.buffer.x, 2)
        XCTAssertEqual(shifted.buffer.y, 0)
        XCTAssertFalse(shifted.buffer.wrapPending)

        let wideOnly = configured("\u{65E5}")
        XCTAssertEqual(
            wideOnly.buffer.liveLine(0).cells,
            [Cell(scalar: 0x65E5, width: 2), Cell(), Cell(), Cell()])
        XCTAssertEqual(wideOnly.buffer.x, 2)
        XCTAssertFalse(wideOnly.buffer.wrapPending)

        let narrowOnly = configured("A")
        XCTAssertEqual(
            narrowOnly.buffer.liveLine(0).cells,
            [Cell(scalar: 0x41), Cell(), Cell(), Cell()])
        XCTAssertEqual(narrowOnly.buffer.x, 2)
        XCTAssertFalse(narrowOnly.buffer.wrapPending)

        let enabled = configured("\u{65E5}A", disableMargins: false)
        XCTAssertEqual(
            enabled.buffer.liveLine(0).cells,
            [Cell(scalar: 0x65E5, width: 2), Cell(scalar: 0x41), Cell(), Cell()])
        XCTAssertEqual(enabled.buffer.x, 2)
        XCTAssertFalse(enabled.buffer.wrapPending)

        shifted.feed(text: "\u{301}")
        XCTAssertEqual(
            shifted.buffer.liveLine(0).cells,
            [Cell(scalar: 0x65E5, width: 2), Cell(scalar: 0x41), Cell(), Cell()])
        XCTAssertEqual(shifted.buffer.x, 2)

        let repeated = configured("\u{65E5}A")
        repeated.feed(text: "\u{1B}9")
        XCTAssertEqual(
            repeated.buffer.liveLine(0).cells,
            [Cell(scalar: 0x65E5, width: 2), Cell(), Cell(), Cell()])
        XCTAssertEqual(repeated.buffer.x, 2)
        XCTAssertEqual(repeated.buffer.y, 0)
        XCTAssertFalse(repeated.buffer.wrapPending)
        XCTAssertEqual(repeated.buffer.lineCount, 2)
        XCTAssertEqual(repeated.buffer.yBase, 0)

        let rightOfStored = CmdyTerminal(cols: 3, rows: 2)
        rightOfStored.feed(text:
            "\u{1B}[?69h\u{1B}[1;2s\u{1B}[1;1H\u{65E5}\u{1B}[1;3H\u{1B}[?69l\u{1B}9")
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        XCTAssertEqual(
            rightOfStored.buffer.liveLine(0).cells,
            [Cell(scalar: 0x65E5, width: 2),
             Cell(scalar: 0, width: 0, attribute: stub), Cell()])
        XCTAssertEqual(rightOfStored.buffer.x, 2)
        XCTAssertFalse(rightOfStored.buffer.wrapPending)

        let externalLead = CmdyTerminal(cols: 3, rows: 2)
        externalLead.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;1H\u{65E5}\u{1B}[1;3H\u{1B}[?69l\u{1B}9")
        XCTAssertEqual(
            externalLead.buffer.liveLine(0).cells,
            [Cell(scalar: 0x65E5, width: 2), Cell(), Cell()])
        XCTAssertEqual(externalLead.buffer.x, 2)
        XCTAssertFalse(externalLead.buffer.wrapPending)

        let fullWidth = CmdyTerminal(cols: 3, rows: 2)
        fullWidth.feed(text:
            "\u{1B}[?69h\u{1B}[1;3s\u{1B}[1;1H\u{65E5}\u{1B}[1;3H\u{1B}[?69l\u{1B}9")
        XCTAssertEqual(
            fullWidth.buffer.liveLine(0).cells,
            [Cell(scalar: 0, width: 0, attribute: stub), Cell(), Cell()])
        XCTAssertEqual(fullWidth.buffer.x, 2)
        XCTAssertFalse(fullWidth.buffer.wrapPending)

        let cursorLeft = CmdyTerminal(cols: 3, rows: 2)
        cursorLeft.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;1H\u{65E5}\u{1B}[1;1H\u{1B}[?69l\u{1B}9")
        XCTAssertEqual(
            cursorLeft.buffer.liveLine(0).cells,
            [Cell(scalar: 0x65E5, width: 2),
             Cell(scalar: 0, width: 0, attribute: stub), Cell()])
        XCTAssertEqual(cursorLeft.buffer.x, 1)
        XCTAssertFalse(cursorLeft.buffer.wrapPending)

        let wrappedControl = CmdyTerminal(cols: 3, rows: 2)
        wrappedControl.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{65E5}\u{1B}[1;1H\u{1B}[?69l\u{1B}9")
        XCTAssertEqual(wrappedControl.buffer.liveLine(0).cells,
                       [Cell(), Cell(), Cell()])
        XCTAssertEqual(
            wrappedControl.buffer.liveLine(1).cells,
            [Cell(scalar: 0, width: 0, attribute: stub), Cell(), Cell()])
        XCTAssertEqual(wrappedControl.buffer.x, 0)
        XCTAssertEqual(wrappedControl.buffer.y, 0)
        XCTAssertFalse(wrappedControl.buffer.wrapPending)

        let splitAtStoredRight = CmdyTerminal(cols: 3, rows: 2)
        splitAtStoredRight.feed(text:
            "\u{1B}[?69h\u{1B}[1;2s\u{65E5}\u{1B}[1;2H\u{1B}[?69l\u{1B}9")
        XCTAssertEqual(
            splitAtStoredRight.buffer.liveLine(0).cells,
            [Cell(scalar: 0, width: 0, attribute: stub), Cell(), Cell()])
        XCTAssertEqual(splitAtStoredRight.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell()])
        XCTAssertEqual(splitAtStoredRight.buffer.x, 1)
        XCTAssertEqual(splitAtStoredRight.buffer.y, 0)
        XCTAssertFalse(splitAtStoredRight.buffer.wrapPending)
        XCTAssertEqual(splitAtStoredRight.buffer.lineCount, 2)
        XCTAssertEqual(splitAtStoredRight.buffer.yBase, 0)
    }

    func testDECFITailOwnershipDependsOnWhetherSourceWasCurrentWrite() {
        for tailIsCurrentWrite in [true, false] {
            let terminal = CmdyTerminal(cols: 2, rows: 1)
            terminal.feed(text: "\u{1B}[?7l\u{1B}[I")
            terminal.feed(text: "A")
            if !tailIsCurrentWrite {
                terminal.feed(text: "\u{1B}[1;1HX")
            }
            terminal.feed(text: "\u{1B}[I\u{1B}9")
            terminal.feed(text: "\u{65E5}\u{200D}")

            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [
                    Cell(
                        scalar: UnicodeScalar("A").value,
                        clusterExtras: tailIsCurrentWrite ? nil : [0x200D]),
                    Cell(),
                ])
            XCTAssertEqual(terminal.buffer.x, 1)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
            XCTAssertEqual(terminal.buffer.lineCount, 1)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testDECFIStaleTailOwnershipRequiresContiguousDestination() {
        for prefix in ["a", "ab"] {
            let terminal = CmdyTerminal(cols: 3, rows: 1)
            terminal.feed(text: "\u{1B}[?7l\u{1B}[2I")
            terminal.feed(text: "A\r" + prefix)
            terminal.feed(text: "\u{1B}[I\u{1B}9")
            terminal.feed(text: "\u{65E5}\u{200D}")

            let isContiguous = prefix == "ab"
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                isContiguous
                    ? [
                        Cell(scalar: UnicodeScalar("b").value),
                        Cell(
                            scalar: UnicodeScalar("A").value,
                            clusterExtras: [0x200D]),
                        Cell(),
                    ]
                    : [
                        Cell(),
                        Cell(scalar: UnicodeScalar("A").value),
                        Cell(),
                    ])
            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
            XCTAssertEqual(terminal.buffer.lineCount, 1)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testDECBIMarginShiftRunsThroughPhysicalRightEdge() {
        let terminal = CmdyTerminal(cols: 4, rows: 3)
        terminal.feed([0x41, 0x42, 0x43, 0x44,
                       0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68,
                       0x1B, 0x5B, 0x32, 0x3B, 0x33, 0x73,
                       0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x48,
                       0x1B, 0x36])

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells.map(\.scalar),
            [0x41, 0x20, 0x42, 0x43])
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[1].attribute,
            CellAttribute(fg: .defaultColor, bg: .defaultInverted))
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDECBIOutsideRightMarginMovesOnePhysicalColumn() {
        let terminal = CmdyTerminal(cols: 4, rows: 2)
        terminal.feed([
            0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68,
            0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x73,
            0x1B, 0x5B, 0x34, 0x47,
        ])
        XCTAssertEqual(terminal.buffer.marginLeft, 0)
        XCTAssertEqual(terminal.buffer.marginRight, 1)
        XCTAssertEqual(terminal.buffer.x, 3)

        terminal.feed([0x1B, 0x36])

        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.liveLine(0).cells.allSatisfy { $0 == Cell() })
    }

    func testDECBIUsesStoredHorizontalBoundsAfterMarginModeIsDisabled() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let cases: [(
            columns: Int, margin: Int, cursor: Int, disableMargins: Bool,
            expectedCells: [Cell], expectedCursor: Int
        )] = [
            (2, 2, 1, true, [Cell(), Cell()], 0),
            (2, 2, 2, true,
             [Cell(), Cell(scalar: 0x20, attribute: stub)], 1),
            (2, 2, 1, false, [Cell(), Cell()], 0),
            (2, 1, 1, true,
             [Cell(scalar: 0x20, attribute: stub), Cell()], 0),
            (3, 3, 2, true, [Cell(), Cell(), Cell()], 0),
        ]

        for testCase in cases {
            let terminal = CmdyTerminal(cols: testCase.columns, rows: 1)
            terminal.feed(text: "\u{1B}[?69h")
            terminal.feed(text: "\u{1B}[\(testCase.margin);\(testCase.margin)s")
            terminal.feed(text: "\u{1B}[1;\(testCase.cursor)H")
            if testCase.disableMargins {
                terminal.feed(text: "\u{1B}[?69l")
            }
            terminal.feed(text: "\u{1B}6")

            XCTAssertEqual(terminal.buffer.liveLine(0).cells, testCase.expectedCells)
            XCTAssertEqual(terminal.buffer.x, testCase.expectedCursor)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
            XCTAssertEqual(terminal.buffer.lineCount, 1)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testDECBIPinnedOutsideVerticalRegionDoesNotShiftRows() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x32, 0x72, 0x1B, 0x36])

        XCTAssertEqual(terminal.buffer.scrollTop, 1)
        XCTAssertEqual(terminal.buffer.scrollBottom, 2)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }
    }

    func testSingleColumnHorizontalMarginsPreservePendingCursor() {
        let terminal = CmdyTerminal(cols: 2, rows: 1)
        terminal.feed([
            0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F,
            0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68,
            0x1B, 0x5B, 0x31, 0x3B, 0x31, 0x73,
            0xF0, 0x9F, 0x9A, 0x80,
        ])

        XCTAssertEqual(terminal.buffer.marginLeft, 0)
        XCTAssertEqual(terminal.buffer.marginRight, 0)
        XCTAssertEqual(terminal.bufferLineCount, 1)
        XCTAssertEqual(terminal.liveScreenTopRow, 0)
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell(scalar: 0x1F680, width: 2))
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[1],
            Cell(
                scalar: 0, width: 0,
                attribute: CellAttribute(fg: .defaultColor, bg: .defaultInverted)))
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testEqualHorizontalMarginsAtEdgesWrapWithinTheStoredColumn() {
        for marginColumn in [1, 2] {
            let terminal = CmdyTerminal(cols: 2, rows: 2)
            terminal.feed(text: "\u{1B}[?69h")
            terminal.feed(text: "\u{1B}[\(marginColumn);\(marginColumn)s")
            if marginColumn == 2 {
                terminal.feed(text: "\u{1B}[1;2H")
            }

            terminal.feed(text: "AB")

            XCTAssertEqual(terminal.buffer.marginLeft, marginColumn - 1)
            XCTAssertEqual(terminal.buffer.marginRight, marginColumn - 1)
            XCTAssertEqual(terminal.buffer.x, marginColumn)
            XCTAssertEqual(terminal.buffer.y, 1)
            XCTAssertTrue(terminal.buffer.wrapPending)
            var expectedFirst = [Cell(), Cell()]
            var expectedSecond = [Cell(), Cell()]
            expectedFirst[marginColumn - 1] = Cell(scalar: UnicodeScalar("A").value)
            expectedSecond[marginColumn - 1] = Cell(scalar: UnicodeScalar("B").value)
            XCTAssertEqual(terminal.buffer.liveLine(0).cells, expectedFirst)
            XCTAssertEqual(terminal.buffer.liveLine(1).cells, expectedSecond)
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testEqualHorizontalMarginRequestPreservesPhysicalAndCustomPendingCursor() {
        do {
            let terminal = CmdyTerminal(cols: 3, rows: 2)
            terminal.feed(text: "\u{1B}[?69h")
            terminal.feed(text: "\u{1B}[1;3H")
            terminal.feed(text: "X")
            XCTAssertEqual(terminal.buffer.x, 3)
            XCTAssertTrue(terminal.buffer.wrapPending)

            terminal.feed(text: "\u{1B}[2;2s")

            XCTAssertEqual(terminal.buffer.marginLeft, 1)
            XCTAssertEqual(terminal.buffer.marginRight, 1)
            XCTAssertEqual(terminal.buffer.x, 3)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertTrue(terminal.buffer.wrapPending)
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [Cell(), Cell(), Cell(scalar: UnicodeScalar("X").value)])
            XCTAssertEqual(terminal.buffer.liveLine(1).cells, [Cell(), Cell(), Cell()])
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }

        do {
            let terminal = CmdyTerminal(cols: 4, rows: 2)
            terminal.feed(text: "\u{1B}[?69h")
            terminal.feed(text: "\u{1B}[1;3s")
            terminal.feed(text: "\u{1B}[1;3H")
            terminal.feed(text: "X")
            XCTAssertEqual(terminal.buffer.x, 3)
            XCTAssertTrue(terminal.buffer.wrapPending)

            terminal.feed(text: "\u{1B}[2;2s")

            XCTAssertEqual(terminal.buffer.marginLeft, 1)
            XCTAssertEqual(terminal.buffer.marginRight, 1)
            XCTAssertEqual(terminal.buffer.x, 3)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertTrue(terminal.buffer.wrapPending)
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [Cell(), Cell(), Cell(scalar: UnicodeScalar("X").value), Cell()])
            XCTAssertEqual(
                terminal.buffer.liveLine(1).cells,
                [Cell(), Cell(), Cell(), Cell()])
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testDECSLRMIsNoOpWhenScreenCannotHoldDistinctMargins() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x44])
        terminal.feed([0x1B, 0x5B, 0x73])

        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
    }

    func testDECSLRMClampsCollapsesReversedAndDefaultsEndpointsWithoutMovingCursor() {
        let cases: [(
            columns: Int, request: String,
            expectedLeft: Int, expectedRight: Int, expectedCursor: Int
        )] = [
            (2, "2;3", 1, 1, 1),
            (4, "5;6", 3, 3, 3),
            (4, "4;2", 1, 1, 1),
            (4, "0;0", 0, 0, 0),
            (4, "2;0", 0, 0, 0),
            (4, "", 0, 3, 0),
            (4, "3;3", 2, 2, 2),
        ]

        for testCase in cases {
            let terminal = CmdyTerminal(cols: testCase.columns, rows: 1)
            terminal.feed(text: "\u{1B}[?69h")
            terminal.feed(text: "\u{1B}[1;\(testCase.columns)H")
            terminal.feed(text: "\u{1B}[\(testCase.request)s")

            XCTAssertEqual(terminal.buffer.x, testCase.columns - 1)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertEqual(terminal.buffer.marginLeft, testCase.expectedLeft)
            XCTAssertEqual(terminal.buffer.marginRight, testCase.expectedRight)
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                Array(repeating: Cell(), count: testCase.columns))

            terminal.feed(text: "\r")

            XCTAssertEqual(terminal.buffer.x, testCase.expectedCursor)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertEqual(terminal.buffer.lineCount, 1)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testRejectedDECSLRMDegenerateBoundaryPersistsThroughAddressing() {
        let terminal = CmdyTerminal(cols: 4, rows: 4)
        terminal.feed(text: "\u{1B}[?69h")
        terminal.feed(text: "\u{1B}[2;3s")
        terminal.feed(text: "\u{1B}[4;1s")

        XCTAssertEqual(terminal.buffer.marginLeft, 0)
        XCTAssertEqual(terminal.buffer.marginRight, 0)

        terminal.feed(text: "\u{1B}[2;2H")
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 1)

        terminal.feed(text: "Z")
        XCTAssertEqual(terminal.buffer.liveLine(1)[1], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], Cell(scalar: 0x5A))
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 2)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testAcceptedDECSLRMReplacesRejectedDegenerateBoundary() {
        let terminal = CmdyTerminal(cols: 4, rows: 4)
        terminal.feed(text: "\u{1B}[?69h")
        terminal.feed(text: "\u{1B}[4;1s")
        terminal.feed(text: "\u{1B}[2;2H")
        terminal.feed(text: "\u{1B}[2;3s")
        terminal.feed(text: "Z")

        XCTAssertEqual(terminal.buffer.marginLeft, 1)
        XCTAssertEqual(terminal.buffer.marginRight, 2)
        XCTAssertEqual(terminal.buffer.liveLine(1)[1], Cell(scalar: 0x5A))
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECSLRMNormalizationPreservesPendingCursorAndOriginMode() {
        for originMode in [false, true] {
            let terminal = CmdyTerminal(cols: 4, rows: 2)
            terminal.feed(text: "\u{1B}[?69h")
            if originMode { terminal.feed(text: "\u{1B}[?6h") }
            terminal.feed(text: "\u{1B}[1;4HA")
            XCTAssertEqual(terminal.buffer.x, 4)
            XCTAssertTrue(terminal.buffer.wrapPending)

            terminal.feed(text: "\u{1B}[3;6s")

            XCTAssertEqual(terminal.buffer.marginLeft, 2)
            XCTAssertEqual(terminal.buffer.marginRight, 3)
            XCTAssertEqual(terminal.buffer.x, 4)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertTrue(terminal.buffer.wrapPending)
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [Cell(), Cell(), Cell(), Cell(scalar: 0x41)])
            XCTAssertEqual(terminal.buffer.liveLine(1).cells,
                           [Cell(), Cell(), Cell(), Cell()])

            terminal.feed(text: "\r")

            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }

        let pendingPrint = CmdyTerminal(cols: 4, rows: 2)
        pendingPrint.feed(text:
            "\u{1B}[?69h\u{1B}[1;4HA\u{1B}[3;6sB")
        XCTAssertEqual(
            pendingPrint.buffer.liveLine(0).cells,
            [Cell(), Cell(), Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(
            pendingPrint.buffer.liveLine(1).cells,
            [Cell(), Cell(), Cell(scalar: 0x42), Cell()])
        XCTAssertEqual(pendingPrint.buffer.marginLeft, 2)
        XCTAssertEqual(pendingPrint.buffer.marginRight, 3)
        XCTAssertEqual(pendingPrint.buffer.x, 3)
        XCTAssertEqual(pendingPrint.buffer.y, 1)
        XCTAssertFalse(pendingPrint.buffer.wrapPending)
        XCTAssertEqual(pendingPrint.buffer.lineCount, 2)
        XCTAssertEqual(pendingPrint.buffer.yBase, 0)
    }

    func testDECSLRMUnderOriginModeStoresMarginsWithoutHoming() {
        let terminal = CmdyTerminal(cols: 9, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x68])
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x39, 0x73])

        XCTAssertTrue(terminal.originMode)
        XCTAssertEqual(terminal.buffer.marginLeft, 1)
        XCTAssertEqual(terminal.buffer.marginRight, 8)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            Array(repeating: Cell(), count: 9))
    }

    func testValidDECSLRMStoresMarginsWithoutHomingOrdinaryCursor() {
        let terminal = CmdyTerminal(cols: 9, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x41])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x39, 0x73])

        XCTAssertEqual(terminal.buffer.marginLeft, 1)
        XCTAssertEqual(terminal.buffer.marginRight, 8)
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
        var expected = Array(repeating: Cell(), count: 9)
        expected[0] = Cell(scalar: 0x41)
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testHiddenOriginModeMarginsDoNotClipVS16Expansion() {
        let terminal = CmdyTerminal(cols: 10, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x68])
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x39, 0x73])
        terminal.feed([0x1B, 0x5B, 0x39, 0x47])
        terminal.feed([0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F])

        var expected = Array(repeating: Cell(), count: 10)
        expected[8] = Cell(
            scalar: 0x2764, clusterExtras: [0xFE0F], width: 2)
        expected[9] = Cell(scalar: 0, width: 0)
        XCTAssertEqual(terminal.buffer.marginLeft, 1)
        XCTAssertEqual(terminal.buffer.marginRight, 8)
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertEqual(terminal.buffer.x, 10)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testHiddenOriginModeMarginsWrapOrdinaryTextFromPhysicalRightEdge() {
        let terminal = CmdyTerminal(cols: 10, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x68])
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x39, 0x73])
        terminal.feed([0x1B, 0x5B, 0x31, 0x30, 0x47])
        terminal.feed([0x30])

        var expected = Array(repeating: Cell(), count: 10)
        expected[1] = Cell(scalar: 0x30)
        XCTAssertEqual(terminal.buffer.marginLeft, 1)
        XCTAssertEqual(terminal.buffer.marginRight, 8)
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testMixedScalarReflowDoesNotRetainTrailingEmptyRow() {
        let terminal = CmdyTerminal(cols: 5, rows: 2)
        terminal.feed(Array("abc\u{0301}\u{1F680}abc\u{0301}\u{1F680}".utf8))
        terminal.resize(cols: 1, rows: 3)

        XCTAssertEqual(terminal.bufferLineCount, 4)
        XCTAssertEqual(terminal.liveScreenTopRow, 1)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 3)
        XCTAssertEqual(terminal.buffer.x, 1)
        let nonempty = (0..<terminal.bufferLineCount)
            .compactMap { terminal.scrollbackLineText(row: $0) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(nonempty, ["ab", "c\u{0301}\u{1F680}", "ab", "c\u{0301}\u{1F680}"])
    }

    func testSemanticPromptAtConsumedLineFeedBoundarySurvivesNarrowingReflow() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed(Array("aaa".utf8))
        terminal.feed([0x1B, 0x5B, 0x42])
        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x41, 0x07])

        XCTAssertEqual(terminal.bufferLineCount, 2)
        XCTAssertEqual(terminal.scrollInvariantCursorRow, 1)
        XCTAssertEqual(terminal.cursorColumn, 2)
        XCTAssertEqual(terminal.blocks.promptRows, [1])

        terminal.resize(cols: 2, rows: 1)

        XCTAssertEqual(terminal.bufferLineCount, 3)
        XCTAssertEqual(terminal.liveScreenTopRow, 2)
        XCTAssertEqual(terminal.scrollInvariantCursorRow, 2)
        XCTAssertEqual(terminal.cursorColumn, 0)
        XCTAssertEqual(terminal.scrollbackLineText(row: 0), "aa")
        XCTAssertEqual(terminal.scrollbackLineText(row: 1), "a")
        XCTAssertEqual(terminal.scrollbackLineText(row: 2), "")
        XCTAssertEqual(terminal.blocks.promptRows, [2])
        XCTAssertEqual(terminal.blocks.blocks.first?.commandRow, 2)
    }

    func testResizePreservesRectangularWrapBoundariesAndNoOpCursorColumn() {
        func configurePendingBoundary(
            cols: Int, left: Int, right: Int
        ) -> CmdyTerminal {
            let terminal = CmdyTerminal(cols: cols, rows: 2)
            terminal.feed(text:
                "\u{1B}[?69h\u{1B}[\(left);\(right)s" +
                "\u{1B}]133;A\u{7}\u{1B}[2;\(right)H" +
                "A\u{1B}]133;C\u{7}B")
            return terminal
        }

        let detached = configurePendingBoundary(cols: 2, left: 1, right: 1)
        XCTAssertEqual(detached.scrollbackLineText(row: 0), "A")
        XCTAssertEqual(detached.scrollbackLineText(row: 1), "B")
        XCTAssertEqual(detached.blocks.blocks.first?.commandRow, 1)
        detached.resize(cols: 3, rows: 2)
        XCTAssertEqual(detached.scrollbackLineText(row: 0), "A")
        XCTAssertEqual(detached.scrollbackLineText(row: 1), "B")
        XCTAssertEqual(detached.blocks.blocks.first?.commandRow, 1)
        XCTAssertEqual(detached.buffer.yBase + detached.buffer.y, 1)
        XCTAssertEqual(detached.buffer.x, 1)

        let aligned = configurePendingBoundary(cols: 3, left: 1, right: 2)
        aligned.resize(cols: 2, rows: 2)
        XCTAssertEqual(aligned.blocks.blocks.first?.commandRow, 1)
        XCTAssertEqual(aligned.buffer.yBase + aligned.buffer.y, 1)
        XCTAssertEqual(aligned.buffer.x, 1)

        let rightAligned = configurePendingBoundary(cols: 3, left: 2, right: 3)
        rightAligned.resize(cols: 2, rows: 2)
        XCTAssertEqual(rightAligned.blocks.blocks.first?.commandRow, 2)
        XCTAssertEqual(rightAligned.buffer.yBase + rightAligned.buffer.y, 2)
        XCTAssertEqual(rightAligned.buffer.x, 0)

        let histories = [
            "C",
            "CC",
            "\u{00E9}",
            "\u{65E5}",
            "\u{1B}[2A",
            "\u{1B}[2X",
            "\u{1B}[?69l",
            "\u{1B}]133;B\u{7}",
            "\u{1B}[1m",
        ]
        for history in histories {
            let persistent = configurePendingBoundary(
                cols: 3, left: 1, right: 2)
            persistent.feed(text: history)
            persistent.resize(cols: 4, rows: 2)
            XCTAssertEqual(
                persistent.blocks.blocks.first?.commandRow, 1,
                "history=\(history.unicodeScalars.map(\.value))")
        }

        let alignedAfterHistory = configurePendingBoundary(
            cols: 3, left: 1, right: 2)
        alignedAfterHistory.feed(text: "C")
        alignedAfterHistory.resize(cols: 2, rows: 2)
        XCTAssertEqual(alignedAfterHistory.blocks.blocks.first?.commandRow, 1)

        let multipleRowsHistory =
            "\u{1B}[?69h\u{1B}[1;3s" +
            "\u{1B}[1;2r\u{1B}[2;3H" +
            "\u{1B}]133;A\u{7}A\u{1B}]133;C\u{7}B" +
            "\u{1B}[1;3r\u{1B}[3;3H" +
            "\u{1B}]133;A\u{7}A\u{1B}]133;C\u{7}B"
        let multipleRows = CmdyTerminal(cols: 4, rows: 3)
        multipleRows.feed(text: multipleRowsHistory)
        multipleRows.resize(cols: 5, rows: 3)
        XCTAssertEqual(multipleRows.scrollbackLineText(row: 0), "B")
        XCTAssertEqual(multipleRows.scrollbackLineText(row: 1), "  A")
        XCTAssertEqual(multipleRows.scrollbackLineText(row: 2), "B")
        XCTAssertEqual(multipleRows.blocks.blocks.map(\.commandRow), [1, 2])
        XCTAssertEqual(multipleRows.buffer.yBase + multipleRows.buffer.y, 2)
        XCTAssertEqual(multipleRows.buffer.x, 1)

        let multipleRowsAligned = CmdyTerminal(cols: 4, rows: 3)
        multipleRowsAligned.feed(text: multipleRowsHistory)
        multipleRowsAligned.resize(cols: 3, rows: 3)
        XCTAssertEqual(multipleRowsAligned.scrollbackLineText(row: 0), "B")
        XCTAssertEqual(multipleRowsAligned.scrollbackLineText(row: 1), "  A")
        XCTAssertEqual(multipleRowsAligned.scrollbackLineText(row: 2), "B")
        XCTAssertEqual(multipleRowsAligned.blocks.blocks.map(\.commandRow), [1, 2])
        XCTAssertEqual(multipleRowsAligned.buffer.yBase + multipleRowsAligned.buffer.y, 2)
        XCTAssertEqual(multipleRowsAligned.buffer.x, 1)

        let erasedPredecessor = CmdyTerminal(cols: 4, rows: 3)
        erasedPredecessor.feed(text:
            multipleRowsHistory + "\u{1B}[2;1H\u{1B}[2K")
        erasedPredecessor.resize(cols: 3, rows: 3)
        XCTAssertEqual(erasedPredecessor.scrollbackLineText(row: 0), "B")
        XCTAssertEqual(erasedPredecessor.scrollbackLineText(row: 1), "")
        XCTAssertEqual(erasedPredecessor.scrollbackLineText(row: 2), "B")
        XCTAssertEqual(erasedPredecessor.blocks.blocks.map(\.commandRow), [1, 2])
        XCTAssertEqual(erasedPredecessor.buffer.yBase + erasedPredecessor.buffer.y, 1)
        XCTAssertEqual(erasedPredecessor.buffer.x, 0)

        let prewrappedDestination = CmdyTerminal(cols: 3, rows: 3)
        prewrappedDestination.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[1;2H" +
            "AA\u{1B}]133;A\u{7}AA")
        prewrappedDestination.resize(cols: 4, rows: 3)
        XCTAssertEqual(prewrappedDestination.scrollbackLineText(row: 0), " A")
        XCTAssertEqual(prewrappedDestination.scrollbackLineText(row: 1), " A")
        XCTAssertEqual(prewrappedDestination.scrollbackLineText(row: 2), " A")
        XCTAssertEqual(prewrappedDestination.blocks.blocks.map(\.promptRow), [1])
        XCTAssertEqual(prewrappedDestination.buffer.yBase + prewrappedDestination.buffer.y, 2)
        XCTAssertEqual(prewrappedDestination.buffer.x, 2)

        // A partial-margin bottom scroll hardens an exposed row, but it must
        // not preemptively harden an unwrapped destination.  If a later
        // ordinary wrap enters the exposed row, that fresh soft continuation
        // supersedes the older hard-boundary witness as well.
        let laterSoftWrap = CmdyTerminal(cols: 4, rows: 3)
        laterSoftWrap.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;3r" +
            "\u{1B}[2;2HU\u{1B}[3;3HAB")
        let exposedBottom = laterSoftWrap.buffer.liveLine(2)
        XCTAssertEqual(laterSoftWrap.activeMarginReflowBoundaries.count, 1)
        XCTAssertTrue(
            laterSoftWrap.activeMarginReflowBoundaries[0].line === exposedBottom)

        laterSoftWrap.feed(text: "\u{1B}[2;3HCD")
        XCTAssertTrue(laterSoftWrap.buffer.liveLine(2) === exposedBottom)
        XCTAssertTrue(laterSoftWrap.buffer.liveLine(2).isWrapped)
        XCTAssertTrue(laterSoftWrap.activeMarginReflowBoundaries.isEmpty)

        let hiddenGeometryRewrap = CmdyTerminal(cols: 2, rows: 3)
        hiddenGeometryRewrap.feed(text:
            "\u{1B}[?69h\u{1B}[2;3r\u{1B}[2;2s" +
            "\u{1B}[1;2HXXXX")
        let previouslyExposedBottom = hiddenGeometryRewrap.buffer.liveLine(2)
        XCTAssertTrue(hiddenGeometryRewrap.activeMarginReflowBoundaries.contains {
            $0.line === previouslyExposedBottom
        })

        hiddenGeometryRewrap.feed(text: "\u{1B}[?69l\u{1F680}")
        XCTAssertTrue(hiddenGeometryRewrap.buffer.liveLine(1) === previouslyExposedBottom)
        XCTAssertTrue(hiddenGeometryRewrap.activeMarginReflowBoundaries.contains {
            $0.line === previouslyExposedBottom
        })
        let freshBottom = hiddenGeometryRewrap.buffer.liveLine(2)
        XCTAssertFalse(hiddenGeometryRewrap.activeMarginReflowBoundaries.contains {
            $0.line === freshBottom
        })

        let hiddenASCIIRewrap = CmdyTerminal(cols: 2, rows: 3)
        hiddenASCIIRewrap.feed(text:
            "\u{1B}[?69h\u{1B}[2;3r\u{1B}[2;2s" +
            "\u{1B}[1;2HXXXX")
        hiddenASCIIRewrap.feed(text: "\u{1B}[?69l")
        hiddenASCIIRewrap.feed(text: "Y")
        let asciiFreshBottom = hiddenASCIIRewrap.buffer.liveLine(2)
        XCTAssertTrue(asciiFreshBottom.isWrapped)
        XCTAssertFalse(hiddenASCIIRewrap.activeMarginReflowBoundaries.contains {
            $0.line === asciiFreshBottom
        })
        hiddenASCIIRewrap.resize(cols: 3, rows: 3)
        XCTAssertEqual(hiddenASCIIRewrap.bufferLineCount, 3)
        XCTAssertEqual(hiddenASCIIRewrap.scrollbackLineText(row: 0), " X")
        XCTAssertEqual(hiddenASCIIRewrap.scrollbackLineText(row: 1), " XY")
        XCTAssertEqual(hiddenASCIIRewrap.scrollbackLineText(row: 2), "")
        XCTAssertEqual(hiddenASCIIRewrap.buffer.yBase + hiddenASCIIRewrap.buffer.y, 2)
        XCTAssertEqual(hiddenASCIIRewrap.buffer.x, 0)

        // Hiding an active margin does not make a cursor parked strictly left
        // of the new physical edge a fresh whole-row wrap owner. The recycled
        // bottom boundary must survive in that geometry.
        let hiddenInteriorRewrap = CmdyTerminal(cols: 4, rows: 3)
        hiddenInteriorRewrap.feed(text:
            "\u{1B}[?69h\u{1B}[2;3r\u{1B}[1;1s" +
            "\u{1B}[1;1HXXXX\u{1B}[?69l\u{1F680}")
        let interiorBottom = hiddenInteriorRewrap.buffer.liveLine(2)
        XCTAssertTrue(hiddenInteriorRewrap.activeMarginReflowBoundaries.contains {
            $0.line === interiorBottom
        })
        hiddenInteriorRewrap.resize(cols: 5, rows: 3)
        XCTAssertEqual(hiddenInteriorRewrap.scrollbackLineText(row: 0), "X")
        XCTAssertEqual(hiddenInteriorRewrap.scrollbackLineText(row: 1), "X")
        XCTAssertEqual(hiddenInteriorRewrap.scrollbackLineText(row: 2), "X\u{1F680} ")

        let sameGeometry = CmdyTerminal(cols: 3, rows: 2)
        sameGeometry.feed(text: "\u{1B}[1;3HB")
        XCTAssertEqual(sameGeometry.buffer.x, 3)
        sameGeometry.resize(cols: 3, rows: 2)
        XCTAssertEqual(sameGeometry.buffer.x, 3)
    }

    func testPartialLineInsertDeletePreserveOutsideColumns() {
        let insertion = configuredMarginTerminal()
        let beforeInsertion = matrix(insertion)
        insertion.marginModeShift(insert: true, at: 1, count: 1)
        assertOutsideRectangleUnchanged(insertion, before: beforeInsertion)
        assertSlice(insertion, row: 1, equals: [0, 0, 0, 0])
        assertSlice(insertion, row: 2, equals: Array(beforeInsertion[1][1...4]))
        assertSlice(insertion, row: 3, equals: Array(beforeInsertion[2][1...4]))

        let deletion = configuredMarginTerminal()
        let beforeDeletion = matrix(deletion)
        deletion.marginModeShift(insert: false, at: 1, count: 1)
        assertOutsideRectangleUnchanged(deletion, before: beforeDeletion)
        assertSlice(deletion, row: 1, equals: Array(beforeDeletion[2][1...4]))
        assertSlice(deletion, row: 2, equals: Array(beforeDeletion[3][1...4]))
        assertSlice(deletion, row: 3, equals: [0, 0, 0, 0])
    }

    func testInsertLineIsNoOpForOneColumnFullWidthMarginPendingWrap() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F])
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 1))
        XCTAssertTrue(terminal.buffer.wrapPending)

        terminal.feed([0x1B, 0x5B, 0x4C])

        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 1))
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testInsertLinesPreserveWidePendingCellWithDefaultHorizontalMargins() {
        let terminal = CmdyTerminal(cols: 2, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F])
        let expected = [
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ]
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertTrue(terminal.buffer.wrapPending)

        terminal.feed([0x1B, 0x5B, 0x4C])

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testInsertLinePreservesPendingCellWithNarrowHorizontalMargins() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x33, 0x73])
        terminal.feed([0x09, 0x41])
        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [Cell(), Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertTrue(terminal.buffer.wrapPending)

        terminal.feed([0x1B, 0x5B, 0x4C])

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [Cell(), Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testInsertLineIsNoOpOutsideHorizontalMarginsAfterBackwardTab() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x33, 0x73])
        terminal.feed([0x09, 0x41])
        terminal.feed([0x1B, 0x5B, 0x5A])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)

        terminal.feed([0x1B, 0x5B, 0x4C])

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [Cell(), Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testPartialColumnScrollPreservesRowsAndColumnsOutsideRegion() {
        let upward = configuredMarginTerminal()
        let beforeUpward = matrix(upward)
        upward.marginModeScroll(up: true)
        assertOutsideRectangleUnchanged(upward, before: beforeUpward)
        assertSlice(upward, row: 1, equals: Array(beforeUpward[2][1...4]))
        assertSlice(upward, row: 2, equals: Array(beforeUpward[3][1...4]))
        assertSlice(upward, row: 3, equals: [0, 0, 0, 0])

        let downward = configuredMarginTerminal()
        let beforeDownward = matrix(downward)
        downward.marginModeScroll(up: false)
        assertOutsideRectangleUnchanged(downward, before: beforeDownward)
        assertSlice(downward, row: 1, equals: [0, 0, 0, 0])
        assertSlice(downward, row: 2, equals: Array(beforeDownward[1][1...4]))
        assertSlice(downward, row: 3, equals: Array(beforeDownward[2][1...4]))
    }

    func testClusterStateMachineCoversMarksZWJRegionalPairsAndVariations() {
        let combining = CmdyTerminal(cols: 12, rows: 2)
        combining.feed(text: "e\u{0301}")
        XCTAssertEqual(combining.buffer.liveLine(0)[0].scalar, 0x65)
        XCTAssertEqual(combining.buffer.liveLine(0)[0].clusterExtras, [0x0301])
        XCTAssertEqual(combining.buffer.x, 1)

        let zwj = CmdyTerminal(cols: 12, rows: 2)
        zwj.feed(text: "\u{1F469}\u{200D}\u{1F4BB}")
        XCTAssertEqual(zwj.buffer.liveLine(0)[0].scalar, 0x1F469)
        XCTAssertEqual(zwj.buffer.liveLine(0)[0].clusterExtras, [0x200D, 0x1F4BB])
        XCTAssertEqual(zwj.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(zwj.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(zwj.buffer.x, 2)

        let regional = CmdyTerminal(cols: 12, rows: 2)
        regional.feed(text: "\u{1F1FA}\u{1F1F8}\u{1F1E8}")
        XCTAssertEqual(regional.buffer.liveLine(0)[0].clusterExtras, [0x1F1F8])
        XCTAssertEqual(regional.buffer.liveLine(0)[2].scalar, 0x1F1E8)
        XCTAssertNil(regional.buffer.liveLine(0)[2].clusterExtras)
        XCTAssertEqual(regional.buffer.x, 4)

        let emojiVariation = CmdyTerminal(cols: 8, rows: 2)
        emojiVariation.feed(text: "\u{2600}\u{FE0F}")
        XCTAssertEqual(emojiVariation.buffer.liveLine(0)[0].scalar, 0x2600)
        XCTAssertEqual(emojiVariation.buffer.liveLine(0)[0].clusterExtras, [0xFE0F])
        XCTAssertEqual(emojiVariation.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(emojiVariation.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(emojiVariation.buffer.x, 2)

        let textVariation = CmdyTerminal(cols: 8, rows: 2)
        textVariation.feed(text: "\u{1F600}\u{FE0E}")
        XCTAssertEqual(textVariation.buffer.liveLine(0)[0].scalar, 0x1F600)
        XCTAssertNil(textVariation.buffer.liveLine(0)[0].clusterExtras)
        XCTAssertEqual(textVariation.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(textVariation.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(textVariation.buffer.x, 2)
    }

    func testClusterTransitionsKeepPlainVSAndPlainZWJFollowersSeparate() {
        let terminal = CmdyTerminal(cols: 12, rows: 6)
        terminal.feed(text: "A\u{0301} B\u{FE0F} C\u{200D}\u{1F680} \u{1F1FA}\u{1F1F8}")

        let expected: [(scalar: UInt32, width: Int8, extras: [UInt32]?)] = [
            (0x41, 1, [0x0301]),
            (0x20, 1, nil),
            (0x42, 1, nil),
            (0x20, 1, nil),
            (0x43, 1, [0x200D]),
            (0x1F680, 2, nil),
            (0, 0, nil),
            (0x20, 1, nil),
            (0x1F1FA, 2, [0x1F1F8]),
            (0, 0, nil),
            (0, 1, nil),
            (0, 1, nil),
        ]
        let line = terminal.buffer.liveLine(0)
        for (column, item) in expected.enumerated() {
            XCTAssertEqual(line[column].scalar, item.scalar, "scalar at column \(column)")
            XCTAssertEqual(line[column].width, item.width, "width at column \(column)")
            XCTAssertEqual(line[column].clusterExtras, item.extras, "extras at column \(column)")
        }
        XCTAssertEqual(terminal.buffer.x, 10)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testNoWrapZWJCompositionRequiresCompatibleWideEmojiPair() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)

        do {
            let terminal = CmdyTerminal(cols: 2, rows: 2)
            terminal.feed(text: "\u{1B}[?7l\u{65E5}\u{200D}a")

            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [
                    Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2),
                    Cell(scalar: UnicodeScalar("a").value),
                ])
            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }

        let separateWidePairs: [(lead: String, follower: String)] = [
            ("\u{65E5}", "\u{65E5}"),
            ("\u{65E5}", "\u{1F680}"),
            ("\u{1F680}", "\u{65E5}"),
        ]
        for pair in separateWidePairs {
            let terminal = CmdyTerminal(cols: 4, rows: 2)
            terminal.feed(text: "\u{1B}[?7l" + pair.lead + "\u{200D}" + pair.follower)

            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [
                    Cell(
                        scalar: pair.lead.unicodeScalars.first!.value,
                        clusterExtras: [0x200D], width: 2),
                    Cell(scalar: 0, width: 0, attribute: stub),
                    Cell(scalar: pair.follower.unicodeScalars.first!.value, width: 2),
                    Cell(scalar: 0, width: 0, attribute: stub),
                ])
            XCTAssertEqual(terminal.buffer.x, 4)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }

        do {
            let terminal = CmdyTerminal(cols: 4, rows: 2)
            terminal.feed(text: "\u{1B}[?7l\u{1F469}\u{200D}\u{1F4BB}")

            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [
                    Cell(
                        scalar: 0x1F469,
                        clusterExtras: [0x200D, 0x1F4BB], width: 2),
                    Cell(scalar: 0, width: 0, attribute: stub),
                    Cell(),
                    Cell(),
                ])
            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }
    }

    func testEmojiZWJCompositionSupportsTextPresentationSymbols() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let composedCases: [(
            input: String, scalar: UInt32, extras: [UInt32], width: Int8,
            usesStubContinuation: Bool
        )] = [
            ("\u{1F680}\u{200D}\u{2764}", 0x1F680, [0x200D, 0x2764], 2, true),
            ("\u{1F680}\u{200D}\u{2764}\u{FE0E}",
             0x1F680, [0x200D, 0x2764, 0xFE0E], 1, true),
            ("\u{1F680}\u{200D}\u{2764}\u{FE0F}",
             0x1F680, [0x200D, 0x2764, 0xFE0F], 2, true),
            ("\u{1F680}\u{200D}\u{2708}\u{FE0F}",
             0x1F680, [0x200D, 0x2708, 0xFE0F], 2, true),
            ("\u{2764}\u{FE0F}\u{200D}\u{2764}\u{FE0F}",
             0x2764, [0xFE0F, 0x200D, 0x2764, 0xFE0F], 2, false),
            ("\u{2764}\u{FE0E}\u{200D}\u{2764}\u{FE0F}",
             0x2764, [0xFE0E, 0x200D, 0x2764, 0xFE0F], 2, false),
        ]

        for testCase in composedCases {
            let terminal = CmdyTerminal(cols: 4, rows: 2)
            terminal.feed(text: testCase.input)

            var expected = Array(repeating: Cell(), count: 4)
            expected[0] = Cell(
                scalar: testCase.scalar,
                clusterExtras: testCase.extras,
                width: testCase.width)
            expected[1] = testCase.usesStubContinuation
                ? Cell(scalar: 0, width: 0, attribute: stub)
                : Cell(scalar: 0, width: 0)
            XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
            XCTAssertEqual(terminal.buffer.x, Int(testCase.width))
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertEqual(terminal.buffer.wrapPending, false)
        }

        do {
            let terminal = CmdyTerminal(cols: 4, rows: 2)
            terminal.feed(text: "\u{2764}\u{200D}\u{1F680}")
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [
                    Cell(
                        scalar: 0x2764,
                        clusterExtras: [0x200D, 0x1F680]),
                    Cell(),
                    Cell(),
                    Cell(),
                ])
            XCTAssertEqual(terminal.buffer.x, 1)
        }

        do {
            let terminal = CmdyTerminal(cols: 4, rows: 2)
            terminal.feed(text: "\u{65E5}\u{200D}\u{2764}\u{FE0F}")
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [
                    Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2),
                    Cell(scalar: 0, width: 0, attribute: stub),
                    Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
                    Cell(scalar: 0, width: 0),
                ])
            XCTAssertEqual(terminal.buffer.x, 4)
        }

        do {
            let terminal = CmdyTerminal(cols: 6, rows: 2)
            terminal.feed(text: "\u{1F680}\u{200D}#\u{FE0F}\u{20E3}")
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [
                    Cell(scalar: 0x1F680, clusterExtras: [0x200D], width: 2),
                    Cell(scalar: 0, width: 0, attribute: stub),
                    Cell(scalar: 0x23, clusterExtras: [0xFE0F, 0x20E3], width: 2),
                    Cell(scalar: 0, width: 0),
                    Cell(),
                    Cell(),
                ])
            XCTAssertEqual(terminal.buffer.x, 4)
        }
    }

    func testZWJClusterBoundaryExcludesRegionalKeycapAndRepeatedJoiners() {
        let stub = Cell(
            scalar: 0, width: 0,
            attribute: CellAttribute(fg: .defaultColor, bg: .defaultInverted))

        let separatedInputs: [(String, UInt32, [UInt32], Cell)] = [
            ("\u{1F1FA}\u{1F1F8}\u{200D}\u{2764}\u{FE0F}",
             0x1F1FA, [0x1F1F8, 0x200D], stub),
            ("\u{1F1FA}\u{200D}\u{2764}\u{FE0F}",
             0x1F1FA, [0x200D], stub),
            ("1\u{FE0F}\u{20E3}\u{200D}\u{2764}\u{FE0F}",
             0x31, [0xFE0F, 0x20E3, 0x200D], Cell(scalar: 0, width: 0)),
            ("\u{1F469}\u{200D}\u{200D}\u{2764}\u{FE0F}",
             0x1F469, [0x200D, 0x200D], stub),
        ]
        for (text, lead, extras, continuation) in separatedInputs {
            let terminal = CmdyTerminal(cols: 3, rows: 1)
            terminal.feed(text: text)
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [
                    Cell(scalar: lead, clusterExtras: extras, width: 2),
                    continuation,
                    Cell(
                        scalar: 0x2764,
                        clusterExtras: [0xFE0F], width: 1),
                ],
                text)
            XCTAssertEqual(terminal.buffer.x, 3, text)
            XCTAssertTrue(terminal.buffer.wrapPending, text)
        }

        let eligible = CmdyTerminal(cols: 3, rows: 1)
        eligible.feed(text: "\u{1F469}\u{200D}\u{2764}\u{FE0F}")
        XCTAssertEqual(
            eligible.buffer.liveLine(0).cells,
            [
                Cell(
                    scalar: 0x1F469,
                    clusterExtras: [0x200D, 0x2764, 0xFE0F], width: 2),
                stub,
                Cell(),
            ])
        XCTAssertEqual(eligible.buffer.x, 2)

        let regionalFollower = CmdyTerminal(cols: 4, rows: 1)
        regionalFollower.feed(text:
            "\u{1F1FA}\u{200D}\u{1F1FA}\u{1F1F8}")
        XCTAssertEqual(
            regionalFollower.buffer.liveLine(0).cells,
            [
                Cell(scalar: 0x1F1FA, clusterExtras: [0x200D], width: 2),
                stub,
                Cell(scalar: 0x1F1FA, clusterExtras: [0x1F1F8], width: 2),
                stub,
            ])
        XCTAssertEqual(regionalFollower.buffer.x, 4)

        let rightEdgeSingleton = CmdyTerminal(cols: 3, rows: 2)
        rightEdgeSingleton.feed(text:
            "\u{1B}[?69h\u{1B}[3;3s\u{1B}[1;3H"
            + "\u{1F469}\u{200D}\u{2764}\u{FE0E}")
        XCTAssertEqual(
            rightEdgeSingleton.buffer.liveLine(1).cells,
            [
                Cell(), Cell(),
                Cell(
                    scalar: 0x1F469,
                    clusterExtras: [0x200D, 0x2764, 0xFE0E], width: 1),
            ])
        XCTAssertEqual(rightEdgeSingleton.buffer.x, 2)
        XCTAssertEqual(rightEdgeSingleton.buffer.y, 1)
        XCTAssertFalse(rightEdgeSingleton.buffer.wrapPending)
    }

    func testVS15ShrinkClearsPendingCursorForOneColumnWrappedEmojiCluster() {
        let followers: [UInt32] = [0x2764, 0x2708]
        for follower in followers {
            let terminal = CmdyTerminal(cols: 1, rows: 2)
            terminal.feed(text: "\u{1F680}\u{200D}"
                + String(UnicodeScalar(follower)!) + "\u{FE0E}")

            XCTAssertEqual(terminal.buffer.liveLine(0).cells, [Cell()])
            XCTAssertEqual(
                terminal.buffer.liveLine(1).cells,
                [Cell(
                    scalar: 0x1F680,
                    clusterExtras: [0x200D, follower, 0xFE0E],
                    width: 1)])
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, 1)
            XCTAssertFalse(terminal.buffer.wrapPending)
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testHorizontalMarginModeSeparatesNarrowFollowerFromWideJoinerPrefix() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0xE6, 0x97, 0xA5])
        terminal.feed([0xE2, 0x80, 0x8D])
        terminal.feed([0x5A])

        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [
                Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2),
                Cell(scalar: 0, width: 0, attribute: stub),
                Cell(scalar: 0x5A),
            ])
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)

        let emoji = CmdyTerminal(cols: 3, rows: 1)
        emoji.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        emoji.feed([0xF0, 0x9F, 0x91, 0xA9])
        emoji.feed([0xE2, 0x80, 0x8D])
        emoji.feed([0xF0, 0x9F, 0x92, 0xBB])
        XCTAssertEqual(
            emoji.buffer.liveLine(0)[0],
            Cell(scalar: 0x1F469, clusterExtras: [0x200D, 0x1F4BB], width: 2))
        XCTAssertEqual(
            emoji.buffer.liveLine(0)[1],
            Cell(scalar: 0, width: 0, attribute: stub))
        XCTAssertEqual(emoji.buffer.x, 2)
        XCTAssertFalse(emoji.buffer.wrapPending)
    }

    func testEmojiVariationSelectorsAreIgnoredForWideNonEmojiLead() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let expected = [
            Cell(scalar: 0x65E5, width: 2),
            Cell(scalar: 0, width: 0, attribute: stub),
        ]
        let selectors: [[UInt8]] = [
            [0xEF, 0xB8, 0x8F],
            [0xEF, 0xB8, 0x8E],
        ]

        for selector in selectors {
            let terminal = CmdyTerminal(cols: 2, rows: 1)
            terminal.feed([0xE6, 0x97, 0xA5])
            terminal.feed(selector)

            XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertTrue(terminal.buffer.wrapPending)
        }
    }

    func testVS16WidthExpansionUsesNeutralContinuationAttribute() {
        let terminal = CmdyTerminal(cols: 12, rows: 6)
        terminal.feed([0x31, 0xEF, 0xB8, 0x8F])

        let lead = terminal.buffer.liveLine(0)[0]
        XCTAssertEqual(lead.scalar, 0x31)
        XCTAssertEqual(lead.clusterExtras, [0xFE0F])
        XCTAssertEqual(lead.width, 2)

        let continuation = terminal.buffer.liveLine(0)[1]
        XCTAssertEqual(continuation.scalar, 0)
        XCTAssertEqual(continuation.width, 0)
        XCTAssertEqual(continuation.attribute, .bufferDefault)
        XCTAssertEqual(continuation.linkId, 0)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testVS16WidthExpansionCopiesLeadAttributeToContinuation() {
        let terminal = CmdyTerminal(cols: 4, rows: 2)
        terminal.feed([
            0x1B, 0x5B, 0x33, 0x38, 0x3B, 0x35, 0x3B, 0x32, 0x30, 0x31, 0x6D,
            0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F,
        ])

        let line = terminal.buffer.liveLine(0)
        XCTAssertEqual(line[0].scalar, 0x2764)
        XCTAssertEqual(line[0].width, 2)
        XCTAssertEqual(line[0].attribute, CellAttribute(fg: .ansi256(201)))
        XCTAssertEqual(line[1].scalar, 0)
        XCTAssertEqual(line[1].width, 0)
        XCTAssertEqual(line[1].attribute, line[0].attribute)
        XCTAssertEqual(line[1].linkId, line[0].linkId)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testCombiningRefusesOverwrittenLastWrite() {
        let overwritten = CmdyTerminal(cols: 8, rows: 2)
        overwritten.feed(text: "A")
        overwritten.buffer.liveLine(0)[0] = Cell(scalar: 0x42)
        overwritten.feed(text: "\u{0301}")
        XCTAssertEqual(overwritten.buffer.liveLine(0)[0].scalar, 0x42)
        XCTAssertNil(overwritten.buffer.liveLine(0)[0].clusterExtras)
    }

    func testCombiningUsesUnchangedLastWriteAfterHorizontalCursorMoves() {
        let movements: [[UInt8]] = [
            [0x08],
            [0x0D],
            [0x1B, 0x5B, 0x44],
        ]
        for movement in movements {
            let terminal = CmdyTerminal(cols: 5, rows: 3)
            terminal.feed([0x5A] + movement + [0xCC, 0x81])
            XCTAssertEqual(terminal.buffer.liveLine(0)[0].scalar, 0x5A)
            XCTAssertEqual(terminal.buffer.liveLine(0)[0].clusterExtras, [0x0301])
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, 0)
        }
    }

    func testDiscardedVS16PreservesLastWriteForFollowingJoiner() {
        let terminal = CmdyTerminal(cols: 5, rows: 3)
        terminal.feed([0x5A, 0xEF, 0xB8, 0x8F, 0xE2, 0x80, 0x8D])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0].scalar, 0x5A)
        XCTAssertEqual(terminal.buffer.liveLine(0)[0].clusterExtras, [0x200D])
        XCTAssertEqual(terminal.buffer.liveLine(0)[0].width, 1)
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testWideCellNeverSplitsAtScreenOrMarginBoundary() {
        let wrapped = CmdyTerminal(cols: 4, rows: 3)
        wrapped.feed(text: "abc\u{65E5}")
        XCTAssertFalse(wrapped.buffer.liveLine(0).cells.contains { $0.width == 2 })
        XCTAssertTrue(wrapped.buffer.liveLine(1).isWrapped)
        XCTAssertEqual(wrapped.buffer.liveLine(1)[0].scalar, 0x65E5)
        XCTAssertEqual(wrapped.buffer.liveLine(1)[0].width, 2)
        XCTAssertEqual(wrapped.buffer.liveLine(1)[1].width, 0)

        let noWrap = CmdyTerminal(cols: 4, rows: 2)
        noWrap.setPrivateMode(7, false)
        noWrap.buffer.x = 3
        noWrap.printScalar("\u{65E5}")
        XCTAssertNotEqual(noWrap.buffer.liveLine(0)[3].width, 2)
        XCTAssertEqual(noWrap.buffer.x, 3)

        let margins = CmdyTerminal(cols: 8, rows: 3)
        margins.setPrivateMode(69, true)
        margins.buffer.marginLeft = 2
        margins.buffer.marginRight = 5
        margins.buffer.x = 5
        margins.printScalar("\u{65E5}")
        XCTAssertEqual(margins.buffer.y, 1)
        XCTAssertEqual(margins.buffer.liveLine(1)[2].scalar, 0x65E5)
        XCTAssertEqual(margins.buffer.liveLine(1)[3].width, 0)
    }

    func testNoWrapRejectedWideGlyphPreservesParkedCursor() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed([
            0x1B, 0x5B, 0x3F, 0x37, 0x6C,
            0x61, 0xE6, 0x97, 0xA5,
        ])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell(scalar: 0x61))
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testNoWrapRejectedWideGlyphPreservesPriorClusterForJoiner() {
        let terminal = CmdyTerminal(cols: 2, rows: 1)
        terminal.feed([
            0x1B, 0x5B, 0x3F, 0x37, 0x6C,
            0x61,
            0xF0, 0x9F, 0x91, 0xA9,
            0xE2, 0x80, 0x8D,
            0xF0, 0x9F, 0x92, 0xBB,
        ])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0].scalar, 0x61)
        XCTAssertEqual(terminal.buffer.liveLine(0)[0].clusterExtras, [0x200D])
        XCTAssertEqual(terminal.buffer.liveLine(0)[1], Cell())
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testRejectedWideGlyphRestoresClusterTargetAfterTabForJoiner() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed([0x5A])
        terminal.feed([0x1B, 0x5B, 0x3F, 0x37, 0x6C])
        terminal.feed([0x09])
        terminal.feed([0xF0, 0x9F, 0x91, 0xA9])
        terminal.feed([0xE2, 0x80, 0x8D])
        terminal.feed([0xF0, 0x9F, 0x92, 0xBB])

        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell(scalar: 0x5A, clusterExtras: [0x200D]))
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testRejectedWideGlyphRestoresPriorRowClusterForJoiner() {
        for rejectedWide in ["\u{65E5}", "\u{1F680}", "\u{1F469}"] {
            let terminal = CmdyTerminal(cols: 1, rows: 2)
            terminal.feed([0x1B, 0x5B, 0x3F, 0x37, 0x6C])
            terminal.feed(text: "a")
            terminal.feed([0x09])
            terminal.feed([0x1B, 0x44])
            terminal.feed(text: rejectedWide)
            terminal.feed(text: "\u{200D}")

            XCTAssertEqual(
                terminal.buffer.liveLine(0)[0],
                Cell(scalar: UnicodeScalar("a").value, clusterExtras: [0x200D]))
            XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, 1)
            XCTAssertFalse(terminal.buffer.wrapPending)
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testRejectedWideDoesNotRestoreReverseIndexContinuationCoordinate() {
        let terminal = CmdyTerminal(cols: 5, rows: 2)
        terminal.feed(text:
            "\u{1B}[1;4H\u{65E5}\u{1B}[2;5H\u{1B}[?7lA" +
                "\u{1B}M\u{1B}M" +
                "\u{1F469}\u{200D}\u{1F469}\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells,
                       Array(repeating: Cell(), count: 5))
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
            Cell(), Cell(), Cell(),
            Cell(scalar: 0x65E5, width: 2),
            Cell(
                scalar: 0, width: 0,
                attribute: CmdyTerminal.stubAttribute),
        ])
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testKittyDisplayVerticalMotionPreservesSelectorCursorOffset() {
        let terminal = CmdyTerminal(cols: 2, rows: 1)
        terminal.feed(text: "0")
        terminal.feed([
            0x1B, 0x5F, 0x47,
            0x61, 0x3D, 0x54, 0x2C, 0x66, 0x3D, 0x33, 0x32, 0x2C,
            0x73, 0x3D, 0x31, 0x2C, 0x76, 0x3D, 0x31, 0x2C,
            0x69, 0x3D, 0x33, 0x2C, 0x71, 0x3D, 0x32, 0x3B,
            0x2F, 0x77, 0x41, 0x41, 0x2F, 0x77, 0x3D, 0x3D,
            0x1B, 0x5C,
        ])
        terminal.feed(text: "\u{FE0F}\u{2764}\u{FE0F}")

        XCTAssertEqual(terminal.buffer.lineCount, 2)
        XCTAssertEqual(terminal.buffer.line(absolute: 0)?.cells, [
            Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ])
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(),
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F]),
        ])
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testNoWrapVS16JoinerClusterAbsorbsRejectedWideFollower() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x37, 0x6C])
        terminal.feed([0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F])
        terminal.feed([0xF0, 0x9F, 0x91, 0xA9])
        terminal.feed([0xE2, 0x80, 0x8D])
        terminal.feed([0xF0, 0x9F, 0x92, 0xBB])

        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x2764,
                clusterExtras: [0xFE0F, 0x200D, 0x1F4BB]))
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testRejectedWideGlyphPreservesPresentationOwnerThroughJoinedSelector() {
        for selector: UnicodeScalar in ["\u{FE0E}", "\u{FE0F}"] {
            let terminal = CmdyTerminal(cols: 1, rows: 1)
            terminal.feed(text:
                "\u{1B}[?7l\u{2764}" + String(selector) +
                "\u{301}\u{65E5}\u{200D}\u{2764}" + String(selector))

            XCTAssertEqual(
                terminal.buffer.liveLine(0)[0],
                Cell(
                    scalar: 0x2764,
                    clusterExtras: [
                        selector.value, 0x301, 0x200D, 0x2764,
                        selector.value,
                    ]))
            XCTAssertEqual(terminal.buffer.x, 1)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }
    }

    func testInternalRightRejectedWidePreservesPresentationOwnerThroughJoinedSelector() {
        for selector: UnicodeScalar in ["\u{FE0E}", "\u{FE0F}"] {
            let terminal = CmdyTerminal(cols: 5, rows: 1)
            terminal.feed(text:
                "\u{1B}[?69h\u{1B}[1;4s \u{1B}[?7l" +
                "\u{2764}\u{FE0F}\u{1F469}\u{200D}\u{1F4BB}" +
                String(selector))

            XCTAssertEqual(
                terminal.buffer.liveLine(0)[1],
                Cell(
                    scalar: 0x2764,
                    clusterExtras: [0xFE0F, 0x200D, 0x1F4BB, selector.value],
                    width: selector == "\u{FE0E}" ? 1 : 2))
            XCTAssertEqual(
                terminal.buffer.x,
                selector == "\u{FE0E}" ? 2 : 3)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }
    }

    func testRejectedWideGlyphPreservesRelocatedPresentationOwner() {
        let terminal = CmdyTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\u{1B}[?7l\u{2764}\u{FE0F}")
        terminal.feed([0x09])
        XCTAssertEqual(terminal.buffer.x, 4)

        terminal.feed(text: "\u{65E5}\u{200D}\u{2764}\u{FE0F}")

        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0].clusterExtras,
            [0xFE0F, 0x200D, 0x2764, 0xFE0F])
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testRepeatedRejectedWideGlyphPreservesJoinedPresentationOwner() {
        for firstRejection in ["\u{65E5}", "\u{2764}\u{FE0F}"] {
            let terminal = CmdyTerminal(cols: 1, rows: 1)
            terminal.feed(text:
                "\u{1B}[?7l\u{2764}\u{FE0F}" + firstRejection +
                "\u{200D}\u{65E5}\u{2764}\u{FE0F}")

            XCTAssertEqual(
                terminal.buffer.liveLine(0)[0],
                Cell(
                    scalar: 0x2764,
                    clusterExtras: [0xFE0F, 0x200D, 0x2764, 0xFE0F]))
            XCTAssertEqual(terminal.buffer.x, 1)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }
    }

    func testOverwritingWideLeadPreservesItsPriorContinuationStub() {
        let terminal = CmdyTerminal(cols: 19, rows: 9)
        terminal.feed([0x1B, 0x5B, 0x31, 0x3B, 0x31, 0x48,
                       0x1B, 0x48, 0x41,
                       0xF0, 0x9F, 0x9A, 0x80,
                       0x1B, 0x5B, 0x5A,
                       0xF0, 0x9F, 0x9A, 0x80])

        let line = terminal.buffer.liveLine(0)
        XCTAssertEqual(line[0].scalar, 0x1F680)
        XCTAssertEqual(line[0].width, 2)
        XCTAssertEqual(line[1].scalar, 0)
        XCTAssertEqual(line[1].width, 0)
        XCTAssertEqual(line[2].scalar, 0)
        XCTAssertEqual(line[2].width, 0)
        XCTAssertEqual(
            line[2].attribute,
            CellAttribute(fg: .defaultColor, bg: .defaultInverted))
        XCTAssertEqual(line[2].linkId, 0)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testOverwritingWideContinuationPreservesItsPriorLead() {
        let terminal = CmdyTerminal(cols: 4, rows: 6)
        terminal.feed([0x41, 0xCC, 0x81,
                       0x1B, 0x5B, 0x32, 0x32, 0x6D,
                       0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F,
                       0x1B, 0x36,
                       0xE6, 0x97, 0xA5])

        let line = terminal.buffer.liveLine(0)
        XCTAssertEqual(line[0].scalar, 0x41)
        XCTAssertEqual(line[0].clusterExtras, [0x0301])
        XCTAssertEqual(line[0].width, 1)
        XCTAssertEqual(line[1].scalar, 0x2764)
        XCTAssertEqual(line[1].clusterExtras, [0xFE0F])
        XCTAssertEqual(line[1].width, 2)
        XCTAssertEqual(line[2].scalar, 0x65E5)
        XCTAssertEqual(line[2].width, 2)
        XCTAssertEqual(line[3].scalar, 0)
        XCTAssertEqual(line[3].width, 0)
        XCTAssertEqual(
            line[3].attribute,
            CellAttribute(fg: .defaultColor, bg: .defaultInverted))
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testWideContinuationOverwriteMatchesMinimalChunkedSequence() {
        let terminal = CmdyTerminal(cols: 4, rows: 3)
        terminal.feed([0xF0, 0x9F, 0x9A, 0x80])
        terminal.feed([0x1B])
        terminal.feed([0x36])
        terminal.feed([0xE6, 0x97, 0xA5])

        let line = terminal.buffer.liveLine(0)
        XCTAssertEqual(line[0], Cell(scalar: 0x1F680, width: 2))
        XCTAssertEqual(line[1], Cell(scalar: 0x65E5, width: 2))
        XCTAssertEqual(
            line[2],
            Cell(scalar: 0, width: 0,
                 attribute: CellAttribute(fg: .defaultColor, bg: .defaultInverted)))
        XCTAssertEqual(line[3], Cell())
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testOneColumnWideGlyphAdvancesOnceAndStoresClippedLead() {
        let fresh = CmdyTerminal(cols: 1, rows: 3)
        fresh.feed([0xF0, 0x9F, 0x9A, 0x80])
        XCTAssertEqual(fresh.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(fresh.buffer.liveLine(1)[0], Cell(scalar: 0x1F680, width: 2))
        XCTAssertEqual(fresh.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(fresh.buffer.x, 1)
        XCTAssertEqual(fresh.buffer.y, 1)

        let pending = CmdyTerminal(cols: 1, rows: 3)
        pending.feed([0x41, 0x1B, 0x5B, 0x31, 0x5A,
                      0xF0, 0x9F, 0x9A, 0x80])
        XCTAssertEqual(pending.buffer.liveLine(0)[0], Cell(scalar: 0x41))
        XCTAssertEqual(pending.buffer.liveLine(1)[0], Cell(scalar: 0x1F680, width: 2))
        XCTAssertEqual(pending.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(pending.buffer.x, 1)
        XCTAssertEqual(pending.buffer.y, 1)
    }

    func testOriginModeIndexThenReverseIndexPreservesClippedWideLead() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        let wideLead = Cell(scalar: 0x1F469, width: 2)

        terminal.feed(text: "\u{1F469}")
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], wideLead)

        terminal.feed(text: "\u{1B}[2r")
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], wideLead)
        XCTAssertEqual(terminal.buffer.y, 0)
        terminal.feed(text: "\u{1B}[?6h")
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], wideLead)
        XCTAssertEqual(terminal.buffer.y, 0)

        terminal.feed(text: "\u{1B}D")
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], wideLead)
        XCTAssertEqual(terminal.buffer.y, 2)
        terminal.feed(text: "\u{1B}M")
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], wideLead)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)

        let narrowWrapped = CmdyTerminal(cols: 1, rows: 3)
        narrowWrapped.feed(text: "AA\u{1B}[2r\u{1B}[?6h\u{1B}D\u{1B}M")
        assertPlainRows(narrowWrapped, [[0x41], [0x41], [0]])
        XCTAssertEqual(narrowWrapped.buffer.y, 1)

        let reverseOnly = CmdyTerminal(cols: 1, rows: 3)
        reverseOnly.feed(text: "\u{1F469}\u{1B}[2r\u{1B}[?6h\u{1B}M")
        XCTAssertEqual(reverseOnly.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(reverseOnly.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(reverseOnly.buffer.liveLine(2)[0], wideLead)
        XCTAssertEqual(reverseOnly.buffer.y, 1)

        let belowRegion = CmdyTerminal(cols: 1, rows: 5)
        belowRegion.feed(text:
            "\u{1B}[2;4r\u{1B}[5;1H\u{1B}[?6h\u{1B}D")
        XCTAssertEqual(belowRegion.buffer.y, 3)
    }

    func testVS16ExpansionReturnsToBlankCUDDestinationOnSingleColumnScreen() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x61])
        terminal.feed([0x1B, 0x5B, 0x42])
        terminal.feed([0xE2, 0x9D, 0xA4])
        terminal.feed([0xEF, 0xB8, 0x8F])

        XCTAssertEqual(terminal.bufferLineCount, 3)
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell(scalar: 0x61))
        XCTAssertEqual(
            terminal.buffer.liveLine(1)[0],
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F]))
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testVS16ExpansionReturnsToBlankNonzeroCUDDestination() {
        let terminal = CmdyTerminal(cols: 2, rows: 3)
        terminal.feed([0x09])
        terminal.feed([0x61])
        terminal.feed([0x1B, 0x5B, 0x42])
        terminal.feed([0xE2, 0x9D, 0xA4])
        terminal.feed([0xEF, 0xB8, 0x8F])

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0x61)])
        XCTAssertEqual(
            terminal.buffer.liveLine(1).cells,
            [Cell(), Cell(scalar: 0x2764, clusterExtras: [0xFE0F])])
        XCTAssertEqual(terminal.buffer.liveLine(2).cells, [Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testVS16ExpansionReturnsToAttributedBlankCUDDestination() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x32, 0x4A])
        terminal.feed([0x61])
        terminal.feed([0x1B, 0x5B, 0x42])
        terminal.feed([0xE2, 0x9D, 0xA4])
        terminal.feed([0xEF, 0xB8, 0x8F])

        XCTAssertEqual(terminal.bufferLineCount, 3)
        let blackBackground = CellAttribute(bg: .ansi256(0))
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell(scalar: 0x61, attribute: blackBackground))
        XCTAssertEqual(
            terminal.buffer.liveLine(1)[0],
            Cell(
                scalar: 0x2764,
                clusterExtras: [0xFE0F],
                attribute: blackBackground))
        XCTAssertEqual(
            terminal.buffer.liveLine(2)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testVS16ExpandsInPlaceAfterPrintingRightOfStoredMargin() {
        let expanded = CmdyTerminal(cols: 2, rows: 2)
        expanded.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{1B}[1;2H\u{2764}\u{FE0F}")

        XCTAssertEqual(expanded.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(
            expanded.buffer.liveLine(1).cells,
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
             Cell(scalar: 0, width: 0)])
        XCTAssertEqual(expanded.buffer.x, 2)
        XCTAssertEqual(expanded.buffer.y, 1)
        XCTAssertTrue(expanded.buffer.wrapPending)
        XCTAssertEqual(expanded.buffer.lineCount, 2)
        XCTAssertEqual(expanded.buffer.yBase, 0)

        let followed = CmdyTerminal(cols: 2, rows: 2)
        followed.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{1B}[1;2H\u{2764}\u{FE0F}A")

        XCTAssertEqual(
            followed.buffer.liveLine(0).cells,
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2), Cell()])
        XCTAssertEqual(
            followed.buffer.liveLine(1).cells,
            [Cell(scalar: 0x41), Cell(scalar: 0, width: 0)])
        XCTAssertEqual(followed.buffer.x, 1)
        XCTAssertEqual(followed.buffer.y, 1)
        XCTAssertTrue(followed.buffer.wrapPending)
        XCTAssertEqual(followed.buffer.lineCount, 2)
        XCTAssertEqual(followed.buffer.yBase, 0)

        let textPresentation = CmdyTerminal(cols: 2, rows: 2)
        textPresentation.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{1B}[1;2H\u{2764}\u{FE0E}")

        XCTAssertEqual(textPresentation.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(
            textPresentation.buffer.liveLine(1).cells,
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0E]), Cell()])
        XCTAssertEqual(textPresentation.buffer.x, 1)
        XCTAssertEqual(textPresentation.buffer.y, 1)
        XCTAssertTrue(textPresentation.buffer.wrapPending)
        XCTAssertEqual(textPresentation.buffer.lineCount, 2)
        XCTAssertEqual(textPresentation.buffer.yBase, 0)
    }

    func testVS16RightOfStoredMarginWrapBranchBoundaries() {
        let bottomRow = CmdyTerminal(cols: 2, rows: 2)
        bottomRow.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{1B}[2;2H\u{2764}\u{FE0F}")
        XCTAssertEqual(bottomRow.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(
            bottomRow.buffer.liveLine(1).cells,
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
             Cell(scalar: 0, width: 0)])
        XCTAssertEqual(bottomRow.buffer.x, 2)
        XCTAssertEqual(bottomRow.buffer.y, 1)
        XCTAssertEqual(bottomRow.buffer.lineCount, 2)
        XCTAssertEqual(bottomRow.buffer.yBase, 0)

        let oneRow = CmdyTerminal(cols: 2, rows: 1)
        oneRow.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{1B}[1;2H\u{2764}\u{FE0F}")
        XCTAssertEqual(
            oneRow.buffer.liveLine(0).cells,
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
             Cell(scalar: 0, width: 0)])
        XCTAssertEqual(oneRow.buffer.x, 2)
        XCTAssertEqual(oneRow.buffer.y, 0)

        let noWrap = CmdyTerminal(cols: 2, rows: 2)
        noWrap.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{1B}[?7l\u{1B}[1;2H\u{2764}\u{FE0F}")
        XCTAssertEqual(
            noWrap.buffer.liveLine(0).cells,
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
             Cell(scalar: 0, width: 0)])
        XCTAssertEqual(noWrap.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(noWrap.buffer.x, 2)
        XCTAssertEqual(noWrap.buffer.y, 0)
    }

    func testVS16RelocationRestoresDisplacedDECBISpace() {
        let terminal = CmdyTerminal(cols: 2, rows: 3)
        terminal.feed([0x1B, 0x36])
        terminal.feed([0x09, 0x61])
        terminal.feed([0x1B, 0x5B, 0x42])

        let marker = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let markedSpace = Cell(scalar: 0x20, attribute: marker)
        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], markedSpace)
        }
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 1)

        terminal.feed([0xE2, 0x9D, 0xA4])
        terminal.feed([0xEF, 0xB8, 0x8F])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], markedSpace)
        XCTAssertEqual(terminal.buffer.liveLine(0)[1], Cell(scalar: 0x61))
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], markedSpace)
        XCTAssertEqual(
            terminal.buffer.liveLine(1)[1],
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F]))
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], markedSpace)
        XCTAssertEqual(terminal.buffer.liveLine(2)[1], Cell())
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testVS16ExpandsNarrowOverwriteWithoutRestoringWideGlyph() {
        let overwritten = CmdyTerminal(cols: 1, rows: 2)
        overwritten.feed(text: "\u{65E5}\r\u{2764}\u{FE0F}")
        XCTAssertEqual(overwritten.buffer.lines.map(\.cells), [
            [Cell()],
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0F])],
        ])
        XCTAssertEqual(overwritten.buffer.x, 1)
        XCTAssertEqual(overwritten.buffer.y, 1)
        XCTAssertEqual(overwritten.buffer.lineCount, 2)
        XCTAssertEqual(overwritten.buffer.yBase, 0)

        let textSelector = CmdyTerminal(cols: 1, rows: 2)
        textSelector.feed(text: "\u{65E5}\r\u{2764}\u{FE0E}")
        XCTAssertEqual(textSelector.buffer.lines.map(\.cells), [
            [Cell()],
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0E])],
        ])
        XCTAssertEqual(textSelector.buffer.x, 1)
        XCTAssertEqual(textSelector.buffer.y, 1)

        let noSelector = CmdyTerminal(cols: 1, rows: 2)
        noSelector.feed(text: "\u{65E5}\r\u{2764}")
        XCTAssertEqual(noSelector.buffer.lines.map(\.cells), [
            [Cell()], [Cell(scalar: 0x2764)],
        ])
        XCTAssertEqual(noSelector.buffer.x, 1)
        XCTAssertEqual(noSelector.buffer.y, 1)

        let physicalRoom = CmdyTerminal(cols: 2, rows: 2)
        physicalRoom.feed(text: "\u{65E5}\r\u{2764}\u{FE0F}")
        XCTAssertEqual(physicalRoom.buffer.liveLine(0).cells, [
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ])
        XCTAssertEqual(physicalRoom.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(physicalRoom.buffer.x, 2)
        XCTAssertEqual(physicalRoom.buffer.y, 0)

        let cursorBackward = CmdyTerminal(cols: 1, rows: 2)
        cursorBackward.feed(text: "\u{65E5}\u{1B}[D\u{2764}\u{FE0F}")
        XCTAssertEqual(cursorBackward.buffer.lines.map(\.cells), [
            [Cell()],
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0F])],
        ])
        XCTAssertEqual(cursorBackward.buffer.x, 1)
        XCTAssertEqual(cursorBackward.buffer.y, 1)

        let offsetMargin = CmdyTerminal(cols: 3, rows: 2)
        offsetMargin.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[1;2H" +
            "\u{65E5}\r\u{2764}\u{FE0F}")
        XCTAssertEqual(offsetMargin.buffer.liveLine(0).cells, [
            Cell(), Cell(), Cell(),
        ])
        XCTAssertEqual(offsetMargin.buffer.liveLine(1).cells, [
            Cell(),
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ])
        XCTAssertEqual(offsetMargin.buffer.x, 3)
        XCTAssertEqual(offsetMargin.buffer.y, 1)
        XCTAssertEqual(offsetMargin.buffer.lineCount, 2)
        XCTAssertEqual(offsetMargin.buffer.yBase, 0)

        let adjacentWide = CmdyTerminal(cols: 2, rows: 2)
        adjacentWide.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[1;2H" +
            "\u{65E5}\u{1B}[Z\u{2764}\u{FE0F}")
        XCTAssertEqual(adjacentWide.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(adjacentWide.buffer.liveLine(1).cells, [
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ])
        XCTAssertEqual(adjacentWide.buffer.x, 2)
        XCTAssertEqual(adjacentWide.buffer.y, 1)
        XCTAssertEqual(adjacentWide.buffer.lineCount, 2)
        XCTAssertEqual(adjacentWide.buffer.yBase, 0)

        let separatedWide = CmdyTerminal(cols: 3, rows: 2)
        separatedWide.feed(text:
            "\u{1B}[?69h\u{1B}[3;3s\u{1B}[1;3H" +
            "\u{65E5}\u{1B}[Z\u{2764}\u{FE0F}")
        XCTAssertEqual(separatedWide.buffer.liveLine(0).cells, [
            Cell(), Cell(), Cell(),
        ])
        XCTAssertEqual(separatedWide.buffer.liveLine(1).cells, [
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
            Cell(scalar: 0x65E5, width: 2),
        ])
        XCTAssertEqual(separatedWide.buffer.x, 2)
        XCTAssertEqual(separatedWide.buffer.y, 1)
        XCTAssertEqual(separatedWide.buffer.lineCount, 2)
        XCTAssertEqual(separatedWide.buffer.yBase, 0)
    }

    func testCBTClearsPendingWrapBeforeTextPresentationGlyph() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed([
            0xE6, 0x97, 0xA5,
            0xE6, 0x97, 0xA5,
            0x1B, 0x5B, 0x5A,
            0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F,
        ])

        XCTAssertEqual(terminal.bufferLineCount, 3)
        XCTAssertEqual(terminal.liveScreenTopRow, 2)
        XCTAssertEqual(terminal.buffer.line(absolute: 0)?[0], Cell())
        XCTAssertEqual(
            terminal.buffer.line(absolute: 1)?[0],
            Cell(scalar: 0x65E5, width: 2))
        XCTAssertEqual(
            terminal.buffer.line(absolute: 2)?[0],
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 1))
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testCBTPreservesHistoricalSelectorWidthTrajectory() {
        let terminal = CmdyTerminal(cols: 4, rows: 1)
        terminal.feed(text: " 0\u{1B}[Z\u{FE0F}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20),
            Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
            Cell(),
        ])
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)

        let repeated = CmdyTerminal(cols: 4, rows: 1)
        repeated.feed(text: " 0\u{1B}[Z\u{1B}[Z\u{FE0F}")
        XCTAssertEqual(repeated.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20),
            Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
            Cell(),
        ])
        XCTAssertEqual(repeated.buffer.x, 1)
        XCTAssertFalse(repeated.buffer.wrapPending)
    }

    func testInsertCellDirectUsesActiveRangeAndPreservesOutsideMargins() {
        let normal = CmdyTerminal(cols: 6, rows: 2)
        seedRow(normal, row: 0, scalars: Array("ABCDEF".unicodeScalars.map(\.value)))
        normal.insertMode = true
        normal.buffer.x = 2
        normal.insertCellDirect(Cell(scalar: 0x58))
        XCTAssertEqual(normal.buffer.liveLine(0).cells.map(\.scalar),
                       Array("ABXCDE".unicodeScalars.map(\.value)))

        let margins = CmdyTerminal(cols: 7, rows: 2)
        seedRow(margins, row: 0, scalars: Array("abcdefg".unicodeScalars.map(\.value)))
        margins.insertMode = true
        margins.marginMode = true
        margins.buffer.marginLeft = 2
        margins.buffer.marginRight = 4
        margins.buffer.x = 3
        margins.insertCellDirect(Cell(scalar: 0x58))
        XCTAssertEqual(margins.buffer.liveLine(0).cells.map(\.scalar),
                       Array("abcXdfg".unicodeScalars.map(\.value)))
    }

    func testInsertModeComposesWideEmojiZWJCluster() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        for columns in [4, 2] {
            let terminal = CmdyTerminal(cols: columns, rows: 2)
            terminal.feed([0x1B, 0x5B, 0x34, 0x68])
            terminal.feed(text: "\u{1F469}\u{200D}\u{1F4BB}")

            var expected = Array(repeating: Cell(), count: columns)
            expected[0] = Cell(
                scalar: 0x1F469,
                clusterExtras: [0x200D, 0x1F4BB],
                width: 2)
            expected[1] = Cell(scalar: 0, width: 0, attribute: stub)
            XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
            XCTAssertEqual(
                terminal.buffer.liveLine(1).cells,
                Array(repeating: Cell(), count: columns))
            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertEqual(terminal.buffer.wrapPending, columns == 2)
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testInsertModePreservesWideLeadShiftedToMarginEdge() {
        let wideGlyphs = ["\u{1F680}", "\u{65E5}"]
        let margins = [(left: 1, right: 2), (left: 2, right: 2)]

        for columns in [3, 4] {
            for wideGlyph in wideGlyphs {
                for margin in margins {
                    let terminal = CmdyTerminal(cols: columns, rows: 2)
                    terminal.feed(text: wideGlyph)
                    terminal.feed(text: "\u{1B}[?69h")
                    terminal.feed(text: "\u{1B}[\(margin.left);\(margin.right)s")
                    terminal.feed([0x1B, 0x5B, 0x34, 0x68])
                    terminal.feed(text: "\u{1B}[1;1H")
                    terminal.feed(text: "X")

                    XCTAssertEqual(terminal.buffer.marginLeft, margin.left - 1)
                    XCTAssertEqual(terminal.buffer.marginRight, margin.right - 1)
                    var expected = Array(repeating: Cell(), count: columns)
                    expected[0] = Cell(scalar: UnicodeScalar("X").value)
                    expected[1] = Cell(
                        scalar: wideGlyph.unicodeScalars.first!.value, width: 2)
                    XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
                    XCTAssertEqual(
                        terminal.buffer.liveLine(1).cells,
                        Array(repeating: Cell(), count: columns))
                    XCTAssertEqual(terminal.buffer.x, 1)
                    XCTAssertEqual(terminal.buffer.y, 0)
                    XCTAssertFalse(terminal.buffer.wrapPending)
                    XCTAssertEqual(terminal.buffer.lineCount, 2)
                    XCTAssertEqual(terminal.buffer.yBase, 0)
                }
            }
        }
    }

    func testInsertModePreservesCellsBeyondHorizontalShiftBoundary() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let cases: [(
            suffix: String,
            leftMargin: Int,
            rightMargin: Int,
            thirdCell: Cell,
            fourthCell: Cell
        )] = [
            (" 0", 2, 3, Cell(scalar: 0, width: 0, attribute: stub),
             Cell(scalar: UnicodeScalar("0").value)),
            ("0", 2, 3, Cell(scalar: 0, width: 0, attribute: stub), Cell()),
            (" 0", 1, 2, Cell(scalar: UnicodeScalar(" ").value),
             Cell(scalar: UnicodeScalar("0").value)),
            (" 0", 2, 2, Cell(scalar: UnicodeScalar(" ").value),
             Cell(scalar: UnicodeScalar("0").value)),
        ]

        for wideGlyph in ["\u{1F680}", "\u{65E5}"] {
            for testCase in cases {
                let terminal = CmdyTerminal(cols: 4, rows: 1)
                terminal.feed(text: wideGlyph + testCase.suffix)
                terminal.feed(text: "\u{1B}[?69h")
                terminal.feed(text:
                    "\u{1B}[\(testCase.leftMargin);\(testCase.rightMargin)s")
                terminal.feed([0x1B, 0x5B, 0x34, 0x68])
                terminal.feed(text: "\u{1B}[1;1H")
                terminal.feed(text: "X")

                XCTAssertEqual(
                    terminal.buffer.liveLine(0).cells,
                    [
                        Cell(scalar: UnicodeScalar("X").value),
                        Cell(scalar: wideGlyph.unicodeScalars.first!.value, width: 2),
                        testCase.thirdCell,
                        testCase.fourthCell,
                    ])
                XCTAssertEqual(terminal.buffer.x, 1)
                XCTAssertEqual(terminal.buffer.y, 0)
                XCTAssertFalse(terminal.buffer.wrapPending)
                XCTAssertEqual(terminal.buffer.lineCount, 1)
                XCTAssertEqual(terminal.buffer.yBase, 0)
            }
        }
    }

    func testInsertModeShiftsExistingWideGlyphBeforeWriting() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed([
            0xE6, 0x97, 0xA5,
            0x1B, 0x5B, 0x34, 0x68,
            0x0D, 0x61,
        ])

        let line = terminal.buffer.liveLine(0)
        XCTAssertEqual(line[0], Cell(scalar: 0x61))
        XCTAssertEqual(line[1], Cell(scalar: 0x65E5, width: 2))
        XCTAssertEqual(
            line[2],
            Cell(
                scalar: 0, width: 0,
                attribute: CellAttribute(fg: .defaultColor, bg: .defaultInverted)))
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testInsertModeClearsWideLeadSplitAtRightBoundary() {
        let terminal = CmdyTerminal(cols: 2, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x34, 0x68])
        terminal.feed([0xE6, 0x97, 0xA5])
        terminal.feed([0x0D])
        terminal.feed([0x41])

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [
                Cell(scalar: 0x41),
                Cell.blank(attribute: CellAttribute(
                    fg: .defaultColor, bg: .defaultInverted)),
            ])
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testInsertModeDropsWideGlyphSplitAtPhysicalMarginEdge() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)

        for glyph in ["\u{1F1FA}\u{1F1F8}", "\u{65E5}"] {
            let terminal = CmdyTerminal(cols: 2, rows: 2)
            terminal.feed(text: "\u{1B}[4h\u{1B}[?69h" + glyph + "\r ")
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [
                    Cell(scalar: UnicodeScalar(" ").value),
                    Cell.blank(attribute: stub),
                ])
            XCTAssertEqual(terminal.buffer.x, 1)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }

        let customRightEdge = CmdyTerminal(cols: 4, rows: 2)
        customRightEdge.feed(text:
            "\u{1B}[4h\u{1B}[?69h\u{1B}[3;4s\u{1B}[1;3H\u{1F680}\r ")
        XCTAssertEqual(
            customRightEdge.buffer.liveLine(0).cells,
            [Cell(), Cell(), Cell(scalar: 0x20), Cell.blank(attribute: stub)])
        XCTAssertEqual(customRightEdge.buffer.x, 3)
        XCTAssertEqual(customRightEdge.buffer.y, 0)
        XCTAssertFalse(customRightEdge.buffer.wrapPending)

        let internalMargin = CmdyTerminal(cols: 5, rows: 2)
        internalMargin.feed(text:
            "\u{1B}[4h\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;2H\u{1F680}\r ")
        XCTAssertEqual(
            internalMargin.buffer.liveLine(0).cells,
            [
                Cell(),
                Cell(scalar: 0x20),
                Cell(scalar: 0x1F680, width: 2),
                Cell(),
                Cell(),
            ])
        XCTAssertEqual(internalMargin.buffer.x, 2)
        XCTAssertEqual(internalMargin.buffer.y, 0)
        XCTAssertFalse(internalMargin.buffer.wrapPending)

        let modeOff = CmdyTerminal(cols: 2, rows: 2)
        modeOff.feed(text: "\u{1B}[4h\u{1F680}\r ")
        XCTAssertEqual(
            modeOff.buffer.liveLine(0).cells,
            [Cell(scalar: 0x20), Cell.blank(attribute: stub)])
        XCTAssertEqual(modeOff.buffer.x, 1)
        XCTAssertEqual(modeOff.buffer.y, 0)
        XCTAssertFalse(modeOff.buffer.wrapPending)
    }

    func testInsertModeDropsWideGlyphAfterCumulativePhysicalEdgeDisplacement() {
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        let continuation = Cell(scalar: 0, width: 0, attribute: stub)
        func assertCursor(_ terminal: CmdyTerminal, _ column: Int) {
            XCTAssertEqual(terminal.buffer.x, column)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertFalse(terminal.buffer.wrapPending)
            XCTAssertEqual(
                terminal.buffer.liveLine(1).cells,
                Array(repeating: Cell(), count: terminal.buffer.cols))
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }

        let wideShift = CmdyTerminal(cols: 3, rows: 2)
        wideShift.feed(text: "\u{1B}[4h\u{1B}[?69h\u{1F1FA}\u{1F1F8}\r\u{1F680}")
        XCTAssertEqual(
            wideShift.buffer.liveLine(0).cells,
            [Cell(scalar: 0x1F680, width: 2), continuation,
             Cell.blank(attribute: stub)])
        assertCursor(wideShift, 2)

        let narrowShift = CmdyTerminal(cols: 3, rows: 2)
        narrowShift.feed(text: "\u{1B}[4h\u{1B}[?69h\u{65E5}\rAA")
        XCTAssertEqual(
            narrowShift.buffer.liveLine(0).cells,
            [Cell(scalar: 0x41), Cell(scalar: 0x41), Cell.blank(attribute: stub)])
        assertCursor(narrowShift, 2)

        let mixedShift = CmdyTerminal(cols: 4, rows: 2)
        mixedShift.feed(text:
            "\u{1B}[4h\u{1B}[?69h\u{1F469}\u{200D}\u{1F4BB}\r\u{1F680}A")
        XCTAssertEqual(
            mixedShift.buffer.liveLine(0).cells,
            [Cell(scalar: 0x1F680, width: 2), continuation,
             Cell(scalar: 0x41), Cell.blank(attribute: stub)])
        assertCursor(mixedShift, 3)

        let fourColumnShift = CmdyTerminal(cols: 5, rows: 2)
        fourColumnShift.feed(text:
            "\u{1B}[4h\u{1B}[?69h\u{2764}\u{FE0F}\r\u{1F680}\u{1F680}")
        XCTAssertEqual(
            fourColumnShift.buffer.liveLine(0).cells,
            [Cell(scalar: 0x1F680, width: 2), continuation,
             Cell(scalar: 0x1F680, width: 2), continuation,
             Cell.blank(attribute: stub)])
        assertCursor(fourColumnShift, 4)

        let customEdge = CmdyTerminal(cols: 5, rows: 2)
        customEdge.feed(text:
            "\u{1B}[4h\u{1B}[?69h\u{1B}[3;5s\u{1B}[1;3H#\u{FE0F}\u{20E3}\r\u{1F680}")
        XCTAssertEqual(
            customEdge.buffer.liveLine(0).cells,
            [Cell(), Cell(), Cell(scalar: 0x1F680, width: 2), continuation,
             Cell.blank(attribute: stub)])
        assertCursor(customEdge, 4)

        let internalRoom = CmdyTerminal(cols: 6, rows: 2)
        internalRoom.feed(text:
            "\u{1B}[4h\u{1B}[?69h\u{1B}[3;5s\u{1B}[1;3H#\u{FE0F}\u{20E3}\r\u{1F680}")
        XCTAssertEqual(
            internalRoom.buffer.liveLine(0).cells,
            [
                Cell(), Cell(), Cell(scalar: 0x1F680, width: 2), continuation,
                Cell(scalar: 0x23, clusterExtras: [0xFE0F, 0x20E3], width: 2),
                Cell(),
            ])
        assertCursor(internalRoom, 4)
    }

    func testInsertModeSanitizesWideLeadShiftedOutsideActiveMargin() {
        let terminal = CmdyTerminal(cols: 10, rows: 3)
        terminal.feed(text:
            "\u{1B}[4hABCDEF\u{65E5}Z" +
            "\u{1B}[?69h\u{1B}[2;9s" +
            "\u{1B}[1;4H\u{65E5}\u{1B}[2L" +
            "\u{1B}[2;1H0\u{1B}6" +
            "\u{1B}[2;9H\u{65E5}")

        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        XCTAssertEqual(
            terminal.buffer.liveLine(2)[9],
            Cell.blank(attribute: stub))
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.y, 2)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testInsertModePrintsOrdinaryScalarAfterWideJoinerCluster() {
        let terminal = CmdyTerminal(cols: 2, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x34, 0x68])
        terminal.feed([0xE6, 0x97, 0xA5])
        terminal.feed([0xE2, 0x80, 0x8D])
        terminal.feed([0x61])

        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2))
        XCTAssertEqual(terminal.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell(scalar: 0x61))
        XCTAssertEqual(terminal.buffer.liveLine(1)[1], Cell())
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testCRLFINDAndRICursorTransitions() {
        let cr = CmdyTerminal(cols: 8, rows: 5)
        cr.marginMode = true
        cr.buffer.marginLeft = 2
        cr.buffer.marginRight = 6
        cr.buffer.x = 5
        cr.executeControl(0x0D)
        XCTAssertEqual(cr.buffer.x, 2)
        cr.buffer.x = 1
        cr.executeControl(0x0D)
        XCTAssertEqual(cr.buffer.x, 0)

        let lf = CmdyTerminal(cols: 8, rows: 5)
        lf.buffer.x = 4
        lf.buffer.y = 1
        lf.executeControl(0x0A)
        XCTAssertEqual(lf.buffer.x, 4)
        XCTAssertEqual(lf.buffer.y, 2)
        lf.lineFeedMode = true
        lf.executeControl(0x0A)
        XCTAssertEqual(lf.buffer.x, 0)
        XCTAssertEqual(lf.buffer.y, 3)

        let index = CmdyTerminal(cols: 8, rows: 5)
        index.buffer.scrollTop = 1
        index.buffer.scrollBottom = 3
        index.buffer.x = 6
        index.buffer.y = 2
        index.indexLineFeed()
        XCTAssertEqual(index.buffer.x, 6)
        XCTAssertEqual(index.buffer.y, 3)

        let reverse = CmdyTerminal(cols: 4, rows: 4)
        reverse.buffer.scrollTop = 1
        reverse.buffer.scrollBottom = 3
        for row in 0..<4 { seedRow(reverse, row: row, scalars: [UInt32(65 + row), 0, 0, 0]) }
        reverse.buffer.x = 2
        reverse.buffer.y = 1
        reverse.reverseLineFeed()
        XCTAssertEqual(reverse.buffer.x, 2)
        XCTAssertEqual(reverse.buffer.y, 1)
        XCTAssertEqual(reverse.buffer.liveLine(1)[0].scalar, 0)
        XCTAssertEqual(reverse.buffer.liveLine(2)[0].scalar, 66)
        XCTAssertEqual(reverse.buffer.liveLine(3)[0].scalar, 67)
    }

    func testCUFClearsPendingWrapBeforeUnicodeASCIIAndWideFollowers() {
        let unicode = CmdyTerminal(cols: 1, rows: 2)
        unicode.feed(text: "A\u{1B}[C\u{E9}")
        XCTAssertEqual(unicode.buffer.liveLine(0)[0], Cell(scalar: 0xE9))
        XCTAssertEqual(unicode.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(unicode.buffer.x, 1)
        XCTAssertEqual(unicode.buffer.y, 0)
        XCTAssertTrue(unicode.buffer.wrapPending)
        XCTAssertEqual(unicode.buffer.lineCount, 2)
        XCTAssertEqual(unicode.buffer.yBase, 0)

        let ascii = CmdyTerminal(cols: 1, rows: 2)
        ascii.feed(text: "A\u{1B}[CB")
        XCTAssertEqual(ascii.buffer.liveLine(0)[0], Cell(scalar: 0x42))
        XCTAssertEqual(ascii.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(ascii.buffer.x, 1)
        XCTAssertEqual(ascii.buffer.y, 0)
        XCTAssertTrue(ascii.buffer.wrapPending)
        XCTAssertEqual(ascii.buffer.lineCount, 2)
        XCTAssertEqual(ascii.buffer.yBase, 0)

        let wide = CmdyTerminal(cols: 1, rows: 2)
        wide.feed(text: "A\u{1B}[C\u{1F680}")
        XCTAssertEqual(wide.buffer.liveLine(0)[0], Cell(scalar: 0x41))
        XCTAssertEqual(wide.buffer.liveLine(1)[0], Cell(scalar: 0x1F680, width: 2))
        XCTAssertEqual(wide.buffer.x, 1)
        XCTAssertEqual(wide.buffer.y, 1)
        XCTAssertTrue(wide.buffer.wrapPending)
        XCTAssertEqual(wide.buffer.lineCount, 2)
        XCTAssertEqual(wide.buffer.yBase, 0)
    }

    func testCUFEdgeStateAcrossMarginsCombiningAndNoWrap() {
        let combining = CmdyTerminal(cols: 1, rows: 2)
        combining.feed(text: "A\u{1B}[C\u{301}")
        XCTAssertEqual(
            combining.buffer.liveLine(0)[0],
            Cell(scalar: 0x41, clusterExtras: [0x301]))
        XCTAssertEqual(combining.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(combining.buffer.x, 0)
        XCTAssertEqual(combining.buffer.y, 0)

        let internalPending = CmdyTerminal(cols: 3, rows: 2)
        internalPending.feed(text:
            "\u{1B}[?69h\u{1B}[1;2s\u{1B}[1;2HA\u{1B}[C\u{E9}")
        XCTAssertEqual(
            internalPending.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0x41), Cell()])
        XCTAssertEqual(
            internalPending.buffer.liveLine(1).cells,
            [Cell(scalar: 0xE9), Cell(), Cell()])
        XCTAssertEqual(internalPending.buffer.x, 1)
        XCTAssertEqual(internalPending.buffer.y, 1)

        let physicalEdgeWide = CmdyTerminal(cols: 3, rows: 2)
        physicalEdgeWide.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;3HA\u{1B}[C\u{65E5}")
        XCTAssertEqual(
            physicalEdgeWide.buffer.liveLine(0).cells,
            [Cell(), Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(
            physicalEdgeWide.buffer.liveLine(1).cells,
            [Cell(), Cell(scalar: 0x65E5, width: 2),
             Cell(scalar: 0, width: 0,
                  attribute: CellAttribute(fg: .defaultColor, bg: .defaultInverted))])
        XCTAssertEqual(physicalEdgeWide.buffer.x, 3)
        XCTAssertEqual(physicalEdgeWide.buffer.y, 1)

        let noWrapEmoji = CmdyTerminal(cols: 1, rows: 2)
        noWrapEmoji.feed(text:
            "\u{1B}[?7lA\u{1B}[C\u{1F469}\u{200D}\u{1F4BB}")
        XCTAssertEqual(
            noWrapEmoji.buffer.liveLine(0)[0],
            Cell(scalar: 0x41, clusterExtras: [0x200D]))
        XCTAssertEqual(noWrapEmoji.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(noWrapEmoji.buffer.x, 0)
        XCTAssertEqual(noWrapEmoji.buffer.y, 0)

        let internalNoWrap = CmdyTerminal(cols: 3, rows: 2)
        internalNoWrap.feed(text:
            "\u{1B}[?69h\u{1B}[1;2s\u{1B}[?7l" +
            "\u{1B}[1;2HA\u{1B}[C\u{E9}")
        XCTAssertEqual(
            internalNoWrap.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0xE9), Cell()])
        XCTAssertEqual(internalNoWrap.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell()])
        XCTAssertEqual(internalNoWrap.buffer.x, 2)
        XCTAssertEqual(internalNoWrap.buffer.y, 0)

        for terminal in [combining, internalPending, physicalEdgeWide,
                         noWrapEmoji, internalNoWrap] {
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testCHTClearsPendingWhenPhysicalScreenCanTraverse() {
        for count in [0, 1, 2, 3] {
            let terminal = CmdyTerminal(cols: 2, rows: 2)
            terminal.feed(text:
                "\u{1B}[1;2HA\u{1B}[\(count)I\u{00E9}")
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [Cell(), Cell(scalar: 0xE9)],
                "count=\(count)")
            XCTAssertEqual(terminal.buffer.liveLine(1).cells,
                           [Cell(), Cell()], "count=\(count)")
            XCTAssertEqual(terminal.buffer.x, 2, "count=\(count)")
            XCTAssertEqual(terminal.buffer.y, 0, "count=\(count)")
            XCTAssertTrue(terminal.buffer.wrapPending, "count=\(count)")
        }

        let active = CmdyTerminal(cols: 3, rows: 2)
        active.feed(text:
            "\u{1B}[?69h\u{1B}[1;2s\u{1B}[1;2HA\u{1B}[2I\u{00E9}")
        XCTAssertEqual(active.buffer.liveLine(0).cells,
                       [Cell(), Cell(scalar: 0xE9), Cell()])
        XCTAssertEqual(active.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell()])
        XCTAssertEqual(active.buffer.x, 2)
        XCTAssertEqual(active.buffer.y, 0)

        let hidden = CmdyTerminal(cols: 3, rows: 2)
        hidden.feed(text:
            "\u{1B}[?69h\u{1B}[1;2s\u{1B}[?69l" +
            "\u{1B}[1;3HA\u{1B}[2I\u{00E9}")
        XCTAssertEqual(hidden.buffer.liveLine(0).cells,
                       [Cell(), Cell(), Cell(scalar: 0xE9)])
        XCTAssertEqual(hidden.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell()])
        XCTAssertEqual(hidden.buffer.x, 3)
        XCTAssertEqual(hidden.buffer.y, 0)

        let oneColumn = CmdyTerminal(cols: 1, rows: 2)
        oneColumn.feed(text: "A\u{1B}[I\u{00E9}")
        XCTAssertEqual(oneColumn.buffer.liveLine(0).cells,
                       [Cell(scalar: 0x41)])
        XCTAssertEqual(oneColumn.buffer.liveLine(1).cells,
                       [Cell(scalar: 0xE9)])
        XCTAssertEqual(oneColumn.buffer.x, 1)
        XCTAssertEqual(oneColumn.buffer.y, 1)
        XCTAssertTrue(oneColumn.buffer.wrapPending)
    }

    func testKittyDisplayNormalizesPendingPrintStateOnlyAfterSuccess() {
        let display = "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"

        for keepsAutowrap in [false, true] {
            let pending = CmdyTerminal(cols: 2, rows: 2)
            pending.feed(text: "AA" + display +
                         (keepsAutowrap ? "" : "\u{1B}[?7l") + " ")
            XCTAssertEqual(
                pending.buffer.liveLine(0).cells,
                [Cell(scalar: 0x41), Cell(scalar: 0x41)])
            XCTAssertEqual(
                pending.buffer.liveLine(1).cells,
                [Cell(scalar: 0x20), Cell()])
            XCTAssertEqual(pending.buffer.x, 1)
            XCTAssertEqual(pending.buffer.y, 1)
            XCTAssertEqual(pending.buffer.lineCount, 2)
            XCTAssertEqual(pending.buffer.yBase, 0)
        }

        let settled = CmdyTerminal(cols: 2, rows: 2)
        settled.feed(text: "A" + display + "\u{1B}[?7l ")
        XCTAssertEqual(
            settled.buffer.liveLine(0).cells,
            [Cell(scalar: 0x41), Cell()])
        XCTAssertEqual(
            settled.buffer.liveLine(1).cells,
            [Cell(scalar: 0x20), Cell()])
        XCTAssertEqual(settled.buffer.x, 1)
        XCTAssertEqual(settled.buffer.y, 1)

        let deletion = CmdyTerminal(cols: 2, rows: 2)
        deletion.feed(text:
            "AA\u{1B}_Ga=d,d=i,i=3,q=2;\u{1B}\\\u{1B}[?7l ")
        XCTAssertEqual(
            deletion.buffer.liveLine(0).cells,
            [Cell(scalar: 0x41), Cell(scalar: 0x20)])
        XCTAssertEqual(deletion.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(deletion.buffer.x, 2)
        XCTAssertEqual(deletion.buffer.y, 0)

        for (follower, expectedLine, expectedCursor) in [
            ("\u{E9}", [Cell(scalar: 0xE9), Cell()], (1, 1)),
            ("\u{65E5}",
             [Cell(scalar: 0x65E5, width: 2),
              Cell(scalar: 0, width: 0,
                   attribute: CellAttribute(fg: .defaultColor, bg: .defaultInverted))],
             (2, 1)),
        ] {
            for disablesAutowrap in [false, true] {
                let terminal = CmdyTerminal(cols: 2, rows: 2)
                terminal.feed(text: "\u{1B}[1;2HA" + display +
                              (disablesAutowrap ? "\u{1B}[?7l" : "") + follower)
                XCTAssertEqual(
                    terminal.buffer.liveLine(0).cells,
                    [Cell(), Cell(scalar: 0x41)])
                XCTAssertEqual(terminal.buffer.liveLine(1).cells, expectedLine)
                XCTAssertEqual(terminal.buffer.x, expectedCursor.0)
                XCTAssertEqual(terminal.buffer.y, expectedCursor.1)
                XCTAssertEqual(terminal.buffer.lineCount, 2)
                XCTAssertEqual(terminal.buffer.yBase, 0)
            }
        }

        let preload = "\u{1B}_Ga=t,f=32,s=1,v=1,i=21,q=2;/wAA/w==\u{1B}\\"
        let place = "\u{1B}_Ga=p,i=21,p=1,x=0,y=0,c=1,r=1,q=2;\u{1B}\\"
        let placed = CmdyTerminal(cols: 2, rows: 2)
        placed.feed(text: preload + "\u{1B}[1;2HA" + place + "\u{E9}")
        XCTAssertEqual(
            placed.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(
            placed.buffer.liveLine(1).cells,
            [Cell(scalar: 0xE9), Cell()])
        XCTAssertEqual(placed.buffer.x, 1)
        XCTAssertEqual(placed.buffer.y, 1)

        let combining = CmdyTerminal(cols: 2, rows: 2)
        combining.feed(text: "\u{1B}[1;2HA" + display + "\u{301}")
        XCTAssertEqual(
            combining.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0x41, clusterExtras: [0x301])])
        XCTAssertEqual(combining.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(combining.buffer.x, 0)
        XCTAssertEqual(combining.buffer.y, 1)

        for inertControl in [
            "\u{1B}_Ga=q,f=32,s=1,v=1,i=23,q=2;/wAA/w==\u{1B}\\",
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=22,q=2;%%%\u{1B}\\",
        ] {
            let terminal = CmdyTerminal(cols: 2, rows: 2)
            terminal.feed(text: "\u{1B}[1;2HA" + inertControl)
            XCTAssertEqual(
                terminal.buffer.liveLine(0).cells,
                [Cell(), Cell(scalar: 0x41)])
            XCTAssertEqual(terminal.buffer.liveLine(1).cells, [Cell(), Cell()])
            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertTrue(terminal.buffer.wrapPending)
        }

        let parked = CmdyTerminal(cols: 2, rows: 2)
        parked.feed(text:
            "\u{1B}[?7l\u{1B}[1;2HA" + display + " ")
        XCTAssertEqual(
            parked.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(
            parked.buffer.liveLine(1).cells,
            [Cell(scalar: 0x20), Cell()])
        XCTAssertEqual(parked.buffer.x, 1)
        XCTAssertEqual(parked.buffer.y, 1)

        for terminal in [settled, deletion, placed, combining, parked] {
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testKittySuccessfulPlacementUsesVerticalLineMotionRules() {
        let transmit = "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let preload = "\u{1B}_Ga=t,f=32,s=1,v=1,i=31,q=2;/wAA/w==\u{1B}\\"
        let display = "\u{1B}_Ga=p,i=31,p=1,x=0,y=0,c=1,r=1,q=2;\u{1B}\\"

        for stream in [transmit, preload + display] {
            let terminal = CmdyTerminal(cols: 1, rows: 1)
            terminal.feed(text: stream)
            assertPlainRows(terminal, [[0], [0]])
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 1)
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 1)
        }

        for parksAtEdge in [false, true] {
            let terminal = CmdyTerminal(cols: 1, rows: 3)
            terminal.feed(text:
                "\u{1B}[1;2r\u{1B}[?7" + (parksAtEdge ? "l" : "h") +
                "\u{1B}[2;1HA" + transmit)
            assertPlainRows(terminal, [[0], [0x41], [0]])
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, 1)
            XCTAssertEqual(terminal.buffer.lineCount, 3)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }

        let fourRows = CmdyTerminal(cols: 1, rows: 4)
        fourRows.feed(text:
            "\u{1B}[?7l\u{1B}[1;1HA\u{1B}[2;1HB\u{1B}[3;1HC\u{1B}[4;1HD" +
            "\u{1B}[2;3r\u{1B}[?7h\u{1B}[3;1H" + transmit)
        assertPlainRows(fourRows, [[0x41], [0x43], [0], [0x44]])
        XCTAssertEqual(fourRows.buffer.x, 0)
        XCTAssertEqual(fourRows.buffer.y, 2)
        XCTAssertEqual(fourRows.buffer.lineCount, 4)
        XCTAssertEqual(fourRows.buffer.yBase, 0)

        let threeRows = CmdyTerminal(cols: 1, rows: 3)
        threeRows.feed(text:
            "\u{1B}[?7l\u{1B}[1;1HA\u{1B}[2;1HB\u{1B}[3;1HC" +
            "\u{1B}[2;3r\u{1B}[?7h\u{1B}[3;1H" + transmit)
        assertPlainRows(threeRows, [[0x41], [0x43], [0]])
        XCTAssertEqual(threeRows.buffer.x, 0)
        XCTAssertEqual(threeRows.buffer.y, 2)
        XCTAssertEqual(threeRows.buffer.lineCount, 3)
        XCTAssertEqual(threeRows.buffer.yBase, 0)

        let blankRegion = CmdyTerminal(cols: 1, rows: 4)
        blankRegion.feed(text: "\u{1B}[2;3r\u{1B}[?7h\u{1B}[3;1H" + transmit)
        assertPlainRows(blankRegion, [[0], [0], [0], [0]])
        XCTAssertEqual(blankRegion.buffer.x, 0)
        XCTAssertEqual(blankRegion.buffer.y, 2)
        XCTAssertEqual(blankRegion.buffer.lineCount, 4)
        XCTAssertEqual(blankRegion.buffer.yBase, 0)

        let alternate = CmdyTerminal(cols: 1, rows: 1)
        alternate.feed(text: "\u{1B}[?1049h" + transmit)
        assertPlainRows(alternate, [[0], [0]])
        XCTAssertEqual(alternate.buffer.x, 0)
        XCTAssertEqual(alternate.buffer.y, 0)
        XCTAssertEqual(alternate.buffer.yBase + alternate.buffer.y, 1)
        XCTAssertEqual(alternate.buffer.lineCount, 2)
        XCTAssertEqual(alternate.buffer.yBase, 1)
    }

    func testKittySuccessfulPlacementUsesStoredHorizontalGateAndSlice() {
        let transmit = "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let markers = "\u{1B}[?7l\u{1B}[1;1HAAA\u{1B}[2;1HBBB\u{1B}[3;1HCCC"
        let regionAndMargin = "\u{1B}[2;3r\u{1B}[?69h\u{1B}[2;2s"

        let activeInside = CmdyTerminal(cols: 3, rows: 3)
        activeInside.feed(text:
            markers + regionAndMargin + "\u{1B}[?7h\u{1B}[3;2H" + transmit)
        assertPlainRows(activeInside, [
            [0x41, 0x41, 0x41],
            [0x42, 0x43, 0x42],
            [0x43, 0, 0x43],
        ])
        XCTAssertEqual(activeInside.buffer.x, 0)
        XCTAssertEqual(activeInside.buffer.y, 2)
        XCTAssertEqual(activeInside.buffer.lineCount, 3)
        XCTAssertEqual(activeInside.buffer.yBase, 0)

        let activeOutside = CmdyTerminal(cols: 3, rows: 3)
        activeOutside.feed(text:
            markers + regionAndMargin + "\u{1B}[?7h\u{1B}[3;1H" + transmit)
        assertPlainRows(activeOutside, [
            [0x41, 0x41, 0x41],
            [0x42, 0x42, 0x42],
            [0x43, 0x43, 0x43],
        ])
        XCTAssertEqual(activeOutside.buffer.x, 0)
        XCTAssertEqual(activeOutside.buffer.y, 2)

        let hiddenInside = CmdyTerminal(cols: 3, rows: 3)
        hiddenInside.feed(text:
            markers + regionAndMargin + "\u{1B}[?69l\u{1B}[?7h\u{1B}[3;2H" +
            transmit)
        assertPlainRows(hiddenInside, [
            [0x41, 0x41, 0x41],
            [0x43, 0x43, 0x43],
            [0, 0, 0],
        ])
        XCTAssertEqual(hiddenInside.buffer.x, 0)
        XCTAssertEqual(hiddenInside.buffer.y, 2)

        let hiddenOutside = CmdyTerminal(cols: 3, rows: 3)
        hiddenOutside.feed(text:
            markers + regionAndMargin + "\u{1B}[?69l\u{1B}[?7h\u{1B}[3;1H" +
            transmit)
        assertPlainRows(hiddenOutside, [
            [0x41, 0x41, 0x41],
            [0x42, 0x42, 0x42],
            [0x43, 0x43, 0x43],
        ])
        XCTAssertEqual(hiddenOutside.buffer.x, 0)
        XCTAssertEqual(hiddenOutside.buffer.y, 2)
    }

    func testKittyPartialSliceDisplayPreservesPrewrappedReflowBoundary() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let transmitOnly =
            "\u{1B}_Ga=t,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let setup =
            "\u{1B}[?6h\u{1B}[2I\u{65E5}\u{1B}[2;5r\tA\u{301}" +
            "\u{1B}]133;A\u{7}\u{1B}[?69h\u{1B}[2;9s\u{E9}\n"

        let placed = CmdyTerminal(cols: 6, rows: 4)
        placed.feed(text: setup + display)
        placed.resize(cols: 1, rows: 1)
        XCTAssertEqual(placed.buffer.lineCount, 4)
        XCTAssertEqual(placed.buffer.yBase + placed.buffer.y, 3)
        XCTAssertEqual(placed.blocks.blocks.map(\.promptRow), [1])
        XCTAssertEqual(placed.blocks.blocks.map(\.commandRow), [1])
        XCTAssertEqual(placed.scrollbackLineText(row: 1), "\u{65E5}\u{E9}")

        let widePremarkerSetup =
            "\u{1B}[?6h\u{1B}[2I\u{65E5}\u{1B}[2;5r\t\u{65E5}" +
            "\u{1B}]133;A\u{7}\u{1B}[?69h\u{1B}[2;9s\u{E9}\n"
        let widePremarker = CmdyTerminal(cols: 6, rows: 4)
        widePremarker.feed(text: widePremarkerSetup + display)
        widePremarker.resize(cols: 1, rows: 1)
        XCTAssertEqual(widePremarker.buffer.lineCount, 5)
        XCTAssertEqual(widePremarker.buffer.yBase + widePremarker.buffer.y, 4)
        XCTAssertEqual(widePremarker.blocks.blocks.map(\.promptRow), [3])
        XCTAssertEqual(widePremarker.scrollbackLineText(row: 1), "\u{65E5} ")
        XCTAssertEqual(widePremarker.scrollbackLineText(row: 2), "\u{E9}")
        XCTAssertEqual(widePremarker.scrollbackLineText(row: 3), "\u{65E5} ")

        let transmitted = CmdyTerminal(cols: 6, rows: 4)
        transmitted.feed(text: setup + transmitOnly)
        transmitted.resize(cols: 1, rows: 1)
        XCTAssertEqual(transmitted.buffer.lineCount, 5)
        XCTAssertEqual(transmitted.buffer.yBase + transmitted.buffer.y, 4)
        XCTAssertEqual(transmitted.blocks.blocks.map(\.promptRow), [0])
        XCTAssertEqual(transmitted.blocks.blocks.map(\.commandRow), [0])
    }

    func testKittyPartialSliceDisplayHardensDisconnectedPrewrappedRow() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 5, rows: 7)
        terminal.feed(text:
            "AAAAAB" + String(repeating: "\n", count: 5) +
            "\u{1B}[?69h\u{1B}[2;4s" + display)

        XCTAssertEqual(terminal.activeMarginReflowBoundaries.count, 1)
        XCTAssertTrue(terminal.activeMarginReflowBoundaries.contains {
            $0.line === terminal.buffer.liveLine(1)
        })
        XCTAssertTrue(terminal.kittyDisplayReflowClaims.isEmpty)

        terminal.resize(cols: 2, rows: 1)
        XCTAssertEqual(terminal.buffer.lineCount, 9)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 8)
    }

    func testKittyDisplayPreservesEarlierWrappedDestinationBoundaryOnReflow() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 4, rows: 5)
        terminal.feed(text:
            "AAAAB\u{1B}]133;A\u{7}" +
            "\u{1B}[?69h\u{1B}[2;4s\u{1B}[3;4H Z\n" + display)

        XCTAssertTrue(terminal.activeMarginReflowBoundaries.contains {
            $0.line === terminal.buffer.liveLine(1)
        })

        terminal.resize(cols: 2, rows: 3)
        XCTAssertEqual(terminal.buffer.lineCount, 6)
        XCTAssertEqual(terminal.blocks.blocks.map(\.promptRow), [1])
        XCTAssertEqual(terminal.scrollbackLineText(row: 0), "A")
        XCTAssertEqual(terminal.scrollbackLineText(row: 1), "B")
        XCTAssertEqual(terminal.scrollbackLineText(row: 2), "  ")
        XCTAssertEqual(terminal.scrollbackLineText(row: 3), " Z")
    }

    func testKittyDisplayPreservesNewlyPopulatedWrappedBoundaryOnReflow() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 5, rows: 5)
        terminal.feed(text:
            "\u{1B}[?69h\n\u{1B}[1;4s \u{65E5}\u{65E5}\r " +
            "\u{65E5}\u{1B}[2M\u{65E5}\n\u{1B}]133;A\u{7}" + display)

        let lines = terminal.buffer.lines
        XCTAssertEqual(terminal.kittyDisplayReflowBoundaries.compactMap {
            boundary in lines.firstIndex { $0 === boundary.line }
        }.sorted(), [1, 2, 3])

        terminal.resize(cols: 1, rows: 1)
        XCTAssertEqual(terminal.buffer.lineCount, 5)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 4)
        XCTAssertEqual(terminal.blocks.blocks.map(\.promptRow), [4])
        XCTAssertEqual(terminal.blocks.blocks.map(\.commandRow), [4])
    }

    func testKittyPartialSliceDisplayPreservesVirtualLineGeneration() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 5, rows: 3)
        terminal.feed(text:
            "\u{1B}[48:5:99m\u{1B}[2B\n" +
            "\u{1B}[?69h\u{1B}[?45h\n\n" +
            "\u{1B}[1;4s\u{1B}[2L" + display +
            "\u{8}\u{1B}[2M ")

        let expectedBackground = CellColor.ansi256(99)
        XCTAssertEqual(
            terminal.buffer.liveLine(1).cells.map(\.attribute.bg),
            Array(repeating: expectedBackground, count: 5))
        XCTAssertEqual(terminal.buffer.liveLine(1)[3].scalar, 0x20)
    }

    func testKittyPartialSliceDisplayClaimsOnlyTheExposedBottomRank() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let retransmitOnly =
            "\u{1B}_Ga=t,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let setup =
            "\u{1B}[2;6HA\u{1B}[?69h\u{1B}[2se\n" + display

        func makeTerminal(markerRow: Int, cleanup: String = "") -> CmdyTerminal {
            let terminal = CmdyTerminal(cols: 6, rows: 4)
            terminal.feed(text:
                setup + cleanup +
                "\u{1B}[\(markerRow);1H\u{1B}]133;A\u{7}")
            return terminal
        }

        let generation = makeTerminal(markerRow: 4)
        XCTAssertTrue(generation.activeMarginReflowBoundaries.isEmpty)
        XCTAssertEqual(generation.kittyDisplayReflowClaims.count, 1)
        XCTAssertTrue(
            generation.kittyDisplayReflowClaims[0].line ===
                generation.buffer.liveLine(3))
        XCTAssertTrue(generation.kittyDisplayReflowBoundaries.contains {
            $0.line === generation.buffer.liveLine(2)
        })
        XCTAssertNil(generation.buffer.liveLine(2).images)
        XCTAssertEqual(generation.buffer.liveLine(3).images?.count, 1)

        generation.resize(cols: 2, rows: 4)
        XCTAssertEqual(generation.buffer.lineCount, 6)
        XCTAssertEqual(generation.blocks.blocks.map(\.promptRow), [5])
        XCTAssertEqual(generation.buffer.yBase + generation.buffer.y, 5)

        let upperMarker = makeTerminal(markerRow: 2)
        upperMarker.resize(cols: 2, rows: 4)
        XCTAssertEqual(upperMarker.buffer.lineCount, 4)
        XCTAssertEqual(upperMarker.blocks.blocks.map(\.promptRow), [3])
        XCTAssertEqual(upperMarker.buffer.yBase + upperMarker.buffer.y, 3)

        let cleanedBottom = makeTerminal(
            markerRow: 4, cleanup: retransmitOnly)
        XCTAssertEqual(cleanedBottom.kittyDisplayReflowClaims.count, 1)
        XCTAssertTrue(cleanedBottom.kittyDisplayReflowBoundaries.contains {
            $0.line === cleanedBottom.buffer.liveLine(2)
        })
        XCTAssertNil(cleanedBottom.buffer.liveLine(3).images)
        cleanedBottom.resize(cols: 2, rows: 4)
        XCTAssertEqual(cleanedBottom.buffer.lineCount, 6)
        XCTAssertEqual(cleanedBottom.blocks.blocks.map(\.promptRow), [5])

        let cleanedUpper = makeTerminal(
            markerRow: 2, cleanup: retransmitOnly)
        cleanedUpper.resize(cols: 2, rows: 4)
        XCTAssertEqual(cleanedUpper.buffer.lineCount, 4)
        XCTAssertEqual(cleanedUpper.blocks.blocks.map(\.promptRow), [3])

        // A height-only trim hides the placement generation without retiring
        // it.  A later width reflow must reactivate the same hidden topology.
        for (markerRow, heightOnlyLines, reflowedLines) in [
            (1, 2, 4), (2, 2, 4), (3, 3, 5), (4, 4, 6),
        ] {
            let sequential = makeTerminal(markerRow: markerRow)
            sequential.resize(cols: 6, rows: 1)
            XCTAssertEqual(sequential.buffer.lineCount, heightOnlyLines)
            sequential.resize(cols: 2, rows: 1)
            XCTAssertEqual(sequential.buffer.lineCount, reflowedLines)
        }

        // DL displaces the exposed-bottom generation.  Its replacement blank
        // is ordinary and must not resurrect the claim on a later reflow.
        let deletedGeneration = CmdyTerminal(cols: 6, rows: 4)
        deletedGeneration.feed(text:
            setup + "\u{1B}[2;2H\u{1B}[M" +
            "\u{1B}[1;1H\u{1B}]133;A\u{7}")
        deletedGeneration.resize(cols: 6, rows: 1)
        XCTAssertEqual(deletedGeneration.buffer.lineCount, 1)
        deletedGeneration.resize(cols: 2, rows: 1)
        XCTAssertEqual(deletedGeneration.buffer.lineCount, 3)
    }

    func testKittyPartialSliceClaimDoesNotPinCollapsedScrollbackRank() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 3, rows: 2)
        terminal.feed(text:
            "\u{1B}[?69h\u{65E5}\u{65E5}\u{65E5}\n\u{1B}[2;3s" +
            display)

        XCTAssertEqual(terminal.buffer.lineCount, 4)
        XCTAssertEqual(terminal.kittyDisplayReflowClaims.count, 1)
        terminal.resize(cols: 2, rows: 1)
        XCTAssertEqual(terminal.buffer.lineCount, 3)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 2)
        XCTAssertEqual(terminal.scrollbackLineText(row: 0), "\u{65E5}\u{65E5}")
        XCTAssertEqual(terminal.scrollbackLineText(row: 1), "\u{65E5} ")
        XCTAssertEqual(terminal.scrollbackLineText(row: 2), "")
    }

    func testKittyPartialSliceBoundarySkipsClippedWrappedLiveTop() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 4, rows: 3)
        terminal.feed(text:
            "A\u{65E5}A\u{65E5}\u{1B}[?69h" +
            "\u{65E5}\u{65E5}\u{65E5}\u{65E5}\n" +
            "\u{1B}[2r\u{1B}[2s\n\t\u{65E5}" + display)

        let lines = terminal.buffer.lines
        XCTAssertEqual(terminal.buffer.yBase, 2)
        XCTAssertEqual(terminal.kittyDisplayReflowBoundaries.compactMap {
            boundary in lines.firstIndex { $0 === boundary.line }
        }, [3])
        XCTAssertEqual(terminal.kittyDisplayReflowClaims.compactMap {
            claim in lines.firstIndex { $0 === claim.line }
        }, [4])

        terminal.resize(cols: 6, rows: 1)
        XCTAssertEqual(terminal.buffer.lineCount, 4)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 3)
        XCTAssertEqual(terminal.scrollbackLineText(row: 0),
                       "A\u{65E5} A\u{65E5} ")
        XCTAssertEqual(terminal.scrollbackLineText(row: 1),
                       "\u{65E5}\u{65E5} \u{65E5} ")
        XCTAssertEqual(terminal.scrollbackLineText(row: 2),
                       "\u{65E5}\u{65E5} ")
        XCTAssertEqual(terminal.scrollbackLineText(row: 3), "")
    }

    func testKittyPartialSliceDisplayPreservesWrappedLiveTopRankCreatedBeforeMargins() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 7, rows: 5)
        terminal.feed(text:
            String(repeating: "A", count: 36) +
            "\u{1B}[?69h\u{1B}[1;2s" + display)

        let lines = terminal.buffer.lines
        XCTAssertEqual(terminal.kittyDisplayReflowBoundaries.compactMap {
            boundary in lines.firstIndex { $0 === boundary.line }
        }, [2, 3, 4])
        XCTAssertEqual(terminal.kittyDisplayClippedTopReflowRanks.compactMap {
            rank in lines.firstIndex { $0 === rank.line }
        }, [1])
        XCTAssertEqual(terminal.kittyDisplayReflowClaims.compactMap {
            claim in lines.firstIndex { $0 === claim.line }
        }, [5])

        terminal.resize(cols: 6, rows: 7)
        XCTAssertEqual(terminal.buffer.lineCount, 11)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 10)
        XCTAssertTrue(terminal.kittyDisplayClippedTopReflowRanks.isEmpty)
    }

    func testKittyInsetRegionDoesNotClaimWrappedRowsAboveItsTop() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 5, rows: 3)
        terminal.feed(text:
            "    \u{65E5}\u{1B}[?69h\u{65E5}\u{65E5}\n" +
            "\u{1B}[1;4s\u{1B}[2;5r\n\n " + display)

        XCTAssertTrue(terminal.kittyDisplayClippedTopReflowRanks.isEmpty)
        terminal.resize(cols: 3, rows: 4)
        XCTAssertEqual(terminal.buffer.lineCount, 5)
        XCTAssertEqual(terminal.buffer.yBase, 1)
        XCTAssertEqual(terminal.scrollbackLineText(row: 0), "   ")
        XCTAssertEqual(terminal.scrollbackLineText(row: 1), " \u{65E5} ")
        XCTAssertEqual(terminal.scrollbackLineText(row: 2), "\u{65E5} ")
        XCTAssertEqual(terminal.scrollbackLineText(row: 3), " ")
        XCTAssertEqual(terminal.scrollbackLineText(row: 4), "")
    }

    func testKittyNonBottomPlacementUsesLaterLineMotionResizeLifecycle() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 5, rows: 4)
        terminal.feed(text:
            "\n\n" + display +
            "\u{1B}[?69h\u{1B}[2;5r\n\u{1B}M" +
            "\u{1B}[1;4s\u{1B}M")

        XCTAssertEqual(terminal.kittyDisplayReflowImages.count, 1)
        terminal.resize(cols: 1, rows: 1)
        XCTAssertEqual(terminal.buffer.lineCount, 2)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 1)
    }

    func testKittyRectangularMotionRetiresOverwrittenPlacementResizeExtent() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 3, rows: 4)
        terminal.feed(text:
            "\n" + display +
            "\u{1B}[?69h\u{1B}[2;4r\n\u{1B}M" +
            "\u{1B}[1;2s\u{1B}M")

        XCTAssertEqual(terminal.kittyDisplayReflowImages.count, 1)
        terminal.resize(cols: 3, rows: 1)
        XCTAssertEqual(terminal.buffer.lineCount, 2)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 1)
    }

    func testKittyReverseSliceWithOutsideOwnerRetiresPlacementResizeExtent() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 2, rows: 5)
        terminal.feed(text:
            "\n\n\n" + display +
            "\u{1B}[?69h\u{1B}[2;5r\n" +
            "\u{1B}[2;3s \u{1B}M")

        XCTAssertEqual(terminal.kittyDisplayReflowImages.count, 1)
        terminal.resize(cols: 2, rows: 1)
        XCTAssertEqual(terminal.buffer.lineCount, 2)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 1)

        let inside = CmdyTerminal(cols: 2, rows: 5)
        inside.feed(text:
            "\n\n\n" + display +
            "\u{1B}[?69h\u{1B}[2;5r\n" +
            "\u{1B}[2;3s  \u{1B}M")
        XCTAssertEqual(inside.kittyDisplayReflowImages.count, 1)
        inside.resize(cols: 2, rows: 1)
        XCTAssertEqual(inside.buffer.lineCount, 3)
        XCTAssertEqual(inside.buffer.yBase + inside.buffer.y, 2)
    }

    func testKittySoftWrapRetiresOnlyTheReusedPlacementGenerationLine() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,q=2;/wAA/w==\u{1B}\\"
        let setup =
            "\u{1B}[?69h\n\u{1B}[4;4s\t\u{65E5}\n" + display

        let intoBoundary = CmdyTerminal(cols: 4, rows: 4)
        intoBoundary.feed(text: setup)
        let boundaryLine = intoBoundary.buffer.liveLine(2)
        let claimedLine = intoBoundary.buffer.liveLine(3)
        XCTAssertTrue(intoBoundary.kittyDisplayReflowBoundaries.contains {
            $0.line === boundaryLine
        })
        XCTAssertTrue(intoBoundary.kittyDisplayReflowClaims.contains {
            $0.line === claimedLine
        })

        intoBoundary.feed(text: "\u{1B}[2;4HZ ")
        XCTAssertFalse(intoBoundary.kittyDisplayReflowBoundaries.contains {
            $0.line === boundaryLine
        })
        XCTAssertTrue(intoBoundary.kittyDisplayReflowClaims.contains {
            $0.line === claimedLine
        })
        intoBoundary.resize(cols: 3, rows: 1)
        XCTAssertEqual(intoBoundary.buffer.lineCount, 4)
        XCTAssertEqual(intoBoundary.buffer.yBase + intoBoundary.buffer.y, 3)
        XCTAssertEqual(intoBoundary.buffer.x, 2)

        let intoClaim = CmdyTerminal(cols: 4, rows: 4)
        intoClaim.feed(text: setup)
        let retainedBoundary = intoClaim.buffer.liveLine(2)
        let reusedClaim = intoClaim.buffer.liveLine(3)
        intoClaim.feed(text: "\u{1B}[3;4HZ ")
        XCTAssertTrue(intoClaim.kittyDisplayReflowBoundaries.contains {
            $0.line === retainedBoundary
        })
        XCTAssertFalse(intoClaim.kittyDisplayReflowClaims.contains {
            $0.line === reusedClaim
        })
        intoClaim.resize(cols: 3, rows: 1)
        XCTAssertEqual(intoClaim.buffer.lineCount, 6)
        XCTAssertEqual(intoClaim.buffer.yBase + intoClaim.buffer.y, 5)
        XCTAssertEqual(intoClaim.buffer.x, 2)
    }

    func testKittyWholeRowBottomWrapRetiresReusedPlacementBoundary() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 5, rows: 3)
        terminal.feed(text:
            "\u{1B}[2;5r\u{65E5}\u{1B}[?69h\u{65E5}\u{65E5}" +
            "\u{1B}[1;4s\n" + display +
            "\u{1B}[?69l\u{65E5}\u{65E5} a")

        let linesBeforeResize = terminal.buffer.lines
        XCTAssertEqual(
            terminal.kittyDisplayReflowBoundaries.compactMap { boundary in
                linesBeforeResize.firstIndex { $0 === boundary.line }
            }, [0])
        XCTAssertEqual(
            terminal.kittyDisplayReflowClaims.compactMap { claim in
                linesBeforeResize.firstIndex { $0 === claim.line }
            }, [1])

        terminal.resize(cols: 1, rows: 6)

        XCTAssertEqual(terminal.buffer.lineCount, 6)
        XCTAssertEqual(terminal.buffer.yBase, 0)
        XCTAssertEqual(terminal.buffer.y, 5)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(
            (0..<6).map { terminal.scrollbackLineText(row: $0) },
            ["\u{65E5} ", "\u{65E5} ", "\u{65E5} ", "\u{65E5} ", " a", ""])
    }

    func testKittyWrapReconcilesCapturedGenerationAfterGeometryChange() {
        let display =
            "\u{1B}_Ga=T,s=1,v=1;/wAA/w==\u{1B}\\"
        let setup =
            "\u{1B}[?69h\n\u{1B}[7;9s\t\u{65E5}\n" + display

        func metadataRows(_ terminal: CmdyTerminal) -> (
            boundaries: [Int], claims: [Int]
        ) {
            let lines = terminal.buffer.lines
            let boundaries = terminal.kittyDisplayReflowBoundaries.compactMap {
                boundary in lines.firstIndex { $0 === boundary.line }
            }
            let claims = terminal.kittyDisplayReflowClaims.compactMap {
                claim in lines.firstIndex { $0 === claim.line }
            }
            return (boundaries, claims)
        }

        let accepted = CmdyTerminal(cols: 4, rows: 4)
        accepted.feed(text: setup + "\u{1B}[2;3s\u{1B}[3;6HZ ")
        XCTAssertEqual(metadataRows(accepted).boundaries, [3])
        XCTAssertEqual(metadataRows(accepted).claims, [])
        accepted.resize(cols: 3, rows: 1)
        XCTAssertEqual(accepted.buffer.lineCount, 4)
        XCTAssertEqual(accepted.buffer.yBase + accepted.buffer.y, 3)
        XCTAssertEqual(accepted.buffer.x, 0)
        XCTAssertEqual(accepted.scrollbackLineText(row: 3), " Z ")

        let modeOffCanonical = CmdyTerminal(cols: 4, rows: 4)
        modeOffCanonical.feed(text:
            setup + "\u{1B}[?69l\u{1B}[2;6HZ ")
        XCTAssertEqual(metadataRows(modeOffCanonical).boundaries, [])
        XCTAssertEqual(metadataRows(modeOffCanonical).claims, [])
        modeOffCanonical.resize(cols: 3, rows: 1)
        XCTAssertEqual(modeOffCanonical.buffer.lineCount, 3)
        XCTAssertEqual(modeOffCanonical.buffer.yBase + modeOffCanonical.buffer.y, 2)
        XCTAssertEqual(modeOffCanonical.buffer.x, 2)
        XCTAssertEqual(modeOffCanonical.scrollbackLineText(row: 2), "Z ")

        func makeModeOffAdjacent(splitFeed: Bool) -> CmdyTerminal {
            let terminal = CmdyTerminal(cols: 4, rows: 4)
            terminal.feed(text: setup + "\u{1B}[?69l\u{1B}[3;6H")
            if splitFeed {
                terminal.feed(text: "Z")
                terminal.feed(text: " ")
            } else {
                terminal.feed(text: "Z ")
            }
            return terminal
        }

        for terminal in [
            makeModeOffAdjacent(splitFeed: true),
            makeModeOffAdjacent(splitFeed: false),
        ] {
            XCTAssertEqual(metadataRows(terminal).boundaries, [2])
            XCTAssertEqual(metadataRows(terminal).claims, [])
            terminal.resize(cols: 3, rows: 1)
            XCTAssertEqual(terminal.buffer.lineCount, 5)
            XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 4)
            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertEqual(terminal.scrollbackLineText(row: 2), "\u{65E5} ")
            XCTAssertEqual(terminal.scrollbackLineText(row: 3), "")
            XCTAssertEqual(terminal.scrollbackLineText(row: 4), "Z ")
        }

        let modeOffWide = CmdyTerminal(cols: 4, rows: 4)
        modeOffWide.feed(text:
            setup + "\u{1B}[?69l\u{1B}[3;6H\u{65E5} ")
        XCTAssertEqual(metadataRows(modeOffWide).boundaries, [3])
        XCTAssertEqual(metadataRows(modeOffWide).claims, [])
        modeOffWide.resize(cols: 3, rows: 1)
        XCTAssertEqual(modeOffWide.buffer.lineCount, 4)
        XCTAssertEqual(modeOffWide.buffer.yBase + modeOffWide.buffer.y, 3)
        XCTAssertEqual(modeOffWide.buffer.x, 0)
        XCTAssertEqual(modeOffWide.scrollbackLineText(row: 3), "\u{65E5}  ")

        let activeFullUnicode = CmdyTerminal(cols: 4, rows: 4)
        activeFullUnicode.feed(text:
            setup + "\u{1B}[1;4s\u{1B}[3;6H\u{E9} ")
        XCTAssertEqual(metadataRows(activeFullUnicode).boundaries, [2])
        XCTAssertEqual(metadataRows(activeFullUnicode).claims, [])
        activeFullUnicode.resize(cols: 3, rows: 1)
        XCTAssertEqual(activeFullUnicode.buffer.lineCount, 5)
        XCTAssertEqual(activeFullUnicode.buffer.yBase + activeFullUnicode.buffer.y, 4)
        XCTAssertEqual(activeFullUnicode.buffer.x, 2)
        XCTAssertEqual(activeFullUnicode.scrollbackLineText(row: 4), "\u{E9} ")
    }

    func testKittyExactEdgeWideOverflowUsesEffectiveDepartureBoundary() {
        let display =
            "\u{1B}_Ga=T,s=1,v=1;/wAA/w==\u{1B}\\"
        let setup =
            "\u{1B}[?69h\n\u{1B}[4;4s\t\u{65E5}\n" + display +
            "\u{1B}[3;4H"

        func metadataRows(_ terminal: CmdyTerminal) -> (
            boundaries: [Int], claims: [Int]
        ) {
            let lines = terminal.buffer.lines
            let boundaries = terminal.kittyDisplayReflowBoundaries.compactMap {
                boundary in lines.firstIndex { $0 === boundary.line }
            }
            let claims = terminal.kittyDisplayReflowClaims.compactMap {
                claim in lines.firstIndex { $0 === claim.line }
            }
            return (boundaries, claims)
        }

        let blankDeparture = CmdyTerminal(cols: 4, rows: 4)
        blankDeparture.feed(text: setup + "\u{1F680}")
        XCTAssertEqual(metadataRows(blankDeparture).boundaries, [3])
        XCTAssertEqual(metadataRows(blankDeparture).claims, [])
        blankDeparture.resize(cols: 3, rows: 1)
        XCTAssertEqual(blankDeparture.buffer.lineCount, 5)
        XCTAssertEqual(blankDeparture.buffer.yBase + blankDeparture.buffer.y, 4)
        XCTAssertEqual(blankDeparture.buffer.x, 1)
        XCTAssertEqual(blankDeparture.scrollbackLineText(row: 2), "\u{65E5} ")
        XCTAssertEqual(blankDeparture.scrollbackLineText(row: 3), "")
        XCTAssertEqual(blankDeparture.scrollbackLineText(row: 4), "\u{1F680} ")

        let contentDeparture = CmdyTerminal(cols: 4, rows: 4)
        contentDeparture.feed(text:
            setup + "\u{1B}[3;1H \u{1B}[3;4H\u{1F680}")
        XCTAssertEqual(metadataRows(contentDeparture).boundaries, [2])
        XCTAssertEqual(metadataRows(contentDeparture).claims, [])

        let semanticDeparture = CmdyTerminal(cols: 4, rows: 4)
        semanticDeparture.feed(text:
            setup + "\u{1B}]133;A\u{7}\u{1B}[3;4H\u{1F680}")
        XCTAssertEqual(semanticDeparture.buffer.liveLine(2).usedLength, 0)
        XCTAssertEqual(metadataRows(semanticDeparture).boundaries, [2])
        XCTAssertEqual(metadataRows(semanticDeparture).claims, [])
    }

    func testKittyReflowPreservesCompletedEndBoundaryOnEmptyDeparture() {
        let display =
            "\u{1B}_Ga=T,s=1,v=1;/wAA/w==\u{1B}\\"
        let terminal = CmdyTerminal(cols: 4, rows: 4)
        terminal.feed(text:
            "\u{1B}[?69h\n\u{1B}[7;9s\t\u{65E5}\n" + display +
            "\u{1B}[3;1H\u{1B}[2K" +
            "\u{1B}[2;1H\u{1B}]133;A\u{7}\u{1B}]133;B\u{7}" +
            "\u{1B}]133;C\u{7}\u{1B}[3;1H\u{1B}]133;D;0\u{7}" +
            "\u{1B}[3;4H\u{65E5}")

        let block = try! XCTUnwrap(terminal.blocks.blocks.last)
        XCTAssertEqual(block.promptRow, 1)
        XCTAssertEqual(block.commandRow, 1)
        XCTAssertEqual(block.endRow, 2)

        var observedEndRows: [Int?] = []
        terminal.blocks.onChange = {
            observedEndRows.append(terminal.blocks.blocks.last?.endRow)
        }
        terminal.resize(cols: 3, rows: 1)
        XCTAssertEqual(observedEndRows.count, 1)
        XCTAssertEqual(observedEndRows.first!, 3)
        XCTAssertEqual(terminal.buffer.lineCount, 5)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 4)
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(block.promptRow, 1)
        XCTAssertEqual(block.commandRow, 1)
        XCTAssertEqual(block.endRow, 3)
    }

    func testKittyUnwrappedPartialSliceImageDoesNotRetainShrunkBlankRow() {
        let display =
            "\u{1B}_Ga=T,f=32,s=1,v=1,q=2;/wAA/w==\u{1B}\\"
        let setup = "\u{1B}[?69h\u{1B}[2s "

        let normal = CmdyTerminal(cols: 2, rows: 2)
        normal.feed(text: setup + "\n" + display + "\u{1B}M")
        XCTAssertEqual(normal.buffer.lineCount, 2)
        XCTAssertEqual(normal.buffer.y, 0)
        normal.resize(cols: 2, rows: 1)
        XCTAssertEqual(normal.buffer.lineCount, 1)
        XCTAssertEqual(normal.buffer.yBase, 0)
        XCTAssertEqual(normal.buffer.y, 0)

        let alternate = CmdyTerminal(cols: 2, rows: 2)
        alternate.feed(text:
            "\u{1B}[?1049h" + setup + "\n" + display + "\u{1B}M")
        alternate.resize(cols: 2, rows: 1)
        XCTAssertEqual(alternate.buffer.lineCount, 1)
        XCTAssertEqual(alternate.buffer.yBase, 0)
        XCTAssertEqual(alternate.buffer.y, 0)

        // Without the reverse motion the cursor still owns the bottom row,
        // so shrinking retains it as scrollback even though the image marker
        // itself is ignored for sizing.
        let noReverse = CmdyTerminal(cols: 2, rows: 2)
        noReverse.feed(text: setup + "\n" + display)
        noReverse.resize(cols: 2, rows: 1)
        XCTAssertEqual(noReverse.buffer.lineCount, 2)
        XCTAssertEqual(noReverse.buffer.yBase, 1)
        XCTAssertEqual(noReverse.buffer.y, 0)

        // On a taller alternate screen RI leaves the cursor one row above the
        // placement. Its ordinary one-row alternate scrollback survives;
        // only the discarded placement row is ignored.
        let tallerAlternate = CmdyTerminal(cols: 2, rows: 3)
        tallerAlternate.feed(text:
            "\u{1B}[?1049h" + setup + "\n\n" + display + "\u{1B}M")
        tallerAlternate.resize(cols: 2, rows: 1)
        XCTAssertEqual(tallerAlternate.buffer.lineCount, 2)
        XCTAssertEqual(tallerAlternate.buffer.yBase, 1)
        XCTAssertEqual(tallerAlternate.buffer.y, 0)
    }

    func testKittySuccessfulPlacementBoundaryGenerationAndAlternateGate() {
        let transmit = "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"

        let alternateOutside = CmdyTerminal(cols: 2, rows: 1)
        alternateOutside.feed(text: "\u{1B}[?1049h\u{1B}[1;2H" + transmit)
        assertPlainRows(alternateOutside, [[0, 0]])
        XCTAssertEqual(alternateOutside.buffer.x, 0)
        XCTAssertEqual(alternateOutside.buffer.y, 0)
        XCTAssertEqual(alternateOutside.buffer.lineCount, 1)
        XCTAssertEqual(alternateOutside.buffer.yBase, 0)

        let activeFull = CmdyTerminal(cols: 2, rows: 1)
        activeFull.feed(text:
            "\u{1B}[?69h\u{1B}[1;2s\u{1B}[1;1H" + transmit)
        assertPlainRows(activeFull, [[0, 0], [0, 0]])
        XCTAssertEqual(activeFull.buffer.x, 0)
        XCTAssertEqual(activeFull.buffer.y, 0)
        XCTAssertEqual(activeFull.buffer.yBase + activeFull.buffer.y, 1)
        XCTAssertEqual(activeFull.buffer.lineCount, 2)
        XCTAssertEqual(activeFull.buffer.yBase, 1)

        let hiddenPartial = CmdyTerminal(cols: 3, rows: 1)
        hiddenPartial.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[?69l\u{1B}[1;2H" + transmit)
        assertPlainRows(hiddenPartial, [[0, 0, 0], [0, 0, 0]])
        XCTAssertEqual(hiddenPartial.buffer.x, 0)
        XCTAssertEqual(hiddenPartial.buffer.y, 0)
        XCTAssertEqual(hiddenPartial.buffer.yBase + hiddenPartial.buffer.y, 1)
        XCTAssertEqual(hiddenPartial.buffer.lineCount, 2)
        XCTAssertEqual(hiddenPartial.buffer.yBase, 1)

        let activePartial = CmdyTerminal(cols: 3, rows: 1)
        activePartial.feed(text:
            "\u{1B}[?7lAAA\u{1B}[?69h\u{1B}[2;2s" +
            "\u{1B}[?7h\u{1B}[1;2H" + transmit)
        assertPlainRows(activePartial, [[0x41, 0, 0x41]])
        XCTAssertEqual(activePartial.buffer.x, 0)
        XCTAssertEqual(activePartial.buffer.y, 0)
        XCTAssertEqual(activePartial.buffer.lineCount, 1)
        XCTAssertEqual(activePartial.buffer.yBase, 0)
    }

    func testKittySuccessfulPlacementUsesActiveEraseBackgroundForExposedCells() {
        let transmit = "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let preload = "\u{1B}_Ga=t,f=32,s=1,v=1,i=31,q=2;/wAA/w==\u{1B}\\"
        let display = "\u{1B}_Ga=p,i=31,p=1,x=0,y=0,c=1,r=1,q=2;\u{1B}\\"
        let query = "\u{1B}_Ga=q,f=32,s=1,v=1,i=32,q=2;/wAA/w==\u{1B}\\"
        let blackBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        let indexedBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(99)))

        let generated = CmdyTerminal(cols: 1, rows: 1)
        generated.feed(text: "\u{1B}[40m" + transmit)
        XCTAssertEqual(generated.buffer.lines[0].cells, [Cell()])
        XCTAssertEqual(generated.buffer.lines[1].cells, [blackBlank])
        XCTAssertEqual(generated.buffer.lineCount, 2)
        XCTAssertEqual(generated.buffer.yBase, 1)

        let displayed = CmdyTerminal(cols: 1, rows: 1)
        displayed.feed(text: preload + "\u{1B}[48;5;99m" + display)
        XCTAssertEqual(displayed.buffer.lines[1].cells, [indexedBlank])

        let activeSlice = CmdyTerminal(cols: 3, rows: 2)
        activeSlice.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[40m\u{1B}[2;2H" + transmit)
        XCTAssertEqual(
            activeSlice.buffer.liveLine(1).cells,
            [Cell(), blackBlank, Cell()])
        XCTAssertEqual(activeSlice.buffer.lineCount, 2)
        XCTAssertEqual(activeSlice.buffer.yBase, 0)

        let hiddenAccepted = CmdyTerminal(cols: 3, rows: 2)
        hiddenAccepted.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[?69l\u{1B}[40m" +
            "\u{1B}[2;3H" + transmit)
        XCTAssertEqual(
            hiddenAccepted.buffer.liveLine(1).cells,
            [blackBlank, blackBlank, blackBlank])
        XCTAssertEqual(hiddenAccepted.buffer.lineCount, 3)
        XCTAssertEqual(hiddenAccepted.buffer.yBase, 1)

        let hiddenOutside = CmdyTerminal(cols: 3, rows: 2)
        hiddenOutside.feed(text:
            "\u{1B}[?69h\u{1B}[1;2s\u{1B}[?69l\u{1B}[40m" +
            "\u{1B}[2;3H" + transmit)
        assertPlainRows(hiddenOutside, [[0, 0, 0], [0, 0, 0]])
        XCTAssertEqual(hiddenOutside.buffer.lineCount, 2)

        let nonBottom = CmdyTerminal(cols: 2, rows: 2)
        nonBottom.feed(text: "\u{1B}[40m\u{1B}[1;1H" + transmit)
        assertPlainRows(nonBottom, [[0, 0], [0, 0]])
        XCTAssertEqual(nonBottom.buffer.lineCount, 2)

        let inert = CmdyTerminal(cols: 1, rows: 1)
        inert.feed(text: "\u{1B}[40m" + query)
        XCTAssertEqual(inert.buffer.lines[0].cells, [Cell()])
        XCTAssertEqual(inert.buffer.lineCount, 1)

        let alternateOutside = CmdyTerminal(cols: 2, rows: 1)
        alternateOutside.feed(text:
            "\u{1B}[?1049h\u{1B}[40m\u{1B}[1;2H" + transmit)
        assertPlainRows(alternateOutside, [[0, 0]])
        XCTAssertEqual(alternateOutside.buffer.lineCount, 1)
    }

    func testKittySuccessEffectIsDistinctFromPubliclyInertControls() {
        let transmit = "\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1B}\\"
        let preload = "\u{1B}_Ga=t,f=32,s=1,v=1,i=31,q=2;/wAA/w==\u{1B}\\"
        let display = "\u{1B}_Ga=p,i=31,p=1,x=0,y=0,c=1,r=1,q=2;\u{1B}\\"
        let setup = "\u{1B}[1;2r\u{1B}[?7h\u{1B}[3;1H"
        let controls = [
            setup + transmit,
            setup + "\u{1B}_Ga=z,i=-1,q=2;AA==\u{1B}\\",
            preload + setup + display,
            preload + setup + "\u{1B}_Ga=d,d=i,i=31,q=2;\u{1B}\\",
        ]

        for stream in controls {
            let terminal = CmdyTerminal(cols: 1, rows: 3)
            terminal.feed(text: stream)
            assertPlainRows(terminal, [[0], [0], [0]])
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, 2)
            XCTAssertEqual(terminal.buffer.lineCount, 3)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testKittyRetransmissionReplacesOnlyItsOwnLineGeneration() {
        func transmitAndDisplay(_ imageId: Int) -> String {
            "\u{1B}_Ga=T,f=32,s=1,v=1,i=\(imageId),q=2;/wAA/w==\u{1B}\\"
        }

        let sameImage = CmdyTerminal(cols: 1, rows: 4)
        sameImage.feed(text:
            "\u{1B}[2B" + transmitAndDisplay(3) +
            "\u{1B}[H" + transmitAndDisplay(3))
        sameImage.resize(cols: 1, rows: 1)
        XCTAssertEqual(sameImage.buffer.lineCount, 2)

        let distinctImages = CmdyTerminal(cols: 1, rows: 4)
        distinctImages.feed(text:
            "\u{1B}[2B" + transmitAndDisplay(3) +
            "\u{1B}[H" + transmitAndDisplay(4))
        distinctImages.resize(cols: 1, rows: 1)
        XCTAssertEqual(distinctImages.buffer.lineCount, 3)

        let explicitPlacement = CmdyTerminal(cols: 1, rows: 4)
        explicitPlacement.feed(text:
            "\u{1B}[2B" + transmitAndDisplay(3) +
            "\u{1B}[H\u{1B}_Ga=p,i=3,p=7,q=2;\u{1B}\\")
        explicitPlacement.resize(cols: 1, rows: 1)
        XCTAssertEqual(explicitPlacement.buffer.lineCount, 3)

        let deletedImage = CmdyTerminal(cols: 1, rows: 4)
        deletedImage.feed(text:
            "\u{1B}[2B" + transmitAndDisplay(3) +
            "\u{1B}[H\u{1B}_Ga=d,d=i,i=3,q=2;\u{1B}\\")
        deletedImage.resize(cols: 1, rows: 1)
        XCTAssertEqual(deletedImage.buffer.lineCount, 1)

        let invalidReplacement = CmdyTerminal(cols: 1, rows: 4)
        invalidReplacement.feed(text:
            "\u{1B}[2B" + transmitAndDisplay(3) +
            "\u{1B}[H\u{1B}_Ga=T,f=32,s=1,v=1,i=3,q=2;%%%\u{1B}\\")
        invalidReplacement.resize(cols: 1, rows: 1)
        XCTAssertEqual(invalidReplacement.buffer.lineCount, 3)
    }

    func testHorizontalTabPreservesClusterContinuationState() {
        let wrappedWide = CmdyTerminal(cols: 1, rows: 1)
        wrappedWide.feed(text: "\u{65E5}\t\u{200D}")
        XCTAssertEqual(wrappedWide.scrollbackLineTexts(rows: 0...1),
                       ["", "\u{65E5}\u{200D}"])
        XCTAssertEqual(wrappedWide.buffer.lines[0].cells, [Cell()])
        XCTAssertEqual(
            wrappedWide.buffer.lines[1].cells,
            [Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2)])
        XCTAssertEqual(wrappedWide.buffer.x, 0)
        XCTAssertEqual(wrappedWide.buffer.yBase + wrappedWide.buffer.y, 1)
        XCTAssertEqual(wrappedWide.buffer.lineCount, 2)
        XCTAssertEqual(wrappedWide.buffer.yBase, 1)

        let sameStopMark = CmdyTerminal(cols: 2, rows: 1)
        sameStopMark.feed(text: "A\t\u{301}")
        XCTAssertEqual(
            sameStopMark.buffer.liveLine(0).cells,
            [Cell(scalar: 0x41, clusterExtras: [0x301]), Cell()])
        XCTAssertEqual(sameStopMark.buffer.x, 1)

        let movedJoiner = CmdyTerminal(cols: 4, rows: 1)
        movedJoiner.feed(text: "\u{E9}\t\u{200D}")
        XCTAssertEqual(
            movedJoiner.buffer.liveLine(0).cells,
            [Cell(scalar: 0xE9, clusterExtras: [0x200D]),
             Cell(), Cell(), Cell()])
        XCTAssertEqual(movedJoiner.buffer.x, 3)

        let pending = CmdyTerminal(cols: 2, rows: 1)
        pending.feed(text: "\u{1B}[1;2HA\t\u{301}")
        XCTAssertEqual(
            pending.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0x41, clusterExtras: [0x301])])
        XCTAssertEqual(pending.buffer.x, 1)

        let parked = CmdyTerminal(cols: 2, rows: 1)
        parked.feed(text: "\u{1B}[?7l\u{1B}[1;2HA\t\u{200D}")
        XCTAssertEqual(
            parked.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0x41, clusterExtras: [0x200D])])
        XCTAssertEqual(parked.buffer.x, 1)

        let wrappedNarrow = CmdyTerminal(cols: 2, rows: 1)
        wrappedNarrow.feed(text: "\u{1B}[1;2HXA\t\u{301}")
        XCTAssertEqual(wrappedNarrow.scrollbackLineTexts(rows: 0...1),
                       [" X", "A\u{301}"])
        XCTAssertEqual(
            wrappedNarrow.buffer.lines[1].cells,
            [Cell(scalar: 0x41, clusterExtras: [0x301]), Cell()])
        XCTAssertEqual(wrappedNarrow.buffer.x, 1)
        XCTAssertEqual(wrappedNarrow.buffer.yBase + wrappedNarrow.buffer.y, 1)

        let clearedTabs = CmdyTerminal(cols: 2, rows: 1)
        clearedTabs.feed(text: "\u{1B}[3gA\t\u{200D}")
        XCTAssertEqual(
            clearedTabs.buffer.liveLine(0).cells,
            [Cell(scalar: 0x41, clusterExtras: [0x200D]), Cell()])
        XCTAssertEqual(clearedTabs.buffer.x, 1)

        let ordinary = CmdyTerminal(cols: 4, rows: 1)
        ordinary.feed(text: "A\tZ")
        assertPlainRows(ordinary, [[0x41, 0, 0, 0x5A]])
        XCTAssertEqual(ordinary.buffer.x, 4)

        let invalid = CmdyTerminal(cols: 1, rows: 1)
        invalid.feed(text: "\u{1B}[?7l\u{65E5}\t\u{301}")
        assertPlainRows(invalid, [[0]])
        XCTAssertEqual(invalid.buffer.x, 0)

        let explicitlySettled = CmdyTerminal(cols: 2, rows: 1)
        explicitlySettled.feed(text: "A\u{1B}[1;1H\t\u{301}")
        XCTAssertEqual(
            explicitlySettled.buffer.liveLine(0).cells,
            [Cell(scalar: 0x41, clusterExtras: [0x301]), Cell()])
        XCTAssertEqual(explicitlySettled.buffer.x, 1)
    }

    func testDeleteCharacterRefreshesClusterOwnerAtPreservedCoordinate() {
        for follower in ["\u{301}", "\u{200D}"] {
            let inherited = CmdyTerminal(cols: 2, rows: 1)
            inherited.feed(text: "0A\rZ\r\u{1B}[P" + follower)
            XCTAssertEqual(inherited.buffer.liveLine(0).cells, [
                Cell(
                    scalar: 0x41,
                    clusterExtras: [UnicodeScalar(follower)!.value]),
                Cell(),
            ])
            XCTAssertEqual(inherited.buffer.x, 0)
        }

        let coordinateNotSource = CmdyTerminal(cols: 4, rows: 1)
        coordinateNotSource.feed(text:
            "ABCD\u{1B}[1;3HX\u{1B}[1;1H\u{1B}[P\u{301}")
        XCTAssertEqual(coordinateNotSource.buffer.liveLine(0).cells, [
            Cell(scalar: 0x42),
            Cell(scalar: 0x58),
            Cell(scalar: 0x44, clusterExtras: [0x301]),
            Cell(),
        ])
        XCTAssertEqual(coordinateNotSource.buffer.x, 0)

        let selectorSensitive = CmdyTerminal(cols: 2, rows: 1)
        selectorSensitive.feed(text: "Z\u{2764}\rZ\r\u{1B}[P\u{FE0F}")
        XCTAssertEqual(selectorSensitive.buffer.liveLine(0).cells, [
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ])
        XCTAssertEqual(selectorSensitive.buffer.x, 1)

        let continuation = CmdyTerminal(cols: 3, rows: 1)
        continuation.feed(text: "Z\u{65E5}\r\u{1B}[P\u{301}")
        XCTAssertEqual(continuation.buffer.liveLine(0).cells, [
            Cell(scalar: 0x65E5, width: 2),
            Cell(
                scalar: 0, width: 0,
                attribute: CmdyTerminal.stubAttribute),
            Cell(),
        ])
        XCTAssertEqual(continuation.buffer.x, 0)

        let exposedBlank = CmdyTerminal(cols: 2, rows: 1)
        exposedBlank.feed(text: "AB\r\u{1B}[P\u{301}")
        XCTAssertEqual(exposedBlank.buffer.liveLine(0).cells, [
            Cell(scalar: 0x42), Cell(),
        ])
        XCTAssertEqual(exposedBlank.buffer.x, 0)
    }

    func testDeleteCharacterAtPendingOrParkedEdgeIsNoOp() {
        let pending = CmdyTerminal(cols: 1, rows: 2)
        pending.feed(text: "Z\u{1B}[P")
        XCTAssertEqual(pending.buffer.liveLine(0).cells, [Cell(scalar: 0x5A)])
        XCTAssertEqual(pending.buffer.liveLine(1).cells, [Cell()])
        XCTAssertEqual(pending.buffer.x, 1)
        XCTAssertTrue(pending.buffer.wrapPending)

        let nextWrap = CmdyTerminal(cols: 1, rows: 2)
        nextWrap.feed(text: "Z\u{1B}[PA")
        XCTAssertEqual(nextWrap.buffer.liveLine(0).cells, [Cell(scalar: 0x5A)])
        XCTAssertEqual(nextWrap.buffer.liveLine(1).cells, [Cell(scalar: 0x41)])
        XCTAssertEqual(nextWrap.buffer.x, 1)
        XCTAssertEqual(nextWrap.buffer.y, 1)
        XCTAssertTrue(nextWrap.buffer.wrapPending)

        let parked = CmdyTerminal(cols: 1, rows: 1)
        parked.feed(text: "\u{1B}[?7lZ\u{1B}[PA")
        XCTAssertEqual(parked.buffer.liveLine(0).cells, [Cell(scalar: 0x41)])
        XCTAssertEqual(parked.buffer.x, 1)
        XCTAssertFalse(parked.buffer.wrapPending)
    }

    func testVerticalCursorMotionsConsumeSemanticPendingState() {
        let canonical = CmdyTerminal(cols: 1, rows: 1)
        canonical.feed(text:
            "a\u{1B}[2B\u{2764}\u{FE0F} ")
        XCTAssertEqual(canonical.buffer.lines.map(\.cells), [
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0F])],
            [Cell(scalar: 0x20)],
        ])
        XCTAssertEqual(canonical.buffer.x, 1)
        XCTAssertEqual(canonical.buffer.yBase + canonical.buffer.y, 1)
        XCTAssertEqual(canonical.buffer.lineCount, 2)
        XCTAssertEqual(canonical.buffer.yBase, 1)

        let unicode = CmdyTerminal(cols: 1, rows: 4)
        unicode.feed(text: "Z\u{1B}[2B\u{E9}")
        XCTAssertEqual(unicode.buffer.liveLine(0).cells, [Cell(scalar: 0x5A)])
        XCTAssertEqual(unicode.buffer.liveLine(1).cells, [Cell()])
        XCTAssertEqual(unicode.buffer.liveLine(2).cells, [Cell(scalar: 0xE9)])
        XCTAssertEqual(unicode.buffer.liveLine(3).cells, [Cell()])
        XCTAssertEqual(unicode.buffer.x, 1)
        XCTAssertEqual(unicode.buffer.y, 2)

        let ascii = CmdyTerminal(cols: 1, rows: 4)
        ascii.feed(text: "Z\u{1B}[2BA")
        XCTAssertEqual(ascii.buffer.liveLine(2).cells, [Cell(scalar: 0x41)])
        XCTAssertEqual(ascii.buffer.y, 2)

        let nextLine = CmdyTerminal(cols: 2, rows: 3)
        nextLine.feed(text: "AB\u{1B}[E\u{E9}")
        XCTAssertEqual(nextLine.buffer.liveLine(0).cells, [
            Cell(scalar: 0x41), Cell(scalar: 0x42),
        ])
        XCTAssertEqual(nextLine.buffer.liveLine(1).cells, [
            Cell(scalar: 0xE9), Cell(),
        ])
        XCTAssertEqual(nextLine.buffer.liveLine(2).cells, [Cell(), Cell()])
        XCTAssertEqual(nextLine.buffer.x, 1)
        XCTAssertEqual(nextLine.buffer.y, 1)

        let precedingLine = CmdyTerminal(cols: 2, rows: 3)
        precedingLine.feed(text: "\u{1B}[2;1HAB\u{1B}[F\u{E9}")
        XCTAssertEqual(precedingLine.buffer.liveLine(0).cells, [
            Cell(scalar: 0xE9), Cell(),
        ])
        XCTAssertEqual(precedingLine.buffer.liveLine(1).cells, [
            Cell(scalar: 0x41), Cell(scalar: 0x42),
        ])
        XCTAssertEqual(precedingLine.buffer.liveLine(2).cells, [Cell(), Cell()])
        XCTAssertEqual(precedingLine.buffer.x, 1)
        XCTAssertEqual(precedingLine.buffer.y, 0)

        let regionBound = CmdyTerminal(cols: 2, rows: 3)
        regionBound.feed(text:
            "\u{1B}[1;2r\u{1B}[1;1H\u{1B}[2B")
        XCTAssertEqual(regionBound.buffer.x, 0)
        XCTAssertEqual(regionBound.buffer.y, 1)

        let startsBelowRegion = CmdyTerminal(cols: 2, rows: 4)
        startsBelowRegion.feed(text:
            "\u{1B}[1;2r\u{1B}[3;1H\u{1B}[2B")
        XCTAssertEqual(startsBelowRegion.buffer.x, 0)
        XCTAssertEqual(startsBelowRegion.buffer.y, 3)
    }

    func testCursorUpPendingWitnessKeepsVS16OnWrappedLandingCell() {
        let minimal = CmdyTerminal(cols: 1, rows: 2)
        minimal.feed(text:
            "\u{1B}[2;1HZ\u{1B}[A\u{2764}\u{FE0F}")
        XCTAssertEqual(minimal.buffer.lines.map(\.cells), [
            [Cell()],
            [Cell(scalar: 0x2764, clusterExtras: [0xFE0F])],
        ])
        XCTAssertEqual(minimal.buffer.x, 1)
        XCTAssertEqual(minimal.buffer.y, 1)
        XCTAssertEqual(minimal.buffer.lineCount, 2)
        XCTAssertEqual(minimal.buffer.yBase, 0)

        let displacedASCII = CmdyTerminal(cols: 2, rows: 3)
        displacedASCII.feed(text:
            "\u{1B}[2;1HD\u{1B}[3;2HZ\u{1B}[2A" +
            "\u{2764}\u{FE0F}")
        XCTAssertEqual(displacedASCII.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(displacedASCII.buffer.liveLine(1).cells, [
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ])
        XCTAssertEqual(displacedASCII.buffer.liveLine(2).cells, [
            Cell(), Cell(scalar: 0x5A),
        ])
        XCTAssertEqual(displacedASCII.buffer.x, 2)
        XCTAssertEqual(displacedASCII.buffer.y, 1)
        XCTAssertEqual(displacedASCII.buffer.lineCount, 3)
        XCTAssertEqual(displacedASCII.buffer.yBase, 0)
    }

    func testDeleteLineRefreshesAttachmentOwnerFromMappedSourceRow() {
        let terminal = CmdyTerminal(cols: 8, rows: 3)
        terminal.feed(text:
            "\u{1B}[3;7H\u{1F680}" +
            "\u{1B}[1;7H\u{1F1FA}\u{1F1F8}" +
            "\u{1B}[2M\u{200D}")

        let incoming = terminal.buffer.liveLine(0)[6]
        XCTAssertEqual(incoming.scalar, 0x1F680)
        XCTAssertEqual(incoming.clusterExtras, [0x200D])
        XCTAssertEqual(incoming.width, 2)
        XCTAssertEqual(terminal.buffer.liveLine(0)[7].width, 0)
        XCTAssertEqual(terminal.buffer.x, 7)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDeleteLineOwnerRequiresBothDestinationAndIncomingSource() {
        let noSource = CmdyTerminal(cols: 8, rows: 3)
        noSource.feed(text:
            "\u{1B}[3;7H" +
            "\u{1B}[1;7H\u{1F1FA}\u{1F1F8}" +
            "\u{1B}[2M\u{200D}")
        XCTAssertEqual(
            noSource.buffer.liveLine(0).cells,
            Array(repeating: Cell(), count: 8))

        let noDestination = CmdyTerminal(cols: 8, rows: 3)
        noDestination.feed(text:
            "\u{1B}[3;7H\u{1F680}" +
            "\u{1B}[1;7H\u{1B}[2M\u{200D}")
        let unclaimedSource = noDestination.buffer.liveLine(0)[6]
        XCTAssertEqual(unclaimedSource.scalar, 0x1F680)
        XCTAssertNil(unclaimedSource.clusterExtras)
        XCTAssertEqual(unclaimedSource.width, 2)
        XCTAssertEqual(noDestination.buffer.x, 6)
    }

    func testDeleteLineOwnerRefreshUsesTheActualActiveOrHiddenSlice() {
        let cases: [(setup: String, column: Int, scalar: UInt32, extras: [UInt32])] = [
            ("\u{1B}[?69h\u{1B}[1;8s", 7, 0x1F680, [0x200D]),
            ("\u{1B}[?69h\u{1B}[2;8s", 7, 0x1F680, [0x200D]),
            ("\u{1B}[?69h\u{1B}[2;7s\u{1B}[?69l", 7, 0x1F680, [0x200D]),
            ("\u{1B}[?69h\u{1B}[2;7s", 6, 0x1F1FA, [0x1F1F8, 0x200D]),
        ]

        for testCase in cases {
            let terminal = CmdyTerminal(cols: 8, rows: 3)
            terminal.feed(text:
                testCase.setup +
                "\u{1B}[3;\(testCase.column)H\u{1F680}" +
                "\u{1B}[1;\(testCase.column)H\u{1F1FA}\u{1F1F8}" +
                "\u{1B}[2M\u{200D}")

            let owner = terminal.buffer.liveLine(0)[testCase.column - 1]
            XCTAssertEqual(owner.scalar, testCase.scalar)
            XCTAssertEqual(owner.clusterExtras, testCase.extras)
            XCTAssertEqual(owner.width, 2)
            XCTAssertEqual(terminal.buffer.x, 7)
            XCTAssertEqual(terminal.buffer.y, 0)
        }
    }

    func testDeleteLineContentUsesCursorAnchoredVirtualWindow() {
        let deleteTwo = CmdyTerminal(cols: 1, rows: 3)
        deleteTwo.feed(text:
            "\u{1B}[?69h\u{1B}[1;2r\u{1B}[3;1Ha" +
            "\u{1B}[2;1H\u{1B}[2M")
        assertPlainRows(deleteTwo, [[0], [0], [0]])
        XCTAssertEqual(deleteTwo.buffer.x, 0)
        XCTAssertEqual(deleteTwo.buffer.y, 1)

        let deleteOne = CmdyTerminal(cols: 1, rows: 3)
        deleteOne.feed(text:
            "\u{1B}[?69h\u{1B}[1;2r\u{1B}[3;1Ha" +
            "\u{1B}[2;1H\u{1B}[M")
        assertPlainRows(deleteOne, [[0], [0x61], [0]])
        XCTAssertEqual(deleteOne.buffer.y, 1)

        let extendsBelow = CmdyTerminal(cols: 1, rows: 4)
        extendsBelow.feed(text:
            "\u{1B}[?69h\u{1B}[1;3r\u{1B}[4;1Ha" +
            "\u{1B}[2;1H\u{1B}[M")
        assertPlainRows(extendsBelow, [[0], [0], [0x61], [0]])
        XCTAssertEqual(extendsBelow.buffer.y, 1)

        let aboveRegion = CmdyTerminal(cols: 1, rows: 4)
        aboveRegion.feed(text:
            "\u{1B}[?69h\u{1B}[3;4r\u{1B}[3;1Ha" +
            "\u{1B}[1;1H\u{1B}[M")
        assertPlainRows(aboveRegion, [[0], [0], [0x61], [0]])
        XCTAssertEqual(aboveRegion.buffer.y, 0)

        let belowRegion = CmdyTerminal(cols: 1, rows: 5)
        belowRegion.feed(text:
            "\u{1B}[?69h\u{1B}[1;2r\u{1B}[5;1Ha" +
            "\u{1B}[3;1H\u{1B}[M")
        assertPlainRows(belowRegion, [[0], [0], [0], [0], [0x61]])
        XCTAssertEqual(belowRegion.buffer.y, 2)

        let oversized = CmdyTerminal(cols: 1, rows: 3)
        oversized.feed(text:
            "\u{1B}[?69h\u{1B}[1;2r\u{1B}[3;1Ha" +
            "\u{1B}[2;1H\u{1B}[4M")
        assertPlainRows(oversized, [[0], [0], [0]])
        XCTAssertEqual(oversized.buffer.y, 1)

        let beforeWindow = CmdyTerminal(cols: 1, rows: 4)
        beforeWindow.feed(text:
            "\u{1B}[?69h\u{1B}[1;3r\u{1B}[1;1Ha" +
            "\u{1B}[2;1H\u{1B}[M")
        assertPlainRows(beforeWindow, [[0x61], [0], [0], [0]])
        XCTAssertEqual(beforeWindow.buffer.y, 1)

        let modeOff = CmdyTerminal(cols: 1, rows: 3)
        modeOff.feed(text:
            "\u{1B}[1;2r\u{1B}[3;1Ha\u{1B}[2;1H\u{1B}[M")
        assertPlainRows(modeOff, [[0], [0], [0x61]])
        XCTAssertEqual(modeOff.buffer.y, 1)
    }

    func testEmojiSelectorsRespectFixedWidthAndSettledLeadState() {
        let stub = Cell(
            scalar: 0, width: 0,
            attribute: CellAttribute(fg: .defaultColor, bg: .defaultInverted))
        let flagLead = Cell(
            scalar: 0x1F1FA, clusterExtras: [0x1F1F8], width: 2)

        for selector in ["\u{FE0E}", "\u{FE0F}"] {
            let flag = CmdyTerminal(cols: 2, rows: 1)
            flag.feed(text: "\u{1F1FA}\u{1F1F8}" + selector)
            XCTAssertEqual(flag.buffer.liveLine(0).cells, [flagLead, stub])
            XCTAssertEqual(flag.buffer.x, 2)
            XCTAssertEqual(flag.scrollbackLineTexts(rows: 0...0),
                           ["\u{1F1FA}\u{1F1F8} "])

            let rocket = CmdyTerminal(cols: 2, rows: 1)
            rocket.feed(text: "\u{1F680}" + selector)
            XCTAssertEqual(
                rocket.buffer.liveLine(0).cells,
                [Cell(scalar: 0x1F680, width: 2), stub])
            XCTAssertEqual(rocket.buffer.x, 2)

            let woman = CmdyTerminal(cols: 2, rows: 1)
            woman.feed(text: "\u{1F469}" + selector)
            XCTAssertEqual(
                woman.buffer.liveLine(0).cells,
                [Cell(scalar: 0x1F469, width: 2), stub])
            XCTAssertEqual(woman.buffer.x, 2)

            let grinning = CmdyTerminal(cols: 2, rows: 1)
            grinning.feed(text: "\u{1F600}" + selector)
            XCTAssertEqual(
                grinning.buffer.liveLine(0).cells,
                [Cell(scalar: 0x1F600, width: 2), stub])
            XCTAssertEqual(grinning.buffer.x, 2)
        }

        let flagFollower = CmdyTerminal(cols: 3, rows: 1)
        flagFollower.feed(text: "\u{1F1FA}\u{1F1F8}\u{FE0E}Z")
        XCTAssertEqual(
            flagFollower.buffer.liveLine(0).cells,
            [flagLead, stub, Cell(scalar: 0x5A)])
        XCTAssertEqual(flagFollower.buffer.x, 3)

        let grinningFollower = CmdyTerminal(cols: 2, rows: 1)
        grinningFollower.feed(text: "\u{1F600}\u{FE0E}Z")
        XCTAssertEqual(grinningFollower.buffer.lineCount, 2)
        XCTAssertEqual(grinningFollower.buffer.yBase, 1)
        XCTAssertEqual(grinningFollower.buffer.x, 1)
        XCTAssertEqual(grinningFollower.buffer.yBase + grinningFollower.buffer.y, 1)
        XCTAssertEqual(
            grinningFollower.buffer.lines[0].cells,
            [Cell(scalar: 0x1F600, width: 2), stub])
        XCTAssertEqual(
            grinningFollower.buffer.lines[1].cells,
            [Cell(scalar: 0x5A), Cell()])

        for lead in ["\u{2764}", "\u{2708}"] {
            let expanded = CmdyTerminal(cols: 2, rows: 1)
            expanded.feed(text: lead + "\u{1B}[1;1H\u{FE0F}")
            XCTAssertEqual(
                expanded.buffer.liveLine(0).cells,
                [Cell(scalar: UnicodeScalar(lead)!.value,
                      clusterExtras: [0xFE0F], width: 2),
                 Cell(scalar: 0, width: 0)])
            XCTAssertEqual(expanded.buffer.x, 1)

            let follower = CmdyTerminal(cols: 3, rows: 1)
            follower.feed(text: lead + "\u{1B}[1;1H\u{FE0F}Z")
            XCTAssertEqual(
                follower.buffer.liveLine(0).cells,
                [Cell(scalar: UnicodeScalar(lead)!.value,
                      clusterExtras: [0xFE0F], width: 2),
                 Cell(scalar: 0x5A), Cell()])
            XCTAssertEqual(follower.buffer.x, 2)
        }

        let completedZWJ = CmdyTerminal(cols: 3, rows: 1)
        completedZWJ.feed(text: "\u{1F469}\u{200D}\u{1F4BB}\u{FE0F}")
        XCTAssertEqual(
            completedZWJ.buffer.liveLine(0).cells,
            [Cell(scalar: 0x1F469,
                  clusterExtras: [0x200D, 0x1F4BB, 0xFE0F], width: 2),
             stub, Cell()])
        XCTAssertEqual(completedZWJ.buffer.x, 2)

        let completedZWJAtLead = CmdyTerminal(cols: 3, rows: 1)
        completedZWJAtLead.feed(text:
            "\u{2764}\u{FE0F}\u{1B}[r\u{200D}\u{2764}\u{FE0F}A")
        XCTAssertEqual(completedZWJAtLead.buffer.liveLine(0).cells, [
            Cell(scalar: 0x41),
            Cell(scalar: 0, width: 0),
            Cell(),
        ])
        XCTAssertEqual(completedZWJAtLead.buffer.x, 1)

        let rejected = CmdyTerminal(cols: 1, rows: 1)
        rejected.feed(text: "\u{1B}[?7l\u{1F680}\u{FE0F}")
        assertPlainRows(rejected, [[0]])
        XCTAssertEqual(rejected.buffer.x, 0)
    }

    func testRawC1IsInertButUTF8EncodedC1KeepsScalarSemantics() {
        let emojiSelector = Array("\u{FE0F}".utf8)
        for rawC1: UInt8 in [0x80, 0x9B] {
            let raw = CmdyTerminal(cols: 2, rows: 1)
            raw.feed([0x30, rawC1] + emojiSelector)
            XCTAssertEqual(
                raw.buffer.liveLine(0)[0],
                Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2))
            XCTAssertEqual(raw.buffer.x, 2)
        }

        let encoded = CmdyTerminal(cols: 2, rows: 1)
        encoded.feed([0x30, 0xC2, 0x80] + emojiSelector)
        XCTAssertEqual(encoded.buffer.liveLine(0)[0], Cell(scalar: 0x30))
        XCTAssertEqual(encoded.buffer.x, 1)
    }

    func testSelectorAuthorityAcrossZeroWidthAndRejectedWideFollowers() {
        for zeroWidth: UnicodeScalar in ["\u{301}", "\u{200D}"] {
            let suspended = CmdyTerminal(cols: 2, rows: 1)
            suspended.feed(text: "0" + String(zeroWidth) + "\u{FE0F}")
            XCTAssertEqual(
                suspended.buffer.liveLine(0)[0],
                Cell(scalar: 0x30, clusterExtras: [zeroWidth.value]))
            XCTAssertEqual(suspended.buffer.x, 1)
        }

        let rejected = CmdyTerminal(cols: 1, rows: 1)
        rejected.feed(text:
            "\u{1B}[?7l0\u{200D}\u{65E5}\u{FE0F}\u{301}")
        XCTAssertEqual(
            rejected.buffer.liveLine(0)[0],
            Cell(scalar: 0x30, clusterExtras: [0x200D, 0x301]))
        XCTAssertEqual(rejected.buffer.x, 1)

        let directOwner = CmdyTerminal(cols: 1, rows: 1)
        directOwner.feed(text:
            "\u{1B}[?7l\u{2764}\u{1F680}\u{FE0F}")
        XCTAssertEqual(
            directOwner.buffer.liveLine(0)[0],
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F]))
        XCTAssertEqual(directOwner.buffer.x, 1)

        let acceptedLaptop = CmdyTerminal(cols: 3, rows: 1)
        acceptedLaptop.feed(text: "0\u{1F4BB}\u{FE0E}")
        XCTAssertEqual(
            acceptedLaptop.buffer.liveLine(0)[1],
            Cell(scalar: 0x1F4BB, clusterExtras: [0xFE0E]))
        XCTAssertEqual(
            acceptedLaptop.buffer.liveLine(0)[2],
            Cell(
                scalar: 0, width: 0,
                attribute: CellAttribute(
                    fg: .defaultColor, bg: .defaultInverted)))
        XCTAssertEqual(acceptedLaptop.buffer.x, 2)

        let wrappedLaptop = CmdyTerminal(cols: 2, rows: 2)
        wrappedLaptop.feed(text: "0\u{1F4BB}\u{FE0E}")
        XCTAssertEqual(
            wrappedLaptop.buffer.liveLine(1).cells,
            [Cell(scalar: 0x1F4BB, clusterExtras: [0xFE0E]),
             Cell(
                scalar: 0, width: 0,
                attribute: CellAttribute(
                    fg: .defaultColor, bg: .defaultInverted))])
        XCTAssertEqual(wrappedLaptop.buffer.x, 1)
        XCTAssertEqual(wrappedLaptop.buffer.y, 1)

        let narrowCompletedZWJ = CmdyTerminal(cols: 4, rows: 1)
        narrowCompletedZWJ.feed(text:
            "\u{2764}\u{200D}\u{1F680}\u{FE0F}")
        XCTAssertEqual(
            narrowCompletedZWJ.buffer.liveLine(0)[0],
            Cell(scalar: 0x2764, clusterExtras: [0x200D, 0x1F680]))
        XCTAssertEqual(narrowCompletedZWJ.buffer.x, 1)

        let eligibleNarrowCompletedZWJ = CmdyTerminal(cols: 4, rows: 1)
        eligibleNarrowCompletedZWJ.feed(text:
            "\u{2764}\u{200D}\u{1F4BB}\u{FE0F}")
        XCTAssertEqual(
            eligibleNarrowCompletedZWJ.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x2764,
                clusterExtras: [0x200D, 0x1F4BB, 0xFE0F], width: 2))
        XCTAssertEqual(eligibleNarrowCompletedZWJ.buffer.x, 2)

        let wideCompletedZWJ = CmdyTerminal(cols: 3, rows: 1)
        wideCompletedZWJ.feed(text:
            "\u{1F469}\u{200D}\u{1F4BB}\u{FE0F}")
        XCTAssertEqual(
            wideCompletedZWJ.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x1F469,
                clusterExtras: [0x200D, 0x1F4BB, 0xFE0F], width: 2))
        XCTAssertEqual(wideCompletedZWJ.buffer.x, 2)

        for trailing in ["\u{1F680}", "\u{1F469}"] {
            for selector in ["\u{FE0E}", "\u{FE0F}"] {
                let fixedWidthCompletedZWJ = CmdyTerminal(cols: 3, rows: 1)
                fixedWidthCompletedZWJ.feed(text:
                    "\u{1F4BB}\u{200D}" + trailing + selector)
                XCTAssertEqual(
                    fixedWidthCompletedZWJ.buffer.liveLine(0)[0],
                    Cell(
                        scalar: 0x1F4BB,
                        clusterExtras: [
                            0x200D,
                            UnicodeScalar(trailing)!.value,
                        ],
                        width: 2))
                XCTAssertEqual(fixedWidthCompletedZWJ.buffer.x, 2)
            }
        }

        let consumedThenReauthorized = CmdyTerminal(cols: 4, rows: 1)
        consumedThenReauthorized.feed(text:
            "\u{2764}\u{FE0F}\u{200D}\u{2764}\u{FE0F}")
        XCTAssertEqual(
            consumedThenReauthorized.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x2764,
                clusterExtras: [0xFE0F, 0x200D, 0x2764, 0xFE0F],
                width: 2))
        XCTAssertEqual(consumedThenReauthorized.buffer.x, 2)
    }

    func testSelectorAuthorityReconstructsEligibleCompletedZWJAfterCellEdit() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed(text:
            "\u{2764}\u{FE0E}\u{200D}\u{1F4BB}")

        terminal.preservingClusterOwnerCoordinateThroughCellEdit(
            row: 0, columns: 0...0) {}
        terminal.feed(text: "\u{FE0F}")

        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x2764,
                clusterExtras: [0xFE0E, 0x200D, 0x1F4BB, 0xFE0F],
                width: 2))
        XCTAssertEqual(terminal.buffer.x, 2)

        let ineligible = CmdyTerminal(cols: 3, rows: 1)
        ineligible.feed(text:
            "\u{1F4BB}\u{200D}\u{1F680}")
        ineligible.preservingClusterOwnerCoordinateThroughCellEdit(
            row: 0, columns: 0...0) {}
        ineligible.feed(text: "\u{FE0F}")

        XCTAssertEqual(
            ineligible.buffer.liveLine(0)[0],
            Cell(
                scalar: 0x1F4BB,
                clusterExtras: [0x200D, 0x1F680], width: 2))
        XCTAssertEqual(ineligible.buffer.x, 2)

        let trailingSelector = CmdyTerminal(cols: 3, rows: 1)
        trailingSelector.feed(text: "\u{2764}\u{FE0F}")
        trailingSelector.preservingClusterOwnerCoordinateThroughCellEdit(
            row: 0, columns: 0...0) {}
        trailingSelector.feed(text: "\u{FE0E}")

        XCTAssertEqual(
            trailingSelector.buffer.liveLine(0)[0],
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2))
        XCTAssertEqual(trailingSelector.buffer.x, 2)
    }

    func testICHRefreshesOwnerAtPendingPhysicalEdge() {
        let terminal = CmdyTerminal(cols: 4, rows: 1)
        terminal.feed(text: " \u{65E5}Z\u{1B}[2@\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0)[0].scalar, 0)
        XCTAssertEqual(terminal.buffer.liveLine(0)[1].scalar, 0)
        XCTAssertEqual(terminal.buffer.liveLine(0)[2].scalar, 0x20)
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[3],
            Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2))
        XCTAssertEqual(terminal.buffer.x, 4)
    }

    func testICHRefreshesOwnerFromNarrowCellAtFixedCoordinate() {
        let terminal = CmdyTerminal(cols: 4, rows: 1)
        terminal.feed(text: " \u{65E5}Z\u{1B}[3@\u{301}")

        XCTAssertEqual(terminal.buffer.liveLine(0)[0].scalar, 0)
        XCTAssertEqual(terminal.buffer.liveLine(0)[1].scalar, 0)
        XCTAssertEqual(terminal.buffer.liveLine(0)[2].scalar, 0)
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[3],
            Cell(scalar: 0x20, clusterExtras: [0x301]))
    }

    func testICHInvalidatesOwnerWhenFixedCoordinateBecomesWideContinuation() {
        let terminal = CmdyTerminal(cols: 4, rows: 1)
        terminal.feed(text: " \u{65E5}Z\u{1B}[@\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0)[2].scalar, 0x65E5)
        XCTAssertNil(terminal.buffer.liveLine(0)[2].clusterExtras)
        XCTAssertEqual(terminal.buffer.liveLine(0)[3].width, 0)
    }

    func testICHRefreshesSelectorAuthorityFromShiftedOwner() {
        let terminal = CmdyTerminal(cols: 4, rows: 1)
        terminal.feed(text: "  \u{2764}Z\u{1B}[@\u{FE0F}")

        XCTAssertEqual(terminal.buffer.liveLine(0)[3].scalar, 0x2764)
        XCTAssertEqual(terminal.buffer.liveLine(0)[3].clusterExtras, [0xFE0F])

        let afterWideTail = CmdyTerminal(cols: 4, rows: 1)
        afterWideTail.feed(text: " \u{2764}\u{65E5}\u{1B}[@\u{FE0F}")
        XCTAssertEqual(afterWideTail.buffer.liveLine(0)[2].scalar, 0x2764)
        XCTAssertEqual(afterWideTail.buffer.liveLine(0)[2].clusterExtras, [0xFE0F])
        XCTAssertEqual(afterWideTail.buffer.x, 5)
    }

    func testICHPendingActiveMarginIsNoOpButHiddenMarginsUsePhysicalEdge() {
        let active = CmdyTerminal(cols: 5, rows: 1)
        active.setPrivateMode(69, true)
        active.buffer.marginLeft = 1
        active.buffer.marginRight = 3
        active.buffer.x = 1
        active.feed(text: "\u{65E5}Z\u{1B}[2@\u{200D}")

        XCTAssertEqual(active.buffer.liveLine(0)[1].scalar, 0x65E5)
        XCTAssertEqual(active.buffer.liveLine(0)[3].scalar, 0x5A)
        XCTAssertEqual(active.buffer.liveLine(0)[3].clusterExtras, [0x200D])

        let hidden = CmdyTerminal(cols: 4, rows: 1)
        hidden.setPrivateMode(69, true)
        hidden.buffer.marginLeft = 1
        hidden.buffer.marginRight = 2
        hidden.setPrivateMode(69, false)
        hidden.feed(text: " \u{65E5}Z\u{1B}[2@\u{200D}")

        XCTAssertEqual(
            hidden.buffer.liveLine(0)[3],
            Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2))
    }

    func testICHPendingFullWidthActiveMarginRemainsNoOp() {
        let terminal = CmdyTerminal(cols: 4, rows: 1)
        terminal.setPrivateMode(69, true)
        terminal.buffer.marginLeft = 0
        terminal.buffer.marginRight = 3
        terminal.feed(text: " \u{65E5}Z\u{1B}[2@\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0)[0].scalar, 0x20)
        XCTAssertEqual(terminal.buffer.liveLine(0)[1].scalar, 0x65E5)
        XCTAssertEqual(terminal.buffer.liveLine(0)[3].scalar, 0x5A)
        XCTAssertEqual(terminal.buffer.liveLine(0)[3].clusterExtras, [0x200D])
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testICHParkedPhysicalEdgeRefreshesOwnerWithAutoWrapDisabled() {
        let terminal = CmdyTerminal(cols: 4, rows: 1)
        terminal.setPrivateMode(7, false)
        terminal.feed(text: " \u{65E5}Z\u{1B}[2@\u{200D}")

        XCTAssertEqual(
            terminal.buffer.liveLine(0)[3],
            Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2))
        XCTAssertFalse(terminal.buffer.wrapPending)
        XCTAssertEqual(terminal.buffer.x, 4)
    }

    func testICHLeavesOwnerStrictlyLeftOfSettledInsertionUntouched() {
        let terminal = CmdyTerminal(cols: 5, rows: 1)
        terminal.feed(text: "A\u{1B}[3G\u{1B}[@\u{301}")

        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell(scalar: 0x41, clusterExtras: [0x301]))
        XCTAssertEqual(terminal.buffer.x, 2)
    }

    func testPendingOwnerRowMutationKeepsVS16OnNewWrappedBase() {
        let inserted = CmdyTerminal(cols: 4, rows: 4)
        inserted.feed(text:
            "\u{1B}[2;1H...A\u{1B}[L\u{2764}\u{FE0F}")
        XCTAssertEqual(inserted.buffer.liveLine(2)[3].scalar, 0x41)
        XCTAssertEqual(inserted.buffer.liveLine(2)[0].scalar, 0x2764)
        XCTAssertEqual(inserted.buffer.liveLine(2)[0].clusterExtras, [0xFE0F])
        XCTAssertEqual(inserted.buffer.liveLine(2)[0].width, 2)
        XCTAssertEqual(inserted.buffer.liveLine(2)[1].width, 0)
        XCTAssertEqual(inserted.buffer.y, 2)
        XCTAssertEqual(inserted.buffer.x, 2)

        let scrolledDown = CmdyTerminal(cols: 4, rows: 4)
        scrolledDown.feed(text:
            "\u{1B}[2;1H...A\u{1B}[T\u{2764}\u{FE0F}")
        XCTAssertEqual(scrolledDown.buffer.liveLine(2)[3].scalar, 0x41)
        XCTAssertEqual(scrolledDown.buffer.liveLine(2)[0].scalar, 0x2764)
        XCTAssertEqual(scrolledDown.buffer.liveLine(2)[0].clusterExtras, [0xFE0F])
        XCTAssertEqual(scrolledDown.buffer.y, 2)
        XCTAssertEqual(scrolledDown.buffer.x, 2)

        let scrolledUp = CmdyTerminal(cols: 4, rows: 4)
        scrolledUp.feed(text:
            "\u{1B}[3;1H...A\u{1B}[S\u{2764}\u{FE0F}")
        XCTAssertEqual(scrolledUp.buffer.liveLine(1)[3].scalar, 0x41)
        XCTAssertEqual(scrolledUp.buffer.liveLine(3)[0].scalar, 0x2764)
        XCTAssertEqual(scrolledUp.buffer.liveLine(3)[0].clusterExtras, [0xFE0F])
        XCTAssertEqual(scrolledUp.buffer.y, 3)
        XCTAssertEqual(scrolledUp.buffer.x, 2)
    }

    func testPendingOwnerICHClippingDoesNotRelocateLaterVS16() {
        let oneColumn = CmdyTerminal(cols: 1, rows: 3)
        oneColumn.feed(text: "A\u{1B}[@\u{2764}\u{FE0F}")
        XCTAssertEqual(oneColumn.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(oneColumn.buffer.liveLine(1)[0].scalar, 0x2764)
        XCTAssertEqual(oneColumn.buffer.liveLine(1)[0].clusterExtras, [0xFE0F])
        XCTAssertEqual(oneColumn.buffer.y, 1)
        XCTAssertEqual(oneColumn.buffer.x, 1)

        let twoColumnControl = CmdyTerminal(cols: 2, rows: 3)
        twoColumnControl.feed(text: ".A\u{1B}[@\u{2764}\u{FE0F}")
        XCTAssertEqual(twoColumnControl.buffer.liveLine(0)[1].scalar, 0x2E)
        XCTAssertEqual(twoColumnControl.buffer.liveLine(1)[0].scalar, 0x2764)
        XCTAssertEqual(twoColumnControl.buffer.liveLine(1)[0].clusterExtras, [0xFE0F])
        XCTAssertEqual(twoColumnControl.buffer.liveLine(1)[0].width, 2)
        XCTAssertEqual(twoColumnControl.buffer.liveLine(1)[1].width, 0)
        XCTAssertEqual(twoColumnControl.buffer.y, 1)
        XCTAssertEqual(twoColumnControl.buffer.x, 2)
    }

    func testNoWrapParkedOwnerClippedByICHDoesNotRelocateLaterVS16() {
        let terminal = CmdyTerminal(cols: 2, rows: 2)
        terminal.feed(text:
            "\u{1B}[?7l\u{1B}[3g\u{1B}[2I \u{1B}[2@" +
            "\u{1B}[?7h\u{2764}\u{FE0F}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(
            terminal.buffer.liveLine(1).cells,
            [
                Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
                Cell(scalar: 0, width: 0),
            ])
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.x, 2)

        let ascii = CmdyTerminal(cols: 2, rows: 2)
        ascii.feed(text:
            "\u{1B}[?7l\u{1B}[1;2H \u{1B}[@" +
            "\u{1B}[?7h0\u{FE0F}")
        XCTAssertEqual(ascii.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(
            ascii.buffer.liveLine(1).cells,
            [
                Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
                Cell(scalar: 0, width: 0),
            ])
        XCTAssertEqual(ascii.buffer.y, 1)
        XCTAssertEqual(ascii.buffer.x, 2)
    }

    func testUnchangedPendingOwnerStillAllowsVS16Relocation() {
        let unchanged = CmdyTerminal(cols: 4, rows: 4)
        unchanged.feed(text:
            "\u{1B}[2;1H...A\u{2764}\u{FE0F}")
        XCTAssertEqual(unchanged.buffer.liveLine(1)[3].scalar, 0x41)
        XCTAssertEqual(unchanged.buffer.liveLine(2)[0].scalar, 0x2764)
        XCTAssertEqual(unchanged.buffer.liveLine(2)[0].clusterExtras, [0xFE0F])
        XCTAssertEqual(unchanged.buffer.y, 2)
        XCTAssertEqual(unchanged.buffer.x, 2)

        let positioned = CmdyTerminal(cols: 4, rows: 4)
        positioned.feed(text:
            "\u{1B}[2;1H...A\u{1B}[2;1H\u{2764}\u{FE0F}")
        XCTAssertEqual(positioned.buffer.liveLine(1)[3].scalar, 0x41)
        XCTAssertEqual(positioned.buffer.liveLine(1)[0].scalar, 0x2764)
        XCTAssertEqual(positioned.buffer.liveLine(1)[0].clusterExtras, [0xFE0F])
        XCTAssertEqual(positioned.buffer.y, 1)
        XCTAssertEqual(positioned.buffer.x, 2)
    }

    func testPendingWrapBelowTopRegionRetainsOwnerRowGeneration() {
        let bottomOwner = CmdyTerminal(cols: 4, rows: 4)
        bottomOwner.feed(text:
            "\u{1B}[1;3r\u{1B}[4;1H..\u{65E5}\u{2764}\u{FE0F}")
        XCTAssertEqual(bottomOwner.buffer.lineCount, 5)
        XCTAssertEqual(bottomOwner.buffer.yBase, 1)
        XCTAssertEqual(bottomOwner.buffer.y, 3)
        XCTAssertEqual(bottomOwner.buffer.x, 2)
        XCTAssertEqual(bottomOwner.buffer.lines[3].cells, [Cell(), Cell(), Cell(), Cell()])
        XCTAssertEqual(bottomOwner.buffer.lines[4][0].scalar, 0x2764)
        XCTAssertEqual(bottomOwner.buffer.lines[4][0].clusterExtras, [0xFE0F])
        XCTAssertEqual(bottomOwner.buffer.lines[4][2].scalar, 0x65E5)
        XCTAssertEqual(bottomOwner.buffer.lines[4][3].width, 0)

        let nonbottomOwner = CmdyTerminal(cols: 4, rows: 4)
        nonbottomOwner.feed(text:
            "\u{1B}[1;2r\u{1B}[3;1H...A\u{2764}\u{FE0F}")
        XCTAssertEqual(nonbottomOwner.buffer.lineCount, 5)
        XCTAssertEqual(nonbottomOwner.buffer.yBase, 1)
        XCTAssertEqual(nonbottomOwner.buffer.y, 2)
        XCTAssertEqual(nonbottomOwner.buffer.lines[2].cells, [Cell(), Cell(), Cell(), Cell()])
        XCTAssertEqual(nonbottomOwner.buffer.lines[3][0].scalar, 0x2764)
        XCTAssertEqual(nonbottomOwner.buffer.lines[3][3].scalar, 0x41)
    }

    func testPendingWrapBelowInsetRegionStopsBeforePhysicalBottom() {
        let nonbottomOwner = CmdyTerminal(cols: 4, rows: 5)
        nonbottomOwner.feed(text:
            "\u{1B}[2;3r\u{1B}[4;1H...A\u{2764}\u{FE0F}")
        XCTAssertEqual(nonbottomOwner.buffer.lineCount, 5)
        XCTAssertEqual(nonbottomOwner.buffer.yBase, 0)
        XCTAssertEqual(nonbottomOwner.buffer.y, 3)
        XCTAssertEqual(nonbottomOwner.buffer.x, 2)
        XCTAssertEqual(nonbottomOwner.buffer.liveLine(3)[0].scalar, 0x2764)
        XCTAssertEqual(nonbottomOwner.buffer.liveLine(3)[3].scalar, 0x41)

        let physicalBottom = CmdyTerminal(cols: 4, rows: 5)
        physicalBottom.feed(text:
            "\u{1B}[2;3r\u{1B}[5;1H...A\u{2764}\u{FE0F}")
        XCTAssertEqual(physicalBottom.buffer.lineCount, 5)
        XCTAssertEqual(physicalBottom.buffer.yBase, 0)
        XCTAssertEqual(physicalBottom.buffer.y, 4)
        XCTAssertEqual(physicalBottom.buffer.x, 2)
        XCTAssertEqual(physicalBottom.buffer.liveLine(4)[0].scalar, 0x2764)
        XCTAssertEqual(physicalBottom.buffer.liveLine(4)[3].scalar, 0x41)
    }

    func testFastASCIIBaseRefreshesPendingOwnerProvenance() {
        for coalescesASCII in [true, false] {
            let terminal = CmdyTerminal(cols: 4, rows: 5)
            terminal.parser.coalescesPrintableASCII = coalescesASCII
            terminal.feed(text:
                "\u{1B}[2;1H...A\u{2764}abc\u{1B}[L#\u{FE0F}")

            XCTAssertEqual(terminal.buffer.liveLine(1)[3].scalar, 0x41)
            XCTAssertEqual(
                terminal.buffer.liveLine(3)[0],
                Cell(scalar: 0x23, clusterExtras: [0xFE0F], width: 2),
                "coalescesASCII=\(coalescesASCII)")
            XCTAssertEqual(terminal.buffer.liveLine(3)[1].width, 0)
            XCTAssertEqual(terminal.buffer.y, 3)
            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }
    }

    func testContractedRightMarginInvalidatesStrandedPendingOwner() {
        let terminal = CmdyTerminal(cols: 4, rows: 3)
        terminal.feed(text:
            "\u{1B}[?69h\u{1B}[1;4s\u{1B}[1;4HA" +
            "\u{1B}[1;3s\u{2764}\u{FE0F}")

        XCTAssertEqual(terminal.buffer.liveLine(0)[3].scalar, 0x41)
        XCTAssertEqual(
            terminal.buffer.liveLine(1)[0],
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2))
        XCTAssertEqual(terminal.buffer.liveLine(1)[1].width, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testForwardIndexConsumedPendingDoesNotRelocateAfterMarginContraction() {
        let terminal = CmdyTerminal(cols: 5, rows: 2)
        terminal.feed(text:
            "\u{1B}[?69h\u{1B}[2I \u{1B}9\u{1B}[1;4s" +
            "\u{2764}\u{FE0F}")

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [Cell(), Cell(), Cell(), Cell(), Cell(scalar: 0x20)])
        XCTAssertEqual(
            terminal.buffer.liveLine(1)[0],
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2))
        XCTAssertEqual(terminal.buffer.liveLine(1)[1].width, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.x, 2)
    }

    func testFirstAcceptedEmojiSelectorWins() {
        let cases: [(String, [UInt32], Int8, Int)] = [
            ("\u{2764}\u{FE0F}\u{FE0F}", [0xFE0F], 2, 2),
            ("\u{2764}\u{FE0E}\u{FE0E}", [0xFE0E], 1, 1),
            ("\u{2764}\u{FE0E}\u{FE0F}", [0xFE0E], 1, 1),
            ("\u{2764}\u{FE0F}\u{FE0E}", [0xFE0F], 2, 2),
        ]
        for (text, extras, width, cursor) in cases {
            let terminal = CmdyTerminal(cols: 4, rows: 2)
            terminal.feed(text: text)
            XCTAssertEqual(
                terminal.buffer.liveLine(0)[0],
                Cell(scalar: 0x2764, clusterExtras: extras, width: width),
                text)
            XCTAssertEqual(terminal.buffer.x, cursor, text)
        }

        let joined = CmdyTerminal(cols: 4, rows: 2)
        joined.feed(text:
            "\u{1F469}\u{200D}\u{1F4BB}\u{FE0E}\u{FE0F}")
        XCTAssertEqual(
            joined.buffer.liveLine(0)[0],
            Cell(scalar: 0x1F469,
                 clusterExtras: [0x200D, 0x1F4BB, 0xFE0E], width: 1))
        XCTAssertEqual(joined.buffer.x, 1)
    }

    func testWideFollowerAfterZWJRequiresAnEligibleEmojiLead() {
        let parkedZeroZWJ = "\u{1B}[?7l0\u{200D}"

        for (wide, follower) in [
            ("\u{1F469}", "\u{200D}"),
            ("\u{1F680}", "\u{200D}"),
            ("\u{1F4BB}", "\u{301}"),
        ] {
            let rejected = CmdyTerminal(cols: 1, rows: 1)
            rejected.feed(text: parkedZeroZWJ + wide + follower)
            XCTAssertEqual(
                rejected.buffer.liveLine(0).cells,
                [Cell(scalar: 0x30,
                      clusterExtras: [0x200D, UnicodeScalar(follower)!.value])])
            XCTAssertEqual(rejected.buffer.x, 1)
        }

        let stub = Cell(
            scalar: 0, width: 0,
            attribute: CellAttribute(fg: .defaultColor, bg: .defaultInverted))
        for (wide, scalar, follower) in [
            ("\u{1F680}", UInt32(0x1F680), ""),
            ("\u{1F469}", UInt32(0x1F469), "\u{301}"),
            ("\u{1F4BB}", UInt32(0x1F4BB), "\u{200D}"),
        ] {
            let accepted = CmdyTerminal(cols: 3, rows: 1)
            accepted.feed(text: parkedZeroZWJ + wide + follower)
            XCTAssertEqual(
                accepted.buffer.liveLine(0).cells,
                [Cell(scalar: 0x30, clusterExtras: [0x200D]),
                 Cell(scalar: scalar,
                      clusterExtras: follower.isEmpty
                          ? nil
                          : [UnicodeScalar(follower)!.value],
                      width: 2),
                 stub])
            XCTAssertEqual(accepted.buffer.x, 3)
        }

        let rejectedCJK = CmdyTerminal(cols: 1, rows: 1)
        rejectedCJK.feed(text: parkedZeroZWJ + "\u{65E5}\u{200D}")
        XCTAssertEqual(
            rejectedCJK.buffer.liveLine(0).cells,
            [Cell(scalar: 0x30, clusterExtras: [0x200D, 0x200D])])
        XCTAssertEqual(rejectedCJK.buffer.x, 1)

        let acceptedCJK = CmdyTerminal(cols: 3, rows: 1)
        acceptedCJK.feed(text: parkedZeroZWJ + "\u{65E5}\u{200D}")
        XCTAssertEqual(
            acceptedCJK.buffer.liveLine(0).cells,
            [Cell(scalar: 0x30, clusterExtras: [0x200D]),
             Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2),
             stub])
        XCTAssertEqual(acceptedCJK.buffer.x, 3)

        let firstMark = CmdyTerminal(cols: 1, rows: 1)
        firstMark.feed(text: "\u{1B}[?7l0\u{301}\u{1F469}\u{200D}")
        XCTAssertEqual(
            firstMark.buffer.liveLine(0).cells,
            [Cell(scalar: 0x30, clusterExtras: [0x301, 0x200D])])
        XCTAssertEqual(firstMark.buffer.x, 1)

        let eligible = CmdyTerminal(cols: 2, rows: 1)
        eligible.feed(text: "\u{1B}[?7l\u{1F469}\u{200D}\u{1F4BB}")
        XCTAssertEqual(
            eligible.buffer.liveLine(0).cells,
            [Cell(scalar: 0x1F469, clusterExtras: [0x200D, 0x1F4BB], width: 2),
             stub])
        XCTAssertEqual(eligible.buffer.x, 2)
    }

    func testKeycapBaseVS16DoesNotBecomeZWJComponentLead() {
        let wrapped = CmdyTerminal(cols: 1, rows: 3)
        wrapped.feed(text:
            "0\u{FE0F}\u{200D}\u{1F469}\u{200D}\u{1F4BB}a")
        XCTAssertEqual(
            wrapped.buffer.liveLine(0).cells,
            [Cell(scalar: 0x30, clusterExtras: [0xFE0F, 0x200D])])
        XCTAssertEqual(
            wrapped.buffer.liveLine(1).cells,
            [Cell(scalar: 0x1F469,
                  clusterExtras: [0x200D, 0x1F4BB], width: 2)])
        XCTAssertEqual(
            wrapped.buffer.liveLine(2).cells,
            [Cell(scalar: 0x61)])
        XCTAssertEqual(wrapped.buffer.x, 1)
        XCTAssertEqual(wrapped.buffer.y, 2)
        XCTAssertTrue(wrapped.buffer.wrapPending)

        let rejected = CmdyTerminal(cols: 1, rows: 1)
        rejected.feed(text:
            "\u{1B}[?7l0\u{FE0F}\u{200D}\u{1F469}\u{301}")
        XCTAssertEqual(
            rejected.buffer.liveLine(0).cells,
            [Cell(scalar: 0x30,
                  clusterExtras: [0xFE0F, 0x200D, 0x301])])
        XCTAssertEqual(rejected.buffer.x, 1)
        XCTAssertFalse(rejected.buffer.wrapPending)
    }

    func testIndexIsNoOpStrictlyRightOfStoredHorizontalMargin() {
        let hiddenSettled = CmdyTerminal(cols: 2, rows: 1)
        hiddenSettled.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{1B}[?69l\u{1B}[1;2H\u{1B}D")
        XCTAssertEqual(hiddenSettled.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(hiddenSettled.buffer.x, 1)
        XCTAssertEqual(hiddenSettled.buffer.y, 0)
        XCTAssertEqual(hiddenSettled.buffer.lineCount, 1)
        XCTAssertEqual(hiddenSettled.buffer.yBase, 0)

        let activeSettled = CmdyTerminal(cols: 2, rows: 1)
        activeSettled.feed(text: " \u{1B}[?69h\u{1B}[1;1s\u{1B}D")
        XCTAssertEqual(
            activeSettled.buffer.liveLine(0).cells,
            [Cell(scalar: 0x20), Cell()])
        XCTAssertEqual(activeSettled.buffer.x, 1)
        XCTAssertEqual(activeSettled.buffer.y, 0)
        XCTAssertEqual(activeSettled.buffer.lineCount, 1)
        XCTAssertEqual(activeSettled.buffer.yBase, 0)

        for hidesMargins in [false, true] {
            let pending = CmdyTerminal(cols: 2, rows: 1)
            pending.feed(text: "AB\u{1B}[?69h\u{1B}[1;1s")
            if hidesMargins { pending.feed(text: "\u{1B}[?69l") }
            pending.feed(text: "\u{1B}D")

            XCTAssertEqual(
                pending.buffer.liveLine(0).cells,
                [Cell(scalar: 0x41), Cell(scalar: 0x42)])
            XCTAssertEqual(pending.buffer.x, 1)
            XCTAssertEqual(pending.buffer.y, 0)
            XCTAssertEqual(pending.buffer.lineCount, 1)
            XCTAssertEqual(pending.buffer.yBase, 0)

            let noWrap = CmdyTerminal(cols: 2, rows: 1)
            noWrap.feed(text: "\u{1B}[?7lAB\u{1B}[?69h\u{1B}[1;1s")
            if hidesMargins { noWrap.feed(text: "\u{1B}[?69l") }
            noWrap.feed(text: "\u{1B}D")

            XCTAssertEqual(
                noWrap.buffer.liveLine(0).cells,
                [Cell(scalar: 0x41), Cell(scalar: 0x42)])
            XCTAssertEqual(noWrap.buffer.x, 1)
            XCTAssertEqual(noWrap.buffer.y, 0)
            XCTAssertEqual(noWrap.buffer.lineCount, 1)
            XCTAssertEqual(noWrap.buffer.yBase, 0)
        }
    }

    func testIndexUsesStoredHorizontalGateAcrossVerticalRegions() {
        func seeded(_ rows: [String]) -> CmdyTerminal {
            let terminal = CmdyTerminal(cols: 2, rows: rows.count)
            for (row, text) in rows.enumerated() {
                terminal.feed(text: "\u{1B}[\(row + 1);1H" + text)
            }
            return terminal
        }

        for hidesMargins in [false, true] {
            let nonBottomPending = CmdyTerminal(cols: 2, rows: 2)
            nonBottomPending.feed(text: "AB\u{1B}[?69h\u{1B}[1;1s")
            if hidesMargins { nonBottomPending.feed(text: "\u{1B}[?69l") }
            nonBottomPending.feed(text: "\u{1B}D")
            XCTAssertEqual(
                nonBottomPending.buffer.liveLine(0).cells,
                [Cell(scalar: 0x41), Cell(scalar: 0x42)])
            XCTAssertEqual(nonBottomPending.buffer.liveLine(1).cells, [Cell(), Cell()])
            XCTAssertEqual(nonBottomPending.buffer.x, 1)
            XCTAssertEqual(nonBottomPending.buffer.y, 1)
            XCTAssertEqual(nonBottomPending.buffer.lineCount, 2)
            XCTAssertEqual(nonBottomPending.buffer.yBase, 0)
        }

        let bottomOutsideLeft = CmdyTerminal(cols: 2, rows: 1)
        bottomOutsideLeft.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[?69l\u{1B}[1;1H\u{1B}D")
        XCTAssertEqual(bottomOutsideLeft.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(bottomOutsideLeft.buffer.x, 0)
        XCTAssertEqual(bottomOutsideLeft.buffer.y, 0)
        XCTAssertEqual(bottomOutsideLeft.buffer.lineCount, 1)
        XCTAssertEqual(bottomOutsideLeft.buffer.yBase, 0)

        let belowOutsideLeft = CmdyTerminal(cols: 2, rows: 3)
        belowOutsideLeft.feed(text:
            "\u{1B}[1;2r\u{1B}[?69h\u{1B}[2;2s\u{1B}[?69l" +
            "\u{1B}[3;1H\u{1B}D")
        for row in 0..<3 {
            XCTAssertEqual(belowOutsideLeft.buffer.liveLine(row).cells, [Cell(), Cell()])
        }
        XCTAssertEqual(belowOutsideLeft.buffer.x, 0)
        XCTAssertEqual(belowOutsideLeft.buffer.y, 2)
        XCTAssertEqual(belowOutsideLeft.buffer.lineCount, 3)
        XCTAssertEqual(belowOutsideLeft.buffer.yBase, 0)

        let activePartial = seeded(["AX", "BY"])
        activePartial.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{1B}[2;1H\u{1B}D")
        XCTAssertEqual(
            activePartial.buffer.liveLine(0).cells,
            [Cell(scalar: 0x42), Cell(scalar: 0x58)])
        XCTAssertEqual(
            activePartial.buffer.liveLine(1).cells,
            [Cell(), Cell(scalar: 0x59)])
        XCTAssertEqual(activePartial.buffer.x, 0)
        XCTAssertEqual(activePartial.buffer.y, 1)
        XCTAssertEqual(activePartial.buffer.lineCount, 2)
        XCTAssertEqual(activePartial.buffer.yBase, 0)

        for hidesMargins in [true, false] {
            let fullScroll = seeded(["AX", "BY"])
            fullScroll.feed(text: "\u{1B}[?69h")
            fullScroll.feed(text: hidesMargins ? "\u{1B}[1;1s\u{1B}[?69l" : "\u{1B}[1;2s")
            fullScroll.feed(text: "\u{1B}[2;1H\u{1B}D")
            XCTAssertEqual(
                fullScroll.buffer.line(absolute: 0)?.cells,
                [Cell(scalar: 0x41), Cell(scalar: 0x58)])
            XCTAssertEqual(
                fullScroll.buffer.line(absolute: 1)?.cells,
                [Cell(scalar: 0x42), Cell(scalar: 0x59)])
            XCTAssertEqual(fullScroll.buffer.line(absolute: 2)?.cells, [Cell(), Cell()])
            XCTAssertEqual(fullScroll.buffer.x, 0)
            XCTAssertEqual(fullScroll.buffer.y, 1)
            XCTAssertEqual(fullScroll.buffer.lineCount, 3)
            XCTAssertEqual(fullScroll.buffer.yBase, 1)
        }

        let belowActivePartial = seeded(["AX", "BY", "CZ"])
        belowActivePartial.feed(text:
            "\u{1B}[1;2r\u{1B}[?69h\u{1B}[1;1s\u{1B}[3;1H\u{1B}D")
        XCTAssertEqual(
            belowActivePartial.buffer.liveLine(0).cells,
            [Cell(scalar: 0x42), Cell(scalar: 0x58)])
        XCTAssertEqual(
            belowActivePartial.buffer.liveLine(1).cells,
            [Cell(), Cell(scalar: 0x59)])
        XCTAssertEqual(
            belowActivePartial.buffer.liveLine(2).cells,
            [Cell(scalar: 0x43), Cell(scalar: 0x5A)])
        XCTAssertEqual(belowActivePartial.buffer.x, 0)
        XCTAssertEqual(belowActivePartial.buffer.y, 2)
        XCTAssertEqual(belowActivePartial.buffer.lineCount, 3)
        XCTAssertEqual(belowActivePartial.buffer.yBase, 0)

        for hidesMargins in [false, true] {
            let lowerRegion = seeded(["AX", "BY", "CZ"])
            lowerRegion.feed(text: "\u{1B}[2;3r\u{1B}[?69h\u{1B}[1;1s")
            if hidesMargins { lowerRegion.feed(text: "\u{1B}[?69l") }
            lowerRegion.feed(text: "\u{1B}[3;1H\u{1B}D")
            XCTAssertEqual(
                lowerRegion.buffer.liveLine(0).cells,
                [Cell(scalar: 0x41), Cell(scalar: 0x58)])
            XCTAssertEqual(
                lowerRegion.buffer.liveLine(1).cells,
                hidesMargins
                    ? [Cell(scalar: 0x43), Cell(scalar: 0x5A)]
                    : [Cell(scalar: 0x43), Cell(scalar: 0x59)])
            XCTAssertEqual(
                lowerRegion.buffer.liveLine(2).cells,
                hidesMargins ? [Cell(), Cell()] : [Cell(), Cell(scalar: 0x5A)])
            XCTAssertEqual(lowerRegion.buffer.x, 0)
            XCTAssertEqual(lowerRegion.buffer.y, 2)
            XCTAssertEqual(lowerRegion.buffer.lineCount, 3)
            XCTAssertEqual(lowerRegion.buffer.yBase, 0)
        }
    }

    func testLineFeedAndReverseIndexUseStoredGateWithRawEdgeOrdering() {
        typealias MotionCase = (
            name: String,
            cols: Int,
            rows: Int,
            stream: String,
            expected: [[Cell]],
            cursor: (x: Int, y: Int),
            lineCount: Int,
            yBase: Int
        )
        let blank = Cell()
        let a = Cell(scalar: UnicodeScalar("A").value)
        let b = Cell(scalar: UnicodeScalar("B").value)
        let x = Cell(scalar: UnicodeScalar("X").value)
        let y = Cell(scalar: UnicodeScalar("Y").value)

        let cases: [MotionCase] = [
            (
                "one-column parked LF gates before physical normalization",
                1, 1, "\u{1B}[?7lA\n", [[a]], (0, 0), 1, 0
            ),
            (
                "one-column parked RI normalizes then reverses",
                1, 1, "\u{1B}[?7lA\u{1B}M", [[blank]], (0, 0), 1, 0
            ),
            (
                "active one-column parked RI uses the normalized column",
                1, 1, "\u{1B}[?7l\u{1B}[?69hA\u{1B}M",
                [[blank]], (0, 0), 1, 0
            ),
            (
                "settled one-column RI control",
                1, 1, "A\u{1B}[H\u{1B}M", [[blank]], (0, 0), 1, 0
            ),
            (
                "pending internal LF advances and consumes pending",
                3, 2, "\u{1B}[?69h\u{1B}[1;2s\u{1B}[1;2HA\n",
                [[blank, a, blank], [blank, blank, blank]], (2, 1), 2, 0
            ),
            (
                "full-width parked LF advances after raw gate",
                2, 2, "\u{1B}[?69h\u{1B}[1;2s\u{1B}[?7l\u{1B}[1;2HA\n",
                [[blank, a], [blank, blank]], (1, 1), 2, 0
            ),
            (
                "full-width parked RI shifts the rectangle",
                2, 2,
                "\u{1B}[?69h\u{1B}[1;2s\u{1B}[?7l\u{1B}[1;2HA\u{1B}M",
                [[blank, blank], [blank, a]], (1, 0), 2, 0
            ),
            (
                "hidden settled RI remains gated by stored right",
                3, 2,
                "A\u{1B}[?69h\u{1B}[1;2s\u{1B}[?69l\u{1B}[1;3H\u{1B}M",
                [[a, blank, blank], [blank, blank, blank]], (2, 0), 2, 0
            ),
            (
                "hidden settled LF at physical bottom is a no-op",
                3, 2,
                "\u{1B}[2;1HB\u{1B}[?69h\u{1B}[1;2s" +
                    "\u{1B}[?69l\u{1B}[2;3H\n",
                [[blank, blank, blank], [b, blank, blank]], (2, 1), 2, 0
            ),
            (
                "active settled LF at physical bottom is a no-op",
                3, 2,
                "\u{1B}[2;1HB\u{1B}[?69h\u{1B}[1;2s\u{1B}[2;3H\n",
                [[blank, blank, blank], [b, blank, blank]], (2, 1), 2, 0
            ),
            (
                "hidden parked RI clamps physical edge before gating",
                3, 2,
                "\u{1B}[?69h\u{1B}[1;2s\u{1B}[?69l" +
                    "\u{1B}[?7l\u{1B}[1;3HA\u{1B}M",
                [[blank, blank, a], [blank, blank, blank]], (2, 0), 2, 0
            ),
            (
                "hidden parked LF gates raw physical edge",
                3, 2,
                "\u{1B}[?69h\u{1B}[1;2s\u{1B}[?69l" +
                    "\u{1B}[?7l\u{1B}[2;3HA\n",
                [[blank, blank, blank], [blank, blank, a]], (2, 1), 2, 0
            ),
            (
                "active parked LF preserves the stored rectangle",
                3, 2,
                "\u{1B}[1;1HX\u{1B}[2;1HY\u{1B}[?69h" +
                    "\u{1B}[1;2s\u{1B}[?7l\u{1B}[2;2HA\n",
                [[x, blank, blank], [y, a, blank]], (2, 1), 2, 0
            ),
            (
                "pending LF above the region advances physically",
                2, 3,
                "\u{1B}[2;3r\u{1B}[?69h\u{1B}[1;1s\u{1B}[1;2HA\n",
                [[blank, blank], [a, blank], [blank, blank]], (1, 2), 3, 0
            ),
            (
                "pending LF below the region stays at physical bottom",
                2, 3,
                "\u{1B}[1;2r\u{1B}[?69h\u{1B}[1;1s\u{1B}[3;2HA\n",
                [[blank, blank], [blank, blank], [a, blank]], (1, 2), 3, 0
            ),
            (
                "hidden stored-edge print gates bottom LF",
                2, 2,
                "\u{1B}[?69h\u{1B}[1;1s\u{1B}[?69l\u{1B}[2;1HA\n",
                [[blank, blank], [a, blank]], (1, 1), 2, 0
            ),
            (
                "physical parked RI moves the cursor without shifting rows",
                2, 2, "\u{1B}[?7l\u{1B}[2;2HA\u{1B}M",
                [[blank, blank], [blank, a]], (1, 0), 2, 0
            ),
            (
                "physical parked LF at bottom is a no-op",
                2, 2, "\u{1B}[?7l\u{1B}[2;2HA\n",
                [[blank, blank], [blank, a]], (1, 1), 2, 0
            ),
        ]

        for testCase in cases {
            let terminal = CmdyTerminal(cols: testCase.cols, rows: testCase.rows)
            terminal.feed(text: testCase.stream)

            XCTAssertEqual(
                (0..<testCase.rows).map { terminal.buffer.liveLine($0).cells },
                testCase.expected,
                testCase.name)
            XCTAssertEqual(terminal.buffer.x, testCase.cursor.x, testCase.name)
            XCTAssertEqual(terminal.buffer.y, testCase.cursor.y, testCase.name)
            XCTAssertEqual(terminal.buffer.lineCount, testCase.lineCount, testCase.name)
            XCTAssertEqual(terminal.buffer.yBase, testCase.yBase, testCase.name)
            XCTAssertFalse(terminal.buffer.wrapPending, testCase.name)
        }
    }

    func testLineFeedAndReverseIndexPreserveWideRowsOutsideStoredGate() {
        let blank = Cell()
        let wide = Cell(scalar: UnicodeScalar("日").value, width: 2)
        let secondWide = Cell(scalar: UnicodeScalar("界").value, width: 2)
        let continuation = Cell(
            scalar: 0, width: 0, attribute: CmdyTerminal.stubAttribute)

        let hiddenRI = CmdyTerminal(cols: 3, rows: 2)
        hiddenRI.feed(text:
            "日\u{1B}[?69h\u{1B}[1;2s\u{1B}[?69l\u{1B}[1;3H\u{1B}M")
        XCTAssertEqual(
            hiddenRI.buffer.liveLine(0).cells,
            [wide, continuation, blank])
        XCTAssertEqual(hiddenRI.buffer.liveLine(1).cells, [blank, blank, blank])
        XCTAssertEqual(hiddenRI.buffer.x, 2)
        XCTAssertEqual(hiddenRI.buffer.y, 0)
        XCTAssertFalse(hiddenRI.buffer.wrapPending)

        let activeLF = CmdyTerminal(cols: 3, rows: 2)
        activeLF.feed(text:
            "\u{1B}[1;1H日\u{1B}[2;1H界\u{1B}[?69h" +
                "\u{1B}[1;2s\u{1B}[?7l\u{1B}[2;2HA\n")
        XCTAssertEqual(
            activeLF.buffer.liveLine(0).cells,
            [wide, continuation, blank])
        XCTAssertEqual(
            activeLF.buffer.liveLine(1).cells,
            [secondWide, Cell(scalar: UnicodeScalar("A").value), blank])
        XCTAssertEqual(activeLF.buffer.x, 2)
        XCTAssertEqual(activeLF.buffer.y, 1)
        XCTAssertFalse(activeLF.buffer.wrapPending)
    }

    func testPrintFromPhysicalRightBelowRegionScrollsActiveStoredColumns() {
        let blank = Cell()
        let a = Cell(scalar: UnicodeScalar("A").value)
        let y = Cell(scalar: UnicodeScalar("Y").value)
        let markerSetup =
            "\u{1B}[1;1HX\u{1B}[2;1HY\u{1B}[3;1HZ" +
            "\u{1B}[1;2r\u{1B}[?69h\u{1B}[1;1s\u{1B}[3;2HA"

        let reverse = CmdyTerminal(cols: 2, rows: 3)
        reverse.feed(text: markerSetup + "\u{1B}M")
        XCTAssertEqual(reverse.buffer.liveLine(0).cells, [y, blank])
        XCTAssertEqual(reverse.buffer.liveLine(1).cells, [blank, blank])
        XCTAssertEqual(reverse.buffer.liveLine(2).cells, [a, blank])
        XCTAssertEqual(reverse.buffer.x, 1)
        XCTAssertEqual(reverse.buffer.y, 1)
        XCTAssertFalse(reverse.buffer.wrapPending)

        let index = CmdyTerminal(cols: 2, rows: 3)
        index.feed(text: markerSetup + "\u{1B}D")
        XCTAssertEqual(index.buffer.liveLine(0).cells, [y, blank])
        XCTAssertEqual(index.buffer.liveLine(1).cells, [blank, blank])
        XCTAssertEqual(index.buffer.liveLine(2).cells, [a, blank])
        XCTAssertEqual(index.buffer.x, 1)
        XCTAssertEqual(index.buffer.y, 2)
        XCTAssertFalse(index.buffer.wrapPending)

        let belowThenReverse = CmdyTerminal(cols: 2, rows: 4)
        belowThenReverse.feed(text:
            "\u{1B}[1;2r\u{1B}[?69h\u{1B}[1;1s" +
                "\u{1B}[3;2HA\u{1B}M")
        XCTAssertEqual(belowThenReverse.buffer.liveLine(0).cells, [blank, blank])
        XCTAssertEqual(belowThenReverse.buffer.liveLine(1).cells, [blank, blank])
        XCTAssertEqual(belowThenReverse.buffer.liveLine(2).cells, [a, blank])
        XCTAssertEqual(belowThenReverse.buffer.liveLine(3).cells, [blank, blank])
        XCTAssertEqual(belowThenReverse.buffer.x, 1)
        XCTAssertEqual(belowThenReverse.buffer.y, 1)
        XCTAssertFalse(belowThenReverse.buffer.wrapPending)
    }

    func testPrintBelowRegionScrollPreservesWideContinuationSlices() {
        let blank = Cell()
        let wide = Cell(scalar: UnicodeScalar("界").value, width: 2)
        let continuation = Cell(
            scalar: 0, width: 0, attribute: CmdyTerminal.stubAttribute)
        let terminal = CmdyTerminal(cols: 2, rows: 3)
        terminal.feed(text:
            "\u{1B}[1;1H日\u{1B}[2;1H界\u{1B}[3;1H語" +
                "\u{1B}[1;2r\u{1B}[?69h\u{1B}[1;1s\u{1B}[3;2HA")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [wide, continuation])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [blank, continuation])
        XCTAssertEqual(
            terminal.buffer.liveLine(2).cells,
            [Cell(scalar: UnicodeScalar("A").value), continuation])
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 2)
        XCTAssertTrue(terminal.buffer.wrapPending)
        XCTAssertEqual(terminal.buffer.lineCount, 3)
        XCTAssertEqual(terminal.buffer.yBase, 0)
    }

    func testLineFeedConsumesPendingWrapWithoutAddingRow() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed([0x5A, 0x0A])

        XCTAssertEqual(terminal.bufferLineCount, 1)
        XCTAssertEqual(terminal.liveScreenTopRow, 0)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell(scalar: 0x5A))
    }

    func testLineFeedPendingWrapPreservesExplicitRowThroughClampedResize() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x61, 0x0A])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.bufferLineCount, 2)

        terminal.resize(cols: 1, rows: 1)

        XCTAssertEqual(terminal.buffer.cols, 2)
        XCTAssertEqual(terminal.buffer.rows, 1)
        XCTAssertEqual(terminal.bufferLineCount, 2)
        XCTAssertEqual(terminal.liveScreenTopRow, 1)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertEqual(terminal.scrollbackLineText(row: 0), "a")
        XCTAssertEqual(terminal.scrollbackLineText(row: 1), "")
    }

    func testReverseIndexNormalizesPendingWrapOnDestinationRow() {
        let terminal = CmdyTerminal(cols: 2, rows: 2)
        terminal.feed([0x09, 0x08, 0x30, 0x41, 0x1B, 0x4D, 0x20])

        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            [Cell(), Cell(scalar: 0x20)])
        XCTAssertEqual(
            terminal.buffer.liveLine(1).cells,
            [Cell(scalar: 0x30), Cell(scalar: 0x41)])
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testReverseIndexNormalizesPendingWrapToPhysicalRightEdge() {
        let terminal = CmdyTerminal(cols: 10, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x68])
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x39, 0x73])
        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5B, 0x39, 0x47])
        terminal.feed([0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F])
        XCTAssertEqual(terminal.buffer.x, 10)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.wrapPending)

        terminal.feed([0x1B, 0x4D])

        XCTAssertEqual(terminal.buffer.x, 9)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            Array(repeating: Cell(), count: 10))
        var expectedSecondRow = Array(repeating: Cell(), count: 10)
        expectedSecondRow[8] = Cell(
            scalar: 0x2764, clusterExtras: [0xFE0F], width: 2)
        expectedSecondRow[9] = Cell(scalar: 0, width: 0)
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, expectedSecondRow)
    }

    func testReverseIndexPreservesPendingColumnInsidePhysicalScreen() {
        let terminal = CmdyTerminal(cols: 12, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x68])
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x39, 0x73])
        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5B, 0x39, 0x47])
        terminal.feed([0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F])
        XCTAssertEqual(terminal.buffer.x, 10)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.wrapPending)

        terminal.feed([0x1B, 0x4D])

        XCTAssertEqual(terminal.buffer.x, 10)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
        XCTAssertEqual(
            terminal.buffer.liveLine(0).cells,
            Array(repeating: Cell(), count: 12))
        var expectedSecondRow = Array(repeating: Cell(), count: 12)
        expectedSecondRow[8] = Cell(
            scalar: 0x2764, clusterExtras: [0xFE0F], width: 2)
        expectedSecondRow[9] = Cell(scalar: 0, width: 0)
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, expectedSecondRow)
    }

    func testReverseIndexRefreshesOwnerAtRotatedCoordinate() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed(text: " A\u{1B}M\u{1B}M\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
            Cell(scalar: 0x20, clusterExtras: [0x200D]),
        ])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testReverseIndexRefreshesWideLeadAtRotatedCoordinate() {
        let terminal = CmdyTerminal(cols: 2, rows: 2)
        terminal.feed(text: "\u{754C}A\u{1B}M\u{1B}M\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
            Cell(scalar: 0x754C, clusterExtras: [0x200D], width: 2),
            Cell(scalar: 0, width: 0, attribute: CmdyTerminal.stubAttribute),
        ])
    }

    func testReverseIndexDoesNotAdoptRotatedWideContinuation() {
        let terminal = CmdyTerminal(cols: 2, rows: 2)
        terminal.feed(text:
            "\u{754C}\u{1B}[2;2HA\u{1B}M\u{1B}M\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
            Cell(scalar: 0x754C, width: 2),
            Cell(scalar: 0, width: 0, attribute: CmdyTerminal.stubAttribute),
        ])
    }

    func testReverseIndexDoesNotSynthesizeOwnerAtBlankRotatedCoordinate() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed(text:
            "\u{1B}[2;1HA\u{1B}M\u{1B}M\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [Cell()])
    }

    func testReverseIndexBlankIntermediateAllowsLaterOwnerRefresh() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed(text:
            "X\u{1B}[3;1HA\u{1B}[1;1H" +
                "\u{1B}M\u{1B}M\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(2).cells, [
            Cell(scalar: 0x58, clusterExtras: [0x200D]),
        ])
    }

    func testReverseIndexBlankIntermediatePreservesSameScalarOwner() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed(text:
            "A\u{1B}[3;1HA\u{1B}[1;1H" +
                "\u{1B}M\u{1B}M\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(2).cells, [
            Cell(scalar: 0x41, clusterExtras: [0x200D]),
        ])
    }

    func testReverseIndexOwnerReturnsAfterTemporaryTopRowReplacement() {
        for temporary in ["A", "\u{65E5}"] {
            let terminal = CmdyTerminal(cols: 2, rows: 3)
            terminal.feed(text:
                "\n0\u{1B}[?6h\u{1B}[2r\u{1B}M" +
                    temporary + "\n\n\u{FE0F}")

            XCTAssertEqual(terminal.buffer.liveLine(0).cells,
                           [Cell(), Cell()])
            XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
                Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
                Cell(scalar: 0, width: 0),
            ])
            XCTAssertEqual(terminal.buffer.liveLine(2).cells,
                           [Cell(), Cell()])
            XCTAssertEqual(terminal.buffer.x, 2)
            XCTAssertEqual(terminal.buffer.y, 2)
        }

        let recycled = CmdyTerminal(cols: 1, rows: 1)
        recycled.feed(text:
            "\u{1B}[3g\t0\u{1B}M0A\u{301}")
        XCTAssertEqual(recycled.buffer.lineCount, 2)
        XCTAssertEqual(recycled.buffer.line(absolute: 0)?.cells, [
            Cell(scalar: 0x30),
        ])
        XCTAssertEqual(recycled.buffer.liveLine(0).cells, [
            Cell(scalar: 0x41, clusterExtras: [0x301]),
        ])

        let returnedDuringNewBase = CmdyTerminal(cols: 5, rows: 5)
        returnedDuringNewBase.feed(text:
            "\u{1B}[2;5r\n\u{1B}[3g \u{1B}M\u{1B}M" +
                "\n\n\n\n\u{1B}[2I\u{1F1FA}\u{1F1F8}")
        XCTAssertEqual(returnedDuringNewBase.buffer.liveLine(1)[0],
                       Cell(scalar: 0x20))
        XCTAssertEqual(returnedDuringNewBase.buffer.liveLine(4).cells, [
            Cell(scalar: 0x1F1FA,
                 clusterExtras: [0x1F1F8], width: 2),
            Cell(scalar: 0, width: 0,
                 attribute: CmdyTerminal.stubAttribute),
            Cell(), Cell(), Cell(),
        ])
    }

    func testReverseIndexOwnerDoesNotReturnAfterBaseAtDifferentCoordinate() {
        let terminal = CmdyTerminal(cols: 2, rows: 3)
        terminal.feed(text:
            "\u{1B}[2r\n \u{1B}M \u{1B}[2B\n\u{0301}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells,
                       [Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
            Cell(scalar: 0x20), Cell(),
        ])
        XCTAssertEqual(terminal.buffer.liveLine(2).cells,
                       [Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.y, 2)
    }

    func testNoWrapPhysicalEdgeCursorUpKeepsSelectorOnLandedRow() {
        for (base, scalar) in [("\u{2764}", UInt32(0x2764)),
                               ("1", UInt32(0x31))] {
            for interposed in ["", "\u{65E5}", "\u{0301}"] {
                let terminal = CmdyTerminal(cols: 2, rows: 2)
                terminal.feed(text:
                    "\u{1B}[?7l\n  " + interposed +
                        "\u{1B}[?7h\u{1B}[A" + base + "\u{FE0F}")

                XCTAssertEqual(terminal.buffer.liveLine(0).cells,
                               [Cell(), Cell()])
                XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
                    Cell(scalar: scalar,
                         clusterExtras: [0xFE0F], width: 2),
                    Cell(scalar: 0, width: 0),
                ])
                XCTAssertEqual(terminal.buffer.x, 2)
                XCTAssertEqual(terminal.buffer.y, 1)
                XCTAssertTrue(terminal.buffer.wrapPending)
            }
        }
    }

    func testBackwardIndexOwnerRefreshPreservesSelectorCursorTrajectory() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed(text: "0 \r\u{1B}6\u{FE0F}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, attribute: CmdyTerminal.stubAttribute),
            Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ])
        XCTAssertEqual(terminal.buffer.x, 1)

        terminal.feed(text: "\u{1B}6")
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, attribute: CmdyTerminal.stubAttribute),
            Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ])
        XCTAssertEqual(terminal.buffer.x, 0)
    }

    func testNoOpAbsoluteCursorCommandPreservesSelectorTrajectory() {
        let forward = CmdyTerminal(cols: 5, rows: 2)
        forward.feed(text:
            "\u{2764}\u{1B}[C\u{1B}[1;3H\u{FE0F}")
        XCTAssertEqual(forward.buffer.x, 3)

        let backward = CmdyTerminal(cols: 5, rows: 2)
        backward.feed(text:
            "A\u{2764}\r\u{1B}[1;1H\u{FE0F}")
        XCTAssertEqual(backward.buffer.x, 1)
    }

    func testCarriageReturnPreservesHistoricalSelectorWidthTrajectory() {
        let terminal = CmdyTerminal(cols: 2, rows: 1)
        terminal.feed(text: "0\n\r\u{FE0F}")

        XCTAssertEqual(terminal.buffer.lines[0].cells, [
            Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
            Cell(width: 0),
        ])
        XCTAssertEqual(terminal.buffer.x, 1)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 1)

        terminal.feed(text: "\u{2764}\u{FE0F}")
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(), Cell(scalar: 0x2764, clusterExtras: [0xFE0F]),
        ])
        XCTAssertEqual(terminal.buffer.x, 2)
    }

    func testInsertLinesRefreshesOwnerAtAffectedDestination() {
        let terminal = CmdyTerminal(cols: 2, rows: 5)
        terminal.feed(text:
            "A\u{1B}[2;1HB\u{1B}[3;1HC\u{1B}[4;1HD" +
                "\u{1B}[5;1HE\u{1B}[2;1H\u{1B}[2L\u{0301}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells,
                       [Cell(scalar: 0x41), Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells,
                       [Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(2).cells,
                       [Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(3).cells,
                       [Cell(scalar: 0x42), Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(4).cells, [
            Cell(scalar: 0x43, clusterExtras: [0x0301]), Cell(),
        ])
    }

    func testInsertLinesOwnerReactivatesAfterMatchingUpwardScrolls() {
        let terminal = CmdyTerminal(cols: 1, rows: 4)
        terminal.feed(text:
            "\u{1B}[2;5r\n \u{1B}[2L\u{1B}[2B\n\n\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
            Cell(scalar: 0x20, clusterExtras: [0x200D]),
        ])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 3)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testInsertLinesOwnerReactivatesAfterMatchingDeleteLines() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed(text: " \u{1B}[2L\u{1B}[2M\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, clusterExtras: [0x200D]),
        ])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIDoesNotReplaceDormantInsertLineOwnerOnAnotherRow() {
        let terminal = CmdyTerminal(cols: 6, rows: 2)
        terminal.feed(text:
            "\u{1B}[2;6H \u{65E5}\u{65E5}\u{65E5}" +
            "\u{1B}[?69h\u{65E5}\u{65E5}   \u{1B}M" +
            "\u{1B}[1;4s\t\u{1B}[2L\u{1B}9\u{0301}")

        XCTAssertEqual(terminal.buffer.line(absolute: 3)?.cells, [
            Cell(), Cell(), Cell(), Cell(scalar: 0x20),
            Cell(scalar: 0x20), Cell(),
        ])
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 3)
    }

    func testDECFIRestoresDormantInsertLineOwnerAtSameCoordinate() {
        let terminal = CmdyTerminal(cols: 10, rows: 1)
        terminal.feed(text:
            "\u{1B}[2;6H  \u{1B}[?69h\u{65E5} " +
            "\u{1B}[2;9s\u{1B}[2I \t\u{1B}[2L\u{1B}9\u{0301}")

        var expected = Array(repeating: Cell(), count: 10)
        expected[8] = Cell(scalar: 0x20, clusterExtras: [0x0301])
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertEqual(terminal.buffer.x, 8)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIRestoresDormantInsertLineOwnerFromIntermediateCell() {
        let terminal = CmdyTerminal(cols: 11, rows: 1)
        terminal.feed(text:
            "\u{1B}[2;6H  \u{1B}[?69h\u{65E5} " +
            "\u{1B}[2;9s\u{1B}[2I \t\u{1B}[2L\u{1B}9\u{0301}")

        var expected = Array(repeating: Cell(), count: 11)
        expected[8] = Cell(scalar: 0x20, clusterExtras: [0x0301])
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertEqual(terminal.buffer.x, 8)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testDECFIDoesNotReplaceSameRowDormantOwnerWithUnrelatedTail() {
        let terminal = CmdyTerminal(cols: 9, rows: 1)
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        terminal.feed(text:
            "\u{1B}[2;6H  \n\u{65E5}\u{65E5}\u{1B}[?69h" +
            "\u{65E5}\u{65E5}   \u{1B}[1;4s\u{1B}[2A\u{1B}[2B" +
            "\r \t\u{1B}[2L\u{1B}9\u{0301}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(), Cell(), Cell(), Cell(scalar: 0x65E5, width: 2),
            Cell(width: 0, attribute: stub),
            Cell(scalar: 0x20), Cell(scalar: 0x20),
            Cell(scalar: 0x20), Cell(),
        ])
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testInsertDeleteCellsRoundTripRestoresAttachmentOwner() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed(text: " \r\u{1B}[2@\u{1B}[2P\u{0301}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, clusterExtras: [0x0301]),
            Cell(), Cell(),
        ])
        XCTAssertEqual(terminal.buffer.x, 0)
    }

    func testInsertDeleteCellsRoundTripRestoresSelectorCursorOffset() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed(text:
            "\u{1B}[1;2H0\u{1B}[1;1H\u{1B}[@\u{1B}[P\u{FE0F}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(), Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
            Cell(width: 0),
        ])
        XCTAssertEqual(terminal.buffer.x, 1)
    }

    func testDeleteLinesThenBackwardIndexRestoresIncomingOwner() {
        let terminal = CmdyTerminal(cols: 3, rows: 2)
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        terminal.feed(text:
            "\u{1B}[2;1H\u{1F469}\u{200D}\u{1F4BB}" +
                "\u{1B}[1;2H \u{1B}[1;1H\u{1B}[M\u{1B}6\u{FE0F}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, attribute: stub),
            Cell(scalar: 0x1F469,
                 clusterExtras: [0x200D, 0x1F4BB, 0xFE0F], width: 2),
            Cell(width: 0, attribute: stub),
        ])
    }

    func testDeleteLinesRefreshesOwnerBelowCursorAfterVerticalMotion() {
        let terminal = CmdyTerminal(cols: 4, rows: 3)
        terminal.feed(text:
            "\u{1B}[3;3H\u{65E5}\u{1B}[2;3HA" +
                "\u{1B}M\u{1B}[M\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(), Cell(), Cell(scalar: 0x41), Cell(),
        ])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
            Cell(), Cell(),
            Cell(scalar: 0x65E5, clusterExtras: [0x200D], width: 2),
            Cell(
                scalar: 0, width: 0,
                attribute: CmdyTerminal.stubAttribute),
        ])
        XCTAssertEqual(terminal.buffer.liveLine(2).cells,
                       Array(repeating: Cell(), count: 4))
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDeleteLinesThenRepeatedBackwardIndexRestoresGeneratedBlankOwner() {
        let terminal = CmdyTerminal(cols: 3, rows: 2)
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        terminal.feed(text:
            "\u{1B}[1;2H \u{1B}[1;1H\u{1B}[M\u{1B}6\u{1B}6\u{0301}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, attribute: stub),
            Cell(scalar: 0x20, clusterExtras: [0x0301], attribute: stub),
            Cell(),
        ])
    }

    func testInsertLinesThenBackwardIndexRestoresGeneratedBlankOwner() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        let stub = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
        terminal.feed(text: " \r\u{1B}[2L\u{1B}6\u{0301}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x20, clusterExtras: [0x0301], attribute: stub),
        ])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testRejectedWideBetweenJoinerAndComponentDoesNotBlockSelector() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed(text:
            "\u{1B}[?7l\u{2764}\u{200D}\u{65E5}\u{2764}\u{FE0F}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x2764,
                 clusterExtras: [0x200D, 0x2764, 0xFE0F]),
        ])
        XCTAssertEqual(terminal.buffer.x, 1)
    }

    func testLineFeedRefreshesOwnerAtScrolledCoordinate() {
        let terminal = CmdyTerminal(cols: 2, rows: 3)
        terminal.feed(text:
            "\u{1B}[2;3r\u{1B}[3;1H0" +
                "\u{1B}[2;1HA\u{1B}[B\n\u{FE0F}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells,
                       [Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
            Cell(scalar: 0x30, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
        ])
        XCTAssertEqual(terminal.buffer.liveLine(2).cells,
                       [Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 2)
    }

    func testForwardLineScrollInvalidatesOwnerAtIncomingWideContinuation() {
        for motion in ["\n", "\u{1B}D"] {
            let terminal = CmdyTerminal(cols: 2, rows: 3)
            terminal.feed(text:
                "\u{1B}[2;3r" +
                    "\u{1B}[3;1H\u{2764}\u{FE0F}" +
                    "\u{1B}[2;2H\u{2764}\r\u{1B}[B" +
                    motion +
                    "\u{200D}")

            XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
                Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
                Cell(scalar: 0, width: 0),
            ])
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, 2)
            XCTAssertFalse(terminal.buffer.wrapPending)
        }
    }

    func testForwardLineScrollAdoptsByteIdenticalNormalBufferOwner() {
        for motion in ["\n", "\u{1B}D"] {
            let terminal = CmdyTerminal(cols: 3, rows: 3)
            terminal.feed(text:
                "\u{1B}[2;3r" +
                    "\u{1B}[3;2H\u{2764}" +
                    "\u{1B}[2;2H\u{2764}" +
                    motion + motion +
                    "\u{FE0F}")

            XCTAssertEqual(terminal.buffer.liveLine(1).cells, [
                Cell(),
                Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
                Cell(scalar: 0, width: 0),
            ])
            XCTAssertEqual(terminal.buffer.x, 3)
            XCTAssertEqual(terminal.buffer.y, 2)
            XCTAssertTrue(terminal.buffer.wrapPending)
        }
    }

    func testForwardIndexRevivesOwnerAfterIntermediateContinuation() {
        let terminal = CmdyTerminal(cols: 5, rows: 1)
        terminal.feed(text:
            "\u{1B}[1;5Hm\u{1B}[1;3H\u{2764}\u{FE0F}" +
                "\u{1B}[1;5H\u{1B}9\u{1B}9\u{200D}")

        XCTAssertEqual(terminal.buffer.liveLine(0).cells, [
            Cell(scalar: 0x2764, clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
            Cell(scalar: 0x6D, clusterExtras: [0x200D]),
            Cell(), Cell(),
        ])
        XCTAssertEqual(terminal.buffer.x, 4)
    }

    func testBufferRoundtripAdoptsHistoricalOwnerAtForeignCoordinate() {
        func exercise(startingInAlternateBuffer: Bool) -> CmdyTerminal {
            let terminal = CmdyTerminal(cols: 1, rows: 5)
            if startingInAlternateBuffer {
                terminal.feed(text: "\u{1B}[?1049h")
            }
            terminal.feed(text:
                " \u{1B}[5;1H\u{65E5}" +
                    String(repeating: "\u{1B}M", count: 6))
            if startingInAlternateBuffer {
                terminal.feed(text:
                    "\u{1B}[?1049lZ\u{1B}[?1049h\u{0301}")
            } else {
                terminal.feed(text:
                    "\u{1B}[?1049hZ\u{1B}[?1049l\u{0301}")
            }
            return terminal
        }

        for startsAlternate in [false, true] {
            let terminal = exercise(
                startingInAlternateBuffer: startsAlternate)
            XCTAssertEqual(terminal.buffer.yBase, 1)
            XCTAssertEqual(
                terminal.buffer.line(absolute: 0)?[0],
                Cell(scalar: 0x20, clusterExtras: [0x0301]))
        }
    }

    func testReverseIndexAtTopOutsideHorizontalMarginsIsNoOp() {
        let terminal = CmdyTerminal(cols: 10, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x39, 0x73])
        terminal.feed([0x41, 0x58])
        terminal.feed([0x1B, 0x5B, 0x31, 0x30, 0x47])
        XCTAssertEqual(terminal.buffer.x, 9)

        terminal.feed([0x1B, 0x4D])

        var expected = Array(repeating: Cell(), count: 10)
        expected[0] = Cell(scalar: 0x41)
        expected[1] = Cell(scalar: 0x58)
        XCTAssertEqual(terminal.buffer.liveLine(0).cells, expected)
        XCTAssertEqual(terminal.buffer.x, 9)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testReverseIndexAtTopPendingBeyondHorizontalMarginIsNoOp() {
        let terminal = CmdyTerminal(cols: 3, rows: 3)
        terminal.feed(text: "\u{1B}[?69h")
        terminal.feed(text: "\u{1B}[2;3r")
        terminal.feed(text: "\u{1B}[2;2s")
        terminal.feed(text: "\u{1B}[2;2Ha")
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.wrapPending)

        terminal.feed(text: "\u{1B}M")

        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertFalse(terminal.buffer.wrapPending)
        for row in 0..<3 {
            var expected = Array(repeating: Cell(), count: 3)
            if row == 1 { expected[1] = Cell(scalar: UnicodeScalar("a").value) }
            XCTAssertEqual(terminal.buffer.liveLine(row).cells, expected)
        }
        XCTAssertEqual(terminal.buffer.lineCount, 3)
        XCTAssertEqual(terminal.buffer.yBase, 0)

        let physicalEdge = CmdyTerminal(cols: 3, rows: 3)
        physicalEdge.feed(text: "\u{1B}[?69h")
        physicalEdge.feed(text: "\u{1B}[2;3r")
        physicalEdge.feed(text: "\u{1B}[2;3s")
        physicalEdge.feed(text: "\u{1B}[2;2Hab")
        XCTAssertEqual(physicalEdge.buffer.x, 3)
        XCTAssertTrue(physicalEdge.buffer.wrapPending)

        physicalEdge.feed(text: "\u{1B}M")

        XCTAssertEqual(physicalEdge.buffer.x, 2)
        XCTAssertEqual(physicalEdge.buffer.y, 1)
        XCTAssertFalse(physicalEdge.buffer.wrapPending)
        XCTAssertEqual(physicalEdge.buffer.liveLine(1).cells, [Cell(), Cell(), Cell()])
        XCTAssertEqual(
            physicalEdge.buffer.liveLine(2).cells,
            [Cell(), Cell(scalar: UnicodeScalar("a").value),
             Cell(scalar: UnicodeScalar("b").value)])
    }

    func testReverseIndexAtTopWithSingleColumnEdgeMargins() {
        let cases: [(
            marginColumn: Int,
            markerColumn: Int,
            finalCursorColumn: Int?,
            pendingAfterRI: Bool
        )] = [
            (1, 1, nil, false),
            (1, 1, 2, false),
            (2, 2, 1, false),
        ]

        for testCase in cases {
            let terminal = CmdyTerminal(cols: 2, rows: 2)
            terminal.feed(text: "\u{1B}[?69h")
            terminal.feed(text:
                "\u{1B}[\(testCase.marginColumn);\(testCase.marginColumn)s")
            terminal.feed(text: "\u{1B}[1;\(testCase.markerColumn)Ha")
            if let finalCursorColumn = testCase.finalCursorColumn {
                terminal.feed(text: "\u{1B}[1;\(finalCursorColumn)H")
            }

            terminal.feed(text: "\u{1B}M")

            XCTAssertEqual(terminal.buffer.marginLeft, testCase.marginColumn - 1)
            XCTAssertEqual(terminal.buffer.marginRight, testCase.marginColumn - 1)
            XCTAssertEqual(terminal.buffer.y, 0)
            XCTAssertEqual(
                terminal.buffer.x,
                (testCase.finalCursorColumn ?? testCase.markerColumn + 1) - 1)
            XCTAssertEqual(terminal.buffer.wrapPending, testCase.pendingAfterRI)
            var expectedTop = [Cell(), Cell()]
            expectedTop[testCase.markerColumn - 1] = Cell(
                scalar: UnicodeScalar("a").value)
            XCTAssertEqual(terminal.buffer.liveLine(0).cells, expectedTop)
            XCTAssertEqual(terminal.buffer.liveLine(1).cells, [Cell(), Cell()])
            XCTAssertEqual(terminal.buffer.lineCount, 2)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testIndexNormalizesPendingWrapBeforeFollowingNarrowCell() {
        let terminal = CmdyTerminal(cols: 4, rows: 2)
        terminal.feed([
            0x09, 0x61, 0x1B, 0x44,
            0xE2, 0x9D, 0xA4, 0xEF, 0xB8, 0x8F,
            0x20, 0x30, 0x08, 0x30, 0x61,
            0x1B, 0x4D, 0x20,
        ])

        XCTAssertEqual(
            terminal.buffer.line(absolute: 0)?.cells,
            [Cell(), Cell(), Cell(), Cell(scalar: 0x61)])
        XCTAssertEqual(
            terminal.buffer.line(absolute: 1)?.cells,
            [Cell(), Cell(), Cell(), Cell(scalar: 0x20)])
        XCTAssertEqual(
            terminal.buffer.line(absolute: 2)?.cells,
            [Cell(scalar: 0x20), Cell(scalar: 0x30), Cell(scalar: 0x61), Cell()])
        XCTAssertEqual(terminal.bufferLineCount, 3)
        XCTAssertEqual(terminal.liveScreenTopRow, 1)
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testIndexNormalizesPendingWrapColumnAcrossParserChunks() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x5A])
        terminal.feed([0x1B])
        terminal.feed([0x44])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell(scalar: 0x5A))
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testIndexNormalizesNoWrapCursorPastRightEdge() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x37, 0x6C])
        terminal.feed([0x30])
        terminal.feed([0x1B, 0x44])

        XCTAssertEqual(terminal.bufferLineCount, 2)
        XCTAssertEqual(terminal.scrollbackLineText(row: 0), "0")
        XCTAssertEqual(terminal.scrollbackLineText(row: 1), "")
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 1)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testIndexPreservesPhysicalColumnOutsideHorizontalMargins() {
        let terminal = CmdyTerminal(cols: 10, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x68])
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x39, 0x73])
        XCTAssertEqual(terminal.buffer.marginLeft, 1)
        XCTAssertEqual(terminal.buffer.marginRight, 8)
        terminal.feed([0x1B, 0x5B, 0x31, 0x30, 0x47])
        XCTAssertEqual(terminal.buffer.x, 9)
        XCTAssertEqual(terminal.buffer.y, 0)

        terminal.feed([0x1B, 0x44])

        XCTAssertEqual(terminal.buffer.x, 9)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertFalse(terminal.buffer.wrapPending)
        for row in 0..<2 {
            XCTAssertEqual(
                terminal.buffer.liveLine(row).cells,
                Array(repeating: Cell(), count: 10))
        }
    }

    func testIndexRetainsLastWriteForCombiningMarkAndJoiner() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed([0x41])
        terminal.feed([0x1B, 0x44])
        terminal.feed([0xCC, 0x81])
        terminal.feed([0x42])
        terminal.feed([0x1B, 0x44])
        terminal.feed([0xE2, 0x80, 0x8D])

        XCTAssertEqual(terminal.bufferLineCount, 3)
        XCTAssertEqual(
            terminal.buffer.line(absolute: 0)?[0],
            Cell(scalar: 0x41, clusterExtras: [0x0301]))
        XCTAssertEqual(
            terminal.buffer.line(absolute: 1)?[0],
            Cell(scalar: 0x42, clusterExtras: [0x200D]))
        XCTAssertEqual(terminal.buffer.line(absolute: 2)?[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.yBase + terminal.buffer.y, 2)
        XCTAssertFalse(terminal.buffer.wrapPending)
    }

    func testEngineScrollTransformsFullAndNarrowRegions() {
        let full = CmdyTerminal(cols: 5, rows: 5)
        full.buffer.scrollTop = 1
        full.buffer.scrollBottom = 3
        for row in 0..<5 { seedRow(full, row: row, scalars: [UInt32(65 + row), 0, 0, 0, 0]) }
        full.engineScrollUp(markNewWrapped: true)
        XCTAssertEqual(full.buffer.liveLine(0)[0].scalar, 65)
        XCTAssertEqual(full.buffer.liveLine(1)[0].scalar, 67)
        XCTAssertEqual(full.buffer.liveLine(2)[0].scalar, 68)
        XCTAssertEqual(full.buffer.liveLine(3)[0].scalar, 0)
        XCTAssertTrue(full.buffer.liveLine(3).isWrapped)
        XCTAssertEqual(full.buffer.liveLine(4)[0].scalar, 69)

        let narrow = configuredMarginTerminal()
        let before = matrix(narrow)
        narrow.engineScrollUp(markNewWrapped: true)
        assertOutsideRectangleUnchanged(narrow, before: before)
        assertSlice(narrow, row: 1, equals: Array(before[2][1...4]))
        assertSlice(narrow, row: 2, equals: Array(before[3][1...4]))
        assertSlice(narrow, row: 3, equals: [0, 0, 0, 0])
        XCTAssertTrue(narrow.buffer.liveLine(3).isWrapped)

        let narrowDown = configuredMarginTerminal()
        let beforeDown = matrix(narrowDown)
        narrowDown.engineScrollDown()
        assertOutsideRectangleUnchanged(narrowDown, before: beforeDown)
        assertSlice(narrowDown, row: 1, equals: [0, 0, 0, 0])
        assertSlice(narrowDown, row: 2, equals: Array(beforeDown[1][1...4]))
        assertSlice(narrowDown, row: 3, equals: Array(beforeDown[2][1...4]))
    }

    func testDeleteLineUnderHorizontalMarginModeUsesDefaultFill() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed(Array("\u{1B}[?69h\u{1B}[48:5:99m\n\u{1B}[M".utf8))

        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
    }

    func testDeleteLineIsNoOpForPendingCustomHorizontalMargins() {
        let pendingCases: [(row: Int, count: Int)] = [(1, 1), (2, 3), (3, 2)]
        for testCase in pendingCases {
            let terminal = CmdyTerminal(cols: 4, rows: 3)
            terminal.feed(text: "\u{1B}[?69h\u{1B}[2;3s")
            terminal.feed(text: "\u{1B}[\(testCase.row);2HAB")
            terminal.feed(text: "\u{1B}[\(testCase.count)M")

            for row in 0..<3 {
                XCTAssertEqual(
                    terminal.buffer.liveLine(row).cells,
                    row == testCase.row - 1
                        ? [Cell(), Cell(scalar: 0x41), Cell(scalar: 0x42), Cell()]
                        : Array(repeating: Cell(), count: 4))
            }
            XCTAssertEqual(terminal.buffer.x, 3)
            XCTAssertEqual(terminal.buffer.y, testCase.row - 1)
            XCTAssertTrue(terminal.buffer.wrapPending)
            XCTAssertEqual(terminal.buffer.lineCount, 3)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }

        let oneColumn = CmdyTerminal(cols: 2, rows: 2)
        oneColumn.feed(text: "\u{1B}[?69h\u{1B}[1;1sA\u{1B}[M")
        XCTAssertEqual(oneColumn.buffer.liveLine(0).cells,
                       [Cell(scalar: 0x41), Cell()])
        XCTAssertEqual(oneColumn.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(oneColumn.buffer.x, 1)
        XCTAssertEqual(oneColumn.buffer.y, 0)
        XCTAssertTrue(oneColumn.buffer.wrapPending)

        let explicitFull = CmdyTerminal(cols: 2, rows: 2)
        explicitFull.feed(text: "\u{1B}[?69h\u{1B}[1;2sAB\u{1B}[M")
        XCTAssertEqual(explicitFull.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(explicitFull.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(explicitFull.buffer.x, 1)
        XCTAssertEqual(explicitFull.buffer.y, 0)
        XCTAssertFalse(explicitFull.buffer.wrapPending)

        let nonpending = CmdyTerminal(cols: 2, rows: 2)
        nonpending.feed(text: "\u{1B}[?69h\u{1B}[1;1sA\r\u{1B}[M")
        XCTAssertEqual(nonpending.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(nonpending.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(nonpending.buffer.x, 0)
        XCTAssertEqual(nonpending.buffer.y, 0)
        XCTAssertFalse(nonpending.buffer.wrapPending)

        let equalPhysicalEdge = CmdyTerminal(cols: 2, rows: 2)
        equalPhysicalEdge.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[1;2HA\u{1B}[M")
        XCTAssertEqual(equalPhysicalEdge.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(equalPhysicalEdge.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(equalPhysicalEdge.buffer.x, 1)
        XCTAssertEqual(equalPhysicalEdge.buffer.y, 0)
        XCTAssertFalse(equalPhysicalEdge.buffer.wrapPending)

        let multiColumnPhysicalEdge = CmdyTerminal(cols: 3, rows: 2)
        multiColumnPhysicalEdge.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;2HAB\u{1B}[M")
        XCTAssertEqual(multiColumnPhysicalEdge.buffer.liveLine(0).cells,
                       [Cell(), Cell(), Cell()])
        XCTAssertEqual(multiColumnPhysicalEdge.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell()])
        XCTAssertEqual(multiColumnPhysicalEdge.buffer.x, 2)
        XCTAssertEqual(multiColumnPhysicalEdge.buffer.y, 0)
        XCTAssertFalse(multiColumnPhysicalEdge.buffer.wrapPending)

        let equalInternal = CmdyTerminal(cols: 3, rows: 2)
        equalInternal.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[1;2HA\u{1B}[M")
        XCTAssertEqual(equalInternal.buffer.liveLine(0).cells,
                       [Cell(), Cell(scalar: 0x41), Cell()])
        XCTAssertEqual(equalInternal.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell()])
        XCTAssertEqual(equalInternal.buffer.x, 2)
        XCTAssertEqual(equalInternal.buffer.y, 0)
        XCTAssertTrue(equalInternal.buffer.wrapPending)

        let parkedSingle = CmdyTerminal(cols: 2, rows: 1)
        parkedSingle.feed(text: "\u{1B}[?69h\u{1B}[1;1s\u{1B}[?7lA\u{1B}[M")
        XCTAssertEqual(parkedSingle.buffer.liveLine(0).cells,
                       [Cell(scalar: 0x41), Cell()])
        XCTAssertEqual(parkedSingle.buffer.x, 1)
        XCTAssertEqual(parkedSingle.buffer.y, 0)
        XCTAssertFalse(parkedSingle.buffer.wrapPending)

        let parkedMulti = CmdyTerminal(cols: 3, rows: 1)
        parkedMulti.feed(text: "\u{1B}[?69h\u{1B}[1;2s\u{1B}[?7lAB\u{1B}[M")
        XCTAssertEqual(parkedMulti.buffer.liveLine(0).cells,
                       [Cell(scalar: 0x41), Cell(scalar: 0x42), Cell()])
        XCTAssertEqual(parkedMulti.buffer.x, 2)
        XCTAssertEqual(parkedMulti.buffer.y, 0)
        XCTAssertFalse(parkedMulti.buffer.wrapPending)

        let parkedPhysicalEdge = CmdyTerminal(cols: 2, rows: 1)
        parkedPhysicalEdge.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[?7l\u{1B}[1;2HA\u{1B}[M")
        XCTAssertEqual(parkedPhysicalEdge.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(parkedPhysicalEdge.buffer.x, 1)
        XCTAssertEqual(parkedPhysicalEdge.buffer.y, 0)
        XCTAssertFalse(parkedPhysicalEdge.buffer.wrapPending)

        let cupOutside = CmdyTerminal(cols: 2, rows: 1)
        cupOutside.feed(text: "\u{1B}[?69h\u{1B}[1;1s\u{1B}[1;2H\u{1B}[M")
        XCTAssertEqual(cupOutside.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(cupOutside.buffer.x, 1)
        XCTAssertEqual(cupOutside.buffer.y, 0)
        XCTAssertFalse(cupOutside.buffer.wrapPending)

        for interposed in ["\u{1B}[41m", "\u{1B}[L"] {
            let preserved = CmdyTerminal(cols: 2, rows: 2)
            preserved.feed(text:
                "\u{1B}[?69h\u{1B}[1;1s\u{1B}[?7lA" + interposed + "\u{1B}[M")
            XCTAssertEqual(preserved.buffer.liveLine(0).cells,
                           [Cell(scalar: 0x41), Cell()])
            XCTAssertEqual(preserved.buffer.liveLine(1).cells, [Cell(), Cell()])
            XCTAssertEqual(preserved.buffer.x, 1)
            XCTAssertEqual(preserved.buffer.y, 0)
            XCTAssertFalse(preserved.buffer.wrapPending)
        }

        let repositionedInside = CmdyTerminal(cols: 2, rows: 2)
        repositionedInside.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s\u{1B}[?7lA\u{1B}[1;1H\u{1B}[M")
        XCTAssertEqual(repositionedInside.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(repositionedInside.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(repositionedInside.buffer.x, 0)
        XCTAssertEqual(repositionedInside.buffer.y, 0)
        XCTAssertFalse(repositionedInside.buffer.wrapPending)
    }

    func testDeleteLineIsNoOpWhenCursorIsOutsideActiveHorizontalMargins() {
        let settledRight = CmdyTerminal(cols: 2, rows: 1)
        settledRight.feed(text: "Z\u{1B}[?69h\u{1B}[1;1s\u{1B}[M")
        XCTAssertEqual(settledRight.buffer.liveLine(0).cells,
                       [Cell(scalar: 0x5A), Cell()])
        XCTAssertEqual(settledRight.buffer.x, 1)
        XCTAssertFalse(settledRight.buffer.wrapPending)

        let parkedBeforeMargins = CmdyTerminal(cols: 2, rows: 1)
        parkedBeforeMargins.feed(text:
            "Z\u{1B}[?7l\u{1B}[1;2HA\u{1B}[?69h\u{1B}[1;1s\u{1B}[M")
        XCTAssertEqual(parkedBeforeMargins.buffer.liveLine(0).cells,
                       [Cell(scalar: 0x5A), Cell(scalar: 0x41)])
        XCTAssertEqual(parkedBeforeMargins.buffer.x, 1)
        XCTAssertFalse(parkedBeforeMargins.buffer.wrapPending)

        let settledLeft = CmdyTerminal(cols: 3, rows: 2)
        settledLeft.feed(text:
            "\u{1B}[1;2HZ\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;1H\u{1B}[M")
        XCTAssertEqual(settledLeft.buffer.liveLine(0).cells,
                       [Cell(), Cell(scalar: 0x5A), Cell()])
        XCTAssertEqual(settledLeft.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell()])
        XCTAssertEqual(settledLeft.buffer.x, 0)
        XCTAssertFalse(settledLeft.buffer.wrapPending)

        let straddledWide = CmdyTerminal(cols: 4, rows: 2)
        straddledWide.feed(text:
            "\u{1F1FA}\u{1F1F8}\u{1B}[1;4H\u{1B}[?69h\u{1B}[2;3s\u{1B}[M")
        XCTAssertEqual(
            straddledWide.buffer.liveLine(0).cells,
            [
                Cell(scalar: 0x1F1FA, clusterExtras: [0x1F1F8], width: 2),
                Cell(scalar: 0, width: 0, attribute: CmdyTerminal.stubAttribute),
                Cell(),
                Cell(),
            ])
        XCTAssertEqual(straddledWide.buffer.liveLine(1).cells,
                       [Cell(), Cell(), Cell(), Cell()])
        XCTAssertEqual(straddledWide.buffer.x, 3)

        let inside = CmdyTerminal(cols: 2, rows: 1)
        inside.feed(text: "Z\u{1B}[?69h\u{1B}[1;2s\u{1B}[M")
        XCTAssertEqual(inside.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(inside.buffer.x, 1)
        XCTAssertFalse(inside.buffer.wrapPending)
    }

    func testIneligibleMarginDeleteClampsOnlyOriginModeRow() {
        let aboveRight = CmdyTerminal(cols: 5, rows: 4)
        aboveRight.feed(text:
            "\u{1B}[?69h\u{1B}[1;4s\u{1B}[2;3r" +
            "\u{1B}[1;5H\u{1B}[?6h\u{1B}[2M")
        XCTAssertEqual(aboveRight.buffer.x, 4)
        XCTAssertEqual(aboveRight.buffer.y, 1)
        XCTAssertFalse(aboveRight.buffer.wrapPending)

        let belowLeft = CmdyTerminal(cols: 5, rows: 4)
        belowLeft.feed(text:
            "\u{1B}[?69h\u{1B}[2;4s\u{1B}[2;3r" +
            "\u{1B}[4;1H\u{1B}[?6h\u{1B}[M")
        XCTAssertEqual(belowLeft.buffer.x, 0)
        XCTAssertEqual(belowLeft.buffer.y, 2)
        XCTAssertFalse(belowLeft.buffer.wrapPending)
    }

    func testPendingCustomMarginDeletePreservesContentAndEraseMetadata() {
        let terminal = CmdyTerminal(cols: 4, rows: 3)
        terminal.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[2;2H\u{1B}[48:2::3:4m\u{1B}[2L0A\u{301}")

        let rgb = CellAttribute(bg: .trueColor(0, 3, 4))
        let expected = [
            Array(repeating: Cell(), count: 4),
            [Cell(), Cell(scalar: 0x30, attribute: rgb),
             Cell(scalar: 0x41, clusterExtras: [0x301], attribute: rgb), Cell()],
            [Cell(), Cell.blank(attribute: rgb), Cell.blank(attribute: rgb), Cell()],
        ]
        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row).cells, expected[row])
        }
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.wrapPending)

        terminal.feed(text: "\u{1B}[2M")

        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row).cells, expected[row])
        }
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertTrue(terminal.buffer.wrapPending)
        XCTAssertEqual(terminal.buffer.lineCount, 3)
        XCTAssertEqual(terminal.buffer.yBase, 0)
    }

    func testPendingPhysicalEdgeClampsOnlyWhenDeleteUsesNarrowedMargins() {
        let narrowed = CmdyTerminal(cols: 2, rows: 1)
        narrowed.feed(text: "\u{1B}[1;2HA\u{1B}[?69h\u{1B}[1;1s")
        XCTAssertEqual(narrowed.buffer.liveLine(0).cells,
                       [Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(narrowed.buffer.x, 2)
        XCTAssertTrue(narrowed.buffer.wrapPending)

        narrowed.feed(text: "\u{1B}[M")

        XCTAssertEqual(narrowed.buffer.liveLine(0).cells,
                       [Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(narrowed.buffer.x, 1)
        XCTAssertEqual(narrowed.buffer.y, 0)
        XCTAssertTrue(narrowed.buffer.wrapPending)
        XCTAssertEqual(narrowed.buffer.lineCount, 1)
        XCTAssertEqual(narrowed.buffer.yBase, 0)

        let noWrap = CmdyTerminal(cols: 2, rows: 1)
        noWrap.feed(text:
            "\u{1B}[?7l\u{1B}[1;2HA\u{1B}[?69h\u{1B}[1;1s\u{1B}[M")
        XCTAssertEqual(noWrap.buffer.liveLine(0).cells,
                       [Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(noWrap.buffer.x, 1)
        XCTAssertFalse(noWrap.buffer.wrapPending)

        let settled = CmdyTerminal(cols: 2, rows: 1)
        settled.feed(text: "\u{1B}[1;2H\u{1B}[?69h\u{1B}[1;1s\u{1B}[M")
        XCTAssertEqual(settled.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(settled.buffer.x, 1)
        XCTAssertFalse(settled.buffer.wrapPending)

        let physicalRight = CmdyTerminal(cols: 2, rows: 1)
        physicalRight.feed(text: "\u{1B}[1;2HA\u{1B}[?69h\u{1B}[1;2s\u{1B}[M")
        XCTAssertEqual(physicalRight.buffer.liveLine(0).cells, [Cell(), Cell()])
        XCTAssertEqual(physicalRight.buffer.x, 1)
        XCTAssertFalse(physicalRight.buffer.wrapPending)

        let tabEdge = CmdyTerminal(cols: 2, rows: 1)
        tabEdge.feed(text: "\u{1B}[3g\tA\u{1B}[?69h\u{1B}[1;1s")
        XCTAssertEqual(tabEdge.buffer.x, 2)
        XCTAssertTrue(tabEdge.buffer.wrapPending)
        tabEdge.feed(text: "\u{1B}[M")
        XCTAssertEqual(tabEdge.buffer.liveLine(0).cells,
                       [Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(tabEdge.buffer.x, 1)
        XCTAssertTrue(tabEdge.buffer.wrapPending)

        let nextPrint = CmdyTerminal(cols: 2, rows: 2)
        nextPrint.feed(text: "\u{1B}[1;2HA\u{1B}[?69h\u{1B}[1;1s\u{1B}[MB")
        XCTAssertEqual(nextPrint.buffer.liveLine(0).cells,
                       [Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(nextPrint.buffer.liveLine(1).cells,
                       [Cell(scalar: 0x42), Cell()])
        XCTAssertEqual(nextPrint.buffer.x, 1)
        XCTAssertEqual(nextPrint.buffer.y, 1)
        XCTAssertTrue(nextPrint.buffer.wrapPending)

        let backspace = CmdyTerminal(cols: 2, rows: 2)
        backspace.feed(text: "\u{1B}[1;2HA\u{1B}[?69h\u{1B}[1;1s\u{1B}[M\u{8}")
        XCTAssertEqual(backspace.buffer.liveLine(0).cells,
                       [Cell(), Cell(scalar: 0x41)])
        XCTAssertEqual(backspace.buffer.liveLine(1).cells, [Cell(), Cell()])
        XCTAssertEqual(backspace.buffer.x, 0)
        XCTAssertEqual(backspace.buffer.y, 0)
        XCTAssertFalse(backspace.buffer.wrapPending)
    }

    func testDeleteLineUnderHorizontalMarginModeStartsAboveVerticalRegion() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x41])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x33, 0x72])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell(scalar: 0x41))

        terminal.feed([0x1B, 0x5B, 0x4D])

        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }
    }

    func testDeleteLineAboveVerticalRegionFillsAtScrollTop() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x33, 0x72])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        let blackBackground = CellAttribute(bg: .ansi256(0))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(
            terminal.buffer.liveLine(1)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDeleteLineAboveVerticalRegionShiftsContentThroughScrollBottom() {
        let terminal = CmdyTerminal(cols: 1, rows: 4)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x33, 0x3B, 0x31, 0x48])
        terminal.feed([0x41])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x34, 0x72])

        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertEqual(
            (0..<4).map { terminal.buffer.liveLine($0)[0] },
            [Cell(), Cell(), Cell(scalar: 0x41), Cell()])

        terminal.feed([0x1B, 0x5B, 0x4D])

        XCTAssertEqual(
            (0..<4).map { terminal.buffer.liveLine($0)[0] },
            [Cell(), Cell(scalar: 0x41), Cell(), Cell()])
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDeleteLinesAboveVerticalRegionBackfillTowardCursor() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x33, 0x72])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])

        let blackBackground = CellAttribute(bg: .ansi256(0))
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(
            terminal.buffer.liveLine(1)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDeleteLineAboveVerticalRegionFillsBeforeScrollBottom() {
        let terminal = CmdyTerminal(cols: 1, rows: 4)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x34, 0x72])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        let blackBackground = CellAttribute(bg: .ansi256(0))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(
            terminal.buffer.liveLine(2)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(terminal.buffer.liveLine(3)[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDeleteLineFromMarginRowUsesActiveEraseFillWhenItShiftsRows() {
        let blackBackground = CellAttribute(bg: .ansi256(0))

        let singleton = CmdyTerminal(cols: 1, rows: 1)
        singleton.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        singleton.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        singleton.feed([0x1B, 0x5B, 0x4D])
        XCTAssertEqual(
            singleton.buffer.liveLine(0)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(singleton.buffer.x, 0)
        XCTAssertEqual(singleton.buffer.y, 0)

        let shifted = CmdyTerminal(cols: 1, rows: 2)
        shifted.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        shifted.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        shifted.feed([0x1B, 0x5B, 0x4D])
        XCTAssertEqual(shifted.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(
            shifted.buffer.liveLine(1)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(shifted.buffer.x, 0)
        XCTAssertEqual(shifted.buffer.y, 0)
    }

    func testDeleteLineFromMiddleMarginRowUsesNeutralFill() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x0A])
        XCTAssertEqual(terminal.buffer.y, 1)

        terminal.feed([0x1B, 0x5B, 0x4D])

        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }
    }

    func testDeleteLineCountOverflowUsesActiveEraseFill() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])

        let blackBackground = CellAttribute(bg: .ansi256(0))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(
            terminal.buffer.liveLine(1)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testDeleteLineCountBelowScreenHeightKeepsBottomFillNeutral() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x33, 0x3B, 0x31, 0x48])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])

        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 2)
    }

    func testDeleteLineExactMultirowSuffixUsesActiveEraseFill() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x31, 0x48])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])

        let blackBackground = CellAttribute(bg: .ansi256(0))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(
            terminal.buffer.liveLine(2)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testDeleteLinesFromEarlyRowMarkOnlyBottomWithActiveEraseFill() {
        let terminal = CmdyTerminal(cols: 1, rows: 4)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x31, 0x48])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])

        let blackBackground = CellAttribute(bg: .ansi256(0))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(
            terminal.buffer.liveLine(3)[0],
            Cell.blank(attribute: blackBackground))
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testDeleteLinesFromTopUseCountSizedActiveEraseWindow() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])

        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDeleteLineAtScrollTopUsesRegionRelativeActiveEraseWindow() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x32, 0x3B, 0x33, 0x72])
        terminal.feed([0x0A])

        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)

        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testDeleteLineAtScrollBottomUsesActiveEraseBelowRegion() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x72])
        terminal.feed([0x0A])

        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)

        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testDeleteLinesAtScrollBottomUseIndependentEraseWindows() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x72])
        terminal.feed([0x0A])

        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }

        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])

        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testDeleteLineInsideShortRegionUsesActiveEraseBelowRegion() {
        let terminal = CmdyTerminal(cols: 1, rows: 4)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x72])
        terminal.feed([0x0A])

        for row in 0..<4 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }

        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(3)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testDeleteLineAtRegionTopDoesNotFillBelowRegion() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x72])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testRepeatedDeleteLineMaterializesStoredGenerationEraseAttribute() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])

        terminal.feed([0x1B, 0x5B, 0x4D])
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())

        terminal.feed([0x1B, 0x5B, 0x4D])

        let storedEraseBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], storedEraseBlank)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testDeleteLineGenerationEraseSurvivesSGRButNotNewBufferRow() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        terminal.feed([0x1B, 0x5B, 0x34, 0x39, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])
        XCTAssertEqual(
            terminal.buffer.liveLine(1)[0],
            Cell.blank(attribute: CellAttribute(bg: .ansi256(0))))

        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testStoredDeleteGenerationFillsEntireLaterDeleteSlice() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])

        terminal.feed([0x1B, 0x5B, 0x4D])
        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }

        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])

        let storedEraseBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], storedEraseBlank)
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], storedEraseBlank)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testRepeatedDeleteLineKeepsCurrentFillAheadOfStoredGeneration() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x34, 0x31, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell.blank(attribute: CellAttribute(bg: .ansi256(1))))

        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        XCTAssertEqual(
            terminal.buffer.liveLine(0)[0],
            Cell.blank(attribute: CellAttribute(bg: .ansi256(0))))
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testActiveDeleteSeedsGenerationForLaterDeferredDelete() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])

        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])
        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], activeBlank)

        terminal.feed([0x1B, 0x5B, 0x4D])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testActiveDeleteAboveBottomDoesNotSeedLaterBottomDelete() {
        let terminal = CmdyTerminal(cols: 1, rows: 2)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], activeBlank)

        terminal.feed([0x0A])
        terminal.feed([0x1B, 0x5B, 0x4D])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
    }

    func testDeleteCountOverflowBelowVerticalRegionUsesActiveErase() {
        let terminal = CmdyTerminal(cols: 1, rows: 3)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x72])
        terminal.feed([0x1B, 0x5B, 0x33, 0x3B, 0x31, 0x48])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])

        for row in 0..<3 {
            XCTAssertEqual(terminal.buffer.liveLine(row)[0], Cell())
        }
        XCTAssertEqual(terminal.buffer.y, 2)

        terminal.feed([0x1B, 0x5B, 0x32, 0x4D])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(
            terminal.buffer.liveLine(2)[0],
            Cell.blank(attribute: CellAttribute(bg: .ansi256(0))))
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 2)
    }

    func testDeleteBelowVerticalRegionTransformsPhysicalSuffix() {
        let terminal = CmdyTerminal(cols: 1, rows: 4)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x72])
        terminal.feed([0x1B, 0x5B, 0x33, 0x3B, 0x31, 0x48])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(
            terminal.buffer.liveLine(3)[0],
            Cell.blank(attribute: CellAttribute(bg: .ansi256(0))))
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 2)
    }

    func testDeleteAboveVerticalRegionPositionsFillByRegionHeight() {
        let terminal = CmdyTerminal(cols: 1, rows: 4)
        terminal.feed([0x1B, 0x5B, 0x3F, 0x36, 0x39, 0x68])
        terminal.feed([0x1B, 0x5B, 0x33, 0x3B, 0x34, 0x72])
        terminal.feed([0x1B, 0x5B, 0x34, 0x30, 0x6D])
        terminal.feed([0x1B, 0x5B, 0x4D])

        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))
        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(1)[0], activeBlank)
        XCTAssertEqual(terminal.buffer.liveLine(2)[0], Cell())
        XCTAssertEqual(terminal.buffer.liveLine(3)[0], Cell())
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 0)
    }

    func testDeleteLineVirtualWindowMatrixRepresentatives() {
        let cases: [(height: Int, marginBottom: Int, count: Int, activeRows: Set<Int>)] = [
            (4, 3, 1, []),
            (5, 3, 1, [4]),
            (5, 3, 2, [3, 4]),
            (3, 2, 1, []),
            (5, 2, 1, [3]),
            (6, 2, 3, [2, 3]),
            (5, 2, 3, [2, 3]),
        ]
        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))

        for testCase in cases {
            let terminal = CmdyTerminal(cols: 1, rows: testCase.height)
            terminal.feed(text: "\u{1B}[?69h")
            terminal.feed(text: "\u{1B}[1;\(testCase.marginBottom)r")
            terminal.feed(text: "\u{1B}[3;1H")
            terminal.feed(text: "\u{1B}[40m")
            terminal.feed(text: "\u{1B}[\(testCase.count)M")

            for row in 0..<testCase.height {
                XCTAssertEqual(
                    terminal.buffer.liveLine(row)[0],
                    testCase.activeRows.contains(row) ? activeBlank : Cell(),
                    "height=\(testCase.height) bottom=\(testCase.marginBottom) " +
                        "count=\(testCase.count) row=\(row)")
            }
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, 2)
        }
    }

    func testRepeatedDeleteLineVirtualWindowAccumulatorMatrix() {
        let cases: [(
            height: Int,
            marginBottom: Int?,
            cursorRow: Int,
            counts: (Int, Int),
            activeRows: Set<Int>
        )] = [
            (3, nil, 2, (2, 1), [1, 2]),
            (3, 2, 3, (1, 1), [2]),
            (5, 3, 4, (1, 2), [3, 4]),
            (3, nil, 3, (1, 1), []),
            (4, nil, 3, (1, 2), [3]),
            (4, 3, 3, (1, 1), [3]),
            (4, nil, 3, (3, 2), [2, 3]),
            (6, 5, 4, (1, 2), [5]),
        ]
        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))

        for testCase in cases {
            let terminal = CmdyTerminal(cols: 1, rows: testCase.height)
            terminal.feed(text: "\u{1B}[?69h")
            if let marginBottom = testCase.marginBottom {
                terminal.feed(text: "\u{1B}[1;\(marginBottom)r")
            }
            terminal.feed(text: "\u{1B}[\(testCase.cursorRow);1H")
            terminal.feed(text: "\u{1B}[40m")
            terminal.feed(text: "\u{1B}[\(testCase.counts.0)M")
            terminal.feed(text: "\u{1B}[\(testCase.counts.1)M")

            for row in 0..<testCase.height {
                XCTAssertEqual(
                    terminal.buffer.liveLine(row)[0],
                    testCase.activeRows.contains(row) ? activeBlank : Cell(),
                    "height=\(testCase.height) bottom=\(String(describing: testCase.marginBottom)) " +
                        "cursor=\(testCase.cursorRow) counts=\(testCase.counts) row=\(row)")
            }
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, testCase.cursorRow - 1)
        }
    }

    func testDeleteLineVirtualRowsSurviveCursorRelocation() {
        let cases: [(
            height: Int,
            margins: ClosedRange<Int>?,
            first: (row: Int, count: Int),
            second: (row: Int, count: Int),
            activeRows: Set<Int>
        )] = [
            (3, nil, (2, 1), (3, 1), [2]),
            (4, 1...3, (3, 3), (4, 1), [2, 3]),
            (4, 1...3, (3, 1), (4, 1), [3]),
            (5, 1...4, (2, 1), (4, 2), []),
            (3, nil, (2, 3), (3, 1), [1, 2]),
            (5, 1...4, (2, 3), (4, 2), [2]),
            (6, 1...5, (3, 2), (4, 2), [3, 4]),
            (4, 1...3, (2, 1), (3, 1), [2]),
            (3, 2...3, (2, 1), (1, 1), [1, 2]),
            (5, 4...5, (4, 2), (1, 2), [0, 1, 3, 4]),
            (4, 3...4, (3, 1), (1, 1), [1, 3]),
            (5, 1...2, (4, 1), (3, 1), [3, 4]),
            (5, 1...3, (5, 2), (4, 1), [4]),
            (6, 1...2, (5, 1), (3, 1), [3, 5]),
            (3, 1...2, (3, 2), (2, 1), [1, 2]),
            (3, nil, (3, 2), (2, 1), [2]),
        ]
        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))

        for testCase in cases {
            let terminal = CmdyTerminal(cols: 1, rows: testCase.height)
            terminal.feed(text: "\u{1B}[?69h")
            if let margins = testCase.margins {
                terminal.feed(text: "\u{1B}[\(margins.lowerBound);\(margins.upperBound)r")
            }
            terminal.feed(text: "\u{1B}[\(testCase.first.row);1H")
            terminal.feed(text: "\u{1B}[40m")
            terminal.feed(text: "\u{1B}[\(testCase.first.count)M")
            terminal.feed(text: "\u{1B}[\(testCase.second.row);1H")
            terminal.feed(text: "\u{1B}[\(testCase.second.count)M")

            for row in 0..<testCase.height {
                XCTAssertEqual(
                    terminal.buffer.liveLine(row)[0],
                    testCase.activeRows.contains(row) ? activeBlank : Cell(),
                    "height=\(testCase.height) margins=\(String(describing: testCase.margins)) " +
                        "first=\(testCase.first) second=\(testCase.second) row=\(row)")
            }
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, testCase.second.row - 1)
        }
    }

    func testDeleteLineVirtualRowsAcrossLineFeedAndIndexBoundaries() {
        let controls = [(name: "LF", text: "\n"), (name: "IND", text: "\u{1B}D")]
        let activeBlank = Cell.blank(attribute: CellAttribute(bg: .ansi256(0)))

        for control in controls {
            let moving = CmdyTerminal(cols: 1, rows: 4)
            moving.feed(text: "\u{1B}[?69h\u{1B}[1;1H\u{1B}[40m\u{1B}[1M")
            moving.feed(text: control.text)
            moving.feed(text: "\u{1B}[1M")
            for row in 0..<4 {
                XCTAssertEqual(
                    moving.buffer.liveLine(row)[0],
                    row == 2 ? activeBlank : Cell(),
                    "\(control.name) non-boundary row=\(row)")
            }
            XCTAssertEqual(moving.buffer.y, 1)
            XCTAssertEqual(moving.buffer.yBase, 0)

            let interiorBoundary = CmdyTerminal(cols: 1, rows: 3)
            interiorBoundary.feed(text:
                "\u{1B}[?69h\u{1B}[2;3r\u{1B}[3;1H\u{1B}[40m\u{1B}[1M")
            interiorBoundary.feed(text: control.text)
            interiorBoundary.feed(text: "\u{1B}[49m\u{1B}[1M")
            for row in 0..<3 {
                XCTAssertEqual(
                    interiorBoundary.buffer.liveLine(row)[0],
                    Cell(),
                    "\(control.name) interior boundary row=\(row)")
            }
            XCTAssertEqual(interiorBoundary.buffer.y, 2)
            XCTAssertEqual(interiorBoundary.buffer.yBase, 0)
            XCTAssertEqual(interiorBoundary.buffer.lineCount, 3)

            let scrollbackBoundary = CmdyTerminal(cols: 1, rows: 2)
            scrollbackBoundary.feed(text:
                "\u{1B}[?69h\u{1B}[2;1H\u{1B}[40m\u{1B}[1M")
            scrollbackBoundary.feed(text: control.text)
            scrollbackBoundary.feed(text: "\u{1B}[49m\u{1B}[1M")
            for row in 0..<2 {
                XCTAssertEqual(
                    scrollbackBoundary.buffer.liveLine(row)[0],
                    Cell(),
                    "\(control.name) scrollback boundary row=\(row)")
            }
            XCTAssertEqual(scrollbackBoundary.buffer.y, 1)
            XCTAssertEqual(scrollbackBoundary.buffer.yBase, 1)
            XCTAssertEqual(scrollbackBoundary.buffer.lineCount, 3)
        }
    }

    func testReverseIndexRebindsFullWidthDeleteVirtualGeneration() {
        let terminal = CmdyTerminal(cols: 2, rows: 3)
        terminal.feed(text:
            "\u{1B}[?69h\u{1B}[2;1H\u{1B}[48:2::3:4m" +
            "\u{1B}[M\u{1B}M\u{1B}M \u{1B}[2;1H\u{1B}[M")

        XCTAssertEqual(
            terminal.buffer.liveLine(2)[0],
            Cell.blank(attribute: CellAttribute(bg: .trueColor(0, 3, 4))))
        XCTAssertEqual(terminal.buffer.x, 0)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.lineCount, 3)
        XCTAssertEqual(terminal.buffer.yBase, 0)
    }

    func testFullWidthLineRotationRebindsDeleteVirtualGeneration() {
        let rotations = [
            (name: "IL", text: "\u{1B}[2L"),
            (name: "DL", text: "\u{1B}[2M"),
            (name: "SU", text: "\u{1B}[2S"),
        ]

        for rotation in rotations {
            let terminal = CmdyTerminal(cols: 2, rows: 3)
            terminal.feed(text:
                "\u{1B}[?69h\u{1B}[2;1H\u{1B}[48:2::3:4m\u{1B}[M" +
                "\u{1B}[?69l\u{1B}[1;1H" + rotation.text +
                "\u{1B}[?69h\u{1B}[2;1H\u{1B}[M")

            XCTAssertEqual(
                terminal.buffer.liveLine(2)[0],
                Cell.blank(attribute: CellAttribute(bg: .trueColor(0, 3, 4))),
                rotation.name)
            XCTAssertEqual(terminal.buffer.x, 0, rotation.name)
            XCTAssertEqual(terminal.buffer.y, 1, rotation.name)
            XCTAssertEqual(terminal.buffer.lineCount, 3, rotation.name)
            XCTAssertEqual(terminal.buffer.yBase, 0, rotation.name)
        }
    }

    func testPartialMarginWrapPreservesWholeVirtualLineGeneration() {
        let rgb = CellColor.trueColor(0, 3, 4)

        let partial = CmdyTerminal(cols: 2, rows: 3)
        partial.feed(text:
            "\u{1B}[48:2::3:4m\u{1B}[?69h\u{1B}[2;2s" +
            "\u{1B}[2;2HA\u{1B}[2;2H\u{1B}[2L\u{1B}[49m" +
            "\u{1B}[3;2HBC\u{1B}[2;2H\u{1B}[2M")

        XCTAssertEqual(
            partial.buffer.liveLine(1)[1],
            Cell(scalar: UnicodeScalar("A").value,
                 attribute: CellAttribute(bg: rgb)))
        XCTAssertEqual(partial.buffer.x, 1)
        XCTAssertEqual(partial.buffer.y, 1)
        XCTAssertEqual(partial.buffer.lineCount, 3)
        XCTAssertEqual(partial.buffer.yBase, 0)

        let fullWidth = CmdyTerminal(cols: 2, rows: 3)
        fullWidth.feed(text:
            "\u{1B}[48:2::3:4m\u{1B}[?69h\u{1B}[1;2s" +
            "\u{1B}[2;2HA\u{1B}[2;2H\u{1B}[2L\u{1B}[49m" +
            "\u{1B}[3;2HBC\u{1B}[2;2H\u{1B}[2M")

        XCTAssertFalse(fullWidth.buffer.lines.contains { line in
            line.cells.contains { $0.scalar == UnicodeScalar("A").value }
        })
        XCTAssertEqual(fullWidth.buffer.x, 1)
        XCTAssertEqual(fullWidth.buffer.y, 1)
        XCTAssertEqual(fullWidth.buffer.lineCount, 4)
        XCTAssertEqual(fullWidth.buffer.yBase, 1)
    }

    func testInsertLineTransformsPersistentDeleteVirtualRows() {
        let rgb = CellColor.trueColor(4, 8, 16)
        let indexed = CellColor.ansi256(99)
        let cases: [(
            height: Int,
            margins: ClosedRange<Int>,
            cursorRow: Int,
            firstDelete: Int,
            secondDelete: Int,
            insertCount: Int,
            expectedBackgrounds: [CellColor]
        )] = [
            (3, 1...2, 2, 1, 1, 1, [.defaultColor, rgb, indexed]),
            (3, 1...2, 2, 2, 1, 1, [.defaultColor, rgb, indexed]),
            (4, 1...3, 3, 1, 1, 3, [.defaultColor, .defaultColor, rgb, rgb]),
            (4, 1...3, 3, 3, 1, 3, [.defaultColor, .defaultColor, rgb, rgb]),
            (3, 2...3, 1, 1, 1, 1, [indexed, rgb, .defaultColor]),
            (3, 1...2, 3, 1, 1, 1, [.defaultColor, .defaultColor, indexed]),
        ]

        for testCase in cases {
            let terminal = CmdyTerminal(cols: 1, rows: testCase.height)
            terminal.feed(text: "\u{1B}[?69h")
            terminal.feed(text:
                "\u{1B}[\(testCase.margins.lowerBound);\(testCase.margins.upperBound)r")
            terminal.feed(text: "\u{1B}[\(testCase.cursorRow);1H")
            terminal.feed(text: "\u{1B}[48;5;99m\u{1B}[\(testCase.firstDelete)M")
            terminal.feed(text: "\u{1B}[48;2;4;8;16m\u{1B}[\(testCase.secondDelete)M")
            terminal.feed(text: "\u{1B}[\(testCase.insertCount)L")

            for (row, background) in testCase.expectedBackgrounds.enumerated() {
                XCTAssertEqual(
                    terminal.buffer.liveLine(row)[0],
                    Cell.blank(attribute: CellAttribute(bg: background)),
                    "height=\(testCase.height) margins=\(testCase.margins) " +
                        "cursor=\(testCase.cursorRow) first=\(testCase.firstDelete) " +
                        "second=\(testCase.secondDelete) insert=\(testCase.insertCount) row=\(row)")
            }
            XCTAssertEqual(terminal.buffer.x, 0)
            XCTAssertEqual(terminal.buffer.y, testCase.cursorRow - 1)
            XCTAssertEqual(terminal.buffer.lineCount, testCase.height)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testInsertLineTransformsContentAcrossVirtualRows() {
        let cases: [(
            height: Int,
            margins: ClosedRange<Int>,
            contentRow: Int,
            cursorRow: Int,
            insertCount: Int,
            expectedRow: Int?
        )] = [
            (3, 1...2, 2, 2, 1, 3),
            (3, 1...2, 3, 2, 1, nil),
            (3, 1...2, 3, 2, 2, nil),
            (4, 1...3, 4, 3, 1, nil),
            (5, 1...3, 4, 3, 1, 5),
        ]

        for testCase in cases {
            let terminal = CmdyTerminal(cols: 2, rows: testCase.height)
            terminal.feed(text: "\u{1B}[?69h")
            terminal.feed(text:
                "\u{1B}[\(testCase.margins.lowerBound);\(testCase.margins.upperBound)r")
            terminal.feed(text: "\u{1B}[\(testCase.contentRow);1Ha")
            if testCase.cursorRow != testCase.contentRow {
                terminal.feed(text: "\u{1B}[\(testCase.cursorRow);1H")
            }
            terminal.feed(text: "\u{1B}[\(testCase.insertCount)L")

            for row in 1...testCase.height {
                XCTAssertEqual(
                    terminal.buffer.liveLine(row - 1)[0].scalar,
                    row == testCase.expectedRow ? UnicodeScalar("a").value : 0,
                    "height=\(testCase.height) margins=\(testCase.margins) " +
                        "content=\(testCase.contentRow) cursor=\(testCase.cursorRow) " +
                        "insert=\(testCase.insertCount) row=\(row)")
            }
            XCTAssertEqual(terminal.buffer.y, testCase.cursorRow - 1)
            XCTAssertEqual(
                terminal.buffer.x,
                testCase.cursorRow == testCase.contentRow ? 1 : 0)
            XCTAssertEqual(terminal.buffer.lineCount, testCase.height)
            XCTAssertEqual(terminal.buffer.yBase, 0)
        }
    }

    func testActiveMarginInsertDeleteRestoresContentFromVirtualRows() {
        let terminal = CmdyTerminal(cols: 4, rows: 4)
        terminal.feed(text: "\u{1B}[?69h\u{1B}[2;4r\u{1B}[3;1H日")

        terminal.feed(text: "\u{1B}[2L\u{1B}[2M")

        XCTAssertEqual(
            terminal.buffer.liveLine(2)[0],
            Cell(scalar: UnicodeScalar("日").value, width: 2))
        XCTAssertEqual(terminal.buffer.liveLine(2)[1].width, 0)
        for row in [0, 1, 3] {
            XCTAssertEqual(terminal.buffer.liveLine(row).cells, Array(repeating: Cell(), count: 4))
        }
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(terminal.buffer.y, 2)
    }

    func testExplicitPartialLineMotionHardensPrewrappedDestinations() {
        let forward = CmdyTerminal(cols: 3, rows: 3)
        forward.setPrivateMode(69, true)
        forward.buffer.marginLeft = 1
        forward.buffer.marginRight = 1
        forward.buffer.y = 2
        forward.buffer.x = 1
        let forwardTop = forward.buffer.liveLine(0)
        let forwardMiddle = forward.buffer.liveLine(1)
        let forwardBottom = forward.buffer.liveLine(2)
        forwardTop.isWrapped = true
        forwardMiddle.isWrapped = true
        forwardBottom.isWrapped = true

        forward.lineFeed()

        XCTAssertTrue(forward.activeMarginReflowBoundaries.contains {
            $0.line === forwardTop
        })
        XCTAssertTrue(forward.activeMarginReflowBoundaries.contains {
            $0.line === forwardMiddle
        })
        XCTAssertFalse(forward.activeMarginReflowBoundaries.contains {
            $0.line === forwardBottom
        })

        let reverse = CmdyTerminal(cols: 3, rows: 3)
        reverse.setPrivateMode(69, true)
        reverse.buffer.marginLeft = 1
        reverse.buffer.marginRight = 1
        reverse.buffer.y = 0
        reverse.buffer.x = 1
        let reverseTop = reverse.buffer.liveLine(0)
        let reverseMiddle = reverse.buffer.liveLine(1)
        let reverseBottom = reverse.buffer.liveLine(2)
        reverseTop.isWrapped = true
        reverseMiddle.isWrapped = true
        reverseBottom.isWrapped = true

        reverse.reverseLineFeed()

        XCTAssertFalse(reverse.activeMarginReflowBoundaries.contains {
            $0.line === reverseTop
        })
        XCTAssertTrue(reverse.activeMarginReflowBoundaries.contains {
            $0.line === reverseMiddle
        })
        XCTAssertTrue(reverse.activeMarginReflowBoundaries.contains {
            $0.line === reverseBottom
        })
    }

    func testVS16CursorTracksQualifyingRelativeForwardMotion() {
        let moved = CmdyTerminal(cols: 4, rows: 1)
        moved.feed(text: "0\u{1B}9\u{FE0F}")
        XCTAssertEqual(moved.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(moved.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(moved.buffer.x, 3)

        let clampedSecondMove = CmdyTerminal(cols: 3, rows: 1)
        clampedSecondMove.feed(text: "0\u{1B}9\u{1B}9\u{FE0F}")
        XCTAssertEqual(clampedSecondMove.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(clampedSecondMove.buffer.x, 2)

        let inertOutsideActiveSlice = CmdyTerminal(cols: 3, rows: 2)
        inertOutsideActiveSlice.feed(text:
            "\u{1B}[?69h\u{1B}[1;1s0\u{1B}9\u{1B}9\u{FE0F}")
        XCTAssertEqual(inertOutsideActiveSlice.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(inertOutsideActiveSlice.buffer.x, 3)

        let unaffectedByBoundaryShift = CmdyTerminal(cols: 3, rows: 2)
        unaffectedByBoundaryShift.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;1H0" +
            "\u{1B}9\u{1B}9\u{FE0F}")
        XCTAssertEqual(unaffectedByBoundaryShift.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(unaffectedByBoundaryShift.buffer.x, 3)

        let absoluteForward = CmdyTerminal(cols: 4, rows: 1)
        absoluteForward.feed(text: "0\u{1B}[1;3H\u{FE0F}")
        XCTAssertEqual(absoluteForward.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(absoluteForward.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(absoluteForward.buffer.x, 3)

        let absoluteColumnForward = CmdyTerminal(cols: 4, rows: 1)
        absoluteColumnForward.feed(text: "0\u{1B}[3G\u{FE0F}")
        XCTAssertEqual(absoluteColumnForward.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(absoluteColumnForward.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(absoluteColumnForward.buffer.x, 3)

        let outsideActiveSlice = CmdyTerminal(cols: 4, rows: 1)
        outsideActiveSlice.feed(text:
            "\u{1B}[?69h\u{1B}[4;4s\u{1B}[1;1H0\u{1B}9")
        XCTAssertEqual(outsideActiveSlice.buffer.x, 2)

        let wrappedAbsolute = CmdyTerminal(cols: 3, rows: 2)
        wrappedAbsolute.feed(text:
            "\u{1B}[?69h\u{1B}[1;2s\u{1B}[1;3H0" +
            "\u{1B}[1;3H\u{FE0F}")
        XCTAssertEqual(
            wrappedAbsolute.buffer.liveLine(1)[0],
            Cell(
                scalar: UnicodeScalar("0").value,
                clusterExtras: [0xFE0F], width: 2))
        XCTAssertEqual(wrappedAbsolute.buffer.x, 3)
        XCTAssertEqual(wrappedAbsolute.buffer.y, 0)

        let hiddenShift = CmdyTerminal(cols: 3, rows: 2)
        hiddenShift.feed(text:
            "\u{1B}[?69h\u{1B}[2;2s\u{1B}[?69l\u{1B}[1;1H0" +
            "\u{1B}9\u{FE0E}")
        XCTAssertEqual(
            hiddenShift.buffer.liveLine(0)[0],
            Cell(scalar: UnicodeScalar("0").value, clusterExtras: [0xFE0E]))
        XCTAssertEqual(hiddenShift.buffer.x, 1)
    }

    func testVS16CursorComposesForwardAndReverseHorizontalMotion() {
        let remainsRight = CmdyTerminal(cols: 6, rows: 1)
        remainsRight.feed(text: "0\u{1B}[I\u{1B}[D\u{FE0F}")
        XCTAssertEqual(remainsRight.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(remainsRight.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(remainsRight.buffer.x, 5)

        let absoluteRemainsRight = CmdyTerminal(cols: 4, rows: 1)
        absoluteRemainsRight.feed(text:
            "0\u{1B}[1;4H\u{1B}[D\u{FE0F}")
        XCTAssertEqual(absoluteRemainsRight.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(absoluteRemainsRight.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(absoluteRemainsRight.buffer.x, 3)

        let movesStrictlyLeft = CmdyTerminal(cols: 4, rows: 1)
        movesStrictlyLeft.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[1;3H0" +
            "\u{1B}[I\u{1B}6\u{FE0F}")
        XCTAssertEqual(movesStrictlyLeft.buffer.liveLine(0)[2].width, 2)
        XCTAssertEqual(movesStrictlyLeft.buffer.liveLine(0)[3].width, 0)
        XCTAssertEqual(movesStrictlyLeft.buffer.x, 2)
    }

    func testVS16CursorTracksDoubleReverseOnlyWhenStrictlyLeft() {
        let strictlyLeft = CmdyTerminal(cols: 4, rows: 1)
        strictlyLeft.feed(text: "\u{1B}[1;2H0\u{1B}6\u{1B}6\u{FE0F}")
        XCTAssertEqual(strictlyLeft.buffer.liveLine(0)[1].width, 2)
        XCTAssertEqual(strictlyLeft.buffer.liveLine(0)[2].width, 0)
        XCTAssertEqual(strictlyLeft.buffer.x, 1)

        let returnsToPostWrite = CmdyTerminal(cols: 4, rows: 1)
        returnsToPostWrite.feed(text:
            "0\u{1B}[I\u{1B}6\u{1B}6\u{FE0F}")
        XCTAssertEqual(returnsToPostWrite.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(returnsToPostWrite.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(returnsToPostWrite.buffer.x, 2)
    }

    func testVS16KeepsForwardHistoryAcrossLaterBoundaryNoOp() {
        let terminal = CmdyTerminal(cols: 4, rows: 1)
        terminal.feed(text: "0\u{1B}[I\u{1B}[I\u{FE0F}")
        XCTAssertEqual(terminal.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(terminal.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testVS16BoundaryObserversConvergeAfterHistoricalCorrection() {
        let narrowNoWrap = CmdyTerminal(cols: 4, rows: 1)
        narrowNoWrap.feed(text:
            "\u{1B}[?7l0\u{1B}[I\u{1B}[I\u{FE0F}Z")
        XCTAssertEqual(narrowNoWrap.buffer.liveLine(0).cells, [
            Cell(
                scalar: UnicodeScalar("0").value,
                clusterExtras: [0xFE0F], width: 2),
            Cell(scalar: 0, width: 0),
            Cell(),
            Cell(scalar: UnicodeScalar("Z").value),
        ])
        XCTAssertEqual(narrowNoWrap.buffer.x, 4)

        let wideWrap = CmdyTerminal(cols: 4, rows: 2)
        wideWrap.feed(text:
            "0\u{1B}[I\u{1B}[I\u{FE0F}\u{1F469}\u{200D}\u{1F4BB}")
        XCTAssertEqual(wideWrap.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(wideWrap.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(wideWrap.buffer.liveLine(1)[0].scalar, 0x1F469)
        XCTAssertEqual(wideWrap.buffer.liveLine(1)[0].width, 2)
        XCTAssertEqual(wideWrap.buffer.liveLine(1)[1].width, 0)
        XCTAssertEqual(wideWrap.buffer.x, 2)
        XCTAssertEqual(wideWrap.buffer.y, 1)
    }

    func testVS16RespectsCursorRepositionAroundPriorOwner() {
        let strictlyLeft = CmdyTerminal(cols: 3, rows: 1)
        strictlyLeft.feed(text: "\u{1B}90\r\u{FE0F}")
        XCTAssertEqual(
            strictlyLeft.buffer.liveLine(0)[1],
            Cell(
                scalar: UnicodeScalar("0").value,
                clusterExtras: [0xFE0F], width: 2))
        XCTAssertEqual(strictlyLeft.buffer.x, 1)

        strictlyLeft.feed(text: "\u{2764}\u{FE0F}")
        XCTAssertEqual(strictlyLeft.buffer.liveLine(0)[0], Cell())
        XCTAssertEqual(
            strictlyLeft.buffer.liveLine(0)[1],
            Cell(
                scalar: UnicodeScalar("\u{2764}").value,
                clusterExtras: [0xFE0F], width: 2))
        XCTAssertEqual(strictlyLeft.buffer.x, 3)

        let landsOnOwner = CmdyTerminal(cols: 4, rows: 1)
        landsOnOwner.feed(text: "\u{1B}[1;2H0\u{1B}[D\u{FE0F}")
        XCTAssertEqual(landsOnOwner.buffer.liveLine(0)[1].width, 2)
        XCTAssertEqual(landsOnOwner.buffer.x, 2)

        let forwardEdge = CmdyTerminal(cols: 4, rows: 2)
        forwardEdge.feed(text:
            "\u{1B}[1;2H0\u{1B}[C\u{FE0F}\u{2764}\u{FE0F}")
        XCTAssertEqual(forwardEdge.buffer.liveLine(0)[1].width, 2)
        XCTAssertEqual(
            forwardEdge.buffer.liveLine(1)[0],
            Cell(
                scalar: UnicodeScalar("\u{2764}").value,
                clusterExtras: [0xFE0F], width: 2))
        XCTAssertEqual(forwardEdge.buffer.y, 1)
        XCTAssertEqual(forwardEdge.buffer.x, 2)
    }

    func testVS16KeepsStrictLeftCarriageReturnHistoryAcrossNoOpRepeats() {
        let terminal = CmdyTerminal(cols: 3, rows: 1)
        terminal.feed(text:
            "a0\r\r\u{FE0F}\u{1F1FA}\u{1F1F8}")

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell(scalar: 0x61))
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[1],
            Cell(
                scalar: 0x1F1FA,
                clusterExtras: [0x1F1F8], width: 2))
        XCTAssertEqual(terminal.buffer.liveLine(0)[2].width, 0)
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testVS16KeepsStrictLeftHistoryAcrossVerticalBoundaryNoOp() {
        let terminal = CmdyTerminal(cols: 3, rows: 3)
        terminal.feed(text:
            "a0\u{1B}[2;3r\u{1B}M\u{FE0F}\u{1F1FA}\u{1F1F8}")

        XCTAssertEqual(terminal.buffer.liveLine(0)[0], Cell(scalar: 0x61))
        XCTAssertEqual(
            terminal.buffer.liveLine(0)[1],
            Cell(
                scalar: 0x1F1FA,
                clusterExtras: [0x1F1F8], width: 2))
        XCTAssertEqual(terminal.buffer.liveLine(0)[2].width, 0)
        XCTAssertEqual(terminal.buffer.x, 3)
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertTrue(terminal.buffer.wrapPending)
    }

    func testVS16CursorTracksLiteralTabProgress() {
        let defaultStops = CmdyTerminal(cols: 11, rows: 1)
        defaultStops.feed(text: "0\t\u{FE0F}")
        XCTAssertEqual(defaultStops.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(defaultStops.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(defaultStops.buffer.x, 9)

        let clearedStops = CmdyTerminal(cols: 11, rows: 1)
        clearedStops.feed(text: "\u{1B}[3g0\t\u{FE0F}")
        XCTAssertEqual(clearedStops.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(clearedStops.buffer.x, 11)

        let noProgress = CmdyTerminal(cols: 11, rows: 1)
        noProgress.feed(text: "\u{1B}[1;10H0\t\u{FE0F}")
        XCTAssertEqual(noProgress.buffer.liveLine(0)[9].width, 2)
        XCTAssertEqual(noProgress.buffer.x, 11)

        let pendingNormalizesBackward = CmdyTerminal(cols: 11, rows: 1)
        pendingNormalizesBackward.feed(text: "\u{1B}[1;11H0\t\u{FE0F}")
        XCTAssertEqual(pendingNormalizesBackward.buffer.liveLine(0)[10].width, 1)
        XCTAssertEqual(pendingNormalizesBackward.buffer.x, 10)
        XCTAssertFalse(pendingNormalizesBackward.buffer.wrapPending)
    }

    func testLiteralTabUsesActiveFallbackFromLeftOfHorizontalSlice() {
        func configured(active: Bool = true) -> CmdyTerminal {
            let terminal = CmdyTerminal(cols: 10, rows: 1)
            terminal.setPrivateMode(69, true)
            terminal.buffer.marginLeft = 1
            terminal.buffer.marginRight = 8
            terminal.buffer.clearAllTabStops()
            if !active { terminal.setPrivateMode(69, false) }
            return terminal
        }

        let noStops = configured()
        noStops.executeControl(0x09)
        XCTAssertEqual(noStops.buffer.x, 8)
        noStops.feed(text: "A")
        XCTAssertEqual(noStops.buffer.liveLine(0)[8].scalar, 0x41)

        let stopInside = configured()
        stopInside.buffer.setTabStop(at: 4)
        stopInside.executeControl(0x09)
        XCTAssertEqual(stopInside.buffer.x, 4)

        let stopPastRight = configured()
        stopPastRight.buffer.setTabStop(at: 9)
        stopPastRight.executeControl(0x09)
        XCTAssertEqual(stopPastRight.buffer.x, 8)

        let repeated = configured()
        repeated.executeControl(0x09)
        repeated.executeControl(0x09)
        XCTAssertEqual(repeated.buffer.x, 8)

        let hiddenMargins = configured(active: false)
        hiddenMargins.executeControl(0x09)
        XCTAssertEqual(hiddenMargins.buffer.x, 9)
    }

    func testVS16CursorTracksVerticalAndNELRepositioning() {
        let vertical = CmdyTerminal(cols: 4, rows: 3)
        vertical.feed(text: "0\u{1B}[2;2H\u{FE0F}")
        XCTAssertEqual(vertical.buffer.liveLine(0)[0].width, 2)
        XCTAssertEqual(vertical.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(vertical.buffer.x, 2)
        XCTAssertEqual(vertical.buffer.y, 1)

        let landsOnWrappedOwner = CmdyTerminal(cols: 4, rows: 3)
        landsOnWrappedOwner.feed(text:
            "\u{1B}[?69h\u{1B}[1;3s\u{1B}[2;4H0" +
            "\u{1B}[3;1H\u{FE0F}")
        XCTAssertEqual(landsOnWrappedOwner.buffer.liveLine(2)[0].width, 2)
        XCTAssertEqual(landsOnWrappedOwner.buffer.liveLine(2)[1].width, 0)
        XCTAssertEqual(landsOnWrappedOwner.buffer.x, 1)
        XCTAssertEqual(landsOnWrappedOwner.buffer.y, 2)

        let nelStrictlyLeft = CmdyTerminal(cols: 4, rows: 3)
        nelStrictlyLeft.feed(text:
            "\u{1B}[?69h\u{1B}[2;3s\u{1B}[2;4H0" +
            "\u{1B}E\u{FE0F}")
        XCTAssertEqual(nelStrictlyLeft.buffer.liveLine(2)[1].width, 2)
        XCTAssertEqual(nelStrictlyLeft.buffer.liveLine(2)[2].width, 0)
        XCTAssertEqual(nelStrictlyLeft.buffer.x, 1)
        XCTAssertEqual(nelStrictlyLeft.buffer.y, 2)
    }

    private func configuredMarginTerminal() -> CmdyTerminal {
        let terminal = CmdyTerminal(cols: 6, rows: 5)
        terminal.setPrivateMode(69, true)
        terminal.buffer.marginLeft = 1
        terminal.buffer.marginRight = 4
        terminal.buffer.scrollTop = 1
        terminal.buffer.scrollBottom = 3
        for row in 0..<terminal.buffer.rows {
            for column in 0..<terminal.buffer.cols {
                terminal.buffer.liveLine(row)[column] = Cell(
                    scalar: UInt32(1 + row * terminal.buffer.cols + column))
            }
        }
        return terminal
    }

    private func matrix(_ terminal: CmdyTerminal) -> [[UInt32]] {
        (0..<terminal.buffer.rows).map { row in
            terminal.buffer.liveLine(row).cells.map(\.scalar)
        }
    }

    private func seedRow(_ terminal: CmdyTerminal, row: Int, scalars: [UInt32]) {
        for (column, scalar) in scalars.prefix(terminal.buffer.cols).enumerated() {
            terminal.buffer.liveLine(row)[column] = Cell(scalar: scalar)
        }
    }

    private func assertOutsideRectangleUnchanged(
        _ terminal: CmdyTerminal,
        before: [[UInt32]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for row in 0..<terminal.buffer.rows {
            for column in 0..<terminal.buffer.cols
                where !(terminal.buffer.scrollTop...terminal.buffer.scrollBottom).contains(row)
                    || !(terminal.buffer.marginLeft...terminal.buffer.marginRight).contains(column) {
                XCTAssertEqual(
                    terminal.buffer.liveLine(row)[column].scalar,
                    before[row][column],
                    "row \(row), column \(column)", file: file, line: line)
            }
        }
    }

    private func assertSlice(
        _ terminal: CmdyTerminal,
        row: Int,
        equals expected: [UInt32],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = (terminal.buffer.marginLeft...terminal.buffer.marginRight)
            .map { terminal.buffer.liveLine(row)[$0].scalar }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}
