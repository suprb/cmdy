import Foundation
import XCTest
@testable import CmdyCore

final class VTParserOwnerControlReentryTests: XCTestCase {
    func testRawCRLFRereadsAlternateBufferAfterBlockCallback() {
        func exercise(_ owned: Bool) -> Run {
            let run = Run(owned: owned)
            run.feed("aa\r\nbb\r\ncc")
            var switched = false
            run.terminal.blocks.onChange = { [weak run] in
                guard let run else { return }
                run.events.append("block:\(run.terminal.isAlternateBuffer)")
                guard !switched else { return }
                switched = true
                run.feed("\u{1B}[?1049h\u{1B}[HALT")
            }
            // These controls enter the new owner ground-control branch. The
            // first LF invokes onChange while recycling the capped normal
            // screen; the next CR/LF must read the now-active alternate grid.
            run.feed("\r\n\r\n")
            XCTAssertTrue(switched)
            XCTAssertTrue(run.terminal.isAlternateBuffer)
            XCTAssertEqual(run.terminal.altBuffer.y, 1)
            XCTAssertEqual(run.terminal.altBuffer.x, 0)
            XCTAssertEqual(run.terminal.altBuffer.liveLine(0).cells.prefix(3).map(\.scalar), [65, 76, 84])
            run.feed("\u{1B}[?1049l")
            XCTAssertFalse(run.terminal.isAlternateBuffer)
            return run
        }
        equivalent(exercise(true), exercise(false))
    }

    func testRawCRLFRereadsNormalBufferAfterImageDeallocatorCallback() {
        func exercise(_ owned: Bool) -> Run {
            let run = Run(owned: owned)
            run.feed("N\u{1B}[?1049ha\r\nb\r\nc")
            run.attachImage { [weak run] in
                guard let run else { return }
                run.releases += 1
                run.events.append("image:\(run.terminal.isAlternateBuffer)")
                run.feed("\u{1B}[?1049l")
            }
            // The alternate buffer grows its single history row on the first
            // LF and releases that image on the second. The third CR/LF must
            // use the normal buffer restored by the deallocator's feed call.
            run.feed("\r\n\r\n\r\n")
            XCTAssertEqual(run.releases, 1)
            XCTAssertFalse(run.terminal.isAlternateBuffer)
            XCTAssertEqual(run.terminal.normalBuffer.y, 1)
            XCTAssertEqual(run.terminal.normalBuffer.x, 0)
            XCTAssertEqual(run.terminal.normalBuffer.liveLine(0)[0].scalar, 78)
            return run
        }
        equivalent(exercise(true), exercise(false))
    }

    private func equivalent(_ actual: Run, _ expected: Run,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.events, expected.events, file: file, line: line)
        let a = actual.terminal, b = expected.terminal
        XCTAssertEqual(a.parser.state, b.parser.state, file: file, line: line)
        XCTAssertEqual(a.isAlternateBuffer, b.isAlternateBuffer, file: file, line: line)
        XCTAssertEqual(a.dirtyRowSpan, b.dirtyRowSpan, file: file, line: line)
        XCTAssertEqual(a.currentAttribute, b.currentAttribute, file: file, line: line)
        XCTAssertEqual(a.blocksDroppedLineCheckpoint, b.blocksDroppedLineCheckpoint, file: file, line: line)
        for (first, second) in [(a.normalBuffer, b.normalBuffer), (a.altBuffer, b.altBuffer)] {
            XCTAssertEqual([first.x, first.y, first.yBase, first.yDisp, first.lineCount, first.droppedLines],
                           [second.x, second.y, second.yBase, second.yDisp, second.lineCount, second.droppedLines],
                           file: file, line: line)
            XCTAssertEqual(first.wrapPending, second.wrapPending, file: file, line: line)
            XCTAssertEqual(first.lines.map(\.cells), second.lines.map(\.cells), file: file, line: line)
            XCTAssertEqual(first.lines.map(\.isWrapped), second.lines.map(\.isWrapped), file: file, line: line)
            XCTAssertEqual(first.lines.map { $0.images?.count ?? 0 }, second.lines.map { $0.images?.count ?? 0 },
                           file: file, line: line)
        }
    }

    private final class Run {
        let terminal = CmdyTerminal(cols: 4, rows: 3, scrollback: 0)
        let owned: Bool
        var events: [String] = []
        var releases = 0
        init(owned: Bool) { self.owned = owned }
        func feed(_ text: String) {
            let bytes = Array(text.utf8)[...]
            if owned {
                terminal.feed(bytes)
            } else {
                terminal.recorder?.record(bytes)
                terminal.parser.feed(bytes)
                terminal.synchronizeBlockRowsToScrollback()
                terminal.delegate?.contentChanged(terminal)
            }
        }
        func attachImage(onRelease: @escaping () -> Void) {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
            memory.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
            let data = Data(bytesNoCopy: memory, count: 4096, deallocator: .custom { memory, _ in
                memory.deallocate()
                onRelease()
            })
            terminal.lineForDiff(absolute: 0)?.images = [LineImage(payload: .png(data),
                pixelWidth: 1, pixelHeight: 1, col: 0)]
        }
    }
}
