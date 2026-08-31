import XCTest
@testable import CmdyKit

final class CmdyChannelsTests: XCTestCase {
    private func channel(id: String = "com.example.mail.inbox") -> CmdyChannel {
        CmdyChannel(
            id: id, name: "Inbox", service: "Mail", account: "team@example.com",
            replyCapabilities: [.reply])
    }

    private func item(id: String = "message-one",
                      deliveryID: String = "delivery-one") -> CmdyWorkItem {
        CmdyWorkItem(
            id: id, channelID: "com.example.mail.inbox",
            deliveryID: deliveryID, conversationID: "thread-one",
            senderName: "Ada", title: "Review this", body: "Please take a look",
            createdAt: "2026-07-17T10:00:00Z",
            receivedAt: "2026-07-17T10:00:01Z")
    }

    func testStableExtensionOwnsChannelAndOnlyOneLaunchCanConnect() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch-one")

        XCTAssertThrowsError(try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch-two"))
        XCTAssertThrowsError(try registry.register(
            channel(), extensionID: "com.attacker", owner: "attacker"))

        registry.disconnect(owner: "launch-one")
        let reconnected = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch-two")
        XCTAssertTrue(reconnected.connected)
    }

    func testGlobalChannelRegistryIsBounded() throws {
        let registry = CmdyChannelRegistry()
        for index in 0..<256 {
            let id = "com.example.channel\(index)"
            _ = try registry.register(
                CmdyChannel(id: id, name: "Channel \(index)", service: "Test"),
                extensionID: id, owner: "launch-\(index)")
        }
        XCTAssertThrowsError(try registry.register(
            CmdyChannel(
                id: "com.example.overflow", name: "Overflow", service: "Test"),
            extensionID: "com.example.overflow", owner: "launch-overflow"))
    }

    func testIngestionDeduplicatesProviderRetriesAndRejectsIDCollision() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")

        let first = try registry.ingest(
            item(), owner: "launch", extensionID: "com.example.mail")
        let retry = try registry.ingest(
            item(id: "different-local-id"), owner: "launch",
            extensionID: "com.example.mail")
        XCTAssertFalse(first.deduplicated)
        XCTAssertTrue(retry.deduplicated)
        XCTAssertEqual(retry.item.id, "message-one")

        XCTAssertThrowsError(try registry.ingest(
            item(deliveryID: "different-delivery"), owner: "launch",
            extensionID: "com.example.mail"))
    }

    func testReplyMustBeQueuedAndAcknowledgedByOwningConnector() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        _ = try registry.ingest(
            item(), owner: "launch", extensionID: "com.example.mail")

        let draft = try registry.createDraft(
            channelID: channel().id, workItemID: "message-one",
            kind: .result, body: "Finished")
        XCTAssertEqual(draft.state, .draft)
        XCTAssertTrue(registry.visibleReplies(owner: "launch", states: [.queued]).isEmpty)

        let queued = try registry.queueReply(id: draft.id)
        XCTAssertEqual(queued.reply.state, .queued)
        XCTAssertEqual(queued.owner, "launch")
        let payload = registry.payload(for: queued.reply)
        XCTAssertEqual(payload["conversationID"] as? String, "thread-one")
        XCTAssertThrowsError(try registry.discardReply(id: draft.id))
        XCTAssertThrowsError(try registry.acknowledgeReply(
            id: draft.id, owner: "someone-else", delivered: true))
        let sent = try registry.acknowledgeReply(
            id: draft.id, owner: "launch", delivered: true)
        XCTAssertEqual(sent.state, .sent)
        try registry.discardReply(id: draft.id)
        XCTAssertNil(registry.reply(id: draft.id))
    }

    func testAmbiguousProviderAcceptanceNeedsVerificationBeforeRetry() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        _ = try registry.ingest(
            item(), owner: "launch", extensionID: "com.example.mail")
        let draft = try registry.createDraft(
            channelID: channel().id, workItemID: "message-one",
            kind: .result, body: "Finished")
        _ = try registry.queueReply(id: draft.id)
        XCTAssertThrowsError(try registry.beginReplyDelivery(
            id: draft.id, owner: "attacker"))
        let delivering = try registry.beginReplyDelivery(
            id: draft.id, owner: "launch")
        XCTAssertEqual(delivering.state, .delivering)
        XCTAssertTrue(registry.visibleReplies(
            owner: "launch", states: [.queued]).isEmpty)
        XCTAssertThrowsError(try registry.discardReply(id: draft.id))

        let ambiguous = try registry.markReplyVerificationNeeded(
            id: draft.id, owner: "launch",
            detail: "provider accepted the socket, response was lost")
        XCTAssertEqual(ambiguous.state, .verificationNeeded)
        XCTAssertTrue(registry.visibleReplies(
            owner: "launch", states: [.queued]).isEmpty)
        let payload = registry.payload(for: ambiguous)
        XCTAssertEqual(payload["state"] as? String, "verification-needed")
        XCTAssertEqual(payload["retryRequiresConfirmation"] as? Bool, true)
        XCTAssertThrowsError(try registry.queueReply(id: draft.id))

        let retried = try registry.queueReply(
            id: draft.id, confirmVerificationNeeded: true)
        XCTAssertEqual(retried.reply.state, .queued)
        _ = try registry.beginReplyDelivery(id: draft.id, owner: "launch")
        _ = try registry.markReplyVerificationNeeded(
            id: draft.id, owner: "launch")
        try registry.discardReply(id: draft.id)
        XCTAssertNil(registry.reply(id: draft.id))
    }

    func testVerificationNeededReplyPersistsAndDoesNotRecoverAsQueued() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-channels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")
        var replyID = ""
        do {
            let registry = CmdyChannelRegistry(storageURL: stateURL)
            _ = try registry.register(
                channel(), extensionID: "com.example.mail", owner: "launch")
            _ = try registry.ingest(
                item(), owner: "launch", extensionID: "com.example.mail")
            let draft = try registry.createDraft(
                channelID: channel().id, workItemID: "message-one",
                kind: .result, body: "Finished")
            replyID = draft.id
            _ = try registry.queueReply(id: draft.id)
            let delivering = try registry.beginReplyDelivery(
                id: draft.id, owner: "launch")
            XCTAssertEqual(delivering.state, .delivering)
        }

        let restored = CmdyChannelRegistry(storageURL: stateURL)
        XCTAssertEqual(restored.reply(id: replyID)?.state, .verificationNeeded)
        XCTAssertTrue(restored.reply(id: replyID)?.deliveryError?.contains(
            "Host restarted") == true)
        XCTAssertTrue(restored.visibleReplies(states: [.queued]).isEmpty)
    }

    func testMarkedDeliveryAttemptAcknowledgesNormally() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        _ = try registry.ingest(
            item(), owner: "launch", extensionID: "com.example.mail")
        let draft = try registry.createDraft(
            channelID: channel().id, workItemID: "message-one",
            kind: .result, body: "Finished")
        _ = try registry.queueReply(id: draft.id)
        _ = try registry.beginReplyDelivery(id: draft.id, owner: "launch")
        let sent = try registry.acknowledgeReply(
            id: draft.id, owner: "launch", delivered: true)
        XCTAssertEqual(sent.state, .sent)
    }

    func testConnectorDisconnectTurnsInFlightAttemptIntoVerification() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        _ = try registry.ingest(
            item(), owner: "launch", extensionID: "com.example.mail")
        let draft = try registry.createDraft(
            channelID: channel().id, workItemID: "message-one",
            kind: .result, body: "Finished")
        _ = try registry.queueReply(id: draft.id)
        _ = try registry.beginReplyDelivery(id: draft.id, owner: "launch")

        registry.disconnect(owner: "launch")
        XCTAssertEqual(registry.reply(id: draft.id)?.state, .verificationNeeded)
        XCTAssertTrue(registry.visibleReplies(states: [.queued]).isEmpty)
    }

    func testConnectorHealthIsOwnedBoundedAndSeparateFromConnectivity() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        let health = CmdyChannelHealth(
            status: .retrying,
            lastSuccessAt: "2026-07-18T09:00:00Z",
            lastErrorAt: "2026-07-18T10:00:00Z",
            error: "HTTP 503", nextRetryAt: "2026-07-18T10:05:00Z",
            detail: "Provider maintenance")
        XCTAssertThrowsError(try registry.reportHealth(
            channelID: channel().id, owner: "attacker", health: health))
        let reported = try registry.reportHealth(
            channelID: channel().id, owner: "launch", health: health)
        XCTAssertEqual(reported, health)

        var runtime = try XCTUnwrap(registry.channelRuntime(id: channel().id))
        XCTAssertTrue(runtime.connected)
        XCTAssertEqual(runtime.health.status, .retrying)
        let payload = registry.payload(for: runtime)
        XCTAssertEqual(payload["connected"] as? Bool, true)
        XCTAssertEqual(
            (payload["health"] as? [String: Any])?["status"] as? String,
            "retrying")

        registry.disconnect(owner: "launch")
        runtime = try XCTUnwrap(registry.channelRuntime(id: channel().id))
        XCTAssertFalse(runtime.connected)
        XCTAssertEqual(runtime.health.status, .offline)
        XCTAssertEqual(runtime.health.lastSuccessAt, "2026-07-18T09:00:00Z")
    }

    func testHealthPayloadParserRejectsOversizedDiagnostics() throws {
        let health = try CmdyChannelRegistry.health(from: [
            "status": "degraded",
            "lastSuccessAt": "2026-07-18T09:00:00Z",
            "error": "temporary",
        ])
        XCTAssertEqual(health.status, .degraded)
        XCTAssertThrowsError(try CmdyChannelRegistry.health(from: [
            "status": "retrying",
            "detail": String(repeating: "x", count: 2_049),
        ]))
        XCTAssertThrowsError(try CmdyChannelRegistry.health(from: [
            "status": "healthy", "lastSuccessAt": 123,
        ]))
    }

    func testAcknowledgementPayloadKeepsBoolCompatibilityAndAddsAmbiguity() throws {
        XCTAssertEqual(
            try CmdyChannelRegistry.replyAcknowledgement(from: ["delivered": true]),
            .delivered)
        XCTAssertEqual(
            try CmdyChannelRegistry.replyAcknowledgement(from: [
                "delivered": false, "error": "HTTP 503",
            ]),
            .failed("HTTP 503"))
        XCTAssertEqual(
            try CmdyChannelRegistry.replyAcknowledgement(from: [
                "state": "verification-needed", "error": "response lost",
            ]),
            .verificationNeeded("response lost"))
        XCTAssertThrowsError(try CmdyChannelRegistry.replyAcknowledgement(from: [
            "delivered": true, "state": "verification-needed",
        ]))
        XCTAssertThrowsError(try CmdyChannelRegistry.replyAcknowledgement(from: [
            "state": "unknown",
        ]))
        XCTAssertThrowsError(try CmdyChannelRegistry.replyAcknowledgement(from: [
            "delivered": false, "error": 503,
        ]))
    }

    func testRemovingChannelRequiresOwnerAndDeletesHostState() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        _ = try registry.ingest(
            item(), owner: "launch", extensionID: "com.example.mail")
        _ = try registry.createDraft(
            channelID: channel().id, workItemID: "message-one",
            kind: .result, body: "Finished")

        XCTAssertThrowsError(try registry.removeChannel(
            id: channel().id, owner: "another-launch"))
        try registry.removeChannel(id: channel().id, owner: "launch")
        XCTAssertTrue(registry.channelRuntimes().isEmpty)
        XCTAssertTrue(registry.visibleWorkItems().isEmpty)
        XCTAssertTrue(registry.visibleReplies().isEmpty)
    }

    func testStatePersistsWithoutPersistingLaunchCredential() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-channels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")

        do {
            let registry = CmdyChannelRegistry(storageURL: stateURL)
            _ = try registry.register(
                channel(), extensionID: "com.example.mail", owner: "secret-token")
            _ = try registry.ingest(
                item(), owner: "secret-token", extensionID: "com.example.mail")
            try registry.setStatus(
                channelID: channel().id, workItemID: "message-one", status: .working)
        }

        let data = try Data(contentsOf: stateURL)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-token"))
        let restored = CmdyChannelRegistry(storageURL: stateURL)
        XCTAssertEqual(restored.channelRuntimes().first?.connected, false)
        XCTAssertEqual(restored.visibleWorkItems().map(\.id), ["message-one"])
        XCTAssertEqual(restored.visibleWorkItems().first?.status, .pending)
    }

    func testOldPersistedChannelWithoutHealthRestoresOffline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-channels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")
        do {
            let registry = CmdyChannelRegistry(storageURL: stateURL)
            _ = try registry.register(
                channel(), extensionID: "com.example.mail", owner: "launch")
        }
        let data = try Data(contentsOf: stateURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var channels = try XCTUnwrap(object["channels"] as? [[String: Any]])
        channels[0].removeValue(forKey: "health")
        object["channels"] = channels
        try JSONSerialization.data(withJSONObject: object).write(
            to: stateURL, options: .atomic)

        let restored = CmdyChannelRegistry(storageURL: stateURL)
        let runtime = try XCTUnwrap(restored.channelRuntime(id: channel().id))
        XCTAssertFalse(runtime.connected)
        XCTAssertEqual(runtime.health, .unreported)
    }

    func testHealthHistoryPersistsButCurrentStatusRestoresOffline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-channels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")
        do {
            let registry = CmdyChannelRegistry(storageURL: stateURL)
            _ = try registry.register(
                channel(), extensionID: "com.example.mail", owner: "launch")
            _ = try registry.reportHealth(
                channelID: channel().id, owner: "launch",
                health: CmdyChannelHealth(
                    status: .healthy,
                    lastSuccessAt: "2026-07-18T10:00:00Z",
                    detail: "poll completed"))
        }

        let restored = CmdyChannelRegistry(storageURL: stateURL)
        let health = try XCTUnwrap(
            restored.channelRuntime(id: channel().id)?.health)
        XCTAssertEqual(health.status, .offline)
        XCTAssertEqual(health.lastSuccessAt, "2026-07-18T10:00:00Z")
        XCTAssertEqual(health.detail, "poll completed")
    }

    func testDoctorSeparatesConnectorAndProviderAndListsAmbiguousReplies() {
        let lines = ChannelCLI.doctorLines(
            channels: [[
                "id": "com.example.mail.inbox", "name": "Inbox",
                "connected": true,
                "health": [
                    "status": "degraded", "lastErrorAt": "2026-07-18T10:00:00Z",
                    "error": "rate limited", "nextRetryAt": "2026-07-18T10:05:00Z",
                ],
            ]],
            replies: [[
                "id": "reply-risk", "channel": "com.example.mail.inbox",
                "state": "verification-needed",
            ]])
        XCTAssertTrue(lines.contains("  connector process: connected"))
        XCTAssertTrue(lines.contains("  provider health: degraded"))
        XCTAssertTrue(lines.contains("  replies needing verification: 1"))
        XCTAssertTrue(lines.contains("    reply-risk"))
    }

    func testOneShellCommandCreatesADraftResultAndCompletesWork() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        _ = try registry.ingest(
            item(), owner: "launch", extensionID: "com.example.mail")
        try registry.beginShellResult(
            channelID: channel().id, workItemID: "message-one", paneID: "pane-one")
        registry.commandStarted(paneID: "pane-one", blockID: "block-one")

        let reply = try XCTUnwrap(registry.commandFinished(
            paneID: "pane-one", blockID: "block-one", command: "swift test",
            exitCode: 0, output: "All tests passed"))
        XCTAssertEqual(reply.state, .draft)
        XCTAssertTrue(reply.body.contains("All tests passed"))
        XCTAssertEqual(
            registry.workItem(channelID: channel().id, id: "message-one")?.status,
            .completed)
    }

    func testClosingPaneCancelsStagedShellWork() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        _ = try registry.ingest(
            item(), owner: "launch", extensionID: "com.example.mail")
        try registry.beginShellResult(
            channelID: channel().id, workItemID: "message-one", paneID: "pane-one")

        XCTAssertTrue(registry.cancelShellResult(paneID: "pane-one"))
        XCTAssertEqual(
            registry.workItem(channelID: channel().id, id: "message-one")?.status,
            .pending)
        XCTAssertNil(registry.commandFinished(
            paneID: "pane-one", blockID: "block-one", command: "true",
            exitCode: 0, output: ""))

        try registry.beginShellResult(
            channelID: channel().id, workItemID: "message-one", paneID: "pane-two")
        registry.commandStarted(paneID: "pane-two", blockID: "block-two")
        XCTAssertTrue(registry.cancelShellResult(paneID: "pane-two"))
        XCTAssertEqual(
            registry.workItem(channelID: channel().id, id: "message-one")?.status,
            .failed)
    }

    func testOversizedWorkItemIsRejected() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        var oversized = item()
        oversized = CmdyWorkItem(
            id: oversized.id, channelID: oversized.channelID,
            deliveryID: oversized.deliveryID, conversationID: oversized.conversationID,
            senderName: oversized.senderName, title: oversized.title,
            body: String(repeating: "x", count: 65_537),
            createdAt: oversized.createdAt, receivedAt: oversized.receivedAt)

        XCTAssertThrowsError(try registry.ingest(
            oversized, owner: "launch", extensionID: "com.example.mail"))
    }

    func testAggregateInboxBodyBudgetIsBounded() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        let body = String(repeating: "x", count: 64 * 1024)
        for index in 0..<128 {
            let workItem = CmdyWorkItem(
                id: "message-\(index)", channelID: channel().id,
                deliveryID: "delivery-\(index)", conversationID: "thread",
                senderName: "Ada", title: "Task", body: body,
                createdAt: "2026-07-17T10:00:00Z",
                receivedAt: "2026-07-17T10:00:01Z")
            _ = try registry.ingest(
                workItem, owner: "launch", extensionID: "com.example.mail")
        }
        let extra = CmdyWorkItem(
            id: "message-extra", channelID: channel().id,
            deliveryID: "delivery-extra", conversationID: "thread",
            senderName: "Ada", title: "Task", body: "x",
            createdAt: "2026-07-17T10:00:00Z",
            receivedAt: "2026-07-17T10:00:01Z")

        XCTAssertThrowsError(try registry.ingest(
            extra, owner: "launch", extensionID: "com.example.mail"))
    }

    func testCompletedItemsMakeRoomWithinPerChannelLimit() throws {
        let registry = CmdyChannelRegistry()
        _ = try registry.register(
            channel(), extensionID: "com.example.mail", owner: "launch")
        for index in 0..<512 {
            let workItem = CmdyWorkItem(
                id: "message-\(index)", channelID: channel().id,
                deliveryID: "delivery-\(index)", conversationID: "thread",
                senderName: "Ada", title: "Task", body: "done",
                createdAt: "2026-07-17T10:00:00Z",
                receivedAt: String(format: "2026-07-17T10:%02d:%02dZ", index / 60, index % 60))
            _ = try registry.ingest(
                workItem, owner: "launch", extensionID: "com.example.mail")
            try registry.setStatus(
                channelID: channel().id, workItemID: workItem.id, status: .completed)
        }
        _ = try registry.ingest(
            item(id: "message-new", deliveryID: "delivery-new"),
            owner: "launch", extensionID: "com.example.mail")

        XCTAssertEqual(registry.visibleWorkItems().count, 512)
        XCTAssertNotNil(registry.workItem(channelID: channel().id, id: "message-new"))
    }
}
