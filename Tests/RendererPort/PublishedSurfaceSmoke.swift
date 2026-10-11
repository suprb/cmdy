import AppKit
@_spi(CmdyApp) import CmdyGPU

/// Separate headless entry point. Does not run the app CLI, launch a PTY,
/// create a window, post input, initialize app services or read the clipboard.
@main private struct PublishedSurfaceSmoke {
    @MainActor static func main() async throws {
        let surface = CmdyTerminalSurface(frame: .init(x: 0, y: 0, width: 420, height: 180))
        try surface.setUseMetal(true)
        precondition(surface.isUsingMetalRenderer && surface.view.window == nil && surface.shellPid <= 0)
        let renderer = surface.metalRenderer!
        @MainActor func change(_ label: String, _ mutation: () -> Void) {
            let before = surface.frameContentRevision
            mutation()
            precondition(surface.frameContentRevision != before, label)
        }
        let initial = surface.frameContentRevision
        _ = surface.captureGrid(); _ = surface.captureGrid()
        precondition(initial != 0 && surface.frameContentRevision == initial)
        surface.activityKeypressTime = 5; surface.activityTypingRate = 7
        precondition(surface.frameContentRevision == initial)

        // Direct model publication exercises the renderer-active path, which
        // does not call the surface's queueDisplay method.
        surface.terminal.feed(text: "alpha")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while surface.renderSnapshot.grid.cursorCol != 5 {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Model publication did not arrive")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(surface.frameContentRevision != initial)
        let row = surface.renderSnapshot.grid.displayTopRow
        change("selection via active renderer") {
            surface.setSelectionForTesting(anchor: .init(row: row, col: 0), active: .init(row: row, col: 3))
        }
        let selected = surface.frameContentRevision
        surface.setSelectionForTesting(anchor: .init(row: row, col: 0), active: .init(row: row, col: 3))
        precondition(surface.frameContentRevision == selected)
        change("selection clearing") { surface.clearSearch() }
        change("foreground") { surface.nativeForegroundColor = .red }
        change("background") { surface.nativeBackgroundColor = .blue }
        change("selection color") { surface.selectedTextBackgroundColor = .green }
        change("failed-block style") { surface.failedBlockRows = [row] }
        change("effective appearance") { surface.viewDidChangeEffectiveAppearance() }
        change("font") { surface.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular) }
        change("line height") { surface.lineHeightMultiplier = 1.2 }
        change("content inset") { surface.leftContentInset = 5 }
        change("rendering preset") { surface.textRenderingModeName = TextRenderingMode.crisp.rawValue }
        change("explicit invalidation") { surface.forceRedraw() }
        change("queued redraw") { surface.queueDisplay() }
        precondition(surface.view.window == nil && surface.shellPid <= 0)
        surface.terminate()
        await renderer.shutdown()
        print("Published surface: direct model publication, active-renderer selection, stable captures, scalar-only activity, appearance/font/geometry invalidation and clean shutdown PASS")
    }
}
