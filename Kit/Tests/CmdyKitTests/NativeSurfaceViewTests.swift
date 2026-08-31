import AppKit
import XCTest
@testable import CmdyKit

@MainActor
final class NativeSurfaceViewTests: XCTestCase {
    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    func testTaskSurfaceHasStableBoundedHeightAndTextRepresentation() throws {
        let document = try SurfaceDocument(
            id: "tasks", kind: .task, title: "Tests", fallback: "all tests",
            tasks: (0..<100).map {
                SurfaceTask(id: "task-\($0)", label: "Task \($0)", status: .pending)
            })
        let view = NativeSurfaceView(document: document)

        XCTAssertGreaterThanOrEqual(view.preferredHeight, 150)
        XCTAssertLessThanOrEqual(view.preferredHeight, 390)
        XCTAssertEqual(view.intrinsicContentSize.height, view.preferredHeight)
    }

    func testUpdateKeepsSurfaceIdentity() throws {
        let first = try SurfaceDocument(
            id: "diff", kind: .diff, title: "Before", fallback: "-old\n+new",
            diff: "-old\n+new")
        var second = first
        second.title = "After"
        second.sequence = 1
        let view = NativeSurfaceView(document: first)

        view.update(second)
        XCTAssertEqual(view.document.id, "diff")
        XCTAssertEqual(view.document.title, "After")
        XCTAssertEqual(view.document.sequence, 1)
    }

    func testKeyboardNavigationAndTrailingCloseControlMatchInlinePanels() throws {
        let document = try SurfaceDocument(
            id: "tasks", kind: .task, title: "Tasks", fallback: "all tests",
            tasks: [
                SurfaceTask(id: "one", label: "One", status: .pending),
                SurfaceTask(id: "two", label: "Two", status: .running),
            ])
        let view = NativeSurfaceView(document: document)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: view.preferredHeight)
        view.layoutSubtreeIfNeeded()

        view.keyDown(with: key(125)) // down
        XCTAssertEqual(view.selectedTableRow, 0)
        view.keyDown(with: key(125))
        XCTAssertEqual(view.selectedTableRow, 1)
        view.keyDown(with: key(126)) // up
        XCTAssertEqual(view.selectedTableRow, 0)

        view.keyDown(with: key(124)) // right -> Text
        XCTAssertTrue(view.isShowingTextRepresentation)
        view.keyDown(with: key(123)) // left -> Surface
        XCTAssertFalse(view.isShowingTextRepresentation)

        let close = try XCTUnwrap(descendants(of: view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "×" })
        let closeFrame = close.convert(close.bounds, to: view)
        XCTAssertGreaterThan(closeFrame.maxX, view.bounds.maxX - 40)

        var dismissed = false
        view.onDismiss = { dismissed = true }
        view.keyDown(with: key(53)) // escape
        XCTAssertTrue(dismissed)
    }
}
