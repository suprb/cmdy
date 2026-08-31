import XCTest
@testable import CmdyCore

final class ReplaySafetyTests: XCTestCase {
    func testReplayRejectsInvalidTerminalDimensions() {
        let negative = Data(
            "CMDY-REPLAY 1\ncols=-1 rows=24\n----\n".utf8)
        let oversized = Data(
            "CMDY-REPLAY 1\ncols=4096 rows=4096\n----\n".utf8)

        XCTAssertThrowsError(try SessionReplay.load(negative)) {
            guard case SessionReplay.ReplayError.invalidDimensions = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertThrowsError(try SessionReplay.load(oversized)) {
            guard case SessionReplay.ReplayError.invalidDimensions = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testReplayRejectsAbsurdChunkBeforeAllocatingIt() {
        var data = Data("CMDY-REPLAY 1\ncols=80 rows=24\n----\n".utf8)
        var length = UInt32(64 * 1024 * 1024 + 1).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }

        XCTAssertThrowsError(try SessionReplay.load(data)) {
            guard case SessionReplay.ReplayError.tooLarge = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }
}
