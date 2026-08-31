import XCTest
@testable import BraincellBridgeKit

final class BridgeVisualTests: XCTestCase {
    func testHostThemeUsesCursorAsAccent() {
        let theme = BridgeVisualTheme(
            backgroundHex: "#1D1F21",
            foregroundHex: "#C5C8C6",
            accentHex: "#81A2BE",
            borderHex: "#2B2E31"
        )

        XCTAssertEqual(theme.background, 0x1D1F21)
        XCTAssertEqual(theme.foreground, 0xC5C8C6)
        XCTAssertEqual(theme.accent, 0x81A2BE)
        XCTAssertEqual(theme.border, 0x2B2E31)
    }

    func testBindBubbleAppearsOnlyNearMovingPointer() {
        let positions = ["pane": CGPoint(x: 100, y: 100)]

        XCTAssertEqual(
            BindBubbleHoverState.resolve(
                positions: positions,
                mouse: CGPoint(x: 110, y: 100),
                secondsSinceMovement: 0.1
            ),
            BindBubbleHoverState(visibleSessionId: "pane", clickable: true)
        )
        XCTAssertNil(BindBubbleHoverState.resolve(
            positions: positions,
            mouse: CGPoint(x: 140, y: 100),
            secondsSinceMovement: 0.1
        ).visibleSessionId)
        XCTAssertNil(BindBubbleHoverState.resolve(
            positions: positions,
            mouse: CGPoint(x: 100, y: 100),
            secondsSinceMovement: BindBubbleHoverState.idleDelay
        ).visibleSessionId)
    }
}
