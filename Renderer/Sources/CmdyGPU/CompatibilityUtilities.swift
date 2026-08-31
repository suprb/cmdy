import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal

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

final class DynamicBufferRing {
    private struct Arena {
        var buffer: MTLBuffer?
        var offset = 0
    }

    private let device: MTLDevice
    private let alignment: Int
    private let minimumPageSize: Int
    private var arenas: [Arena]
    private var activeIndex = -1
    public private(set) var allocationCount = 0

    public init(device: MTLDevice,
                frameCount: Int = 3,
                minimumPageSize: Int = 256 * 1_024,
                alignment: Int = 256) {
        self.device = device
        self.minimumPageSize = max(256, minimumPageSize)
        self.alignment = max(256, alignment)
        arenas = Array(repeating: Arena(), count: max(1, frameCount))
    }

    public func beginFrame() {
        activeIndex = (activeIndex + 1) % arenas.count
        arenas[activeIndex].offset = 0
    }

    public func write<T>(_ values: [T]) -> MetalBufferSlice? {
        if activeIndex < 0 { beginFrame() }
        let byteCount = values.count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
        guard !byteCount.overflow else { return nil }
        let size = byteCount.partialValue
        let alignedOffset = align(arenas[activeIndex].offset)
        let required = alignedOffset.addingReportingOverflow(size)
        guard !required.overflow else { return nil }

        if arenas[activeIndex].buffer == nil
            || required.partialValue > arenas[activeIndex].buffer!.length {
            let capacity = growCapacity(for: required.partialValue)
            guard let buffer = device.makeBuffer(length: capacity,
                                                  options: .storageModeShared) else {
                return nil
            }
            arenas[activeIndex].buffer = buffer
            arenas[activeIndex].offset = 0
            allocationCount += 1
        }

        guard let buffer = arenas[activeIndex].buffer else { return nil }
        let offset = align(arenas[activeIndex].offset)
        if size > 0 {
            values.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                buffer.contents().advanced(by: offset).copyMemory(from: base,
                                                                  byteCount: size)
            }
        }
        arenas[activeIndex].offset = offset + size
        return MetalBufferSlice(buffer: buffer, offset: offset)
    }

    private func align(_ value: Int) -> Int {
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }

    private func growCapacity(for required: Int) -> Int {
        var capacity = minimumPageSize
        while capacity < required, capacity <= Int.max / 2 {
            capacity *= 2
        }
        return max(capacity, required)
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

final class GlyphAtlas {
    /// A page is represented by disjoint unoccupied rectangles. Allocation
    /// removes one rectangle and guillotine-splits its remainder; there is no
    /// row, shelf, or insertion cursor.
    private struct FreeRectangle: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        var area: Int { width * height }

        func accepts(width requestedWidth: Int,
                     height requestedHeight: Int) -> Bool {
            requestedWidth <= width && requestedHeight <= height
        }
    }

    private struct PageState {
        var generation: UInt64 = 1
        var lastTouch: UInt64 = 0
        var free: [FreeRectangle]

        init(size: Int) {
            free = [FreeRectangle(x: 0, y: 0, width: size, height: size)]
        }
    }

    public let size: Int
    public let texture: MTLTexture
    public private(set) var evictedPage: Int?
    private let maxPages: Int
    private let format: GlyphAtlasFormat
    private var pages: [PageState]
    private var preferredPage = 0
    private var touchClock: UInt64 = 0

    public init?(device: MTLDevice,
                 size: Int = 1_024,
                 maxPages: Int = 4,
                 format: GlyphAtlasFormat = .grayscale) {
        guard size > 0, maxPages > 0 else { return nil }
        self.size = size
        self.maxPages = maxPages
        self.format = format
        pages = (0..<maxPages).map { _ in PageState(size: size) }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = format.pixelFormat
        descriptor.width = size
        descriptor.height = size
        descriptor.arrayLength = maxPages
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
    }

    public func generation(forPage page: Int) -> UInt64 {
        guard pages.indices.contains(page) else { return 0 }
        return pages[page].generation
    }

    public func touch(page: Int) {
        guard pages.indices.contains(page) else { return }
        touchClock &+= 1
        pages[page].lastTouch = touchClock
    }

    public func ensureRegion(width: Int, height: Int) -> AtlasRegion? {
        guard width > 0, height > 0, width <= size, height <= size else { return nil }
        evictedPage = nil

        for offset in pages.indices {
            let page = (preferredPage + offset) % maxPages
            if let region = carve(width: width, height: height, from: page) {
                preferredPage = page
                return region
            }
        }

        guard let victim = pages.indices.min(by: {
            if pages[$0].lastTouch == pages[$1].lastTouch { return $0 < $1 }
            return pages[$0].lastTouch < pages[$1].lastTouch
        }) else { return nil }
        zero(page: victim)
        pages[victim].free = [FreeRectangle(x: 0, y: 0,
                                            width: size, height: size)]
        pages[victim].generation &+= 1
        evictedPage = victim
        preferredPage = victim
        return carve(width: width, height: height, from: victim)
    }

    public func write(region: AtlasRegion,
                      pixels: [UInt8],
                      width: Int,
                      height: Int,
                      padding: Int = 0) {
        guard pages.indices.contains(region.page),
              pages[region.page].generation == region.generation,
              width >= 0, height >= 0, padding >= 0,
              region.x >= 0, region.y >= 0,
              region.width > 0, region.height > 0,
              region.x <= size - region.width,
              region.y <= size - region.height else { return }
        let bpp = format.bytesPerPixel
        zero(rectangle: MTLRegionMake2D(region.x, region.y,
                                        region.width, region.height),
             page: region.page)
        let copyWidth = min(width, max(0, region.width - 2 * padding))
        let copyHeight = min(height, max(0, region.height - 2 * padding))
        guard copyWidth > 0, copyHeight > 0,
              width <= Int.max / bpp,
              height <= Int.max / (width * bpp),
              pixels.count >= width * height * bpp else { return }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(region.x + padding, region.y + padding,
                                        copyWidth, copyHeight),
                mipmapLevel: 0,
                slice: region.page,
                withBytes: base,
                bytesPerRow: width * bpp,
                bytesPerImage: width * height * bpp)
        }
        touch(page: region.page)
    }

    private func carve(width: Int, height: Int,
                       from page: Int) -> AtlasRegion? {
        let candidates = pages[page].free.enumerated().filter {
            $0.element.accepts(width: width, height: height)
        }
        guard let selected = candidates.min(by: {
            let lhsWaste = $0.element.area - width * height
            let rhsWaste = $1.element.area - width * height
            if lhsWaste != rhsWaste { return lhsWaste < rhsWaste }
            if $0.element.y != $1.element.y {
                return $0.element.y < $1.element.y
            }
            return $0.element.x < $1.element.x
        }) else { return nil }

        let container = selected.element
        pages[page].free.remove(at: selected.offset)
        let remainingWidth = container.width - width
        let remainingHeight = container.height - height

        // Split along the larger remainder so long, useful rectangles survive
        // instead of degenerating into terminal-cell-sized shelves.
        if remainingWidth > remainingHeight {
            appendFree(FreeRectangle(x: container.x + width, y: container.y,
                                     width: remainingWidth,
                                     height: container.height), to: page)
            appendFree(FreeRectangle(x: container.x,
                                     y: container.y + height,
                                     width: width,
                                     height: remainingHeight), to: page)
        } else {
            appendFree(FreeRectangle(x: container.x + width, y: container.y,
                                     width: remainingWidth,
                                     height: height), to: page)
            appendFree(FreeRectangle(x: container.x,
                                     y: container.y + height,
                                     width: container.width,
                                     height: remainingHeight), to: page)
        }
        touchClock &+= 1
        pages[page].lastTouch = touchClock
        return AtlasRegion(page: page, generation: pages[page].generation,
                           x: container.x, y: container.y,
                           width: width, height: height)
    }

    private func appendFree(_ rectangle: FreeRectangle, to page: Int) {
        guard rectangle.width > 0, rectangle.height > 0 else { return }
        pages[page].free.append(rectangle)
    }

    private func zero(page: Int) {
        zero(rectangle: MTLRegionMake2D(0, 0, size, size), page: page)
    }

    private func zero(rectangle: MTLRegion, page: Int) {
        guard rectangle.size.width > 0, rectangle.size.height > 0 else { return }
        let bpp = format.bytesPerPixel
        let rowsPerStrip = min(32, rectangle.size.height)
        let rowBytes = rectangle.size.width * bpp
        let zeroes = [UInt8](repeating: 0, count: rowBytes * rowsPerStrip)
        zeroes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var row = 0
            while row < rectangle.size.height {
                let height = min(rowsPerStrip, rectangle.size.height - row)
                texture.replace(
                    region: MTLRegionMake2D(rectangle.origin.x,
                                            rectangle.origin.y + row,
                                            rectangle.size.width, height),
                    mipmapLevel: 0,
                    slice: page,
                    withBytes: base,
                    bytesPerRow: rowBytes,
                    bytesPerImage: rowBytes * height)
                row += height
            }
        }
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

final class CoreTextGlyphRasterizer {
    public init() {}

    public func hasVisibleBounds(font: CTFont, glyph: CGGlyph) -> Bool {
        let rect = bounds(font: font, glyph: glyph)
        return rect.width > 0 && rect.height > 0 && rect.width.isFinite && rect.height.isFinite
    }

    public func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphBitmap? {
        guard glyph != 0, hasVisibleBounds(font: font, glyph: glyph) else { return nil }
        let bounds = bounds(font: font, glyph: glyph)
        let minX = floor(bounds.minX)
        let minY = floor(bounds.minY)
        let width = Int(ceil(bounds.maxX) - minX)
        let height = Int(ceil(bounds.maxY) - minY)
        guard width > 0, height > 0, width <= 2_048, height <= 2_048 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let rasterContext = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return nil
        }
        rasterContext.setAllowsAntialiasing(true)
        rasterContext.setShouldAntialias(true)
        rasterContext.setAllowsFontSubpixelPositioning(true)
        rasterContext.setShouldSubpixelPositionFonts(true)
        rasterContext.setAllowsFontSubpixelQuantization(false)
        rasterContext.setShouldSubpixelQuantizeFonts(false)
        rasterContext.setAllowsFontSmoothing(true)
        rasterContext.setShouldSmoothFonts(true)
        rasterContext.setFillColor(NSColor.white.cgColor)
        rasterContext.setStrokeColor(NSColor.white.cgColor)
        var value = glyph
        var position = CGPoint(x: -minX, y: -minY)
        CTFontDrawGlyphs(font, &value, &position, 1, rasterContext)
        guard let rasterData = rasterContext.data else { return nil }
        let bitmapBytes = Array(UnsafeBufferPointer(
            start: rasterData.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4))
        var isColor = false
        for offset in stride(from: 0, to: bitmapBytes.count, by: 4) {
            if bitmapBytes[offset] != bitmapBytes[offset + 1]
                || bitmapBytes[offset + 1] != bitmapBytes[offset + 2] {
                isColor = true
                break
            }
        }
        return GlyphBitmap(width: width, height: height,
                           bearing: CGPoint(x: minX, y: minY),
                           pixels: bitmapBytes, isColor: isColor)
    }

    private func bounds(font: CTFont, glyph: CGGlyph) -> CGRect {
        var value = glyph
        var rectangle = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &value, &rectangle, 1)
        return rectangle
    }
}

struct FrozenLineAtlasRegion {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// The frozen renderer's grayscale glyph store is a 1024px shelf atlas. The
/// independent row compositor only consults this compatibility surface for
/// DEC transformed line modes, where linear filtering at an allocation edge
/// is externally observable.
final class FrozenLineModeGlyphAtlas {
    let size = 1_024
    let texture: MTLTexture
    private var cursorX = 0
    private var cursorY = 0
    private var rowHeight = 0

    init?(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        let zeroes = [UInt8](repeating: 0, count: size * size)
        zeroes.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: 0, withBytes: base,
                            bytesPerRow: size)
        }
    }

    func insert(_ bitmap: GlyphBitmap, padding: Int) -> FrozenLineAtlasRegion? {
        guard !bitmap.isColor, bitmap.width > 0, bitmap.height > 0,
              bitmap.pixels.count >= bitmap.width * bitmap.height * 4 else {
            return nil
        }
        let inset = max(0, padding)
        let width = bitmap.width + inset * 2
        let height = bitmap.height + inset * 2
        guard width <= size, height <= size else { return nil }
        if cursorX + width > size {
            cursorY += rowHeight
            cursorX = 0
            rowHeight = 0
        }
        guard cursorY + height <= size else { return nil }
        let region = FrozenLineAtlasRegion(
            x: cursorX, y: cursorY, width: width, height: height)
        cursorX += width
        rowHeight = max(rowHeight, height)

        var atlasBytes = [UInt8](repeating: 0, count: width * height)
        for outputY in 0..<bitmap.height {
            // The frozen atlas stores CoreGraphics glyph rows in y-up order.
            // Keep those observable bytes here; the independent y-down
            // compositor reverses the UV direction for this path instead of
            // reversing each allocation independently. That also preserves
            // the exact neighboring texels seen by linear filtering at an
            // allocation edge.
            let sourceY = bitmap.height - 1 - outputY
            for x in 0..<bitmap.width {
                atlasBytes[(outputY + inset) * width + x + inset]
                    = bitmap.pixels[(sourceY * bitmap.width + x) * 4 + 3]
            }
        }
        let uploadRegion = MTLRegionMake2D(
            region.x, region.y, region.width, region.height)
        atlasBytes.withUnsafeBytes { storage in
            guard let pointer = storage.baseAddress else { return }
            texture.replace(region: uploadRegion, mipmapLevel: 0,
                            withBytes: pointer, bytesPerRow: width)
        }
        return region
    }

    /// Advances the shelf allocator for a frozen custom-glyph allocation.
    /// Procedural box/block cells are composed directly by the independent
    /// renderer, but their legacy atlas residency remains observable because
    /// later line-mode glyphs linearly sample neighboring texels.
    func reserve(width: Int, height: Int) -> FrozenLineAtlasRegion? {
        guard width > 0, height > 0, width <= size, height <= size else {
            return nil
        }
        if cursorX + width > size {
            cursorY += rowHeight
            cursorX = 0
            rowHeight = 0
        }
        guard cursorY + height <= size else { return nil }
        let region = FrozenLineAtlasRegion(
            x: cursorX, y: cursorY, width: width, height: height)
        cursorX += width
        rowHeight = max(rowHeight, height)
        return region
    }
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
