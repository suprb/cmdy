import AppKit
import CmdyKit

/// The pane-host construction seam shared by production windows and tests.
enum TerminalEngineFactory {
    static func makePaneHost(frame: NSRect, adopting model: TerminalModel? = nil) -> TerminalPaneHost {
        MainActor.assumeIsolated {
            CmdyTerminalSurface.adoptedModelForNextInit = .init(model: model)
            defer { precondition(CmdyTerminalSurface.adoptedModelForNextInit.take() == nil) }
            return CmdyTerminalSurface(frame: frame)
        }
    }

    static func makeHeadlessSurface(frame: NSRect) -> TerminalPaneHost {
        MainActor.assumeIsolated {
            CmdyTerminalSurface(frame: frame)
        }
    }
}
