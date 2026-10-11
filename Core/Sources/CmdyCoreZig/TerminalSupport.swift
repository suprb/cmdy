import Foundation
import CmdyNative

extension CmdyTerminal {
    @discardableResult
    public func sendMouseEvent(button: Int, pressed: Bool, motion: Bool,
                               modifiers: MouseModifiers, col: Int, row: Int) -> Bool {
        var reported: UInt8 = 0
        checkedNative(cmdy_zig_terminal_mouse(nativeOwner.handle, button, pressed ? 1 : 0,
            motion ? 1 : 0, modifiers.rawValue, col, row, &reported))
        return reported != 0
    }

    public struct MouseModifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = MouseModifiers(rawValue: 1)
        public static let meta = MouseModifiers(rawValue: 2)
        public static let control = MouseModifiers(rawValue: 4)
    }
}
