import Foundation
import XCTest
@testable import CmdyCore

/// Opt-in release microbenchmarks for the CPU side of the terminal pipeline.
///
///     CMDY_CORE_BENCHMARK=1 swift test -c release --filter CorePerformanceTests
final class CorePerformanceTests: XCTestCase {
    func testASCIIAndReflowBenchmarks() {
        guard ProcessInfo.processInfo.environment["CMDY_CORE_BENCHMARK"] == "1" else { return }

        let targetBytes = 3_000_000
        let pattern = [UInt8](repeating: UInt8(ascii: "A"), count: 76) + [0x0D, 0x0A]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(targetBytes)
        while bytes.count < targetBytes { bytes.append(contentsOf: pattern) }
        bytes.removeLast(bytes.count - targetBytes)

        func parse(_ payload: [UInt8], coalesced: Bool) -> (milliseconds: Double, signature: String) {
            let terminal = CmdyTerminal(cols: 212, rows: 62, scrollback: 10_000)
            terminal.parser.coalescesPrintableASCII = coalesced
            let start = DispatchTime.now().uptimeNanoseconds
            terminal.feed(payload)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let tail = (max(0, terminal.bufferLineCount - 4)..<terminal.bufferLineCount)
                .map { terminal.scrollbackLineText(row: $0) ?? "" }
                .joined(separator: "|")
            return (elapsed, "\(terminal.cursorColumn),\(terminal.scrollInvariantCursorRow):\(tail)")
        }

        let scalar = parse(bytes, coalesced: false)
        let coalesced = parse(bytes, coalesced: true)
        XCTAssertEqual(coalesced.signature, scalar.signature)
        XCTAssertLessThan(coalesced.milliseconds, scalar.milliseconds)

        let reflowTerminal = CmdyTerminal(cols: 80, rows: 60, scrollback: 10_000)
        reflowTerminal.feed([UInt8](repeating: UInt8(ascii: "a"), count: 80 * 10_000))
        let reflowStart = DispatchTime.now().uptimeNanoseconds
        reflowTerminal.resize(cols: 79, rows: 60)
        let reflowMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - reflowStart) / 1_000_000

        let scalarMBps = Double(bytes.count) / scalar.milliseconds / 1_000
        let coalescedMBps = Double(bytes.count) / coalesced.milliseconds / 1_000
        let continuousBytes = [UInt8](repeating: UInt8(ascii: "A"), count: targetBytes)
        let continuous = parse(continuousBytes, coalesced: true)
        let continuousMBps = Double(continuousBytes.count) / continuous.milliseconds / 1_000
        print(String(format:
            "CMDY_CORE_BENCH ascii_bytes=%d scalar_ms=%.2f scalar_MBps=%.2f coalesced_ms=%.2f coalesced_MBps=%.2f continuous_ms=%.2f continuous_MBps=%.2f reflow_10k_ms=%.2f",
            bytes.count, scalar.milliseconds, scalarMBps,
            coalesced.milliseconds, coalescedMBps,
            continuous.milliseconds, continuousMBps, reflowMilliseconds))

        // Keep the optimized path alive long enough for `sample`/Instruments
        // when explicitly requested; ordinary benchmark and test runs stay at
        // one iteration.
        let repetitions = Int(ProcessInfo.processInfo.environment[
            "CMDY_CORE_BENCHMARK_REPETITIONS"] ?? "1") ?? 1
        if repetitions > 1 {
            for _ in 1..<repetitions { _ = parse(bytes, coalesced: true) }
        }
    }
}
