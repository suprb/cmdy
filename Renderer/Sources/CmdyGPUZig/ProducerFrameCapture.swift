import AppKit
import CoreText
import CmdyNative

enum ProducerCaptureFailure: Error {
    case reentrantCapture
    case invalidated
    case invalidGeometry
    case row(Int, RowInputCaptureFailure)
    case deferredRow(Int, Error)
    case image(Int, FrameInputCaptureFailure)
    case unsupportedImage(Int)
}

/// Values published by the render owner; no borrowed scheduler/GPU handle.
struct ProducerFrameEnvironment {
    var identity: CmdyRenderFrameIdentity
    var drawableSize: CGSize
    var config: CmdyRenderScheduleConfig
    var motion: CmdyRenderScheduleInspection
    var preset: TextRenderingMode
    var liveResize: Bool
    var now: Double
}

struct ProducedFrame {
    let input: CapturedFrameInput
    let cursorBlinkEligible: Bool
    let renderedScrollPoints: CGFloat
}

/// Cursor and animation values are deliberately absent: they are copied anew.
/// The publication revision covers row/style/selection state; geometry and
/// renderer configuration can change independently of a source publication.
private struct PublishedFrameKey: Equatable {
    let revision: UInt64
    let rows: Int, cols: Int, bufferLineCount: Int, retainedRowOrigin: Int
    let displayTopRow: Int, liveTopRow: Int
    let alternateBuffer: Bool
    let fringeRows: Int, rowWidth: Int, rowHeight: Int
    let cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat
    let preset: TextRenderingMode
}

@MainActor
private final class ProducerRow {
    let key: IndependentRowKey
    let raster: IndependentRowRasterInputs
    let revision: SnapshotRowRevision?
    let text: CapturedRowInput
    let images: [(identity: UUID, input: CapturedImageInput, placement: CmdyGpuImagePlacement)]
    let placeholders: [CmdyGpuPlaceholder]
    let descriptor: CapturedFrameRowInput
    private let eagerRevisionReusable: Bool?
    var revisionReusable: Bool {
        eagerRevisionReusable ?? (images.isEmpty && text.revisionReusable)
    }
    var lastUse: UInt64

    init(key: IndependentRowKey, raster: IndependentRowRasterInputs, revision: SnapshotRowRevision?,
         text: CapturedRowInput,
         images: [(identity: UUID, input: CapturedImageInput, placement: CmdyGpuImagePlacement)],
         placeholders: [CmdyGpuPlaceholder], revisionReusable: Bool?, lastUse: UInt64) throws {
        // Freeze nested row values only when the cached row changes. Selection
        // and viewport placement belong to the frame's separate reference list.
        let nativeImages = images.map { image in
            CmdyRenderFrameImageInput(
                payload: image.input.withUnsafeNativeHandle { cmdy_render_image_input_retain($0)! },
                placement: image.placement)
        }
        defer { for image in nativeImages { cmdy_render_image_input_release(image.payload) } }
        descriptor = try key.withGPUKey { nativeKey in
            Result {
                try text.withUnsafeNativeHandle { nativeText in
                    try nativeImages.withUnsafeBufferPointer { imageBuffer in
                        try placeholders.withUnsafeBufferPointer { placeholderBuffer in
                            var input = CmdyRenderFrameRowInput()
                            input.key = nativeKey.pointee; input.font_name_bytes = key.fontName.utf8.count
                            input.revision = .init(content: revision?.content ?? 0, context: revision?.context ?? 0)
                            input.text = nativeText
                            input.images = imageBuffer.baseAddress; input.image_count = imageBuffer.count
                            input.placeholders = placeholderBuffer.baseAddress; input.placeholder_count = placeholderBuffer.count
                            return try CapturedFrameRowInput.capture(&input).get()
                        }
                    }
                }
            }
        }.get()
        self.key = key; self.raster = raster; self.revision = revision; self.text = text
        self.images = images; self.placeholders = placeholders
        self.eagerRevisionReusable = revisionReusable; self.lastUse = lastUse
    }
}

/// The source is read only on the main actor. Owned text/image handles are
/// reused; rasterization, glyph uploads and Metal encoding are absent here.
/// Invalidation or any capture error discards producer caches so consumed dirty
/// information cannot make a later frame reuse an incomplete capture.
@MainActor
final class ProducerFrameCapture {
    private var rows: [Int: ProducerRow] = [:]
    private var images: [UUID: (input: CapturedImageInput, used: UInt64)] = [:]
    private weak var cachedSource: (any MetalRenderSource)?
    private var surface: UInt64 = 0
    private var epoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var tick: UInt64 = 0
    private var capturing = false
    private var capturedFrame: CapturedFrameInput?
    private var capturedRows: [ProducerRow] = []
    private var capturedPlacements: [CmdyGpuFrameRow] = []
    private var capturedWithoutGlobalKitty = false
    private var capturedPublication: PublishedFrameKey?

    var cachedRowCount: Int { rows.count }
    var cachedImageCount: Int { images.count }
    private(set) var capturedRowCount: Int = 0

    func invalidate() {
        generation &+= 1
        rows.removeAll(keepingCapacity: true)
        images.removeAll(keepingCapacity: true)
        capturedFrame = nil
        capturedRows.removeAll(keepingCapacity: true)
        capturedPlacements.removeAll(keepingCapacity: true)
        capturedWithoutGlobalKitty = false
        capturedPublication = nil
        capturedRowCount = 0
    }

    func capture(source: any MetalRenderSource, environment e: ProducerFrameEnvironment,
                 acquireDrawable: (() throws -> CGSize)? = nil) throws -> ProducedFrame {
        guard !capturing else { throw ProducerCaptureFailure.reentrantCapture }
        capturing = true
        let tracing = RendererPerformanceTrace.enabled
        let started = tracing ? RendererPerformanceTrace.now() : 0
        var requestedRows = 0, rebuiltRows = 0
        var succeeded = false
        defer {
            capturing = false
            if !succeeded { invalidate() }
            if tracing {
                RendererPerformanceTrace.record(event: "capture.total", started: started,
                    fields: ["surface": Int(clamping: e.identity.surface), "sequence": Int(clamping: e.identity.sequence),
                             "rows": requestedRows, "rebuilt": rebuiltRows, "success": succeeded ? 1 : 0])
            }
        }
        if cachedSource !== source || surface != e.identity.surface || epoch != e.identity.epoch {
            invalidate()
            cachedSource = source; surface = e.identity.surface; epoch = e.identity.epoch
        }
        let expectedGeneration = generation
        tick &+= 1
        // Snapshot must precede every other source-protocol read.
        let snapshot = source.captureGrid()
        let publishedSource = source as? any PublishedFrameRenderSource
        let publication = publishedSource?.frameContentRevision ?? 0
        let scale = source.backingScaleFactor(), cellSize = source.cellSize, bounds = source.viewBounds
        var metrics = cmdy_gpu_frame_metrics(snapshot.rows, snapshot.cols, cellSize.width, cellSize.height, scale,
            bounds.width, bounds.height, e.drawableSize.width, e.drawableSize.height)
        guard metrics.valid != 0 else { throw ProducerCaptureFailure.invalidGeometry }
        // Reject an unbuildable grid before requesting a drawable/recovery timer.
        // The source snapshot is still the first source-protocol read. No dirty
        // rows are consumed if acquisition fails. Use the actual target size.
        if let acquireDrawable {
            let size = try acquireDrawable()
            metrics = cmdy_gpu_frame_metrics(snapshot.rows, snapshot.cols, cellSize.width, cellSize.height, scale,
                bounds.width, bounds.height, size.width, size.height)
            guard metrics.valid != 0 else { throw ProducerCaptureFailure.invalidGeometry }
        }
        let foreground = source.nativeForegroundColor, background = source.nativeBackgroundColor, font = source.normalFont
        let underline = source.underlinePosition(), thickness = source.underlineThickness()
        let width = metrics.cell_width, height = metrics.cell_height
        let scroll = e.config.smooth_scroll ? SmoothScrollMotion.effectiveOffset(source: source.scrollContentOffset.y,
            held: e.motion.scroll_held, glide: e.motion.scroll_glide) : 0
        let fringeRows = SmoothScrollMotion.fringeRows(offset: scroll, cellHeight: height, enabled: e.config.smooth_scroll)
        let dirty = source.consumeDirtyRows()
        let selection = source as? any MetalSelectionRenderSource
        var frame = CmdyGpuFrame()
        frame.width = e.drawableSize.width; frame.height = e.drawableSize.height
        frame.scale = scale; frame.cell_width = width; frame.cell_height = height
        frame.top_inset = source.topContentInset; frame.bottom_inset = source.bottomContentInset; frame.left_inset = source.leftContentInset
        frame.content_x = source.contentXOrigin; frame.scroll_pixels = scroll; frame.image_scale = source.getImageScale()
        frame.grid_rows = snapshot.rows; frame.grid_cols = snapshot.cols; frame.display_top_row = snapshot.displayTopRow
        frame.cursor_source_row = snapshot.cursorRow; frame.cursor_col = snapshot.cursorCol
        let cursorRow = snapshot.independentDisplayRow(forSourceRow: snapshot.cursorRow)
        frame.cursor_display_row = cursorRow ?? 0; frame.cursor_valid = cursorRow == nil ? 0 : 1
        frame.cursor_style = snapshot.cursorStyle.gpuValue; frame.cursor_hidden = snapshot.cursorHidden ? 1 : 0
        frame.host_cursor_hidden = e.config.host_cursor_hidden ? 1 : 0; frame.caret_focused = source.caretFocused ? 1 : 0
        frame.smooth_cursor = e.config.smooth_cursor ? 1 : 0; frame.live_resize = e.liveResize ? 1 : 0
        frame.cursor_speed = e.config.cursor_speed; frame.cursor_max_distance = e.config.cursor_max_distance
        frame.cursor_natural_height = MetalTerminalRenderer.cursorHeightPixels(cellHeight: metrics.cursor_cell_height, font: font as CTFont, scale: scale)
        frame.underline_thickness = thickness
        frame.background = CmdyRenderColor(IndependentRowRasterizer.rgba(background))
        frame.selection = CmdyRenderColor(IndependentRowRasterizer.rgba(selection?.selectionBackgroundColor ?? .selectedTextBackgroundColor))
        frame.caret = CmdyRenderColor(IndependentRowRasterizer.rgba(source.caretColor))
        frame.caret_text = CmdyRenderColor(IndependentRowRasterizer.rgba(source.caretTextColor ?? background))
        frame.now = e.now; frame.activity_keypress_time = source.activityKeypressTime; frame.typing_rate = source.activityTypingRate
        frame.shader_mode = Int32(clamping: e.config.shader_mode); frame.shader_energy = e.motion.envelope_energy; frame.shader_velocity = e.motion.envelope_velocity
        let publicationKey = publication == 0 ? nil : PublishedFrameKey(revision: publication,
            rows: snapshot.rows, cols: snapshot.cols, bufferLineCount: snapshot.bufferLineCount,
            retainedRowOrigin: snapshot.retainedRowOrigin, displayTopRow: snapshot.displayTopRow,
            liveTopRow: snapshot.liveTopRow, alternateBuffer: snapshot.isAlternateBuffer,
            fringeRows: fringeRows, rowWidth: metrics.row_width, rowHeight: metrics.row_height,
            cellWidth: width, cellHeight: height, scale: scale, preset: e.preset)
        if let publicationKey, publicationKey == capturedPublication, dirty == nil,
           let previous = capturedFrame {
            // No row requests, scaled font, per-row source calls or cache-array
            // traversal are needed for an unchanged image-free publication.
            requestedRows = capturedRows.count
            let assemblyStarted = tracing ? RendererPerformanceTrace.now() : 0
            var input = Self.metadata(identity: e.identity, snapshot: snapshot, frame: frame)
            let captured = try previous.reusingContent(&input).get()
            guard publishedSource?.frameContentRevision == publication,
                  expectedGeneration == generation else { throw ProducerCaptureFailure.invalidated }
            capturedFrame = captured
            capturedRowCount = requestedRows
            succeeded = true
            if tracing {
                RendererPerformanceTrace.record(event: "capture.assemble", started: assemblyStarted,
                    fields: ["surface": Int(clamping: e.identity.surface), "sequence": Int(clamping: e.identity.sequence),
                             "rows": requestedRows, "reusedContent": 1, "reusedPublication": 1])
            }
            return ProducedFrame(input: captured,
                cursorBlinkEligible: MetalTerminalRenderer.cursorBlinkEligible(snapshot: snapshot, hostCursorHidden: e.config.host_cursor_hidden),
                renderedScrollPoints: SmoothScrollTranslation(offsetPixels: scroll, scale: scale).renderedPoints)
        }
        var nextRows = rows
        var nextImages = images
        guard let fontPointer = cmdy_gpu_scaled_font(Unmanaged.passUnretained(font).toOpaque(), scale) else {
            throw ProducerCaptureFailure.invalidGeometry
        }
        let scaledFont = Unmanaged<NSFont>.fromOpaque(fontPointer).takeRetainedValue()
        let raster = IndependentRowRasterInputs(cellWidth: width, cellHeight: height, scale: scale,
            normalFont: scaledFont, foreground: IndependentRowRasterizer.rgba(foreground),
            underlinePosition: underline, underlineThickness: thickness)
        if let nativeSource = source as? any NativeViewportRenderSource {
            let viewport = try nativeSource.nativeFrameViewport()
            let graphics = nativeSource.nativeFrameGraphics()
            let key = IndependentRowKey(absoluteRow: 0, version: 0, lineMode: .single,
                cols: snapshot.cols, widthPx: metrics.row_width, heightPx: metrics.row_height,
                scaleBits: Double(scale).bitPattern, fontName: font.fontName, fontSizeBits: Double(font.pointSize).bitPattern,
                alternateBuffer: snapshot.isAlternateBuffer, kittyStamp: source.kittyStamp,
                foreground: IndependentRowRasterizer.packedColor(foreground), background: IndependentRowRasterizer.packedColor(background),
                preset: e.preset, antialiasBlocks: source.antiAliasCustomBlockGlyphs, bufferingMode: source.metalBufferingMode)
            let parameters = NativeRowCaptureParameters(cols: snapshot.cols, width: metrics.row_width, height: metrics.row_height,
                cellWidth: width, cellHeight: height, scale: scale, font: scaledFont, foreground: foreground,
                underline: underline, thickness: thickness, preset: e.preset, antialias: key.antialiasBlocks)
            var metadata = Self.metadata(identity: e.identity, snapshot: snapshot, frame: frame)
            let captured = try CapturedFrameInput.capture(&metadata, viewport: viewport, key: key,
                fringeRows: fringeRows, parameters: parameters, graphics: graphics)
            guard expectedGeneration == generation,
                  publishedSource == nil || publishedSource?.frameContentRevision == publication else {
                throw ProducerCaptureFailure.invalidated
            }
            // Only the render owner retains row/image caches for this path.
            rows.removeAll(keepingCapacity: true); images.removeAll(keepingCapacity: true)
            capturedRows.removeAll(keepingCapacity: true); capturedPlacements.removeAll(keepingCapacity: true)
            capturedFrame = nil; capturedPublication = nil; capturedWithoutGlobalKitty = false
            // Pure range arithmetic: no row enumeration or buffer reads.
            requestedRows = cmdy_render_visible_rows(Int64(snapshot.rows), Int64(snapshot.bufferLineCount),
                Int64(snapshot.displayTopRow), Int64(snapshot.retainedRowOrigin), Int64(fringeRows), nil, 0)
            capturedRowCount = requestedRows
            succeeded = true
            return ProducedFrame(input: captured,
                cursorBlinkEligible: MetalTerminalRenderer.cursorBlinkEligible(snapshot: snapshot, hostCursorHidden: e.config.host_cursor_hidden),
                renderedScrollPoints: SmoothScrollTranslation(offsetPixels: scroll, scale: scale).renderedPoints)
        }
        let requests = snapshot.independentVisibleRowRequests(extraRows: fringeRows)
        requestedRows = requests.count
        let revisionSource = source as? any SnapshotRowRevisionSource
        let deferredSource = source as? any DeferredRowRenderSource
        let stamp = source.kittyStamp, antialias = source.antiAliasCustomBlockGlyphs, buffering = source.metalBufferingMode
        // Freeze shared platform values only when a changed deferred row needs
        // them. Cache-only/selection frames and general sources need no packet.
        var nativeParameters: NativeRowCaptureParameters?
        // Keep the previous immutable arrays until a row or placement actually
        // changes. Local values retain their storage even if a source callback
        // invalidates the producer while the frame is being captured.
        var content = capturedRows
        var placements = capturedPlacements
        var unchangedRowSequence = content.count == requests.count && placements.count == requests.count
        if !unchangedRowSequence {
            content = []; placements = []
            content.reserveCapacity(requests.count); placements.reserveCapacity(requests.count)
        }
        // These cache-key values belong to the captured frame. Resolve them
        // once here; refresh on every capture so font/appearance changes still
        // invalidate rows, including for general sources using lineInfo.
        let scaleBits = Double(scale).bitPattern
        let fontName = font.fontName, fontSizeBits = Double(font.pointSize).bitPattern
        let foregroundKey = IndependentRowRasterizer.packedColor(foreground)
        let backgroundKey = IndependentRowRasterizer.packedColor(background)
        for (index, request) in requests.enumerated() {
            let mode = source.lineRenderMode(forRow: request.sourceRow)
            let key = IndependentRowKey(absoluteRow: request.cacheRow, version: source.lineVersion(forRow: request.sourceRow),
                lineMode: mode, cols: snapshot.cols, widthPx: metrics.row_width, heightPx: metrics.row_height,
                scaleBits: scaleBits, fontName: fontName, fontSizeBits: fontSizeBits,
                alternateBuffer: snapshot.isAlternateBuffer, kittyStamp: stamp,
                foreground: foregroundKey, background: backgroundKey,
                preset: e.preset, antialiasBlocks: antialias, bufferingMode: buffering)
            var row = nextRows[key.absoluteRow]
            var evidence: SnapshotRowRevision?
            var reusable = row?.key == key && row?.raster == raster && key.version != 0
            if reusable && dirty?.contains(request.sourceRow) == true {
                evidence = revisionSource?.snapshotRowRevision(forRow: request.sourceRow)
                reusable = row!.revisionReusable && evidence?.content == key.version && evidence?.context != 0
                    && evidence != nil && row!.revision == evidence
            }
            if !reusable {
                rebuiltRows += 1
                if evidence == nil { evidence = revisionSource?.snapshotRowRevision(forRow: request.sourceRow) }
                let text: CapturedRowInput
                let imageOwners: [any RenderableCellImage]
                let placeholders: [CmdyGpuPlaceholder]
                let revisionReusable: Bool?
                let deferredStarted = tracing ? RendererPerformanceTrace.now() : 0
                let deferred: DeferredRenderRow?
                do {
                    if let deferredSource {
                        if nativeParameters == nil {
                            nativeParameters = NativeRowCaptureParameters(cols: snapshot.cols,
                                width: metrics.row_width, height: metrics.row_height, cellWidth: width,
                                cellHeight: height, scale: scale, font: scaledFont, foreground: foreground,
                                underline: underline, thickness: thickness, preset: e.preset, antialias: antialias)
                        }
                        deferred = try deferredSource.deferredRenderRow(forRow: request.sourceRow, parameters: nativeParameters!)
                    } else { deferred = nil }
                } catch { throw ProducerCaptureFailure.deferredRow(request.sourceRow, error) }
                if let deferred {
                    text = deferred.text; imageOwners = deferred.images
                    placeholders = [] // Decoded from the frozen row by the Zig owner.
                    // Eligibility is published with worker-prepared text. Keep
                    // querying that owned input instead of caching an initial
                    // conservative false for the lifetime of this row.
                    revisionReusable = nil
                    if tracing {
                        RendererPerformanceTrace.record(event: "capture.deferredRow", started: deferredStarted,
                            fields: ["surface": Int(clamping: e.identity.surface), "sequence": Int(clamping: e.identity.sequence),
                                     "row": request.sourceRow])
                    }
                } else {
                    let shapingStarted = tracing ? RendererPerformanceTrace.now() : 0
                    let info = source.lineInfo(forRow: request.sourceRow)
                    if tracing {
                        RendererPerformanceTrace.record(event: "capture.lineInfo", started: shapingStarted,
                            fields: ["surface": Int(clamping: e.identity.surface), "sequence": Int(clamping: e.identity.sequence),
                                     "row": request.sourceRow, "segments": info.segments.count])
                    }
                    let inputStarted = tracing ? RendererPerformanceTrace.now() : 0
                    do {
                        text = try IndependentRowRasterizer.captureNativeInput(info: info, cols: key.cols,
                            width: key.widthPx, height: key.heightPx, cellWidth: width, cellHeight: height, scale: scale,
                            normalFont: scaledFont, nativeForeground: foreground, underlinePosition: underline,
                            underlineThickness: thickness, preset: e.preset, antialiasBlocks: antialias).get()
                    } catch { throw ProducerCaptureFailure.row(request.sourceRow, error) }
                    if tracing {
                        RendererPerformanceTrace.record(event: "capture.rowInput", started: inputStarted,
                            fields: ["surface": Int(clamping: e.identity.surface), "sequence": Int(clamping: e.identity.sequence),
                                     "row": request.sourceRow])
                    }
                    imageOwners = info.images ?? []
                    placeholders = info.kittyPlaceholders.map { $0.gpuValue }
                    revisionReusable = imageOwners.isEmpty && placeholders.isEmpty
                        && info.blockElements.isEmpty && info.boxDrawings.isEmpty
                }
                var rowImages: [(identity: UUID, input: CapturedImageInput, placement: CmdyGpuImagePlacement)] = []
                for owner in imageOwners {
                    guard let encoded = owner as? any EncodedRenderableCellImage else {
                        throw ProducerCaptureFailure.unsupportedImage(request.sourceRow)
                    }
                    let identity = encoded.renderIdentity
                    let image: CapturedImageInput
                    if let cached = nextImages[identity] { image = cached.input }
                    else {
                        do { image = try Self.captureImage(identity: identity, payload: encoded.encodedPayload) }
                        catch let error as FrameInputCaptureFailure { throw ProducerCaptureFailure.image(request.sourceRow, error) }
                    }
                    nextImages[identity] = (image, tick)
                    rowImages.append((identity, image, CmdyGpuImagePlacement(owner: nil, image: nil,
                        col: owner.col, z_index: owner.kittyZIndex, width: owner.pixelWidth, height: owner.pixelHeight,
                        offset_x: owner.kittyPixelOffsetX, offset_y: owner.kittyPixelOffsetY,
                        kitty_image_id: owner.kittyImageId ?? 0, has_kitty_id: owner.kittyImageId == nil ? 0 : 1,
                        is_kitty: owner.kittyIsKitty ? 1 : 0, owned_image: nil)))
                }
                row = try ProducerRow(key: key, raster: raster, revision: evidence, text: text,
                    images: rowImages, placeholders: placeholders, revisionReusable: revisionReusable,
                    lastUse: tick)
                // An unchanged entry already points at this same immutable
                // row. Reassigning it would copy the shared cache dictionary.
                nextRows[key.absoluteRow] = row!
            }
            row!.lastUse = tick
            for image in row!.images { nextImages[image.identity] = (image.input, tick) }
            let columns = selection?.selectionColumns(forRow: request.sourceRow)
            let placement = CmdyGpuFrameRow(entry: nil, display_index: request.displayIndex, source_row: request.sourceRow,
                line_mode: mode.gpuValue, selection_lower: columns?.lowerBound ?? 0, selection_upper: columns?.upperBound ?? 0,
                has_selection: columns == nil ? 0 : 1)
            if unchangedRowSequence && (content[index] !== row! || !Self.samePlacement(placements[index], placement)) {
                // Copy the already-validated prefix once, then append the
                // changed suffix without mutating storage held by old frames.
                var changedContent: [ProducerRow] = []
                var changedPlacements: [CmdyGpuFrameRow] = []
                changedContent.reserveCapacity(requests.count)
                changedPlacements.reserveCapacity(requests.count)
                changedContent.append(contentsOf: content.prefix(index))
                changedPlacements.append(contentsOf: placements.prefix(index))
                content = changedContent; placements = changedPlacements
                unchangedRowSequence = false
            }
            if !unchangedRowSequence {
                content.append(row!); placements.append(placement)
            }
        }
        let graphicsSource = source as? any NativeGraphicsRenderSource
        let nativeGraphics = graphicsSource?.nativeFrameGraphics()
        // The normal app publishes these from the model owner. Its frozen
        // native payloads and metadata are retained directly by the frame.
        // General sources keep the existing copying contract below.
        let liveIds = graphicsSource == nil ? Array(source.kittyLiveImageIds) : []
        let kittyPlacements = graphicsSource == nil ? source.kittyVirtualPlacements(alternateBuffer: snapshot.isAlternateBuffer).map {
            CmdyGpuKittyPlacement(image_id: $0.imageId, placement_id: $0.placementId, cols: $0.cols, rows: $0.rows, offset_x: $0.pixelOffsetX, offset_y: $0.pixelOffsetY)
        } : []
        var kittyStorage: [UInt8] = []
        var kittyOffsets: [Int] = []
        var kittyImages: [CmdyGpuKittyImage] = []
        for id in liveIds {
            guard let payload = source.kittyImagePayload(imageId: id) else { continue }
            kittyOffsets.append(kittyStorage.count)
            switch payload {
            case .png(let data):
                kittyImages.append(CmdyGpuKittyImage(image_id: id, kind: 0, bytes: nil, byte_count: data.count, width: 0, height: 0))
                kittyStorage.append(contentsOf: data)
            case .rgba(let bytes, let w, let h):
                kittyImages.append(CmdyGpuKittyImage(image_id: id, kind: 1, bytes: nil, byte_count: bytes.count, width: w, height: h))
                kittyStorage.append(contentsOf: bytes)
            }
        }
        let assemblyStarted = tracing ? RendererPerformanceTrace.now() : 0
        let withoutGlobalKitty = nativeGraphics?.isEmpty(alternate: snapshot.isAlternateBuffer)
            ?? (kittyImages.isEmpty && kittyPlacements.isEmpty && liveIds.isEmpty)
        let captured: CapturedFrameInput
        let reusedContent: Bool
        if let previous = capturedFrame, withoutGlobalKitty, capturedWithoutGlobalKitty,
           unchangedRowSequence {
            // All borrowed array/target fields remain zero here. In addition to
            // row identity, compare placement and selection on every capture.
            var input = Self.metadata(identity: e.identity, snapshot: snapshot, frame: frame)
            captured = try previous.reusingContent(&input).get()
            reusedContent = true
        } else if let nativeGraphics {
            captured = try Self.assemble(identity: e.identity, snapshot: snapshot, frame: frame,
                content: content, placements: placements, graphics: nativeGraphics)
            reusedContent = false
        } else {
            captured = try kittyStorage.withUnsafeBufferPointer { bytes in
                for index in kittyImages.indices { kittyImages[index].bytes = bytes.baseAddress?.advanced(by: kittyOffsets[index]) }
                return try kittyImages.withUnsafeBufferPointer { images in
                    try kittyPlacements.withUnsafeBufferPointer { nativePlacements in
                        try liveIds.withUnsafeBufferPointer { ids in
                            frame.kitty_images = images.baseAddress; frame.kitty_image_count = images.count
                            frame.kitty_placements = nativePlacements.baseAddress; frame.kitty_placement_count = nativePlacements.count
                            frame.live_kitty_ids = ids.baseAddress; frame.live_kitty_count = ids.count
                            return try Self.assemble(identity: e.identity, snapshot: snapshot, frame: frame, content: content, placements: placements)
                        }
                    }
                }
            }
            reusedContent = false
        }
        if tracing {
            RendererPerformanceTrace.record(event: "capture.assemble", started: assemblyStarted,
                fields: ["surface": Int(clamping: e.identity.surface), "sequence": Int(clamping: e.identity.sequence),
                         "rows": requests.count, "reusedContent": reusedContent ? 1 : 0])
        }
        if publication != 0, publishedSource?.frameContentRevision != publication {
            throw ProducerCaptureFailure.invalidated
        }
        guard expectedGeneration == generation else { throw ProducerCaptureFailure.invalidated }
        let (tripled, overflow) = requests.count.multipliedReportingOverflow(by: 3)
        let rowLimit = overflow ? Int.max : max(1, tripled)
        if nextRows.count > rowLimit {
            let expired = nextRows.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(nextRows.count - rowLimit)
            for (key, _) in expired { nextRows.removeValue(forKey: key) }
        }
        if nextImages.count > 512 {
            let expired = nextImages.sorted { $0.value.used < $1.value.used }.prefix(nextImages.count - 512)
            for (key, _) in expired { nextImages.removeValue(forKey: key) }
        }
        rows = nextRows; images = nextImages
        capturedFrame = captured; capturedRows = content; capturedPlacements = placements
        capturedWithoutGlobalKitty = withoutGlobalKitty
        // External image objects can be mutable. Keep graphics on the existing
        // validated path even when a source provides a publication revision.
        capturedPublication = withoutGlobalKitty && content.allSatisfy({ $0.revisionReusable && $0.images.isEmpty && $0.placeholders.isEmpty })
            ? publicationKey : nil
        capturedRowCount = requestedRows
        succeeded = true
        return ProducedFrame(input: captured,
            cursorBlinkEligible: MetalTerminalRenderer.cursorBlinkEligible(snapshot: snapshot, hostCursorHidden: e.config.host_cursor_hidden),
            renderedScrollPoints: SmoothScrollTranslation(offsetPixels: scroll, scale: scale).renderedPoints)
    }

    private static func samePlacement(_ current: CmdyGpuFrameRow, _ previous: CmdyGpuFrameRow) -> Bool {
        current.entry == previous.entry && current.display_index == previous.display_index
            && current.source_row == previous.source_row && current.line_mode == previous.line_mode
            && current.selection_lower == previous.selection_lower
            && current.selection_upper == previous.selection_upper
            && current.has_selection == previous.has_selection
    }

    private static func metadata(identity: CmdyRenderFrameIdentity, snapshot: GridSnapshot,
                                 frame: CmdyGpuFrame) -> CmdyRenderFrameInput {
        var input = CmdyRenderFrameInput()
        input.identity = identity; input.parameters = frame
        input.buffer_line_count = snapshot.bufferLineCount; input.retained_row_origin = snapshot.retainedRowOrigin
        input.live_top_row = snapshot.liveTopRow; input.alternate_buffer = snapshot.isAlternateBuffer ? 1 : 0
        return input
    }

    private static func captureImage(identity: UUID, payload: KittyImagePayload) throws -> CapturedImageInput {
        var input = CmdyRenderImageInput()
        var uuid = identity.uuid
        withUnsafeMutableBytes(of: &input.identity) { out in withUnsafeBytes(of: &uuid) { out.copyBytes(from: $0) } }
        switch payload {
        case .png(let data):
            return try data.withUnsafeBytes { bytes in
                input.kind = 0; input.bytes = bytes.bindMemory(to: UInt8.self).baseAddress; input.byte_count = bytes.count
                return try CapturedImageInput.capture(&input).get()
            }
        case .rgba(let bytes, let width, let height):
            return try bytes.withUnsafeBufferPointer { buffer in
                input.kind = 1; input.width = width; input.height = height; input.bytes = buffer.baseAddress; input.byte_count = buffer.count
                return try CapturedImageInput.capture(&input).get()
            }
        }
    }

    private static func assemble(identity: CmdyRenderFrameIdentity, snapshot: GridSnapshot, frame: CmdyGpuFrame,
                                 content: [ProducerRow], placements: [CmdyGpuFrameRow],
                                 graphics: NativeFrameGraphics? = nil) throws -> CapturedFrameInput {
        let references = zip(content, placements).map { row, placement in
            CmdyRenderFrameRowReference(
                row: row.descriptor.withUnsafeNativeHandle { cmdy_render_frame_row_retain($0)! },
                placement: placement)
        }
        // Own these references across Swift pointer loans; native capture takes
        // its own references. Complete row-view assembly happens on the worker.
        defer { for reference in references { cmdy_render_frame_row_release(reference.row) } }
        return try references.withUnsafeBufferPointer { rows in
            var input = Self.metadata(identity: identity, snapshot: snapshot, frame: frame)
            return try CapturedFrameInput.capture(&input, references: rows, graphics: graphics).get()
        }
    }
}

/// Diagnostic access to the actual producer algorithm. No target, GPU cache or
/// drawing is involved, so durations attribute capture work only.
@_spi(CmdyApp)
@MainActor
public final class ProducerFrameCaptureProbe {
    private let producer = ProducerFrameCapture()
    public init() {}
    public func capture(source: any MetalRenderSource, surface: UInt64, sequence: UInt64,
                        drawableSize: CGSize) throws -> Int {
        let frame = try producer.capture(source: source, environment: ProducerFrameEnvironment(
            identity: .init(surface: surface, epoch: 1, sequence: sequence), drawableSize: drawableSize,
            config: cmdy_render_schedule_default_config(), motion: .init(), preset: .current,
            liveResize: false, now: ProcessInfo.processInfo.systemUptime))
        return withExtendedLifetime(frame) { producer.capturedRowCount }
    }
}
