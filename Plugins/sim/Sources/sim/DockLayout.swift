import AppKit

/// One source of truth for the native Simulator sidecar geometry.
struct SimDockLayout: Equatable {
    static let defaultFraction: CGFloat = 0.70
    static let minimumStripWidth: CGFloat = 280
    static let minimumTerminalWidth: CGFloat = 320

    let stripWidth: CGFloat
    let cardFrame: NSRect
    let simulatorFrame: CGRect
    let availableSimulatorSize: CGSize
    let simulatorFits: Bool

    /// True when the current device is already at the smallest native preset
    /// and still cannot fit. The caller must wait for a resize/device change
    /// instead of retrying the same focus-stealing menu action forever.
    func isUnfittableMinimum(_ minimumSize: CGSize?) -> Bool {
        guard !simulatorFits, let minimumSize else { return false }
        return abs(simulatorFrame.width - minimumSize.width) <= 0.5
            && abs(simulatorFrame.height - minimumSize.height) <= 0.5
    }

    init(host: NSRect,
         dockSide: CGFloat,
         trailingOffset: CGFloat,
         fraction: CGFloat,
         simulatorSize: CGSize,
         screenHeight: CGFloat,
         padding: CGFloat) {
        let maximumStripWidth = max(Self.minimumStripWidth,
                                    host.width - Self.minimumTerminalWidth)
        let minimumStripWidth = min(maximumStripWidth, Self.minimumStripWidth)
        stripWidth = min(max(host.width * fraction, minimumStripWidth), maximumStripWidth)

        // Use the same outer inset on the three exposed window edges. Pane
        // chrome is asymmetric (title bar vs bottom), so it cannot produce a
        // visually centered card.
        let stripHeight = max(0, host.height - 2 * dockSide)
        let stripLeft = host.maxX - max(0, trailingOffset)
            - dockSide - stripWidth
        cardFrame = NSRect(x: stripLeft,
                           y: host.minY + dockSide,
                           width: stripWidth,
                           height: stripHeight)

        let contentWidth = max(0, stripWidth - 2 * padding)
        let contentHeight = max(0, stripHeight - 2 * padding)
        availableSimulatorSize = CGSize(width: contentWidth, height: contentHeight)
        simulatorFits = simulatorSize.width <= contentWidth + 0.5
            && simulatorSize.height <= contentHeight + 0.5

        // Center even when the native window is temporarily too large. This
        // keeps resize symmetric while Sim switches to a smaller preset.
        let simulatorX = stripLeft + (stripWidth - simulatorSize.width) / 2
        let stripTopCG = screenHeight - cardFrame.maxY
        let simulatorY = stripTopCG + (stripHeight - simulatorSize.height) / 2
        simulatorFrame = CGRect(origin: CGPoint(x: simulatorX, y: simulatorY),
                                size: simulatorSize)
    }
}
