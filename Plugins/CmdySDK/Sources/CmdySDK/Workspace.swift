import Foundation

public enum CmdyWorkspaceLocation: String, Sendable {
    case navigator
    case inspector
}

public enum CmdyWorkspaceContext: String, Sendable {
    case pane
    case command
    case selection
    case surface
}

public enum CmdyWorkspaceItemStatus: String, Sendable {
    case neutral
    case active
    case attention
    case success
    case failure
}

public struct CmdyWorkspaceItem: Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let badge: String?
    public let status: CmdyWorkspaceItemStatus
    public let action: String?
    public let enabled: Bool

    public init(id: String, title: String, detail: String? = nil,
                badge: String? = nil,
                status: CmdyWorkspaceItemStatus = .neutral,
                action: String? = nil, enabled: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.badge = badge
        self.status = status
        self.action = action
        self.enabled = enabled
    }

    fileprivate var payload: [String: Any] {
        var value: [String: Any] = [
            "id": id, "title": title, "status": status.rawValue,
            "enabled": enabled,
        ]
        if let detail { value["detail"] = detail }
        if let badge { value["badge"] = badge }
        if let action { value["action"] = action }
        return value
    }
}

public struct CmdyWorkspaceContribution: Sendable {
    public let id: String
    public let location: CmdyWorkspaceLocation
    public let title: String
    public let window: Int?
    public let pane: String?
    public let priority: Int
    public let contexts: [CmdyWorkspaceContext]
    public let sequence: Int
    public let items: [CmdyWorkspaceItem]

    public init(id: String, location: CmdyWorkspaceLocation, title: String,
                window: Int? = nil, pane: String? = nil, priority: Int = 0,
                contexts: [CmdyWorkspaceContext] = [], sequence: Int = 0,
                items: [CmdyWorkspaceItem]) {
        self.id = id
        self.location = location
        self.title = title
        self.window = window
        self.pane = pane
        self.priority = priority
        self.contexts = contexts
        self.sequence = sequence
        self.items = items
    }

    fileprivate var payload: [String: Any] {
        var value: [String: Any] = [
            "id": id, "location": location.rawValue, "title": title,
            "priority": priority, "contexts": contexts.map(\.rawValue),
            "sequence": sequence, "items": items.map(\.payload),
        ]
        if let window { value["window"] = window }
        if let pane { value["pane"] = pane }
        return value
    }
}

public extension Cmdy {
    /// Add one host-rendered section to the Navigator or Inspector.
    func openWorkspaceContribution(
        _ contribution: CmdyWorkspaceContribution,
        completion: ((Bool) -> Void)? = nil
    ) {
        post("/v1/ui/contributions", contribution.payload) { response in
            completion?(response?["ok"] as? Bool == true)
        }
    }

    /// Replace an existing section. Sequence numbers must increase, which
    /// prevents a slow older request from overwriting fresher state.
    func updateWorkspaceContribution(
        _ contribution: CmdyWorkspaceContribution,
        completion: ((Bool) -> Void)? = nil
    ) {
        post("/v1/ui/contributions/\(contribution.id)/update",
             contribution.payload) { response in
            completion?(response?["ok"] as? Bool == true)
        }
    }

    func dismissWorkspaceContribution(
        _ id: String, completion: ((Bool) -> Void)? = nil
    ) {
        delete("/v1/ui/contributions/\(id)") { response in
            completion?(response?["ok"] as? Bool == true)
        }
    }
}
