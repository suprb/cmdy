import Foundation
import CmdyKit
import CmdyCore

// CmdyCore speaking the Phase 0 seam: the engine's accessors were built
// to this dialect, so the conformance is one style shim away.
extension CmdyTerminal: @retroactive TerminalEngine {
    public var isCurrentBufferAlternate: Bool { isAlternateBuffer }

    public func setCursorStyle(_ style: TermCursorStyle) {
        let shape: TermCursorShape
        switch style {
        case .blinkBlock: shape = .blinkBlock
        case .steadyBlock: shape = .steadyBlock
        case .blinkUnderline: shape = .blinkUnderline
        case .steadyUnderline: shape = .steadyUnderline
        case .blinkBar: shape = .blinkBar
        case .steadyBar: shape = .steadyBar
        }
        setCursorStyle(shape)
    }
}
