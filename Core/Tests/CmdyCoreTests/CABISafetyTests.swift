import XCTest
import CmdyC

final class CABISafetyTests: XCTestCase {
    func testInvalidDimensionsReturnNull() {
        XCTAssertNil(cmdy_create(0, 24))
        XCTAssertNil(cmdy_create(80, -1))
        XCTAssertNil(cmdy_create(4_097, 24))
        XCTAssertNil(cmdy_create(4_096, 4_096))
    }

    func testNullHandlesAndPointersAreRejected() {
        XCTAssertEqual(cmdy_cols(nil), -1)
        XCTAssertEqual(cmdy_rows(nil), -1)
        XCTAssertEqual(cmdy_block_count(nil), -1)
        XCTAssertEqual(cmdy_line_text(nil, 0, nil, 0), -1)
        XCTAssertEqual(
            cmdy_cell(nil, 0, 0, nil, nil, nil, nil, nil),
            -1)
        cmdy_free(nil)
        cmdy_feed(nil, nil, 0)
        cmdy_resize(nil, 80, 24)
    }

    func testValidHandleStillFeedsAndReads() {
        guard let handle = cmdy_create(8, 3) else {
            return XCTFail("expected a valid terminal")
        }
        defer { cmdy_free(handle) }
        let bytes = Array("hello".utf8)
        bytes.withUnsafeBufferPointer {
            cmdy_feed(handle, $0.baseAddress, $0.count)
        }
        var output = [CChar](repeating: 0, count: 16)
        let count = output.withUnsafeMutableBufferPointer {
            cmdy_line_text(handle, 0, $0.baseAddress, $0.count)
        }

        XCTAssertEqual(count, 5)
        XCTAssertEqual(String(cString: output), "hello")
    }
}
