import AppKit

@MainActor
extension AppDelegate {
    func focusedSettingsContext() -> CmdyFocusedSettingsContext? {
        // Keep the inspected terminal while the Settings window owns focus.
        guard !(NSApp.keyWindow?.windowController is CmdySettingsWindowController),
              let controller = currentController,
              let pane = controller.focusedPane else { return nil }
        func overrides(_ appearance: TerminalTabAppearance) -> [String] {
            [appearance.themeName.map { "Theme: \($0)" },
             appearance.shaderName.map { "Shader: \($0)" },
             appearance.fontName.map { "Font: \($0)" }].compactMap { $0 }
        }
        let paneOverrides = overrides(pane.paneAppearance)
        let tabOverrides = overrides(controller.tabAppearanceSnapshot)
        return CmdyFocusedSettingsContext(
            title: controller.window?.title ?? "Current Terminal",
            paneOverrides: paneOverrides,
            tabOverrides: tabOverrides,
            resetPaneOverrides: paneOverrides.isEmpty ? nil : { [weak controller, weak pane] in
                guard let controller, let pane,
                      controller.panes.contains(where: { $0 === pane }) else { return }
                pane.restoreAppearance(TerminalTabAppearance())
                pane.onAppearanceChanged?(pane)
            },
            resetTabOverrides: tabOverrides.isEmpty ? nil : { [weak controller] in
                controller?.restoreTabAppearance(TerminalTabAppearance())
            },
            refreshOverrides: { [weak controller, weak pane] in
                guard let controller, let pane,
                      controller.panes.contains(where: { $0 === pane }) else { return nil }
                return (overrides(pane.paneAppearance), overrides(controller.tabAppearanceSnapshot))
            })
    }
}
