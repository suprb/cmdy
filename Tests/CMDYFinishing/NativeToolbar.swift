// Normal-app toolbar observer. Operates only on the controller-owned process.
// Reuses the qualified menu observer's public AX/identity checks. No test app
// mode, clipboard access, settings outside the isolated app, or permission prompt.
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


import CryptoKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
struct MenuProbeFailure: Error { let message: String }
func requireMenu(_ condition: Bool, _ message: String) throws {
    if !condition { throw MenuProbeFailure(message: message) }
}
let arguments = CommandLine.arguments
guard arguments.count == 5, let targetPID = Int32(arguments[1]), targetPID > 0,
      arguments[2].hasPrefix("/"), arguments[3].count == 64,
      arguments[4].hasPrefix("/") else {
    fail("usage: toolbar-observer OWNED_PID ABSOLUTE_EXECUTABLE SHA256 NEW_ABSOLUTE_CAPTURE_DIRECTORY")
}
let executable = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath().path
let expectedDigest = arguments[3]
let directory = URL(fileURLWithPath: arguments[4], isDirectory: true)
let deadline = ProcessInfo.processInfo.systemUptime + 60
var identity: WindowSetupIdentity?
var openedMenus: [AXUIElement] = []
var observations: [[String: Any]] = []
var actionObservations: [[String: Any]] = []
var captureObservations: [[String: Any]] = []
var initialAXTree: [[String: Any]] = []
var panelAXTree: [[String: Any]] = []
var commandsSelected = 0
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

func settle() throws {
    try checkOwner()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    try checkOwner()
}

func waitFor(_ message: String, _ condition: () throws -> Bool) throws {
    let limit = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
    repeat {
        try checkOwner()
        if try condition() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    } while ProcessInfo.processInfo.systemUptime < limit
    throw MenuProbeFailure(message: message)
}

func text(_ element: AXUIElement, _ name: CFString) throws -> String {
    try owned(element)
    return attribute(element, name) as? String ?? ""
}

func label(_ element: AXUIElement) throws -> String {
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
        let value = try text(element, name as CFString)
        if !value.isEmpty { return value }
    }
    return ""
}

func descendants(_ root: AXUIElement) throws -> [AXUIElement] {
    var pending: [(AXUIElement, Int)] = [(root, 0)]
    var result: [AXUIElement] = []
    while !pending.isEmpty {
        let (element, depth) = pending.removeFirst()
        try owned(element)
        try requireMenu(result.count < 1500 && depth < 20, "AX tree exceeds bounded traversal")
        if result.contains(where: { CFEqual($0, element) }) { continue }
        result.append(element)
        pending += try menuChildren(element).map { ($0, depth + 1) }
    }
    return result
}

func press(_ element: AXUIElement) throws {
    try owned(element)
    var raw: CFArray?
    let query = AXUIElementCopyActionNames(element, &raw)
    let actions = raw as? [String] ?? []
    let action = actions.contains(kAXPressAction as String) ? kAXPressAction as String : "AXPick"
    try requireMenu(query == .success && actions.contains(action), "control has no supported press action")
    try requireMenu((attribute(element, kAXEnabledAttribute as CFString) as? NSNumber)?.boolValue == true,
                    "control is not enabled")
    let index = actionObservations.count
    actionObservations.append(["label": try label(element), "action": action])
    let status = AXUIElementPerformAction(element, action as CFString)
    actionObservations[index]["result"] = status.rawValue
    try requireMenu(status == .success, "owned control action failed")
    try settle()
}

func appWindows() throws -> [AXUIElement] {
    let application = AXUIElementCreateApplication(targetPID)
    try owned(application)
    let result = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
    for window in result { try owned(window) }
    return result
}

func uniqueButton(_ root: AXUIElement, named name: String) throws -> AXUIElement {
    let matches = try descendants(root).filter {
        try text($0, kAXRoleAttribute as CFString) == kAXButtonRole as String && label($0) == name
    }
    try requireMenu(matches.count == 1, "required unique owned button missing: " + name)
    return matches[0]
}

let expectedButtons = ["Show or Hide Sidebar", "Browser is not installed — click to install", "Split Right", "Split Down", "Show or Hide Inspector"]

func toolbarButtons(_ window: AXUIElement) throws -> [AXUIElement] {
    let frame = try menuFrame(window)
    return try descendants(window).filter { element in
        guard try text(element, kAXRoleAttribute as CFString) == kAXButtonRole as String,
              let buttonFrame = try? menuFrame(element) else { return false }
        // AppKit expands these 28-point views to 30-point AX hit bounds.
        // Native view constraints are verified separately in the app harness.
        return abs(buttonFrame.width - 30) < 0.1 && abs(buttonFrame.height - 30) < 0.1
            && frame.contains(buttonFrame) && buttonFrame.maxY < frame.minY + 90
    }.sorted { (try? menuFrame($0).minX) ?? 0 < (try? menuFrame($1).minX) ?? 0 }
}

func observeToolbar(_ window: AXUIElement, state: String, expected: [String]) throws {
    let buttons = try toolbarButtons(window)
    let labels = try buttons.map { try label($0) }
    let frames = try buttons.map { try menuFrame($0) }
    observations.append(["state": state, "labels": labels, "frames": frames.map(rect),
                         "window": rect(try menuFrame(window))])
    try requireMenu(labels == expected, "unexpected visible toolbar controls in " + state)
    for pair in zip(frames, frames.dropFirst()) {
        try requireMenu(abs(pair.1.minX - pair.0.minX - 34) < 0.5,
                        "visible toolbar spacing changed")
    }
}

// Capture only one independently matched owned window. A toolbar strip is
// cropped at the capture source, with its actual native backing scale.
func capture(_ element: AXUIElement, name: String, toolbarOnly: Bool) throws {
    guard #available(macOS 14.2, *) else { throw MenuProbeFailure(message: "capture needs macOS 14.2") }
    let axFrame = try menuFrame(element)
    let crop = CGRect(x: axFrame.minX, y: axFrame.minY, width: axFrame.width,
                      height: toolbarOnly ? min(80, axFrame.height) : axFrame.height)
    var result: Result<(CGImage, UInt32, Double, CGRect), Error>?
    let task = Task { @MainActor in
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try owned(element)
            let matches = content.windows.filter {
                $0.owningApplication?.processID == targetPID && $0.isOnScreen && $0.windowLayer == 0
                    && abs($0.frame.minX - axFrame.minX) < 1 && abs($0.frame.minY - axFrame.minY) < 1
                    && abs($0.frame.width - axFrame.width) < 1 && abs($0.frame.height - axFrame.height) < 1
            }
            try requireMenu(matches.count == 1, "AX window has no unique matching owned capture window")
            let window = matches[0]
            let displays = content.displays.filter { $0.frame.contains(window.frame) }
            try requireMenu(displays.count == 1, "capture window must fit wholly on one display")
            let display = displays[0]
            let filter = SCContentFilter(display: display, including: [window])
            filter.includeMenuBar = false
            let scale = Double(filter.pointPixelScale)
            try requireMenu(scale >= 1 && scale <= 4, "invalid capture backing scale")
            let configuration = SCStreamConfiguration()
            configuration.width = Int((crop.width * scale).rounded())
            configuration.height = Int((crop.height * scale).rounded())
            configuration.sourceRect = crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.includeChildWindows = false
            configuration.ignoreShadowsDisplay = true
            configuration.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try owned(element)
            try requireMenu(try menuFrame(element) == axFrame, "window changed during capture")
            result = .success((image, window.windowID, scale, configuration.sourceRect))
        } catch { result = .failure(error) }
    }
    defer { task.cancel() }
    let limit = min(deadline, ProcessInfo.processInfo.systemUptime + 4)
    while result == nil && ProcessInfo.processInfo.systemUptime < limit {
        try owned(element)
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
    try requireMenu(result != nil, "owned window capture timed out")
    let (image, windowID, scale, sourceRect) = try result!.get()
    let data = NSMutableData()
    guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw MenuProbeFailure(message: "PNG encoder unavailable")
    }
    CGImageDestinationAddImage(encoder, image, nil)
    try requireMenu(CGImageDestinationFinalize(encoder), "PNG encoding failed")
    let output = directory.appendingPathComponent(name + ".png")
    try (data as Data).write(to: output, options: .withoutOverwriting)
    captureObservations.append(["state": name, "file": output.path, "windowID": windowID,
        "ownerPID": Int(targetPID), "axBounds": rect(axFrame), "crop": rect(crop), "sourceRect": rect(sourceRect),
        "scale": scale, "pixelWidth": image.width, "pixelHeight": image.height,
        "includedWindowIDs": [windowID], "includeChildWindows": false, "includeMenuBar": false,
        "filter": "displayIncludingExactOwnedWindow", "performanceSample": false,
        "sha256": SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()])
}

func customizer() throws -> AXUIElement {
    let application = AXUIElementCreateApplication(targetPID)
    try owned(application)
    guard let raw = attribute(application, kAXMenuBarAttribute as CFString),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else {
        throw MenuProbeFailure(message: "owned application has no menu bar")
    }
    let view = try openMenu(namedItem("View", in: raw as! AXUIElement))
    try press(namedItem("Customize Toolbar…", in: view))
    commandsSelected += 1
    openedMenus.removeAll()
    try waitFor("customizer did not open") { try appWindows().contains { try menuTitle($0) == "Customize Toolbar" } }
    let panels = try appWindows().filter { try menuTitle($0) == "Customize Toolbar" }
    try requireMenu(panels.count == 1, "customizer is not unique")
    return panels[0]
}

func resize(_ window: AXUIElement, size: CGSize) throws {
    try owned(window)
    var value = size
    guard let encoded = AXValueCreate(.cgSize, &value) else { throw MenuProbeFailure(message: "invalid resize") }
    try requireMenu(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, encoded) == .success,
                    "owned window resize failed")
    try settle()
}

do {
    identity = WindowSetupIdentity.read(targetPID)
    try requireMenu(identity?.uid == getuid() && identity?.executable == executable, "unexpected owned executable")
    let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe))
        .map { String(format: "%02x", $0) }.joined()
    try requireMenu(digest == expectedDigest, "owned executable hash mismatch")
    try requireMenu(AXIsProcessTrusted(), "existing Accessibility permission unavailable")
    NSApplication.shared.setActivationPolicy(.prohibited)
    try requireMenu(CGPreflightScreenCaptureAccess(), "existing capture permission unavailable")
    try requireMenu(!FileManager.default.fileExists(atPath: directory.path), "capture directory already exists")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let windows = try appWindows()
    try requireMenu(windows.count == 1, "exactly one initial owned window required")
    let main = windows[0]
    let initialFrame = try menuFrame(main)
    initialAXTree = try descendants(main).map {
        ["role": try text($0, kAXRoleAttribute as CFString), "label": try label($0),
         "frame": (try? menuFrame($0)).map(rect) as Any? ?? NSNull()]
    }
    try capture(main, name: "01-initial", toolbarOnly: true)
    try observeToolbar(main, state: "initial", expected: expectedButtons)
    var panel = try customizer()
    panelAXTree = try descendants(panel).map {
        ["role": try text($0, kAXRoleAttribute as CFString), "label": try label($0),
         "value": try text($0, kAXValueAttribute as CFString),
         "frame": (try? menuFrame($0)).map(rect) as Any? ?? NSNull()]
    }
    try capture(panel, name: "02-customizer", toolbarOnly: false)
    let add = try uniqueButton(panel, named: "New Window")
    try requireMenu(try text(add, kAXValueAttribute as CFString) == "Not in toolbar", "new-window option already selected")
    try press(add)
    try waitFor("new-window choice did not update") {
        try text(uniqueButton(panel, named: "New Window"), kAXValueAttribute as CFString) == "In toolbar"
    }
    try press(uniqueButton(panel, named: "Done"))
    try waitFor("customizer did not close") { try appWindows().count == 1 }
    try observeToolbar(main, state: "added", expected: expectedButtons + ["New Window"])
    try capture(main, name: "03-added", toolbarOnly: true)
    panel = try customizer()
    try press(uniqueButton(panel, named: "New Window"))
    try waitFor("new-window choice did not clear") {
        try text(uniqueButton(panel, named: "New Window"), kAXValueAttribute as CFString) == "Not in toolbar"
    }
    try press(uniqueButton(panel, named: "Done"))
    try waitFor("customizer did not close after removal") { try appWindows().count == 1 }
    try observeToolbar(main, state: "removed", expected: expectedButtons)
    try capture(main, name: "04-removed", toolbarOnly: true)
    try resize(main, size: CGSize(width: initialFrame.width, height: 100))
    try requireMenu(try menuFrame(main).height < 104, "window did not enter compact chrome")
    try observeToolbar(main, state: "compact", expected: [])
    try capture(main, name: "05-compact", toolbarOnly: false)
    try resize(main, size: initialFrame.size)
    try requireMenu(try menuFrame(main) == initialFrame, "window did not restore its exact initial geometry")
    try observeToolbar(main, state: "restored", expected: expectedButtons)
    try capture(main, name: "06-restored", toolbarOnly: true)
    try checkOwner()
    emit(["ok": true, "pid": Int(targetPID), "executableSHA256": digest,
          "observations": observations, "actionObservations": actionObservations,
          "initialAXTree": initialAXTree,
          "panelAXTree": panelAXTree,
          "captures": captureObservations, "menuCommandsSelected": commandsSelected,
          "geometryRestored": true, "customizationRestored": true,
          "clipboardAccessed": false, "permissionRequested": false, "performanceSamples": 0])
} catch {
    // On failure the controller tears down its isolated app. Never reach for
    // another window or change focus to finish a partially completed action.
    emit(["ok": false, "error": (error as? MenuProbeFailure)?.message ?? String(describing: error),
          "pid": Int(targetPID), "observations": observations, "actionObservations": actionObservations,
          "initialAXTree": initialAXTree,
          "panelAXTree": panelAXTree,
          "captures": captureObservations, "menuCommandsSelected": commandsSelected,
          "clipboardAccessed": false, "permissionRequested": false, "performanceSamples": 0])
    exit(2)
}
