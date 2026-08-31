import AppKit
import ApplicationServices

/// Captures the current text selection from the frontmost application.
///
/// Two strategies, in order:
///
/// 1. **AX (Accessibility) read** — ask the system-wide AXUIElement for the focused
///    element's `kAXSelectedTextAttribute`. Works when the app exposes its text
///    surface to AX (most native AppKit apps, Xcode, etc.). Requires the bridge
///    process to be trusted in System Settings → Privacy & Security → Accessibility.
///
/// 2. **Pasteboard fallback** — synthesize ⌘C, briefly wait, read the pasteboard,
///    restore previous contents. Works in apps that ignore AX (browsers running
///    in some sandbox modes, Electron, etc.).
@MainActor
enum SelectionCapture {

    /// Try to read the frontmost app's current text selection. Returns nil if no
    /// usable selection was found (or AX denied + pasteboard didn't change).
    static func capture() async -> String? {
        await captureWithDiagnostics().text
    }

    /// Result of a capture attempt with extra metadata so callers can
    /// distinguish "we tried both AX and Cmd+C and they came back empty"
    /// (typical of Electron / web-app surfaces) from "no app focused at all".
    /// Drives the inline "couldn't read selection — capture a region instead?"
    /// hint in the overlay.
    struct Result {
        /// The captured text, or `nil` when nothing usable was found.
        let text: String?
        /// True when the AX read actually fired against a focused element
        /// (cleanly or with `kAXErrorNoValue`). False when there was no
        /// focused element to query in the first place.
        let axAttempted: Bool
        /// True when the Cmd+C pasteboard fallback ran to completion. False
        /// when we short-circuited (AX returned non-empty text).
        let pasteboardAttempted: Bool
    }

    /// Same as `capture()` but returns telemetry alongside the text so the
    /// caller can render a fallback hint when both methods completed-but-empty.
    static func captureWithDiagnostics() async -> Result {
        // Prompt for Accessibility once. Subsequent calls return immediately if granted.
        promptForAXIfNeeded()

        let axResult = readSelectionViaAXDiag()
        if let s = axResult.text, !s.isEmpty {
            return Result(text: s, axAttempted: axResult.attempted, pasteboardAttempted: false)
        }

        let pbText = await captureViaPasteboard()
        return Result(text: pbText, axAttempted: axResult.attempted, pasteboardAttempted: true)
    }

    // MARK: - AX path

    private static func promptForAXIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static func readSelectionViaAX() -> String? {
        readSelectionViaAXDiag().text
    }

    /// AX read with telemetry. `attempted` is true when we actually queried
    /// the focused element's `kAXSelectedTextAttribute` (i.e. there WAS a
    /// focused element); false when there was no focused element at all (no
    /// app focused, AX permission denied, etc). The fallback hint depends on
    /// `attempted == true && text == nil` — that's the "Electron focused
    /// something but kAXSelectedTextAttribute returned empty" signature.
    private static func readSelectionViaAXDiag() -> (text: String?, attempted: Bool) {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard focusErr == .success, let focusedElement = AXSafety.element(focusedRef) else {
            if focusErr != .success {
                NSLog("[Bridge] AX focused element copy failed (err=%d)", focusErr.rawValue)
            }
            return (nil, false)
        }

        var selectedRef: CFTypeRef?
        let selErr = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedRef
        )

        // We attempted the read either way — even kAXErrorNoValue counts as
        // "AX answered, said nothing selected", which is our fallback signal.
        if selErr == .success, let str = selectedRef as? String, !str.isEmpty {
            return (str, true)
        }
        return (nil, true)
    }

    // MARK: - Pasteboard fallback

    private static func captureViaPasteboard() async -> String? {
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)
        let savedItems = snapshotPasteboardItems(pb)
        let savedChangeCount = pb.changeCount

        synthesizeCmdC()

        // Wait briefly for the frontmost app to react and update the pasteboard.
        try? await Task.sleep(nanoseconds: 80_000_000)

        var captured: String? = nil
        if pb.changeCount > savedChangeCount,
           let s = pb.string(forType: .string), !s.isEmpty {
            captured = s
        }

        // Restore previous pasteboard contents either way so we don't pollute the user's clipboard.
        restorePasteboard(pb, items: savedItems, fallbackString: savedString)

        return captured
    }

    private static func synthesizeCmdC() {
        // keyCode 8 = "C"
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) else {
            NSLog("[Bridge] Failed to synthesize CGEvent for ⌘C")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Best-effort snapshot of all pasteboard items so we can restore complex
    /// (e.g. multi-type) clipboard contents after our ⌘C round-trip.
    private static func snapshotPasteboardItems(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items: [NSPasteboardItem], fallbackString: String?) {
        pb.clearContents()
        if !items.isEmpty {
            pb.writeObjects(items)
        } else if let s = fallbackString {
            pb.setString(s, forType: .string)
        }
    }
}
