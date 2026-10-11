import AppKit
import CmdyNative
import XCTest
@_spi(CmdyApp) @testable import CmdyGPU

final class DeferredRowRevisionTests: XCTestCase {
    @MainActor
    func testPreparedEligibilityEnablesDirtyRowAndPublicationReuse() async throws {
        let source = try DeferredRevisionSource(scalar: 0x41)
        let producer = ProducerFrameCapture()
        let first = try capture(producer, source, sequence: 1)
        let text = try XCTUnwrap(source.lastRow).text
        XCTAssertFalse(text.revisionReusable)
        await prepare(text)
        XCTAssertTrue(text.revisionReusable)

        source.dirty = 0...0
        let second = try capture(producer, source, sequence: 2)
        XCTAssertEqual(source.deferredCalls, 1, "The host must read newly published eligibility")
        let versionReads = source.versionReads
        let third = try capture(producer, source, sequence: 3)
        XCTAssertEqual(source.versionReads, versionReads, "A prepared unchanged publication skips row traversal")
        XCTAssertEqual(source.deferredCalls, 1)

        source.replace(scalar: 0x5A)
        let changed = try capture(producer, source, sequence: 4)
        XCTAssertEqual(source.deferredCalls, 2, "Eligibility cannot bypass changed content")
        XCTAssertFalse(try XCTUnwrap(source.lastRow).revisionReusable)
        XCTAssertTrue(text.revisionReusable, "The previous prepared publication remains immutable")
        withExtendedLifetime((first, second, third, changed)) {}
    }

    @MainActor
    func testProceduralRowsKeepDirtyCaptureAfterWorkerPreparation() async throws {
        for scalar: UInt32 in [0x2500, 0x2588, 0x10EEEE] {
            let source = try DeferredRevisionSource(scalar: scalar)
            let producer = ProducerFrameCapture()
            let first = try capture(producer, source, sequence: 1)
            let text = try XCTUnwrap(source.lastRow).text
            XCTAssertFalse(text.revisionReusable)
            await prepare(text)
            XCTAssertFalse(text.revisionReusable)
            source.dirty = 0...0
            let second = try capture(producer, source, sequence: 2)
            XCTAssertEqual(source.deferredCalls, 2, "Procedural rows retain the existing conservative capture path")
            withExtendedLifetime((first, second)) {}
        }
    }

    @MainActor
    private func capture(_ producer: ProducerFrameCapture, _ source: DeferredRevisionSource,
                         sequence: UInt64) throws -> ProducedFrame {
        try producer.capture(source: source, environment: ProducerFrameEnvironment(
            identity: .init(surface: 1, epoch: 1, sequence: sequence),
            drawableSize: CGSize(width: 96, height: 20),
            config: cmdy_render_schedule_default_config(), motion: .init(), preset: .current,
            liveResize: false, now: 1))
    }

    private func prepare(_ text: CapturedRowInput) async {
        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            text.withUnsafeNativeHandle { handle in
                var status: UInt32 = 999
                XCTAssertNotNil(cmdy_render_input_prepare(handle, &status))
                XCTAssertEqual(status, UInt32(CMDY_RENDER_INPUT_OK))
            }
        }.value
    }
}

@MainActor
private final class DeferredRevisionSource: DeferredRowRenderSource, SnapshotRowRevisionSource,
    PublishedFrameRenderSource {
    private let line: OpaquePointer
    private let style: NativeRowStyle
    let normalFont: NSFont
    var dirty: ClosedRange<Int>? = 0...0
    var frameContentRevision: UInt64 = 1
    private(set) var deferredCalls = 0
    private(set) var versionReads = 0
    private(set) var lastRow: DeferredRenderRow?

    init(scalar: UInt32) throws {
        let nativeFont = try XCTUnwrap(NSFont(name: "Menlo", size: 14))
        normalFont = nativeFont
        let font = UnsafeRawPointer(Unmanaged.passUnretained(nativeFont).toOpaque())
        let white = UnsafeRawPointer(Unmanaged.passUnretained(NSColor.white).toOpaque())
        let black = UnsafeRawPointer(Unmanaged.passUnretained(NSColor.black).toOpaque())
        var input = CmdyShapeStyleInput()
        input.fonts = (font, font, font, font)
        input.colors = (white, black, black, white, black)
        let raw = try XCTUnwrap(cmdy_shape_style_create(&input))
        defer { cmdy_shape_style_free(raw) }
        style = try NativeRowStyle(nativeStyle: raw)
        var cell = CmdyZigCell()
        cell.width = 1; cell.scalar = scalar
        line = try XCTUnwrap(cmdy_zig_line_create(8, &cell, nil, 0, 0))
    }
    deinit { cmdy_zig_line_release(line) }

    func replace(scalar: UInt32) {
        var cell = CmdyZigCell()
        cell.scalar = scalar; cell.width = 1
        XCTAssertEqual(cmdy_zig_line_set(line, 0, &cell, nil, 0, 0), 0)
        frameContentRevision += 1; dirty = 0...0
    }
    func captureGrid() -> GridSnapshot {
        GridSnapshot(rows: 1, cols: 8, bufferLineCount: 1, displayTopRow: 0, liveTopRow: 0,
            cursorRow: 0, cursorCol: 0, cursorHidden: true, cursorStyle: .steadyBlock,
            isAlternateBuffer: false)
    }
    func deferredRenderRow(forRow row: Int, parameters: NativeRowCaptureParameters) throws -> DeferredRenderRow? {
        XCTAssertEqual(row, 0)
        deferredCalls += 1
        let captured = try DeferredRenderRow(nativeLine: UnsafeRawPointer(line), sourceRow: row,
            style: style, parameters: parameters, images: [])
        lastRow = captured
        return captured
    }
    func snapshotRowRevision(forRow row: Int) -> SnapshotRowRevision? {
        SnapshotRowRevision(content: cmdy_zig_line_version(line), context: 1)
    }
    func lineVersion(forRow row: Int) -> UInt64 {
        versionReads += 1
        return cmdy_zig_line_version(line)
    }
    func lineInfo(forRow row: Int) -> ViewLineInfo {
        XCTFail("The actual deferred source must be used")
        return ViewLineInfo(segments: [], images: nil)
    }
    func consumeDirtyRows() -> ClosedRange<Int>? { defer { dirty = nil }; return dirty }
    func lineRenderMode(forRow row: Int) -> RenderLineMode { .single }
    func cursorCellAttributedString() -> NSAttributedString? { nil }
    var kittyStamp: KittyCacheStamp { .init(imagesCount: 0, placementsCount: 0, nextImageId: 0, nextPlacementId: 0) }
    func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec] { [] }
    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? { nil }
    var kittyLiveImageIds: Set<UInt32> { [] }
    var viewBounds: CGRect { CGRect(x: 0, y: 0, width: 96, height: 20) }
    func backingScaleFactor() -> CGFloat { 1 }
    var cellSize: CGSize { CGSize(width: 12, height: 20) }
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
    var activityKeypressTime: Double { 0 }
    var activityTypingRate: Float { 0 }
}
