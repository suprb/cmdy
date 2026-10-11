import AppKit
import CoreText
import Metal
import MetalKit
import CmdyNative

/// Scalar evidence from Metal's on-screen presentation callback. This is a
/// diagnostic seam, distinct from command-buffer completion or a frame counter.
@_spi(CmdyApp)
public struct DrawablePresentationObservation: Sendable {
    public let surface: UInt64
    public let epoch: UInt64
    public let sequence: UInt64
    public let drawableID: Int
    public let presented: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int
}

/// AppKit source/target adapter for the dedicated Zig render session.
/// Mutable caches, scheduling decisions, rasterization and encoding stay there.
@MainActor
public final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
    weak var source: (any MetalRenderSource)?
    weak var view: MTKView?
    let session: RenderWorkerSession
    var scheduler: RendererScheduler!
    private let producer = ProducerFrameCapture()
    private let cursorLayer = CursorCacheLayer()
    private var config = cmdy_render_schedule_default_config()
    private static var nextSurface: UInt64 = 0
    private var ready = false
    private var closed = false
    /// Set once any committed drawable has been shown on screen.
    private var hasPresentedFrame = false
    private var fullScreenObservers: [NSObjectProtocol] = []
    private var nextRequest: UInt64 = 0
    private var shaderReplies: [UInt64: (String?) -> Void] = [:]
    private var inspectionReplies: [UInt64: (CmdyRenderSessionUpdate?) -> Void] = [:]
    public private(set) var lastFailure: String?
    @_spi(CmdyApp)
    public var modelPublisher: ModelRenderPublisher { session.modelPublisher }
    @_spi(CmdyApp)
    public var cursorCacheStats: [String: Any] { cursorLayer.statistics }
    public var onFailure: ((String?) -> Void)?
    // Deterministic headless qualification uses the same capture/submission path.
    var targetProviderForTesting: ((CmdyRenderFrameIdentity) throws -> (CapturedRenderTarget, CGSize))?
    var onCaptureRequestedForTesting: (() -> Void)?
    var onFrameCompletedForTesting: (() -> Void)? {
        didSet {
            guard !closed else { return }
            scheduler.observeFrames(onFrameCompletedForTesting != nil)
        }
    }
    /// Headless pixel qualification: render subsequent frames into `texture`
    /// through the normal capture and submission path instead of the view's
    /// drawable, and report each completed frame. Pass nil to restore drawables.
    @_spi(CmdyApp)
    public func useOffscreenTargetForTesting(_ texture: MTLTexture?,
                                             onFrameCompleted: (() -> Void)?) {
        guard let texture else {
            targetProviderForTesting = nil
            onFrameCompletedForTesting = nil
            return
        }
        targetProviderForTesting = { identity in
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let target = try CapturedRenderTarget.capture(
                identity: identity, drawable: nil, pass: pass).get()
            pass.colorAttachments[0].texture = nil
            return (target, CGSize(width: texture.width, height: texture.height))
        }
        onFrameCompletedForTesting = onFrameCompleted
    }
    @_spi(CmdyApp)
    public var onDrawablePresentedForTesting: ((DrawablePresentationObservation) -> Void)? {
        didSet { sourceDidChange() }
    }
    private var frameInFlight = false
    private enum TargetFailure: Error { case unavailable }

    public static var framesPresented: Int {
        get { Int(cmdy_gpu_counter(0)) }
        set { cmdy_gpu_counter_set(0, UInt64(clamping: newValue)) }
    }
    public static var rowsRebuilt: Int {
        get { Int(cmdy_gpu_counter(1)) }
        set { cmdy_gpu_counter_set(1, UInt64(clamping: newValue)) }
    }
    public static var rowsReused: Int {
        get { Int(cmdy_gpu_counter(2)) }
        set { cmdy_gpu_counter_set(2, UInt64(clamping: newValue)) }
    }
    private func configure(_ change: (inout CmdyRenderScheduleConfig) -> Void) {
        change(&config)
        sourceDidChange()
        producer.invalidate()
        scheduler.configure(config)
    }
    public var shaderMode: Int {
        get { Int(config.shader_mode) }
        set { guard newValue != shaderMode else { return }; configure { $0.shader_mode = Int64(newValue) } }
    }
    public var smoothCursorEnabled: Bool {
        get { config.smooth_cursor }
        set { guard newValue != smoothCursorEnabled else { return }; configure { $0.smooth_cursor = newValue } }
    }
    public var hostCursorHidden: Bool {
        get { config.host_cursor_hidden }
        set { guard newValue != hostCursorHidden else { return }; configure { $0.host_cursor_hidden = newValue } }
    }
    public var cursorGlideSpeed: Float {
        get { config.cursor_speed }
        set { guard newValue != cursorGlideSpeed else { return }; configure { $0.cursor_speed = newValue } }
    }
    public var cursorGlideMaxDistance: Float {
        get { config.cursor_max_distance }
        set { guard newValue != cursorGlideMaxDistance else { return }; configure { $0.cursor_max_distance = newValue } }
    }
    public var smoothScrollEnabled: Bool {
        get { config.smooth_scroll }
        set { guard newValue != smoothScrollEnabled else { return }; configure { $0.smooth_scroll = newValue } }
    }
    public var textRenderingMode: TextRenderingMode = .current {
        didSet {
            guard oldValue != textRenderingMode else { return }
            sourceDidChange()
            producer.invalidate(); scheduler.preset(textRenderingMode.gpuValue)
        }
    }
    public var onScrollOffsetChanged: ((CGFloat) -> Void)? {
        didSet { scheduler.onScrollOffsetChanged = onScrollOffsetChanged }
    }
    public static let userShaderPreamble: String = String(cString: cmdy_gpu_shader_source(2))

    public convenience init(view: MTKView, source: any MetalRenderSource) throws {
        try self.init(view: view, source: source, nativeCallbackForTesting: nil)
    }
    init(view: MTKView, source: any MetalRenderSource,
         nativeCallbackForTesting: (@Sendable (UInt32) -> Void)?) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { throw MetalError.deviceUnavailable }
        view.device = device
        if view.colorPixelFormat == .invalid { view.colorPixelFormat = .bgra8Unorm }
        view.sampleCount = 1
        Self.nextSurface &+= 1
        if Self.nextSurface == 0 { Self.nextSurface = 1 }
        session = try RenderWorkerSession(device: device, pixelFormat: view.colorPixelFormat,
                                          surface: Self.nextSurface, hostWorkOnly: true, cursorCaching: true,
                                          nativeCallbackForTesting: nativeCallbackForTesting)
        self.source = source; self.view = view
        super.init()
        scheduler = RendererScheduler(session: session, view: view, source: source)
        scheduler.onOverload = { [weak self] in
            self?.report("Renderer control queue is busy; recovering the visible frame.")
        }
        session.onUpdate = { [weak self] in self?.receive($0) }
        session.onCursorOffer = { [weak self] images in
            guard let self, !self.closed, let view = self.view, !view.inLiveResize,
                  let layer = view.layer as? CAMetalLayer else { return false }
            return self.cursorLayer.install(images, in: layer) { [weak self] token in
                self?.session.cancelCursor(token: token, removed: false, requestDraw: true)
            }
        }
        session.onCursorRetired = { [weak self] token in
            guard let self, self.cursorLayer.token == token else { return }
            self.invalidateCursor()
        }
        view.delegate = self
        view.framebufferOnly = false; view.enableSetNeedsDisplay = true
        view.isPaused = true; view.preferredFramesPerSecond = 60
        if let layer = view.layer as? CAMetalLayer {
            layer.allowsNextDrawableTimeout = true
            layer.presentsWithTransaction = false
            // A composited window shows the newest committed drawable at the
            // next refresh, as Ghostty's IOSurface layer does. Waiting for
            // vertical sync first only adds a refresh to every response.
            // Native full screen may scan out directly, so it keeps sync.
            layer.displaySyncEnabled = false
            for (name, synced) in [(NSWindow.didEnterFullScreenNotification, true),
                                   (NSWindow.didExitFullScreenNotification, false)] {
                fullScreenObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main) { [weak layer, weak view] note in
                    MainActor.assumeIsolated {
                        guard let window = note.object as? NSWindow, window === view?.window else { return }
                        layer?.displaySyncEnabled = synced
                    }
                })
            }
        }
    }

    isolated deinit { close() }

    /// In-flight work drains off the UI executor; repeated calls are harmless.
    public func close() {
        guard !closed else { return }
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver); fullScreenObservers.removeAll()
        closed = true; cursorLayer.clear(); producer.invalidate(); scheduler.close(); session.close()
        let shaders = Array(shaderReplies.values); shaderReplies.removeAll()
        let inspections = Array(inspectionReplies.values); inspectionReplies.removeAll()
        for reply in shaders { reply("Renderer closed") }
        for reply in inspections { reply(nil) }
        onFailure = nil; onScrollOffsetChanged = nil; onDrawablePresentedForTesting = nil
    }
    public func shutdown() async { close(); await session.shutdown() }

    @discardableResult
    public func loadUserShader(source: String?) async -> String? {
        guard !closed else { return "Renderer closed" }
        guard (source?.utf8.count ?? 0) <= 1_048_576 else { return "Shader exceeds the 1 MiB source limit" }
        guard shaderReplies.count + inspectionReplies.count < RenderUpdateMailbox.replyLimit else {
            return "Renderer control queue is busy; retry the shader change"
        }
        let request = requestID()
        return await withCheckedContinuation { continuation in
            shaderReplies[request] = { continuation.resume(returning: $0) }
            let environment = scheduler.environment(readFocus: false)
            if !scheduler.enqueue(attempt: { [session] in session.loadShader(source, requestID: request, environment: environment) }) {
                shaderReplies.removeValue(forKey: request)?("Renderer control queue is busy; retry the shader change")
            }
        }
    }
    private func requestID() -> UInt64 {
        nextRequest &+= 1; if nextRequest == 0 { nextRequest = 1 }; return nextRequest
    }
    func synchronizeForTesting(at now: Double? = nil) async -> CmdyRenderSessionUpdate? {
        guard !closed, shaderReplies.count + inspectionReplies.count < RenderUpdateMailbox.replyLimit else { return nil }
        let request = requestID()
        return await withCheckedContinuation { continuation in
            inspectionReplies[request] = { continuation.resume(returning: $0) }
            if !scheduler.inspect(request: request, at: now) {
                inspectionReplies.removeValue(forKey: request)?(nil)
            }
        }
    }
    private func receive(_ update: CmdyRenderSessionUpdate) {
        guard !closed else { return }
        config.has_user_pipeline = update.config.has_user_pipeline
        config.user_shader_uses_time = update.config.user_shader_uses_time
        if update.kind == UInt32(CMDY_SESSION_INSPECTION) {
            inspectionReplies.removeValue(forKey: update.request_id)?(update)
        } else if update.request_id != 0, let reply = shaderReplies.removeValue(forKey: update.request_id) {
            reply(update.kind == UInt32(CMDY_SESSION_ERROR) ? Self.message(update) : nil)
        }
        guard !closed else { return }
        scheduler.receive(update)
        switch update.kind {
        case UInt32(CMDY_SESSION_READY):
            ready = true; scheduler.requestDraw()
        case UInt32(CMDY_SESSION_CAPTURE): requestCapture(update)
        case UInt32(CMDY_SESSION_FRAME):
            if update.success != 0 { report(nil) }
            else { report("A terminal frame could not be rendered.") }
        case UInt32(CMDY_SESSION_ERROR):
            if update.request_id == 0 {
                if update.identity.sequence == 0 && !ready {
                    report("Terminal renderer initialization failed: " + Self.message(update))
                    close()
                } else if lastFailure == nil { report(Self.message(update)) }
            }
        default: break
        }
        let completed = frameInFlight && !update.inspection.frame_in_flight
        frameInFlight = update.inspection.frame_in_flight
        if completed { onFrameCompletedForTesting?() }
    }
    private static func message(_ update: CmdyRenderSessionUpdate) -> String {
        var message = update.message
        return withUnsafePointer(to: &message) {
            $0.withMemoryRebound(to: CChar.self, capacity: 512) { String(cString: $0) }
        }
    }
    private func report(_ message: String?) {
        guard message != lastFailure else { return }
        lastFailure = message; onFailure?(message)
    }

    public func draw(in view: MTKView) {
        guard !closed else { return }
        scheduler.beginDraw(in: view)
    }
    /// Admit the completed viewport update without replacing AppKit invalidation.
    @_spi(CmdyApp)
    public func requestViewportDraw(in view: MTKView) {
        guard !closed, source is any WorkerPublishedRenderSource else { return }
        scheduler.beginDraw(in: view, viewport: true)
    }
    private func requestCapture(_ update: CmdyRenderSessionUpdate) {
        guard !closed, update.identity.epoch == session.epoch,
              update.source_revision == session.sourceRevision else { return }
        // Capture only host-owned data here. The worker obtains a fresh layer
        // drawable after accepting this identity; no nested MTKView.draw call.
        capture(update)
    }
    private func capture(_ update: CmdyRenderSessionUpdate) {
        guard !closed, let source, let view else { scheduler.captureFailed(update.identity, reason: 2); return }
        onCaptureRequestedForTesting?()
        guard update.identity.epoch == session.epoch, update.source_revision == session.sourceRevision else { return }
        let started = RendererPerformanceTrace.now()
        var target: CapturedRenderTarget?
        do {
            let provider = targetProviderForTesting
            let layer = provider == nil ? view.layer as? CAMetalLayer : nil
            guard provider != nil || layer != nil else { throw TargetFailure.unavailable }
            let environment = ProducerFrameEnvironment(identity: update.identity, drawableSize: view.drawableSize,
                config: update.config, motion: update.inspection, preset: TextRenderingMode(gpuValue: update.preset),
                liveResize: view.inLiveResize, now: ProcessInfo.processInfo.systemUptime)
            let acquire: (() throws -> CGSize)? = provider.map { provider in
                { let result = try provider(update.identity); target = result.0; return result.1 }
            }
            let frame = try producer.capture(source: source, environment: environment, acquireDrawable: acquire)
            onScrollOffsetChanged?(frame.renderedScrollPoints)
            guard update.identity.epoch == session.epoch, update.source_revision == session.sourceRevision, !closed else { return }
            let submitted: Bool
            if let target {
                submitted = session.submit(frame: frame.input, target: target,
                    cursorBlinkEligible: frame.cursorBlinkEligible, environment: scheduler.environment())
            } else if let layer {
                let observer: ((CmdyRenderLayerPresentation) -> Void)?
                if onDrawablePresentedForTesting != nil || !hasPresentedFrame {
                    observer = { [weak self] value in self?.observePresentation(value) }
                } else { observer = nil }
                submitted = session.submit(frame: frame.input, layer: layer,
                    cursorBlinkEligible: frame.cursorBlinkEligible, environment: scheduler.environment(),
                    publicationRevision: source is any WorkerPublishedRenderSource ? update.source_revision : nil,
                    onPresented: observer)
            } else { submitted = false }
            guard submitted else {
                producer.invalidate(); scheduler.captureFailed(update.identity, reason: 0); return
            }
            RendererPerformanceTrace.record(event: "draw.captureHandoff", started: started,
                fields: ["source": Int(bitPattern: ObjectIdentifier(source)), "epoch": Int(clamping: update.identity.epoch)])
        } catch TargetFailure.unavailable {
            scheduler.captureFailed(update.identity, reason: 0)
        } catch ProducerCaptureFailure.invalidGeometry {
            scheduler.captureFailed(update.identity, reason: 2)
        } catch ProducerCaptureFailure.invalidated {
            scheduler.captureFailed(update.identity, reason: 2)
        } catch ProducerCaptureFailure.reentrantCapture {
            scheduler.captureFailed(update.identity, reason: 2)
        } catch {
            report("Terminal frame capture failed: \(error)")
            scheduler.captureFailed(update.identity, reason: 1)
        }
    }
    private func observePresentation(_ value: CmdyRenderLayerPresentation) {
        guard !closed, session.epoch == value.identity.epoch else { return }
        if value.presented_time > 0 {
            hasPresentedFrame = true
        } else if !hasPresentedFrame, view?.window?.occlusionState.contains(.visible) == true {
            // A window's first frames can be committed before it reaches the
            // screen. Nothing newer may follow when the content is already
            // complete, so redraw now rather than on the drawable recovery
            // timer. Only until one frame has actually been presented.
            noteActivity()
        }
        onDrawablePresentedForTesting?(DrawablePresentationObservation(
            surface: value.identity.surface, epoch: value.identity.epoch, sequence: value.identity.sequence,
            drawableID: Int(clamping: value.drawable_id), presented: value.presented_time > 0,
            pixelWidth: value.pixel_width, pixelHeight: value.pixel_height))
    }
    public func invalidateRowCache() {
        sourceDidChange()
        producer.invalidate(); scheduler.clearRows()
    }
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        sourceDidChange()
        producer.invalidate(); scheduler.resize()
    }
    public func noteScroll(pixels: CGFloat) { invalidateCursor(); scheduler.noteScroll(pixels: pixels) }
    public func setScrollHeld(_ pixels: CGFloat) { invalidateCursor(); scheduler.setScrollHeld(pixels) }
    public func updateScrollHeld(_ pixels: CGFloat, activityPixels: CGFloat) { invalidateCursor(); scheduler.updateScrollHeld(pixels, activityPixels: activityPixels) }
    public func noteSelectionInteraction() { sourceDidChange(); scheduler.noteSelectionInteraction() }
    public func cancelScrollAnimation() { scheduler.cancelScrollAnimation() }
    public func noteActivity() { invalidateCursor(); scheduler.noteActivity() }
    private func invalidateCursor() {
        guard !closed else { return }
        let token = cursorLayer.clear()
        session.cancelCursor(token: token, removed: true)
    }
    /// Publish host content changes before the next draw request.
    /// This does not clear immutable producer rows or the native GPU row cache.
    @_spi(CmdyApp)
    public func sourceDidChange() {
        invalidateCursor()
        guard !closed, source is any WorkerPublishedRenderSource else { return }
        scheduler.sourceChanged()
    }
    /// Reactive shader telemetry is copied without discarding published rows,
    /// geometry or style, and without scheduling a frame ahead of PTY output.
    @_spi(CmdyApp)
    public func updateInputActivity(keypressTime: Double, typingRate: Float) {
        scheduler.updateInputActivity(keypressTime: keypressTime, typingRate: typingRate)
    }
    @_spi(CmdyApp) public func noteKeyboardInteraction() { invalidateCursor(); scheduler.noteKeyboardInteraction(at: ProcessInfo.processInfo.systemUptime) }
    @_spi(CmdyApp) public func cancelKeyboardInteraction() { scheduler.cancelKeyboardInteraction() }
    static var sharedCoreResourceConstructionCount: Int { cmdy_gpu_shared_constructions() }
    static func resetSharedCoreResourcesForTesting() { cmdy_gpu_shared_reset() }
    static func sharedCoreResourceIdentity(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm, sampleCount: Int = 1) throws -> ObjectIdentifier {
        var error = [CChar](repeating: 0, count: 4096)
        guard let pointer = cmdy_gpu_shared_identity(Unmanaged.passUnretained(device as AnyObject).toOpaque(), UInt64(pixelFormat.rawValue), sampleCount, &error, error.count) else { throw MetalError.pipelineCreationFailed(String(cString: error)) }
        return ObjectIdentifier(Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue())
    }
    static func sharedCommandQueueIdentity(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm, sampleCount: Int = 1) throws -> ObjectIdentifier {
        try sharedCoreResourceIdentity(device: device, pixelFormat: pixelFormat, sampleCount: sampleCount)
    }
    static func kittyAspectFitRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        cmdy_gpu_kitty_fit(imageSize.width, imageSize.height, CmdyRenderRect(container)).cgRect
    }
}

extension TextRenderingMode {
    init(gpuValue: UInt32) {
        switch gpuValue {
        case 1: self = .ySnap
        case 2: self = .atlasPadding
        case 3: self = .nearest
        case 4: self = .highContrast
        case 5: self = .crisp
        default: self = .current
        }
    }
    var gpuValue: UInt32 { switch self { case .current: 0; case .ySnap: 1; case .atlasPadding: 2; case .nearest: 3; case .highContrast: 4; case .crisp: 5 } }
}
extension RenderLineMode {
    var gpuValue: UInt32 { switch self { case .single: 0; case .doubleWidth: 1; case .doubledTop: 2; case .doubledDown: 3 } }
}
extension RenderCursorStyle {
    var gpuValue: UInt32 { switch self { case .blinkBlock: 0; case .steadyBlock: 1; case .blinkUnderline: 2; case .steadyUnderline: 3; case .blinkBar: 4; case .steadyBar: 5 } }
}
extension KittyPlaceholderCell {
    var gpuValue: CmdyGpuPlaceholder { CmdyGpuPlaceholder(image_id: imageId, placement_id: placementId, row: row, col: col, placeholder_row: placeholderRow, placeholder_col: placeholderCol, msb: msb) }
}
private extension CmdyGpuPlaceholder {
    var swiftValue: KittyPlaceholderCell { KittyPlaceholderCell(row: row, col: col, imageId: image_id, placementId: placement_id, placeholderRow: placeholder_row, placeholderCol: placeholder_col, msb: msb) }
}
extension IndependentRowKey {
    func withGPUKey<T>(_ body: (UnsafePointer<CmdyGpuRowKey>) -> T) -> T {
        fontName.withCString { name in
            var value = CmdyGpuRowKey(absolute_row: absoluteRow, version: version, line_mode: lineMode.gpuValue, cols: cols, width: widthPx, height: heightPx,
                scale_bits: scaleBits, font_name: name, font_size_bits: fontSizeBits, alternate_buffer: alternateBuffer ? 1 : 0,
                kitty_images: kittyStamp.imagesCount, kitty_placements: kittyStamp.placementsCount, kitty_next_image: kittyStamp.nextImageId, kitty_next_placement: kittyStamp.nextPlacementId,
                foreground: foreground, background: background, preset: preset.gpuValue, antialias_blocks: antialiasBlocks ? 1 : 0, buffering_mode: bufferingMode == .perRowPersistent ? 0 : 1)
            return body(&value)
        }
    }
}
