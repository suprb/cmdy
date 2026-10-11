import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal
import CmdyNative

// These utilities remain as small, isolated compatibility/test seams. The
// independent compositor does not use a glyph atlas or cell-batched geometry.

struct MetalBufferSlice {
    public let buffer: MTLBuffer
    public let offset: Int

    public init(buffer: MTLBuffer, offset: Int) {
        self.buffer = buffer
        self.offset = offset
    }
}

enum GlyphAtlasFormat: Hashable, Sendable {
    case grayscale
    case bgra

    public var bytesPerPixel: Int { self == .grayscale ? 1 : 4 }
    public var pixelFormat: MTLPixelFormat {
        self == .grayscale ? .r8Unorm : .bgra8Unorm
    }
}

struct AtlasRegion: Sendable {
    public let page: Int
    public let generation: UInt64
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(page: Int, generation: UInt64, x: Int, y: Int,
                width: Int, height: Int) {
        self.page = page
        self.generation = generation
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

struct GlyphBitmap: Sendable {
    public let width: Int
    public let height: Int
    public let bearing: CGPoint
    public let pixels: [UInt8]
    public let isColor: Bool

    public init(width: Int, height: Int, bearing: CGPoint,
                pixels: [UInt8], isColor: Bool) {
        self.width = width
        self.height = height
        self.bearing = bearing
        self.pixels = pixels
        self.isColor = isColor
    }
}

struct FrozenLineAtlasRegion {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

enum GlyphAtlasKind: Hashable, Sendable {
    case grayscale
    case color
}

struct GlyphEntry: Sendable {
    public let region: AtlasRegion
    public let size: CGSize
    public let bearing: CGPoint
    public let isColor: Bool
    public let atlasKind: GlyphAtlasKind

    public init(region: AtlasRegion, size: CGSize, bearing: CGPoint,
                isColor: Bool, atlasKind: GlyphAtlasKind) {
        self.region = region
        self.size = size
        self.bearing = bearing
        self.isColor = isColor
        self.atlasKind = atlasKind
    }
}

struct GlyphVertex {
    public var position: SIMD2<Float>
    public var texCoord: SIMD2<Float>
    public var color: SIMD4<Float>
    public var atlasPage: UInt32

    public init(position: SIMD2<Float>, texCoord: SIMD2<Float>,
                color: SIMD4<Float>, atlasPage: UInt32) {
        self.position = position
        self.texCoord = texCoord
        self.color = color
        self.atlasPage = atlasPage
    }
}

struct TextCell {
    public var position: SIMD2<Float>
    public var size: SIMD2<Float>
    public var texOrigin: SIMD2<Float>
    public var texSize: SIMD2<Float>
    public var color: SIMD4<Float>
    public var atlasPage: UInt32

    public init(position: SIMD2<Float>, size: SIMD2<Float>,
                texOrigin: SIMD2<Float>, texSize: SIMD2<Float>,
                color: SIMD4<Float>, atlasPage: UInt32) {
        self.position = position
        self.size = size
        self.texOrigin = texOrigin
        self.texSize = texSize
        self.color = color
        self.atlasPage = atlasPage
    }
}

final class DynamicBufferRing {
    private let handle: OpaquePointer
    public var allocationCount: Int { cmdy_render_buffer_ring_allocations(handle) }
    public init(device: MTLDevice, frameCount: Int = 3,
                minimumPageSize: Int = 256 * 1_024, alignment: Int = 256) {
        handle = cmdy_render_buffer_ring_create(Unmanaged.passUnretained(device as AnyObject).toOpaque(),
                                                max(1, frameCount), max(256, minimumPageSize), max(256, alignment))!
    }
    deinit { cmdy_render_buffer_ring_free(handle) }
    public func beginFrame() { cmdy_render_buffer_ring_begin(handle) }
    public func write<T>(_ values: [T]) -> MetalBufferSlice? {
        values.withUnsafeBytes { bytes in
            var offset = 0
            guard let pointer = cmdy_render_buffer_ring_write(handle, bytes.baseAddress, bytes.count, &offset) else { return nil }
            let buffer = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as! MTLBuffer
            return MetalBufferSlice(buffer: buffer, offset: offset)
        }
    }
}

final class GlyphAtlas {
    private let handle: OpaquePointer
    public let size: Int
    public let texture: MTLTexture
    public var evictedPage: Int? { let page = cmdy_render_atlas_evicted_page(handle); return page < 0 ? nil : page }
    public init?(device: MTLDevice, size: Int = 1_024, maxPages: Int = 4, format: GlyphAtlasFormat = .grayscale) {
        guard let handle = cmdy_render_atlas_create(Unmanaged.passUnretained(device as AnyObject).toOpaque(),
                                                    size, maxPages, format == .bgra ? 1 : 0, 0),
              let pointer = cmdy_render_atlas_texture(handle) else { return nil }
        self.handle = handle; self.size = size
        texture = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as! MTLTexture
    }
    deinit { cmdy_render_atlas_free(handle) }
    public func generation(forPage page: Int) -> UInt64 { cmdy_render_atlas_generation(handle, page) }
    public func touch(page: Int) { cmdy_render_atlas_touch(handle, page) }
    public func ensureRegion(width: Int, height: Int) -> AtlasRegion? {
        var region = CmdyRenderAtlasRegion()
        guard cmdy_render_atlas_region(handle, width, height, &region) != 0 else { return nil }
        return AtlasRegion(page: region.page, generation: region.generation, x: region.x, y: region.y,
                           width: region.width, height: region.height)
    }
    public func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int, padding: Int = 0) {
        var value = CmdyRenderAtlasRegion(page: region.page, x: region.x, y: region.y,
                                         width: region.width, height: region.height, generation: region.generation)
        pixels.withUnsafeBufferPointer { bytes in
            cmdy_render_atlas_write(handle, &value, bytes.baseAddress, bytes.count, width, height, padding)
        }
    }
}

final class CoreTextGlyphRasterizer {
    public init() {}
    public func hasVisibleBounds(font: CTFont, glyph: CGGlyph) -> Bool {
        cmdy_render_glyph_has_bounds(Unmanaged.passUnretained(font).toOpaque(), glyph) != 0
    }
    public func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphBitmap? {
        guard let handle = cmdy_render_glyph_rasterize(Unmanaged.passUnretained(font).toOpaque(), glyph) else { return nil }
        defer { cmdy_render_glyph_bitmap_free(handle) }
        var view = CmdyRenderGlyphBitmapView()
        cmdy_render_glyph_bitmap_view(handle, &view)
        return GlyphBitmap(width: view.width, height: view.height,
                           bearing: CGPoint(x: view.bearing_x, y: view.bearing_y),
                           pixels: Array(UnsafeBufferPointer(start: view.bytes, count: view.byte_count)), isColor: view.is_color != 0)
    }
}

final class FrozenLineModeGlyphAtlas {
    private let handle: OpaquePointer
    let size = 1_024
    let texture: MTLTexture
    init?(device: MTLDevice) {
        guard let handle = cmdy_render_atlas_create(Unmanaged.passUnretained(device as AnyObject).toOpaque(), 1_024, 1, 0, 1),
              let pointer = cmdy_render_atlas_texture(handle) else { return nil }
        self.handle = handle
        texture = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as! MTLTexture
    }
    deinit { cmdy_render_atlas_free(handle) }
    func insert(_ bitmap: GlyphBitmap, padding: Int) -> FrozenLineAtlasRegion? {
        bitmap.pixels.withUnsafeBufferPointer { pixels in
            var view = CmdyRenderGlyphBitmapView(width: bitmap.width, height: bitmap.height,
                                                 bearing_x: bitmap.bearing.x, bearing_y: bitmap.bearing.y,
                                                 bytes: pixels.baseAddress, byte_count: pixels.count,
                                                 is_color: bitmap.isColor ? 1 : 0)
            var region = CmdyRenderAtlasRegion()
            guard cmdy_render_atlas_insert_glyph(handle, &view, padding, &region) != 0 else { return nil }
            return FrozenLineAtlasRegion(x: region.x, y: region.y, width: region.width, height: region.height)
        }
    }
    func reserve(width: Int, height: Int) -> FrozenLineAtlasRegion? {
        var region = CmdyRenderAtlasRegion()
        guard cmdy_render_atlas_region(handle, width, height, &region) != 0 else { return nil }
        return FrozenLineAtlasRegion(x: region.x, y: region.y, width: region.width, height: region.height)
    }
}
