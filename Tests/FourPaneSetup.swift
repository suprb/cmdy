// Untimed setup only. No app launch, activation, permission prompt,
// clipboard access, or implementation-specific terminal APIs.
import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

private var excludedSystemCursors: [[String: Any]] = []

private func captureExcludesCursor(_ window: [String: Any]) -> Bool {
    guard let layer = window[kCGWindowLayer as String] as? Int,
          layer == Int(CGWindowLevelForKey(.cursorWindow)),
          let owner = window[kCGWindowOwnerPID as String] as? Int32 else { return false }
    var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard bytes.withUnsafeMutableBytes({ proc_pidpath(owner, $0.baseAddress, UInt32($0.count)) }) > 0 else { return false }
    let executable = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path
    guard scrollIsCaptureExcludedCursor(layer: layer, ownerExecutable: executable) else { return false }
    excludedSystemCursors.append(["windowID": window[kCGWindowNumber as String] ?? NSNull(),
        "ownerPID": owner, "layer": layer, "ownerExecutable": executable])
    return true
}

private struct SetupError: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}

private func ownedWindow(pid: pid_t, id: CGWindowID) throws -> CGRect {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          let items = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] else {
        throw SetupError("owned application must already be foreground")
    }
    let owned = items.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
        && ($0[kCGWindowLayer as String] as? Int) == 0 }
    guard owned.count == 1, let item = owned.first,
          (item[kCGWindowNumber as String] as? UInt32) == id,
          let raw = item[kCGWindowBounds as String] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: raw) else {
        throw SetupError("exactly one on-screen window must belong to the requested PID")
    }
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount)
    guard displays.prefix(Int(displayCount)).contains(where: { CGDisplayBounds($0).contains(frame) }) else {
        throw SetupError("the entire owned window must fit on one display")
    }
    for other in items {
        if (other[kCGWindowNumber as String] as? UInt32) == id { break }
        if captureExcludesCursor(other) { continue }
        guard (other[kCGWindowOwnerPID as String] as? Int) != Int(pid),
              (other[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
              let raw = other[kCGWindowBounds as String] as? NSDictionary,
              let rectangle = CGRect(dictionaryRepresentation: raw) else { continue }
        if rectangle.intersection(frame).width > 2 && rectangle.intersection(frame).height > 2 {
            throw SetupError("another visible window covers the owned terminal: id=\(other[kCGWindowNumber as String] ?? "unknown") ownerPID=\(other[kCGWindowOwnerPID as String] ?? "unknown") layer=\(other[kCGWindowLayer as String] ?? "unknown") bounds=\(rectangle) terminalBounds=\(frame)")
        }
    }
    return frame
}

private let colors = [(40, 160, 80), (200, 60, 80), (40, 100, 200), (160, 100, 40)]

@main
private struct FourPaneSetup {
    static func main() async {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let words = Array(CommandLine.arguments.dropFirst())
            guard let operation = words.first, ["key", "landmarks"].contains(operation),
                  words.count % 2 == 1 else { throw SetupError("key/landmarks --pid PID --window ID --action ACTION or --output PNG") }
            var arguments: [String: String] = [:]
            for index in stride(from: 1, to: words.count, by: 2) {
                guard ["--pid", "--window", "--action", "--output"].contains(words[index]),
                      arguments[words[index]] == nil else { throw SetupError("unknown or repeated argument") }
                arguments[words[index]] = words[index + 1]
            }
            guard let rawPID = arguments["--pid"], let pid = Int32(rawPID), pid > 0,
                  let rawID = arguments["--window"], let id = UInt32(rawID) else {
                throw SetupError("positive PID and window ID required")
            }
            let before = try ownedWindow(pid: pid, id: id)
            var result: [String: Any] = ["ok": true, "pid": pid, "windowID": id]
            if operation == "key" {
                guard CGPreflightPostEventAccess(), let action = arguments["--action"] else {
                    throw SetupError("existing event-post access and explicit setup action required")
                }
                let keys: [String: (CGKeyCode, String)] = [
                    "split-right": (15, "r"), "split-down": (2, "d"),
                    "focus-left": (4, "h"), "focus-right": (37, "l"),
                    "focus-up": (40, "k"), "focus-down": (38, "j"),
                    "equalize": (14, "e"), "probe": (6, "z"),
                    "resize-up": (32, "u"), "resize-down": (45, "n"),
                    "resize-right": (34, "i"), "resize-left": (31, "o")]
                guard let key = keys[action], let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: key.0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: key.0, keyDown: false) else {
                    throw SetupError("unknown setup action or event creation failure")
                }
                let flags: CGEventFlags = action == "probe" ? [] : [.maskCommand, .maskControl, .maskAlternate]
                var character = key.1.utf16.first!
                for event in [down, up] {
                    event.flags = flags
                    event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                }
                _ = try ownedWindow(pid: pid, id: id)
                down.postToPid(pid)
                usleep(25_000)
                _ = try ownedWindow(pid: pid, id: id)
                up.postToPid(pid)
                result["action"] = action
                result["virtualKey"] = key.0
                result["flags"] = flags.rawValue
            } else {
                guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess(),
                      let output = arguments["--output"], !FileManager.default.fileExists(atPath: output) else {
                    throw SetupError("macOS 14, existing capture permission and a new PNG path required")
                }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == id
                    && $0.owningApplication?.processID == pid && $0.isOnScreen }) else {
                    throw SetupError("owned window unavailable for capture")
                }
                let configuration = SCStreamConfiguration()
                configuration.width = 1280
                configuration.height = max(64, Int(1280 * before.height / before.width))
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.colorSpaceName = CGColorSpace.sRGB
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
                let width = image.width, height = image.height
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                let rectangles: [[String: Any]] = try bytes.withUnsafeMutableBytes { raw in
                    guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                        throw SetupError("could not decode captured pixels")
                    }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    let data = raw.bindMemory(to: UInt8.self)
                    return colors.enumerated().map { slot, color in
                        var x0 = width, x1 = -1, y0 = height, y1 = -1, count = 0
                        for y in 0..<height {
                            for x in 0..<width {
                                let offset = (y * width + x) * 4
                                if abs(Int(data[offset]) - color.0) <= 3,
                                   abs(Int(data[offset + 1]) - color.1) <= 3,
                                   abs(Int(data[offset + 2]) - color.2) <= 3,
                                   data[offset + 3] >= 250 {
                                    x0 = min(x0, x); x1 = max(x1, x)
                                    y0 = min(y0, y); y1 = max(y1, y); count += 1
                                }
                            }
                        }
                        let w = max(0, x1 - x0 + 1), h = max(0, y1 - y0 + 1)
                        return ["slot": slot, "x": Double(x0) / Double(width),
                                "y": Double(y0) / Double(height), "width": Double(w) / Double(width),
                                "height": Double(h) / Double(height), "pixelCount": count,
                                "fillFraction": w * h > 0 ? Double(count) / Double(w * h) : 0]
                    }
                }
                guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                    "public.png" as CFString, 1, nil) else { throw SetupError("could not create PNG evidence") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw SetupError("could not write PNG evidence") }
                result["rectangles"] = rectangles
                result["captureWidth"] = width
                result["captureHeight"] = height
                result["png"] = output
                guard try ownedWindow(pid: pid, id: id) == before else { throw SetupError("window changed during capture") }
            }
            result["captureExcludedSystemCursor"] = excludedSystemCursors
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            let data = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": String(describing: error)])
            print(String(decoding: data, as: UTF8.self))
            exit(2)
        }
    }
}
