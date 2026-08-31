import Carbon.HIToolbox
import XCTest
@testable import CmdySDK

final class HotKeyModifierTests: XCTestCase {
    func testControlOptionDoesNotAliasCommand() {
        let modifiers: CmdyHotKeyModifiers = [.control, .option]

        XCTAssertEqual(modifiers.rawValue, Int(controlKey | optionKey))
        XCTAssertEqual(modifiers.rawValue & Int(cmdKey), 0)
    }

    func testCommandShiftMatchesCarbon() {
        let modifiers: CmdyHotKeyModifiers = [.command, .shift]
        XCTAssertEqual(modifiers.rawValue, Int(cmdKey | shiftKey))
    }
}
