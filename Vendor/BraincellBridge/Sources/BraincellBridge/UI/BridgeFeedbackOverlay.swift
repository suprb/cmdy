import AppKit
import ApplicationServices

/// Target-agnostic semantic picker for Bridge's native and Simulator
/// bindings. It overlays the bound window, resolves the AX element beneath
/// the pointer, and captures a note plus accessibility identity and geometry.
@MainActor
final class BridgeFeedbackOverlay: NSObject {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private final class NoteView: NSTextView {
        var submit: (() -> Void)?
        var cancel: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancel?(); return }
            if (event.keyCode == 36 || event.keyCode == 76),
               !event.modifierFlags.contains(.shift) { submit?(); return }
            super.keyDown(with: event)
        }
    }

    private final class Editor: NSView {
        let summary = NSTextField(labelWithString: "")
        let note = NoteView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.065,
                                             blue: 0.06, alpha: 0.98).cgColor
            layer?.borderColor = NSColor(srgbRed: 0.49, green: 0.77,
                                         blue: 0.47, alpha: 1).cgColor
            layer?.borderWidth = 1
            layer?.cornerRadius = 4

            summary.frame = NSRect(x: 10, y: bounds.height - 27,
                                   width: bounds.width - 20, height: 17)
            summary.autoresizingMask = [.width, .minYMargin]
            summary.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            summary.textColor = .secondaryLabelColor
            summary.lineBreakMode = .byTruncatingMiddle
            addSubview(summary)

            let scroll = NSScrollView(frame: NSRect(x: 5, y: 27,
                                                    width: bounds.width - 10,
                                                    height: bounds.height - 57))
            scroll.autoresizingMask = [.width, .height]
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            note.frame = scroll.bounds
            note.autoresizingMask = [.width]
            note.isVerticallyResizable = true
            note.isHorizontallyResizable = false
            note.textContainer?.widthTracksTextView = true
            note.drawsBackground = false
            note.isRichText = false
            note.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            note.textColor = NSColor(white: 0.92, alpha: 1)
            note.insertionPointColor = NSColor(white: 0.92, alpha: 1)
            note.isAutomaticQuoteSubstitutionEnabled = false
            note.isAutomaticDashSubstitutionEnabled = false
            note.isAutomaticTextReplacementEnabled = false
            scroll.documentView = note
            addSubview(scroll)

            let footer = NSTextField(
                labelWithString: "return send  ·  shift+return newline  ·  esc cancel"
            )
            footer.frame = NSRect(x: 10, y: 7, width: bounds.width - 20, height: 14)
            footer.autoresizingMask = [.width, .maxYMargin]
            footer.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            footer.textColor = NSColor(white: 0.54, alpha: 1)
            addSubview(footer)
        }

        required init?(coder: NSCoder) { fatalError("not supported") }
    }

    private final class Canvas: NSView {
        var highlight: NSRect?
        var elementHighlights: [NSRect] = []
        var label = ""
        var locked = false
        var moved: ((NSPoint) -> Void)?
        var selected: ((NSRect?) -> Void)?
        var cancelled: (() -> Void)?
        private var tracking: NSTrackingArea?
        private var dragStart: NSPoint?
        private var dragged = false

        override var acceptsFirstResponder: Bool { true }
        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self)
            if let tracking { addTrackingArea(tracking) }
            super.updateTrackingAreas()
        }
        override func mouseMoved(with event: NSEvent) {
            if !locked { moved?(convert(event.locationInWindow, from: nil)) }
        }
        override func mouseDown(with event: NSEvent) {
            guard !locked else { return }
            let point = convert(event.locationInWindow, from: nil)
            dragStart = point
            dragged = false
            moved?(point)
        }
        override func mouseDragged(with event: NSEvent) {
            guard !locked, let start = dragStart else { return }
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) > 5 { dragged = true }
            guard dragged else { return }
            highlight = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(point.x - start.x), height: abs(point.y - start.y))
            elementHighlights = []
            label = "selecting region"
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            guard !locked, let start = dragStart else { return }
            let point = convert(event.locationInWindow, from: nil)
            dragStart = nil
            if dragged {
                selected?(NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                 width: abs(point.x - start.x), height: abs(point.y - start.y)))
            } else {
                moved?(point)
                selected?(nil)
            }
            dragged = false
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancelled?() } else { super.keyDown(with: event) }
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let highlight else { return }
            NSColor(srgbRed: 0.49, green: 0.77, blue: 0.47, alpha: 0.10).setFill()
            highlight.fill()
            NSColor(srgbRed: 0.49, green: 0.77, blue: 0.47, alpha: 1).setStroke()
            let border = NSBezierPath(rect: highlight.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
            for rect in elementHighlights {
                let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                path.lineWidth = 1
                path.stroke()
            }

            guard !label.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor(white: 0.92, alpha: 1),
                .backgroundColor: NSColor(srgbRed: 0.055, green: 0.065,
                                          blue: 0.06, alpha: 0.96),
            ]
            let value = NSAttributedString(string: " \(label) ", attributes: attrs)
            var point = NSPoint(x: highlight.minX, y: highlight.maxY + 4)
            let size = value.size()
            if point.y + size.height > bounds.maxY { point.y = max(2, highlight.minY - size.height - 4) }
            point.x = min(max(2, point.x), max(2, bounds.maxX - size.width - 2))
            value.draw(at: point)
        }
    }

    private var panel: Panel?
    private var canvas: Canvas?
    private var editor: Editor?
    private var pid: pid_t = 0
    private var targetFrame = CGRect.zero
    private var point = CGPoint.zero
    private var element: AXUIElement?
    private var selectedElements: [AXUIElement] = []
    private var selectedRegion: CGRect?
    private var targetContext: [String: Any] = [:]
    private var completion: (([String: Any]) -> Void)?

    func begin(pid: pid_t, frame: CGRect, targetContext: [String: Any],
               completion: @escaping ([String: Any]) -> Void) {
        close()
        guard frame.width > 20, frame.height > 20,
              let primary = NSScreen.screens.first else { return }
        self.pid = pid
        self.targetFrame = frame
        self.targetContext = targetContext
        self.completion = completion

        let appKitFrame = NSRect(x: frame.minX,
                                 y: primary.frame.height - frame.maxY,
                                 width: frame.width, height: frame.height)
        let panel = Panel(contentRect: appKitFrame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.acceptsMouseMovedEvents = true

        let canvas = Canvas(frame: NSRect(origin: .zero, size: appKitFrame.size))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.clear.cgColor
        canvas.moved = { [weak self] in self?.update(at: $0) }
        canvas.selected = { [weak self] region in self?.select(region: region) }
        canvas.cancelled = { [weak self] in self?.close() }
        panel.contentView = canvas
        self.panel = panel
        self.canvas = canvas

        NSRunningApplication.current.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(canvas)
    }

    private func update(at local: NSPoint) {
        point = CGPoint(x: targetFrame.minX + local.x,
                        y: targetFrame.maxY - local.y)
        let app = AXUIElementCreateApplication(pid)
        var ref: AXUIElement?
        element = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &ref) == .success
            ? ref : nil

        guard let element, let frame = Self.frame(of: element) else {
            canvas?.highlight = NSRect(x: local.x - 12, y: local.y - 12, width: 24, height: 24)
            canvas?.label = "target region"
            canvas?.needsDisplay = true
            return
        }
        let localFrame = NSRect(x: frame.minX - targetFrame.minX,
                                y: targetFrame.maxY - frame.maxY,
                                width: frame.width, height: frame.height)
        canvas?.highlight = localFrame.intersection(canvas?.bounds ?? localFrame)
        canvas?.label = [Self.string(element, kAXRoleAttribute),
                         Self.string(element, kAXTitleAttribute),
                         Self.string(element, kAXValueAttribute)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        canvas?.needsDisplay = true
    }

    private func select(region: NSRect?) {
        guard let panel, let canvas else { return }
        canvas.locked = true
        if let region {
            let global = CGRect(x: targetFrame.minX + region.minX,
                                y: targetFrame.maxY - region.maxY,
                                width: region.width, height: region.height)
            selectedRegion = global
            selectedElements = Self.elements(pid: pid, intersecting: global)
            element = selectedElements.first
            point = CGPoint(x: global.midX, y: global.midY)
            canvas.highlight = region
            canvas.elementHighlights = selectedElements.compactMap(Self.frame(of:)).map {
                NSRect(x: $0.minX - targetFrame.minX,
                       y: targetFrame.maxY - $0.maxY,
                       width: $0.width, height: $0.height).intersection(canvas.bounds)
            }.filter { !$0.isEmpty }
            canvas.label = "\(selectedElements.count) accessibility element\(selectedElements.count == 1 ? "" : "s")"
            canvas.needsDisplay = true
        } else {
            selectedRegion = nil
            selectedElements = element.map { [$0] } ?? []
        }
        let editorWidth = min(CGFloat(420), max(280, canvas.bounds.width - 24))
        let editorHeight: CGFloat = 150
        let selected = canvas.highlight ?? NSRect(x: point.x - targetFrame.minX,
                                                  y: targetFrame.maxY - point.y,
                                                  width: 1, height: 1)
        var x = min(max(12, selected.minX), max(12, canvas.bounds.width - editorWidth - 12))
        var y = selected.minY - editorHeight - 10
        if y < 12 { y = min(canvas.bounds.height - editorHeight - 12, selected.maxY + 10) }
        x = max(12, x); y = max(12, y)
        let editor = Editor(frame: NSRect(x: x, y: y, width: editorWidth, height: editorHeight))
        if selectedRegion != nil {
            editor.summary.stringValue = "region  ·  \(selectedElements.count) selected element\(selectedElements.count == 1 ? "" : "s")"
        } else {
            editor.summary.stringValue = Self.summary(for: element) ?? "target region"
        }
        editor.note.submit = { [weak self] in self?.submit() }
        editor.note.cancel = { [weak self] in self?.close() }
        canvas.addSubview(editor)
        self.editor = editor
        panel.makeFirstResponder(editor.note)
    }

    private func submit() {
        guard let comment = editor?.note.string.trimmingCharacters(in: .whitespacesAndNewlines),
              !comment.isEmpty else { NSSound.beep(); return }
        var context = targetContext
        context["point"] = ["x": point.x, "y": point.y]
        context["windowBounds"] = ["x": targetFrame.minX, "y": targetFrame.minY,
                                   "width": targetFrame.width, "height": targetFrame.height]
        if let selectedRegion {
            context["selectionType"] = "region"
            context["element"] = "AXRegion"
            context["label"] = "\(selectedElements.count) accessibility elements"
            context["elementCount"] = selectedElements.count
            context["bounds"] = ["x": selectedRegion.minX, "y": selectedRegion.minY,
                                 "width": selectedRegion.width, "height": selectedRegion.height]
            context["elementPath"] = selectedElements.map(Self.path(of:))
            context["elements"] = selectedElements.map { item -> [String: Any] in
                var value = Self.attributes(of: item)
                value["elementPath"] = Self.path(of: item)
                if let frame = Self.frame(of: item) {
                    value["bounds"] = ["x": frame.minX, "y": frame.minY,
                                       "width": frame.width, "height": frame.height]
                }
                return value
            }
        } else if let element {
            context["selectionType"] = "element"
            context["elementPath"] = Self.path(of: element)
            context["accessibility"] = Self.attributes(of: element)
            if let frame = Self.frame(of: element) {
                context["bounds"] = ["x": frame.minX, "y": frame.minY,
                                     "width": frame.width, "height": frame.height]
            }
        } else {
            context["elementPath"] = "region@\(Int(point.x)),\(Int(point.y))"
        }
        completion?(["source": "bridge", "comment": comment, "context": context,
                     "intent": "change", "severity": "normal", "status": "open"])
        close()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil; canvas = nil; editor = nil; element = nil
        selectedElements = []; selectedRegion = nil; completion = nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        if let string = ref as? String { return string }
        if let number = ref as? NSNumber { return number.stringValue }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        AXSafety.frame(of: element)
    }

    private static func summary(for element: AXUIElement?) -> String? {
        guard let element else { return nil }
        return [string(element, kAXRoleAttribute), string(element, kAXIdentifierAttribute),
                string(element, kAXTitleAttribute), string(element, kAXValueAttribute)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func attributes(of element: AXUIElement) -> [String: Any] {
        var result: [String: Any] = [:]
        for (name, key) in [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute),
                            ("identifier", kAXIdentifierAttribute), ("title", kAXTitleAttribute),
                            ("value", kAXValueAttribute), ("description", kAXDescriptionAttribute),
                            ("help", kAXHelpAttribute)] {
            if let value = string(element, key) { result[name] = value }
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func elements(pid: pid_t, intersecting region: CGRect) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        let interesting: Set<String> = [
            "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXSlider", "AXLink",
            "AXStaticText", "AXImage", "AXTabGroup", "AXSegmentedControl",
        ]
        var result: [AXUIElement] = []
        var visited = 0
        func walk(_ item: AXUIElement, depth: Int) {
            guard depth <= 16, result.count < 80, visited < 20_000 else { return }
            visited += 1
            let descendants = children(of: item)
            if let itemFrame = frame(of: item), !itemFrame.isEmpty,
               itemFrame.intersects(region),
               interesting.contains(string(item, kAXRoleAttribute) ?? "") || descendants.isEmpty {
                result.append(item)
            }
            for child in descendants { walk(child, depth: depth + 1) }
        }
        walk(app, depth: 0)
        return result
    }

    private static func path(of element: AXUIElement) -> String {
        var segments: [String] = []
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 12 {
            let role = string(node, kAXRoleAttribute) ?? "AXElement"
            let identity = string(node, kAXIdentifierAttribute)
                ?? string(node, kAXTitleAttribute)
                ?? string(node, kAXValueAttribute)
            segments.insert(identity.map { "\(role)[\($0.prefix(80))]" } ?? role, at: 0)
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let next = AXSafety.element(parent) else { break }
            current = next
            depth += 1
        }
        return segments.joined(separator: " > ")
    }
}
