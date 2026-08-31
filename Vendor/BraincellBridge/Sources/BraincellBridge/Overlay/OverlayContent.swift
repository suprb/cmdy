import SwiftUI

/// Floating-overlay UI shown when ⌘⇧B or ⌘⇧S fires. Lists live terminal
/// sessions and previews the payload that's about to be injected — either
/// captured text (⌘⇧B) or a captured image (⌘⇧S).
struct OverlayContent: View {
    @ObservedObject var appState: BridgeAppState
    let capturedText: String?
    let capturedImage: Data?
    let capturedImageSize: CGSize?
    /// True when both AX and Cmd+C completed but came back empty — render
    /// the inline "couldn't read selection — capture a region instead?" hint.
    let showFallbackHint: Bool
    let onPick: (TerminalSession) -> Void
    let onCaptureRegion: () -> Void
    let onDismiss: () -> Void

    private let panelWidth: CGFloat = 480
    private let panelHeight: CGFloat = 360
    private let cornerRadius: CGFloat = 14
    private let previewCharLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 12) {
                payloadPreview
                Text("Pick a terminal session")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, 4)
                sessionList
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerIcon: String {
        capturedImage != nil ? "photo.fill" : "paperplane.fill"
    }

    /// "Image: 1234×567 captured" when the payload is an image, otherwise the
    /// existing "Send to Claude" header. Surfacing dimensions in the header is
    /// the easiest way to confirm the region picker captured what the user
    /// intended without re-rendering a large thumbnail.
    private var headerTitle: String {
        if capturedImage != nil {
            if let size = capturedImageSize,
               size.width.isFinite, size.height.isFinite,
               size.width > 0, size.height > 0 {
                return "Image: \(Int(size.width.rounded()))×\(Int(size.height.rounded())) captured"
            }
            return "Image captured"
        }
        return "Send to Claude"
    }

    // MARK: - Preview

    @ViewBuilder
    private var payloadPreview: some View {
        if capturedImage != nil {
            imagePreview
        } else {
            VStack(alignment: .leading, spacing: 8) {
                selectionPreview
                if showFallbackHint {
                    fallbackHint
                }
            }
        }
    }

    private var selectionPreview: some View {
        let text = capturedText ?? ""
        let display: String
        if text.isEmpty {
            display = showFallbackHint
                ? "No selection captured."
                : "No selection captured. Pick a session to focus its terminal."
        } else if text.count > previewCharLimit {
            display = String(text.prefix(previewCharLimit)) + "…"
        } else {
            display = text
        }

        return Text(display)
            .font(.system(size: 12, design: text.isEmpty ? .default : .monospaced))
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(5)
            .truncationMode(.tail)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    /// Inline thumbnail for the captured image. Bounded so a tall capture
    /// can't stretch the panel.
    @ViewBuilder
    private var imagePreview: some View {
        if let data = capturedImage, let nsImg = NSImage(data: data) {
            Image(nsImage: nsImg)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
    }

    /// Inline call-to-action shown when AX + Cmd+C both came back empty. The
    /// usual cause is an Electron app where the AX surface is shallow and
    /// pasteboard timing is mangled — region capture sidesteps both.
    private var fallbackHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "viewfinder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn't read selection")
                    .font(.system(size: 12, weight: .semibold))
                Text("Try a region capture instead — it works in Electron apps where text selection doesn't.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: onCaptureRegion) {
                Text("⌘⇧S")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
            .help("Capture a screen region instead")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Session list

    @ViewBuilder
    private var sessionList: some View {
        if appState.registry.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("No live sessions.")
                    .font(.system(size: 12, weight: .medium))
                Text("Open the agent from a cmdy pane with Bridge enabled.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8)
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(appState.registry.sessions) { session in
                        SessionRow(session: session) {
                            onPick(session)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: TerminalSession
    let onPick: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.06))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(session.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
