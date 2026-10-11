import AppKit
import XCTest
import CmdyNative
@_spi(CmdyApp) @testable import CmdyGPU

@MainActor
final class NativeGraphicsPublicationTests: XCTestCase {
    private func capture(_ producer: ProducerFrameCapture, _ source: any MetalRenderSource,
                         sequence: UInt64 = 1) throws -> CapturedFrameInput {
        try producer.capture(source: source, environment: .init(
            identity: .init(surface: 7, epoch: 2, sequence: sequence),
            drawableSize: CGSize(width: 192, height: 64), config: cmdy_render_schedule_default_config(),
            motion: .init(), preset: .current, liveResize: false, now: 0)).input
    }

    func testViewportProducerNeverReadsIndividualRowsOrLegacyGraphics() throws {
        let source = NativeViewportSource()
        let buffer = try XCTUnwrap(cmdy_zig_buffer_create(8, 2, 0, 0))
        defer { cmdy_zig_buffer_free(buffer) }
        var status: Int32 = 99
        let snapshot = try XCTUnwrap(cmdy_zig_buffer_snapshot_capture(buffer, 0, 2, &status))
        defer { cmdy_zig_buffer_snapshot_release(snapshot) }
        let font = source.normalFont, color = NSColor.white
        let f = UnsafeRawPointer(Unmanaged.passUnretained(font).toOpaque())
        let c = UnsafeRawPointer(Unmanaged.passUnretained(color).toOpaque())
        var styleInput = CmdyShapeStyleInput()
        styleInput.fonts = (f, f, f, f); styleInput.colors = (c, c, c, c, c)
        let nativeStyle = try XCTUnwrap(withExtendedLifetime((font, color)) { cmdy_shape_style_create(&styleInput) })
        defer { cmdy_shape_style_free(nativeStyle) }
        let style = try NativeRowStyle(nativeStyle: nativeStyle)
        source.viewport = NativeFrameViewport(retaining: snapshot, style: style,
            selection: (0, -5, 1, 100))
        let producer = ProducerFrameCapture()
        for sequence in 1...12 {
            source.capturedGrid = false
            let frame = try capture(producer, source, sequence: UInt64(sequence))
            frame.withUnsafeNativeMetadata { XCTAssertEqual($0.pointee.identity.sequence, UInt64(sequence)) }
            XCTAssertEqual(source.rowReads, 0)
            XCTAssertEqual(source.legacyGraphicsReads, 0)
            XCTAssertEqual(producer.cachedRowCount, 0)
            XCTAssertEqual(producer.cachedImageCount, 0)
            XCTAssertEqual(producer.capturedRowCount, 2)
        }
        XCTAssertEqual(source.viewportReads, 12)
    }

    func testProducerSharesNativePayloadAndPreservesLegacyFrameGraphics() throws {
        let source = FrozenGraphicsSource()
        let store = try XCTUnwrap(cmdy_zig_graphics_create())
        defer { cmdy_zig_graphics_free(store) }
        let payload = try XCTUnwrap(source.bytes.withUnsafeBufferPointer {
            cmdy_zig_payload_create_host(0, $0.baseAddress, $0.count, 1, 1, nil, nil)
        })
        defer { cmdy_zig_payload_release(payload) }
        let image = try XCTUnwrap(cmdy_zig_stored_image_create(payload, 91, 0, 0, 1, 1))
        defer { cmdy_zig_stored_image_release(image) }
        XCTAssertEqual(cmdy_zig_graphics_store(store, image), 1)
        for alternate in [UInt8(0), UInt8(1)] {
            var placement = CmdyZigPlacement()
            placement.image_id = 91; placement.placement_id = alternate == 0 ? 71 : 72
            placement.cols = 4; placement.rows = 5; placement.offset_x = -2; placement.offset_y = 7
            placement.is_virtual = 1; placement.is_alternate_buffer = alternate
            XCTAssertEqual(cmdy_zig_graphics_place(store, &placement), 1)
        }
        var status: UInt32 = 99
        let native = try XCTUnwrap(cmdy_render_graphics_input_capture(store, &status))
        XCTAssertEqual(status, 0)
        source.graphics = NativeFrameGraphics(retaining: native)
        cmdy_render_graphics_input_release(native)
        var bytes = CmdyZigPayloadInfo()
        XCTAssertEqual(cmdy_zig_payload_info(payload, &bytes), 0)
        let legacy = GraphicsSource(), producer = ProducerFrameCapture()
        for alternate in [false, true] {
            source.alternate = alternate; legacy.alternate = alternate
            let actual = try capture(producer, source, sequence: alternate ? 2 : 1)
            let expected = try capture(ProducerFrameCapture(), legacy)
            actual.withUnsafeNativeInput { actual in
                expected.withUnsafeNativeInput { expected in
                    let a = actual.pointee.parameters, e = expected.pointee.parameters
                    XCTAssertEqual(a.kitty_image_count, e.kitty_image_count)
                    XCTAssertEqual(a.kitty_images[0].bytes, bytes.bytes)
                    XCTAssertEqual(a.kitty_images[0].kind, e.kitty_images[0].kind)
                    XCTAssertEqual(a.kitty_images[0].width, e.kitty_images[0].width)
                    XCTAssertEqual(a.kitty_images[0].height, e.kitty_images[0].height)
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: a.kitty_images[0].bytes, count: a.kitty_images[0].byte_count)), source.bytes)
                    XCTAssertEqual(a.kitty_placement_count, e.kitty_placement_count)
                    XCTAssertEqual(a.kitty_placements[0].placement_id, e.kitty_placements[0].placement_id)
                    XCTAssertEqual(a.kitty_placements[0].offset_x, e.kitty_placements[0].offset_x)
                    XCTAssertEqual(a.kitty_placements[0].offset_y, e.kitty_placements[0].offset_y)
                    XCTAssertEqual(a.live_kitty_count, e.live_kitty_count)
                    XCTAssertEqual(a.live_kitty_ids[0], 91)
                }
            }
        }
        let retained = try capture(producer, source, sequence: 3)
        source.graphics = nil
        cmdy_zig_graphics_delete_all(store)
        producer.invalidate()
        retained.withUnsafeNativeInput {
            XCTAssertEqual($0.pointee.parameters.kitty_images[0].bytes, bytes.bytes)
            XCTAssertEqual($0.pointee.parameters.kitty_placements[0].placement_id, 72)
        }
        let empty = try capture(producer, source, sequence: 4)
        empty.withUnsafeNativeInput {
            XCTAssertEqual($0.pointee.parameters.kitty_image_count, 0)
            XCTAssertEqual($0.pointee.parameters.kitty_placement_count, 0)
            XCTAssertEqual($0.pointee.parameters.live_kitty_count, 0)
        }
        XCTAssertEqual(source.legacyGraphicsReads, 0)
        XCTAssertGreaterThan(legacy.legacyGraphicsReads, 0)
    }
}

@MainActor
private final class NativeViewportSource: GraphicsSource, NativeViewportRenderSource {
    var viewport: NativeFrameViewport!
    var capturedGrid = false
    var rowReads = 0, viewportReads = 0
    override func captureGrid() -> GridSnapshot { capturedGrid = true; return super.captureGrid() }
    override func lineInfo(forRow row: Int) -> ViewLineInfo { rowReads += 1; return super.lineInfo(forRow: row) }
    override func lineRenderMode(forRow row: Int) -> RenderLineMode { rowReads += 1; return super.lineRenderMode(forRow: row) }
    override func lineVersion(forRow row: Int) -> UInt64 { rowReads += 1; return super.lineVersion(forRow: row) }
    func nativeFrameGraphics() -> NativeFrameGraphics? { XCTAssertTrue(capturedGrid); return nil }
    func nativeFrameViewport() throws -> NativeFrameViewport {
        XCTAssertTrue(capturedGrid); viewportReads += 1; return viewport
    }
}

@MainActor
private final class FrozenGraphicsSource: GraphicsSource, NativeGraphicsRenderSource {
    var graphics: NativeFrameGraphics?
    func nativeFrameGraphics() -> NativeFrameGraphics? { graphics }
}

@MainActor
private class GraphicsSource: MetalRenderSource {
    let bytes: [UInt8] = [12, 34, 56, 255]
    var alternate = false
    var legacyGraphicsReads = 0
    func captureGrid() -> GridSnapshot {
        GridSnapshot(rows: 2, cols: 8, bufferLineCount: 2, displayTopRow: 0, liveTopRow: 0,
            cursorRow: 0, cursorCol: 0, cursorHidden: true, cursorStyle: .steadyBlock, isAlternateBuffer: alternate)
    }
    func lineInfo(forRow row: Int) -> ViewLineInfo { ViewLineInfo(segments: [], images: nil) }
    func lineRenderMode(forRow row: Int) -> RenderLineMode { .single }
    func lineVersion(forRow row: Int) -> UInt64 { 1 }
    func cursorCellAttributedString() -> NSAttributedString? { nil }
    var kittyStamp: KittyCacheStamp { .init(imagesCount: 1, placementsCount: 2, nextImageId: 92, nextPlacementId: 73) }
    func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec] {
        legacyGraphicsReads += 1
        return [.init(imageId: 91, placementId: alternateBuffer ? 72 : 71, cols: 4, rows: 5, pixelOffsetX: -2, pixelOffsetY: 7)]
    }
    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? {
        legacyGraphicsReads += 1
        return .rgba(bytes: bytes, width: 1, height: 1)
    }
    var kittyLiveImageIds: Set<UInt32> { legacyGraphicsReads += 1; return [91] }
    var viewBounds: CGRect { CGRect(x: 0, y: 0, width: 96, height: 32) }
    func backingScaleFactor() -> CGFloat { 2 }
    var cellSize: CGSize { CGSize(width: 12, height: 16) }
    var normalFont: NSFont { NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) }
    func underlinePosition() -> CGFloat { -2 }
    func underlineThickness() -> CGFloat { 1 }
    var contentXOrigin: CGFloat { 0 }
    var topContentInset: CGFloat { 0 }
    var bottomContentInset: CGFloat { 0 }
    var leftContentInset: CGFloat { 0 }
    var scrollContentOffset: CGPoint { .zero }
    func getImageScale() -> CGFloat { 1 }
    var nativeForegroundColor: NSColor { .white }
    var nativeBackgroundColor: NSColor { .black }
    var caretColor: NSColor { .white }
    var caretTextColor: NSColor? { .black }
    var caretFocused: Bool { false }
    var antiAliasCustomBlockGlyphs: Bool { true }
    var metalBufferingMode: MetalBufferingMode { .perRowPersistent }
    func consumeDirtyRows() -> ClosedRange<Int>? { nil }
    var activityKeypressTime: Double { 0 }
    var activityTypingRate: Float { 0 }
}
