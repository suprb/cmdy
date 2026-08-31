import AppKit

/// Shared, deliberately quiet chrome for the native Channels and Extensions
/// managers. The content is the interface; this view only provides the inset
/// surface and hairline boundary around it.
@MainActor
public final class CmdyInsetListView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// Keeps an AppKit table locked to the visible width of its scroll view from
/// the very first layout pass. NSTableView otherwise begins at the sum of its
/// configured column widths and only corrects itself after a window resize.
@MainActor
public final class CmdyTableScrollView: NSScrollView {
    public override func layout() {
        super.layout()
        guard let table = documentView as? NSTableView else { return }
        let width = contentSize.width
        guard width > 0, abs(table.frame.width - width) > 0.5 else { return }
        table.setFrameSize(NSSize(width: width, height: table.frame.height))
    }
}

/// A quiet selection state for management lists. AppKit's default table
/// selection is visually heavy here, while disabling selection entirely makes
/// the clicked row appear to lose its divider with no replacement feedback.
@MainActor
public final class CmdyManagementRowView: NSTableRowView {
    public override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color = isEmphasized
            ? NSColor.controlAccentColor.withAlphaComponent(0.16)
            : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.28)
        color.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 7, dy: 4),
            xRadius: 7,
            yRadius: 7
        ).fill()
    }

    public override func drawSeparator(in dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 16, y: bounds.height - 1, width: max(0, bounds.width - 32), height: 1).fill()
    }
}

/// Presents a factual product guide as a small document instead of flattening
/// the same information into a crowded alert.
@MainActor
public final class CmdyProductGuidePresenter: NSObject, NSWindowDelegate {
    public static let shared = CmdyProductGuidePresenter()

    private weak var parentWindow: NSWindow?
    private var detailWindow: NSWindow?

    private override init() {}

    public func show(
        title: String,
        category: String,
        summary: String,
        guide: CmdyProductGuide,
        relativeTo parent: NSWindow?
    ) {
        dismiss()

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "\(title) — \(category)"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let summaryLabel = NSTextField(wrappingLabelWithString: summary)
        summaryLabel.font = .systemFont(ofSize: 12.5)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributedGuide(guide))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "Done", target: self, action: #selector(closePressed))
        close.keyEquivalent = "\r"
        close.bezelStyle = .rounded
        close.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titleLabel)
        root.addSubview(summaryLabel)
        root.addSubview(separator)
        root.addSubview(scroll)
        root.addSubview(close)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            separator.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -14),
            close.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])

        window.contentView = root
        detailWindow = window
        parentWindow = parent
        if let parent, parent.isVisible {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        detailWindow = nil
        parentWindow = nil
    }

    @objc private func closePressed() {
        dismiss()
    }

    private func dismiss() {
        guard let window = detailWindow else { return }
        if let parent = window.sheetParent ?? parentWindow {
            parent.endSheet(window)
        }
        window.orderOut(nil)
        window.close()
        detailWindow = nil
        parentWindow = nil
    }

    private func attributedGuide(_ guide: CmdyProductGuide) -> NSAttributedString {
        let result = NSMutableAttributedString()
        appendSection("What it does", lines: guide.whatItDoes, to: result)
        appendSection("Safety", lines: guide.safety, to: result)
        appendSection("Setup", lines: guide.setup, to: result, isLast: true)
        return result
    }

    private func appendSection(
        _ title: String,
        lines: [String],
        to result: NSMutableAttributedString,
        isLast: Bool = false
    ) {
        guard !lines.isEmpty else { return }

        let bodyColor = NSColor.labelColor.withAlphaComponent(0.82)
        for (index, line) in lines.enumerated() {
            let heading = index == 0 ? title : ""
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = index == lines.count - 1
                ? (isLast ? 0 : 18)
                : 8
            paragraph.headIndent = 112
            paragraph.firstLineHeadIndent = 0
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 112)]

            let start = result.length
            let value = heading + "\t" + line
                + ((isLast && index == lines.count - 1) ? "" : "\n")
            result.append(NSAttributedString(
                string: value,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5),
                    .foregroundColor: bodyColor,
                    .paragraphStyle: paragraph,
                ]))
            if !heading.isEmpty {
                result.addAttributes([
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: NSRange(location: start, length: (heading as NSString).length))
            }
        }
    }
}
