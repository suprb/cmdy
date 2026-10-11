// Diagnostic for the isolated generated fixture; no clipboard or paste input.
import AppKit
import Carbon
import Foundation

struct ScrollProbeError: Error { let message: String; init(_ value: String) { message = value } }
func scrollRequire(_ value: Bool, _ message: String) throws {
    if !value { throw ScrollProbeError(message) }
}

@main private struct PasteScriptingProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
            throw ScrollProbeError("owned PID required")
        }
        let every = try PasteAppleEvent.object(want: PasteAppleEvent.terminalClass,
            form: OSType(formAbsolutePosition), data: NSAppleEventDescriptor(enumCode: OSType(kAEAll)))
        let list = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        list.setParam(every, forKeyword: AEKeyword(keyDirectObject))
        for (name, event) in [("terminals", list), ("terminal IDs", try PasteAppleEvent.terminalIDs(pid: pid))] {
            let reply = try event.sendEvent(options: PasteAppleEvent.sendOptions, timeout: 5)
            print(name, "request", event.description, "reply", reply.description)
        }
    }
}
