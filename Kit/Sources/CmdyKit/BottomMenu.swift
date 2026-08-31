import Foundation

/// One reusable action in Cmdy's native bottom-edge menus. The same item
/// shape backs transient InlinePanel menus and persistent Extension control
/// rows so plugins and first-party UI share keyboard and visual conventions.
public struct BottomMenuItem: Sendable, Equatable {
    public let id: String
    public let title: String
    public let isEnabled: Bool
    public let shortcut: String?

    public init(id: String, title: String, isEnabled: Bool = true,
                shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.shortcut = shortcut
    }
}
