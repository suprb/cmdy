// Public scripting transport shared by both terminals. No clipboard, typing,
// activation, bundle-ID lookup, or application launch fallback exists here.
import AppKit
import Carbon
import Darwin
import Foundation

enum PasteAppleEvent {
    static let eventClass: AEEventClass = 0x47687374 // Ghst
    static let eventID: AEEventID = 0x496e5478       // InTx
    static let targetKey: AEKeyword = 0x47497454    // GItT
    static let terminalClass: DescType = 0x4774726d // Gtrm
    static let idProperty: DescType = 0x49442020    // ID<space><space>
    static let sendOptions: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract, .dontRecord]

    static func object(want: DescType, form: OSType, data: NSAppleEventDescriptor,
                       container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        guard let value = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            throw ScrollProbeError("cannot encode public terminal object specifier")
        }
        return value
    }

    static func terminal(_ id: String) throws -> NSAppleEventDescriptor {
        try object(want: terminalClass, form: OSType(formUniqueID), data: NSAppleEventDescriptor(string: id))
    }

    static func input(pid: Int32, terminalID: String, text: String) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: text), forKeyword: AEKeyword(keyDirectObject))
        event.setParam(try terminal(terminalID), forKeyword: targetKey)
        return event
    }

    static func terminalIDs(pid: Int32) throws -> NSAppleEventDescriptor {
        // An absolute ordinal is not an enumerated selector. Cocoa correctly
        // tries to coerce any other descriptor type to an integer index.
        guard let all = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal),
            data: NSAppleEventDescriptor(enumCode: OSType(kAEAll)).data) else {
            throw ScrollProbeError("cannot encode absolute ordinal for terminal query")
        }
        let every = try object(want: terminalClass, form: OSType(formAbsolutePosition),
                               data: all)
        let property = try object(want: DescType(cProperty), form: OSType(formPropertyID),
                                  data: NSAppleEventDescriptor(typeCode: idProperty), container: every)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(property, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
}

final class PasteAppleEventClient {
    typealias Permission = (NSAppleEventDescriptor, AEEventClass, AEEventID, Bool) -> OSStatus
    typealias Send = (NSAppleEventDescriptor, NSAppleEventDescriptor.SendOptions, Double) throws -> NSAppleEventDescriptor
    let pid: Int32
    private let permission: Permission
    private let send: Send
    private var authorized = false
    private(set) var permissions: [[String: Any]] = []

    init(pid: Int32, permission: @escaping Permission = { target, eventClass, eventID, ask in
        AEDeterminePermissionToAutomateTarget(target.aeDesc, eventClass, eventID, ask)
    }, send: @escaping Send = { event, options, timeout in
        try event.sendEvent(options: options, timeout: timeout)
    }) {
        self.pid = pid; self.permission = permission; self.send = send
    }

    func preflight() throws {
        authorized = false
        try scrollRequire(pid > 1, "paste target must be a pinned running process")
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        for (eventClass, eventID) in [(AEEventClass(kAECoreSuite), AEEventID(kAEGetData)),
                                     (PasteAppleEvent.eventClass, PasteAppleEvent.eventID)] {
            let started = mach_absolute_time()
            let status = permission(target, eventClass, eventID, false)
            permissions.append(["eventClass": eventClass, "eventID": eventID, "targetPID": pid,
                "askUserIfNeeded": false, "status": status, "startedTicks": started,
                "finishedTicks": mach_absolute_time()])
            try scrollRequire(status == noErr,
                "existing Apple Event authorization is required; no prompt or fallback is permitted")
        }
        authorized = true
    }

    func dispatch(_ event: NSAppleEventDescriptor, timeout: Double) throws -> NSAppleEventDescriptor {
        try scrollRequire(authorized, "Apple Event dispatch requires a successful no-prompt permission preflight")
        let reply = try send(event, PasteAppleEvent.sendOptions, timeout)
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            // Remote error strings may contain user text. Retain only the code.
            throw ScrollProbeError("public input/query Apple Event returned error code \(error.int32Value)")
        }
        return reply
    }

    func soleTerminalID() throws -> String {
        let reply = try dispatch(PasteAppleEvent.terminalIDs(pid: pid), timeout: 5)
        guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
              value.descriptorType == DescType(typeAEList), value.numberOfItems == 1,
              let id = value.atIndex(1)?.stringValue, !id.isEmpty, id.utf8.count <= 512,
              id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ScrollProbeError("public query must identify exactly one owned terminal with a stable ID")
        }
        return id
    }
}

func pastePayload(_ token: String, _ sequence: Int) -> String {
    if sequence == 0 { return "CMDYPASTE-OFF/\(token)/" }
    let prefix = String(format: "CMDYPASTE/%@/%02d/", token, sequence)
    let pattern = "terminal-λ世界🙂0123456789 "
    let remaining = 65_536 - prefix.utf8.count
    return prefix + String(repeating: pattern, count: remaining / pattern.utf8.count)
        + String(repeating: "x", count: remaining % pattern.utf8.count)
}
