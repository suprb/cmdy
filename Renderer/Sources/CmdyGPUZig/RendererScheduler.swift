import AppKit
import CmdyNative
import Foundation
import MetalKit

/// Main-actor OS adapter. Native policy and all mutable GPU state belong to
/// RenderWorkerSession; this adapter only sends values and applies ordered replies.
@MainActor
final class RendererScheduler {
    private let session: RenderWorkerSession
    private weak var view: MTKView?
    private weak var source: (any MetalRenderSource)?
    private(set) var inspection = CmdyRenderScheduleInspection()
    private var config = cmdy_render_schedule_default_config()
    private(set) var animationTimer: Timer?
    /// Shader animation ticks on refresh boundaries (display-locked actions).
    private(set) var animationLink: CADisplayLink?
    private(set) var animationLinkInterval: Double?
    private var animationLinkTarget: DisplayLinkTarget?
    private var coalescedTimer: Timer?
    var pacingTimerForTesting: Timer? { coalescedTimer }
    private(set) var keyboardFeedbackTimer: Timer?
    private var recoveryTimer: Timer?
    private var retryTimer: Timer?
    var retryTimerForTesting: Timer? { retryTimer }
    private var environmentObservers: [NSObjectProtocol] = []
    var environmentObserverCountForTesting: Int { environmentObservers.count }
    private var closed = false
    private struct Pending {
        let key: Int
        let attempt: () -> Bool
    }
    // Fixed storage bounds both live closures and consumed slots. Native tickets
    // (1,024) and explicit replies (64) have their own independent bounds.
    static let pendingLimit = 256
    private var pending = [Pending?](repeating: nil, count: pendingLimit)
    private var pendingHead = 0
    private(set) var pendingCount = 0
    private(set) var rejectedControlCount: UInt64 = 0
    private var waitingForCapacity = false
    private var flushing = false
    private var flushScheduled = false
    private var needsRecovery = false
    private var desiredConfig: CmdyRenderScheduleConfig?
    private var desiredPreset: UInt32?
    private var desiredObservation = false
    private var desiredInputActivity: CmdyRenderSessionCommand?
    var onOverload: (() -> Void)?
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    var environmentForTesting: (() -> CmdyRenderScheduleEnvironment)?
    var timerInstallerForTesting: ((Timer) -> Void)?
    var serviceQueueForTesting: ((@escaping @MainActor @Sendable () -> Void) -> Void)?
    var capacityWaitForTesting: (() -> Bool)?

    init(session: RenderWorkerSession, view: MTKView, source: any MetalRenderSource) {
        self.session = session; self.view = view; self.source = source
        // Owned animation no longer polls the host every frame. Publish system
        // budget changes explicitly, alongside the surface's window events.
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            environmentObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAnimationTimer() }
            })
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        for observer in environmentObservers { NotificationCenter.default.removeObserver(observer) }
        environmentObservers.removeAll()
        for timer in [animationTimer, coalescedTimer, keyboardFeedbackTimer, recoveryTimer, retryTimer] {
            timer?.invalidate()
        }
        stopAnimationLink()
        animationTimer = nil; coalescedTimer = nil; keyboardFeedbackTimer = nil
        recoveryTimer = nil; retryTimer = nil
        for index in pending.indices { pending[index] = nil }
        pendingHead = 0; pendingCount = 0; onScrollOffsetChanged = nil
        waitingForCapacity = false; needsRecovery = false; onOverload = nil
        desiredConfig = nil; desiredPreset = nil; desiredInputActivity = nil
        environmentForTesting = nil; timerInstallerForTesting = nil; serviceQueueForTesting = nil
        capacityWaitForTesting = nil
    }
    func environment(at now: Double = ProcessInfo.processInfo.systemUptime,
                     readFocus: Bool = true, readCell: Bool = false) -> CmdyRenderScheduleEnvironment {
        if let environmentForTesting {
            var value = environmentForTesting(); value.now = now; return value
        }
        let process = ProcessInfo.processInfo
        let window = view?.window
        let visible = window?.occlusionState.contains(.visible) == true
            && view?.isHiddenOrHasHiddenAncestor == false
        let maximum = window?.screen?.maximumFramesPerSecond
            ?? view?.preferredFramesPerSecond ?? 60
        // Snapshot is the first source read of a draw. Only explicit scroll
        // events read cell metrics, and activity/timer events read focus.
        let focus = readFocus ? source?.caretFocused == true : false
        let cell = readCell ? (source?.cellSize.height ?? 16)
            * (source?.backingScaleFactor() ?? 1) : 16
        return .init(now: now, cell_height_pixels: cell, maximum_fps: Int64(maximum),
                     has_view: view != nil, has_source: source != nil,
                     visible: visible, key_window: window?.isKeyWindow == true,
                     caret_focused: focus, low_power: process.isLowPowerModeEnabled,
                     thermal: UInt8(exactly: process.thermalState.rawValue) ?? 255)
    }

    /// True transfers ownership; false explicitly rejects the new operation.
    /// Accepted controls retain FIFO order. Only adjacent idempotent requests
    /// may be replaced. No task or callback stores rejected work for later.
    @discardableResult
    func enqueue(coalesceKey: Int = 0, attempt: @escaping () -> Bool) -> Bool {
        guard !closed else { return false }
        if pendingCount == 0, !flushing, attempt() { return true }
        guard !closed else { return false }
        let next = Pending(key: coalesceKey, attempt: attempt)
        let tail = (pendingHead + pendingCount) % Self.pendingLimit
        let last = (tail + Self.pendingLimit - 1) % Self.pendingLimit
        if coalesceKey != 0, pendingCount > 0, pending[last]?.key == coalesceKey {
            pending[last] = next
        } else {
            guard pendingCount < Self.pendingLimit else {
                rejectedControlCount &+= 1
                return false
            }
            pending[tail] = next; pendingCount += 1
        }
        if !waitingForCapacity, retryTimer == nil { flush() }
        return true
    }
    private func flush() {
        guard !closed, !flushing else { return }
        flushing = true
        defer { flushing = false }
        // Bound work on the input caller even when the worker starts draining.
        // A single payload-free continuation services the next batch.
        var budget = 32
        while pendingCount > 0, budget > 0 {
            if pending[pendingHead]!.attempt() {
                guard !closed else { return }
                consumeHead(); budget -= 1; continue
            }
            guard !closed else { return }
            if waitForCapacity() {
                waitingForCapacity = true
                retryTimer?.invalidate(); retryTimer = nil
                return
            }
            // Capacity may have been released before registration. Retry once
            // immediately to avoid losing that wakeup or adding a timer delay.
            if pending[pendingHead]!.attempt() {
                guard !closed else { return }
                consumeHead(); budget -= 1; continue
            }
            guard !closed else { return }
            if waitForCapacity() {
                waitingForCapacity = true
                retryTimer?.invalidate(); retryTimer = nil
                return
            }
            // A rejection with spare queue capacity can be an allocation
            // failure. No capacity transition can wake it; retain the bounded
            // host fallback instead of spinning on immediate notifications.
            break
        }
        if pendingCount == 0 {
            pendingHead = 0; waitingForCapacity = false
            retryTimer?.invalidate(); retryTimer = nil
            if needsRecovery { recover() }
            if pendingCount > 0 { scheduleFlush() }
        } else if budget == 0 {
            scheduleFlush()
        } else {
            if retryTimer == nil {
                let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] timer in
                    let identity = ObjectIdentifier(timer)
                    let active = MainActor.assumeIsolated {
                        guard let self, !self.closed,
                              self.retryTimer.map(ObjectIdentifier.init) == identity else { return false }
                        self.flush(); return self.retryTimer != nil
                    }
                    if !active { timer.invalidate() }
                }
                retryTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
        }
    }
    private func consumeHead() {
        pending[pendingHead] = nil
        pendingHead = (pendingHead + 1) % Self.pendingLimit
        pendingCount -= 1
    }
    private func scheduleFlush() {
        guard !flushScheduled, !closed else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            if !self.waitingForCapacity { self.flush() }
        }
    }
    private func waitForCapacity() -> Bool {
        capacityWaitForTesting?() ?? session.waitForCapacity()
    }
    @discardableResult
    private func post(_ command: CmdyRenderSessionCommand, coalesceKey: Int = 0,
                      recoverOnRejection: Bool = true) -> Bool {
        let accepted = enqueue(coalesceKey: coalesceKey) { [session] in session.post(command) }
        if !accepted, recoverOnRejection { requireRecovery() }
        return accepted
    }
    private func requireRecovery() {
        guard !closed, !needsRecovery else { return }
        needsRecovery = true
        // Fence stale geometry/style immediately; this native operation advances
        // the revision even if it cannot allocate a notification ticket.
        _ = session.sourceChanged(environment: environment(readFocus: false))
        onOverload?()
    }
    private func recover() {
        needsRecovery = false
        // Reconcile final UI state after every accepted control. This is a fixed
        // number of scalar values, never a second queue of rejected operations.
        // Scroll history lives in the model; discard only transient animation.
        resize()
        post(command(CMDY_SESSION_CLEAR_ROWS))
        if let desiredConfig { configure(desiredConfig) }
        if let desiredPreset { preset(desiredPreset) }
        observeFrames(desiredObservation)
        if let desiredInputActivity { post(desiredInputActivity, coalesceKey: 101) }
        cancelScrollAnimation()
        noteActivity()
        requestDraw(immediately: true)
    }
    private func command(_ kind: Int, at now: Double = ProcessInfo.processInfo.systemUptime,
                         readFocus: Bool = false, readCell: Bool = false) -> CmdyRenderSessionCommand {
        var value = CmdyRenderSessionCommand(); value.kind = UInt32(kind)
        value.environment = environment(at: now, readFocus: readFocus, readCell: readCell)
        return value
    }
    private func event(_ kind: Int, at now: Double = ProcessInfo.processInfo.systemUptime,
                       value: Double = 0, value2: Double = 0,
                       readFocus: Bool = true, readCell: Bool = false) {
        guard !closed else { return }
        var next = command(CMDY_SESSION_EVENT, at: now, readFocus: readFocus, readCell: readCell)
        next.event = UInt32(kind); next.value = value; next.value2 = value2
        let key: Int
        switch kind {
        case CMDY_RENDER_REQUEST, CMDY_RENDER_UPDATE_ANIMATION: key = kind + 1
        default: key = 0
        }
        post(next, coalesceKey: key)
    }
    func configure(_ config: CmdyRenderScheduleConfig) {
        desiredConfig = config
        var next = command(CMDY_SESSION_CONFIG, readFocus: true)
        next.config = config; post(next)
    }
    func preset(_ value: UInt32) {
        desiredPreset = value
        var next = command(CMDY_SESSION_PRESET); next.event = value; post(next)
    }
    @discardableResult
    func inspect(request: UInt64, at now: Double?) -> Bool {
        var next = command(CMDY_SESSION_INSPECT, at: now ?? ProcessInfo.processInfo.systemUptime)
        next.request_id = request; return post(next, recoverOnRejection: false)
    }
    func clearRows() {
        resize()
        post(command(CMDY_SESSION_CLEAR_ROWS))
    }
    func resize() {
        guard !closed else { return }
        let value = environment(readFocus: false)
        // Publish the epoch immediately when capacity permits, including a
        // resize reentered from source capture. Reset work itself runs on Zig.
        if session.invalidate(environment: value) == 0 {
            if !enqueue(attempt: { [session] in session.invalidate(environment: value) != 0 }) {
                requireRecovery()
            }
        }
    }
    func beginDraw(in view: MTKView, viewport: Bool = false) {
        self.view = view
        var next = command(CMDY_SESSION_BEGIN_DRAW)
        next.event = UInt32(viewport ? CMDY_BEGIN_DRAW_VIEWPORT : CMDY_BEGIN_DRAW_ORDINARY)
        post(next, coalesceKey: viewport ? 102 : 100)
    }
    func sourceChanged() {
        guard !closed else { return }
        // Publish the fence immediately, independently of the FIFO retry queue.
        // The subsequent request guarantees maintenance even if the native
        // source notification could not reserve an extra control ticket.
        guard session.sourceChanged(environment: environment(readFocus: false)) != 0 else { return }
        requestDraw()
    }
    func updateInputActivity(keypressTime: Double, typingRate: Float) {
        guard !closed, keypressTime.isFinite, typingRate.isFinite, typingRate >= 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // The app exposes CFAbsoluteTime for reactive effects. GPU frame time
        // is monotonic uptime; convert once, before copying to the worker.
        let age = min(10, max(0, CFAbsoluteTimeGetCurrent() - keypressTime))
        var next = command(CMDY_SESSION_INPUT_ACTIVITY, at: now)
        next.value = max(0, now - age); next.value2 = Double(typingRate)
        desiredInputActivity = next
        post(next, coalesceKey: 101)
    }
    func observeFrames(_ enabled: Bool) {
        desiredObservation = enabled
        var next = command(CMDY_SESSION_OBSERVE_FRAMES)
        next.event = enabled ? 1 : 0
        post(next)
    }
    func captureFailed(_ identity: CmdyRenderFrameIdentity, reason: UInt32) {
        var next = command(CMDY_SESSION_CAPTURE_FAILED)
        next.identity = identity; next.event = reason; post(next)
    }
    func receive(_ update: CmdyRenderSessionUpdate) {
        guard !closed else { return }
        waitingForCapacity = false
        let previousGeneration = inspection.interactive_generation
        inspection = update.inspection; config = update.config
        if update.kind == UInt32(CMDY_SESSION_ACTIONS) { apply(update) }
        if RendererPerformanceTrace.enabled, previousGeneration != inspection.interactive_generation {
            RendererPerformanceTrace.record(event: "draw.keyboardRequest", started: RendererPerformanceTrace.now(),
                fields: ["source": source.map { Int(bitPattern: ObjectIdentifier($0)) } ?? 0])
        }
        flush()
    }
    private func apply(_ update: CmdyRenderSessionUpdate) {
        let actions = update.actions, flags = actions.flags
        if flags & UInt32(CMDY_RENDER_STOP_ANIMATION) != 0 {
            animationTimer?.invalidate(); animationTimer = nil; stopAnimationLink()
        }
        if flags & UInt32(CMDY_RENDER_STOP_COALESCED) != 0 { coalescedTimer?.invalidate(); coalescedTimer = nil }
        if flags & UInt32(CMDY_RENDER_STOP_KEYBOARD) != 0 { keyboardFeedbackTimer?.invalidate(); keyboardFeedbackTimer = nil }
        if flags & UInt32(CMDY_RENDER_STOP_RECOVERY) != 0 { recoveryTimer?.invalidate(); recoveryTimer = nil }
        if actions.preferred_fps > 0, let view, view.preferredFramesPerSecond != Int(actions.preferred_fps) {
            view.preferredFramesPerSecond = Int(actions.preferred_fps)
        }
        if flags & UInt32(CMDY_RENDER_START_ANIMATION) != 0 {
            animationTimer?.invalidate(); animationTimer = nil; stopAnimationLink()
            if flags & UInt32(CMDY_RENDER_DISPLAY_LOCKED) != 0, let view, timerInstallerForTesting == nil {
                startAnimationLink(view: view, interval: actions.animation_interval)
            } else {
                animationTimer = makeTimer(interval: actions.animation_interval, origin: update.environment.now,
                                           repeats: true, kind: CMDY_RENDER_ANIMATION_FIRED)
            }
        }
        if flags & UInt32(CMDY_RENDER_START_COALESCED) != 0 {
            coalescedTimer?.invalidate()
            coalescedTimer = makeTimer(interval: actions.coalesced_interval, origin: update.environment.now,
                                       repeats: false, kind: CMDY_RENDER_COALESCED_FIRED)
        }
        if flags & UInt32(CMDY_RENDER_START_KEYBOARD) != 0 {
            keyboardFeedbackTimer?.invalidate()
            keyboardFeedbackTimer = makeTimer(interval: actions.keyboard_interval, origin: update.environment.now,
                                               repeats: false, kind: CMDY_RENDER_KEYBOARD_FIRED)
        }
        if flags & UInt32(CMDY_RENDER_START_RECOVERY) != 0 {
            recoveryTimer?.invalidate()
            recoveryTimer = makeTimer(interval: actions.recovery_interval, origin: update.environment.now,
                                      repeats: false, kind: CMDY_RENDER_RECOVERY_FIRED)
        }
        if flags & UInt32(CMDY_RENDER_QUEUE_SERVICE) != 0 {
            let started = RendererPerformanceTrace.now()
            let service: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, !self.closed else { return }
                RendererPerformanceTrace.record(event: "draw.manualQueueWait", started: started,
                    fields: ["source": self.source.map { Int(bitPattern: ObjectIdentifier($0)) } ?? 0])
                self.event(CMDY_RENDER_SERVICE, readFocus: false)
            }
            // Already on the UI executor: service in this turn. Another main
            // queue hop only adds latency, and at launch AppKit's first-window
            // work holds that queue for tens of milliseconds.
            if let serviceQueueForTesting { serviceQueueForTesting(service) }
            else { service() }
        }
        if flags & UInt32(CMDY_RENDER_INVALIDATE_VIEW) != 0, let view { view.setNeedsDisplay(view.bounds) }
        // Session services DRAW_MANUAL on its owner and sends a capture request.
    }
    /// A fixed-rate display link at the shader cadence: on a 120 Hz panel a
    /// 60 fps shader ticks on every second refresh, right after it, instead
    /// of drifting against the refresh grid as a free-running timer does.
    private func startAnimationLink(view: NSView, interval: Double) {
        let fps = Float(1 / max(0.000001, interval))
        let target = DisplayLinkTarget { [weak self] in
            guard let self, !self.closed, self.animationLink != nil else { return }
            self.event(CMDY_RENDER_ANIMATION_FIRED)
        }
        let link = view.displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        animationLink = link; animationLinkTarget = target; animationLinkInterval = interval
    }
    private func stopAnimationLink() {
        animationLink?.invalidate()
        animationLink = nil; animationLinkTarget = nil; animationLinkInterval = nil
    }
    private func makeTimer(interval: Double, origin: Double, repeats: Bool, kind: Int) -> Timer {
        let cadence = max(0.000001, interval)
        let delay = max(0.000001, origin + cadence - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(fire: Date(timeIntervalSinceNow: delay), interval: cadence, repeats: repeats) { [weak self] timer in
            let identity = ObjectIdentifier(timer)
            let active = MainActor.assumeIsolated {
                guard let self, !self.closed else { return false }
                // Identity is Sendable. The Timer itself never crosses an
                // isolation boundary; all state lives on this main run loop.
                switch kind {
                case CMDY_RENDER_ANIMATION_FIRED:
                    guard self.animationTimer.map(ObjectIdentifier.init) == identity else { return false }
                case CMDY_RENDER_COALESCED_FIRED:
                    guard self.coalescedTimer.map(ObjectIdentifier.init) == identity else { return false }
                    self.coalescedTimer = nil
                case CMDY_RENDER_KEYBOARD_FIRED:
                    guard self.keyboardFeedbackTimer.map(ObjectIdentifier.init) == identity else { return false }
                    self.keyboardFeedbackTimer = nil
                case CMDY_RENDER_RECOVERY_FIRED:
                    guard self.recoveryTimer.map(ObjectIdentifier.init) == identity else { return false }
                    self.recoveryTimer = nil
                default: return false
                }
                self.event(kind); return repeats
            }
            if !active { timer.invalidate() }
        }
        if let timerInstallerForTesting { timerInstallerForTesting(timer) }
        else { RunLoop.main.add(timer, forMode: .common) }
        return timer
    }
    func requestDraw(immediately: Bool = false) {
        event(immediately ? CMDY_RENDER_REQUEST_IMMEDIATE : CMDY_RENDER_REQUEST, readFocus: false)
    }
    func updateAnimationTimer() { event(CMDY_RENDER_UPDATE_ANIMATION) }
    func noteActivity() { event(CMDY_RENDER_ACTIVITY) }
    func noteKeyboardInteraction(at now: Double = ProcessInfo.processInfo.systemUptime) { event(CMDY_RENDER_KEYBOARD, at: now) }
    func cancelKeyboardInteraction() { event(CMDY_RENDER_CANCEL_KEYBOARD, readFocus: false) }
    func noteScroll(pixels: CGFloat) { event(CMDY_RENDER_SCROLL, value: pixels, readCell: true) }
    func setScrollHeld(_ pixels: CGFloat) { event(CMDY_RENDER_SET_HELD, value: pixels, readFocus: false) }
    func updateScrollHeld(_ pixels: CGFloat, activityPixels: CGFloat) {
        event(CMDY_RENDER_UPDATE_HELD, value: pixels, value2: activityPixels)
    }
    func noteSelectionInteraction() { event(CMDY_RENDER_SELECTION) }
    func cancelScrollAnimation() { onScrollOffsetChanged?(0); post(command(CMDY_SESSION_CANCEL_SCROLL)) }
    func targetFrameRate(at now: Double) -> Double? {
        guard view != nil else { return nil }
        return cmdy_render_schedule_project_target_fps(config, inspection, environment(at: now, readFocus: false))
    }
}

@MainActor
extension MetalTerminalRenderer {
    var animationTimerIsActiveForTesting: Bool {
        scheduler.animationTimer?.isValid == true || scheduler.animationLink != nil
    }
    var animationTimerIntervalForTesting: Double? {
        scheduler.animationTimer?.timeInterval ?? scheduler.animationLinkInterval
    }
    var animationIsDisplayLockedForTesting: Bool { scheduler.animationLink != nil }
    var cursorActivityTimeForTesting: Double { scheduler.inspection.activity_time }
    var keyboardFeedbackDeadlineForTesting: Double? {
        let value = scheduler.inspection
        return value.has_feedback_deadline ? value.keyboard_feedback_deadline : nil
    }
    var keyboardFeedbackTimerForTesting: Timer? { scheduler.keyboardFeedbackTimer }
    var keyboardResponseDeadlineForTesting: Double? {
        let value = scheduler.inspection
        return value.has_response_deadline ? value.keyboard_response_deadline : nil
    }
    var interactiveDrawGenerationForTesting: UInt64 { scheduler.inspection.interactive_generation }
    func targetFrameRateForTesting(at now: Double) -> Double? { scheduler.targetFrameRate(at: now) }
    func noteKeyboardInteraction(at now: Double) { scheduler.noteKeyboardInteraction(at: now) }
}

/// Holds the display link's callback; CADisplayLink retains its target.
@MainActor
private final class DisplayLinkTarget: NSObject {
    private let fire: @MainActor () -> Void
    init(_ fire: @escaping @MainActor () -> Void) { self.fire = fire }
    @objc func tick(_ link: CADisplayLink) { fire() }
}
