import Foundation
import XCTest
import CmdyNative
@testable import CmdyCore

final class NativeOwnershipBridgeTests: XCTestCase {
    func testWeakLineIdentityTracksNativeOwnerAndSurvivesBufferReleaseWhenRetained() {
        var buffer: ScreenBuffer? = ScreenBuffer(cols: 4, rows: 2, hasScrollback: true)
        weak var weakBuffer = buffer
        weak var weakLine: Line?
        autoreleasepool {
            let line = buffer!.liveLine(0)
            weakLine = line
            XCTAssertTrue(line === buffer!.line(absolute: 0))
        }
        XCTAssertNotNil(weakLine)
        var retained = weakLine
        buffer = nil
        XCTAssertNil(weakBuffer)
        XCTAssertNotNil(weakLine)
        retained![0] = Cell(scalar: 65)
        XCTAssertEqual(retained!.trimmedText(), "A")
        retained = nil
        XCTAssertNil(weakLine)
    }

    func testUnretainedExposedRowsReleaseWhenBufferDies() {
        weak var line: Line?
        autoreleasepool {
            let buffer = ScreenBuffer(cols: 4, rows: 2, hasScrollback: true)
            line = buffer.liveLine(0)
            XCTAssertNotNil(line)
        }
        XCTAssertNil(line)
    }

    func testReadoptionDoesNotChangeIdentityOrIntroduceOwnershipCycle() {
        var row: Line? = Line(cols: 4)
        weak var weakRow = row
        var buffer: ScreenBuffer? = ScreenBuffer(cols: 4, rows: 1, hasScrollback: false)
        for _ in 0..<64 {
            buffer!.replaceLines([row!])
            XCTAssertTrue(buffer!.liveLine(0) === row)
            buffer!.replaceLines([Line(cols: 4)])
            XCTAssertNotNil(weakRow)
        }
        buffer!.replaceLines([row!])
        row = nil
        XCTAssertNotNil(weakRow)
        buffer = nil
        XCTAssertNil(weakRow)
    }

    func testGhostIdentityAndLifetimeFollowStructuralClear() {
        let buffer = ScreenBuffer(cols: 4, rows: 2, hasScrollback: true, maxScrollback: 10)
        weak var ghost: Line?
        autoreleasepool {
            let exposed = buffer.lineAutovivified(absolute: 5)!
            ghost = exposed
            XCTAssertTrue(exposed === buffer.overflowLines[5])
            XCTAssertTrue(exposed === buffer.lineAutovivified(absolute: 17))
        }
        XCTAssertNotNil(ghost)
        buffer.clearOverflowLines()
        XCTAssertNil(ghost)
        XCTAssertTrue(buffer.overflowLines.isEmpty)
    }

    func testPublicCloneSharesLiveImageMetadataButDetachesCells() {
        var line: Line? = Line(cols: 2)
        var image: LineImage? = LineImage(payload: .rgba(bytes: [1,2,3,4], width: 1, height: 1),
                                         pixelWidth: 10, pixelHeight: 20, col: 3)
        weak var weakImage = image
        line!.images = [image!]
        line![0] = Cell(scalar: 101, clusterExtras: [0x301])
        var clone: Line? = line!.clone()
        XCTAssertTrue(clone!.images![0] === image)
        image!.col = 9
        image!.kittyImageId = 0
        XCTAssertEqual(clone!.images![0].col, 9)
        XCTAssertEqual(clone!.images![0].kittyImageId, 0)
        line!.appendClusterScalar(0x302, at: 0, width: 2)
        XCTAssertEqual(clone![0].clusterExtras, [0x301])
        XCTAssertEqual(clone![0].width, 1)
        image = nil
        line = nil
        XCTAssertNotNil(weakImage)
        clone = nil
        XCTAssertNil(weakImage)
    }

    func testNativeSnapshotFreezesImageGeometryAndRetainsOriginalPayload() {
        var releases = 0
        var line: Line? = Line(cols: 2)
        attachImage(to: line!) { releases += 1 }
        line!.images![0].col = 2
        let identity = line!.images![0].renderIdentity
        var snapshot: Line? = Line.wrapping(retained: cmdy_zig_line_snapshot(line!.native)!)
        line!.images![0].col = 8
        XCTAssertEqual(snapshot!.images![0].col, 2)
        XCTAssertEqual(snapshot!.images![0].renderIdentity, identity)
        XCTAssertFalse(snapshot!.images![0] === line!.images![0])
        line = nil
        XCTAssertEqual(releases, 0)
        snapshot = nil
        XCTAssertEqual(releases, 1)
    }

    func testImageClearPublishesNilBeforePayloadCallbackCanReenter() {
        let line = Line(cols: 3)
        weak var weakLine = line
        var releases = 0
        attachImage(to: line) {
            releases += 1
            XCTAssertNil(weakLine!.images)
            weakLine![1] = Cell(scalar: 82)
        }
        line.images = nil
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(line.trimmedText(), " R")
    }

    func testNeverExposedNativeRowsDoNotAllocateSwiftIdentityBridges() {
        let buffer = ScreenBuffer(cols: 4, rows: 2, hasScrollback: true, maxScrollback: 4)
        for _ in 0..<100 { buffer.scrollUp(fill: Cell()) }
        for index in 0..<buffer.lineCount {
            let native = cmdy_zig_buffer_line(buffer.native, index)!
            XCTAssertNil(cmdy_zig_line_swift_context(native))
            cmdy_zig_line_release(native)
        }
    }

    private func attachImage(to line: Line, onRelease: @escaping () -> Void) {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
        let data = Data(bytesNoCopy: memory, count: 4096, deallocator: .custom { memory, _ in
            memory.deallocate()
            onRelease()
        })
        line.images = [LineImage(payload: .png(data), pixelWidth: 1, pixelHeight: 1, col: 0)]
    }
}
