import AppKit

private final class SurfacePanelButton: NSButton {
    enum Role {
        case tab
        case close
        case action
        case destructive
    }

    var role: Role = .action { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }
    var panelFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var panelForeground = NSColor.white { didSet { needsDisplay = true } }
    var panelAccent = NSColor.systemBlue { didSet { needsDisplay = true } }

    convenience init(title: String, role: Role, target: AnyObject?, action: Selector?) {
        self.init(title: title, target: target, action: action)
        self.role = role
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: panelFont]).width
        let padding: CGFloat = role == .close ? 12 : 16
        return NSSize(width: ceil(width + padding), height: max(20, ceil(panelFont.pointSize * 1.55)))
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = (cell as? NSButtonCell)?.isHighlighted == true
        if isActive || highlighted {
            panelForeground.withAlphaComponent(highlighted ? 0.20 : 0.14).setFill()
            bounds.fill()
        }

        let color: NSColor
        if !isEnabled { color = panelForeground.withAlphaComponent(0.30) }
        else if role == .destructive { color = .systemRed }
        else if isActive { color = panelAccent }
        else if role == .close { color = panelForeground.withAlphaComponent(0.55) }
        else { color = panelForeground }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: panelFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .ligature: 0,
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(
            in: NSRect(x: 0, y: floor((bounds.height - height) / 2),
                       width: bounds.width, height: height),
            withAttributes: attributes)
    }
}

private final class SurfaceTableHeaderCell: NSTableHeaderCell {
    var panelFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    var panelForeground = NSColor.white

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        panelForeground.withAlphaComponent(0.18).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.minY,
               width: cellFrame.width, height: 1).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: panelFont,
            .foregroundColor: panelForeground.withAlphaComponent(0.72),
            .ligature: 0,
        ]
        let height = (stringValue as NSString).size(withAttributes: attributes).height
        (stringValue as NSString).draw(
            in: NSRect(x: cellFrame.minX + 4,
                       y: floor(cellFrame.midY - height / 2),
                       width: max(0, cellFrame.width - 8), height: height),
            withAttributes: attributes)
    }
}

private final class SurfaceTableRowView: NSTableRowView {
    var panelForeground = NSColor.white

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        panelForeground.withAlphaComponent(0.14).setFill()
        bounds.fill()
    }
}

/// Host-rendered Surface Protocol v1 UI. Extensions provide data and semantic
/// actions; Cmdy owns controls, theme, focus, accessibility, and resource
/// behavior. This view never evaluates extension-provided code or markup.
public final class NativeSurfaceView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public private(set) var document: SurfaceDocument
    public var onDismiss: (() -> Void)?
    public var onHeightChanged: ((CGFloat) -> Void)?
    public var onAction: ((_ action: SurfaceAction, _ itemID: String?,
                           _ values: [String: SurfaceValue]) -> Void)?
    /// Match the terminal grid exactly, as the popup menus do.
    public var metrics: (() -> (font: NSFont, rowHeight: CGFloat, originX: CGFloat))? {
        didSet { refreshMetrics() }
    }
    /// A tab-scoped theme supplied by the terminal host.
    public var themeOverride: Theme? {
        didSet { applyTheme() }
    }

    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let surfaceButton = SurfacePanelButton(
        title: "Surface", role: .tab, target: nil, action: nil)
    private let textButton = SurfacePanelButton(
        title: "Text", role: .tab, target: nil, action: nil)
    private let closeButton = SurfacePanelButton(
        title: "×", role: .close, target: nil, action: nil)
    private let headerSpacer = NSView()
    private let content = NSView()
    private let actionBar = NSStackView()
    private var activeContent: NSView?
    private var table: NSTableView?
    private var formControls: [String: NSControl] = [:]
    private var buttonActions: [ObjectIdentifier: (SurfaceAction, String?)] = [:]
    private var actionMenus: [ObjectIdentifier: ([SurfaceAction], String)] = [:]
    private var preferencesObserver: NSObjectProtocol?
    private let actionsColumnID = "$cmdy.actions"
    private var renderedFontSignature = ""
    private var hostFont: NSFont?
    private var hostRowHeight: CGFloat = 0
    private var hostOriginX: CGFloat = 10
    private var chromeLeadingConstraints: [NSLayoutConstraint] = []
    private var chromeTrailingConstraints: [NSLayoutConstraint] = []
    private var headerHeightConstraint: NSLayoutConstraint?
    private var actionBarHeightConstraint: NSLayoutConstraint?

    private var rowHeight: CGFloat {
        hostRowHeight > 0 ? hostRowHeight : max(20, ceil(bodyFont.boundingRectForFont.height * 1.15))
    }

    public init(document: SurfaceDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setupChrome()
        render()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .cmdyPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.renderedFontSignature != self.fontSignature { self.render() }
            else { self.applyTheme() }
        }
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    public override var acceptsFirstResponder: Bool { true }

    public func update(_ document: SurfaceDocument) {
        guard document.id == self.document.id else { return }
        self.document = document
        render()
    }

    public func dismiss() { onDismiss?() }
    var isShowingTextRepresentation: Bool { textButton.isActive }
    var selectedTableRow: Int { table?.selectedRow ?? -1 }

    private func setupChrome() {
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 0
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = bodyFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = bodyFont
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .right
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)

        surfaceButton.isActive = true
        surfaceButton.target = self
        surfaceButton.action = #selector(surfaceRepresentationPressed)
        surfaceButton.setAccessibilityLabel("Show native surface")
        textButton.target = self
        textButton.action = #selector(textRepresentationPressed)
        textButton.setAccessibilityLabel("Show text output")

        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityLabel("Close surface")

        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(stateLabel)
        header.setCustomSpacing(12, after: titleLabel)
        header.setCustomSpacing(12, after: stateLabel)
        header.addArrangedSubview(surfaceButton)
        header.addArrangedSubview(textButton)
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(headerSpacer)
        headerSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 6).isActive = true
        header.addArrangedSubview(closeButton)

        content.translatesAutoresizingMaskIntoConstraints = false
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 8
        actionBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(content)
        addSubview(actionBar)
        let headerLeading = header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        let headerTrailing = header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        let contentLeading = content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        let contentTrailing = content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        let actionLeading = actionBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        let actionTrailing = actionBar.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -10)
        let headerHeight = header.heightAnchor.constraint(equalToConstant: rowHeight)
        let actionHeight = actionBar.heightAnchor.constraint(equalToConstant: rowHeight)
        chromeLeadingConstraints = [headerLeading, contentLeading, actionLeading]
        chromeTrailingConstraints = [headerTrailing, contentTrailing, actionTrailing]
        headerHeightConstraint = headerHeight
        actionBarHeightConstraint = actionHeight
        NSLayoutConstraint.activate([
            headerLeading,
            headerTrailing,
            header.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            headerHeight,
            contentLeading,
            contentTrailing,
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            actionLeading,
            actionTrailing,
            actionBar.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 5),
            actionBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            actionHeight,
        ])
    }

    private func render() {
        titleLabel.stringValue = document.title
        stateLabel.stringValue = "\(document.kind.rawValue) · \(document.state.rawValue)"
        activeContent?.removeFromSuperview()
        activeContent = nil
        table = nil
        formControls.removeAll()
        buttonActions.removeAll()
        actionMenus.removeAll()
        actionBar.arrangedSubviews.forEach {
            actionBar.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let view: NSView
        if textButton.isActive {
            view = textView(document.fallback)
        } else {
            switch document.kind {
            case .list, .table, .task: view = tableView()
            case .diff: view = diffView(document.diff ?? "")
            case .form: view = formView()
            case .text: view = textView(document.summary ?? document.fallback)
            }
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        activeContent = view

        if surfaceButton.isActive {
            document.actions.forEach { actionBar.addArrangedSubview(actionButton($0)) }
        }
        if actionBar.arrangedSubviews.isEmpty {
            let summary = NSTextField(labelWithString: document.summary ?? "")
            summary.font = bodyFont
            summary.textColor = .secondaryLabelColor
            actionBar.addArrangedSubview(summary)
        }
        applyTheme()
        renderedFontSignature = fontSignature
        invalidateIntrinsicContentSize()
        onHeightChanged?(preferredHeight)
    }

    public var preferredHeight: CGFloat {
        let count: Int
        switch document.kind {
        case .task: count = document.tasks.count
        case .list, .table: count = document.rows.count
        case .form: count = document.fields.count
        case .diff: count = min(12, max(4, (document.diff ?? "").split(separator: "\n").count))
        case .text: count = min(10, max(3, document.fallback.split(separator: "\n").count))
        }
        return min(390, max(150, 74 + CGFloat(min(12, max(3, count))) * rowHeight))
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    private func tableView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = NSTableView()
        table.headerView = document.kind == .table ? NSTableHeaderView() : nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)

        let columns: [SurfaceColumn]
        switch document.kind {
        case .table:
            columns = document.columns
        case .task:
            columns = [
                SurfaceColumn(id: "status", title: "Status", width: 84),
                SurfaceColumn(id: "label", title: "Task"),
                SurfaceColumn(id: "detail", title: "Detail"),
            ]
        default:
            columns = document.columns.isEmpty
                ? [SurfaceColumn(id: "label", title: "Item")]
                : document.columns
        }
        var displayedColumns = columns
        let hasItemActions = document.kind == .task
            ? document.tasks.contains { !$0.actions.isEmpty }
            : document.rows.contains { !$0.actions.isEmpty }
        if hasItemActions {
            displayedColumns.append(SurfaceColumn(id: actionsColumnID, title: "", width: 160))
        }
        for column in displayedColumns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            let headerCell = SurfaceTableHeaderCell(textCell: column.title)
            headerCell.panelFont = bodyFont
            headerCell.panelForeground = Preferences.shared.theme.ns(
                Preferences.shared.theme.foreground)
            tableColumn.headerCell = headerCell
            tableColumn.minWidth = 60
            if let width = column.width { tableColumn.width = max(60, min(600, width)) }
            table.addTableColumn(tableColumn)
        }
        if table.tableColumns.count == 1 { table.tableColumns[0].resizingMask = .autoresizingMask }
        scroll.documentView = table
        self.table = table
        return scroll
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SurfaceTableRowView()
        view.panelForeground = Preferences.shared.theme.ns(Preferences.shared.theme.foreground)
        return view
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        document.kind == .task ? document.tasks.count : document.rows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let id = tableColumn.identifier.rawValue
        if id == actionsColumnID {
            let itemID: String
            let actions: [SurfaceAction]
            if document.kind == .task {
                guard row < document.tasks.count else { return nil }
                itemID = document.tasks[row].id
                actions = document.tasks[row].actions
            } else {
                guard row < document.rows.count else { return nil }
                itemID = document.rows[row].id
                actions = document.rows[row].actions
            }
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 4
            if actions.count <= 2 {
                actions.forEach { stack.addArrangedSubview(actionButton($0, itemID: itemID)) }
            } else {
                let menu = NSPopUpButton(frame: .zero, pullsDown: true)
                menu.addItem(withTitle: "Actions")
                actions.forEach { menu.addItem(withTitle: $0.title) }
                menu.target = self
                menu.action = #selector(itemActionPicked(_:))
                menu.controlSize = .small
                menu.setAccessibilityLabel("Actions for \(itemID)")
                actionMenus[ObjectIdentifier(menu)] = (actions, itemID)
                stack.addArrangedSubview(menu)
            }
            return stack
        }
        let value: String
        if document.kind == .task {
            guard row < document.tasks.count else { return nil }
            let task = document.tasks[row]
            switch id {
            case "status": value = taskSymbol(task.status) + " " + task.status.rawValue
            case "label": value = task.label
            case "detail":
                if let progress = task.progress {
                    value = "\(Int(max(0, min(1, progress)) * 100))% " + (task.detail ?? "")
                } else { value = task.detail ?? duration(task.durationMs) }
            default: value = ""
            }
        } else {
            guard row < document.rows.count else { return nil }
            let item = document.rows[row]
            value = item.cells[id]?.description
                ?? (id == "label" ? item.cells["title"]?.description
                    ?? item.cells.values.first?.description : nil)
                ?? ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.font = bodyFont
        label.lineBreakMode = .byTruncatingTail
        if let alignment = document.columns.first(where: { $0.id == id })?.alignment {
            switch alignment {
            case .leading: label.alignment = .left
            case .center: label.alignment = .center
            case .trailing: label.alignment = .right
            }
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func textView(_ text: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = bodyFont
        view.string = text
        view.textContainerInset = NSSize(width: 5, height: 5)
        scroll.documentView = view
        return scroll
    }

    private func diffView(_ text: String) -> NSView {
        let scroll = textView(text)
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
        ])
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let color: NSColor?
            if line.hasPrefix("+") && !line.hasPrefix("+++") { color = .systemGreen }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { color = .systemRed }
            else if line.hasPrefix("@@") { color = .systemBlue }
            else { color = nil }
            if let color {
                attributed.addAttribute(.foregroundColor, value: color,
                                        range: NSRange(location: offset, length: line.utf16.count))
            }
            offset += line.utf16.count + 1
        }
        view.textStorage?.setAttributedString(attributed)
        return scroll
    }

    private func formView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for field in document.fields {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let label = NSTextField(labelWithString: field.label + (field.required ? " *" : ""))
            label.font = bodyFont
            let labelWidth = label.widthAnchor.constraint(equalToConstant: 150)
            labelWidth.priority = .defaultHigh
            labelWidth.isActive = true
            row.addArrangedSubview(label)
            let control: NSControl
            switch field.kind {
            case .toggle:
                let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                if case .bool(let value) = field.value { button.state = value ? .on : .off }
                control = button
            case .choice:
                let popup = NSPopUpButton()
                popup.addItems(withTitles: field.options)
                popup.selectItem(withTitle: field.value.description)
                control = popup
            case .secure:
                let input = NSSecureTextField(string: field.value.description)
                input.placeholderString = field.placeholder
                control = input
            case .text:
                let input = NSTextField(string: field.value.description)
                input.placeholderString = field.placeholder
                control = input
            }
            control.isEnabled = !field.disabled
            control.setAccessibilityLabel(field.label)
            if !(control is NSButton) {
                control.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            }
            formControls[field.id] = control
            row.addArrangedSubview(control)
            stack.addArrangedSubview(row)
        }
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scroll.documentView = documentView
        return scroll
    }

    private func actionButton(_ action: SurfaceAction, itemID: String? = nil) -> NSButton {
        let role: SurfacePanelButton.Role = action.style == .destructive ? .destructive : .action
        let button = SurfacePanelButton(
            title: action.title, role: role, target: self, action: #selector(actionPressed(_:)))
        button.isActive = action.style == .primary
        button.panelFont = bodyFont
        button.isEnabled = !action.disabled && document.state != .disconnected
        buttonActions[ObjectIdentifier(button)] = (action, itemID)
        button.setAccessibilityLabel(action.title)
        button.toolTip = action.title
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        return button
    }

    @objc private func actionPressed(_ sender: NSButton) {
        guard let (action, itemID) = buttonActions[ObjectIdentifier(sender)] else { return }
        perform(action, itemID: itemID)
    }

    @objc private func itemActionPicked(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0,
              let (actions, itemID) = actionMenus[ObjectIdentifier(sender)] else { return }
        let index = sender.indexOfSelectedItem - 1
        sender.selectItem(at: 0)
        guard index < actions.count else { return }
        perform(actions[index], itemID: itemID)
    }

    @objc private func tableDoubleClicked() {
        guard let table, table.clickedRow >= 0 else { return }
        _ = performPrimaryAction(at: table.clickedRow)
    }

    @discardableResult
    private func performPrimaryAction(at row: Int) -> Bool {
        if document.kind == .task, row < document.tasks.count,
           let action = document.tasks[row].actions.first {
            perform(action, itemID: document.tasks[row].id)
            return true
        } else if row < document.rows.count,
                  let action = document.rows[row].actions.first {
            perform(action, itemID: document.rows[row].id)
            return true
        }
        return false
    }

    private func perform(_ action: SurfaceAction, itemID: String?) {
        guard !action.disabled else { return }
        let values = formValues()
        let missing = document.fields.filter { field in
            guard field.required else { return false }
            switch values[field.id] ?? field.value {
            case .string(let value):
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .bool(let value): return !value
            case .number: return false
            case .null: return true
            }
        }
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Complete required fields"
            alert.informativeText = missing.map(\.label).joined(separator: ", ")
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        if let confirmation = action.confirmation, action.effect != .localView {
            let alert = NSAlert()
            alert.messageText = action.title
            alert.informativeText = confirmation
            alert.addButton(withTitle: action.title)
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        onAction?(action, itemID, values)
    }

    private func formValues() -> [String: SurfaceValue] {
        var values: [String: SurfaceValue] = [:]
        for (id, control) in formControls {
            switch control {
            case let button as NSButton: values[id] = .bool(button.state == .on)
            case let popup as NSPopUpButton: values[id] = .string(popup.titleOfSelectedItem ?? "")
            case let input as NSTextField: values[id] = .string(input.stringValue)
            default: break
            }
        }
        return values
    }

    @objc private func surfaceRepresentationPressed() {
        guard !surfaceButton.isActive else { return }
        surfaceButton.isActive = true
        textButton.isActive = false
        render()
    }

    @objc private func textRepresentationPressed() {
        guard !textButton.isActive else { return }
        surfaceButton.isActive = false
        textButton.isActive = true
        render()
    }

    @objc private func closePressed() { dismiss() }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control]).isEmpty {
            switch event.keyCode {
            case 53: // escape
                dismiss()
                return
            case 123: // left
                surfaceRepresentationPressed()
                return
            case 124: // right
                textRepresentationPressed()
                return
            case 125: // down
                if !moveTableSelection(by: 1) { _ = scrollActiveContent(by: rowHeight) }
                return
            case 126: // up
                if !moveTableSelection(by: -1) { _ = scrollActiveContent(by: -rowHeight) }
                return
            case 115: // home
                if !selectTableEdge(first: true) { _ = scrollActiveContent(toEnd: false) }
                return
            case 119: // end
                if !selectTableEdge(first: false) { _ = scrollActiveContent(toEnd: true) }
                return
            case 116: // page up
                _ = scrollActiveContent(by: -pageScrollDistance)
                return
            case 121: // page down
                _ = scrollActiveContent(by: pageScrollDistance)
                return
            case 36, 76: // return / keypad enter
                if let table, table.selectedRow >= 0 {
                    _ = performPrimaryAction(at: table.selectedRow)
                    return
                }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    private func moveTableSelection(by delta: Int) -> Bool {
        guard surfaceButton.isActive, let table else { return false }
        let count = numberOfRows(in: table)
        guard count > 0 else { return false }
        let current = table.selectedRow
        let next: Int
        if current < 0 { next = delta > 0 ? 0 : count - 1 }
        else { next = min(count - 1, max(0, current + delta)) }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
        return true
    }

    private func selectTableEdge(first: Bool) -> Bool {
        guard surfaceButton.isActive, let table else { return false }
        let count = numberOfRows(in: table)
        guard count > 0 else { return false }
        let row = first ? 0 : count - 1
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        return true
    }

    private var pageScrollDistance: CGFloat {
        guard let scroll = activeContent as? NSScrollView else { return rowHeight * 8 }
        return max(rowHeight, scroll.contentView.bounds.height - rowHeight)
    }

    @discardableResult
    private func scrollActiveContent(by distance: CGFloat) -> Bool {
        guard let scroll = activeContent as? NSScrollView,
              let documentView = scroll.documentView else { return false }
        let clip = scroll.contentView
        let maxY = max(0, documentView.bounds.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(maxY, max(0, origin.y + distance))
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }

    @discardableResult
    private func scrollActiveContent(toEnd: Bool) -> Bool {
        guard let scroll = activeContent as? NSScrollView,
              let documentView = scroll.documentView else { return false }
        let maxY = max(0, documentView.bounds.height - scroll.contentView.bounds.height)
        var origin = scroll.contentView.bounds.origin
        origin.y = toEnd ? maxY : 0
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    public func refreshMetrics() {
        if let measured = metrics?() {
            hostFont = measured.font
            hostRowHeight = max(1, measured.rowHeight)
            hostOriginX = max(0, measured.originX)
        } else {
            hostFont = nil
            hostRowHeight = 0
            hostOriginX = 10
        }
        let inset = max(8, hostOriginX)
        chromeLeadingConstraints.forEach { $0.constant = inset }
        chromeTrailingConstraints.forEach { $0.constant = -inset }
        headerHeightConstraint?.constant = rowHeight
        actionBarHeightConstraint?.constant = rowHeight
        render()
    }

    private func applyTheme() {
        let theme = themeOverride ?? Preferences.shared.theme
        let background = theme.ns(theme.background)
        let foreground = theme.ns(theme.foreground)
        let accent = theme.ns(theme.ansi[12])
        layer?.backgroundColor = background.withAlphaComponent(0.38).cgColor
        layer?.borderWidth = 0
        titleLabel.font = bodyFont
        stateLabel.font = bodyFont
        titleLabel.textColor = foreground
        stateLabel.textColor = foreground.withAlphaComponent(0.55)
        [surfaceButton, textButton, closeButton].forEach {
            $0.panelFont = bodyFont
            $0.panelForeground = foreground
            $0.panelAccent = accent
        }
        actionBar.arrangedSubviews.compactMap { $0 as? SurfacePanelButton }.forEach {
            $0.panelFont = bodyFont
            $0.panelForeground = foreground
            $0.panelAccent = accent
        }
        table?.backgroundColor = .clear
        table?.gridColor = foreground.withAlphaComponent(0.18)
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let foreground = Preferences.shared.theme.ns(Preferences.shared.theme.foreground)
        foreground.withAlphaComponent(0.18).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: max(0, bounds.height - 1),
               width: bounds.width, height: 1).fill()
    }

    private func taskSymbol(_ status: SurfaceTask.Status) -> String {
        switch status {
        case .pending: return "○"
        case .running: return "●"
        case .passed: return "✓"
        case .failed: return "×"
        case .skipped: return "–"
        case .cancelled: return "■"
        }
    }

    private func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "" }
        return milliseconds < 1_000 ? "\(milliseconds)ms"
            : String(format: "%.1fs", Double(milliseconds) / 1_000)
    }

    private var fontSignature: String {
        let font = bodyFont
        return "\(font.fontName)|\(font.pointSize)|\(rowHeight)|\(hostOriginX)"
    }

    private var bodyFont: NSFont {
        hostFont ?? Preferences.shared.resolvedFont()
    }
}

/// App-side pane host used by the extension manager without importing the app
/// target. A Surface stays associated with a semantic command block even though
/// its live controls occupy a bounded drawer below the grid.
public protocol ExtensionSurfaceHost: AnyObject {
    var extensionSurfacePaneID: String { get }
    func resolveSurfaceBlock(_ requested: String) -> String?
    @discardableResult
    func presentExtensionSurface(_ document: SurfaceDocument) -> NativeSurfaceView
    func dismissExtensionSurface(_ view: NativeSurfaceView)
}
