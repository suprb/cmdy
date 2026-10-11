// Owned, generated-text system-IME diagnostic. No user document or clipboard use.
import AppKit
import Carbon
import Darwin
import Foundation

let arguments = CommandLine.arguments
let modeID = "com.apple.inputmethod.Korean.2SetKorean"
let parentID = "com.apple.inputmethod.Korean"
let japaneseParentID = "com.apple.inputmethod.Kotoeri"
let japanesePaletteID = "com.apple.50onPaletteIM"
let prefsDomain = "com.apple.HIToolbox" as CFString
let prefsKey = "AppleEnabledInputSources" as CFString

func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let p = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
}
func identifier(_ s: TISInputSource) -> String { property(s, kTISPropertyInputSourceID) as? String ?? "" }
func sources() -> [TISInputSource] { TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource] }
func enabled(_ s: TISInputSource) -> Bool { (property(s, kTISPropertyInputSourceIsEnabled) as? NSNumber)?.boolValue == true }
func currentSource() -> String { identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) }
func enabledIDs() -> [String] { sources().filter(enabled).map(identifier).sorted() }
func rows() -> [[String: Any]] { CFPreferencesCopyAppValue(prefsKey, prefsDomain) as? [[String: Any]] ?? [] }
func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) }
func save(_ value: Any, _ path: String) throws { try json(value).write(to: URL(fileURLWithPath: path), options: .atomic) }
func emit(_ value: Any) throws { FileHandle.standardOutput.write(try json(value) + Data([10])) }
func pause(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "KoreanIMEProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

final class ReferenceTextView: NSTextView {
    var committed: [String] = []
    var insertions: [[String: Any]] = []
    var commands: [String] = []
    var markCalls = 0
    var keyEvents: [[String: Any]] = []
    override func keyDown(with event: NSEvent) {
        keyEvents.append(["keyCode": event.keyCode, "characters": event.characters ?? "",
                          "flags": event.modifierFlags.rawValue, "timestamp": event.timestamp,
                          "sourceAtKeyDown": currentSource(),
                          "currentContextMatches": NSTextInputContext.current === inputContext])
        super.keyDown(with: event)
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String ?? "")
        committed.append(text)
        insertions.append(["text": text, "replacementLocation": replacementRange.location,
                           "replacementLength": replacementRange.length])
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markCalls += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func doCommand(by selector: Selector) {
        commands.append(NSStringFromSelector(selector))
        // Keep the reference's Return action separate from IME-committed text.
        if selector == #selector(insertNewline(_:)) { return }
        super.doCommand(by: selector)
    }
}

func reference(_ directory: String) throws {
    let root = URL(fileURLWithPath: directory)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 620, height: 300),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "CMDY owned Korean input reference"
    window.isReleasedWhenClosed = false
    let text = ReferenceTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 300))
    text.isRichText = false
    text.font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
    window.contentView = text
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(text)
    app.activate(ignoringOtherApps: true)
    var commandError = ""
    var lastCommand: String?
    var lastData: Data?
    let timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
        let commandURL = root.appendingPathComponent("command.json")
        if let data = try? Data(contentsOf: commandURL),
           let c = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
           let id = c["id"], id != lastCommand {
            lastCommand = id
            commandError = ""
            if c["command"] == "yield-activation" {
                if let raw = c["targetPID"], let pid = Int32(raw), pid != getpid(), app.isActive,
                   let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated,
                   target.executableURL?.path == ProcessInfo.processInfo.environment["CMDY_IME_PEER_EXECUTABLE"] {
                    app.yieldActivation(to: target)
                } else { commandError = "activation target is not a live owned peer" }
            } else if c["command"] == "activate-window" {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(text)
                app.activate()
            } else if c["command"] == "clear" {
                text.inputContext?.discardMarkedText()
                text.string = ""
                text.setSelectedRange(NSRange(location: 0, length: 0))
                text.committed = []; text.insertions = []; text.commands = []; text.markCalls = 0; text.keyEvents = []
            } else if c["command"] == "activate-korean" {
                // AppKit activates the first responder's input context. Select
                // the source in its owning process without manually invoking
                // the system-managed activate/deactivate callbacks.
                text.inputContext?.selectedKeyboardInputSource = modeID
            } else if c["command"] == "activate-japanese" {
                text.inputContext?.selectedKeyboardInputSource = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
            } else if c["command"] == "stop" { app.terminate(nil) }
        }
        let state: [String: Any] = [
            "pid": getpid(), "bundleIdentifier": Bundle.main.bundleIdentifier ?? "", "string": text.string, "hasMarkedText": text.hasMarkedText(),
            "markedLocation": text.markedRange().location, "markedLength": text.markedRange().length,
            "committed": text.committed, "insertions": text.insertions,
            "commands": text.commands, "markCalls": text.markCalls, "keyEvents": text.keyEvents,
            "currentContextMatches": NSTextInputContext.current === text.inputContext,
            "selectedSource": text.inputContext?.selectedKeyboardInputSource ?? "",
            "globalSource": currentSource(), "firstResponderIsView": window.firstResponder === text,
            "keyWindow": window.isKeyWindow, "active": app.isActive,
            "lastCommand": lastCommand ?? "", "commandError": commandError, "clipboardAccessed": false,
        ]
        if let data = try? json(state), data != lastData {
            try? data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
            lastData = data
        }
    }
    app.run()
    timer.invalidate()
}

do {
    try require(arguments.count >= 2, "expected command")
    switch arguments[1] {
    case "reference":
        try require(arguments.count == 3, "reference directory")
        try reference(arguments[2])
    case "snapshot":
        try require(arguments.count == 3, "snapshot path")
        try save(["originalSource": currentSource(), "enabledIDs": enabledIDs(),
                  "enabledPreferences": rows(), "clipboardAccessed": false], arguments[2])
        try emit(["status": "saved"])
    case "enable":
        for id in [parentID, modeID] {
            let source = sources().first { identifier($0) == id }
            try require(source != nil, "requested installed source missing")
            if let source, !enabled(source) {
                let status = TISEnableInputSource(source)
                try require(status == noErr, "source enable failed: \(status)")
            }
        }
        try emit(["status": "enabled", "enabledIDs": enabledIDs()])
    case "select":
        let source = sources().first { identifier($0) == modeID }
        try require(source != nil, "Korean source missing")
        if let source { try require(TISSelectInputSource(source) == noErr, "selection failed") }
        pause(0.3)
        try emit(["status": "selected", "selectedSource": currentSource()])
    case "select-enabled":
        try require(arguments.count == 3, "select-enabled source ID")
        let source = sources().first { identifier($0) == arguments[2] && enabled($0) }
        try require(source != nil, "requested source is not already enabled")
        if let source { try require(TISSelectInputSource(source) == noErr, "selection failed") }
        pause(0.3)
        try require(currentSource() == arguments[2], "selected source differs")
        try emit(["status": "selected", "selectedSource": currentSource()])
    case "select-japanese":
        let beforeIDs = Set(enabledIDs())
        let japaneseModeID = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
        // TIS exposes separate KanaTyping and RomajiTyping parents; the bundle
        // identifier itself is not an input source on this macOS installation.
        for id in [japaneseParentID + ".RomajiTyping", japaneseModeID] {
            let source = sources().first { identifier($0) == id }
            try require(source != nil, "installed Japanese source missing: \(id)")
            if let source, !enabled(source) {
                try require(TISEnableInputSource(source) == noErr, "Japanese source enable failed")
            }
        }
        pause(0.3)
        let source = sources().first { identifier($0) == japaneseModeID }
        try require(source != nil, "Japanese mode missing")
        if let source { try require(TISSelectInputSource(source) == noErr, "Japanese selection failed") }
        pause(0.3)
        try require(currentSource() == japaneseModeID, "Japanese selected source differs")
        try emit(["status": "selected", "selectedSource": currentSource(),
                  "introducedIDs": Array(Set(enabledIDs()).subtracting(beforeIDs)).sorted()])
    case "inspect":
        try emit(["selectedSource": currentSource(), "enabledIDs": enabledIDs()])
    case "key", "key-hid":
        try require(arguments.count == 6, "key pid executable keycode tag")
        let pid = Int32(arguments[2])!, code = UInt16(arguments[4])!, tag = Int64(arguments[5])!
        try require(CGPreflightPostEventAccess(), "event permission unavailable")
        for down in [true, false] {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            try require(proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == arguments[3], "owned executable changed")
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "owned target lost foreground")
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            if arguments[1] == "key-hid" { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
            usleep(70_000)
        }
        try emit(["status": "posted", "pid": pid, "executable": arguments[3],
                  "keyCode": code, "events": 2, "route": arguments[1] == "key-hid" ? "postHID" : "postToPid",
                  "foregroundAndExecutableCheckedPerEvent": true])
    case "restore":
        try require(arguments.count == 4, "restore snapshot receipt")
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[2]))) as! [String: Any]
        let originalID = before["originalSource"] as! String
        let originalEnabled = before["enabledIDs"] as! [String]
        let originalRows = before["enabledPreferences"] as! [[String: Any]]
        if let original = sources().first(where: { identifier($0) == originalID }) {
            try require(TISSelectInputSource(original) == noErr, "original source restoration failed")
        }
        pause(0.2)
        let introduced = sources().filter { enabled($0) && !originalEnabled.contains(identifier($0)) }
        try require(introduced.allSatisfy {
            let id = identifier($0)
            return id.hasPrefix(parentID) || id.hasPrefix(japaneseParentID) || id == japanesePaletteID
        }, "unrelated enabled-source change; no preference rewrite")
        var disabled: [[String: Any]] = []
        for source in introduced.reversed() {
            disabled.append(["id": identifier(source), "status": TISDisableInputSource(source)])
        }
        pause(0.3)
        // Some input methods retain a preference row after TISDisable succeeds.
        // Remove only rows introduced by this run's Korean/Japanese services.
        let currentRows = rows()
        let filtered = currentRows.filter { row in
            let ownedFamily = [parentID, japaneseParentID, japanesePaletteID].contains(row["Bundle ID"] as? String ?? "")
            let existed = originalRows.contains { NSDictionary(dictionary: $0).isEqual(to: row) }
            return !ownedFamily || existed
        }
        let preferencesAdjusted = !NSArray(array: currentRows).isEqual(to: filtered)
        if preferencesAdjusted {
            CFPreferencesSetAppValue(prefsKey, filtered as CFArray, prefsDomain)
            try require(CFPreferencesAppSynchronize(prefsDomain), "enabled-source preference sync failed")
        }
        pause(0.3)
        let sourceRestored = currentSource() == originalID
        let enabledRestored = enabledIDs() == originalEnabled
        let preferencesRestored = NSArray(array: rows()).isEqual(to: originalRows)
        let result: [String: Any] = ["status": sourceRestored && enabledRestored && preferencesRestored ? "pass" : "failed",
            "sourceRestored": sourceRestored, "enabledSourcesRestored": enabledRestored,
            "enabledPreferencesRestored": preferencesRestored,
            "removedOnlyIntroducedTestIMEPreferenceRows": preferencesAdjusted,
            "nativeDisableResults": disabled, "clipboardAccessed": false]
        try save(result, arguments[3]); try emit(result)
        // TIS may retain stale enabled flags in this process after preferences sync.
        // The controller must verify restoration with a fresh-process snapshot.
        if !(sourceRestored && enabledRestored && preferencesRestored) { exit(1) }
    default: throw NSError(domain: "KoreanIMEProbe", code: 2)
    }
} catch {
    try? emit(["status": "failed", "error": String(describing: error)])
    exit(1)
}
