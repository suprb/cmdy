import AppKit
import ProductIdentity
import ScreenCaptureKit

@MainActor
final class AnnotationOverlay {
    static let shared = AnnotationOverlay()

    private var window: NSWindow?

    func present(windowNumber: CGWindowID?, completion: @escaping (String?) -> Void) {
        dismiss()
        Task {
            do {
                let capture = try await Self.capture(windowNumber: windowNumber)
                let canvas = AnnotationCanvas(image: NSImage(cgImage: capture.image, size: capture.frame.size))
                let overlay = AnnotationWindow(contentRect: capture.frame,
                                               styleMask: [.borderless],
                                               backing: .buffered, defer: false)
                overlay.contentView = canvas
                overlay.backgroundColor = .black
                overlay.isOpaque = true
                overlay.level = .screenSaver
                overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                overlay.hasShadow = false
                canvas.onCancel = { [weak self] in
                    self?.dismiss()
                    completion(nil)
                }
                canvas.onFinish = { [weak self, weak canvas] in
                    guard let canvas else { return }
                    let path = canvas.writePNG()
                    self?.dismiss()
                    completion(path)
                }
                self.window = overlay
                overlay.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                overlay.makeFirstResponder(canvas)
            } catch {
                NSSound.beep()
                completion(nil)
            }
        }
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
    }

    private struct Capture {
        let image: CGImage
        let frame: NSRect
    }

    private static func capture(windowNumber: CGWindowID?) async throws -> Capture {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best

        if let windowNumber,
           let target = content.windows.first(where: { $0.windowID == windowNumber }) {
            let pixelWidth = target.frame.width * 2
            let pixelHeight = target.frame.height * 2
            guard pixelWidth.isFinite, pixelHeight.isFinite,
                  pixelWidth > 0, pixelHeight > 0,
                  pixelWidth <= 16_384, pixelHeight <= 16_384 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            config.width = Int(pixelWidth.rounded(.up))
            config.height = Int(pixelHeight.rounded(.up))
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target),
                configuration: config)
            return Capture(image: image, frame: appKitFrame(for: target.frame))
        }

        guard let screen = NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CocoaError(.featureUnsupported)
        }
        config.width = max(1, display.width)
        config.height = max(1, display.height)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: config)
        return Capture(image: image, frame: screen.frame)
    }

    private static func appKitFrame(for quartzFrame: CGRect) -> NSRect {
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { continue }
            let display = CGDisplayBounds(id)
            guard display.intersects(quartzFrame) else { continue }
            return NSRect(x: screen.frame.minX + quartzFrame.minX - display.minX,
                          y: screen.frame.maxY - (quartzFrame.maxY - display.minY),
                          width: quartzFrame.width, height: quartzFrame.height)
        }
        return NSRect(x: quartzFrame.minX,
                      y: NSScreen.main.map { $0.frame.maxY - quartzFrame.maxY } ?? quartzFrame.minY,
                      width: quartzFrame.width, height: quartzFrame.height)
    }
}

private final class AnnotationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class AnnotationCanvas: NSView {
    private let image: NSImage
    private var marks: [NSRect] = []
    private var anchor: NSPoint?
    private var activeMark: NSRect?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        for rect in marks + (activeMark.map { [$0] } ?? []) {
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            rect.fill()
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 3
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        activeMark = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        activeMark = rect(from: anchor, to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor else { return }
        let mark = rect(from: anchor, to: convert(event.locationInWindow, from: nil))
        if mark.width >= 4, mark.height >= 4 { marks.append(mark) }
        self.anchor = nil
        activeMark = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { onFinish?(); return }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if !marks.isEmpty { marks.removeLast(); needsDisplay = true }
            return
        }
        super.keyDown(with: event)
    }

    func writePNG() -> String? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(ProductIdentity.current.slug)-annotation-\(UUID().uuidString).png")
        do { try data.write(to: url); return url.path } catch { return nil }
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(bounds)
    }
}
