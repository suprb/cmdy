import XCTest
@testable import CmdyCore

final class ASCIIBulkBoundaryTests: XCTestCase {
    func testASCIIRowAttributesPreserveAllFieldsAndRetainedNeighbors() {
        let colors: [CellColor] = [.defaultColor, .defaultInverted,
                                  .ansi256(0), .ansi256(255),
                                  .trueColor(0, 255, 17), .trueColor(255, 0, 239)]
        let underlines: [UnderlineKind] = [.none, .single, .double, .curly, .dotted, .dashed]
        let bytes: [UInt8] = [0, 0, 0, 0x20, 0x21, 0x3F, 0x41, 0x5A, 0x61, 0x7E, 0]
        for rawStyle: UInt8 in [0, 1, 2, 4, 8, 16, 32, 64, 128, 255] {
            for (colorIndex, color) in colors.enumerated() {
                for underline in underlines {
                    let attribute = CellAttribute(
                        fg: color, bg: colors[(colorIndex + 1) % colors.count],
                        style: CellStyle(rawValue: rawStyle), underlineKind: underline,
                        underlineColor: rawStyle & 1 == 0 ? nil : colors[(colorIndex + 2) % colors.count])
                    for deferred in [false, true] {
                        for extras: [UInt32]? in [nil, [0x301, 0x200D]] {
                            let seed = (0..<11).map {
                                Cell(scalar: UInt32(0x4E00 + $0), clusterExtras: extras,
                                     width: 2, attribute: .empty, linkId: 7)
                            }
                            let line = Line(cells: seed, isWrapped: true)
                            let retained = line.cells
                            if deferred {
                                line.resetDeferred(fill: Cell.blank(attribute: .empty), isWrapped: true)
                            }
                            var expected = (0..<line.count).map { line[$0] }
                            for (offset, byte) in bytes[3..<10].enumerated() {
                                expected[2 + offset] = Cell(scalar: UInt32(byte), width: 1,
                                                            attribute: attribute, linkId: .max)
                            }
                            let version = line.version
                            line.writeASCII(bytes[3..<10], at: 2, attribute: attribute, linkId: .max)
                            XCTAssertEqual(line.cells, expected)
                            XCTAssertEqual(retained, seed)
                            XCTAssertTrue(line.isWrapped)
                            XCTAssertGreaterThan(line.version, version)
                        }
                    }
                }
            }
        }
    }

    func testEveryByteAtBulkWordBoundariesMatchesScalarCallbacks() {
        for byte in UInt8.min...UInt8.max {
            for lane in 0..<16 {
                let padding = lane % 8 + 1
                let prefix = [UInt8](repeating: 65, count: lane)
                let suffix = Array("tail\r\nnext line\r\nlast line\r\n".utf8) + [0x18]
                let storage = [UInt8](repeating: 0, count: padding) + prefix + [byte] + suffix + [0]
                let payload = storage[padding..<(storage.count - 1)]
                XCTAssertEqual(events(payload, coalesced: true), events(payload, coalesced: false),
                               "byte \(byte), lane \(lane), slice offset \(padding)")
            }
        }
    }

    func testShortAndUnalignedASCIITailsStayInsideSlice() {
        for padding in 0..<8 {
            for length in 0..<33 {
                let storage = [UInt8](repeating: 0, count: padding)
                    + [UInt8](repeating: 126, count: length) + [0x1B, 0x5B, 0x63]
                let payload = storage[padding..<(padding + length)]
                XCTAssertEqual(events(payload, coalesced: true), events(payload, coalesced: false))
                XCTAssertEqual(events(payload, coalesced: true).count, length)
            }
        }
    }

    func testMixedCRLFLengthsAndChunkCutsMatchScalarTerminal() {
        let lengths = [1, 7, 8, 9, 16, 17, 18, 76, 120, 121]
        let records = lengths.map { String(repeating: "A", count: $0) + "\r\n" }.joined()
        let text = "prefix\r\n\u{1B}[31;44m" + records + "\r\n\u{1B}[0m"
            + "e\u{301} 界 😀\r\n" + records
            + "\u{1B}[?7l" + records + "\u{1B}[?7h"
        let storage = [UInt8](repeating: 0, count: 3) + Array(text.utf8) + [0]
        let payload = storage[3..<(storage.count - 1)]
        for columns in [1, 17, 120] {
            let scalar = CmdyTerminal(cols: columns, rows: 4, scrollback: 7)
            scalar.parser.coalescesPrintableASCII = false
            scalar.feed(payload)
            for chunk in [1, 7, 8, 9, 77, 1024, payload.count] {
                let terminal = CmdyTerminal(cols: columns, rows: 4, scrollback: 7)
                for offset in stride(from: payload.startIndex, to: payload.endIndex, by: chunk) {
                    terminal.feed(payload[offset..<min(payload.endIndex, offset + chunk)])
                }
                XCTAssertEqual(terminal.bufferLineCount, scalar.bufferLineCount)
                XCTAssertEqual(terminal.scrollbackDroppedLines, scalar.scrollbackDroppedLines)
                XCTAssertEqual(terminal.scrollInvariantCursorRow, scalar.scrollInvariantCursorRow)
                XCTAssertEqual(terminal.cursorColumn, scalar.cursorColumn)
                XCTAssertEqual(terminal.currentAttribute, scalar.currentAttribute)
                for row in 0..<terminal.bufferLineCount {
                    let actual = terminal.lineForDiff(absolute: row)!
                    let expected = scalar.lineForDiff(absolute: row)!
                    XCTAssertEqual(actual.cells, expected.cells, "cols \(columns), chunk \(chunk), row \(row)")
                    XCTAssertEqual(actual.isWrapped, expected.isWrapped)
                }
            }
        }
    }

    private func events(_ bytes: ArraySlice<UInt8>, coalesced: Bool) -> [String] {
        let parser = VTParser()
        let recorder = EventRecorder()
        parser.delegate = recorder
        parser.coalescesPrintableASCII = coalesced
        parser.feed(bytes)
        return recorder.events
    }

    private final class EventRecorder: VTParserDelegate {
        var events: [String] = []
        func parserPrint(_ scalar: UnicodeScalar) { events.append("print:\(scalar.value)") }
        func parserExecute(_ byte: UInt8) { events.append("control:\(byte)") }
        func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) {
            events.append("csi:\(final):\(params):\(collect)")
        }
        func parserESC(final: UInt8, collect: [UInt8]) { events.append("esc:\(final):\(collect)") }
        func parserOSC(code: Int, payload: ArraySlice<UInt8>) { events.append("osc:\(code):\(Array(payload))") }
        func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) {
            events.append("dcs:\(final):\(params):\(collect)")
        }
        func parserDCSPut(_ bytes: ArraySlice<UInt8>) { events.append("dcs-data:\(Array(bytes))") }
        func parserDCSUnhook() { events.append("dcs-end") }
        func parserAPC(_ bytes: ArraySlice<UInt8>) { events.append("apc:\(Array(bytes))") }
    }
}
