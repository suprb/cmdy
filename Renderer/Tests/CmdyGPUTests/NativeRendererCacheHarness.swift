import AppKit
import CoreText
import MetalKit
import CmdyNative
@_spi(CmdyApp) @testable import CmdyGPU

// Explicit native-cache unit fixture. App rendering uses RenderWorkerSession;
// owner-thread/cache lifetime integration is covered by the session/Metal tests.
private final class CacheGPUHandle: @unchecked Sendable {
    let value: OpaquePointer
    init(_ value: OpaquePointer) { self.value = value }
    deinit { cmdy_gpu_destroy(value) }
}
@MainActor
final class NativeRendererCacheHarness {
    private let handle: CacheGPUHandle
    var gpu: OpaquePointer { handle.value }
    init(view: MTKView, source: any MetalRenderSource) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { throw MetalError.deviceUnavailable }
        var error = [CChar](repeating: 0, count: 4096)
        guard let value = cmdy_gpu_create(Unmanaged.passUnretained(device as AnyObject).toOpaque(),
            UInt64(view.colorPixelFormat.rawValue), 1, ProcessInfo.processInfo.systemUptime, &error, error.count)
        else { throw MetalError.pipelineCreationFailed(String(cString: error)) }
        handle = CacheGPUHandle(value)
    }
    var textRenderingMode: TextRenderingMode = .current {
        didSet { cmdy_gpu_set_preset(gpu, textRenderingMode.gpuValue) }
    }
    func invalidateRowCache() { cmdy_gpu_rows_clear(gpu) }
    private func resolveNativeRow(key: IndependentRowKey, explicitlyDirty: Bool,
        info: () -> ViewLineInfo, revision: () -> SnapshotRowRevision?, scaledFont: NSFont, foreground: NSColor,
        underlinePosition: () -> CGFloat, underlineThickness: () -> CGFloat, cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat) -> OpaquePointer? {
        key.withGPUKey { nativeKey in
            if let cached = cmdy_gpu_row_lookup(gpu, nativeKey, explicitlyDirty ? 1 : 0, CmdyGpuRowRevision(), nil) { return cached }
            let revisionStarted = RendererPerformanceTrace.now()
            let evidence = revision()
            let token = CmdyGpuRowRevision(content: evidence?.content ?? 0, context: evidence?.context ?? 0)
            let underline = underlinePosition(), thickness = underlineThickness()
            let empty = ViewLineInfo(segments: [], images: nil)
            let cached = IndependentRowRasterizer.withNativeInput(info: empty, cols: key.cols, width: key.widthPx, height: key.heightPx,
                cellWidth: cellWidth, cellHeight: cellHeight, scale: scale, normalFont: scaledFont, nativeForeground: foreground,
                underlinePosition: underline, underlineThickness: thickness, preset: key.preset, antialiasBlocks: key.antialiasBlocks,
                { cmdy_gpu_row_lookup(gpu, nativeKey, 1, token, $0) })
            if evidence != nil {
                RendererPerformanceTrace.record(event: "row.snapshotRevision", started: revisionStarted, fields: ["row": key.absoluteRow, "reused": cached == nil ? 0 : 1])
            }
            if let cached { return cached }
            let infoStarted = RendererPerformanceTrace.now()
            let line = info()
            RendererPerformanceTrace.record(event: "row.info", started: infoStarted, fields: ["row": key.absoluteRow, "columns": key.cols, "explicitlyDirty": explicitlyDirty ? 1 : 0])
            let owners = line.images ?? []
            let imageObjects = owners.map { $0.image }
            let images = zip(owners, imageObjects).map { owner, image in CmdyGpuImagePlacement(owner: UnsafeRawPointer(Unmanaged.passUnretained(owner as AnyObject).toOpaque()), image: UnsafeRawPointer(Unmanaged.passUnretained(image).toOpaque()), col: owner.col, z_index: owner.kittyZIndex,
                width: owner.pixelWidth, height: owner.pixelHeight, offset_x: owner.kittyPixelOffsetX, offset_y: owner.kittyPixelOffsetY,
                kitty_image_id: owner.kittyImageId ?? 0, has_kitty_id: owner.kittyImageId == nil ? 0 : 1, is_kitty: owner.kittyIsKitty ? 1 : 0, cell_cols: 0, cell_rows: 0, source_x: 0, source_y: 0, source_width: 0, source_height: 0, owned_image: nil) }
            let placeholders = line.kittyPlaceholders.map { $0.gpuValue }
            return withExtendedLifetime(imageObjects) {
                images.withUnsafeBufferPointer { nativeImages in
                    placeholders.withUnsafeBufferPointer { nativePlaceholders in
                        IndependentRowRasterizer.withNativeInput(info: line, cols: key.cols, width: key.widthPx, height: key.heightPx,
                            cellWidth: cellWidth, cellHeight: cellHeight, scale: scale, normalFont: scaledFont, nativeForeground: foreground,
                            underlinePosition: underline, underlineThickness: thickness, preset: key.preset, antialiasBlocks: key.antialiasBlocks) {
                                cmdy_gpu_row_resolve(gpu, nativeKey, token, $0, nativeImages.baseAddress, nativeImages.count, nativePlaceholders.baseAddress, nativePlaceholders.count)
                            }
                    }
                }
            }
        }
    }

    // The existing test seams return value projections of real native state.
    func resolveRowEntry(key: IndependentRowKey, explicitlyDirty: Bool,
        info: @autoclosure () -> ViewLineInfo, revision: @autoclosure () -> SnapshotRowRevision? = nil,
        scaledFont: NSFont, foreground: NSColor, underlinePosition: @autoclosure () -> CGFloat,
        underlineThickness: @autoclosure () -> CGFloat, cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat) -> IndependentRowCacheEntry? {
        guard let native = resolveNativeRow(key: key, explicitlyDirty: explicitlyDirty, info: info, revision: revision,
            scaledFont: scaledFont, foreground: foreground, underlinePosition: underlinePosition, underlineThickness: underlineThickness,
            cellWidth: cellWidth, cellHeight: cellHeight, scale: scale) else { return nil }
        return projectRow(native, key: key)
    }
    private func projectRow(_ native: OpaquePointer, key: IndependentRowKey) -> IndependentRowCacheEntry {
        var value = CmdyGpuRowView(); cmdy_gpu_row_view(native, &value)
        let textKey = cmdy_gpu_row_text_key(native).map { IndependentSharedTextRowKey(nativeKey: $0, rowKey: key) }
        let revision = cmdy_gpu_row_revision(native)
        let images = nativeArray(value.images, value.image_count).compactMap { item -> IndependentRowImage? in
            guard let pointer = cmdy_gpu_weak_owner(item.owner), let owner = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? any RenderableCellImage else { return nil }
            return IndependentRowImage(image: WeakRenderableImage(owner), col: item.col, zIndex: item.z_index, pixelWidth: item.width, pixelHeight: item.height,
                pixelOffsetX: item.offset_x, pixelOffsetY: item.offset_y, kittyImageId: item.has_kitty_id == 0 ? nil : item.kitty_image_id, kittyIsKitty: item.is_kitty != 0)
        }
        return IndependentRowCacheEntry(key: key, sharedTextKey: textKey, snapshotRevision: revision.content == 0 ? nil : SnapshotRowRevision(content: revision.content, context: revision.context),
            coverageTexture: metalTexture(value.coverage_texture),
            colorLayers: nativeArray(value.color_layers, value.color_layer_count).map { IndependentColorLayer(texture: metalTexture($0.texture)!, rect: $0.rect.cgRect) },
            backgrounds: nativeArray(value.backgrounds, value.background_count).map { IndependentSolidRect(rect: $0.rect.cgRect, color: $0.color.simd) },
            tintSpans: nativeArray(value.tints, value.tint_count).map { IndependentTintSpan(rect: $0.rect.cgRect, glyphEnvelope: $0.has_envelope == 0 ? nil : $0.envelope.cgRect, replacedByAtlas: $0.replaced_by_atlas != 0, color: $0.color.simd) },
            atlasGlyphs: nativeArray(value.atlas_glyphs, value.atlas_glyph_count).map { IndependentAtlasGlyphDraw(rect: $0.rect.cgRect, atlasRect: $0.atlas_rect.cgRect, color: $0.color.simd) },
            decorations: nativeArray(value.decorations, value.decoration_count).map { IndependentSolidRect(rect: $0.rect.cgRect, color: $0.color.simd) },
            images: images, kittyPlaceholders: nativeArray(value.placeholders, value.placeholder_count).map { KittyPlaceholderCell(row: $0.row, col: $0.col, imageId: $0.image_id, placementId: $0.placement_id, placeholderRow: $0.placeholder_row, placeholderCol: $0.placeholder_col, msb: $0.msb) }, width: value.width, height: value.height, lastUse: value.last_use)
    }
    var rowCacheAllocatedBytes: Int { cmdy_gpu_rows_bytes(gpu) }
    var rowCacheAllocatedBytesForTesting: Int { rowCacheAllocatedBytes }
    var rowCacheCountForTesting: Int { cmdy_gpu_rows_count(gpu) }
    var rowCacheRowsForTesting: Set<Int> {
        var values = [Int](repeating: 0, count: cmdy_gpu_rows_keys(gpu, nil, 0))
        let count = values.withUnsafeMutableBufferPointer { cmdy_gpu_rows_keys(gpu, $0.baseAddress, $0.count) }
        return Set(values.prefix(count))
    }
    func replaceAndTrimRowCacheForTesting(_ entries: [Int: IndependentRowCacheEntry], visibleRows: Set<Int>, visibleCount: Int) {
        cmdy_gpu_rows_clear(gpu)
        for (row, entry) in entries { importRow(entry, at: row) }
        trimRowCacheForTesting(visibleRows: visibleRows, visibleCount: visibleCount)
    }
    func storeAndTrimRowCacheEntryForTesting(_ entry: IndependentRowCacheEntry, at row: Int, visibleRows: Set<Int>, visibleCount: Int) {
        importRow(entry, at: row); trimRowCacheForTesting(visibleRows: visibleRows, visibleCount: visibleCount)
    }
    func trimRowCacheForTesting(visibleRows: Set<Int>, visibleCount: Int) {
        Array(visibleRows).withUnsafeBufferPointer { cmdy_gpu_rows_trim(gpu, $0.baseAddress, $0.count, visibleCount) }
    }
    private func importRow(_ entry: IndependentRowCacheEntry, at row: Int) {
        let colors = entry.colorLayers.map { CmdyGpuColorLayer(texture: UnsafeRawPointer(Unmanaged.passUnretained($0.texture as AnyObject).toOpaque()), rect: CmdyRenderRect($0.rect)) }
        let backgrounds = entry.backgrounds.map { CmdyRenderSolid(rect: CmdyRenderRect($0.rect), color: CmdyRenderColor($0.color)) }
        let tints = entry.tintSpans.map { CmdyRenderTint(rect: CmdyRenderRect($0.rect), envelope: CmdyRenderRect($0.glyphEnvelope ?? .zero), color: CmdyRenderColor($0.color), has_envelope: $0.glyphEnvelope == nil ? 0 : 1, replaced_by_atlas: $0.replacedByAtlas ? 1 : 0) }
        let atlas = entry.atlasGlyphs.map { CmdyGpuAtlasGlyph(rect: CmdyRenderRect($0.rect), atlas_rect: CmdyRenderRect($0.atlasRect), color: CmdyRenderColor($0.color)) }
        let decorations = entry.decorations.map { CmdyRenderSolid(rect: CmdyRenderRect($0.rect), color: CmdyRenderColor($0.color)) }
        let placeholders = entry.kittyPlaceholders.map { $0.gpuValue }
        let owners = entry.images.compactMap { item -> (IndependentRowImage, any RenderableCellImage, NSImage)? in
            guard let owner = item.image.value else { return nil }
            return (item, owner, owner.image)
        }
        let images = owners.map { item, owner, image in CmdyGpuImagePlacement(
            owner: UnsafeRawPointer(Unmanaged.passUnretained(owner as AnyObject).toOpaque()), image: UnsafeRawPointer(Unmanaged.passUnretained(image).toOpaque()),
            col: item.col, z_index: item.zIndex, width: item.pixelWidth, height: item.pixelHeight, offset_x: item.pixelOffsetX, offset_y: item.pixelOffsetY,
            kitty_image_id: item.kittyImageId ?? 0, has_kitty_id: item.kittyImageId == nil ? 0 : 1, is_kitty: item.kittyIsKitty ? 1 : 0, cell_cols: 0, cell_rows: 0, source_x: 0, source_y: 0, source_width: 0, source_height: 0, owned_image: nil) }
        withExtendedLifetime(owners) { images.withUnsafeBufferPointer { imageBuffer in entry.key.withGPUKey { key in
            var cacheKey = key.pointee; cacheKey.absolute_row = row
            colors.withUnsafeBufferPointer { colorBuffer in backgrounds.withUnsafeBufferPointer { backgroundBuffer in tints.withUnsafeBufferPointer { tintBuffer in atlas.withUnsafeBufferPointer { atlasBuffer in decorations.withUnsafeBufferPointer { decorationBuffer in placeholders.withUnsafeBufferPointer { placeholderBuffer in
                var value = CmdyGpuRowView()
                value.coverage_texture = entry.coverageTexture.map { UnsafeRawPointer(Unmanaged.passUnretained($0 as AnyObject).toOpaque()) }
                value.color_layers = colorBuffer.baseAddress; value.color_layer_count = colorBuffer.count
                value.backgrounds = backgroundBuffer.baseAddress; value.background_count = backgroundBuffer.count
                value.tints = tintBuffer.baseAddress; value.tint_count = tintBuffer.count
                value.atlas_glyphs = atlasBuffer.baseAddress; value.atlas_glyph_count = atlasBuffer.count
                value.decorations = decorationBuffer.baseAddress; value.decoration_count = decorationBuffer.count
                value.placeholders = placeholderBuffer.baseAddress; value.placeholder_count = placeholderBuffer.count
                value.images = imageBuffer.baseAddress; value.image_count = imageBuffer.count
                value.width = entry.width; value.height = entry.height; value.last_use = entry.lastUse
                _ = cmdy_gpu_row_import(gpu, &cacheKey, &value)
            } } } } } }
        } } }
    }
    func textureForTesting(_ image: any RenderableCellImage) -> MTLTexture? {
        let native = image.image
        return withExtendedLifetime(native) { metalTexture(cmdy_gpu_image_texture(gpu, Unmanaged.passUnretained(image as AnyObject).toOpaque(), Unmanaged.passUnretained(native).toOpaque())) }
    }
    var imageDecodeAttemptsForTesting: Int { cmdy_gpu_image_attempts(gpu) }
    var imageDecodePendingCountForTesting: Int { cmdy_gpu_image_pending(gpu) }
    var colorAtlasAllocationCount: Int { cmdy_gpu_color_atlas_allocations(gpu) }
    var colorAtlasPageCapacityForTesting: Int? { let count = cmdy_gpu_color_atlas_capacity(gpu); return count == 0 ? nil : count }
    func cacheGlyphForTesting(font: CTFont, glyph: CGGlyph) -> GlyphEntry? {
        var value = CmdyGpuGlyphEntry()
        guard cmdy_gpu_cache_glyph(gpu, Unmanaged.passUnretained(font).toOpaque(), glyph, &value) != 0 else { return nil }
        return GlyphEntry(region: AtlasRegion(page: value.page, generation: value.generation, x: value.x, y: value.y, width: value.width, height: value.height),
            size: CGSize(width: value.bitmap_width, height: value.bitmap_height), bearing: CGPoint(x: value.bearing_x, y: value.bearing_y),
            isColor: value.is_color != 0, atlasKind: value.is_color == 0 ? .grayscale : .color)
    }

}
private func nativeArray<T>(_ pointer: UnsafePointer<T>?, _ count: Int) -> [T] {
    guard count > 0, let pointer else { return [] }
    return Array(UnsafeBufferPointer(start: pointer, count: count))
}
private func metalTexture(_ pointer: UnsafeRawPointer?) -> MTLTexture? {
    pointer.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! MTLTexture }
}
