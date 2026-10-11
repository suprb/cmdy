import AppKit
import CmdyNative
import CoreGraphics
import CoreText
import Foundation
import Metal

struct IndependentVisibleRowRequest: Equatable, Sendable {
    let displayIndex: Int
    let sourceRow: Int
    let cacheRow: Int
}

extension GridSnapshot {
    var independentVisibleRowRequests: [IndependentVisibleRowRequest] {
        independentVisibleRowRequests(extraRows: 0)
    }
    func independentVisibleRowRequests(extraRows: Int) -> [IndependentVisibleRowRequest] {
        let count = cmdy_render_visible_rows(Int64(rows), Int64(bufferLineCount), Int64(displayTopRow), Int64(retainedRowOrigin), Int64(extraRows), nil, 0)
        guard count > 0 else { return [] }
        var values = [CmdyRenderVisibleRow](repeating: .init(), count: count)
        values.withUnsafeMutableBufferPointer {
            _ = cmdy_render_visible_rows(Int64(rows), Int64(bufferLineCount), Int64(displayTopRow), Int64(retainedRowOrigin), Int64(extraRows), $0.baseAddress, $0.count)
        }
        return values.map { .init(displayIndex: Int($0.display_index), sourceRow: Int($0.source_row), cacheRow: Int($0.cache_row)) }
    }
    func independentDisplayRow(forSourceRow row: Int) -> Int? {
        var value: Int64 = 0
        return cmdy_render_display_row(Int64(row), Int64(displayTopRow), Int64(rows), &value) ? Int(value) : nil
    }
    func independentCacheRow(forSourceRow row: Int) -> Int? {
        var value: Int64 = 0
        return cmdy_render_cache_row(Int64(row), Int64(retainedRowOrigin), &value) ? Int(value) : nil
    }
}

struct ViewportTranslation: Equatable, Sendable {
    let x: Float
    let y: Float
    init(contentXOrigin: CGFloat, viewHeight: CGFloat, topContentInset: CGFloat,
         cellHeight: CGFloat, displayRow: Int, scale: CGFloat) {
        let value = cmdy_render_viewport_translation(contentXOrigin, viewHeight, topContentInset, cellHeight, Int64(displayRow), scale)
        x = value.x; y = value.y
    }
}
struct SmoothScrollTranslation: Equatable, Sendable {
    let snappedPoints: CGFloat
    let renderedPoints: CGFloat
    let yShiftPixels: Float
    init(offsetPixels: CGFloat, scale: CGFloat) {
        let value = cmdy_render_scroll_translation(offsetPixels, scale)
        snappedPoints = value.snapped_points
        renderedPoints = value.rendered_points
        yShiftPixels = value.y_shift_pixels
    }
}
struct SmoothScrollMotion: Sendable {
    static func effectiveOffset(source: CGFloat, held: CGFloat, glide: CGFloat) -> CGFloat {
        cmdy_render_effective_scroll(source, held, glide)
    }
    static func decayedGlide(_ value: CGFloat, elapsed: Double) -> CGFloat {
        cmdy_render_decayed_glide(value, elapsed)
    }
    static func accumulatedGlide(current: CGFloat, impulse: CGFloat, cellHeight: CGFloat) -> CGFloat {
        cmdy_render_accumulated_glide(current, impulse, cellHeight)
    }
    static func shouldSelfAnimate(glide: CGFloat) -> Bool { cmdy_render_scroll_self_animates(glide) }
    static func fringeRows(offset: CGFloat, cellHeight: CGFloat, enabled: Bool) -> Int {
        Int(cmdy_render_fringe_rows(offset, cellHeight, enabled))
    }
}
struct TerminalGridScissor: Sendable {
    let rect: MTLScissorRect
    static func deviceTopInset(_ inset: CGFloat, scale: CGFloat) -> Int {
        Int(cmdy_render_device_top_inset(inset, scale))
    }
    init(drawableSize: CGSize, topInset: CGFloat, bottomInset: CGFloat, leftInset: CGFloat = 0, scale: CGFloat) {
        let value = cmdy_render_scissor(drawableSize.width, drawableSize.height, topInset, bottomInset, leftInset, scale)
        rect = .init(x: Int(value.x), y: Int(value.y), width: Int(value.width), height: Int(value.height))
    }
}
struct CursorGlideStep: Sendable {
    let position: SIMD2<Float>
    let isAnimating: Bool
    init(position: SIMD2<Float>, isAnimating: Bool) {
        self.position = position; self.isAnimating = isAnimating
    }
}
enum CursorPulse {
    static func opacity(blinks: Bool, caretFocused: Bool, now: Double, lastActivityTime: Double, activeUntil: Double) -> Float {
        cmdy_render_cursor_opacity(blinks, caretFocused, now, lastActivityTime, activeUntil)
    }
    static func shouldPresentFinalFrame(timerActive: Bool, blinkEligible: Bool, caretFocused: Bool, viewVisible: Bool, now: Double, activeUntil: Double) -> Bool {
        cmdy_render_final_cursor_frame(timerActive, blinkEligible, caretFocused, viewVisible, now, activeUntil)
    }
}
enum CursorGlide {
    static func resolvedStep(from: SIMD2<Float>, to: SIMD2<Float>, shouldDraw: Bool,
                             smoothEnabled: Bool, isLiveResize: Bool = false,
                             deltaTime: Float, speed: Float, maxDistance: Float,
                             cellSize: SIMD2<Float>) -> CursorGlideStep {
        let value = cmdy_render_cursor_step(.init(x: from.x, y: from.y), .init(x: to.x, y: to.y), shouldDraw, smoothEnabled, isLiveResize, deltaTime, speed, maxDistance, .init(x: cellSize.x, y: cellSize.y))
        return .init(position: SIMD2(value.position.x, value.position.y), isAnimating: value.is_animating)
    }
    static func step(from: SIMD2<Float>, to: SIMD2<Float>, deltaTime: Float,
                     speed: Float, maxDistance: Float, cellSize: SIMD2<Float>) -> CursorGlideStep {
        resolvedStep(from: from, to: to, shouldDraw: true, smoothEnabled: true,
                     deltaTime: deltaTime, speed: speed, maxDistance: maxDistance, cellSize: cellSize)
    }
}
struct ShaderScrollEnvelope: Sendable {
    private var native = CmdyRenderScrollEnvelope()
    var velocity: Float { native.velocity }
    var energy: Float { native.energy }
    init() {}
    mutating func noteScroll(deltaPixels: CGFloat, at time: Double = ProcessInfo.processInfo.systemUptime) {
        cmdy_render_envelope_scroll(&native, deltaPixels, time)
    }
    mutating func update(at time: Double = ProcessInfo.processInfo.systemUptime) {
        cmdy_render_envelope_update(&native, time)
    }
}
struct FrameBuildPacer: Sendable {
    private var native = CmdyRenderFramePacer()
    var lastBuildTime: Double? { native.has_last_build ? native.last_build_time : nil }
    func delay(at time: Double, targetFPS: Double) -> Double { cmdy_render_pacer_delay(native, time, targetFPS) }
    mutating func markBuild(at time: Double) { cmdy_render_pacer_mark(&native, time) }
    mutating func reset() { cmdy_render_pacer_reset(&native) }
}

private extension CGRect {
    var scheduleNative: CmdyRenderRect { .init(x: origin.x, y: origin.y, width: width, height: height) }
    init(scheduleNative value: CmdyRenderRect) { self.init(x: value.x, y: value.y, width: value.width, height: value.height) }
}
private func nativeThermal(_ value: ProcessInfo.ThermalState) -> UInt8 { UInt8(exactly: value.rawValue) ?? 255 }

@MainActor
extension MetalTerminalRenderer {
    static func selectionRect(columns: ClosedRange<Int>?, columnCount: Int, cellWidth: CGFloat, cellHeight: CGFloat) -> CGRect? {
        guard let columns else { return nil }
        var result = CmdyRenderRect()
        return cmdy_render_selection_rect(Int64(columns.lowerBound), Int64(columns.upperBound), Int64(columnCount), cellWidth, cellHeight, &result) ? CGRect(scheduleNative: result) : nil
    }
    static func backgroundFragments(_ rect: CGRect, excluding selection: CGRect?) -> [CGRect] {
        var result = [CmdyRenderRect](repeating: .init(), count: 2)
        let count: Int
        if var selected = selection?.scheduleNative {
            count = cmdy_render_background_fragments(rect.scheduleNative, &selected, &result)
        } else {
            count = cmdy_render_background_fragments(rect.scheduleNative, nil, &result)
        }
        return result.prefix(count).map { CGRect(scheduleNative: $0) }
    }
    public static func interactiveContentTargetFPS(isKeyWindow: Bool, thermalState: ProcessInfo.ThermalState, lowPowerMode: Bool, maximumFramesPerSecond: Int) -> Double {
        cmdy_render_interactive_fps(isKeyWindow, nativeThermal(thermalState), lowPowerMode, Int64(maximumFramesPerSecond))
    }
    static func selectionInteractionShouldSelfAnimate(now: Double, activeUntil: Double) -> Bool { cmdy_render_selection_animates(now, activeUntil) }
    static func builtInContinuouslyAnimates(mode: Int) -> Bool { cmdy_render_continuously_animates(Int64(mode)) }
    static func staticContentTargetFPS(isKeyWindow: Bool, thermalState: ProcessInfo.ThermalState, lowPowerMode: Bool) -> Double {
        cmdy_render_static_fps(isKeyWindow, nativeThermal(thermalState), lowPowerMode)
    }
    static func shaderTargetFPS(isKeyWindow: Bool, thermalState: ProcessInfo.ThermalState, lowPowerMode: Bool) -> Double {
        cmdy_render_shader_fps(isKeyWindow, nativeThermal(thermalState), lowPowerMode)
    }
    static func cursorBlinkEligible(snapshot: GridSnapshot, hostCursorHidden: Bool) -> Bool {
        cmdy_render_cursor_blink_eligible(snapshot.cursorStyle.blinks, snapshot.cursorHidden, hostCursorHidden, Int64(snapshot.cursorCol), Int64(snapshot.cols), Int64(snapshot.cursorRow), Int64(snapshot.displayTopRow), Int64(snapshot.rows))
    }
    static func cursorShouldInvertGlyph(style: RenderCursorStyle, caretFocused: Bool, cursorAnimating: Bool) -> Bool {
        cmdy_render_cursor_inverts_glyph(style.isBlock, caretFocused, cursorAnimating)
    }
    static func cursorHeightPixels(cellHeight: CGFloat, font: CTFont, scale: CGFloat) -> CGFloat {
        withExtendedLifetime(font) { cmdy_render_cursor_font_height(cellHeight, unsafeBitCast(font, to: UnsafeRawPointer.self), scale) }
    }
    static func cursorNaturalY(cellMinY: CGFloat, cellHeight: CGFloat, naturalHeight: CGFloat) -> CGFloat { cmdy_render_cursor_natural_y(cellMinY, cellHeight, naturalHeight) }
    static func cursorUnderlineThicknessPixels(underlineThickness: CGFloat, scale: CGFloat) -> CGFloat { cmdy_render_cursor_underline(underlineThickness, scale) }
    static func cursorBarWidthPixels(scale: CGFloat) -> CGFloat { cmdy_render_cursor_bar(scale) }
    static func lineModeRect(_ rect: CGRect, displayIndex: Int, mode: RenderLineMode, xOrigin: CGFloat, yOrigin: CGFloat, cellHeight: CGFloat) -> CGRect {
        let nativeMode: UInt32
        switch mode { case .single: nativeMode = 0; case .doubleWidth: nativeMode = 1; case .doubledTop: nativeMode = 2; case .doubledDown: nativeMode = 3 }
        return CGRect(scheduleNative: cmdy_render_line_mode_rect(rect.scheduleNative, Int64(displayIndex), nativeMode, xOrigin, yOrigin, cellHeight))
    }
    static func requiresOffscreenScene(shaderMode: Int, hasBuiltInPipeline: Bool, hasUserPipeline: Bool) -> Bool {
        cmdy_render_requires_offscreen(Int64(shaderMode), hasBuiltInPipeline, hasUserPipeline)
    }
}
