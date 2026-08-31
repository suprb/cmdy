import AppKit
import ApplicationServices

/// A native semantic picker for Simulator.app. It asks the Simulator process
/// for the AX element under the pointer, highlights that element, and submits
/// a structured note. When UIKit does not expose a deeper AX node, the exact
/// screen point and region remain useful context for the agent.
final class SimFeedbackOverlay: NSObject {
    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private final class NoteTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onCancel: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
            } else if (event.keyCode == 36 || event.keyCode == 76),
                      !event.modifierFlags.contains(.shift) {
                onSubmit?()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private final class NoteEditor: NSView {
        let summary = NSTextField(labelWithString: "")
        let text = NoteTextView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.065,
                                             blue: 0.06, alpha: 0.98).cgColor
            layer?.borderColor = NSColor(srgbRed: 0.48, green: 0.72,
                                         blue: 0.46, alpha: 1).cgColor
            layer?.borderWidth = 1
            layer?.cornerRadius = 4

            summary.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            summary.textColor = .secondaryLabelColor
            summary.lineBreakMode = .byTruncatingMiddle
            summary.frame = NSRect(x: 10, y: bounds.height - 27,
                                   width: bounds.width - 20, height: 17)
            summary.autoresizingMask = [.width, .minYMargin]
            addSubview(summary)

            let scroll = NSScrollView(frame: NSRect(x: 5, y: 28,
                                                    width: bounds.width - 10,
                                                    height: bounds.height - 58))
            scroll.autoresizingMask = [.width, .height]
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            text.frame = scroll.bounds
            text.minSize = .zero
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.drawsBackground = false
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.textColor = NSColor(white: 0.92, alpha: 1)
            text.insertionPointColor = NSColor(white: 0.92, alpha: 1)
            text.isRichText = false
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticTextReplacementEnabled = false
            scroll.documentView = text
            addSubview(scroll)

            let footer = NSTextField(labelWithString: "return send  ·  shift+return newline  ·  esc cancel")
            footer.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            footer.textColor = NSColor(white: 0.54, alpha: 1)
            footer.frame = NSRect(x: 10, y: 7, width: bounds.width - 20, height: 14)
            footer.autoresizingMask = [.width, .maxYMargin]
            addSubview(footer)
        }

        required init?(coder: NSCoder) { fatalError("not supported") }
    }

    private final class Canvas: NSView {
        var highlight: NSRect?
        var elementHighlights: [NSRect] = []
        var label = ""
        var selected = false
        var onMove: ((NSPoint) -> Void)?
        var onSelect: ((NSRect?) -> Void)?
        var onCancel: (() -> Void)?
        private var tracking: NSTrackingArea?
        private var dragStart: NSPoint?
        private var dragged = false

        override var acceptsFirstResponder: Bool { true }
        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
            super.updateTrackingAreas()
        }
        override func mouseMoved(with event: NSEvent) {
            guard !selected else { return }
            onMove?(convert(event.locationInWindow, from: nil))
        }
        override func mouseDown(with event: NSEvent) {
            guard !selected else { return }
            let point = convert(event.locationInWindow, from: nil)
            dragStart = point
            dragged = false
            onMove?(point)
        }
        override func mouseDragged(with event: NSEvent) {
            guard !selected, let start = dragStart else { return }
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
            guard !selected, let start = dragStart else { return }
            let point = convert(event.locationInWindow, from: nil)
            dragStart = nil
            if dragged {
                let region = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                    width: abs(point.x - start.x), height: abs(point.y - start.y))
                onSelect?(region)
            } else {
                onMove?(point)
                onSelect?(nil)
            }
            dragged = false
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let highlight else { return }
            NSColor(srgbRed: 0.49, green: 0.77, blue: 0.47, alpha: 0.10).setFill()
            NSBezierPath(rect: highlight).fill()
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
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor(white: 0.9, alpha: 1),
            ]
            let value = NSAttributedString(string: label, attributes: attributes)
            let size = value.size()
            var origin = NSPoint(x: highlight.minX,
                                 y: highlight.maxY + 4)
            if origin.y + size.height + 8 > bounds.maxY {
                origin.y = max(4, highlight.minY - size.height - 8)
            }
            origin.x = min(max(4, origin.x), max(4, bounds.maxX - size.width - 12))
            let background = NSRect(x: origin.x - 4, y: origin.y - 3,
                                    width: size.width + 8, height: size.height + 6)
            NSColor(srgbRed: 0.055, green: 0.065, blue: 0.06, alpha: 0.98).setFill()
            NSBezierPath(rect: background).fill()
            value.draw(at: origin)
        }
    }

    private var panel: OverlayPanel?
    private var canvas: Canvas?
    private var editor: NoteEditor?
    private var simulatorWindow: AXUIElement?
    private var simulatorPID: pid_t = 0
    private var simulatorFrame = CGRect.zero
    private var hoveredElement: AXUIElement?
    private var hoveredPoint = CGPoint.zero
    private var selectedNode: AXKit.Node?
    private var selectedNodes: [AXKit.Node] = []
    private var selectedRegion: CGRect?
    private var metadata: [String: Any] = [:]
    private var restorePID: pid_t = 0
    private var submit: (([String: Any]) -> Void)?

    var isActive: Bool { panel != nil }

    func begin(window: AXUIElement, simulatorPID: pid_t,
               metadata: [String: Any], restorePID: pid_t,
               submit: @escaping ([String: Any]) -> Void) {
        if isActive { finish(restoreFocus: false) }
        guard let frame = AXKit.frame(of: window), frame.width > 20, frame.height > 20,
              let primary = NSScreen.screens.first else { return }
        self.simulatorWindow = window
        self.simulatorPID = simulatorPID
        self.simulatorFrame = frame
        self.metadata = metadata
        self.restorePID = restorePID
        self.submit = submit

        let appKitFrame = NSRect(x: frame.minX,
                                 y: primary.frame.height - frame.maxY,
                                 width: frame.width, height: frame.height)
        let panel = OverlayPanel(contentRect: appKitFrame, styleMask: [.borderless],
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
        canvas.onMove = { [weak self] point in self?.updateHover(at: point) }
        canvas.onSelect = { [weak self] region in
            if let region { self?.selectRegion(region) } else { self?.selectHover() }
        }
        canvas.onCancel = { [weak self] in self?.finish() }
        panel.contentView = canvas
        self.panel = panel
        self.canvas = canvas

        NSRunningApplication.current.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(canvas)
    }

    private func updateHover(at localPoint: NSPoint) {
        let point = CGPoint(x: simulatorFrame.minX + localPoint.x,
                            y: simulatorFrame.maxY - localPoint.y)
        hoveredPoint = point
        hoveredElement = AXKit.element(pid: simulatorPID, at: point)
        guard let element = hoveredElement else {
            canvas?.highlight = NSRect(x: localPoint.x - 12, y: localPoint.y - 12,
                                       width: 24, height: 24)
            canvas?.label = "simulator region"
            canvas?.needsDisplay = true
            return
        }
        let node = AXKit.node(for: element, path: "")
        var local = localRect(for: node.frame)
        if local.width < 2 || local.height < 2 {
            local = NSRect(x: localPoint.x - 12, y: localPoint.y - 12,
                           width: 24, height: 24)
        }
        canvas?.highlight = local.intersection(canvas?.bounds ?? local)
        canvas?.label = [node.role, node.title, node.value]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        canvas?.needsDisplay = true
    }

    private func selectHover() {
        guard let canvas else { return }
        let path: String
        let node: AXKit.Node
        if let element = hoveredElement, let window = simulatorWindow {
            path = AXKit.path(in: window, to: element) ?? ""
            node = AXKit.node(for: element, path: path)
        } else {
            path = "region@\(Int(hoveredPoint.x)),\(Int(hoveredPoint.y))"
            node = AXKit.Node(path: path, role: "AXRegion", title: "Simulator region",
                              value: "", identifier: "", subrole: "", enabled: true,
                              frame: CGRect(x: hoveredPoint.x - 12, y: hoveredPoint.y - 12,
                                            width: 24, height: 24))
        }
        selectedNode = node
        selectedNodes = [node]
        selectedRegion = nil
        canvas.selected = true
        canvas.label = [node.role, node.title, node.value]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        canvas.needsDisplay = true

        presentEditor(selection: canvas.highlight ?? .zero,
                      summary: [path.isEmpty ? "ax://window" : "ax://\(path)", node.title, node.value]
                        .filter { !$0.isEmpty }.joined(separator: "  ·  "))
    }

    private func selectRegion(_ localRegion: NSRect) {
        guard let canvas else { return }
        let global = CGRect(x: simulatorFrame.minX + localRegion.minX,
                            y: simulatorFrame.maxY - localRegion.maxY,
                            width: localRegion.width, height: localRegion.height)
        let nodes = simulatorWindow.map {
            AXKit.tree(window: $0, maxDepth: 16, interactiveOnly: true)
                .filter { !$0.path.isEmpty && !$0.frame.isEmpty && $0.frame.intersects(global) }
        } ?? []
        selectedNodes = Array(nodes.prefix(80))
        selectedNode = selectedNodes.first ?? AXKit.Node(
            path: "region@\(Int(global.midX)),\(Int(global.midY))",
            role: "AXRegion", title: "Simulator region", value: "",
            identifier: "", subrole: "", enabled: true, frame: global)
        selectedRegion = global
        hoveredPoint = CGPoint(x: global.midX, y: global.midY)
        canvas.selected = true
        canvas.highlight = localRegion
        canvas.elementHighlights = selectedNodes.map(localRect(for:)).map {
            $0.intersection(canvas.bounds)
        }.filter { !$0.isEmpty }
        canvas.label = "\(selectedNodes.count) accessibility element\(selectedNodes.count == 1 ? "" : "s")"
        canvas.needsDisplay = true
        presentEditor(selection: localRegion,
                      summary: "region  ·  \(selectedNodes.count) selected element\(selectedNodes.count == 1 ? "" : "s")")
    }

    private func presentEditor(selection selected: NSRect, summary: String) {
        guard let canvas, let panel else { return }
        let width = min(CGFloat(420), max(260, canvas.bounds.width - 24))
        let height: CGFloat = 154
        var y = selected.minY - height - 10
        if y < 12 { y = min(canvas.bounds.height - height - 12, selected.maxY + 10) }
        let x = min(max(12, selected.minX), max(12, canvas.bounds.width - width - 12))
        let editor = NoteEditor(frame: NSRect(x: x, y: max(12, y), width: width, height: height))
        editor.summary.stringValue = summary
        editor.text.onCancel = { [weak self] in self?.finish() }
        editor.text.onSubmit = { [weak self] in self?.send() }
        canvas.addSubview(editor)
        self.editor = editor
        panel.makeFirstResponder(editor.text)
    }

    private func send() {
        guard let node = selectedNode,
              let comment = editor?.text.string.trimmingCharacters(in: .whitespacesAndNewlines),
              !comment.isEmpty else { return }
        var context = node.dictionary
        if let selectedRegion {
            context = [
                "selectionType": "region",
                "element": "AXRegion",
                "label": "\(selectedNodes.count) accessibility elements",
                "elementCount": selectedNodes.count,
                "elements": selectedNodes.map(\.dictionary),
                "bounds": ["x": Int(selectedRegion.minX), "y": Int(selectedRegion.minY),
                           "width": Int(selectedRegion.width), "height": Int(selectedRegion.height)],
            ]
            context["elementPath"] = selectedNodes.map(\.path)
        } else {
            context["selectionType"] = "element"
            context["selector"] = node.path.isEmpty ? "ax://window" : "ax://\(node.path)"
            context["elementPath"] = node.path
            context["element"] = node.role
            context["label"] = !node.title.isEmpty ? node.title : node.value
        }
        context["point"] = ["x": Int(hoveredPoint.x), "y": Int(hoveredPoint.y)]
        context["windowFrame"] = ["x": Int(simulatorFrame.minX),
                                  "y": Int(simulatorFrame.minY),
                                  "width": Int(simulatorFrame.width),
                                  "height": Int(simulatorFrame.height)]
        context["simulator"] = metadata
        submit?(["source": "sim", "comment": comment, "context": context,
                 "intent": "change", "severity": "normal", "status": "open"])
        finish()
    }

    private func localRect(for cgRect: CGRect) -> NSRect {
        NSRect(x: cgRect.minX - simulatorFrame.minX,
               y: simulatorFrame.maxY - cgRect.maxY,
               width: cgRect.width, height: cgRect.height)
    }

    private func localRect(for node: AXKit.Node) -> NSRect {
        localRect(for: node.frame)
    }

    func finish(restoreFocus: Bool = true) {
        panel?.orderOut(nil)
        panel = nil
        canvas = nil
        editor = nil
        simulatorWindow = nil
        hoveredElement = nil
        selectedNode = nil
        selectedNodes = []
        selectedRegion = nil
        submit = nil
        if restoreFocus, restorePID > 0 {
            NSRunningApplication(processIdentifier: restorePID)?.activate()
        }
    }
}
