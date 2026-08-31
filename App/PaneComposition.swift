import AppKit
import CmdyKit

enum PaneCompositionError: LocalizedError {
    case invalidSelection
    case missingPane(String)
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "Choose at least two different panes to combine"
        case .missingPane(let id):
            return "Pane \(id) is no longer available"
        case .moveFailed(let id):
            return "Pane \(id) could not be moved"
        }
    }
}

extension AppDelegate {
    /// Gather selected live panes into a new window. The exact TerminalPane
    /// objects move; no process restarts, scrollback copies, or fake tabs are
    /// involved. First-row panes form columns and later panes fill rows below
    /// them, producing a compact grid instead of one unusably thin strip.
    func composePanes(ids: [String]) throws -> [String: Any] {
        let uniqueIDs = ids.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard uniqueIDs.count == ids.count, (2...64).contains(uniqueIDs.count) else {
            throw PaneCompositionError.invalidSelection
        }

        var resolved: [(controller: TerminalWindowController, pane: TerminalPane)] = []
        for id in uniqueIDs {
            guard let pair = allControllers.lazy.compactMap({ controller in
                controller.panes.first(where: { $0.paneId == id }).map {
                    (controller: controller, pane: $0)
                }
            }).first else {
                throw PaneCompositionError.missingPane(id)
            }
            resolved.append(pair)
        }

        // Resolve the whole request before the first mutation. From here each
        // release is deterministic because pane IDs and controller ownership
        // are main-thread-owned.
        let destinationAppearance = resolved.first?.controller.tabAppearanceSnapshot
        var moved: [TerminalPane] = []
        var donors: [TerminalWindowController] = []
        for pair in resolved {
            guard let pane = pair.controller.releasePaneForMove(pair.pane.paneId) else {
                // This should be unreachable on the main thread. Put anything
                // already released back into its original controller so a
                // failed request cannot strand live views.
                for (index, released) in moved.enumerated() {
                    resolved[index].controller.adopt(released)
                }
                throw PaneCompositionError.moveFailed(pair.pane.paneId)
            }
            moved.append(pane)
            if !donors.contains(where: { $0 === pair.controller }) {
                donors.append(pair.controller)
            }
        }

        let destination = TerminalWindowController(
            adopting: moved[0], appearance: destinationAppearance)
        let columns = max(2, Int(ceil(sqrt(Double(moved.count)))))
        var topRow = [moved[0]]
        if moved.count > 1 {
            for index in 1..<moved.count {
                let pane = moved[index]
                if index < columns {
                    let target = topRow.last
                    destination.adopt(pane, nextTo: target, vertical: true)
                    topRow.append(pane)
                } else {
                    let target = topRow[index % columns]
                    destination.adopt(pane, nextTo: target, vertical: false)
                }
            }
        }
        adopt(controller: destination)
        destination.showWindow(nil)
        destination.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        for donor in donors where donor.isEmptyAfterPaneMove {
            donor.window?.close()
        }
        PluginManager.shared.scheduleProjectExtensionReconcile()
        let paneIDs = destination.panes.map(\.paneId)
        PluginManager.shared.emit("panes-composed", [
            "panes": paneIDs,
            "window": destination.window?.windowNumber ?? 0,
        ])
        return [
            "ok": true,
            "panes": paneIDs,
            "count": paneIDs.count,
            "window": destination.window?.windowNumber ?? 0,
        ]
    }
}
