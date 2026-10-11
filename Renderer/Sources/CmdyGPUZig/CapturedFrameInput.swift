import CmdyNative

/// The normal app publishes one frozen viewport after captureGrid. No per-row
/// source callbacks are used; text, images and placement are prepared by Zig.
@_spi(CmdyApp) @MainActor
public protocol NativeViewportRenderSource: NativeGraphicsRenderSource {
    func nativeFrameViewport() throws -> NativeFrameViewport
}

@_spi(CmdyApp)
public final class NativeFrameViewport: @unchecked Sendable {
    let snapshot: OpaquePointer
    let style: NativeRowStyle
    let modelGeneration: UInt64
    let selection: (startRow: Int, startCol: Int, endRow: Int, endCol: Int)?
    public init(retaining snapshot: OpaquePointer, style: NativeRowStyle,
                selection: (startRow: Int, startCol: Int, endRow: Int, endCol: Int)?, modelGeneration: UInt64 = 0) {
        self.snapshot = cmdy_zig_buffer_snapshot_retain(snapshot)!
        self.style = style
        self.selection = selection
        self.modelGeneration = modelGeneration
    }
    deinit { cmdy_zig_buffer_snapshot_release(snapshot) }
}

/// Optional renderer source path for model-owned immutable graphics. The grid
/// capture establishes which coherent snapshot this method must return.
@_spi(CmdyApp) @MainActor
public protocol NativeGraphicsRenderSource: MetalRenderSource {
    func nativeFrameGraphics() -> NativeFrameGraphics?
}

/// One atomic native owner; no payload projection, source or UI object retained.
@_spi(CmdyApp)
public final class NativeFrameGraphics: @unchecked Sendable {
    let handle: OpaquePointer
    public init(retaining handle: OpaquePointer) {
        self.handle = cmdy_render_graphics_input_retain(handle)!
    }
    deinit { cmdy_render_graphics_input_release(handle) }
    func isEmpty(alternate: Bool) -> Bool {
        withExtendedLifetime(self) {
            let view = cmdy_render_graphics_input_view(handle, alternate ? 1 : 0)!.pointee
            return view.image_count == 0 && view.placement_count == 0 && view.live_count == 0
        }
    }
}

enum FrameInputCaptureFailure: Error {
    case invalidInput
    case outOfMemory

    fileprivate init(status: UInt32) {
        self = status == UInt32(CMDY_RENDER_INPUT_OUT_OF_MEMORY) ? .outOfMemory : .invalidInput
    }
}

/// Only the immutable, byte-owning native image handle crosses threads.
/// It contains no NSImage or callbacks to a host image object.
final class CapturedImageInput: @unchecked Sendable {
    private let handle: OpaquePointer
    private init(handle: OpaquePointer) { self.handle = handle }
    deinit { cmdy_render_image_input_release(handle) }

    @MainActor
    static func capture(_ input: UnsafePointer<CmdyRenderImageInput>) -> Result<CapturedImageInput, FrameInputCaptureFailure> {
        var status: UInt32 = 0
        guard let value = cmdy_render_image_input_capture(input, &status) else { return .failure(.init(status: status)) }
        return .success(CapturedImageInput(handle: value))
    }

    /// The borrowed handle must not escape; native frame capture retains it.
    func withUnsafeNativeHandle<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try body(handle) }
    }

    func withUnsafeNativeInput<T>(_ body: (UnsafePointer<CmdyRenderImageInput>) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try body(cmdy_render_image_input_view(handle)!) }
    }
}

/// A reusable row description with native ownership of its nested values.
/// Each frame retains this handle and supplies its own immutable placement.
final class CapturedFrameRowInput: @unchecked Sendable {
    private let handle: OpaquePointer
    private init(handle: OpaquePointer) { self.handle = handle }
    deinit { cmdy_render_frame_row_release(handle) }

    @MainActor
    static func capture(_ input: UnsafePointer<CmdyRenderFrameRowInput>) -> Result<CapturedFrameRowInput, FrameInputCaptureFailure> {
        var status: UInt32 = 0
        guard let value = cmdy_render_frame_row_capture(input, &status) else { return .failure(.init(status: status)) }
        return .success(CapturedFrameRowInput(handle: value))
    }

    func withUnsafeNativeHandle<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try body(handle) }
    }
}

/// Native storage owns all nested frame content and uses atomic references.
/// It has no GPU targets, mutable caches, or host/source objects.
final class CapturedFrameInput: @unchecked Sendable {
    private let handle: OpaquePointer
    private init(handle: OpaquePointer) { self.handle = handle }
    deinit { cmdy_render_frame_input_release(handle) }

    @MainActor
    static func capture(_ input: UnsafePointer<CmdyRenderFrameInput>, viewport: NativeFrameViewport,
                        key: IndependentRowKey, fringeRows: Int, parameters: NativeRowCaptureParameters,
                        graphics: NativeFrameGraphics?) throws -> CapturedFrameInput {
        try parameters.withFrozenHandle { raster in
            try key.withGPUKey { keyPointer in
                Result { try withExtendedLifetime((viewport, graphics)) {
                    var packet = CmdyRenderViewportInput()
                    packet.snapshot = viewport.snapshot; packet.style = viewport.style.handle; packet.raster = raster
                    packet.key = keyPointer.pointee; packet.font_name_bytes = key.fontName.utf8.count
                    packet.fringe_rows = fringeRows
                    packet.model_generation = viewport.modelGeneration
                    if let selection = viewport.selection {
                        packet.has_selection = 1
                        packet.selection_start_row = selection.startRow; packet.selection_start_col = selection.startCol
                        packet.selection_end_row = selection.endRow; packet.selection_end_col = selection.endCol
                    }
                    var status: UInt32 = 0
                    guard let handle = cmdy_render_frame_input_capture_viewport(input, &packet, graphics?.handle, &status) else {
                        throw FrameInputCaptureFailure(status: status)
                    }
                    return CapturedFrameInput(handle: handle)
                } }
            }.get()
        }
    }

    @MainActor
    static func capture(_ input: UnsafePointer<CmdyRenderFrameInput>) -> Result<CapturedFrameInput, FrameInputCaptureFailure> {
        var status: UInt32 = 0
        guard let value = cmdy_render_frame_input_capture(input, &status) else { return .failure(.init(status: status)) }
        return .success(CapturedFrameInput(handle: value))
    }

    @MainActor
    static func capture(_ input: UnsafePointer<CmdyRenderFrameInput>,
                        references: UnsafeBufferPointer<CmdyRenderFrameRowReference>,
                        graphics: NativeFrameGraphics? = nil) -> Result<CapturedFrameInput, FrameInputCaptureFailure> {
        var status: UInt32 = 0
        let value = withExtendedLifetime(graphics) {
            if let graphics {
                return cmdy_render_frame_input_capture_referenced_graphics(input, references.baseAddress,
                    references.count, graphics.handle, &status)
            }
            return cmdy_render_frame_input_capture_referenced(input, references.baseAddress, references.count, &status)
        }
        guard let value else {
            return .failure(.init(status: status))
        }
        return .success(CapturedFrameInput(handle: value))
    }

    /// Scalar metadata is immutable from capture onward and never assembles rows.
    func withUnsafeNativeMetadata<T>(_ body: (UnsafePointer<CmdyRenderFrameInput>) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try body(cmdy_render_frame_input_metadata(handle)!) }
    }

    /// The caller has verified unchanged nested content and placements.
    /// Only scalar metadata is borrowed for this call. The caller exclusively
    /// owns that metadata until this returns; native storage copies it and
    /// atomically retains the immutable content owner. No host object is read.
    func reusingContent(_ input: UnsafePointer<CmdyRenderFrameInput>) -> Result<CapturedFrameInput, FrameInputCaptureFailure> {
        var status: UInt32 = 0
        return withUnsafeNativeHandle { previous in
            guard let value = cmdy_render_frame_input_reuse(previous, input, &status) else {
                return .failure(.init(status: status))
            }
            return .success(CapturedFrameInput(handle: value))
        }
    }

    /// Native rendering borrows the immutable packet for this call and retains
    /// any text/image inputs that its caches or asynchronous work still need.
    func withUnsafeNativeHandle<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try body(handle) }
    }

    /// Full view access assembles row descriptions once without allocation.
    /// Production admission uses metadata; the native draw worker requests rows.
    /// Pointers must not outlive this closure. Worker identity fences still apply.
    func withUnsafeNativeInput<T>(_ body: (UnsafePointer<CmdyRenderFrameInput>) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try body(cmdy_render_frame_input_view(handle)!) }
    }
}
