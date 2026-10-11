import Foundation
import XCTest
import CmdyNative
@_spi(CmdyApp) @testable import CmdyCore

final class NativeViewportSnapshotTests: XCTestCase {
    func testNativeWindowAndSwiftRowsShareTheSameFrozenStorage() {
        let terminal = CmdyTerminal(cols: 12, rows: 3)
        terminal.feed(text: "e\u{301}🧑‍💻\r\nnext")
        let snapshot = terminal.captureTerminalSnapshot(extraScreens: 0)
        snapshot.withNativeRows { handle in
            XCTAssertEqual(cmdy_zig_buffer_snapshot_first(handle), snapshot.firstLineRow)
            XCTAssertEqual(cmdy_zig_buffer_snapshot_count(handle), snapshot.lines.count)
            for (index, row) in snapshot.lines.enumerated() {
                row.withNativeLine { raw in
                    XCTAssertEqual(cmdy_zig_buffer_snapshot_line(handle, index), OpaquePointer(raw))
                    XCTAssertNil(cmdy_zig_line_swift_context(OpaquePointer(raw)))
                }
            }
            XCTAssertNil(cmdy_zig_buffer_snapshot_line(handle, snapshot.lines.count))
        }
    }

    func testRetainedNativeWindowOutlivesSwiftSnapshotAndTerminal() {
        var terminal: CmdyTerminal? = CmdyTerminal(cols: 8, rows: 2)
        terminal!.feed(text: "e\u{301}")
        var snapshot: CoreTerminalSnapshot? = terminal!.captureTerminalSnapshot(extraScreens: 0)
        let native = snapshot!.withNativeRows { cmdy_zig_buffer_snapshot_retain($0)! }
        defer { cmdy_zig_buffer_snapshot_release(native) }
        terminal!.feed(text: "\u{1b}[2Jreplacement")
        terminal!.resize(cols: 20, rows: 5)
        snapshot = nil; terminal = nil
        let row = cmdy_zig_buffer_snapshot_line(native, 0)!
        var cell = CmdyZigCell(), extras: UnsafePointer<UInt32>?, count = 0, present: UInt8 = 0
        XCTAssertEqual(cmdy_zig_line_read(row, 0, &cell, &extras, &count, &present), 0)
        XCTAssertEqual(cell.scalar, 101)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: extras, count: count)), [0x301])
        XCTAssertEqual(cmdy_zig_line_count(row), 8)
        XCTAssertEqual(cmdy_zig_buffer_snapshot_count(native), 2)
    }

    func testImageGeometryIsFrozenWithoutNativeSnapshotSwiftIdentity() {
        let terminal = CmdyTerminal(cols: 12, rows: 2)
        let image = LineImage(payload: .rgba(bytes: [1, 2, 3, 4], width: 1, height: 1),
                              pixelWidth: 7, pixelHeight: 9, col: 2)
        image.kittyIsKitty = true; image.kittyImageId = 100; image.kittyPlacementId = 71
        image.kittyZIndex = -2; image.kittyPixelOffsetX = 3; image.kittyPixelOffsetY = 4
        terminal.buffer.liveLine(0).images = [image]
        let snapshot = terminal.captureTerminalSnapshot(extraScreens: 0)
        image.col = 8; image.kittyPixelOffsetY = 80
        terminal.buffer.liveLine(0).images = nil
        snapshot.withNativeRows { handle in
            let row = cmdy_zig_buffer_snapshot_line(handle, 0)!
            let frozen = cmdy_zig_line_image_get(row, 0)!
            defer { cmdy_zig_image_release(frozen) }
            XCTAssertNil(cmdy_zig_image_swift_context(frozen))
            var info = CmdyZigImageInfo()
            XCTAssertEqual(cmdy_zig_image_info(frozen, &info), 0)
            XCTAssertEqual(info.col, 2); XCTAssertEqual(info.offset_y, 4)
            XCTAssertEqual(info.pixel_width, 7); XCTAssertEqual(info.pixel_height, 9)
            XCTAssertEqual(info.image_id, 100); XCTAssertEqual(info.placement_id, 71)
            XCTAssertEqual(info.z_index, -2)
            var payload = CmdyZigPayloadInfo()
            XCTAssertEqual(cmdy_zig_payload_info(cmdy_zig_image_payload(frozen), &payload), 0)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: payload.bytes, count: payload.count)), [1, 2, 3, 4])
        }
        let projected = snapshot.lines[0].images[0]
        XCTAssertEqual(projected.renderIdentity, image.renderIdentity)
        XCTAssertEqual(projected.col, 2); XCTAssertEqual(projected.kittyPixelOffsetY, 4)
        guard case .rgba(let bytes, let width, let height) = projected.payload else {
            return XCTFail("RGBA payload changed format")
        }
        XCTAssertEqual(bytes, [1, 2, 3, 4]); XCTAssertEqual(width, 1); XCTAssertEqual(height, 1)
    }

    func testViewportProjectionAndConcurrentReadersRetainOneWindow() {
        let terminal = CmdyTerminal(cols: 12, rows: 3)
        terminal.feed(text: "shared")
        let snapshot = terminal.captureTerminalSnapshot()
        let projected = snapshot.projectingViewport(onto: snapshot.grid)
        snapshot.withNativeRows { first in
            projected.withNativeRows { XCTAssertEqual(first, $0) }
        }
        struct ReadResult {
            var status: Int32 = -1
            var scalar: UInt32 = 0
            var extraCount = -1
            var extrasPresent: UInt8 = 1
        }
        let results = UnsafeMutableBufferPointer<ReadResult>.allocate(capacity: 32)
        results.initialize(repeating: ReadResult())
        defer {
            results.deinitialize()
            results.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: results.count) { index in
            results[index] = projected.withNativeRows { handle in
                let row = cmdy_zig_buffer_snapshot_line(handle, 0)!
                var cell = CmdyZigCell()
                var extras: UnsafePointer<UInt32>?, count = 0, present: UInt8 = 0
                let status = cmdy_zig_line_read(row, 0, &cell, &extras, &count, &present)
                return ReadResult(status: status, scalar: cell.scalar,
                                  extraCount: count, extrasPresent: present)
            }
        }
        for result in results {
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.scalar, 115)
            XCTAssertEqual(result.extraCount, 0)
            XCTAssertEqual(result.extrasPresent, 0)
        }
    }
}
