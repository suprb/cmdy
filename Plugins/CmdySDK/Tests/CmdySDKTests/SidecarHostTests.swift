import CoreGraphics
import XCTest
@testable import CmdySDK

final class SidecarHostTests: XCTestCase {
    func testUnattachedSidecarTracksTheCurrentKeyWindow() {
        var host = CmdySidecarHost()

        XCTAssertTrue(host.observe(11, attached: false))
        XCTAssertTrue(host.observe(22, attached: false))
        XCTAssertEqual(host.windowNumber, 22)
    }

    func testAttachedSidecarRejectsAnotherCmdyWindow() {
        var host = CmdySidecarHost(windowNumber: 11)

        XCTAssertFalse(host.observe(22, attached: true))
        XCTAssertEqual(host.windowNumber, 11)
        XCTAssertTrue(host.observe(11, attached: true))
    }

    func testClearAllowsAnewAttachment() {
        var host = CmdySidecarHost(windowNumber: 11)

        host.clear()
        XCTAssertNil(host.windowNumber)
        XCTAssertTrue(host.observe(22, attached: true))
        XCTAssertEqual(host.windowNumber, 22)
    }

    func testCardGeometryUsesEqualExposedEdgeInsets() {
        let host = CGRect(x: 100, y: 80, width: 1200, height: 900)
        let frame = CmdySidecarGeometry.cardFrame(host: host, dockSide: 25,
                                                     stripWidth: 500, padding: 10)

        XCTAssertEqual(frame.minY - host.minY, 35, accuracy: 0.01)
        XCTAssertEqual(host.maxY - frame.maxY, 35, accuracy: 0.01)
        XCTAssertEqual(host.maxX - frame.maxX, 35, accuracy: 0.01)
        XCTAssertEqual(frame.width, 480, accuracy: 0.01)
    }

    func testCardGeometryStaysBeforeATrailingInspector() {
        let host = CGRect(x: 100, y: 80, width: 1200, height: 900)
        let frame = CmdySidecarGeometry.cardFrame(
            host: host, dockSide: 0, stripWidth: 500, padding: 10,
            trailingOffset: 280)

        XCTAssertEqual(host.maxX - frame.maxX, 290, accuracy: 0.01)
        XCTAssertEqual(frame.minY - host.minY, 10, accuracy: 0.01)
        XCTAssertEqual(host.maxY - frame.maxY, 10, accuracy: 0.01)
    }

    func testInsetSyncCoalescesLiveResizeToTheLatestWidth() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var sync = CmdySidecarInsetSync()

        XCTAssertEqual(sync.update(to: 620, now: start), 620)
        XCTAssertNil(sync.update(to: 540, now: start.addingTimeInterval(0.01)))
        XCTAssertNil(sync.update(to: 420, now: start.addingTimeInterval(0.02)))

        XCTAssertEqual(
            sync.complete(sent: 620, succeeded: true,
                          now: start.addingTimeInterval(0.03)),
            420
        )
        XCTAssertNil(
            sync.complete(sent: 420, succeeded: true,
                          now: start.addingTimeInterval(0.04))
        )
        XCTAssertEqual(sync.applied, 420)
    }

    func testInsetSyncHeartbeatsAndRateLimitsFailedRetries() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        var sync = CmdySidecarInsetSync()

        XCTAssertEqual(sync.update(to: 500, now: start), 500)
        XCTAssertNil(sync.complete(sent: 500, succeeded: false,
                                   now: start.addingTimeInterval(0.1)))
        XCTAssertNil(sync.update(to: 500, now: start.addingTimeInterval(1)))
        XCTAssertEqual(sync.update(to: 500, now: start.addingTimeInterval(2.1)), 500)
        XCTAssertNil(sync.complete(sent: 500, succeeded: true,
                                   now: start.addingTimeInterval(2.2)))
        XCTAssertNil(sync.update(to: 500, now: start.addingTimeInterval(3)))
        XCTAssertEqual(sync.update(to: 500, now: start.addingTimeInterval(4.2)), 500)
    }
}
