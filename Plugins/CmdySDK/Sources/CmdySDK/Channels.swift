import Foundation

public enum CmdyChannelReplyCapability: String, Codable, CaseIterable, Sendable {
    case reply
    case update
    case upload
}

public struct CmdyChannel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let service: String
    public let account: String
    public let description: String
    public let replyCapabilities: [CmdyChannelReplyCapability]

    public init(id: String, name: String, service: String,
                account: String = "", description: String = "",
                replyCapabilities: [CmdyChannelReplyCapability] = []) {
        self.id = id
        self.name = name
        self.service = service
        self.account = account
        self.description = description
        self.replyCapabilities = replyCapabilities
    }
}

/// One externally delivered task/message before Cmdy adds host-owned state.
/// `deliveryID` is the connector's retry/deduplication key; use the provider's
/// immutable event id rather than generating a new value on every poll.
public struct CmdyIncomingWorkItem: Codable, Equatable, Sendable {
    public let id: String
    public let deliveryID: String
    public let conversationID: String
    public let replyToID: String?
    public let senderID: String?
    public let senderName: String
    public let title: String
    public let body: String
    public let createdAt: String?
    public let projectHint: String?

    public init(id: String, deliveryID: String, conversationID: String,
                replyToID: String? = nil, senderID: String? = nil,
                senderName: String, title: String, body: String,
                createdAt: String? = nil, projectHint: String? = nil) {
        self.id = id
        self.deliveryID = deliveryID
        self.conversationID = conversationID
        self.replyToID = replyToID
        self.senderID = senderID
        self.senderName = senderName
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.projectHint = projectHint
    }
}

public enum CmdyWorkItemStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case working
    case needsInput = "needs-input"
    case completed
    case failed
    case ignored
}

public enum CmdyChannelReplyKind: String, Codable, CaseIterable, Sendable {
    case acknowledgement
    case progress
    case question
    case result
}

public enum CmdyChannelReplyState: String, Codable, CaseIterable, Sendable {
    case draft
    case queued
    case delivering
    case sent
    case failed
    case verificationNeeded = "verification-needed"
}

public enum CmdyChannelHealthStatus: String, Codable, CaseIterable, Sendable {
    case healthy
    case degraded
    case retrying
    case offline
}

public struct CmdyChannelHealth: Codable, Equatable, Sendable {
    public let status: CmdyChannelHealthStatus
    public let lastSuccessAt: String?
    public let lastErrorAt: String?
    public let error: String?
    public let nextRetryAt: String?
    public let detail: String?

    public init(status: CmdyChannelHealthStatus,
                lastSuccessAt: String? = nil, lastErrorAt: String? = nil,
                error: String? = nil, nextRetryAt: String? = nil,
                detail: String? = nil) {
        self.status = status
        self.lastSuccessAt = lastSuccessAt
        self.lastErrorAt = lastErrorAt
        self.error = error
        self.nextRetryAt = nextRetryAt
        self.detail = detail
    }
}

/// A host-approved outbound message. Channel Extensions receive only queued
/// replies, never private drafts. A connector must acknowledge each attempt.
public struct CmdyChannelReply: Codable, Equatable, Sendable {
    public let id: String
    public let channelID: String
    public let workItemID: String
    /// Provider routing context copied from the durable Work Item so queued
    /// replies remain deliverable after the connector restarts.
    public let conversationID: String
    public let replyToID: String?
    public let kind: CmdyChannelReplyKind
    public let body: String
    public let createdAt: String
    public let state: CmdyChannelReplyState
    public let deliveryError: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel"
        case workItemID = "workItem"
        case conversationID, replyToID
        case kind, replyKind, body, createdAt, state
        case deliveryError = "error"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        channelID = try values.decode(String.self, forKey: .channelID)
        workItemID = try values.decode(String.self, forKey: .workItemID)
        conversationID = try values.decode(String.self, forKey: .conversationID)
        replyToID = try values.decodeIfPresent(String.self, forKey: .replyToID)
        kind = try values.decodeIfPresent(CmdyChannelReplyKind.self,
                                          forKey: .replyKind)
            ?? values.decode(CmdyChannelReplyKind.self, forKey: .kind)
        body = try values.decode(String.self, forKey: .body)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        state = try values.decode(CmdyChannelReplyState.self, forKey: .state)
        deliveryError = try values.decodeIfPresent(String.self, forKey: .deliveryError)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(channelID, forKey: .channelID)
        try values.encode(workItemID, forKey: .workItemID)
        try values.encode(conversationID, forKey: .conversationID)
        try values.encodeIfPresent(replyToID, forKey: .replyToID)
        try values.encode(kind, forKey: .kind)
        try values.encode(body, forKey: .body)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(deliveryError, forKey: .deliveryError)
    }
}

public struct CmdyChannelRegistration: Equatable, Sendable {
    public let channel: CmdyChannel
    public let pendingReplies: [CmdyChannelReply]

    public init(channel: CmdyChannel,
                pendingReplies: [CmdyChannelReply]) {
        self.channel = channel
        self.pendingReplies = pendingReplies
    }
}

public extension Cmdy {
    /// Register (or reconnect) a Channel owned by this Extension's stable id.
    /// Replies queued while the connector was offline are returned here.
    func registerChannel(
        _ channel: CmdyChannel,
        completion: ((CmdyChannelRegistration?) -> Void)? = nil
    ) {
        guard let body = Self.channelJSONObject(channel) else {
            completion?(nil)
            return
        }
        post("/v1/channels", body) { payload in
            guard let channelPayload = payload?["channel"],
                  let registered = Self.decodeChannelValue(
                    CmdyChannel.self, from: channelPayload) else {
                completion?(nil)
                return
            }
            let replies = (payload?["pendingReplies"] as? [Any] ?? []).compactMap {
                Self.decodeChannelValue(CmdyChannelReply.self, from: $0)
            }
            completion?(CmdyChannelRegistration(
                channel: registered, pendingReplies: replies))
        }
    }

    /// Ingest a provider event into Cmdy's durable Work Inbox. Reusing the
    /// same delivery id is safe: the host returns the existing Work Item.
    func ingestWorkItem(
        _ item: CmdyIncomingWorkItem,
        into channelID: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let body = Self.channelJSONObject(item) else {
            completion?(false)
            return
        }
        post("/v1/channels/\(channelID)/work-items", body) { payload in
            completion?(payload?["ok"] as? Bool == true)
        }
    }

    /// Update one owned Work Item after provider-side handling.
    func updateWorkItemStatus(
        channelID: String,
        workItemID: String,
        status: CmdyWorkItemStatus,
        completion: ((Bool) -> Void)? = nil
    ) {
        patch(
            "/v1/channel-work-items/\(channelID)/\(workItemID)",
            ["status": status.rawValue]
        ) { payload in
            completion?(payload?["ok"] as? Bool == true)
        }
    }

    /// Permanently unregister one owned Channel and delete its host-owned
    /// Work Items and replies. Stopping the connector alone retains them.
    func unregisterChannel(
        _ channelID: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        delete("/v1/channels/\(channelID)") { payload in
            completion?(payload?["ok"] as? Bool == true)
        }
    }

    /// Fetch queued replies for this connector. This is the recovery path if
    /// an SSE event was missed during a restart or network/provider outage.
    func pendingChannelReplies(
        completion: @escaping ([CmdyChannelReply]) -> Void
    ) {
        get("/v1/channel-replies") { payload in
            let replies = (payload?["replies"] as? [Any] ?? []).compactMap {
                Self.decodeChannelValue(CmdyChannelReply.self, from: $0)
            }
            completion(replies)
        }
    }

    /// Persist the provider-call boundary before making the external send.
    /// If the connector or host stops after this succeeds, Cmdy requires
    /// verification instead of automatically repeating a possibly accepted
    /// provider request.
    func beginChannelReplyDelivery(
        _ replyID: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        post("/v1/channel-replies/\(replyID)/attempt", [:]) { payload in
            completion?(payload?["ok"] as? Bool == true)
        }
    }

    /// Confirm the provider accepted a queued reply, or return it to failed
    /// state with a bounded diagnostic so the user can retry deliberately.
    func acknowledgeChannelReply(
        _ replyID: String,
        delivered: Bool,
        error: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        var body: [String: Any] = ["delivered": delivered]
        if let error { body["error"] = error }
        post("/v1/channel-replies/\(replyID)/ack", body) { payload in
            completion?(payload?["ok"] as? Bool == true)
        }
    }

    /// Record that provider acceptance is ambiguous. The reply will not be
    /// recovered or retried until the user explicitly confirms duplicate risk.
    func markChannelReplyVerificationNeeded(
        _ replyID: String,
        error: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        var body: [String: Any] = ["state": "verification-needed"]
        if let error { body["error"] = error }
        post("/v1/channel-replies/\(replyID)/ack", body) { payload in
            completion?(payload?["ok"] as? Bool == true)
        }
    }

    /// Report provider health separately from Extension process readiness.
    func reportChannelHealth(
        _ health: CmdyChannelHealth,
        for channelID: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let body = Self.channelJSONObject(health) else {
            completion?(false)
            return
        }
        post("/v1/channels/\(channelID)/health", body) { payload in
            completion?(payload?["ok"] as? Bool == true)
        }
    }

    /// Decode a private `kind=channel-reply` SSE event. Call the provider,
    /// then acknowledge the reply through `acknowledgeChannelReply`.
    static func channelReply(from event: [String: Any]) -> CmdyChannelReply? {
        guard event["kind"] as? String == "channel-reply" else { return nil }
        return decodeChannelValue(CmdyChannelReply.self, from: event)
    }

    private static func channelJSONObject<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func decodeChannelValue<T: Decodable>(
        _ type: T.Type, from value: Any
    ) -> T? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}
