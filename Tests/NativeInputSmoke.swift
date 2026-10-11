// Physical key events for the owned native-input smoke app only. This helper
// never changes the input source, overrides Unicode, or launches an application.
// Build before GUI/timing work:
// swiftc -O -parse-as-library Tests/NativeInputSmoke.swift -o /tmp/native-input-key
import AppKit
import Carbon
import CoreGraphics
import CryptoKit

private struct SmokeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private struct PhysicalStroke {
    let code: CGKeyCode
    var flags: CGEventFlags = []

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.maskShift) { value |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { value |= UInt32(optionKey) }
        if flags.contains(.maskControl) { value |= UInt32(controlKey) }
        return value >> 8  // UCKeyTranslate uses the Carbon modifier byte.
    }

    var metadata: [String: Any] {
        ["keyCode": Int(code), "cgEventFlags": flags.rawValue,
         "carbonModifierState": carbonModifiers,
         "modifiers": [(CGEventFlags.maskShift, "shift"), (.maskAlternate, "option"),
                       (.maskControl, "control")].compactMap { flags.contains($0.0) ? $0.1 : nil }]
    }
}

private struct KeyboardLayout {
    let data: Data
    let keyboardType: UInt32

    init(source: TISInputSource) throws {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw SmokeError("the active input source has no Unicode keyboard layout data; no fallback layout was selected")
        }
        data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        guard data.count >= MemoryLayout<UCKeyboardLayout>.size else {
            throw SmokeError("the active Unicode keyboard layout data is incomplete")
        }
        keyboardType = UInt32(LMGetKbdType())
    }

    func translate(_ stroke: PhysicalStroke, deadState: UInt32 = 0) throws -> (text: String, state: UInt32) {
        var state = deadState
        var characters = [UniChar](repeating: 0, count: 255)
        var count = 0
        let status = data.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
                           stroke.code, UInt16(kUCKeyActionDown), stroke.carbonModifiers,
                           keyboardType, 0, &state, characters.count, &count, &characters)
        }
        guard status == noErr else { throw SmokeError("UCKeyTranslate failed with status \(status)") }
        return (String(utf16CodeUnits: characters, count: count), state)
    }

    func letter(_ text: String, preferredCode: CGKeyCode) throws -> PhysicalStroke {
        for code in [preferredCode] + (0..<128).map({ CGKeyCode($0) }).filter({ $0 != preferredCode }) {
            let stroke = PhysicalStroke(code: code)
            if let value = try? translate(stroke), value.text == text, value.state == 0 { return stroke }
        }
        throw SmokeError("the active layout has no unmodified physical key for \(text)")
    }
}

private struct InputSequence {
    let dead: PhysicalStroke
    let e: PhysicalStroke
    let a: PhysicalStroke
    let c: PhysicalStroke
    let metadata: [String: Any]

    init(layout: KeyboardLayout) throws {
        e = try layout.letter("e", preferredCode: 14)
        a = try layout.letter("a", preferredCode: 0)
        c = try layout.letter("c", preferredCode: 8)
        var candidate: (stroke: PhysicalStroke, pending: UInt32, committed: UInt32, afterProbe: UInt32)?
        var deadKeyDiagnostics: [String] = []
        // Prefer an unmodified native accent key, then Option, Shift, and
        // Shift-Option. No command/control shortcuts or global layout changes.
        for flags: CGEventFlags in [[], .maskAlternate, .maskShift, [.maskShift, .maskAlternate]] {
            for code in UInt16(0)..<UInt16(128) {
                let stroke = PhysicalStroke(code: code, flags: flags)
                guard let first = try? layout.translate(stroke), first.state != 0,
                      let committed = try? layout.translate(e, deadState: first.state) else { continue }
                deadKeyDiagnostics.append("key=\(code) modifiers=\(stroke.carbonModifiers) first=\(first.text.debugDescription) next=\(committed.text.debugDescription) state=\(committed.state)")
                // deadKeyState is opaque: Swedish retains layout bookkeeping
                // after emitting é. Verify a following plain a is unaffected
                // instead of assuming a successful commit resets it to zero.
                guard first.text.isEmpty, Array(committed.text.utf8) == [0xC3, 0xA9],
                      let after = try? layout.translate(a, deadState: committed.state),
                      Array(after.text.utf8) == [0x61] else { continue }
                candidate = (stroke, first.state, committed.state, after.state)
                break
            }
            if candidate != nil { break }
        }
        guard let candidate else {
            throw SmokeError("UCKeyTranslate found no silent acute dead key followed by an unmodified e that produces exactly UTF-8 c3a9; \(deadKeyDiagnostics.prefix(12).joined(separator: "; "))")
        }
        dead = candidate.stroke
        let physicalE = try layout.translate(PhysicalStroke(code: 14))
        guard physicalE.text == "e", physicalE.state == 0 else {
            throw SmokeError("physical Option-E Meta check needs key 14 charactersIgnoringModifiers to be e on this layout")
        }
        metadata = [
            "derivation": "UCKeyTranslate", "keyboardType": layout.keyboardType,
            "unicodeLayoutSHA256": SHA256.hash(data: layout.data).map { String(format: "%02x", $0) }.joined(),
            "deadKey": dead.metadata, "deadKeyOutputUTF8Hex": "", "deadKeyState": candidate.pending,
            "commitKey": e.metadata, "committedDeadKeyState": candidate.committed,
            "postCommitProbe": ["key": a.metadata, "outputUTF8Hex": "61", "state": candidate.afterProbe],
            "expectedText": "é", "expectedUTF8Hex": "c3a9",
            "asciiKey": a.metadata, "controlKey": PhysicalStroke(code: c.code, flags: .maskControl).metadata,
            "metaKey": PhysicalStroke(code: 14, flags: .maskAlternate).metadata,
            "metaCharactersIgnoringModifiers": physicalE.text, "metaExpectedUTF8Hex": "1b65",
        ]
    }
}

@main
private enum NativeInputSmoke {
    static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func inputSource() -> [String: Any] {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        func value(_ key: CFString) -> String {
            guard let raw = TISGetInputSourceProperty(source, key) else { return "" }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let identifier = value(kTISPropertyInputSourceID)
        return ["id": identifier, "name": value(kTISPropertyLocalizedName)]
    }

    @MainActor
    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch {
            emit(["ok": false, "error": String(describing: error), "inputSource": inputSource()])
            exit(2)
        }
    }

    @MainActor
    static func run() async throws {
        let args = CommandLine.arguments
        let initialSource = inputSource()
        let active = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let sequence = try InputSequence(layout: KeyboardLayout(source: active))
        if args.count == 2, args[1] == "inspect" {
            emit(["ok": true, "inputSource": initialSource,
                  "sequence": sequence.metadata,
                  "postEventAuthorized": CGPreflightPostEventAccess()])
            return
        }
        guard args.count == 4, let pid = Int32(args[1]), pid > 0,
              let windowID = UInt32(args[2]),
              ["dead-key", "plain-e", "ascii-control", "meta-e"].contains(args[3]) else {
            throw SmokeError("usage: native-input-key inspect | PID WINDOW_ID dead-key/plain-e/ascii-control/meta-e")
        }
        guard CGPreflightPostEventAccess() else {
            throw SmokeError("event-posting permission is not available; no permission prompt was opened")
        }
        let modifiers: CGEventFlags = [.maskShift, .maskAlternate, .maskControl, .maskCommand, .maskAlphaShift]
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else {
            throw SmokeError("release physical modifier keys and turn off Caps Lock before running the smoke")
        }
        func validateTarget() throws {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                throw SmokeError("the owned application must remain frontmost")
            }
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] ?? []
            guard windows.contains(where: {
                ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
                    && ($0[kCGWindowNumber as String] as? UInt32) == windowID
                    && ($0[kCGWindowLayer as String] as? Int) == 0
            }) else { throw SmokeError("the visible target window is not owned by the supplied PID") }
            guard inputSource()["id"] as? String == initialSource["id"] as? String else {
                throw SmokeError("the active input source changed during the smoke")
            }
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw SmokeError("could not allocate the private keyboard event source")
        }
        var events: [[String: Any]] = []
        func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags,
                  flagsChanged: Bool = false) async throws {
            try validateTarget()
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                throw SmokeError("could not create the physical key event")
            }
            event.flags = flags
            if flagsChanged { event.type = .flagsChanged }
            event.postToPid(pid)
            events.append(["keyCode": Int(code), "down": down, "flags": flags.rawValue,
                           "flagsChanged": flagsChanged])
            try await Task.sleep(nanoseconds: 35_000_000)
        }
        func key(_ stroke: PhysicalStroke) async throws {
            let modifiers: [(CGKeyCode, CGEventFlags)] = [(56, .maskShift), (58, .maskAlternate), (59, .maskControl)]
            let pressed = modifiers.filter { stroke.flags.contains($0.1) }
            var flags: CGEventFlags = []
            for (code, flag) in pressed {
                flags.insert(flag)
                try await post(code, down: true, flags: flags, flagsChanged: true)
            }
            try await post(stroke.code, down: true, flags: stroke.flags)
            try await post(stroke.code, down: false, flags: stroke.flags)
            for (code, flag) in pressed.reversed() {
                flags.remove(flag)
                try await post(code, down: false, flags: flags, flagsChanged: true)
            }
        }
        switch args[3] {
        case "dead-key": try await key(sequence.dead)
        case "meta-e": try await key(PhysicalStroke(code: 14, flags: .maskAlternate))
        case "plain-e": try await key(sequence.e)
        case "ascii-control":
            try await key(sequence.a)
            try await key(PhysicalStroke(code: sequence.c.code, flags: .maskControl))
        default: break
        }
        try validateTarget()
        emit(["ok": true, "pid": pid, "windowID": windowID, "phase": args[3],
              "inputSource": initialSource, "sequence": sequence.metadata,
              "events": events, "unicodeOverride": false])
    }
}
