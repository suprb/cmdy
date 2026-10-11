import Foundation
import XCTest
@testable import CmdyCore

final class VTParserOwnerDispatchTests: XCTestCase {
    func testWholeEngineMatchesGenericRouteAtEverySplit() {
        let sequences = [
            "\u{1B}[31;44mabc\u{1B}[0mdef\r\nnext\r\nlast\r\n",
            "\u{1B}[4:3;38:2::1:2:3mA\u{1B}[?1mB\u{1B}[4 mC",
            "\u{1B}[" + String(repeating: "9", count: 260) + "mX",
            "\u{1B}[" + String(repeating: ";1", count: 257) + "mX",
            "\u{1B}[?1049h\u{1B}[2;3r\u{1B}[?69h\u{1B}[2;5sABCDEFG\r\nH\u{1B}[?1049l",
            "\u{1B}]0;title\u{7}\u{1B}[6n\u{1B}P$qm\u{1B}\\\u{1B}_ignored\u{1B}\\",
            "A界e\u{301}👩\u{200D}💻7\u{FE0F}\r\n\u{1B}[1A\u{FE0E}Z"
        ]
        for text in sequences {
            let payload = Array(text.utf8)
            let storage = [UInt8](repeating: 0xFF, count: 7) + payload + [0xFF]
            for cut in 0...payload.count {
                let actual = Run(owned: true), expected = Run(owned: false)
                for part in [storage[7..<(7 + cut)], storage[(7 + cut)..<(7 + payload.count)]] {
                    actual.feed(part); expected.feed(part)
                    equivalent(actual, expected, "length \(payload.count), cut \(cut)")
                }
                // Observe continuation ownership and any partial parser state.
                actual.feed("\u{18}\u{1B}[0m7\u{FE0F}\u{301}\r\nZ")
                expected.feed("\u{18}\u{1B}[0m7\u{FE0F}\u{301}\r\nZ")
                equivalent(actual, expected, "continuation after cut \(cut)")
            }
        }
    }

    func testEveryInterruptedCSIByteAndFinalMatchesGenericRoute() {
        for byte in UInt8.min...UInt8.max {
            let payload = [0x1B, 0x5B, 0x33, 0x31, 0x3B, byte, 0x33, 0x32, 0x6D, 0x58]
            for chunk in [1, 3, payload.count] {
                let actual = Run(owned: true), expected = Run(owned: false)
                for start in stride(from: 0, to: payload.count, by: chunk) {
                    let part = payload[start..<min(payload.count, start + chunk)]
                    actual.feed(part); expected.feed(part)
                    equivalent(actual, expected, "byte \(byte), chunk \(chunk)")
                }
            }
        }
        for final in UInt8(0x40)...UInt8(0x7E) {
            for body in ["", ";31;;", "38:2::1:2:3", "?1", "4 "] {
                let actual = Run(owned: true), expected = Run(owned: false)
                let bytes = Array(("\u{1B}[" + body).utf8) + [final, 0x21]
                actual.feed(bytes[...]); expected.feed(bytes[...])
                equivalent(actual, expected, "final \(final), body \(body)")
            }
        }
    }

    func testBlockCallbackReentryLeavesPartialCSIForOuterBytes() {
        func exercise(owned: Bool) -> Run {
            let run = Run(owned: owned, columns: 4, rows: 2, scrollback: 0)
            var entered = false
            run.terminal.blocks.onChange = { [weak run] in
                guard let run else { return }
                run.log.events.append("block:\(run.terminal.parser.state)")
                guard !entered else { return }
                entered = true
                run.feed("\u{1B}[")
            }
            run.feed("ab\r\ncd\r\n31mZ")
            XCTAssertTrue(entered)
            XCTAssertEqual(run.terminal.parser.state, .ground)
            XCTAssertEqual(run.terminal.currentAttribute.fg, .ansi256(1))
            XCTAssertTrue(run.terminal.buffer.lines.flatMap(\.cells).contains {
                $0.scalar == 0x5A && $0.attribute.fg == .ansi256(1)
            })
            return run
        }
        equivalent(exercise(owned: true), exercise(owned: false), "block reentry")
    }

    func testImageDeallocatorReentryPreservesOrderAndOuterState() {
        func exercise(owned: Bool) -> Run {
            let run = Run(owned: owned, columns: 4, rows: 2, scrollback: 0)
            attachCustomImage(to: run.terminal) { [weak run] in
                guard let run else { return }
                run.imageReleases += 1
                run.log.events.append("image-release:\(run.terminal.parser.state)")
                run.feed("\u{1B}[")
            }
            run.feed("ab\r\ncd\r\n31mZ")
            XCTAssertEqual(run.imageReleases, 1, "the fixture must actually release the image during feed")
            XCTAssertEqual(run.terminal.parser.state, .ground)
            XCTAssertEqual(run.terminal.currentAttribute.fg, .ansi256(1))
            return run
        }
        equivalent(exercise(owned: true), exercise(owned: false), "Data deallocator reentry")
    }

    func testHostDelegateReplacementAndUTF8ReentryRemainObservable() {
        func exercise(owned: Bool) -> Run {
            let run = Run(owned: owned)
            let replacement = Host(name: "second", log: run.log)
            run.otherHosts.append(replacement)
            run.host.onBell = { [weak run] terminal in
                terminal.delegate = replacement
                run?.feed([0xE2][...])
            }
            run.feed([0x07, 0x82, 0xAC] + Array("\u{1B}[31mX\r\n\u{7}".utf8))
            XCTAssertEqual(run.log.events.filter { $0 == "first:bell" }.count, 1)
            XCTAssertEqual(run.log.events.filter { $0 == "second:bell" }.count, 1)
            XCTAssertTrue(run.terminal.buffer.lines.flatMap(\.cells).contains { $0.scalar == 0x20AC })
            XCTAssertEqual(run.terminal.parser.state, .ground)
            return run
        }
        equivalent(exercise(owned: true), exercise(owned: false), "host replacement and UTF-8 reentry")
    }

    func testStandalonePublicDelegateExpiresBetweenCallbacks() {
        let parser = VTParser(), log = Log()
        var first: PublicDelegate? = PublicDelegate(name: "first", log: log)
        weak var weakFirst = first
        first?.onPrint = { _ in
            first = nil
            XCTAssertNotNil(weakFirst, "the active callback still owns its receiver")
        }
        parser.delegate = first
        parser.feed(Array("A\u{1B}[31mB".utf8))
        XCTAssertNil(weakFirst)
        XCTAssertEqual(log.events, ["first:print:65", "first:deinit"])
        XCTAssertEqual(parser.state, .ground)
    }

    func testStandaloneReplacementReentryAndRetainedParametersStayExact() {
        let parser = VTParser(), log = Log()
        let first = PublicDelegate(name: "first", log: log)
        let second = PublicDelegate(name: "second", log: log)
        var retained: [[Int]] = []
        first.onCSI = { values in
            XCTAssertEqual(parser.state, .ground)
            retained.append(values)
            parser.delegate = second
            parser.reset()
            parser.feed(Array("\u{1B}[32;44mR\u{1B}[".utf8))
        }
        second.onCSI = { retained.append($0) }
        parser.delegate = first
        parser.feed(Array("\u{1B}[31;1m0mZ\u{1B}[38;2;1;2;3m".utf8))
        XCTAssertEqual(retained, [[31, 1], [32, 44], [0], [38, 2, 1, 2, 3]])
        XCTAssertEqual(log.events, [
            "first:csi:109:[31, 1]:[]", "second:csi:109:[32, 44]:[]", "second:print:82",
            "second:csi:109:[0]:[]", "second:print:90", "second:csi:109:[38, 2, 1, 2, 3]:[]"
        ])
        XCTAssertEqual(parser.state, .ground)
        withExtendedLifetime((first, second)) {}
    }

    func testStandaloneConcreteTerminalNeverQualifiesAsAnOwnedParser() {
        for useImage in [false, true] {
            let parser = VTParser(), log = Log()
            let terminal = CmdyTerminal(cols: 4, rows: 2, scrollback: 0)
            let replacement = PublicDelegate(name: "replacement", log: log)
            var changed = false
            let replace = {
                guard !changed else { return }
                changed = true
                parser.delegate = replacement
            }
            if useImage {
                attachCustomImage(to: terminal, onRelease: replace)
            } else {
                terminal.blocks.onChange = replace
            }
            parser.delegate = terminal
            parser.feed(Array("ab\r\ncd\r\n\u{1B}[31mZ".utf8))
            XCTAssertTrue(changed)
            XCTAssertEqual(terminal.currentAttribute, .empty)
            XCTAssertEqual(log.events, ["replacement:csi:109:[31]:[]", "replacement:print:90"])
            withExtendedLifetime(replacement) {}
        }
        // A concrete engine reached through the standalone weak delegate can
        // also lose its last external owner from an engine callback.
        let parser = VTParser()
        var terminal: CmdyTerminal? = CmdyTerminal(cols: 4, rows: 2, scrollback: 0)
        weak var witness = terminal
        terminal?.blocks.onChange = { terminal = nil }
        parser.delegate = terminal
        parser.feed(Array("ab\r\ncd\r\n\u{1B}[31mZ".utf8))
        XCTAssertNil(witness)
        XCTAssertNil(parser.delegate)
        XCTAssertEqual(parser.state, .ground)
    }

    func testSnapshotsAndBothBuffersSurviveMixedOwnedOutput() {
        let actual = Run(owned: true), expected = Run(owned: false)
        for run in [actual, expected] {
            run.feed("界e\u{301}7\u{FE0F}\u{1B}[1;2H")
            let row = run.terminal.buffer.liveLine(0)
            row.renderMode = .doubleWidth
            row.images = [LineImage(payload: .rgba(bytes: [1, 2, 3, 255], width: 1, height: 1),
                                    pixelWidth: 1, pixelHeight: 1, col: 3)]
        }
        let before = actual.terminal.captureTerminalSnapshot(consumeDamage: false)
        let cells = before.lines.map { row in row.cells.map { cell in
            Cell(scalar: cell.scalar, clusterExtras: cell.clusterExtras.map { $0.map { $0 } },
                 width: cell.width, attribute: cell.attribute, linkId: cell.linkId)
        } }
        let versions = before.lines.map(\.version)
        let identity = before.lines[0].images[0].renderIdentity
        let fragments = [
            "\u{1B}[31mabc\u{FE0F}\u{301}\r\n",
            "\u{1B}[?1049h\u{1B}[4h1234567890\r\n\u{1B}[4l",
            "\u{1B}[?69h\u{1B}[2;5s123456789012345\r\n\u{1B}[?69l",
            "\u{1B}M\u{FE0E}\u{1B}[?1049l" + String(repeating: "scroll\r\n", count: 12)
        ]
        for fragment in fragments {
            actual.feed(fragment); expected.feed(fragment)
            equivalent(actual, expected, fragment.debugDescription)
        }
        XCTAssertEqual(before.lines.map(\.cells), cells)
        XCTAssertEqual(before.lines.map(\.version), versions)
        XCTAssertEqual(before.lines[0].images[0].renderIdentity, identity)
        XCTAssertEqual(before.lines[0].images[0].col, 3)
    }

    func testContiguousUnicodeFlagsAndMalformedSplitsMatchGenericRoute() {
        let payloads: [[UInt8]] = [
            Array("é界🙂e\u{301}🇸🇪👩\u{200D}💻7\u{FE0F}\r\n\u{1B}[31mZ".utf8),
            [0xC0, 0xAF, 0xED, 0xA0, 0x80, 0xF4, 0x90, 0x80, 0x80,
             0xE2, 0x07, 0x82, 0xAC, 0xF0, 0x9F],
            Array("\u{1B}[?1049h界é\u{1B}[4h🙂\u{1B}[4l\u{1B}[?1049l".utf8)
                + [0xE2, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0xE7, 0x95, 0x8C]
        ]
        for decode in [false, true] {
            for batches in [false, true] {
                for payload in payloads {
                    let storage = [UInt8](repeating: 0xFF, count: 5) + payload + [0xFF]
                    for cut in 0...payload.count {
                        let actual = Run(owned: true, columns: 5, rows: 3, scrollback: 0)
                        let expected = Run(owned: false, columns: 5, rows: 3, scrollback: 0)
                        for run in [actual, expected] {
                            run.terminal.parser.decodesContiguousUTF8 = decode
                            run.terminal.parser.batchesOrdinaryUnicode = batches
                        }
                        let context = "decode \(decode), batches \(batches), cut \(cut), bytes \(payload.count)"
                        for part in [storage[5..<(5 + cut)], storage[(5 + cut)..<(5 + payload.count)]] {
                            actual.feed(part); expected.feed(part)
                            equivalent(actual, expected, context)
                        }
                        // Exercise pending UTF-8 and hidden selector/owner state
                        // after each split, rather than comparing cells alone.
                        let tail = [UInt8]([0x92, 0xA9, 0x18])
                            + Array("\u{1B}[0m7\u{FE0F}\u{301}\u{1B}[1A\u{FE0E}\u{1B}[2bZ".utf8)
                        actual.feed(tail); expected.feed(tail)
                        equivalent(actual, expected, context + " continuation")
                    }
                }
            }
        }
    }

    func testFirstContiguousUnicodeWrapReentersBlockCallback() {
        func exercise(owned: Bool, batches: Bool) -> Run {
            let run = Run(owned: owned, columns: 4, rows: 2, scrollback: 0)
            run.terminal.parser.batchesOrdinaryUnicode = batches
            run.feed("abcd\r\nefgh")
            XCTAssertTrue(run.terminal.buffer.wrapPending)
            var entered = false
            run.terminal.blocks.onChange = { [weak run] in
                guard let run, !entered else { return }
                entered = true
                run.log.events.append("unicode-block:\(run.terminal.parser.state)")
                run.feed("\u{1B}[")
            }
            // A regional indicator uses the contiguous decoder but cannot
            // extend an ordinary run. Its wrap triggers the actual callback;
            // the next outer bytes must observe that callback's partial CSI.
            run.feed("🇸31mZ")
            XCTAssertTrue(entered)
            XCTAssertEqual(run.terminal.parser.state, .ground)
            XCTAssertEqual(run.terminal.currentAttribute.fg, .ansi256(1))
            XCTAssertTrue(run.terminal.buffer.lines.flatMap(\.cells).contains {
                $0.scalar == 0x5A && $0.attribute.fg == .ansi256(1)
            })
            return run
        }
        for batches in [false, true] {
            equivalent(exercise(owned: true, batches: batches),
                       exercise(owned: false, batches: batches), "first Unicode block reentry")
        }
    }

    func testFirstContiguousUnicodeImageReleaseLeavesPartialUTF8() {
        func exercise(owned: Bool, batches: Bool) -> Run {
            let run = Run(owned: owned, columns: 4, rows: 2, scrollback: 0)
            run.terminal.parser.batchesOrdinaryUnicode = batches
            run.feed("abcd\r\nefgh")
            attachCustomImage(to: run.terminal) { [weak run] in
                guard let run else { return }
                run.imageReleases += 1
                run.log.events.append("unicode-image:\(run.terminal.parser.state)")
                run.feed([0xE2][...])
            }
            run.feed(Array("🇸".utf8) + [0x82, 0xAC] + Array("\u{1B}[32mX".utf8))
            XCTAssertEqual(run.imageReleases, 1)
            XCTAssertEqual(run.terminal.parser.state, .ground)
            XCTAssertEqual(run.terminal.currentAttribute.fg, .ansi256(2))
            XCTAssertTrue(run.terminal.buffer.lines.flatMap(\.cells).contains { $0.scalar == 0x20AC })
            return run
        }
        for batches in [false, true] {
            equivalent(exercise(owned: true, batches: batches),
                       exercise(owned: false, batches: batches), "first Unicode Data reentry")
        }
    }

    func testStandaloneContiguousUnicodeReplacementReentersPartialCSI() {
        for batches in [false, true] {
            let parser = VTParser(), log = Log()
            parser.batchesOrdinaryUnicode = batches
            let first = PublicDelegate(name: "first", log: log)
            let second = PublicDelegate(name: "second", log: log)
            first.onPrint = { scalar in
                XCTAssertEqual(scalar.value, 0xE9)
                XCTAssertEqual(parser.state, .ground)
                parser.delegate = second
                parser.reset()
                parser.feed(Array("\u{1B}[".utf8))
            }
            parser.delegate = first
            let storage = [UInt8](repeating: 0xFF, count: 3) + Array("é31m界".utf8)
            parser.feed(storage[3...])
            XCTAssertEqual(log.events, [
                "first:print:233", "second:csi:109:[31]:[]", "second:print:30028"
            ])
            XCTAssertEqual(parser.state, .ground)
            withExtendedLifetime((first, second)) {}
        }
    }

    func testStandaloneContiguousUnicodeDelegateExpiresBetweenScalars() {
        for batches in [false, true] {
            let parser = VTParser(), log = Log()
            parser.batchesOrdinaryUnicode = batches
            var first: PublicDelegate? = PublicDelegate(name: "first", log: log)
            weak var witness = first
            first?.onPrint = { scalar in
                XCTAssertEqual(scalar.value, 0xE9)
                first = nil
                XCTAssertNotNil(witness, "the active scalar callback owns its receiver")
            }
            parser.delegate = first
            parser.feed(Array("é界🙂".utf8))
            XCTAssertNil(witness)
            XCTAssertNil(parser.delegate)
            XCTAssertEqual(log.events, ["first:print:233", "first:deinit"])
            XCTAssertEqual(parser.state, .ground)
        }
    }

    func testStandaloneConcreteUnicodeReceiverCanExpireAndBeReplaced() {
        for batches in [false, true] {
            let parser = VTParser(), log = Log()
            parser.batchesOrdinaryUnicode = batches
            var terminal: CmdyTerminal? = CmdyTerminal(cols: 4, rows: 2, scrollback: 0)
            terminal?.feed(text: "abcd\r\nefgh")
            weak var witness = terminal
            let replacement = PublicDelegate(name: "replacement", log: log)
            var changed = false
            terminal?.blocks.onChange = {
                guard !changed else { return }
                changed = true
                parser.delegate = replacement
                parser.feed(Array("\u{1B}[".utf8))
                terminal = nil
                XCTAssertNotNil(witness, "the engine callback retains the concrete receiver")
            }
            parser.delegate = terminal
            autoreleasepool { parser.feed(Array("🇸31mZ".utf8)) }
            XCTAssertTrue(changed)
            XCTAssertNil(witness)
            XCTAssertTrue(parser.delegate === replacement)
            XCTAssertEqual(log.events, ["replacement:csi:109:[31]:[]", "replacement:print:90"])
            XCTAssertEqual(parser.state, .ground)
            withExtendedLifetime(replacement) {}
        }
    }

    func testAllEightRetainedCorporaMatchGenericRouteWhenSupplied() throws {
        guard let directory = ProcessInfo.processInfo.environment["CMDY_OWNED_OUTPUT_CORPUS_DIR"] else {
            throw XCTSkip("Set CMDY_OWNED_OUTPUT_CORPUS_DIR to the eight retained corpus files.")
        }
        for name in ["unicode", "styled", "source", "lines", "continuous", "sgr-fallback", "diversity", "collisions"] {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: directory)
                .appendingPathComponent(name + ".bin")))
            XCTAssertEqual(bytes.count, 3_000_000)
            for (columns, rows) in [(120, 36), (212, 62)] {
                let actual = Run(owned: true, columns: columns, rows: rows, scrollback: 10_000)
                let expected = Run(owned: false, columns: columns, rows: rows, scrollback: 10_000)
                for start in stride(from: 0, to: bytes.count, by: 1024) {
                    let part = bytes[start..<min(bytes.count, start + 1024)]
                    actual.feed(part); expected.feed(part)
                }
                equivalent(actual, expected, "\(name), \(columns)x\(rows)")
            }
        }
    }

    private func attachCustomImage(to terminal: CmdyTerminal, onRelease: @escaping () -> Void) {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
        let payload = Data(bytesNoCopy: pointer, count: 4096, deallocator: .custom { memory, _ in
            memory.deallocate()
            onRelease()
        })
        terminal.buffer.liveLine(0).images = [LineImage(payload: .png(payload),
            pixelWidth: 1, pixelHeight: 1, col: 0)]
    }

    private func equivalent(_ actual: Run, _ expected: Run, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let a = actual.terminal, b = expected.terminal
        XCTAssertEqual(actual.log.events, expected.log.events, context, file: file, line: line)
        XCTAssertEqual(a.parser.state, b.parser.state, context, file: file, line: line)
        XCTAssertEqual(a.currentAttribute, b.currentAttribute, context, file: file, line: line)
        XCTAssertEqual(a.dirtyRowSpan, b.dirtyRowSpan, context, file: file, line: line)
        XCTAssertEqual([a.lastWrite.row, a.lastWrite.x, a.lastWrite.cols, a.lastWrite.rows],
                       [b.lastWrite.row, b.lastWrite.x, b.lastWrite.cols, b.lastWrite.rows], context, file: file, line: line)
        XCTAssertEqual(a.title, b.title, context, file: file, line: line)
        XCTAssertEqual(a.linkTable, b.linkTable, context, file: file, line: line)
        XCTAssertEqual(a.activeLinkId, b.activeLinkId, context, file: file, line: line)
        XCTAssertEqual([a.isAlternateBuffer, a.autoWrap, a.insertMode, a.marginMode, a.originMode,
                        a.lineFeedMode, a.reverseWraparound, a.cursorHidden, a.applicationCursorKeys,
                        a.bracketedPaste, a.focusReporting, a.reverseVideo, a.cursorBlink, a.synchronizedUpdates],
                       [b.isAlternateBuffer, b.autoWrap, b.insertMode, b.marginMode, b.originMode,
                        b.lineFeedMode, b.reverseWraparound, b.cursorHidden, b.applicationCursorKeys,
                        b.bracketedPaste, b.focusReporting, b.reverseVideo, b.cursorBlink, b.synchronizedUpdates],
                       context, file: file, line: line)
        XCTAssertEqual(a.cursorStyle, b.cursorStyle, context, file: file, line: line)
        XCTAssertEqual(a.mouseMode, b.mouseMode, context, file: file, line: line)
        XCTAssertEqual(a.mouseProtocol, b.mouseProtocol, context, file: file, line: line)
        XCTAssertEqual(a.blocksDroppedLineCheckpoint, b.blocksDroppedLineCheckpoint, context, file: file, line: line)
        XCTAssertEqual(a.blocks.blocks.map { [$0.index, $0.promptRow, $0.commandRow, $0.endRow ?? -1, $0.exitCode ?? -1] },
                       b.blocks.blocks.map { [$0.index, $0.promptRow, $0.commandRow, $0.endRow ?? -1, $0.exitCode ?? -1] },
                       context, file: file, line: line)
        for (first, second) in [(a.normalBuffer, b.normalBuffer), (a.altBuffer, b.altBuffer)] {
            XCTAssertEqual([first.cols, first.rows, first.x, first.y, first.yBase, first.yDisp,
                            first.lineCount, first.droppedLines, first.scrollTop, first.scrollBottom,
                            first.marginLeft, first.marginRight, first.maxScrollback],
                           [second.cols, second.rows, second.x, second.y, second.yBase, second.yDisp,
                            second.lineCount, second.droppedLines, second.scrollTop, second.scrollBottom,
                            second.marginLeft, second.marginRight, second.maxScrollback], context, file: file, line: line)
            XCTAssertEqual(first.wrapPending, second.wrapPending, context, file: file, line: line)
            XCTAssertEqual(first.tabStops, second.tabStops, context, file: file, line: line)
            XCTAssertEqual(first.overflowLines.keys.sorted(), second.overflowLines.keys.sorted(), context, file: file, line: line)
            let pairs = Array(zip(first.lines, second.lines)) + first.overflowLines.compactMap { key, value in
                second.overflowLines[key].map { (value, $0) }
            }
            for (left, right) in pairs {
                XCTAssertEqual(left.cells, right.cells, context, file: file, line: line)
                XCTAssertEqual(left.isWrapped, right.isWrapped, context, file: file, line: line)
                XCTAssertEqual(left.wrapStyle, right.wrapStyle, context, file: file, line: line)
                XCTAssertEqual(left.renderMode, right.renderMode, context, file: file, line: line)
                XCTAssertEqual(left.images?.map { [$0.col, $0.pixelWidth, $0.pixelHeight, $0.kittyZIndex] },
                               right.images?.map { [$0.col, $0.pixelWidth, $0.pixelHeight, $0.kittyZIndex] },
                               context, file: file, line: line)
            }
        }
    }

    private final class Log { var events: [String] = [] }

    private final class Run {
        let terminal: CmdyTerminal
        let owned: Bool
        let log: Log
        let host: Host
        var otherHosts: [Host] = []
        var imageReleases = 0

        init(owned: Bool, columns: Int = 7, rows: Int = 4, scrollback: Int = 7) {
            self.owned = owned
            let eventLog = Log()
            log = eventLog
            terminal = CmdyTerminal(cols: columns, rows: rows, scrollback: scrollback)
            host = Host(name: "first", log: eventLog)
            terminal.delegate = host
        }

        func feed(_ text: String) { feed(Array(text.utf8)[...]) }
        func feed(_ bytes: [UInt8]) { feed(bytes[...]) }
        func feed(_ bytes: ArraySlice<UInt8>) {
            if owned {
                terminal.feed(bytes)
            } else {
                // Exact original CmdyTerminal.feed sequence. Reentrant feeds
                // take this route too, so the reference never uses the new
                // owner overload; no production oracle switch is necessary.
                terminal.recorder?.record(bytes)
                terminal.parser.feed(bytes)
                terminal.synchronizeBlockRowsToScrollback()
                terminal.delegate?.contentChanged(terminal)
            }
        }
    }

    private final class Host: CmdyTerminalDelegate {
        let name: String
        let log: Log
        var onBell: ((CmdyTerminal) -> Void)?
        init(name: String, log: Log) { self.name = name; self.log = log }
        func contentChanged(_ terminal: CmdyTerminal) { log.events.append("\(name):content:\(terminal.parser.state)") }
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) { log.events.append("\(name):send:\(Array(data))") }
        func setTitle(_ terminal: CmdyTerminal, title: String) { log.events.append("\(name):title:\(title)") }
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) { log.events.append("\(name):cwd:\(directory ?? "nil")") }
        func bell(_ terminal: CmdyTerminal) { log.events.append("\(name):bell"); onBell?(terminal) }
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) { log.events.append("\(name):clipboard:\(Array(content))") }
        func willReflow(_ terminal: CmdyTerminal) { log.events.append("\(name):willReflow") }
        func didReflow(_ terminal: CmdyTerminal) { log.events.append("\(name):didReflow") }
    }

    private final class PublicDelegate: VTParserDelegate {
        let name: String
        let log: Log
        var onPrint: ((UnicodeScalar) -> Void)?
        var onCSI: (([Int]) -> Void)?
        init(name: String, log: Log) { self.name = name; self.log = log }
        deinit { log.events.append("\(name):deinit") }
        func parserPrint(_ scalar: UnicodeScalar) { log.events.append("\(name):print:\(scalar.value)"); onPrint?(scalar) }
        func parserExecute(_ byte: UInt8) { log.events.append("\(name):control:\(byte)") }
        func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) {
            log.events.append("\(name):csi:\(final):\(params):\(collect)")
            onCSI?(params)
        }
        func parserESC(final: UInt8, collect: [UInt8]) { log.events.append("\(name):esc:\(final):\(collect)") }
        func parserOSC(code: Int, payload: ArraySlice<UInt8>) { log.events.append("\(name):osc:\(code):\(Array(payload))") }
        func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) { log.events.append("\(name):dcs:\(final):\(params):\(collect)") }
        func parserDCSPut(_ bytes: ArraySlice<UInt8>) { log.events.append("\(name):put:\(Array(bytes))") }
        func parserDCSUnhook() { log.events.append("\(name):unhook") }
        func parserAPC(_ bytes: ArraySlice<UInt8>) { log.events.append("\(name):apc:\(Array(bytes))") }
    }
}
