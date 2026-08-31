import AppKit
import CmdyKit

/// The pane-host construction seam shared by production windows and tests.
enum TerminalEngineFactory {
    static func makePaneHost(frame: NSRect) -> TerminalPaneHost {
        MainActor.assumeIsolated {
            CmdyTerminalSurface(frame: frame)
        }
    }

    static func makeHeadlessSurface(frame: NSRect) -> TerminalPaneHost {
        MainActor.assumeIsolated {
            CmdyTerminalSurface(frame: frame)
        }
    }
}
