import XCTest
@testable import CmdyKit

final class BoundedFileReaderTests: XCTestCase {
    func testRejectsAFileThatExceedsTheLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-bounded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x61, count: 1_025).write(to: url)

        XCTAssertThrowsError(try BoundedFileReader.data(at: url, maxBytes: 1_024))
        XCTAssertEqual(
            try BoundedFileReader.data(at: url, maxBytes: 1_025).count,
            1_025)
    }

    func testUTF8ReaderRejectsInvalidText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-utf8-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xFF]).write(to: url)

        XCTAssertThrowsError(
            try BoundedFileReader.utf8String(at: url, maxBytes: 16))
    }
}
