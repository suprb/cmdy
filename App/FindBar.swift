import AppKit
import CmdyKit

/// Compact search bar that lives in the window's top band (⌘F). Enter finds
/// the next match, Shift-Enter the previous, Esc closes. "Aa" toggles case
/// sensitivity, ".*" regex mode; the counter shows current/total matches.
final class FindBar: NSView, NSSearchFieldDelegate {

    private let field = NSSearchField()
    private let counter = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    private var caseSensitive = false
    private var regex = false
    private weak var caseMenuItem: NSMenuItem?
    private weak var regexMenuItem: NSMenuItem?

    /// Current options, assembled from the toggle buttons.
    var options: TermSearchOptions {
        TermSearchOptions(caseSensitive: caseSensitive, regex: regex)
    }

    /// (term, forward) — run a search step. Result reported back via indicate().
    var onSearch: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    var searchTerm: String { field.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7

        field.placeholderString = "Find"
        field.controlSize = .regular
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(fieldAction)
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        let searchMenu = NSMenu(title: "Search Options")
        let caseItem = NSMenuItem(title: "Match Case", action: #selector(toggleMatchCase(_:)),
                                  keyEquivalent: "")
        let regexItem = NSMenuItem(title: "Regular Expression",
                                   action: #selector(toggleRegex(_:)), keyEquivalent: "")
        caseItem.target = self
        regexItem.target = self
        searchMenu.addItem(caseItem)
        searchMenu.addItem(regexItem)
        field.searchMenuTemplate = searchMenu
        caseMenuItem = caseItem
        regexMenuItem = regexItem

        let controls: [(NSButton, String, String, Selector)] = [
            (previousButton, "chevron.up", "Previous match", #selector(previousMatch)),
            (nextButton, "chevron.down", "Next match", #selector(nextMatch)),
            (closeButton, "xmark", "Close search", #selector(closeSearch)),
        ]
        for (button, symbol, tip, action) in controls {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.title = ""
            button.isBordered = false
            button.controlSize = .small
            button.toolTip = tip
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }

        counter.font = .systemFont(ofSize: 10, weight: .medium)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .center
        counter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(counter)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 24),
            field.trailingAnchor.constraint(equalTo: counter.leadingAnchor, constant: -2),
            counter.centerYAnchor.constraint(equalTo: centerYAnchor),
            counter.widthAnchor.constraint(equalToConstant: 44),
            counter.trailingAnchor.constraint(equalTo: previousButton.leadingAnchor, constant: -2),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 25),
            previousButton.heightAnchor.constraint(equalToConstant: 24),
            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 25),
            nextButton.heightAnchor.constraint(equalToConstant: 24),
            nextButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 25),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func beginSearch(in window: NSWindow?, term: String? = nil) {
        if let term { field.stringValue = term }
        window?.makeFirstResponder(field)
        field.selectText(nil)
        counter.stringValue = ""
        if !field.stringValue.isEmpty { onSearch?(field.stringValue, true) }
    }

    func step(forward: Bool) -> Bool {
        guard !field.stringValue.isEmpty else { return false }
        onSearch?(field.stringValue, forward)
        return true
    }

    /// Report the last step's result: "2/17", or a red 0/0 when nothing matched.
    func indicate(found: Bool, index: Int, total: Int) {
        if total == 0 {
            counter.stringValue = field.stringValue.isEmpty ? "" : "0/0"
            counter.textColor = .systemRed
        } else {
            counter.stringValue = index > 0 ? "\(index)/\(total)" : "\(total)"
            counter.textColor = .secondaryLabelColor
        }
    }

    func applyTheme(_ theme: Theme, onBorder: Bool) {
        let foreground = theme.ns(theme.foreground)
        layer?.backgroundColor = theme.ns(theme.background)
            .withAlphaComponent(onBorder ? 0.92 : 0.62).cgColor
        counter.textColor = foreground.withAlphaComponent(0.58)
        for button in [previousButton, nextButton, closeButton] {
            button.contentTintColor = foreground.withAlphaComponent(0.72)
        }
    }

    @objc private func previousMatch() { _ = step(forward: false) }
    @objc private func nextMatch() { _ = step(forward: true) }
    @objc private func closeSearch() { onClose?() }

    @objc private func toggleMatchCase(_ sender: NSMenuItem) {
        caseSensitive.toggle()
        sender.state = caseSensitive ? .on : .off
        if !field.stringValue.isEmpty { fieldAction() }
    }

    @objc private func toggleRegex(_ sender: NSMenuItem) {
        regex.toggle()
        sender.state = regex ? .on : .off
        if !field.stringValue.isEmpty { fieldAction() }
    }

    @objc private func fieldAction() {
        let term = field.stringValue
        guard !term.isEmpty else { return }
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        onSearch?(term, !backwards)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {   // Esc
            onClose?()
            return true
        }
        return false
    }
}
