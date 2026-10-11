import AppKit
import CmdyNative

enum RowInputCaptureFailure: Error {
    case invalidInput
    case unsupportedAttributes
    case outOfMemory

    init(status: UInt32) {
        switch status {
        case UInt32(CMDY_RENDER_INPUT_UNSUPPORTED_ATTRIBUTES): self = .unsupportedAttributes
        case UInt32(CMDY_RENDER_INPUT_OUT_OF_MEMORY): self = .outOfMemory
        default: self = .invalidInput
        }
    }
}

/// An optional native snapshot path. Returning nil uses the general source
/// contract; errors invalidate the capture instead of dropping row content.
@_spi(CmdyApp) @MainActor
public protocol DeferredRowRenderSource: MetalRenderSource {
    func deferredRenderRow(forRow row: Int, parameters: NativeRowCaptureParameters) throws -> DeferredRenderRow?
}

/// Scalar raster settings plus owned platform values. Freeze only if the source
/// actually constructs a deferred row; returning nil keeps the general path.
@_spi(CmdyApp) @MainActor
public struct NativeRowCaptureParameters {
    fileprivate let source: RowParameterCapture

    func withFrozenHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let frozen = try source.freeze()
        return try withExtendedLifetime(frozen) { try body(frozen.handle) }
    }

    init(cols: Int, width: Int, height: Int, cellWidth: CGFloat, cellHeight: CGFloat,
         scale: CGFloat, font: NSFont, foreground: NSColor, underline: CGFloat,
         thickness: CGFloat, preset: TextRenderingMode, antialias: Bool) {
        let input = CmdyRenderRowInput(segments: nil, segment_count: 0,
            blocks: nil, block_count: 0, boxes: nil, box_count: 0,
            cols: cols, width: width, height: height, cell_width: cellWidth,
            cell_height: cellHeight, scale: scale, underline_position: underline,
            underline_thickness: thickness, normal_font: Unmanaged.passUnretained(font).toOpaque(),
            foreground: Unmanaged.passUnretained(foreground).toOpaque(),
            coverage_exponent: preset.coverageExponent, snaps_y: preset.snapsY ? 1 : 0,
            antialias_blocks: antialias ? 1 : 0, ascii_caching: 1, font_caching: 1)
        source = RowParameterCapture(input: input, font: font, foreground: foreground)
    }
}

@MainActor
fileprivate final class RowParameterCapture {
    private let input: CmdyRenderRowInput
    private let font: NSFont
    private let foreground: NSColor
    private var captured: CapturedRowParameters?
    init(input: CmdyRenderRowInput, font: NSFont, foreground: NSColor) {
        self.input = input; self.font = font; self.foreground = foreground
    }
    func freeze() throws -> CapturedRowParameters {
        if let captured { return captured }
        let value = try withExtendedLifetime((font, foreground)) {
            var input = self.input
            return try CapturedRowParameters(input: &input)
        }
        captured = value
        return value
    }
}

/// The native packet resolves UI values once and owns atomic, immutable storage.
/// Rows share it without retaining a Swift/AppKit source or resolving colors.
fileprivate final class CapturedRowParameters: @unchecked Sendable {
    let handle: OpaquePointer
    @MainActor init(input: UnsafePointer<CmdyRenderRowInput>) throws {
        var status: UInt32 = 0
        guard let handle = cmdy_render_row_parameters_capture(input, &status) else {
            throw RowInputCaptureFailure(status: status)
        }
        self.handle = handle
    }
    deinit { cmdy_render_row_parameters_release(handle) }
}

/// A private, resolved native style with atomic references. Capturing under the
/// host appearance never transfers the UI style's non-atomic reference count.
@_spi(CmdyApp)
public final class NativeRowStyle: @unchecked Sendable {
    let handle: OpaquePointer
    @MainActor public init(nativeStyle: OpaquePointer) throws {
        var status: UInt32 = 0
        guard let handle = cmdy_render_row_style_capture(nativeStyle, &status) else {
            throw RowInputCaptureFailure(status: status)
        }
        self.handle = handle
    }
    deinit { cmdy_render_row_style_release(handle) }
}

@_spi(CmdyApp) @MainActor
public struct DeferredRenderRow {
    let text: CapturedRowInput
    let images: [any RenderableCellImage]
    var revisionReusable: Bool { images.isEmpty && text.revisionReusable }

    /// The native line is borrowed only for this call. Zig freezes its COW row
    /// and retains the resolved style; the render owner prepares text later.
    public init(nativeLine: UnsafeRawPointer, sourceRow: Int, style: NativeRowStyle,
                parameters: NativeRowCaptureParameters, images: [any RenderableCellImage]) throws {
        let frozen = try parameters.source.freeze()
        var status: UInt32 = 0
        let handle = withExtendedLifetime((style, frozen)) {
            cmdy_render_input_capture_frozen(OpaquePointer(nativeLine), sourceRow,
                style.handle, frozen.handle, &status)
        }
        guard let handle else { throw RowInputCaptureFailure(status: status) }
        text = CapturedRowInput(handle: handle)
        self.images = images
    }
}

/// The native object owns immutable nested buffers and resolved text attributes.
/// Its references are atomic. Swift only holds and lends that immutable handle;
/// no AppKit object or source callback is accessed through this wrapper.
final class CapturedRowInput: @unchecked Sendable {
    private let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) { self.handle = handle }
    deinit { cmdy_render_input_release(handle) }

    /// Conservative until worker preparation publishes the immutable result.
    /// The native query only reads an atomic publication; it never scans cells.
    var revisionReusable: Bool {
        withExtendedLifetime(self) { cmdy_render_input_revision_reusable(handle) != 0 }
    }

    @MainActor
    static func capture(_ input: UnsafePointer<CmdyRenderRowInput>) -> Result<CapturedRowInput, RowInputCaptureFailure> {
        var status: UInt32 = 0
        guard let handle = cmdy_render_input_capture(input, &status) else {
            switch status {
            case UInt32(CMDY_RENDER_INPUT_UNSUPPORTED_ATTRIBUTES): return .failure(.unsupportedAttributes)
            case UInt32(CMDY_RENDER_INPUT_OUT_OF_MEMORY): return .failure(.outOfMemory)
            default: return .failure(.invalidInput)
            }
        }
        return .success(CapturedRowInput(handle: handle))
    }

    /// The immutable view and its nested pointers must not escape this closure.
    func withUnsafeNativeInput<T>(_ body: (UnsafePointer<CmdyRenderRowInput>) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) {
            guard let view = cmdy_render_input_view(handle) else {
                preconditionFailure("Deferred row input must be prepared on the rendering owner")
            }
            return try body(view)
        }
    }

    /// The borrowed handle must not escape; native frame capture retains it.
    func withUnsafeNativeHandle<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try body(handle) }
    }
}
