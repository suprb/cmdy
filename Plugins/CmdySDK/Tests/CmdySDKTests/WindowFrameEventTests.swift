import XCTest
@testable import CmdySDK

final class WindowFrameEventTests: XCTestCase {
    func testDecodesWindowFrameEvent() {
        let frame = Cmdy.windowFrame(from: [
            "kind": "window-frame",
            "x": NSNumber(value: 20.5),
            "y": NSNumber(value: 40),
            "width": NSNumber(value: 1200),
            "height": NSNumber(value: 800),
        ])

        XCTAssertEqual(frame, CGRect(x: 20.5, y: 40, width: 1200, height: 800))
    }

    func testRejectsOtherAndInvalidEvents() {
        XCTAssertNil(Cmdy.windowFrame(from: ["kind": "command"]))
        XCTAssertNil(Cmdy.windowFrame(from: [
            "kind": "window-frame", "x": 0, "y": 0, "width": 0, "height": 100,
        ]))
        XCTAssertNil(Cmdy.windowFrame(from: [
            "kind": "window-frame", "x": Double.nan, "y": 0,
            "width": 100, "height": 100,
        ]))
        XCTAssertNil(Cmdy.windowFrame(from: [
            "kind": "window-frame", "x": 0, "y": 0,
            "width": Double.infinity, "height": 100,
        ]))
        XCTAssertNil(Cmdy.windowFrame(from: [
            "kind": "window-frame", "x": 0, "y": 0,
            "width": 2_000_000, "height": 100,
        ]))
    }
}
