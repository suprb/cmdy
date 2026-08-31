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

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
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
        let enabled: Bool
        let frame: CGRect

        var dictionary: [String: Any] {
            var d: [String: Any] = ["path": path, "role": role, "enabled": enabled,
                                    "frame": ["x": Int(frame.origin.x), "y": Int(frame.origin.y),
                                              "w": Int(frame.width), "h": Int(frame.height)]]
            if !title.isEmpty { d["title"] = title }
            if !value.isEmpty { d["value"] = value }
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
                    title: title, value: value, enabled: enabled, frame: frame)
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
