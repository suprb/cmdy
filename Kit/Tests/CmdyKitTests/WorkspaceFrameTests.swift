import XCTest
@testable import CmdyKit

final class WorkspaceFrameTests: XCTestCase {
    func testWideWindowShowsBothRequestedRails() {
        let result = WorkspaceFrameLayout.resolve(
            windowWidth: 1_100, navigatorRequested: true,
            inspectorRequested: true, focusMode: false)
        XCTAssertEqual(result.navigatorWidth, 210)
        XCTAssertEqual(result.inspectorWidth, 280)
        XCTAssertEqual(result.terminalWidth, 610)
    }

    func testRailsCompressBeforeInspectorCollapses() {
        let compressed = WorkspaceFrameLayout.resolve(
            windowWidth: 860, navigatorRequested: true,
            inspectorRequested: true, focusMode: false)
        XCTAssertTrue(compressed.showsNavigator)
        XCTAssertTrue(compressed.showsInspector)
        XCTAssertEqual(compressed.terminalWidth, 400)

        let narrow = WorkspaceFrameLayout.resolve(
            windowWidth: 760, navigatorRequested: true,
            inspectorRequested: true, focusMode: false)
        XCTAssertTrue(narrow.showsNavigator)
        XCTAssertFalse(narrow.showsInspector)
        XCTAssertGreaterThanOrEqual(narrow.terminalWidth, 400)
    }

    func testFocusModeAlwaysReturnsSpaceToTerminal() {
        let result = WorkspaceFrameLayout.resolve(
            windowWidth: 860, navigatorRequested: true,
            inspectorRequested: true, focusMode: true,
            reservedTrailingWidth: 160)
        XCTAssertFalse(result.showsNavigator)
        XCTAssertFalse(result.showsInspector)
        XCTAssertEqual(result.terminalWidth, 700)
    }

    func testTabsUseExactlyOneVisibleSwitcher() {
        XCTAssertFalse(WorkspaceTabPresentation.showsNativeTabBar(
            tabCount: 3, tabSidebarVisible: true))
        XCTAssertTrue(WorkspaceTabPresentation.showsNativeTabBar(
            tabCount: 3, tabSidebarVisible: false))
        XCTAssertFalse(WorkspaceTabPresentation.showsNativeTabBar(
            tabCount: 1, tabSidebarVisible: false))
    }

    func testLiveResizeMinimumKeepsVisibleRailsFixed() {
        XCTAssertEqual(
            WorkspaceFrameLayout.minimumWindowWidthKeepingRailsFixed(
                navigatorWidth: 176,
                inspectorWidth: 232,
                dividerThickness: 2),
            812)
        XCTAssertEqual(
            WorkspaceFrameLayout.minimumWindowWidthKeepingRailsFixed(
                navigatorWidth: nil,
                inspectorWidth: 280,
                dividerThickness: 2,
                reservedTrailingWidth: 160),
            842)
    }
}
