// An owned, temporary app activates itself and cooperatively returns focus to
// the exact test process. It sends no input and does not select an input source.
import AppKit
import Carbon
import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let pid = Int32(args[1]), pid > 0 else { exit(2) }
let executable = args[2]
let receipt = URL(fileURLWithPath: args[3])
var record: [String: Any] = ["status": "starting", "pid": getpid(), "targetPID": pid,
                            "targetExecutable": executable, "inputEventsPosted": 0,
                            "inputSourceSelected": false, "clipboardAccessed": false]
func save() { if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: receipt, options: .atomic) } }
func source() -> String {
    let value = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let raw = TISGetInputSourceProperty(value, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}
func owned() -> NSRunningApplication? {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == executable,
          let value = NSRunningApplication(processIdentifier: pid), !value.isTerminated else { return nil }
    return value
}
func fail(_ reason: String) -> Never { record["status"] = "failed"; record["error"] = reason; save(); exit(1) }
guard let target = owned(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { fail("exact owned target must initially be foreground") }
let launchDate = target.launchDate
record["initialSource"] = source()
record["initialForegroundPID"] = pid
record["targetLaunchDate"] = launchDate?.timeIntervalSince1970 ?? 0
save()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 16, y: 16, width: 160, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "CMDY owned IME focus check"
window.isReleasedWhenClosed = false
window.makeKeyAndOrderFront(nil)
var phase = 0
var deadline = ProcessInfo.processInfo.systemUptime + 4
var returnAfter: TimeInterval = 0
// AppKit must dispatch its application events, including activation, throughout
// the handshake. A Foundation-only nested run loop does not do that.
let timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
    guard let live = owned(), live.launchDate == launchDate else { fail("target identity changed") }
    let now = ProcessInfo.processInfo.systemUptime
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    record["lastObservedForegroundPID"] = front
    record["bridgeActive"] = app.isActive
    record["targetActive"] = live.isActive
    if now > deadline { fail(phase < 2 ? "bridge did not receive focus" : "focus did not return to target") }
    if phase == 0 {
        app.activate(ignoringOtherApps: true)
        phase = 1
    } else if phase == 1 && front == getpid() && app.isActive && !live.isActive {
        record["awayForegroundPID"] = getpid()
        record["awayUptime"] = now
        returnAfter = now + 0.2
        deadline = now + 4
        phase = 2
        save()
    } else if phase == 2 && now >= returnAfter {
        app.yieldActivation(to: live)
        record["returnRequestAccepted"] = live.activate(from: NSRunningApplication.current, options: [])
        phase = 3
    } else if phase == 3 && front == pid && live.isActive && !app.isActive {
        record["returnedForegroundPID"] = pid
        record["returnedUptime"] = now
        record["finalSource"] = source()
        record["status"] = "pass"
        save()
        window.close()
        exit(0)
    }
}
app.run()
timer.invalidate()
fail("application event loop ended before focus returned")
