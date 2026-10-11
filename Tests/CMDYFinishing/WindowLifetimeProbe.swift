import AppKit

@MainActor private final class WeakWindow { weak var window: NSWindow?; init(_ window: NSWindow) { self.window = window } }
@main struct Probe {
    @MainActor private static func cycle(_ mode: String) async -> WeakWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        window.tabbingMode = .preferred; window.tabbingIdentifier = "test"
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "test"); window.toolbarStyle = .unifiedCompact
        let content = NSViewController(); content.view = NSView(frame: window.contentView!.bounds)
        window.contentViewController = content
        window.makeKeyAndOrderFront(nil)
        window.title = UUID().uuidString; window.subtitle = "test subtitle"
        // Accessing the native singleton group installs AppKit tab chrome.
        _ = window.tabGroup?.windows
        let ref = WeakWindow(window)
        try? await Task.sleep(for: .milliseconds(50))
        if mode == "ungroup" { window.tabGroup?.removeWindow(window) }
        if mode == "hidebar", window.tabGroup?.isTabBarVisible == true { window.toggleTabBar(nil) }
        window.close()
        if mode == "remove" { NSApp.removeWindowsItem(window) }
        if mode == "borderless" { window.toolbar = nil; window.styleMask = .borderless }
        window.contentViewController = nil; window.contentView = nil; controller.window = nil
        return ref
    }
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let menu = NSMenu(); let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windows = NSMenu(title: "Window"); item.submenu = windows; menu.addItem(item)
        app.mainMenu = menu; app.windowsMenu = windows
        Task { @MainActor in
            var result: [[String: Any]] = []
            for mode in ["menu", "ungroup", "hidebar", "borderless"] {
                var refs: [WeakWindow] = []
                let anchor = NSWindow(contentRect: NSRect(x: 650, y: 100, width: 500, height: 300),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                anchor.isReleasedWhenClosed = false; anchor.makeKeyAndOrderFront(nil)
                for _ in 0..<12 {
                    refs.append(await cycle(mode))
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .milliseconds(300))
                result.append(["mode": mode, "retained": refs.filter { $0.window != nil }.count])
                anchor.close()
            }
            print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
            exit(0)
        }
        app.run()
    }
}
