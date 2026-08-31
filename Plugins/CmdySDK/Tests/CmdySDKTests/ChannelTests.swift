import XCTest
@testable import CmdySDK

final class ChannelTests: XCTestCase {
    func testDecodesOnlyPrivateChannelReplyEvents() throws {
        let payload: [String: Any] = [
            "kind": "channel-reply",
            "id": "reply-one",
            "channel": "com.example.slack.team",
            "workItem": "message-one",
            "conversationID": "thread-one",
            "replyToID": "message-one",
            "replyKind": "result",
            "body": "Done",
            "createdAt": "2026-07-17T10:00:00Z",
            "state": "queued",
        ]

        let reply = try XCTUnwrap(Cmdy.channelReply(from: payload))
        XCTAssertEqual(reply.id, "reply-one")
        XCTAssertEqual(reply.channelID, "com.example.slack.team")
        XCTAssertEqual(reply.conversationID, "thread-one")
        XCTAssertEqual(reply.replyToID, "message-one")
        XCTAssertEqual(reply.state, .queued)
    }

    func testRejectsUnrelatedEvents() {
        XCTAssertNil(Cmdy.channelReply(from: ["kind": "command-finished"]))
    }

    func testIncomingWorkItemUsesProviderDeliveryIdentity() throws {
        let item = CmdyIncomingWorkItem(
            id: "message-one", deliveryID: "event-42",
            conversationID: "thread-9", senderName: "Ada",
            title: "Fix CI", body: "Please investigate")
        let data = try JSONEncoder().encode(item)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["deliveryID"] as? String, "event-42")
        XCTAssertEqual(payload["conversationID"] as? String, "thread-9")
        XCTAssertEqual(CmdyWorkItemStatus.needsInput.rawValue, "needs-input")
    }

    func testDeliverySafetyAndHealthWireValuesStayStable() throws {
        XCTAssertEqual(CmdyChannelReplyState.delivering.rawValue, "delivering")
        XCTAssertEqual(
            CmdyChannelReplyState.verificationNeeded.rawValue,
            "verification-needed")

        let health = CmdyChannelHealth(
            status: .retrying,
            lastSuccessAt: "2026-07-18T10:00:00Z",
            lastErrorAt: "2026-07-18T10:01:00Z",
            error: "rate limited",
            nextRetryAt: "2026-07-18T10:02:00Z",
            detail: "provider retry scheduled")
        let data = try JSONEncoder().encode(health)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["status"] as? String, "retrying")
        XCTAssertEqual(payload["error"] as? String, "rate limited")
        XCTAssertEqual(payload["nextRetryAt"] as? String, "2026-07-18T10:02:00Z")
    }
}
