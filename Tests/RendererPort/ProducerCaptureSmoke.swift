import AppKit
import CmdyNative
import Foundation

@MainActor private final class EncodedImage: @preconcurrency RenderableCellImage, EncodedRenderableCellImage {
    var renderIdentity = UUID()
    var payload: KittyImagePayload = .rgba(bytes: [10, 20, 30, 128], width: 1, height: 1)
    var payloadReads = 0
    var encodedPayload: KittyImagePayload { payloadReads += 1; return payload }
    var image: NSImage { preconditionFailure("Capture must not decode an NSImage") }
    var pixelWidth = 1, pixelHeight = 1, col = 4
    var kittyIsKitty = false
    var kittyImageId: UInt32? = nil
    var kittyZIndex = 3, kittyPixelOffsetX = 2, kittyPixelOffsetY = 1
}
private final class UnsupportedImage: RenderableCellImage {
    var image: NSImage { preconditionFailure("Unsupported images must be reported without decoding") }
    var pixelWidth = 1, pixelHeight = 1, col = 0
    var kittyIsKitty = false
    var kittyImageId: UInt32? = nil
    var kittyZIndex = 0, kittyPixelOffsetX = 0, kittyPixelOffsetY = 0
}

@MainActor private class Source: MetalRenderSource, SnapshotRowRevisionSource, MetalSelectionRenderSource, DeferredRowRenderSource {
    var normalFont = NSFont(name: "Menlo", size: 14)!
    var foreground: NSColor = .white, background: NSColor = .black
    lazy var text = NSMutableAttributedString(string: "Aé𝄞", attributes: [.font: normalFont, .foregroundColor: NSColor.white])
    var top = 100, rowCount = 2
    var bufferLines = 2000, cursorColumn = 2
    var keypressTime: Double = 3
    var typingRate: Float = 4
    var versions: [Int: UInt64] = [:]
    var context: UInt64 = 7
    var dirty: ClosedRange<Int>? = nil
    var selected: ClosedRange<Int>? = 1...2
    var selections: [Int: ClosedRange<Int>] = [:]
    var rowText: [Int: NSAttributedString] = [:]
    var onSelection: ((Int) -> Void)?
    var attached: (any RenderableCellImage)?
    var lineReads = 0, snapshots = 0, revisionReads = 0
    var modeReads = 0, versionReads = 0, selectionReads = 0, kittyReads = 0
    var scale: CGFloat = 1
    var onActivityRead: (() -> Void)?
    var contentReads: Int { lineReads + revisionReads + modeReads + versionReads + selectionReads + kittyReads + nativeReads }
    var onLine: (() -> Void)?
    var onCapture: (() -> Void)?
    var nativeRow: ((Int, NativeRowCaptureParameters) throws -> DeferredRenderRow?)?
    var nativeReads = 0
    func deferredRenderRow(forRow row: Int, parameters: NativeRowCaptureParameters) throws -> DeferredRenderRow? {
        precondition(gridCaptured)
        guard let nativeRow else { return nil }
        nativeReads += 1
        return try nativeRow(row, parameters)
    }
    var underline: CGFloat = 2
    var gridCaptured = false
    var kittyPayloads: [UInt32: KittyImagePayload] = [:]
    func captureGrid() -> GridSnapshot {
        gridCaptured = true; snapshots += 1; onCapture?()
        return GridSnapshot(rows: rowCount, cols: 8, bufferLineCount: bufferLines, retainedRowOrigin: 100,
            displayTopRow: top, liveTopRow: 110, cursorRow: top + 1, cursorCol: cursorColumn,
            cursorHidden: false, cursorStyle: .steadyBlock, isAlternateBuffer: false)
    }
    func info(_ row: Int) -> ViewLineInfo {
        ViewLineInfo(segments: [ViewLineSegment(column: 0, columnWidth: 1, characterCount: 3,
            attributedString: rowText[row] ?? text, cellUTF16Boundaries: [0, 1, 2, 4])], images: row == top ? attached.map { [$0] } : nil)
    }
    func lineInfo(forRow row: Int) -> ViewLineInfo { precondition(gridCaptured); lineReads += 1; onLine?(); return info(row) }
    func lineRenderMode(forRow row: Int) -> RenderLineMode { modeReads += 1; return .single }
    func lineVersion(forRow row: Int) -> UInt64 { versionReads += 1; return versions[row] ?? 1 }
    func snapshotRowRevision(forRow row: Int) -> SnapshotRowRevision? {
        revisionReads += 1
        // Match CmdySnapshotRowContext: image-bearing rows (and any Kitty
        // frame) must not advertise the text-only fast reuse token.
        guard (row != top || attached == nil) && kittyPayloads.isEmpty else { return nil }
        return .init(content: lineVersion(forRow: row), context: context)
    }
    func cursorCellAttributedString() -> NSAttributedString? { nil }
    var kittyStamp: KittyCacheStamp { kittyReads += 1; return .init(imagesCount: kittyPayloads.count, placementsCount: kittyPayloads.count, nextImageId: 0, nextPlacementId: 0) }
    func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec] {
        kittyReads += 1
        return kittyPayloads.keys.map { .init(imageId: $0, placementId: 9, cols: 2, rows: 3, pixelOffsetX: 4, pixelOffsetY: 5) }
    }
    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? { kittyPayloads[imageId] }
    var kittyLiveImageIds: Set<UInt32> { kittyReads += 1; return Set(kittyPayloads.keys) }
    var viewBounds: CGRect { .init(x: 0, y: 0, width: 96, height: 40) }
    func backingScaleFactor() -> CGFloat { precondition(gridCaptured); return scale }
    var cellSize: CGSize { .init(width: 12, height: 20) }
    func underlinePosition() -> CGFloat { underline }
    func underlineThickness() -> CGFloat { 1 }
    var contentXOrigin: CGFloat { 0 }
    var topContentInset: CGFloat { 0 }
    var bottomContentInset: CGFloat { 0 }
    var leftContentInset: CGFloat { 0 }
    var scrollContentOffset: CGPoint { .zero }
    func getImageScale() -> CGFloat { 1 }
    var nativeForegroundColor: NSColor { foreground }
    var nativeBackgroundColor: NSColor { background }
    var caretColor: NSColor { .green }
    var caretTextColor: NSColor? { .black }
    var caretFocused: Bool { true }
    var antiAliasCustomBlockGlyphs: Bool { true }
    var metalBufferingMode: MetalBufferingMode { .perRowPersistent }
    func consumeDirtyRows() -> ClosedRange<Int>? { let result = dirty; dirty = nil; return result }
    var activityKeypressTime: Double { onActivityRead?(); return keypressTime }
    var activityTypingRate: Float { typingRate }
    var selectionBackgroundColor: NSColor { .red }
    func selectionColumns(forRow row: Int) -> ClosedRange<Int>? {
        selectionReads += 1
        onSelection?(row)
        return selections[row] ?? selected
    }
}

@MainActor private final class PublishedSource: Source, PublishedFrameRenderSource {
    var publication: UInt64 = 1
    var publicationReads = 0
    var onPublicationRead: ((Int) -> Void)?
    var frameContentRevision: UInt64 {
        precondition(gridCaptured)
        publicationReads += 1
        onPublicationRead?(publicationReads)
        return publication
    }
}

private func textHandle(_ frame: ProducedFrame) -> UInt {
    frame.input.withUnsafeNativeInput { UInt(bitPattern: $0.pointee.rows![0].text!) }
}
private func rowStorage(_ frame: ProducedFrame) -> UInt {
    frame.input.withUnsafeNativeInput { UInt(bitPattern: $0.pointee.rows!) }
}
private func imageHandle(_ frame: ProducedFrame) -> UInt {
    frame.input.withUnsafeNativeInput { UInt(bitPattern: $0.pointee.rows![0].images![0].payload!) }
}
private final class Work: @unchecked Sendable {
    let frame: CapturedFrameInput
    let expectedCoverage: [UInt8]
    let done = DispatchSemaphore(value: 0)
    var passed = false
    init(frame: CapturedFrameInput, coverage: [UInt8]) { self.frame = frame; expectedCoverage = coverage }
}
private func runFrame(_ context: UnsafeMutableRawPointer?, _ worker: OpaquePointer?, _ epoch: UInt64) {
    let work = Unmanaged<Work>.fromOpaque(context!).takeUnretainedValue()
    precondition(!Thread.isMainThread)
    work.frame.withUnsafeNativeInput { pointer in
        let frame = pointer.pointee
        precondition(frame.identity.epoch == epoch && frame.row_count == 2)
        precondition(frame.buffer_line_count == 2000 && frame.retained_row_origin == 100 && frame.live_top_row == 110)
        precondition(frame.parameters.grid_rows == 2 && frame.parameters.grid_cols == 8)
        precondition(frame.parameters.cursor_source_row == 101 && frame.parameters.cursor_col == 2)
        precondition(frame.parameters.activity_keypress_time == 3 && frame.parameters.typing_rate == 4)
        precondition(frame.parameters.rows == nil && frame.parameters.drawable == nil && frame.parameters.pass == nil)
        let row = frame.rows![0]
        precondition(row.placement.source_row == 100 && row.placement.has_selection == 1)
        let input = cmdy_render_input_view(row.text)!
        let segment = input.pointee.segments![0]
        let text = Unmanaged<NSAttributedString>.fromOpaque(segment.attributed_string!).takeUnretainedValue()
        precondition(text.string == "Aé𝄞")
        precondition(Array(UnsafeBufferPointer(start: segment.boundaries, count: segment.boundary_count)) == [0, 1, 2, 4])
        let raster = cmdy_render_row_create(input)!
        defer { cmdy_render_row_free(raster) }
        var view = CmdyRenderRowView(); cmdy_render_row_view(raster, &view)
        precondition(Array(UnsafeBufferPointer(start: view.coverage, count: view.coverage_count)) == work.expectedCoverage)
        work.passed = true
    }
}
private func releaseWork(_ context: UnsafeMutableRawPointer?, _ reason: UInt32) {
    precondition(reason == UInt32(CMDY_RENDER_WORKER_EXECUTED))
    Unmanaged<Work>.fromOpaque(context!).takeRetainedValue().done.signal()
}
private func scope(_ body: CmdyRenderWorkerCallback?, _ context: UnsafeMutableRawPointer?) { autoreleasepool { body!(context) } }

private final class RowPreparationWork: @unchecked Sendable {
    let frame: CapturedFrameInput
    let done = DispatchSemaphore(value: 0)
    var prepared = false
    init(frame: CapturedFrameInput) { self.frame = frame }
}
private func prepareRows(_ context: UnsafeMutableRawPointer?, _ worker: OpaquePointer?, _ epoch: UInt64) {
    precondition(!Thread.isMainThread)
    let work = Unmanaged<RowPreparationWork>.fromOpaque(context!).takeUnretainedValue()
    work.frame.withUnsafeNativeMetadata { metadata in
        precondition(metadata.pointee.identity.epoch == epoch)
        precondition(metadata.pointee.rows == nil && metadata.pointee.row_count == 0)
    }
    work.frame.withUnsafeNativeInput { input in
        precondition(input.pointee.row_count == 2)
        for row in UnsafeBufferPointer(start: input.pointee.rows, count: input.pointee.row_count) {
            precondition(cmdy_render_input_view(row.text) == nil)
            var status: UInt32 = 0
            precondition(cmdy_render_input_prepare(row.text, &status) != nil)
            precondition(status == UInt32(CMDY_RENDER_INPUT_OK))
            precondition(cmdy_render_input_revision_reusable(row.text) != 0)
        }
    }
    work.prepared = true
}
private func releaseRowPreparation(_ context: UnsafeMutableRawPointer?, _ reason: UInt32) {
    precondition(reason == UInt32(CMDY_RENDER_WORKER_EXECUTED))
    Unmanaged<RowPreparationWork>.fromOpaque(context!).takeRetainedValue().done.signal()
}
@MainActor private func prepareDeferredRowsOnWorker(_ frame: CapturedFrameInput) {
    let worker = cmdy_render_worker_create_with_scope(scope)!
    let work = RowPreparationWork(frame: frame)
    let context = Unmanaged.passRetained(work).toOpaque()
    precondition(cmdy_render_worker_submit(worker, 1, context, prepareRows, releaseRowPreparation) != 0)
    precondition(work.done.wait(timeout: .now() + 10) == .success)
    precondition(cmdy_render_worker_destroy(worker) != 0 && work.prepared)
}

@MainActor private func deferredFixture() throws -> CapturedFrameInput {
    weak var releasedSource: Source?
    let frame = try autoreleasepool {
        let producer = ProducerFrameCapture(), source = Source()
        releasedSource = source
        let font = UnsafeRawPointer(Unmanaged.passUnretained(source.normalFont).toOpaque())
        let white = UnsafeRawPointer(Unmanaged.passUnretained(NSColor.white).toOpaque())
        let black = UnsafeRawPointer(Unmanaged.passUnretained(NSColor.black).toOpaque())
        var styleInput = CmdyShapeStyleInput()
        styleInput.fonts = (font, font, font, font)
        styleInput.colors = (white, black, white, white, black)
        let originalStyle = cmdy_shape_style_create(&styleInput)!
        let style = try NativeRowStyle(nativeStyle: originalStyle)
        cmdy_shape_style_free(originalStyle)
        var blank = CmdyZigCell(); blank.width = 1
        let line = cmdy_zig_line_create(8, &blank, nil, 0, 0)!
        defer { cmdy_zig_line_release(line) }
        for (col, scalar) in [UInt32(0x41), 0xe9, 0x1d11e].enumerated() {
            var cell = blank; cell.scalar = scalar
            precondition(cmdy_zig_line_set(line, col, &cell, nil, 0, 0) == 0)
        }
        source.nativeRow = { row, parameters in
            try DeferredRenderRow(nativeLine: UnsafeRawPointer(line), sourceRow: row,
                style: style, parameters: parameters, images: [])
        }
        source.onLine = { preconditionFailure("Deferred source shaped text on the producer") }
        var config = CmdyRenderScheduleConfig(); config.cursor_speed = 9; config.cursor_max_distance = 20
        var environment = ProducerFrameEnvironment(identity: .init(surface: 1, epoch: 1, sequence: 1),
            drawableSize: .init(width: 96, height: 40), config: config, motion: .init(), preset: .current, liveResize: false, now: 10)
        let first = try producer.capture(source: source, environment: environment)
        precondition(source.lineReads == 0 && source.nativeReads == 2)
        first.input.withUnsafeNativeInput {
            for row in UnsafeBufferPointer(start: $0.pointee.rows, count: $0.pointee.row_count) {
                precondition(cmdy_render_input_view(row.text) == nil)
            }
        }
        // Reuse eligibility is now published by worker preparation. A dirty
        // row that has never reached the worker remains conservatively unknown.
        prepareDeferredRowsOnWorker(first.input)
        source.dirty = 100...101; environment.identity.sequence += 1
        let reused = try producer.capture(source: source, environment: environment)
        precondition(textHandle(first) == textHandle(reused) && source.nativeReads == 2)
        precondition(rowStorage(first) == rowStorage(reused))
        producer.invalidate()
        source.nativeRow = { _, _ in throw RowInputCaptureFailure.invalidInput }
        do { _ = try producer.capture(source: source, environment: environment); preconditionFailure("Deferred error accepted") }
        catch ProducerCaptureFailure.deferredRow(100, _) {}
        precondition(producer.cachedRowCount == 0)
        // Native mutation and source/style disposal precede the actual session.
        precondition(cmdy_zig_line_reset(line, &blank, nil, 0, 0, 0) == 0)
        return reused.input
    }
    precondition(releasedSource == nil)
    print("Deferred producer: zero lineInfo reads, unprepared frame, dirty reuse, error invalidation and source disposal PASS")
    return frame
}

@MainActor private func sharedContentFixture() throws -> CapturedFrameInput {
    weak var releasedSource: Source?
    let result = try autoreleasepool {
        let producer = ProducerFrameCapture(), source = Source()
        releasedSource = source
        var environment = ProducerFrameEnvironment(identity: .init(surface: 1, epoch: 1, sequence: 0),
            drawableSize: .init(width: 96, height: 40), config: .init(), motion: .init(),
            preset: .current, liveResize: false, now: 10)
        @MainActor func capture() throws -> ProducedFrame {
            environment.identity.sequence += 1; source.gridCaptured = false
            return try producer.capture(source: source, environment: environment)
        }
        let first = try capture()
        environment.now = 11
        let animation = try capture()
        precondition(source.snapshots == 2 && source.lineReads == 2)
        precondition(rowStorage(first) == rowStorage(animation))
        animation.input.withUnsafeNativeInput { precondition($0.pointee.parameters.now == 11) }
        first.input.withUnsafeNativeInput { precondition($0.pointee.parameters.now == 10) }

        source.cursorColumn = 4; source.bufferLines = 2100
        source.keypressTime = 8; source.typingRate = 9
        environment.config.host_cursor_hidden = true
        environment.config.shader_mode = 2; environment.motion.envelope_energy = 0.75
        let metadata = try capture()
        precondition(rowStorage(metadata) == rowStorage(first) && source.lineReads == 2)
        metadata.input.withUnsafeNativeInput {
            let input = $0.pointee, frame = input.parameters
            precondition(input.buffer_line_count == 2100 && frame.cursor_col == 4)
            precondition(frame.activity_keypress_time == 8 && frame.typing_rate == 9)
            precondition(frame.host_cursor_hidden == 1 && frame.shader_mode == 2 && frame.shader_energy == 0.75)
        }
        first.input.withUnsafeNativeInput {
            precondition($0.pointee.buffer_line_count == 2000 && $0.pointee.parameters.cursor_col == 2)
        }
        source.dirty = 100...101
        let dirtyUnchanged = try capture()
        precondition(rowStorage(dirtyUnchanged) == rowStorage(metadata) && source.lineReads == 2)

        source.selected = 3...4
        let selection = try capture()
        precondition(rowStorage(selection) != rowStorage(dirtyUnchanged))
        precondition(textHandle(selection) == textHandle(dirtyUnchanged) && source.lineReads == 2)
        selection.input.withUnsafeNativeInput { precondition($0.pointee.rows![0].placement.selection_lower == 3) }
        let sameSelection = try capture()
        precondition(rowStorage(sameSelection) == rowStorage(selection))

        source.context += 1; source.dirty = 100...101
        let context = try capture()
        precondition(rowStorage(context) != rowStorage(sameSelection) && source.lineReads == 4)
        source.versions[100] = 2
        let version = try capture()
        precondition(rowStorage(version) != rowStorage(context) && source.lineReads == 5)
        source.underline += 1
        let geometry = try capture()
        precondition(rowStorage(geometry) != rowStorage(version) && source.lineReads == 7)
        source.top += 1
        let scrolled = try capture()
        precondition(rowStorage(scrolled) != rowStorage(geometry))
        scrolled.input.withUnsafeNativeInput { precondition($0.pointee.rows![0].placement.source_row == 101) }
        source.top = 100

        let image = EncodedImage(); source.attached = image; source.dirty = 100...100
        let imaged = try capture()
        let sameImage = try capture()
        precondition(rowStorage(sameImage) == rowStorage(imaged) && image.payloadReads == 1)
        image.col = 7; source.dirty = 100...100
        let movedImage = try capture()
        precondition(rowStorage(movedImage) != rowStorage(sameImage))
        movedImage.input.withUnsafeNativeInput { precondition($0.pointee.rows![0].images![0].placement.col == 7) }
        image.renderIdentity = UUID(); image.payload = .rgba(bytes: [50, 60, 70, 255], width: 1, height: 1)
        source.dirty = 100...100
        let replacedImage = try capture()
        precondition(rowStorage(replacedImage) != rowStorage(movedImage) && image.payloadReads == 2)
        source.attached = nil; source.dirty = 100...100
        _ = try capture()

        source.kittyPayloads[42] = .rgba(bytes: [1, 2, 3, 255], width: 1, height: 1)
        let kitty = try capture()
        source.kittyPayloads[42] = .rgba(bytes: [9, 8, 7, 255], width: 1, height: 1)
        let changedKitty = try capture()
        precondition(rowStorage(changedKitty) != rowStorage(kitty))
        changedKitty.input.withUnsafeNativeInput {
            let image = $0.pointee.parameters.kitty_images![0]
            precondition(Array(UnsafeBufferPointer(start: image.bytes, count: image.byte_count)) == [9, 8, 7, 255])
        }
        source.kittyPayloads.removeAll()
        let removedKitty = try capture()
        precondition(rowStorage(removedKitty) != rowStorage(changedKitty))
        removedKitty.input.withUnsafeNativeInput {
            precondition($0.pointee.parameters.kitty_image_count == 0 && $0.pointee.parameters.live_kitty_count == 0)
        }
        let afterKitty = try capture()
        precondition(rowStorage(afterKitty) == rowStorage(removedKitty))

        source.onCapture = { producer.invalidate() }
        do { _ = try capture(); preconditionFailure("Invalidated reuse accepted") }
        catch ProducerCaptureFailure.invalidated {}
        precondition(producer.cachedRowCount == 0 && producer.cachedImageCount == 0)
        source.onCapture = nil
        let recovered = try capture()
        precondition(rowStorage(recovered) != rowStorage(afterKitty))
        var rejectedReentry = false
        source.onCapture = {
            do { _ = try producer.capture(source: source, environment: environment) }
            catch ProducerCaptureFailure.reentrantCapture { rejectedReentry = true }
            catch { preconditionFailure("Unexpected nested capture error") }
        }
        let afterReentry = try capture()
        precondition(rejectedReentry && rowStorage(afterReentry) == rowStorage(recovered))
        source.onCapture = nil
        environment.identity.epoch += 1
        let epoch = try capture()
        precondition(rowStorage(epoch) != rowStorage(afterReentry))
        let replacement = Source()
        let replaced = try producer.capture(source: replacement, environment: environment)
        precondition(rowStorage(replaced) != rowStorage(epoch))
        producer.invalidate()
        source.text.replaceCharacters(in: NSRange(location: 0, length: source.text.length), with: "changed")
        // This packet really reused the first frame's owned content. Both
        // producer/source teardown and later frames precede its worker draw.
        return animation.input
    }
    precondition(releasedSource == nil)
    print("Shared frame content: metadata refresh, row/selection/geometry/image/Kitty invalidation, reentry, epochs and source disposal PASS")
    return result
}

@MainActor private func producerBufferFixture() throws {
    let producer = ProducerFrameCapture(), source = Source()
    source.rowCount = 4
    var environment = ProducerFrameEnvironment(identity: .init(surface: 91, epoch: 1, sequence: 0),
        drawableSize: .init(width: 96, height: 100), config: .init(), motion: .init(),
        preset: .current, liveResize: false, now: 10)
    @MainActor func capture() throws -> ProducedFrame {
        environment.identity.sequence += 1
        return try producer.capture(source: source, environment: environment)
    }
    func handles(_ frame: ProducedFrame) -> [UInt] {
        frame.input.withUnsafeNativeInput { input in
            UnsafeBufferPointer(start: input.pointee.rows, count: input.pointee.row_count)
                .map { UInt(bitPattern: $0.text!) }
        }
    }
    func strings(_ frame: ProducedFrame) -> [String] {
        frame.input.withUnsafeNativeInput { input in
            UnsafeBufferPointer(start: input.pointee.rows, count: input.pointee.row_count).map { row in
                let segment = cmdy_render_input_view(row.text)!.pointee.segments![0]
                return Unmanaged<NSAttributedString>.fromOpaque(segment.attributed_string!).takeUnretainedValue().string
            }
        }
    }
    @MainActor func replace(_ row: Int, text: String) {
        source.rowText[row] = NSAttributedString(string: text,
            attributes: [.font: source.normalFont, .foregroundColor: NSColor.white])
        source.versions[row] = (source.versions[row] ?? 1) + 1
    }
    let first = try capture()
    let clean = try capture()
    precondition(source.lineReads == 4 && rowStorage(first) == rowStorage(clean))
    replace(103, text: "Zé𝄞")
    let tail = try capture()
    precondition(source.lineReads == 5 && strings(tail) == ["Aé𝄞", "Aé𝄞", "Aé𝄞", "Zé𝄞"])
    precondition(Array(handles(tail).prefix(3)) == Array(handles(first).prefix(3)))
    precondition(handles(tail)[3] != handles(first)[3])
    replace(101, text: "Mé𝄞")
    let middle = try capture()
    precondition(source.lineReads == 6 && strings(middle) == ["Aé𝄞", "Mé𝄞", "Aé𝄞", "Zé𝄞"])
    for index in [0, 2, 3] { precondition(handles(middle)[index] == handles(tail)[index]) }
    precondition(handles(middle)[1] != handles(tail)[1])

    source.selections[102] = 4...5
    let selected = try capture()
    precondition(handles(selected) == handles(middle) && rowStorage(selected) != rowStorage(middle))
    selected.input.withUnsafeNativeInput { input in
        for index in 0..<4 {
            let placement = input.pointee.rows![index].placement
            precondition(placement.source_row == 100 + index && placement.display_index == index)
            precondition(placement.selection_lower == (index == 2 ? 4 : 1))
        }
    }
    let sameSelection = try capture()
    precondition(rowStorage(sameSelection) == rowStorage(selected) && source.lineReads == 6)
    source.rowCount = 2
    let smaller = try capture()
    precondition(strings(smaller) == ["Aé𝄞", "Mé𝄞"] && source.lineReads == 6)
    source.rowCount = 5
    let larger = try capture()
    precondition(strings(larger) == ["Aé𝄞", "Mé𝄞", "Aé𝄞", "Zé𝄞", "Aé𝄞"] && source.lineReads == 7)
    source.top = 101
    let shifted = try capture()
    precondition(strings(shifted) == ["Mé𝄞", "Aé𝄞", "Zé𝄞", "Aé𝄞", "Aé𝄞"] && source.lineReads == 8)
    shifted.input.withUnsafeNativeInput { input in
        for index in 0..<5 {
            precondition(input.pointee.rows![index].placement.source_row == 101 + index)
            precondition(input.pointee.rows![index].placement.display_index == index)
        }
    }
    source.onSelection = { row in if row == 103 { producer.invalidate() } }
    do { _ = try capture(); preconditionFailure("Invalidated retained buffers accepted") }
    catch ProducerCaptureFailure.invalidated {}
    precondition(producer.cachedRowCount == 0)
    source.onSelection = nil
    let recovered = try capture()
    precondition(strings(recovered) == strings(shifted) && source.lineReads == 13)
    let reused = try capture()
    precondition(rowStorage(reused) == rowStorage(recovered) && source.lineReads == 13)
    precondition(strings(first) == ["Aé𝄞", "Aé𝄞", "Aé𝄞", "Aé𝄞"])
    precondition(strings(tail) == ["Aé𝄞", "Aé𝄞", "Aé𝄞", "Zé𝄞"])
    first.input.withUnsafeNativeInput { precondition($0.pointee.rows![2].placement.selection_lower == 1) }
    print("Producer buffers: unchanged frames, middle/tail edits, selection, shrink/grow, scrolling, mid-capture invalidation and old-frame ownership PASS")
}

@MainActor private func publishedFrameFixture() throws -> CapturedFrameInput {
    weak var releasedSource: PublishedSource?
    let result = try autoreleasepool {
        let producer = ProducerFrameCapture(), source = PublishedSource()
        releasedSource = source
        var environment = ProducerFrameEnvironment(identity: .init(surface: 1, epoch: 1, sequence: 0),
            drawableSize: .init(width: 96, height: 40), config: .init(), motion: .init(),
            preset: .current, liveResize: false, now: 10)
        @MainActor func capture() throws -> ProducedFrame {
            environment.identity.sequence += 1; source.gridCaptured = false
            return try producer.capture(source: source, environment: environment)
        }
        @MainActor func fullCapture() throws -> ProducedFrame {
            let reads = source.contentReads
            let frame = try capture()
            precondition(source.contentReads > reads, "Changed content must take the validated row path")
            return frame
        }
        @MainActor func reusedCapture() throws -> ProducedFrame {
            let reads = source.contentReads
            let frame = try capture()
            precondition(source.contentReads == reads, "Unchanged publication must not read any row or graphics source")
            return frame
        }
        let first = try fullCapture()
        environment.now = 11
        let animation = try reusedCapture()
        precondition(source.snapshots == 2 && rowStorage(first) == rowStorage(animation))
        for _ in 0..<32 {
            let reused = try reusedCapture()
            precondition(rowStorage(reused) == rowStorage(first))
        }
        source.cursorColumn = 4; source.keypressTime = 8; source.typingRate = 9
        environment.config.host_cursor_hidden = true
        environment.config.shader_mode = 2; environment.motion.envelope_energy = 0.75
        let scalar = try reusedCapture()
        scalar.input.withUnsafeNativeInput {
            let frame = $0.pointee.parameters
            precondition(frame.now == 11 && frame.cursor_col == 4 && frame.host_cursor_hidden == 1)
            precondition(frame.activity_keypress_time == 8 && frame.typing_rate == 9)
            precondition(frame.shader_mode == 2 && frame.shader_energy == 0.75)
        }
        first.input.withUnsafeNativeInput { precondition($0.pointee.parameters.now == 10 && $0.pointee.parameters.cursor_col == 2) }

        source.dirty = 100...101
        let dirty = try fullCapture()
        precondition(rowStorage(dirty) == rowStorage(first))
        _ = try reusedCapture()
        source.publication += 1; source.versions[100] = 2
        source.rowText[100] = NSAttributedString(string: "Zé𝄞", attributes: [.font: source.normalFont])
        let edited = try fullCapture()
        precondition(textHandle(edited) != textHandle(first))
        _ = try reusedCapture()
        source.selected = 3...4; source.publication += 1
        let selected = try fullCapture()
        precondition(textHandle(selected) == textHandle(edited) && rowStorage(selected) != rowStorage(edited))
        selected.input.withUnsafeNativeInput { precondition($0.pointee.rows![0].placement.selection_lower == 3) }
        _ = try reusedCapture()

        source.context += 1; source.publication += 1; source.dirty = 100...101
        let style = try fullCapture()
        precondition(textHandle(style) != textHandle(selected))
        source.normalFont = NSFont(name: "Menlo", size: 16)!; source.publication += 1
        let font = try fullCapture()
        precondition(textHandle(font) != textHandle(style))
        source.foreground = .red; source.publication += 1
        let color = try fullCapture()
        precondition(textHandle(color) != textHandle(font))
        source.underline += 1; source.publication += 1
        let underline = try fullCapture()
        precondition(textHandle(underline) != textHandle(color))
        _ = try reusedCapture()

        // Geometry and fringe changes invalidate reuse even without a source
        // publication. Within the same fringe, only the scroll scalar changes.
        source.scale = 2; _ = try fullCapture(); _ = try reusedCapture()
        source.scale = 1; _ = try fullCapture()
        environment.preset = .crisp; _ = try fullCapture(); _ = try reusedCapture()
        environment.preset = .current; _ = try fullCapture()
        source.top += 1; _ = try fullCapture(); _ = try reusedCapture()
        source.rowCount += 1; _ = try fullCapture(); _ = try reusedCapture()
        source.bufferLines += 1; _ = try fullCapture(); _ = try reusedCapture()
        environment.config.smooth_scroll = true; environment.motion.scroll_held = 1
        let fringe = try fullCapture()
        environment.motion.scroll_held = 2
        let moved = try reusedCapture()
        precondition(rowStorage(fringe) == rowStorage(moved))
        moved.input.withUnsafeNativeInput { precondition($0.pointee.parameters.scroll_pixels == 2) }
        environment.motion.scroll_held = 21; _ = try fullCapture()
        environment.config.smooth_scroll = false; _ = try fullCapture()

        // Revision and producer invalidation are checked after all scalar
        // callbacks, including the last revision read on the fast path.
        source.onActivityRead = { source.publication += 1 }
        do { _ = try capture(); preconditionFailure("Mixed publication accepted") }
        catch ProducerCaptureFailure.invalidated {}
        precondition(producer.cachedRowCount == 0)
        source.onActivityRead = nil; _ = try fullCapture()
        let finalRead = source.publicationReads + 2
        source.onPublicationRead = { count in if count == finalRead { producer.invalidate() } }
        do { _ = try capture(); preconditionFailure("Invalidated publication accepted") }
        catch ProducerCaptureFailure.invalidated {}
        precondition(producer.cachedRowCount == 0)
        source.onPublicationRead = nil; _ = try fullCapture()
        var rejectedReentry = false
        source.onActivityRead = {
            do { _ = try producer.capture(source: source, environment: environment) }
            catch ProducerCaptureFailure.reentrantCapture { rejectedReentry = true }
            catch { preconditionFailure("Unexpected reentry failure") }
        }
        _ = try reusedCapture(); precondition(rejectedReentry)
        source.onActivityRead = nil
        environment.identity.epoch += 1; _ = try fullCapture(); _ = try reusedCapture()
        source.publication = 0; _ = try fullCapture(); _ = try fullCapture()
        source.publication = 100; _ = try fullCapture(); _ = try reusedCapture()

        let image = EncodedImage(); source.attached = image
        source.dirty = source.top...source.top; source.publication += 1
        _ = try fullCapture(); _ = try fullCapture()
        image.col = 7; source.dirty = source.top...source.top; source.publication += 1
        let movedImage = try fullCapture()
        movedImage.input.withUnsafeNativeInput { precondition($0.pointee.rows![0].images![0].placement.col == 7) }
        source.attached = nil; source.dirty = source.top...source.top; source.publication += 1
        _ = try fullCapture(); _ = try reusedCapture()
        source.kittyPayloads[42] = .rgba(bytes: [1, 2, 3, 255], width: 1, height: 1); source.publication += 1
        _ = try fullCapture(); _ = try fullCapture()
        source.kittyPayloads.removeAll(); source.publication += 1
        _ = try fullCapture(); _ = try reusedCapture()

        let replacement = PublishedSource()
        _ = try producer.capture(source: replacement, environment: environment)
        precondition(replacement.lineReads == 2)
        producer.invalidate()
        source.text.replaceCharacters(in: NSRange(location: 0, length: source.text.length), with: "changed")
        return animation.input
    }
    precondition(releasedSource == nil)
    print("Published frames: zero row reads across 33 animation captures, fresh scalars, dirty/style/selection/geometry/graphics guards, revision races, reentry and disposal PASS")
    return result
}

@main private struct Smoke {
    @MainActor static func main() async throws {
        try producerBufferFixture()
        try autoreleasepool {
            let producer = ProducerFrameCapture(), source = Source()
            var environment = ProducerFrameEnvironment(identity: .init(surface: 80, epoch: 1, sequence: 0),
                drawableSize: .init(width: 96, height: 40), config: .init(), motion: .init(),
                preset: .current, liveResize: false, now: 10)
            @MainActor func capture() throws -> ProducedFrame {
                environment.identity.sequence += 1
                return try producer.capture(source: source, environment: environment)
            }
            @MainActor func capture(appearance: NSAppearance) throws -> ProducedFrame {
                var result: Result<ProducedFrame, Error>!
                appearance.performAsCurrentDrawingAppearance { result = Result { try capture() } }
                return try result.get()
            }
            let first = try capture(), clean = try capture()
            precondition(textHandle(first) == textHandle(clean) && source.lineReads == 2)
            source.normalFont = NSFont(name: "Menlo", size: 16)!
            let changedFont = try capture()
            precondition(textHandle(changedFont) != textHandle(clean) && source.lineReads == 4)
            source.foreground = .red
            let changedForeground = try capture()
            precondition(textHandle(changedForeground) != textHandle(changedFont) && source.lineReads == 6)
            source.background = .blue
            let changedBackground = try capture()
            precondition(textHandle(changedBackground) != textHandle(changedForeground) && source.lineReads == 8)
            // The same dynamic color identity can resolve differently in a
            // later frame; a per-frame key must observe the new appearance.
            source.foreground = NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
            })
            let lightFrame = try capture(appearance: NSAppearance(named: .aqua)!)
            let darkFrame = try capture(appearance: NSAppearance(named: .darkAqua)!)
            precondition(textHandle(lightFrame) != textHandle(darkFrame) && source.lineReads == 12)
            let warm = try capture(appearance: NSAppearance(named: .darkAqua)!)
            precondition(textHandle(warm) == textHandle(darkFrame) && source.lineReads == 12)
            print("Producer frame keys: clean reuse, font, foreground, background and dynamic appearance refresh PASS")
        }
        let (sessionFrame, pixels) = try autoreleasepool {
            let producer = ProducerFrameCapture(), source = Source()
            var config = CmdyRenderScheduleConfig(); config.cursor_speed = 9; config.cursor_max_distance = 20
            var environment = ProducerFrameEnvironment(identity: .init(surface: 1, epoch: 1, sequence: 1),
                drawableSize: .init(width: 96, height: 40), config: config, motion: .init(), preset: .current, liveResize: false, now: 10)
            @MainActor func capture() throws -> ProducedFrame {
                environment.identity.sequence += 1; source.gridCaptured = false
                return try producer.capture(source: source, environment: environment)
            }
            let reference = IndependentRowRasterizer.rasterize(info: source.info(100), cols: 8, width: 96, height: 20,
                cellWidth: 12, cellHeight: 20, scale: 1, normalFont: source.normalFont, nativeForeground: .white,
                underlinePosition: 2, underlineThickness: 1, preset: .current, antialiasBlocks: true)!
            let first = try capture(); precondition(source.lineReads == 2)
            let clean = try capture(); precondition(source.lineReads == 2 && textHandle(first) == textHandle(clean))
            source.dirty = 100...101
            let dirty = try capture(); precondition(source.lineReads == 2 && textHandle(first) == textHandle(dirty))
            source.selected = 3...5
            let selected = try capture()
            selected.input.withUnsafeNativeInput { precondition($0.pointee.rows![0].placement.selection_lower == 3) }
            precondition(source.lineReads == 2 && textHandle(first) == textHandle(selected))
            source.underline = 3
            let geometry = try capture(); precondition(source.lineReads == 4 && textHandle(first) != textHandle(geometry))
            source.versions[100] = 2; source.dirty = 100...100
            _ = try capture(); precondition(source.lineReads == 5)
            source.text.addAttribute(.link, value: "https://example.invalid", range: NSRange(location: 0, length: 1))
            source.versions[100] = 3
            do { _ = try capture(); preconditionFailure("Unsupported attributes accepted") }
            catch ProducerCaptureFailure.row(100, .unsupportedAttributes) {}
            precondition(producer.cachedRowCount == 0)
            source.text.removeAttribute(.link, range: NSRange(location: 0, length: 1))
            let beforeRecovery = source.lineReads
            _ = try capture(); precondition(source.lineReads == beforeRecovery + 2)
            source.context += 1; source.dirty = 100...101
            let beforeContext = source.lineReads
            _ = try capture(); precondition(source.lineReads == beforeContext + 2)
            source.attached = UnsupportedImage(); source.dirty = 100...100
            do { _ = try capture(); preconditionFailure("Unsupported image accepted") }
            catch ProducerCaptureFailure.unsupportedImage(100) {}
            let image = EncodedImage(); source.attached = image
            let imaged = try capture(); precondition(image.payloadReads == 1)
            source.dirty = 100...100; image.col = 6
            let moved = try capture(); precondition(image.payloadReads == 1 && imageHandle(imaged) == imageHandle(moved))
            moved.input.withUnsafeNativeInput { precondition($0.pointee.rows![0].images![0].placement.col == 6) }
            image.renderIdentity = UUID(); image.payload = .rgba(bytes: [80, 70, 60, 255], width: 1, height: 1)
            source.dirty = 100...100
            let changed = try capture(); precondition(image.payloadReads == 2 && imageHandle(moved) != imageHandle(changed))
            imaged.input.withUnsafeNativeInput {
                let input = cmdy_render_image_input_view($0.pointee.rows![0].images![0].payload)!.pointee
                precondition(Array(UnsafeBufferPointer(start: input.bytes, count: input.byte_count)) == [10, 20, 30, 128])
            }
            source.versions[100] = 4; source.onLine = { producer.invalidate() }
            do { _ = try capture(); preconditionFailure("Invalidated frame accepted") }
            catch ProducerCaptureFailure.invalidated {}
            precondition(producer.cachedRowCount == 0 && producer.cachedImageCount == 0)
            source.onLine = nil; _ = try capture()
            var rejectedReentry = false
            source.onLine = {
                do { _ = try producer.capture(source: source, environment: environment) }
                catch ProducerCaptureFailure.reentrantCapture { rejectedReentry = true }
                catch { preconditionFailure("Wrong reentry failure") }
            }
            source.dirty = 100...100; _ = try capture(); precondition(rejectedReentry)
            source.onLine = nil; source.attached = nil
            environment.identity.epoch = 2
            let beforeEpoch = source.lineReads; _ = try capture(); precondition(source.lineReads == beforeEpoch + 2)
            for top in 101...125 { source.top = top; _ = try capture() }
            precondition(producer.cachedRowCount <= 6)
            let replacement = Source(); _ = try producer.capture(source: replacement, environment: environment)
            precondition(replacement.lineReads == 2)
            weak var releasedSource: Source?
            do {
                let transient = Source(); releasedSource = transient
                _ = try producer.capture(source: transient, environment: environment)
            }
            precondition(releasedSource == nil)
            source.kittyPayloads[42] = .rgba(bytes: [1, 2, 3, 255], width: 1, height: 1)
            let kitty = try capture()
            source.kittyPayloads[42] = .rgba(bytes: [9, 9, 9, 255], width: 1, height: 1)
            kitty.input.withUnsafeNativeInput {
                let frame = $0.pointee.parameters
                precondition(frame.kitty_image_count == 1 && frame.kitty_placement_count == 1 && frame.live_kitty_count == 1)
                precondition(frame.live_kitty_ids![0] == 42 && frame.kitty_placements![0].offset_x == 4)
                let image = frame.kitty_images![0]
                precondition(image.image_id == 42 && image.kind == 1 && image.width == 1 && image.height == 1)
                precondition(Array(UnsafeBufferPointer(start: image.bytes, count: image.byte_count)) == [1, 2, 3, 255])
            }
            source.text.replaceCharacters(in: NSRange(location: 0, length: source.text.length), with: "changed")
            let worker = cmdy_render_worker_create_with_scope(scope)!
            let work = Work(frame: first.input, coverage: reference.coverage)
            let context = Unmanaged.passRetained(work).toOpaque()
            precondition(cmdy_render_worker_submit(worker, 1, context, runFrame, releaseWork) != 0)
            precondition(work.done.wait(timeout: .now() + 10) == .success)
            precondition(cmdy_render_worker_destroy(worker) != 0 && work.passed)
            let pixels = try verifySwiftTargetPipeline(frame: first.input)
            print("Producer capture: snapshot order, cache/revision/selection, geometry, graphics, failures, invalidation, reentry, pruning and Zig worker raster parity PASS")
            return (first.input, pixels)
        }
        try await verifySwiftSessionPipeline(frame: sessionFrame, reference: pixels)
        let deferredFrame = try deferredFixture()
        try await verifySwiftSessionPipeline(frame: deferredFrame, reference: pixels)
        let sharedFrame = try sharedContentFixture()
        let sharedPixels = try verifySwiftTargetPipeline(frame: sharedFrame)
        precondition(sharedPixels == pixels)
        try await verifySwiftSessionPipeline(frame: sharedFrame, reference: sharedPixels)
        let publishedFrame = try publishedFrameFixture()
        let publishedPixels = try verifySwiftTargetPipeline(frame: publishedFrame)
        precondition(publishedPixels == pixels)
        try await verifySwiftSessionPipeline(frame: publishedFrame, reference: publishedPixels)
    }
}
