import Foundation
import ProductIdentity

public enum CmdyChannelError: LocalizedError, Equatable {
    case invalid(String)
    case forbidden(String)
    case notFound(String)
    case conflict(String)
    case unavailable(String)

    public var errorDescription: String? {
        let product = ProductIdentity.current.titleName
        switch self {
        case .invalid(let detail): return "Invalid \(product) Channel: \(detail)"
        case .forbidden(let detail): return "\(product) Channel access denied: \(detail)"
        case .notFound(let detail): return "\(product) Channel resource not found: \(detail)"
        case .conflict(let detail): return "\(product) Channel conflict: \(detail)"
        case .unavailable(let detail): return "\(product) Channel unavailable: \(detail)"
        }
    }
}

public enum CmdyChannelReplyCapability: String, Codable, CaseIterable, Sendable {
    case reply
    case update
    case upload
}

public enum CmdyWorkItemStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case working
    case needsInput = "needs-input"
    case completed
    case failed
    case ignored

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .ignored
    }
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
    /// The connector durably marked that it is about to call the provider.
    /// If this state survives its owner, recovery becomes verification-needed
    /// rather than blindly repeating a potentially accepted send.
    case delivering
    case sent
    case failed
    /// The provider may have accepted the reply, but the connector cannot
    /// prove either success or failure. Retrying requires a separate,
    /// explicit confirmation because it may duplicate an external message.
    case verificationNeeded = "verification-needed"
}

public enum CmdyChannelReplyAcknowledgement: Equatable, Sendable {
    case delivered
    case failed(String?)
    case verificationNeeded(String?)
}

public enum CmdyChannelHealthStatus: String, Codable, CaseIterable, Sendable {
    case healthy
    case degraded
    case retrying
    case offline
}

/// Connector-reported provider health. Process connectivity is deliberately
/// kept on `CmdyChannelRuntime.connected`: a running process is not proof
/// that its provider account, poller, or outbound API is healthy.
public struct CmdyChannelHealth: Codable, Equatable, Sendable {
    public var status: CmdyChannelHealthStatus
    public var lastSuccessAt: String?
    public var lastErrorAt: String?
    public var error: String?
    public var nextRetryAt: String?
    public var detail: String?

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

    public static var unreported: CmdyChannelHealth {
        CmdyChannelHealth(status: .offline, detail: "No connector health report yet")
    }
}

public struct CmdyChannel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let service: String
    public let account: String
    public let description: String
    public let replyCapabilities: [CmdyChannelReplyCapability]

    public init(id: String, name: String, service: String, account: String = "",
                description: String = "",
                replyCapabilities: [CmdyChannelReplyCapability] = []) {
        self.id = id
        self.name = name
        self.service = service
        self.account = account
        self.description = description
        self.replyCapabilities = replyCapabilities
    }

    public var canReply: Bool { replyCapabilities.contains(.reply) }
}

public struct CmdyChannelRuntime: Equatable, Sendable {
    public let channel: CmdyChannel
    public let extensionID: String
    public let connected: Bool
    public let health: CmdyChannelHealth

    public init(channel: CmdyChannel, extensionID: String, connected: Bool,
                health: CmdyChannelHealth = .unreported) {
        self.channel = channel
        self.extensionID = extensionID
        self.connected = connected
        self.health = health
    }
}

public struct CmdyWorkItem: Codable, Equatable, Sendable {
    public let id: String
    public let channelID: String
    public let deliveryID: String
    public let conversationID: String
    public let replyToID: String?
    public let senderID: String?
    public let senderName: String
    public let title: String
    public let body: String
    public let createdAt: String
    public let receivedAt: String
    public let projectHint: String?
    public var status: CmdyWorkItemStatus

    public init(id: String, channelID: String, deliveryID: String,
                conversationID: String, replyToID: String? = nil,
                senderID: String? = nil, senderName: String,
                title: String, body: String, createdAt: String,
                receivedAt: String, projectHint: String? = nil,
                status: CmdyWorkItemStatus = .pending) {
        self.id = id
        self.channelID = channelID
        self.deliveryID = deliveryID
        self.conversationID = conversationID
        self.replyToID = replyToID
        self.senderID = senderID
        self.senderName = senderName
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.receivedAt = receivedAt
        self.projectHint = projectHint
        self.status = status
    }
}

public struct CmdyChannelReply: Codable, Equatable, Sendable {
    public let id: String
    public let channelID: String
    public let workItemID: String
    public let kind: CmdyChannelReplyKind
    public let body: String
    public let createdAt: String
    public var state: CmdyChannelReplyState
    public var deliveryError: String?

    public init(id: String, channelID: String, workItemID: String,
                kind: CmdyChannelReplyKind, body: String, createdAt: String,
                state: CmdyChannelReplyState = .draft,
                deliveryError: String? = nil) {
        self.id = id
        self.channelID = channelID
        self.workItemID = workItemID
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
        self.state = state
        self.deliveryError = deliveryError
    }
}

extension Notification.Name {
    /// Posted on the main thread after Inbox, Outbox, or connection state changes.
    public static let cmdyChannelsChanged = Notification.Name("cmdy.channelsChanged")
}

/// Persistent, capability-neutral Channel state. PluginManager enforces HTTP
/// credentials; this registry enforces stable Extension ownership, bounds,
/// deduplication, reply state, and crash-safe storage.
public final class CmdyChannelRegistry {
    private static let maxChannels = 256
    private static let maxWorkBodyBytes = 8 * 1024 * 1024
    private static let maxReplyBodyBytes = 8 * 1024 * 1024
    private static let maxStateBytes = 32 * 1024 * 1024

    private struct ChannelRecord {
        var channel: CmdyChannel
        let extensionID: String
        var owner: String?
        var health: CmdyChannelHealth
    }

    private struct PersistedChannel: Codable {
        var channel: CmdyChannel
        var extensionID: String
        /// Optional so v1 state written before provider health existed keeps
        /// decoding. Such records restore as offline/unreported.
        var health: CmdyChannelHealth?
    }

    private struct PersistedState: Codable {
        var version: Int
        var channels: [PersistedChannel]
        var workItems: [CmdyWorkItem]
        var replies: [CmdyChannelReply]
    }

    private struct WorkKey: Hashable {
        let channelID: String
        let workItemID: String
    }

    private struct DeliveryKey: Hashable {
        let channelID: String
        let deliveryID: String
    }

    private struct ShellAssociation {
        let key: WorkKey
        var blockID: String?
    }

    private let storageURL: URL?
    private let fileManager: FileManager
    private var channels: [String: ChannelRecord] = [:]
    private var workItems: [WorkKey: CmdyWorkItem] = [:]
    private var replies: [String: CmdyChannelReply] = [:]
    private var shellAssociations: [String: ShellAssociation] = [:]

    public init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        load()
    }

    @discardableResult
    public func register(_ channel: CmdyChannel, extensionID: String,
                         owner: String) throws -> CmdyChannelRuntime {
        try Self.validate(channel, extensionID: extensionID)
        if let existing = channels[channel.id], existing.extensionID != extensionID {
            throw CmdyChannelError.conflict(
                "'\(channel.id)' belongs to \(existing.extensionID)")
        }
        if let existing = channels[channel.id], let currentOwner = existing.owner,
           currentOwner != owner {
            throw CmdyChannelError.conflict(
                "'\(channel.id)' is already connected by this Extension")
        }
        let ownedCount = channels.values.filter { $0.extensionID == extensionID }.count
        guard channels[channel.id] != nil || ownedCount < 16 else {
            throw CmdyChannelError.invalid("an Extension may register at most 16 Channels")
        }
        guard channels[channel.id] != nil || channels.count < Self.maxChannels else {
            throw CmdyChannelError.invalid(
                "\(ProductIdentity.current.titleName) may retain at most 256 Channels")
        }
        resolveAbandonedDeliveries(channelIDs: [channel.id])
        let health = channels[channel.id]?.health ?? .unreported
        channels[channel.id] = ChannelRecord(
            channel: channel, extensionID: extensionID, owner: owner, health: health)
        persistAndNotify(reason: "channel-registered", channelID: channel.id)
        return CmdyChannelRuntime(
            channel: channel, extensionID: extensionID, connected: true,
            health: health)
    }

    public func disconnect(owner: String) {
        var changed: [String] = []
        for id in channels.keys.sorted() where channels[id]?.owner == owner {
            channels[id]?.owner = nil
            channels[id]?.health.status = .offline
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        resolveAbandonedDeliveries(channelIDs: Set(changed))
        persistAndNotify(reason: "channel-disconnected", channelID: changed.first)
    }

    public func removeChannel(id: String, owner: String?) throws {
        guard let record = channels[id] else {
            throw CmdyChannelError.notFound(id)
        }
        if let owner, record.owner != owner {
            throw CmdyChannelError.forbidden("another Extension owns '\(id)'")
        }
        channels[id] = nil
        workItems = workItems.filter { $0.key.channelID != id }
        replies = replies.filter { $0.value.channelID != id }
        shellAssociations = shellAssociations.filter { $0.value.key.channelID != id }
        persistAndNotify(reason: "channel-removed", channelID: id)
    }

    public func channelRuntimes(owner: String? = nil) -> [CmdyChannelRuntime] {
        channels.values.filter { owner == nil || $0.owner == owner }.map {
            CmdyChannelRuntime(
                channel: $0.channel, extensionID: $0.extensionID,
                connected: $0.owner != nil, health: $0.health)
        }.sorted { $0.channel.name.localizedCaseInsensitiveCompare($1.channel.name) == .orderedAscending }
    }

    public func channelRuntime(id: String, owner: String? = nil)
        -> CmdyChannelRuntime? {
        guard let record = channels[id], owner == nil || record.owner == owner else {
            return nil
        }
        return CmdyChannelRuntime(
            channel: record.channel, extensionID: record.extensionID,
            connected: record.owner != nil, health: record.health)
    }

    public func reportHealth(channelID: String, owner: String,
                             health: CmdyChannelHealth) throws
        -> CmdyChannelHealth {
        guard var record = channels[channelID] else {
            throw CmdyChannelError.notFound(channelID)
        }
        guard record.owner == owner else {
            throw CmdyChannelError.forbidden(
                "the connector does not own '\(channelID)'")
        }
        try Self.validate(health)
        record.health = health
        channels[channelID] = record
        persistAndNotify(reason: "channel-health", channelID: channelID)
        return health
    }

    @discardableResult
    public func ingest(_ item: CmdyWorkItem, owner: String,
                       extensionID: String) throws -> (item: CmdyWorkItem, deduplicated: Bool) {
        guard let channel = channels[item.channelID] else {
            throw CmdyChannelError.notFound(item.channelID)
        }
        guard channel.owner == owner, channel.extensionID == extensionID else {
            throw CmdyChannelError.forbidden("the connector does not own '\(item.channelID)'")
        }
        try Self.validate(item)
        if let existing = workItems.values.first(where: {
            $0.channelID == item.channelID && $0.deliveryID == item.deliveryID
        }) {
            return (existing, true)
        }
        let key = WorkKey(channelID: item.channelID, workItemID: item.id)
        guard workItems[key] == nil else {
            throw CmdyChannelError.conflict(
                "work item '\(item.id)' already exists in '\(item.channelID)'")
        }
        var pending = item
        pending.status = .pending
        pruneTerminalItemsIfNeeded(
            channelID: item.channelID, requiredBodyBytes: pending.body.utf8.count)
        guard workItems.count < 2_048,
              workItems.values.filter({ $0.channelID == item.channelID }).count < 512,
              workItems.values.reduce(0, { $0 + $1.body.utf8.count })
                + pending.body.utf8.count <= Self.maxWorkBodyBytes else {
            throw CmdyChannelError.invalid("the Work Inbox is full; archive completed items")
        }
        workItems[key] = pending
        persistAndNotify(reason: "work-item-received", channelID: item.channelID,
                         workItemID: item.id)
        return (pending, false)
    }

    public func workItem(channelID: String, id: String) -> CmdyWorkItem? {
        workItems[WorkKey(channelID: channelID, workItemID: id)]
    }

    public func visibleWorkItems(owner: String? = nil,
                                 includeTerminal: Bool = true) -> [CmdyWorkItem] {
        workItems.values.filter { item in
            (includeTerminal || !item.status.isTerminal)
                && (owner == nil || channels[item.channelID]?.owner == owner)
        }.sorted {
            if $0.status == .pending && $1.status != .pending { return true }
            if $0.status != .pending && $1.status == .pending { return false }
            return $0.receivedAt > $1.receivedAt
        }
    }

    public func setStatus(channelID: String, workItemID: String,
                          status: CmdyWorkItemStatus) throws {
        let key = WorkKey(channelID: channelID, workItemID: workItemID)
        guard var item = workItems[key] else {
            throw CmdyChannelError.notFound("\(channelID)/\(workItemID)")
        }
        item.status = status
        workItems[key] = item
        persistAndNotify(reason: "work-item-updated", channelID: channelID,
                         workItemID: workItemID)
    }

    public func connectorSetStatus(channelID: String, workItemID: String,
                                   status: CmdyWorkItemStatus,
                                   owner: String) throws {
        guard channels[channelID]?.owner == owner else {
            throw CmdyChannelError.forbidden("the connector does not own '\(channelID)'")
        }
        try setStatus(channelID: channelID, workItemID: workItemID, status: status)
    }

    @discardableResult
    public func createDraft(channelID: String, workItemID: String,
                            kind: CmdyChannelReplyKind,
                            body: String) throws -> CmdyChannelReply {
        let key = WorkKey(channelID: channelID, workItemID: workItemID)
        guard workItems[key] != nil else {
            throw CmdyChannelError.notFound("\(channelID)/\(workItemID)")
        }
        guard let channel = channels[channelID]?.channel, channel.canReply else {
            throw CmdyChannelError.unavailable("'\(channelID)' does not support replies")
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 * 1024 else {
            throw CmdyChannelError.invalid("a reply must contain 1 to 65536 bytes")
        }
        pruneDeliveredRepliesIfNeeded(requiredBodyBytes: trimmed.utf8.count)
        guard replies.count < 4_096,
              replies.values.reduce(0, { $0 + $1.body.utf8.count })
                + trimmed.utf8.count <= Self.maxReplyBodyBytes else {
            throw CmdyChannelError.invalid(
                "the Channel Outbox is full; send or discard older drafts")
        }
        let reply = CmdyChannelReply(
            id: "reply-\(UUID().uuidString.lowercased())",
            channelID: channelID, workItemID: workItemID, kind: kind,
            body: trimmed, createdAt: Self.timestamp())
        replies[reply.id] = reply
        persistAndNotify(reason: "reply-drafted", channelID: channelID,
                         workItemID: workItemID)
        return reply
    }

    @discardableResult
    public func queueReply(id: String, confirmVerificationNeeded: Bool = false)
        throws -> (reply: CmdyChannelReply, owner: String?) {
        guard var reply = replies[id] else { throw CmdyChannelError.notFound(id) }
        let normallyRetryable = reply.state == .draft || reply.state == .failed
        let confirmedAmbiguousRetry = reply.state == .verificationNeeded
            && confirmVerificationNeeded
        guard normallyRetryable || confirmedAmbiguousRetry else {
            if reply.state == .verificationNeeded {
                throw CmdyChannelError.conflict(
                    "reply '\(id)' may already have been delivered; verify the provider or explicitly confirm a duplicate-risk retry")
            }
            throw CmdyChannelError.conflict("reply '\(id)' is already \(reply.state.rawValue)")
        }
        reply.state = .queued
        reply.deliveryError = nil
        replies[id] = reply
        persistAndNotify(reason: "reply-queued", channelID: reply.channelID,
                         workItemID: reply.workItemID)
        return (reply, channels[reply.channelID]?.owner)
    }

    public func reply(id: String) -> CmdyChannelReply? { replies[id] }

    public func discardReply(id: String) throws {
        guard let reply = replies[id] else { throw CmdyChannelError.notFound(id) }
        guard reply.state != .queued && reply.state != .delivering else {
            throw CmdyChannelError.conflict(
                "reply '\(id)' is active in connector delivery")
        }
        replies[id] = nil
        persistAndNotify(reason: "reply-discarded", channelID: reply.channelID,
                         workItemID: reply.workItemID)
    }

    public func visibleReplies(owner: String? = nil,
                               states: Set<CmdyChannelReplyState>? = nil)
        -> [CmdyChannelReply] {
        replies.values.filter { reply in
            (states == nil || states?.contains(reply.state) == true)
                && (owner == nil || channels[reply.channelID]?.owner == owner)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func acknowledgeReply(id: String, owner: String, delivered: Bool,
                                 error: String? = nil) throws -> CmdyChannelReply {
        guard var reply = replies[id] else { throw CmdyChannelError.notFound(id) }
        guard channels[reply.channelID]?.owner == owner else {
            throw CmdyChannelError.forbidden("the connector does not own this reply")
        }
        guard reply.state == .queued || reply.state == .delivering else {
            throw CmdyChannelError.conflict("reply '\(id)' is not active for delivery")
        }
        reply.state = delivered ? .sent : .failed
        reply.deliveryError = delivered ? nil : Self.utf8Prefix(
            error ?? "delivery failed", maxBytes: 1_024)
        replies[id] = reply
        persistAndNotify(reason: delivered ? "reply-sent" : "reply-failed",
                         channelID: reply.channelID, workItemID: reply.workItemID)
        return reply
    }

    /// Persist the retry-safety boundary before a connector invokes its
    /// provider. Modern connectors call this immediately before the external
    /// send. Legacy connectors may still acknowledge directly from queued.
    public func beginReplyDelivery(id: String, owner: String) throws
        -> CmdyChannelReply {
        guard var reply = replies[id] else { throw CmdyChannelError.notFound(id) }
        guard channels[reply.channelID]?.owner == owner else {
            throw CmdyChannelError.forbidden("the connector does not own this reply")
        }
        guard reply.state == .queued else {
            throw CmdyChannelError.conflict("reply '\(id)' is not queued")
        }
        reply.state = .delivering
        reply.deliveryError = nil
        replies[id] = reply
        persistAndNotify(reason: "reply-delivering", channelID: reply.channelID,
                         workItemID: reply.workItemID)
        return reply
    }

    /// Record the honest third outcome: the provider may have accepted the
    /// message, but the connector lost the evidence required to acknowledge
    /// success. This state is visible to discovery clients only and is never
    /// automatically returned in the connector's queued-reply recovery list.
    public func markReplyVerificationNeeded(id: String, owner: String,
                                            detail: String? = nil) throws
        -> CmdyChannelReply {
        guard var reply = replies[id] else { throw CmdyChannelError.notFound(id) }
        guard channels[reply.channelID]?.owner == owner else {
            throw CmdyChannelError.forbidden("the connector does not own this reply")
        }
        guard reply.state == .queued || reply.state == .delivering else {
            throw CmdyChannelError.conflict("reply '\(id)' is not active for delivery")
        }
        reply.state = .verificationNeeded
        reply.deliveryError = Self.utf8Prefix(
            detail ?? "Provider acceptance could not be verified", maxBytes: 1_024)
        replies[id] = reply
        persistAndNotify(reason: "reply-verification-needed",
                         channelID: reply.channelID, workItemID: reply.workItemID)
        return reply
    }

    private func resolveAbandonedDeliveries<S: Sequence>(channelIDs: S)
    where S.Element == String {
        let ids = Set(channelIDs)
        let abandoned = replies.values.filter {
            ids.contains($0.channelID) && $0.state == .delivering
        }.map(\.id)
        for id in abandoned {
            replies[id]?.state = .verificationNeeded
            if replies[id]?.deliveryError == nil {
                replies[id]?.deliveryError = Self.utf8Prefix(
                    "Connector stopped before provider acceptance was acknowledged",
                    maxBytes: 1_024)
            }
        }
    }

    public func beginShellResult(channelID: String, workItemID: String,
                                 paneID: String) throws {
        guard workItems[WorkKey(channelID: channelID, workItemID: workItemID)] != nil else {
            throw CmdyChannelError.notFound("\(channelID)/\(workItemID)")
        }
        shellAssociations[paneID] = ShellAssociation(
            key: WorkKey(channelID: channelID, workItemID: workItemID), blockID: nil)
        try setStatus(channelID: channelID, workItemID: workItemID, status: .accepted)
    }

    public func cancelShellResult(channelID: String, workItemID: String,
                                  paneID: String) {
        guard shellAssociations[paneID]?.key == WorkKey(
            channelID: channelID, workItemID: workItemID) else { return }
        _ = cancelShellResult(paneID: paneID)
    }

    /// Drop staged shell work when its pane closes. A command that never
    /// started is reviewable again; a command interrupted after start is a
    /// failed attempt rather than a silently completed one.
    @discardableResult
    public func cancelShellResult(paneID: String) -> Bool {
        guard let association = shellAssociations.removeValue(forKey: paneID) else {
            return false
        }
        try? setStatus(
            channelID: association.key.channelID,
            workItemID: association.key.workItemID,
            status: association.blockID == nil ? .pending : .failed)
        return true
    }

    public func commandStarted(paneID: String, blockID: String) {
        guard var association = shellAssociations[paneID], association.blockID == nil else {
            return
        }
        association.blockID = blockID
        shellAssociations[paneID] = association
        try? setStatus(channelID: association.key.channelID,
                       workItemID: association.key.workItemID, status: .working)
    }

    @discardableResult
    public func commandFinished(paneID: String, blockID: String, command: String,
                                exitCode: Int, output: String) -> CmdyChannelReply? {
        guard let association = shellAssociations[paneID],
              association.blockID == blockID else { return nil }
        shellAssociations[paneID] = nil
        let status: CmdyWorkItemStatus = exitCode == 0 ? .completed : .failed
        try? setStatus(channelID: association.key.channelID,
                       workItemID: association.key.workItemID, status: status)
        let boundedCommand = Self.utf8Prefix(command, maxBytes: 8 * 1024)
        let boundedOutput = Self.utf8Prefix(output, maxBytes: 48 * 1024)
        let body = """
        Command: \(boundedCommand)
        Exit code: \(exitCode)

        \(boundedOutput.isEmpty ? "(no output)" : boundedOutput)
        """
        return try? createDraft(
            channelID: association.key.channelID,
            workItemID: association.key.workItemID, kind: .result, body: body)
    }

    public func payload(for runtime: CmdyChannelRuntime) -> [String: Any] {
        [
            "id": runtime.channel.id,
            "name": runtime.channel.name,
            "service": runtime.channel.service,
            "account": runtime.channel.account,
            "description": runtime.channel.description,
            "replyCapabilities": runtime.channel.replyCapabilities.map(\.rawValue),
            "extension": runtime.extensionID,
            "connected": runtime.connected,
            "health": payload(for: runtime.health),
        ]
    }

    public func payload(for health: CmdyChannelHealth) -> [String: Any] {
        var result: [String: Any] = ["status": health.status.rawValue]
        if let value = health.lastSuccessAt { result["lastSuccessAt"] = value }
        if let value = health.lastErrorAt { result["lastErrorAt"] = value }
        if let value = health.error { result["error"] = value }
        if let value = health.nextRetryAt { result["nextRetryAt"] = value }
        if let value = health.detail { result["detail"] = value }
        return result
    }

    public func payload(for item: CmdyWorkItem) -> [String: Any] {
        var result: [String: Any] = [
            "id": item.id,
            "channel": item.channelID,
            "deliveryID": item.deliveryID,
            "conversationID": item.conversationID,
            "senderName": item.senderName,
            "title": item.title,
            "body": item.body,
            "createdAt": item.createdAt,
            "receivedAt": item.receivedAt,
            "status": item.status.rawValue,
        ]
        if let value = item.replyToID { result["replyToID"] = value }
        if let value = item.senderID { result["senderID"] = value }
        if let value = item.projectHint { result["projectHint"] = value }
        return result
    }

    public func payload(for reply: CmdyChannelReply) -> [String: Any] {
        var result: [String: Any] = [
            "id": reply.id,
            "channel": reply.channelID,
            "workItem": reply.workItemID,
            "kind": reply.kind.rawValue,
            "body": reply.body,
            "createdAt": reply.createdAt,
            "state": reply.state.rawValue,
        ]
        // Carry the provider address with every queued delivery. This keeps
        // restart recovery lossless without forcing each connector to mirror
        // Cmdy's durable Work Inbox in a second local database.
        if let item = workItems[WorkKey(
            channelID: reply.channelID, workItemID: reply.workItemID)] {
            result["conversationID"] = item.conversationID
            if let replyToID = item.replyToID { result["replyToID"] = replyToID }
        }
        if let error = reply.deliveryError { result["error"] = error }
        if reply.state == .verificationNeeded {
            result["retryRequiresConfirmation"] = true
        }
        return result
    }

    public static func channel(from payload: [String: Any]) throws -> CmdyChannel {
        guard let id = payload["id"] as? String,
              let name = payload["name"] as? String,
              let service = payload["service"] as? String else {
            throw CmdyChannelError.invalid("a Channel needs id, name, and service")
        }
        let names = payload["replyCapabilities"] as? [String] ?? []
        guard names.count <= CmdyChannelReplyCapability.allCases.count,
              let capabilities = try? names.map({ name -> CmdyChannelReplyCapability in
                  guard let value = CmdyChannelReplyCapability(rawValue: name) else {
                      throw CmdyChannelError.invalid("unknown reply capability '\(name)'")
                  }
                  return value
              }), Set(capabilities).count == capabilities.count else {
            throw CmdyChannelError.invalid("replyCapabilities contains an unknown or duplicate value")
        }
        return CmdyChannel(
            id: id, name: name, service: service,
            account: payload["account"] as? String ?? "",
            description: payload["description"] as? String ?? "",
            replyCapabilities: capabilities)
    }

    public static func workItem(from payload: [String: Any],
                                channelID: String) throws -> CmdyWorkItem {
        guard let id = payload["id"] as? String,
              let deliveryID = payload["deliveryID"] as? String,
              let conversationID = payload["conversationID"] as? String,
              let senderName = payload["senderName"] as? String,
              let title = payload["title"] as? String,
              let body = payload["body"] as? String else {
            throw CmdyChannelError.invalid(
                "a Work Item needs id, deliveryID, conversationID, senderName, title, and body")
        }
        let now = timestamp()
        return CmdyWorkItem(
            id: id, channelID: channelID, deliveryID: deliveryID,
            conversationID: conversationID,
            replyToID: payload["replyToID"] as? String,
            senderID: payload["senderID"] as? String,
            senderName: senderName, title: title, body: body,
            createdAt: payload["createdAt"] as? String ?? now,
            receivedAt: now,
            projectHint: payload["projectHint"] as? String)
    }

    public static func health(from payload: [String: Any]) throws
        -> CmdyChannelHealth {
        guard let rawStatus = payload["status"] as? String,
              let status = CmdyChannelHealthStatus(rawValue: rawStatus) else {
            throw CmdyChannelError.invalid(
                "Channel health needs status healthy, degraded, retrying, or offline")
        }
        for key in ["lastSuccessAt", "lastErrorAt", "error", "nextRetryAt", "detail"] {
            if let value = payload[key], !(value is NSNull), !(value is String) {
                throw CmdyChannelError.invalid(
                    "Channel health field '\(key)' must be a string or null")
            }
        }
        let health = CmdyChannelHealth(
            status: status,
            lastSuccessAt: payload["lastSuccessAt"] as? String,
            lastErrorAt: payload["lastErrorAt"] as? String,
            error: payload["error"] as? String,
            nextRetryAt: payload["nextRetryAt"] as? String,
            detail: payload["detail"] as? String)
        try validate(health)
        return health
    }

    /// Decode both the original binary acknowledgement and the explicit
    /// ambiguous-acceptance form. Exactly one discriminator is required.
    public static func replyAcknowledgement(from payload: [String: Any]) throws
        -> CmdyChannelReplyAcknowledgement {
        let delivered = payload["delivered"] as? Bool
        let state = payload["state"] as? String
        guard (delivered != nil) != (state != nil) else {
            throw CmdyChannelError.invalid(
                "acknowledgement needs exactly one of {delivered} or {state: verification-needed}")
        }
        if let error = payload["error"], !(error is NSNull), !(error is String) {
            throw CmdyChannelError.invalid(
                "acknowledgement error must be a string or null")
        }
        let error = payload["error"] as? String
        if delivered == true { return .delivered }
        if delivered == false { return .failed(error) }
        guard state == CmdyChannelReplyState.verificationNeeded.rawValue else {
            throw CmdyChannelError.invalid(
                "unknown acknowledgement state; use verification-needed")
        }
        return .verificationNeeded(error)
    }

    private static func validate(_ channel: CmdyChannel,
                                 extensionID: String) throws {
        guard validResourceID(channel.id),
              channel.id == extensionID || channel.id.hasPrefix(extensionID + ".") else {
            throw CmdyChannelError.invalid(
                "Channel id must equal or extend the owning Extension id")
        }
        guard bounded(channel.name, 160, nonempty: true),
              bounded(channel.service, 80, nonempty: true),
              bounded(channel.account, 256), bounded(channel.description, 1_024),
              Set(channel.replyCapabilities).count == channel.replyCapabilities.count else {
            throw CmdyChannelError.invalid("Channel fields are missing, oversized, or duplicated")
        }
    }

    private static func validate(_ item: CmdyWorkItem) throws {
        guard validResourceID(item.id),
              bounded(item.deliveryID, 512, nonempty: true),
              bounded(item.conversationID, 512, nonempty: true),
              bounded(item.replyToID ?? "", 512),
              bounded(item.senderID ?? "", 512),
              bounded(item.senderName, 256, nonempty: true),
              bounded(item.title, 512, nonempty: true),
              bounded(item.body, 64 * 1024),
              bounded(item.createdAt, 128, nonempty: true),
              bounded(item.receivedAt, 128, nonempty: true),
              bounded(item.projectHint ?? "", 4_096) else {
            throw CmdyChannelError.invalid("Work Item fields are missing or oversized")
        }
    }

    private static func validate(_ health: CmdyChannelHealth) throws {
        guard bounded(health.lastSuccessAt ?? "", 128),
              bounded(health.lastErrorAt ?? "", 128),
              bounded(health.error ?? "", 1_024),
              bounded(health.nextRetryAt ?? "", 128),
              bounded(health.detail ?? "", 2_048) else {
            throw CmdyChannelError.invalid("Channel health fields are oversized")
        }
    }

    private static func validResourceID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.first != "."
            && value.last != "." && !value.contains("..") && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "."
                    || $0 == "-" || $0 == "_")
            }
    }

    private static func bounded(_ value: String, _ bytes: Int,
                                nonempty: Bool = false) -> Bool {
        (!nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && value.utf8.count <= bytes
    }

    private static func utf8Prefix(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var end = value.startIndex
        var bytes = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let width = value[end..<next].utf8.count
            guard bytes + width <= maxBytes else { break }
            bytes += width
            end = next
        }
        return String(value[..<end])
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func pruneTerminalItemsIfNeeded(channelID: String,
                                            requiredBodyBytes: Int) {
        var totalBytes = workItems.values.reduce(0) { $0 + $1.body.utf8.count }
        var channelCount = workItems.values.filter { $0.channelID == channelID }.count
        let needsChannelSpace = channelCount >= 512
        guard workItems.count >= 2_048
                || needsChannelSpace
                || totalBytes + requiredBodyBytes > Self.maxWorkBodyBytes else { return }
        let candidates = workItems.values.filter { item in
            item.status.isTerminal && !replies.values.contains { reply in
                reply.channelID == item.channelID && reply.workItemID == item.id
                    && reply.state != .sent
            }
        }
            .sorted {
                if needsChannelSpace, ($0.channelID == channelID) != ($1.channelID == channelID) {
                    return $0.channelID == channelID
                }
                return $0.receivedAt < $1.receivedAt
            }
            .prefix(512)
        for item in candidates {
            let key = WorkKey(channelID: item.channelID, workItemID: item.id)
            workItems[key] = nil
            totalBytes -= item.body.utf8.count
            replies = replies.filter {
                !($0.value.channelID == item.channelID && $0.value.workItemID == item.id)
            }
            if item.channelID == channelID { channelCount -= 1 }
            if workItems.count < 2_048,
               channelCount < 512,
               totalBytes + requiredBodyBytes <= Self.maxWorkBodyBytes { break }
        }
    }

    private func pruneDeliveredRepliesIfNeeded(requiredBodyBytes: Int) {
        var totalBytes = replies.values.reduce(0) { $0 + $1.body.utf8.count }
        guard replies.count >= 4_096
                || totalBytes + requiredBodyBytes > Self.maxReplyBodyBytes else { return }
        let delivered = replies.values.filter { $0.state == .sent }
            .sorted { $0.createdAt < $1.createdAt }
        for reply in delivered {
            replies[reply.id] = nil
            totalBytes -= reply.body.utf8.count
            if replies.count < 4_096,
               totalBytes + requiredBodyBytes <= Self.maxReplyBodyBytes { break }
        }
    }

    private func load() {
        guard let storageURL,
              let data = try? BoundedFileReader.data(
                at: storageURL, maxBytes: Self.maxStateBytes),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.version == 1 else { return }
        var extensionChannelCounts: [String: Int] = [:]
        for record in state.channels.prefix(Self.maxChannels) {
            guard (try? Self.validate(record.channel, extensionID: record.extensionID)) != nil else {
                continue
            }
            guard channels[record.channel.id] == nil,
                  extensionChannelCounts[record.extensionID, default: 0] < 16 else {
                continue
            }
            var health = record.health ?? .unreported
            if (try? Self.validate(health)) == nil { health = .unreported }
            // A persisted provider report is historical evidence. Until a
            // connector launch reports again, current health is offline.
            health.status = .offline
            channels[record.channel.id] = ChannelRecord(
                channel: record.channel, extensionID: record.extensionID,
                owner: nil, health: health)
            extensionChannelCounts[record.extensionID, default: 0] += 1
        }
        var workBodyBytes = 0
        var channelWorkCounts: [String: Int] = [:]
        var deliveries = Set<DeliveryKey>()
        for item in state.workItems.prefix(2_048) where channels[item.channelID] != nil {
            guard (try? Self.validate(item)) != nil else { continue }
            guard workBodyBytes + item.body.utf8.count <= Self.maxWorkBodyBytes else { break }
            let key = WorkKey(channelID: item.channelID, workItemID: item.id)
            let delivery = DeliveryKey(
                channelID: item.channelID, deliveryID: item.deliveryID)
            guard workItems[key] == nil,
                  channelWorkCounts[item.channelID, default: 0] < 512,
                  deliveries.insert(delivery).inserted else { continue }
            var restored = item
            if restored.status == .accepted || restored.status == .working {
                restored.status = .pending
            }
            workItems[key] = restored
            channelWorkCounts[item.channelID, default: 0] += 1
            workBodyBytes += restored.body.utf8.count
        }
        var replyBodyBytes = 0
        for reply in state.replies.prefix(4_096)
        where workItems[WorkKey(channelID: reply.channelID,
                                workItemID: reply.workItemID)] != nil {
            guard Self.validResourceID(reply.id),
                  Self.bounded(reply.body, 64 * 1024, nonempty: true),
                  Self.bounded(reply.createdAt, 128, nonempty: true),
                  Self.bounded(reply.deliveryError ?? "", 1_024) else { continue }
            guard replyBodyBytes + reply.body.utf8.count <= Self.maxReplyBodyBytes else { break }
            var restored = reply
            if restored.state == .delivering {
                restored.state = .verificationNeeded
                if restored.deliveryError == nil {
                    restored.deliveryError = Self.utf8Prefix(
                        "Host restarted during provider delivery; verify before retrying",
                        maxBytes: 1_024)
                }
            }
            replies[restored.id] = restored
            replyBodyBytes += restored.body.utf8.count
        }
    }

    private func persistAndNotify(reason: String, channelID: String? = nil,
                                  workItemID: String? = nil) {
        persist()
        notify(reason: reason, channelID: channelID, workItemID: workItemID)
    }

    private func persist() {
        guard let storageURL else { return }
        let state = PersistedState(
            version: 1,
            channels: channels.values.map {
                PersistedChannel(channel: $0.channel, extensionID: $0.extensionID,
                                 health: $0.health)
            }.sorted { $0.channel.id < $1.channel.id },
            workItems: workItems.values.sorted { $0.receivedAt < $1.receivedAt },
            replies: replies.values.sorted { $0.createdAt < $1.createdAt })
        guard let data = try? JSONEncoder.pretty.encode(state) else { return }
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: storageURL.path)
        } catch {
            NSLog("cmdy Channels: could not persist state: %@", error.localizedDescription)
        }
    }

    private func notify(reason: String, channelID: String? = nil,
                        workItemID: String? = nil) {
        var info: [String: Any] = ["reason": reason]
        if let channelID { info["channel"] = channelID }
        if let workItemID { info["workItem"] = workItemID }
        NotificationCenter.default.post(
            name: .cmdyChannelsChanged, object: self, userInfo: info)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
