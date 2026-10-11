import XCTest
@testable import CmdyCore

final class InteriorEmojiBatchTests: XCTestCase {
    func testFirstEmojiStillUsesOnlyTheGenericScalarPath() {
        for prefix in ["", "👩\u{200D}", "❤\u{FE0F}\u{200D}", "🇺\u{200D}"] {
            for first in ["👩", "❤", "🏳", "💻"] {
                let (actual, expected) = pair(columns: 20)
                actual.feed(text: prefix); expected.feed(text: prefix)
                let bytes = Array((first + "αβ").utf8)
                let padded = [UInt8](repeating: 0xFF, count: 5) + bytes + [0xFF]
                let consumed = actual.parserPrintOrdinaryUnicode(
                    padded[5..<(5 + bytes.count)], first: first.unicodeScalars.first!,
                    firstByteCount: first.utf8.count)
                XCTAssertEqual(consumed, first.utf8.count, prefix + first)
                expected.feed(Array(first.utf8))
                equivalent(actual, expected, "first scalar: " + prefix + first)
                actual.feed(bytes[consumed...]); expected.feed(text: "αβ")
                for follower in ["\u{FE0F}", "\u{200D}💻", "\u{301}"] {
                    actual.feed(text: follower); expected.feed(text: follower)
                    equivalent(actual, expected, "after first scalar: " + prefix + first + follower)
                }
            }
        }
        // An ordinary first scalar establishes the independent-base invariant;
        // later emoji bases should be consumed until a real follower arrives.
        let (actual, expected) = pair(columns: 20)
        let text = "α👩❤β"
        let bytes = Array(text.utf8)
        let consumed = actual.parserPrintOrdinaryUnicode(
            bytes[...], first: "α", firstByteCount: "α".utf8.count)
        XCTAssertEqual(consumed, bytes.count)
        expected.feed(bytes)
        equivalent(actual, expected, "independent interior emoji bases")
    }

    func testEveryFollowerByteBoundaryPreservesWideOverwriteAndOwnership() {
        let texts = [
            "α❤\u{FE0F}\u{FE0E}", "α❤\u{FE0E}\u{FE0F}",
            "α👩🏽\u{200D}💻", "α🏳\u{FE0F}\u{200D}🌈",
            "α👩💻\u{FE0F}", "α#\u{FE0F}\u{20E3}", "αβ🇺🇸",
            "α❤\u{301}\u{FE0F}", "α👩\u{200D}\u{200D}💻",
            "α❤\u{E0100}", "α👩\u{E0067}\u{E007F}"
        ]
        for columns in [1, 2, 3, 7, 12, 20] {
            for text in texts {
                let payload = Array(text.utf8)
                let padded = [UInt8](repeating: 0xFF, count: 3) + payload + [0xFF]
                for cut in 0...payload.count {
                    let (actual, expected) = pair(columns: columns)
                    let setup = "界界A\u{301}界界\r\n界B\u{301}界\u{1B}[1;2H\u{1B}[32;45m"
                    actual.feed(text: setup); expected.feed(text: setup)
                    for range in [3..<(3 + cut), (3 + cut)..<(3 + payload.count)] {
                        actual.feed(padded[range]); expected.feed(padded[range])
                        equivalent(actual, expected, "\(columns) columns, cut \(cut), \(text.debugDescription)")
                    }
                    for suffix in ["\u{1B}[1D\u{FE0F}", "\u{1B}[1C\u{FE0E}", "\u{1B}[2b\u{301}Z"] {
                        actual.feed(text: suffix); expected.feed(text: suffix)
                        equivalent(actual, expected, "later ownership: \(text.debugDescription), \(suffix.debugDescription)")
                    }
                }
            }
        }
    }

    func testPhysicalRowAndCapacityBoundariesKeepTheFinalEmojiOwner() {
        for columns in [1, 2, 3, 7, 64, 65, 66, 120, 212] {
            for count in [0, 1, 62, 63, 64, 65, 128, 129] {
                for unit in ["❤", "👩", "β👩❤"] {
                    for start in Set([1, max(1, columns - 1), columns]) {
                        let (actual, expected) = pair(columns: columns)
                        for segment in ["\u{1B}[1;\(start)H", "α" + String(repeating: unit, count: count),
                                        "\u{FE0F}\u{FE0E}\u{200D}💻", "\u{1B}[2b\u{301}Z\r\n"] {
                            actual.feed(text: segment); expected.feed(text: segment)
                            equivalent(actual, expected, "\(columns) columns, start \(start), count \(count), \(unit)")
                        }
                    }
                }
            }
        }
    }

    func testCursorModeReverseIndexAndResizeTransitionsMatchScalarInsertion() {
        let controls = ["", "\u{1B}[1D", "\u{1B}[1C", "\u{1B}[1G", "\u{1B}[1A",
                        "\u{1B}M", "\u{1B}[1L", "\u{1B}[1M", "\u{1B}6", "\u{1B}9",
                        "\u{1B}[2;4r", "\u{1B}[?7l", "\u{1B}[4h", "\u{1B}[?45h",
                        "\u{1B}[?69h\u{1B}[2;6s", "\u{1B}[?1049h"]
        for columns in [2, 7, 17] {
            for control in controls {
                let (actual, expected) = pair(columns: columns)
                let segments = [String(repeating: "界α👩❤\u{FE0F}\r\n", count: 9),
                                "\u{1B}[1;1H" + control, "α👩❤", "\u{FE0F}\u{301}",
                                "\u{1B}[1A\u{1B}[1D", "α❤\u{200D}💻", "\u{FE0E}",
                                "\u{1B}[4l\u{1B}[r\u{1B}[?7h\u{1B}[?69l\u{1B}[?1049l"]
                for segment in segments {
                    actual.feed(text: segment); expected.feed(text: segment)
                    equivalent(actual, expected, "\(columns) columns, control \(control.debugDescription)")
                }
                for width in [columns + 3, max(1, columns - 1), columns] {
                    actual.resize(cols: width, rows: 4); expected.resize(cols: width, rows: 4)
                    for segment in ["α👩❤", "\u{FE0F}\u{200D}💻\u{1B}[2b"] {
                        actual.feed(text: segment); expected.feed(text: segment)
                        equivalent(actual, expected, "resize \(width), control \(control.debugDescription)")
                    }
                }
            }
        }
    }

    func testSnapshotsTokensDamageAndImagesSurviveInteriorEmojiWrites() {
        var newTokens = Set<UInt64>()
        for _ in 0..<2 {
            let (actual, expected) = pair(columns: 20)
            let setup = "界界e\u{301}界界\u{1B}[1;1H\u{1B}]8;;https://example.invalid/\u{1B}\\\u{1B}[32;45m"
            actual.feed(text: setup); expected.feed(text: setup)
            let image = LineImage(payload: .rgba(bytes: [1, 2, 3, 255], width: 1, height: 1),
                                  pixelWidth: 1, pixelHeight: 1, col: 2)
            actual.lineForDiff(absolute: 0)?.images = [image]
            _ = actual.consumeDirtyRows(); _ = expected.consumeDirtyRows()
            let retained = actual.captureTerminalSnapshot(consumeDamage: false)
            let oldCells = detachedCells(retained), oldTokens = retained.lines.map(\.version)
            actual.feed(text: "α👩❤β💻❤"); expected.feed(text: "α👩❤β💻❤")
            XCTAssertEqual(actual.consumeDirtyRows(), 0...0)
            XCTAssertEqual(expected.consumeDirtyRows(), 0...0)
            let fresh = actual.captureTerminalSnapshot(consumeDamage: false)
            XCTAssertNotEqual(fresh.lines[0].version, oldTokens[0])
            XCTAssertTrue(newTokens.insert(fresh.lines[0].version).inserted)
            XCTAssertTrue(actual.lineForDiff(absolute: 0)?.images?.first === image)
            XCTAssertEqual(fresh.lines[0].images.map(\.renderIdentity), [image.renderIdentity])
            let token = fresh.lines[0].version
            _ = actual.captureTerminalSnapshot(consumeDamage: false)
            XCTAssertEqual(actual.lineForDiff(absolute: 0)?.version, token)
            for follower in ["\u{FE0F}", "\u{200D}💻", "\u{301}"] {
                actual.feed(text: follower); expected.feed(text: follower)
                equivalent(actual, expected, "retained snapshot and follower \(follower.debugDescription)")
            }
            XCTAssertEqual(retained.lines.map(\.cells), oldCells)
            XCTAssertEqual(retained.lines.map(\.version), oldTokens)
            XCTAssertEqual(retained.lines[0].images.first?.col, 2)
        }
    }

    func testCustomDelegateReplacementAndControlReentryRemainScalarCallbacks() {
        func exercise(_ batches: Bool) -> [[String]] {
            let parser = VTParser(), first = Recorder(), replacement = Recorder()
            parser.batchesOrdinaryUnicode = batches
            parser.delegate = first
            first.onScalar = { _ in
                parser.delegate = replacement
                parser.feed(Array("\u{1B}[32;".utf8))
            }
            parser.feed(Array("α44m👩❤\u{FE0F}β".utf8))
            var injected = false
            replacement.onScalar = { scalar in
                if scalar == "❤".unicodeScalars.first!.value, !injected {
                    injected = true
                    parser.feed([0xF0, 0x9F])
                }
            }
            parser.feed(Array("❤".utf8) + [0x92, 0xBB] + Array("\u{200D}👩".utf8))
            replacement.onControl = { _ in parser.reset(); parser.feed(Array("\u{1B}[31;".utf8)) }
            parser.feed(Array("α👩".utf8) + [0xE2, 0x07] + Array("44m❤\u{FE0F}".utf8))
            XCTAssertEqual(first.engineHookCalls + replacement.engineHookCalls, 0)
            XCTAssertEqual(first.events, ["scalar:945"])
            return [first.events, replacement.events]
        }
        XCTAssertEqual(exercise(true), exercise(false))
    }

    func testContentCallbackReentrySeesFinalEmojiAndRetainedSnapshots() {
        for continuation in ["\u{FE0F}", "\u{FE0E}", "🏽\u{200D}💻", "\u{200D}💻", "\u{301}"] {
            let (actual, expected) = pair(columns: 20)
            var observers: [Observer] = []
            for terminal in [actual, expected] {
                let observer = Observer()
                var injected = false
                observer.onChange = { terminal in
                    if !injected {
                        injected = true
                        terminal.feed(text: continuation + "\u{1B}[32mα👩❤\u{1B}[6n")
                    }
                }
                terminal.delegate = observer
                observers.append(observer)
                terminal.feed(text: "α💻❤")
            }
            XCTAssertEqual(observers[0].events, observers[1].events, continuation)
            XCTAssertEqual(observers[0].changeCount, 2)
            XCTAssertEqual(observers[0].sendCount, 1)
            equivalent(actual, expected, "callback reentry " + continuation)
        }
    }

    func testAllEightCompleteCorporaAtBothGridsMatchScalarInsertionWhenSupplied() throws {
        guard let directory = ProcessInfo.processInfo.environment["CMDY_INTERIOR_EMOJI_CORPUS_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set CMDY_INTERIOR_EMOJI_CORPUS_DIR to the eight retained corpus files.")
        }
        for name in ["unicode", "styled", "source", "lines", "continuous", "sgr-fallback", "diversity", "collisions"] {
            let payload = [UInt8](try Data(contentsOf: URL(fileURLWithPath: directory)
                .appendingPathComponent(name + ".bin")))
            XCTAssertEqual(payload.count, 3_000_000)
            for (columns, rows) in [(120, 36), (212, 62)] {
                let expected = CmdyTerminal(cols: columns, rows: rows, scrollback: 10_000)
                expected.parser.batchesOrdinaryUnicode = false
                for start in stride(from: 0, to: payload.count, by: 1024) {
                    expected.feed(payload[start..<min(payload.count, start + 1024)])
                }
                // Keep the oracle's accumulated damage for both chunk modes.
                let expectedDirty = expected.consumeDirtyRows()
                for chunk in [1024, 65536] {
                    let actual = CmdyTerminal(cols: columns, rows: rows, scrollback: 10_000)
                    var retained: CoreTerminalSnapshot?
                    var oldCells: [[Cell]] = []
                    var oldTokens: [UInt64] = []
                    for start in stride(from: 0, to: payload.count, by: chunk) {
                        actual.feed(payload[start..<min(payload.count, start + chunk)])
                        if retained == nil, start >= payload.count / 2 {
                            let snapshot = actual.captureTerminalSnapshot(consumeDamage: false)
                            retained = snapshot
                            oldCells = detachedCells(snapshot)
                            oldTokens = snapshot.lines.map(\.version)
                        }
                    }
                    XCTAssertEqual(actual.consumeDirtyRows(), expectedDirty, name)
                    equivalent(actual, expected, "\(name), \(columns)×\(rows), chunk \(chunk)")
                    XCTAssertNotNil(retained)
                    XCTAssertEqual(retained?.lines.map(\.cells), oldCells, name)
                    XCTAssertEqual(retained?.lines.map(\.version), oldTokens, name)
                }
            }
        }
    }

    private func pair(columns: Int) -> (CmdyTerminal, CmdyTerminal) {
        let actual = CmdyTerminal(cols: columns, rows: 4, scrollback: 7)
        let expected = CmdyTerminal(cols: columns, rows: 4, scrollback: 7)
        expected.parser.batchesOrdinaryUnicode = false
        return (actual, expected)
    }

    private func detachedCells(_ snapshot: CoreTerminalSnapshot) -> [[Cell]] {
        snapshot.lines.map { row in
            row.cells.map { cell in
                Cell(scalar: cell.scalar, clusterExtras: cell.clusterExtras.map { $0.map { $0 } },
                     width: cell.width, attribute: cell.attribute, linkId: cell.linkId)
            }
        }
    }

    private func equivalent(_ actual: CmdyTerminal, _ expected: CmdyTerminal, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.bufferLineCount, expected.bufferLineCount, context, file: file, line: line)
        XCTAssertEqual(actual.scrollbackDroppedLines, expected.scrollbackDroppedLines, context, file: file, line: line)
        XCTAssertEqual(actual.scrollInvariantCursorRow, expected.scrollInvariantCursorRow, context, file: file, line: line)
        XCTAssertEqual(actual.cursorColumn, expected.cursorColumn, context, file: file, line: line)
        XCTAssertEqual(actual.isAlternateBuffer, expected.isAlternateBuffer, context, file: file, line: line)
        XCTAssertEqual(actual.currentAttribute, expected.currentAttribute, context, file: file, line: line)
        XCTAssertEqual(actual.buffer.wrapPending, expected.buffer.wrapPending, context, file: file, line: line)
        XCTAssertEqual(actual.lastPrintedScalar, expected.lastPrintedScalar, context, file: file, line: line)
        XCTAssertEqual(actual.consumeDirtyRows(), expected.consumeDirtyRows(), context, file: file, line: line)
        for row in 0..<min(actual.bufferLineCount, expected.bufferLineCount) {
            let a = actual.lineForDiff(absolute: row)!, b = expected.lineForDiff(absolute: row)!
            XCTAssertEqual(a.cells, b.cells, "\(context), row \(row)", file: file, line: line)
            XCTAssertEqual(a.isWrapped, b.isWrapped, context, file: file, line: line)
            XCTAssertEqual(a.wrapStyle, b.wrapStyle, context, file: file, line: line)
            XCTAssertEqual(a.renderMode, b.renderMode, context, file: file, line: line)
        }
    }

    private final class Recorder: VTParserDelegate {
        var events: [String] = []
        var engineHookCalls = 0
        var onScalar: ((UInt32) -> Void)?
        var onControl: ((UInt8) -> Void)?
        func parserPrintOrdinaryUnicode(_ bytes: ArraySlice<UInt8>, first: UnicodeScalar, firstByteCount: Int) -> Int {
            engineHookCalls += 1
            return bytes.count
        }
        func parserPrint(_ scalar: UnicodeScalar) { events.append("scalar:\(scalar.value)"); onScalar?(scalar.value) }
        func parserExecute(_ byte: UInt8) { events.append("control:\(byte)"); onControl?(byte) }
        func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) { events.append("csi:\(final):\(params):\(collect)") }
        func parserESC(final: UInt8, collect: [UInt8]) {}
        func parserOSC(code: Int, payload: ArraySlice<UInt8>) {}
        func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) {}
        func parserDCSPut(_ bytes: ArraySlice<UInt8>) {}
        func parserDCSUnhook() {}
        func parserAPC(_ bytes: ArraySlice<UInt8>) {}
    }

    private final class Observer: CmdyTerminalDelegate {
        var events: [String] = []
        var changeCount = 0
        var sendCount = 0
        var onChange: ((CmdyTerminal) -> Void)?
        func contentChanged(_ terminal: CmdyTerminal) {
            changeCount += 1
            events.append("change:\(terminal.cursorColumn):\(terminal.lineForDiff(absolute: 0)!.cells)")
            onChange?(terminal)
        }
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) { sendCount += 1; events.append("send:\(Array(data))") }
        func setTitle(_ terminal: CmdyTerminal, title: String) {}
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {}
        func bell(_ terminal: CmdyTerminal) {}
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {}
        func willReflow(_ terminal: CmdyTerminal) {}
        func didReflow(_ terminal: CmdyTerminal) {}
    }
}
