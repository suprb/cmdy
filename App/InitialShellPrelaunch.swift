import AppKit
import CmdyKit

/// Starts the first window's login shell while the menu bar, Dock helper and
/// first window are still being built, so the user's shell startup overlaps
/// app startup instead of following it. Only a plain launch that will open one
/// fresh window qualifies; its first pane adopts the running model and the
/// normal layout pass gives the shell its final size.
@MainActor
enum InitialShellPrelaunch {
    private static var model: TerminalModel?
    /// TerminalWindowController's initial content rectangle.
    static let initialContentSize = NSSize(width: 860, height: 540)
    /// Measured title/tool band above the first pane in a fresh window. The
    /// pane's top inset is the larger of this and the toolbar style's band.
    static let chromeHeight: CGFloat = 38

    static func startIfEligible(arguments: [String]) {
        guard model == nil, arguments.count == 1 else { return }
        let traceStarted = CmdyPerformanceTrace.now()
        ConfigFile.migrateLegacyDirectoriesIfNeeded()
        ConfigFile.applyIfPresent()
        let preferences = Preferences.shared
        if preferences.restoreSession,
           [SessionStore.url, SessionStore.previousURL].contains(where: {
               FileManager.default.fileExists(atPath: $0.path)
           }) { return }
        let grid = CmdyTerminalSurface.predictedGrid(
            contentSize: initialContentSize, font: preferences.resolvedFont(),
            lineHeight: preferences.lineHeight, margin: preferences.contentMargin,
            topInset: max(chromeHeight, NativeToolbarPreset.titleBandHeight(preferences.nativeToolbarStyle)),
            scale: NSScreen.main?.backingScaleFactor ?? 2)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let environment = ShellIntegration.makeEnvironment(
            shellPath: shell, integrationEnabled: preferences.shellIntegration,
            cleanPrompt: preferences.cleanPrompt)
        let started = TerminalModel(cols: grid.cols, rows: grid.rows)
        started.updatePixelSize(width: grid.pixelWidth, height: grid.pixelHeight)
        started.startProcess(executable: shell, args: ["-l"], environment: environment,
                             currentDirectory: nil)
        model = started
        CmdyPerformanceTrace.record(event: "startup.shell-prelaunch", started: traceStarted,
                                    fields: ["columns": grid.cols, "rows": grid.rows,
                                             "pixelWidth": grid.pixelWidth, "pixelHeight": grid.pixelHeight])
    }

    /// The first fresh pane takes the running shell; later calls get nil.
    static func take() -> TerminalModel? {
        defer { model = nil }
        return model
    }

    /// A launch path that did not adopt the shell (restore, tests) ends it.
    static func discard() {
        model?.terminate()
        model = nil
    }
}
