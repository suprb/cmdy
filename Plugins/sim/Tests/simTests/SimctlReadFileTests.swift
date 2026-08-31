import Foundation
import XCTest
@testable import sim

final class SimctlReadFileTests: XCTestCase {
    func testReadFileTreatsNilAtEOFAsACompleteRead() throws {
        let fixture = try makeFixture(Data("browser-api".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            Simctl.readFile(fixture.file.path, maxBytes: 64 * 1024),
            Data("browser-api".utf8))
    }

    func testReadFileAcceptsTheExactLimit() throws {
        let bytes = Data([0, 1, 2, 3])
        let fixture = try makeFixture(bytes)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(Simctl.readFile(fixture.file.path, maxBytes: 4), bytes)
    }

    func testReadFileRejectsContentPastTheLimit() throws {
        let fixture = try makeFixture(Data([0, 1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertNil(Simctl.readFile(fixture.file.path, maxBytes: 3))
    }

    private func makeFixture(_ bytes: Data) throws -> (
        directory: URL,
        file: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("fixture.bin")
        try bytes.write(to: file)
        return (directory, file)
    }
}
