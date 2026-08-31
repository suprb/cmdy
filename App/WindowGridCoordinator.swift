import AppKit
import CmdyKit

struct WindowGridParticipant {
    let id: String
    let controller: TerminalWindowController
    let window: NSWindow
    let screen: NSScreen
    let minimumSize: CGSize
}

/// Owns the relationship among independent native terminal windows. AppKit
/// remains responsible for the window under the pointer; this coordinator moves
/// only the surrounding windows until the gesture settles.
final class WindowGridCoordinator {
    private struct DragSession {
        let sourceWindowNumber: Int
        let screenID: String
        let originalTree: WindowGridNode
        let pointerOffset: CGPoint
        let sourceSize: CGSize
        var lastMouse: CGPoint
        var candidateID: String?
        var candidateSince: TimeInterval
        var previewTargetID: String?
    }

    private struct ResizeSession {
        let sourceWindowNumber: Int
        let screenID: String
        let originalTree: WindowGridNode
        let boundaries: [WindowGridResizeBoundary]
    }

    private weak var appDelegate: AppDelegate?
    private var storedState = WindowGridStoredState()
    private var didLoadState = false
    private var isActive = false
    private var expectedFrames: [Int: CGRect] = [:]
    private var frameApplicationGeneration = 0
    private var frameAnimationInFlight = false
    private var activeFrameAnimation: NSViewAnimation?
    private var pendingAnimatedFrameApplication = false
    private var frameSettleWorkItem: DispatchWorkItem?
    private var frameVerificationWorkItem: DispatchWorkItem?
    private var frameVerificationAttemptsRemaining = 0
    private var interactiveDropSettleGeneration = 0
    private var interactiveDropSettleDeadline: TimeInterval = 0
    private var lifecycleSettleGeneration = 0
    private var lifecycleSettleDeadline: TimeInterval = 0
    private var lifecycleSettleWorkItem: DispatchWorkItem?
    private var dragFrameProtectionGeneration = 0
    private var dragFrameProtectionWorkItem: DispatchWorkItem?
    private var dragSession: DragSession?
    private var resizeSession: ResizeSession?
    private var isUpdatingDrag = false
    private var programmaticFrameApplicationDepth = 0
    private var reconcileWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    deinit {
        activeFrameAnimation?.stop()
        frameSettleWorkItem?.cancel()
        frameVerificationWorkItem?.cancel()
        lifecycleSettleWorkItem?.cancel()
        dragFrameProtectionWorkItem?.cancel()
        reconcileWorkItem?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    func start() {
        loadStateIfNeeded()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelActiveGestures()
                    self?.scheduleReconcile(animated: true)
                }
            }
        }
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelActiveGestures()
                    self?.scheduleReconcile(animated: false)
                }
            }
        }
        preferencesDidChange()
    }

    func preferencesDidChange() {
        loadStateIfNeeded()
        if Preferences.shared.windowGridEnabled {
            if !isActive {
                captureMissingManualFrames()
                isActive = true
            }
            scheduleReconcile(animated: true)
        } else if isActive {
            interactiveDropSettleGeneration += 1
            interactiveDropSettleDeadline = 0
            lifecycleSettleGeneration += 1
            lifecycleSettleDeadline = 0
            lifecycleSettleWorkItem?.cancel()
            lifecycleSettleWorkItem = nil
            cancelActiveGestures()
            restoreManualFrames()
            isActive = false
        }
    }

    /// Gives a new window both a sensible future manual frame and its grid frame
    /// before the first presentation, avoiding a cascade-then-snap flash. The
    /// post-presentation reconcile moves the surrounding windows. Starting an
    /// animation here allowed rapid Cmd-N presses to create overlapping AppKit
    /// frame transactions whose oldest completion could strand the last window.
    func prepareNewWindow(
        _ controller: TerminalWindowController,
        source: TerminalWindowController?
    ) -> CGRect? {
        loadStateIfNeeded()
        guard let delegate = appDelegate,
              let window = controller.window,
              let id = delegate.windowGridIdentifier(for: controller)
        else { return nil }

        let sourceWindow = source?.window
        let screen = sourceWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        let sourceID = source.flatMap { delegate.windowGridIdentifier(for: $0) }
        let sourceManual = sourceID.flatMap { storedState.manualFrames[$0]?.cgRect }
        let manualBase = sourceManual ?? sourceWindow?.frame
        let manualFrame: CGRect
        if let manualBase {
            manualFrame = AppDelegate.cascadedWindowFrame(
                from: manualBase,
                visibleFrame: screen.visibleFrame)
        } else {
            let size = CGSize(width: 860, height: 540)
            manualFrame = CGRect(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height)
        }
        storedState.manualFrames[id] = WindowGridStoredFrame(manualFrame)

        guard Preferences.shared.windowGridEnabled else {
            persistState()
            return manualFrame
        }
        isActive = true
        let screenID = Self.identifier(for: screen)
        removeIDFromEveryTree(id)
        let participants = delegate.windowGridParticipants()
        var minimums = Dictionary(uniqueKeysWithValues: participants.map {
            ($0.id, $0.minimumSize)
        })
        minimums[id] = resolvedMinimumSize(for: window)
        let root = storedState.trees[screenID]
        guard let next = WindowGridLayout.inserting(
            id,
            into: root,
            in: screen.visibleFrame,
            gap: Preferences.shared.contentMargin,
            scale: screen.backingScaleFactor,
            minimumSizes: minimums)
        else {
            persistState()
            return manualFrame
        }
        storedState.trees[screenID] = next
        persistState()
        let targetFrames = WindowGridLayout.frames(
            for: next,
            in: screen.visibleFrame,
            gap: Preferences.shared.contentMargin,
            scale: screen.backingScaleFactor)
        return targetFrames[id]
    }

    func scheduleReconcile(
        animated: Bool = true,
        after delay: TimeInterval = 0
    ) {
        guard Preferences.shared.windowGridEnabled else { return }
        // Never drop a lifecycle request merely because an older reconcile is
        // queued. Rapid create/close can otherwise leave the last closed leaf
        // in the tree and strand the survivor at half-screen.
        reconcileWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconcileWorkItem = nil
            self.reconcile(animated: animated)
        }
        reconcileWorkItem = work
        if delay > 0 {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func reconcile(animated: Bool) {
        guard Preferences.shared.windowGridEnabled,
              let delegate = appDelegate else { return }
        loadStateIfNeeded()
        isActive = true
        let participants = delegate.windowGridParticipants()
        let activeIDs = Set(participants.map(\.id))

        // Minimized/fullscreen/closed workspaces leave no active rectangle.
        for id in Set(storedState.trees.values.flatMap {
            WindowGridLayout.leafIDs(in: $0)
        }) where !activeIDs.contains(id) {
            removeIDFromEveryTree(id)
        }

        let byScreen = Dictionary(grouping: participants) {
            Self.identifier(for: $0.screen)
        }
        for (screenID, members) in byScreen {
            guard let screen = members.first?.screen else { continue }
            let memberIDs = Set(members.map(\.id))

            // Moving to another display transfers ownership before insertion.
            for id in memberIDs {
                for otherID in Array(storedState.trees.keys) where otherID != screenID {
                    storedState.trees[otherID] = WindowGridLayout.removing(
                        id, from: storedState.trees[otherID])
                }
            }

            var root = storedState.trees[screenID]
            let minimums = Dictionary(uniqueKeysWithValues: members.map {
                ($0.id, $0.minimumSize)
            })
            for member in members where !WindowGridLayout.contains(member.id, in: root) {
                if let inserted = WindowGridLayout.inserting(
                    member.id,
                    into: root,
                    in: screen.visibleFrame,
                    gap: Preferences.shared.contentMargin,
                    scale: screen.backingScaleFactor,
                    minimumSizes: minimums) {
                    root = inserted
                }
            }
            storedState.trees[screenID] = root
        }

        persistState()
        applyCurrentFrames(animated: animated)
    }

    // MARK: - Drag reordering

    @discardableResult
    func updateDrag(window: NSWindow, mouse: CGPoint) -> Bool {
        if isUpdatingDrag {
            return dragSession?.sourceWindowNumber == window.windowNumber
        }
        isUpdatingDrag = true
        defer { isUpdatingDrag = false }
        guard Preferences.shared.windowGridEnabled,
              let delegate = appDelegate,
              let controller = window.windowController as? TerminalWindowController,
              let sourceID = delegate.windowGridIdentifier(for: controller),
              let source = delegate.windowGridParticipants().first(where: {
                  $0.id == sourceID && $0.window === window
              })
        else { return false }

        let screenID = Self.identifier(for: source.screen)
        if let existing = dragSession,
           existing.sourceWindowNumber == window.windowNumber,
           existing.screenID != screenID {
            let participants = delegate.windowGridParticipants()
            let minimums = Dictionary(uniqueKeysWithValues: participants.map {
                ($0.id, $0.minimumSize)
            })
            let destinationRoot = WindowGridLayout.removing(
                sourceID, from: storedState.trees[screenID])
            guard let transferred = WindowGridLayout.inserting(
                sourceID,
                into: destinationRoot,
                in: source.screen.visibleFrame,
                gap: Preferences.shared.contentMargin,
                scale: source.screen.backingScaleFactor,
                minimumSizes: minimums)
            else { return true }
            storedState.trees[existing.screenID] = WindowGridLayout.removing(
                sourceID, from: storedState.trees[existing.screenID])
            storedState.trees[screenID] = transferred
            dragSession = DragSession(
                sourceWindowNumber: window.windowNumber,
                screenID: screenID,
                originalTree: transferred,
                pointerOffset: CGPoint(
                    x: mouse.x - window.frame.minX,
                    y: mouse.y - window.frame.minY),
                sourceSize: window.frame.size,
                lastMouse: mouse,
                candidateID: nil,
                candidateSince: ProcessInfo.processInfo.systemUptime,
                previewTargetID: nil)
            applyCurrentFrames(
                animated: true,
                excludingWindowNumber: window.windowNumber)
        }
        guard let original = dragSession?.originalTree
                ?? storedState.trees[screenID],
              WindowGridLayout.contains(sourceID, in: original)
        else { return false }

        if dragSession == nil {
            interactiveDropSettleGeneration += 1
            interactiveDropSettleDeadline = 0
            let handFrame = window.frame
            let wasAnimating = frameAnimationInFlight
            dragSession = DragSession(
                sourceWindowNumber: window.windowNumber,
                screenID: screenID,
                originalTree: original,
                pointerOffset: CGPoint(
                    x: mouse.x - handFrame.minX,
                    y: mouse.y - handFrame.minY),
                sourceSize: handFrame.size,
                lastMouse: mouse,
                candidateID: nil,
                candidateSince: ProcessInfo.processInfo.systemUptime,
                previewTargetID: nil)
            // From this point until mouse-up, AppKit's native drag owns the
            // source window. Drain any older grid animation for the neighbors
            // and explicitly supersede its source-window animator at the exact
            // frame currently under the pointer.
            applyCurrentFrames(
                animated: false,
                excludingWindowNumber: window.windowNumber)
            if wasAnimating {
                applyProgrammaticFrame(handFrame, to: window)
            }
            startDragFrameProtection()
        }
        guard var session = dragSession,
              session.sourceWindowNumber == window.windowNumber else { return false }
        session.lastMouse = mouse
        dragSession = session
        applyDragFrameProtection()

        let frames = WindowGridLayout.frames(
            for: session.originalTree,
            in: source.screen.visibleFrame,
            gap: Preferences.shared.contentMargin,
            scale: source.screen.backingScaleFactor)
        let targetID = frames.first(where: { id, frame in
            id != sourceID && frame.contains(mouse)
        })?.key

        let now = ProcessInfo.processInfo.systemUptime
        if targetID != session.candidateID {
            session.candidateID = targetID
            session.candidateSince = now
            dragSession = session
            return true
        }
        guard now - session.candidateSince >= 0.06 else { return true }
        guard targetID != session.previewTargetID else { return true }

        session.previewTargetID = targetID
        dragSession = session
        if let targetID {
            storedState.trees[screenID] = WindowGridLayout.moving(
                sourceID,
                to: targetID,
                in: session.originalTree)
        } else {
            storedState.trees[screenID] = session.originalTree
        }
        applyCurrentFrames(
            animated: true,
            excludingWindowNumber: window.windowNumber)
        return true
    }

    func isDragging(window: NSWindow?) -> Bool {
        guard let number = window?.windowNumber else { return false }
        return dragSession?.sourceWindowNumber == number
    }

    var activelyDraggedWindow: NSWindow? {
        guard let number = dragSession?.sourceWindowNumber else { return nil }
        return NSApp.window(withWindowNumber: number)
    }

    var dragTargetsForTesting: (candidate: String?, preview: String?) {
        (dragSession?.candidateID, dragSession?.previewTargetID)
    }

    var dragOriginalTreeForTesting: WindowGridNode? {
        dragSession?.originalTree
    }

    func endDrag(window: NSWindow?) {
        guard let session = dragSession,
              window?.windowNumber == session.sourceWindowNumber else { return }
        dragSession = nil
        stopDragFrameProtection()
        if session.previewTargetID == nil,
           let candidateID = session.candidateID,
           let controller = window?.windowController
                as? TerminalWindowController,
           let sourceID = appDelegate?.windowGridIdentifier(for: controller) {
            // A quick native drag may reach mouse-up before the 60 ms hover
            // preview fires. The rectangle under the pointer is still an
            // intentional drop target, so commit it instead of silently
            // restoring the original ordering.
            storedState.trees[session.screenID] = WindowGridLayout.moving(
                sourceID,
                to: candidateID,
                in: session.originalTree)
        } else if session.previewTargetID == nil {
            storedState.trees[session.screenID] = session.originalTree
        }
        persistState()
        settleInteractiveDrop()
    }

    func cancelDrag(window: NSWindow? = nil) {
        guard let session = dragSession else { return }
        if let window, window.windowNumber != session.sourceWindowNumber { return }
        storedState.trees[session.screenID] = session.originalTree
        dragSession = nil
        stopDragFrameProtection()
        applyCurrentFrames(animated: true)
    }

    // MARK: - Live resize

    func windowWillStartLiveResize(_ controller: TerminalWindowController) {
        guard let window = controller.window else { return }
        let pointer = NSEvent.mouseLocation
        let frame = window.frame
        let threshold: CGFloat = 14
        let activeEdges = Set([
            abs(pointer.x - frame.minX) <= threshold ? WindowGridEdge.left : nil,
            abs(pointer.x - frame.maxX) <= threshold ? WindowGridEdge.right : nil,
            abs(pointer.y - frame.minY) <= threshold ? WindowGridEdge.bottom : nil,
            abs(pointer.y - frame.maxY) <= threshold ? WindowGridEdge.top : nil,
        ].compactMap { $0 })
        beginResize(controller, activeEdges: activeEdges)
    }

    /// Used by the visible-window smoke gate to drive the exact production
    /// resize session without moving the developer's real pointer.
    @discardableResult
    func beginResizeForTesting(
        _ controller: TerminalWindowController,
        edge: WindowGridEdge
    ) -> Bool {
        beginResize(controller, activeEdges: [edge])
    }

    @discardableResult
    private func beginResize(
        _ controller: TerminalWindowController,
        activeEdges: Set<WindowGridEdge>
    ) -> Bool {
        guard Preferences.shared.windowGridEnabled,
              resizeSession == nil,
              let delegate = appDelegate,
              let window = controller.window,
              let participant = delegate.windowGridParticipants().first(where: {
                  $0.controller === controller
              })
        else { return false }
        let screenID = Self.identifier(for: participant.screen)
        guard let tree = storedState.trees[screenID] else { return false }

        let minimums = Dictionary(uniqueKeysWithValues:
            delegate.windowGridParticipants().map { ($0.id, $0.minimumSize) })
        let boundaries = WindowGridLayout.resizeBoundaries(
            for: participant.id,
            in: tree,
            frame: participant.screen.visibleFrame,
            gap: Preferences.shared.contentMargin,
            scale: participant.screen.backingScaleFactor,
            minimumSizes: minimums)
            .filter { activeEdges.contains($0.edge) }
        resizeSession = ResizeSession(
            sourceWindowNumber: window.windowNumber,
            screenID: screenID,
            originalTree: tree,
            boundaries: boundaries)
        return true
    }

    func windowDidResize(_ controller: TerminalWindowController) {
        guard let session = resizeSession,
              let window = controller.window,
              window.windowNumber == session.sourceWindowNumber else { return }
        var tree = session.originalTree
        for boundary in session.boundaries {
            let ratio = WindowGridLayout.ratio(
                for: window.frame,
                boundary: boundary)
            tree = WindowGridLayout.settingRatio(
                ratio,
                at: boundary.splitPath,
                in: tree)
        }
        storedState.trees[session.screenID] = tree
        applyCurrentFrames(
            animated: false,
            excludingWindowNumber: window.windowNumber)
    }

    func windowDidEndLiveResize(_ controller: TerminalWindowController) {
        guard let session = resizeSession,
              controller.window?.windowNumber == session.sourceWindowNumber else {
            return
        }
        resizeSession = nil
        persistState()
        applyCurrentFrames(animated: true)
    }

    func windowLifecycleDidChange() {
        cancelActiveGestures()
        reconcileWorkItem?.cancel()
        reconcileWorkItem = nil
        // Closure is a terminal lifecycle boundary. Reconcile synchronously
        // after AppDelegate removes the controller so no later animation can
        // observe a tree containing the closed workspace.
        reconcile(animated: true)
        scheduleLifecycleSettle()
    }

    func leafIDsForTesting(on screen: NSScreen) -> [String] {
        WindowGridLayout.leafIDs(
            in: storedState.trees[Self.identifier(for: screen)])
    }

    func treeForConversion(on screen: NSScreen) -> WindowGridNode? {
        loadStateIfNeeded()
        return storedState.trees[Self.identifier(for: screen)]
    }

    /// Replace only the converted leaves, leaving layouts on other displays
    /// untouched. The caller presents every new window in its assigned frame
    /// first; the delayed pass merely reconciles transient WindowServer state.
    func installConvertedTree(_ tree: WindowGridNode, on screen: NSScreen) {
        loadStateIfNeeded()
        let ids = Set(WindowGridLayout.leafIDs(in: tree))
        if let delegate = appDelegate {
            for controller in delegate.allControllers {
                guard let id = delegate.windowGridIdentifier(for: controller),
                      ids.contains(id),
                      storedState.manualFrames[id] == nil,
                      let frame = controller.window?.frame
                else { continue }
                storedState.manualFrames[id] = WindowGridStoredFrame(frame)
            }
        }
        for id in ids { removeIDFromEveryTree(id) }
        storedState.trees[Self.identifier(for: screen)] = tree
        persistState()
        if Preferences.shared.windowGridEnabled {
            isActive = true
            scheduleReconcile(animated: false, after: 0.1)
        }
    }

    /// Merge a saved workspace's Window Grid into the live grid. Workspace
    /// group IDs are remapped when opened so the saved workspace can be opened
    /// more than once without two native windows claiming the same leaf.
    func importWorkspaceState(
        _ data: Data,
        remapping identifiers: [String: String]
    ) {
        loadStateIfNeeded()
        guard let imported = try? JSONDecoder().decode(
            WindowGridStoredState.self, from: data), imported.isSupported
        else { return }

        func remap(_ node: WindowGridNode) -> WindowGridNode? {
            switch node {
            case .leaf(let id):
                return identifiers[id].map(WindowGridNode.leaf)
            case .split(let axis, let ratio, let first, let second):
                switch (remap(first), remap(second)) {
                case let (.some(a), .some(b)):
                    return .split(axis: axis, ratio: ratio, first: a, second: b)
                case let (.some(a), .none), let (.none, .some(a)):
                    return a
                case (.none, .none):
                    return nil
                }
            }
        }

        let screensByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.map {
            (Self.identifier(for: $0), $0)
        })
        for (screenID, sourceTree) in imported.trees {
            guard let tree = remap(sourceTree) else { continue }
            let targetScreen = screensByID[screenID] ?? NSScreen.main
            guard let targetScreen else { continue }
            let targetID = Self.identifier(for: targetScreen)
            if let current = storedState.trees[targetID] {
                let currentCount = max(1, WindowGridLayout.leafIDs(in: current).count)
                let newCount = max(1, WindowGridLayout.leafIDs(in: tree).count)
                storedState.trees[targetID] = .split(
                    axis: .vertical,
                    ratio: CGFloat(currentCount) / CGFloat(currentCount + newCount),
                    first: current,
                    second: tree)
            } else {
                storedState.trees[targetID] = tree
            }
        }
        for (oldID, frame) in imported.manualFrames {
            if let newID = identifiers[oldID] {
                storedState.manualFrames[newID] = frame
            }
        }
        persistState()
        scheduleReconcile(animated: false, after: 0.1)
    }

    func layoutDiagnosticForTesting() -> (
        participants: Int, leaves: Int, membership: Bool, frames: Bool,
        mismatches: [String]
    ) {
        guard let delegate = appDelegate else {
            return (0, 0, false, false, ["missing-app-delegate"])
        }
        let participants = delegate.windowGridParticipants()
        let participantIDs = Set(participants.map(\.id))
        let leafIDs = Set(storedState.trees.values.flatMap {
            WindowGridLayout.leafIDs(in: $0)
        })
        let mismatches = participants.compactMap { participant -> String? in
            let screenID = Self.identifier(for: participant.screen)
            guard let tree = storedState.trees[screenID],
                  let expected = WindowGridLayout.frames(
                    for: tree,
                    in: participant.screen.visibleFrame,
                    gap: Preferences.shared.contentMargin,
                    scale: participant.screen.backingScaleFactor
                  )[participant.id]
            else { return "\(participant.id):missing-assignment" }
            guard !framesEqual(participant.window.frame, expected) else {
                return nil
            }
            return "\(participant.id):actual="
                + NSStringFromRect(participant.window.frame)
                + ",expected=" + NSStringFromRect(expected)
                + ",minimum=" + NSStringFromSize(participant.window.minSize)
        }
        return (
            participants.count, leafIDs.count,
            participantIDs == leafIDs, mismatches.isEmpty, mismatches)
    }

    func windowDidChangeScreen(_ controller: TerminalWindowController) {
        if let window = controller.window,
           dragSession?.sourceWindowNumber == window.windowNumber {
            return
        }
        windowLifecycleDidChange()
    }

    func windowDidMove(_ controller: TerminalWindowController) {
        guard Preferences.shared.windowGridEnabled,
              programmaticFrameApplicationDepth == 0,
              let window = controller.window,
              resizeSession?.sourceWindowNumber != window.windowNumber,
              !window.inLiveResize else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            // NSWindowDelegate is authoritative for a real titlebar drag. The
            // docking poller remains useful for native-tab previews, but grid
            // reorder must not depend on mover heuristics noticing this frame.
            if let active = dragSession,
               active.sourceWindowNumber != window.windowNumber {
                return
            }
            _ = updateDrag(window: window, mouse: NSEvent.mouseLocation)
            return
        }
        guard dragSession?.sourceWindowNumber != window.windowNumber else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now <= interactiveDropSettleDeadline
            || now <= lifecycleSettleDeadline {
            return
        }
        // AppKit emits windowDidMove throughout our own animator transaction.
        // Treating each intermediate presentation frame as a fresh user move
        // continuously queued another animation, so a rapid close collapse
        // could still be in motion long after the newest topology had won.
        guard !frameAnimationInFlight else { return }
        if let expected = expectedFrames[window.windowNumber],
           framesEqual(window.frame, expected) {
            return
        }
        scheduleReconcile(animated: true)
    }

    // MARK: - Frame application and state

    private func applyCurrentFrames(
        animated: Bool,
        excludingWindowNumber: Int? = nil
    ) {
        guard let delegate = appDelegate else { return }
        // A held window belongs to the native pointer gesture. Even delayed
        // animation completions and verification passes may only rearrange its
        // neighbors; the source joins the grid again in endDrag on mouse-up.
        let protectedWindowNumbers = Set([
            excludingWindowNumber,
            dragSession?.sourceWindowNumber,
        ].compactMap { $0 })
        if animated, frameAnimationInFlight {
            // AppKit does not reliably cancel an older NSWindow animator when
            // another frame transaction starts. Coalesce changes that arrive
            // during the current 180 ms movement and replay the newest complete
            // topology when it finishes.
            pendingAnimatedFrameApplication = true
            return
        }
        if !animated, frameAnimationInFlight {
            // NSAnimationContext window animators cannot be cancelled. A
            // retained NSViewAnimation can: stop it before a live gesture
            // takes ownership, then the exact application below restores the
            // held source and current neighbor topology in the same run loop.
            frameApplicationGeneration += 1
            frameSettleWorkItem?.cancel()
            frameSettleWorkItem = nil
            frameAnimationInFlight = false
            pendingAnimatedFrameApplication = false
            frameVerificationWorkItem?.cancel()
            frameVerificationWorkItem = nil
            frameVerificationAttemptsRemaining = 0
            activeFrameAnimation?.stop()
            activeFrameAnimation = nil
        }
        frameApplicationGeneration += 1
        let generation = frameApplicationGeneration
        frameSettleWorkItem?.cancel()
        frameSettleWorkItem = nil
        let participants = delegate.windowGridParticipants()
        let membersByScreen = Dictionary(grouping: participants) {
            Self.identifier(for: $0.screen)
        }
        var targetFramesByScreen: [String: [String: CGRect]] = [:]
        for (screenID, members) in membersByScreen {
            guard let screen = members.first?.screen,
                  let tree = storedState.trees[screenID] else { continue }
            targetFramesByScreen[screenID] = WindowGridLayout.frames(
                for: tree,
                in: screen.visibleFrame,
                gap: Preferences.shared.contentMargin,
                scale: screen.backingScaleFactor)
        }
        var targets: [Int: CGRect] = [:]
        var assignments: [(NSWindow, CGRect)] = []

        for participant in participants {
            let screenID = Self.identifier(for: participant.screen)
            guard let frame = targetFramesByScreen[screenID]?[participant.id],
                  !protectedWindowNumbers.contains(
                      participant.window.windowNumber)
            else { continue }
            targets[participant.window.windowNumber] = frame
            if !framesEqual(participant.window.frame, frame) {
                assignments.append((participant.window, frame))
            }
        }

        expectedFrames = targets
        guard !assignments.isEmpty else {
            frameVerificationAttemptsRemaining = 0
            frameVerificationWorkItem?.cancel()
            frameVerificationWorkItem = nil
            return
        }
        // Animating every native window continuously resizes every terminal,
        // which reflows scrollback at each animation frame. Dense grids are
        // too small for that motion to add useful spatial information, so
        // settle them in one exact layout pass.
        let shouldAnimate = animated
            && participants.count <= 12
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            frameVerificationWorkItem?.cancel()
            frameVerificationWorkItem = nil
            frameVerificationAttemptsRemaining = 4
            frameAnimationInFlight = true
            let animation = NSViewAnimation(viewAnimations: assignments.map {
                window, frame in
                [
                    .target: window,
                    .startFrame: NSValue(rect: window.frame),
                    .endFrame: NSValue(rect: frame),
                ]
            })
            animation.duration = 0.18
            animation.animationCurve = .easeInOut
            animation.animationBlockingMode = .nonblocking
            animation.frameRate = 60
            activeFrameAnimation = animation
            animation.start()
            // AppKit can omit or delay an animation completion when a window
            // closes mid-transaction. The newest generation gets one bounded
            // exact pass so an older create/close animation can never win.
            let work = DispatchWorkItem { [weak self] in
                self?.settleFramesIfCurrent(generation)
            }
            frameSettleWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.24, execute: work)
        } else {
            // Only touch windows whose geometry is actually stale. Reapplying
            // an unchanged frame still triggers AppKit layout and a Metal
            // redraw, which multiplied badly across dense grids and the
            // bounded lifecycle-settle passes below. The verifier handles a
            // later compact-toolbar geometry adjustment if one occurs.
            for (window, frame) in assignments {
                applyProgrammaticFrame(frame, to: window)
            }
            scheduleFrameVerificationIfNeeded(generation)
        }
    }

    private func settleInteractiveDrop() {
        interactiveDropSettleGeneration += 1
        let generation = interactiveDropSettleGeneration
        interactiveDropSettleDeadline =
            ProcessInfo.processInfo.systemUptime + 0.6

        // The window under the pointer has already been moved natively. Snap
        // the completed drop to the model immediately; hover preview is where
        // surrounding windows animate. Repeating this bounded exact pass lets
        // compact toolbar attachment and any superseded AppKit animator drain
        // without taking ownership back from the user's drop.
        applyCurrentFrames(animated: false)
        for delay in [0.06, 0.18, 0.34, 0.52] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      Preferences.shared.windowGridEnabled,
                      generation == self.interactiveDropSettleGeneration,
                      self.dragSession == nil,
                      self.resizeSession == nil else { return }
                self.applyCurrentFrames(animated: false)
            }
        }
    }

    private func scheduleLifecycleSettle() {
        lifecycleSettleGeneration += 1
        let generation = lifecycleSettleGeneration
        lifecycleSettleDeadline = ProcessInfo.processInfo.systemUptime + 0.68
        lifecycleSettleWorkItem?.cancel()

        // Creating or closing a window can also attach/detach compact native
        // chrome after the topology animation completes. Coalesce a burst to
        // its newest lifecycle generation, then verify the final rectangles
        // after both the frame animation and delayed AppKit chrome updates.
        scheduleLifecycleSettlePass(generation: generation, pass: 0)
    }

    private func startDragFrameProtection() {
        dragFrameProtectionGeneration += 1
        let generation = dragFrameProtectionGeneration
        dragFrameProtectionWorkItem?.cancel()
        scheduleDragFrameProtection(generation: generation)
    }

    private func stopDragFrameProtection() {
        dragFrameProtectionGeneration += 1
        dragFrameProtectionWorkItem?.cancel()
        dragFrameProtectionWorkItem = nil
    }

    private func scheduleDragFrameProtection(generation: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.dragFrameProtectionGeneration,
                  self.dragSession != nil else { return }
            self.dragFrameProtectionWorkItem = nil
            self.applyDragFrameProtection()
            self.scheduleDragFrameProtection(generation: generation)
        }
        dragFrameProtectionWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.0 / 60.0, execute: work)
    }

    private func applyDragFrameProtection() {
        guard let session = dragSession,
              let window = NSApp.window(
                withWindowNumber: session.sourceWindowNumber) else { return }
        let expected = CGRect(
            x: session.lastMouse.x - session.pointerOffset.x,
            y: session.lastMouse.y - session.pointerOffset.y,
            width: session.sourceSize.width,
            height: session.sourceSize.height)
        guard !framesEqual(window.frame, expected) else { return }
        // An older NSWindow animator cannot be cancelled reliably. While the
        // mouse is held, the pointer anchor is authoritative and immediately
        // rejects any stale presentation frame that tries to reclaim source.
        applyProgrammaticFrame(expected, to: window)
    }

    private func applyProgrammaticFrame(_ frame: CGRect, to window: NSWindow) {
        programmaticFrameApplicationDepth += 1
        defer { programmaticFrameApplicationDepth -= 1 }
        window.setFrame(frame, display: true)
    }

    private func scheduleLifecycleSettlePass(generation: Int, pass: Int) {
        let relativeDelays: [TimeInterval] = [0.2, 0.12, 0.14, 0.16]
        guard relativeDelays.indices.contains(pass) else {
            lifecycleSettleWorkItem = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  Preferences.shared.windowGridEnabled,
                  generation == self.lifecycleSettleGeneration,
                  self.dragSession == nil,
                  self.resizeSession == nil else { return }
            self.lifecycleSettleWorkItem = nil
            self.applyCurrentFrames(animated: false)
            self.scheduleLifecycleSettlePass(
                generation: generation, pass: pass + 1)
        }
        lifecycleSettleWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + relativeDelays[pass], execute: work)
    }

    private func scheduleFrameVerificationIfNeeded(_ generation: Int) {
        guard frameVerificationAttemptsRemaining > 0,
              dragSession == nil,
              resizeSession == nil else { return }
        frameVerificationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.frameApplicationGeneration,
                  self.dragSession == nil,
                  self.resizeSession == nil else { return }
            self.frameVerificationWorkItem = nil
            let mismatch = self.expectedFrames.contains { number, frame in
                guard let window = NSApp.window(withWindowNumber: number) else {
                    return false
                }
                return !self.framesEqual(window.frame, frame)
            }
            guard mismatch else {
                self.frameVerificationAttemptsRemaining = 0
                return
            }
            self.frameVerificationAttemptsRemaining -= 1
            // Compact chrome can attach/detach a native toolbar one run-loop
            // after the outer window reaches its new tile. Reapply the exact
            // model rectangle until that AppKit geometry has settled.
            self.applyCurrentFrames(animated: false)
        }
        frameVerificationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func settleFramesIfCurrent(_ generation: Int) {
        guard generation == frameApplicationGeneration else { return }
        frameSettleWorkItem?.cancel()
        frameSettleWorkItem = nil
        if activeFrameAnimation?.isAnimating == true {
            activeFrameAnimation?.stop()
        }
        activeFrameAnimation = nil
        frameAnimationInFlight = false
        if pendingAnimatedFrameApplication {
            pendingAnimatedFrameApplication = false
            // Re-resolve participants and topology, then perform one animation
            // to the latest state instead of letting overlapping transactions
            // race each other to different destinations.
            applyCurrentFrames(animated: true)
        } else {
            // One exact pass removes fractional/presentation drift after the
            // final animation in the sequence.
            applyCurrentFrames(animated: false)
        }
    }

    private func captureMissingManualFrames() {
        guard let delegate = appDelegate else { return }
        for participant in delegate.windowGridParticipants()
            where storedState.manualFrames[participant.id] == nil {
            storedState.manualFrames[participant.id] = WindowGridStoredFrame(
                participant.window.frame)
        }
        persistState()
    }

    private func restoreManualFrames() {
        guard let delegate = appDelegate else { return }
        let assignments = delegate.windowGridParticipants().compactMap { participant
            -> (NSWindow, CGRect)? in
            guard let frame = storedState.manualFrames[participant.id]?.cgRect else {
                return nil
            }
            return (participant.window, frame)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0 : 0.18
            for (window, frame) in assignments {
                window.animator().setFrame(frame, display: true)
            }
        }
    }

    private func cancelActiveGestures() {
        if let drag = dragSession {
            storedState.trees[drag.screenID] = drag.originalTree
        }
        if let resize = resizeSession {
            storedState.trees[resize.screenID] = resize.originalTree
        }
        dragSession = nil
        resizeSession = nil
        stopDragFrameProtection()
    }

    private func removeIDFromEveryTree(_ id: String) {
        for screenID in Array(storedState.trees.keys) {
            storedState.trees[screenID] = WindowGridLayout.removing(
                id, from: storedState.trees[screenID])
        }
    }

    private func loadStateIfNeeded() {
        guard !didLoadState else { return }
        didLoadState = true
        guard let data = Preferences.shared.windowGridStateData,
              let decoded = try? JSONDecoder().decode(
                  WindowGridStoredState.self, from: data),
              decoded.isSupported else { return }
        storedState = decoded
    }

    private func persistState() {
        guard let data = try? JSONEncoder().encode(storedState) else { return }
        Preferences.shared.windowGridStateData = data
    }

    private func resolvedMinimumSize(for window: NSWindow) -> CGSize {
        CGSize(
            width: max(WindowGridLayout.defaultMinimumSize.width, window.minSize.width),
            height: max(WindowGridLayout.defaultMinimumSize.height, window.minSize.height))
    }

    static func identifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display-\(number.uint32Value)"
        }
        return String(format: "display-%.0f-%.0f-%.0f-%.0f",
                      screen.frame.minX, screen.frame.minY,
                      screen.frame.width, screen.frame.height)
    }

    private func framesEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        // WindowServer rounds top-level NSWindow frames to whole logical
        // points even when a Retina layout boundary lands on a half point.
        // Treat that unavoidable half-point projection as exact; otherwise
        // every layout callback schedules another reconcile forever.
        abs(lhs.minX - rhs.minX) < 0.51
            && abs(lhs.minY - rhs.minY) < 0.51
            && abs(lhs.width - rhs.width) < 0.51
            && abs(lhs.height - rhs.height) < 0.51
    }
}
