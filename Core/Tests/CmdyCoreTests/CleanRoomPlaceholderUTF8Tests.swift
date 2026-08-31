import XCTest
@testable import CmdyCore

final class CleanRoomPlaceholderUTF8Tests: XCTestCase {
    func testPlaceholderUsesOfficialDiacriticBoundaryAndRejectsOversizedIndex() {
        var decoder = KittyUnicodePlaceholderDecoder()
        let attribute = CellAttribute(fg: .trueColor(1, 2, 3))
        let maximum = Cell(
            scalar: 0x10EEEE,
            clusterExtras: [0xA8E5, 0x0305, 0x0305],
            attribute: attribute)
        XCTAssertEqual(
            decoder.decode(maximum, absoluteRow: 2, column: 3)?.placeholderRow,
            255)

        let oversized = Cell(
            scalar: 0x10EEEE,
            clusterExtras: [0xA8E6],
            attribute: attribute)
        XCTAssertNil(decoder.decode(oversized, absoluteRow: 2, column: 4))
    }

    func testPlaceholderEncodesColorsAndRequiresNonzeroImageID() {
        var decoder = KittyUnicodePlaceholderDecoder()
        let attribute = CellAttribute(
            fg: .trueColor(1, 2, 3),
            underlineColor: .ansi256(42))
        let cell = Cell(
            scalar: 0x10EEEE,
            clusterExtras: [0x0305, 0x030D, 0x030E],
            attribute: attribute)
        let decoded = decoder.decode(cell, absoluteRow: 7, column: 8)
        XCTAssertEqual(decoded?.imageId, 0x02010203)
        XCTAssertEqual(decoded?.placementId, 42)

        let zero = Cell(
            scalar: 0x10EEEE,
            clusterExtras: [0x0305],
            attribute: CellAttribute(fg: .ansi256(0)))
        XCTAssertNil(decoder.decode(zero, absoluteRow: 7, column: 9))
    }

    func testPlaceholderInheritanceRequiresPhysicalAdjacencyAndMatchingColors() {
        let attribute = CellAttribute(fg: .ansi256(42))
        let first = Cell(
            scalar: 0x10EEEE,
            clusterExtras: [0x030D],
            attribute: attribute)
        let omitted = Cell(scalar: 0x10EEEE, attribute: attribute)

        var decoder = KittyUnicodePlaceholderDecoder()
        XCTAssertEqual(
            decoder.decode(first, absoluteRow: 4, column: 2)?.placeholderCol,
            0)
        let inherited = decoder.decode(omitted, absoluteRow: 4, column: 3)
        XCTAssertEqual(inherited?.placeholderRow, 1)
        XCTAssertEqual(inherited?.placeholderCol, 1)

        XCTAssertNil(decoder.decode(omitted, absoluteRow: 4, column: 5))
        XCTAssertNil(decoder.decode(omitted, absoluteRow: 4, column: 6),
                     "an invalid cell must clear inheritance state")

        decoder.reset()
        _ = decoder.decode(first, absoluteRow: 4, column: 2)
        let changedColor = Cell(
            scalar: 0x10EEEE,
            attribute: CellAttribute(fg: .ansi256(43)))
        XCTAssertNil(decoder.decode(changedColor, absoluteRow: 4, column: 3))
    }

    func testPlaceholderRejectsWrongScalarUnknownAndExcessMarksAndClearsState() {
        let attribute = CellAttribute(fg: .ansi256(9))
        let valid = Cell(
            scalar: 0x10EEEE,
            clusterExtras: [0x0305],
            attribute: attribute)
        let omitted = Cell(scalar: 0x10EEEE, attribute: attribute)
        var decoder = KittyUnicodePlaceholderDecoder()
        XCTAssertNotNil(decoder.decode(valid, absoluteRow: 1, column: 0))

        XCTAssertNil(decoder.decode(
            Cell(scalar: 0x41, attribute: attribute),
            absoluteRow: 1, column: 1))
        XCTAssertNil(decoder.decode(omitted, absoluteRow: 1, column: 2))

        XCTAssertNil(decoder.decode(
            Cell(scalar: 0x10EEEE, clusterExtras: [0x0300], attribute: attribute),
            absoluteRow: 1, column: 3))
        XCTAssertNil(decoder.decode(
            Cell(scalar: 0x10EEEE,
                 clusterExtras: [0x0305, 0x030D, 0x030E, 0x0310],
                 attribute: attribute),
            absoluteRow: 1, column: 4))
    }

    func testUTF8DecoderEmitsValidTwoThreeAndFourByteScalars() {
        let (parser, probe) = makeParser()
        parser.feed([0xC2, 0xA2, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x9A, 0x80])
        XCTAssertEqual(probe.scalars, [0x00A2, 0x20AC, 0x1F680])
    }

    func testMalformedUTF8EmitsLatin1LeadAndDropsTail() {
        let cases: [([UInt8], UInt32)] = [
            ([0xE2, 0x28, 0xA1], UInt32(0xE2)),
            ([0xE0, 0x80, 0x80], UInt32(0xE0)),
            ([0xED, 0xA0, 0x80], UInt32(0xED)),
            ([0xF4, 0x90, 0x80, 0x80], UInt32(0xF4)),
        ]
        for (bytes, expected) in cases {
            let (parser, probe) = makeParser()
            parser.feed(bytes)
            XCTAssertEqual(probe.scalars, [expected], "bytes=\(bytes)")
        }
    }

    func testUTF8PendingStateIsClearBeforeDelegateReentrancy() {
        let parser = VTParser()
        let probe = ParserProbe()
        parser.delegate = probe
        probe.onScalar = { value in
            if value == 0x20AC {
                parser.feed([0xC2, 0xA2])
            }
        }
        parser.feed([0xE2, 0x82, 0xAC])
        XCTAssertEqual(probe.scalars, [0x20AC, 0x00A2])
    }

    private func makeParser() -> (VTParser, ParserProbe) {
        let parser = VTParser()
        let probe = ParserProbe()
        parser.delegate = probe
        return (parser, probe)
    }
}

private final class ParserProbe: VTParserDelegate {
    var scalars: [UInt32] = []
    var onScalar: ((UInt32) -> Void)?

    func parserPrint(_ scalar: UnicodeScalar) {
        scalars.append(scalar.value)
        onScalar?(scalar.value)
    }

    func parserExecute(_ byte: UInt8) {}
    func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) {}
    func parserESC(final: UInt8, collect: [UInt8]) {}
    func parserOSC(code: Int, payload: ArraySlice<UInt8>) {}
    func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) {}
    func parserDCSPut(_ bytes: ArraySlice<UInt8>) {}
    func parserDCSUnhook() {}
    func parserAPC(_ bytes: ArraySlice<UInt8>) {}
}
