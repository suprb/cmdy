import Foundation
import XCTest
@testable import CmdyCore

final class OrdinaryUnicodeReentryTests: XCTestCase {
    func testFirstOrdinaryScalarLeavesReentrantCSIForOuterBytes() {
        for owned in [true, false] {
            let actual = exercise(owned: owned, batches: true, nested: [0x1B, 0x5B], outer: "α31mZ")
            let expected = exercise(owned: owned, batches: false, nested: [0x1B, 0x5B], outer: "α31mZ")
            XCTAssertEqual(expected.terminal.currentAttribute.fg, .ansi256(1))
            XCTAssertTrue(expected.terminal.buffer.lines.flatMap(\.cells).contains {
                $0.scalar == 90 && $0.attribute.fg == .ansi256(1)
            })
            equivalent(actual, expected, "complete CSI; owned \(owned)")
            continueAndCompare(actual, expected, suffix: Array("\u{301}\u{FE0F}\u{1B}[6n".utf8))
        }
    }

    func testFirstOrdinaryScalarPreservesIncompleteCSIAtOuterEnd() {
        for owned in [true, false] {
            let actual = exercise(owned: owned, batches: true, nested: [0x1B, 0x5B], outer: "α31")
            let expected = exercise(owned: owned, batches: false, nested: [0x1B, 0x5B], outer: "α31")
            XCTAssertEqual(expected.parser.state, .csiParam)
            equivalent(actual, expected, "partial CSI; owned \(owned)")
            continueAndCompare(actual, expected, suffix: Array("mZ\u{301}\u{1B}[6n".utf8))
            XCTAssertEqual(expected.terminal.currentAttribute.fg, .ansi256(1))
        }
    }

    func testFirstOrdinaryScalarPreservesReentrantPendingUTF8() {
        for owned in [true, false] {
            let actual = exercise(owned: owned, batches: true, nested: [0xE2], outer: "αABZ")
            let expected = exercise(owned: owned, batches: false, nested: [0xE2], outer: "αABZ")
            // Existing malformed-tail behavior consumes A/B into the pending
            // three-byte sequence and emits its Latin-1 lead, then prints Z.
            XCTAssertTrue(expected.terminal.buffer.lines.flatMap(\.cells).contains { $0.scalar == 0xE2 })
            equivalent(actual, expected, "pending UTF8; owned \(owned)")
            continueAndCompare(actual, expected, suffix: [0x82, 0xAC] + Array("\u{301}\u{1B}[6n".utf8))
        }
    }

    func testFirstOrdinaryScalarPreservesSplitReentrantOSCPayload() {
        for owned in [true, false] {
            let nested = Array("\u{1B}]0;".utf8)
            let actual = exercise(owned: owned, batches: true, nested: nested, outer: "αTit")
            let expected = exercise(owned: owned, batches: false, nested: nested, outer: "αTit")
            XCTAssertEqual(expected.parser.state, .oscString)
            XCTAssertEqual(expected.observer.titles, [])
            equivalent(actual, expected, "partial OSC; owned \(owned)")
            continueAndCompare(actual, expected, suffix: Array("le\u{7}Z\u{1B}[6n".utf8))
            XCTAssertEqual(expected.observer.titles, ["Title"])
        }
    }

    func testStandaloneFirstOrdinaryScalarHonorsDelegateReplacement() {
        func exerciseReplacement(batches: Bool) -> [UInt32] {
            let parser = VTParser()
            parser.batchesOrdinaryUnicode = batches
            var terminal: CmdyTerminal? = CmdyTerminal(cols: 4, rows: 3, scrollback: 0)
            terminal?.feed(text: "aaaa\r\nbbbb\r\ncccc")
            weak var witness = terminal
            let replacement = PublicRecorder()
            var entered = false
            terminal?.blocks.onChange = {
                guard !entered else { return }
                entered = true
                parser.delegate = replacement
                terminal = nil
                XCTAssertNotNil(witness, "the first engine callback still owns its receiver")
            }
            parser.delegate = terminal
            let input = [UInt8](repeating: 0xFF, count: 3) + Array("αBC".utf8) + [0xFF]
            autoreleasepool { parser.feed(input[3..<(input.count - 1)]) }
            XCTAssertTrue(entered)
            XCTAssertNil(witness)
            XCTAssertTrue(parser.delegate === replacement)
            XCTAssertEqual(parser.state, .ground)
            return replacement.scalars
        }
        let actual = exerciseReplacement(batches: true)
        let expected = exerciseReplacement(batches: false)
        XCTAssertEqual(expected, [66, 67])
        XCTAssertEqual(actual, expected)
    }

    private func exercise(owned: Bool, batches: Bool, nested: [UInt8], outer: String) -> Run {
        let run = Run(owned: owned, batches: batches)
        run.feed(Array("aaaa\r\nbbbb\r\ncccc".utf8)[...])
        XCTAssertTrue(run.terminal.buffer.wrapPending)
        run.retained = run.terminal.captureTerminalSnapshot(consumeDamage: false)
        run.retainedCells = run.retained!.lines.map(\.cells)
        run.retainedVersions = run.retained!.lines.map(\.version)
        _ = run.terminal.consumeDirtyRows()
        run.terminal.blocks.onChange = { [weak run] in
            guard let run, !run.entered else { return }
            run.entered = true
            run.callbackStates.append(String(describing: run.parser.state))
            run.feed(nested[...])
            run.callbackStates.append(String(describing: run.parser.state))
        }
        let input = [UInt8](repeating: 0xFF, count: 3) + Array(outer.utf8) + [0xFF]
        run.feed(input[3..<(input.count - 1)])
        XCTAssertTrue(run.entered, "the real first-scalar wrap must enter the callback")
        XCTAssertEqual(run.retained!.lines.map(\.cells), run.retainedCells)
        XCTAssertEqual(run.retained!.lines.map(\.version), run.retainedVersions)
        return run
    }

    private func continueAndCompare(_ actual: Run, _ expected: Run, suffix: [UInt8]) {
        actual.feed(suffix[...]); expected.feed(suffix[...])
        equivalent(actual, expected, "subsequent parser/cluster continuation")
        XCTAssertEqual(actual.retained!.lines.map(\.cells), actual.retainedCells)
        XCTAssertEqual(actual.retained!.lines.map(\.version), actual.retainedVersions)
    }

    private func equivalent(_ a: Run, _ b: Run, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.parser.state, b.parser.state, context, file: file, line: line)
        XCTAssertEqual(a.callbackStates, b.callbackStates, context, file: file, line: line)
        XCTAssertEqual(a.observer.titles, b.observer.titles, context, file: file, line: line)
        XCTAssertEqual(a.observer.replies, b.observer.replies, context, file: file, line: line)
        XCTAssertEqual(a.terminal.currentAttribute, b.terminal.currentAttribute, context, file: file, line: line)
        XCTAssertEqual(a.terminal.dirtyRowSpan, b.terminal.dirtyRowSpan, context, file: file, line: line)
        XCTAssertEqual(a.terminal.isAlternateBuffer, b.terminal.isAlternateBuffer, context, file: file, line: line)
        for (left, right) in [(a.terminal.normalBuffer, b.terminal.normalBuffer),
                              (a.terminal.altBuffer, b.terminal.altBuffer)] {
            XCTAssertEqual([left.cols, left.rows, left.x, left.y, left.yBase, left.yDisp,
                            left.lineCount, left.droppedLines],
                           [right.cols, right.rows, right.x, right.y, right.yBase, right.yDisp,
                            right.lineCount, right.droppedLines], context, file: file, line: line)
            XCTAssertEqual(left.wrapPending, right.wrapPending, context, file: file, line: line)
            XCTAssertEqual(left.lines.map(\.cells), right.lines.map(\.cells), context, file: file, line: line)
            XCTAssertEqual(left.lines.map(\.isWrapped), right.lines.map(\.isWrapped), context, file: file, line: line)
            XCTAssertEqual(left.lines.map(\.renderMode), right.lines.map(\.renderMode), context, file: file, line: line)
        }
    }

    private final class Run {
        let terminal = CmdyTerminal(cols: 4, rows: 3, scrollback: 0)
        let parser: VTParser
        let owned: Bool
        let observer = Observer()
        var entered = false
        var callbackStates: [String] = []
        var retained: CoreTerminalSnapshot?
        var retainedCells: [[Cell]] = []
        var retainedVersions: [UInt64] = []
        init(owned: Bool, batches: Bool) {
            self.owned = owned
            parser = owned ? terminal.parser : VTParser()
            parser.delegate = terminal
            parser.batchesOrdinaryUnicode = batches
            terminal.delegate = observer
        }
        func feed(_ bytes: ArraySlice<UInt8>) {
            if owned { terminal.feed(bytes) } else { parser.feed(bytes) }
        }
    }

    private final class Observer: CmdyTerminalDelegate {
        var titles: [String] = []
        var replies: [[UInt8]] = []
        func contentChanged(_ terminal: CmdyTerminal) {}
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) { replies.append(Array(data)) }
        func setTitle(_ terminal: CmdyTerminal, title: String) { titles.append(title) }
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {}
        func bell(_ terminal: CmdyTerminal) {}
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {}
        func willReflow(_ terminal: CmdyTerminal) {}
        func didReflow(_ terminal: CmdyTerminal) {}
    }

    private final class PublicRecorder: VTParserDelegate {
        var scalars: [UInt32] = []
        func parserPrint(_ scalar: UnicodeScalar) { scalars.append(scalar.value) }
        func parserExecute(_ byte: UInt8) {}
        func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) {}
        func parserESC(final: UInt8, collect: [UInt8]) {}
        func parserOSC(code: Int, payload: ArraySlice<UInt8>) {}
        func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) {}
        func parserDCSPut(_ bytes: ArraySlice<UInt8>) {}
        func parserDCSUnhook() {}
        func parserAPC(_ bytes: ArraySlice<UInt8>) {}
    }
}
