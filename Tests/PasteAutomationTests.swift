import AppKit

// The test runner inserts the exact current surface paste method here. The
// surrounding test doubles avoid launching an application or creating views.
class PasteSurface {
    var shellPid: Int32 = 42
}
final class CmdyTerminalSurface: PasteSurface {
    final class Terminal { var bracketedPaste = true }
    let terminal = Terminal()
    var onPasteRequest: ((String) -> String?)?
    var events: [String] = []
    var bytes: [UInt8] = []
    func cancelTextComposition() { events.append("composition-cancelled") }
    func emitUserInput(_ value: [UInt8]) { events.append("input-emitted"); bytes += value }
    // PASTE_IMPLEMENTATION
}
final class TerminalPane {
    let paneId: String
    let surface: PasteSurface
    var window: NSWindow? { nil }
    init(_ id: String, _ surface: PasteSurface) { paneId = id; self.surface = surface }
}
final class TerminalWindowController { var panes: [TerminalPane] = [] }
final class AppDelegate: NSObject, NSApplicationDelegate {
    var allControllers: [TerminalWindowController] = []
}

@main
enum PasteAutomationTests {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            precondition(value(), label)
        }
        func failure(_ expected: CmdyPasteAutomationFailure, _ body: () throws -> Void) {
            do { try body(); preconditionFailure("Expected rejection") }
            catch let value as CmdyPasteAutomationFailure { expect(value.number == expected.number, "wrong rejection") }
            catch { preconditionFailure("Unexpected failure: \(error)") }
        }
        let surface = CmdyTerminalSurface()
        let id = UUID().uuidString
        let pane = TerminalPane(id, surface)
        var current: TerminalPane? = pane
        let terminal = CmdyScriptTerminal(id: id, name: "Generated fixture") { requested in
            requested == id ? current : nil
        }
        let text = "generated λ世界🙂\nsecond line"
        surface.onPasteRequest = { value in
            surface.events.append("paste-policy")
            expect(value == text, "text was altered before policy")
            return "approved\n🙂"
        }
        guard let definition = NSScriptCommandDescription(suiteName: "CMDY Suite", commandName: "input text",
            dictionary: ["AppleEventClassCode": "Ghst", "AppleEventCode": "InTx",
                         "CommandClass": "CmdyScriptInputTextCommand"]) else {
            preconditionFailure("Cannot construct the actual script command")
        }
        let command = CmdyScriptInputTextCommand(commandDescription: definition)
        command.directParameter = text
        command.arguments = ["terminal": terminal]
        _ = command.execute()
        expect(command.scriptErrorNumber == 0, "actual NSScriptCommand rejected valid input")
        expect(surface.events == ["paste-policy", "composition-cancelled", "input-emitted"], "paste path or ordering changed")
        expect(surface.bytes == Array("\u{1b}[200~approved\n🙂\u{1b}[201~".utf8), "normal replacement/framing changed")

        surface.events = []; surface.bytes = []
        surface.onPasteRequest = { _ in surface.events.append("paste-policy"); return nil }
        let cancelled = CmdyScriptInputTextCommand(commandDescription: definition)
        cancelled.directParameter = text; cancelled.arguments = ["terminal": terminal]
        _ = cancelled.execute()
        expect(cancelled.scriptErrorNumber == -128, "paste cancellation was not returned to AppleScript")
        expect(surface.events == ["paste-policy"] && surface.bytes.isEmpty, "cancelled paste changed composition or input")
        expect(!(cancelled.scriptErrorString ?? "").contains(text), "error exposed supplied text")

        surface.events = []; surface.onPasteRequest = nil; surface.terminal.bracketedPaste = false
        try CmdyScriptInputTextCommand.route(text: text, terminal: terminal)
        expect(surface.bytes == Array(text.utf8), "unbracketed text changed or gained Return")
        surface.bytes = []; surface.terminal.bracketedPaste = true
        try CmdyScriptInputTextCommand.route(text: "", terminal: terminal)
        expect(surface.bytes == Array("\u{1b}[200~\u{1b}[201~".utf8), "empty paste behavior changed")
        surface.bytes = []
        let large = String(repeating: "λ世界🙂", count: 8_192)
        try CmdyScriptInputTextCommand.route(text: large, terminal: terminal)
        expect(surface.bytes == Array(("\u{1b}[200~" + large + "\u{1b}[201~").utf8), "large Unicode paste changed")

        surface.bytes = []; surface.events = []
        failure(.wrongText) { try CmdyScriptInputTextCommand.route(text: 42, terminal: terminal) }
        failure(.wrongTarget) { try CmdyScriptInputTextCommand.route(text: text, terminal: nil) }
        failure(.wrongTarget) { try CmdyScriptInputTextCommand.route(text: text, terminal: [terminal]) }
        failure(.wrongTarget) { try CmdyScriptInputTextCommand.route(text: text, terminal: NSObject()) }
        current = nil
        failure(.closedTarget) { try CmdyScriptInputTextCommand.route(text: text, terminal: terminal) }
        let closed = CmdyScriptInputTextCommand(commandDescription: definition)
        closed.directParameter = text; closed.arguments = ["terminal": terminal]
        _ = closed.execute()
        expect(closed.scriptErrorNumber == -1728, "actual command did not reject stale target")
        current = TerminalPane(UUID().uuidString, surface)
        failure(.closedTarget) { try CmdyScriptInputTextCommand.route(text: text, terminal: terminal) }
        current = pane; surface.shellPid = 0
        failure(.policyCancelled) { try CmdyScriptInputTextCommand.route(text: text, terminal: terminal) }
        expect(surface.bytes.isEmpty && surface.events.isEmpty, "rejected target received input")
        print("Paste automation: \(checks) checks passed; no application, window, clipboard, or Apple Event was opened")
    }
}
