// Explicit user-requested permission setup, separate from timed observations.
// No Apple Event is sent and no clipboard is read or written.
import AppKit
import Carbon
import Darwin
import Foundation

@main private struct PastePermissionSetup {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, args[1] == "--request", let pid = Int32(args[2]), pid > 1 else {
            throw NSError(domain: "PastePermissionSetup", code: 1)
        }
        func verify() throws {
            let capacity = 4 * Int(MAXPATHLEN)
            var path = [CChar](repeating: 0, count: capacity)
            guard proc_pidpath(pid, &path, UInt32(capacity)) > 0,
                  String(cString: path) == args[3],
                  NSRunningApplication(processIdentifier: pid)?.isTerminated == false else {
                throw NSError(domain: "PastePermissionSetup", code: 2)
            }
        }
        try verify()
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        var records = [[String: Any]]()
        for (eventClass, eventID) in [(AEEventClass(kAECoreSuite), AEEventID(kAEGetData)),
                                     (AEEventClass(0x47687374), AEEventID(0x496e5478))] {
            try verify()
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, eventClass, eventID, true)
            records.append(["eventClass": eventClass, "eventID": eventID,
                            "askUserIfNeeded": true, "status": status])
            guard status == noErr else { break }
        }
        try verify()
        let authorized = records.count == 2 && records.allSatisfy { ($0["status"] as? Int32) == noErr }
        let result: [String: Any] = ["authorized": authorized, "pid": pid,
            "executable": args[3], "permissions": records, "appleEventsSent": false,
            "clipboardAccessed": false]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data); print("")
        exit(authorized ? 0 : 1)
    }
}
