// Viewport-only snapshot projection owned by the Cmdy publication layer.

extension CoreTerminalSnapshot {
    /// Return a new viewport identity while retaining the already-detached row
    /// window. Callers must first prove that this window covers the visible
    /// grid and that no parser publication, geometry, or buffer change is
    /// pending.
    public func projectingViewport(
        onto replacement: CoreGridSnapshot
    ) -> CoreTerminalSnapshot {
        CoreTerminalSnapshot(
            grid: replacement,
            firstLineRow: firstLineRow,
            lines: lines,
            dirtyRows: nil,
            applicationCursorKeys: applicationCursorKeys,
            bracketedPaste: bracketedPaste,
            focusReporting: focusReporting,
            mouseMode: mouseMode,
            mouseProtocol: mouseProtocol,
            kittyKeyboardFlags: kittyKeyboardFlags,
            kittyPlacements: kittyPlacements,
            kittyImages: kittyImages,
            kittyNextImageId: kittyNextImageId,
            kittyNextPlacementId: kittyNextPlacementId)
    }
}
