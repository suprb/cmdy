import AppKit
import CmdyNative
import Foundation
import MetalKit

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

@MainActor private final class Source: MetalRenderSource, SnapshotRowRevisionSource, MetalSelectionRenderSource {
    let normalFont = NSFont(name: "Menlo", size: 14)!
    lazy var text = NSMutableAttributedString(string: "Aé𝄞", attributes: [.font: normalFont, .foregroundColor: NSColor.white])
    var top = 100, rowCount = 2
    var versions: [Int: UInt64] = [:]
    var context: UInt64 = 7
    var dirty: ClosedRange<Int>? = nil
    var selected: ClosedRange<Int>? = 1...2
    var attached: (any RenderableCellImage)?
    var lineReads = 0, snapshots = 0, revisionReads = 0
    var onLine: (() -> Void)?
    var underline: CGFloat = 2
    var gridCaptured = false
    var kittyPayloads: [UInt32: KittyImagePayload] = [:]
    func captureGrid() -> GridSnapshot {
        gridCaptured = true; snapshots += 1
        return GridSnapshot(rows: rowCount, cols: 8, bufferLineCount: 2000, retainedRowOrigin: 100,
            displayTopRow: top, liveTopRow: 110, cursorRow: top + 1, cursorCol: 2,
            cursorHidden: false, cursorStyle: .steadyBlock, isAlternateBuffer: false)
    }
    func info(_ row: Int) -> ViewLineInfo {
        ViewLineInfo(segments: [ViewLineSegment(column: 0, columnWidth: 1, characterCount: 3,
            attributedString: text, cellUTF16Boundaries: [0, 1, 2, 4])], images: row == top ? attached.map { [$0] } : nil)
    }
    func lineInfo(forRow row: Int) -> ViewLineInfo { precondition(gridCaptured); lineReads += 1; onLine?(); return info(row) }
    func lineRenderMode(forRow row: Int) -> RenderLineMode { .single }
    func lineVersion(forRow row: Int) -> UInt64 { versions[row] ?? 1 }
    func snapshotRowRevision(forRow row: Int) -> SnapshotRowRevision? {
        revisionReads += 1
        // Match CmdySnapshotRowContext: image-bearing rows (and any Kitty
        // frame) must not advertise the text-only fast reuse token.
        guard (row != top || attached == nil) && kittyPayloads.isEmpty else { return nil }
        return .init(content: lineVersion(forRow: row), context: context)
    }
    func cursorCellAttributedString() -> NSAttributedString? { nil }
    var kittyStamp: KittyCacheStamp { .init(imagesCount: kittyPayloads.count, placementsCount: kittyPayloads.count, nextImageId: 0, nextPlacementId: 0) }
    func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec] {
        kittyPayloads.keys.map { .init(imageId: $0, placementId: 9, cols: 2, rows: 3, pixelOffsetX: 4, pixelOffsetY: 5) }
    }
    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? { kittyPayloads[imageId] }
    var kittyLiveImageIds: Set<UInt32> { Set(kittyPayloads.keys) }
    var viewBounds: CGRect { .init(x: 0, y: 0, width: 96, height: 40) }
    func backingScaleFactor() -> CGFloat { precondition(gridCaptured); return 1 }
    var cellSize: CGSize { .init(width: 12, height: 20) }
    func underlinePosition() -> CGFloat { underline }
    func underlineThickness() -> CGFloat { 1 }
    var contentXOrigin: CGFloat { 0 }
    var topContentInset: CGFloat { 0 }
    var bottomContentInset: CGFloat { 0 }
    var leftContentInset: CGFloat { 0 }
    var scrollContentOffset: CGPoint { .zero }
    func getImageScale() -> CGFloat { 1 }
    var nativeForegroundColor: NSColor { .white }
    var nativeBackgroundColor: NSColor { .black }
    var caretColor: NSColor { .green }
    var caretTextColor: NSColor? { .black }
    var caretFocused: Bool { true }
    var antiAliasCustomBlockGlyphs: Bool { true }
    var metalBufferingMode: MetalBufferingMode { .perRowPersistent }
    func consumeDirtyRows() -> ClosedRange<Int>? { let result = dirty; dirty = nil; return result }
    var activityKeypressTime: Double { 3 }
    var activityTypingRate: Float { 4 }
    var selectionBackgroundColor: NSColor { .red }
    func selectionColumns(forRow row: Int) -> ClosedRange<Int>? { selected }
}


@MainActor private func waitFor(_ name: String, timeout: Double = 8,
                               _ condition: () -> Bool) async throws {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() {
        precondition(ProcessInfo.processInfo.systemUptime < end, "Timed out: " + name)
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
@MainActor private func pixels(_ texture: any MTLTexture) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    bytes.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    }
    return bytes
}
@MainActor private func targetTexture(_ device: any MTLDevice, width: Int = 96, height: Int = 40) -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
    return device.makeTexture(descriptor: descriptor)!
}
@main private struct AppOwnerSmoke {
    @MainActor static func main() async throws {
        let device = MTLCreateSystemDefaultDevice()!
        let source = Source()
        var config = cmdy_render_schedule_default_config()
        config.smooth_cursor = false; config.smooth_scroll = false
        let referenceFrame = try ProducerFrameCapture().capture(source: source,
            environment: .init(identity: .init(surface: 777, epoch: 1, sequence: 1),
                drawableSize: CGSize(width: 96, height: 40), config: config,
                motion: .init(), preset: .current, liveResize: false, now: 1))
        let reference = try verifySwiftTargetPipeline(frame: referenceFrame.input)
        // No NSApplication, NSWindow, drawable acquisition, PTY or user input.
        // MTKView is only the normal delegate adapter's local source of geometry.
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 96, height: 40), device: device)
        view.autoResizeDrawable = false; view.drawableSize = CGSize(width: 96, height: 40)
        let renderer = try MetalTerminalRenderer(view: view, source: source)
        defer { renderer.close() }
        var visible = true
        renderer.scheduler.environmentForTesting = {
            .init(now: ProcessInfo.processInfo.systemUptime, cell_height_pixels: 20, maximum_fps: 120,
                has_view: true, has_source: true, visible: visible, key_window: true,
                caret_focused: false, low_power: false, thermal: 0)
        }
        var texture = targetTexture(device)
        var captures = 0, completions = 0, acquisitions = 0
        renderer.onCaptureRequestedForTesting = { source.gridCaptured = false; captures += 1 }
        renderer.onFrameCompletedForTesting = { completions += 1 }
        renderer.targetProviderForTesting = { identity in
            precondition(Thread.isMainThread); acquisitions += 1
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let target = try CapturedRenderTarget.capture(identity: identity, drawable: nil, pass: pass).get()
            pass.colorAttachments[0].texture = nil
            return (target, CGSize(width: texture.width, height: texture.height))
        }
        // Controls are posted before READY is delivered. An older timer START
        // must survive the following config epoch when cadence is unchanged.
        renderer.shaderMode = 1
        renderer.smoothCursorEnabled = false
        renderer.smoothScrollEnabled = false
        let configured = await renderer.synchronizeForTesting()!
        precondition(configured.config.shader_mode == 1 && !configured.config.smooth_cursor)
        precondition(renderer.animationTimerIsActiveForTesting)
        renderer.shaderMode = 0
        _ = await renderer.synchronizeForTesting()
        precondition(!renderer.animationTimerIsActiveForTesting)
        print("app adapter: startup controls and ordered cross-epoch timer actions PASS")

        @MainActor func drawFrame() async throws {
            // A functional fixture waits out native pacing; these are not samples.
            try await Task.sleep(nanoseconds: 25_000_000)
            let completed = completions, presented = MetalTerminalRenderer.framesPresented
            renderer.draw(in: view)
            try await waitFor("real Metal completion") {
                completions > completed && MetalTerminalRenderer.framesPresented > presented
            }
            precondition(renderer.lastFailure == nil)
        }
        try await drawFrame()
        precondition(pixels(texture) == reference)
        let first = await renderer.synchronizeForTesting()!
        precondition(first.row_count == 2 && first.row_bytes > 0)
        let reads = source.lineReads
        try await drawFrame()
        precondition(source.lineReads == reads && pixels(texture) == reference)
        print("app adapter: production capture, real Metal pixels and clean row reuse PASS")

        let epoch = renderer.session.epoch
        renderer.invalidateRowCache()
        precondition(renderer.session.epoch != epoch)
        let cleared = await renderer.synchronizeForTesting()!
        precondition(cleared.row_count == 0 && cleared.row_bytes == 0)
        try await drawFrame()
        precondition(source.lineReads > reads && pixels(texture) == reference)
        print("app adapter: immediate invalidation, owner cache release and rebuild PASS")

        source.rowCount = 0; source.dirty = 100...101
        let beforeInvalid = captures, beforeAcquire = acquisitions
        try await Task.sleep(nanoseconds: 25_000_000)
        renderer.draw(in: view)
        try await waitFor("invalid geometry capture") { captures > beforeInvalid }
        let invalid = await renderer.synchronizeForTesting()!
        precondition(!invalid.inspection.drawing && acquisitions == beforeAcquire && source.dirty != nil)
        let stable = captures
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(captures == stable && renderer.lastFailure == nil)
        source.rowCount = 2
        try await drawFrame()
        print("app adapter: invalid geometry consumes no drawable or dirty rows and does not loop PASS")

        source.attached = UnsupportedImage(); source.dirty = 100...101; source.versions[100] = 2
        renderer.draw(in: view)
        // An explicit request wakes native pacing without depending on NSWindow.
        renderer.noteKeyboardInteraction()
        try await waitFor("capture failure report") { renderer.lastFailure != nil }
        renderer.cancelKeyboardInteraction()
        _ = await renderer.synchronizeForTesting()
        let failed = captures
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(captures == failed)
        source.attached = nil; source.versions[100] = 3; source.dirty = 100...101
        renderer.invalidateRowCache()
        try await drawFrame()
        print("app adapter: explicit source failure, no retry loop and later recovery PASS")

        renderer.invalidateRowCache(); _ = await renderer.synchronizeForTesting()
        let beforeReentry = captures, presentedBeforeReentry = MetalTerminalRenderer.framesPresented
        source.onLine = { source.onLine = nil; renderer.invalidateRowCache() }
        renderer.draw(in: view)
        try await waitFor("reentrant capture") { captures > beforeReentry }
        _ = await renderer.synchronizeForTesting()
        precondition(MetalTerminalRenderer.framesPresented == presentedBeforeReentry)
        try await drawFrame()
        print("app adapter: source reentry invalidates the captured frame before publication PASS")

        texture = targetTexture(device, width: 192, height: 80)
        view.drawableSize = CGSize(width: 192, height: 80)
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        try await drawFrame()
        precondition(pixels(texture).enumerated().contains { $0.offset % 4 != 3 && $0.element != 0 })
        print("app adapter: resize captures the new target dimensions and completes on Metal PASS")

        visible = false; renderer.shaderMode = 1
        _ = await renderer.synchronizeForTesting()
        let hidden = captures
        renderer.draw(in: view); _ = await renderer.synchronizeForTesting()
        precondition(captures == hidden && !renderer.animationTimerIsActiveForTesting)
        visible = true; renderer.shaderMode = 0
        _ = await renderer.synchronizeForTesting()
        try await drawFrame()
        print("app adapter: hidden surface stops work and resumes with current content PASS")

        let loaded = await renderer.loadUserShader(source: "float4 cmdy_main(float2 uv, float4 sceneColor, constant CmdyUniforms &u, texture2d<float> scene, sampler smp) { return sceneColor; }")
        precondition(loaded == nil, loaded ?? "")
        let installed = await renderer.synchronizeForTesting()!
        precondition(installed.config.has_user_pipeline)
        let invalidShader = await renderer.loadUserShader(source: "garbage ((")
        precondition(invalidShader != nil)
        let tooLarge = await renderer.loadUserShader(source: String(repeating: "x", count: 1_048_577))
        precondition(tooLarge?.contains("limit") == true)
        let clearError = await renderer.loadUserShader(source: nil)
        precondition(clearError == nil)
        let shaderState = await renderer.synchronizeForTesting()!
        precondition(!shaderState.config.has_user_pipeline)
        print("app adapter: asynchronous shader errors, size rejection and clear replies PASS")

        renderer.onCaptureRequestedForTesting = { captures += 1; renderer.close() }
        let beforeClose = MetalTerminalRenderer.framesPresented
        renderer.draw(in: view)
        try await waitFor("close from capture") { renderer.session.epoch == 0 }
        async let drain1: Void = renderer.shutdown()
        async let drain2: Void = renderer.shutdown()
        _ = await (drain1, drain2)
        precondition(MetalTerminalRenderer.framesPresented == beforeClose)
        let closedState = await renderer.synchronizeForTesting()
        precondition(closedState == nil)
        renderer.draw(in: view)
        print("app adapter: close during capture rejects publication and concurrent shutdown drains PASS")
    }
}
