// Untimed verification of generated, isolated history through native UI.
// Caller clipboard data is retained only in memory, never logged or written.
import AppKit
import ApplicationServices
import CryptoKit
import Darwin

func emit(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
func fail(_ message: String) -> Never { emit(["ok": false, "error": message]); exit(2) }
func nowNS() -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else {
        fail("native monotonic clock unavailable")
    }
    let value = mach_absolute_time()
    return value / UInt64(timebase.denom) * UInt64(timebase.numer)
        + value % UInt64(timebase.denom) * UInt64(timebase.numer) / UInt64(timebase.denom)
}
func pause(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
func normalized(_ text: String) -> [String] {
    var rows = text.replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n")
        .map { row in String(row.reversed().drop(while: { $0 == " " }).reversed()) }
    while rows.first == "" { rows.removeFirst() }
    while rows.last == "" { rows.removeLast() }
    return rows
}
func digest(_ rows: [String]) -> String {
    SHA256.hash(data: Data((rows.joined(separator: "\n") + "\n").utf8))
        .map { String(format: "%02x", $0) }.joined()
}
func recognizedGeneratedBurstResidual(_ actual: [String], expected: [String], verifiedPayload: Bool) -> Bool {
    guard verifiedPayload, expected.count == 35, actual.count == 36 else { return false }
    let expectedSet = Set(expected)
    let residual = actual.filter { !expectedSet.contains($0) }
    return actual.filter { expectedSet.contains($0) } == expected
        && residual.count == 1 && (1...120).contains(residual[0].count)
        && residual[0].allSatisfy { $0 == "A" }
}
let args = CommandLine.arguments
if args == [args[0], "--self-test"] {
    // Pure classification only: this branch never creates NSApplication or
    // accesses the clipboard. Acceptance still cannot make history match.
    let expected = (0..<35).map { "CMDY_MEMORY_0123456789abcdef_ROW_\($0)|" }
    let burst = String(repeating: "A", count: 120)
    let valid = [burst] + expected
    let checks = [
        recognizedGeneratedBurstResidual(valid, expected: expected, verifiedPayload: true),
        recognizedGeneratedBurstResidual(expected + ["A"], expected: expected, verifiedPayload: true),
        !recognizedGeneratedBurstResidual(valid, expected: expected, verifiedPayload: false),
        !recognizedGeneratedBurstResidual(expected, expected: expected, verifiedPayload: true),
        !recognizedGeneratedBurstResidual([burst] + Array(expected.dropLast()), expected: expected, verifiedPayload: true),
        !recognizedGeneratedBurstResidual([burst] + Array(expected.reversed()), expected: expected, verifiedPayload: true),
        !recognizedGeneratedBurstResidual([burst] + Array(repeating: expected[0], count: 35), expected: expected, verifiedPayload: true),
        !recognizedGeneratedBurstResidual([String(repeating: "A", count: 121)] + expected, expected: expected, verifiedPayload: true),
        !recognizedGeneratedBurstResidual(["unrecognized"] + expected, expected: expected, verifiedPayload: true),
        !recognizedGeneratedBurstResidual([burst, burst] + expected, expected: expected, verifiedPayload: true),
        !recognizedGeneratedBurstResidual([], expected: expected, verifiedPayload: true),
        valid != expected,
    ]
    emit(["ok": checks.allSatisfy { $0 }, "checks": checks.count, "clipboardAccessed": false])
    exit(checks.allSatisfy { $0 } ? 0 : 2)
}
if args == [args[0], "conditions"] {
    let process = ProcessInfo.processInfo
    emit(["ok": true, "lowPowerMode": process.isLowPowerModeEnabled,
          "thermalState": process.thermalState.rawValue,
          "os": process.operatingSystemVersionString, "monotonicNS": nowNS(),
          "physicalMemoryBytes": process.physicalMemory,
          "activeProcessorCount": process.activeProcessorCount,
          "processorCount": process.processorCount,
          "systemUptimeSeconds": process.systemUptime])
    exit(0)
}
NSApplication.shared.setActivationPolicy(.prohibited)
guard (args.count == 4 || (args.count == 6 && args[4] == "--generated-alternate-payload")),
      let pid = Int32(args[1]), pid > 1 else {
    fail("usage: TerminalHistoryProbe OWNED_PID EXPECTED_EXECUTABLE GENERATED_ROWS_FILE [--generated-alternate-payload GENERATED_PAYLOAD]")
}
let auditStartedNS = nowNS()
let executable = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
func targetIsOwnedAndFrontmost() -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
          app.executableURL?.resolvingSymlinksInPath() == executable,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] ?? []
    let owned = windows.filter {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            && ($0[kCGWindowLayer as String] as? Int) == 0
    }
    return owned.count == 1
}
guard targetIsOwnedAndFrontmost(), CGPreflightPostEventAccess() else {
    fail("owned window must already be frontmost and event posting authorized")
}
guard let expectedData = try? Data(contentsOf: URL(fileURLWithPath: args[3])),
      expectedData.count <= 2_000_000,
      let expectedText = String(data: expectedData, encoding: .utf8) else {
    fail("generated expectation is missing, invalid or too large")
}
let expectedRows = normalized(expectedText)
let firstPrefix = String(expectedRows.first?.prefix(29) ?? "")
guard (1...5_000).contains(expectedRows.count),
      firstPrefix.range(of: "^CMDY_MEMORY_[0-9a-f]{16}_$", options: .regularExpression) != nil,
      expectedRows.enumerated().allSatisfy({ index, row in
          row.hasPrefix(firstPrefix + String(format: "ROW_%06d|", index)) && row.count == 76
      }) else { fail("expectation must contain only bounded uniquely marked benchmark rows") }
// This permits restoration after this one fully recognized generated failure.
// Exact retained-history comparison remains unchanged and will still fail.
var verifiedAlternatePayload = false
if args.count == 6 {
    guard expectedRows.count == 35,
          let payload = try? Data(contentsOf: URL(fileURLWithPath: args[5]), options: .mappedIfSafe),
          payload.count == 3_002_745 else { fail("alternate context requires the exact bounded generated payload") }
    var generated = Data("\u{1b}[?1049h".utf8)
    generated.append(Data(repeating: 65, count: 3_000_000))
    generated.append(Data("\u{1b}[2J\u{1b}[H".utf8))
    generated.append(expectedData)
    guard generated == payload else { fail("alternate context differs from the generated fixture") }
    verifiedAlternatePayload = true
}
let pasteboard = NSPasteboard.general
let initialChangeCount = pasteboard.changeCount
var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
var savedBytes = 0
for item in pasteboard.pasteboardItems ?? [] {
    var types: [(NSPasteboard.PasteboardType, Data)] = []
    for type in item.types {
        guard let data = item.data(forType: type) else {
            fail("could not preserve every existing clipboard representation")
        }
        savedBytes += data.count
        guard savedBytes <= 64 * 1_024 * 1_024 else {
            fail("existing clipboard exceeds in-memory preservation budget")
        }
        types.append((type, data))
    }
    saved.append(types)
}
guard pasteboard.changeCount == initialChangeCount, targetIsOwnedAndFrontmost() else {
    fail("caller state changed before copy; no input posted")
}
func commandKey(_ key: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        event?.flags = .maskCommand
        event?.postToPid(pid)
    }
}
commandKey(0)  // Native Command-A.
pause(0.08)
guard targetIsOwnedAndFrontmost(), pasteboard.changeCount == initialChangeCount else {
    fail("caller state changed before copy")
}
commandKey(8)  // Native Command-C.
let deadline = Date().addingTimeInterval(2)
while pasteboard.changeCount == initialChangeCount && Date() < deadline { pause(0.01) }
let copiedChangeCount = pasteboard.changeCount
guard copiedChangeCount != initialChangeCount,
      let copiedText = pasteboard.string(forType: .string),
      copiedText.utf8.count <= 2_000_000 else {
    fail("native copy did not produce bounded text")
}
let actualRows = normalized(copiedText)
let matches = actualRows == expectedRows
// Only restore after identifying our generated fixture text. If another app
// writes during the probe, leave its clipboard ownership intact.
let expectedSet = Set(expectedRows)
let recognizedBurstResidual = recognizedGeneratedBurstResidual(
    actualRows, expected: expectedRows, verifiedPayload: verifiedAlternatePayload)
let containsOnlyFixtureRows = (!actualRows.isEmpty && actualRows.allSatisfy { expectedSet.contains($0) })
    || recognizedBurstResidual
var restored = false
if containsOnlyFixtureRows && pasteboard.changeCount == copiedChangeCount {
    let items = saved.map { values -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in values { item.setData(data, forType: type) }
        return item
    }
    pasteboard.clearContents()
    restored = items.isEmpty || pasteboard.writeObjects(items)
}
let frontmostOwnedAfter = targetIsOwnedAndFrontmost()
emit(["ok": matches && restored && frontmostOwnedAfter, "retainedRows": actualRows.count,
      "ownedPID": Int(pid), "ownedExecutableVerified": true,
      "nativeStartedMonotonicNS": auditStartedNS, "nativeFinishedMonotonicNS": nowNS(),
      "expectedRows": expectedRows.count, "matchesExpectedRows": matches,
      "normalizedSHA256": containsOnlyFixtureRows ? digest(actualRows) : "unrecognized",
      "expectedNormalizedSHA256": digest(expectedRows), "clipboardRestored": restored,
      "frontmostOwnedAfter": frontmostOwnedAfter,
      "verifiedGeneratedAlternatePayload": verifiedAlternatePayload,
      "recognizedGeneratedBurstResidual": recognizedBurstResidual,
      "metric": "untimed native full-selection verification after memory samples"])
exit(matches && restored && frontmostOwnedAfter ? 0 : 2)
