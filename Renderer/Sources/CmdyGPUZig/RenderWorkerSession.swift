import CmdyNative
import Foundation
import Metal
import QuartzCore

enum RenderWorkerSessionFailure: Error { case allocation }

private struct LayerPresentationUpdate: @unchecked Sendable {
    let value: CmdyRenderLayerPresentation
}

@MainActor
private final class LayerPresentationDelivery {
    let callback: (CmdyRenderLayerPresentation) -> Void
    init(_ callback: @escaping (CmdyRenderLayerPresentation) -> Void) { self.callback = callback }
    func receive(_ update: LayerPresentationUpdate) { callback(update.value) }
}

private final class SessionDelivery: @unchecked Sendable {
    @MainActor weak var owner: RenderWorkerSession?
    let mailbox = RenderUpdateMailbox()
    let cursorMailbox = CursorCacheMailbox()
    private let mainDelivery: MainRunLoopDelivery
    private let nativeCallbackForTesting: (@Sendable (UInt32) -> Void)?
    @MainActor init(nativeCallbackForTesting: (@Sendable (UInt32) -> Void)?) {
        self.nativeCallbackForTesting = nativeCallbackForTesting
        self.mainDelivery = MainRunLoopDelivery()
    }
    func publish(_ update: CmdyRenderSessionUpdate) {
        nativeCallbackForTesting?(update.kind)
        if update.kind == UInt32(CMDY_SESSION_CURSOR_CACHE) {
            if cursorMailbox.append(offer: CursorCacheOffer(update)) {
                DispatchQueue.main.async { self.drainCursor() }
            }
            return
        }
        if update.kind == UInt32(CMDY_SESSION_CURSOR_RETIRED) {
            if cursorMailbox.append(retired: update.cursor_token) {
                DispatchQueue.main.async { self.drainCursor() }
            }
            return
        }
        if mailbox.append(update) { mainDelivery.enqueue { self.drain() } }
    }
    @MainActor private func drainCursor() {
        let (offer, retired) = cursorMailbox.take()
        if let offer { owner?.receiveCursor(offer) }
        if let retired { owner?.receiveCursorRetired(retired) }
        if cursorMailbox.finishDrain() { DispatchQueue.main.async { self.drainCursor() } }
    }
    @MainActor private func drain() {
        for update in mailbox.take() {
            // Release admission before invoking UI code, which may post a new
            // request or flush a backpressured command in response.
            if update.value.request_id != 0 { mailbox.releaseReply(update.value.request_id) }
            owner?.receive(update.value)
        }
        if mailbox.finishDrain() { mainDelivery.enqueue { self.drain() } }
    }
}

/// A consumed handle has exactly one off-thread join owner.
private struct SessionJoin: @unchecked Sendable {
    let native: OpaquePointer
    func close() { cmdy_render_session_close(native) }
    func join() { precondition(cmdy_render_session_destroy(native) != 0) }
}

/// Pointer access and consumption are serialized, including nonisolated deinit.
/// The lock never covers a worker join or renderer work.
fileprivate final class SessionStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let drained = DispatchGroup()
    private var native: OpaquePointer?
    init(_ native: OpaquePointer) { self.native = native }
    func withNative<T>(_ body: (OpaquePointer?) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(native)
    }
    private func take() -> SessionJoin? {
        lock.lock(); defer { lock.unlock() }
        guard let native else { return nil }
        self.native = nil
        drained.enter()
        return SessionJoin(native: native)
    }
    private func startShutdown() {
        if let item = take() {
            item.close()
            let drained = drained
            DispatchQueue.global(qos: .utility).async { item.join(); drained.leave() }
        }
    }
    deinit { startShutdown() }
    func shutdown() async {
        startShutdown()
        await withCheckedContinuation { continuation in
            drained.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
}

/// A thread-safe terminal-owner endpoint. It shares the session lifetime guard,
/// never the UI adapter. Native admission copies/retains the borrowed packet.
@_spi(CmdyApp)
public final class ModelRenderPublisher: @unchecked Sendable {
    fileprivate let storage: SessionStorage
    fileprivate init(storage: SessionStorage) { self.storage = storage }
    @discardableResult
    public func publish(_ input: UnsafePointer<CmdyRenderModelInput>) -> Bool {
        storage.withNative { cmdy_render_session_publish_model($0, input) != 0 }
    }
}

/// UI adapter for the native owner. Calls enqueue copied values/owned packets;
/// no host code reads or waits for a mutable GPU or scheduler object.
@MainActor
final class RenderWorkerSession {
    private let storage: SessionStorage
    private let delivery: SessionDelivery
    private var closed = false
    var onUpdate: ((CmdyRenderSessionUpdate) -> Void)?
    var onCursorOffer: ((CursorFrameImages) -> Bool)?
    var onCursorRetired: ((UInt64) -> Void)?
    var modelPublisher: ModelRenderPublisher { ModelRenderPublisher(storage: storage) }

    init(device: any MTLDevice, pixelFormat: MTLPixelFormat, sampleCount: Int = 1,
         surface: UInt64, now: Double = ProcessInfo.processInfo.systemUptime,
         hostWorkOnly: Bool = false, cursorCaching: Bool = false,
         nativeCallbackForTesting: (@Sendable (UInt32) -> Void)? = nil) throws {
        let delivery = SessionDelivery(nativeCallbackForTesting: nativeCallbackForTesting)
        let context = Unmanaged.passRetained(delivery).toOpaque()
        let native = withExtendedLifetime(device) {
            cmdy_render_session_create_with_options(Unmanaged.passUnretained(device as AnyObject).toOpaque(),
                UInt64(pixelFormat.rawValue), sampleCount, surface, now,
                UInt32(hostWorkOnly ? CMDY_SESSION_HOST_WORK_UPDATES : CMDY_SESSION_ESSENTIAL_UPDATES)
                    | UInt32(cursorCaching ? CMDY_SESSION_CURSOR_CACHE_UPDATES : 0), { context, pointer in
                    guard let context, let pointer else { return }
                    let delivery = Unmanaged<SessionDelivery>.fromOpaque(context).takeUnretainedValue()
                    delivery.publish(pointer.pointee)
                }, context, { context in
                    if let context { Unmanaged<SessionDelivery>.fromOpaque(context).release() }
                })
        }
        guard let native else {
            Unmanaged<SessionDelivery>.fromOpaque(context).release()
            throw RenderWorkerSessionFailure.allocation
        }
        storage = SessionStorage(native)
        self.delivery = delivery
        delivery.owner = self
    }

    var epoch: UInt64 { storage.withNative { cmdy_render_session_epoch($0) } }
    var sourceRevision: UInt64 { storage.withNative { cmdy_render_session_source_revision($0) } }
    fileprivate func receiveCursor(_ offer: CursorCacheOffer) {
        guard !closed else { return }
        let generation = storage.withNative { cmdy_render_session_cursor_generation($0) }
        var installed = false
        if let images = offer.images, images.epoch == epoch, images.revision == sourceRevision,
           images.generation == generation {
            installed = onCursorOffer?(images) ?? false
        }
        let accepted = storage.withNative { cmdy_render_session_cursor_respond($0, offer.token, installed ? 1 : 0) != 0 }
        if installed && !accepted { onCursorRetired?(offer.token) }
    }
    fileprivate func receiveCursorRetired(_ token: UInt64) {
        guard !closed else { return }
        onCursorRetired?(token)
    }
    func cancelCursor(token: UInt64, removed: Bool, requestDraw: Bool = false) {
        guard !closed else { return }
        storage.withNative { cmdy_render_session_cursor_cancel($0, token, removed ? 1 : 0, requestDraw ? 1 : 0) }
    }

    fileprivate func receive(_ update: CmdyRenderSessionUpdate) {
        guard !closed else { return }
        // Capture/presentation replies belong to an epoch. Scheduler actions
        // are ordered deltas: dropping an earlier timer START can also lose the
        // later state when the native scheduler correctly avoids restarting it.
        // READY and control replies must survive a following config change too.
        let scoped = update.kind == UInt32(CMDY_SESSION_CAPTURE)
            || update.kind == UInt32(CMDY_SESSION_FRAME)
            || (update.kind == UInt32(CMDY_SESSION_ERROR) && update.identity.sequence != 0)
        if scoped && (update.identity.epoch == 0 || update.identity.epoch != epoch
            || update.source_revision == 0 || update.source_revision != sourceRevision) { return }
        onUpdate?(update)
    }

    @discardableResult
    func post(_ command: CmdyRenderSessionCommand) -> Bool {
        guard !closed else { return false }
        if command.request_id != 0, !delivery.mailbox.reserveReply(command.request_id) { return false }
        var command = command
        let accepted = storage.withNative { cmdy_render_session_post($0, &command) != 0 }
        if !accepted, command.request_id != 0 { delivery.mailbox.releaseReply(command.request_id) }
        return accepted
    }

    /// The worker sends one capacity update after queued controls drain. False
    /// means retry now; the release may have preceded this registration.
    func waitForCapacity() -> Bool {
        guard !closed else { return false }
        let nativeWait = storage.withNative { cmdy_render_session_wait_for_capacity($0) != 0 }
        return nativeWait || delivery.mailbox.replyCapacityFull
    }

    @discardableResult
    func submit(frame: CapturedFrameInput, target: CapturedRenderTarget,
                cursorBlinkEligible: Bool, environment: CmdyRenderScheduleEnvironment) -> Bool {
        guard !closed else { return false }
        return storage.withNative { native in
            frame.withUnsafeNativeHandle { frame in
                target.withUnsafeNativeHandle { target in
                    cmdy_render_session_submit(native, frame, target, cursorBlinkEligible ? 1 : 0, environment) != 0
                }
            }
        }
    }

    /// Native code retains the layer and obtains its drawable on the GPU owner.
    /// The optional observer owns its delivery separately from session shutdown.
    @discardableResult
    func submit(frame: CapturedFrameInput, layer: CAMetalLayer,
                cursorBlinkEligible: Bool, environment: CmdyRenderScheduleEnvironment,
                publicationRevision: UInt64? = nil,
                onPresented: ((CmdyRenderLayerPresentation) -> Void)?) -> Bool {
        guard !closed else { return false }
        let context = onPresented.map { Unmanaged.passRetained(LayerPresentationDelivery($0)).toOpaque() }
        let callback: CmdyRenderLayerPresented? = context == nil ? nil : { context, pointer in
            guard let context, let pointer else { return }
            let delivery = Unmanaged<LayerPresentationDelivery>.fromOpaque(context).takeUnretainedValue()
            let update = LayerPresentationUpdate(value: pointer.pointee)
            DispatchQueue.main.async { delivery.receive(update) }
        }
        let dispose: CmdyRenderWorkerCallback? = context == nil ? nil : { context in
            if let context { Unmanaged<LayerPresentationDelivery>.fromOpaque(context).release() }
        }
        let accepted = storage.withNative { native in
            withExtendedLifetime(layer) {
                frame.withUnsafeNativeHandle { frame in
                    if let publicationRevision {
                        return cmdy_render_session_publish_layer(native, frame, publicationRevision,
                            Unmanaged.passUnretained(layer).toOpaque(), cursorBlinkEligible ? 1 : 0,
                            environment, callback, context, dispose) != 0
                    }
                    return cmdy_render_session_submit_layer(native, frame,
                        Unmanaged.passUnretained(layer).toOpaque(), cursorBlinkEligible ? 1 : 0,
                        environment, callback, context, dispose) != 0
                }
            }
        }
        if !accepted, let context { Unmanaged<LayerPresentationDelivery>.fromOpaque(context).release() }
        return accepted
    }

    /// Synchronous revision fence; capacity pressure cannot preserve old work.
    @discardableResult
    func sourceChanged(environment: CmdyRenderScheduleEnvironment) -> UInt64 {
        guard !closed else { return 0 }
        return storage.withNative { cmdy_render_session_source_changed($0, environment) }
    }

    /// Zero is explicit backpressure: no epoch change occurred.
    @discardableResult
    func invalidate(environment: CmdyRenderScheduleEnvironment) -> UInt64 {
        guard !closed else { return 0 }
        return storage.withNative { cmdy_render_session_invalidate($0, environment) }
    }

    @discardableResult
    func loadShader(_ source: String?, requestID: UInt64, environment: CmdyRenderScheduleEnvironment) -> Bool {
        guard !closed, delivery.mailbox.reserveReply(requestID) else { return false }
        let accepted = storage.withNative { native in
            guard let source else { return cmdy_render_session_shader(native, nil, 0, requestID, environment) != 0 }
            return source.utf8CString.withUnsafeBufferPointer {
                cmdy_render_session_shader(native, $0.baseAddress, $0.count - 1, requestID, environment) != 0
            }
        }
        if !accepted { delivery.mailbox.releaseReply(requestID) }
        return accepted
    }

    func close() {
        closed = true; onUpdate = nil
        onCursorOffer = nil; onCursorRetired = nil
        delivery.mailbox.close()
        delivery.cursorMailbox.close()
        storage.withNative { cmdy_render_session_close($0) }
    }

    /// Optional awaited drain for orderly app teardown; the UI executor remains free.
    func shutdown() async {
        close()
        await storage.shutdown()
    }
}
