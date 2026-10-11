import Foundation
import XCTest
@testable import CmdyCore

/// Expectations come from xterm's control-sequence reference and the Kitty
/// progressive-enhancement protocol, not from another CMDY implementation.
final class IndependentCompatibilityTests: XCTestCase {
    private final class Host: CmdyTerminalDelegate {
        var replies: [String] = []
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) { replies.append(String(decoding: data, as: UTF8.self)) }
        func contentChanged(_ terminal: CmdyTerminal) {}
        func setTitle(_ terminal: CmdyTerminal, title: String) {}
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {}
        func bell(_ terminal: CmdyTerminal) {}
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {}
        func willReflow(_ terminal: CmdyTerminal) {}
        func didReflow(_ terminal: CmdyTerminal) {}
    }

    func testKeyboardStackEvictsOldestAtDeclaredBoundAndResetsWhenPoppedEmpty() {
        let terminal = CmdyTerminal(cols: 20, rows: 4)
        for index in 1...100_000 { terminal.feed(text: "\u{1b}[>\(index % 31)u") }
        XCTAssertEqual(terminal.kittyKeyboardFlags, 100_000 % 31)
        terminal.feed(text: "\u{1b}[<63u")
        XCTAssertEqual(terminal.kittyKeyboardFlags, (100_000 - 63) % 31)
        terminal.feed(text: "\u{1b}[<u")
        XCTAssertEqual(terminal.kittyKeyboardFlags, 0, "The declared stack limit is 64; the oldest requests must be evicted")
    }

    func testKeyboardStacksAreIndependentAndQueryReturnsExactFlags() {
        let terminal = CmdyTerminal(cols: 20, rows: 4)
        let host = Host(); terminal.delegate = host
        terminal.feed(text: "\u{1b}[>3u\u{1b}[?u\u{1b}[?1049h\u{1b}[?u\u{1b}[>8u\u{1b}[?u\u{1b}[?1049l\u{1b}[?u")
        XCTAssertEqual(host.replies, ["\u{1b}[?3u", "\u{1b}[?0u", "\u{1b}[?8u", "\u{1b}[?3u"])
        terminal.feed(text: "\u{1b}[=8;2u\u{1b}[=1;3u")
        XCTAssertEqual(terminal.kittyKeyboardFlags, 10)
        terminal.feed(text: "\u{1b}[<999u")
        XCTAssertEqual(terminal.kittyKeyboardFlags, 0)
    }

    func testImplementedPrivateModesReportSetResetAndUnknownExactly() {
        let terminal = CmdyTerminal(cols: 20, rows: 4)
        let host = Host(); terminal.delegate = host
        for mode in [40, 45, 69, 1004, 2004, 2026] {
            terminal.feed(text: "\u{1b}[?\(mode)h\u{1b}[?\(mode)$p\u{1b}[?\(mode)l\u{1b}[?\(mode)$p")
            XCTAssertEqual(Array(host.replies.suffix(2)), ["\u{1b}[?\(mode);1$y", "\u{1b}[?\(mode);2$y"], "mode \(mode)")
        }
        terminal.feed(text: "\u{1b}[?9999$p")
        XCTAssertEqual(host.replies.last, "\u{1b}[?9999;0$y")
    }

    func testCursorStatusAndTabsUseIndependentExpectedBytes() {
        let terminal = CmdyTerminal(cols: 24, rows: 6)
        let host = Host(); terminal.delegate = host
        terminal.feed(text: "\tX\u{1b}[6n\u{1b}[5n")
        XCTAssertEqual(host.replies, ["\u{1b}[1;10R", "\u{1b}[0n"])
        terminal.feed(text: "\u{1b}[2;5r\u{1b}[?6h\u{1b}[2;3H\u{1b}[6n")
        XCTAssertEqual(host.replies.last, "\u{1b}[2;3R")
    }

    func testUTF8OnlyCharacterSetDeviationIsExplicit() {
        let terminal = CmdyTerminal(cols: 24, rows: 6)
        terminal.feed(text: "\u{1b}(0lqk\u{1b}(B")
        // CMDY explicitly scopes the terminal to UTF-8. DEC designation is
        // currently inert: this documents a gap, not standards conformance.
        XCTAssertEqual(Array(terminal.buffer.liveLine(0).cells.prefix(3)).map(\.scalar), [108, 113, 107])
        terminal.feed(text: "\r┌─┐")
        XCTAssertEqual(Array(terminal.buffer.liveLine(0).cells.prefix(3)).map(\.scalar), [0x250c, 0x2500, 0x2510])
    }

    func testUTF8AndSGRBoundariesAreInvariantAtEveryByteSplit() {
        let payload = Array("Aé日👩🏽‍💻e\u{301}\u{1b}[31mZ\u{1b}[0m!".utf8)
        // Fixed grapheme expectations independently encode the expected cells.
        for split in 0...payload.count {
            let terminal = CmdyTerminal(cols: 30, rows: 2)
            terminal.feed(payload[..<split]); terminal.feed(payload[split...])
            XCTAssertEqual(terminal.buffer.x, 9, "split \(split)")
            XCTAssertEqual(terminal.buffer.liveLine(0).cells[0].scalar, 65)
            XCTAssertEqual(terminal.buffer.liveLine(0).cells[1].scalar, 0xe9)
            XCTAssertEqual(terminal.buffer.liveLine(0).cells[2].scalar, 0x65e5)
            XCTAssertEqual(terminal.buffer.liveLine(0).cells[7].scalar, 90)
            XCTAssertEqual(terminal.buffer.liveLine(0).cells[8].scalar, 33)
        }
    }
}
