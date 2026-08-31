import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Anchored capture canvas — the composer panel is positioned and sized to
/// match the captured element's rect on screen. The image renders at 1:1
/// (one captured pixel = one display point), with a pen-style annotation
/// overlay. On Send the strokes are baked into the image, scaled down to a
/// token-friendly size, and pasted into the bound terminal as markdown.
@MainActor
final class ComposerController {
    struct Context {
        let sessionId: String
        let source: String
        let title: String
        let subtitle: String?
        let bodyMarkdown: String
        let imagePath: String?
        let structuredContext: [String: Any]
    }

    /// Called when user hits Send. `withImage` reflects the include-screenshot
    /// toggle. If the user annotated, the bridge will have already swapped
    /// `context.imagePath` to a baked file before calling onSend.
    var onSend: ((Context, _ note: String, _ withImage: Bool) -> Void)?

    /// Asked to flatten current annotations into the image on disk and
    /// return a new file path. Implemented in BridgeAppDelegate so it can
    /// reach Core Graphics. Set by the delegate after construction.
    var bakeAnnotations: ((_ imagePath: String, _ strokes: [Stroke], _ imageSize: CGSize) -> String?)?

    private var panel: NSPanel?
    private var hostingController: NSHostingController<ComposerView>?
    private var current: Context?

    /// Shows the composer anchored to the given element rect (NSScreen coords,
    /// bottom-left origin). Falls back to screen-center if no rect.
    func show(context: Context, elementRect: NSRect? = nil) {
        current = context
        if panel == nil { buildPanel() }
        renderView(context: context, elementRect: elementRect)
        positionPanel(elementRect: elementRect, context: context)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        current = nil
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func buildPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.borderless, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false

        let host = NSHostingController(rootView: ComposerView(
            context: .init(sessionId: "", source: "bridge", title: "", subtitle: nil,
                           bodyMarkdown: "", imagePath: nil, structuredContext: [:]),
            imageDisplaySize: .zero,
            containerSize: .zero,
            onSend: { _, _, _ in },
            onCancel: {},
            onPenActiveChanged: { _ in }
        ))
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host.view
        panel = p
        hostingController = host
    }

    /// Layout constants. `pad` is the panel's outer padding; `headerHeight`
    /// is the chrome ABOVE the image (header text + spacing). `inputArea` is
    /// the chrome BELOW the image (input field + actions). Together they let
    /// the controller compute the panel's exact frame from the image size
    /// AND offset the panel so its image area aligns with the element rect.
    private struct Layout {
        let pad: CGFloat = 10
        let headerHeight: CGFloat = 18       // single-row header, tighter
        let headerSpacing: CGFloat = 8       // VStack gap between header and image
        let inputSpacing: CGFloat = 8        // VStack gap between image and input
        let inputArea: CGFloat = 84          // input field (~56) + actions row + spacing
        var topChrome: CGFloat { pad + headerHeight + headerSpacing }
        var bottomChrome: CGFloat { inputSpacing + inputArea + pad }
    }
    private let layout = Layout()

    /// Compute three sizes:
    ///   - image:     1:1 element pixels (clamped to ~85% of screen for huge elements)
    ///   - container: the drawable region that holds the image. Always at
    ///                least `minContainer` so there's room to draw and the
    ///                toolbar doesn't crowd small captures. Image is
    ///                centered within this rect at its 1:1 size.
    ///   - panel:     outer panel size = container + chrome
    private func computeSizes(elementRect: NSRect?, hasImage: Bool)
        -> (image: CGSize, container: CGSize, panel: CGSize)
    {
        let minContainer = CGSize(width: 300, height: 180)

        guard hasImage else {
            return (.zero, .zero, CGSize(width: minContainer.width + layout.pad * 2,
                                          height: 60 + layout.inputArea))
        }

        let visible = (NSScreen.main?.visibleFrame ?? .zero).insetBy(dx: 24, dy: 24)
        let maxW = max(360, visible.width * 0.85)
        let maxH = max(240, visible.height * 0.65)

        var imgW = elementRect?.width ?? 360
        var imgH = elementRect?.height ?? 200
        if imgW > maxW || imgH > maxH {
            let s = min(maxW / imgW, maxH / imgH)
            imgW *= s; imgH *= s
        }
        // Container grows to hold image, never shrinks below minContainer.
        let containerW = max(imgW, minContainer.width)
        let containerH = max(imgH, minContainer.height)
        let panelW = containerW + layout.pad * 2
        let panelH = containerH + layout.topChrome + layout.bottomChrome - layout.pad
        return (
            CGSize(width: imgW, height: imgH),
            CGSize(width: containerW, height: containerH),
            CGSize(width: panelW, height: panelH)
        )
    }

    private func renderView(context: Context, elementRect: NSRect?) {
        let hasImage = context.imagePath != nil
        let sizes = computeSizes(elementRect: elementRect, hasImage: hasImage)
        hostingController?.rootView = ComposerView(
            context: context,
            imageDisplaySize: sizes.image,
            containerSize: sizes.container,
            onSend: { [weak self] note, withImage, strokes in
                guard let self = self else { return }
                var ctx = context
                if withImage, !strokes.isEmpty,
                   let path = context.imagePath,
                   let baked = self.bakeAnnotations?(path, strokes, sizes.image) {
                    ctx = Context(
                        sessionId: context.sessionId,
                        source: context.source,
                        title: context.title,
                        subtitle: context.subtitle,
                        bodyMarkdown: context.bodyMarkdown,
                        imagePath: baked,
                        structuredContext: context.structuredContext
                    )
                }
                self.onSend?(ctx, note, withImage)
                self.close()
            },
            onCancel: { [weak self] in self?.close() },
            onPenActiveChanged: { [weak self] active in
                self?.setMovable(!active)
            }
        )
    }

    /// Position panel so the IMAGE AREA aligns EXACTLY with the element's
    /// screen rect. Panel extends UPWARD past the element by the header
    /// chrome height and DOWNWARD past for the input/actions. ALWAYS clamped
    /// to the visible frame — alignment may be sacrificed when the element
    /// is near a screen edge, but the panel is always fully visible.
    private func positionPanel(elementRect: NSRect?, context: Context) {
        guard let panel = panel else { return }
        let hasImage = context.imagePath != nil
        let sizes = computeSizes(elementRect: elementRect, hasImage: hasImage)
        panel.setContentSize(sizes.panel)

        let screen = NSScreen.screens.first { $0.frame.contains(elementRect?.origin ?? .zero) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let target: NSPoint
        if let er = elementRect {
            let imgInset = (sizes.container.width - sizes.image.width) / 2
            let imgVerticalInset = (sizes.container.height - sizes.image.height) / 2
            let x = er.minX - layout.pad - imgInset
            let y = er.maxY + layout.topChrome + imgVerticalInset - sizes.panel.height
            target = NSPoint(x: x, y: y)
        } else {
            target = NSPoint(
                x: visible.midX - sizes.panel.width / 2,
                y: visible.midY - sizes.panel.height / 2
            )
        }
        // Clamp aggressively — visible.minY/maxY are in NSScreen coords
        // (bottom-left origin). max() prevents the panel from sliding off the
        // BOTTOM (origin.y < visible.minY); min() prevents it from sliding off
        // the TOP (origin.y + panel.height > visible.maxY). When the panel is
        // taller than visible height, max wins (panel pinned to bottom + maxY
        // clipped), which is the right side to err on — keeps the input field
        // visible.
        let m: CGFloat = 12
        let maxOriginY = visible.maxY - sizes.panel.height - m
        let minOriginY = visible.minY + m
        let clampedX = min(max(target.x, visible.minX + m), visible.maxX - sizes.panel.width - m)
        let clampedY: CGFloat
        if maxOriginY < minOriginY {
            // Panel is taller than the visible area — pin to top (so header +
            // image are visible; actions might clip at bottom).
            clampedY = maxOriginY
        } else {
            clampedY = min(max(target.y, minOriginY), maxOriginY)
        }
        NSLog("[Bridge] Composer position: target=%@ clamped=(%.0f,%.0f) panel=%@ visible=%@",
              String(describing: target), clampedX, clampedY,
              String(describing: sizes.panel), String(describing: visible))
        panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    /// Toggle whether the panel can be dragged by its background. SwiftUI
    /// pen-mode flips this off so dragging strokes doesn't move the window.
    func setMovable(_ movable: Bool) {
        panel?.isMovableByWindowBackground = movable
    }
}

// MARK: - Strokes

/// One pen stroke. Points are in display-points relative to the image's
/// top-left. The bake step transforms them to image-pixel space.
struct Stroke: Equatable {
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat

    static func == (lhs: Stroke, rhs: Stroke) -> Bool {
        lhs.points == rhs.points && lhs.width == rhs.width && lhs.color == rhs.color
    }
}

// MARK: - SwiftUI

private struct ComposerView: View {
    let context: ComposerController.Context
    let imageDisplaySize: CGSize
    let containerSize: CGSize
    /// (note, withImage, strokes)
    let onSend: (_ note: String, _ withImage: Bool, _ strokes: [Stroke]) -> Void
    let onCancel: () -> Void
    let onPenActiveChanged: (Bool) -> Void

    @State private var note: String = ""
    @State private var includeImage: Bool = true
    @State private var strokes: [Stroke] = []
    @State private var currentStroke: Stroke? = nil
    @State private var penActive: Bool = false
    @State private var appeared: Bool = false
    @FocusState private var noteFocused: Bool

    private let strokeColor: NSColor = NSColor(red: 0.96, green: 0.27, blue: 0.27, alpha: 1)
    private let strokeWidth: CGFloat = 3

    private var hasImage: Bool { context.imagePath != nil && imageDisplaySize != .zero }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if hasImage { imageCanvas }
            inputField
            actions
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
        .scaleEffect(appeared ? 1.0 : 0.92, anchor: .center)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                appeared = true
            }
        }
        .onChange(of: penActive) { _, active in onPenActiveChanged(active) }
        // Force SwiftUI to reset view identity when the captured image
        // changes — otherwise @State (notes, strokes, toggle, scale-in
        // animation flag) and the loaded NSImage can persist across
        // distinct captures, making the composer show the previous image
        // even after a fresh /composer/show call.
        .id(context.imagePath ?? context.sessionId)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            Text(context.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            if let sub = context.subtitle, !sub.isEmpty {
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(sub)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(height: 18)
    }

    // MARK: image canvas with annotation strokes + floating toolbar

    private var imageCanvas: some View {
        // Container is the drawable region. Image sits at 1:1 in the center.
        // For tiny elements the container provides breathing room around the
        // image so the toolbar doesn't crowd it. Strokes are stored in IMAGE-
        // local coords (relative to image's top-left), so the bake step needs
        // no knowledge of the container offset.
        ZStack {
            // Container background — subtle so the user sees its bounds.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

            // Centered image + strokes + drag catcher (all sized to image,
            // so gesture coords are already image-local).
            ZStack(alignment: .topLeading) {
                if let path = context.imagePath, let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .grayscale(includeImage ? 0 : 1)
                        .opacity(includeImage ? 1 : 0.4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                        )
                }
                Canvas { ctx, _ in
                    for stroke in strokes { drawStroke(stroke, in: &ctx) }
                    if let s = currentStroke { drawStroke(s, in: &ctx) }
                }
                .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                .allowsHitTesting(false)
                if penActive && includeImage {
                    Color.clear
                        .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in appendPoint(value.location) }
                                .onEnded { _ in finishStroke() }
                        )
                }
            }
            .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .overlay(alignment: .topLeading) {
            // Floating toolbar in the container's top-left corner. When the
            // image is small and centered, the toolbar lives in the empty
            // gutter and never covers the image.
            HStack(spacing: 2) {
                ToolbarButton(
                    icon: "pencil.tip",
                    isActive: penActive,
                    action: { penActive.toggle() }
                ).help("Pen — draw on the image")
                ToolbarButton(
                    icon: "arrow.uturn.backward",
                    isActive: false,
                    enabled: !strokes.isEmpty,
                    action: { _ = strokes.popLast() }
                ).help("Undo last stroke")
                ToolbarButton(
                    icon: "trash",
                    isActive: false,
                    enabled: !strokes.isEmpty,
                    action: { strokes.removeAll() }
                ).help("Clear all strokes")
            }
            .padding(3)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .padding(6)
        }
    }

    private func drawStroke(_ stroke: Stroke, in ctx: inout GraphicsContext) {
        guard stroke.points.count > 1 else {
            // Single-tap dot.
            if let p = stroke.points.first {
                let r = CGRect(
                    x: p.x - stroke.width / 2,
                    y: p.y - stroke.width / 2,
                    width: stroke.width, height: stroke.width
                )
                ctx.fill(Path(ellipseIn: r), with: .color(Color(nsColor: stroke.color)))
            }
            return
        }
        var path = Path()
        path.move(to: stroke.points[0])
        for p in stroke.points.dropFirst() { path.addLine(to: p) }
        ctx.stroke(
            path,
            with: .color(Color(nsColor: stroke.color)),
            style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
        )
    }

    private func appendPoint(_ p: CGPoint) {
        if currentStroke == nil {
            currentStroke = Stroke(points: [p], color: strokeColor, width: strokeWidth)
        } else {
            currentStroke?.points.append(p)
        }
    }
    private func finishStroke() {
        if let s = currentStroke, !s.points.isEmpty {
            strokes.append(s)
        }
        currentStroke = nil
    }

    // MARK: input field

    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            if note.isEmpty {
                Text("What about this?")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $note)
                .focused($noteFocused)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(minHeight: 48)
                .onAppear { noteFocused = true }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(noteFocused ? 0.18 : 0.08), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.12), value: noteFocused)
    }

    // MARK: action row

    private var actions: some View {
        HStack(spacing: 8) {
            if hasImage {
                Toggle(isOn: $includeImage) {
                    Text("Include image")
                        .font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)
            }
            Spacer()
            Text("⌘↩")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            ComposerButton(
                label: "Send",
                icon: "arrow.up",
                style: .primary,
                action: { onSend(note, includeImage && hasImage, strokes) }
            )
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
        }
    }
}

// MARK: - Toolbar button

private struct ToolbarButton: View {
    let icon: String
    let isActive: Bool
    var enabled: Bool = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 24, height: 24)
                .background(background)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.10), value: hovering)
        .animation(.easeOut(duration: 0.10), value: isActive)
    }

    private var foreground: Color {
        if isActive { return .white }
        return .primary
    }
    private var background: Color {
        if isActive { return Color.accentColor }
        return Color.primary.opacity(hovering ? 0.10 : 0.0)
    }
}

// MARK: - Action button (Send)

private struct ComposerButton: View {
    enum Style { case primary, secondary }
    let label: String
    let icon: String
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var background: some View {
        Group {
            switch style {
            case .primary:
                Capsule(style: .continuous)
                    .fill(hovering ? Color.accentColor.opacity(0.92) : Color.accentColor)
            case .secondary:
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
            }
        }
    }
    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .primary
        }
    }
}
