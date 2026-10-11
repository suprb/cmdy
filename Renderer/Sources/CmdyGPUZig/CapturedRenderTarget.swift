import CmdyNative
import Metal
import QuartzCore

/// Native storage owns the descriptor copy and Metal resources. Its atomic
/// claim permits a single encoding attempt, so the descriptor has one worker.
final class CapturedRenderTarget: @unchecked Sendable {
    private let handle: OpaquePointer
    private init(handle: OpaquePointer) { self.handle = handle }
    deinit { cmdy_render_target_release(handle) }

    func withUnsafeNativeHandle<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try body(handle) }
    }

    // The caller exclusively owns the pass during this synchronous copy.
    // A worker may create its own pass; no MTKView or AppKit state is read.
    static func capture(identity: CmdyRenderFrameIdentity, drawable: (any CAMetalDrawable)?,
                        pass: MTLRenderPassDescriptor) -> Result<CapturedRenderTarget, FrameInputCaptureFailure> {
        var status: UInt32 = 0
        let value = withExtendedLifetime((drawable, pass)) {
            cmdy_render_target_capture(identity,
                drawable.map { UnsafeRawPointer(Unmanaged.passUnretained($0 as AnyObject).toOpaque()) },
                UnsafeRawPointer(Unmanaged.passUnretained(pass).toOpaque()), &status)
        }
        guard let value else {
            return .failure(status == UInt32(CMDY_RENDER_INPUT_OUT_OF_MEMORY) ? .outOfMemory : .invalidInput)
        }
        return .success(CapturedRenderTarget(handle: value))
    }

    /// Call on the native GPU owner. Rejected/aborted attempts require a newly
    /// captured target for retry. Frame storage may be reused for animation.
    func draw(frame: CapturedFrameInput, on gpu: OpaquePointer) -> Bool {
        withExtendedLifetime(self) {
            frame.withUnsafeNativeHandle { cmdy_gpu_draw_target(gpu, $0, handle) != 0 }
        }
    }
}
