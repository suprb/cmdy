import Foundation
import XCTest
import CmdyNative
@_spi(CmdyApp) @testable import CmdyCore

final class NativeGraphicsSnapshotTests: XCTestCase {
    func testEmptyRegistryDoesNotAllocateGraphicsOwner() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        terminal.captureTerminalSnapshot().withNativeGraphics { XCTAssertNil($0) }
    }

    func testGraphicsOutliveTerminalAndKeepBothBufferPlacementsAndExactPayloadStorage() {
        var terminal: CmdyTerminal? = CmdyTerminal(cols: 8, rows: 2)
        let image = KittyGraphicsStore.Image(id: 91, number: nil,
            payload: .rgba(bytes: [1, 2, 3, 4], width: 1, height: 1), width: 7, height: 9)
        XCTAssertTrue(terminal!.kittyGraphics.store(image))
        for alternate in [false, true] {
            XCTAssertTrue(terminal!.kittyGraphics.place(.init(imageId: 91,
                placementId: alternate ? 72 : 71, col: 0, row: 0, cols: 4, rows: 5,
                zIndex: -1, pixelOffsetX: -2, pixelOffsetY: 7, isVirtual: true, isAlternateBuffer: alternate)))
        }
        var payload = CmdyZigPayloadInfo()
        XCTAssertEqual(cmdy_zig_payload_info(cmdy_zig_stored_image_payload(image.native), &payload), 0)
        var snapshot: CoreTerminalSnapshot? = terminal!.captureTerminalSnapshot()
        let native = snapshot!.withNativeGraphics { cmdy_render_graphics_input_retain($0)! }
        defer { cmdy_render_graphics_input_release(native) }
        var projected: CoreTerminalSnapshot? = snapshot!.projectingViewport(onto: snapshot!.grid)
        projected!.withNativeGraphics { XCTAssertEqual($0, native) }
        terminal!.kittyGraphics.deleteAll()
        projected = nil; snapshot = nil; terminal = nil
        for alternate in [UInt8(0), UInt8(1)] {
            let view = cmdy_render_graphics_input_view(native, alternate)!.pointee
            XCTAssertEqual(view.image_count, 1); XCTAssertEqual(view.live_count, 1)
            let value = view.images[0]
            XCTAssertEqual(value.bytes, payload.bytes)
            XCTAssertEqual(value.width, 1); XCTAssertEqual(value.height, 1)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: value.bytes, count: value.byte_count)), [1, 2, 3, 4])
            XCTAssertEqual(view.placement_count, 1)
            XCTAssertEqual(view.placements[0].placement_id, alternate == 0 ? 71 : 72)
            XCTAssertEqual(view.placements[0].offset_y, 7)
        }
    }

    func testRegistryReplacementChangesNewSnapshotWithoutMutatingPublishedBytes() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        func replace(_ value: UInt8) {
            XCTAssertTrue(terminal.kittyGraphics.store(.init(id: 91, number: nil,
                payload: .rgba(bytes: [value, 2, 3, 4], width: 1, height: 1), width: 1, height: 1)))
        }
        replace(10)
        let first = terminal.captureTerminalSnapshot()
        replace(20)
        let second = terminal.captureTerminalSnapshot()
        terminal.kittyGraphics.deleteAll()
        for (snapshot, expected) in [(first, UInt8(10)), (second, UInt8(20))] {
            snapshot.withNativeGraphics { handle in
                XCTAssertEqual(cmdy_render_graphics_input_view(handle, 0)!.pointee.images[0].bytes[0], expected)
            }
        }
    }
}
