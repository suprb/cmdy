import AppKit

/// Geometry policy for the Adaptive Frame surrounding the terminal. The
/// terminal always wins: rails compress first, then the Inspector disappears,
/// then the Navigator. User preferences are never changed by a narrow window,
/// so expanding restores the requested tools.
public enum WorkspaceFrameLayout {
    public struct Result: Equatable, Sendable {
        public let navigatorWidth: CGFloat
        public let inspectorWidth: CGFloat

        public var showsNavigator: Bool { navigatorWidth > 0 }
        public var showsInspector: Bool { inspectorWidth > 0 }
        public var terminalWidth: CGFloat

        public init(navigatorWidth: CGFloat, inspectorWidth: CGFloat,
                    terminalWidth: CGFloat) {
            self.navigatorWidth = navigatorWidth
            self.inspectorWidth = inspectorWidth
            self.terminalWidth = terminalWidth
        }
    }

    public static let idealNavigatorWidth: CGFloat = 210
    public static let minimumNavigatorWidth: CGFloat = 176
    public static let idealInspectorWidth: CGFloat = 280
    public static let minimumInspectorWidth: CGFloat = 232
    public static let minimumTerminalWidth: CGFloat = 400

    /// Minimum outer width for a live resize that keeps every visible rail at
    /// its current user-selected width. Each rail contributes one divider
    /// because the terminal column is always present.
    public static func minimumWindowWidthKeepingRailsFixed(
        navigatorWidth: CGFloat?,
        inspectorWidth: CGFloat?,
        dividerThickness: CGFloat,
        reservedTrailingWidth: CGFloat = 0
    ) -> CGFloat {
        let rails = [navigatorWidth, inspectorWidth]
            .compactMap { width in width.map { max(0, $0) } }
        return minimumTerminalWidth
            + rails.reduce(0, +)
            + CGFloat(rails.count) * max(0, dividerThickness)
            + max(0, reservedTrailingWidth)
    }

    public static func resolve(windowWidth: CGFloat,
                               navigatorRequested: Bool,
                               inspectorRequested: Bool,
                               focusMode: Bool,
                               reservedTrailingWidth: CGFloat = 0) -> Result {
        let available = max(0, windowWidth - max(0, reservedTrailingWidth))
        guard !focusMode else {
            return Result(navigatorWidth: 0, inspectorWidth: 0,
                          terminalWidth: available)
        }

        var navigator = navigatorRequested ? idealNavigatorWidth : 0
        var inspector = inspectorRequested ? idealInspectorWidth : 0

        // Shrink both rails proportionally before hiding either one.
        var deficit = max(0, minimumTerminalWidth + navigator + inspector - available)
        if deficit > 0, navigator > 0 {
            let shrink = min(deficit, navigator - minimumNavigatorWidth)
            navigator -= shrink
            deficit -= shrink
        }
        if deficit > 0, inspector > 0 {
            let shrink = min(deficit, inspector - minimumInspectorWidth)
            inspector -= shrink
            deficit -= shrink
        }

        // Context is useful, but never more important than a usable terminal.
        if deficit > 0, inspector > 0 {
            inspector = 0
            deficit = max(0, minimumTerminalWidth + navigator - available)
        }
        if deficit > 0, navigator > 0 { navigator = 0 }

        return Result(navigatorWidth: navigator, inspectorWidth: inspector,
                      terminalWidth: max(0, available - navigator - inspector))
    }
}

/// Tabs have one visible home. A multi-tab group uses the left tab sidebar
/// when it fits; otherwise it falls back to AppKit's native tab bar. A single
/// tab needs neither an extra bar nor a duplicate row of chrome.
public enum WorkspaceTabPresentation {
    public static func showsNativeTabBar(tabCount: Int,
                                         tabSidebarVisible: Bool) -> Bool {
        tabCount > 1 && !tabSidebarVisible
    }
}
