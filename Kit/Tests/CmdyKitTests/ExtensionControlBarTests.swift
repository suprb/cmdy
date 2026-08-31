import AppKit
import XCTest
@testable import CmdyKit

@MainActor
final class ExtensionControlBarTests: XCTestCase {
    private func key(_ characters: String, code: UInt16,
                     modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
    }

    func testControlBarUsesTerminalMetricsAndEmitsActionsAndSubmissions() throws {
        let margin = Preferences.shared.contentMargin
        let bar = ExtensionControlBar(frame: NSRect(x: 0, y: 0, width: 720, height: 80))
        bar.metrics = {
            (.monospacedSystemFont(ofSize: 13, weight: .regular), 22, 14)
        }

        var action: String?
        var submission: String?
        bar.onAction = { action = $0 }
        bar.onSubmit = { submission = $0 }
        bar.configure(
            actions: [ExtensionControlBarAction(id: "annotate", title: "[ annotate ]")],
            placeholder: "enter URL", value: "localhost:3000")
        bar.layoutSubtreeIfNeeded()

        XCTAssertEqual(bar.preferredHeight, 22 + 2 * margin, accuracy: 0.01)
        bar.performAction(id: "annotate")
        XCTAssertEqual(action, "annotate")

        XCTAssertEqual(bar.currentValue, "localhost:3000")
        bar.setValue("example.com")
        bar.submitCurrentValue()
        XCTAssertEqual(submission, "example.com")
    }

    func testKeyboardCyclesFromInputToActionsAndBackToTyping() {
        let bar = ExtensionControlBar(frame: NSRect(x: 0, y: 0, width: 720, height: 80))
        var action: String?
        var submission: String?
        bar.onAction = { action = $0 }
        bar.onSubmit = { submission = $0 }
        bar.configure(
            actions: [
                ExtensionControlBarAction(id: "annotate", title: "[ annotate ]"),
                ExtensionControlBarAction(id: "back", title: "back"),
            ],
            placeholder: "enter URL", value: "example.com")

        bar.keyDown(with: key("\t", code: 48))
        bar.keyDown(with: key("\r", code: 36))
        XCTAssertEqual(action, "annotate")

        bar.keyDown(with: key("\t", code: 48, modifiers: [.shift]))
        bar.keyDown(with: key("a", code: 0, modifiers: [.command]))
        bar.keyDown(with: key("x", code: 7))
        bar.keyDown(with: key("\r", code: 36))
        XCTAssertEqual(submission, "x")
    }

    func testDownEntryFocusesFirstActionAndArrowsActivateOrExit() {
        let bar = ExtensionControlBar(frame: NSRect(x: 0, y: 0, width: 720, height: 80))
        var action: String?
        var escaped = false
        bar.onAction = { action = $0 }
        bar.onEscape = { escaped = true }
        bar.configure(
            actions: [
                ExtensionControlBarAction(id: "annotate", title: "[ annotate ]"),
                ExtensionControlBarAction(id: "back", title: "back"),
            ],
            placeholder: "enter URL")

        bar.focusFirstAction()
        bar.keyDown(with: key("", code: 124))
        bar.keyDown(with: key("\r", code: 36))
        XCTAssertEqual(action, "back")

        bar.focusFirstAction()
        bar.keyDown(with: key("", code: 126))
        XCTAssertTrue(escaped)
    }

    func testInputCanLeadFlexibleRightAlignedActions() throws {
        let bar = ExtensionControlBar(frame: NSRect(x: 0, y: 0, width: 720, height: 80))
        bar.configure(
            actions: [
                ExtensionControlBarAction(id: "back", title: "←"),
                ExtensionControlBarAction(id: "forward", title: "→"),
                ExtensionControlBarAction(id: "annotate", title: "Annotate"),
            ],
            placeholder: "enter URL",
            inputFirst: true)
        bar.layoutSubtreeIfNeeded()

        let input = bar.currentInputFrame
        let back = try XCTUnwrap(bar.frameForAction(id: "back"))
        let forward = try XCTUnwrap(bar.frameForAction(id: "forward"))
        let annotate = try XCTUnwrap(bar.frameForAction(id: "annotate"))
        XCTAssertLessThan(input.minX, back.minX)
        XCTAssertLessThan(back.maxX, forward.maxX)
        XCTAssertLessThan(forward.maxX, annotate.maxX)
        XCTAssertEqual(annotate.maxX, bar.bounds.width - Preferences.shared.contentMargin,
                       accuracy: 0.5)
    }

    func testInputFirstControlRelayoutsAtEachHostWidth() throws {
        let bar = ExtensionControlBar(frame: NSRect(x: 0, y: 0, width: 720, height: 80))
        bar.configure(
            actions: [
                ExtensionControlBarAction(id: "back", title: "←"),
                ExtensionControlBarAction(id: "forward", title: "→"),
                ExtensionControlBarAction(id: "annotate", title: "Annotate"),
            ],
            placeholder: "enter URL",
            inputFirst: true)
        bar.layoutSubtreeIfNeeded()
        let initialInputWidth = bar.currentInputFrame.width

        bar.setFrameSize(NSSize(width: 510, height: 80))
        bar.layoutSubtreeIfNeeded()
        let narrowAnnotate = try XCTUnwrap(bar.frameForAction(id: "annotate"))
        XCTAssertEqual(narrowAnnotate.maxX,
                       510 - Preferences.shared.contentMargin, accuracy: 0.5)
        XCTAssertLessThan(bar.currentInputFrame.width, initialInputWidth)

        bar.setFrameSize(NSSize(width: 940, height: 80))
        bar.layoutSubtreeIfNeeded()
        let wideAnnotate = try XCTUnwrap(bar.frameForAction(id: "annotate"))
        XCTAssertEqual(wideAnnotate.maxX,
                       940 - Preferences.shared.contentMargin, accuracy: 0.5)
        XCTAssertGreaterThan(bar.currentInputFrame.width, initialInputWidth)
    }
}
