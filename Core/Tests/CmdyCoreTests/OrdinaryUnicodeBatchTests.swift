import XCTest
@testable import CmdyCore

final class OrdinaryUnicodeBatchTests: XCTestCase {
    private let mixed = "ASCII 0123456789 | cafe\u{301} | 中文 日本語 한국어 | Ελληνικά | العربية | 👩🏽‍💻 🏳️‍🌈 | ┌─┬─┐ █▄▀\r\n"

    func testMixedScriptsAcrossCutsModesAndFilledScrollback() {
        // Exercise the fixed 64-member buffer and physical right edge before
        // later scrollback could discard evidence of a boundary error.
        for columns in [64, 65, 66, 128, 132] {
            for count in [63, 64, 65, 66, 127, 129, 130] {
                for unit in ["α", "界"] {
                    let (actual, expected) = pair(columns: columns)
                    for text in [String(repeating: unit, count: count), "\u{301}\u{FE0F}Z"] {
                        actual.feed(text: text); expected.feed(text: text)
                        equivalent(actual, expected, "capacity columns \(columns), scalars \(count), \(unit)")
                    }
                }
            }
        }
        let records = String(repeating: mixed, count: 6)
        let text = "\u{1B}[31;44m" + records + "\u{1B}[0m"
            + "\u{1B}[?7l" + mixed + "\u{1B}[?7h"
            + "\u{1B}[4h" + mixed + "\u{1B}[4l"
            + "\u{1B}[?69h\u{1B}[2;6s\u{1B}[?6h" + mixed
            + "\u{1B}[?6l\u{1B}[?69l"
            + "\u{1B}[?1049h" + records + "\u{1B}[2J\u{1B}[H" + mixed
            + "\u{1B}[?1049l" + records
        let payload = [UInt8](repeating: 0x1B, count: 5) + Array(text.utf8) + [0x1B]
        for columns in [1, 2, 3, 7, 17, 120] {
            for chunk in [1, 2, 3, 4, 7, 31, 1024, payload.count] {
                let (actual, expected) = pair(columns: columns)
                for start in stride(from: 5, to: payload.count - 1, by: chunk) {
                    let bytes = payload[start..<min(payload.count - 1, start + chunk)]
                    actual.feed(bytes); expected.feed(bytes)
                }
                equivalent(actual, expected, "columns \(columns), chunk \(chunk)")
            }
        }
    }

    func testBoundariesBeforeFollowersPreserveWideOverwriteAndLastBase() {
        let followers = ["\u{301}", "\u{FE0F}", "\u{FE0E}", "\u{200D}💻", "\u{1F1F8}", "\u{E0100}"]
        let bases = ["αβγ", "中文한", "α7", "α#", "αβ❤", "αβ👩", "αβ🇺"]
        let moves = ["", "\u{1B}[1D", "\u{1B}[1G", "\u{1B}[1A", "\u{1B}[1C"]
        for columns in [1, 2, 3, 6, 9] {
            for base in bases {
                for follower in followers {
                    for move in moves {
                        let (actual, expected) = pair(columns: columns)
                        let setup = "界界界界界\r\nA\u{301}界B\u{301}界\u{1B}[1;2H\u{1B}[32;45m"
                        for text in [setup, base, move, follower, "αβ\u{FE0F}\u{301}Z\r\n"] {
                            let retained = actual.captureTerminalSnapshot(consumeDamage: false)
                            let oldCells = detachedCells(retained)
                            let oldVersions = retained.lines.map(\.version)
                            actual.feed(text: text); expected.feed(text: text)
                            equivalent(actual, expected, "columns \(columns), \(base.debugDescription), \(move.debugDescription), \(follower.debugDescription)")
                            XCTAssertEqual(retained.lines.map(\.cells), oldCells)
                            XCTAssertEqual(retained.lines.map(\.version), oldVersions)
                        }
                    }
                }
            }
        }
    }

    func testReverseIndexMarginsAndOwnerTransitionsMatchScalarPath() {
        let controls = ["\u{1B}M", "\u{1B}[1L", "\u{1B}[1M", "\u{1B}[1T", "\u{1B}[1S",
                        "\u{1B}[2;4r", "\u{1B}[?7l", "\u{1B}[?45h", "\u{1B}[?69h\u{1B}[2;6s"]
        for columns in [2, 7, 17] {
            for control in controls {
                let (actual, expected) = pair(columns: columns)
                for segment in [String(repeating: "αβ界❤\u{FE0F}\r\n", count: 9),
                                "\u{1B}[1;1H" + control,
                                "αβγ中文", "\u{FE0F}\u{301}", "\u{1B}[1A\u{1B}[1D",
                                "αβ\u{200D}💻", "\u{1B}[?1049hαβγ\u{1B}[?1049l\u{FE0E}",
                                "\u{1B}[r\u{1B}[?7h\u{1B}[?69l" + mixed] {
                    actual.feed(text: segment); expected.feed(text: segment)
                    equivalent(actual, expected, "columns \(columns), control \(control.debugDescription)")
                }
            }
        }
    }

    func testMalformedControlAndPartialSequencesRetainByteBoundaries() {
        let prefix = Array("αβγ 中文 ".utf8)
        let suffix = Array("\u{1B}[0mαβ\u{301}\u{FE0F}\u{200D}界Z\r\n".utf8)
        for byte in UInt8.min...UInt8.max {
            let payload = [UInt8](repeating: 0x1B, count: 3) + prefix
                + [byte, 0xE2, 0x07, 0x82, 0xAC, 0xED, 0xA0, 0x80] + suffix + [0x1B]
            for chunk in [1, 2, 3, 4, 7, payload.count] {
                let (actual, expected) = pair(columns: 17)
                for start in stride(from: 3, to: payload.count - 1, by: chunk) {
                    let part = payload[start..<min(payload.count - 1, start + chunk)]
                    actual.feed(part); expected.feed(part)
                }
                equivalent(actual, expected, "byte \(byte), chunk \(chunk)")
            }
        }
    }

    func testCustomDelegateReplacementAndReentryCannotUseEngineHook() {
        for batches in [false, true] {
            let parser = VTParser()
            parser.batchesOrdinaryUnicode = batches
            let first = Recorder(), replacement = Recorder()
            parser.delegate = first
            first.onScalar = { _ in
                parser.delegate = replacement
                parser.feed([0x1B, 0x5B, 0x33])
            }
            parser.feed(Array("€1mαβ".utf8))
            XCTAssertEqual(first.events, ["scalar:8364"])
            XCTAssertEqual(replacement.events, ["csi:109:[31]:[]", "scalar:945", "scalar:946"])
            XCTAssertEqual(first.engineHookCalls + replacement.engineHookCalls, 0)

            replacement.events = []
            replacement.onScalar = { scalar in
                if scalar == 945 { parser.feed([0xF0, 0x9F]) }
            }
            parser.feed(Array("α".utf8) + [0x9A, 0x80])
            XCTAssertEqual(replacement.events, ["scalar:945", "scalar:128640"])
            replacement.onScalar = nil
            replacement.onControl = { _ in parser.reset() }
            replacement.events = []
            parser.feed([0xE2, 0x07, 0x82, 0xAC])
            XCTAssertEqual(replacement.events, ["control:7", "scalar:172"])
            XCTAssertEqual(replacement.engineHookCalls, 0)
        }
    }

    func testBatchMutationPublishesUniqueTokensAndPreservesRetainedCells() {
        let first = CmdyTerminal(cols: 20, rows: 3, scrollback: 4)
        let second = CmdyTerminal(cols: 20, rows: 3, scrollback: 4)
        var versions = Set<UInt64>()
        for terminal in [first, second] {
            terminal.feed(text: "界界e\u{301}界界\u{1B}[1;1H")
            let image = LineImage(payload: .rgba(bytes: [1, 2, 3, 255], width: 1, height: 1),
                                  pixelWidth: 1, pixelHeight: 1, col: 2)
            terminal.lineForDiff(absolute: 0)?.images = [image]
            _ = terminal.consumeDirtyRows()
            let retained = terminal.captureTerminalSnapshot(consumeDamage: false)
            let cells = detachedCells(retained)
            let tokens = retained.lines.map(\.version)
            terminal.feed(text: "αβ中文γδ")
            XCTAssertEqual(terminal.consumeDirtyRows(), 0...0)
            let fresh = terminal.captureTerminalSnapshot(consumeDamage: false)
            XCTAssertNotEqual(fresh.lines[0].version, retained.lines[0].version)
            XCTAssertTrue(versions.insert(fresh.lines[0].version).inserted)
            XCTAssertEqual(retained.lines.map(\.cells), cells)
            XCTAssertEqual(retained.lines.map(\.version), tokens)
            XCTAssertTrue(terminal.lineForDiff(absolute: 0)?.images?.first === image)
            XCTAssertEqual(fresh.lines[0].images.map(\.renderIdentity), [image.renderIdentity])
            XCTAssertEqual(retained.lines[0].images.first?.col, 2)
            let token = fresh.lines[0].version
            _ = terminal.captureTerminalSnapshot(consumeDamage: false)
            XCTAssertEqual(terminal.lineForDiff(absolute: 0)?.version, token)
        }
        let (actual, expected) = pair(columns: 20)
        for text in ["界界e\u{301}界界\u{1B}[1;1H", "αβ中文γδ", "\u{FE0F}\u{301}\u{1B}[1D\u{FE0E}"] {
            actual.feed(text: text); expected.feed(text: text)
            equivalent(actual, expected, text.debugDescription)
        }
    }

    func testContentCallbackReentryObservesCompletedRunAndLastCluster() {
        let (actual, expected) = pair(columns: 20)
        var observers: [Observer] = []
        for terminal in [actual, expected] {
            let observer = Observer()
            var reentered = false
            observer.onChange = { terminal in
                if !reentered {
                    reentered = true
                    terminal.feed(text: "\u{301}\u{1B}[32mλμ\u{1B}[6n")
                }
            }
            observers.append(observer)
            terminal.delegate = observer
            terminal.feed(text: "αβ中文γδ")
        }
        XCTAssertEqual(observers[0].events, observers[1].events)
        XCTAssertEqual(observers[0].changeCount, 2)
        XCTAssertEqual(observers[0].sendCount, 1)
        equivalent(actual, expected, "content callback reentry")
    }

    #if CMDY_UNICODE_BATCH_DIAGNOSTICS
    func testActualUnicodeCorpusBatchLengthsAndFullRetainedContent() throws {
        guard let path = ProcessInfo.processInfo.environment["CMDY_UNICODE_BATCH_CORPUS"],
              !path.isEmpty else {
            throw XCTSkip("Set CMDY_UNICODE_BATCH_CORPUS to the retained Unicode corpus file.")
        }
        let payload = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(payload.count, 3_000_000)
        let scalarCount = String(decoding: payload, as: UTF8.self).unicodeScalars.count
        for (columns, rows) in [(120, 36), (212, 62)] {
            let actual = CmdyTerminal(cols: columns, rows: rows, scrollback: 10_000)
            let expected = CmdyTerminal(cols: columns, rows: rows, scrollback: 10_000)
            expected.parser.batchesOrdinaryUnicode = false
            for start in stride(from: 0, to: payload.count, by: 1024) {
                let bytes = payload[start..<min(payload.count, start + 1024)]
                actual.feed(bytes); expected.feed(bytes)
            }
            equivalent(actual, expected, "full corpus \(columns)×\(rows)")
            let lengths = actual.ordinaryUnicodeBatchLengths
            XCTAssertFalse(lengths.isEmpty)
            var histogram: [String: Int] = [:]
            for length in lengths { histogram[String(length), default: 0] += 1 }
            let value: [String: Any] = ["columns": columns, "rows": rows,
                "payloadBytes": payload.count, "payloadScalars": scalarCount,
                "chunkBytes": 1024, "batchCount": lengths.count,
                "additionalScalarsBatched": lengths.reduce(0, +),
                "maxAdditionalScalarsPerBatch": lengths.max()!, "histogram": histogram,
                "includesFirstScalarInBatchLength": false]
            let json = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            print("UNICODE_BATCH_DIAGNOSTIC " + String(decoding: json, as: UTF8.self))
        }
    }
    #endif

    private func pair(columns: Int) -> (CmdyTerminal, CmdyTerminal) {
        let actual = CmdyTerminal(cols: columns, rows: 4, scrollback: 7)
        let expected = CmdyTerminal(cols: columns, rows: 4, scrollback: 7)
        expected.parser.batchesOrdinaryUnicode = false
        return (actual, expected)
    }

    private func detachedCells(_ snapshot: CoreTerminalSnapshot) -> [[Cell]] {
        // Build independent storage, including extras. Retaining a second
        // reference to the same COW array would not catch unsafe alias writes.
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
        // A same-named custom method must never opt a replacement delegate in.
        func parserPrintOrdinaryUnicode(_ bytes: ArraySlice<UInt8>, first: UnicodeScalar,
                                        firstByteCount: Int) -> Int {
            engineHookCalls += 1
            return bytes.count
        }
        func parserPrint(_ scalar: UnicodeScalar) {
            events.append("scalar:\(scalar.value)"); onScalar?(scalar.value)
        }
        func parserExecute(_ byte: UInt8) { events.append("control:\(byte)"); onControl?(byte) }
        func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) {
            events.append("csi:\(final):\(params):\(collect)")
        }
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
            events.append("change:\(terminal.cursorColumn):\(terminal.currentAttribute):\(terminal.lineForDiff(absolute: 0)!.cells)")
            onChange?(terminal)
        }
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) {
            sendCount += 1
            events.append("send:\(Array(data))")
        }
        func setTitle(_ terminal: CmdyTerminal, title: String) {}
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {}
        func bell(_ terminal: CmdyTerminal) {}
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {}
        func willReflow(_ terminal: CmdyTerminal) {}
        func didReflow(_ terminal: CmdyTerminal) {}
    }
}
