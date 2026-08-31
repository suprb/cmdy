import AppKit

/// One persistent, Extension-owned command row at the bottom of a terminal
/// pane. Unlike `InlinePanel`, this does not take over the palette surface: it
/// stays available while the companion is open and temporarily yields when a
/// transient panel or Surface Protocol document is presented.
public typealias ExtensionControlBarAction = BottomMenuItem

public final class ExtensionControlBar: NSView {
    public var onAction: ((String) -> Void)?
    public var onSubmit: ((String) -> Void)?
    public var onEscape: (() -> Void)?
    public var onInputFocusChanged: ((Bool) -> Void)?
    /// A tab-scoped theme supplied by the terminal host.
    public var themeOverride: Theme? {
        didSet { refreshMetrics() }
    }
    public var onHeightChanged: ((CGFloat) -> Void)?
    public var metrics: (() -> (font: NSFont, rowHeight: CGFloat, originX: CGFloat))?

    private var actions: [ExtensionControlBarAction] = []
    private var actionFrames: [NSRect] = []
    private var inputFrame = NSRect.zero
    private var value = ""
    private var placeholder = ""
    private var inputFirst = false
    private var cursorUTF16 = 0
    private var selectsAll = false
    /// Action indices come first; `actions.count` is the URL/input target.
    private var keyboardTarget = 0
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var rowHeight: CGFloat = 18
    private var padX: CGFloat = 10
    private var padY: CGFloat = 6
    private var background = NSColor.black
    private var foreground = NSColor.white
    private var dim = NSColor.white.withAlphaComponent(0.55)
    private var accent = NSColor.systemBlue
    private var cursorColor = NSColor.white
    private let rowTextLayout = TerminalRowTextLayout()
    private var preferenceObserver: NSObjectProtocol?
    private var cursorPulseTimer: Timer?
    private var visibleInputStartUTF16 = 0
    private var visibleInputOriginX: CGFloat = 0

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .cmdyPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMetrics() }
        }
        refreshMetrics()
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        cursorPulseTimer?.invalidate()
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    public var preferredHeight: CGFloat {
        max(1, rowHeight) + 2 * max(0, padY)
    }

    public func configure(actions: [ExtensionControlBarAction],
                          placeholder: String = "", value: String = "",
                          inputFirst: Bool = false) {
        self.actions = actions
        self.placeholder = placeholder
        self.value = value
        self.inputFirst = inputFirst
        cursorUTF16 = (value as NSString).length
        selectsAll = false
        keyboardTarget = actions.count
        refreshMetrics()
    }

    public func setValue(_ value: String) {
        guard window?.firstResponder !== self else { return }
        self.value = value
        cursorUTF16 = (value as NSString).length
        selectsAll = false
        needsDisplay = true
    }

    public func setPlaceholder(_ value: String) {
        placeholder = value
        needsDisplay = true
    }

    public func focusInput() {
        keyboardTarget = actions.count
        cursorUTF16 = (value as NSString).length
        selectsAll = !value.isEmpty
        window?.makeFirstResponder(self)
        updateCursorPulseTimer()
        needsDisplay = true
    }

    /// Enter the persistent bottom menu from the terminal canvas. Horizontal
    /// arrows can then move between actions and Return activates the choice.
    public func focusFirstAction() {
        guard let index = actions.firstIndex(where: \.isEnabled) else {
            focusInput()
            return
        }
        keyboardTarget = index
        selectsAll = false
        window?.makeFirstResponder(self)
        updateCursorPulseTimer()
        needsDisplay = true
    }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onInputFocusChanged?(true)
            updateCursorPulseTimer()
            needsDisplay = true
        }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        cursorPulseTimer?.invalidate()
        cursorPulseTimer = nil
        onInputFocusChanged?(false)
        needsDisplay = true
        return super.resignFirstResponder()
    }

    public func refreshMetrics() {
        let theme = themeOverride ?? Preferences.shared.theme
        if let value = metrics?() {
            font = value.font
            rowHeight = max(1, value.rowHeight)
            padX = max(0, value.originX)
        } else {
            font = Preferences.shared.resolvedFont()
            rowHeight = ceil(font.boundingRectForFont.height * Preferences.shared.lineHeight)
            padX = max(0, Preferences.shared.contentMargin)
        }
        padY = max(0, Preferences.shared.contentMargin)
        background = theme.ns(theme.background)
        foreground = theme.ns(theme.foreground)
        dim = foreground.withAlphaComponent(0.56)
        accent = theme.ns(theme.ansi[10])
        cursorColor = theme.ns(theme.cursor)
        layer?.backgroundColor = background.cgColor
        updateCursorPulseTimer()
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
        onHeightChanged?(preferredHeight)
    }

    public override func layout() {
        super.layout()
        let contentHeight = max(1, rowHeight)
        let actionWidths = actions.map { ceil(textWidth($0.title)) + 12 }
        if inputFirst {
            let actionsWidth = actionWidths.reduce(0, +)
                + CGFloat(max(0, actions.count - 1)) * 4
            var x = max(padX, bounds.width - padX - actionsWidth)
            let inputTrailingGap: CGFloat = actions.isEmpty ? 0 : 13
            inputFrame = NSRect(
                x: padX, y: padY,
                width: max(0, x - inputTrailingGap - padX),
                height: contentHeight)
            actionFrames = actionWidths.map { width in
                let frame = NSRect(x: x, y: padY, width: width, height: contentHeight)
                x += width + 4
                return frame
            }
        } else {
            var x = padX
            actionFrames = actionWidths.map { width in
                let frame = NSRect(x: x, y: padY, width: width, height: contentHeight)
                x += width + 4
                return frame
            }
            let inputX = min(bounds.width, x + 6)
            inputFrame = NSRect(x: inputX, y: padY,
                                width: max(0, bounds.width - inputX - padX),
                                height: contentHeight)
        }
        window?.invalidateCursorRects(for: self)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        background.setFill()
        bounds.fill()
        foreground.withAlphaComponent(0.18).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let focused = window?.firstResponder === self
        for (index, action) in actions.enumerated() where actionFrames.indices.contains(index) {
            let frame = actionFrames[index]
            if focused, keyboardTarget == index {
                foreground.withAlphaComponent(0.12).setFill()
                frame.fill()
            }
            drawText(action.title, in: frame,
                     color: action.isEnabled ? (keyboardTarget == index && focused
                         ? foreground : accent) : dim)
        }
        if inputFirst, !actions.isEmpty, inputFrame.width > 0 {
            foreground.withAlphaComponent(0.12).setFill()
            NSRect(x: inputFrame.maxX + 6, y: padY,
                   width: 1, height: max(1, rowHeight)).fill()
        } else if inputFrame.minX > padX {
            foreground.withAlphaComponent(0.12).setFill()
            NSRect(x: inputFrame.minX - 7, y: padY,
                   width: 1, height: max(1, rowHeight)).fill()
        }
        drawInput(focused: focused && keyboardTarget == actions.count)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = actionFrames.firstIndex(where: { $0.contains(point) }) {
            keyboardTarget = index
            selectsAll = false
            needsDisplay = true
            performCurrentSelection()
            return
        }
        guard inputFrame.contains(point) else { return }
        keyboardTarget = actions.count
        selectsAll = false
        cursorUTF16 = inputIndex(at: point.x)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(inputFrame, cursor: .iBeam)
        for frame in actionFrames { addCursorRect(frame, cursor: .pointingHand) }
    }

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if event.keyCode == 48 {
            cycleKeyboardTarget(reverse: flags.contains(.shift))
            return
        }
        if [36, 76].contains(event.keyCode) {
            performCurrentSelection()
            return
        }
        if keyboardTarget < actions.count {
            switch event.keyCode {
            case 123: cycleKeyboardTarget(reverse: true); return
            case 124: cycleKeyboardTarget(reverse: false); return
            case 126:
                onEscape?()
                return
            case 125:
                keyboardTarget = actions.count
                cursorUTF16 = (value as NSString).length
                selectsAll = !value.isEmpty
                needsDisplay = true
                return
            default:
                if let typed = printableCharacters(from: event) {
                    keyboardTarget = actions.count
                    insert(typed)
                    return
                }
                super.keyDown(with: event)
                return
            }
        }

        if flags == [.command] {
            switch chars {
            case "a", "l":
                selectsAll = !value.isEmpty
                cursorUTF16 = (value as NSString).length
                needsDisplay = true
                return
            case "c":
                if selectsAll, !value.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                return
            case "x":
                if selectsAll, !value.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    replaceSelection(with: "")
                }
                return
            case "v":
                if let pasted = NSPasteboard.general.string(forType: .string) {
                    insert(pasted.replacingOccurrences(of: "\n", with: " "))
                }
                return
            default: break
            }
        }

        switch event.keyCode {
        case 51: deleteBackward(); return
        case 117: deleteForward(); return
        case 123:
            if flags.contains(.command) { moveToStart() } else { moveLeft() }
            return
        case 124:
            if flags.contains(.command) { moveToEnd() } else { moveRight() }
            return
        case 115: moveToStart(); return
        case 119: moveToEnd(); return
        case 126: cycleKeyboardTarget(reverse: true); return
        case 125: cycleKeyboardTarget(reverse: false); return
        default: break
        }
        if let typed = printableCharacters(from: event) {
            insert(typed)
            return
        }
        super.keyDown(with: event)
    }

    // Internal hooks used by focused tests without synthesizing AppKit events.
    var currentValue: String { value }
    var currentInputFrame: NSRect { inputFrame }

    func frameForAction(id: String) -> NSRect? {
        guard let index = actions.firstIndex(where: { $0.id == id }),
              actionFrames.indices.contains(index) else { return nil }
        return actionFrames[index]
    }

    func performAction(id: String) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        keyboardTarget = index
        performCurrentSelection()
    }

    func submitCurrentValue() {
        keyboardTarget = actions.count
        performCurrentSelection()
    }

    private func performCurrentSelection() {
        if actions.indices.contains(keyboardTarget) {
            let action = actions[keyboardTarget]
            if action.isEnabled { onAction?(action.id) }
        } else {
            onSubmit?(value)
        }
    }

    private func cycleKeyboardTarget(reverse: Bool) {
        let count = actions.count + 1
        guard count > 0 else { return }
        for _ in 0..<count {
            keyboardTarget = (keyboardTarget + (reverse ? count - 1 : 1)) % count
            if keyboardTarget == actions.count || actions[keyboardTarget].isEnabled {
                break
            }
        }
        selectsAll = false
        if keyboardTarget == actions.count {
            cursorUTF16 = (value as NSString).length
        }
        needsDisplay = true
    }

    private func printableCharacters(from event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let chars = event.characters, !chars.isEmpty,
              !chars.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return chars
    }

    private func insert(_ text: String) {
        replaceSelection(with: text)
    }

    private func replaceSelection(with text: String) {
        let ns = value as NSString
        let range = selectsAll
            ? NSRange(location: 0, length: ns.length)
            : NSRange(location: min(cursorUTF16, ns.length), length: 0)
        value = ns.replacingCharacters(in: range, with: text)
        cursorUTF16 = range.location + (text as NSString).length
        selectsAll = false
        needsDisplay = true
    }

    private func deleteBackward() {
        if selectsAll { replaceSelection(with: ""); return }
        let ns = value as NSString
        guard cursorUTF16 > 0, ns.length > 0 else { return }
        let range = ns.rangeOfComposedCharacterSequence(at: cursorUTF16 - 1)
        value = ns.replacingCharacters(in: range, with: "")
        cursorUTF16 = range.location
        needsDisplay = true
    }

    private func deleteForward() {
        if selectsAll { replaceSelection(with: ""); return }
        let ns = value as NSString
        guard cursorUTF16 < ns.length else { return }
        let range = ns.rangeOfComposedCharacterSequence(at: cursorUTF16)
        value = ns.replacingCharacters(in: range, with: "")
        needsDisplay = true
    }

    private func moveLeft() {
        selectsAll = false
        let ns = value as NSString
        guard cursorUTF16 > 0, ns.length > 0 else { return }
        cursorUTF16 = ns.rangeOfComposedCharacterSequence(at: cursorUTF16 - 1).location
        needsDisplay = true
    }

    private func moveRight() {
        selectsAll = false
        let ns = value as NSString
        guard cursorUTF16 < ns.length else { return }
        cursorUTF16 = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: cursorUTF16))
        needsDisplay = true
    }

    private func moveToStart() {
        selectsAll = false
        cursorUTF16 = 0
        needsDisplay = true
    }

    private func moveToEnd() {
        selectsAll = false
        cursorUTF16 = (value as NSString).length
        needsDisplay = true
    }

    private func drawInput(focused: Bool) {
        guard inputFrame.width > 0 else { return }
        let ns = value as NSString
        cursorUTF16 = min(cursorUTF16, ns.length)
        let cursorWidth = max(6, textWidth("M"))
        visibleInputStartUTF16 = visibleStart(for: ns, cursorWidth: cursorWidth)
        let shownRange = NSRange(location: visibleInputStartUTF16,
                                 length: ns.length - visibleInputStartUTF16)
        let shown = ns.substring(with: shownRange)
        visibleInputOriginX = inputFrame.minX
        let textY = textOriginY(rowTop: inputFrame.minY)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: inputFrame).addClip()
        let prefixRange = NSRange(location: visibleInputStartUTF16,
                                  length: max(0, cursorUTF16 - visibleInputStartUTF16))
        let prefix = ns.substring(with: prefixRange)
        let cursorX = inputFrame.minX + textWidth(prefix)

        if selectsAll, !value.isEmpty, focused {
            foreground.withAlphaComponent(0.14).setFill()
            NSRect(x: inputFrame.minX, y: inputFrame.minY,
                   width: min(inputFrame.width, textWidth(shown)),
                   height: rowHeight).fill()
        }
        if value.isEmpty {
            let placeholderX = inputFrame.minX + (focused ? cursorWidth + 5 : 0)
            (placeholder as NSString).draw(
                at: NSPoint(x: placeholderX, y: textY),
                withAttributes: [.font: font, .foregroundColor: dim])
        } else {
            (shown as NSString).draw(
                at: NSPoint(x: inputFrame.minX, y: textY),
                withAttributes: [.font: font, .foregroundColor: foreground])
        }

        if focused, !selectsAll {
            drawCursor(x: cursorX, y: inputFrame.minY, ns: ns)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCursor(x: CGFloat, y: CGFloat, ns: NSString) {
        let style = Preferences.shared.cursorStyleName.lowercased()
        let alpha: CGFloat
        if style.hasPrefix("blink") {
            alpha = 0.5 * (1 + cos(2 * .pi
                * CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1.2) / 1.2))
        } else {
            alpha = 1
        }
        let cursorWidth = max(6, textWidth("M"))
        let cursorFrame = cursorVerticalFrame(rowTop: y)
        cursorColor.withAlphaComponent(0.88 * alpha).setFill()
        if style.contains("bar") {
            NSRect(x: x, y: cursorFrame.minY,
                   width: 2, height: cursorFrame.height).fill()
        } else if style.contains("underline") {
            NSRect(x: x, y: cursorFrame.maxY - 2,
                   width: cursorWidth, height: 2).fill()
        } else {
            NSRect(x: x, y: cursorFrame.minY,
                   width: cursorWidth, height: cursorFrame.height).fill()
            if cursorUTF16 < ns.length {
                let range = ns.rangeOfComposedCharacterSequence(at: cursorUTF16)
                let character = ns.substring(with: range)
                (character as NSString).draw(
                    at: NSPoint(x: x, y: textOriginY(rowTop: y)),
                    withAttributes: [.font: font, .foregroundColor: background])
            }
        }
    }

    private func visibleStart(for ns: NSString, cursorWidth: CGFloat) -> Int {
        guard inputFrame.width > cursorWidth + 2 else { return cursorUTF16 }
        var start = 0
        while start < cursorUTF16 {
            let range = NSRange(location: start, length: cursorUTF16 - start)
            if textWidth(ns.substring(with: range)) + cursorWidth <= inputFrame.width {
                break
            }
            start = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: start))
        }
        return start
    }

    private func inputIndex(at x: CGFloat) -> Int {
        let ns = value as NSString
        var index = visibleInputStartUTF16
        var cursorX = visibleInputOriginX
        while index < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: index)
            let width = textWidth(ns.substring(with: range))
            if x < cursorX + width / 2 { return index }
            cursorX += width
            index = NSMaxRange(range)
        }
        return ns.length
    }

    private func drawText(_ string: String, in frame: NSRect, color: NSColor) {
        (string as NSString).draw(
            at: NSPoint(x: frame.minX + 6,
                        y: textOriginY(rowTop: frame.minY)),
            withAttributes: [.font: font, .foregroundColor: color])
    }

    private func textOriginY(rowTop: CGFloat) -> CGFloat {
        rowTextLayout.drawOriginY(
            rowTop: rowTop,
            baselineFromTop: textBaselineFromTop,
            font: font)
    }

    private var textBaselineFromTop: CGFloat {
        rowHeight - ceil(abs(font.descender) + font.leading)
    }

    private func cursorVerticalFrame(rowTop: CGFloat) -> NSRect {
        rowTextLayout.cursorVerticalFrame(
            rowTop: rowTop,
            rowHeight: rowHeight,
            baselineFromTop: textBaselineFromTop,
            font: font)
    }

    private func textWidth(_ string: String) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private func updateCursorPulseTimer() {
        let shouldPulse = Preferences.shared.cursorStyleName.hasPrefix("blink")
            && window?.firstResponder === self
        guard shouldPulse else {
            cursorPulseTimer?.invalidate()
            cursorPulseTimer = nil
            return
        }
        guard cursorPulseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, self.window?.firstResponder === self,
                  self.window?.occlusionState.contains(.visible) == true else { return }
            self.needsDisplay = true
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        cursorPulseTimer = timer
    }
}
