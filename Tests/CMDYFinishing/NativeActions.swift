import AppKit
import ApplicationServices
import Carbon
import Foundation

func fail(_ message: String) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: ["ok": false, "error": message]), encoding: .utf8)!)
    exit(1)
}
func emit(_ value: [String: Any]) {
    print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
}
func rectangle(_ rect: CGRect) -> [String: Double] {
    ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
}
let args = CommandLine.arguments
let ownedEventTag = ProcessInfo.processInfo.environment["CMDY_NATIVE_EVENT_TAG"].flatMap(Int64.init)
func tagOwnedEvent(_ event: CGEvent) {
    if let ownedEventTag { event.setIntegerValueField(.eventSourceUserData, value: ownedEventTag) }
}
guard args.count >= 2 else { fail("actions: sources, drag, scroll, key, hide, show") }
if args[1] == "sources" {
    let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    let values = list.compactMap { item -> [String: String]? in
        guard let id = TISGetInputSourceProperty(item, kTISPropertyInputSourceID),
              let name = TISGetInputSourceProperty(item, kTISPropertyLocalizedName) else { return nil }
        return ["id": Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String,
                "name": Unmanaged<CFString>.fromOpaque(name).takeUnretainedValue() as String]
    }
    emit(["ok": true, "sources": values]); exit(0)
}
guard args.count >= 3, let pid = Int32(args[2]),
      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
      app.executableURL?.lastPathComponent == "cmdy" else { fail("owned CMDY process is absent") }
if args[1] == "hide" {
    let changed = app.hide()
    let deadline = Date().addingTimeInterval(2)
    while !app.isHidden && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
    emit(["ok": app.isHidden, "changed": changed]); exit(0)
}
if args[1] == "show" {
    _ = app.unhide(); let changed = app.activate(options: [])
    let deadline = Date().addingTimeInterval(2)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
    emit(["ok": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "changed": changed]); exit(0)
}
guard CGPreflightPostEventAccess(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    fail("event permission or owned foreground is absent")
}
let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
let owned = windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
guard let owned, let raw = owned[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: raw) else { fail("owned visible window absent") }
let started = ProcessInfo.processInfo.systemUptime
func ensureOwned() {
    guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        fail("owned foreground changed during action")
    }
}
func pointer(_ type: CGEventType, _ point: CGPoint) {
    ensureOwned()
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { fail("event creation failed") }
    tagOwnedEvent(event)
    event.post(tap: .cghidEventTap)
}
switch args[1] {
case "drag":
    guard args.count == 7, let x = Double(args[3]), let y = Double(args[4]),
          let dx = Double(args[5]), let dy = Double(args[6]), abs(dx) <= 500, abs(dy) <= 500 else { fail("invalid drag") }
    let start = CGPoint(x: x, y: y), end = CGPoint(x: x + dx, y: y + dy)
    guard bounds.insetBy(dx: -4, dy: -4).contains(start), CGDisplayBounds(CGMainDisplayID()).contains(end) else { fail("drag leaves owned window/display") }
    pointer(.mouseMoved, start); usleep(100_000)
    pointer(.leftMouseDown, start); usleep(60_000)
    for step in 1...40 {
        let fraction = Double(step) / 40
        pointer(.leftMouseDragged, CGPoint(x: x + dx * fraction, y: y + dy * fraction))
        usleep(12_500)
    }
    pointer(.leftMouseUp, end)
case "scroll":
    guard args.count == 6, let x = Double(args[3]), let y = Double(args[4]), let delta = Int32(args[5]), abs(delta) <= 40 else { fail("invalid scroll") }
    let point = CGPoint(x: x, y: y)
    guard bounds.contains(point) else { fail("scroll leaves owned window") }
    pointer(.mouseMoved, point); usleep(100_000)
    for step in 0..<24 {
        ensureOwned()
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { fail("scroll creation failed") }
        event.location = point
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: step == 0 ? 1 : step == 23 ? 4 : 2)
        tagOwnedEvent(event)
        event.post(tap: .cghidEventTap); usleep(12_500)
    }
case "key":
    guard args.count == 5, let code = UInt16(args[3]), let flags = UInt64(args[4]) else { fail("invalid key") }
    for down in [true, false] {
        ensureOwned()
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("key creation failed") }
        event.flags = CGEventFlags(rawValue: flags); tagOwnedEvent(event)
        event.postToPid(pid); usleep(25_000)
    }
default: fail("unknown action")
}
emit(["ok": true, "pid": pid, "action": args[1], "windowBefore": rectangle(bounds),
      "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started])
