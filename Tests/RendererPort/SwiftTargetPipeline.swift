import AppKit
import Darwin
import CmdyNative
import Metal

/// Mutable fields below are accessed only by the Zig owner. Main retains the
/// work until its semaphore fires and worker destruction joins every callback.
private final class TargetPipelineWork: @unchecked Sendable {
    var frame: CapturedFrameInput
    var target: CapturedRenderTarget?
    let device: any MTLDevice
    let texture: any MTLTexture
    let done = DispatchSemaphore(value: 0)
    var worker: OpaquePointer?
    var ownerThread: pthread_t?
    var gpu: OpaquePointer?
    var reference: [UInt8]?
    var passed = false
    init(frame: CapturedFrameInput, device: any MTLDevice, texture: any MTLTexture) {
        self.frame = frame; self.device = device; self.texture = texture
    }
    func reuseMetadataOnWorker() {
        precondition(!Thread.isMainThread && ownerThread != nil && pthread_equal(ownerThread!, pthread_self()) != 0)
        frame.withUnsafeNativeInput { original in
            let before = original.pointee
            // The scalar packet owns no borrowed row, image, or GPU pointers.
            var metadata = before
            metadata.rows = nil; metadata.row_count = 0
            metadata.parameters.drawable = nil; metadata.parameters.pass = nil
            metadata.parameters.rows = nil; metadata.parameters.row_count = 0
            metadata.parameters.kitty_images = nil; metadata.parameters.kitty_image_count = 0
            metadata.parameters.kitty_placements = nil; metadata.parameters.kitty_placement_count = 0
            metadata.parameters.live_kitty_ids = nil; metadata.parameters.live_kitty_count = 0
            metadata.identity.sequence += 100
            metadata.parameters.now += 0.5
            metadata.buffer_line_count += 37
            let sequence = metadata.identity.sequence
            var intermediate: CapturedFrameInput? = try! frame.reusingContent(&metadata).get()
            weak let releasedIntermediate = intermediate
            // Caller mutation after return cannot change the captured scalars.
            metadata.identity.sequence = 0
            metadata.parameters.now = -123
            metadata.buffer_line_count = 0
            intermediate!.withUnsafeNativeInput {
                precondition($0.pointee.identity.sequence == sequence)
                precondition($0.pointee.parameters.now == before.parameters.now + 0.5)
                precondition($0.pointee.buffer_line_count == before.buffer_line_count + 37)
                precondition($0.pointee.rows == before.rows && $0.pointee.row_count == before.row_count)
            }
            precondition(original.pointee.identity.sequence == before.identity.sequence)
            precondition(original.pointee.parameters.now == before.parameters.now)
            // Restore visual scalar values for comparison with the untouched
            // original frame, while retaining a new frame identity.
            metadata.parameters = before.parameters
            metadata.parameters.drawable = nil; metadata.parameters.pass = nil
            metadata.parameters.rows = nil; metadata.parameters.row_count = 0
            metadata.parameters.kitty_images = nil; metadata.parameters.kitty_image_count = 0
            metadata.parameters.kitty_placements = nil; metadata.parameters.kitty_placement_count = 0
            metadata.parameters.live_kitty_ids = nil; metadata.parameters.live_kitty_count = 0
            metadata.buffer_line_count = before.buffer_line_count
            metadata.identity.sequence = sequence + 1
            func rejected(_ input: inout CmdyRenderFrameInput) {
                guard case .failure(.invalidInput) = intermediate!.reusingContent(&input) else {
                    preconditionFailure("Invalid worker frame metadata was accepted")
                }
            }
            var invalid = metadata
            invalid.identity.epoch += 1; rejected(&invalid)
            invalid = metadata; invalid.identity.surface += 1; rejected(&invalid)
            invalid = metadata; invalid.identity.sequence = 0; rejected(&invalid)
            invalid = metadata; invalid.rows = before.rows; invalid.row_count = before.row_count; rejected(&invalid)
            frame = try! intermediate!.reusingContent(&metadata).get()
            intermediate = nil
            precondition(releasedIntermediate == nil)
            metadata.identity.sequence = 0; metadata.parameters.now = -456
            frame.withUnsafeNativeInput {
                precondition($0.pointee.identity.sequence == sequence + 1)
                precondition($0.pointee.rows == before.rows && $0.pointee.row_count == before.row_count)
                precondition($0.pointee.parameters.now == before.parameters.now)
            }
        }
    }
    func pixels() -> [UInt8] {
        precondition(!Thread.isMainThread)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }
    func drawRawReference() {
        frame.withUnsafeNativeInput { pointer in
            let input = pointer.pointee
            var rows: [CmdyGpuFrameRow] = []
            defer { for row in rows { cmdy_gpu_row_release(row.entry) } }
            for source in UnsafeBufferPointer(start: input.rows, count: input.row_count) {
                precondition(source.image_count == 0 && source.placeholder_count == 0)
                var key = source.key
                let entry = cmdy_gpu_row_resolve(gpu, &key, source.revision, cmdy_render_input_view(source.text), nil, 0, nil, 0)!
                var row = source.placement; row.entry = cmdy_gpu_row_retain(entry)!
                rows.append(row)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            withExtendedLifetime(pass) {
                rows.withUnsafeBufferPointer { native in
                    var parameters = input.parameters
                    parameters.pass = UnsafeRawPointer(Unmanaged.passUnretained(pass).toOpaque())
                    parameters.rows = native.baseAddress; parameters.row_count = native.count
                    precondition(cmdy_gpu_draw(gpu, &parameters) != 0)
                }
            }
        }
    }
}

private func targetPipelineEvent(_ context: UnsafeMutableRawPointer?, _ kind: UInt32) {
    precondition(!Thread.isMainThread && kind == 1)
    let work = Unmanaged<TargetPipelineWork>.fromOpaque(context!).takeUnretainedValue()
    let pixels = work.pixels()
    if let reference = work.reference {
        precondition(reference == pixels)
        work.passed = true
        cmdy_gpu_destroy(work.gpu); work.gpu = nil
        cmdy_render_worker_stop(work.worker)
        work.done.signal()
    } else {
        precondition(pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element != 0 })
        work.reference = pixels
        precondition(!work.target!.draw(frame: work.frame, on: work.gpu!)) // Already consumed after GPU completion.
        work.drawRawReference()
    }
}
private func targetPipelineRun(_ context: UnsafeMutableRawPointer?, _ worker: OpaquePointer?, _ epoch: UInt64) {
    precondition(!Thread.isMainThread && epoch == 1)
    let work = Unmanaged<TargetPipelineWork>.fromOpaque(context!).takeUnretainedValue()
    work.worker = worker
    work.ownerThread = pthread_self()
    var error = [CChar](repeating: 0, count: 2048)
    work.gpu = cmdy_gpu_create_on_worker(worker, Unmanaged.passUnretained(work.device as AnyObject).toOpaque(),
        UInt64(MTLPixelFormat.bgra8Unorm.rawValue), 1, 1, &error, error.count)
    precondition(work.gpu != nil, String(cString: error))
    cmdy_gpu_set_event(work.gpu, targetPipelineEvent, context)
    work.reuseMetadataOnWorker()
    let identity = work.frame.withUnsafeNativeInput { $0.pointee.identity }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = work.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    // Compile and execute target capture directly on the actual Zig owner.
    let target = try! CapturedRenderTarget.capture(identity: identity, drawable: nil, pass: pass).get()
    pass.colorAttachments[0].texture = nil
    work.target = target
    precondition(target.draw(frame: work.frame, on: work.gpu!))
}
private func targetPipelineDispose(_ context: UnsafeMutableRawPointer?, _ reason: UInt32) {
    precondition(reason == UInt32(CMDY_RENDER_WORKER_EXECUTED))
    Unmanaged<TargetPipelineWork>.fromOpaque(context!).release()
}
private func targetPipelineScope(_ body: CmdyRenderWorkerCallback?, _ context: UnsafeMutableRawPointer?) {
    autoreleasepool { body!(context) }
}

@discardableResult
@MainActor func verifySwiftTargetPipeline(frame: CapturedFrameInput) throws -> [UInt8] {
    let device = MTLCreateSystemDefaultDevice()!
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 96, height: 40, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
    let texture = device.makeTexture(descriptor: descriptor)!
    let identity = frame.withUnsafeNativeInput { $0.pointee.identity }
    let work = TargetPipelineWork(frame: frame, device: device, texture: texture)
    let worker = cmdy_render_worker_create_with_scope(targetPipelineScope)!
    let context = Unmanaged.passRetained(work).toOpaque()
    precondition(cmdy_render_worker_submit(worker, identity.epoch, context, targetPipelineRun, targetPipelineDispose) != 0)
    precondition(work.done.wait(timeout: .now() + 20) == .success)
    precondition(cmdy_render_worker_destroy(worker) != 0 && work.passed)
    print("Swift producer, worker-captured owned target and Zig GPU: full-frame pixels match raw native reference PASS")
    print("Swift worker frame metadata: copied scalars, rejected epoch/surface/zero/nested input, released intermediate and full pixels PASS")
    return work.reference!
}
