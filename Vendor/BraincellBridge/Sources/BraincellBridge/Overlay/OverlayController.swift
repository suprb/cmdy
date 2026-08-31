import AppKit
import SwiftUI
import Combine

/// Owns the floating overlay panel that appears when a Bridge hotkey fires.
///
/// Two entry points:
///
/// - `show()` — ⌘⇧B path. Captures the frontmost app's text selection
///   (AX → Cmd+C fallback) and presents the picker.
/// - `showWithImage(...)` — ⌘⇧S path. Skips selection capture; the caller has
///   already obtained PNG bytes from `RegionCapture` and just wants the user
///   to pick a session to hand it off to.
///
/// In both cases the user picks a session row → the captured payload is
/// injected into the bound terminal (small text inline; large text or any
/// image staged to `/tmp` via `AssetHandoff`).
@MainActor
final class OverlayController {
    weak var appState: BridgeAppState?

    private var panel: NSPanel?
    private var hostingController: NSHostingController<OverlayContent>?
    private var keyMonitor: Any?

    /// External "drop to region picker" hook the AppDelegate wires up so the
    /// inline fallback hint (and any future entry points) can fire ⌘⇧S
    /// without dragging in a circular dependency on the AppDelegate type.
    var onCaptureRegion: (() -> Void)?

    /// Bridge between the SwiftUI view and the controller. Marked `@MainActor` so
    /// SwiftUI's `@ObservedObject` machinery is happy and we don't bounce off-actor.
    private final class State: ObservableObject {
        @Published var capturedText: String?
        /// PNG bytes from a region capture, when present. Mutually exclusive
        /// with `capturedText` — exactly one is populated per show().
        @Published var capturedImage: Data?
        /// Pixel dimensions for the captured image, used in the overlay
        /// header ("Image: 1234×567 captured").
        @Published var capturedImageSize: CGSize?
        /// True when both AX and Cmd+C completed but came back empty — used
        /// to show the "couldn't read selection — capture a region instead?"
        /// hint inline. Distinct from "no app focused at all", which yields
        /// the existing empty-preview text.
        @Published var emptySelectionFallbackHint: Bool = false
    }
    private let state = State()

    init(appState: BridgeAppState) {
        self.appState = appState
    }

    // MARK: - Public

    func show() {
        guard let appState = appState else { return }

        // Capture selection BEFORE we steal focus (otherwise the frontmost app changes
        // and AX/Cmd+C reads the wrong window). We're already on the main actor, but the
        // capture itself is async (pasteboard fallback sleeps briefly).
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let result = await SelectionCapture.captureWithDiagnostics()
            self.state.capturedText = result.text
            self.state.capturedImage = nil
            self.state.capturedImageSize = nil
            // Show the "couldn't read selection" fallback hint only when both
            // strategies actually completed but came back empty — the most
            // common signal for "this is an Electron / web app where AX is
            // dead and Cmd+C timing is mangled". Don't show it for legitimately
            // empty selections (no app focused at all).
            self.state.emptySelectionFallbackHint =
                result.text == nil && result.axAttempted && result.pasteboardAttempted
            self.presentPanel(appState: appState)
        }
    }

    /// Show the picker with an already-captured PNG image (region capture).
    /// Skips the AX/pasteboard read entirely.
    func showWithImage(_ pngData: Data, dimensions: CGSize?) {
        guard let appState = appState else { return }
        state.capturedText = nil
        state.capturedImage = pngData
        state.capturedImageSize = dimensions
        state.emptySelectionFallbackHint = false
        presentPanel(appState: appState)
    }

    func hide() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }

    // MARK: - Panel construction

    private func presentPanel(appState: BridgeAppState) {
        // If a panel is already up (e.g. ⌘⇧B fired then ⌘⇧S), tear it down
        // and rebuild — simplest way to swap content for the new payload.
        if panel != nil {
            hide()
        }

        // Build content view.
        let content = OverlayContent(
            appState: appState,
            capturedText: state.capturedText,
            capturedImage: state.capturedImage,
            capturedImageSize: state.capturedImageSize,
            showFallbackHint: state.emptySelectionFallbackHint,
            onPick: { [weak self] session in
                self?.handlePick(session: session)
            },
            onCaptureRegion: { [weak self] in
                guard let self = self else { return }
                // Hide the overlay so the screencapture crosshair has no
                // panel to capture under it. The region picker calls back
                // into showWithImage when done.
                self.hide()
                self.onCaptureRegion?()
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let hosting = NSHostingController(rootView: content)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 480, height: 360)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentViewController = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false

        // Center on the screen with the mouse pointer (best proxy for "where the user is looking").
        if let screen = screenWithMouse() ?? NSScreen.main {
            let frame = screen.visibleFrame
            let originX = frame.midX - 240
            let originY = frame.midY - 180
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        }

        self.panel = panel
        self.hostingController = hosting

        // Activate so the borderless panel can receive key events (ESC).
        // Accessory apps stay accessory; this just brings them to the front briefly.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Local key monitor handles ESC and (later) Enter / arrows. Local-only because
        // the panel is key — system-wide monitor isn't required.
        installKeyMonitor()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 = ESC
            if event.keyCode == 53 {
                Task { @MainActor in self?.hide() }
                return nil
            }
            return event
        }
    }

    // MARK: - Row pick

    private func handlePick(session: TerminalSession) {
        let text = state.capturedText
        let image = state.capturedImage
        let imageSize = state.capturedImageSize
        // Hide the overlay first so it can't intercept the activation race.
        hide()

        Task { @MainActor in
            // Image route: always /tmp + "Look at <path>".
            if let image = image {
                await AssetHandoff.injectImage(image, into: session, dimensions: imageSize)
                return
            }

            // Text route: small → inline, large → /tmp + "Read <path>".
            if let text = text, !text.isEmpty {
                await AssetHandoff.injectText(text, into: session)
                return
            }

            // Empty payload: just bring the terminal to front.
            if let app = NSRunningApplication(processIdentifier: pid_t(session.pid)) {
                app.activate()
            }
        }
    }

    // MARK: - Helpers

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
