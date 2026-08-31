import XCTest
@testable import CmdySDK

final class FeedbackTests: XCTestCase {
    func testStoreAddsFiltersAndResolvesRecords() {
        let store = CmdyFeedbackStore()
        let first = store.add(["source": "browser", "comment": "Move this"])
        _ = store.add(["source": "sim", "comment": "Wrong color"])

        XCTAssertEqual(store.list(status: "open").count, 2)
        let id = try! XCTUnwrap(first["id"] as? String)
        XCTAssertEqual(store.resolve(id: id, resolution: "Adjusted spacing")?["status"] as? String,
                       "resolved")
        XCTAssertEqual(store.list(status: "open").count, 1)
        XCTAssertEqual(store.list(status: "resolved").count, 1)
        XCTAssertEqual(store.clear(resolvedOnly: true), 1)
        XCTAssertEqual(store.list().count, 1)
    }

    func testStoreKeepsCallerIdentityAndCapsHistory() {
        let store = CmdyFeedbackStore()
        let record = store.add(["id": "chosen", "timestamp": "now", "status": "open"])
        XCTAssertEqual(record["id"] as? String, "chosen")
        XCTAssertEqual(record["timestamp"] as? String, "now")
        for i in 0..<510 { _ = store.add(["comment": "\(i)"]) }
        XCTAssertEqual(store.list().count, 500)
    }
}
