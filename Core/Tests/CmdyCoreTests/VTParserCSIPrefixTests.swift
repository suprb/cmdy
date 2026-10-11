import XCTest
@testable import CmdyCore

final class VTParserCSIPrefixTests: XCTestCase {
    func testLongDigitRunsPublishParametersBeforeEveryInterruption() {
        let digits = Array(String(repeating: "1234567890", count: 30).utf8)
        for prefix in ["\u{1B}[?", "\u{1B}[4:", "\u{1B}[1;"] {
            for byte in UInt8.min...UInt8.max {
                let payload = Array(prefix.utf8) + digits + [byte] + digits
                    + Array(";31mtext\u{1B}[6n".utf8)
                let expected = run(payload, fast: false)
                for chunk in [1, 2, 31, 256, payload.count] {
                    let actual = run(payload, fast: true, chunk: chunk)
                    XCTAssertEqual(actual.events, expected.events, "\(prefix.debugDescription), byte \(byte), chunk \(chunk)")
                    XCTAssertEqual(actual.state, expected.state)
                }
            }
        }
    }

    func testSimpleSequencesHaveExactParametersAndOneCallback() {
        let cases: [(String, [Int])] = [
            ("", [0]), ("0", [0]), (";", [0, 0]),
            (";5;;", [0, 5, 0, 0]), ("00001;000032", [1, 32]),
            ("38;2;10;20;30;48;5;255", [38, 2, 10, 20, 30, 48, 5, 255]),
            ("99999999999999999999999999999999999", [65535]),
            (Array(repeating: "1", count: 32).joined(separator: ";"), Array(repeating: 1, count: 32))
        ]
        for (body, values) in cases {
            let parser = VTParser(), capture = Capture()
            parser.delegate = capture
            parser.feed(Array(("\u{1B}[" + body + "m").utf8))
            XCTAssertEqual(capture.events, [Capture.csi(0x6D, values, [])], body)
            XCTAssertEqual(parser.state, .ground)
        }
    }

    func testEverySplitAndNonzeroSliceMatchesByteMachine() {
        let sequences = [
            "\u{1B}[m", "\u{1B}[;31;;1;38;2;10;20;30m",
            "\u{1B}[4:3;38:2::1:2:3m", "\u{1B}[?1m", "\u{1B}[4 m",
            "\u{1B}[" + String(repeating: "9", count: 260) + "m",
            "\u{1B}[" + Array(repeating: "1", count: 257).joined(separator: ";") + "m",
            "\u{1B}[" + String(repeating: ";", count: 260) + "7m"
        ]
        for sequence in sequences {
            let payload = Array(("before" + sequence + "after\u{1B}[6n").utf8)
            let expected = run(payload, fast: false).events
            let storage = [UInt8](repeating: 0xFF, count: 7) + payload + [0xFF]
            for cut in 0...payload.count {
                let parser = VTParser(), capture = Capture()
                parser.delegate = capture
                parser.feed(storage[7..<(7 + cut)])
                parser.feed(storage[(7 + cut)..<(7 + payload.count)])
                XCTAssertEqual(capture.events, expected, "length \(payload.count), cut \(cut)")
                XCTAssertEqual(parser.state, .ground)
            }
        }
    }

    func testUnexpectedBytesAndPartialStatesRemainOnByteOracle() {
        for byte in UInt8.min...UInt8.max {
            let fragments: [[UInt8]] = [
                [0x1B, 0x5B, byte, 0x33, 0x31, 0x6D],
                [0x1B, 0x5B, 0x33, 0x31, byte, 0x3B, 0x31, 0x6D],
                [0xE2, byte, 0x1B, 0x5B, 0x33, 0x32, 0x6D],
                [0x1B, 0x5B, 0x33, 0x31, 0x6D, byte]
            ]
            for fragment in fragments {
                let payload = fragment + [0x1B, 0x5B, 0x30, 0x6D, 0x58]
                let expected = run(payload, fast: false)
                for chunk in [1, 2, 3, 7, payload.count] {
                    let actual = run(payload, fast: true, chunk: chunk)
                    XCTAssertEqual(actual.events, expected.events, "byte \(byte), chunk \(chunk)")
                    XCTAssertEqual(actual.state, expected.state)
                }
            }
        }
    }

    func testBoundedLookaheadDoesNotChangeLongOrOverflowingParameters() {
        for length in [31, 32, 33, 255, 256, 257, 1024] {
            for body in [String(repeating: "9", count: length),
                         String(repeating: ";", count: length),
                         Array(repeating: "1", count: length).joined(separator: ";")] {
                let payload = Array(("\u{1B}[" + body + "m!").utf8)
                XCTAssertEqual(run(payload, fast: true).events,
                               run(payload, fast: false).events)
            }
        }
    }

    func testCallbacksCanResetAndEstablishPartialState() {
        let continuations: [([UInt8], [UInt8])] = [
            ([0x1B, 0x5B, 0x33, 0x32, 0x3B], [0x34, 0x34, 0x6D]),
            ([0xE2], [0x82, 0xAC]),
            (Array("\u{1B}]0;title".utf8), [0x07]),
            ([0x1B, 0x50, 0x31, 0x71, 0x61], [0x62, 0x1B, 0x5C])
        ]
        for (inside, outside) in continuations {
            func exercise(_ fast: Bool) -> [String] {
                let parser = VTParser(), capture = Capture()
                parser.coalescesCSIParameters = fast
                parser.delegate = capture
                var called = false
                capture.onCSI = {
                    XCTAssertEqual(parser.state, .ground)
                    if !called {
                        called = true
                        parser.reset()
                        parser.feed(inside)
                    }
                }
                parser.feed([0x1B, 0x5B, 0x33, 0x31, 0x6D] + outside + [0x21])
                return capture.events
            }
            XCTAssertEqual(exercise(true), exercise(false))
        }
    }

    func testReplacementDelegateAndRetainedParametersSurviveCallbackReentry() {
        func exercise(_ fast: Bool) -> [[String]] {
            let parser = VTParser(), first = Capture(), second = Capture()
            parser.coalescesCSIParameters = fast
            parser.delegate = first
            var retained: [[Int]] = []
            first.onParameters = { parameters in
                retained.append(parameters)
                parser.delegate = second
                parser.feed(Array("\u{1B}[32;44mR\u{1B}[".utf8))
            }
            second.onParameters = { retained.append($0) }
            parser.feed(Array("\u{1B}[31;1m0mZ\u{1B}[38;2;1;2;3m".utf8))
            XCTAssertEqual(retained, [[31, 1], [32, 44], [0], [38, 2, 1, 2, 3]])
            return [first.events, second.events]
        }
        XCTAssertEqual(exercise(true), exercise(false))
    }

    func testAbsentDelegateStillPublishesIdenticalState() {
        for fast in [false, true] {
            let parser = VTParser(), capture = Capture()
            parser.coalescesCSIParameters = fast
            parser.feed(Array("\u{1B}[31;1m".utf8))
            XCTAssertEqual(parser.state, .ground)
            parser.delegate = capture
            parser.feed(Array("X\u{1B}[m".utf8))
            XCTAssertEqual(capture.events, ["print:88", Capture.csi(0x6D, [0], [])])
        }
    }

    func testEveryFinalAndPartialPrefixPublishesTheByteMachineState() {
        for final in UInt8(0x40)...UInt8(0x7E) {
            for body in ["", ";31;;", String(repeating: "9", count: 260),
                         String(repeating: ";1", count: 34)] {
                let bytes = [0x1B, 0x5B] + Array(body.utf8)
                for cut in 0...bytes.count {
                    let actual = VTParser(), expected = VTParser()
                    expected.coalescesCSIParameters = false
                    let a = Capture(), b = Capture()
                    actual.delegate = a; expected.delegate = b
                    actual.feed(bytes[..<cut]); expected.feed(bytes[..<cut])
                    XCTAssertEqual(actual.state, expected.state)
                    XCTAssertEqual(a.events, b.events)
                    actual.feed(bytes[cut...]); expected.feed(bytes[cut...])
                    XCTAssertEqual(actual.state, expected.state)
                    for parser in [actual, expected] { parser.feed([0x3B, 0x32, final, 0x21]) }
                    XCTAssertEqual(a.events, b.events)
                    XCTAssertEqual(actual.state, expected.state)
                }
            }
        }
    }

    func testControlCallbacksObserveThePrefixAndMayReplaceState() {
        for control in UInt8(0)...UInt8(0x1F) where control != 0x1B {
            func exercise(_ fast: Bool) -> [String] {
                let parser = VTParser(), capture = Capture()
                parser.coalescesCSIParameters = fast
                parser.delegate = capture
                var seen = false
                capture.onControl = {
                    capture.events.append("state:\(parser.state)")
                    if !seen {
                        seen = true
                        parser.reset()
                        parser.feed(Array("\u{1B}[36;".utf8))
                    }
                }
                parser.feed(Array("\u{1B}[31;".utf8) + [control] + Array("32mX".utf8))
                return capture.events
            }
            XCTAssertEqual(exercise(true), exercise(false), "control \(control)")
        }
    }

    func testCompleteRetainedCorporaMatchTheByteParserWhenSupplied() throws {
        guard let directory = ProcessInfo.processInfo.environment["CMDY_CSI_PREFIX_CORPUS_DIR"] else {
            throw XCTSkip("Set CMDY_CSI_PREFIX_CORPUS_DIR to the six retained corpus files.")
        }
        for name in ["unicode", "styled", "source", "lines", "continuous", "sgr-fallback"] {
            let payload = [UInt8](try Data(contentsOf: URL(fileURLWithPath: directory)
                .appendingPathComponent(name + ".bin")))
            XCTAssertEqual(payload.count, 3_000_000)
            for (columns, rows) in [(120, 36), (212, 62)] {
                let actual = CmdyTerminal(cols: columns, rows: rows, scrollback: 10_000)
                let expected = CmdyTerminal(cols: columns, rows: rows, scrollback: 10_000)
                expected.parser.coalescesCSIParameters = false
                for start in stride(from: 0, to: payload.count, by: 1024) {
                    let part = payload[start..<min(payload.count, start + 1024)]
                    actual.feed(part); expected.feed(part)
                }
                XCTAssertEqual(actual.currentAttribute, expected.currentAttribute, name)
                XCTAssertEqual(actual.cursorColumn, expected.cursorColumn, name)
                XCTAssertEqual(actual.scrollInvariantCursorRow, expected.scrollInvariantCursorRow, name)
                XCTAssertEqual(actual.bufferLineCount, expected.bufferLineCount, name)
                XCTAssertEqual(actual.scrollbackDroppedLines, expected.scrollbackDroppedLines, name)
                XCTAssertEqual(actual.consumeDirtyRows(), expected.consumeDirtyRows(), name)
                XCTAssertEqual(actual.buffer.wrapPending, expected.buffer.wrapPending, name)
                for row in 0..<min(actual.bufferLineCount, expected.bufferLineCount) {
                    let a = actual.lineForDiff(absolute: row)!, b = expected.lineForDiff(absolute: row)!
                    XCTAssertEqual(a.cells, b.cells, "\(name) row \(row)")
                    XCTAssertEqual(a.isWrapped, b.isWrapped, name)
                    XCTAssertEqual(a.wrapStyle, b.wrapStyle, name)
                    XCTAssertEqual(a.renderMode, b.renderMode, name)
                }
            }
        }
    }

    private func run(_ bytes: [UInt8], fast: Bool, chunk: Int? = nil) -> (events: [String], state: VTParser.State) {
        let parser = VTParser(), capture = Capture()
        parser.coalescesCSIParameters = fast
        parser.delegate = capture
        let count = chunk ?? max(1, bytes.count)
        for start in stride(from: 0, to: bytes.count, by: count) {
            parser.feed(bytes[start..<min(bytes.count, start + count)])
        }
        return (capture.events, parser.state)
    }

    private final class Capture: VTParserDelegate {
        var events: [String] = []
        var onCSI: (() -> Void)?
        var onControl: (() -> Void)?
        var onParameters: (([Int]) -> Void)?
        static func csi(_ final: UInt8, _ params: [Int], _ collect: [UInt8]) -> String {
            "csi:\(final):\(params):\(collect)"
        }
        func parserPrint(_ scalar: UnicodeScalar) { events.append("print:\(scalar.value)") }
        func parserExecute(_ byte: UInt8) { events.append("control:\(byte)"); onControl?() }
        func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) {
            events.append(Self.csi(final, params, collect)); onParameters?(params); onCSI?()
        }
        func parserESC(final: UInt8, collect: [UInt8]) { events.append("esc:\(final):\(collect)") }
        func parserOSC(code: Int, payload: ArraySlice<UInt8>) { events.append("osc:\(code):\(Array(payload))") }
        func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) { events.append("hook:\(final):\(params):\(collect)") }
        func parserDCSPut(_ bytes: ArraySlice<UInt8>) { events.append("put:\(Array(bytes))") }
        func parserDCSUnhook() { events.append("unhook") }
        func parserAPC(_ bytes: ArraySlice<UInt8>) { events.append("apc:\(Array(bytes))") }
    }
}
