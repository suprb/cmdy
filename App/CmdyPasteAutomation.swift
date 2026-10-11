import AppKit

/// A script command resolves its stable pane ID again at execution time. It
/// never falls back to whichever pane happens to be focused later.
@MainActor protocol CmdyScriptPasteTarget: AnyObject {
    var scriptTerminalID: String { get }
    var scriptTerminalName: String { get }
    func scriptPasteText(_ text: String) -> Bool
}

enum CmdyPasteAutomationFailure: Error {
    case wrongText, wrongTarget, closedTarget, policyCancelled, wrongThread

    var number: Int {
        switch self {
        case .wrongText, .wrongTarget: return -1700
        case .closedTarget: return -1728
        case .policyCancelled: return -128
        case .wrongThread: return -1708
        }
    }

    var message: String {
        switch self {
        case .wrongText: return "Input text requires a text value."
        case .wrongTarget: return "Input text requires one CMDY terminal."
        case .closedTarget: return "The target terminal is no longer available."
        case .policyCancelled: return "The terminal declined the paste."
        case .wrongThread: return "Input text must execute on the application thread."
        }
    }
}

@objc(CmdyScriptTerminal)
final class CmdyScriptTerminal: NSObject {
    @objc let id: String
    @objc let name: String
    private let resolve: @MainActor (String) -> (any CmdyScriptPasteTarget)?

    init(id: String, name: String,
         resolve: @escaping @MainActor (String) -> (any CmdyScriptPasteTarget)?) {
        self.id = id
        self.name = name
        self.resolve = resolve
        super.init()
    }

    @MainActor func inputText(_ text: String) throws {
        guard let target = resolve(id), target.scriptTerminalID == id else {
            throw CmdyPasteAutomationFailure.closedTarget
        }
        guard target.scriptPasteText(text) else {
            throw CmdyPasteAutomationFailure.policyCancelled
        }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let description = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description,
                                   containerSpecifier: nil, key: "cmdyScriptTerminals", uniqueID: id)
    }
}

@objc(CmdyScriptInputTextCommand)
final class CmdyScriptInputTextCommand: NSScriptCommand {
    @MainActor static func route(text: Any?, terminal: Any?) throws {
        guard let text = text as? String else { throw CmdyPasteAutomationFailure.wrongText }
        guard let terminal = terminal as? CmdyScriptTerminal else {
            throw CmdyPasteAutomationFailure.wrongTarget
        }
        try terminal.inputText(text)
    }

    override func performDefaultImplementation() -> Any? {
        guard Thread.isMainThread else {
            scriptErrorNumber = CmdyPasteAutomationFailure.wrongThread.number
            scriptErrorString = CmdyPasteAutomationFailure.wrongThread.message
            return nil
        }
        MainActor.assumeIsolated {
            do {
                try Self.route(text: directParameter, terminal: evaluatedArguments?["terminal"])
            } catch let failure as CmdyPasteAutomationFailure {
                scriptErrorNumber = failure.number
                scriptErrorString = failure.message
            } catch {
                scriptErrorNumber = NSInternalScriptError
                scriptErrorString = "The terminal could not accept input text."
            }
        }
        return nil
    }
}
