import Foundation
import XCTest
import CmdyNative
@testable import CmdyCore

final class BlockSubscriptionDeliveryTests: XCTestCase {
    private final class Events {
        var blocks = 0
        var contents = 0
    }
    private final class ReleaseAction {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        deinit { action() }
    }
    private func held(_ object: ReleaseAction) -> () -> Void { { withExtendedLifetime(object) {} } }
    private func intercept(_ terminal: CmdyTerminal, _ events: Events) {
        var host = CmdyZigHost(context: Unmanaged.passUnretained(events).toOpaque(), event: { context, event in
            let state = Unmanaged<Events>.fromOpaque(context!).takeUnretainedValue()
            if event!.pointee.kind == UInt32(CMDY_ZIG_EVENT_BLOCKS_CHANGED) { state.blocks += 1 }
            if event!.pointee.kind == UInt32(CMDY_ZIG_EVENT_CONTENT_CHANGED) { state.contents += 1 }
        }, now: nil)
        XCTAssertEqual(cmdy_zig_terminal_set_host(terminal.nativeOwner.handle, &host), 0)
    }

    func testSwiftRegistrationSuppressesActualNativeHostBoundaryOnlyWhenNil() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        let events = Events(); intercept(terminal, events)
        terminal.feed(text: "\u{1B}]133;B\u{7}")
        XCTAssertEqual(events.blocks, 0)
        terminal.blocks.onChange = {}
        terminal.feed(text: "\u{1B}]133;B\u{7}")
        XCTAssertEqual(events.blocks, 1)
        terminal.blocks.onChange = nil
        terminal.feed(text: "\u{1B}c\u{1B}]133;B\u{7}")
        XCTAssertEqual(events.blocks, 1)
        XCTAssertEqual(events.contents, 3)
        withExtendedLifetime(events) {}
    }

    func testNativeSubscriptionPrecedesReentrantOldCaptureDestruction() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        let events = Events(); intercept(terminal, events)
        terminal.blocks.onChange = held(ReleaseAction { [weak terminal] in
            terminal?.feed(text: "\u{1B}]133;B\u{7}")
        })
        terminal.blocks.onChange = nil
        XCTAssertEqual(events.blocks, 0, "The old closure must die after the native subscription is disabled")
        terminal.blocks.onChange = held(ReleaseAction { [weak terminal] in
            terminal?.feed(text: "\u{1B}]133;B\u{7}")
        })
        terminal.blocks.onChange = {}
        XCTAssertEqual(events.blocks, 1)
        XCTAssertEqual(events.contents, 2)
        withExtendedLifetime(events) {}
    }
}
