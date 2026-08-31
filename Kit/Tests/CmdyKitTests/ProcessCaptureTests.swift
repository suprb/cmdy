import XCTest
@testable import CmdyKit

final class ProcessCaptureTests: XCTestCase {
    func testVerboseChildIsDrainedWithoutUnboundedCapture() throws {
        let result = try ProcessCapture.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 200000"],
            timeout: 5,
            outputLimit: 4_096)

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.outputWasTruncated)
        XCTAssertTrue(result.output.hasSuffix("… output truncated …"))
        XCTAssertLessThan(result.output.utf8.count, 4_200)
    }

    func testNonzeroExitStillReturnsDiagnosticOutput() throws {
        let result = try ProcessCapture.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo failure >&2; exit 7"],
            timeout: 5)

        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "failure")
    }

    func testBackgroundDescendantCannotKeepCaptureOpenForever() throws {
        let started = Date()
        let result = try ProcessCapture.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 10 & echo parent-finished"],
            timeout: 5)

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.output.contains("parent-finished"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
