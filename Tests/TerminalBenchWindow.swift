// Standalone public-macOS-API metadata/control helper. Never launches an app,
// captures screen pixels, prompts for permission, or controls an unrelated PID.
import AppKit
import ApplicationServices
import CoreText
import Darwin

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func fail(_ message: String) -> Never {
    emit(["ok": false, "error": message])
    exit(2)
}

func rect(_ r: CGRect) -> [String: Double] {
    ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
}

func displayIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func windows(_ pid: pid_t) -> [[String: Any]] {
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                       kCGNullWindowID) as? [[String: Any]] ?? []
    return all.compactMap { item in
        guard (item[kCGWindowOwnerPID as String] as? Int) == Int(pid),
              (item[kCGWindowLayer as String] as? Int) == 0,
              let bounds = item[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              frame.width > 10, frame.height > 10 else { return nil }
        let display = displayIDs().max { left, right in
            let a = CGDisplayBounds(left).intersection(frame)
            let b = CGDisplayBounds(right).intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        } ?? 0
        return ["windowID": item[kCGWindowNumber as String] ?? 0,
                "ownerPID": Int(pid), "bounds": rect(frame),
                "displayID": display,
                "onScreen": item[kCGWindowIsOnscreen as String] ?? false,
                "alpha": item[kCGWindowAlpha as String] ?? 1]
    }
}

func inspect(_ pid: pid_t) -> [String: Any] {
    ["ok": true, "pid": Int(pid),
     "frontmostPID": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),
     "executable": NSRunningApplication(processIdentifier: pid)?.executableURL?.path ?? "",
     "windows": windows(pid)]
}

func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

struct WindowSetupIdentity: Equatable, Codable {
    let pid: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String

    static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let count = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard withUnsafeMutablePointer(to: &info, {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, count)
        }) == count else { return nil }
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard bytes.withUnsafeMutableBytes({ proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }) > 0 else { return nil }
        return Self(pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                    startMicroseconds: info.pbi_start_tvusec,
                    executable: URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path)
    }
}

struct WindowSetupObservation<Window> {
    var identity: WindowSetupIdentity?
    var frontmostPID: Int32
    var visibleWindowIDs: [UInt32]
    var axError: Int32
    var axWindows: [Window]?
    var axOwnerPIDs: [Int32]
    var details: [String: Any] = [:]
}

struct WindowSetupFailure: Error {
    let message: String
    let diagnostics: [String: Any]
}

// Pure waiting policy, also exercised with generated observations. Only resize
// setup calls this; inspect and all timed checks remain single observations.
func readySetupWindow<Window>(identity: WindowSetupIdentity,
                              read: () -> WindowSetupObservation<Window>,
                              sameWindow: (Window, Window) -> Bool,
                              now: () -> Double, pause: (Double) -> Void) throws -> (Window, [String: Any]) {
    let started = now()
    let deadline = started + 2
    var expectedWindowID: UInt32?
    var polls: [[String: Any]] = []
    func diagnostics(_ status: String) -> [String: Any] {
        ["status": status, "timeoutSeconds": 2, "elapsedSeconds": max(0, now() - started),
         "expectedPID": identity.pid, "expectedWindowID": expectedWindowID as Any? ?? NSNull(),
         "processStartSeconds": identity.startSeconds, "processStartMicroseconds": identity.startMicroseconds,
         "executable": identity.executable, "polls": polls]
    }
    func reject(_ message: String) throws -> Never {
        throw WindowSetupFailure(message: message, diagnostics: diagnostics("failed"))
    }
    func observe(_ phase: String) throws -> Window? {
        let value = read()
        var record = value.details
        record.merge(["phase": phase, "elapsedSeconds": max(0, now() - started),
                      "identityMatches": value.identity == identity, "frontmostPID": value.frontmostPID,
                      "visibleWindowIDs": value.visibleWindowIDs, "axError": value.axError,
                      "axCount": value.axWindows.map { $0.count } as Any? ?? NSNull(),
                      "axOwnerPIDs": value.axOwnerPIDs]) { _, new in new }
        polls.append(record)
        guard value.identity == identity else { try reject("owned process exited or changed identity during resize setup") }
        guard value.frontmostPID == identity.pid else { try reject("focus changed during resize setup") }
        guard value.visibleWindowIDs.count == 1, let windowID = value.visibleWindowIDs.first, windowID > 0 else {
            try reject("resize requires exactly one visible owned window")
        }
        if let expectedWindowID, expectedWindowID != windowID { try reject("owned window identity changed during resize setup") }
        expectedWindowID = windowID
        if let owned = value.axWindows, owned.count > 1 { try reject("resize requires exactly one owned AX window") }
        guard value.axError == AXError.success.rawValue || value.axError == AXError.noValue.rawValue
                || value.axError == AXError.cannotComplete.rawValue else {
            try reject("owned AX window query failed during resize setup")
        }
        // A pending response must not supply a usable window, even if malformed
        // native data happens to accompany its error code.
        guard value.axError == AXError.success.rawValue,
              let owned = value.axWindows, let window = owned.first else { return nil }
        guard value.axOwnerPIDs == [identity.pid] else { try reject("AX window does not belong to the owned process") }
        return window
    }
    while now() < deadline {
        if let window = try observe("poll") {
            // Recheck immediately before granting a resize, including the AX
            // element identity. Never silently switch to a replacement window.
            guard now() < deadline, let confirmed = try observe("before-resize"), sameWindow(window, confirmed) else {
                try reject("owned AX window changed before resize")
            }
            guard now() < deadline else { try reject("owned AX window readiness exceeded two seconds") }
            return (confirmed, diagnostics("ready"))
        }
        let remaining = deadline - now()
        guard remaining > 0 else { break }
        pause(min(0.025, remaining))
    }
    try reject("owned AX window was not ready within two seconds")
}

// Cursor placement is setup only. Every later visibility check remains strict.
func pointerParkPoint(window: CGRect, display: CGRect, clearance: CGFloat = 96) throws -> CGPoint {
    func finite(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
    guard finite(window), finite(display), display.contains(window),
          clearance.isFinite, clearance >= 1 else {
        throw WindowSetupFailure(message: "invalid pointer setup geometry", diagnostics: [:])
    }
    let free = [
        CGRect(x: display.minX, y: display.minY, width: window.minX - display.minX, height: display.height),
        CGRect(x: window.maxX, y: display.minY, width: display.maxX - window.maxX, height: display.height),
        CGRect(x: display.minX, y: display.minY, width: display.width, height: window.minY - display.minY),
        CGRect(x: display.minX, y: window.maxY, width: display.width, height: display.maxY - window.maxY)
    ].filter { $0.width >= 2 * clearance && $0.height >= 2 * clearance }
    guard let region = free.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
        throw WindowSetupFailure(message: "no clear pointer location outside the owned window", diagnostics: [:])
    }
    return CGPoint(x: region.midX, y: region.midY)
}

#if !CMDY_WINDOW_SETUP_TEST
let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: probe [font-size] | inspect/activate/park-pointer pid | resize pid width height [x y]") }
if args[1] == "conditions" {
    let process = ProcessInfo.processInfo
    emit(["ok": true, "lowPowerMode": process.isLowPowerModeEnabled,
          "thermalState": process.thermalState.rawValue,
          "os": process.operatingSystemVersionString])
    exit(0)
}
if args[1] == "probe" {
    let size = args.count > 2 ? Double(args[2]) ?? 14 : 14
    let font = CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
    let path = (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.path ?? ""
    let displays: [[String: Any]] = displayIDs().map { id in
        let mode = CGDisplayCopyDisplayMode(id)
        return ["displayID": id, "bounds": rect(CGDisplayBounds(id)),
                "pixelWidth": mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                "pixelHeight": mode?.pixelHeight ?? CGDisplayPixelsHigh(id),
                "refreshRate": mode?.refreshRate ?? 0]
    }
    emit(["ok": true, "frontmostPID": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),
          "accessibilityTrusted": AXIsProcessTrusted(),
          "screenCaptureAuthorized": CGPreflightScreenCaptureAccess(),
          "postEventAuthorized": CGPreflightPostEventAccess(), "displays": displays,
          "font": ["postScriptName": CTFontCopyPostScriptName(font),
                   "family": CTFontCopyFamilyName(font), "sizePoints": size, "file": path]])
    exit(0)
}
guard args.count >= 3, let pid = Int32(args[2]), pid > 0,
      let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated
else { fail("target PID is not a running application") }
switch args[1] {
case "inspect":
    emit(inspect(pid))
case "activate":
    _ = application.activate(options: [])
    let deadline = Date().addingTimeInterval(2)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        fail("macOS did not make the owned application frontmost")
    }
    emit(inspect(pid))
case "park-pointer":
    guard args.count == 3, CGPreflightPostEventAccess(),
          let identity = WindowSetupIdentity.read(pid), identity.uid == getuid(),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        fail("pointer setup requires the owned foreground process and existing input authorization")
    }
    let visible = windows(pid)
    guard visible.count == 1, let item = visible.first,
          let windowID = (item["windowID"] as? NSNumber)?.uint32Value,
          let displayID = (item["displayID"] as? NSNumber)?.uint32Value,
          CGDisplayIsActive(displayID) != 0,
          let frameValues = item["bounds"] as? [String: Double],
          let x = frameValues["x"], let y = frameValues["y"],
          let width = frameValues["width"], let height = frameValues["height"],
          let before = CGEvent(source: nil)?.location else {
        fail("pointer setup requires one owned visible window on an active display")
    }
    let frame = CGRect(x: x, y: y, width: width, height: height)
    let display = CGDisplayBounds(displayID)
    let target: CGPoint
    do { target = try pointerParkPoint(window: frame, display: display) }
    catch { fail("pointer setup has no validated space outside the owned window") }
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS,
          WindowSetupIdentity.read(pid) == identity,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          (windows(pid) as NSArray).isEqual(to: visible) else {
        fail("owned window or process changed before pointer setup")
    }
    let beforeTicks = mach_absolute_time()
    let moved = abs(before.x - target.x) > 0.5 || abs(before.y - target.y) > 0.5
    if moved && CGWarpMouseCursorPosition(target) != .success { fail("pointer placement failed") }
    guard let after = CGEvent(source: nil)?.location,
          abs(after.x - target.x) <= 1, abs(after.y - target.y) <= 1,
          WindowSetupIdentity.read(pid) == identity,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          (windows(pid) as NSArray).isEqual(to: visible) else {
        fail("pointer placement or owned process/window identity changed")
    }
    let afterTicks = mach_absolute_time()
    emit(["ok": true, "schemaVersion": 1, "kind": "owned-window-pointer-setup",
          "pid": Int(pid), "foregroundPID": Int(pid), "windowID": windowID, "displayID": displayID,
          "identity": ["pid": identity.pid, "uid": identity.uid, "startSeconds": identity.startSeconds,
                       "startMicroseconds": identity.startMicroseconds, "executable": identity.executable],
          "windowBounds": rect(frame), "displayBounds": rect(display), "clearancePoints": 96,
          "cursorBefore": ["x": before.x, "y": before.y], "target": ["x": target.x, "y": target.y],
          "cursorAfter": ["x": after.x, "y": after.y], "warped": moved,
          "eventsPosted": false, "windowMutated": false, "beforeTicks": beforeTicks, "afterTicks": afterTicks,
          "timebaseNumer": timebase.numer, "timebaseDenom": timebase.denom])
case "resize":
    guard AXIsProcessTrusted() else { fail("Accessibility is not authorized; no permission request was made") }
    guard args.count == 5 || args.count == 7,
          let width = Double(args[3]), let height = Double(args[4]),
          width.isFinite, height.isFinite, width >= 100, height >= 100 else {
        fail("resize requires finite width/height in screen points, at least 100")
    }
    guard let identity = WindowSetupIdentity.read(pid), identity.uid == getuid() else {
        fail("owned process start identity is unavailable")
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.05)
    let window: AXUIElement
    let readiness: [String: Any]
    do {
        (window, readiness) = try readySetupWindow(identity: identity, read: {
            let visible = windows(pid)
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
            let owned = raw as? [AXUIElement]
            let owners = (owned ?? []).map { item -> Int32 in
                var owner: pid_t = 0
                return AXUIElementGetPid(item, &owner) == .success ? owner : 0
            }
            return WindowSetupObservation(identity: application.isTerminated ? nil : WindowSetupIdentity.read(pid),
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                visibleWindowIDs: visible.compactMap { ($0["windowID"] as? NSNumber)?.uint32Value },
                axError: error.rawValue, axWindows: owned, axOwnerPIDs: owners,
                details: ["visibleWindows": visible])
        }, sameWindow: { CFEqual($0, $1) }, now: { ProcessInfo.processInfo.systemUptime },
            pause: { RunLoop.current.run(until: Date().addingTimeInterval($0)) })
    } catch let error as WindowSetupFailure {
        emit(["ok": false, "error": error.message, "resizeReadiness": error.diagnostics])
        exit(2)
    } catch {
        fail("owned AX window readiness failed: \(error)")
    }
    func resizeFailure(_ message: String) -> Never {
        emit(["ok": false, "error": message, "resizeReadiness": readiness])
        exit(2)
    }
    if args.count == 7 {
        guard let x = Double(args[5]), let y = Double(args[6]), x.isFinite, y.isFinite else {
            resizeFailure("position must be finite screen coordinates")
        }
        var origin = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &origin),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
        else { resizeFailure("could not set owned window position") }
    }
    var size = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &size),
          AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    else { resizeFailure("could not set owned window size") }
    var result = inspect(pid)
    result["resizeReadiness"] = readiness
    emit(result)
default:
    fail("unknown command")
}
#endif
