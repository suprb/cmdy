import CmdyNative
import Foundation
import Metal

@MainActor
private final class SessionProbe {
    let session: RenderWorkerSession
    let frame: CapturedFrameInput
    let texture: any MTLTexture
    let reference: [UInt8]
    var done: CheckedContinuation<Void, Never>?
    var submitted = false
    var captured = false

    init(frame: CapturedFrameInput, reference: [UInt8]) throws {
        self.frame = frame; self.reference = reference
        let device = MTLCreateSystemDefaultDevice()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 96, height: 40, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        texture = device.makeTexture(descriptor: descriptor)!
        session = try RenderWorkerSession(device: device, pixelFormat: .bgra8Unorm, surface: 999)
        session.onUpdate = { [weak self] update in self?.receive(update) }
        var config = CmdyRenderSessionCommand()
        config.kind = UInt32(CMDY_SESSION_CONFIG); config.environment = environment()
        config.config = cmdy_render_schedule_default_config()
        precondition(session.post(config))
        // Keep the UI executor occupied in this headless fixture until the
        // owner changes epoch. READY is then provably an older queued reply.
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while session.epoch == 1 {
            precondition(ProcessInfo.processInfo.systemUptime < deadline)
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    func environment() -> CmdyRenderScheduleEnvironment {
        .init(now: ProcessInfo.processInfo.systemUptime, cell_height_pixels: 20, maximum_fps: 120,
            has_view: true, has_source: true, visible: true, key_window: true,
            caret_focused: false, low_power: false, thermal: 0)
    }
    func receive(_ update: CmdyRenderSessionUpdate) {
        if update.kind == UInt32(CMDY_SESSION_CAPTURE) || update.kind == UInt32(CMDY_SESSION_FRAME) {
            precondition(update.identity.epoch == session.epoch)
        }
        switch update.kind {
        case UInt32(CMDY_SESSION_READY):
            precondition(update.identity.epoch < session.epoch)
            print("Swift session: READY survives a provably later configuration epoch PASS")
            var command = CmdyRenderSessionCommand()
            command.kind = UInt32(CMDY_SESSION_BEGIN_DRAW); command.environment = environment()
            precondition(session.post(command))
        case UInt32(CMDY_SESSION_CAPTURE):
            precondition(!captured); captured = true
            // Rebind the retained production packet after all source objects and
            // the producer autorelease pool are gone. Capture copies nested data.
            let rebound = try! frame.withUnsafeNativeInput { pointer in
                var value = pointer.pointee; value.identity = update.identity
                return try CapturedFrameInput.capture(&value).get()
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let target = try! CapturedRenderTarget.capture(identity: update.identity, drawable: nil, pass: pass).get()
            precondition(session.submit(frame: rebound, target: target, cursorBlinkEligible: false, environment: environment()))
            pass.colorAttachments[0].texture = nil
        case UInt32(CMDY_SESSION_FRAME):
            precondition(update.success != 0 && !update.inspection.drawing)
            submitted = true
        case UInt32(CMDY_SESSION_ACTIONS):
            if submitted && !update.inspection.frame_in_flight {
                var pixels = [UInt8](repeating: 0, count: 96 * 40 * 4)
                pixels.withUnsafeMutableBytes {
                    texture.getBytes($0.baseAddress!, bytesPerRow: 96 * 4,
                        from: MTLRegionMake2D(0, 0, 96, 40), mipmapLevel: 0)
                }
                precondition(pixels == reference)
                session.close()
                let continuation = done; done = nil; continuation!.resume()
            }
        case UInt32(CMDY_SESSION_ERROR): preconditionFailure("Unexpected native session error")
        default: preconditionFailure("Unknown native session event")
        }
    }
}

@MainActor
func verifySwiftSessionPipeline(frame: CapturedFrameInput, reference: [UInt8]) async throws {
    let probe = try SessionProbe(frame: frame, reference: reference)
    await withCheckedContinuation { probe.done = $0 }
    async let first: Void = probe.session.shutdown()
    async let second: Void = probe.session.shutdown()
    _ = await (first, second)
    precondition(probe.session.epoch == 0 && probe.captured && probe.submitted)
    print("Swift asynchronous session: production-frame pixels match raw reference after source release; concurrent awaited shutdown PASS")
}
