import XCTest
@testable import CmdyCore

final class SGRDispatchTests: XCTestCase {
    func testPenOnlySGRPreservesCellsVersionsCursorAndPendingWrap() {
        for alternate in [false, true] {
            let terminal = CmdyTerminal(cols: 8, rows: 3, scrollback: 7)
            if alternate { terminal.feed(text: "\u{1B}[?1049h") }
            terminal.feed(text: "prior\r\nline\r\nscroll\r\n12345678")
            XCTAssertTrue(terminal.buffer.wrapPending)
            let row = terminal.scrollInvariantCursorRow
            let column = terminal.cursorColumn
            let top = terminal.liveScreenTopRow
            let snapshot = terminal.captureTerminalSnapshot(extraScreens: 10)
            let cells = terminal.buffer.lines.map(\.cells)
            let versions = terminal.buffer.lines.map(\.version)
            let wrapped = terminal.buffer.lines.map(\.isWrapped)
            let observer = Observer()
            terminal.delegate = observer

            terminal.feed(text: "\u{1B}[1;38;2;10;20;30;4:3;58:5:201m")

            XCTAssertEqual(terminal.currentAttribute, CellAttribute(
                fg: .trueColor(10, 20, 30), style: [.bold, .underline],
                underlineKind: .curly, underlineColor: .ansi256(201)))
            XCTAssertEqual(terminal.scrollInvariantCursorRow, row)
            XCTAssertEqual(terminal.cursorColumn, column)
            XCTAssertEqual(terminal.liveScreenTopRow, top)
            XCTAssertTrue(terminal.buffer.wrapPending)
            XCTAssertEqual(terminal.isAlternateBuffer, alternate)
            XCTAssertEqual(terminal.buffer.lines.map(\.cells), cells)
            XCTAssertEqual(terminal.buffer.lines.map(\.version), versions)
            XCTAssertEqual(terminal.buffer.lines.map(\.isWrapped), wrapped)
            XCTAssertEqual(snapshot.lines.map(\.cells), cells)
            XCTAssertEqual(terminal.consumeDirtyRows(), row...row)
            XCTAssertNil(terminal.consumeDirtyRows())
            XCTAssertEqual(observer.events, ["change"])
        }
    }

    func testIgnoredPrivateAndIntermediateSGRKeepPenAndDamageUnion() {
        let terminal = CmdyTerminal(cols: 8, rows: 4)
        terminal.feed(text: "\u{1B}[3;4H\u{1B}[31;44;1m")
        let pen = terminal.currentAttribute
        let observer = Observer()
        terminal.delegate = observer
        for sequence in ["\u{1B}[?0m", "\u{1B}[>32m", "\u{1B}[4 m", "\u{1B}[0$m"] {
            _ = terminal.consumeDirtyRows()
            terminal.markDirty(absoluteRow: 0)
            terminal.feed(text: sequence)
            XCTAssertEqual(terminal.currentAttribute, pen, sequence)
            XCTAssertEqual(terminal.cursorColumn, 3)
            XCTAssertEqual(terminal.scrollInvariantCursorRow, 2)
            XCTAssertEqual(terminal.consumeDirtyRows(), 0...2)
        }
        XCTAssertEqual(observer.events, Array(repeating: "change", count: 4))
    }

    func testSGRDoesNotDetachCombiningSelectorOrJoinerOwners() {
        let clusters = [("e", "\u{301}"), ("❤", "\u{FE0F}"),
                        ("👩", "🏽\u{200D}💻"), ("👩\u{200D}", "💻")]
        for autowrap in [false, true] {
            for width in [2, 8] {
                for (prefix, suffix) in clusters {
                    let plain = CmdyTerminal(cols: width, rows: 3)
                    let styled = CmdyTerminal(cols: width, rows: 3)
                    for terminal in [plain, styled] {
                        terminal.feed(text: autowrap ? "\u{1B}[?7h" : "\u{1B}[?7l")
                        terminal.feed(text: String(repeating: "x", count: width - 1) + prefix)
                    }
                    styled.feed(text: "\u{1B}[38:2::10:20:30;1m")
                    for terminal in [plain, styled] { terminal.feed(text: suffix + "!") }
                    XCTAssertEqual(styled.bufferLineCount, plain.bufferLineCount)
                    XCTAssertEqual(styled.scrollInvariantCursorRow, plain.scrollInvariantCursorRow)
                    XCTAssertEqual(styled.cursorColumn, plain.cursorColumn)
                    XCTAssertEqual(styled.buffer.wrapPending, plain.buffer.wrapPending)
                    for row in 0..<plain.bufferLineCount {
                        let a = styled.lineForDiff(absolute: row)!
                        let b = plain.lineForDiff(absolute: row)!
                        XCTAssertEqual(a.cells.map(\.scalar), b.cells.map(\.scalar))
                        XCTAssertEqual(a.cells.map(\.width), b.cells.map(\.width))
                        XCTAssertEqual(a.cells.map(\.clusterExtras), b.cells.map(\.clusterExtras))
                        XCTAssertEqual(a.isWrapped, b.isWrapped)
                    }
                }
            }
        }
    }

    func testSGRFeedPublishesOnceAndAllowsContentCallbackReentry() {
        let terminal = CmdyTerminal(cols: 8, rows: 3)
        let observer = Observer()
        terminal.delegate = observer
        var pens: [CellAttribute] = []
        var damages: [ClosedRange<Int>?] = []
        observer.onChange = { terminal in
            pens.append(terminal.currentAttribute)
            damages.append(terminal.consumeDirtyRows())
            if pens.count == 1 {
                terminal.feed(text: "\u{1B}[32mY\u{1B}[6n")
            }
        }

        terminal.feed(text: "\u{1B}[31m")

        XCTAssertEqual(pens, [CellAttribute(fg: .ansi256(1)), CellAttribute(fg: .ansi256(2))])
        XCTAssertEqual(damages, [0...0, 0...0])
        XCTAssertEqual(observer.events, ["change", "send:1b5b313b3252", "change"])
        XCTAssertEqual(terminal.currentAttribute.fg, .ansi256(2))
        XCTAssertEqual(terminal.lineForDiff(absolute: 0)?.cells[0], Cell(scalar: 89, attribute: CellAttribute(fg: .ansi256(2))))
        XCTAssertEqual(terminal.cursorColumn, 1)
    }

    private final class Observer: CmdyTerminalDelegate {
        var events: [String] = []
        var onChange: ((CmdyTerminal) -> Void)?
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) {
            events.append("send:" + data.map { String(format: "%02x", $0) }.joined())
        }
        func contentChanged(_ terminal: CmdyTerminal) {
            events.append("change"); onChange?(terminal)
        }
        func setTitle(_ terminal: CmdyTerminal, title: String) { events.append("title") }
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) { events.append("directory") }
        func bell(_ terminal: CmdyTerminal) { events.append("bell") }
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) { events.append("clipboard") }
        func willReflow(_ terminal: CmdyTerminal) { events.append("willReflow") }
        func didReflow(_ terminal: CmdyTerminal) { events.append("didReflow") }
    }
}
