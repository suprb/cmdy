import XCTest
@testable import CmdySDK

final class ThemeTests: XCTestCase {
    func testDecodesNativeThemePalette() {
        let theme = CmdyTheme(payload: [
            "name": "Dark",
            "background": "#1D1F21",
            "foreground": "#C5C8C6",
            "cursor": "#81A2BE",
            "border": "#2B2E31",
            "ansi": ["#000000", "#FFFFFF"],
        ])

        XCTAssertEqual(theme?.name, "Dark")
        XCTAssertEqual(theme?.cursor, "#81A2BE")
        XCTAssertEqual(theme?.ansi.count, 2)
    }

    func testRejectsIncompleteThemePayload() {
        XCTAssertNil(CmdyTheme(payload: ["name": "Missing colors"]))
    }
}
