import CmdyNative
import Metal
import XCTest
@testable import CmdyGPU

@MainActor
final class HostWorkUpdatesTests: XCTestCase {
    func testObservationControlPreservesEnvironmentAndRejectsInvalidValues() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let session = try RenderWorkerSession(device: device, pixelFormat: .bgra8Unorm,
            surface: 1903, now: 17, hostWorkOnly: true)
        let replies = expectation(description: "observation controls and inspect reply")
        replies.expectedFulfillmentCount = 3
        var seen: [UInt64] = []
        session.onUpdate = { update in
            guard update.request_id != 0 else { return }
            XCTAssertEqual(update.environment.now, 17)
            XCTAssertEqual(update.kind, UInt32(update.request_id == 3 ? CMDY_SESSION_INSPECTION : CMDY_SESSION_ACTIONS))
            XCTAssertNotEqual(update.success, 0)
            seen.append(update.request_id)
            replies.fulfill()
        }
        var command = CmdyRenderSessionCommand()
        command.kind = UInt32(CMDY_SESSION_OBSERVE_FRAMES)
        command.environment.now = 999
        command.request_id = 1; command.event = 2
        XCTAssertFalse(session.post(command))
        command.event = 1
        XCTAssertTrue(session.post(command)) // rejected request released its reservation
        command.request_id = 2; command.event = 0
        XCTAssertTrue(session.post(command))
        command.kind = UInt32(CMDY_SESSION_INSPECT); command.request_id = 3
        XCTAssertTrue(session.post(command))
        await fulfillment(of: [replies], timeout: 10)
        XCTAssertEqual(seen, [1, 2, 3])
        await session.shutdown()
        XCTAssertFalse(session.post(command))
    }

    func testFullReplyQueueRecoversInHostWorkModeWithoutUnsolicitedState() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let session = try RenderWorkerSession(device: device, pixelFormat: .bgra8Unorm,
            surface: 1904, hostWorkOnly: true)
        let replies = expectation(description: "full queue plus reentrant admission")
        replies.expectedFulfillmentCount = RenderUpdateMailbox.replyLimit + 1
        var ids: [UInt64] = []
        var command = CmdyRenderSessionCommand()
        command.kind = UInt32(CMDY_SESSION_OBSERVE_FRAMES)
        command.event = 1
        session.onUpdate = { update in
            guard update.request_id != 0 else { return }
            ids.append(update.request_id)
            XCTAssertEqual(update.kind, UInt32(CMDY_SESSION_ACTIONS))
            if update.request_id == 1 {
                var resumed = CmdyRenderSessionCommand()
                resumed.kind = UInt32(CMDY_SESSION_OBSERVE_FRAMES)
                resumed.event = 0; resumed.request_id = 1000
                XCTAssertTrue(session.post(resumed))
            }
            replies.fulfill()
        }
        for id in 1...RenderUpdateMailbox.replyLimit {
            command.request_id = UInt64(id)
            XCTAssertTrue(session.post(command))
        }
        command.request_id = 1000
        XCTAssertFalse(session.post(command))
        XCTAssertTrue(session.waitForCapacity())
        await fulfillment(of: [replies], timeout: 10)
        XCTAssertEqual(ids, (1...64).map(UInt64.init) + [1000])
        await session.shutdown()
    }
}
