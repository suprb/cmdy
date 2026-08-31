import AppKit

/// Shared "captured payload → terminal" hand-off helper.
///
/// Two routes:
///
/// 1. **Inline paste** — small text payloads (`< largeTextThreshold`) go
///    straight through `TextInjection.send` and land verbatim in the terminal.
///    Same as the original ⌘⇧B flow.
/// 2. **Asset hand-off via /tmp** — large text or any image payload is written
///    to a temp file with a unique name; the terminal receives a short
///    `Look at <path>` / `Read <path>` line instead of the bytes themselves.
///    Claude's Read tool then picks up the file by path. This avoids choking
///    a TTY on a megabyte of pasted text and is the only sane path for images
///    (no terminal can render base64 PNG).
///
/// The same pattern is mirrored in adapter-side captures (`mac_screenshot`
/// already does it). When adding new MCP tools that produce large blobs,
/// follow the same convention: write to `NSTemporaryDirectory()`, return the
/// path; never return the bytes inline.
@MainActor
enum AssetHandoff {
    /// Anything bigger than this gets the file-on-disk treatment instead of
    /// being pasted into the terminal directly. 4 KB is comfortably above
    /// "code snippet from a doc" but well below "log dump from a build".
    static let largeTextThreshold = 4 * 1024

    // MARK: - File writes

    /// Write `data` to `/tmp` with the given extension and return the path.
    /// Caller chooses what message (if any) to inject into the terminal.
    static func writeToTemp(_ data: Data, ext: String) -> String? {
        let path = NSTemporaryDirectory() + "braincell-bridge-cap-\(UUID().uuidString).\(ext)"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            NSLog("[Bridge] AssetHandoff wrote %d bytes to %@", data.count, path)
            return path
        } catch {
            NSLog("[Bridge] AssetHandoff failed to write %@: %@", path, error.localizedDescription)
            return nil
        }
    }

    // MARK: - Text payloads

    /// Inject `text` into `session`. Small text pastes inline; large text is
    /// staged to `/tmp` and a `Read <path>` line is pasted instead so Claude
    /// can pick up the full content via its Read tool.
    static func injectText(_ text: String, into session: TerminalSession, targetWindowId: CGWindowID? = nil) async {
        if text.utf8.count <= largeTextThreshold {
            await TextInjection.send(text, to: session, targetWindowId: targetWindowId)
            return
        }

        guard let path = writeToTemp(Data(text.utf8), ext: "txt") else {
            // Fall back to inline paste if /tmp write failed — better than
            // silently dropping the user's selection.
            await TextInjection.send(text, to: session, targetWindowId: targetWindowId)
            return
        }
        let line = "Read \(path)"
        NSLog("[Bridge] AssetHandoff: large text (%d bytes) → %@", text.utf8.count, line)
        await TextInjection.send(line, to: session, targetWindowId: targetWindowId)
    }

    // MARK: - Image payloads

    /// Write `pngData` to `/tmp` and inject `Look at <path> (WxH)` into
    /// `session`. Always uses the file route — no terminal can render PNG
    /// inline and Claude's Read tool handles images by path.
    static func injectImage(_ pngData: Data, into session: TerminalSession, dimensions: CGSize?, targetWindowId: CGWindowID? = nil) async {
        guard let path = writeToTemp(pngData, ext: "png") else {
            NSLog("[Bridge] AssetHandoff: failed to write PNG, dropping injection for session %@", session.id)
            return
        }
        let dims = dimensions.flatMap { size -> String? in
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return " (\(Int(size.width.rounded()))x\(Int(size.height.rounded())))"
        } ?? ""
        let line = "Look at \(path)\(dims)"
        NSLog("[Bridge] AssetHandoff: image (%d bytes%@) → %@", pngData.count, dims, line)
        await TextInjection.send(line, to: session, targetWindowId: targetWindowId)
    }
}
