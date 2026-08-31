import AppKit

/// Region capture via macOS's built-in `screencapture -i -c` subprocess.
///
/// Why subprocess instead of `CGDisplayStream` / `ScreenCaptureKit`: the system
/// `screencapture` UI is the gold standard — Retina-aware crosshair, ESC to
/// cancel, region drag with snapping, modifier keys for window vs region. We
/// don't reinvent it. The captured PNG lands on the pasteboard via `-c`.
///
/// We then read the bytes off the pasteboard and snapshot back the previous
/// contents so we don't trash the user's clipboard. Detection of "user
/// cancelled" is via `NSPasteboard.changeCount` — if the count didn't bump,
/// `screencapture` exited without writing (Esc / no drag).
@MainActor
enum RegionCapture {

    /// Run `screencapture -i -c` synchronously (blocks until the user finishes
    /// the drag or hits Escape). Returns the captured image as PNG `Data`, or
    /// `nil` if the user cancelled.
    static func captureToPasteboard() async -> Data? {
        let pb = NSPasteboard.general
        let prevChange = pb.changeCount
        // Snapshot the existing pasteboard contents so we can restore them
        // after we read the captured PNG. Otherwise the user's clipboard
        // ends up holding a stray screenshot from this flow.
        let savedString = pb.string(forType: .string)
        let savedItems = snapshotPasteboardItems(pb)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i  = interactive region picker
        // -c  = copy to pasteboard instead of writing to a file
        proc.arguments = ["-i", "-c"]

        do {
            try proc.run()
        } catch {
            NSLog("[Bridge] RegionCapture failed to launch screencapture: %@", error.localizedDescription)
            return nil
        }

        // Wait for the subprocess off the main actor so we don't beach-ball
        // the app while the picker is up. waitUntilExit is blocking so we
        // bridge it through a continuation fired from a global queue.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                cont.resume()
            }
        }

        // No new pasteboard content → user cancelled. Nothing to restore.
        guard pb.changeCount != prevChange else {
            NSLog("[Bridge] RegionCapture: user cancelled (no pasteboard change)")
            return nil
        }

        var captured: Data? = nil
        if let png = pb.data(forType: .png) {
            captured = png
        } else if let tiff = pb.data(forType: .tiff),
                  let img = NSImage(data: tiff),
                  let png = img.bridge_pngData() {
            captured = png
        } else {
            NSLog("[Bridge] RegionCapture: pasteboard changed but contained no image")
        }

        // Restore the user's previous pasteboard contents so the captured
        // image doesn't linger on their clipboard. The injection step uses
        // its own pasteboard dance via TextInjection; we don't need this
        // image to stay on the system pasteboard.
        restorePasteboard(pb, items: savedItems, fallbackString: savedString)

        return captured
    }

    // MARK: - Pasteboard helpers (mirror SelectionCapture / TextInjection)

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

/// PNG-encode helper. Namespaced (`bridge_`) so it doesn't clash with any
/// other extension someone might add to NSImage.
extension NSImage {
    func bridge_pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Pixel dimensions, not point dimensions. Region capture from a Retina
    /// display reports e.g. `1234×567` pixels — that's what we want to surface
    /// in the overlay header.
    func bridge_pixelSize() -> CGSize? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
