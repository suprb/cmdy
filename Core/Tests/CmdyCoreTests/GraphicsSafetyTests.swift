import XCTest
@testable import CmdyCore

final class GraphicsSafetyTests: XCTestCase {
    func testSixelDecodesSmallImage() {
        let decoder = SixelDecoder()
        decoder.feed(Array("~".utf8)[...])

        let result = decoder.finish()
        XCTAssertEqual(result?.1, 1)
        XCTAssertEqual(result?.2, 6)
        XCTAssertEqual(result?.0.count, 24)
        XCTAssertEqual(result?.0[3], 255)
    }

    func testSixelRejectsSparseCanvasBeyondAllocationLimit() {
        let decoder = SixelDecoder()
        var payload = Array("!10000~".utf8)
        payload.append(contentsOf: repeatElement(UInt8(ascii: "-"), count: 100))
        payload.append(UInt8(ascii: "~"))

        decoder.feed(payload[...])

        XCTAssertNil(decoder.finish())
    }

    func testSixelHugeNumberCannotOverflowAccumulator() {
        let decoder = SixelDecoder()
        decoder.feed(Array(("!" + String(repeating: "9", count: 128) + "~").utf8)[...])

        XCTAssertNotNil(decoder.finish())
    }

    func testDECRQSSPayloadIsBounded() {
        let terminal = CmdyTerminal(cols: 80, rows: 24)
        terminal.dcsHook(
            final: UInt8(ascii: "q"),
            params: [],
            collect: [UInt8(ascii: "$")])

        terminal.dcsPut(Array(repeating: UInt8(0x61), count: 4_097)[...])

        XCTAssertTrue(terminal.decrqssBuffer.isEmpty)
        terminal.dcsUnhook()
    }

    func testPNGDimensionsRequireRealIHDR() {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0..<8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes[16..<24] = [0, 0, 0, 1, 0, 0, 0, 1]

        XCTAssertNil(CmdyTerminal.pngDimensions(Data(bytes)))
    }

    func testITermImageWithHostileDimensionsIsIgnored() {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0..<16] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
        ]
        bytes[16..<24] = [0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1]
        let terminal = CmdyTerminal(cols: 8, rows: 3)
        let payload = Data(bytes).base64EncodedString()

        terminal.feed(text: "\u{1b}]1337;File=inline=1:\(payload)\u{7}")

        XCTAssertTrue(terminal.buffer.lines.allSatisfy { $0.images == nil })
    }

    func testKittyRawImageDimensionMultiplicationIsChecked() {
        let terminal = CmdyTerminal(cols: 8, rows: 3)
        let apc = Array("Gf=32,s=\(Int.max),v=2;AAAA".utf8)

        terminal.handleAPC(apc[...])

        XCTAssertEqual(terminal.kittyImageCount, 0)
    }

    func testKittyHandlerReportsOnlySuccessfulCursorMovingPlacements() {
        let terminal = CmdyTerminal(cols: 3, rows: 3)
        let transmitAndPlace = Array(
            "Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==".utf8)
        XCTAssertTrue(terminal.handleAPC(transmitAndPlace[...]))

        let transmitOnly = Array(
            "Ga=t,f=32,s=1,v=1,i=21,q=2;/wAA/w==".utf8)
        XCTAssertFalse(terminal.handleAPC(transmitOnly[...]))

        let display = Array(
            "Ga=p,i=21,p=1,x=0,y=0,c=1,r=1,q=2;".utf8)
        XCTAssertTrue(terminal.handleAPC(display[...]))

        let query = Array(
            "Ga=q,f=32,s=1,v=1,i=23,q=2;/wAA/w==".utf8)
        XCTAssertFalse(terminal.handleAPC(query[...]))

        let deletion = Array("Ga=d,d=i,i=21,q=2;".utf8)
        XCTAssertFalse(terminal.handleAPC(deletion[...]))

        let malformed = Array("Ga=T,f=32,s=1,v=1,i=22,q=2;%%%".utf8)
        XCTAssertFalse(terminal.handleAPC(malformed[...]))
    }

    /// Multiplexers such as herdr re-send one placement as their panes scroll
    /// and crop it to the visible area. Kitty replaces the placement with the
    /// same IDs and keeps the requested cell box and source crop.
    func testKittyReplacedPlacementMovesAndKeepsCellBoxAndCrop() {
        let terminal = CmdyTerminal(cols: 20, rows: 8)
        func images() -> [(row: Int, image: LineImage)] {
            (0..<terminal.rows).flatMap { row in
                (terminal.lineForDiff(absolute: terminal.liveScreenTopRow + row)?.images ?? []).map { (row, $0) }
            }
        }
        terminal.feed(text: "\u{1b}[?1049h\u{1b}_Ga=t,f=32,s=2,v=2,i=5,q=2;/wAA//8AAP8AAP//AP8A/w==\u{1b}\\")
        terminal.feed(text: "\u{1b}[2;3H\u{1b}_Ga=p,i=5,p=7,c=4,r=2,x=1,y=0,w=1,h=2,C=1,q=2;\u{1b}\\")
        var placed = images()
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed.first?.row, 1)
        XCTAssertEqual(placed.first?.image.kittyDisplayBox,
                       CoreKittyDisplayBox(cellColumns: 4, cellRows: 2, sourceX: 1, sourceY: 0,
                                           sourceWidth: 1, sourceHeight: 2))
        terminal.feed(text: "\u{1b}[6;3H\u{1b}_Ga=p,i=5,p=7,c=4,r=2,C=1,q=2;\u{1b}\\")
        placed = images()
        XCTAssertEqual(placed.map(\.row), [5])
        XCTAssertEqual(placed.first?.image.kittyDisplayBox,
                       CoreKittyDisplayBox(cellColumns: 4, cellRows: 2, sourceX: 0, sourceY: 0,
                                           sourceWidth: 0, sourceHeight: 0))
        // A different placement of the same image is a second copy.
        terminal.feed(text: "\u{1b}[1;1H\u{1b}_Ga=p,i=5,p=8,c=1,r=1,C=1,q=2;\u{1b}\\")
        XCTAssertEqual(images().map(\.row).sorted(), [0, 5])
    }

    func testKittyExplicitPlacementDoesNotMoveImplicitlyNumberedDisplay() {
        let terminal = CmdyTerminal(cols: 4, rows: 6)
        func rows() -> [Int] {
            (0..<terminal.rows).filter { row in
                !(terminal.lineForDiff(absolute: terminal.liveScreenTopRow + row)?.images ?? []).isEmpty
            }
        }
        // a=T without p= is numbered by the store; an explicit p=1 is a separate placement.
        terminal.feed(text: "\u{1b}[5;4H\u{1b}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1b}\\")
        terminal.feed(text: "\u{1b}[1;4H\u{1b}_Ga=p,i=3,p=1,c=1,r=1,q=2;\u{1b}\\")
        XCTAssertEqual(rows(), [0, 4])
    }

    func testKittyAPCDispatchesAtStringTerminatorEscapePrefix() {
        let terminal = CmdyTerminal(cols: 12, rows: 6)
        let firstChunk = Array(
            "\u{1b}_Gs=1,v=1,i=11;/wAA/w==\u{1b}".utf8)
        let secondChunk = Array(
            "\\\u{1b}_Ga=p,i=11\u{1b}\\d".utf8)

        terminal.feed(firstChunk)
        XCTAssertEqual(terminal.kittyImageCount, 1)
        terminal.feed(secondChunk)

        XCTAssertEqual(terminal.kittyImageCount, 1)
        XCTAssertEqual(terminal.buffer.lines[1].cells[0].scalar,
                       Unicode.Scalar("d").value)
        XCTAssertEqual(terminal.buffer.lines[1].cells[1].scalar, 0)
    }

    func testKittyPlacementMovesToTheRowBelowBeforeFollowingText() {
        let terminal = CmdyTerminal(cols: 3, rows: 3)
        let stream = Array((
            "\u{1b}_Gs=1,v=1,i=1;/wAA/w==\u{1b}\\"
                + "\u{1b}_Ga=p,i=1;\u{1b}\\D").utf8)

        terminal.feed(stream)

        XCTAssertEqual(terminal.kittyImageCount, 1)
        XCTAssertEqual(terminal.buffer.lines[0].cells[1].scalar, 0)
        XCTAssertEqual(terminal.buffer.lines[1].cells[0].scalar,
                       Unicode.Scalar("D").value)
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.x, 1)
    }

    func testKittyTransmitAndPlaceWrapsFromPhysicalRightEdge() {
        let terminal = CmdyTerminal(cols: 2, rows: 2)
        let stream = Array((
            "\t\u{1b}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1b}\\"
        ).utf8)

        XCTAssertEqual(stream.count, 39)
        terminal.feed(stream)

        XCTAssertEqual(terminal.kittyImageCount, 1)
        XCTAssertEqual(terminal.scrollbackLineTexts(rows: 0...1), ["", ""])
        XCTAssertEqual(terminal.buffer.lines.map { $0.cells.map(\.scalar) },
                       [[0, 0], [0, 0]])
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.x, 0)
    }

    func testKittyTransmitAndPlaceResetsNonEdgeColumnAcrossChunks() {
        let terminal = CmdyTerminal(cols: 3, rows: 2)
        let stream = Array((
            "a\u{1b}_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\u{1b}\\"
        ).utf8)

        XCTAssertEqual(stream.count, 39)
        terminal.feed(stream.prefix(1))
        terminal.feed(stream.dropFirst())

        XCTAssertEqual(terminal.kittyImageCount, 1)
        XCTAssertEqual(terminal.scrollbackLineTexts(rows: 0...1), ["a", ""])
        XCTAssertEqual(terminal.buffer.lines.map { $0.cells.map(\.scalar) },
                       [[Unicode.Scalar("a").value, 0, 0], [0, 0, 0]])
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.x, 0)
    }

    func testKittyIdentifierWrapFindsAnUnusedValue() {
        let store = KittyGraphicsStore()
        let one = KittyGraphicsStore.Image(
            id: 1, number: nil,
            payload: .rgba(bytes: [0, 0, 0, 255], width: 1, height: 1),
            width: 1, height: 1)
        let last = KittyGraphicsStore.Image(
            id: UInt32.max, number: nil,
            payload: .rgba(bytes: [0, 0, 0, 255], width: 1, height: 1),
            width: 1, height: 1)

        XCTAssertTrue(store.store(one))
        XCTAssertTrue(store.store(last))
        XCTAssertEqual(store.nextImageId, 2)
    }

    func testKittyPlacementCountIsBounded() {
        let store = KittyGraphicsStore()
        for id in 1...4_096 {
            XCTAssertTrue(store.place(KittyGraphicsStore.Placement(
                imageId: 1,
                placementId: UInt32(id),
                col: 0, row: 0, cols: 1, rows: 1, zIndex: 0,
                pixelOffsetX: 0, pixelOffsetY: 0,
                isVirtual: true, isAlternateBuffer: false)))
        }
        XCTAssertFalse(store.place(KittyGraphicsStore.Placement(
            imageId: 1,
            placementId: 4_097,
            col: 0, row: 0, cols: 1, rows: 1, zIndex: 0,
            pixelOffsetX: 0, pixelOffsetY: 0,
            isVirtual: true, isAlternateBuffer: false)))
        XCTAssertEqual(store.placementsByKey.count, 4_096)
    }

    func testBoundedZlibInflation() {
        let compressed = Data([
            0x78, 0x9C, 0xCB, 0x48, 0xCD, 0xC9, 0xC9,
            0x07, 0x00, 0x06, 0x2C, 0x02, 0x15,
        ])

        XCTAssertEqual(
            String(data: compressed.zlibInflated(maxOutputSize: 32) ?? Data(),
                   encoding: .utf8),
            "hello")
        XCTAssertNil(compressed.zlibInflated(maxOutputSize: 4))
    }
}
