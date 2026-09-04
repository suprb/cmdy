import AppKit
import ChromiumSupport
import ProductIdentity
import SwiftUI
import CmdyKit

enum NativeToolbarPreset {
    static func appKitStyle(_ value: String) -> NSWindow.ToolbarStyle {
        value == "compact" ? .unifiedCompact : .unified
    }

    static func titleBandHeight(_ value: String) -> CGFloat {
        value == "compact" ? 40 : 52
    }

    static func titleTop(_ value: String) -> CGFloat {
        value == "compact" ? 13 : 19
    }

    static func titleLeading(_ value: String) -> CGFloat {
        value == "compact" ? 80 : 88
    }
}

/// A split view whose divider color can follow either the terminal theme
/// (between terminal panes) or AppKit's native separator (workspace columns).
final class ThemedSplitView: NSSplitView {
    enum HairlinePlacement: Equatable {
        case centered
        case againstOuterRails
    }

    var themedDividerColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }
    var themedDividerBackingColor: NSColor? {
        didSet { needsDisplay = true }
    }
    var themedDividerHairlineThickness: CGFloat? {
        didSet { needsDisplay = true }
    }
    var themedDividerHairlinePlacement: HairlinePlacement = .centered {
        didSet { needsDisplay = true }
    }
    var themedDividerTopInset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var themedDividerThickness: CGFloat = 2 {
        didSet {
            needsDisplay = true
            needsLayout = true
            adjustSubviews()
        }
    }
    /// Zero keeps normal pane-split behavior. Workspace rails opt into a
    /// comfortable invisible target around their one-pixel separator.
    var interactiveDividerHitTargetThickness: CGFloat = 0 {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    /// Set only when a native window-grid branch is converted back into an
    /// internal pane split. Applying it after the host window settles keeps
    /// the grid's exact recursive proportions instead of equalizing panes.
    var preservedGridRatio: CGFloat?
    var onLayout: (() -> Void)?
    override var dividerColor: NSColor { themedDividerColor }
    override var dividerThickness: CGFloat { themedDividerThickness }

    override func layout() {
        super.layout()
        onLayout?()
    }

    private func visibleDividerRect(_ rect: NSRect) -> NSRect {
        var drawnRect = rect
        if isVertical, themedDividerTopInset > 0 {
            if isFlipped {
                let visibleTop = max(rect.minY, bounds.minY + themedDividerTopInset)
                drawnRect.origin.y = visibleTop
                drawnRect.size.height = max(0, rect.maxY - visibleTop)
            } else {
                let visibleBottom = min(rect.maxY, bounds.maxY - themedDividerTopInset)
                drawnRect.size.height = max(0, visibleBottom - rect.minY)
            }
        }
        return drawnRect
    }

    override func drawDivider(in rect: NSRect) {
        if let backing = themedDividerBackingColor {
            backing.setFill()
            NSBezierPath(rect: rect).fill()
        }

        var drawnRect = visibleDividerRect(rect)
        if let hairline = themedDividerHairlineThickness {
            let scale = max(1, window?.backingScaleFactor ?? 2)
            if isVertical {
                let dividerIndex = (0..<max(0, subviews.count - 1)).first {
                    guard let candidate = drawnDividerRect(at: $0) else {
                        return false
                    }
                    return abs(candidate.midX - rect.midX) < 0.5
                }
                if themedDividerHairlinePlacement == .againstOuterRails,
                   dividerIndex == 0 {
                    drawnRect.origin.x = floor(rect.minX * scale) / scale
                } else if themedDividerHairlinePlacement == .againstOuterRails,
                          dividerIndex == subviews.count - 2 {
                    drawnRect.origin.x =
                        ceil(rect.maxX * scale) / scale - hairline
                } else {
                    drawnRect.origin.x = floor(rect.midX * scale) / scale
                }
                drawnRect.size.width = hairline
            } else {
                drawnRect.origin.y = floor(rect.midY * scale) / scale
                drawnRect.size.height = hairline
            }
        }
        themedDividerColor.setFill()
        NSBezierPath(rect: drawnRect).fill()
    }

    func drawnDividerRect(at index: Int) -> NSRect? {
        guard index >= 0, index < subviews.count - 1 else { return nil }
        let first = subviews[index].frame
        let second = subviews[index + 1].frame
        if isVertical {
            let left = first.minX <= second.minX ? first : second
            let right = first.minX <= second.minX ? second : first
            let gap = max(0, right.minX - left.maxX)
            let thickness = max(dividerThickness, gap)
            let midpoint = (left.maxX + right.minX) / 2
            return NSRect(
                x: midpoint - thickness / 2,
                y: bounds.minY,
                width: thickness,
                height: bounds.height)
        } else {
            let lower = first.minY <= second.minY ? first : second
            let upper = first.minY <= second.minY ? second : first
            let gap = max(0, upper.minY - lower.maxY)
            let thickness = max(dividerThickness, gap)
            let midpoint = (lower.maxY + upper.minY) / 2
            return NSRect(
                x: bounds.minX,
                y: midpoint - thickness / 2,
                width: bounds.width,
                height: thickness)
        }
    }

    func interactiveDividerRect(at index: Int) -> NSRect? {
        guard interactiveDividerHitTargetThickness > 0,
              index >= 0,
              index < subviews.count - 1,
              !subviews[index].isHidden,
              !subviews[index + 1].isHidden else { return nil }
        guard let fullDividerRect = drawnDividerRect(at: index) else { return nil }
        let drawnRect = visibleDividerRect(fullDividerRect)
        let drawnThickness = isVertical ? drawnRect.width : drawnRect.height
        guard drawnThickness > 0 else { return nil }
        let targetThickness = max(
            interactiveDividerHitTargetThickness,
            drawnThickness)
        if isVertical {
            return drawnRect.insetBy(
                dx: -(targetThickness - drawnThickness) / 2,
                dy: 0)
        } else {
            return drawnRect.insetBy(
                dx: 0,
                dy: -(targetThickness - drawnThickness) / 2)
        }
    }

}

/// A transparent sibling above the hosted AppKit/SwiftUI rails. Returning nil
/// everywhere except around a divider lets normal terminal and rail interaction
/// pass through, while guaranteeing the separator wins that narrow hit test.
final class WorkspaceDividerOverlayView: NSView {
    weak var splitView: ThemedSplitView?
    var isLeadingRailVisible: (() -> Bool)?
    var isTrailingRailVisible: (() -> Bool)?
    var onDragEnded: (() -> Void)?

    static func rememberedRailThickness(
        _ thickness: CGFloat?,
        whileVisible isVisible: Bool
    ) -> CGFloat? {
        guard isVisible, let thickness, thickness > 0 else { return nil }
        return thickness
    }

    private struct DragState {
        let dividerIndex: Int
        let startPoint: NSPoint
        let startPosition: CGFloat
        let leadingRailThickness: CGFloat?
        let trailingRailThickness: CGFloat?
    }
    private var dragState: DragState?

    private func divider(at point: NSPoint) -> Int? {
        guard let splitView, splitView.subviews.count > 1 else { return nil }
        return (0..<(splitView.subviews.count - 1)).first { index in
            guard let splitRect = splitView.interactiveDividerRect(at: index) else {
                return false
            }
            return convert(splitRect, from: splitView).contains(point)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        return divider(at: localPoint) == nil ? nil : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let splitView, splitView.subviews.count > 1 else { return }
        let cursor: NSCursor = splitView.isVertical ? .resizeLeftRight : .resizeUpDown
        for index in 0..<(splitView.subviews.count - 1) {
            if let splitRect = splitView.interactiveDividerRect(at: index) {
                addCursorRect(convert(splitRect, from: splitView), cursor: cursor)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let splitView,
              let dividerIndex = divider(at: point),
              let dividerRect = splitView.drawnDividerRect(at: dividerIndex) else {
            return
        }
        dragState = DragState(
            dividerIndex: dividerIndex,
            startPoint: splitView.convert(event.locationInWindow, from: nil),
            startPosition: splitView.isVertical
                ? dividerRect.minX
                : dividerRect.minY,
            leadingRailThickness: Self.rememberedRailThickness(
                splitView.isVertical
                    ? splitView.subviews.first?.frame.width : nil,
                whileVisible: isLeadingRailVisible?() ?? true),
            trailingRailThickness: Self.rememberedRailThickness(
                splitView.isVertical
                    ? splitView.subviews.last?.frame.width : nil,
                whileVisible: isTrailingRailVisible?() ?? true))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let splitView, let dragState else { return }
        let point = splitView.convert(event.locationInWindow, from: nil)
        let delta = splitView.isVertical
            ? point.x - dragState.startPoint.x
            : point.y - dragState.startPoint.y
        splitView.setPosition(
            dragState.startPosition + delta,
            ofDividerAt: dragState.dividerIndex)
        // A three-column NSSplitView may rebalance both outer items when
        // either divider moves, even though both rails have holding priority.
        // The user's gesture owns one rail only; pin the opposite rail to the
        // thickness it had at mouse-down and let the terminal absorb the delta.
        if splitView.isVertical, splitView.subviews.count >= 3 {
            let lastDivider = splitView.subviews.count - 2
            if dragState.dividerIndex == 0,
               isTrailingRailVisible?() ?? true,
               let trailing = dragState.trailingRailThickness {
                splitView.setPosition(
                    splitView.bounds.width - trailing - splitView.dividerThickness,
                    ofDividerAt: lastDivider)
            } else if dragState.dividerIndex == lastDivider,
                      isLeadingRailVisible?() ?? true,
                      let leading = dragState.leadingRailThickness {
                splitView.setPosition(leading, ofDividerAt: 0)
            }
        }
        window?.displayIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        dragState = nil
        if let window, let splitView {
            window.invalidateCursorRects(for: splitView)
            window.invalidateCursorRects(for: self)
        }
        onDragEnded?()
    }
}

/// Invisible strip across the window's top band. In flush mode the terminal
/// view reaches the very top and swallows titlebar behavior — this restores
/// it: drag moves the window, double-click zooms/minimizes per the system
/// preference, and the cursor stays an arrow (it's chrome, not text).
final class TitleBandView: NSView {
    var fillColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var passthroughRects: (() -> [NSRect])? {
        didSet { needsDisplay = true }
    }

    private var drawableRects: [NSRect] {
        let excluded = (passthroughRects?() ?? [])
            .map { $0.intersection(bounds) }
            .filter { !$0.isNull && $0.width > 0 }
            .sorted { $0.minX < $1.minX }
        guard !excluded.isEmpty else { return [bounds] }
        var rects: [NSRect] = []
        var x = bounds.minX
        for hole in excluded {
            if hole.minX > x {
                rects.append(NSRect(
                    x: x, y: bounds.minY,
                    width: hole.minX - x, height: bounds.height))
            }
            x = max(x, hole.maxX)
        }
        if x < bounds.maxX {
            rects.append(NSRect(
                x: x, y: bounds.minY,
                width: bounds.maxX - x, height: bounds.height))
        }
        return rects
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        fillColor.setFill()
        for rect in drawableRects where rect.intersects(dirtyRect) {
            rect.fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if passthroughRects?().contains(where: { $0.contains(point) }) == true {
            return nil
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        for rect in drawableRects {
            addCursorRect(rect, cursor: .arrow)   // chrome, not text
        }
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let pref = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch pref {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
        } else {
            window?.performDrag(with: event)
        }
    }

    // `performDrag` owns the gesture. Do not let a trailing drag/up event walk
    // the responder chain into the focused terminal surface.
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

final class WorkspaceHairlineView: NSView {
    var lineColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var excludedRect: (() -> NSRect?)? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        lineColor.setFill()
        guard let excluded = excludedRect?()?.intersection(bounds),
              !excluded.isNull, excluded.width > 0 else {
            bounds.fill()
            return
        }
        if excluded.minX > bounds.minX {
            NSRect(
                x: bounds.minX, y: bounds.minY,
                width: excluded.minX - bounds.minX, height: bounds.height
            ).fill()
        }
        if excluded.maxX < bounds.maxX {
            NSRect(
                x: excluded.maxX, y: bounds.minY,
                width: bounds.maxX - excluded.maxX, height: bounds.height
            ).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Controls drawn inside a full-size content titlebar must opt out of AppKit's
/// background-window dragging explicitly. Without this, the icons can look and
/// hit-test like buttons while the window still consumes their mouse gesture.
private final class CompactToolbarButton: NSButton {
    /// Matches the native reference control at Retina scale: a 56 px tile,
    /// 26 px symbol, soft continuous corners, and neutral light-mode ink.
    static let side: CGFloat = 28
    static let cornerRadius: CGFloat = 10
    static let restingOpacity: CGFloat = 0.495
    static let hoverOpacity: CGFloat = 0.8
    static let activeFillOpacity: CGFloat = 0.051
    static let referenceDarkInk = NSColor(
        srgbRed: 26.0 / 255.0,
        green: 28.0 / 255.0,
        blue: 31.0 / 255.0,
        alpha: 1)
    static let referenceActiveFill = NSColor(
        srgbRed: 243.0 / 255.0,
        green: 243.0 / 255.0,
        blue: 244.0 / 255.0,
        alpha: 1)
    static let referenceInactiveInk = NSColor(
        srgbRed: 142.0 / 255.0,
        green: 143.0 / 255.0,
        blue: 144.0 / 255.0,
        alpha: 1)

    private var hoverTrackingArea: NSTrackingArea?
    private let selectionMaskLayer = CAShapeLayer()
    private var baseTintColor = NSColor.labelColor
    private var isPointerInside = false
    private var isPointerPressed = false
    private(set) var interactionOpacityHistory: [CGFloat] = []
    var onInteractionOpacityChange: ((CGFloat) -> Void)?
    var isToggledOn = false {
        didSet {
            guard oldValue != isToggledOn else { return }
            state = isToggledOn ? .on : .off
            setAccessibilityValue(isToggledOn ? "On" : "Off")
            applyToggleAppearance()
            applyInteractionOpacity()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    var visualTileRect: NSRect {
        NSRect(
            x: (bounds.width - Self.side) / 2,
            y: (bounds.height - Self.side) / 2,
            width: Self.side,
            height: Self.side)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func prepareInteractionOpacity() {
        wantsLayer = true
        layer?.mask = selectionMaskLayer
        updateSelectionMask()
        applyToggleAppearance()
        applyInteractionOpacity()
    }

    func applyBaseTint(_ color: NSColor) {
        baseTintColor = color
        applyToggleAppearance()
        applyInteractionOpacity()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyToggleAppearance()
    }

    override func layout() {
        super.layout()
        updateSelectionMask()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        applyInteractionOpacity()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        applyInteractionOpacity()
    }

    // Keep mouse handling on this titlebar control rather than allowing the
    // full-size content window to reinterpret it as a background drag.
    override func mouseDown(with event: NSEvent) {
        isPointerPressed = true
        applyInteractionOpacity()
        defer {
            isPointerPressed = false
            if let window {
                isPointerInside = bounds.contains(convert(
                    window.mouseLocationOutsideOfEventStream, from: nil))
            }
            applyInteractionOpacity()
        }
        super.mouseDown(with: event)
    }

    private func applyInteractionOpacity() {
        let opacity: CGFloat = isPointerPressed || isToggledOn
            ? 1 : (isPointerInside
                ? Self.hoverOpacity : Self.restingOpacity)
        if usesLightReferencePalette {
            contentTintColor = isPointerInside && !isToggledOn
                ? Self.referenceDarkInk
                : (opacity == 1
                    ? Self.referenceDarkInk : Self.referenceInactiveInk)
            alphaValue = isPointerInside && !isToggledOn
                ? Self.hoverOpacity : 1
        } else {
            contentTintColor = baseTintColor
            alphaValue = opacity
        }
        // Record the semantic interaction strength even when light mode uses
        // an exact precomposited inactive ink to remain independent of the
        // terminal theme's cream or white title-band color.
        if interactionOpacityHistory.last != opacity {
            interactionOpacityHistory.append(opacity)
            onInteractionOpacityChange?(opacity)
            if interactionOpacityHistory.count > 8 {
                interactionOpacityHistory.removeFirst(
                    interactionOpacityHistory.count - 8)
            }
        }
    }

    private func applyToggleAppearance() {
        guard let layer else { return }
        if isToggledOn {
            // Use the exact #F3F3F4 behind #1A1C1F in light mode. Dark
            // terminal themes derive a translucent tile from their light ink
            // so the control stays adaptive without adding a pale rectangle.
            layer.backgroundColor = (usesLightReferencePalette
                ? Self.referenceActiveFill
                : baseTintColor.withAlphaComponent(
                    Self.activeFillOpacity)).cgColor
            layer.borderColor = NSColor.clear.cgColor
            layer.borderWidth = 0
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderColor = NSColor.clear.cgColor
            layer.borderWidth = 0
        }
    }

    private var usesLightReferencePalette: Bool {
        guard let actual = baseTintColor.usingColorSpace(.sRGB),
              let reference = Self.referenceDarkInk.usingColorSpace(.sRGB)
        else { return false }
        return abs(actual.redComponent - reference.redComponent) < 0.001
            && abs(actual.greenComponent - reference.greenComponent) < 0.001
            && abs(actual.blueComponent - reference.blueComponent) < 0.001
    }

    private func updateSelectionMask() {
        selectionMaskLayer.frame = bounds
        selectionMaskLayer.path = CGPath(
            roundedRect: visualTileRect,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil)
    }
}

private final class CompactToolbarStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// AppKit adds its own "Customize Toolbar…" context-menu item whenever a
/// toolbar is customizable. Route that system entry point through cmdy's
/// compact, scrolling picker too, rather than exposing AppKit's giant palette.
private final class CompactNativeToolbar: NSToolbar {
    var customizationHandler: ((Any?) -> Void)?

    override func runCustomizationPalette(_ sender: Any?) {
        customizationHandler?(sender)
    }
}

/// Hosts one or more terminal panes in a window (or tab). Owns the window
/// chrome (C64 border, compact title, native window buttons, find bar), manages the
/// split-pane tree, and routes app actions to the focused pane.
final class TerminalWindowController: NSWindowController, NSWindowDelegate,
                                      NSToolbarDelegate, NSToolbarItemValidation,
                                      NSMenuItemValidation {

    static let embeddedBrowserStartsVisible = false
    static var compactToolbarRestingOpacityForTesting: CGFloat {
        CompactToolbarButton.restingOpacity
    }

    enum PaneDirection: Equatable { case up, down, left, right }
    struct ResolvedChromeAppearance: Equatable {
        let sourcePaneID: String?
        let themeName: String
        let shaderName: String
    }
    struct WorkspaceRailGeometry {
        let navigatorWidth: CGFloat?
        let inspectorWidth: CGFloat?
    }
    private static let globalAppearanceSelection = "$cmdy.global"

    private let container = DropView(frame: .zero)
    private let paneHost = NSView(frame: .zero)   // the region inside the border
    private(set) var panes: [TerminalPane] = []
    private var editorPanes: [CmdyEditorPane] = []
    private var lastFocused: TerminalPane?
    private var responderObservation: NSKeyValueObservation?
    private var chromeUpdateScheduled = false
    private var isNormalizingNativeToolbar = false
    private var nativeToolbarVisualFixture: NSToolbar?
    private var toolbarCustomizationPanel: NSPanel?
    private var toolbarCustomizationModel: ToolbarCustomizationModel?
    private var compactToolbarGroup: NSStackView?
    private var nativeToolbarThemeTint = NSColor.labelColor
    private var compactToolbarInteractionOpacityHistory: [CGFloat] = []
    private var workspaceContextRefreshGeneration = 0
    private var workspaceContextRefreshWorkItem: DispatchWorkItem?
    private var workspaceResourcesByPane: [String: [WorkspaceOutputResource]] = [:]
    private var workspaceFrameRefreshAfterLiveResize = false
    private var preservedGridRatioDeadline: TimeInterval = 0
    private var preservedGridRatioGeneration = 0
    private var preservedGridRatioResizeWorkItem: DispatchWorkItem?
    private var compactChrome = false
    private var tabPresentationSyncWorkItem: DispatchWorkItem?
    /// Session restore builds every tab before AppDelegate has reconstructed
    /// their owning workspace. Do not let an individual controller present
    /// itself as a standalone sidebar window during that interval.
    private var defersWorkspaceTabPresentation = false
    private var lastPluginFrameEmit = Date.distantPast
    private var pendingPluginFrameEmit: DispatchWorkItem?
    private var paneStateBroadcastWorkItem: DispatchWorkItem?
    private var pendingPaneStateBroadcastIDs = Set<String>()
    private let findBar = FindBar(frame: .zero)
    private let rootViewController = NSViewController()
    private let workspaceSplitController = NSSplitViewController()
    private let workspaceSplitView = ThemedSplitView(frame: .zero)
    private let centerSplitController = NSSplitViewController()
    private let centerSplitView = ThemedSplitView(frame: .zero)
    private let workspaceDividerOverlay = WorkspaceDividerOverlayView(frame: .zero)
    private let embeddedBrowserDividerOverlay = WorkspaceDividerOverlayView(frame: .zero)
    private let workspaceContentView = NSView(frame: .zero)
    private let workspaceContentController = NSViewController()
    private let embeddedBrowserController = EmbeddedChromiumViewController()
    private let navigatorModel = WorkspaceRailModel(side: .navigator)
    private let inspectorModel = WorkspaceRailModel(side: .inspector)
    // Keep collapsed rails AppKit-only. Constructing two SwiftUI hosting trees
    // for every terminal window made hidden Navigator/Inspector rails take
    // part in layout and focus-loop updates across dense window grids.
    private let navigatorController = NSViewController()
    private let inspectorController = NSViewController()
    private var navigatorHostingController:
        NSHostingController<WorkspaceRailView>?
    private var inspectorHostingController:
        NSHostingController<WorkspaceRailView>?
    private var navigatorSplitItem: NSSplitViewItem?
    private var inspectorSplitItem: NSSplitViewItem?
    private var terminalSplitItem: NSSplitViewItem?
    private var workspaceContentSplitItem: NSSplitViewItem?
    private var embeddedBrowserSplitItem: NSSplitViewItem?
    private weak var embeddedBrowserControlBar: ExtensionControlBar?
    private weak var embeddedBrowserControlPane: TerminalPane?
    private struct LiveResizeWorkspaceState {
        let geometry: WorkspaceRailGeometry
        let previousMinimumWidth: CGFloat
    }
    private var liveResizeWorkspaceState: LiveResizeWorkspaceState?
    private(set) var isWorkspaceFocusMode = false
    private struct GitWorkspaceState {
        let cwd: String
        let branch: String
        let changes: [String]
    }
    private var gitWorkspaceState: GitWorkspaceState?
    private var gitWorkspaceRequestCwd: String?
    private var gitWorkspaceGeneration = 0
    private var tabAppearance = TerminalTabAppearance()
    private(set) var lastAppliedChromeAppearanceForTesting:
        ResolvedChromeAppearance?
    private var blurView: NSVisualEffectView?
    private(set) var agentSession: AgentSession?
    private var splitZoomHiddenViews: [NSView] = []
    private var editorWindowCloseApproved = false
    private var windowCloseApproved = false
    private var windowCloseConfirmationPending = false
    private var windowCloseConfirmationAlert: NSAlert?

    func approveNextWindowClose() { windowCloseApproved = true }

    private var workspaceTrailing: NSLayoutConstraint?
    private var workspaceBottom: NSLayoutConstraint?
    private var paneHostTrailing: NSLayoutConstraint?
    /// Theme-colored backing for the plugin dock strip (see applyEdgeInsets).
    private let dockStrip = NSView(frame: .zero)
    private var dockStripWidth: NSLayoutConstraint?
    private var layoutRectObservation: NSKeyValueObservation?
    private var titleLeading: NSLayoutConstraint?
    private var titleTop: NSLayoutConstraint?
    private var titleTrailing: NSLayoutConstraint?
    private var findTop: NSLayoutConstraint?
    private var findTrailing: NSLayoutConstraint?
    private var titleBandHeight: NSLayoutConstraint?
    private var workspaceToolbarHairlineHeight: NSLayoutConstraint?
    private var workspaceRailsVisible = false
    private var workspaceNavigatorVisible = false
    private var workspaceInspectorVisible = false
    private let initialCwd: String?          // new tabs/windows inherit the parent's cwd
    private let startsShells: Bool
    private let borderInset: CGFloat = 27                 // 1px less than the top band

    /// Right-edge strip reserved by a plugin (POST /v1/ui/inset — the chromium
    /// sidecar docks there): panes reflow so terminal text never runs behind
    /// the plugin's overlay window. The static carries the current value to
    /// windows created while the strip is held.
    static var sharedDockInset: CGFloat = 0
    var pluginDockInset: CGFloat = 0 {
        didSet { if pluginDockInset != oldValue { applyDockGeometry(oldInset: oldValue) } }
    }
    /// When a docked plugin hosts a FIXED-SIZE window (the iOS Simulator won't
    /// shrink past a minimum), cmdy GROWS to fit it instead of squeezing it
    /// into a fraction: the window widens by the strip so the terminal keeps
    /// its size, and its height grows to at least this. 0 = don't grow (the
    /// chromium sidecar renders at any size, so it stays inside the window).
    var pluginDockMinHeight: CGFloat = 0 {
        didSet { if pluginDockMinHeight != oldValue { applyDockGeometry(oldInset: pluginDockInset) } }
    }

    /// The window's own size just before a growing dock began — restored on
    /// undock so the terminal returns to how the user had it.
    private var preDockSize: NSSize?

    /// Apply the reserved strip AND, when a fixed-size window is docked, resize
    /// the window to fit it: width = the terminal's own width + the strip, and
    /// height = at least the docked content — both tracked live (the Simulator
    /// resizes via its zoom presets), top-left anchored, and restored on undock.
    private func applyDockGeometry(oldInset: CGFloat) {
        applyEdgeInsets()
        defer {
            // Docking is driven by an external process, outside AppKit's live
            // resize loop. Resolve the new pane/control-bar width immediately
            // so the Browser divider and terminal UI move as one surface.
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
        guard let win = window else { return }
        if pluginDockMinHeight > 0 {
            if preDockSize == nil { preDockSize = win.frame.size }   // remember the terminal-only size
            let base = preDockSize!
            var f = win.frame
            let top = f.maxY                                          // AppKit maxY = the window's TOP
            f.size.width = base.width + pluginDockInset
            // Track the docked window's height exactly — the terminal window
            // sizes itself to the Simulator (grows AND shrinks with it), with
            // a sane floor so the terminal stays usable.
            f.size.height = max(300, pluginDockMinHeight)
            f.origin.y = top - f.size.height                         // keep the top fixed
            // Keep it on screen: slide up/left rather than spill under the Dock.
            if let vis = (win.screen ?? NSScreen.main)?.visibleFrame {
                f.size.height = min(f.size.height, vis.height)
                f.size.width = min(f.size.width, vis.width)
                if f.maxY > vis.maxY { f.origin.y = vis.maxY - f.height }
                if f.minY < vis.minY { f.origin.y = vis.minY }
                if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width }
                if f.minX < vis.minX { f.origin.x = vis.minX }
            }
            if f != win.frame { win.setFrame(f, display: true) }
        } else if let base = preDockSize {
            // Undock: restore the terminal's own size, keeping its top-left.
            var f = win.frame
            let top = f.maxY
            f.size = base
            f.origin.y = top - base.height
            win.setFrame(f, display: true)
            preDockSize = nil
        }
    }

    /// Window margins, native column visibility, and the plugin dock funnel
    /// through one place so preferences and /v1/ui/inset cannot fight.
    private func applyEdgeInsets() {
        let p = Preferences.shared
        let terminalMinimum = p.windowGridEnabled
            ? CGFloat(1) : WorkspaceFrameLayout.minimumTerminalWidth
        terminalSplitItem?.minimumThickness = terminalMinimum
        workspaceContentSplitItem?.minimumThickness = terminalMinimum
        let lr: CGFloat = 0
        let previouslyShowedWorkspaceRails = workspaceRailsVisible
        let windowWidth = container.bounds.width > 0
            ? container.bounds.width : (window?.frame.width ?? 860)
        // Companion space belongs to the terminal column, not to responsive
        // workspace chrome. Attaching Browser or Simulator must never replace
        // an open Navigator with native top tabs or hide the Inspector. Resolve
        // those rails from the unchanged outer window width, then let the dock
        // reservation compress only the remaining terminal content.
        let chromeLayout = WorkspaceFrameLayout.resolve(
            windowWidth: windowWidth,
            navigatorRequested: p.workspaceNavigatorVisible,
            inspectorRequested: p.workspaceInspectorVisible,
            focusMode: isWorkspaceFocusMode)
        let dockAvailableWidth = max(0, windowWidth - pluginDockInset)
        let resolvedLayout = WorkspaceFrameLayout.Result(
            navigatorWidth: chromeLayout.navigatorWidth,
            inspectorWidth: chromeLayout.inspectorWidth,
            terminalWidth: max(
                0,
                dockAvailableWidth
                    - chromeLayout.navigatorWidth
                    - chromeLayout.inspectorWidth))
        let layout: WorkspaceFrameLayout.Result
        if let state = liveResizeWorkspaceState {
            let navigator = state.geometry.navigatorWidth ?? 0
            let inspector = state.geometry.inspectorWidth ?? 0
            let available = max(
                0, windowWidth - pluginDockInset)
            layout = WorkspaceFrameLayout.Result(
                navigatorWidth: navigator,
                inspectorWidth: inspector,
                terminalWidth: max(0, available - navigator - inspector))
        } else {
            layout = resolvedLayout
        }
        // The split shell owns the complete window height. Applying the
        // terminal content margin here leaves a visible strip beneath both
        // native rails.
        workspaceTrailing?.constant = -lr
        workspaceBottom?.constant = 0
        paneHostTrailing?.constant = -pluginDockInset
        dockStripWidth?.constant = pluginDockInset
        applyWorkspaceVisibility(layout)
        workspaceRailsVisible = layout.showsNavigator || layout.showsInspector
        workspaceNavigatorVisible = layout.showsNavigator
        workspaceInspectorVisible = layout.showsInspector
        updateNativeToolbarToggleStates()
        updateWorkspaceToolbarHairlineVisibility()
        if workspaceRailsVisible != previouslyShowedWorkspaceRails {
            updateTopInsets()
        }
        syncTabPresentation(tabSidebarVisible: layout.showsNavigator)
        // The strip covers exactly the reserved inset (the C64 border, when
        // shown, keeps its right edge beyond it).
        dockStrip.isHidden = pluginDockInset == 0
        dockStrip.layer?.backgroundColor = p.theme.ns(p.theme.background).cgColor

        // AppKit owns native titlebar geometry. Window Inset still moves the
        // terminal content, but must not push native chrome around.
        let titleOffset = workspaceNavigatorVisible
            ? 8
            : NativeToolbarPreset.titleLeading(p.nativeToolbarStyle)
        titleLeading?.constant = titleOffset
        titleTop?.constant = NativeToolbarPreset.titleTop(p.nativeToolbarStyle)
        // These controls are anchored to the native content item, so they
        // naturally stop before a resized Inspector or an external dock.
        titleTrailing?.constant = -max(8, lr)
        findTop?.constant = max(0, (topInset - 28) / 2)
        findTrailing?.constant = -max(8, lr)
        let headerHeight = topInset
        titleBandHeight?.constant = headerHeight
        workspaceSplitView.themedDividerTopInset =
            titleBand.isHidden ? 0 : headerHeight
    }

    /// Keep responsive policy separate from split geometry. AppKit owns the
    /// actual widths, dividers, animation, and materials; this policy only
    /// decides which requested columns fit while the terminal keeps 400 pt.
    private func applyWorkspaceVisibility(_ layout: WorkspaceFrameLayout.Result) {
        ensureWorkspaceRailHosts(
            navigator: layout.showsNavigator,
            inspector: layout.showsInspector)
        if let item = navigatorSplitItem, item.isCollapsed != !layout.showsNavigator {
            item.isCollapsed = !layout.showsNavigator
        }
        if let item = inspectorSplitItem, item.isCollapsed != !layout.showsInspector {
            item.isCollapsed = !layout.showsInspector
        }
    }

    private func ensureWorkspaceRailHosts(
        navigator: Bool, inspector: Bool
    ) {
        if navigator, navigatorHostingController == nil {
            let host = NSHostingController(
                rootView: WorkspaceRailView(model: navigatorModel))
            host.sizingOptions = []
            mountWorkspaceRail(host, in: navigatorController)
            navigatorHostingController = host
        }
        if inspector, inspectorHostingController == nil {
            let host = NSHostingController(
                rootView: WorkspaceRailView(model: inspectorModel))
            host.sizingOptions = []
            mountWorkspaceRail(host, in: inspectorController)
            inspectorHostingController = host
        }
    }

    private func mountWorkspaceRail(
        _ host: NSHostingController<WorkspaceRailView>,
        in container: NSViewController
    ) {
        container.addChild(host)
        let view = host.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
    }

    /// The left column and AppKit's tab bar are two presentations of the same
    /// model, never simultaneous chrome. AppDelegate owns the group-wide
    /// bridge because AppKit does not remove its multi-window strip merely
    /// because `isTabBarVisible` is false on current macOS.
    func syncTabPresentation(tabSidebarVisible: Bool? = nil) {
        guard !defersWorkspaceTabPresentation, let window else { return }
        let sidebarVisible = tabSidebarVisible ?? WorkspaceFrameLayout.resolve(
            windowWidth: container.bounds.width > 0 ? container.bounds.width : window.frame.width,
            navigatorRequested: Preferences.shared.workspaceNavigatorVisible,
            inspectorRequested: Preferences.shared.workspaceInspectorVisible,
            focusMode: isWorkspaceFocusMode).showsNavigator
        (NSApp.delegate as? AppDelegate)?
            .setWorkspaceTabSidebar(sidebarVisible, for: self)
    }

    var workspaceChromeVisibility: (navigator: Bool, inspector: Bool) {
        (workspaceNavigatorVisible, workspaceInspectorVisible)
    }

    var isEmbeddedBrowserVisible: Bool {
        embeddedBrowserSplitItem?.isCollapsed == false
    }

    var embeddedBrowserHandle: ChromiumBrowserHandle? {
        embeddedBrowserController.browserHandle
    }

    var embeddedBrowserCaptureRect: NSRect? {
        guard isEmbeddedBrowserVisible else { return nil }
        return embeddedBrowserController.captureRectInWindow
    }

    private func embeddedBrowserRect(in target: NSView) -> NSRect? {
        guard isEmbeddedBrowserVisible,
              let browserRect = embeddedBrowserController.captureRectInWindow
        else { return nil }
        return target.convert(browserRect, from: nil)
    }

    private func refreshEmbeddedBrowserChromeExclusion() {
        titleBand.needsDisplay = true
        workspaceToolbarHairline.needsDisplay = true
        updateNativeToolbarToggleStates()
        applyCompactToolbarTint()
        if let window { window.invalidateCursorRects(for: titleBand) }
    }

    var embeddedBrowserDiagnostic:
        (handle: Bool, attached: Bool, nativeSubviews: Int, pageLoaded: Bool,
         cornerRadius: CGFloat, masksToBounds: Bool, chromeOverlap: CGFloat,
         chromePassthrough: Bool, toolbarOverlapsBrowser: Bool,
         toolbarTintBrightness: CGFloat, toolbarTintMatchesTheme: Bool,
         browserChromeMatchesTheme: Bool,
         topGap: CGFloat, bottomGap: CGFloat, horizontalGap: CGFloat) {
        applyCompactToolbarTint()
        let layout = embeddedBrowserController.layoutDiagnostic
        let overlap: CGFloat
        if let browserRect = embeddedBrowserCaptureRect,
           !titleBand.isHidden {
            let titleRect = titleBand.convert(titleBand.bounds, to: nil)
            let intersection = browserRect.intersection(titleRect)
            overlap = intersection.isNull ? 0 : intersection.height
        } else {
            overlap = 0
        }
        let chromePassthrough: Bool
        if !titleBand.isHidden,
           let browserInBand = embeddedBrowserRect(in: titleBand) {
            let intersection = browserInBand.intersection(titleBand.bounds)
            if intersection.isNull || intersection.isEmpty {
                chromePassthrough = true
            } else {
                chromePassthrough = titleBand.hitTest(NSPoint(
                    x: intersection.midX, y: intersection.midY)) == nil
            }
        } else {
            chromePassthrough = true
        }
        let toolbarTint = compactToolbarGroup?.arrangedSubviews
            .compactMap({ ($0 as? NSButton)?.contentTintColor })
            .first?.usingColorSpace(.deviceRGB)
        let expectedToolbarTint = effectiveCompactToolbarTint()
            .usingColorSpace(.deviceRGB)
        let toolbarTintMatchesTheme = zip(
            [toolbarTint?.redComponent, toolbarTint?.greenComponent,
             toolbarTint?.blueComponent],
            [expectedToolbarTint?.redComponent, expectedToolbarTint?.greenComponent,
             expectedToolbarTint?.blueComponent]
        ).allSatisfy { actual, expected in
            guard let actual, let expected else { return false }
            return abs(actual - expected) < 0.01
        }
        return (
            embeddedBrowserController.browserHandle != nil,
            embeddedBrowserController.isAttachedToCmdyWindow,
            embeddedBrowserController.nativeBrowserSubviewCount,
            !embeddedBrowserController.lastLoadedURL.isEmpty,
            layout.cornerRadius,
            layout.masksToBounds,
            overlap,
            chromePassthrough,
            compactToolbarOverlapsEmbeddedBrowser(),
            toolbarTint?.brightnessComponent ?? 1,
            toolbarTintMatchesTheme,
            embeddedBrowserController.chromeBackground == effectiveTheme.background,
            layout.topGap,
            layout.bottomGap,
            layout.horizontalGap
        )
    }

    var windowInlinePanelDiagnostic:
        (panelWidth: CGFloat, windowWidth: CGFloat,
         panelHeight: CGFloat, isFrontmost: Bool)? {
        guard let panel = windowInlinePanel else { return nil }
        container.layoutSubtreeIfNeeded()
        return (
            panel.frame.width,
            container.bounds.width,
            panel.frame.height,
            container.subviews.last === panel)
    }

    /// Reveal Chromium as a real child split between the terminal and the
    /// outer-right Inspector. This never orders the Cmdy window forward:
    /// background agent navigation must not steal focus or flash over the
    /// user's active application.
    @discardableResult
    func showEmbeddedBrowser(url: String? = nil, focusLocation: Bool = false) -> Bool {
        guard EmbeddedChromiumRuntime.shared.isAvailable,
              let window else { return false }
        let wasCollapsed = embeddedBrowserSplitItem?.isCollapsed == true
        if wasCollapsed {
            embeddedBrowserSplitItem?.isCollapsed = false
            centerSplitView.layoutSubtreeIfNeeded()
            let width = centerSplitView.bounds.width
            if width > 0 {
                let browserWidth = min(
                    max(280, floor(width * 0.46)),
                    max(280, width - WorkspaceFrameLayout.minimumTerminalWidth))
                centerSplitView.setPosition(
                    width - browserWidth - centerSplitView.dividerThickness,
                    ofDividerAt: 0)
            }
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
        updateTopInsets()

        // CEF needs a parent view that is already attached to a native
        // window. A collapsed split item's view has no window yet, so reveal
        // and lay out the item before creating Chromium's child NSView.
        let windowNumber = CGWindowID(window.windowNumber)
        guard embeddedBrowserController.ensureBrowser(
            windowNumber: windowNumber, initialURL: url) else {
            if wasCollapsed {
                embeddedBrowserSplitItem?.isCollapsed = true
                refreshEmbeddedBrowserChromeExclusion()
            }
            return false
        }
        presentEmbeddedBrowserControls(focusLocation: focusLocation)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        refreshEmbeddedBrowserChromeExclusion()
        return true
    }

    func hideEmbeddedBrowser() {
        guard isEmbeddedBrowserVisible else { return }
        embeddedBrowserSplitItem?.isCollapsed = true
        dismissEmbeddedBrowserControls()
        focusedPane?.focus()
        container.needsLayout = true
        refreshEmbeddedBrowserChromeExclusion()
    }

    func toggleEmbeddedBrowser(focusLocation: Bool = false) {
        if PluginManager.shared.runCommand(id: "chromium.toggle") { return }
        if isEmbeddedBrowserVisible {
            hideEmbeddedBrowser()
        } else if !EmbeddedChromiumRuntime.shared.isAvailable {
            BrowserEditionInstaller.presentInstallPrompt(relativeTo: window)
        } else if !showEmbeddedBrowser(focusLocation: focusLocation) {
            NSSound.beep()
        }
    }

    func focusEmbeddedBrowserLocation() {
        if PluginManager.shared.runCommand(id: "chromium.open") { return }
        if isEmbeddedBrowserVisible {
            presentEmbeddedBrowserControls(focusLocation: true)
        } else if !EmbeddedChromiumRuntime.shared.isAvailable {
            BrowserEditionInstaller.presentInstallPrompt(relativeTo: window)
        } else if !showEmbeddedBrowser(focusLocation: true) {
            NSSound.beep()
        }
    }

    func reloadEmbeddedBrowser() {
        if PluginManager.shared.runCommand(id: "chromium.reload") { return }
        guard EmbeddedChromiumRuntime.shared.isAvailable else {
            BrowserEditionInstaller.presentInstallPrompt(relativeTo: window)
            return
        }
        guard showEmbeddedBrowser() else {
            NSSound.beep()
            return
        }
        embeddedBrowserController.reload()
    }

    func openEmbeddedBrowserDevTools() {
        if PluginManager.shared.runCommand(id: "chromium.devtools") { return }
        guard EmbeddedChromiumRuntime.shared.isAvailable else {
            BrowserEditionInstaller.presentInstallPrompt(relativeTo: window)
            return
        }
        guard showEmbeddedBrowser() else {
            NSSound.beep()
            return
        }
        embeddedBrowserController.openDevTools()
    }

    private func presentEmbeddedBrowserControls(focusLocation: Bool) {
        guard let pane = focusedPane else { return }
        if let oldPane = embeddedBrowserControlPane,
           let oldBar = embeddedBrowserControlBar,
           oldPane !== pane {
            oldPane.dismissExtensionControlBar(oldBar)
        }
        let bar = pane.presentExtensionControlBar()
        bar.configure(
            actions: [
                BottomMenuItem(id: "back", title: "←"),
                BottomMenuItem(id: "forward", title: "→"),
                BottomMenuItem(id: "reload", title: "Reload"),
                BottomMenuItem(id: "close", title: "Close"),
            ],
            placeholder: "enter URL or search", value: "", inputFirst: true)
        bar.onAction = { [weak self] action in
            switch action {
            case "back": self?.embeddedBrowserController.goBack()
            case "forward": self?.embeddedBrowserController.goForward()
            case "reload": self?.embeddedBrowserController.reload()
            case "close": self?.hideEmbeddedBrowser()
            default: break
            }
        }
        bar.onSubmit = { [weak self] address in
            self?.embeddedBrowserController.navigate(to: address)
        }
        bar.onEscape = { [weak pane] in pane?.focus() }
        embeddedBrowserController.onPageLoaded = { [weak bar] url in
            let shown = url.hasPrefix("file:")
                && url.contains(
                    "\(ProductIdentity.current.slug)-start.html") ? "" : url
            bar?.setValue(shown)
        }
        embeddedBrowserControlPane = pane
        embeddedBrowserControlBar = bar
        if focusLocation { pane.focusExtensionControlBar(bar) }
    }

    private func dismissEmbeddedBrowserControls() {
        guard let pane = embeddedBrowserControlPane,
              let bar = embeddedBrowserControlBar else { return }
        pane.dismissExtensionControlBar(bar)
        embeddedBrowserControlPane = nil
        embeddedBrowserControlBar = nil
    }

    func finishDeferredWorkspaceTabPresentation() {
        guard defersWorkspaceTabPresentation else { return }
        defersWorkspaceTabPresentation = false
        syncTabPresentation()
    }

    /// Sidebar-mode tabs are separate NSWindows while inactive. Copy the
    /// visible split geometry before revealing another one so switching tabs
    /// changes content only, never the Navigator/Inspector widths.
    func workspaceRailGeometry() -> WorkspaceRailGeometry {
        workspaceSplitView.layoutSubtreeIfNeeded()
        return WorkspaceRailGeometry(
            navigatorWidth: navigatorSplitItem?.isCollapsed == false
                ? navigatorController.view.frame.width : nil,
            inspectorWidth: inspectorSplitItem?.isCollapsed == false
                ? inspectorController.view.frame.width : nil)
    }

    /// Screen-space drop target for a sidebar-tab drag. Restricting the area
    /// dropper to the center workspace keeps a drag that is still over the
    /// Navigator, Inspector, or title band from accidentally becoming a split.
    var workspaceDockTargetScreenFrame: NSRect? {
        guard let window else { return nil }
        workspaceContentView.layoutSubtreeIfNeeded()
        let inWindow = workspaceContentView.convert(
            workspaceContentView.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    func applyWorkspaceRailGeometry(_ geometry: WorkspaceRailGeometry) {
        window?.contentView?.layoutSubtreeIfNeeded()
        workspaceSplitView.layoutSubtreeIfNeeded()
        let width = workspaceSplitView.bounds.width
        guard width > 0 else { return }

        if let navigatorWidth = geometry.navigatorWidth,
           navigatorSplitItem?.isCollapsed == false {
            workspaceSplitView.setPosition(
                navigatorWidth, ofDividerAt: 0)
        }
        if let inspectorWidth = geometry.inspectorWidth,
           inspectorSplitItem?.isCollapsed == false {
            workspaceSplitView.setPosition(
                width - inspectorWidth - workspaceSplitView.dividerThickness,
                ofDividerAt: 1)
        }
        workspaceSplitView.layoutSubtreeIfNeeded()
    }

    /// Persist a direct divider gesture across the hidden NSWindows that back
    /// sidebar tabs. The next tab should inherit the new widths, not reveal
    /// the geometry it had before the drag.
    func workspaceDividerDragDidEnd() {
        (NSApp.delegate as? AppDelegate)?
            .synchronizeWorkspaceTabFrames(from: self)
        NotificationCenter.default.post(
            name: .cmdyWorkspaceFrameChanged, object: self)
    }

    /// Drive the real overlay gesture for the packaged UI regression smoke.
    /// This intentionally uses mouse events instead of setting split positions
    /// directly so the opposite-rail preservation path is covered.
    func performNavigatorDividerResizeSmokeTest(delta: CGFloat)
        -> (navigatorBefore: CGFloat, navigatorAfter: CGFloat,
            inspectorCollapsed: Bool, inspectorSplitSubviewHidden: Bool)? {
        guard let window,
              let dividerRect = workspaceSplitView.interactiveDividerRect(at: 0)
        else { return nil }
        workspaceSplitView.layoutSubtreeIfNeeded()
        let before = navigatorController.view.frame.width
        let startInSplit = NSPoint(
            x: dividerRect.midX, y: dividerRect.midY)
        let startInWindow = workspaceSplitView.convert(startInSplit, to: nil)

        func mouseEvent(
            _ type: NSEvent.EventType, at point: NSPoint
        ) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
        }

        guard let down = mouseEvent(.leftMouseDown, at: startInWindow),
              let drag = mouseEvent(
                .leftMouseDragged,
                at: NSPoint(
                    x: startInWindow.x + delta, y: startInWindow.y)),
              let up = mouseEvent(
                .leftMouseUp,
                at: NSPoint(
                    x: startInWindow.x + delta, y: startInWindow.y))
        else { return nil }
        workspaceDividerOverlay.mouseDown(with: down)
        workspaceDividerOverlay.mouseDragged(with: drag)
        workspaceDividerOverlay.mouseUp(with: up)
        workspaceSplitView.layoutSubtreeIfNeeded()

        return (
            navigatorBefore: before,
            navigatorAfter: navigatorController.view.frame.width,
            inspectorCollapsed: inspectorSplitItem?.isCollapsed == true,
            inspectorSplitSubviewHidden:
                workspaceSplitView.subviews.last?.isHidden == true)
    }

    /// Start outside the one-point painted separator and drive the real
    /// overlay gesture. Chromium hosts a native child view, so this catches the
    /// regression where the split view knew about a larger target but never
    /// received the mouse event above that child.
    func performEmbeddedBrowserDividerResizeSmokeTest(delta: CGFloat)
        -> (browserBefore: CGFloat, browserAfter: CGFloat,
            expandedTargetCaptured: Bool, targetWidth: CGFloat)? {
        guard let window, isEmbeddedBrowserVisible else { return nil }
        centerSplitView.layoutSubtreeIfNeeded()
        guard let targetRect = centerSplitView.interactiveDividerRect(at: 0),
              let paintedRect = centerSplitView.drawnDividerRect(at: 0)
        else { return nil }

        let targetInOverlay = embeddedBrowserDividerOverlay.convert(
            targetRect, from: centerSplitView)
        let paintedInOverlay = embeddedBrowserDividerOverlay.convert(
            paintedRect, from: centerSplitView)
        let probeInOverlay = NSPoint(
            x: targetInOverlay.minX + 1,
            y: targetInOverlay.midY)
        let startInWindow = embeddedBrowserDividerOverlay.convert(
            probeInOverlay, to: nil)
        let probeInContent = window.contentView?.convert(startInWindow, from: nil)
        let capturedOverlay = probeInContent.flatMap {
            window.contentView?.hitTest($0) as? WorkspaceDividerOverlayView
        }
        let expandedTargetCaptured =
            !paintedInOverlay.contains(probeInOverlay)
            && capturedOverlay === embeddedBrowserDividerOverlay
        let before = embeddedBrowserController.view.frame.width

        // The outer-rail smoke covers WorkspaceDividerOverlayView's real
        // mouse gesture. Here the Browser-specific regression is that CEF's
        // native child wins the initial hit. Prove the root window selects our
        // off-hairline overlay, then separately prove this split accepts the
        // same resize; synthetic NSEvents do not retain AppKit mouse capture
        // between calls on headless CI.
        if expandedTargetCaptured {
            centerSplitView.setPosition(
                paintedRect.minX + delta, ofDividerAt: 0)
        }
        centerSplitView.layoutSubtreeIfNeeded()

        return (
            browserBefore: before,
            browserAfter: embeddedBrowserController.view.frame.width,
            expandedTargetCaptured: expandedTargetCaptured,
            targetWidth: targetRect.width)
    }

    /// Adding or tearing out a native tab changes AppKit's bar after the key
    /// window callback. Reconcile once more after that system animation settles.
    func scheduleTabPresentationSync() {
        tabPresentationSyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.tabPresentationSyncWorkItem = nil
            self?.syncTabPresentation()
        }
        tabPresentationSyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Keep a tiny terminal useful: once the window is shorter than the
    /// compact breakpoint, remove the complete title strip and let row zero
    /// use that space. Preferences are not changed, so expanding restores the
    /// user's chosen chrome immediately.
    private func applyChromeVisibility() {
        guard let window else { return }
        let p = Preferences.shared
        let showTitle = !compactChrome
        let showButtons = !compactChrome && !p.hideTrafficLights

        titleLabel.isHidden = !showTitle
        if compactChrome { titleLabel.stringValue = "" }
        titleBand.isHidden = !showTitle && !showButtons
        updateWorkspaceToolbarHairlineVisibility()

        if !compactChrome {
            let toolbar = nativeToolbarVisualFixture ?? nativeToolbar
            if window.toolbar !== toolbar { window.toolbar = toolbar }
            ensureNativeToolbarTrailingAlignment(toolbar)
            window.toolbarStyle = NativeToolbarPreset.appKitStyle(p.nativeToolbarStyle)
        } else if window.toolbar === (nativeToolbarVisualFixture ?? nativeToolbar) {
            window.toolbar = nil
        }
        updateCompactToolbarGroupVisibility()
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = !showButtons
        }
    }

    private func updateCompactChrome() {
        guard let window else { return }
        let next = WindowChromeLayout.isCompact(windowHeight: window.frame.height)
            || (Preferences.shared.windowGridEnabled
                && window.frame.width < 220)
        guard next != compactChrome else { return }
        compactChrome = next
        applyChromeVisibility()
        if !next { updateWindowTitle() }
        container.needsLayout = true
    }

    /// Geometry a docking plugin needs to line its window up with the pane
    /// area: offsets from the window's top/bottom edges to the pane host, and
    /// the exposed edge plus any right-side workspace rail (all points, screen
    /// scale independent).
    var dockGeometry: [String: Any] {
        guard let win = window else { return [:] }
        let f = paneHost.convert(paneHost.bounds, to: nil)
        let content = workspaceContentView.convert(
            workspaceContentView.bounds, to: nil)
        return ["top": Double(win.frame.height - f.maxY),
                "bottom": Double(f.minY),
                "side": 0,
                "trailing": Double(max(0, win.frame.width - content.maxX))]
    }
    private var topInset: CGFloat {
        let p = Preferences.shared
        return NativeToolbarPreset.titleBandHeight(p.nativeToolbarStyle)
    }
    /// Compact custom title drawn in the top band (smaller than the system title).
    private let titleLabel = NSTextField(
        labelWithString: ProductIdentity.current.displayName)
    private let inspectorTitleLabel = NSTextField(labelWithString: "Inspector")
    private lazy var nativeToolbar: NSToolbar = {
        let toolbar = CompactNativeToolbar(
            identifier: "\(ProductIdentity.current.slug).native.window")
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.customizationHandler = { [weak self] sender in
            self?.customizeNativeToolbar(sender)
        }
        return toolbar
    }()

    private enum NativeToolbarItem {
        private static let prefix = ProductIdentity.current.slug + ".toolbar."
        static let iconPointSize: CGFloat = 13
        static let newWindow = NSToolbarItem.Identifier(prefix + "new-window")
        static let newTab = NSToolbarItem.Identifier(prefix + "new-tab")
        static let close = NSToolbarItem.Identifier(prefix + "close")
        static let navigator = NSToolbarItem.Identifier(prefix + "navigator")
        static let inspector = NSToolbarItem.Identifier(prefix + "inspector")
        static let browser = NSToolbarItem.Identifier(prefix + "browser")
        static let browserLocation = NSToolbarItem.Identifier(prefix + "browser-location")
        static let browserReload = NSToolbarItem.Identifier(prefix + "browser-reload")
        static let browserDevTools = NSToolbarItem.Identifier(prefix + "browser-dev-tools")
        static let splitRight = NSToolbarItem.Identifier(prefix + "split-right")
        static let splitDown = NSToolbarItem.Identifier(prefix + "split-down")
        static let focusPrevious = NSToolbarItem.Identifier(prefix + "focus-previous-pane")
        static let focusNext = NSToolbarItem.Identifier(prefix + "focus-next-pane")
        static let equalizeSplits = NSToolbarItem.Identifier(prefix + "equalize-splits")
        static let zoomPane = NSToolbarItem.Identifier(prefix + "zoom-pane")
        static let breakWindow = NSToolbarItem.Identifier(prefix + "break-window")
        static let breakTab = NSToolbarItem.Identifier(prefix + "break-tab")
        static let mergeSplits = NSToolbarItem.Identifier(prefix + "merge-splits")
        static let find = NSToolbarItem.Identifier(prefix + "find")
        static let previousCommand = NSToolbarItem.Identifier(prefix + "previous-command")
        static let nextCommand = NSToolbarItem.Identifier(prefix + "next-command")
        static let copyOutput = NSToolbarItem.Identifier(prefix + "copy-output")
        static let explain = NSToolbarItem.Identifier(prefix + "explain")
        static let clearBuffer = NSToolbarItem.Identifier(prefix + "clear-buffer")
        static let attention = NSToolbarItem.Identifier(prefix + "attention")
        static let focusMode = NSToolbarItem.Identifier(prefix + "focus-mode")
        static let palette = NSToolbarItem.Identifier(prefix + "palette")
        static let mixer = NSToolbarItem.Identifier(prefix + "mixer")
        static let themes = NSToolbarItem.Identifier(prefix + "themes")
        static let fonts = NSToolbarItem.Identifier(prefix + "fonts")
        static let shaders = NSToolbarItem.Identifier(prefix + "shaders")
        static let cursors = NSToolbarItem.Identifier(prefix + "cursors")
        static let smallerText = NSToolbarItem.Identifier(prefix + "smaller-text")
        static let largerText = NSToolbarItem.Identifier(prefix + "larger-text")
        static let extensions = NSToolbarItem.Identifier(prefix + "extensions")
        static let channels = NSToolbarItem.Identifier(prefix + "channels")
        static let doctor = NSToolbarItem.Identifier(prefix + "doctor")
        static let settings = NSToolbarItem.Identifier(prefix + "settings")
        static let agent = NSToolbarItem.Identifier(prefix + "agent")
        static let compose = NSToolbarItem.Identifier(prefix + "compose")
        static let fullScreen = NSToolbarItem.Identifier(prefix + "full-screen")

        static let allowed: [NSToolbarItem.Identifier] = [
            newWindow, newTab, close,
            navigator, inspector,
            browser, browserLocation, browserReload, browserDevTools,
            splitRight, splitDown, focusPrevious, focusNext, equalizeSplits,
            zoomPane, breakWindow, breakTab, mergeSplits,
            find, previousCommand, nextCommand, copyOutput, explain, clearBuffer,
            attention, focusMode, palette,
            mixer, themes, fonts, shaders, cursors, smallerText, largerText,
            extensions, channels, doctor, settings,
            agent, compose, fullScreen,
            .space, .flexibleSpace,
        ]

        static let recommended: [NSToolbarItem.Identifier] = [
            .flexibleSpace,
            navigator,
            browser,
            splitRight,
            splitDown,
            inspector,
        ]

        static var customCount: Int {
            allowed.filter { $0 != .space && $0 != .flexibleSpace }.count
        }

    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier] {
        NativeToolbarItem.allowed
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier] {
        // A small, useful fresh-user set: navigation, cmdy's signature browser,
        // spatial pane controls, and context. Existing autosaved layouts remain
        // untouched. The leading spring keeps the group at the trailing edge.
        NativeToolbarItem.recommended
    }

    private func toolbarDefinition(
        for identifier: NSToolbarItem.Identifier
    ) -> (label: String, symbol: String, palette: String)? {
        let definition: (label: String, symbol: String, palette: String)?
        switch identifier {
        case NativeToolbarItem.newWindow:
            definition = ("New Window", "macwindow.badge.plus", "New Window")
        case NativeToolbarItem.newTab:
            definition = ("New Tab", "plus.square.on.square", "New Tab")
        case NativeToolbarItem.close:
            definition = ("Close", "xmark", "Close Pane, Tab, or Window")
        case NativeToolbarItem.navigator:
            definition = ("Sidebar", "sidebar.left", "Show or Hide Sidebar")
        case NativeToolbarItem.inspector:
            definition = ("Inspector", "sidebar.right", "Show or Hide Inspector")
        case NativeToolbarItem.browser:
            definition = ("Browser", "globe", "Show or Hide Browser")
        case NativeToolbarItem.browserLocation:
            definition = ("Open URL", "location.magnifyingglass", "Open Browser URL")
        case NativeToolbarItem.browserReload:
            definition = ("Reload", "arrow.clockwise", "Reload Browser")
        case NativeToolbarItem.browserDevTools:
            definition = ("DevTools", "wrench.and.screwdriver", "Browser Developer Tools")
        case NativeToolbarItem.splitRight:
            definition = ("Split Right", "rectangle.split.2x1", "Split Right")
        case NativeToolbarItem.splitDown:
            definition = ("Split Down", "rectangle.split.1x2", "Split Down")
        case NativeToolbarItem.focusPrevious:
            definition = ("Previous Pane", "chevron.left", "Focus Previous Pane")
        case NativeToolbarItem.focusNext:
            definition = ("Next Pane", "chevron.right", "Focus Next Pane")
        case NativeToolbarItem.equalizeSplits:
            definition = ("Equalize", "rectangle.split.3x1", "Equalize Splits")
        case NativeToolbarItem.zoomPane:
            definition = ("Zoom Pane", "rectangle.inset.filled", "Zoom Focused Pane")
        case NativeToolbarItem.breakWindow:
            definition = ("Detach", "macwindow.on.rectangle", "Break Pane into Window")
        case NativeToolbarItem.breakTab:
            definition = ("Move to Tab", "square.on.square", "Break Pane into Tab")
        case NativeToolbarItem.mergeSplits:
            definition = ("Merge", "rectangle.3.group", "Merge Windows into Splits")
        case NativeToolbarItem.find:
            definition = ("Find", "magnifyingglass", "Find")
        case NativeToolbarItem.previousCommand:
            definition = ("Previous Command", "chevron.up", "Previous Command")
        case NativeToolbarItem.nextCommand:
            definition = ("Next Command", "chevron.down", "Next Command")
        case NativeToolbarItem.copyOutput:
            definition = ("Copy Output", "doc.on.doc", "Copy Last Command Output")
        case NativeToolbarItem.explain:
            definition = ("Explain", "sparkles", "Explain Last Command")
        case NativeToolbarItem.clearBuffer:
            definition = ("Clear", "eraser", "Clear Terminal Buffer")
        case NativeToolbarItem.attention:
            definition = ("Attention", "bell.badge", "Jump to Attention")
        case NativeToolbarItem.focusMode:
            definition = ("Focus", "scope", "Focus Mode")
        case NativeToolbarItem.palette:
            definition = ("Commands", "command", "Command Palette")
        case NativeToolbarItem.mixer:
            definition = ("Mixer", "slider.horizontal.3", "Config Mixer")
        case NativeToolbarItem.themes:
            definition = ("Themes", "paintpalette", "Browse Themes")
        case NativeToolbarItem.fonts:
            definition = ("Fonts", "textformat", "Browse Fonts")
        case NativeToolbarItem.shaders:
            definition = ("Shaders", "wand.and.stars", "Browse Shaders")
        case NativeToolbarItem.cursors:
            definition = ("Cursors", "cursorarrow", "Browse Cursors")
        case NativeToolbarItem.smallerText:
            definition = ("Smaller Text", "textformat.size.smaller", "Decrease Text Size")
        case NativeToolbarItem.largerText:
            definition = ("Larger Text", "textformat.size.larger", "Increase Text Size")
        case NativeToolbarItem.extensions:
            definition = ("Extensions", "puzzlepiece.extension", "Extensions")
        case NativeToolbarItem.channels:
            definition = ("Channels", "point.3.connected.trianglepath.dotted", "Channels")
        case NativeToolbarItem.doctor:
            definition = ("Doctor", "stethoscope", "Integration Doctor")
        case NativeToolbarItem.settings:
            definition = ("Settings", "gearshape", "Open Settings")
        case NativeToolbarItem.agent:
            definition = ("Agent", "person.crop.circle.badge.plus", "Agent Mode")
        case NativeToolbarItem.compose:
            definition = ("Compose", "text.cursor", "Compose Command with AI")
        case NativeToolbarItem.fullScreen:
            definition = ("Full Screen", "arrow.up.left.and.arrow.down.right", "Full Screen")
        default:
            definition = nil
        }
        return definition
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let definition = toolbarDefinition(for: identifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = definition.label
        item.paletteLabel = definition.palette
        item.toolTip = definition.palette
        let image = NSImage(systemSymbolName: definition.symbol,
                            accessibilityDescription: definition.palette)
        let configuredImage = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: NativeToolbarItem.iconPointSize, weight: .regular))
        item.image = configuredImage
        item.target = self
        item.action = #selector(performNativeToolbarAction(_:))
        item.isBordered = false
        // AppKit temporarily reveals the real NSToolbar items while its
        // customization palette is open. Give those items the exact same
        // compact control used by cmdy's title-band overlay so adding or
        // removing a tool cannot fan the icons back across the window.
        item.view = makeCompactToolbarButton(for: identifier)
        return item
    }

    @objc private func performNativeToolbarAction(_ sender: NSToolbarItem) {
        let identifier = sender.itemIdentifier
        let app = NSApp.delegate as? AppDelegate
        switch identifier {
        case NativeToolbarItem.newWindow: app?.newWindow(sender)
        case NativeToolbarItem.newTab: app?.newTab(attachedTo: window)
        case NativeToolbarItem.close: closePaneOrWindow()
        case NativeToolbarItem.navigator: toggleNavigator()
        case NativeToolbarItem.inspector: showInspector()
        case NativeToolbarItem.browser: toggleEmbeddedBrowser()
        case NativeToolbarItem.browserLocation: focusEmbeddedBrowserLocation()
        case NativeToolbarItem.browserReload: reloadEmbeddedBrowser()
        case NativeToolbarItem.browserDevTools: openEmbeddedBrowserDevTools()
        case NativeToolbarItem.splitRight: splitFocusedPane(vertical: true)
        case NativeToolbarItem.splitDown: splitFocusedPane(vertical: false)
        case NativeToolbarItem.focusPrevious: focusNextPane(offset: -1)
        case NativeToolbarItem.focusNext: focusNextPane(offset: 1)
        case NativeToolbarItem.equalizeSplits: equalizeSplits()
        case NativeToolbarItem.zoomPane: toggleSplitZoom()
        case NativeToolbarItem.breakWindow: breakOutFocusedPane(asTab: false)
        case NativeToolbarItem.breakTab: breakOutFocusedPane(asTab: true)
        case NativeToolbarItem.mergeSplits: mergeAllWindowsIntoSplits()
        case NativeToolbarItem.find: showFindBar()
        case NativeToolbarItem.previousCommand: jumpToPreviousPrompt()
        case NativeToolbarItem.nextCommand: jumpToNextPrompt()
        case NativeToolbarItem.copyOutput: copyLastCommandOutput()
        case NativeToolbarItem.explain: explainLastCommand()
        case NativeToolbarItem.clearBuffer: clearBuffer()
        case NativeToolbarItem.attention: app?.jumpToAttention(sender)
        case NativeToolbarItem.focusMode: toggleFocusMode()
        case NativeToolbarItem.palette: app?.showPalette(sender)
        case NativeToolbarItem.mixer: app?.showConfigMixer(sender)
        case NativeToolbarItem.themes: app?.browseThemes(sender)
        case NativeToolbarItem.fonts: app?.browseFonts(sender)
        case NativeToolbarItem.shaders: app?.browseShaders(sender)
        case NativeToolbarItem.cursors: app?.browseCursors(sender)
        case NativeToolbarItem.smallerText: app?.decreaseFontSize(sender)
        case NativeToolbarItem.largerText: app?.increaseFontSize(sender)
        case NativeToolbarItem.extensions: app?.showPlugins(sender)
        case NativeToolbarItem.channels: app?.showChannelManager(sender)
        case NativeToolbarItem.doctor: app?.showIntegrationDoctor(sender)
        case NativeToolbarItem.settings: app?.openConfig(sender)
        case NativeToolbarItem.agent: startAgent()
        case NativeToolbarItem.compose: composeWithAI()
        case NativeToolbarItem.fullScreen: window?.toggleFullScreen(sender)
        default: break
        }
        // Preference-backed rails update on the next run-loop turn; mirror
        // that timing so toggle tiles always describe the resulting UI.
        DispatchQueue.main.async { [weak self] in
            self?.updateNativeToolbarToggleStates()
        }
    }

    /// Keep customized items as a compact trailing group. AppKit still owns
    /// insertion, removal, persistence, and the Finder-style palette; this
    /// only maintains the one layout invariant cmdy promises.
    private func ensureNativeToolbarTrailingAlignment(_ toolbar: NSToolbar? = nil) {
        let toolbar = toolbar ?? nativeToolbar
        guard !isNormalizingNativeToolbar else { return }
        let flexibleIndices = toolbar.items.indices.filter {
            toolbar.items[$0].itemIdentifier == .flexibleSpace
        }
        let alreadyNormalized = flexibleIndices == [0]
            && !toolbar.items.dropFirst().contains(where: {
                $0.itemIdentifier == .space
            })
        guard !alreadyNormalized else { return }
        isNormalizingNativeToolbar = true
        for index in toolbar.items.indices.reversed() where
            toolbar.items[index].itemIdentifier == .flexibleSpace
                || toolbar.items[index].itemIdentifier == .space {
            toolbar.removeItem(at: index)
        }
        toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
        isNormalizingNativeToolbar = false
    }

    private func makeCompactToolbarButton(
        for identifier: NSToolbarItem.Identifier
    ) -> NSButton? {
        guard let definition = toolbarDefinition(for: identifier),
              let image = NSImage(
                systemSymbolName: definition.symbol,
                accessibilityDescription: definition.palette)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(
                    pointSize: NativeToolbarItem.iconPointSize,
                    weight: .regular))
        else { return nil }
        let button = CompactToolbarButton(
            image: image,
            target: self,
            action: #selector(performCompactToolbarAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(identifier.rawValue)
        button.isBordered = false
        button.bezelStyle = .inline
        button.controlSize = .mini
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = definition.palette
        button.setAccessibilityLabel(definition.palette)
        button.isToggledOn = isNativeToolbarItemToggled(identifier)
        button.onInteractionOpacityChange = { [weak self] opacity in
            guard let self,
                  compactToolbarInteractionOpacityHistory.last != opacity
            else { return }
            compactToolbarInteractionOpacityHistory.append(opacity)
            if compactToolbarInteractionOpacityHistory.count > 12 {
                compactToolbarInteractionOpacityHistory.removeFirst(
                    compactToolbarInteractionOpacityHistory.count - 12)
            }
        }
        button.prepareInteractionOpacity()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required,
                                                       for: .horizontal)
        button.setContentCompressionResistancePriority(.required,
                                                       for: .vertical)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant:
                                            CompactToolbarButton.side),
            button.heightAnchor.constraint(equalToConstant:
                                             CompactToolbarButton.side),
        ])
        return button
    }

    private func setupCompactToolbarGroup() {
        let group = CompactToolbarStackView()
        group.orientation = .horizontal
        group.alignment = .centerY
        group.distribution = .gravityAreas
        group.spacing = 6
        group.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(group, positioned: .above, relativeTo: titleBand)
        NSLayoutConstraint.activate([
            group.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                            constant: -11),
            group.centerYAnchor.constraint(equalTo: titleBand.centerYAnchor),
        ])
        compactToolbarGroup = group
        rebuildCompactToolbarGroup(from: nativeToolbar)
    }

    private func rebuildCompactToolbarGroup(from toolbar: NSToolbar) {
        guard let group = compactToolbarGroup else { return }
        let identifiers = toolbar.items.compactMap { item -> NSToolbarItem.Identifier? in
            let identifier = item.itemIdentifier
            guard identifier != .space, identifier != .flexibleSpace else {
                return nil
            }
            return identifier
        }
        let currentIdentifiers = group.arrangedSubviews.compactMap {
            ($0 as? NSButton).flatMap { button in
                button.identifier.map {
                    NSToolbarItem.Identifier($0.rawValue)
                }
            }
        }
        // NSToolbar emits several add/remove notifications while restoring or
        // normalizing one saved layout. Replacing an NSButton between its
        // mouse-down and mouse-up drops the click. Preserve the live controls
        // when their semantic item sequence did not actually change.
        guard currentIdentifiers != identifiers else {
            updateNativeToolbarToggleStates()
            return
        }
        for view in group.arrangedSubviews {
            group.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for identifier in identifiers {
            if let button = makeCompactToolbarButton(for: identifier) {
                group.addArrangedSubview(button)
            }
        }
        updateNativeToolbarToggleStates()
    }

    private func isNativeToolbarItemToggled(
        _ identifier: NSToolbarItem.Identifier
    ) -> Bool {
        switch identifier {
        case NativeToolbarItem.navigator:
            return workspaceNavigatorVisible
        case NativeToolbarItem.inspector:
            return workspaceInspectorVisible
        case NativeToolbarItem.browser:
            return isEmbeddedBrowserVisible
        case NativeToolbarItem.focusMode:
            return isWorkspaceFocusMode
        case NativeToolbarItem.zoomPane:
            return !splitZoomHiddenViews.isEmpty
        case NativeToolbarItem.find:
            return !findBar.isHidden
        case NativeToolbarItem.fullScreen:
            return window?.styleMask.contains(.fullScreen) == true
        case NativeToolbarItem.agent:
            return agentSession != nil
        default:
            return false
        }
    }

    private func updateNativeToolbarToggleStates() {
        let update: (CompactToolbarButton) -> Void = { [weak self] button in
            guard let self, let raw = button.identifier?.rawValue else { return }
            let identifier = NSToolbarItem.Identifier(raw)
            button.isToggledOn = self.isNativeToolbarItemToggled(identifier)
            if identifier == NativeToolbarItem.browser {
                let description = EmbeddedChromiumRuntime.shared.isAvailable
                    || PluginManager.shared.hasCommand(id: "chromium.toggle")
                    ? "Show or Hide Browser"
                    : "Browser is not installed — click to install"
                button.toolTip = description
                button.setAccessibilityLabel(description)
            }
        }
        compactToolbarGroup?.arrangedSubviews
            .compactMap { $0 as? CompactToolbarButton }
            .forEach(update)
        [nativeToolbar, nativeToolbarVisualFixture].compactMap { $0 }
            .flatMap(\.items)
            .compactMap { $0.view as? CompactToolbarButton }
            .forEach(update)
    }

    func browserInstallToolbarDiagnosticForTesting() -> (
        present: Bool, tooltip: String?, accessibilityLabel: String?,
        toggled: Bool
    ) {
        updateNativeToolbarToggleStates()
        let button = compactToolbarGroup?.arrangedSubviews
            .compactMap { $0 as? CompactToolbarButton }
            .first {
                $0.identifier?.rawValue == NativeToolbarItem.browser.rawValue
            }
        return (
            button != nil,
            button?.toolTip,
            button?.accessibilityLabel(),
            button?.isToggledOn ?? false)
    }

    @discardableResult
    func activateBrowserToolbarForTesting() -> Bool {
        guard let button = compactToolbarGroup?.arrangedSubviews
            .compactMap({ $0 as? CompactToolbarButton })
            .first(where: {
                $0.identifier?.rawValue == NativeToolbarItem.browser.rawValue
            }) else { return false }
        button.performClick(nil)
        return true
    }

    @objc private func performCompactToolbarAction(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue else { return }
        let item = NSToolbarItem(
            itemIdentifier: NSToolbarItem.Identifier(rawValue))
        performNativeToolbarAction(item)
    }

    private func updateCompactToolbarGroupVisibility() {
        guard let group = compactToolbarGroup else { return }
        let toolbar = window?.toolbar ?? nativeToolbar
        rebuildCompactToolbarGroup(from: toolbar)
        let useCompactGroup = !compactChrome
            && !toolbar.customizationPaletteIsRunning
        group.isHidden = !useCompactGroup
        // Hiding only the stack leaves its required 24 pt arranged-subview
        // constraints in the window's fitting size. Collapse the items too so
        // a narrow grid tile is not clamped to the toolbar's former width.
        group.arrangedSubviews.forEach { $0.isHidden = !useCompactGroup }
        applyCompactToolbarTint()
        toolbar.isVisible = true
        for item in toolbar.items where item.itemIdentifier != .flexibleSpace {
            item.isHidden = useCompactGroup
        }
    }

    private func monitorNativeToolbarCustomization(_ toolbar: NSToolbar? = nil) {
        let toolbar = toolbar ?? window?.toolbar ?? nativeToolbar
        guard toolbar.customizationPaletteIsRunning else {
            updateCompactToolbarGroupVisibility()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            [weak self, weak toolbar] in
            guard let toolbar else { return }
            self?.monitorNativeToolbarCustomization(toolbar)
        }
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard let toolbar = notification.object as? NSToolbar else { return }
        DispatchQueue.main.async { [weak self, weak toolbar] in
            guard let toolbar else { return }
            self?.ensureNativeToolbarTrailingAlignment(toolbar)
            self?.updateCompactToolbarGroupVisibility()
            self?.synchronizeToolbarCustomizationModel(with: toolbar)
        }
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        guard let toolbar = notification.object as? NSToolbar else { return }
        DispatchQueue.main.async { [weak self, weak toolbar] in
            guard let toolbar else { return }
            self?.ensureNativeToolbarTrailingAlignment(toolbar)
            self?.updateCompactToolbarGroupVisibility()
            self?.synchronizeToolbarCustomizationModel(with: toolbar)
        }
    }

    @objc func customizeNativeToolbar(_ sender: Any?) {
        guard !compactChrome else { NSSound.beep(); return }
        if let panel = toolbarCustomizationPanel, panel.isVisible {
            panel.makeKeyAndOrderFront(sender)
            return
        }
        guard let parent = window else { return }
        let toolbar = nativeToolbarVisualFixture ?? nativeToolbar
        if parent.toolbar !== toolbar {
            parent.toolbar = toolbar
        }
        ensureNativeToolbarTrailingAlignment(toolbar)
        updateCompactToolbarGroupVisibility()

        let selected = selectedToolbarIdentifiers(in: toolbar)
        let options = NativeToolbarItem.allowed.compactMap {
            identifier -> ToolbarCustomizationOption? in
            guard identifier != .space, identifier != .flexibleSpace,
                  let definition = toolbarDefinition(for: identifier)
            else { return nil }
            return ToolbarCustomizationOption(
                id: identifier.rawValue,
                label: definition.palette,
                symbol: definition.symbol,
                isSelected: selected.contains(identifier.rawValue))
        }
        let model = ToolbarCustomizationModel(
            options: options,
            setSelection: { [weak self, weak toolbar] identifier, selected in
                guard let toolbar else { return false }
                return self?.setToolbarItem(
                    identifier, selected: selected, in: toolbar) ?? false
            },
            clearSelection: { [weak self, weak toolbar] in
                guard let toolbar else { return false }
                return self?.clearCustomizedToolbar(in: toolbar) ?? false
            })
        toolbarCustomizationModel = model

        let content = ToolbarCustomizationView(
            model: model,
            done: { [weak self] in self?.dismissToolbarCustomization() })
        let panel = ToolbarCustomizationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 450),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        panel.title = "Customize Toolbar"
        panel.contentViewController = NSHostingController(rootView: content)
        panel.contentMinSize = NSSize(width: 520, height: 380)
        panel.contentMaxSize = NSSize(width: 720, height: 560)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel,
                  self.toolbarCustomizationPanel === panel else { return }
            self.window?.removeChildWindow(panel)
            self.toolbarCustomizationPanel = nil
            self.toolbarCustomizationModel = nil
            self.window?.makeKeyAndOrderFront(nil)
        }
        toolbarCustomizationPanel = panel

        let parentFrame = parent.frame
        var origin = NSPoint(
            x: parentFrame.midX - panel.frame.width / 2,
            y: parentFrame.midY - panel.frame.height / 2)
        if let visible = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX),
                           visible.maxX - panel.frame.width)
            origin.y = min(max(origin.y, visible.minY),
                           visible.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(origin)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(sender)
    }

    private func selectedToolbarIdentifiers(in toolbar: NSToolbar) -> Set<String> {
        Set(toolbar.items.compactMap { item in
            let identifier = item.itemIdentifier
            guard identifier != .space, identifier != .flexibleSpace else {
                return nil
            }
            return identifier.rawValue
        })
    }

    private func synchronizeToolbarCustomizationModel(with toolbar: NSToolbar) {
        toolbarCustomizationModel?.synchronize(
            selectedIdentifiers: selectedToolbarIdentifiers(in: toolbar))
    }

    private func setToolbarItem(
        _ rawIdentifier: String,
        selected: Bool,
        in toolbar: NSToolbar
    ) -> Bool {
        let identifier = NSToolbarItem.Identifier(rawIdentifier)
        guard NativeToolbarItem.allowed.contains(identifier),
              identifier != .space, identifier != .flexibleSpace
        else { return false }
        if selected {
            if !toolbar.items.contains(where: {
                $0.itemIdentifier == identifier
            }) {
                toolbar.insertItem(
                    withItemIdentifier: identifier,
                    at: toolbar.items.count)
            }
        } else if let index = toolbar.items.firstIndex(where: {
            $0.itemIdentifier == identifier
        }) {
            toolbar.removeItem(at: index)
        }
        ensureNativeToolbarTrailingAlignment(toolbar)
        updateCompactToolbarGroupVisibility()
        synchronizeToolbarCustomizationModel(with: toolbar)
        return toolbar.items.contains(where: {
            $0.itemIdentifier == identifier
        }) == selected
    }

    private func clearCustomizedToolbar(in toolbar: NSToolbar) -> Bool {
        for index in toolbar.items.indices.reversed() where
            toolbar.items[index].itemIdentifier != .space
                && toolbar.items[index].itemIdentifier != .flexibleSpace {
            toolbar.removeItem(at: index)
        }
        ensureNativeToolbarTrailingAlignment(toolbar)
        updateCompactToolbarGroupVisibility()
        synchronizeToolbarCustomizationModel(with: toolbar)
        return selectedToolbarIdentifiers(in: toolbar).isEmpty
    }

    private func dismissToolbarCustomization() {
        guard let panel = toolbarCustomizationPanel else { return }
        window?.removeChildWindow(panel)
        toolbarCustomizationPanel = nil
        toolbarCustomizationModel = nil
        (panel as? ToolbarCustomizationPanel)?.onClose = nil
        panel.close()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Kept only for the visual regression fixture: it verifies AppKit's
    /// fallback item views remain compact if the system palette is invoked.
    func runNativeToolbarCustomizationPaletteForTest() {
        guard !compactChrome else { return }
        let toolbar = nativeToolbarVisualFixture ?? nativeToolbar
        if window?.toolbar !== toolbar {
            window?.toolbar = toolbar
        }
        ensureNativeToolbarTrailingAlignment(toolbar)
        compactToolbarGroup?.isHidden = true
        toolbar.isVisible = true
        for item in toolbar.items where item.itemIdentifier != .flexibleSpace {
            item.isHidden = false
        }
        toolbar.runCustomizationPalette(nil)
        DispatchQueue.main.async { [weak self, weak toolbar] in
            guard let toolbar else { return }
            self?.monitorNativeToolbarCustomization(toolbar)
        }
    }

    /// Exercises the exact system context-menu route without opening AppKit's
    /// stock palette. Used by the packaged toolbar regression.
    func routeNativeToolbarCustomizationForTest() {
        nativeToolbar.runCustomizationPalette(nil)
    }

    /// Read-only seam for packaged UI smoke tests. Keeping the item factory
    /// private prevents app code from bypassing NSToolbar's customization API.
    func nativeToolbarDiagnostic() -> (customizable: Bool, autosaves: Bool,
                                       allowed: Int, instantiated: Int,
                                       trailingAligned: Bool,
                                       compactSpacing: Bool,
                                       iconPointSize: CGFloat,
                                       buttonSide: CGFloat,
                                       factoryWidths: [CGFloat],
                                       visibleGap: CGFloat) {
        let instantiated = NativeToolbarItem.allowed.reduce(into: 0) { count, identifier in
            if identifier != .space, identifier != .flexibleSpace,
               toolbar(nativeToolbar, itemForItemIdentifier: identifier,
                       willBeInsertedIntoToolbar: false) != nil {
                count += 1
            }
        }
        let compactFrames = compactToolbarGroup?.arrangedSubviews.map {
            $0.convert($0.bounds, to: nil)
        }.sorted { $0.minX < $1.minX } ?? []
        let visibleGap = zip(compactFrames, compactFrames.dropFirst()).map {
            max(0, $1.minX - $0.maxX)
        }.max() ?? 0
        let factoryWidths = nativeToolbar.items.dropFirst().compactMap {
            $0.view?.fittingSize.width
        }
        let compactFactory = nativeToolbar.items.dropFirst().allSatisfy { item in
            guard item.itemIdentifier != .space,
                  item.itemIdentifier != .flexibleSpace,
                  let button = item.view as? CompactToolbarButton
            else { return false }
            let fixedWidth = button.constraints.contains {
                $0.isActive
                    && $0.firstItem as? NSView === button
                    && $0.firstAttribute == .width
                    && $0.relation == .equal
                    && abs($0.constant - CompactToolbarButton.side) < 0.001
            }
            let fixedHeight = button.constraints.contains {
                $0.isActive
                    && $0.firstItem as? NSView === button
                    && $0.firstAttribute == .height
                    && $0.relation == .equal
                    && abs($0.constant - CompactToolbarButton.side) < 0.001
            }
            return fixedWidth && fixedHeight
        }
        return (nativeToolbar.allowsUserCustomization,
                nativeToolbar.autosavesConfiguration,
                NativeToolbarItem.allowed.count, instantiated,
                nativeToolbar.items.first?.itemIdentifier == .flexibleSpace,
                compactFactory,
                NativeToolbarItem.iconPointSize,
                CompactToolbarButton.side,
                factoryWidths,
                visibleGap)
    }

    /// Exercises the same model callbacks as clicking two choices in the
    /// customization panel. The visible compact group must stay present and
    /// retain its six-point rhythm through both insertion and removal.
    func toolbarCustomizationMutationDiagnostic()
        -> (panelVisible: Bool, before: Int, afterAdd: Int, afterRemove: Int,
            compactVisible: Bool, maximumGap: CGFloat, modelMatches: Bool,
            panelHeight: CGFloat, recommendedDefaults: Bool)? {
        guard let model = toolbarCustomizationModel,
              let toolbar = window?.toolbar else { return nil }
        let before = selectedToolbarIdentifiers(in: toolbar).count
        model.toggle(NativeToolbarItem.themes.rawValue)
        let afterAdd = selectedToolbarIdentifiers(in: toolbar).count
        model.toggle(NativeToolbarItem.browser.rawValue)
        let afterRemove = selectedToolbarIdentifiers(in: toolbar).count
        compactToolbarGroup?.layoutSubtreeIfNeeded()
        let frames = compactToolbarGroup?.arrangedSubviews.map {
            $0.convert($0.bounds, to: nil)
        }.sorted { $0.minX < $1.minX } ?? []
        let maximumGap = zip(frames, frames.dropFirst()).map {
            max(0, $1.minX - $0.maxX)
        }.max() ?? 0
        let selected = selectedToolbarIdentifiers(in: toolbar)
        let modelSelected = Set(model.options.filter(\.isSelected).map(\.id))
        return (
            toolbarCustomizationPanel?.isVisible == true,
            before,
            afterAdd,
            afterRemove,
            compactToolbarGroup?.isHidden == false,
            maximumGap,
            selected == modelSelected,
            toolbarCustomizationPanel?.contentView?.bounds.height ?? 0,
            toolbarDefaultItemIdentifiers(nativeToolbar)
                == NativeToolbarItem.recommended)
    }

    /// Isolated visual fixture: install four representative controls without
    /// touching the user's autosaved toolbar configuration.
    func installNativeToolbarVisualFixture() {
        let toolbar = NSToolbar(
            identifier: ProductIdentity.current.slug + ".ui-test.toolbar")
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        nativeToolbarVisualFixture = toolbar
        window?.toolbar = toolbar
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for identifier in [
            NSToolbarItem.Identifier.flexibleSpace,
            NativeToolbarItem.navigator,
            // Deliberately malformed saved-layout spacers: normalization must
            // collapse these so controls cannot fan across the titlebar.
            NSToolbarItem.Identifier.flexibleSpace,
            NativeToolbarItem.browser,
            NSToolbarItem.Identifier.space,
            NativeToolbarItem.splitRight,
            NativeToolbarItem.splitDown,
            NativeToolbarItem.inspector,
        ] {
            toolbar.insertItem(withItemIdentifier: identifier,
                               at: toolbar.items.count)
        }
        ensureNativeToolbarTrailingAlignment(toolbar)
    }

    func nativeToolbarVisualDiagnostic() -> String {
        guard let toolbar = window?.toolbar else { return "toolbar=nil" }
        let identifiers = toolbar.items.map(\.itemIdentifier.rawValue).joined(separator: ",")
        let frames = toolbar.items.compactMap(\.view).map {
            $0.convert($0.bounds, to: nil)
        }.sorted { $0.minX < $1.minX }
        let widths = frames.map { String(format: "%.1f", $0.width) }
            .joined(separator: ",")
        let gaps = zip(frames, frames.dropFirst()).map {
            max(0, $1.minX - $0.maxX)
        }
        let maximumGap = gaps.max() ?? 0
        let maximumGapText = String(format: "%.1f", maximumGap)
        let compactFrames = compactToolbarGroup?.arrangedSubviews.map {
            $0.convert($0.bounds, to: nil)
        }.sorted { $0.minX < $1.minX } ?? []
        let compactGaps = zip(compactFrames, compactFrames.dropFirst()).map {
            max(0, $1.minX - $0.maxX)
        }
        let compactMaximumGap = compactGaps.max() ?? 0
        let compactMaximumGapText = String(format: "%.1f", compactMaximumGap)
        let compactHits = compactToolbarGroup?.arrangedSubviews.map { view in
            let center = container.convert(
                NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
            let hit = container.hitTest(center)
            return hit === view ? "button" : String(describing: type(of: hit))
        }.joined(separator: ",") ?? ""
        let activeButtons = compactToolbarGroup?.arrangedSubviews
            .compactMap { $0 as? CompactToolbarButton }
            .filter(\.isToggledOn) ?? []
        let inactiveButtons = compactToolbarGroup?.arrangedSubviews
            .compactMap { $0 as? CompactToolbarButton }
            .filter { !$0.isToggledOn } ?? []
        let activeIdentifiers = activeButtons.compactMap {
            $0.identifier?.rawValue
        }.joined(separator: ",")
        let referenceInk = CompactToolbarButton.referenceDarkInk
            .usingColorSpace(.sRGB)
        let activeInkMatches = !activeButtons.isEmpty
            && activeButtons.allSatisfy { button in
                guard let actual = button.contentTintColor?
                    .usingColorSpace(.sRGB),
                      let referenceInk else { return false }
                return abs(actual.redComponent - referenceInk.redComponent)
                        < 0.001
                    && abs(actual.greenComponent
                        - referenceInk.greenComponent) < 0.001
                    && abs(actual.blueComponent
                        - referenceInk.blueComponent) < 0.001
            }
        let referenceFill = CompactToolbarButton.referenceActiveFill
            .usingColorSpace(.sRGB)
        let activeFillMatches = !activeButtons.isEmpty
            && activeButtons.allSatisfy { button in
                guard let cgColor = button.layer?.backgroundColor,
                      let actual = NSColor(cgColor: cgColor)?
                        .usingColorSpace(.sRGB),
                      let referenceFill else { return false }
                return abs(actual.redComponent - referenceFill.redComponent)
                        < 0.001
                    && abs(actual.greenComponent
                        - referenceFill.greenComponent) < 0.001
                    && abs(actual.blueComponent
                        - referenceFill.blueComponent) < 0.001
                    && abs(actual.alphaComponent - 1) < 0.001
            }
        let referenceInactiveInk = CompactToolbarButton.referenceInactiveInk
            .usingColorSpace(.sRGB)
        let inactiveInkMatches = !inactiveButtons.isEmpty
            && inactiveButtons.allSatisfy { button in
                guard let actual = button.contentTintColor?
                    .usingColorSpace(.sRGB),
                      let referenceInactiveInk else { return false }
                return abs(actual.redComponent
                        - referenceInactiveInk.redComponent) < 0.001
                    && abs(actual.greenComponent
                        - referenceInactiveInk.greenComponent) < 0.001
                    && abs(actual.blueComponent
                        - referenceInactiveInk.blueComponent) < 0.001
                    && button.alphaValue == 1
            }
        let activeTilesStyled = !activeButtons.isEmpty
            && activeInkMatches
            && activeFillMatches
            && inactiveInkMatches
            && activeButtons.allSatisfy {
                $0.layer?.borderWidth == 0
                    && $0.layer?.mask != nil
                    && $0.visualTileRect.width == CompactToolbarButton.side
                    && $0.visualTileRect.height == CompactToolbarButton.side
                    && $0.alphaValue == 1
            }
        let activeStyleMetrics = activeButtons.map { button in
            let fill = button.layer?.backgroundColor?.alpha ?? -1
            return "fill=\(String(format: "%.3f", fill))"
                + ",border=\(button.layer?.borderWidth ?? -1)"
                + ",radius=\(CompactToolbarButton.cornerRadius)"
                + ",tile=\(button.visualTileRect.width)"
                + "x\(button.visualTileRect.height)"
                + ",hit=\(button.bounds.width)x\(button.bounds.height)"
                + ",alpha=\(button.alphaValue)"
        }.joined(separator: ";")
        return "visible=\(toolbar.isVisible) fixture=\(toolbar === nativeToolbarVisualFixture) "
            + "items=\(toolbar.items.count) [\(identifiers)] "
            + "widths=[\(widths)] maxGap=\(maximumGapText) "
            + "compactVisible=\(compactToolbarGroup?.isHidden == false) "
            + "compactCount=\(compactFrames.count) "
            + "compactMaxGap=\(compactMaximumGapText) "
            + "compactHits=[\(compactHits)] "
            + "active=[\(activeIdentifiers)] "
            + "activeInk=\(activeInkMatches) "
            + "activeFill=\(activeFillMatches) "
            + "inactiveInk=\(inactiveInkMatches) "
            + "activeStyle=[\(activeStyleMetrics)] "
            + "activeTilesStyled=\(activeTilesStyled)"
    }

    /// Coordinates and state for a pointer-level UI regression. This keeps
    /// the test honest: AppDelegate posts mouse down/up into the window at the
    /// visible Split Right icon instead of calling its selector directly. The
    /// split action is intentionally self-contained, so this test does not
    /// require an optional extension to be installed or replace the toolbar
    /// while its interaction states are being inspected.
    func compactToolbarPointerTestTarget()
        -> (screenPoint: NSPoint, paneCount: Int)? {
        guard let window,
              let button = compactToolbarGroup?.arrangedSubviews
                .compactMap({ $0 as? NSButton })
                .first(where: {
                    $0.identifier?.rawValue
                        == NativeToolbarItem.splitRight.rawValue
                })
        else { return nil }
        let centerInWindow = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        return (window.convertPoint(toScreen: centerInWindow), panes.count)
    }

    func compactToolbarInteractionOpacityDiagnostic()
        -> (current: CGFloat, history: [CGFloat])? {
        let button = compactToolbarGroup?.arrangedSubviews
            .compactMap({ $0 as? CompactToolbarButton })
            .first(where: {
                $0.identifier?.rawValue == NativeToolbarItem.splitRight.rawValue
            })
        guard button != nil || !compactToolbarInteractionOpacityHistory.isEmpty
        else { return nil }
        return (button?.interactionOpacityHistory.last
                    ?? button?.alphaValue ?? -1,
                compactToolbarInteractionOpacityHistory)
    }

    /// Tracking areas follow the physical cursor, so a queued synthetic
    /// `mouseMoved` event alone is not deterministic in headless runs. Drive
    /// the same NSResponder entry point before the pointer-level click smoke.
    func driveCompactToolbarHoverSmokeTest() {
        guard let window,
              let button = compactToolbarGroup?.arrangedSubviews
                .compactMap({ $0 as? CompactToolbarButton })
                .first(where: {
                    $0.identifier?.rawValue
                        == NativeToolbarItem.splitRight.rawValue
                }),
              let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: button.convert(
                    NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                    to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0)
        else { return }
        button.mouseEntered(with: event)
        // Return to the real pointer state before the click event is queued;
        // otherwise a headless cursor elsewhere on screen can leave AppKit's
        // tracking state inconsistent with the synthetic window event.
        button.mouseExited(with: event)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(customizeNativeToolbar(_:)) {
            return !compactChrome
        }
        return true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        // The action methods handle their own contextual no-op/beep states.
        // Keeping items enabled also preserves the normal semantic tint in
        // translucent and light titlebars.
        NativeToolbarItem.allowed.contains(item.itemIdentifier)
    }

    /// Chromium deliberately paints through the title band. A terminal theme
    /// can therefore ask for pale toolbar symbols while a white page is the
    /// actual surface beneath them. Use dark ink only for the compact group
    /// when it overlaps that browser surface; everywhere else keeps the theme.
    private func effectiveCompactToolbarTint() -> NSColor {
        if compactToolbarOverlapsEmbeddedBrowser() {
            return CompactToolbarButton.referenceDarkInk
        }
        guard let resolved = nativeToolbarThemeTint.usingColorSpace(.sRGB)
        else { return nativeToolbarThemeTint }
        let luminance = 0.2126 * resolved.redComponent
            + 0.7152 * resolved.greenComponent
            + 0.0722 * resolved.blueComponent
        // Light terminal themes use the exact neutral reference ink instead
        // of inheriting a colored prompt foreground. Dark themes keep their
        // light semantic tint so the same controls retain contrast.
        return luminance < 0.55
            ? CompactToolbarButton.referenceDarkInk
            : nativeToolbarThemeTint
    }

    private func compactToolbarOverlapsEmbeddedBrowser() -> Bool {
        guard let group = compactToolbarGroup,
              !group.isHidden,
              let browserRect = embeddedBrowserRect(in: titleBand)
        else { return false }
        let groupRect = group.convert(group.bounds, to: titleBand)
        let overlap = browserRect.intersection(groupRect)
        return !overlap.isNull && !overlap.isEmpty
    }

    private func applyCompactToolbarTint() {
        let color = effectiveCompactToolbarTint().withAlphaComponent(1)
        for button in compactToolbarGroup?.arrangedSubviews.compactMap({
            $0 as? CompactToolbarButton
        }) ?? [] {
            button.applyBaseTint(color)
        }
    }

    private func updateNativeToolbarTint(_ color: NSColor) {
        nativeToolbarThemeTint = color
        let toolbars = [nativeToolbar, nativeToolbarVisualFixture].compactMap { $0 }
        for toolbar in toolbars {
            for case let button as NSButton in toolbar.items.compactMap(\.view) {
                if let compact = button as? CompactToolbarButton {
                    compact.applyBaseTint(color)
                } else {
                    button.contentTintColor = color
                }
            }
        }
        applyCompactToolbarTint()
    }
    /// Restores drag + double-click-to-zoom over the top band in flush mode.
    private let titleBand = TitleBandView(frame: .zero)
    private let workspaceToolbarHairline = WorkspaceHairlineView(frame: .zero)
    private var windowInlinePanel: InlinePanel?
    private weak var windowInlinePanelSourcePane: TerminalPane?
    private var windowInlinePanelHeightConstraint: NSLayoutConstraint?

    /// The pane the user is working in (first responder), falling back to the
    /// last known focused pane, then the first.
    var focusedPane: TerminalPane? {
        panes.first { $0.isFocused } ?? lastFocused ?? panes.first
    }

    var focusedEditor: CmdyEditorPane? {
        editorPanes.first { $0.ownsFirstResponder(in: window) }
    }

    /// Bottom panes extend an inline surface through the complete window
    /// inset, including the border band. A pane above another split must stop
    /// at its divider.
    func inlinePanelBottomOffset(for pane: TerminalPane) -> CGFloat {
        paneHost.layoutSubtreeIfNeeded()
        let frameInHost = pane.convert(pane.bounds, to: paneHost)
        let touchesWindowBottom = frameInHost.minY <= 0.5
        guard touchesWindowBottom else { return 0 }
        let frameInContainer = pane.convert(pane.bounds, to: container)
        return max(0, frameInContainer.minY)
    }

    /// Present a terminal-native panel across the complete window. Doctor
    /// diagnostics describe app-wide integrations, so squeezing them into the
    /// terminal remainder beside Browser makes the message unnecessarily hard
    /// to read.
    @discardableResult
    func presentWindowInlinePanel(
        from pane: TerminalPane, takeFocus: Bool = true
    ) -> InlinePanel {
        dismissWindowInlinePanel(refocus: false)
        pane.prepareForWindowInlinePanel(takeFocus: takeFocus)

        let panel = InlinePanel(frame: .zero)
        panel.themeOverride = effectiveTheme
        panel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(panel)
        let heightConstraint = panel.heightAnchor.constraint(
            equalToConstant: panel.intrinsicContentSize.height)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            heightConstraint,
        ])

        windowInlinePanel = panel
        windowInlinePanelSourcePane = pane
        windowInlinePanelHeightConstraint = heightConstraint
        panel.onDismiss = { [weak self] in
            self?.dismissWindowInlinePanel(refocus: true)
        }
        panel.onHeightChanged = { [weak self, weak panel, weak pane] height in
            guard let self, let panel, self.windowInlinePanel === panel else { return }
            self.windowInlinePanelHeightConstraint?.constant = height
            pane?.reserveWindowInlinePanelHeight(height)
        }
        panel.metrics = { [weak pane] in
            guard let surface = pane?.surface else {
                let font = Preferences.shared.resolvedFont()
                return (font, 0, 10, font.ascender)
            }
            return (
                surface.font,
                surface.cellSize.height,
                surface.contentXOrigin,
                surface.textBaselineFromRowTop
            )
        }
        // Resolve the full-window width before configureText performs its
        // first wrap. Otherwise a newly added zero-width panel bakes in the
        // same narrow lines we are trying to eliminate.
        container.layoutSubtreeIfNeeded()
        panel.refreshMetrics()
        pane.reserveWindowInlinePanelHeight(panel.intrinsicContentSize.height)

        if takeFocus {
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, self.windowInlinePanel === panel else { return }
                self.window?.makeFirstResponder(panel)
            }
        }
        return panel
    }

    func dismissWindowInlinePanel(refocus: Bool = true) {
        guard let panel = windowInlinePanel else { return }
        let sourcePane = windowInlinePanelSourcePane
        windowInlinePanel = nil
        windowInlinePanelSourcePane = nil
        windowInlinePanelHeightConstraint = nil
        panel.onHeightChanged = nil
        panel.onDismiss = nil
        panel.metrics = nil
        panel.removeFromSuperview()
        sourcePane?.finishWindowInlinePanel(refocus: refocus)
    }

    func dismissWindowInlinePanel(
        from pane: TerminalPane, refocus: Bool = true
    ) {
        guard windowInlinePanelSourcePane === pane else { return }
        dismissWindowInlinePanel(refocus: refocus)
    }

    /// Current working directory (for a new tab/window to inherit).
    var workingDirectory: String? { focusedPane?.currentCwd }
    var tabAppearanceSnapshot: TerminalTabAppearance { tabAppearance }
    var selectedThemeName: String {
        tabAppearance.resolvedThemeName(global: Preferences.shared.themeName)
    }
    var selectedShaderName: String {
        tabAppearance.resolvedShaderName(global: Preferences.shared.shaderName)
    }
    var selectedFontName: String {
        tabAppearance.resolvedFontName(global: Preferences.shared.fontName)
    }

    /// Layout snapshot to rebuild instead of a fresh single pane (session restore).
    private let restoreNode: [String: Any]?
    /// A live pane (shell running) this window adopts instead of spawning one —
    /// used when a pane breaks out of a split into its own window.
    private let adoptedPane: TerminalPane?

    init(cwd: String? = nil, session: [String: Any]? = nil,
         adopting pane: TerminalPane? = nil,
         appearance: TerminalTabAppearance? = nil,
         deferWorkspaceTabPresentation: Bool = false,
         startShells: Bool = true) {
        initialCwd = cwd
        startsShells = startShells
        restoreNode = session
        adoptedPane = pane
        defersWorkspaceTabPresentation = deferWorkspaceTabPresentation
        if let session {
            tabAppearance = TerminalTabAppearance.restored(
                themeName: session["tabTheme"] as? String,
                shaderName: session["tabShader"] as? String,
                fontName: session["tabFont"] as? String)
        } else if let appearance {
            tabAppearance = TerminalTabAppearance.restored(
                themeName: appearance.themeName,
                shaderName: appearance.shaderName,
                fontName: appearance.fontName)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = ProductIdentity.current.displayName
        window.tabbingIdentifier = ProductIdentity.current.slug
        // AppKit may apply the real app's saved automatic-tabbing preference
        // as soon as a new window is shown. Sidebar mode must opt out before
        // that first presentation; suppressing the bar afterward leaves its
        // titlebar accessory visibly stranded on some configurations.
        window.tabbingMode = Preferences.shared.workspaceNavigatorVisible
            ? .disallowed : .preferred
        // Transparent titlebar so the C64 border integrates, but the title +
        // folder proxy icon (via representedURL) stay visible — Terminal/Ghostty style.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden   // hide the big system title; we draw a compact one
        container.wantsLayer = true
        window.contentView = container

        super.init(window: window)

        // Keep AppKit in charge of the window and tabs while giving the native
        // split controller a real parent in the window's view-controller tree.
        rootViewController.view = container
        window.contentViewController = rootViewController

        window.delegate = self
        // Cmdy positions windows explicitly: first windows center, Cmd+N
        // inherits and offsets the active frame, and restored sessions keep
        // their saved frame. AppKit's cascade otherwise overwrites all three.
        shouldCascadeWindows = false
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// AppKit shows the native tab bar's "+" button (right edge) only when
    /// this action exists in the responder chain — it opens a new tab here.
    @objc override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newTab(attachedTo: window)
    }

    // MARK: - Setup

    private func setup() {
        workspaceContentController.view = workspaceContentView
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        workspaceContentView.addSubview(paneHost)

        // Companion space is part of the central content column. The terminal
        // stops at its leading edge while the Inspector remains the outer-right
        // split item.
        dockStrip.translatesAutoresizingMaskIntoConstraints = false
        dockStrip.wantsLayer = true
        dockStrip.isHidden = true
        workspaceContentView.addSubview(
            dockStrip, positioned: .below, relativeTo: paneHost)
        paneHostTrailing = paneHost.trailingAnchor.constraint(
            equalTo: workspaceContentView.trailingAnchor)
        dockStripWidth = dockStrip.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            paneHost.leadingAnchor.constraint(
                equalTo: workspaceContentView.leadingAnchor),
            paneHostTrailing!,
            paneHost.topAnchor.constraint(
                equalTo: workspaceContentView.topAnchor),
            paneHost.bottomAnchor.constraint(
                equalTo: workspaceContentView.bottomAnchor),
            dockStrip.trailingAnchor.constraint(
                equalTo: workspaceContentView.trailingAnchor),
            dockStripWidth!,
            dockStrip.topAnchor.constraint(
                equalTo: workspaceContentView.topAnchor),
            dockStrip.bottomAnchor.constraint(
                equalTo: workspaceContentView.bottomAnchor),
        ])
        workspaceSplitController.splitView = workspaceSplitView
        workspaceSplitView.interactiveDividerHitTargetThickness = 12
        workspaceSplitView.themedDividerHairlinePlacement = .againstOuterRails

        // A regular split item is intentional. AppKit's special sidebar item
        // becomes a floating, rounded overlay on current macOS; tabs are a
        // structural column and must take real width away from the terminal.
        let navigatorItem = NSSplitViewItem(viewController: navigatorController)
        navigatorItem.minimumThickness = WorkspaceFrameLayout.minimumNavigatorWidth
        navigatorItem.maximumThickness = 340
        navigatorItem.preferredThicknessFraction = 0.20
        // Window resizing belongs to the terminal column. A rail changes width
        // only when the user drags its own divider. AppKit requires holding
        // priorities below 490 for a divider to remain directly draggable.
        navigatorItem.holdingPriority =
            NSLayoutConstraint.Priority(rawValue: 480)
        // Visibility is owned by the menu/shortcut, close affordance, Focus
        // Mode, and responsive policy. Direct divider collapse is disabled
        // because AppKit also changes that state transiently during tab swaps.
        navigatorItem.canCollapse = false
        navigatorItem.canCollapseFromWindowResize = false
        navigatorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        navigatorItem.allowsFullHeightLayout = true

        centerSplitController.splitView = centerSplitView
        centerSplitView.isVertical = true
        centerSplitView.dividerStyle = .thin
        centerSplitView.interactiveDividerHitTargetThickness = 16
        centerSplitView.onLayout = { [weak self] in
            self?.refreshEmbeddedBrowserChromeExclusion()
        }

        let terminalItem = NSSplitViewItem(
            viewController: workspaceContentController)
        terminalItem.minimumThickness = WorkspaceFrameLayout.minimumTerminalWidth
        terminalItem.holdingPriority = .defaultLow
        terminalItem.automaticallyAdjustsSafeAreaInsets = true

        let browserItem = NSSplitViewItem(
            viewController: embeddedBrowserController)
        browserItem.minimumThickness = 280
        browserItem.maximumThickness = 1_200
        browserItem.preferredThicknessFraction = 0.46
        browserItem.holdingPriority =
            NSLayoutConstraint.Priority(rawValue: 470)
        browserItem.canCollapse = true
        browserItem.canCollapseFromWindowResize = false
        browserItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        browserItem.isCollapsed = !Self.embeddedBrowserStartsVisible
        embeddedBrowserSplitItem = browserItem

        centerSplitController.addSplitViewItem(terminalItem)
        centerSplitController.addSplitViewItem(browserItem)

        let contentItem = NSSplitViewItem(viewController: centerSplitController)
        contentItem.minimumThickness = WorkspaceFrameLayout.minimumTerminalWidth
        contentItem.holdingPriority = .defaultLow
        contentItem.automaticallyAdjustsSafeAreaInsets = true

        // Use the same structural split-item type as Navigator. AppKit's
        // special inspector item draws an additional dark, full-height edge;
        // the hosted rail already supplies the shared one-point separator.
        let inspectorItem = NSSplitViewItem(viewController: inspectorController)
        inspectorItem.minimumThickness = WorkspaceFrameLayout.minimumInspectorWidth
        inspectorItem.maximumThickness = 380
        inspectorItem.preferredThicknessFraction = 0.27
        inspectorItem.holdingPriority =
            NSLayoutConstraint.Priority(rawValue: 480)
        inspectorItem.canCollapse = false
        inspectorItem.canCollapseFromWindowResize = false
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspectorItem.allowsFullHeightLayout = true

        navigatorSplitItem = navigatorItem
        inspectorSplitItem = inspectorItem
        terminalSplitItem = terminalItem
        workspaceContentSplitItem = contentItem
        workspaceSplitController.splitView.isVertical = true
        workspaceSplitController.splitView.dividerStyle = .thin
        workspaceSplitController.addSplitViewItem(navigatorItem)
        workspaceSplitController.addSplitViewItem(contentItem)
        workspaceSplitController.addSplitViewItem(inspectorItem)

        rootViewController.addChild(workspaceSplitController)
        let workspaceView = workspaceSplitController.view
        workspaceView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(workspaceView)
        workspaceTrailing = workspaceView.trailingAnchor.constraint(
            equalTo: container.trailingAnchor)
        workspaceBottom = workspaceView.bottomAnchor.constraint(
            equalTo: container.bottomAnchor)
        NSLayoutConstraint.activate([
            workspaceView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            workspaceTrailing!,
            workspaceView.topAnchor.constraint(equalTo: container.topAnchor),
            workspaceBottom!,
        ])

        navigatorModel.onClose = { Preferences.shared.workspaceNavigatorVisible = false }
        navigatorModel.onCreate = { [weak self] in
            (NSApp.delegate as? AppDelegate)?.newTab(attachedTo: self?.window)
        }
        inspectorModel.onClose = { Preferences.shared.workspaceInspectorVisible = false }

        pluginDockInset = Self.sharedDockInset   // inherit a strip held by a plugin
        window?.titlebarSeparatorStyle = .none

        // Above the panes, below the lights/title/find bar: the top band acts
        // like a titlebar again (drag, double-click zoom, arrow cursor).
        titleBand.translatesAutoresizingMaskIntoConstraints = false
        titleBand.wantsLayer = true
        titleBand.layer?.backgroundColor = NSColor.clear.cgColor
        titleBand.passthroughRects = { [weak self] in
            guard let self else { return [] }
            var rects = self.panes.compactMap {
                $0.splitAffordanceRect(in: self.titleBand)
            }
            if let browser = self.embeddedBrowserRect(in: self.titleBand) {
                rects.append(browser)
            }
            return rects
        }
        container.addSubview(titleBand)
        titleBandHeight = titleBand.heightAnchor.constraint(equalToConstant: topInset)
        NSLayoutConstraint.activate([
            titleBand.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleBand.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            titleBand.topAnchor.constraint(equalTo: container.topAnchor),
            titleBandHeight!,
        ])
        setupCompactToolbarGroup()

        workspaceToolbarHairline.translatesAutoresizingMaskIntoConstraints = false
        workspaceToolbarHairline.wantsLayer = true
        workspaceToolbarHairline.layer?.backgroundColor = NSColor.clear.cgColor
        workspaceToolbarHairline.excludedRect = { [weak self] in
            guard let self else { return nil }
            return self.embeddedBrowserRect(in: self.workspaceToolbarHairline)
        }
        workspaceToolbarHairline.isHidden = true
        container.addSubview(
            workspaceToolbarHairline,
            positioned: .above,
            relativeTo: titleBand)
        workspaceToolbarHairlineHeight =
            workspaceToolbarHairline.heightAnchor.constraint(equalToConstant: 0.5)
        NSLayoutConstraint.activate([
            workspaceToolbarHairline.leadingAnchor.constraint(
                equalTo: container.leadingAnchor),
            workspaceToolbarHairline.trailingAnchor.constraint(
                equalTo: container.trailingAnchor),
            workspaceToolbarHairline.topAnchor.constraint(
                equalTo: titleBand.bottomAnchor),
            workspaceToolbarHairlineHeight!,
        ])

        // Tab bar appearing/disappearing changes the chrome height — re-inset.
        layoutRectObservation = window?.observe(\.contentLayoutRect) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.applyEdgeInsets()
                self?.updateTopInsets()
            }
        }

        // Compact title, aligned to AppKit's native window controls.
        titleLabel.font = .systemFont(
            ofSize: WorkspaceChromeMetrics.titleFontSize,
            weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.refusesFirstResponder = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)
        titleLeading = titleLabel.leadingAnchor.constraint(
            equalTo: paneHost.leadingAnchor,
            constant: NativeToolbarPreset.titleLeading(
                Preferences.shared.nativeToolbarStyle))
        titleTop = titleLabel.topAnchor.constraint(
            equalTo: container.topAnchor,
            constant: NativeToolbarPreset.titleTop(
                Preferences.shared.nativeToolbarStyle))
        titleTrailing = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: paneHost.trailingAnchor, constant: -borderInset)
        NSLayoutConstraint.activate([titleLeading!, titleTop!, titleTrailing!])

        inspectorTitleLabel.font = .systemFont(
            ofSize: WorkspaceChromeMetrics.titleFontSize,
            weight: .medium)
        inspectorTitleLabel.textColor = .secondaryLabelColor
        inspectorTitleLabel.alignment = .left
        inspectorTitleLabel.lineBreakMode = .byTruncatingTail
        inspectorTitleLabel.refusesFirstResponder = true
        inspectorTitleLabel.wantsLayer = true
        inspectorTitleLabel.layer?.backgroundColor = NSColor.clear.cgColor
        inspectorTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inspectorTitleLabel)
        NSLayoutConstraint.activate([
            inspectorTitleLabel.leadingAnchor.constraint(
                equalTo: inspectorController.view.leadingAnchor,
                constant: 8),
            inspectorTitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: inspectorController.view.trailingAnchor,
                constant: -8),
            inspectorTitleLabel.firstBaselineAnchor.constraint(
                equalTo: titleLabel.firstBaselineAnchor),
        ])
        updateWorkspaceToolbarHairlineVisibility()

        // Find bar, right-aligned in the top band (hidden until ⌘F).
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        container.addSubview(findBar)
        findTrailing = findBar.trailingAnchor.constraint(
            equalTo: paneHost.trailingAnchor, constant: -borderInset)
        findTop = findBar.topAnchor.constraint(
            equalTo: container.topAnchor, constant: max(0, (topInset - 28) / 2))
        NSLayoutConstraint.activate([
            findTrailing!,
            findTop!,
            findBar.widthAnchor.constraint(equalToConstant: 420),
            findBar.heightAnchor.constraint(equalToConstant: 28),
        ])
        findBar.onSearch = { [weak self] term, forward in
            guard let self, let pane = self.focusedPane ?? self.panes.first else { return }
            let opts = self.findBar.options
            let found = forward
                ? pane.surface.findNext(term, options: opts)
                : pane.surface.findPrevious(term, options: opts)
            let status = pane.surface.searchStatus(term, options: opts)
            self.findBar.indicate(found: found, index: status.index, total: status.total)
        }
        findBar.onClose = { [weak self] in self?.hideFindBar() }

        workspaceDividerOverlay.splitView = workspaceSplitView
        workspaceDividerOverlay.isLeadingRailVisible = { [weak self] in
            guard let self else { return false }
            return workspaceNavigatorVisible
                && navigatorSplitItem?.isCollapsed == false
        }
        workspaceDividerOverlay.isTrailingRailVisible = { [weak self] in
            guard let self else { return false }
            return workspaceInspectorVisible
                && inspectorSplitItem?.isCollapsed == false
        }
        workspaceDividerOverlay.onDragEnded = { [weak self] in
            self?.workspaceDividerDragDidEnd()
        }
        workspaceDividerOverlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(workspaceDividerOverlay)
        NSLayoutConstraint.activate([
            workspaceDividerOverlay.leadingAnchor.constraint(
                equalTo: container.leadingAnchor),
            workspaceDividerOverlay.trailingAnchor.constraint(
                equalTo: container.trailingAnchor),
            workspaceDividerOverlay.topAnchor.constraint(
                equalTo: container.topAnchor),
            workspaceDividerOverlay.bottomAnchor.constraint(
                equalTo: container.bottomAnchor),
        ])

        // Chromium owns a native child view and therefore needs the same
        // transparent sibling used by the outer workspace rails. Without this
        // overlay only the painted one-point separator receives a drag.
        embeddedBrowserDividerOverlay.splitView = centerSplitView
        embeddedBrowserDividerOverlay.onDragEnded = { [weak self] in
            self?.refreshEmbeddedBrowserChromeExclusion()
        }
        embeddedBrowserDividerOverlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(embeddedBrowserDividerOverlay)
        NSLayoutConstraint.activate([
            embeddedBrowserDividerOverlay.leadingAnchor.constraint(
                equalTo: container.leadingAnchor),
            embeddedBrowserDividerOverlay.trailingAnchor.constraint(
                equalTo: container.trailingAnchor),
            embeddedBrowserDividerOverlay.topAnchor.constraint(
                equalTo: container.topAnchor),
            embeddedBrowserDividerOverlay.bottomAnchor.constraint(
                equalTo: container.bottomAnchor),
        ])

        // Drops on the border region go to the focused pane.
        container.onDropPaths = { [weak self] paths in
            guard let self, let pane = self.focusedPane else { return }
            let text = paths.map { Self.shellQuote($0) }.joined(separator: " ") + " "
            pane.appendPromptInput(text)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .cmdyPreferencesChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(workspaceFrameChanged(_:)),
            name: .cmdyWorkspaceFrameChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(workspaceFrameChanged(_:)),
            name: .cmdyWorkspaceContributionsChanged, object: nil)

        // Refresh chrome (title, subtitle) when focus moves between panes.
        responderObservation = window?.observe(\.firstResponder) { [weak self] _, _ in
            guard let controller = self else { return }
            Task { @MainActor [weak controller] in
                guard let controller else { return }
                let previous = controller.lastFocused
                if let p = controller.panes.first(where: { $0.isFocused }) {
                    controller.lastFocused = p
                    if p !== previous {
                        if let previous {
                            PluginManager.shared.emit(
                                "pane-updated", ["pane": previous.paneId])
                        }
                        PluginManager.shared.emit("pane-updated", ["pane": p.paneId])
                    }
                }
                // A responder change within this window does not otherwise
                // invalidate the Metal surface. Explicit host suppression both
                // repaints immediately and prevents a terminal caret remaining
                // visible beside the active attached editor.
                if controller.focusedEditor != nil {
                    controller.panes.forEach { $0.surface.hostCursorHidden = true }
                } else if controller.panes.contains(where: { $0.isTerminalFocused }) {
                    controller.panes.forEach { $0.surface.hostCursorHidden = false }
                }
                controller.applyFocusModePresentation()
                controller.scheduleChromeUpdate()
            }
        }

        if let pane = adoptedPane {
            // Adopt a live pane broken out of another window.
            wire(pane)
            panes = [pane]
            lastFocused = pane
            installRoot(pane)
            applyPreferences()
            window?.initialFirstResponder = pane.surface.view
            DispatchQueue.main.async { [weak self] in
                self?.updateTopInsets()
                pane.surface.forceRedraw()
                pane.focus()
            }
        } else if let node = restoreNode {
            // Rebuild a saved layout: split tree, per-pane cwd + scrollback.
            let root = buildTree(node)
            installRoot(root)
            lastFocused = panes.first
            applyPreferences()
            if startsShells {
                for pane in panes { pane.startShell() }
            }
            window?.initialFirstResponder = panes.first?.surface.view
            if let f = node["frame"] as? String {
                let rect = NSRectFromString(f)
                if rect.width > 100, rect.height > 100 { window?.setFrame(rect, display: false) }
            }
            if node["floating"] as? Bool == true { window?.level = .floating }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.distributeAll(in: self.paneHost)
                self.panes.forEach { $0.surface.forceRedraw() }
            }
        } else {
            // First pane fills the host.
            let pane = makePane(cwd: initialCwd)
            panes = [pane]
            lastFocused = pane
            installRoot(pane)
            applyPreferences()
            if startsShells { pane.startShell() }
            window?.initialFirstResponder = pane.surface.view
        }
        refreshSplitAffordances()
        // Seed the folder proxy icon / title until the shell reports cwd via OSC 7.
        window?.representedURL = URL(fileURLWithPath: NSHomeDirectory())
        scheduleChromeUpdate()
        NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged, object: self)
    }

    // MARK: - Session persistence

    /// JSON-ready snapshot of this window: frame + the split/pane tree.
    func serializeLayout() -> [String: Any] {
        guard let root = paneHost.subviews.first, var node = encode(view: root) else { return [:] }
        node["frame"] = NSStringFromRect(window?.frame ?? .zero)
        node["floating"] = window?.level == .floating
        if let themeName = tabAppearance.themeName { node["tabTheme"] = themeName }
        if let shaderName = tabAppearance.shaderName { node["tabShader"] = shaderName }
        if let fontName = tabAppearance.fontName { node["tabFont"] = fontName }
        return node
    }

    private func encode(view: NSView) -> [String: Any]? {
        if let sv = view as? ThemedSplitView {
            let children = sv.arrangedSubviews.compactMap { encode(view: $0) }
            if children.count == 1 { return children[0] }
            guard children.count > 1 else { return nil }
            return ["type": "split", "vertical": sv.isVertical, "children": children]
        }
        if let pane = view as? TerminalPane {
            var node: [String: Any] = [
                "type": "pane",
                "cwd": pane.currentCwd ?? NSHomeDirectory(),
                "scrollback": pane.scrollbackForSession(),
            ]
            if let themeName = pane.paneAppearance.themeName {
                node["paneTheme"] = themeName
            }
            if let shaderName = pane.paneAppearance.shaderName {
                node["paneShader"] = shaderName
            }
            if let fontName = pane.paneAppearance.fontName {
                node["paneFont"] = fontName
            }
            return node
        }
        // Editor documents own their save lifecycle and are intentionally not
        // turned into phantom shell panes during terminal session restore.
        return nil
    }

    /// Rebuild a saved node into live views (panes are registered as created).
    private func buildTree(_ node: [String: Any]) -> NSView {
        if node["type"] as? String == "split",
           let children = node["children"] as? [[String: Any]], children.count > 1 {
            let sv = ThemedSplitView(frame: .zero)
            sv.isVertical = node["vertical"] as? Bool ?? true
            sv.dividerStyle = .thin
            for child in children { sv.addArrangedSubview(buildTree(child)) }
            return sv
        }
        let pane = makePane(cwd: node["cwd"] as? String)
        pane.restoreAppearance(TerminalTabAppearance.restored(
            themeName: node["paneTheme"] as? String,
            shaderName: node["paneShader"] as? String,
            fontName: node["paneFont"] as? String))
        pane.pendingRestoreText = node["scrollback"] as? String
        panes.append(pane)
        return pane
    }

    private func distributeAll(in view: NSView) {
        for sub in view.subviews {
            if let sv = sub as? ThemedSplitView { distributeEvenly(sv) }
            distributeAll(in: sub)
        }
    }

    private func makePane(cwd: String?) -> TerminalPane {
        let pane = TerminalPane(cwd: cwd)
        wire(pane)
        return pane
    }

    /// Point a pane's callbacks at THIS controller (fresh panes and panes
    /// adopted from a merged window).
    private func wire(_ pane: TerminalPane) {
        PluginManager.shared.emit("pane-opened", ["pane": pane.paneId, "cwd": pane.currentCwd ?? ""])
        pane.surface.onSelectionChanged = { [weak self] in
            self?.scheduleChromeUpdate()
        }
        pane.onViewportChanged = { [weak self] pane in
            guard pane === self?.focusedPane else { return }
            self?.scheduleWorkspaceContextRefresh()
        }
        pane.inheritedAppearanceProvider = { [weak self] in
            guard let self else {
                return (Preferences.shared.themeName,
                        Preferences.shared.shaderName,
                        Preferences.shared.fontName)
            }
            return (self.selectedThemeName, self.selectedShaderName,
                    self.selectedFontName)
        }
        pane.onAppearanceChanged = { [weak self] pane in
            self?.paneAppearanceDidChange(pane)
        }
        pane.onStateChanged = { [weak self] p in
            guard let self else { return }
            if p === self.focusedPane {
                if let dir = p.currentCwd {
                    let url = URL(fileURLWithPath: dir)
                    if self.window?.representedURL != url {
                        self.window?.representedURL = url   // folder proxy icon
                    }
                }
            }
            self.schedulePaneStateBroadcast(for: p.paneId)
            self.scheduleChromeUpdate()
        }
        pane.onClosed = { [weak self] p in
            self?.pendingPaneStateBroadcastIDs.remove(p.paneId)
            if self?.pendingPaneStateBroadcastIDs.isEmpty == true {
                self?.paneStateBroadcastWorkItem?.cancel()
                self?.paneStateBroadcastWorkItem = nil
            }
            PluginManager.shared.emit("pane-closed", ["pane": p.paneId])
            self?.workspaceResourcesByPane.removeValue(forKey: p.paneId)
            self?.removePane(p)
            NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged, object: self)
        }
        pane.onSplitCloseRequested = { [weak self] pane in
            guard let self, self.panes.count > 1 else { return }
            _ = self.closePaneById(pane.paneId)
        }
        pane.onSplitDetachRequested = { [weak self] pane in
            guard let self, self.panes.count > 1, let window = self.window else {
                return
            }
            let drop = NSPoint(
                x: window.frame.maxX - 40,
                y: window.frame.maxY - 36)
            _ = self.tearOutPane(pane, at: drop)
        }
        pane.onSplitDragBegan = { [weak self] pane in
            guard let self, self.panes.count > 1 else { return }
            WindowDock.shared.beginPaneDrag(pane, from: self)
        }
        pane.onSplitDragChanged = { _ in
            WindowDock.shared.updatePaneDrag()
        }
        pane.onSplitDragEnded = { _ in
            WindowDock.shared.endPaneDrag()
        }
        pane.onAttention = { [weak self] p, text in
            PluginManager.shared.emit("attention", [
                "pane": p.paneId,
                "text": text,
            ])
            let away = !NSApp.isActive || self?.window?.isKeyWindow == false
                || self?.window?.isMiniaturized == true
            if away {
                Notifier.post(title: text.isEmpty ? "A pane wants attention" : text,
                              body: (p.currentCwd as NSString?)?.lastPathComponent
                                  ?? ProductIdentity.current.displayName)
            }
            self?.scheduleChromeUpdate()
            NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged, object: self)
        }
        pane.onCommandFinished = { [weak self] p, block in
            let output = p.outputText(for: block)
            // The SDK's richest signal: every finished command, with its exit.
            PluginManager.shared.emit("command-finished", [
                "pane": p.paneId,
                "command": block.commandText,
                "exitCode": Int(block.exitCode ?? -1),
                "cwd": block.cwd ?? "",
                "block": block.id,
            ])
            _ = PluginManager.shared.channelCommandFinished(
                paneID: p.paneId, blockID: block.id,
                command: block.commandText, exitCode: Int(block.exitCode ?? -1),
                output: output)
            self?.notifyIfAway(pane: p, block: block)
            self?.requestGitWorkspaceState(for: p.currentCwd, force: true)
            NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged, object: self)
            // Agent mode: results of the pane's commands feed the session.
            if let session = self?.agentSession, session.pane === p {
                session.commandFinished(block: block, output: output)
                return
            }
        }
        pane.onCommandStarted = { [weak self] p, block in
            PluginManager.shared.emit("command-started", [
                "pane": p.paneId,
                "block": block.id,
                "command": block.commandText,
                "cwd": block.cwd ?? "",
            ])
            PluginManager.shared.channelCommandStarted(
                paneID: p.paneId, blockID: block.id)
            self?.scheduleChromeUpdate()
        }
        pane.onAskRequested = { [weak self] p, request in
            self?.ask(request: request, in: p)
        }
    }

    private func schedulePaneStateBroadcast(for paneID: String) {
        pendingPaneStateBroadcastIDs.insert(paneID)
        guard paneStateBroadcastWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.paneStateBroadcastWorkItem = nil
            let paneIDs = self.pendingPaneStateBroadcastIDs
            self.pendingPaneStateBroadcastIDs.removeAll(keepingCapacity: true)
            for paneID in paneIDs {
                PluginManager.shared.emit("pane-updated", ["pane": paneID])
            }
            if (NSApp.delegate as? AppDelegate)?
                .workspaceHasVisibleRails(containing: self) == true {
                NotificationCenter.default.post(
                    name: .cmdyWorkspaceFrameChanged, object: self)
            }
        }
        paneStateBroadcastWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    // MARK: - Split pane tree

    private func installRoot(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: paneHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
        ])
    }

    /// Split the focused pane. `vertical: true` = side-by-side (divider is vertical).
    func splitFocusedPane(vertical: Bool) {
        guard let pane = focusedPane else { return }
        _ = splitPane(pane, vertical: vertical)
    }

    /// Split a specific pane and return the newly created one. Shared by the
    /// menu (splitFocusedPane) and the plugin API (/v1/panes/<id>/split).
    @discardableResult
    func splitPane(_ pane: TerminalPane, vertical requestedVertical: Bool) -> TerminalPane? {
        let decision = PluginManager.shared.decide(.paneSplit, payload: [
            "pane": pane.paneId,
            "cwd": pane.currentCwd ?? "",
            "direction": requestedVertical ? "right" : "down",
        ])
        guard decision.action != .cancel else { return nil }
        let vertical: Bool
        if decision.action == .replace, decision.value == "right" { vertical = true }
        else if decision.action == .replace, decision.value == "down" { vertical = false }
        else { vertical = requestedVertical }
        let newPane = makePane(cwd: pane.currentCwd)
        panes.append(newPane)
        insert(newPane, nextTo: pane, vertical: vertical)
        newPane.applyPreferences()
        if startsShells { newPane.startShell() }
        applyPreferences()   // recolor dividers etc.
        relayoutPanes(focus: newPane)
        return newPane
    }

    /// Splice `newPane` into the layout beside `pane` (shared by splits,
    /// window-merging, and restore).
    private func insert(_ newView: NSView, nextTo view: NSView, vertical: Bool,
                        after: Bool = true) {
        if let sv = view.superview as? ThemedSplitView, sv.isVertical == vertical {
            // Same orientation: just add alongside.
            let idx = sv.arrangedSubviews.firstIndex(of: view) ?? sv.arrangedSubviews.count - 1
            sv.insertArrangedSubview(newView, at: idx + (after ? 1 : 0))
            distributeEvenly(sv)
        } else {
            // Wrap the pane in a new split of the requested orientation.
            let sv = ThemedSplitView(frame: view.frame)
            sv.isVertical = vertical
            sv.dividerStyle = .thin
            let theme = effectiveTheme
            sv.themedDividerColor = theme.ns(theme.border)
            replace(view, with: sv)
            if after {
                sv.addArrangedSubview(view)
                sv.addArrangedSubview(newView)
            } else {
                sv.addArrangedSubview(newView)
                sv.addArrangedSubview(view)
            }
            distributeEvenly(sv)
        }
    }

    /// Move a document surface into the terminal's real split hierarchy. It
    /// therefore follows window moves and resizes in the same layout pass.
    func attachEditor(_ editor: CmdyEditorPane, side: DockSide = .right) {
        guard !editorPanes.contains(where: { $0 === editor }) else {
            editor.focus()
            return
        }
        let target: NSView? = (focusedEditor as NSView?)
            ?? (focusedPane as NSView?) ?? paneHost.subviews.first
        guard let target else { return }
        editorPanes.append(editor)
        editor.setAttached(true, controller: self)
        editor.onTitleChanged = { [weak self] in self?.scheduleChromeUpdate() }
        let vertical = side == .left || side == .right
        let after = side == .right || side == .bottom
        insert(editor, nextTo: target, vertical: vertical, after: after)
        applyPreferences()
        editor.focus()
        relayoutPanes(editor: editor)
    }

    /// Remove a document from the split without closing it. The manager puts
    /// the same view into a standalone editor window immediately afterwards.
    func releaseEditor(_ editor: CmdyEditorPane) {
        guard editorPanes.contains(where: { $0 === editor }) else { return }
        editorPanes.removeAll { $0 === editor }
        removeFromTree(editor)
        editor.onTitleChanged = nil
        editor.setAttached(false, controller: nil)
        scheduleChromeUpdate()
        relayoutPanes()
    }

    func removeEditor(_ editor: CmdyEditorPane) {
        releaseEditor(editor)
        if panes.isEmpty && editorPanes.isEmpty { window?.close() }
    }

    // MARK: - Window merging (tabs handled natively; splits below)

    private struct ReleasedGridContent {
        let tree: NSView
        let panes: [TerminalPane]
        let editors: [CmdyEditorPane]
    }

    /// A geometry-bearing version of the live pane tree. N-ary NSSplitViews
    /// become equivalent binary branches so the same model can drive native
    /// grid windows without rebuilding any terminal session.
    func paneGridNodeForTesting() -> WindowGridNode? {
        guard editorPanes.isEmpty, let root = paneHost.subviews.first else {
            return nil
        }
        paneHost.layoutSubtreeIfNeeded()
        let node = paneGridNode(from: root)
        guard Set(WindowGridLayout.leafIDs(in: node)) == Set(panes.map(\.paneId))
        else { return nil }
        return node
    }

    func paneFramesForTesting() -> [String: CGRect] {
        paneHost.layoutSubtreeIfNeeded()
        return Dictionary(uniqueKeysWithValues: panes.map {
            ($0.paneId, $0.convert($0.bounds, to: paneHost))
        })
    }

    private func paneGridNode(from view: NSView) -> WindowGridNode? {
        if let pane = view as? TerminalPane { return .leaf(pane.paneId) }
        guard let split = view as? ThemedSplitView else { return nil }
        let axis: WindowGridAxis = split.isVertical ? .vertical : .horizontal
        let entries: [(node: WindowGridNode, size: CGFloat, frame: CGRect)] =
            split.arrangedSubviews.compactMap { child in
                guard let node = paneGridNode(from: child) else { return nil }
                let frame = child.convert(child.bounds, to: paneHost)
                let size = axis == .vertical ? frame.width : frame.height
                return (node, max(1, size), frame)
            }
        let ordered = entries.sorted { lhs, rhs in
            if axis == .vertical { return lhs.frame.minX < rhs.frame.minX }
            return lhs.frame.maxY > rhs.frame.maxY
        }
        return combinedGridNode(ordered, axis: axis)
    }

    private func combinedGridNode(
        _ entries: [(node: WindowGridNode, size: CGFloat, frame: CGRect)],
        axis: WindowGridAxis
    ) -> WindowGridNode? {
        guard let first = entries.first else { return nil }
        guard entries.count > 1 else { return first.node }
        let tail = Array(entries.dropFirst())
        guard let second = combinedGridNode(tail, axis: axis) else { return nil }
        let total = entries.reduce(CGFloat.zero) { $0 + $1.size }
        let ratio = min(0.999, max(0.001, first.size / max(1, total)))
        return .split(
            axis: axis, ratio: ratio,
            first: first.node, second: second)
    }

    private func replacingGridLeafIDs(
        in node: WindowGridNode,
        with ids: [String: String]
    ) -> WindowGridNode? {
        switch node {
        case .leaf(let paneID):
            return ids[paneID].map(WindowGridNode.leaf)
        case .split(let axis, let ratio, let first, let second):
            guard let mappedFirst = replacingGridLeafIDs(in: first, with: ids),
                  let mappedSecond = replacingGridLeafIDs(in: second, with: ids)
            else { return nil }
            return .split(
                axis: axis, ratio: ratio,
                first: mappedFirst, second: mappedSecond)
        }
    }

    /// Turn every terminal split in this window into an independent native
    /// window while retaining the same recursive shape and split proportions.
    /// TerminalPane instances move directly, so PTYs, scrollback, and process
    /// identity remain uninterrupted.
    @discardableResult
    func breakAllSplitsIntoGridWindows() -> Bool {
        guard panes.count > 1,
              editorPanes.isEmpty,
              let paneTree = paneGridNodeForTesting(),
              let sourceWindow = window,
              let screen = sourceWindow.screen ?? NSScreen.main,
              let delegate = NSApp.delegate as? AppDelegate
        else { return false }

        let originalPanes = panes
        let keeper = focusedPane ?? originalPanes[0]
        var controllersByPaneID: [String: TerminalWindowController] = [
            keeper.paneId: self,
        ]
        var created: [TerminalWindowController] = []
        for pane in originalPanes where pane !== keeper {
            detach(pane)
            let controller = TerminalWindowController(
                adopting: pane,
                appearance: tabAppearanceSnapshot,
                deferWorkspaceTabPresentation: true)
            delegate.adopt(
                controller: controller, reconcileWindowGrid: false)
            controllersByPaneID[pane.paneId] = controller
            created.append(controller)
        }

        var windowIDsByPaneID: [String: String] = [:]
        var controllersByWindowID: [String: TerminalWindowController] = [:]
        for (paneID, controller) in controllersByPaneID {
            guard let id = delegate.windowGridIdentifier(for: controller) else {
                return false
            }
            windowIDsByPaneID[paneID] = id
            controllersByWindowID[id] = controller
        }
        guard let windowTree = replacingGridLeafIDs(
            in: paneTree, with: windowIDsByPaneID)
        else { return false }

        delegate.windowGridCoordinator.installConvertedTree(
            windowTree, on: screen)
        let wasGridEnabled = Preferences.shared.windowGridEnabled

        let frames = WindowGridLayout.frames(
            for: windowTree,
            in: screen.visibleFrame,
            gap: Preferences.shared.contentMargin,
            scale: screen.backingScaleFactor)
        for (id, controller) in controllersByWindowID {
            if let frame = frames[id] {
                controller.window?.setFrame(frame, display: false)
            }
        }
        for controller in created {
            controller.finishDeferredWorkspaceTabPresentation()
            controller.showWindow(nil)
        }
        sourceWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Showing a new NSWindow may spin AppKit's run loop. If Window Grid is
        // enabled before every converted window is visible, a reconcile can
        // observe only part of the set, discard those missing leaves, and then
        // rebuild a different topology as the remaining windows appear. Read
        // the now-settled workspace IDs and publish the intended tree again
        // before enabling/scheduling any final reconciliation.
        let settledWindowIDsByPaneID = Dictionary(uniqueKeysWithValues:
            controllersByPaneID.compactMap { paneID, controller
                -> (String, String)? in
                delegate.windowGridIdentifier(for: controller).map {
                    (paneID, $0)
                }
            })
        guard settledWindowIDsByPaneID.count == controllersByPaneID.count,
              Set(settledWindowIDsByPaneID.values).count
                == settledWindowIDsByPaneID.count,
              let settledTree = replacingGridLeafIDs(
                in: paneTree, with: settledWindowIDsByPaneID)
        else { return false }
        delegate.windowGridCoordinator.installConvertedTree(
            settledTree, on: screen)
        if !wasGridEnabled {
            // The first install captured the still-original source frame as
            // its manual restore destination. Enable only after all converted
            // windows and their stable workspace identities are visible.
            Preferences.shared.windowGridEnabled = true
        }
        delegate.windowGridCoordinator.scheduleReconcile(
            animated: false, after: 0.12)
        delegate.refreshActionsMenu()
        return true
    }

    /// Collapse native grid windows into one internal split tree. Every donor
    /// releases its complete live root first; only its now-empty NSWindow is
    /// closed, so nested pane layouts and shell processes survive unchanged.
    @discardableResult
    func combineGridWindowsIntoSplits(
        tree: WindowGridNode,
        participants: [WindowGridParticipant]
    ) -> Bool {
        let leafIDs = WindowGridLayout.leafIDs(in: tree)
        guard leafIDs.count > 1,
              Set(leafIDs) == Set(participants.map(\.id)),
              Set(participants.map { ObjectIdentifier($0.controller) }).count
                == participants.count,
              participants.contains(where: { $0.controller === self }),
              participants.allSatisfy({ participant in
                  participant.controller.paneHost.subviews.first != nil
                      && (!participant.controller.panes.isEmpty
                          || !participant.controller.editorPanes.isEmpty)
              })
        else { return false }

        let controllersByID = Dictionary(uniqueKeysWithValues:
            participants.map { ($0.id, $0.controller) })
        var releasedByID: [String: ReleasedGridContent] = [:]
        for id in leafIDs {
            guard let controller = controllersByID[id],
                  let released = controller.releaseRoot()
            else { return false }
            releasedByID[id] = ReleasedGridContent(
                tree: released.tree,
                panes: released.panes,
                editors: released.editors)
        }
        guard let combinedRoot = buildGridSplitTree(
            tree, releasedByID: releasedByID)
        else { return false }

        panes = leafIDs.flatMap { releasedByID[$0]?.panes ?? [] }
        panes.forEach(wire)
        editorPanes = leafIDs.flatMap { releasedByID[$0]?.editors ?? [] }
        for editor in editorPanes {
            editor.setAttached(true, controller: self)
            editor.onTitleChanged = { [weak self] in self?.scheduleChromeUpdate() }
        }
        lastFocused = panes.first
        installRoot(combinedRoot)
        refreshSplitAffordances()
        applyPreferences()
        scheduleChromeUpdate()

        for participant in participants where participant.controller !== self {
            participant.controller.window?.close()
        }
        window?.makeKeyAndOrderFront(nil)
        applyPreservedGridRatiosAfterLayout()
        return true
    }

    private func buildGridSplitTree(
        _ node: WindowGridNode,
        releasedByID: [String: ReleasedGridContent]
    ) -> NSView? {
        switch node {
        case .leaf(let id):
            return releasedByID[id]?.tree
        case .split(let axis, let ratio, let first, let second):
            guard let firstView = buildGridSplitTree(
                    first, releasedByID: releasedByID),
                  let secondView = buildGridSplitTree(
                    second, releasedByID: releasedByID)
            else { return nil }
            let split = ThemedSplitView(frame: .zero)
            split.isVertical = axis == .vertical
            split.dividerStyle = .thin
            split.preservedGridRatio = ratio
            split.addArrangedSubview(firstView)
            split.addArrangedSubview(secondView)
            split.setHoldingPriority(
                NSLayoutConstraint.Priority(250), forSubviewAt: 0)
            split.setHoldingPriority(
                NSLayoutConstraint.Priority(250), forSubviewAt: 1)
            return split
        }
    }

    private func applyPreservedGridRatiosAfterLayout() {
        preservedGridRatioGeneration += 1
        preservedGridRatioResizeWorkItem?.cancel()
        preservedGridRatioResizeWorkItem = nil
        let generation = preservedGridRatioGeneration
        preservedGridRatioDeadline = ProcessInfo.processInfo.systemUptime + 2.5
        for delay in [0.0, 0.15, 0.4, 0.8, 1.4, 2.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      generation == self.preservedGridRatioGeneration else {
                    return
                }
                self.applyPreservedGridRatioPass(
                    finish: delay == 2.2)
            }
        }
    }

    private func schedulePreservedGridRatioPassAfterWindowResize() {
        guard ProcessInfo.processInfo.systemUptime
                <= preservedGridRatioDeadline else { return }
        let generation = preservedGridRatioGeneration
        preservedGridRatioResizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.preservedGridRatioGeneration else { return }
            self.preservedGridRatioResizeWorkItem = nil
            self.applyPreservedGridRatioPass(finish: false)
        }
        preservedGridRatioResizeWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func applyPreservedGridRatioPass(finish: Bool) {
        paneHost.layoutSubtreeIfNeeded()
        applyPreservedGridRatios(in: paneHost)
        updateMinimumWindowHeight()
        updateTopInsets()
        panes.forEach { $0.surface.forceRedraw() }
        if finish { lastFocused?.focus() }
    }

    private func applyPreservedGridRatios(in view: NSView) {
        for child in view.subviews {
            guard let split = child as? ThemedSplitView else { continue }
            split.layoutSubtreeIfNeeded()
            if let ratio = split.preservedGridRatio,
               split.arrangedSubviews.count >= 2 {
                let first = split.arrangedSubviews[0]
                let second = split.arrangedSubviews[1]
                let total = split.isVertical
                    ? split.bounds.width : split.bounds.height
                let usable = max(1, total - split.dividerThickness)
                let firstLength = usable * min(0.999, max(0.001, ratio))
                let position: CGFloat
                if split.isVertical {
                    position = first.frame.midX <= second.frame.midX
                        ? split.bounds.minX + firstLength
                        : split.bounds.maxX - firstLength
                } else {
                    position = first.frame.midY >= second.frame.midY
                        ? split.bounds.maxY - firstLength
                        : split.bounds.minY + firstLength
                }
                split.setPosition(position, ofDividerAt: 0)
                split.layoutSubtreeIfNeeded()
            }
            applyPreservedGridRatios(in: split)
        }
    }

    /// Take over a live pane from another window and splice it in as a split.
    func adopt(_ pane: TerminalPane, nextTo requestedTarget: TerminalPane? = nil,
               vertical: Bool = true) {
        wire(pane)
        if let target = requestedTarget ?? focusedPane ?? panes.last {
            panes.append(pane)
            insert(pane, nextTo: target, vertical: vertical)
        } else {
            panes = [pane]
            installRoot(pane)
        }
        applyPreferences()
        relayoutPanes()
    }

    /// Which edge of the target window a merge lands on.
    enum DockSide: String {
        case left, right, top, bottom
    }

    /// Adopt one live pane on an exact edge. Unlike the older boolean helper,
    /// this preserves the user's directional area-drop choice.
    func adopt(_ pane: TerminalPane, side: DockSide) {
        wire(pane)
        if let target = focusedPane ?? panes.last {
            panes.append(pane)
            let vertical = side == .left || side == .right
            let after = side == .right || side == .bottom
            insert(pane, nextTo: target, vertical: vertical, after: after)
        } else {
            panes = [pane]
            installRoot(pane)
        }
        applyPreferences()
        relayoutPanes(focus: pane)
    }

    /// Detach this window's ENTIRE pane tree (splits preserved) without
    /// terminating any shell, for another window to adopt. Leaves the window
    /// empty — the caller closes it.
    func releaseRoot() -> (tree: NSView, panes: [TerminalPane], editors: [CmdyEditorPane])? {
        guard let root = paneHost.subviews.first,
              !panes.isEmpty || !editorPanes.isEmpty else { return nil }
        let released = panes
        let releasedEditors = editorPanes
        panes = []
        editorPanes = []
        agentSession = nil
        updateNativeToolbarToggleStates()
        root.removeFromSuperview()
        return (root, released, releasedEditors)
    }

    /// Adopt a whole pane tree from another window, splitting the current
    /// layout on the given side (splits inside the tree stay intact).
    func adoptTree(_ tree: NSView, panes newPanes: [TerminalPane],
                   editors newEditors: [CmdyEditorPane] = [], side: DockSide) {
        for pane in newPanes { wire(pane) }
        panes.append(contentsOf: newPanes)
        for editor in newEditors {
            editor.setAttached(true, controller: self)
            editor.onTitleChanged = { [weak self] in self?.scheduleChromeUpdate() }
        }
        editorPanes.append(contentsOf: newEditors)

        guard let currentRoot = paneHost.subviews.first else {
            installRoot(tree)
            finishAdoption()
            return
        }
        let sv = ThemedSplitView(frame: paneHost.bounds)
        sv.isVertical = (side == .left || side == .right)   // side-by-side for L/R
        sv.dividerStyle = .thin
        let theme = effectiveTheme
        sv.themedDividerColor = theme.ns(theme.border)
        currentRoot.removeFromSuperview()
        if side == .left || side == .top {
            sv.addArrangedSubview(tree)
            sv.addArrangedSubview(currentRoot)
        } else {
            sv.addArrangedSubview(currentRoot)
            sv.addArrangedSubview(tree)
        }
        installRoot(sv)
        distributeEvenly(sv)
        finishAdoption()
    }

    private func finishAdoption() {
        applyPreferences()
        scheduleChromeUpdate()
        relayoutPanes()
    }

    /// Merge another window into this one on a side (or nil = as a tab).
    func merge(window other: NSWindow, side: DockSide?) {
        guard let side else {
            window?.addTabbedWindow(other, ordered: .above)
            other.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in self?.scheduleTabPresentationSync() }
            return
        }
        guard let src = other.windowController as? TerminalWindowController,
              let released = src.releaseRoot() else { return }
        adoptTree(released.tree, panes: released.panes, editors: released.editors, side: side)
        other.close()   // panes already released — shells stay alive
        window?.makeKeyAndOrderFront(nil)
    }

    /// Pull every other window's panes into this one as splits.
    func mergeAllWindowsIntoSplits() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        for other in delegate.allControllers where other !== self {
            guard let released = other.releaseRoot() else { continue }
            adoptTree(released.tree, panes: released.panes,
                      editors: released.editors, side: .right)
            other.window?.close()   // panes already released — shells stay alive
        }
        applyPreferences()
        scheduleChromeUpdate()
        relayoutPanes()
    }

    /// Swap `old` for `new` wherever it sits (pane host root or a split view).
    private func replace(_ old: NSView, with new: NSView) {
        if let sv = old.superview as? ThemedSplitView {
            let idx = sv.arrangedSubviews.firstIndex(of: old)!
            sv.removeArrangedSubview(old)
            old.removeFromSuperview()
            sv.insertArrangedSubview(new, at: idx)
        } else {
            old.removeFromSuperview()
            installRoot(new)
        }
    }

    private func distributeEvenly(_ sv: ThemedSplitView) {
        sv.layoutSubtreeIfNeeded()
        let n = sv.arrangedSubviews.count
        guard n > 1 else { return }
        // Equal holding priorities — otherwise NSSplitView lets existing panes
        // keep their sizes and squeezes every newcomer.
        for i in 0..<n {
            sv.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: i)
        }
        let total = sv.isVertical ? sv.bounds.width : sv.bounds.height
        guard total > 1 else { return }
        let step = total / CGFloat(n)
        for i in 0..<(n - 1) {
            sv.setPosition(step * CGFloat(i + 1), ofDividerAt: i)
        }
    }

    /// Full re-layout pass after ANY structural change (split, merge, adopt,
    /// detach): every split re-balances against its final geometry, top insets
    /// recompute, and the Metal views repaint. Mutating mid-layout leaves panes
    /// drifting further out of shape with each added pane.
    private func relayoutPanes(focus pane: TerminalPane? = nil,
                               editor: CmdyEditorPane? = nil) {
        refreshSplitAffordances()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.paneHost.layoutSubtreeIfNeeded()
            self.distributeAll(in: self.paneHost)
            self.updateMinimumWindowHeight()
            self.updateTopInsets()
            self.panes.forEach { $0.surface.forceRedraw() }
            if let editor { editor.focus() }
            else if let terminal = pane ?? self.focusedPane { terminal.focus() }
            else { self.editorPanes.first?.focus() }
        }
    }

    private func refreshSplitAffordances() {
        let visible = panes.count > 1
        panes.forEach { $0.setSplitAffordanceVisible(visible) }
    }

    var paneDividerAppearanceDiagnostic:
        [(vertical: Bool, layoutThickness: CGFloat, hairline: CGFloat?)] {
        var result:
            [(vertical: Bool, layoutThickness: CGFloat, hairline: CGFloat?)] = []
        func collect(_ view: NSView) {
            if let split = view as? ThemedSplitView {
                result.append((
                    split.isVertical,
                    split.themedDividerThickness,
                    split.themedDividerHairlineThickness))
            }
            view.subviews.forEach(collect)
        }
        collect(paneHost)
        return result
    }

    /// Remove a pane whose shell exited (or the user closed). An attached
    /// editor remains usable even when the final shell pane is gone.
    private func removePane(_ pane: TerminalPane) {
        guard panes.contains(where: { $0 === pane }) else { return }
        if agentSession?.pane === pane {
            agentSession?.stop(reason: "The terminal pane closed")
        }
        PluginManager.shared.cancelChannelShellResult(paneID: pane.paneId)
        pane.shutdown()
        detach(pane)
        PluginManager.shared.scheduleProjectExtensionReconcile()
        if panes.isEmpty && editorPanes.isEmpty {
            window?.close()
        } else if panes.isEmpty {
            editorPanes.first?.focus()
        }
    }

    /// Close a pane by its API id (plugin API /v1/panes/<id>/close).
    @discardableResult
    func closePaneById(_ id: String) -> Bool {
        guard let pane = panes.first(where: { $0.paneId == id }) else { return false }
        let decision = PluginManager.shared.decide(.paneClose, payload: [
            "pane": pane.paneId,
            "cwd": pane.currentCwd ?? "",
        ])
        guard decision.action != .cancel else { return false }
        removePane(pane)
        return true
    }

    /// Pull a pane out of the layout WITHOUT touching its shell (breakout /
    /// pane moves). Splits left with one child dissolve.
    private func detach(_ pane: TerminalPane) {
        panes.removeAll { $0 === pane }
        if lastFocused === pane { lastFocused = nil }

        removeFromTree(pane)
        guard !panes.isEmpty || !editorPanes.isEmpty else { return }
        // Removing the first spatial leaf promotes the next pane to chrome
        // ownership immediately, including during live cross-window moves.
        applyPreferences()
        scheduleChromeUpdate()
        relayoutPanes()
    }

    /// Release one live pane for a cross-window move. Unlike close, this never
    /// runs pane-close hooks and never terminates the PTY or shell.
    @discardableResult
    func releasePaneForMove(_ id: String) -> TerminalPane? {
        guard let pane = panes.first(where: { $0.paneId == id }) else { return nil }
        detach(pane)
        return pane
    }

    /// A donor with an attached editor still owns useful content and must stay
    /// open after its selected terminal panes move elsewhere.
    var isEmptyAfterPaneMove: Bool { panes.isEmpty && editorPanes.isEmpty }

    /// Tear one split into a standalone window without touching its process.
    /// The same TerminalPane is adopted synchronously before either window is
    /// presented again, so a cancelled or successful gesture never rebuilds a
    /// shell from serialized state.
    @discardableResult
    func tearOutPane(_ pane: TerminalPane, at drop: NSPoint)
        -> TerminalWindowController? {
        guard panes.count > 1,
              panes.contains(where: { $0 === pane }),
              let delegate = NSApp.delegate as? AppDelegate,
              let sourceWindow = window else { return nil }

        detach(pane)
        let destination = TerminalWindowController(
            adopting: pane, appearance: tabAppearanceSnapshot,
            deferWorkspaceTabPresentation: true)
        delegate.adopt(controller: destination)

        let screen = NSScreen.screens.first { $0.frame.contains(drop) }
            ?? sourceWindow.screen
        if let destinationWindow = destination.window {
            let targetFrame = AppDelegate.sidebarTearOutFrame(
                from: destinationWindow.frame,
                drop: drop,
                visibleFrame: screen?.visibleFrame)
            destinationWindow.setFrame(targetFrame, display: false)
        }
        destination.finishDeferredWorkspaceTabPresentation()
        destination.showWindow(nil)
        destination.window?.makeKeyAndOrderFront(nil)
        delegate.refreshActionsMenu()
        return destination
    }

    private func removeFromTree(_ view: NSView) {
        if let sv = view.superview as? ThemedSplitView {
            sv.removeArrangedSubview(view)
            view.removeFromSuperview()
            // A split with a single child dissolves into its parent.
            if sv.arrangedSubviews.count == 1 {
                let survivor = sv.arrangedSubviews[0]
                sv.removeArrangedSubview(survivor)
                survivor.removeFromSuperview()
                replace(sv, with: survivor)
            }
        } else {
            view.removeFromSuperview()
        }
    }

    /// Break the focused pane out of its split into its own window (`asTab`
    /// keeps it in this window's tab group instead). The shell keeps running —
    /// from there, drag-docking can carry it anywhere.
    func breakOutFocusedPane(asTab: Bool) {
        guard panes.count > 1, let pane = focusedPane else { NSSound.beep(); return }
        detach(pane)
        let c = TerminalWindowController(
            adopting: pane, appearance: tabAppearanceSnapshot)
        (NSApp.delegate as? AppDelegate)?.adopt(controller: c)
        if let host = window, let newWindow = c.window {
            if asTab {
                host.addTabbedWindow(newWindow, ordered: .above)
                DispatchQueue.main.async { c.scheduleTabPresentationSync() }
            } else {
                var origin = host.frame.origin
                origin.x += 60
                origin.y -= 60
                newWindow.setFrameOrigin(origin)
            }
        }
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘W: close the focused pane if there are several, else the window.
    func closePaneOrWindow() {
        if let editor = focusedEditor {
            CmdyEditorManager.shared.requestClose(editor)
        } else if panes.count > 1, let pane = focusedPane {
            _ = closePaneById(pane.paneId)
        } else {
            window?.performClose(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !windowCloseApproved,
           panes.allSatisfy(\.isDisposableEmptySession) {
            // The shell itself is always a live process; an untouched prompt
            // is not meaningful work and should close on the first click.
            windowCloseApproved = true
        }
        if !windowCloseApproved {
            presentWindowCloseConfirmation(for: sender)
            return false
        }
        if let pane = focusedPane ?? panes.first {
            let decision = PluginManager.shared.decide(.paneClose, payload: [
                "pane": pane.paneId,
                "panes": panes.map(\.paneId),
                "cwd": pane.currentCwd ?? "",
                "window": true,
            ])
            guard decision.action != .cancel else {
                windowCloseApproved = false
                return false
            }
        }
        if editorWindowCloseApproved { return true }
        let dirtyEditors = editorPanes.filter(\.isDirty)
        guard !dirtyEditors.isEmpty else { return true }
        CmdyEditorManager.shared.confirmClosing(dirtyEditors) { [weak self] approved in
            guard let self else { return }
            guard approved else {
                self.windowCloseApproved = false
                return
            }
            self.editorWindowCloseApproved = true
            self.window?.performClose(nil)
        }
        return false
    }

    private func presentWindowCloseConfirmation(for sender: NSWindow) {
        guard !windowCloseConfirmationPending else { return }
        windowCloseConfirmationPending = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this window?"
        let runningCount = panes.count
        if runningCount > 1 {
            alert.informativeText = "This will close \(runningCount) terminal panes and stop their running processes."
        } else {
            alert.informativeText = "This will close the terminal and stop its running process."
        }
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        windowCloseConfirmationAlert = alert
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.windowCloseConfirmationPending = false
            self.windowCloseConfirmationAlert = nil
            guard response == .alertFirstButtonReturn, let sender else { return }
            self.windowCloseApproved = true
            // AppKit can ignore performClose while it is still unwinding the
            // sheet completion. Retry on the next main-loop turn, after the
            // sheet has detached, so the destructive button really closes.
            DispatchQueue.main.async { [weak sender] in
                sender?.performClose(nil)
            }
        }
    }

    func windowCloseConfirmationDiagnostic() -> (
        pending: Bool, message: String?, buttons: [String]
    ) {
        (windowCloseConfirmationPending,
         windowCloseConfirmationAlert?.messageText,
         windowCloseConfirmationAlert?.buttons.map(\.title) ?? [])
    }

    func acceptWindowCloseConfirmationForTesting() {
        windowCloseConfirmationAlert?.buttons.first?.performClick(nil)
    }

    func compactGridWidthDiagnostic() -> String {
        let toolbarItemsHidden = compactToolbarGroup?.arrangedSubviews
            .allSatisfy(\.isHidden) ?? false
        return "containerFit=\(container.fittingSize.width) "
            + "workspaceFit=\(workspaceSplitController.view.fittingSize.width) "
            + "centerFit=\(centerSplitController.view.fittingSize.width) "
            + "paneFit=\(paneHost.fittingSize.width) "
            + "toolbarCollapsed=\(toolbarItemsHidden)"
    }

    func focusNextPane(offset: Int = 1) {
        let surfaces: [NSView] = panes.map { $0 as NSView } + editorPanes.map { $0 as NSView }
        let current: NSView? = (focusedEditor as NSView?) ?? (focusedPane as NSView?)
        guard surfaces.count > 1, let current else { return }
        // Spatial order (top-to-bottom, left-to-right), not creation order.
        let ordered = surfaces.sorted { a, b in
            let fa = a.convert(a.bounds, to: nil)
            let fb = b.convert(b.bounds, to: nil)
            if abs(fa.maxY - fb.maxY) > 1 { return fa.maxY > fb.maxY }   // higher first (y-up)
            return fa.minX < fb.minX
        }
        guard let idx = ordered.firstIndex(where: { $0 === current }) else { return }
        focusSurface(ordered[(idx + offset + ordered.count) % ordered.count])
    }

    @discardableResult
    func focusPane(direction: PaneDirection) -> Bool {
        let surfaces: [NSView] = panes.map { $0 as NSView } + editorPanes.map { $0 as NSView }
        let current: NSView? = (focusedEditor as NSView?) ?? (focusedPane as NSView?)
        guard surfaces.count > 1, let current else { return false }
        let origin = current.convert(current.bounds, to: nil)
        let center = NSPoint(x: origin.midX, y: origin.midY)
        let candidates: [(NSView, CGFloat)] = surfaces.compactMap { surface in
            guard surface !== current, !surface.isHidden else { return nil }
            let frame = surface.convert(surface.bounds, to: nil)
            let candidate = NSPoint(x: frame.midX, y: frame.midY)
            let primary: CGFloat
            let secondary: CGFloat
            switch direction {
            case .up: guard candidate.y > center.y + 1 else { return nil }; primary = candidate.y - center.y; secondary = abs(candidate.x - center.x)
            case .down: guard candidate.y < center.y - 1 else { return nil }; primary = center.y - candidate.y; secondary = abs(candidate.x - center.x)
            case .left: guard candidate.x < center.x - 1 else { return nil }; primary = center.x - candidate.x; secondary = abs(candidate.y - center.y)
            case .right: guard candidate.x > center.x + 1 else { return nil }; primary = candidate.x - center.x; secondary = abs(candidate.y - center.y)
            }
            return (surface, primary + secondary * 2)
        }
        guard let target = candidates.min(by: { $0.1 < $1.1 })?.0 else { return false }
        focusSurface(target)
        return true
    }

    private func focusSurface(_ view: NSView) {
        if let pane = view as? TerminalPane { pane.focus() }
        else if let editor = view as? CmdyEditorPane { editor.focus() }
    }

    @discardableResult
    func resizeSplit(direction: PaneDirection, points: CGFloat = 10) -> Bool {
        guard var child: NSView = (focusedEditor as NSView?) ?? (focusedPane as NSView?) else {
            return false
        }
        let wantsVertical = direction == .left || direction == .right
        var parent = child.superview
        while let view = parent {
            if let split = view as? ThemedSplitView, split.isVertical == wantsVertical,
               let index = split.arrangedSubviews.firstIndex(of: child), split.arrangedSubviews.count > 1 {
                let divider = index > 0 ? index - 1 : index
                guard divider < split.arrangedSubviews.count - 1 else { return false }
                let before = split.isVertical
                    ? split.arrangedSubviews[divider].frame.maxX
                    : split.arrangedSubviews[divider].frame.maxY
                let delta: CGFloat = (direction == .right || direction == .up) ? points : -points
                split.setPosition(before + delta, ofDividerAt: divider)
                split.adjustSubviews()
                panes.forEach { $0.surface.forceRedraw() }
                let after = split.isVertical
                    ? split.arrangedSubviews[divider].frame.maxX
                    : split.arrangedSubviews[divider].frame.maxY
                return abs(after - before) > 0.5
            }
            child = view
            parent = view.superview
        }
        return false
    }

    func equalizeSplits() {
        paneHost.layoutSubtreeIfNeeded()
        distributeAll(in: paneHost)
        panes.forEach { $0.surface.forceRedraw() }
    }

    func toggleSplitZoom() {
        if !splitZoomHiddenViews.isEmpty {
            splitZoomHiddenViews.forEach { $0.isHidden = false }
            splitZoomHiddenViews.removeAll()
            paneHost.layoutSubtreeIfNeeded()
            updateNativeToolbarToggleStates()
            if let editor = focusedEditor { editor.focus() } else { focusedPane?.focus() }
            return
        }
        let surfaceCount = panes.count + editorPanes.count
        guard surfaceCount > 1,
              let focused: NSView = (focusedEditor as NSView?) ?? (focusedPane as NSView?) else { return }
        var path = focused
        while let split = path.superview as? ThemedSplitView {
            for sibling in split.arrangedSubviews where sibling !== path {
                sibling.isHidden = true
                splitZoomHiddenViews.append(sibling)
            }
            path = split
        }
        paneHost.layoutSubtreeIfNeeded()
        updateNativeToolbarToggleStates()
        focusSurface(focused)
    }

    @discardableResult
    func selectTab(offset: Int) -> Bool {
        if let delegate = NSApp.delegate as? AppDelegate {
            return delegate.selectWorkspaceTab(from: self, offset: offset)
        }
        guard let window, let tabs = window.tabGroup?.windows, tabs.count > 1,
              let index = tabs.firstIndex(of: window) else { return false }
        tabs[(index + offset + tabs.count) % tabs.count].makeKeyAndOrderFront(nil)
        return true
    }

    @discardableResult
    func selectTab(index: Int) -> Bool {
        if let delegate = NSApp.delegate as? AppDelegate {
            return delegate.selectWorkspaceTab(from: self, index: index)
        }
        guard let tabs = window?.tabGroup?.windows, tabs.indices.contains(index) else { return false }
        tabs[index].makeKeyAndOrderFront(nil)
        return true
    }

    func closeTabGroup() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.closeWorkspaceTabGroup(containing: self)
            return
        }
        let tabs = window?.tabGroup?.windows ?? []
        if tabs.isEmpty { window?.performClose(nil) }
        else { tabs.forEach { $0.performClose(nil) } }
    }

    // MARK: - Find (⌘F)

    func showFindBar(term: String? = nil) {
        findBar.isHidden = false
        updateNativeToolbarToggleStates()
        findBar.beginSearch(in: window, term: term)
    }

    func hideFindBar() {
        findBar.isHidden = true
        updateNativeToolbarToggleStates()
        for p in panes { p.surface.clearSearch() }
        focusedPane?.focus()
    }

    var isFindVisible: Bool { !findBar.isHidden }
    @discardableResult
    func stepFind(forward: Bool) -> Bool { !findBar.isHidden && findBar.step(forward: forward) }

    func showInspector() {
        Preferences.shared.workspaceInspectorVisible.toggle()
    }

    func toggleNavigator() { Preferences.shared.workspaceNavigatorVisible.toggle() }

    func toggleFocusMode() {
        isWorkspaceFocusMode.toggle()
        applyEdgeInsets()
        applyFocusModePresentation()
        refreshWorkspaceFrame()
        updateNativeToolbarToggleStates()
    }

    private func applyFocusModePresentation() {
        let activePane = focusedPane
        let activeEditor = focusedEditor
        for pane in panes {
            pane.alphaValue = !isWorkspaceFocusMode || (activeEditor == nil && pane === activePane)
                ? 1 : 0.18
        }
        for editor in editorPanes {
            editor.alphaValue = !isWorkspaceFocusMode || editor === activeEditor ? 1 : 0.18
        }
    }

    @objc private func workspaceFrameChanged(_ notification: Notification) {
        // Pane updates are scoped to one workspace. NotificationCenter still
        // delivers the event to every controller, but unrelated windows must
        // not rebuild their Navigator/Inspector snapshots. Sidebar-backed tabs
        // remain linked: an update from a hidden tab refreshes the selected
        // controller in that same workspace.
        if notification.name == .cmdyWorkspaceFrameChanged,
           let source = notification.object as? TerminalWindowController,
            source !== self {
            guard let delegate = NSApp.delegate as? AppDelegate,
                  delegate.controllersShareWorkspace(self, source)
            else { return }
        }
        refreshWorkspaceFrame()
    }

    private func refreshWorkspaceFrame() {
        // Sidebar tabs are separate hidden NSWindows. Only the window the user
        // can see owns the shared Navigator/Inspector snapshot; rebuilding the
        // same N-tab model in all N hidden controllers turns updates into O(N²).
        guard window?.isVisible == true, window?.isMiniaturized == false else {
            return
        }
        // Hidden rails have no model consumer. Building their tab previews,
        // selection summaries, scrollback resources, extension sections, and
        // Git state on every pane update was pure main-thread work in ordinary
        // terminal-only windows and multiplied directly with grid size.
        guard workspaceRailsVisible else { return }
        if liveResizeWorkspaceState != nil || window?.inLiveResize == true {
            workspaceFrameRefreshAfterLiveResize = true
            return
        }
        let theme = effectiveTheme
        let extensionContexts = workspaceExtensionContexts()

        if workspaceNavigatorVisible {
            let delegate = NSApp.delegate as? AppDelegate
            let tabControllers = delegate?.workspaceTabs(containing: self)
                ?? [self]
            let selectedController = delegate?.selectedWorkspaceTab(
                containing: self) ?? self
            let tabItems = tabControllers.enumerated().compactMap {
            index, controller -> WorkspaceRailItem? in
            guard let tabWindow = controller.window else { return nil }
            let pane = controller.focusedPane ?? controller.panes.first
            let selected = controller === selectedController
            let title: String
            if let pane, !pane.oscTitle.isEmpty {
                title = pane.oscTitle
            } else if let cwd = pane?.currentCwd {
                title = (cwd as NSString).lastPathComponent
            } else {
                title = "Terminal tab"
            }
            let wantsAttention = controller.panes.contains { $0.wantsAttention }
            let isRunning = controller.panes.contains { $0.blockStore.isRunning }
            let state: WorkspaceRailStatus = wantsAttention ? .attention
                : isRunning ? .active : .neutral
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let cwd = pane?.currentCwd?.replacingOccurrences(of: home, with: "~") ?? "starting…"
            let summary = controller.panes.count > 1 ? ["\(controller.panes.count) panes"] : []
            let detail = ([cwd] + summary).joined(separator: " · ")
            return WorkspaceRailItem(
                id: "tab-\(tabWindow.windowNumber)",
                title: title, detail: detail, badge: "\(index + 1)",
                status: state, selected: selected,
                tabAppearance: controller.tabAppearanceControl(),
                tabPreview: controller.workspaceTabPreview(),
                tabDragAction: { [weak controller] in
                    guard let controller else { return }
                    WindowDock.shared.beginSidebarTabDrag(controller)
                },
                action: { [weak self, weak controller, weak pane] in
                    guard let self, let controller else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    (NSApp.delegate as? AppDelegate)?
                        .activateWorkspaceTab(controller, from: self)
                    pane?.focus()
                })
            }
            let navigatorExtensions = workspaceExtensionSections(
                PluginManager.shared.workspaceContributions(
                    location: .navigator, windowNumber: window?.windowNumber,
                    paneID: focusedPane?.paneId, contexts: extensionContexts))
            navigatorModel.update(
                sections: [
                    WorkspaceRailSection(
                        id: "tabs", title: "", items: tabItems),
                ] + navigatorExtensions,
                emptyMessage: "Open a tab to begin.", theme: theme)
        }

        guard workspaceInspectorVisible else { return }
        var inspectorSections: [WorkspaceRailSection] = []
        if let pane = focusedPane {
            var selectionSection: WorkspaceRailSection?
            var projectSection: WorkspaceRailSection?
            var commandSection: WorkspaceRailSection?
            var resourceSection: WorkspaceRailSection?
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let cwd = pane.currentCwd?
                .replacingOccurrences(of: home, with: "~") ?? "Unknown folder"

            let selection = pane.surface.selectedText().trimmingCharacters(in: .whitespacesAndNewlines)
            if !selection.isEmpty {
                let preview = selection.count > 240
                    ? String(selection.prefix(240)) + "…" : selection
                let selectionUnit = selection.count == 1 ? "character" : "characters"
                selectionSection = WorkspaceRailSection(
                    id: "selection", title: "Selection", items: [
                        WorkspaceRailItem(
                            id: "selected-text",
                            title: "\(selection.count) \(selectionUnit) selected",
                            detail: preview,
                            presentation: .summary,
                            actions: [
                                WorkspaceRailAction(
                                    id: "copy", title: "Copy",
                                    action: { Self.copyToPasteboard(selection) }),
                                WorkspaceRailAction(
                                    id: "command", title: "Use as Command",
                                    action: { [weak pane] in
                                        pane?.replacePromptInput(with: selection)
                                        pane?.focus()
                                    }),
                                WorkspaceRailAction(
                                    id: "explain", title: "Explain",
                                    action: { [weak self, weak pane] in
                                        guard let pane else { return }
                                        self?.explainSelection(selection, in: pane)
                                    }),
                            ])
                    ])
            }

            let runningBlock = pane.blockStore.blocks.last(where: \.running)
            if let runningBlock {
                let command = runningBlock.commandText.isEmpty
                    ? "Command \(runningBlock.index)" : runningBlock.commandText
                inspectorSections.append(WorkspaceRailSection(
                    id: "now", title: "Now", items: [
                        WorkspaceRailItem(
                            id: "now-running",
                            title: command,
                            detail: "Running in \(cwd)",
                            status: .active,
                            presentation: .summary,
                            startedAt: runningBlock.startedAt,
                            actions: [
                                WorkspaceRailAction(
                                    id: "stop", title: "Stop",
                                    action: { [weak pane] in
                                        pane?.surface.send(txt: "\u{3}")
                                        pane?.focus()
                                    }),
                            ])
                    ]))
            } else {
                let attention = pane.wantsAttention && !pane.attentionText.isEmpty
                inspectorSections.append(WorkspaceRailSection(
                    id: "now", title: "Now", items: [
                        WorkspaceRailItem(
                            id: "now-ready",
                            title: attention ? "Needs attention" : "Ready",
                            detail: attention ? pane.attentionText : cwd,
                            status: attention ? .attention : .neutral,
                            presentation: .summary)
                    ]))
            }

            if let block = pane.blockStore.lastCompletedBlock {
                let command = block.commandText.isEmpty ? "Command \(block.index)" : block.commandText
                let succeeded = block.exitCode == 0
                let output = pane.outputText(for: block)
                var actions = [
                    WorkspaceRailAction(
                        id: "copy", title: "Copy Output",
                        enabled: !output.isEmpty,
                        action: { Self.copyToPasteboard(output) }),
                    WorkspaceRailAction(
                        id: "rerun", title: "Run Again",
                        enabled: !block.commandText.isEmpty,
                        action: { [weak self] in self?.runCommand(block.commandText) }),
                    WorkspaceRailAction(
                        id: "explain", title: "Explain",
                        action: { [weak self, weak pane] in
                            guard let pane else { return }
                            self?.explain(block: block, in: pane)
                        }),
                    WorkspaceRailAction(
                        id: "jump", title: "Jump",
                        action: { [weak pane] in pane?.jumpToRow(block.commandRow) }),
                ]
                if !succeeded {
                    actions.append(WorkspaceRailAction(
                        id: "fix", title: "Suggest Fix",
                        action: { [weak self, weak pane] in
                            guard let pane else { return }
                            self?.fix(block: block, in: pane)
                        }))
                }
                commandSection = WorkspaceRailSection(
                    id: "command", title: "Last Command", items: [
                        WorkspaceRailItem(
                            id: "last-command",
                            title: command,
                            detail: succeeded ? "Completed" : "Exit \(block.exitCode ?? -1)",
                            status: succeeded ? .success : .failure,
                            presentation: .summary,
                            startedAt: block.startedAt,
                            finishedAt: block.finishedAt,
                            actions: actions),
                    ])
            }

            let resourceBlock = runningBlock ?? pane.blockStore.lastCompletedBlock
            if let resourceBlock {
                let blockOutput = pane.outputText(for: resourceBlock)
                // Shell integrations can occasionally report a zero-row block
                // for extremely fast commands. Recent visible output is still
                // safe recognition input; actions are only created for valid
                // URLs and paths that exist.
                let output = blockOutput.isEmpty
                    ? pane.recentScrollbackText(maxLines: 80) : blockOutput
                let currentResources = WorkspaceOutputRecognizer.resources(
                    in: output, cwd: pane.currentCwd)
                let resources = Self.calmWorkspaceResources(
                    current: currentResources,
                    previous: workspaceResourcesByPane[pane.paneId] ?? [],
                    commandRunning: runningBlock != nil)
                if !currentResources.isEmpty {
                    workspaceResourcesByPane[pane.paneId] = currentResources
                } else if runningBlock == nil {
                    workspaceResourcesByPane.removeValue(forKey: pane.paneId)
                }
                if !resources.isEmpty {
                    resourceSection = WorkspaceRailSection(
                        id: "resources", title: "Detected", items:
                            resources.enumerated().map { index, resource in
                                workspaceResourceItem(
                                    resource, index: index)
                            })
                }
            } else {
                workspaceResourcesByPane.removeValue(forKey: pane.paneId)
            }

            requestGitWorkspaceState(for: pane.currentCwd)
            if let git = gitWorkspaceState, git.cwd == pane.currentCwd {
                let changes = git.changes.compactMap(WorkspaceGitChange.parse)
                var items = [
                    WorkspaceRailItem(
                        id: "git-branch", title: "Branch", detail: git.branch,
                        badge: changes.isEmpty ? "CLEAN" : "DIRTY",
                        status: changes.isEmpty ? .success : .attention),
                    WorkspaceRailItem(
                        id: "git-summary", title: "Working Tree",
                        detail: changes.isEmpty ? "Clean"
                            : "\(changes.count) changed file\(changes.count == 1 ? "" : "s")",
                        status: changes.isEmpty ? .success : .attention),
                ]
                items.append(contentsOf: changes.prefix(5).enumerated().map { index, change in
                    WorkspaceRailItem(
                        id: "git-change-\(index)",
                        title: change.path,
                        detail: "\(change.displayStatus) · show diff",
                        status: .attention,
                        action: { [weak self] in
                            self?.runCommand(self?.gitDiffCommand(for: change) ?? "")
                        })
                })
                if changes.count > 5 {
                    items.append(WorkspaceRailItem(
                        id: "git-more",
                        title: "+ \(changes.count - 5) more",
                        detail: "Show Status lists every change"))
                }
                items.append(WorkspaceRailItem(
                    id: "git-actions",
                    title: "",
                    actions: [
                        WorkspaceRailAction(
                            id: "status", title: "Show Status",
                            action: { [weak self] in
                                self?.runCommand("git status --short --branch")
                            }),
                        WorkspaceRailAction(
                            id: "diff", title: "Show Diff",
                            enabled: !changes.isEmpty,
                            action: { [weak self] in
                                self?.runCommand("git diff --stat; git diff")
                            }),
                        WorkspaceRailAction(
                            id: "folder", title: "Reveal Folder",
                            action: { [weak pane] in
                                guard let cwd = pane?.currentCwd else { return }
                                NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                            }),
                        WorkspaceRailAction(
                            id: "refresh", title: "Refresh",
                            action: { [weak self, weak pane] in
                                self?.requestGitWorkspaceState(
                                    for: pane?.currentCwd, force: true)
                            }),
                    ]))
                projectSection = WorkspaceRailSection(
                    id: "project", title: "Project", items: items)
            }

            // Semantic order is stable even as output changes the contents.
            // Cards never trade places just because a command printed a line.
            inspectorSections.append(contentsOf: [
                selectionSection,
                projectSection,
                commandSection,
                resourceSection,
            ].compactMap { $0 })

            inspectorSections.append(contentsOf: workspaceExtensionSections(
                PluginManager.shared.workspaceContributions(
                    location: .inspector, windowNumber: window?.windowNumber,
                    paneID: pane.paneId, contexts: extensionContexts)))

            let engine = pane.surface.engine
            inspectorSections.append(WorkspaceRailSection(
                id: "details", title: "Details", items: [
                    WorkspaceRailItem(
                        id: "pane-directory", title: "Directory", detail: cwd),
                    WorkspaceRailItem(
                        id: "pane-grid", title: "Grid",
                        detail: "\(engine.cols) × \(engine.rows)"),
                    WorkspaceRailItem(
                        id: "pane-scrollback", title: "Scrollback",
                        detail: "\(engine.bufferLineCount) rows"),
                    WorkspaceRailItem(
                        id: "pane-renderer", title: "Renderer", detail: "Metal"),
                ]))
        }
        inspectorModel.update(
            sections: inspectorSections,
            emptyMessage: "Focus a terminal pane to inspect its context.",
            theme: theme)
    }

    /// While a new command is still running, an empty partial scan is not a
    /// meaningful replacement for already-published resources. Keep the stable
    /// card until settled output contains a replacement or the command ends.
    static func calmWorkspaceResources(
        current: [WorkspaceOutputResource],
        previous: [WorkspaceOutputResource],
        commandRunning: Bool
    ) -> [WorkspaceOutputResource] {
        if !current.isEmpty { return current }
        return commandRunning ? previous : []
    }

    /// Capture the current terminal viewport as text plus normalized pane
    /// geometry. Rail snapshots are rebuilt on meaningful workspace events,
    /// avoiding one permanently-running timer per tab miniature.
    fileprivate func workspaceTabPreview() -> WorkspaceTabPreview? {
        guard !panes.isEmpty else { return nil }
        let bounds = paneHost.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let previewPanes = panes.map { pane -> WorkspaceTabPreview.Pane in
            let rect = pane.convert(pane.bounds, to: paneHost)
            let normalized = CGRect(
                x: max(0, min(1, rect.minX / bounds.width)),
                y: max(0, min(1, (bounds.maxY - rect.maxY) / bounds.height)),
                width: max(0, min(1, rect.width / bounds.width)),
                height: max(0, min(1, rect.height / bounds.height)))
            let engine = pane.surface.engine
            let lines = (0..<max(1, engine.rows)).map { row in
                engine.scrollbackLineText(row: engine.currentTopRow + row) ?? ""
            }
            return WorkspaceTabPreview.Pane(frame: normalized, lines: lines)
        }
        let theme = effectiveTheme
        return WorkspaceTabPreview(
            panes: previewPanes,
            background: theme.ns(theme.background),
            foreground: theme.ns(theme.foreground),
            divider: theme.ns(theme.border).withAlphaComponent(0.75))
    }

    private func workspaceResourceItem(
        _ resource: WorkspaceOutputResource,
        index: Int
    ) -> WorkspaceRailItem {
        switch resource.kind {
        case .web:
            return WorkspaceRailItem(
                id: "resource-web-\(index)",
                title: "Open \(resource.displayName)",
                detail: resource.url.absoluteString,
                status: .active,
                action: { [weak self] in
                    TerminalLinkOpener.open(
                        resource.url, windowNumber: self?.window?.windowNumber)
                })
        case .file:
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: resource.url.path, isDirectory: &isDirectory)
            return WorkspaceRailItem(
                id: "resource-file-\(index)",
                title: "\(isDirectory.boolValue ? "Open" : "Reveal") \(resource.displayName)",
                detail: resource.url.path,
                action: {
                    if isDirectory.boolValue {
                        NSWorkspace.shared.open(resource.url)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([resource.url])
                    }
                })
        }
    }

    private func tabAppearanceControl() -> WorkspaceTabAppearanceControl {
        let preferences = Preferences.shared
        let global = Self.globalAppearanceSelection
        let themes = [
            WorkspaceRailPickerOption(
                id: global, title: "Global — \(preferences.themeName)")
        ] + Theme.names.map { WorkspaceRailPickerOption(id: $0, title: $0) }
        let shaderNames = Preferences.shaderNames + UserShaders.names
        let shaders = [
            WorkspaceRailPickerOption(
                id: global, title: "Global — \(preferences.shaderName)")
        ] + shaderNames.map { name in
            WorkspaceRailPickerOption(
                id: name,
                title: name.hasPrefix("user/")
                    ? String(name.dropFirst("user/".count)) : name)
        }
        let globalFontTitle = TerminalAppearanceFontCatalog.displayName(
            for: preferences.fontName)
        let fonts = [
            WorkspaceRailPickerOption(
                id: global,
                title: "Global — \(globalFontTitle)")
        ] + TerminalAppearanceFontCatalog.choices.map { font in
            WorkspaceRailPickerOption(id: font.name, title: font.title)
        }
        return WorkspaceTabAppearanceControl(
            theme: WorkspaceRailPicker(
                selection: tabAppearance.themeName ?? global,
                options: themes,
                onChange: { [weak self] selection in
                    self?.setTabTheme(selection == global ? nil : selection)
                }),
            shader: WorkspaceRailPicker(
                selection: tabAppearance.shaderName ?? global,
                options: shaders,
                onChange: { [weak self] selection in
                    self?.setTabShader(selection == global ? nil : selection)
                }),
            font: WorkspaceRailPicker(
                selection: tabAppearance.fontName ?? global,
                options: fonts,
                onChange: { [weak self] selection in
                    self?.setTabFont(selection == global ? nil : selection)
                }))
    }

    func setTabTheme(_ name: String?) {
        let validated = TerminalTabAppearance.restored(
            themeName: name, shaderName: nil).themeName
        guard tabAppearance.themeName != validated else { return }
        tabAppearance.themeName = validated
        applyPreferences()
    }

    func setTabShader(_ name: String?) {
        let validated = TerminalTabAppearance.restored(
            themeName: nil, shaderName: name).shaderName
        guard tabAppearance.shaderName != validated else { return }
        tabAppearance.shaderName = validated
        applyPreferences()
    }

    func setTabFont(_ name: String?) {
        let validated = TerminalAppearanceFontCatalog.validated(name)
        guard tabAppearance.fontName != validated else { return }
        tabAppearance.fontName = validated
        applyPreferences()
    }

    func restoreTabAppearance(_ appearance: TerminalTabAppearance) {
        let validated = TerminalTabAppearance.restored(
            themeName: appearance.themeName,
            shaderName: appearance.shaderName,
            fontName: appearance.fontName)
        guard tabAppearance != validated else { return }
        tabAppearance = validated
        applyPreferences()
    }

    func setPaneAppearanceForTesting(
        _ pane: TerminalPane,
        themeName: String?, shaderName: String?, fontName: String?
    ) {
        guard panes.contains(where: { $0 === pane }) else { return }
        pane.restoreAppearance(TerminalTabAppearance.restored(
            themeName: themeName, shaderName: shaderName,
            fontName: fontName))
        paneAppearanceDidChange(pane)
    }

    private func gitDiffCommand(for change: WorkspaceGitChange) -> String {
        let path = Self.shellQuote(change.path)
        if change.status == "??" {
            return "git status --short -- \(path)"
        }
        return change.prefersCachedDiff
            ? "git diff --cached -- \(path)"
            : "git diff -- \(path)"
    }

    private static func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func explainSelection(_ selection: String, in pane: TerminalPane) {
        let panel = pane.presentInlinePanel()
        panel.configureText(
            title: "Explain selection",
            body: "Looking at the selected terminal text…",
            hint: "local-first assistance · esc close")
        Task { [weak panel, weak pane] in
            let response = await ErrorAssistant.explain(
                command: "selected terminal text",
                output: selection,
                exitCode: nil,
                cwd: pane?.currentCwd)
            await MainActor.run {
                panel?.configureText(
                    title: "Explain selection",
                    body: response.text,
                    hint: "\(response.source.label) · esc close")
            }
        }
    }

    private func workspaceExtensionContexts() -> Set<ExtensionWorkspaceContext> {
        guard let pane = focusedPane else { return [] }
        var contexts: Set<ExtensionWorkspaceContext> = [.pane]
        if !pane.blockStore.blocks.isEmpty { contexts.insert(.command) }
        if !pane.surface.selectedText().isEmpty { contexts.insert(.selection) }
        if pane.extensionSurfaceView != nil { contexts.insert(.surface) }
        return contexts
    }

    private func requestGitWorkspaceState(for cwd: String?, force: Bool = false) {
        guard let cwd, !cwd.isEmpty else {
            gitWorkspaceState = nil
            gitWorkspaceRequestCwd = nil
            return
        }
        if !force, gitWorkspaceRequestCwd == cwd { return }
        gitWorkspaceRequestCwd = cwd
        gitWorkspaceGeneration += 1
        let generation = gitWorkspaceGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = try? ProcessCapture.run(
                URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", cwd, "status", "--short", "--branch"],
                timeout: 2, outputLimit: 32 * 1_024)
            let state: GitWorkspaceState? = result.flatMap { captured in
                guard captured.terminationStatus == 0 else { return nil }
                let lines = captured.output.split(separator: "\n").map(String.init)
                guard let head = lines.first, head.hasPrefix("## ") else { return nil }
                let tracking = String(head.dropFirst(3))
                let branch = tracking.components(separatedBy: "...").first ?? tracking
                return GitWorkspaceState(cwd: cwd, branch: branch,
                                         changes: Array(lines.dropFirst()))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.gitWorkspaceGeneration else { return }
                self.gitWorkspaceState = state
                self.scheduleChromeUpdate()
            }
        }
    }

    private func workspaceExtensionSections(
        _ contributions: [ExtensionWorkspaceContribution]
    ) -> [WorkspaceRailSection] {
        contributions.map { contribution in
            let items = contribution.items.map { item -> WorkspaceRailItem in
                let status: WorkspaceRailStatus
                switch item.status {
                case .neutral: status = .neutral
                case .active: status = .active
                case .attention: status = .attention
                case .success: status = .success
                case .failure: status = .failure
                }
                return WorkspaceRailItem(
                    id: "\(contribution.id).\(item.id)", title: item.title,
                    detail: item.detail, badge: item.badge, status: status,
                    enabled: item.isEnabled,
                    action: item.action == nil ? nil : {
                        PluginManager.shared.activateWorkspaceContribution(
                            owner: contribution.owner, id: contribution.id,
                            itemID: item.id)
                    })
            }
            return WorkspaceRailSection(
                id: "extension.\(contribution.extensionID).\(contribution.id)",
                title: contribution.title, items: items)
        }
    }

    enum ScreenFileAction { case copy, paste, open }
    @discardableResult
    func writeScreenFile(_ action: ScreenFileAction) -> Bool {
        guard let pane = focusedPane else { return false }
        let engine = pane.surface.engine
        let text = (0..<engine.rows).compactMap {
            engine.scrollbackLineText(row: engine.currentTopRow + $0)
        }.joined(separator: "\n") + "\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(ProductIdentity.current.slug)-screen-\(UUID().uuidString).txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { return false }
        switch action {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        case .paste: pane.surface.send(txt: url.path)
        case .open: NSWorkspace.shared.open(url)
        }
        return true
    }

    // MARK: - Preferences / theme

    @objc private func preferencesChanged() { applyPreferences() }

    /// The top/left-most terminal leaf in the actual split hierarchy owns the
    /// tab's visual chrome. Creation order is deliberately ignored: panes can
    /// be inserted on the left/top or moved between windows without changing
    /// their identity.
    private var firstTerminalPaneInSpatialTree: TerminalPane? {
        guard let root = paneHost.subviews.first else { return nil }
        paneHost.layoutSubtreeIfNeeded()
        return firstTerminalPane(in: root)
    }

    private func firstTerminalPane(in view: NSView) -> TerminalPane? {
        if let pane = view as? TerminalPane { return pane }
        guard let split = view as? ThemedSplitView else {
            for child in view.subviews {
                if let pane = firstTerminalPane(in: child) { return pane }
            }
            return nil
        }
        let indexed = split.arrangedSubviews.enumerated().map {
            (index: $0.offset, view: $0.element,
             frame: $0.element.convert($0.element.bounds, to: paneHost))
        }
        let ordered = indexed.sorted { lhs, rhs in
            if split.isVertical, abs(lhs.frame.minX - rhs.frame.minX) > 0.5 {
                return lhs.frame.minX < rhs.frame.minX
            }
            if !split.isVertical, abs(lhs.frame.maxY - rhs.frame.maxY) > 0.5 {
                return lhs.frame.maxY > rhs.frame.maxY
            }
            return lhs.index < rhs.index
        }
        for child in ordered {
            if let pane = firstTerminalPane(in: child.view) { return pane }
        }
        return nil
    }

    var resolvedChromeAppearanceForTesting: ResolvedChromeAppearance {
        let pane = firstTerminalPaneInSpatialTree
        return ResolvedChromeAppearance(
            sourcePaneID: pane?.paneId,
            themeName: pane?.resolvedThemeName(inherited: selectedThemeName)
                ?? selectedThemeName,
            shaderName: pane?.resolvedShaderName(inherited: selectedShaderName)
                ?? selectedShaderName)
    }

    private var effectiveTheme: Theme {
        let preferences = Preferences.shared
        let base = Theme.named(resolvedChromeAppearanceForTesting.themeName)
        guard let hex = preferences.cursorColorOverrideHex,
              let cursor = Theme.hex(hex) else { return base }
        return base.replacingCursor(with: cursor)
    }

    private var effectiveShaderName: String {
        resolvedChromeAppearanceForTesting.shaderName
    }

    private func effectiveTheme(for pane: TerminalPane) -> Theme {
        let preferences = Preferences.shared
        let base = Theme.named(
            pane.resolvedThemeName(inherited: selectedThemeName))
        guard let hex = preferences.cursorColorOverrideHex,
              let cursor = Theme.hex(hex) else { return base }
        return base.replacingCursor(with: cursor)
    }

    private func effectiveShaderName(for pane: TerminalPane) -> String {
        pane.resolvedShaderName(inherited: selectedShaderName)
    }

    private func effectiveFontName(for pane: TerminalPane) -> String {
        pane.resolvedFontName(inherited: selectedFontName)
    }

    private func applyPreferences(to pane: TerminalPane) {
        pane.applyPreferences(
            theme: effectiveTheme(for: pane),
            shaderName: effectiveShaderName(for: pane),
            fontName: effectiveFontName(for: pane))
    }

    private func paneAppearanceDidChange(_ pane: TerminalPane) {
        if pane === firstTerminalPaneInSpatialTree {
            // The source leaf changed: refresh both its terminal surface and
            // every piece of native window/tab chrome derived from it.
            applyPreferences()
        } else {
            // A non-source leaf is genuinely local. Do not churn the window or
            // repaint unrelated panes for a right-click appearance change.
            applyPreferences(to: pane)
        }
        NotificationCenter.default.post(
            name: .cmdyWorkspaceFrameChanged, object: self)
    }

    private func applyPreferences() {
        let p = Preferences.shared
        let theme = effectiveTheme
        lastAppliedChromeAppearanceForTesting =
            resolvedChromeAppearanceForTesting

        // The pane measures how far its edge-to-edge inline panel must extend
        // through the window's bottom inset. Apply and resolve that geometry
        // first so a live Window Inset preview cannot combine the new panel
        // padding with the previous bottom position.
        applyEdgeInsets()
        paneHost.layoutSubtreeIfNeeded()

        for pane in panes { applyPreferences(to: pane) }
        for editor in editorPanes { editor.applyPreferences(theme: theme) }
        embeddedBrowserController.applyTheme(theme)
        windowInlinePanel?.themeOverride = theme
        windowInlinePanel?.refreshMetrics()
        updateMinimumWindowHeight()

        // The native split shell is full-height. The title strip / tab bar
        // float over the center content and the terminal grid shifts down via
        // topContentInset, preserving the existing edge-to-edge Metal surface.
        updateCompactChrome()
        applyChromeVisibility()
        DispatchQueue.main.async { [weak self] in self?.updateTopInsets() }

        // With the border hidden the only chrome left is the top strip, which
        // takes the terminal background so it melts into the picture.
        let band = theme.background
        let opacity = CGFloat(p.opacity)
        let translucent = opacity < 0.999

        // One device pixel on the current display, with a theme-relative ink.
        // Drawing only the native split divider avoids the doubled edge that
        // made high-contrast and inverted themes look heavier.
        updateWorkspaceDividerAppearance(theme: theme)
        updatePaneDividerAppearance(
            in: paneHost,
            theme: theme,
            background: theme.ns(theme.background).withAlphaComponent(
                translucent ? opacity : 1))

        // Transparency: non-opaque window, alpha on the band + terminal background,
        // optional frost (blur) of whatever is behind the window.
        window?.isOpaque = !translucent
        window?.backgroundColor = translucent ? .clear : theme.ns(band)
        window?.hasShadow = true
        container.layer?.backgroundColor = theme.ns(band).withAlphaComponent(translucent ? opacity : 1).cgColor
        if translucent {
            for pane in panes {
                pane.surface.nativeBackgroundColor =
                    theme.ns(theme.background).withAlphaComponent(opacity)
            }
        }
        if translucent && p.blur {
            if blurView == nil {
                let v = NSVisualEffectView()
                v.blendingMode = .behindWindow
                v.state = .active
                v.material = .underWindowBackground
                v.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(v, positioned: .below, relativeTo: nil)
                NSLayoutConstraint.activate([
                    v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    v.topAnchor.constraint(equalTo: container.topAnchor),
                    v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
                blurView = v
            }
            blurView?.isHidden = false
        } else {
            blurView?.isHidden = true
        }

        // Title uses the terminal background color (sits on the border band).
        // When the band IS the bg (hidden border / CRT), fall back to foreground.
        let titleColor = theme.ns(theme.foreground).withAlphaComponent(0.7)
        titleLabel.textColor = titleColor
        inspectorTitleLabel.textColor = titleColor
        updateNativeToolbarTint(titleColor)
        findBar.applyTheme(theme, onBorder: false)

        scheduleChromeUpdate()   // refresh the GPU/CPU badge after any change
    }

    private func updateMinimumWindowHeight() {
        guard let window else { return }
        let rowHeight = panes.first?.surface.cellSize.height
            ?? editorPanes.first?.contentLineHeight
            ?? 1
        var minimumSize = window.minSize
        minimumSize.height = WindowChromeLayout.minimumWindowHeight(
            rowHeight: rowHeight,
            contentMargin: Preferences.shared.contentMargin,
            backingScale: window.backingScaleFactor)
        window.minSize = minimumSize
    }

    /// In flush mode the chrome (title strip + tab bar) floats over the shader;
    /// panes that touch the window top shift their grid down so text clears it.
    static func flushTopContentInset(measuredChrome: CGFloat,
                                     toolbarBand: CGFloat,
                                     contentSpacing: CGFloat = 0) -> CGFloat {
        max(measuredChrome, toolbarBand) + max(0, contentSpacing)
    }

    /// Chromium sits beneath the complete title band with one physical pixel
    /// of breathing room. Expressing the hairline in points keeps it crisp on
    /// both Retina and standard-density displays.
    static func embeddedBrowserTopContentInset(
        toolbarBand: CGFloat,
        titleBandVisible: Bool,
        backingScale: CGFloat
    ) -> CGFloat {
        guard titleBandVisible else { return 0 }
        return max(0, toolbarBand) + 1 / max(1, backingScale)
    }

    private func updateTopInsets() {
        guard let window = window else { return }
        let p = Preferences.shared
        let margin = p.contentMargin      // the top part of the window inset
        // Chrome height measured from the top of the content area.
        let chrome = max(0, container.bounds.maxY - window.contentLayoutRect.maxY)
        let contentViews: [NSView] = panes.map { $0 as NSView }
            + editorPanes.map { $0 as NSView }
        for view in contentViews {
            var inset = margin
            let topInContainer = view.convert(view.bounds, to: container).maxY
            let touchesTop = topInContainer >= container.bounds.maxY - 0.5
            if compactChrome {
                // The title and window buttons are both gone. Preserve a real
                // native tab bar if one is visible; otherwise reclaim the top.
                if touchesTop, window.tabGroup?.isTabBarVisible == true {
                    inset += chrome
                }
            } else if touchesTop {
                // contentLayoutRect briefly reports zero/partial chrome while
                // macOS zooms or rearranges native tabs. Never let that
                // transient collapse put row zero beneath our custom title.
                // `chrome` already measures from the window edge. Window Inset
                // must not create another gap beneath a visible toolbar.
                inset = Self.flushTopContentInset(
                    measuredChrome: chrome,
                    toolbarBand: topInset,
                    contentSpacing: workspaceRailsVisible
                        ? WorkspaceChromeMetrics.terminalTopSpacing
                        : 0)
            }
            if let pane = view as? TerminalPane {
                pane.setTopContentInset(inset)
            } else if let editor = view as? CmdyEditorPane {
                editor.setTopContentInset(inset)
            }
        }
        // Unlike terminal text, Chromium owns its complete rectangular surface.
        // Keep it immediately below the toolbar with a one-device-pixel
        // separator, while preserving edge-to-edge left/right/bottom docking.
        let browserTopInset = Self.embeddedBrowserTopContentInset(
            toolbarBand: topInset,
            titleBandVisible: !titleBand.isHidden,
            backingScale: window.backingScaleFactor)
        embeddedBrowserController.topContentInset = browserTopInset
        centerSplitView.themedDividerTopInset = browserTopInset
        refreshEmbeddedBrowserChromeExclusion()
    }

    func windowDidResize(_ notification: Notification) {
        updateCompactChrome()
        applyEdgeInsets()
        if let state = liveResizeWorkspaceState {
            applyWorkspaceRailGeometry(state.geometry)
        } else {
            (NSApp.delegate as? AppDelegate)?
                .synchronizeWorkspaceTabFrames(from: self)
        }
        updateTopInsets()
        schedulePreservedGridRatioPassAfterWindowResize()
        emitPluginWindowFrame()
        (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.windowDidResize(self)
    }

    /// External sidecars cannot be AppKit child windows. Publish the key
    /// window's stable WindowServer id and frame so followers can wake their
    /// high-rate local tracker without guessing which Cmdy window to use.
    private func emitPluginWindowFrame(force: Bool = false, liveResize: Bool? = nil) {
        guard let window, window.isKeyWindow, window.isVisible, !window.isMiniaturized else { return }
        let minimumInterval: TimeInterval = 1.0 / 30.0
        let elapsed = Date().timeIntervalSince(lastPluginFrameEmit)
        if !force, elapsed < minimumInterval {
            if pendingPluginFrameEmit == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingPluginFrameEmit = nil
                    self?.emitPluginWindowFrame(force: true)
                }
                pendingPluginFrameEmit = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (minimumInterval - elapsed), execute: work)
            }
            return
        }
        pendingPluginFrameEmit?.cancel()
        pendingPluginFrameEmit = nil
        lastPluginFrameEmit = Date()
        let frame = window.frame
        PluginManager.shared.emit("window-frame", [
            "window": window.windowNumber,
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "width": Double(frame.width),
            "height": Double(frame.height),
            "liveResize": liveResize ?? window.inLiveResize,
        ])
    }

    func windowDidMove(_ notification: Notification) {
        emitPluginWindowFrame()
        (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.windowDidMove(self)
    }
    func windowDidChangeScreen(_ notification: Notification) {
        updateWorkspaceDividerAppearance(theme: effectiveTheme)
        emitPluginWindowFrame()
        (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.windowDidChangeScreen(self)
    }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateWorkspaceDividerAppearance(theme: effectiveTheme)
    }
    func windowWillStartLiveResize(_ notification: Notification) {
        // Grid resize must be able to collapse responsive rails and reach its
        // compact floor. Freezing rail widths here inflated AppKit's minimum.
        if !Preferences.shared.windowGridEnabled,
           liveResizeWorkspaceState == nil, let window {
            let geometry = workspaceRailGeometry()
            let minimumWidth =
                WorkspaceFrameLayout.minimumWindowWidthKeepingRailsFixed(
                    navigatorWidth: geometry.navigatorWidth,
                    inspectorWidth: geometry.inspectorWidth,
                    dividerThickness: workspaceSplitView.dividerThickness,
                    reservedTrailingWidth: pluginDockInset)
            let previousMinimumWidth = window.minSize.width
            liveResizeWorkspaceState = LiveResizeWorkspaceState(
                geometry: geometry,
                previousMinimumWidth: previousMinimumWidth)
            if minimumWidth > previousMinimumWidth {
                var minimumSize = window.minSize
                minimumSize.width = minimumWidth
                window.minSize = minimumSize
            }
        }
        emitPluginWindowFrame(force: true, liveResize: true)
        (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.windowWillStartLiveResize(self)
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if let state = liveResizeWorkspaceState {
            applyWorkspaceRailGeometry(state.geometry)
            if let window {
                var minimumSize = window.minSize
                minimumSize.width = state.previousMinimumWidth
                window.minSize = minimumSize
            }
        }
        liveResizeWorkspaceState = nil
        applyEdgeInsets()
        (NSApp.delegate as? AppDelegate)?.synchronizeWorkspaceTabFrames(from: self)
        if workspaceFrameRefreshAfterLiveResize {
            workspaceFrameRefreshAfterLiveResize = false
            // AppKit clears `inLiveResize` at the end of this delegate turn.
            // Refresh afterward so the guard above cannot defer it again.
            DispatchQueue.main.async { [weak self] in
                self?.refreshWorkspaceFrame()
            }
        }
        updateTopInsets()
        emitPluginWindowFrame(force: true, liveResize: false)
        (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.windowDidEndLiveResize(self)
    }

    private func emitPluginWindowState(_ state: String) {
        guard let window else { return }
        PluginManager.shared.emit("window-state", [
            "window": window.windowNumber,
            "state": state,
        ])
    }

    func windowDidMiniaturize(_ notification: Notification) {
        emitPluginWindowState("hidden")
        (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.windowLifecycleDidChange()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        emitPluginWindowState("visible")
        emitPluginWindowFrame(force: true)
        (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.windowLifecycleDidChange()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        updateNativeToolbarToggleStates()
        (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.windowLifecycleDidChange()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateNativeToolbarToggleStates()
        (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.windowLifecycleDidChange()
    }

    private func updateWorkspaceDividerAppearance(theme: Theme) {
        let scale = max(
            1,
            window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2)
        let hairline = 1 / scale
        let color = theme.ns(theme.foreground).withAlphaComponent(0.16)
        workspaceSplitView.themedDividerThickness = 2
        workspaceSplitView.themedDividerBackingColor = theme.ns(theme.background)
        workspaceSplitView.themedDividerHairlineThickness = hairline
        workspaceSplitView.themedDividerColor = color
        workspaceToolbarHairlineHeight?.constant = hairline
        workspaceToolbarHairline.lineColor = color
        titleBand.fillColor = (
            workspaceRailsVisible
                ? theme.ns(theme.background)
                : NSColor.clear
        )
        inspectorTitleLabel.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func updateWorkspaceToolbarHairlineVisibility() {
        workspaceToolbarHairline.isHidden =
            !workspaceRailsVisible || titleBand.isHidden
        titleBand.fillColor = (
            workspaceRailsVisible
                ? effectiveTheme.ns(effectiveTheme.background)
                : NSColor.clear
        )
        workspaceSplitView.themedDividerTopInset =
            titleBand.isHidden ? 0 : (titleBandHeight?.constant ?? topInset)
        inspectorTitleLabel.isHidden =
            !workspaceInspectorVisible || titleLabel.isHidden
    }

    /// Pane splits keep a two-point layout gap for reliable AppKit resizing,
    /// but paint only one physical pixel in either orientation. Previously the
    /// full two-point gap was filled, which made vertical rules look heavier
    /// than the window and toolbar hairlines.
    private func updatePaneDividerAppearance(
        in view: NSView,
        theme: Theme,
        background: NSColor
    ) {
        let scale = max(
            1,
            window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2)
        let hairline = 1 / scale
        let color = theme.ns(theme.foreground).withAlphaComponent(0.16)
        for sub in view.subviews {
            if let split = sub as? ThemedSplitView {
                split.themedDividerThickness = 2
                split.themedDividerBackingColor = background
                split.themedDividerHairlineThickness = hairline
                split.themedDividerHairlinePlacement = .centered
                split.themedDividerColor = color
            }
            updatePaneDividerAppearance(
                in: sub, theme: theme, background: background)
        }
    }

    // MARK: - Notifications (finished while away)

    private func notifyIfAway(pane: TerminalPane, block: Block) {
        guard let duration = block.duration, duration >= 5 else { return }
        let away = !NSApp.isActive || window?.isKeyWindow == false || window?.isMiniaturized == true
        guard away else { return }
        let ok = block.exitCode == 0
        Notifier.post(
            title: ok ? "Command finished" : "Command failed (exit \(block.exitCode ?? -1))",
            body: "\(block.commandText.isEmpty ? "(command)" : block.commandText) · \(block.durationText ?? "")")
    }

    // MARK: - Actions routed from AppDelegate (target the focused pane)

    func clearBuffer() { focusedPane?.clearBuffer() }
    func jumpToPreviousPrompt() { focusedPane?.jumpToPreviousPrompt() }
    func jumpToNextPrompt() { focusedPane?.jumpToNextPrompt() }
    func copyLastCommandOutput() { focusedPane?.copyLastCommandOutput() }
    func jumpToRow(_ row: Int) { focusedPane?.jumpToRow(row) }

    func recentCommands(limit: Int = 15) -> [(label: String, promptRow: Int, command: String)] {
        focusedPane?.recentCommands(limit: limit) ?? []
    }

    /// Type a command at the prompt (clearing any current input) WITHOUT running it.
    func insertCommand(_ cmd: String) {
        focusedPane?.replacePromptInput(with: cmd)
        focusedPane?.focus()
    }

    /// Clear the current input and run a command.
    func runCommand(_ cmd: String) {
        focusedPane?.replacePromptInput(with: cmd, submit: true)
        focusedPane?.focus()
    }

    /// ⌘⇧A: agent mode — a goal pursued one user-approved command at a time.
    /// Everything renders inline in the pane: the goal prompt takes the
    /// keyboard; the session log is a passive strip (typing stays with the
    /// terminal, because YOU press Enter to run each step). ⌘⇧A toggles the
    /// log while a session runs; click it to give it the keys (esc hide, ⌃C stop).
    private var agentLog: [String] = []

    func startAgent() {
        guard let pane = focusedPane else { NSSound.beep(); return }
        if let session = agentSession {
            if pane.inlinePanel != nil { pane.dismissInlinePanel() }   // toggle
            else { showAgentLog(for: session, in: pane) }
            return
        }
        let panel = pane.presentInlinePanel()
        panel.configureInput(
            placeholder: "✦ agent goal — e.g. \"init a git repo and push it to GitHub\"…",
            hint: "every command is typed at your prompt — YOU press Enter to run each step · esc dismiss")
        panel.onSubmit = { [weak self] goal in
            _ = self?.startAgent(goal: goal)
        }
    }

    /// Start Agent Mode with a host-provided goal. Channel Work Items use this
    /// path after an explicit user choice; command execution remains unchanged:
    /// every proposed command is staged and the user must press Enter.
    @discardableResult
    func startAgent(goal: String,
                    onEnd completion: (@MainActor (AgentSession) -> Void)? = nil) -> Bool {
        guard let pane = focusedPane, agentSession == nil else {
            NSSound.beep()
            return false
        }
        pane.dismissInlinePanel(refocus: false)
        let session = AgentSession(goal: goal, pane: pane)
        agentSession = session
        updateNativeToolbarToggleStates()
        agentLog = []
        session.onLog = { [weak self, weak pane] line in
            self?.agentLog.append(line)
            pane?.inlinePanel?.appendLine(line)
        }
        session.onStateChange = { [weak self, weak pane] session in
            let hint: String
            switch session.state {
            case .thinking: hint = "✦ thinking… · ⌘⇧A hide · click + ⌃C stop"
            case .awaitingRun:
                hint = "command typed at your prompt — press Enter to run it (edit it first if you like)"
            case .finished: hint = "session finished · esc close"
            case .failed: hint = "session ended · esc close"
            }
            pane?.inlinePanel?.setHint(hint)
            self?.scheduleChromeUpdate()
        }
        session.onEnd = { [weak self, weak pane, weak session] in
            guard let session else { return }
            self?.agentSession = nil
            self?.updateNativeToolbarToggleStates()
            pane?.inlinePanel?.setHint("session ended · esc close")
            self?.scheduleChromeUpdate()
            completion?(session)
        }
        showAgentLog(for: session, in: pane)
        session.start()
        return true
    }

    private func showAgentLog(for session: AgentSession, in pane: TerminalPane) {
        // Passive: the terminal keeps the keyboard so Enter runs the step.
        let panel = pane.presentInlinePanel(takeFocus: false)
        panel.configureText(title: "✦ agent", body: agentLog.joined(separator: "\n"),
                            hint: "✦ thinking… · ⌘⇧A hide · click + ⌃C stop")
        panel.onKey = { [weak session] event in
            if event.modifierFlags.contains(.control),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                session?.stop()
                return true
            }
            return false
        }
        pane.focus()
    }

    /// ⌘⇧K: natural language → command, typed at the prompt for review.
    /// Renders inline at the bottom of the pane — part of the terminal.
    func composeWithAI() {
        guard let pane = focusedPane else { NSSound.beep(); return }
        let cwd = pane.currentCwd
        let shell = (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") as NSString
        let panel = pane.presentInlinePanel()
        panel.configureInput(
            placeholder: "describe the command you need…",
            hint: "return inserts the command at your prompt · return again runs it · esc dismiss")
        panel.onSubmit = { [weak pane, weak panel] request in
            panel?.setBusy("translating locally when available…")
            Task {
                do {
                    let response = try await ErrorAssistant.composeCommand(
                        request: request, cwd: cwd, shell: shell.lastPathComponent)
                    await MainActor.run {
                        pane?.dismissInlinePanel()
                        pane?.replacePromptInput(with: response.text)
                        pane?.focus()
                    }
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await MainActor.run { panel?.fail(msg) }
                }
            }
        }
    }

    /// `# request` from the shell prompt: translate without sending the line to
    /// zsh, then leave the proposed command one keyboard confirmation away.
    func ask(request: String, in pane: TerminalPane) {
        if IntegrationDoctor.matches(request) {
            IntegrationDoctor.present(in: pane, cwd: pane.currentCwd)
            return
        }
        let id = "ask-\(UUID().uuidString)"
        pane.presentCommandAssistance(id: id, body: "translating: \(request)")
        Task { [weak pane] in
            do {
                let response = try await ErrorAssistant.composeCommand(
                    request: request, cwd: pane?.currentCwd)
                await MainActor.run {
                    _ = pane?.updateCommandAssistance(
                        id: id, explanation: "request: \(request)",
                        suggestion: response.text, source: response.source.label)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run {
                    _ = pane?.updateCommandAssistance(
                        id: id, explanation: message,
                        suggestion: nil, source: "unavailable")
                }
            }
        }
    }

    /// Correct the last failed command; the fix is typed at the prompt for
    /// review, never run.
    func fixLastCommand() {
        guard let pane = focusedPane,
              let block = pane.blockStore.blocks.last(where: { !$0.running && $0.exitCode != 0 })
        else { NSSound.beep(); return }
        fix(block: block, in: pane)
    }

    /// Local-first fix for a specific failed block (⌘⇧X uses the latest failure).
    func fix(block: Block, in pane: TerminalPane) {
        let output = pane.outputText(for: block)
        window?.subtitle = "finding a safe fix…"
        Task {
            do {
                let response = try await ErrorAssistant.fixCommand(
                    command: block.commandText, output: output,
                    exitCode: block.exitCode, cwd: block.cwd)
                await MainActor.run { [weak self] in
                    self?.scheduleChromeUpdate()
                    pane.replacePromptInput(with: response.text)
                    pane.focus()
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.scheduleChromeUpdate()
                    pane.presentInlinePanel().configureText(
                        title: "fix failed", body: msg, hint: "esc close")
                }
            }
        }
    }

    /// Explain the most recently finished command. The answer renders inline
    /// at the bottom of the pane.
    func explainLastCommand() {
        guard let pane = focusedPane,
              let block = pane.blockStore.lastCompletedBlock else { NSSound.beep(); return }
        explain(block: block, in: pane)
    }

    /// Local-first explanation for an exact semantic command block.
    func explain(block: Block, in pane: TerminalPane) {
        let command = block.commandText.isEmpty ? "(unknown command)" : block.commandText
        let output = pane.outputText(for: block)
        let panel = pane.presentInlinePanel()
        panel.configureText(title: "explain: \(command)", body: "looking at this command…",
                            hint: "private local diagnosis first · ↑↓ scroll · esc close")
        Task {
            let response = await ErrorAssistant.explain(
                command: command, output: output,
                exitCode: block.exitCode, cwd: block.cwd)
            await MainActor.run { [weak panel] in
                panel?.setBody(response.text)
                panel?.setHint("\(response.source.label) · ↑↓ scroll · esc close")
            }
        }
    }

    /// Shell-quote a dropped path so spaces/specials survive (single-quote form).
    static func shellQuote(_ path: String) -> String {
        if path.range(of: "[^A-Za-z0-9_@%+=:,./-]", options: .regularExpression) == nil {
            return path   // only safe characters — no quoting needed
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Best-effort strip of the shell prompt from a command line, leaving the command.
    static func stripPrompt(_ line: String) -> String {
        for sep in ["% ", "$ ", "# ", "❯ ", "› "] {
            if let r = line.range(of: sep, options: .backwards) {
                return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Title / status

    static let workspaceInspectorOutputSettleDelay: TimeInterval = 0.9

    /// Output can arrive many times per frame. The Inspector is an instrument
    /// panel, not a second terminal: publish Details/resources only after the
    /// output has been quiet. Semantic changes use scheduleChromeUpdate and
    /// remain immediate.
    private func scheduleWorkspaceContextRefresh() {
        guard workspaceInspectorVisible,
              !isWorkspaceFocusMode else { return }
        workspaceContextRefreshGeneration += 1
        let generation = workspaceContextRefreshGeneration
        workspaceContextRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.workspaceContextRefreshGeneration
            else { return }
            self.workspaceContextRefreshWorkItem = nil
            guard self.workspaceInspectorVisible,
                  !self.isWorkspaceFocusMode else { return }
            self.refreshWorkspaceFrame()
        }
        workspaceContextRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.workspaceInspectorOutputSettleDelay,
            execute: work)
    }

    /// Pane output can deliver several semantic state markers in one parser
    /// batch. Collapse their AppKit title/subtitle work into one main-loop pass.
    private func scheduleChromeUpdate() {
        guard !chromeUpdateScheduled else { return }
        chromeUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.chromeUpdateScheduled = false
            // This semantic refresh supersedes any pending raw-output refresh.
            self.workspaceContextRefreshGeneration += 1
            self.workspaceContextRefreshWorkItem?.cancel()
            self.workspaceContextRefreshWorkItem = nil
            self.updateWindowTitle()
            self.updateStatus()
            if self.liveResizeWorkspaceState != nil
                || self.window?.inLiveResize == true {
                self.workspaceFrameRefreshAfterLiveResize = true
            } else {
                self.refreshWorkspaceFrame()
            }
        }
    }

    private func updateStatus() {
        guard let window else { return }
        if let editor = focusedEditor {
            window.subtitle = editor.isDirty ? "modified - UTF-8" : "UTF-8"
            return
        }
        guard let pane = focusedPane else { return }
        let store = pane.blockStore
        let count = store.commandCount
        var state: String
        if store.isRunning {
            state = "running…"
        } else if let last = store.lastCompletedBlock {
            state = last.exitCode == 0 ? "ok" : "exit \(last.exitCode ?? -1)"
            if let d = last.durationText { state += " · \(d)" }
        } else {
            state = "ready"
        }
        // Show the ACTUAL renderer in use (authoritative), so the GPU toggle is observable.
        let paneBadge = panes.count > 1 ? " · \(panes.count) panes" : ""
        let subtitle = "GPU⚡︎ · ● \(count) cmd\(count == 1 ? "" : "s") · \(state)\(paneBadge)"
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    /// Terminal/Ghostty-style title: "<name> — <cols>×<rows>". `name` prefers the
    /// shell-set OSC title, else the current folder, else the app name.
    private func updateWindowTitle() {
        if let editor = focusedEditor {
            let title = editor.displayTitle
            if window?.title != title { window?.title = title }
            if !compactChrome, titleLabel.stringValue != title {
                titleLabel.stringValue = title
            }
            window?.representedURL = editor.documentURL
            return
        }
        guard let pane = focusedPane else { return }
        let name: String
        if !pane.oscTitle.isEmpty {
            name = pane.oscTitle
        } else if let cwd = pane.currentCwd {
            name = (cwd as NSString).lastPathComponent
        } else {
            name = "cmdy"
        }
        // The amber dot travels to the tab title, so a background tab shows
        // WHICH workspace is waiting.
        let needy = panes.contains { $0.wantsAttention }
        let title = "\(needy ? "● " : "")\(name) · \(pane.cols)×\(pane.rows)"
        if window?.title != title { window?.title = title }           // for tabs / window menu
        if !compactChrome, titleLabel.stringValue != title {
            titleLabel.stringValue = title
        }
        (NSApp.delegate as? AppDelegate)?.refreshAttentionBadge()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // AppKit swaps native tabs by selecting their backing NSWindow. Reapply
        // this controller's first-pane appearance before the next frame so the
        // shared-looking titlebar never flashes the previously selected tab.
        applyPreferences()
        syncTabPresentation()
        scheduleTabPresentationSync()
        emitPluginWindowState("foreground")
        emitPluginWindowFrame(force: true)
        scheduleChromeUpdate()
        NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged, object: self)
        (NSApp.delegate as? AppDelegate)?.refreshActionsMenu()
    }
    func windowDidResignKey(_ notification: Notification) {
        emitPluginWindowState("background")
        NotificationCenter.default.post(name: .cmdyWorkspaceFrameChanged, object: self)
    }

    func windowWillClose(_ notification: Notification) {
        let delegate = NSApp.delegate as? AppDelegate
        NotificationCenter.default.removeObserver(self)
        delegate?.rememberClosedLayout(self)
        delegate?.prepareWorkspaceTabReplacement(beforeClosing: self)
        emitPluginWindowState("closed")
        dismissEmbeddedBrowserControls()
        if let window {
            embeddedBrowserController.close(
                windowNumber: CGWindowID(window.windowNumber))
        }
        pendingPluginFrameEmit?.cancel()
        pendingPluginFrameEmit = nil
        paneStateBroadcastWorkItem?.cancel()
        paneStateBroadcastWorkItem = nil
        pendingPaneStateBroadcastIDs.removeAll()
        workspaceContextRefreshWorkItem?.cancel()
        workspaceContextRefreshWorkItem = nil
        preservedGridRatioResizeWorkItem?.cancel()
        preservedGridRatioResizeWorkItem = nil
        tabPresentationSyncWorkItem?.cancel()
        tabPresentationSyncWorkItem = nil
        responderObservation?.invalidate()
        layoutRectObservation?.invalidate()
        agentSession?.stop(reason: "The terminal window closed")
        for editor in editorPanes { CmdyEditorManager.shared.terminalDidClose(editor) }
        editorPanes.removeAll()
        for pane in panes {
            PluginManager.shared.cancelChannelShellResult(paneID: pane.paneId)
            pane.shutdown()   // don't orphan the child shells
            // The whole window is going away, so bypass split-tree collapse
            // and detach the pane hierarchy immediately. AppKit can otherwise
            // retain closed view graphs for several run-loop turns.
            pane.removeFromSuperview()
        }
        panes.removeAll()
        delegate?.remove(self)
    }
}
