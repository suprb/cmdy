# Move/copy-aware terminal lineage report

- ref: `584624985809f6000a82d3b3b97e43ef885af572`
- initial vendor import: `512b859268662b8e01f5923fabd7958e12e280df`
- method: `git blame --line-porcelain -C -C -M`
- warning: classifications are audit leads, not legal conclusions

## Totals

| Classification | Lines |
| --- | ---: |
| confirmed-derived | 4642 |
| vendor-era-uncertain | 992 |
| cmdy-addition | 148 |
| post-extraction-review | 4231 |

## `Core/Sources/TermitePTY/Pty.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-4 | post-extraction-review | `a1069e5b2eb2` | `Core/Sources/TermitePTY/Pty.swift` | file scope |
| 5-17 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Pty.swift` | file scope |
| 18 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Pty.swift` | public class PseudoTerminalHelpers { |
| 19-23 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Pty.swift` | private struct CStringArray { |
| 24-43 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Pty.swift` | private static func allocateCStringArray(_ strings: [String]) -> CStringArray? { |
| 44-59 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Pty.swift` | private static func freeCStringArray(_ array: CStringArray) { |
| 60-116 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Pty.swift` | public static func fork (andExec: String, args: [String], env: [String], currentDirectory: St... |
| 117-128 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Pty.swift` | public static func setWinSize (masterPtyDescriptor: Int32, windowSize: inout winsize) -> Int32 |
| 129-136 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Pty.swift` | public static func availableBytes (fd: Int32) -> (status: Int32, size: Int32) |

## `Core/Sources/TermitePTY/LocalProcess.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-4 | post-extraction-review | `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | file scope |
| 5-14 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | file scope |
| 15-18 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public protocol LocalProcessDelegate: AnyObject { |
| 19-21 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | func processTerminated (_ source: LocalProcess, exitCode: Int32?) |
| 22-24 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | func dataReceived (slice: ArraySlice<UInt8>) |
| 25-58 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | func getWindowSize () -> winsize |
| 59-61 | post-extraction-review | `4ccdba121f6d` | `Core/Sources/TermitePTY/LocalProcess.swift` | func getWindowSize () -> winsize |
| 62-66 | post-extraction-review | `4ccdba121f6d`, `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | public final class LocalProcess: @unchecked Sendable { |
| 67-93 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public final class LocalProcess: @unchecked Sendable { |
| 94-95 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | public final class LocalProcess: @unchecked Sendable { |
| 96-107 | post-extraction-review | `d695fb70583a`, `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | private struct PendingChunk { |
| 108-124 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private struct PendingChunk { |
| 125-132 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public init (delegate: LocalProcessDelegate, dispatchQueue: DispatchQueue? = nil) |
| 133-135 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | public init (delegate: LocalProcessDelegate, dispatchQueue: DispatchQueue? = nil) |
| 136-146 | post-extraction-review | `d695fb70583a`, `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func enqueueReceivedData(_ bytes: [UInt8], generation: UInt64) { |
| 147-158 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func enqueueReceivedData(_ bytes: [UInt8], generation: UInt64) { |
| 159-168 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func installReadChannel(_ channel: DispatchIO) { |
| 169-177 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func invalidateReadChannel() { |
| 178-189 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func discardPendingDataLocked() { |
| 190-208 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func scheduleReadIfNeeded() { |
| 209-221 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func finishReadOperation(generation: UInt64, continueReading: Bool) { |
| 222-224 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func drainReceivedData() { |
| 225-226 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func drainReceivedData() { |
| 227-230 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func drainReceivedData() { |
| 231-235 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func drainReceivedData() { |
| 236-248 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func drainReceivedData() { |
| 249-252 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func drainReceivedData() { |
| 253-267 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func drainReceivedData() { |
| 268-299 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public func send (data: ArraySlice<UInt8>) |
| 300-312 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func createPseudoTerminal() throws -> (master: Int32, slave: Int32) { |
| 313-320 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func setupLoginTty(slaveFd: Int32) throws { |
| 321-332 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | func childStopped(cancelProcessMonitor: Bool = true) { |
| 333-339 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func isCurrentReadGeneration(_ generation: UInt64) -> Bool { |
| 340-347 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func stopAfterReadFailure(generation: UInt64) { |
| 348-355 | post-extraction-review | `d695fb70583a`, `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | func childProcessRead(done: Bool, data: DispatchData?, errno: Int32, |
| 356-364 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | func childProcessRead(done: Bool, data: DispatchData?, errno: Int32, |
| 365-374 | post-extraction-review | `d695fb70583a`, `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | func childProcessRead(done: Bool, data: DispatchData?, errno: Int32, |
| 375-393 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | func childProcessRead(done: Bool, data: DispatchData?, errno: Int32, |
| 394-405 | post-extraction-review | `d695fb70583a`, `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | func childProcessRead(done: Bool, data: DispatchData?, errno: Int32, |
| 406-411 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | func childProcessRead(done: Bool, data: DispatchData?, errno: Int32, |
| 412-418 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | deinit { |
| 419-435 | post-extraction-review | `d695fb70583a`, `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | func processTerminated(pid: pid_t) |
| 436-448 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | func processTerminated(pid: pid_t) |
| 449-462 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: ... |
| 463-504 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func startProcessWithSubprocess(executable: String, args: [String], environment: [Str... |
| 505 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func startProcessWithSubprocess(executable: String, args: [String], environment: [Str... |
| 506-559 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func startProcessWithSubprocess(executable: String, args: [String], environment: [Str... |
| 560-571 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func startProcessWithForkpty(executable: String, args: [String], environment: [String... |
| 572 | post-extraction-review | `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func startProcessWithForkpty(executable: String, args: [String], environment: [String... |
| 573-580 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func startProcessWithForkpty(executable: String, args: [String], environment: [String... |
| 581-594 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func startProcessWithForkpty(executable: String, args: [String], environment: [String... |
| 595-606 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | private func startProcessWithForkpty(executable: String, args: [String], environment: [String... |
| 607-612 | post-extraction-review | `d695fb70583a`, `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | private func startProcessWithForkpty(executable: String, args: [String], environment: [String... |
| 613-621 | post-extraction-review | `a1069e5b2eb2` | `Core/Sources/TermitePTY/LocalProcess.swift` | public static func defaultEnvironment(termName: String) -> [String] { |
| 622-623 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public static func defaultEnvironment(termName: String) -> [String] { |
| 624-640 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public func terminate() |
| 641 | post-extraction-review | `d695fb70583a` | `Core/Sources/TermitePTY/LocalProcess.swift` | public func terminate() |
| 642-649 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public func terminate() |
| 650-655 | post-extraction-review | `a652a3c0afe1` | `Core/Sources/TermitePTY/LocalProcess.swift` | public func terminate() |
| 656-663 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public func terminate() |
| 664-669 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift` | public func setHostLogging (directory: String?) |

## `Core/Sources/TermiteCore/UnicodeWidth.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-6 | post-extraction-review | `fffaf2df7ef2` | `Core/Sources/TermiteCore/UnicodeWidth.swift` | file scope |
| 7 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/UnicodeWidthData.swift` | file scope |
| 8-322 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/UnicodeWidthData.swift` | struct UnicodeWidthData { |
| 323 | post-extraction-review | `fffaf2df7ef2` | `Core/Sources/TermiteCore/UnicodeWidth.swift` | struct UnicodeWidthData { |
| 324-326 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | struct UnicodeWidthData { |
| 327-330 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | struct UnicodeUtil { |
| 331-354 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | static func expectedSizeFromFirstByte (_ b: UInt8) -> Int |
| 355 | post-extraction-review | `4ccdba121f6d` | `Core/Sources/TermiteCore/UnicodeWidth.swift` | static func expectedSizeFromFirstByte (_ b: UInt8) -> Int |
| 356-376 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | static func expectedSizeFromFirstByte (_ b: UInt8) -> Int |
| 377-585 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | struct LH { |
| 586-607 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | static func bisearch (rune: UInt32, table: [LH], max _max: Int) -> Int |
| 608-612 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | private static func isFullwidthModifierSymbol (_ value: UInt32) -> Bool |
| 613-616 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | static func isRegionalIndicator(_ scalar: UnicodeScalar) -> Bool { |
| 617-624 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | static func isEmojiVs16Base (rune: UnicodeScalar) -> Bool |
| 625-638 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | private static func isEastAsianWide (_ value: UInt32) -> Bool |
| 639-696 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Utilities.swift` | static func columnWidth (rune: UnicodeScalar) -> Int |

## `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-9 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | file scope |
| 10 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift` | public enum BlockAlpha: CGFloat, Sendable { |
| 11-16 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | public enum BlockAlpha: CGFloat, Sendable { |
| 17-22 | post-extraction-review | `4ccdba121f6d`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift` | public struct BlockElementRect: Sendable { |
| 23 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | public struct BlockElementRect: Sendable { |
| 24 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift` | public func rect(in cellOrigin: CGPoint, xEighth: CGFloat, yEighth: CGFloat, cellHeight: CGFl... |
| 25-32 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | public func rect(in cellOrigin: CGPoint, xEighth: CGFloat, yEighth: CGFloat, cellHeight: CGFl... |
| 33 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift` | public struct BlockElementMapping { |
| 34 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift` | public static func rects(for codePoint: UInt32) -> [BlockElementRect]? { |
| 35-43 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | public static func rects(for codePoint: UInt32) -> [BlockElementRect]? { |
| 44-47 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | private static func upperBlock(_ num: UInt8) -> [BlockElementRect] { |
| 48-51 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | private static func lowerBlock(_ num: UInt8) -> [BlockElementRect] { |
| 52-55 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | private static func leftBlock(_ num: UInt8) -> [BlockElementRect] { |
| 56-59 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | private static func rightBlock(_ num: UInt8) -> [BlockElementRect] { |
| 60-61 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift` | private static func rightBlock(_ num: UInt8) -> [BlockElementRect] { |
| 62-97 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | private static func rightBlock(_ num: UInt8) -> [BlockElementRect] { |
| 98-104 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift` | public struct BlockElementRenderItem { |
| 105-112 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift` | public init(column: Int, columnWidth: Int, codePoint: UInt32, |
| 113-114 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BlockElementRenderer.swift` | public init(column: Int, columnWidth: Int, codePoint: UInt32, |

## `Renderer/Sources/TermiteGPU/BoxDrawingRenderer.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-9 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | file scope |
| 10-16 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | enum LineStyle { |
| 17-23 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | struct Lines { |
| 24-30 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | enum Corner { |
| 31-39 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | struct BoxDrawingCanvas { |
| 40-54 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { |
| 55-59 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | func point(x: Double, y: Double) -> CGPoint { |
| 60-75 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | func line(from start: CGPoint, to end: CGPoint, thicknessPx: Int) { |
| 76-78 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BoxDrawingRenderer.swift` | public struct BoxDrawingRenderer { |
| 79 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | public struct BoxDrawingRenderer { |
| 80 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BoxDrawingRenderer.swift` | public static func draw(codePoint: UInt32, |
| 81-86 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | public static func draw(codePoint: UInt32, |
| 87-95 | post-extraction-review | `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/BoxDrawingRenderer.swift` | public static func draw(codePoint: UInt32, |
| 96-244 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | public static func draw(codePoint: UInt32, |
| 245-248 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func subClamped(_ value: Int, _ subtract: Int) -> Int { |
| 249-252 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func addClamped(_ value: Int, _ add: Int, _ maxValue: Int) -> Int { |
| 253-391 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func linesChar(lines: Lines, canvas: BoxDrawingCanvas, baseThicknessPx: Int) { |
| 392-396 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func hlineMiddle(canvas: BoxDrawingCanvas, thicknessPx: Int) { |
| 397-401 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func vlineMiddle(canvas: BoxDrawingCanvas, thicknessPx: Int) { |
| 402-405 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func hline(canvas: BoxDrawingCanvas, x1: Int, x2: Int, y: Int, thicknessPx: Int) { |
| 406-409 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func vline(canvas: BoxDrawingCanvas, y1: Int, y2: Int, x: Int, thicknessPx: Int) { |
| 410-440 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func dashHorizontal(count: Int, thicknessPx: Int, desiredGapPx: Int, canvas: BoxDrawi... |
| 441-471 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func dashVertical(count: Int, thicknessPx: Int, desiredGapPx: Int, canvas: BoxDrawing... |
| 472-479 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func diagonalStrokePx(_ thicknessPx: Int, minStroke: Int) -> Int { |
| 480-491 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func lightDiagonalUpperRightToLowerLeft(thicknessPx: Int, canvas: BoxDrawingCanvas) { |
| 492-503 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func lightDiagonalUpperLeftToLowerRight(thicknessPx: Int, canvas: BoxDrawingCanvas) { |
| 504-508 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func lightDiagonalCross(thicknessPx: Int, canvas: BoxDrawingCanvas) { |
| 509-580 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func arc(corner: Corner, thicknessPx: Int, canvas: BoxDrawingCanvas) { |
| 581-634 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | private func fillArcQuarter(corner: Corner, |
| 635-640 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BoxDrawingRenderer.swift` | public struct BoxDrawingRenderItem { |
| 641-646 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/BoxDrawingRenderer.swift` | public init(column: Int, columnWidth: Int, codePoint: UInt32, foregroundColor: TTColor) { |
| 647-648 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/BoxDrawingRenderer.swift` | public init(column: Int, columnWidth: Int, codePoint: UInt32, foregroundColor: TTColor) { |

## `Renderer/Sources/TermiteGPU/CoreTextGlyphRasterizer.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-4 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/CoreTextGlyphRasterizer.swift` | file scope |
| 5 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/CoreTextGlyphRasterizer.swift` | final class CoreTextGlyphRasterizer { |
| 6 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/CoreTextGlyphRasterizer.swift` | func hasVisibleBounds(font: CTFont, glyph: CGGlyph) -> Bool { |
| 7-8 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/CoreTextGlyphRasterizer.swift` | func hasVisibleBounds(font: CTFont, glyph: CGGlyph) -> Bool { |
| 9-11 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/CoreTextGlyphRasterizer.swift` | func hasVisibleBounds(font: CTFont, glyph: CGGlyph) -> Bool { |
| 12-22 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/CoreTextGlyphRasterizer.swift` | func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphBitmap? { |
| 23-31 | post-extraction-review | `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/CoreTextGlyphRasterizer.swift` | func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphBitmap? { |
| 32-33 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/CoreTextGlyphRasterizer.swift` | func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphBitmap? { |
| 34-38 | post-extraction-review | `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/CoreTextGlyphRasterizer.swift` | func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphBitmap? { |
| 39-97 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/CoreTextGlyphRasterizer.swift` | func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphBitmap? { |

## `Renderer/Sources/TermiteGPU/GlyphAtlas.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-4 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | file scope |
| 5 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | struct AtlasRegion { |
| 6-7 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | struct AtlasRegion { |
| 8-13 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | struct AtlasRegion { |
| 14-21 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | struct GlyphBitmap { |
| 22-25 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | enum GlyphAtlasFormat { |
| 26-27 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | enum GlyphAtlasFormat { |
| 28-29 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | enum GlyphAtlasFormat { |
| 30-32 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | enum GlyphAtlasFormat { |
| 33 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | final class GlyphAtlas { |
| 34-41 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | private struct PageState { |
| 42-43 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | private struct PageState { |
| 44-50 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | private struct PageState { |
| 51 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | private struct PageState { |
| 52-55 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | private struct PageState { |
| 56-57 | post-extraction-review | `a652a3c0afe1`, `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | init?(device: MTLDevice, size: Int = 1024, maxPages: Int = 4, |
| 58 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | init?(device: MTLDevice, size: Int = 1024, maxPages: Int = 4, |
| 59-68 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | init?(device: MTLDevice, size: Int = 1024, maxPages: Int = 4, |
| 69-70 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | init?(device: MTLDevice, size: Int = 1024, maxPages: Int = 4, |
| 71 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | init?(device: MTLDevice, size: Int = 1024, maxPages: Int = 4, |
| 72 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | init?(device: MTLDevice, size: Int = 1024, maxPages: Int = 4, |
| 73-74 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | init?(device: MTLDevice, size: Int = 1024, maxPages: Int = 4, |
| 75-79 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func generation(forPage page: Int) -> UInt64 { |
| 80-83 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func touch(page: Int) { |
| 84-85 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func touch(page: Int) { |
| 86 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func ensureRegion(width: Int, height: Int) -> AtlasRegion? { |
| 87-90 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func ensureRegion(width: Int, height: Int) -> AtlasRegion? { |
| 91-92 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func ensureRegion(width: Int, height: Int) -> AtlasRegion? { |
| 93-97 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func ensureRegion(width: Int, height: Int) -> AtlasRegion? { |
| 98 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func ensureRegion(width: Int, height: Int) -> AtlasRegion? { |
| 99-102 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func ensureRegion(width: Int, height: Int) -> AtlasRegion? { |
| 103 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func ensureRegion(width: Int, height: Int) -> AtlasRegion? { |
| 104-115 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func ensureRegion(width: Int, height: Int) -> AtlasRegion? { |
| 116-117 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func ensureRegion(width: Int, height: Int) -> AtlasRegion? { |
| 118-133 | post-extraction-review | `3ba83c216876`, `4ccdba121f6d`, `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 134 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 135-136 | post-extraction-review | `4ccdba121f6d`, `3ba83c216876` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 137-138 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 139-140 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 141-142 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 143 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 144-146 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 147-150 | post-extraction-review | `4ccdba121f6d`, `fbe7a56c73ac`, `3ba83c216876` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 151 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 152-155 | post-extraction-review | `4ccdba121f6d`, `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 156 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 157 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 158-159 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, |
| 160-177 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/GlyphAtlas.swift` | private func reserve(width: Int, height: Int, page: Int) -> AtlasRegion? { |
| 178-180 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/GlyphAtlas.swift` | private func reserve(width: Int, height: Int, page: Int) -> AtlasRegion? { |

## `Renderer/Sources/TermiteGPU/MetalBufferingMode.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-6 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalBufferingMode.swift` | file scope |
| 7-19 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalBufferingMode.swift` | public enum MetalBufferingMode { |

## `Renderer/Sources/TermiteGPU/MetalError.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-8 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalError.swift` | file scope |
| 9-49 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalError.swift` | public enum MetalError: Error, CustomStringConvertible { |

## `Renderer/Sources/TermiteGPU/MetalRenderSource.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-8 | post-extraction-review | `8ee8a196bbf5`, `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | file scope |
| 9-15 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | public protocol MetalRenderSource: AnyObject { |
| 16-17 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func captureGrid() -> GridSnapshot |
| 18 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func lineInfo(forRow row: Int) -> ViewLineInfo |
| 19-22 | post-extraction-review | `8ee8a196bbf5`, `0bec46a41928` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func lineRenderMode(forRow row: Int) -> RenderLineMode |
| 23-25 | post-extraction-review | `0bec46a41928`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func lineVersion(forRow row: Int) -> UInt64 |
| 26-30 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func cursorCellAttributedString() -> NSAttributedString? |
| 31 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec] |
| 32-38 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? |
| 39-42 | post-extraction-review | `8ee8a196bbf5`, `4616a520f010` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift`<br>`Sources/term64/TerminalCoreProtocols.swift` | func backingScaleFactor() -> CGFloat |
| 43 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func underlinePosition() -> CGFloat |
| 44-49 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func underlineThickness() -> CGFloat |
| 50-66 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func getImageScale() -> CGFloat |
| 67-75 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalRenderSource.swift` | func consumeDirtyRows() -> ClosedRange<Int>? |

## `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-6 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | file scope |
| 7 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | file scope |
| 8-14 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | file scope |
| 15-28 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public enum TextRenderingMode: String, CaseIterable { |
| 29-34 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct GlyphKey: Hashable { |
| 35-42 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct GlyphEntry { |
| 43-47 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | enum GlyphAtlasKind { |
| 48-51 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct GlyphVertex { |
| 52 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct GlyphVertex { |
| 53-54 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct GlyphVertex { |
| 55-59 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct ColorVertex { |
| 60-65 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct TextCell { |
| 66 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct TextCell { |
| 67-68 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct TextCell { |
| 69-74 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct ColorCell { |
| 75-79 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct ImageDraw { |
| 80-85 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct ImageDrawBuffer { |
| 86-96 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct RowDrawData { |
| 97-111 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct RowDrawBuffers { |
| 112-114 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct RowCacheEntry { |
| 115 | post-extraction-review | `0bec46a41928` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct RowCacheEntry { |
| 116-117 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct RowCacheEntry { |
| 118-128 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct FrameDrawData { |
| 129-136 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct DrawData { |
| 137-139 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct DrawData { |
| 140-145 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct ShaderScrollEnvelope { |
| 146-164 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | mutating func noteScroll(deltaPixels: CGFloat, at now: CFTimeInterval) { |
| 165-181 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | mutating func update(at now: CFTimeInterval) { |
| 182-185 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private final class RedrawGate: @unchecked Sendable { |
| 186-191 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func mark() { |
| 192-200 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func consume() -> Bool { |
| 201-208 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct KittyImageSignature: Hashable { |
| 209-215 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct ClipRect { |
| 216-224 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct CustomGlyphKey: Hashable { |
| 225-229 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct CustomGlyphEntry { |
| 230-235 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct CustomGlyphBitmap { |
| 236-239 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct CacheSignature: Hashable { |
| 240-243 | post-extraction-review | `9c53c58fe8eb`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct CacheSignature: Hashable { |
| 244-248 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct CacheSignature: Hashable { |
| 249-251 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct CacheSignature: Hashable { |
| 252-254 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct CacheSignature: Hashable { |
| 255-256 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct CacheSignature: Hashable { |
| 257-260 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct ViewportTranslation: Equatable { |
| 261-268 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(contentXOrigin: CGFloat, viewHeight: CGFloat, topContentInset: CGFloat, |
| 269-272 | post-extraction-review | `45a60cd7fcfc` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct SmoothScrollTranslation: Equatable { |
| 273-285 | post-extraction-review | `45a60cd7fcfc`, `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(offsetPoints: CGFloat, scale: CGFloat) { |
| 286-288 | post-extraction-review | `45a60cd7fcfc` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct TerminalGridScissor { |
| 289-312 | post-extraction-review | `45a60cd7fcfc`, `fbe7a56c73ac`, `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(drawableSize: CGSize, topInset: CGFloat, bottomInset: CGFloat, |
| 313-315 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | struct TerminalCellIndexMap { |
| 316-326 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(text: String) { |
| 327-339 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(cellUTF16Boundaries: [Int]) { |
| 340-348 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func cellIndex(forUTF16Offset offset: Int) -> Int { |
| 349-359 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func cellRange(forUTF16Range range: NSRange) -> Range<Int> { |
| 360-375 | post-extraction-review | `d695fb70583a`, `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func lowerBound(for value: Int) -> Int { |
| 376-377 | post-extraction-review | `8ee8a196bbf5`, `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public final class MetalTerminalRenderer: NSObject, MTKViewDelegate { |
| 378-382 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct SharedResourceKey: Hashable { |
| 383-396 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private final class SharedCoreResources { |
| 397-425 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 426-429 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 430 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 431-434 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 435 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 436-439 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 440 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 441-442 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 443 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 444-446 | vendor-era-uncertain | `382b973bb9ed` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 447-458 | post-extraction-review | `0f30f2e7c0d4`, `c94591caa2cd`, `8ee8a196bbf5`, `ac5d35a007e4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 459-462 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 463-497 | post-extraction-review | `8ee8a196bbf5`, `9a8efa1de04d`, `628b6d3eccd4`, `831e5af61c03`, `3ba83c216876`, `4ccdba121f6d`, `eeafffb2c0f9`, `9c53c58fe8eb`, `dc0f4ba5acf3`, `45a60cd7fcfc` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 498-499 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | init(commandQueue: MTLCommandQueue, |
| 500-508 | vendor-era-uncertain | `d2ce06f1b093`, `ed229daadfdb`, `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct CRTUniforms { |
| 509-514 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 515-517 | vendor-era-uncertain | `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 518 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 519 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 520 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 521-525 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 526 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 527-533 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 534-542 | post-extraction-review | `4ccdba121f6d`, `ac5d35a007e4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 543-544 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 545 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 546-556 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct DatabloomTextUniforms { |
| 557 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public init(view: MTKView, source: any MetalRenderSource) throws { |
| 558-564 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public init(view: MTKView, source: any MetalRenderSource) throws { |
| 565 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public init(view: MTKView, source: any MetalRenderSource) throws { |
| 566-571 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public init(view: MTKView, source: any MetalRenderSource) throws { |
| 572-586 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public init(view: MTKView, source: any MetalRenderSource) throws { |
| 587-589 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public init(view: MTKView, source: any MetalRenderSource) throws { |
| 590 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public init(view: MTKView, source: any MetalRenderSource) throws { |
| 591-593 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public init(view: MTKView, source: any MetalRenderSource) throws { |
| 594-603 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func sharedCoreResources( |
| 604-606 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func sharedCoreResources( |
| 607-639 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func sharedCoreResources( |
| 640-641 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func sharedCoreResources( |
| 642-656 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func sharedCoreResources( |
| 657-658 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func sharedCoreResources( |
| 659-678 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func sharedCoreResources( |
| 679-690 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | static func sharedCoreResourceIdentity( |
| 691-695 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | static func resetSharedCoreResourcesForTesting() { |
| 696-699 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | deinit { |
| 700 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { |
| 701-703 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { |
| 704 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 705-715 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 716-724 | vendor-era-uncertain | `7c682a67a842` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 725-728 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 729 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 730-732 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 733-747 | post-extraction-review | `8ee8a196bbf5`, `d4b03be30e75`, `d695fb70583a`, `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 748-778 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 779-781 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 782-789 | post-extraction-review | `b64a219836ef`, `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 790-798 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 799-804 | post-extraction-review | `45a60cd7fcfc`, `831e5af61c03` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 805 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 806-823 | post-extraction-review | `831e5af61c03`, `45a60cd7fcfc`, `ac5d35a007e4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 824-847 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 848 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 849-853 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 854-861 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 862 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 863-882 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 883-887 | post-extraction-review | `4ccdba121f6d`, `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 888 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 889-895 | post-extraction-review | `45a60cd7fcfc`, `831e5af61c03` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 896 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 897-898 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 899-913 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 914-924 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 925-956 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 957 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 958 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 959-962 | post-extraction-review | `4ccdba121f6d`, `45a60cd7fcfc`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 963-967 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 968 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 969 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 970-973 | post-extraction-review | `4ccdba121f6d`, `45a60cd7fcfc`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 974 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 975 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 976-980 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 981-986 | post-extraction-review | `4ccdba121f6d`, `45a60cd7fcfc`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 987-993 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 994-1000 | vendor-era-uncertain | `d2ce06f1b093`, `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1001 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1002-1008 | vendor-era-uncertain | `d2ce06f1b093`, `98c75cf88994`, `ed229daadfdb` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1009 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1010-1017 | vendor-era-uncertain | `d2ce06f1b093`, `382b973bb9ed`, `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1018-1024 | post-extraction-review | `ac5d35a007e4`, `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1025-1027 | vendor-era-uncertain | `98c75cf88994`, `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1028-1033 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1034-1043 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1044 | post-extraction-review | `0f30f2e7c0d4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1045-1053 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func draw(in view: MTKView) { |
| 1054-1055 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | nonisolated private func markPendingRedraw() { |
| 1056-1057 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | nonisolated private func markPendingRedraw() { |
| 1058-1059 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | nonisolated private func consumePendingRedraw() -> Bool { |
| 1060-1061 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | nonisolated private func consumePendingRedraw() -> Bool { |
| 1062 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1063 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1064-1073 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1074 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1075 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1076-1080 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1081 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1082-1084 | post-extraction-review | `9c53c58fe8eb`, `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1085 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1086-1089 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1090-1100 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1101-1113 | post-extraction-review | `9c53c58fe8eb`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1114-1122 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1123 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1124-1126 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1127-1132 | post-extraction-review | `8ee8a196bbf5`, `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1133-1135 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1136-1141 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1142-1147 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1148-1155 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1156-1157 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1158-1161 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1162-1165 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1166 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1167-1174 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1175-1179 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1180 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1181-1183 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1184-1188 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1189 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1190 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1191-1195 | post-extraction-review | `0bec46a41928`, `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1196-1198 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1199 | post-extraction-review | `0bec46a41928` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1200-1204 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1205-1206 | post-extraction-review | `d4b03be30e75`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1207-1209 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1210 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1211-1213 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1214 | post-extraction-review | `0bec46a41928` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1215-1219 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1220-1221 | post-extraction-review | `d4b03be30e75`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1222-1224 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1225 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1226-1228 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1229 | post-extraction-review | `0bec46a41928` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1230-1246 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1247-1248 | post-extraction-review | `d4b03be30e75`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1249-1251 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1252 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1253-1255 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1256 | post-extraction-review | `0bec46a41928` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1257-1264 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1265-1272 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1273-1274 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1275-1276 | post-extraction-review | `c94591caa2cd` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1277-1282 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1283-1284 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1285-1292 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1293-1294 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1295-1296 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1297-1299 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1300-1301 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1302 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1303-1305 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildDrawData(scale: CGFloat) -> DrawData { |
| 1306-1317 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func intersect(_ range: ClosedRange<Int>?, _ other: ClosedRange<Int>) -> ClosedRange<... |
| 1318-1322 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func rowCoordinateEpoch(for retainedRowOrigin: Int) -> Int { |
| 1323-1324 | post-extraction-review | `8ee8a196bbf5`, `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1325 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1326-1327 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1328-1330 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1331 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1332-1334 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1335 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1336 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1337 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1338 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1339 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1340-1343 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1344-1346 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1347 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1348-1356 | post-extraction-review | `831e5af61c03`, `eeafffb2c0f9` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1357-1359 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1360-1362 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1363-1365 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func visibleRowRange(grid: GridSnapshot, |
| 1366 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1367-1368 | post-extraction-review | `d4b03be30e75`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1369-1371 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1372 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1373 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1374-1375 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1376-1384 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1385 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1386-1404 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1405-1410 | post-extraction-review | `d4b03be30e75`, `dc0f4ba5acf3`, `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1411 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1412-1413 | post-extraction-review | `d4b03be30e75`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1414-1423 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1424 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1425-1439 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1440-1441 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1442-1447 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1448-1449 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1450-1483 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1484-1485 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1486-1535 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1536-1537 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1538-1541 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildRowDrawData(row: Int, |
| 1542-1552 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformPoint(_ point: CGPoint) -> CGPoint { |
| 1553-1564 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1565 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1566-1568 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1569-1570 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1571-1581 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1582-1588 | vendor-era-uncertain | `7c682a67a842` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1589-1604 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1605-1608 | post-extraction-review | `8ee8a196bbf5`, `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1609-1618 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1619 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1620-1629 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1630 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1631-1695 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1696 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1697-1699 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1700 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1701 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1702 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1703-1705 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1706 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1707-1708 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1709-1711 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1712-1716 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Floa... |
| 1717-1726 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1727-1729 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1730-1731 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1732-1739 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1740-1742 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1743 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1744 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1745-1746 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1747-1748 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1749-1751 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1752-1774 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1775-1776 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1777-1789 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1790 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1791-1792 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1793 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1794 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1795-1796 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1797 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1798 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1799-1830 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1831 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1832 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1833 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1834-1844 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1845-1846 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1847 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1848 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1849-1900 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1901 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1902-1950 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func decorationBasePosition(for localCell: Int) -> CGPoint { |
| 1951 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildShapedSegments(_ segments: [ViewLineSegment], source: any MetalRenderSource... |
| 1952-1957 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildShapedSegments(_ segments: [ViewLineSegment], source: any MetalRenderSource... |
| 1958-1960 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildShapedSegments(_ segments: [ViewLineSegment], source: any MetalRenderSource... |
| 1961-1967 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildShapedSegments(_ segments: [ViewLineSegment], source: any MetalRenderSource... |
| 1968-1985 | post-extraction-review | `d695fb70583a`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildShapedSegments(_ segments: [ViewLineSegment], source: any MetalRenderSource... |
| 1986-1987 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildShapedSegments(_ segments: [ViewLineSegment], source: any MetalRenderSource... |
| 1988-1991 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildShapedSegments(_ segments: [ViewLineSegment], source: any MetalRenderSource... |
| 1992-1999 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildShapedSegments(_ segments: [ViewLineSegment], source: any MetalRenderSource... |
| 2000-2004 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2005-2010 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2011 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2012-2018 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2019-2023 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2024-2026 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2027-2028 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2029-2031 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2032 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2033-2040 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2041-2049 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? { |
| 2050-2061 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func scaledFontFor(font: CTFont, scale: CGFloat) -> CTFont { |
| 2062-2068 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func alignToPixel(_ value: CGFloat, scale: CGFloat, rule: FloatingPointRoundingRule) ... |
| 2069-2079 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func pixelAlignedRect(_ rect: CGRect, scale: CGFloat) -> CGRect { |
| 2080-2093 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func customGlyphEntry(codePoint: UInt32, |
| 2094-2098 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func customGlyphEntry(codePoint: UInt32, |
| 2099-2110 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func customGlyphEntry(codePoint: UInt32, |
| 2111-2113 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func customGlyphEntry(codePoint: UInt32, |
| 2114-2124 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func customGlyphEntry(codePoint: UInt32, |
| 2125-2207 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func renderCustomGlyphBitmap(codePoint: UInt32, |
| 2208-2211 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func renderCustomGlyphBitmap(codePoint: UInt32, |
| 2212-2229 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func isEffectivelyMonospaced(_ font: CTFont) -> Bool { |
| 2230-2244 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func quadVertices(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, color: SIMD4<Fl... |
| 2245-2246 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func glyphQuadVertices(x0: Float, y0: Float, x1: Float, y1: Float, |
| 2247 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func glyphQuadVertices(x0: Float, y0: Float, x1: Float, y1: Float, |
| 2248-2256 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func glyphQuadVertices(x0: Float, y0: Float, x1: Float, y1: Float, |
| 2257-2262 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func glyphQuadVertices(x0: Float, y0: Float, x1: Float, y1: Float, |
| 2263-2265 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func glyphQuadVertices(x0: Float, y0: Float, x1: Float, y1: Float, |
| 2266-2271 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeColorCell(x0: Float, y0: Float, x1: Float, y1: Float, color: SIMD4<Float>) -... |
| 2272-2279 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeTextCell(x0: Float, |
| 2280-2281 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func makeTextCell(x0: Float, |
| 2282-2289 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeTextCell(x0: Float, |
| 2290-2291 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func makeTextCell(x0: Float, |
| 2292-2293 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeTextCell(x0: Float, |
| 2294-2297 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShaperKey: Hashable { |
| 2298 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct ShaperKey: Hashable { |
| 2299-2300 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShaperKey: Hashable { |
| 2301 | post-extraction-review | `d029cee0e521` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct ShapingFontKey: Hashable { |
| 2302-2303 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShapingFontKey: Hashable { |
| 2304-2305 | post-extraction-review | `d029cee0e521` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct ShapingFontKey: Hashable { |
| 2306-2309 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShaperGlyphRun { |
| 2310 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct ShaperGlyphRun { |
| 2311-2312 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShaperGlyphRun { |
| 2313-2316 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShaperRun { |
| 2317 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct ShaperRun { |
| 2318-2319 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShaperRun { |
| 2320-2322 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShapedRun { |
| 2323-2324 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private struct ShapedRun { |
| 2325-2326 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShapedRun { |
| 2327-2331 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private struct ShapedSegment { |
| 2332-2335 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private final class ShaperCache { |
| 2336 | post-extraction-review | `d029cee0e521` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private final class ShaperCache { |
| 2337 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private final class ShaperCache { |
| 2338-2341 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | init(maxEntries: Int) { |
| 2342 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2343-2347 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2348-2349 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2350-2353 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2354-2369 | post-extraction-review | `d029cee0e521` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2370-2374 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2375-2378 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2379 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2380 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2381-2401 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2402-2406 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2407-2410 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2411-2415 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2416-2418 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2419-2421 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2422-2425 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func shape(text: String, font: CTFont, cellUTF16Boundaries: [Int]) -> ShaperRun? { |
| 2426-2437 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func insert(key: ShaperKey, run: ShaperRun) { |
| 2438-2472 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func colorToSIMD(_ color: TTColor) -> SIMD4<Float> { |
| 2473-2474 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func makeBuffer<T>(_ vertices: [T]) -> MetalBufferSlice? { |
| 2475-2476 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeBuffer<T>(_ vertices: [T]) -> MetalBufferSlice? { |
| 2477-2481 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeStaticBuffer<T>(_ vertices: [T]) -> (MTLBuffer?, Int) { |
| 2482-2484 | post-extraction-review | `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func makeStaticBuffer<T>(_ vertices: [T]) -> (MTLBuffer?, Int) { |
| 2485-2487 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeStaticBuffer<T>(_ vertices: [T]) -> (MTLBuffer?, Int) { |
| 2488-2490 | post-extraction-review | `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func makeStaticBuffer<T>(_ vertices: [T]) -> (MTLBuffer?, Int) { |
| 2491-2494 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeStaticBuffer<T>(_ vertices: [T]) -> (MTLBuffer?, Int) { |
| 2495-2510 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeImageDrawBuffers(_ draws: [ImageDraw]) -> [ImageDrawBuffer] { |
| 2511-2529 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func makeRowBuffers(from data: RowDrawData) -> RowDrawBuffers { |
| 2530-2534 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawCellBuffer<T>(_ cells: [T], |
| 2535 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawCellBuffer<T>(_ cells: [T], |
| 2536-2538 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawCellBuffer<T>(_ cells: [T], |
| 2539-2542 | post-extraction-review | `4ccdba121f6d`, `45a60cd7fcfc`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawCellBuffer<T>(_ cells: [T], |
| 2543-2544 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawCellBuffer<T>(_ cells: [T], |
| 2545 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawCellBuffer<T>(_ cells: [T], |
| 2546-2549 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawCellBuffer<T>(_ cells: [T], |
| 2550 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawFrameData(_ frame: FrameDrawData, |
| 2551 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawFrameData(_ frame: FrameDrawData, |
| 2552-2553 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawFrameData(_ frame: FrameDrawData, |
| 2554-2561 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawFrameData(_ frame: FrameDrawData, |
| 2562-2570 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawFrameData(_ frame: FrameDrawData, |
| 2571-2588 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawFrameData(_ frame: FrameDrawData, |
| 2589-2593 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawFrameData(_ frame: FrameDrawData, |
| 2594-2615 | post-extraction-review | `a652a3c0afe1`, `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawDatabloomGlyphCells(_ cells: [TextCell], |
| 2616-2639 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawDatabloomGlyphRows(_ rows: [RowDrawBuffers], |
| 2640-2675 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func encodeDatabloomPasses(encoder: MTLRenderCommandEncoder, |
| 2676-2681 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawImageBatches(_ draws: [ImageDraw], encoder: MTLRenderCommandEncoder, viewpor... |
| 2682-2684 | post-extraction-review | `45a60cd7fcfc`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawImageBatches(_ draws: [ImageDraw], encoder: MTLRenderCommandEncoder, viewpor... |
| 2685 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawImageBatches(_ draws: [ImageDraw], encoder: MTLRenderCommandEncoder, viewpor... |
| 2686 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawImageBatches(_ draws: [ImageDraw], encoder: MTLRenderCommandEncoder, viewpor... |
| 2687-2688 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawImageBatches(_ draws: [ImageDraw], encoder: MTLRenderCommandEncoder, viewpor... |
| 2689 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawImageBatches(_ draws: [ImageDraw], encoder: MTLRenderCommandEncoder, viewpor... |
| 2690-2694 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawImageBatches(_ draws: [ImageDraw], encoder: MTLRenderCommandEncoder, viewpor... |
| 2695-2712 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawVertexBuffers(rows: [RowDrawBuffers], |
| 2713-2715 | post-extraction-review | `45a60cd7fcfc`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawVertexBuffers(rows: [RowDrawBuffers], |
| 2716-2717 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawVertexBuffers(rows: [RowDrawBuffers], |
| 2718 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawVertexBuffers(rows: [RowDrawBuffers], |
| 2719-2732 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawVertexBuffers(rows: [RowDrawBuffers], |
| 2733-2748 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawImageRows(rows: [RowDrawBuffers], |
| 2749-2751 | post-extraction-review | `45a60cd7fcfc`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawImageRows(rows: [RowDrawBuffers], |
| 2752-2760 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func drawImageRows(rows: [RowDrawBuffers], |
| 2761-2764 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func drawImageRows(rows: [RowDrawBuffers], |
| 2765-2768 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func sampler(for texture: MTLTexture) -> MTLSamplerState { |
| 2769 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2770-2771 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2772-2779 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2780 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2781-2782 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2783 | post-extraction-review | `9a8efa1de04d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2784-2785 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2786-2789 | post-extraction-review | `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2790-2791 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2792 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2793-2794 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2795 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2796 | vendor-era-uncertain | `eae6014681fb` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2797 | post-extraction-review | `ac5d35a007e4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2798-2799 | vendor-era-uncertain | `eae6014681fb` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2800-2803 | post-extraction-review | `d4b03be30e75`, `dc0f4ba5acf3`, `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2804-2806 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2807-2811 | post-extraction-review | `dad2afb5333e`, `9c53c58fe8eb`, `d4b03be30e75` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2812-2814 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2815 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2816-2820 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2821 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2822-2826 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2827-2835 | post-extraction-review | `628b6d3eccd4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2836 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2837-2841 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2842-2845 | post-extraction-review | `9c53c58fe8eb` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2846-2849 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2850 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2851-2854 | post-extraction-review | `dad2afb5333e` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2855 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2856 | vendor-era-uncertain | `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2857-2863 | post-extraction-review | `dc0f4ba5acf3`, `45a60cd7fcfc`, `8ee8a196bbf5`, `9c53c58fe8eb`, `dad2afb5333e` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2864 | vendor-era-uncertain | `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2865-2866 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2867 | vendor-era-uncertain | `eae6014681fb` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2868-2922 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2923-2928 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2929-2932 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2933-2937 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2938-2939 | vendor-era-uncertain | `eae6014681fb` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2940 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2941-2947 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2948 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2949-2972 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2973-2978 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2979-2995 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2996-2997 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 2998-3010 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func buildCursorDrawData(scale: CGFloat, |
| 3011 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func texture(for image: any RenderableCellImage) -> MTLTexture? { |
| 3012-3041 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func texture(for image: any RenderableCellImage) -> MTLTexture? { |
| 3042 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func kittyTexture(imageId: UInt32) -> MTLTexture? { |
| 3043-3044 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func kittyTexture(imageId: UInt32) -> MTLTexture? { |
| 3045-3046 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func kittyTexture(imageId: UInt32) -> MTLTexture? { |
| 3047 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func kittyTexture(imageId: UInt32) -> MTLTexture? { |
| 3048-3051 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func kittyTexture(imageId: UInt32) -> MTLTexture? { |
| 3052 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func kittyTexture(imageId: UInt32) -> MTLTexture? { |
| 3053-3070 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func kittyTexture(imageId: UInt32) -> MTLTexture? { |
| 3071 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func kittySignature(for payload: KittyImagePayload) -> KittyImageSignature { |
| 3072-3081 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func kittySignature(for payload: KittyImagePayload) -> KittyImageSignature { |
| 3082-3094 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func hashBytes(_ data: Data, limit: Int) -> UInt32 { |
| 3095 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func textureFromRGBA(bytes: [UInt8], width: Int, height: Int) -> MTLTexture? { |
| 3096-3102 | post-extraction-review | `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func textureFromRGBA(bytes: [UInt8], width: Int, height: Int) -> MTLTexture? { |
| 3103-3112 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func textureFromRGBA(bytes: [UInt8], width: Int, height: Int) -> MTLTexture? { |
| 3113-3118 | post-extraction-review | `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func textureFromRGBA(bytes: [UInt8], width: Int, height: Int) -> MTLTexture? { |
| 3119-3121 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func textureFromRGBA(bytes: [UInt8], width: Int, height: Int) -> MTLTexture? { |
| 3122-3137 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func cgImage(from image: TTImage) -> CGImage? { |
| 3138-3144 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func textureOptions() -> [MTKTextureLoader.Option: Any] { |
| 3145-3147 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func imageDraw(texture: MTLTexture, |
| 3148 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func imageDraw(texture: MTLTexture, |
| 3149-3169 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func imageDraw(texture: MTLTexture, |
| 3170-3222 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func clipRect(_ x0: Float, |
| 3223-3226 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func transformImageRect(x0: CGFloat, |
| 3227 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func transformImageRect(x0: CGFloat, |
| 3228 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func transformImageRect(x0: CGFloat, |
| 3229-3247 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformPoint(_ point: CGPoint) -> CGPoint { |
| 3248-3260 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func kittyAspectFitRect(imageSize: CGSize, in rect: CGRect) -> CGRect { |
| 3261-3265 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func appendUnderlineSegments(x0: CGFloat, |
| 3266 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func appendUnderlineSegments(x0: CGFloat, |
| 3267 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func appendUnderlineSegments(x0: CGFloat, |
| 3268 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func appendUnderlineSegments(x0: CGFloat, |
| 3269-3276 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func appendUnderlineSegments(x0: CGFloat, |
| 3277-3318 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func emitSegment(start: CGFloat, end: CGFloat, centerY: CGFloat) { |
| 3319 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func resolveUnderlineStyle(_ attributes: [NSAttributedString.Key: Any]) -> RenderUnde... |
| 3320 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func resolveUnderlineStyle(_ attributes: [NSAttributedString.Key: Any]) -> RenderUnde... |
| 3321 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func resolveUnderlineStyle(_ attributes: [NSAttributedString.Key: Any]) -> RenderUnde... |
| 3322-3337 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func resolveUnderlineStyle(_ attributes: [NSAttributedString.Key: Any]) -> RenderUnde... |
| 3338-3341 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func transformUnderlineRect(x0: CGFloat, |
| 3342 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func transformUnderlineRect(x0: CGFloat, |
| 3343 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func transformUnderlineRect(x0: CGFloat, |
| 3344-3362 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func transformPoint(_ point: CGPoint) -> CGPoint { |
| 3363-3366 | post-extraction-review | `d029cee0e521`, `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func transformPoint(_ point: CGPoint) -> CGPoint { |
| 3367-3379 | post-extraction-review | `d695fb70583a`, `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func shaderAnimationIsActive(keypressAge: Float) -> Bool { |
| 3380-3382 | vendor-era-uncertain | `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func scheduleShaderFrame() { |
| 3383-3388 | post-extraction-review | `d029cee0e521`, `ac5d35a007e4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func scheduleShaderFrame() { |
| 3389-3394 | vendor-era-uncertain | `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func scheduleShaderFrame() { |
| 3395-3397 | post-extraction-review | `d029cee0e521` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func scheduleShaderFrame() { |
| 3398-3413 | post-extraction-review | `d029cee0e521`, `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | static func shaderTargetFPS(isKeyWindow: Bool, |
| 3414-3426 | post-extraction-review | `dad2afb5333e` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | static func cursorHeightPixels( |
| 3427 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | static func cursorHeightPixels( |
| 3428 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func ensureSceneTexture(size: CGSize, format: MTLPixelFormat) { |
| 3429-3444 | post-extraction-review | `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func ensureSceneTexture(size: CGSize, format: MTLPixelFormat) { |
| 3445-3461 | vendor-era-uncertain | `d2ce06f1b093`, `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func ensureSceneTexture(size: CGSize, format: MTLPixelFormat) { |
| 3462-3463 | post-extraction-review | `8ee8a196bbf5`, `ac5d35a007e4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func loadUserShader(source: String?) -> String? { |
| 3464-3494 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func loadUserShader(source: String?) -> String? { |
| 3495-3496 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct TermiteVaryings { float4 position [[position]]; float2 uv; }; |
| 3497-3545 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | struct TermiteUniforms { |
| 3546-3550 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeCRTPipeline(device: MTLDevice, |
| 3551-3555 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeCRTPipeline(device: MTLDevice, |
| 3556 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func makeCRTPipeline(device: MTLDevice, |
| 3557-3558 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeCRTPipeline(device: MTLDevice, |
| 3559 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeCRTPipeline(device: MTLDevice, |
| 3560-3562 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeCRTPipeline(device: MTLDevice, |
| 3563-3574 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeTextPipeline(device: MTLDevice, |
| 3575 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func makeTextPipeline(device: MTLDevice, |
| 3576-3587 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeTextPipeline(device: MTLDevice, |
| 3588-3599 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeColorPipeline(device: MTLDevice, |
| 3600 | post-extraction-review | `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func makeColorPipeline(device: MTLDevice, |
| 3601-3612 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeColorPipeline(device: MTLDevice, |
| 3613 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func isBlinkStyle(_ style: RenderCursorStyle) -> Bool { |
| 3614-3621 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func isBlinkStyle(_ style: RenderCursorStyle) -> Bool { |
| 3622-3624 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3625-3626 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3627-3629 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3630-3632 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3633-3639 | post-extraction-review | `ac5d35a007e4`, `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3640 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3641-3654 | post-extraction-review | `4ccdba121f6d`, `ac5d35a007e4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3655 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3656-3657 | post-extraction-review | `ac5d35a007e4` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3658 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3659-3660 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3661-3662 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3663-3666 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func updateCursorBlinkTimer(shouldBlink: Bool, externallyDriven: Bool = false) { |
| 3667-3669 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func settleCursorBlink(requestFinalFrame: Bool) { |
| 3670 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func settleCursorBlink(requestFinalFrame: Bool) { |
| 3671-3674 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func settleCursorBlink(requestFinalFrame: Bool) { |
| 3675-3677 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func settleCursorBlink(requestFinalFrame: Bool) { |
| 3678-3682 | post-extraction-review | `ac5d35a007e4`, `eeafffb2c0f9` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func settleCursorBlink(requestFinalFrame: Bool) { |
| 3683 | post-extraction-review | `831e5af61c03` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func noteScroll(pixels: CGFloat) { |
| 3684 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | public func noteScroll(pixels: CGFloat) { |
| 3685-3704 | post-extraction-review | `a652a3c0afe1`, `3ba83c216876`, `831e5af61c03`, `d4b03be30e75`, `eeafffb2c0f9` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func noteScroll(pixels: CGFloat) { |
| 3705-3713 | post-extraction-review | `eeafffb2c0f9`, `831e5af61c03`, `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func setScrollHeld(_ pixels: CGFloat) { |
| 3714-3717 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func noteScrollActivity(pixels: CGFloat) { |
| 3718-3721 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func noteScrollActivity(pixels: CGFloat, at now: CFTimeInterval) { |
| 3722-3729 | post-extraction-review | `4ccdba121f6d`, `831e5af61c03` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func cancelScrollAnimation() { |
| 3730-3742 | post-extraction-review | `ac5d35a007e4`, `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func noteActivity() { |
| 3743-3746 | post-extraction-review | `d695fb70583a` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | public func invalidateRowCache() { |
| 3747 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func pruneKittyTextureCache() { |
| 3748 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func pruneKittyTextureCache() { |
| 3749-3754 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func pruneKittyTextureCache() { |
| 3755 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func pruneKittyTextureCache() { |
| 3756-3758 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func pruneKittyTextureCache() { |
| 3759 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private func pruneKittyTextureCache() { |
| 3760-3770 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private func pruneKittyTextureCache() { |
| 3771-3801 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary { |
| 3802-3810 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func libraryHasRequiredFunctions(_ library: MTLLibrary) -> Bool { |
| 3811-3816 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func requiredShaderFunctions() -> [String] { |
| 3817 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func requiredShaderFunctions() -> [String] { |
| 3818-3823 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func requiredShaderFunctions() -> [String] { |
| 3824-3833 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func loadShaderSource() -> String? { |
| 3834-3850 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func findMetallibURL() -> URL? { |
| 3851-3852 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | private static func candidateBundles() -> [Bundle] { |
| 3853 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func candidateBundles() -> [Bundle] { |
| 3854-3867 | post-extraction-review | `a652a3c0afe1`, `584624985809` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func append(_ bundle: Bundle?) { |
| 3868-3869 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func append(_ bundle: Bundle?) { |
| 3870-3872 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func append(_ bundle: Bundle?) { |
| 3873-3875 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | private static func resourceBundle(named name: String) -> Bundle? { |
| 3876-3884 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func append(_ url: URL?) { |
| 3885-3906 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift` | func appendExecutableAncestors(_ executableURL: URL?) { |
| 3907-3908 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` | func appendExecutableAncestors(_ executableURL: URL?) { |

## `Renderer/Sources/TermiteGPU/PlatformCompat.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-12 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/PlatformCompat.swift` | file scope |
| 13 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/PlatformCompat.swift` | public enum RenderUnderlineStyle: UInt8 { |
| 14-21 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/CharData.swift` | public enum RenderUnderlineStyle: UInt8 { |
| 22-25 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/PlatformCompat.swift` | public enum RenderUnderlineStyle: UInt8 { |
| 26-30 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/PlatformCompat.swift` | public extension NSAttributedString.Key { |

## `Renderer/Sources/TermiteGPU/RenderTypes.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-6 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | file scope |
| 7-9 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift` | file scope |
| 10-23 | post-extraction-review | `8ee8a196bbf5`, `d695fb70583a` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public struct ViewLineSegment { |
| 24-43 | post-extraction-review | `d695fb70583a`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public init(column: Int, columnWidth: Int, characterCount: Int, |
| 44-51 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public struct ViewLineInfo { |
| 52-66 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public init(segments: [ViewLineSegment], |
| 67-80 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public protocol RenderableCellImage: AnyObject { |
| 81-89 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public struct KittyPlaceholderCell { |
| 90-106 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public init(row: Int, col: Int, imageId: UInt32, placementId: UInt32, |
| 107-114 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public enum RenderLineMode { |
| 115-120 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public enum RenderCursorStyle { |
| 121-139 | post-extraction-review | `8ee8a196bbf5`, `d4b03be30e75` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public struct GridSnapshot { |
| 140-158 | post-extraction-review | `d4b03be30e75`, `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public init(rows: Int, cols: Int, bufferLineCount: Int, retainedRowOrigin: Int = 0, |
| 159-164 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public struct KittyCacheStamp: Hashable { |
| 165-173 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public init(imagesCount: Int, placementsCount: Int, nextImageId: UInt32, nextPlacementId: UIn... |
| 174 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public enum KittyImagePayload { |
| 175-178 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/KittyGraphics.swift` | public enum KittyImagePayload { |
| 179 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public enum KittyImagePayload { |
| 180-187 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public struct KittyPlacementSpec { |
| 188-198 | post-extraction-review | `8ee8a196bbf5` | `Renderer/Sources/TermiteGPU/RenderTypes.swift` | public init(imageId: UInt32, placementId: UInt32, cols: Int, rows: Int, |

## `Renderer/Sources/TermiteGPU/Shaders.metal`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-3 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | file scope |
| 4-7 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | GlyphVertex |
| 8 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/Shaders.metal` | GlyphVertex |
| 9-10 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | GlyphVertex |
| 11-16 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | TextCell |
| 17 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/Shaders.metal` | TextCell |
| 18-19 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | TextCell |
| 20-25 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | ColorCell |
| 26-29 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | GlyphOut |
| 30 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/Shaders.metal` | GlyphOut |
| 31-41 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | GlyphOut |
| 42-43 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_text_vertex |
| 44 | post-extraction-review | `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_text_vertex |
| 45 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_text_vertex |
| 46-49 | post-extraction-review | `9c53c58fe8eb`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_text_vertex |
| 50-53 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_text_vertex |
| 54 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_text_vertex |
| 55-57 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_text_vertex |
| 58-59 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_cell_text_vertex |
| 60 | post-extraction-review | `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_cell_text_vertex |
| 61-65 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_cell_text_vertex |
| 66-67 | post-extraction-review | `9c53c58fe8eb`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_cell_text_vertex |
| 68-71 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_cell_text_vertex |
| 72 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_cell_text_vertex |
| 73-75 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_cell_text_vertex |
| 76-79 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_text_fragment |
| 80-82 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | float4 |
| 83-84 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_text_fragment_gray |
| 85-86 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_text_fragment_gray |
| 87 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_text_fragment_gray |
| 88-90 | vendor-era-uncertain | `8b0654ce3efe` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_text_fragment_gray |
| 91 | post-extraction-review | `3ba83c216876` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_text_fragment_gray |
| 92-94 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | float4 |
| 95-98 | post-extraction-review | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_atlas_text_fragment |
| 99-101 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | float4 |
| 102-107 | post-extraction-review | `4ccdba121f6d`, `3ba83c216876` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_atlas_text_fragment_gray |
| 108-110 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | float4 |
| 111-117 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/Shaders.metal` | DatabloomTextUniforms |
| 118 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/Shaders.metal` | t64_databloom_hash |
| 119-121 | vendor-era-uncertain | `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | fract |
| 122 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/Shaders.metal` | t64_databloom_palette |
| 123-125 | vendor-era-uncertain | `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | t64_databloom_palette |
| 126-128 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/Shaders.metal` | t64_databloom_palette |
| 129-145 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_atlas_text_fragment_gray_databloom |
| 146-159 | post-extraction-review | `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/Shaders.metal` | float4 |
| 160-164 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | ColorVertex |
| 165-169 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | ColorOut |
| 170-171 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_color_vertex |
| 172 | post-extraction-review | `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_color_vertex |
| 173 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_color_vertex |
| 174-175 | post-extraction-review | `9c53c58fe8eb`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_color_vertex |
| 176-181 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_color_vertex |
| 182-183 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_cell_color_vertex |
| 184 | post-extraction-review | `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_cell_color_vertex |
| 185-189 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_cell_color_vertex |
| 190-191 | post-extraction-review | `9c53c58fe8eb`, `dc0f4ba5acf3` | `Renderer/Sources/TermiteGPU/Shaders.metal` | terminal_cell_color_vertex |
| 192-197 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_cell_color_vertex |
| 198-200 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_color_fragment |
| 201-204 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | terminal_color_fragment |
| 205 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | CRTVaryings |
| 206 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | CRTVaryings |
| 207-209 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | CRTVaryings |
| 210-220 | vendor-era-uncertain | `d2ce06f1b093`, `ed229daadfdb`, `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | CRTUniforms |
| 221 | vendor-era-uncertain | `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | t64_hash |
| 222-225 | vendor-era-uncertain | `98c75cf88994` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | fract |
| 226-231 | vendor-era-uncertain | `98c75cf88994`, `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | t64_palette |
| 232-233 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | t64_textMask |
| 234-236 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | clamp |
| 237 | post-extraction-review | `79a940347564` | `Renderer/Sources/TermiteGPU/Shaders.metal` | clamp |
| 238-244 | post-extraction-review | `79a940347564` | `Renderer/Sources/TermiteGPU/Shaders.metal` | t64_vnoise |
| 245-246 | post-extraction-review | `79a940347564` | `Renderer/Sources/TermiteGPU/Shaders.metal` | mix |
| 247-256 | post-extraction-review | `79a940347564` | `Renderer/Sources/TermiteGPU/Shaders.metal` | t64_fbm |
| 257-303 | vendor-era-uncertain | `d2ce06f1b093`, `382b973bb9ed`, `98c75cf88994`, `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | crt_vertex |
| 304-335 | post-extraction-review | `79a940347564`, `a652a3c0afe1` | `Renderer/Sources/TermiteGPU/Shaders.metal` | crt_vertex |
| 336-337 | vendor-era-uncertain | `382b973bb9ed` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | crt_vertex |
| 338-901 | vendor-era-uncertain | `d2ce06f1b093`, `382b973bb9ed`, `c077add57fe1`, `98c75cf88994`, `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | crt_fragment |
| 902-918 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | if |
| 919-922 | post-extraction-review | `79a940347564` | `Renderer/Sources/TermiteGPU/Shaders.metal` | if |
| 923-928 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | if |
| 929-955 | post-extraction-review | `79a940347564` | `Renderer/Sources/TermiteGPU/Shaders.metal` | if |
| 956-957 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | if |
| 958-1073 | post-extraction-review | `79a940347564` | `Renderer/Sources/TermiteGPU/Shaders.metal` | if |
| 1074-1075 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | if |
| 1076-1095 | post-extraction-review | `79a940347564` | `Renderer/Sources/TermiteGPU/Shaders.metal` | if |
| 1096-1097 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | if |
| 1098-1257 | post-extraction-review | `79a940347564` | `Renderer/Sources/TermiteGPU/Shaders.metal` | if |
| 1258-1262 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | if |
| 1263-1264 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal` | float4 |

## `Renderer/Sources/TermiteGPU/CursorGlide.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-2 | cmdy-addition | `628b6d3eccd4` | `Renderer/Sources/TermiteGPU/CursorGlide.swift` | file scope |
| 3-7 | cmdy-addition | `628b6d3eccd4` | `Renderer/Sources/TermiteGPU/CursorGlide.swift` | struct CursorGlideStep { |
| 8 | cmdy-addition | `628b6d3eccd4` | `Renderer/Sources/TermiteGPU/CursorGlide.swift` | enum CursorGlide { |
| 9-29 | cmdy-addition | `628b6d3eccd4` | `Renderer/Sources/TermiteGPU/CursorGlide.swift` | static func step(from current: SIMD2<Float>, to target: SIMD2<Float>, |

## `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-3 | cmdy-addition | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | file scope |
| 4-11 | cmdy-addition | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | struct MetalBufferSlice { |
| 12 | cmdy-addition | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | final class DynamicBufferRing { |
| 13-17 | cmdy-addition | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | private final class Arena { |
| 18-30 | cmdy-addition | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | func reset() { |
| 31-39 | cmdy-addition | `4ccdba121f6d`, `584624985809` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | init(device: MTLDevice, frameCount: Int = 3, |
| 40-44 | cmdy-addition | `4ccdba121f6d` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | func beginFrame() { |
| 45-80 | cmdy-addition | `4ccdba121f6d`, `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | func write<T>(_ values: [T]) -> MetalBufferSlice? { |
| 81-86 | cmdy-addition | `4ccdba121f6d`, `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | private func aligned(_ value: Int) -> Int { |
| 87-101 | cmdy-addition | `4ccdba121f6d`, `fbe7a56c73ac` | `Renderer/Sources/TermiteGPU/DynamicBufferRing.swift` | private func allocate(minimumLength: Int) -> MTLBuffer? { |

## `Renderer/Sources/TermiteGPU/TerminalFontFeatures.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-6 | cmdy-addition | `d029cee0e521` | `Renderer/Sources/TermiteGPU/TerminalFontFeatures.swift` | file scope |
| 7-18 | cmdy-addition | `d029cee0e521` | `Renderer/Sources/TermiteGPU/TerminalFontFeatures.swift` | func terminalGridShapingFont(_ font: CTFont) -> CTFont { |

## `App/TermiteCoreShaping.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-9 | post-extraction-review | `a1069e5b2eb2`, `1dade4bb5a5c`, `c8c69fbf2014` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | file scope |
| 10-13 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | extension TermiteCoreSurface: MetalRenderSource { |
| 14-27 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d`, `d4b03be30e75` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func captureGrid() -> GridSnapshot { |
| 28-29 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | static func renderCursorStyle(_ shape: TermCursorShape) -> RenderCursorStyle { |
| 30-38 | vendor-era-uncertain | `8ee8a196bbf5` | `Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MetalRenderSourceAdapter.swift` | static func renderCursorStyle(_ shape: TermCursorShape) -> RenderCursorStyle { |
| 39-42 | post-extraction-review | `0bec46a41928`, `4ccdba121f6d` | `App/TermiteCoreShaping.swift` | func lineVersion(forRow row: Int) -> UInt64 { |
| 43-47 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func lineInfo(forRow row: Int) -> ViewLineInfo { |
| 48-49 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift` | func lineInfo(forRow row: Int) -> ViewLineInfo { |
| 50-145 | post-extraction-review | `4ccdba121f6d`, `d4b03be30e75`, `a1069e5b2eb2`, `96d82f5bff26` | `App/TermiteCoreShaping.swift`<br>`Sources/term64/TermiteCoreShaping.swift` | func lineInfo(forRow row: Int) -> ViewLineInfo { |
| 146-149 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift` | func lineInfo(forRow row: Int) -> ViewLineInfo { |
| 150-152 | post-extraction-review | `96d82f5bff26` | `Sources/term64/TermiteCoreShaping.swift` | func lineInfo(forRow row: Int) -> ViewLineInfo { |
| 153 | post-extraction-review | `96d82f5bff26` | `Sources/term64/TermiteCoreShaping.swift` | private final class RunBuilder { |
| 154-168 | post-extraction-review | `d4b03be30e75`, `a1069e5b2eb2`, `96d82f5bff26`, `d695fb70583a` | `App/TermiteCoreShaping.swift`<br>`Sources/term64/TermiteCoreShaping.swift` | private struct Style: Equatable { |
| 169-172 | post-extraction-review | `d4b03be30e75` | `App/TermiteCoreShaping.swift` | init(resolve: @escaping (CellAttribute, Bool) -> [NSAttributedString.Key: Any]) { |
| 173-187 | post-extraction-review | `d4b03be30e75`, `96d82f5bff26`, `d695fb70583a` | `App/TermiteCoreShaping.swift`<br>`Sources/term64/TermiteCoreShaping.swift` | func append(_ piece: String, attribute: CellAttribute, selected: Bool, |
| 188-203 | post-extraction-review | `96d82f5bff26`, `d4b03be30e75`, `d695fb70583a`, `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func flush() { |
| 204-205 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func lineRenderMode(forRow row: Int) -> TermiteGPU.RenderLineMode { |
| 206-208 | vendor-era-uncertain | `8ee8a196bbf5` | `Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MetalRenderSourceAdapter.swift` | func lineRenderMode(forRow row: Int) -> TermiteGPU.RenderLineMode { |
| 209-212 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | func lineRenderMode(forRow row: Int) -> TermiteGPU.RenderLineMode { |
| 213-229 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d`, `96d82f5bff26` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func cursorCellAttributedString() -> NSAttributedString? { |
| 230-245 | post-extraction-review | `96d82f5bff26`, `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | func mapColor(_ color: CellColor, isFg: Bool, isBold: Bool) -> NSColor { |
| 246-256 | post-extraction-review | `96d82f5bff26`, `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | static func rgbInverse(_ color: NSColor) -> NSColor { |
| 257-265 | post-extraction-review | `96d82f5bff26`, `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | static func blend(_ a: NSColor, _ b: NSColor) -> NSColor { |
| 266-281 | post-extraction-review | `96d82f5bff26`, `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | private func resolvedPair(_ attr: CellAttribute) -> (fg: NSColor, bg: NSColor) { |
| 282-285 | post-extraction-review | `a1069e5b2eb2`, `96d82f5bff26` | `Sources/term64/TermiteCoreShaping.swift` | private func resolveFG(_ attr: CellAttribute, selected: Bool) -> NSColor { |
| 286-318 | post-extraction-review | `a1069e5b2eb2`, `96d82f5bff26`, `d695fb70583a` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func attributes(for attr: CellAttribute, selected: Bool) -> [NSAttributedString.Key: Any] { |
| 319-322 | post-extraction-review | `d695fb70583a` | `App/TermiteCoreShaping.swift` | static func needsExplicitBackground(_ attr: CellAttribute) -> Bool { |
| 323-338 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | private func fontFor(style: CellStyle) -> NSFont { |
| 339-346 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec] { |
| 347-348 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? { |
| 349-355 | vendor-era-uncertain | `8ee8a196bbf5` | `Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MetalRenderSourceAdapter.swift` | func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? { |
| 356-362 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? { |
| 363-364 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | func backingScaleFactor() -> CGFloat { window?.backingScaleFactor ?? 2 } |
| 365 | post-extraction-review | `96d82f5bff26` | `Sources/term64/TermiteCoreShaping.swift` | func underlinePosition() -> CGFloat { font.underlinePosition } |
| 366-367 | post-extraction-review | `96d82f5bff26`, `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | func underlineThickness() -> CGFloat { font.underlineThickness } |
| 368-374 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func getImageScale() -> CGFloat { window?.backingScaleFactor ?? 2 } |
| 375-380 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | func consumeDirtyRows() -> ClosedRange<Int>? { |
| 381-387 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreShaping.swift` | func selectionColumnsForShaping(absoluteRow row: Int) -> ClosedRange<Int>? { |
| 388-394 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreShaping.swift`<br>`App/TermiteCoreShaping.swift` | final class CoreCellImage: RenderableCellImage { |
| 395-412 | post-extraction-review | `4ccdba121f6d`, `a1069e5b2eb2` | `App/TermiteCoreShaping.swift`<br>`Sources/term64/TermiteCoreShaping.swift` | static func wrap(_ source: CoreLineImageSnapshot) -> CoreCellImage { |
| 413-441 | post-extraction-review | `4ccdba121f6d`, `a1069e5b2eb2` | `App/TermiteCoreShaping.swift`<br>`Sources/term64/TermiteCoreShaping.swift` | private init(_ source: CoreLineImageSnapshot) { |

## `App/TermiteCoreSurface.swift`

| Lines | Class | Commit | Historical path | Nearest declaration |
| ---: | --- | --- | --- | --- |
| 1-14 | post-extraction-review | `a1069e5b2eb2`, `1dade4bb5a5c`, `c8c69fbf2014` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | file scope |
| 15-98 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d`, `71d92ffdda9e`, `7e9bb7480fcc`, `7f3c77b3c7b8`, `4616a520f010`, `c986dbeaca81`, `2f48808df28a`, `d695fb70583a`, `5b2119d46b2c` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift`<br>`Sources/term64/SwiftTermAdapter.swift` | final class TermiteCoreSurface: NSView, TerminalSurface, TerminalSession { |
| 99-104 | vendor-era-uncertain | `d2ce06f1b093`, `382b973bb9ed` | `Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift` | final class TermiteCoreSurface: NSView, TerminalSurface, TerminalSession { |
| 105-113 | post-extraction-review | `3ba83c216876`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | final class TermiteCoreSurface: NSView, TerminalSurface, TerminalSession { |
| 114-119 | vendor-era-uncertain | `d2ce06f1b093` | `Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift` | final class TermiteCoreSurface: NSView, TerminalSurface, TerminalSession { |
| 120-168 | post-extraction-review | `9a8efa1de04d`, `628b6d3eccd4`, `831e5af61c03`, `45a60cd7fcfc`, `4ccdba121f6d`, `a1069e5b2eb2`, `ec66a51376d7` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | final class TermiteCoreSurface: NSView, TerminalSurface, TerminalSession { |
| 169-174 | post-extraction-review | `ec66a51376d7`, `dad2afb5333e` | `App/TermiteCoreSurface.swift` | private enum PrimaryMouseGesture: Equatable { |
| 175-184 | post-extraction-review | `dad2afb5333e`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | private struct PendingReportedMouseDown { |
| 185-196 | post-extraction-review | `7f3c77b3c7b8`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | private struct LinkHit: Equatable { |
| 197-216 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d`, `9c53c58fe8eb` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | override init(frame: CGRect) { |
| 217-218 | post-extraction-review | `fdf76bd72f51` | `Sources/term64/TerminalWindowController.swift` | required init?(coder: NSCoder) { fatalError("not supported") } |
| 219-224 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | deinit { |
| 225-228 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func computeFontDimensions() -> CGSize { |
| 229 | vendor-era-uncertain | `4c6c1ab7f663` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift` | private func computeFontDimensions() -> CGSize { |
| 230-237 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func computeFontDimensions() -> CGSize { |
| 238-239 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift` | private func computeFontDimensions() -> CGSize { |
| 240-242 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func computeFontDimensions() -> CGSize { |
| 243-258 | post-extraction-review | `a1069e5b2eb2`, `ee852af0c8f4` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | private func fontsChanged() { |
| 259-264 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func effectiveWidth(_ size: CGSize) -> CGFloat { |
| 265-269 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | override func setFrameSize(_ newSize: NSSize) { |
| 270-307 | post-extraction-review | `a1069e5b2eb2`, `0b69b59f4061`, `d695fb70583a`, `7f3c77b3c7b8`, `4ccdba121f6d` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | override func viewDidMoveToWindow() { |
| 308-311 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func relayout() { |
| 312 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift` | private func relayout() { |
| 313-336 | post-extraction-review | `4ccdba121f6d`, `9c53c58fe8eb`, `a1069e5b2eb2`, `fbe7a56c73ac` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | private func relayout() { |
| 337-347 | post-extraction-review | `a1069e5b2eb2`, `ac5d35a007e4` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | func queueDisplay() { |
| 348-361 | post-extraction-review | `a1069e5b2eb2`, `d695fb70583a` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | func forceRedraw() { |
| 362-365 | post-extraction-review | `a1069e5b2eb2`, `e352bd923356` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | func send(txt: String) { |
| 366-372 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d`, `e352bd923356` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | private func sendBytes(_ bytes: [UInt8]) { |
| 373-380 | post-extraction-review | `e352bd923356` | `App/TermiteCoreSurface.swift` | private func sendUserInput(_ bytes: [UInt8]) { |
| 381-385 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func feed(text: String) { |
| 386-394 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func installColors(_ colors: [TermColor]) { |
| 395-397 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func setUseMetal(_ on: Bool) throws { |
| 398-400 | confirmed-derived | `512b85926866` | `Vendor/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift` | func setUseMetal(_ on: Bool) throws { |
| 401-438 | post-extraction-review | `a1069e5b2eb2`, `9c53c58fe8eb`, `3ba83c216876`, `9a8efa1de04d`, `628b6d3eccd4`, `831e5af61c03`, `4ccdba121f6d`, `c8c69fbf2014` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | func setUseMetal(_ on: Bool) throws { |
| 439 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func setUserShader(_ source: String?) -> String? { |
| 440-442 | vendor-era-uncertain | `c03c5a8b5d84` | `Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift` | func setUserShader(_ source: String?) -> String? { |
| 443-448 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func setUserShader(_ source: String?) -> String? { |
| 449-454 | post-extraction-review | `45a60cd7fcfc`, `9c53c58fe8eb` | `App/TermiteCoreSurface.swift` | private func applyViewportUpdate(_ update: TerminalViewportUpdate) { |
| 455-461 | post-extraction-review | `a1069e5b2eb2`, `eeafffb2c0f9`, `45a60cd7fcfc`, `d4b03be30e75` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | func scrollTo(row: Int) { |
| 462-471 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d`, `45a60cd7fcfc`, `d4b03be30e75` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | func scrollUp(lines: Int) { |
| 472-492 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d`, `45a60cd7fcfc`, `d4b03be30e75` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | func scrollDown(lines: Int) { |
| 493-501 | post-extraction-review | `4616a520f010`, `a1069e5b2eb2` | `Sources/term64/SwiftTermAdapter.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func findNext(_ term: String, options: TermSearchOptions) -> Bool { |
| 502-509 | post-extraction-review | `4616a520f010`, `a1069e5b2eb2` | `Sources/term64/SwiftTermAdapter.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func findPrevious(_ term: String, options: TermSearchOptions) -> Bool { |
| 510-514 | post-extraction-review | `4616a520f010`, `a1069e5b2eb2` | `Sources/term64/SwiftTermAdapter.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func searchStatus(_ term: String, options: TermSearchOptions) -> (index: Int, total: Int) { |
| 515-524 | post-extraction-review | `a1069e5b2eb2`, `2f48808df28a` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | func clearSearch() { |
| 525-531 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | private func refreshSearch(_ term: String, options: TermSearchOptions) { |
| 532-545 | post-extraction-review | `a1069e5b2eb2`, `eeafffb2c0f9`, `45a60cd7fcfc`, `2f48808df28a` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | private func revealHit(_ hit: TerminalSearchHit) { |
| 546-551 | post-extraction-review | `4616a520f010`, `4ccdba121f6d`, `a1069e5b2eb2` | `Sources/term64/SwiftTermAdapter.swift`<br>`App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func startProcess(executable: String, args: [String], environment: [String]?, |
| 552-560 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d`, `a652a3c0afe1` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | func terminate() { |
| 561-575 | post-extraction-review | `a652a3c0afe1`, `a1069e5b2eb2`, `4ccdba121f6d`, `c03c5a8b5d84`, `ec66a51376d7` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift`<br>`Sources/term64/InlinePanel.swift` | private func tearDownRenderer() { |
| 576-581 | post-extraction-review | `a1069e5b2eb2`, `e352bd923356` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | override func keyDown(with event: NSEvent) { |
| 582-660 | post-extraction-review | `a1069e5b2eb2`, `dad2afb5333e`, `d029cee0e521` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | private func encodeKey(_ event: NSEvent) -> [UInt8]? { |
| 661-679 | post-extraction-review | `dad2afb5333e` | `App/TermiteCoreSurface.swift` | static func returnKeyBytes( |
| 680-687 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func modifierParam(_ flags: NSEvent.ModifierFlags) -> Int { |
| 688-698 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func arrowKey(_ letter: String, _ flags: NSEvent.ModifierFlags) -> [UInt8] { |
| 699-703 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func csiTilde(_ code: Int, _ flags: NSEvent.ModifierFlags) -> [UInt8] { |
| 704-739 | post-extraction-review | `a1069e5b2eb2`, `71d92ffdda9e`, `e2c1f7f7b729`, `628b6d3eccd4` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift`<br>`Sources/term64/TerminalWindowController.swift` | private func fKey(_ n: Int, _ flags: NSEvent.ModifierFlags) -> [UInt8] { |
| 740-747 | post-extraction-review | `7f3c77b3c7b8`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | private func gridPosition(at p: NSPoint) -> (col: Int, row: Int) { |
| 748-751 | post-extraction-review | `a1069e5b2eb2`, `7f3c77b3c7b8` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | private func gridPosition(of event: NSEvent) -> (col: Int, row: Int) { |
| 752-759 | post-extraction-review | `7f3c77b3c7b8`, `ec66a51376d7` | `App/TermiteCoreSurface.swift` | private func isInsideGrid(_ p: NSPoint) -> Bool { |
| 760-763 | post-extraction-review | `ec66a51376d7`, `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | private func isInsideGrid(_ event: NSEvent) -> Bool { |
| 764-818 | post-extraction-review | `a1069e5b2eb2`, `ec66a51376d7`, `dad2afb5333e`, `7e9bb7480fcc`, `7f3c77b3c7b8` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | override func mouseDown(with event: NSEvent) { |
| 819-834 | post-extraction-review | `a1069e5b2eb2`, `dad2afb5333e`, `ec66a51376d7` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | override func mouseDragged(with event: NSEvent) { |
| 835-856 | post-extraction-review | `a1069e5b2eb2`, `2f48808df28a`, `dad2afb5333e` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | override func mouseUp(with event: NSEvent) { |
| 857-875 | post-extraction-review | `a1069e5b2eb2`, `eeafffb2c0f9`, `4ccdba121f6d` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | private func mouseModifiers(_ event: NSEvent) -> TermiteTerminal.MouseModifiers { |
| 876-928 | post-extraction-review | `a1069e5b2eb2`, `eeafffb2c0f9`, `866735a54b8c`, `4ccdba121f6d`, `45a60cd7fcfc`, `d4b03be30e75`, `8c0987b11ed9` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | override func scrollWheel(with event: NSEvent) { |
| 929-959 | post-extraction-review | `b06b8d4e8995`, `eeafffb2c0f9`, `4ccdba121f6d`, `a652a3c0afe1`, `8c0987b11ed9`, `45a60cd7fcfc`, `d4b03be30e75` | `App/TermiteCoreSurface.swift` | private func nativeScroll(deltaY: CGFloat) { |
| 960-964 | post-extraction-review | `eeafffb2c0f9`, `4ccdba121f6d` | `App/TermiteCoreSurface.swift` | func resetScrollOffset() { |
| 965-975 | post-extraction-review | `4ccdba121f6d`, `eeafffb2c0f9`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | private func cancelScrollMotion() { |
| 976-981 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func normalizedSelection() -> ((row: Int, col: Int), (row: Int, col: Int))? { |
| 982-985 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func selectedColumnsForShaping(row: Int) -> ClosedRange<Int>? { |
| 986-993 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func selectedColumns(inAbsoluteRow row: Int) -> ClosedRange<Int>? { |
| 994-1010 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func selectedText() -> String { |
| 1011-1019 | post-extraction-review | `628b6d3eccd4`, `2f48808df28a` | `App/TermiteCoreSurface.swift` | func selectAllContent() { |
| 1020-1046 | post-extraction-review | `628b6d3eccd4`, `2f48808df28a`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func adjustSelection(_ adjustment: TerminalSelectionAdjustment) -> Bool { |
| 1047-1052 | post-extraction-review | `628b6d3eccd4` | `App/TermiteCoreSurface.swift` | func scrollSelectionIntoView() -> Bool { |
| 1053-1061 | post-extraction-review | `628b6d3eccd4`, `4ccdba121f6d` | `App/TermiteCoreSurface.swift` | private func revealSelectionEndpoint(_ endpoint: (row: Int, col: Int)) { |
| 1062-1063 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private func selectWord(row: Int, col: Int) { |
| 1064-1076 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func isWordChar(_ cell: Cell) -> Bool { |
| 1077-1087 | post-extraction-review | `b9576b46a76b`, `7f3c77b3c7b8` | `App/TerminalPane.swift`<br>`App/TermiteCoreSurface.swift` | override func updateTrackingAreas() { |
| 1088-1094 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | override func mouseMoved(with event: NSEvent) { |
| 1095-1099 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | override func mouseExited(with event: NSEvent) { |
| 1100-1108 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | override func flagsChanged(with event: NSEvent) { |
| 1109-1117 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | private func refreshLinkHover(at point: NSPoint, |
| 1118-1130 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | private func setHoveredLink(_ hit: LinkHit?, commandArmed: Bool, |
| 1131-1148 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | private func linkHit(at point: NSPoint) -> LinkHit? { |
| 1149-1159 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | func isTokenCell(_ candidate: Cell) -> Bool { |
| 1160-1175 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | func isIn(_ candidate: Cell, _ set: CharacterSet) -> Bool { |
| 1176-1189 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | private static func normalizedLink(_ raw: String) -> URL? { |
| 1190-1193 | post-extraction-review | `7f3c77b3c7b8` | `App/TermiteCoreSurface.swift` | func linkURL(at point: NSPoint) -> URL? { |
| 1194-1217 | post-extraction-review | `a1069e5b2eb2`, `e6d3c8898a16`, `7f3c77b3c7b8` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | override func resetCursorRects() { |
| 1218-1221 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func paletteColor(_ index: Int) -> NSColor { |
| 1222-1232 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | func fontVariant(bold: Bool, italic: Bool) -> NSFont { |
| 1233-1262 | post-extraction-review | `a1069e5b2eb2`, `4ccdba121f6d` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | static func defaultPalette() -> [NSColor] { |
| 1263 | post-extraction-review | `4ccdba121f6d` | `App/TermiteCoreSurface.swift` | extension TermiteCoreSurface: TerminalModelObserver { |
| 1264-1279 | post-extraction-review | `4ccdba121f6d`, `45a60cd7fcfc`, `9c53c58fe8eb`, `d695fb70583a` | `App/TermiteCoreSurface.swift` | func terminalModel(_ model: TerminalModel, didPublish snapshot: CoreTerminalSnapshot) { |
| 1280-1290 | post-extraction-review | `9c53c58fe8eb`, `4ccdba121f6d`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | private func acceptRenderSnapshot(_ snapshot: CoreTerminalSnapshot) { |
| 1291-1294 | post-extraction-review | `4ccdba121f6d`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func terminalModel(_ model: TerminalModel, didSetTitle title: String) { |
| 1295-1298 | post-extraction-review | `4ccdba121f6d`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func terminalModel(_ model: TerminalModel, didSetCurrentDirectory directory: String?) { |
| 1299-1303 | post-extraction-review | `4ccdba121f6d`, `a1069e5b2eb2`, `c986dbeaca81` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func terminalModelDidBell(_ model: TerminalModel) { |
| 1304-1308 | post-extraction-review | `4ccdba121f6d`, `c986dbeaca81`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func terminalModel(_ model: TerminalModel, |
| 1309-1315 | post-extraction-review | `4ccdba121f6d`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func terminalModel(_ model: TerminalModel, didRequestClipboardCopy content: Data) { |
| 1316-1319 | post-extraction-review | `4ccdba121f6d`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func terminalModel(_ model: TerminalModel, didSend data: [UInt8]) { |
| 1320-1323 | post-extraction-review | `4ccdba121f6d`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func terminalModel(_ model: TerminalModel, processTerminated exitCode: Int32?) { |
| 1324-1332 | post-extraction-review | `4ccdba121f6d`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | func consumePublishedDirtyRows() -> ClosedRange<Int>? { |
| 1333 | post-extraction-review | `a1069e5b2eb2` | `Sources/term64/TermiteCoreSurface.swift` | private final class PassthroughMTKView: MTKView { |
| 1334-1336 | post-extraction-review | `a1069e5b2eb2`, `b64a219836ef` | `Sources/term64/TermiteCoreSurface.swift`<br>`App/TermiteCoreSurface.swift` | override func hitTest(_ point: NSPoint) -> NSView? { nil } |
| 1337-1341 | post-extraction-review | `b64a219836ef`, `a1069e5b2eb2` | `App/TermiteCoreSurface.swift`<br>`Sources/term64/TermiteCoreSurface.swift` | override func viewDidEndLiveResize() { |
