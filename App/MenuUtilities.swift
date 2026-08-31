import AppKit

extension NSMenu {
    /// Find a dynamic menu regardless of whether it lives directly in the menu
    /// bar or inside Tools. This keeps background refreshes independent of the
    /// presentation hierarchy.
    func cmdyDescendantMenu(titled title: String) -> NSMenu? {
        if self.title == title { return self }
        for item in items {
            if let found = item.submenu?.cmdyDescendantMenu(titled: title) {
                return found
            }
        }
        return nil
    }

    /// Apply the same native SF Symbol treatment to static and dynamic menus.
    /// Existing custom images win; informational rows and separators stay quiet.
    @MainActor
    func cmdyApplyIconsRecursively() {
        for item in items {
            item.cmdyApplyMenuIcon()
            item.submenu?.cmdyApplyIconsRecursively()
        }
    }
}

extension NSMenuItem {
    @MainActor
    func cmdyApplyMenuIcon() {
        guard !isSeparatorItem,
              image == nil,
              !title.isEmpty,
              menu !== NSApp.mainMenu,
              action != nil || submenu != nil else { return }

        let symbol = CmdyMenuIconInstaller.symbolName(
            title: title,
            action: action,
            menuTitle: menu?.title)
        guard let base = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title)
            ?? NSImage(
                systemSymbolName: "command",
                accessibilityDescription: title)
        else { return }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .regular)
        image = base.withSymbolConfiguration(configuration) ?? base
        image?.isTemplate = true
    }
}

/// Menus such as Workspaces, Blocks, Channels, and Extensions rebuild while
/// the app is running. One observer ensures their new commands get icons too.
@MainActor
final class CmdyMenuIconInstaller: NSObject {
    static let shared = CmdyMenuIconInstaller()

    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidChange(_:)),
            name: NSMenu.didAddItemNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidChange(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil)
    }

    @objc private func menuDidChange(_ notification: Notification) {
        (notification.object as? NSMenu)?.cmdyApplyIconsRecursively()
    }

    fileprivate static func symbolName(
        title rawTitle: String,
        action: Selector?,
        menuTitle rawMenuTitle: String?
    ) -> String {
        let title = normalized(rawTitle)
        let menuTitle = normalized(rawMenuTitle ?? "")
        let selector = action.map(NSStringFromSelector)?.lowercased() ?? ""

        switch menuTitle {
        case "theme": return "paintpalette"
        case "shader": return "wand.and.stars"
        case "font": return "textformat"
        case "cursor", "glide speed", "glide distance": return "cursorarrow.rays"
        case "text size":
            if title == "increase" { return "plus.magnifyingglass" }
            if title == "decrease" { return "minus.magnifyingglass" }
            return "textformat.size"
        case "line spacing": return "text.line.first.and.arrowtriangle.forward"
        case "window inset": return "arrow.down.right.and.arrow.up.left"
        case "window opacity": return "circle.lefthalf.filled"
        case "scroll speed": return "speedometer"
        case "keybindings": return "keyboard"
        case "merge with": return "macwindow.on.rectangle"
        default: break
        }

        let rules: [(String, String)] = [
            ("about ", "info.circle"),
            ("licenses and notices", "doc.text"),
            ("check for updates", "arrow.triangle.2.circlepath"),
            ("settings", "gearshape"),
            ("reload config", "arrow.clockwise"),
            ("hide ", "eye.slash"),
            ("quit ", "power"),
            ("new window", "macwindow.badge.plus"),
            ("new tab", "plus.rectangle.on.rectangle"),
            ("new text file", "doc.badge.plus"),
            ("open in terminal split", "rectangle.split.1x2"),
            ("open", "folder"),
            ("save workspace as", "square.grid.2x2.fill"),
            ("update current workspace", "arrow.clockwise.circle"),
            ("save as", "square.and.arrow.down.on.square"),
            ("save", "square.and.arrow.down"),
            ("workspaces", "square.grid.2x2"),
            ("panes", "rectangle.split.1x2"),
            ("split right", "rectangle.split.1x2"),
            ("split down", "rectangle.split.2x1"),
            ("focus next", "chevron.right"),
            ("focus previous", "chevron.left"),
            ("break into window", "macwindow"),
            ("break into tab", "square.on.square"),
            ("beam", "paperplane"),
            ("selected text", "text.quote"),
            ("screenshot", "camera"),
            ("attach or detach", "arrow.left.arrow.right"),
            ("close", "xmark"),
            ("undo", "arrow.uturn.backward"),
            ("redo", "arrow.uturn.forward"),
            ("cut", "scissors"),
            ("copy", "doc.on.doc"),
            ("paste", "doc.on.clipboard"),
            ("select all", "selection.pin.in.out"),
            ("find previous", "arrow.up.magnifyingglass"),
            ("find next", "arrow.down.magnifyingglass"),
            ("find", "magnifyingglass"),
            ("clear buffer", "eraser"),
            ("show tab sidebar", "sidebar.left"),
            ("show inspector", "sidebar.right"),
            ("show browser", "globe"),
            ("focus mode", "scope"),
            ("jump to attention", "bell.badge"),
            ("text size", "textformat.size"),
            ("appearance", "paintpalette"),
            ("config mixer", "slider.horizontal.3"),
            ("theme", "paintpalette"),
            ("cursor", "cursorarrow.rays"),
            ("font", "textformat"),
            ("shader", "wand.and.stars"),
            ("line spacing", "text.line.first.and.arrowtriangle.forward"),
            ("window inset", "arrow.down.right.and.arrow.up.left"),
            ("window opacity", "circle.lefthalf.filled"),
            ("blur background", "drop.halffull"),
            ("terminal", "terminal"),
            ("option as meta", "option"),
            ("shell integration", "point.3.connected.trianglepath.dotted"),
            ("automatic error help", "cross.case"),
            ("clean prompt", "text.badge.checkmark"),
            ("boot banner", "flag"),
            ("scroll speed", "speedometer"),
            ("window chrome", "macwindow"),
            ("hide window buttons", "button.horizontal.top.press"),
            ("customize toolbar", "slider.horizontal.3"),
            ("command palette", "command"),
            ("keybindings", "keyboard"),
            ("import from", "square.and.arrow.down"),
            ("reset imported", "trash"),
            ("blocks", "square.stack.3d.up"),
            ("previous command", "arrow.up"),
            ("next command", "arrow.down"),
            ("copy last command output", "doc.on.doc"),
            ("explain last command", "text.bubble"),
            ("compose command", "sparkles"),
            ("fix last failed command", "wrench.and.screwdriver"),
            ("agent mode", "person.crop.circle.badge.checkmark"),
            ("actions", "bolt"),
            ("channels", "tray.full"),
            ("extensions", "puzzlepiece.extension"),
            ("browse the marketplace", "storefront"),
            ("minimize", "minus"),
            ("zoom", "plus.magnifyingglass"),
            ("window grid", "rectangle.split.2x2"),
            ("break splits into grid windows", "square.grid.2x2"),
            ("combine grid windows into splits", "rectangle.split.1x2"),
            ("merge with", "macwindow.on.rectangle"),
            ("merge all windows into tabs", "square.on.square"),
            ("merge all windows into splits", "rectangle.split.1x2"),
            ("float on top", "pin"),
        ]
        if let match = rules.first(where: { title.hasPrefix($0.0) }) {
            return match.1
        }
        if selector.contains("delete") || selector.contains("remove") {
            return "trash"
        }
        if selector.contains("refresh") || selector.contains("reload") {
            return "arrow.clockwise"
        }
        if selector.contains("toggle") {
            return "switch.2"
        }
        return action == nil ? "list.bullet" : "command"
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
