import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import MetalKit

@MainActor
public final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
    public static var framesPresented = 0
    public static var rowsRebuilt = 0
    public static var rowsReused = 0

    public var shaderMode = 0 {
        didSet {
            resetFramePacing()
            updateAnimationTimer()
            requestDraw()
        }
    }
    public var smoothCursorEnabled = false
    public var hostCursorHidden = false
    public var cursorGlideSpeed: Float = 1
    public var cursorGlideMaxDistance: Float = 0
    public var smoothScrollEnabled = true
    public var textRenderingMode: TextRenderingMode = .current {
        didSet {
            if oldValue != textRenderingMode {
                // The frozen renderer invalidates glyph residency when the
                // text preset changes. The atlas pages themselves survive,
                // so subsequent presets append fresh allocations and that
                // shelf position remains observable at the next backing
                // scale through transformed-line linear filtering.
                frozenLineGlyphs.removeAll(keepingCapacity: true)
            }
            resetFramePacing()
            invalidateRowCache()
            requestDraw()
        }
    }
    public var onScrollOffsetChanged: ((CGFloat) -> Void)?

    public static let userShaderPreamble = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct CmdyUniforms {
        float2 resolution;
        float time;
        float curvature;
        float4 background;
        float2 cursor;
        float keypressAge;
        float typingRate;
        float opacity;
        uint passIndex;
        uint2 padding;
    };
    struct QuadVertex {
        float2 position;
        float2 uv;
        float4 color;
    };
    struct RasterUniforms {
        float2 resolution;
        float coveragePower;
        float databloomEnergy;
    };

    static float cmdy_hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }
    static float3 cmdy_palette(float t) {
        return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
    }
    static float cmdy_textMask(float3 rgb, float3 background) {
        float3 delta = abs(rgb - background);
        return clamp(max(delta.r, max(delta.g, delta.b)) * 5.0, 0.0, 1.0);
    }
    """#

    // MARK: Shared immutable Metal state

    private struct SharedKey: Hashable {
        let device: ObjectIdentifier
        let format: UInt
        let sampleCount: Int
    }

    private static var sharedCores: [SharedKey: IndependentSharedCore] = [:]
    static private(set) var sharedCoreResourceConstructionCount = 0

    static func resetSharedCoreResourcesForTesting() {
        sharedCores.removeAll()
    }

    static func sharedCoreResourceIdentity(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        sampleCount: Int = 1
    ) throws -> ObjectIdentifier {
        ObjectIdentifier(try sharedCore(device: device, pixelFormat: pixelFormat,
                                        sampleCount: sampleCount))
    }

    static func sharedCommandQueueIdentity(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        sampleCount: Int = 1
    ) throws -> ObjectIdentifier {
        let core = try sharedCore(device: device, pixelFormat: pixelFormat,
                                  sampleCount: sampleCount)
        return ObjectIdentifier(core.commandQueue as AnyObject)
    }

    private static func sharedCore(device: MTLDevice,
                                   pixelFormat: MTLPixelFormat,
                                   sampleCount: Int) throws -> IndependentSharedCore {
        let key = SharedKey(device: ObjectIdentifier(device as AnyObject),
                            format: pixelFormat.rawValue,
                            sampleCount: max(1, sampleCount))
        if let existing = sharedCores[key] { return existing }
        let core = try IndependentSharedCore(device: device,
                                             pixelFormat: pixelFormat,
                                             sampleCount: max(1, sampleCount))
        sharedCores[key] = core
        sharedCoreResourceConstructionCount += 1
        return core
    }

    // MARK: Lifetime and storage

    private weak var source: (any MetalRenderSource)?
    private weak var view: MTKView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let core: IndependentSharedCore
    private let dynamicBuffers: DynamicBufferRing

    private var rowCache: [Int: IndependentRowCacheEntry] = [:]
    private var cacheUseClock: UInt64 = 0
    private let rowCacheBudget = 20 * 1_024 * 1_024
    private var frameInFlight = false
    private var redrawPending = false
    private var sceneTexture: MTLTexture?

    private var animationTimer: Timer?
    private var recoveryTimer: Timer?
    private var coalescedDrawTimer: Timer?
    private var framePacer = FrameBuildPacer()
    private let startTime = ProcessInfo.processInfo.systemUptime
    private var recentActivityUntil = 0.0
    private var lastCursorActivityTime = 0.0
    private var glideLastFrameTime = 0.0
    private var cursorBlinkEligible = false
    private var glideCursorPosition: SIMD2<Float>?
    private var scrollHeldPixels: CGFloat = 0
    private var scrollGlidePixels: CGFloat = 0
    private var scrollLastTime = 0.0
    private var recentDirectManipulationUntil = 0.0
    private var recentSelectionInteractionUntil = 0.0
    private var shaderScroll = ShaderScrollEnvelope()
    private var lastCursorCenter = SIMD2<Float>.zero

    private var userPipeline: MTLRenderPipelineState?
    private var userShaderUsesTime = false

    private final class ImageTextureRecord {
        weak var owner: AnyObject?
        let texture: MTLTexture
        var lastUse: UInt64
        init(owner: AnyObject, texture: MTLTexture, lastUse: UInt64) {
            self.owner = owner
            self.texture = texture
            self.lastUse = lastUse
        }
    }

    /// A weak, explicitly sendable handoff used by detached image decoding.
    /// The referenced renderer is read only after returning to MainActor.
    private final class WeakRendererBox: @unchecked Sendable {
        weak var renderer: MetalTerminalRenderer?

        init(_ renderer: MetalTerminalRenderer) {
            self.renderer = renderer
        }
    }
    private final class SendableImageBox: @unchecked Sendable {
        let image: NSImage

        init(_ image: NSImage) {
            self.image = image
        }
    }
    private var imageTextures: [ObjectIdentifier: ImageTextureRecord] = [:]
    private var imageTextureFailures: [ObjectIdentifier: WeakRenderableImage] = [:]
    private var imageTexturePending: [ObjectIdentifier: WeakRenderableImage] = [:]
    private(set) var imageDecodeAttemptsForTesting = 0

    private struct KittySignature: Hashable {
        let kind: UInt8
        let width: Int
        let height: Int
        let count: Int
        let headHash: UInt32
    }
    private struct KittyTextureRecord {
        let signature: KittySignature
        let texture: MTLTexture
        var lastUse: UInt64
    }
    private var kittyTextures: [UInt32: KittyTextureRecord] = [:]
    private var kittyFailures: Set<KittySignature> = []
    private var kittyPending: Set<KittySignature> = []

    // Compatibility-test storage; production row rendering never allocates it.
    private var compatibilityGrayAtlas: GlyphAtlas?
    private var compatibilityColorAtlas: GlyphAtlas?
    private let compatibilityRasterizer = CoreTextGlyphRasterizer()
    private struct CompatibilityGlyphKey: Hashable {
        let name: String
        let sizeBits: UInt64
        let glyph: CGGlyph
    }
    private var compatibilityGlyphs: [CompatibilityGlyphKey: GlyphEntry] = [:]
    private var frozenLineAtlas: FrozenLineModeGlyphAtlas?
    private var frozenLineGlyphs: [CompatibilityGlyphKey: CGRect] = [:]
    private struct FrozenCustomGlyphKey: Hashable {
        let codePoint: UInt32
        let width: Int
        let height: Int
        let scaleBits: UInt64
        let antialias: Bool
    }
    private var frozenCustomGlyphs: Set<FrozenCustomGlyphKey> = []
    private(set) var colorAtlasAllocationCount = 0
    var colorAtlasPageCapacityForTesting: Int? {
        compatibilityColorAtlas?.texture.arrayLength
    }

    public init(view: MTKView, source: any MetalRenderSource) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalError.deviceUnavailable
        }
        view.device = device
        view.colorPixelFormat = view.colorPixelFormat == .invalid
            ? .bgra8Unorm : view.colorPixelFormat
        // A sampled post-process target requires an explicit resolve path for
        // MSAA. Terminal antialiasing is already performed in row coverage.
        view.sampleCount = 1
        self.device = device
        core = try Self.sharedCore(device: device,
                                   pixelFormat: view.colorPixelFormat,
                                   sampleCount: view.sampleCount)
        commandQueue = core.commandQueue
        dynamicBuffers = DynamicBufferRing(device: device)
        self.source = source
        self.view = view
        super.init()

        view.delegate = self
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 60
        let initialActivityTime = ProcessInfo.processInfo.systemUptime
        lastCursorActivityTime = initialActivityTime
        recentActivityUntil = initialActivityTime + 12
    }

    deinit {
        animationTimer?.invalidate()
        recoveryTimer?.invalidate()
        coalescedDrawTimer?.invalidate()
    }

    // MARK: Public controls

    @discardableResult
    public func loadUserShader(source: String?) -> String? {
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            userPipeline = nil
            userShaderUsesTime = false
            updateAnimationTimer()
            requestDraw()
            return nil
        }
        guard source.contains("cmdy_main") else {
            userPipeline = nil
            userShaderUsesTime = false
            return MetalError.shaderSourceMissing("cmdy_main").description
        }
        do {
            let library = try device.makeLibrary(
                source: Self.userShaderPreamble + "\n" + source + "\n"
                    + IndependentMetalSource.userWrapper,
                options: nil)
            guard let vertex = library.makeFunction(name: "cmdy_user_vertex") else {
                throw MetalError.shaderFunctionMissing("cmdy_user_vertex")
            }
            guard let fragment = library.makeFunction(name: "cmdy_user_fragment") else {
                throw MetalError.shaderFunctionMissing("cmdy_user_fragment")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "cmdy independent user shader"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view?.colorPixelFormat
                ?? .bgra8Unorm
            descriptor.rasterSampleCount = 1
            userPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            userShaderUsesTime = source.contains("u.time")
                || source.contains("u . time")
            updateAnimationTimer()
            requestDraw()
            return nil
        } catch {
            userPipeline = nil
            userShaderUsesTime = false
            updateAnimationTimer()
            requestDraw()
            return MetalError.shaderCompilationFailed(error.localizedDescription).description
        }
    }

    public func noteScroll(pixels: CGFloat) {
        guard pixels.isFinite else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recentDirectManipulationUntil = now + 0.15
        shaderScroll.noteScroll(deltaPixels: pixels, at: now)
        guard smoothScrollEnabled else {
            requestDraw()
            updateAnimationTimer()
            return
        }
        scrollGlidePixels = SmoothScrollMotion.accumulatedGlide(
            current: scrollGlidePixels, impulse: pixels,
            cellHeight: (source?.cellSize.height ?? 16)
                * (source?.backingScaleFactor() ?? 1))
        scrollLastTime = now
        requestDraw()
        updateAnimationTimer()
    }

    public func setScrollHeld(_ pixels: CGFloat) {
        scrollHeldPixels = smoothScrollEnabled && pixels.isFinite ? pixels : 0
        requestDraw()
    }

    /// One precise-scroll event updates motion, reactive shader telemetry, and
    /// presentation with one draw request. The previous three-call sequence
    /// repeatedly dirtied both the MTKView and its AppKit host for the same
    /// input sample.
    public func updateScrollHeld(
        _ pixels: CGFloat, activityPixels: CGFloat
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        scrollHeldPixels = smoothScrollEnabled && pixels.isFinite ? pixels : 0
        if activityPixels.isFinite {
            recentDirectManipulationUntil = now + 0.15
            shaderScroll.noteScroll(
                deltaPixels: activityPixels,
                at: now)
        }
        requestDraw()
        updateAnimationTimer()
    }

    /// Selection changes only composition geometry, so they can use the
    /// display-aligned interaction cadence without invalidating row textures.
    public func noteSelectionInteraction() {
        let now = ProcessInfo.processInfo.systemUptime
        recentDirectManipulationUntil = now + 0.15
        recentSelectionInteractionUntil = now + 0.15
        requestDraw()
        updateAnimationTimer()
    }

    public func cancelScrollAnimation() {
        scrollHeldPixels = 0
        scrollGlidePixels = 0
        scrollLastTime = 0
        onScrollOffsetChanged?(0)
        requestDraw()
        updateAnimationTimer()
    }

    public func noteActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        lastCursorActivityTime = now
        recentActivityUntil = now + 12
        requestDraw()
        updateAnimationTimer()
    }

    public func invalidateRowCache() {
        rowCache.removeAll(keepingCapacity: true)
        requestDraw()
    }

    public func mtkView(_ view: MTKView,
                        drawableSizeWillChange size: CGSize) {
        sceneTexture = nil
        resetFramePacing()
        requestDraw()
    }

    // MARK: Draw

    public func draw(in view: MTKView) {
        guard !frameInFlight else {
            redrawPending = true
            return
        }
        guard let source,
              let window = view.window,
              window.occlusionState.contains(.visible) else {
            updateAnimationTimer()
            return
        }

        let pacingNow = ProcessInfo.processInfo.systemUptime
        let pacingDelay = framePacer.delay(
            at: pacingNow, targetFPS: targetFrameRate(for: view))
        if pacingDelay > 0.000_25 {
            redrawPending = true
            scheduleCoalescedDraw(after: pacingDelay)
            return
        }
        coalescedDrawTimer?.invalidate()
        coalescedDrawTimer = nil
        redrawPending = false
        framePacer.markBuild(at: pacingNow)

        // The snapshot is deliberately the first source read for the frame.
        let snapshot = source.captureGrid()
        cursorBlinkEligible = Self.cursorBlinkEligible(
            snapshot: snapshot, hostCursorHidden: hostCursorHidden)
        let scale = source.backingScaleFactor()
        let cellSize = source.cellSize
        let bounds = source.viewBounds
        guard snapshot.rows > 0, snapshot.cols > 0,
              scale.isFinite, scale > 0,
              cellSize.width.isFinite, cellSize.height.isFinite,
              cellSize.width > 0, cellSize.height > 0,
              bounds.width > 0, bounds.height > 0,
              view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }

        guard let drawable = view.currentDrawable,
              let viewPass = view.currentRenderPassDescriptor else {
            scheduleDrawableRecovery()
            return
        }
        recoveryTimer?.invalidate()
        recoveryTimer = nil

        let foreground = source.nativeForegroundColor
        let background = source.nativeBackgroundColor
        let normalFont = source.normalFont
        let topInset = source.topContentInset
        let bottomInset = source.bottomContentInset
        let leftInset = source.leftContentInset
        let contentX = source.contentXOrigin
        let dirtyRows = source.consumeDirtyRows()
        let now = ProcessInfo.processInfo.systemUptime
        updateScroll(at: now)
        shaderScroll.update(at: now)

        let cellWidthPx = cellSize.width * scale
        let cellHeightPx = cellSize.height * scale
        let scrollPixels = effectiveScrollPixels(source: source)
        let scrollFringeRows = SmoothScrollMotion.fringeRows(
            offset: scrollPixels, cellHeight: cellHeightPx,
            enabled: smoothScrollEnabled)
        let rowRequests = snapshot.independentVisibleRowRequests(
            extraRows: scrollFringeRows)
        let rowWidth = Int(ceil(CGFloat(snapshot.cols) * cellWidthPx))
        let rowHeight = Int(ceil(cellHeightPx))
        guard rowWidth > 0, rowHeight > 0 else { return }
        let scaledFont = NSFont(descriptor: normalFont.fontDescriptor,
                                size: normalFont.pointSize * scale) ?? normalFont

        var visibleRows: [(displayIndex: Int, sourceRow: Int, cacheRow: Int,
                           mode: RenderLineMode, entry: IndependentRowCacheEntry)] = []
        visibleRows.reserveCapacity(rowRequests.count)
        let colorKeyForeground = IndependentRowRasterizer.packedColor(foreground)
        let colorKeyBackground = IndependentRowRasterizer.packedColor(background)

        for request in rowRequests {
            let version = source.lineVersion(forRow: request.sourceRow)
            let mode = source.lineRenderMode(forRow: request.sourceRow)
            let key = IndependentRowKey(
                absoluteRow: request.cacheRow,
                version: version,
                lineMode: mode,
                cols: snapshot.cols,
                widthPx: rowWidth,
                heightPx: rowHeight,
                scaleBits: Double(scale).bitPattern,
                fontName: normalFont.fontName,
                fontSizeBits: Double(normalFont.pointSize).bitPattern,
                alternateBuffer: snapshot.isAlternateBuffer,
                kittyStamp: source.kittyStamp,
                foreground: colorKeyForeground,
                background: colorKeyBackground,
                preset: textRenderingMode,
                antialiasBlocks: source.antiAliasCustomBlockGlyphs,
                bufferingMode: source.metalBufferingMode)
            let explicitlyDirty = dirtyRows?.contains(request.sourceRow) == true
            if !explicitlyDirty, var cached = rowCache[request.cacheRow], cached.key == key {
                cacheUseClock &+= 1
                cached.lastUse = cacheUseClock
                rowCache[request.cacheRow] = cached
                visibleRows.append((request.displayIndex, request.sourceRow,
                                    request.cacheRow, mode, cached))
                Self.rowsReused += 1
                continue
            }

            let info = source.lineInfo(forRow: request.sourceRow)
            if let entry = makeRowEntry(info: info, key: key,
                                        scaledFont: scaledFont,
                                        foreground: foreground,
                                        underlinePosition: source.underlinePosition(),
                                        underlineThickness: source.underlineThickness(),
                                        cellWidth: cellWidthPx,
                                        cellHeight: cellHeightPx,
                                        scale: scale) {
                rowCache[request.cacheRow] = entry
                visibleRows.append((request.displayIndex, request.sourceRow,
                                    request.cacheRow, mode, entry))
                Self.rowsRebuilt += 1
            }
        }
        trimRowCache(visibleRows: Set(visibleRows.map(\.cacheRow)),
                     visibleCount: max(snapshot.rows, visibleRows.count))
        pruneImageCaches(liveKittyIds: source.kittyLiveImageIds)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "cmdy independent terminal frame"
        dynamicBuffers.beginFrame()
        frameInFlight = true

        let needsScene = Self.requiresOffscreenScene(
            shaderMode: shaderMode,
            hasBuiltInPipeline: (1...67).contains(shaderMode),
            hasUserPipeline: userPipeline != nil)
        if !needsScene { sceneTexture = nil }
        let scenePass: MTLRenderPassDescriptor
        if needsScene, let texture = ensureSceneTexture(size: view.drawableSize,
                                                        format: view.colorPixelFormat) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            scenePass = descriptor
        } else {
            scenePass = viewPass
        }
        let clear = IndependentRowRasterizer.rgba(background)
        scenePass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clear.x), green: Double(clear.y),
            blue: Double(clear.z), alpha: Double(clear.w))
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: scenePass) else {
            frameInFlight = false
            return
        }
        encoder.label = "cmdy row texture composition"
        let scissor = TerminalGridScissor(drawableSize: view.drawableSize,
                                          topInset: topInset,
                                          bottomInset: bottomInset,
                                          leftInset: leftInset,
                                          scale: scale).rect
        guard scissor.width > 0, scissor.height > 0 else {
            encoder.endEncoding()
            frameInFlight = false
            return
        }
        encoder.setScissorRect(scissor)
        let snappedScroll = SmoothScrollTranslation(offsetPixels: scrollPixels,
                                                     scale: scale)
        onScrollOffsetChanged?(snappedScroll.renderedPoints)
        let xOrigin = (contentX * scale).rounded()
        let yOrigin = CGFloat(TerminalGridScissor.deviceTopInset(
            topInset, scale: scale)) + CGFloat(snappedScroll.yShiftPixels)
        let resolution = SIMD2(Float(view.drawableSize.width),
                               Float(view.drawableSize.height))

        encodeRows(visibleRows, encoder: encoder,
                   xOrigin: xOrigin, yOrigin: yOrigin,
                   cellWidth: cellWidthPx, cellHeight: cellHeightPx,
                   resolution: resolution, source: source,
                   snapshot: snapshot)
        encodeCursor(snapshot: snapshot, visibleRows: visibleRows,
                     encoder: encoder, source: source,
                     xOrigin: xOrigin, yOrigin: yOrigin,
                     cellWidth: cellWidthPx, cellHeight: cellHeightPx,
                     resolution: resolution, font: normalFont, now: now)
        encoder.endEncoding()

        if needsScene, let sceneTexture,
           let finalEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: viewPass) {
            encodePostProcess(encoder: finalEncoder, scene: sceneTexture,
                              resolution: resolution, background: clear,
                              source: source, now: now)
            finalEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                Self.framesPresented += 1
                self.frameInFlight = false
                if self.redrawPending {
                    self.redrawPending = false
                    self.requestDraw()
                }
            }
        }
        commandBuffer.commit()
        updateAnimationTimer()
    }

    // MARK: Row building and residency

    private func makeRowEntry(info: ViewLineInfo,
                              key: IndependentRowKey,
                              scaledFont: NSFont,
                              foreground: NSColor,
                              underlinePosition: CGFloat,
                              underlineThickness: CGFloat,
                              cellWidth: CGFloat,
                              cellHeight: CGFloat,
                              scale: CGFloat) -> IndependentRowCacheEntry? {
        reserveFrozenCustomGlyphs(
            in: info, cellWidth: cellWidth, cellHeight: cellHeight,
            scale: scale, antialias: key.antialiasBlocks)
        guard let cpu = IndependentRowRasterizer.rasterize(
            info: info, cols: key.cols, width: key.widthPx, height: key.heightPx,
            cellWidth: cellWidth, cellHeight: cellHeight, scale: scale,
            normalFont: scaledFont, nativeForeground: foreground,
            underlinePosition: underlinePosition,
            underlineThickness: underlineThickness,
            preset: key.preset, antialiasBlocks: key.antialiasBlocks) else {
            return nil
        }
        let coverage = makeTexture(width: cpu.width, height: cpu.height,
                                   format: .r8Unorm, bytes: cpu.coverage,
                                   bytesPerRow: cpu.width)
        let colorLayers = cpu.colorTiles.compactMap { tile -> IndependentColorLayer? in
            guard let texture = makeTexture(width: tile.width, height: tile.height,
                                            format: .bgra8Unorm,
                                            bytes: tile.bytes,
                                            bytesPerRow: tile.width * 4) else { return nil }
            return IndependentColorLayer(texture: texture, rect: tile.rect)
        }
        let atlasGlyphs = cpu.glyphSeeds.compactMap { seed -> IndependentAtlasGlyphDraw? in
            guard let atlasRect = frozenLineGlyph(
                font: seed.font, glyph: seed.glyph, preset: key.preset) else {
                return nil
            }
            return IndependentAtlasGlyphDraw(rect: seed.rect,
                                             atlasRect: atlasRect,
                                             color: seed.color)
        }
        cacheUseClock &+= 1
        return IndependentRowCacheEntry(
            key: key, coverageTexture: coverage, colorLayers: colorLayers,
            backgrounds: cpu.backgrounds, tintSpans: cpu.tintSpans,
            atlasGlyphs: atlasGlyphs,
            decorations: cpu.decorations, images: cpu.images,
            kittyPlaceholders: cpu.kittyPlaceholders,
            width: cpu.width, height: cpu.height, lastUse: cacheUseClock)
    }

    private func reserveFrozenCustomGlyphs(
        in info: ViewLineInfo,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        scale: CGFloat,
        antialias: Bool
    ) {
        guard !info.boxDrawings.isEmpty || !info.blockElements.isEmpty else {
            return
        }
        if frozenLineAtlas == nil {
            frozenLineAtlas = FrozenLineModeGlyphAtlas(device: device)
        }
        guard let atlas = frozenLineAtlas else { return }
        func reserve(codePoint: UInt32, columnWidth: Int) {
            let width = max(1, Int((CGFloat(max(1, columnWidth))
                * cellWidth).rounded()))
            let height = max(1, Int(cellHeight.rounded()))
            let key = FrozenCustomGlyphKey(
                codePoint: codePoint, width: width, height: height,
                scaleBits: Double(scale).bitPattern, antialias: antialias)
            guard frozenCustomGlyphs.insert(key).inserted else { return }
            _ = atlas.reserve(width: width, height: height)
        }
        for item in info.boxDrawings {
            reserve(codePoint: item.codePoint, columnWidth: item.columnWidth)
        }
        for item in info.blockElements {
            reserve(codePoint: item.codePoint, columnWidth: item.columnWidth)
        }
    }

    private func makeTexture(width: Int, height: Int,
                             format: MTLPixelFormat,
                             bytes: [UInt8], bytesPerRow: Int) -> MTLTexture? {
        guard width > 0, height > 0, bytesPerRow > 0,
              bytes.count >= bytesPerRow * height else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0, withBytes: base,
                            bytesPerRow: bytesPerRow)
        }
        return texture
    }

    private func frozenLineGlyph(font: CTFont,
                                 glyph: CGGlyph,
                                 preset: TextRenderingMode) -> CGRect? {
        let key = CompatibilityGlyphKey(
            name: CTFontCopyPostScriptName(font) as String,
            sizeBits: Double(CTFontGetSize(font)).bitPattern,
            glyph: glyph)
        if let cached = frozenLineGlyphs[key] { return cached }
        guard let bitmap = compatibilityRasterizer.rasterize(font: font,
                                                              glyph: glyph),
              !bitmap.isColor else { return nil }
        if frozenLineAtlas == nil {
            frozenLineAtlas = FrozenLineModeGlyphAtlas(device: device)
        }
        guard let atlas = frozenLineAtlas else { return nil }
        let padding = preset.padsAtlas ? 1 : 0
        guard let region = atlas.insert(bitmap, padding: padding) else { return nil }
        let content = CGRect(x: region.x + padding,
                             y: region.y + padding,
                             width: bitmap.width,
                             height: bitmap.height)
        frozenLineGlyphs[key] = content
        return content
    }

    private func trimRowCache(visibleRows: Set<Int>, visibleCount: Int) {
        let rowLimit = max(1, visibleCount * 3)
        while rowCache.count > rowLimit || rowCacheAllocatedBytes > rowCacheBudget {
            let candidates = rowCache.filter { !visibleRows.contains($0.key) }
            guard let victim = candidates.min(by: { $0.value.lastUse < $1.value.lastUse }) else {
                break
            }
            rowCache.removeValue(forKey: victim.key)
        }
    }

    var rowCacheAllocatedBytes: Int {
        rowCache.values.reduce(0) { $0 + $1.allocatedBytes }
    }

    var rowCacheAllocatedBytesForTesting: Int { rowCacheAllocatedBytes }

    func replaceAndTrimRowCacheForTesting(
        _ entries: [Int: IndependentRowCacheEntry],
        visibleRows: Set<Int>,
        visibleCount: Int
    ) {
        rowCache = entries
        trimRowCache(visibleRows: visibleRows, visibleCount: visibleCount)
    }

    var rowCacheCountForTesting: Int { rowCache.count }

    // MARK: Composition

    private func encodeRows(
        _ rows: [(displayIndex: Int, sourceRow: Int, cacheRow: Int,
                  mode: RenderLineMode, entry: IndependentRowCacheEntry)],
        encoder: MTLRenderCommandEncoder,
        xOrigin: CGFloat,
        yOrigin: CGFloat,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        resolution: SIMD2<Float>,
        source: any MetalRenderSource,
        snapshot: GridSnapshot
    ) {
        // 1. Per-cell backgrounds plus the dynamic selection plane. Selection
        // spans are deliberately absent from the row cache: a drag changes
        // only these few quads, never CoreText or glyph rasterization.
        var backgrounds: [IndependentQuadVertex] = []
        var selections: [IndependentQuadVertex] = []
        let selectionSource = source as? any MetalSelectionRenderSource
        let selectionColor = IndependentRowRasterizer.rgba(
            selectionSource?.selectionBackgroundColor
                ?? NSColor.selectedTextBackgroundColor)
        for row in rows {
            let selection = Self.selectionRect(
                columns: selectionSource?.selectionColumns(
                    forRow: row.sourceRow),
                columnCount: snapshot.cols,
                cellWidth: cellWidth, cellHeight: cellHeight)
            for solid in row.entry.backgrounds {
                for fragment in Self.backgroundFragments(
                    solid.rect, excluding: selection
                ) {
                    let rect = transformed(
                        fragment, displayIndex: row.displayIndex,
                        mode: row.mode, xOrigin: xOrigin,
                        yOrigin: yOrigin, cellHeight: cellHeight)
                    backgrounds.append(contentsOf: quad(
                        rect: rect, color: solid.color))
                }
            }
            if let selection {
                let rect = transformed(
                    selection, displayIndex: row.displayIndex,
                    mode: row.mode, xOrigin: xOrigin,
                    yOrigin: yOrigin, cellHeight: cellHeight)
                selections.append(contentsOf: quad(
                    rect: rect, color: selectionColor))
            }
        }
        backgrounds.append(contentsOf: selections)
        encodeSolid(vertices: backgrounds, encoder: encoder, resolution: resolution)

        // 2. Grayscale/color glyphs.
        for row in rows {
            encodeCoverage(row: row, encoder: encoder,
                           xOrigin: xOrigin, yOrigin: yOrigin,
                           cellHeight: cellHeight, resolution: resolution)
            for layer in row.entry.colorLayers {
                let rect = transformed(layer.rect, displayIndex: row.displayIndex,
                                       mode: row.mode, xOrigin: xOrigin,
                                       yOrigin: yOrigin, cellHeight: cellHeight)
                encodeTexture(layer.texture, rect: rect, encoder: encoder,
                              resolution: resolution, flipped: false)
            }
        }

        // 3. Underlines, strikes, blocks, and other solid decorations.
        var decorations: [IndependentQuadVertex] = []
        for row in rows {
            for solid in row.entry.decorations {
                let rect = transformed(solid.rect, displayIndex: row.displayIndex,
                                       mode: row.mode, xOrigin: xOrigin,
                                       yOrigin: yOrigin, cellHeight: cellHeight)
                decorations.append(contentsOf: quad(rect: rect, color: solid.color))
            }
        }
        encodeSolid(vertices: decorations, encoder: encoder, resolution: resolution)

        // 4. Kitty placeholder images.
        encodeKittyPlaceholders(rows, encoder: encoder, source: source,
                                snapshot: snapshot, xOrigin: xOrigin,
                                yOrigin: yOrigin, cellWidth: cellWidth,
                                cellHeight: cellHeight, resolution: resolution)

        // 5. The frozen compositor draws every ordinary image over row
        // content, including placements carrying a negative z-index.
        encodeOrdinaryImages(rows, where: { _ in true }, encoder: encoder,
                             xOrigin: xOrigin, yOrigin: yOrigin,
                             cellWidth: cellWidth, cellHeight: cellHeight,
                             resolution: resolution,
                             backingScale: source.backingScaleFactor(),
                             imageScale: source.getImageScale())
    }

    private func encodeCoverage(
        row: (displayIndex: Int, sourceRow: Int, cacheRow: Int,
              mode: RenderLineMode, entry: IndependentRowCacheEntry),
        encoder: MTLRenderCommandEncoder,
        xOrigin: CGFloat, yOrigin: CGFloat, cellHeight: CGFloat,
        resolution: SIMD2<Float>
    ) {
        guard let texture = row.entry.coverageTexture else { return }
        let pipeline = shaderMode == CmdyBuiltInEffectShaders.databloomMode
            ? core.builtInEffects.databloomGlyph : core.coveragePipeline
        encoder.setRenderPipelineState(pipeline)
        let sampler = textRenderingMode.usesNearestSampling
            ? core.nearestSampler : core.linearSampler
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentTexture(texture, index: 0)

        if shaderMode == CmdyBuiltInEffectShaders.databloomMode {
            var coveragePower: Float = 1 / max(0.1, textRenderingMode.coveragePower)
            var uniforms = CmdyDatabloomUniforms(
                energy: shaderScroll.energy,
                velocity: shaderScroll.velocity,
                opacity: 1,
                passIndex: 0)
            encoder.setFragmentBytes(&coveragePower,
                                     length: MemoryLayout<Float>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<CmdyDatabloomUniforms>.stride,
                                     index: 1)
        } else {
            var uniforms = IndependentRasterUniforms(
                resolution: resolution,
                coveragePower: textRenderingMode.coveragePower,
                databloomEnergy: 0)
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<IndependentRasterUniforms>.stride,
                                     index: 0)
        }

        var raster = IndependentRasterUniforms(
            resolution: resolution,
            coveragePower: textRenderingMode.coveragePower,
            databloomEnergy: shaderScroll.energy)
        encoder.setVertexBytes(&raster,
                               length: MemoryLayout<IndependentRasterUniforms>.stride,
                               index: 1)
        let usesFrozenAtlas = row.mode != .single
            && !row.entry.atlasGlyphs.isEmpty
            && frozenLineAtlas != nil
        if usesFrozenAtlas, let atlas = frozenLineAtlas {
            encoder.setFragmentTexture(atlas.texture, index: 0)
            for glyph in row.entry.atlasGlyphs {
                guard let transformed = transformedGlyphSpan(
                    glyph.rect, displayIndex: row.displayIndex,
                    mode: row.mode, xOrigin: xOrigin, yOrigin: yOrigin,
                    cellHeight: cellHeight), glyph.rect.width > 0,
                    glyph.rect.height > 0 else { continue }
                let xFraction = (transformed.sample.minX - glyph.rect.minX)
                    / glyph.rect.width
                let yFraction = (transformed.sample.minY - glyph.rect.minY)
                    / glyph.rect.height
                let widthFraction = transformed.sample.width / glyph.rect.width
                let heightFraction = transformed.sample.height / glyph.rect.height
                let atlasSample = CGRect(
                    x: glyph.atlasRect.minX + glyph.atlasRect.width * xFraction,
                    // Row-local source rectangles are y-down while the
                    // frozen atlas bytes are y-up. Reflect a clipped sample
                    // inside its allocation before reversing the UV
                    // direction; full-height glyphs are unchanged, while DEC
                    // upper/lower halves select the same atlas rows as the
                    // frozen TextCell path.
                    y: glyph.atlasRect.maxY
                        - glyph.atlasRect.height * (yFraction + heightFraction),
                    width: glyph.atlasRect.width * widthFraction,
                    height: glyph.atlasRect.height * heightFraction)
                let uv = uvRect(for: atlasSample,
                                textureWidth: atlas.size,
                                textureHeight: atlas.size,
                                flipped: true, mode: .single)
                let vertices = quad(rect: transformed.destination, uv: uv,
                                    color: glyph.color,
                                    preserveUVOrientation: true)
                guard let slice = dynamicBuffers.write(vertices) else { continue }
                encoder.setVertexBuffer(slice.buffer, offset: slice.offset, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: vertices.count)
            }
            encoder.setFragmentTexture(texture, index: 0)
        }

        for span in row.entry.tintSpans
            where !usesFrozenAtlas || !span.replacedByAtlas {
            // The frozen atlas transforms the allocated glyph bitmap, then
            // clips doubled-height rows and derives the UV slice from that
            // intersection. Recreate that order from the tight bitmap
            // envelope rather than scaling an entire terminal cell.
            let sourceRect = row.mode != .single
                ? (span.glyphEnvelope ?? span.rect)
                : span.rect
            guard let transformed = transformedGlyphSpan(
                sourceRect, displayIndex: row.displayIndex,
                mode: row.mode, xOrigin: xOrigin, yOrigin: yOrigin,
                cellHeight: cellHeight) else { continue }
            let rect = transformed.destination
            let uv = uvRect(for: transformed.sample,
                            textureWidth: row.entry.width,
                            textureHeight: row.entry.height,
                            flipped: true, mode: .single)
            var vertices = quad(rect: rect, uv: uv, color: span.color)
            guard let slice = dynamicBuffers.write(vertices) else { continue }
            encoder.setVertexBuffer(slice.buffer, offset: slice.offset, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: vertices.count)
            if shaderMode == CmdyBuiltInEffectShaders.databloomMode,
               shaderScroll.energy > 0.01 {
                var second = CmdyDatabloomUniforms(
                    energy: shaderScroll.energy,
                    velocity: shaderScroll.velocity,
                    opacity: shaderScroll.energy * 0.7,
                    passIndex: 1)
                encoder.setFragmentBytes(&second,
                                         length: MemoryLayout<CmdyDatabloomUniforms>.stride,
                                         index: 1)
                let shift = CGFloat(max(-10, min(10,
                    shaderScroll.velocity * 0.012)))
                vertices = quad(rect: rect.offsetBy(dx: shift, dy: 0),
                                uv: uv, color: span.color)
                if let secondSlice = dynamicBuffers.write(vertices) {
                    encoder.setVertexBuffer(secondSlice.buffer,
                                            offset: secondSlice.offset, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                           vertexCount: vertices.count)
                }
            }
        }
    }

    private func transformedGlyphSpan(
        _ sourceRect: CGRect,
        displayIndex: Int,
        mode: RenderLineMode,
        xOrigin: CGFloat,
        yOrigin: CGFloat,
        cellHeight: CGFloat
    ) -> (destination: CGRect, sample: CGRect)? {
        let rowMinY = yOrigin + CGFloat(displayIndex) * cellHeight
        if mode == .single || mode == .doubleWidth {
            let horizontalScale = mode == .single ? 1.0 : 2.0
            return (
                CGRect(x: xOrigin + sourceRect.minX * horizontalScale,
                       y: rowMinY + sourceRect.minY,
                       width: sourceRect.width * horizontalScale,
                       height: sourceRect.height),
                sourceRect)
        }

        var unbounded = CGRect(
            x: xOrigin + sourceRect.minX * 2,
            y: rowMinY + sourceRect.minY * 2,
            width: sourceRect.width * 2,
            height: sourceRect.height * 2)
        if mode == .doubledDown { unbounded.origin.y -= cellHeight }
        let destination = unbounded.intersection(CGRect(
            x: unbounded.minX,
            y: rowMinY,
            width: unbounded.width,
            height: cellHeight))
        guard !destination.isNull, destination.width > 0,
              destination.height > 0, unbounded.height > 0 else { return nil }
        let topFraction = (destination.minY - unbounded.minY) / unbounded.height
        let heightFraction = destination.height / unbounded.height
        let sample = CGRect(
            x: sourceRect.minX,
            y: sourceRect.minY + sourceRect.height * topFraction,
            width: sourceRect.width,
            height: sourceRect.height * heightFraction)
        return (destination, sample)
    }

    private func encodeSolid(vertices: [IndependentQuadVertex],
                             encoder: MTLRenderCommandEncoder,
                             resolution: SIMD2<Float>) {
        guard !vertices.isEmpty, let slice = dynamicBuffers.write(vertices) else { return }
        encoder.setRenderPipelineState(core.solidPipeline)
        var uniforms = IndependentRasterUniforms(resolution: resolution,
                                                  coveragePower: 1,
                                                  databloomEnergy: 0)
        encoder.setVertexBuffer(slice.buffer, offset: slice.offset, index: 0)
        encoder.setVertexBytes(&uniforms,
                               length: MemoryLayout<IndependentRasterUniforms>.stride,
                               index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: vertices.count)
    }

    private func encodeTexture(_ texture: MTLTexture,
                               rect: CGRect,
                               encoder: MTLRenderCommandEncoder,
                               resolution: SIMD2<Float>,
                               flipped: Bool,
                               uv: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                               color: SIMD4<Float> = SIMD4(repeating: 1)) {
        var vertices = quad(rect: rect, uv: uv, color: color)
        if flipped {
            for index in vertices.indices {
                // The frozen image path flips in full-texture coordinates.
                // This matters when a Kitty placeholder exposes only a
                // clipped UV slice: reflecting inside that slice shifts the
                // sampled image by the clipped-away extent.
                vertices[index].uv.y = 1 - vertices[index].uv.y
            }
        }
        guard let slice = dynamicBuffers.write(vertices) else { return }
        encoder.setRenderPipelineState(core.imagePipeline)
        var uniforms = IndependentRasterUniforms(resolution: resolution,
                                                  coveragePower: 1,
                                                  databloomEnergy: 0)
        encoder.setVertexBuffer(slice.buffer, offset: slice.offset, index: 0)
        encoder.setVertexBytes(&uniforms,
                               length: MemoryLayout<IndependentRasterUniforms>.stride,
                               index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(core.linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: vertices.count)
    }

    private func encodeOrdinaryImages(
        _ rows: [(displayIndex: Int, sourceRow: Int, cacheRow: Int,
                  mode: RenderLineMode, entry: IndependentRowCacheEntry)],
        where predicate: (Int) -> Bool,
        encoder: MTLRenderCommandEncoder,
        xOrigin: CGFloat, yOrigin: CGFloat,
        cellWidth: CGFloat, cellHeight: CGFloat,
        resolution: SIMD2<Float>, backingScale: CGFloat, imageScale: CGFloat
    ) {
        for row in rows {
            for placement in row.entry.images where predicate(placement.zIndex) {
                guard let image = placement.image.value,
                      let texture = texture(for: image) else { continue }
                let x = xOrigin + CGFloat(placement.col) * cellWidth
                let y = yOrigin + CGFloat(row.displayIndex) * cellHeight
                let contentFactor = imageScale.isFinite ? max(0, imageScale) : 1
                let deviceFactor = backingScale.isFinite ? max(0, backingScale) : 1
                let factor = contentFactor * deviceFactor
                let rect = CGRect(x: x, y: y,
                                  width: CGFloat(placement.pixelWidth) * factor,
                                  height: CGFloat(placement.pixelHeight) * factor)
                encodeTexture(texture, rect: rect, encoder: encoder,
                              resolution: resolution, flipped: false)
            }
        }
    }

    private struct PlaceholderKey: Hashable {
        let image: UInt32
        let placement: UInt32
    }

    private func encodeKittyPlaceholders(
        _ rows: [(displayIndex: Int, sourceRow: Int, cacheRow: Int,
                  mode: RenderLineMode, entry: IndependentRowCacheEntry)],
        encoder: MTLRenderCommandEncoder,
        source: any MetalRenderSource,
        snapshot: GridSnapshot,
        xOrigin: CGFloat, yOrigin: CGFloat,
        cellWidth: CGFloat, cellHeight: CGFloat,
        resolution: SIMD2<Float>
    ) {
        let placements = source.kittyVirtualPlacements(
            alternateBuffer: snapshot.isAlternateBuffer)
        var specs: [PlaceholderKey: KittyPlacementSpec] = [:]
        for placement in placements {
            specs[PlaceholderKey(image: placement.imageId,
                                 placement: placement.placementId)] = placement
        }
        for row in rows {
            for placeholder in row.entry.kittyPlaceholders {
                let key = PlaceholderKey(image: placeholder.imageId,
                                         placement: placeholder.placementId)
                guard let payload = source.kittyImagePayload(imageId: key.image),
                      let texture = kittyTexture(imageId: key.image,
                                                 payload: payload) else { continue }
                guard let spec = specs[key] else { continue }
                let anchorRow = placeholder.row - placeholder.placeholderRow
                let anchorCol = placeholder.col - placeholder.placeholderCol
                let cols = max(1, spec.cols)
                let rows = max(1, spec.rows)
                let deviceScale = source.backingScaleFactor().isFinite
                    ? max(0, source.backingScaleFactor()) : 1
                let placementRect = CGRect(
                    x: xOrigin + CGFloat(anchorCol) * cellWidth
                        + CGFloat(spec.pixelOffsetX) * deviceScale,
                    // Kitty's public y offset is expressed in the renderer's
                    // bottom-up image coordinate system, so positive values
                    // move the top-left drawable rect upward.
                    y: yOrigin + CGFloat(anchorRow - snapshot.displayTopRow) * cellHeight
                        - CGFloat(spec.pixelOffsetY) * deviceScale,
                    width: CGFloat(cols) * cellWidth,
                    height: CGFloat(rows) * cellHeight)
                let fitted = Self.kittyAspectFitRect(
                    imageSize: CGSize(width: texture.width, height: texture.height),
                    in: placementRect)
                let placeholderRect = CGRect(
                    x: xOrigin + CGFloat(placeholder.col) * cellWidth,
                    y: yOrigin
                        + CGFloat(placeholder.row - snapshot.displayTopRow) * cellHeight,
                    width: cellWidth,
                    height: cellHeight)
                let visible = fitted.intersection(placeholderRect)
                guard !visible.isNull, visible.width > 0, visible.height > 0,
                      fitted.width > 0, fitted.height > 0 else { continue }
                let uv = CGRect(
                    x: (visible.minX - fitted.minX) / fitted.width,
                    y: (visible.minY - fitted.minY) / fitted.height,
                    width: visible.width / fitted.width,
                    height: visible.height / fitted.height)
                encodeTexture(texture, rect: visible, encoder: encoder,
                              resolution: resolution, flipped: true, uv: uv)
            }
        }
    }

    static func kittyAspectFitRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              container.width.isFinite, container.height.isFinite,
              container.width > 0, container.height > 0 else { return .zero }
        let factor = min(container.width / imageSize.width,
                         container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * factor,
                          height: imageSize.height * factor)
        return CGRect(x: container.midX - size.width / 2,
                      y: container.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Cursor

    private func encodeCursor(
        snapshot: GridSnapshot,
        visibleRows: [(displayIndex: Int, sourceRow: Int, cacheRow: Int,
                       mode: RenderLineMode, entry: IndependentRowCacheEntry)],
        encoder: MTLRenderCommandEncoder,
        source: any MetalRenderSource,
        xOrigin: CGFloat, yOrigin: CGFloat,
        cellWidth: CGFloat, cellHeight: CGFloat,
        resolution: SIMD2<Float>, font: NSFont, now: Double
    ) {
        guard let displayRow = snapshot.independentDisplayRow(
            forSourceRow: snapshot.cursorRow),
              snapshot.cursorCol >= 0, snapshot.cursorCol < snapshot.cols else {
            glideCursorPosition = nil
            lastCursorCenter = .zero
            return
        }

        let cursorRow = visibleRows.first {
            $0.sourceRow == snapshot.cursorRow
        }
        let cursorWidth = cellWidth * (cursorRow?.mode.horizontalScale ?? 1)
        let target = SIMD2(Float(xOrigin + CGFloat(snapshot.cursorCol) * cursorWidth),
                           Float(yOrigin + CGFloat(displayRow) * cellHeight))
        let cursorOpacity = CursorPulse.opacity(
            blinks: snapshot.cursorStyle.blinks,
            caretFocused: source.caretFocused,
            now: now,
            lastActivityTime: lastCursorActivityTime,
            activeUntil: recentActivityUntil)
        // A pulse trough is visual opacity, not structural hiding. Keep the
        // glide advancing through the fade so the cursor cannot reappear from
        // a stale position. Only DECTCEM/host hiding snaps to the latest cell.
        let shouldDrawCursor = !snapshot.cursorHidden && !hostCursorHidden
        let start = glideCursorPosition ?? target
        let isLiveResize = view?.inLiveResize == true
        let glideActive = shouldDrawCursor && smoothCursorEnabled && !isLiveResize
        let deltaTime: Float
        if glideActive {
            // Keep a glide-only clock: ordinary redraw cadence must not change
            // the frozen first/re-enabled glide step. CursorGlide clamps the
            // elapsed interval to the original 1...50 ms envelope.
            deltaTime = Float(now - glideLastFrameTime)
            glideLastFrameTime = now
        } else {
            // The value is ignored by resolvedStep when hidden, disabled, or
            // live-resizing; keep it finite for defensive callers.
            deltaTime = 0.001
        }
        let step = CursorGlide.resolvedStep(
            from: start, to: target, shouldDraw: shouldDrawCursor,
            smoothEnabled: smoothCursorEnabled, isLiveResize: isLiveResize,
            deltaTime: deltaTime,
            speed: cursorGlideSpeed, maxDistance: cursorGlideMaxDistance,
            cellSize: SIMD2(Float(cursorWidth), Float(cellHeight)))
        let position = step.position
        let cursorAnimating = step.isAnimating
        glideCursorPosition = step.position
        lastCursorCenter = position + SIMD2(Float(cursorWidth / 2),
                                            Float(cellHeight / 2))
        guard shouldDrawCursor else { return }

        var color = IndependentRowRasterizer.rgba(source.caretColor)
        color.w *= cursorOpacity
        let naturalHeight = Self.cursorHeightPixels(
            cellHeight: cellHeight / max(1, source.backingScaleFactor()),
            font: font as CTFont, scale: source.backingScaleFactor())
        let naturalY = Self.cursorNaturalY(
            cellMinY: CGFloat(position.y),
            cellHeight: cellHeight,
            naturalHeight: naturalHeight)
        var rects: [IndependentSolidRect] = []
        switch snapshot.cursorStyle {
        case .blinkBlock, .steadyBlock:
            let block = CGRect(x: CGFloat(position.x), y: naturalY,
                               width: cursorWidth, height: naturalHeight)
            if source.caretFocused {
                rects.append(.init(rect: block, color: color))
            } else {
                let thickness = max(1, source.backingScaleFactor().rounded())
                rects.append(.init(rect: CGRect(x: block.minX, y: block.minY,
                                                width: block.width, height: thickness), color: color))
                rects.append(.init(rect: CGRect(x: block.minX, y: block.maxY - thickness,
                                                width: block.width, height: thickness), color: color))
                rects.append(.init(rect: CGRect(x: block.minX, y: block.minY,
                                                width: thickness, height: block.height), color: color))
                rects.append(.init(rect: CGRect(x: block.maxX - thickness, y: block.minY,
                                                width: thickness, height: block.height), color: color))
            }
        case .blinkUnderline, .steadyUnderline:
            let thickness = Self.cursorUnderlineThicknessPixels(
                underlineThickness: source.underlineThickness(),
                scale: source.backingScaleFactor())
            rects.append(.init(rect: CGRect(x: CGFloat(position.x),
                                            y: CGFloat(position.y) + cellHeight - thickness,
                                            width: cursorWidth, height: thickness), color: color))
        case .blinkBar, .steadyBar:
            rects.append(.init(rect: CGRect(x: CGFloat(position.x),
                                            y: naturalY,
                                            width: Self.cursorBarWidthPixels(
                                                scale: source.backingScaleFactor()),
                                            height: naturalHeight), color: color))
        }
        encodeSolid(vertices: rects.flatMap { quad(rect: $0.rect, color: $0.color) },
                    encoder: encoder, resolution: resolution)

        if Self.cursorShouldInvertGlyph(
            style: snapshot.cursorStyle,
            caretFocused: source.caretFocused,
            cursorAnimating: cursorAnimating),
           let row = cursorRow,
           let texture = row.entry.coverageTexture {
            let sourceRect = CGRect(x: CGFloat(snapshot.cursorCol) * cellWidth,
                                    y: 0, width: cellWidth,
                                    height: CGFloat(row.entry.height))
            let uv = uvRect(for: sourceRect,
                            textureWidth: row.entry.width,
                            textureHeight: row.entry.height,
                            flipped: true, mode: .single)
            let drawRect = CGRect(x: CGFloat(position.x),
                                  y: CGFloat(position.y),
                                  width: cursorWidth, height: cellHeight)
            // Coverage output is premultiplied. Scale the full vector so the
            // inverted glyph fades with the block instead of leaving its RGB
            // visible when the cursor reaches the pulse trough.
            let textColor = IndependentRowRasterizer.rgba(
                source.caretTextColor ?? source.nativeBackgroundColor)
                * cursorOpacity
            encodeCoverageTexture(texture, rect: drawRect, uv: uv,
                                  color: textColor, encoder: encoder,
                                  resolution: resolution)
        }
        if cursorAnimating {
            // A display invalidation issued from inside MTKView.draw can be
            // consumed by the frame that is already being presented. Defer
            // the continuation one main-run-loop turn so a steady cursor gets
            // every glide frame even when no blinking shader or palette is
            // independently driving redraws.
            DispatchQueue.main.async { [weak self] in
                self?.requestDraw()
            }
        }
    }

    private func encodeCoverageTexture(_ texture: MTLTexture,
                                       rect: CGRect, uv: CGRect,
                                       color: SIMD4<Float>,
                                       encoder: MTLRenderCommandEncoder,
                                       resolution: SIMD2<Float>) {
        let vertices = quad(rect: rect, uv: uv, color: color)
        guard let slice = dynamicBuffers.write(vertices) else { return }
        encoder.setRenderPipelineState(core.coveragePipeline)
        var raster = IndependentRasterUniforms(
            resolution: resolution,
            coveragePower: textRenderingMode.coveragePower,
            databloomEnergy: 0)
        encoder.setVertexBuffer(slice.buffer, offset: slice.offset, index: 0)
        encoder.setVertexBytes(&raster,
                               length: MemoryLayout<IndependentRasterUniforms>.stride,
                               index: 1)
        encoder.setFragmentBytes(&raster,
                                 length: MemoryLayout<IndependentRasterUniforms>.stride,
                                 index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(core.linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: vertices.count)
    }

    // MARK: Post process

    private func ensureSceneTexture(size: CGSize,
                                    format: MTLPixelFormat) -> MTLTexture? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        if let sceneTexture, sceneTexture.width == width,
           sceneTexture.height == height,
           sceneTexture.pixelFormat == format { return sceneTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        sceneTexture = device.makeTexture(descriptor: descriptor)
        return sceneTexture
    }

    private func encodePostProcess(encoder: MTLRenderCommandEncoder,
                                   scene: MTLTexture,
                                   resolution: SIMD2<Float>,
                                   background: SIMD4<Float>,
                                   source: any MetalRenderSource,
                                   now: Double) {
        let pipeline: MTLRenderPipelineState
        if shaderMode == -1, let userPipeline { pipeline = userPipeline }
        else { pipeline = core.builtInEffects.scenePostprocess }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.setFragmentSamplerState(core.linearSampler, index: 0)
        var uniforms = IndependentCmdyUniforms(
            resolution: resolution,
            time: Float(now - startTime),
            curvature: 0.08,
            background: background,
            cursor: lastCursorCenter,
            keypressAge: Float(max(0, min(10, now - source.activityKeypressTime))),
            typingRate: source.activityTypingRate,
            opacity: background.w,
            passIndex: UInt32(max(0, shaderMode)))
        encoder.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<IndependentCmdyUniforms>.stride,
                                 index: 0)
        if shaderMode >= 1 {
            var mode = Int32(shaderMode)
            encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride,
                                     index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else {
            let rect = CGRect(x: 0, y: 0,
                              width: CGFloat(resolution.x),
                              height: CGFloat(resolution.y))
            let vertices = quad(rect: rect, color: SIMD4(repeating: 1))
            guard let slice = dynamicBuffers.write(vertices) else { return }
            var raster = IndependentRasterUniforms(resolution: resolution,
                                                    coveragePower: 1,
                                                    databloomEnergy: 0)
            encoder.setVertexBuffer(slice.buffer, offset: slice.offset, index: 0)
            encoder.setVertexBytes(&raster,
                                   length: MemoryLayout<IndependentRasterUniforms>.stride,
                                   index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: vertices.count)
        }
    }

    // MARK: Image cache

    private func texture(for image: any RenderableCellImage) -> MTLTexture? {
        let object = image as AnyObject
        let identity = ObjectIdentifier(object)
        cacheUseClock &+= 1
        if let cached = imageTextures[identity], cached.owner != nil {
            cached.lastUse = cacheUseClock
            return cached.texture
        }
        if let failed = imageTextureFailures[identity] {
            if failed.value != nil { return nil }
            imageTextureFailures.removeValue(forKey: identity)
        }
        if let pending = imageTexturePending[identity] {
            if pending.value != nil { return nil }
            imageTexturePending.removeValue(forKey: identity)
        }

        let ownerBox = WeakRenderableImage(image)
        imageTexturePending[identity] = ownerBox
        imageDecodeAttemptsForTesting += 1
        let imageBox = SendableImageBox(image.image)
        let rendererBox = WeakRendererBox(self)
        let device = self.device
        Task.detached {
            let result: MTLTexture? = autoreleasepool {
                var proposed = CGRect(origin: .zero, size: imageBox.image.size)
                guard let cgImage = imageBox.image.cgImage(
                    forProposedRect: &proposed, context: nil, hints: nil) else {
                    return nil
                }
                return try? MTKTextureLoader(device: device).newTexture(
                    cgImage: cgImage,
                    options: [.SRGB: false,
                              .origin: MTKTextureLoader.Origin.topLeft])
            }
            await MainActor.run {
                guard let self = rendererBox.renderer else { return }
                self.imageTexturePending.removeValue(forKey: identity)
                guard let owner = ownerBox.value,
                      ObjectIdentifier(owner as AnyObject) == identity else { return }
                if let result {
                    self.cacheUseClock &+= 1
                    self.imageTextures[identity] = ImageTextureRecord(
                        owner: owner as AnyObject, texture: result,
                        lastUse: self.cacheUseClock)
                    self.requestDraw()
                } else {
                    self.imageTextureFailures[identity] = ownerBox
                }
            }
        }
        return nil
    }

    func textureForTesting(_ image: any RenderableCellImage) -> MTLTexture? {
        texture(for: image)
    }

    var imageDecodePendingCountForTesting: Int { imageTexturePending.count }

    private func kittyTexture(imageId: UInt32,
                              payload: KittyImagePayload) -> MTLTexture? {
        let signature = kittySignature(payload)
        cacheUseClock &+= 1
        if var cached = kittyTextures[imageId], cached.signature == signature {
            cached.lastUse = cacheUseClock
            kittyTextures[imageId] = cached
            return cached.texture
        }
        guard !kittyFailures.contains(signature) else { return nil }
        switch payload {
        case .rgba(let bytes, let width, let height):
            guard width > 0, height > 0, width <= 16_384, height <= 16_384,
                  width <= Int.max / height,
                  width * height <= Int.max / 4,
                  bytes.count >= width * height * 4,
                  let texture = makeTexture(width: width, height: height,
                                            format: .rgba8Unorm,
                                            bytes: bytes,
                                            bytesPerRow: width * 4) else {
                kittyFailures.insert(signature)
                return nil
            }
            kittyTextures[imageId] = KittyTextureRecord(
                signature: signature, texture: texture, lastUse: cacheUseClock)
            return texture
        case .png(let data):
            guard !kittyPending.contains(signature) else { return nil }
            kittyPending.insert(signature)
            let device = self.device
            let rendererBox = WeakRendererBox(self)
            Task.detached {
                let result: MTLTexture? = autoreleasepool {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                          image.width <= 16_384, image.height <= 16_384 else { return nil }
                    return try? MTKTextureLoader(device: device).newTexture(
                        cgImage: image,
                        options: [.SRGB: false,
                                  .origin: MTKTextureLoader.Origin.topLeft])
                }
                await MainActor.run {
                    guard let self = rendererBox.renderer else { return }
                    self.kittyPending.remove(signature)
                    if let result {
                        self.cacheUseClock &+= 1
                        self.kittyTextures[imageId] = KittyTextureRecord(
                            signature: signature, texture: result,
                            lastUse: self.cacheUseClock)
                        self.requestDraw()
                    } else {
                        self.kittyFailures.insert(signature)
                    }
                }
            }
            return nil
        }
    }

    private func kittySignature(_ payload: KittyImagePayload) -> KittySignature {
        func hash<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
            bytes.prefix(4_096).reduce(UInt32(2_166_136_261)) {
                ($0 ^ UInt32($1)) &* 16_777_619
            }
        }
        switch payload {
        case .png(let data):
            return KittySignature(kind: 0, width: 0, height: 0,
                                  count: data.count, headHash: hash(data))
        case .rgba(let bytes, let width, let height):
            return KittySignature(kind: 1, width: width, height: height,
                                  count: bytes.count, headHash: hash(bytes))
        }
    }

    private func pruneImageCaches(liveKittyIds: Set<UInt32>) {
        imageTextures = imageTextures.filter { $0.value.owner != nil }
        imageTextureFailures = imageTextureFailures.filter { $0.value.value != nil }
        imageTexturePending = imageTexturePending.filter { $0.value.value != nil }
        kittyTextures = kittyTextures.filter { liveKittyIds.contains($0.key) }
        if kittyTextures.count > 128 {
            for (id, _) in kittyTextures.sorted(by: { $0.value.lastUse < $1.value.lastUse })
                .prefix(kittyTextures.count - 128) {
                kittyTextures.removeValue(forKey: id)
            }
        }
    }

    // MARK: Scheduling

    private func effectiveScrollPixels(source: any MetalRenderSource) -> CGFloat {
        guard smoothScrollEnabled else { return 0 }
        // The source owns any base device-pixel translation. Cmdy's App source
        // deliberately reports zero and keeps the rendered callback only for
        // overlays, so that observation can never feed back into this sum.
        return SmoothScrollMotion.effectiveOffset(
            source: source.scrollContentOffset.y,
            held: scrollHeldPixels, glide: scrollGlidePixels)
    }

    private func updateScroll(at now: Double) {
        guard smoothScrollEnabled, scrollHeldPixels == 0,
              scrollGlidePixels != 0 else { return }
        if scrollLastTime == 0 { scrollLastTime = now; return }
        scrollGlidePixels = SmoothScrollMotion.decayedGlide(
            scrollGlidePixels, elapsed: now - scrollLastTime)
        scrollLastTime = now
        if scrollGlidePixels == 0 {
            scrollLastTime = 0
        }
    }

    private func shouldAnimate() -> Bool {
        guard let view, view.window?.occlusionState.contains(.visible) == true else {
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        let shaderAnimated = Self.builtInContinuouslyAnimates(mode: shaderMode)
            || (shaderMode == -1 && userPipeline != nil && userShaderUsesTime)
        let cursorAnimated = cursorBlinkEligible
            && (source?.caretFocused == true)
            && now < recentActivityUntil
        let reactiveShaderAnimating = (shaderMode == 9 || shaderMode == 68)
            && shaderScroll.energy > 0
        // A precise trackpad remainder is held, not animated. Each native
        // scroll event requests its own frame; self-ticking a static remainder
        // wastes work and amplified the offset feedback regression.
        return shaderAnimated || cursorAnimated
            || Self.selectionInteractionShouldSelfAnimate(
                now: now, activeUntil: recentSelectionInteractionUntil)
            || SmoothScrollMotion.shouldSelfAnimate(glide: scrollGlidePixels)
            || reactiveShaderAnimating
    }

    private func updateAnimationTimer() {
        let animate = shouldAnimate()
        guard animate, let view else {
            // The activity window is an exact number of pulse cycles, but a
            // stalled run loop can jump from a dim frame to beyond its end.
            // Present one explicit full-opacity frame before retiring the
            // timer so a blinking cursor cannot remain dim indefinitely.
            let now = ProcessInfo.processInfo.systemUptime
            let needsFinalCursorFrame = CursorPulse.shouldPresentFinalFrame(
                timerActive: animationTimer != nil,
                blinkEligible: cursorBlinkEligible,
                caretFocused: source?.caretFocused == true,
                viewVisible: self.view?.window?.occlusionState
                    .contains(.visible) == true,
                now: now,
                activeUntil: recentActivityUntil)
            animationTimer?.invalidate()
            animationTimer = nil
            if needsFinalCursorFrame { requestDraw() }
            return
        }
        let process = ProcessInfo.processInfo
        let selectionAnimating = Self.selectionInteractionShouldSelfAnimate(
            now: process.systemUptime,
            activeUntil: recentSelectionInteractionUntil)
        let fps: Double
        if selectionAnimating {
            let displayFPS = max(
                1, view.window?.screen?.maximumFramesPerSecond
                    ?? view.preferredFramesPerSecond)
            fps = Self.interactiveContentTargetFPS(
                isKeyWindow: view.window?.isKeyWindow == true,
                thermalState: process.thermalState,
                lowPowerMode: process.isLowPowerModeEnabled,
                maximumFramesPerSecond: displayFPS)
        } else {
            fps = Self.shaderTargetFPS(
                isKeyWindow: view.window?.isKeyWindow == true,
                thermalState: process.thermalState,
                lowPowerMode: process.isLowPowerModeEnabled)
        }
        let interval = 1 / max(1, fps)
        if let timer = animationTimer,
           abs(timer.timeInterval - interval) < 0.0001 { return }
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval,
                                              repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.shouldAnimate() { self.requestDraw() }
                else { self.updateAnimationTimer() }
            }
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func targetFrameRate(for view: MTKView) -> Double {
        let process = ProcessInfo.processInfo
        if process.systemUptime < recentDirectManipulationUntil
            || SmoothScrollMotion.shouldSelfAnimate(glide: scrollGlidePixels) {
            let displayFPS = max(
                1, view.window?.screen?.maximumFramesPerSecond
                    ?? view.preferredFramesPerSecond)
            if view.preferredFramesPerSecond != displayFPS {
                view.preferredFramesPerSecond = displayFPS
            }
            return Self.interactiveContentTargetFPS(
                isKeyWindow: view.window?.isKeyWindow == true,
                thermalState: process.thermalState,
                lowPowerMode: process.isLowPowerModeEnabled,
                maximumFramesPerSecond: displayFPS)
        }
        let reactiveShader = (shaderMode == 9 || shaderMode == 68)
            && shaderScroll.energy > 0
        let shaderRequiresCadence = Self.builtInContinuouslyAnimates(
            mode: shaderMode)
            || (shaderMode == -1 && userPipeline != nil && userShaderUsesTime)
            || reactiveShader
        if shaderRequiresCadence {
            return Self.shaderTargetFPS(
                isKeyWindow: view.window?.isKeyWindow == true,
                thermalState: process.thermalState,
                lowPowerMode: process.isLowPowerModeEnabled)
        }
        return Self.staticContentTargetFPS(
            isKeyWindow: view.window?.isKeyWindow == true,
            thermalState: process.thermalState,
            lowPowerMode: process.isLowPowerModeEnabled)
    }

    private func scheduleCoalescedDraw(after delay: Double) {
        guard coalescedDrawTimer == nil else { return }
        coalescedDrawTimer = Timer.scheduledTimer(
            withTimeInterval: max(0.001, delay), repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coalescedDrawTimer = nil
                self.requestDraw()
            }
        }
        if let coalescedDrawTimer {
            RunLoop.main.add(coalescedDrawTimer, forMode: .common)
        }
    }

    private func resetFramePacing() {
        framePacer.reset()
        coalescedDrawTimer?.invalidate()
        coalescedDrawTimer = nil
    }

    private func requestDraw() {
        guard let view else { return }
        view.setNeedsDisplay(view.bounds)
    }

    private func scheduleDrawableRecovery() {
        guard recoveryTimer == nil else { return }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 0.1,
                                             repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recoveryTimer = nil
                self.requestDraw()
            }
        }
    }

    // MARK: Geometry helpers

    private func transformed(_ rect: CGRect,
                             displayIndex: Int,
                             mode: RenderLineMode,
                             xOrigin: CGFloat,
                             yOrigin: CGFloat,
                             cellHeight: CGFloat) -> CGRect {
        Self.lineModeRect(rect, displayIndex: displayIndex, mode: mode,
                          xOrigin: xOrigin, yOrigin: yOrigin,
                          cellHeight: cellHeight)
    }

    private func uvRect(for rect: CGRect,
                        textureWidth: Int,
                        textureHeight: Int,
                        flipped: Bool,
                        mode: RenderLineMode) -> CGRect {
        guard textureWidth > 0, textureHeight > 0 else { return .zero }
        var y = rect.minY / CGFloat(textureHeight)
        var height = rect.height / CGFloat(textureHeight)
        if mode == .doubledTop { height *= 0.5 }
        if mode == .doubledDown { y += height * 0.5; height *= 0.5 }
        let value = CGRect(x: rect.minX / CGFloat(textureWidth), y: y,
                           width: rect.width / CGFloat(textureWidth), height: height)
        return flipped
            ? CGRect(x: value.minX, y: value.maxY,
                     width: value.width, height: -value.height)
            : value
    }

    private func quad(rect: CGRect,
                      uv: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                      color: SIMD4<Float>,
                      preserveUVOrientation: Bool = false)
        -> [IndependentQuadVertex] {
        let x0 = Float(rect.minX), x1 = Float(rect.maxX)
        let y0 = Float(rect.minY), y1 = Float(rect.maxY)
        let u0 = Float(preserveUVOrientation ? uv.origin.x : uv.minX)
        let u1 = Float(preserveUVOrientation
            ? uv.origin.x + uv.size.width : uv.maxX)
        let v0 = Float(preserveUVOrientation ? uv.origin.y : uv.minY)
        let v1 = Float(preserveUVOrientation
            ? uv.origin.y + uv.size.height : uv.maxY)
        return [
            .init(position: SIMD2(x0, y0), uv: SIMD2(u0, v0), color: color),
            .init(position: SIMD2(x1, y0), uv: SIMD2(u1, v0), color: color),
            .init(position: SIMD2(x0, y1), uv: SIMD2(u0, v1), color: color),
            .init(position: SIMD2(x1, y0), uv: SIMD2(u1, v0), color: color),
            .init(position: SIMD2(x1, y1), uv: SIMD2(u1, v1), color: color),
            .init(position: SIMD2(x0, y1), uv: SIMD2(u0, v1), color: color),
        ]
    }

    // MARK: Isolated compatibility test hook

    func cacheGlyphForTesting(font: CTFont, glyph: CGGlyph) -> GlyphEntry? {
        let key = CompatibilityGlyphKey(
            name: CTFontCopyPostScriptName(font) as String,
            sizeBits: Double(CTFontGetSize(font)).bitPattern,
            glyph: glyph)
        if let cached = compatibilityGlyphs[key] { return cached }
        guard let bitmap = compatibilityRasterizer.rasterize(font: font,
                                                              glyph: glyph) else {
            return nil
        }
        let atlas: GlyphAtlas
        let kind: GlyphAtlasKind
        if bitmap.isColor {
            if compatibilityColorAtlas == nil {
                compatibilityColorAtlas = GlyphAtlas(device: device, format: .bgra)
                if compatibilityColorAtlas != nil { colorAtlasAllocationCount += 1 }
            }
            guard let value = compatibilityColorAtlas else { return nil }
            atlas = value
            kind = .color
        } else {
            if compatibilityGrayAtlas == nil {
                compatibilityGrayAtlas = GlyphAtlas(device: device, format: .grayscale)
            }
            guard let value = compatibilityGrayAtlas else { return nil }
            atlas = value
            kind = .grayscale
        }
        let padding = textRenderingMode.padsAtlas ? 1 : 0
        guard let region = atlas.ensureRegion(width: bitmap.width + padding * 2,
                                              height: bitmap.height + padding * 2) else {
            return nil
        }
        if let evicted = atlas.evictedPage {
            compatibilityGlyphs = compatibilityGlyphs.filter {
                $0.value.atlasKind != kind || $0.value.region.page != evicted
            }
        }
        atlas.write(region: region, pixels: bitmap.pixels,
                    width: bitmap.width, height: bitmap.height,
                    padding: padding)
        let entry = GlyphEntry(region: region,
                               size: CGSize(width: bitmap.width,
                                            height: bitmap.height),
                               bearing: bitmap.bearing,
                               isColor: bitmap.isColor, atlasKind: kind)
        compatibilityGlyphs[key] = entry
        return entry
    }
}
