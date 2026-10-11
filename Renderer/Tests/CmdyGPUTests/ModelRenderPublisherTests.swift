import CmdyNative
import Metal
import XCTest
@_spi(CmdyApp) @testable import CmdyGPU

@MainActor
final class ModelRenderPublisherTests: XCTestCase {
    private final class Rows: @unchecked Sendable {
        let snapshot: OpaquePointer
        init() throws {
            let buffer = try XCTUnwrap(cmdy_zig_buffer_create(1, 1, 0, 0))
            defer { cmdy_zig_buffer_free(buffer) }
            snapshot = try XCTUnwrap(cmdy_zig_buffer_snapshot_capture(buffer, 0, 1, nil))
        }
        deinit { cmdy_zig_buffer_snapshot_release(snapshot) }
        func input(_ generation: UInt64) -> CmdyRenderModelInput {
            var value = CmdyRenderModelInput()
            value.snapshot = snapshot; value.generation = generation
            value.rows = 1; value.cols = 1; value.buffer_line_count = 1
            value.cursor_hidden = 1
            return value
        }
    }

    func testBackgroundPublisherRejectsOldGenerationsAndSurvivesExplicitShutdown() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let session = try RenderWorkerSession(device: device, pixelFormat: .bgra8Unorm, surface: 801)
        let publisher = session.modelPublisher
        let rows = try Rows()
        let accepted = await Task.detached {
            var first = rows.input(1), duplicate = rows.input(1), newer = rows.input(2)
            return [publisher.publish(&first), publisher.publish(&duplicate), publisher.publish(&newer)]
        }.value
        XCTAssertEqual(accepted, [true, false, true])
        await session.shutdown()
        let afterClose = await Task.detached {
            var input = rows.input(3)
            return publisher.publish(&input)
        }.value
        XCTAssertFalse(afterClose)
    }
}
