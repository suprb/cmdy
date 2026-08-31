import Foundation

public extension Notification.Name {
    /// Posted on the main thread whenever an Extension adds, changes, or
    /// removes declarative Adaptive Frame content.
    static let cmdyWorkspaceContributionsChanged = Notification.Name(
        "cmdy.workspaceContributionsChanged")
}

public enum ExtensionWorkspaceLocation: String, CaseIterable, Codable, Sendable {
    case navigator
    case inspector
}

/// A contribution can remain always visible or opt into one or more live host
/// contexts. Matching any declared context makes it visible.
public enum ExtensionWorkspaceContext: String, CaseIterable, Codable, Sendable {
    case pane
    case command
    case selection
    case surface
}

public enum ExtensionWorkspaceItemStatus: String, Codable, Sendable {
    case neutral
    case active
    case attention
    case success
    case failure
}

public struct ExtensionWorkspaceItem: Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let badge: String?
    public let status: ExtensionWorkspaceItemStatus
    public let action: String?
    public let isEnabled: Bool

    public init(id: String, title: String, detail: String? = nil,
                badge: String? = nil,
                status: ExtensionWorkspaceItemStatus = .neutral,
                action: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.badge = badge
        self.status = status
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// Immutable host snapshot. `owner` is an opaque per-launch identity used only
/// to route actions back to the process that created the section.
public struct ExtensionWorkspaceContribution: Sendable {
    public let owner: String
    public let extensionID: String
    public let extensionName: String
    public let id: String
    public let location: ExtensionWorkspaceLocation
    public let title: String
    public let windowNumber: Int?
    public let paneID: String?
    public let priority: Int
    public let contexts: Set<ExtensionWorkspaceContext>
    public let sequence: Int
    public let items: [ExtensionWorkspaceItem]

    public init(owner: String, extensionID: String, extensionName: String,
                id: String, location: ExtensionWorkspaceLocation, title: String,
                windowNumber: Int? = nil, paneID: String? = nil,
                priority: Int = 0,
                contexts: Set<ExtensionWorkspaceContext> = [],
                sequence: Int = 0, items: [ExtensionWorkspaceItem]) {
        self.owner = owner
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.id = id
        self.location = location
        self.title = title
        self.windowNumber = windowNumber
        self.paneID = paneID
        self.priority = priority
        self.contexts = contexts
        self.sequence = sequence
        self.items = items
    }
}
