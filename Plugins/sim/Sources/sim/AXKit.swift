import AppKit
import ApplicationServices

// AXKit — the Accessibility layer: adopt a foreign app's window (move/size),
// and treat its UI hierarchy as a DOM (serialize, find, press, fill).
// Everything here needs the one-time Accessibility grant for the appdock
// binary; AXKit.trusted(prompt:) drives the system prompt.

enum AXKit {

    static func trusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Windows

    /// The frontmost standard window element of a pid.
    static func mainWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success,
           let window = element(value) {
            return window
        }
        // Fall back to the first window (apps mid-launch may lack a main yet).
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let list = value as? [AXUIElement], let first = list.first {
            return first
        }
        return nil
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue = axValue(posValue, type: .cgPoint),
              let sizeValue = axValue(sizeValue, type: .cgSize)
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue, .cgSize, &size),
              pos.x.isFinite, pos.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              abs(pos.x) <= 1_000_000, abs(pos.y) <= 1_000_000,
              size.width > 0, size.height > 0,
              size.width <= 1_000_000, size.height <= 1_000_000 else { return nil }
        return CGRect(origin: pos, size: size)   // CG coords: top-left origin
    }

    /// Move+resize a window (CG top-left coordinates).
    @discardableResult
    static func setFrame(_ window: AXUIElement, _ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              abs(rect.origin.x) <= 1_000_000, abs(rect.origin.y) <= 1_000_000,
              rect.width > 0, rect.height > 0,
              rect.width <= 1_000_000, rect.height <= 1_000_000 else { return false }
        var pos = rect.origin
        var size = rect.size
        guard let posValue = AXValueCreate(.cgPoint, &pos),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let a = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        let b = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return a == .success && b == .success
    }

    /// Move without touching size. Simulator rejects arbitrary size writes
    /// and may re-anchor its window even when the requested size is unchanged.
    @discardableResult
    static func setPosition(_ window: AXUIElement, _ position: CGPoint) -> Bool {
        guard position.x.isFinite, position.y.isFinite,
              abs(position.x) <= 1_000_000, abs(position.y) <= 1_000_000 else {
            return false
        }
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Click a menu item outright. (Simulator only honors its Window-size
    /// presets while frontmost — callers activate the app first.)
    @discardableResult
    static func clickMenuItem(pid: pid_t, menuTitle: String, itemTitle: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = element(attribute(app, kAXMenuBarAttribute as String)) else {
            return false
        }
        guard let menuBarItem = children(of: bar).first(where: {
            (attribute($0, kAXTitleAttribute as String) as? String) == menuTitle
        }), let menu = children(of: menuBarItem).first,
        let item = children(of: menu).first(where: {
            (attribute($0, kAXTitleAttribute as String) as? String) == itemTitle
        }) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Whether a menu item currently carries a checkmark. Simulator uses this
    /// to expose the active Window size preset.
    static func menuItemIsMarked(pid: pid_t, menuTitle: String, itemTitle: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = element(attribute(app, kAXMenuBarAttribute as String)),
              let menuBarItem = children(of: bar).first(where: {
                  (attribute($0, kAXTitleAttribute as String) as? String) == menuTitle
              }),
              let menu = children(of: menuBarItem).first,
              let item = children(of: menu).first(where: {
                  (attribute($0, kAXTitleAttribute as String) as? String) == itemTitle
              }) else { return false }
        let mark = attribute(item, kAXMenuItemMarkCharAttribute as String) as? String ?? ""
        return !mark.isEmpty
    }

    /// Set a checkmark menu item to a desired state (e.g. the Simulator's
    /// "Stay On Top" so its window floats above cmdy, like the browser
    /// sidecar). Path: menu-bar item `menuTitle` → its menu → item `itemTitle`.
    static func setMenuChecked(pid: pid_t, menuTitle: String, itemTitle: String, checked: Bool) {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = element(attribute(app, kAXMenuBarAttribute as String)) else {
            return
        }
        let barItems = children(of: bar)
        guard let menuBarItem = barItems.first(where: {
            (attribute($0, kAXTitleAttribute as String) as? String) == menuTitle
        }) else { return }
        let menus = children(of: menuBarItem)
        guard let menu = menus.first else { return }
        guard let item = children(of: menu).first(where: {
            (attribute($0, kAXTitleAttribute as String) as? String) == itemTitle
        }) else { return }
        let mark = attribute(item, kAXMenuItemMarkCharAttribute as String) as? String ?? ""
        let isChecked = !mark.isEmpty
        if isChecked != checked {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }

    // MARK: - Tree

    /// One serialized node. `path` is the index path from the window ("0.2.1")
    /// — stable enough between a read and the following action; agents re-read
    /// after mutations.
    struct Node {
        let path: String
        let role: String
        let title: String
        let value: String
        let identifier: String
        let subrole: String
        let enabled: Bool
        let frame: CGRect

        var dictionary: [String: Any] {
            var d: [String: Any] = ["path": path, "role": role, "enabled": enabled,
                                    "frame": ["x": Int(frame.origin.x), "y": Int(frame.origin.y),
                                              "w": Int(frame.width), "h": Int(frame.height)]]
            if !title.isEmpty { d["title"] = title }
            if !value.isEmpty { d["value"] = value }
            if !identifier.isEmpty { d["identifier"] = identifier }
            if !subrole.isEmpty { d["subrole"] = subrole }
            return d
        }
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private static func axValue(_ ref: CFTypeRef?, type: AXValueType) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(ref, to: AXValue.self)
        return AXValueGetType(value) == type ? value : nil
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String {
        (attribute(el, name) as? String) ?? ""
    }

    static func children(of el: AXUIElement) -> [AXUIElement] {
        (attribute(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    static func node(for el: AXUIElement, path: String) -> Node {
        var enabled = true
        if let v = attribute(el, kAXEnabledAttribute as String) as? Bool { enabled = v }
        var value = ""
        if let raw = attribute(el, kAXValueAttribute as String) {
            if let s = raw as? String { value = s }
            else if let n = raw as? NSNumber { value = n.stringValue }
        }
        var frame = CGRect.zero
        if let posValue = attribute(el, kAXPositionAttribute as String),
           let sizeValue = attribute(el, kAXSizeAttribute as String),
           let position = axValue(posValue, type: .cgPoint),
           let dimensions = axValue(sizeValue, type: .cgSize) {
            var p = CGPoint.zero, s = CGSize.zero
            if AXValueGetValue(position, .cgPoint, &p),
               AXValueGetValue(dimensions, .cgSize, &s),
               p.x.isFinite, p.y.isFinite,
               s.width.isFinite, s.height.isFinite,
               abs(p.x) <= 1_000_000, abs(p.y) <= 1_000_000,
               s.width >= 0, s.height >= 0,
               s.width <= 1_000_000, s.height <= 1_000_000 {
                frame = CGRect(origin: p, size: s)
            }
        }
        let title = [string(el, kAXTitleAttribute as String),
                     string(el, kAXDescriptionAttribute as String),
                     string(el, kAXPlaceholderValueAttribute as String)]
            .first { !$0.isEmpty } ?? ""
        return Node(path: path, role: string(el, kAXRoleAttribute as String),
                    title: title, value: value,
                    identifier: string(el, kAXIdentifierAttribute as String),
                    subrole: string(el, kAXSubroleAttribute as String),
                    enabled: enabled, frame: frame)
    }

    /// Depth-first serialization. `interactiveOnly` keeps the rows an agent
    /// acts on (buttons, fields, checkboxes…) plus static text for context.
    static func tree(window: AXUIElement, maxDepth: Int, interactiveOnly: Bool) -> [Node] {
        var out: [Node] = []
        let depthLimit = min(max(maxDepth, 0), 64)
        let nodeLimit = 10_000
        var visited = 0
        let interesting: Set<String> = [
            "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXSlider", "AXIncrementor",
            "AXLink", "AXStaticText", "AXMenuItem", "AXTabGroup", "AXSegmentedControl",
        ]
        func walk(_ el: AXUIElement, _ path: String, _ depth: Int) {
            guard depth <= depthLimit, visited < nodeLimit else { return }
            visited += 1
            let n = node(for: el, path: path)
            if !interactiveOnly || interesting.contains(n.role) || path.isEmpty {
                out.append(n)
            }
            for (i, child) in children(of: el).prefix(nodeLimit).enumerated() {
                guard visited < nodeLimit else { break }
                walk(child, path.isEmpty ? "\(i)" : "\(path).\(i)", depth + 1)
            }
        }
        walk(window, "", 0)
        return out
    }

    /// Resolve an index path back to a live element.
    static func element(in window: AXUIElement, path: String) -> AXUIElement? {
        if path.isEmpty { return window }
        var el = window
        for part in path.split(separator: ".") {
            guard let i = Int(part) else { return nil }
            let kids = children(of: el)
            guard i >= 0, i < kids.count else { return nil }
            el = kids[i]
        }
        return el
    }

    /// Resolve the deepest accessibility element under a global CG point.
    /// This stays scoped to the Simulator process, so Cmdy's transparent
    /// picker window cannot accidentally select itself.
    static func element(pid: pid_t, at point: CGPoint) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success
        else { return nil }
        return element
    }

    /// Find an element's index path in a known window. AX elements are CF
    /// objects, so CFEqual is the reliable identity test across API calls.
    static func path(in window: AXUIElement, to target: AXUIElement,
                     maxDepth: Int = 16) -> String? {
        let depthLimit = min(max(maxDepth, 0), 64)
        var visited = 0
        func walk(_ element: AXUIElement, _ path: String, _ depth: Int) -> String? {
            guard visited < 20_000 else { return nil }
            visited += 1
            if CFEqual(element, target) { return path }
            guard depth < depthLimit else { return nil }
            for (index, child) in children(of: element).prefix(20_000).enumerated() {
                guard visited < 20_000 else { break }
                let childPath = path.isEmpty ? "\(index)" : "\(path).\(index)"
                if let found = walk(child, childPath, depth + 1) { return found }
            }
            return nil
        }
        return walk(window, "", 0)
    }

    // MARK: - Actions

    @discardableResult
    static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    /// Set a text value directly when the element allows it; otherwise focus
    /// and type via key events (caller handles the CGEvent path).
    @discardableResult
    static func setValue(_ el: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    @discardableResult
    static func focus(_ el: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, true as CFTypeRef) == .success
    }
}
