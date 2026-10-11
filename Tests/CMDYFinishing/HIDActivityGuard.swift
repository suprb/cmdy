import ApplicationServices
import Darwin
import Foundation

// Observes event origin only. Never reads key codes, characters, or input text.
let arguments = CommandLine.arguments
guard (3...4).contains(arguments.count), let ownedTag = Int64(arguments[1]), ownedTag != 0 else {
    exit(2)
}
let output = URL(fileURLWithPath: arguments[2])
enum GuardState {
    static var tag: Int64 = 0
    static var ownedEvents = 0
    static var observerEvents = 0
    static var observerConfig: URL?
}
GuardState.tag = ownedTag
if arguments.count == 4 { GuardState.observerConfig = URL(fileURLWithPath: arguments[3]) }

func processInfo(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_uid == getuid() else { return nil }
    return info
}

func isOwnedScrollObserver(_ event: CGEvent) -> Bool {
    guard event.type == .scrollWheel,
          event.getIntegerValueField(.eventSourceUserData) > 0,
          let config = GuardState.observerConfig,
          let data = try? Data(contentsOf: config),
          let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let rootPID = value["rootPID"] as? Int32,
          let executable = value["executable"] as? String,
          let root = processInfo(rootPID), root.pbi_ppid == UInt32(getppid()),
          let sourcePID = Int32(exactly: event.getIntegerValueField(.eventSourceUnixProcessID)),
          let source = processInfo(sourcePID) else { return false }
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(sourcePID, &buffer, UInt32(buffer.count)) > 0,
          URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path == executable else { return false }
    var parent = Int32(source.pbi_ppid)
    var seen = Set<Int32>()
    for _ in 0..<32 {
        if parent == rootPID { return true }
        guard seen.insert(parent).inserted, let info = processInfo(parent) else { return false }
        parent = Int32(info.pbi_ppid)
    }
    return false
}
func record(_ status: String) {
    let value: [String: Any] = ["status": status,
        "uptime": ProcessInfo.processInfo.systemUptime,
        "ownedEvents": GuardState.ownedEvents,
        "observerEvents": GuardState.observerEvents,
        "inputContentsRecorded": false]
    do {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: output, options: .atomic)
    } catch { exit(3) }
}
guard CGPreflightListenEventAccess() else {
    record("input-monitoring-unavailable")
    exit(4)
}
let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
    .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
    .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
    .otherMouseDragged, .scrollWheel]
let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        record("event-monitor-disabled")
        CFRunLoopStop(CFRunLoopGetMain())
    } else if event.getIntegerValueField(.eventSourceUserData) == GuardState.tag {
        GuardState.ownedEvents += 1
        record("ready")
    } else if isOwnedScrollObserver(event) {
        GuardState.observerEvents += 1
        record("ready")
    } else {
        record("unowned-input")
        CFRunLoopStop(CFRunLoopGetMain())
    }
    return Unmanaged.passUnretained(event)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
    options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: nil) else {
    record("event-monitor-unavailable")
    exit(5)
}
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
record("ready")
CFRunLoopRun()
exit(1)
