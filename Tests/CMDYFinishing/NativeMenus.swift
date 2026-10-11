// Standalone public-macOS-API metadata/control helper. Never launches an app,
// prompts for permission, or controls an unrelated PID. Optional menu captures
// below include only an independently verified window of the owned app.
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

#if !CMDY_WINDOW_SETUP_TEST
let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: probe [font-size] | inspect/activate pid | resize pid width height [x y]") }
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


// Native correctness helper for one controller-owned CMDY process.
// Opens only named menus, reads their entries, then cancels tracking.
// No menu command is selected; no settings, clipboard or permissions are changed.
import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

struct MenuProbeFailure: Error { let message: String }
func requireMenu(_ condition: Bool, _ message: String) throws {
    if !condition { throw MenuProbeFailure(message: message) }
}

let arguments = CommandLine.arguments
guard [4, 6].contains(arguments.count), let targetPID = Int32(arguments[1]), targetPID > 0,
      arguments[2].hasPrefix("/"), arguments[3].count == 64 else {
    fail("usage: menu-observer OWNED_PID ABSOLUTE_EXECUTABLE SHA256 [--capture-dir NEW_ABSOLUTE_DIRECTORY]")
}
let captureDirectory: URL?
if arguments.count == 6 {
    guard arguments[4] == "--capture-dir", arguments[5].hasPrefix("/") else {
        fail("capture requires --capture-dir and an absolute path")
    }
    captureDirectory = URL(fileURLWithPath: arguments[5], isDirectory: true)
} else { captureDirectory = nil }
let executable = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath().path
let expectedDigest = arguments[3]
let deadline = ProcessInfo.processInfo.systemUptime + (captureDirectory == nil ? 12 : 30)
var identity: WindowSetupIdentity?
var openedMenus: [AXUIElement] = []
var observations: [[String: Any]] = []
var cancelledMenus = 0
var actionObservations: [[String: Any]] = []
var captureObservations: [[String: Any]] = []

func checkOwner() throws {
    try requireMenu(ProcessInfo.processInfo.systemUptime < deadline, "menu probe deadline exceeded")
    try requireMenu(identity != nil && WindowSetupIdentity.read(targetPID) == identity,
                    "owned process identity changed")
    try requireMenu(NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
                    "owned app is no longer frontmost")
}

func owned(_ element: AXUIElement) throws {
    try checkOwner()
    var pid: pid_t = 0
    try requireMenu(AXUIElementGetPid(element, &pid) == .success && pid == targetPID,
                    "menu element belongs to another process")
    AXUIElementSetMessagingTimeout(element, 0.15)
}

func menuChildren(_ element: AXUIElement) throws -> [AXUIElement] {
    try owned(element)
    return attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

func menuTitle(_ element: AXUIElement) throws -> String {
    try owned(element)
    return attribute(element, kAXTitleAttribute as CFString) as? String ?? ""
}

func menuFrame(_ element: AXUIElement) throws -> CGRect {
    try owned(element)
    guard let position = attribute(element, kAXPositionAttribute as CFString),
          let size = attribute(element, kAXSizeAttribute as CFString),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
        throw MenuProbeFailure(message: "owned menu has no native position or size")
    }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    try requireMenu(AXValueGetValue(position as! AXValue, .cgPoint, &point)
        && AXValueGetValue(size as! AXValue, .cgSize, &dimensions), "invalid menu geometry")
    let frame = CGRect(origin: point, size: dimensions)
    try requireMenu([frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
        && frame.width > 10 && frame.height > 10, "empty or nonfinite menu geometry")
    return frame
}

// A capture is diagnostic UI evidence, never a latency sample. The window must
// independently belong to the exact process and closely enclose its AX menu.
// Never fall back to a whole-display capture or another process's menu window.
func captureMenu(_ menu: AXUIElement, path: [String]) throws {
    guard let directory = captureDirectory else { return }
    guard #available(macOS 14.2, *) else {
        throw MenuProbeFailure(message: "menu capture requires macOS 14.2")
    }
    let frame = try menuFrame(menu)
    let index = captureObservations.count
    captureObservations.append(["path": path, "axBounds": rect(frame), "status": "querying-owned-window"])
    var result: Result<(CGImage, UInt32, CGRect, Double), Error>?
    let task = Task { @MainActor in
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try owned(menu)
            let ownedWindows = content.windows.filter { $0.owningApplication?.processID == targetPID && $0.isOnScreen }
            captureObservations[index]["ownedWindows"] = ownedWindows.map {
                ["windowID": $0.windowID, "layer": $0.windowLayer, "bounds": rect($0.frame)] as [String: Any]
            }
            let matches = ownedWindows.filter {
                $0.windowLayer > 0 && $0.frame.insetBy(dx: -2, dy: -2).contains(frame)
                    && $0.frame.width * $0.frame.height <= frame.width * frame.height * 1.4
            }
            try requireMenu(matches.count == 1, "actual menu has no unique matching owned capture window")
            let window = matches[0]
            let displays = content.displays.filter { $0.frame.contains(window.frame) }
            try requireMenu(displays.count == 1, "menu must fit wholly on one display for capture")
            let display = displays[0]
            // Independent-window capture groups nested AppKit menu windows and
            // scales that group into the requested single-menu size. A display
            // filter including exactly this owned window can exclude its children.
            let filter = SCContentFilter(display: display, including: [window])
            filter.includeMenuBar = false
            let scale = Double(filter.pointPixelScale)
            try requireMenu(scale >= 1 && scale <= 4, "unexpected menu backing scale")
            let configuration = SCStreamConfiguration()
            configuration.width = Int((window.frame.width * scale).rounded())
            configuration.height = Int((window.frame.height * scale).rounded())
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.includeChildWindows = false
            configuration.ignoreShadowsDisplay = true
            configuration.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            configuration.colorSpaceName = CGColorSpace.sRGB
            captureObservations[index].merge(["displayID": display.displayID, "displayBounds": rect(display.frame),
                "sourceRect": rect(configuration.sourceRect), "filterContentRect": rect(filter.contentRect),
                "includeChildWindows": false, "includeMenuBar": false,
                "includedWindowIDs": [window.windowID]]) { _, new in new }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try owned(menu)
            try requireMenu(try menuFrame(menu) == frame, "menu geometry changed during capture")
            result = .success((image, window.windowID, window.frame, scale))
        } catch { result = .failure(error) }
    }
    defer { task.cancel() }
    let captureDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 4)
    while result == nil && ProcessInfo.processInfo.systemUptime < captureDeadline {
        try owned(menu)
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
    try requireMenu(result != nil, "owned menu capture timed out")
    let (image, windowID, bounds, scale) = try result!.get()
    try owned(menu)
    let output = directory.appendingPathComponent(String(format: "%02d", index + 1) + "-" + path.joined(separator: "-") + ".png")
    try requireMenu(!FileManager.default.fileExists(atPath: output.path), "menu capture path already exists")
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw MenuProbeFailure(message: "could not encode owned menu capture")
    }
    CGImageDestinationAddImage(destination, image, nil)
    try requireMenu(CGImageDestinationFinalize(destination), "menu PNG encoding failed")
    try (data as Data).write(to: output, options: .withoutOverwriting)
    captureObservations[index].merge(["status": "captured", "file": output.path,
        "sha256": SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined(),
        "windowID": windowID, "ownerPID": Int(targetPID), "bounds": rect(bounds),
        "scale": scale, "pixelWidth": image.width, "pixelHeight": image.height,
        "filter": "displayIncludingExactOwnedWindow", "performanceSample": false]) { _, new in new }
}

func namedItem(_ title: String, in parent: AXUIElement) throws -> AXUIElement {
    var matches: [AXUIElement] = []
    for child in try menuChildren(parent) {
        let actual = try menuTitle(child)
        // AppDelegate decorates this submenu with the selected font. The
        // prefix is accepted only for the known Font/Theme submenus, not commands.
        if actual == title || (["Font", "Theme"].contains(title) && actual.hasPrefix(title + " — ")) {
            matches.append(child)
        }
    }
    try requireMenu(matches.count == 1, "required unique menu item missing: " + title)
    return matches[0]
}

func openMenu(_ item: AXUIElement) throws -> AXUIElement {
    try owned(item)
    let label = try menuTitle(item)
    var rawActions: CFArray?
    let actionQuery = AXUIElementCopyActionNames(item, &rawActions)
    let actions = rawActions as? [String] ?? []
    let role = attribute(item, kAXRoleAttribute as CFString) as? String ?? ""
    let chosen: CFString
    if role == kAXMenuItemRole as String && actions.contains("AXPick") {
        // The observed AppKit submenu headings advertise AXPick. AXPress
        // acknowledges a click but can dismiss tracking without showing it.
        chosen = "AXPick" as CFString
    } else if actions.contains(kAXShowMenuAction as String) {
        chosen = kAXShowMenuAction as CFString
    } else {
        chosen = kAXPressAction as CFString
    }
    let index = actionObservations.count
    actionObservations.append(["title": label, "role": role,
        "supportedActions": actions, "actionQueryStatus": actionQuery.rawValue,
        "chosenAction": chosen as String,
        "enabled": (attribute(item, kAXEnabledAttribute as CFString) as? NSNumber)?.boolValue ?? false])
    try requireMenu(actionQuery == .success && actions.contains(chosen as String),
                    "owned menu has no supported show-menu or press action: " + label)
    let result = AXUIElementPerformAction(item, chosen)
    actionObservations[index]["actionResult"] = result.rawValue
    try requireMenu(result == .success, "owned menu could not begin tracking: " + label)
    // AX accepts tracking actions before AppKit finishes processing them.
    // This is a correctness probe, not a latency measurement: allow the
    // parent menu transition to settle before descending into its submenu.
    actionObservations[index]["settleIntervalMS"] = 150
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    try owned(item)
    actionObservations[index]["selectedAfterSettle"] =
        (attribute(item, kAXSelectedAttribute as CFString) as? NSNumber)?.boolValue
    let readyDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 1)
    repeat {
        var candidates = try menuChildren(item)
        if let shown = attribute(item, kAXShownMenuUIElementAttribute as CFString),
           CFGetTypeID(shown) == AXUIElementGetTypeID() {
            candidates.insert(shown as! AXUIElement, at: 0)
        }
        var roles: [String] = []
        for child in candidates {
            try owned(child)
            let childRole = attribute(child, kAXRoleAttribute as CFString) as? String ?? ""
            roles.append(childRole)
            if childRole == kAXMenuRole as String {
                actionObservations[index]["observedMenuRole"] = childRole
                openedMenus.append(child)
                return child
            }
        }
        actionObservations[index]["lastChildRoles"] = roles
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    } while ProcessInfo.processInfo.systemUptime < readyDeadline
    throw MenuProbeFailure(message: "opened menu did not expose its native menu element: " + label)
}

func observeMenu(_ menu: AXUIElement, path: [String], required: [String]) throws {
    let children = try menuChildren(menu)
    let titles = try children.map { try menuTitle($0) }
    let complete = required.allSatisfy { titles.contains($0) }
    observations.append(["path": path, "requiredTitles": required,
                         "requiredTitlesPresent": complete, "observedTitles": titles,
                         "itemCount": children.count])
    try requireMenu(complete, "required entries missing in " + path.joined(separator: "/"))
    try captureMenu(menu, path: path)
}

func cancelTracking() throws {
    // Closing an ancestor closes its descendants. Reverse order also permits
    // a submenu that AppKit has already closed while exposing another menu.
    for menu in openedMenus.reversed() {
        try owned(menu)
        let result = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        try requireMenu(result == .success || result == .invalidUIElement,
                        "owned menu tracking could not be cancelled")
        cancelledMenus += 1
    }
    openedMenus.removeAll()
}

do {
    identity = WindowSetupIdentity.read(targetPID)
    try requireMenu(identity?.uid == getuid() && identity?.executable == executable,
                    "target is not the expected owned executable")
    let data = try Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try requireMenu(digest == expectedDigest, "owned executable hash mismatch")
    try requireMenu(AXIsProcessTrusted(), "Accessibility is unavailable; no permission request was made")
    if let captureDirectory {
        // ScreenCaptureKit's window filter requires AppKit's graphics session.
        // Keep this observer prohibited from activation, as other capture helpers do.
        NSApplication.shared.setActivationPolicy(.prohibited)
        try requireMenu(CGPreflightScreenCaptureAccess(), "existing screen capture permission is unavailable; no prompt was requested")
        try requireMenu(!FileManager.default.fileExists(atPath: captureDirectory.path), "menu capture directory already exists")
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    try checkOwner()
    let application = AXUIElementCreateApplication(targetPID)
    try owned(application)
    guard let rawMenuBar = attribute(application, kAXMenuBarAttribute as CFString),
          CFGetTypeID(rawMenuBar) == AXUIElementGetTypeID() else {
        throw MenuProbeFailure(message: "owned application menu bar is unavailable")
    }
    let menuBar = rawMenuBar as! AXUIElement
    let file = try openMenu(namedItem("File", in: menuBar))
    try observeMenu(file, path: ["File"], required: ["New Window", "New Tab", "Open…"])
    try cancelTracking()

    let edit = try openMenu(namedItem("Edit", in: menuBar))
    try observeMenu(edit, path: ["Edit"],
                    required: ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Find…"])
    try cancelTracking()

    let window = try openMenu(namedItem("Window", in: menuBar))
    try observeMenu(window, path: ["Window"],
                    required: ["Minimize", "Zoom", "Window Grid", "Merge With", "Float on Top"])
    try cancelTracking()

    let view = try openMenu(namedItem("View", in: menuBar))
    try observeMenu(view, path: ["View"], required: ["Text Size", "Appearance", "Terminal"])
    let appearance = try openMenu(namedItem("Appearance", in: view))
    let font = try openMenu(namedItem("Font", in: appearance))
    try observeMenu(font, path: ["View", "Appearance", "Font"],
                    required: ["Browse with Preview…", "System Mono"])
    try cancelTracking()

    let themeView = try openMenu(namedItem("View", in: menuBar))
    let themeAppearance = try openMenu(namedItem("Appearance", in: themeView))
    let theme = try openMenu(namedItem("Theme", in: themeAppearance))
    try observeMenu(theme, path: ["View", "Appearance", "Theme"],
                    required: ["Browse with Preview…"])
    try cancelTracking()

    try checkOwner()
    emit(["ok": true, "pid": Int(targetPID), "executableSHA256": digest,
          "observations": observations, "cancelledMenus": cancelledMenus,
          "actionObservations": actionObservations,
          "captures": captureObservations,
          "menuCommandsSelected": 0, "clipboardAccessed": false,
          "permissionRequested": false, "performanceSamples": 0])
} catch {
    // Never act after a process or foreground change. The controller owns
    // teardown of its app if an AX action fails or times out.
    if WindowSetupIdentity.read(targetPID) == identity,
       NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
        try? cancelTracking()
    }
    let reason = (error as? MenuProbeFailure)?.message ?? String(describing: error)
    emit(["ok": false, "error": reason, "pid": Int(targetPID),
          "observations": observations, "actionObservations": actionObservations, "menuCommandsSelected": 0,
          "captures": captureObservations,
          "clipboardAccessed": false, "permissionRequested": false,
          "performanceSamples": 0])
    exit(2)
}
