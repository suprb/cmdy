import AppKit
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
    /// Renderer sources expose rows in retained-buffer-local coordinates.
    /// Cache rows add the retained origin so surviving lines keep their
    /// identity when the buffer drops old scrollback and rebases local rows.
    var independentVisibleRowRequests: [IndependentVisibleRowRequest] {
        independentVisibleRowRequests(extraRows: 0)
    }

    /// Include retained rows just outside the viewport while the composed grid
    /// is translated between row boundaries. Without this fringe a fractional
    /// scroll exposes the clear color until the model advances a whole row,
    /// which makes an otherwise continuous gesture look like a hard jump.
    func independentVisibleRowRequests(
        extraRows requestedExtraRows: Int
    ) -> [IndependentVisibleRowRequest] {
        guard rows > 0, bufferLineCount > 0 else { return [] }
        let extraRows = min(bufferLineCount, max(0, requestedExtraRows))
        var requests: [IndependentVisibleRowRequest] = []
        requests.reserveCapacity(min(bufferLineCount, rows + extraRows * 2))
        for displayIndex in (-extraRows)..<(rows + extraRows) {
            let (sourceRow, sourceOverflow) = displayTopRow
                .addingReportingOverflow(displayIndex)
            guard !sourceOverflow else { continue }
            guard sourceRow >= 0, sourceRow < bufferLineCount else { continue }
            let (cacheRow, overflow) = retainedRowOrigin.addingReportingOverflow(sourceRow)
            guard !overflow else { continue }
            requests.append(IndependentVisibleRowRequest(
                displayIndex: displayIndex,
                sourceRow: sourceRow,
                cacheRow: cacheRow))
        }
        return requests
    }

    func independentDisplayRow(forSourceRow sourceRow: Int) -> Int? {
        let displayRow = sourceRow - displayTopRow
        guard displayRow >= 0, displayRow < rows else { return nil }
        return displayRow
    }

    func independentCacheRow(forSourceRow sourceRow: Int) -> Int? {
        let (cacheRow, overflow) = retainedRowOrigin.addingReportingOverflow(sourceRow)
        return overflow ? nil : cacheRow
    }
}

struct ViewportTranslation: Equatable, Sendable {
    let x: Float
    let y: Float

    init(contentXOrigin: CGFloat,
                viewHeight: CGFloat,
                topContentInset: CGFloat,
                cellHeight: CGFloat,
                displayRow: Int,
                scale: CGFloat) {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        let rawX = contentXOrigin * safeScale
        let rawY = (viewHeight - topContentInset
                    - CGFloat(displayRow + 1) * cellHeight) * safeScale
        x = Float(rawX.rounded())
        y = Float(rawY.rounded())
    }
}

struct SmoothScrollTranslation: Equatable, Sendable {
    let snappedPoints: CGFloat
    let renderedPoints: CGFloat
    let yShiftPixels: Float

    init(offsetPixels: CGFloat, scale: CGFloat) {
        let resolvedScale: CGFloat
        switch scale {
        case let candidate where candidate.isFinite && candidate > 0:
            resolvedScale = candidate.clamped(to: 1...16)
        default:
            resolvedScale = 1
        }
        let finiteOffset = offsetPixels.isFinite ? offsetPixels : 0
        let boundedOffset = finiteOffset.clamped(to: -1_000_000...1_000_000)
        // The renderer contract defines this value in device pixels. That
        // preserves the locked fractional-scroll raster at every backing
        // scale; the App converts its point-space gesture before calling us.
        let deviceTranslation = boundedOffset.rounded()
        snappedPoints = deviceTranslation / resolvedScale
        yShiftPixels = Float(-deviceTranslation)
        renderedPoints = -snappedPoints
    }
}

private extension CGFloat {
    func clamped(to interval: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(interval.upperBound, Swift.max(interval.lowerBound, self))
    }
}

struct SmoothScrollMotion: Sendable {
    static func effectiveOffset(
        source: CGFloat, held: CGFloat, glide: CGFloat
    ) -> CGFloat {
        guard source.isFinite, held.isFinite, glide.isFinite else { return 0 }
        return source + held + glide
    }

    static func decayedGlide(_ value: CGFloat, elapsed: Double) -> CGFloat {
        guard value.isFinite, elapsed.isFinite else { return 0 }
        let dt = max(0.001, min(0.05, elapsed))
        // Wheel smoothing should bridge frames, not trail the user's hand.
        // This reaches 95% settlement in roughly 75 ms.
        let next = value * exp(-40 * dt)
        return abs(next) < 0.5 ? 0 : next
    }

    static func accumulatedGlide(
        current: CGFloat, impulse: CGFloat, cellHeight: CGFloat
    ) -> CGFloat {
        guard current.isFinite, impulse.isFinite else { return 0 }
        let safeCellHeight = cellHeight.isFinite && cellHeight > 0
            ? cellHeight : 16
        // Never let a burst place the visible pixels several rows behind the
        // already-updated terminal model. A small bridge preserves motion
        // continuity while keeping wheel input immediate.
        let cap = max(1, safeCellHeight * 1.25)
        return max(-cap, min(cap, current + impulse))
    }

    static func shouldSelfAnimate(glide: CGFloat) -> Bool {
        glide.isFinite && abs(glide) >= 0.5
    }

    static func fringeRows(
        offset: CGFloat, cellHeight: CGFloat, enabled: Bool
    ) -> Int {
        guard enabled, offset.isFinite, cellHeight.isFinite,
              cellHeight > 0, abs(offset) > 0.5 else { return 0 }
        return Int(ceil(abs(offset) / cellHeight)) + 1
    }
}

struct TerminalGridScissor: Sendable {
    let rect: MTLScissorRect

    static func deviceTopInset(_ inset: CGFloat, scale: CGFloat) -> Int {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        return max(0, Int((inset * safeScale).rounded(.up)))
    }

    init(drawableSize: CGSize,
                topInset: CGFloat,
                bottomInset: CGFloat,
                leftInset: CGFloat = 0,
                scale: CGFloat) {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        let width = max(0, Int(drawableSize.width.rounded(.down)))
        let height = max(0, Int(drawableSize.height.rounded(.down)))
        let left = min(width, max(0, Int((leftInset * safeScale).rounded())))
        let top = min(height, Self.deviceTopInset(topInset, scale: safeScale))
        let bottom = min(height - top,
                         max(0, Int((bottomInset * safeScale).rounded())))
        rect = MTLScissorRect(x: left, y: top, width: max(0, width - left),
                              height: max(0, height - top - bottom))
    }
}

struct CursorGlideStep: Sendable {
    let position: SIMD2<Float>
    let isAnimating: Bool

    init(position: SIMD2<Float>, isAnimating: Bool) {
        self.position = position
        self.isAnimating = isAnimating
    }
}

enum CursorPulse {
    /// Match the inline palette's soft 1.2-second cursor fade. Activity starts
    /// a fresh fully-visible cycle; after the renderer's bounded activity
    /// window the cursor settles at full opacity without a discontinuity (the
    /// 12-second window is exactly ten pulse cycles).
    static func opacity(blinks: Bool,
                        caretFocused: Bool,
                        now: Double,
                        lastActivityTime: Double,
                        activeUntil: Double) -> Float {
        guard blinks, caretFocused, now < activeUntil,
              now.isFinite, lastActivityTime.isFinite else { return 1 }
        let period = 1.2
        let elapsed = max(0, now - lastActivityTime)
        let phase = elapsed.truncatingRemainder(dividingBy: period) / period
        return Float(0.5 * (1 + cos(2 * Double.pi * phase)))
    }

    static func shouldPresentFinalFrame(timerActive: Bool,
                                        blinkEligible: Bool,
                                        caretFocused: Bool,
                                        viewVisible: Bool,
                                        now: Double,
                                        activeUntil: Double) -> Bool {
        timerActive && blinkEligible && caretFocused && viewVisible
            && now >= activeUntil
    }
}

private struct CursorGlideTrajectory {
    private static let settleRadiusSquared: Float = 0.25

    let destination: SIMD2<Float>
    let retainedOffset: SIMD2<Float>
    let cellSize: SIMD2<Float>
    let maximumCellDistance: Float

    init(origin: SIMD2<Float>,
         destination: SIMD2<Float>,
         cellSize: SIMD2<Float>,
         maximumCellDistance: Float) {
        self.destination = destination
        retainedOffset = origin - destination
        self.cellSize = cellSize
        self.maximumCellDistance = maximumCellDistance
    }

    private static func squaredLength(_ vector: SIMD2<Float>) -> Float {
        vector.x * vector.x + vector.y * vector.y
    }

    private static func clamped(_ value: Float,
                                to limits: ClosedRange<Float>) -> Float {
        min(limits.upperBound, max(limits.lowerBound, value))
    }

    private var fitsDistanceBudget: Bool {
        let cellUnits = SIMD2<Float>(
            retainedOffset.x / max(1, cellSize.x),
            retainedOffset.y / max(1, cellSize.y))
        return maximumCellDistance <= 0
            || Self.squaredLength(cellUnits)
                <= maximumCellDistance * maximumCellDistance
    }

    func sample(elapsedTime: Float, response: Float) -> CursorGlideStep {
        let pursuitNeeded = Self.squaredLength(retainedOffset)
            > Self.settleRadiusSquared && fitsDistanceBudget
        switch pursuitNeeded {
        case false:
            return CursorGlideStep(position: destination, isAnimating: false)
        case true:
            let seconds = Self.clamped(elapsedTime, to: 0.001...0.05)
            let responseScale = Self.clamped(response, to: 0.1...8)
            let retention = exp(-(seconds * (responseScale * 40)))
            let candidate = destination + retainedOffset * retention
            let remainder = destination - candidate
            let keepsMoving = Self.squaredLength(remainder)
                > Self.settleRadiusSquared
            return CursorGlideStep(
                position: keepsMoving ? candidate : destination,
                isAnimating: keepsMoving)
        }
    }
}

enum CursorGlide {
    /// Resolve one cursor frame. Structurally hidden frames still synchronize
    /// the stored position with the terminal target; otherwise the next
    /// visible frame animates from an arbitrarily stale cell. A pulse trough
    /// remains structurally visible and therefore keeps gliding.
    static func resolvedStep(from: SIMD2<Float>,
                             to: SIMD2<Float>,
                             shouldDraw: Bool,
                             smoothEnabled: Bool,
                             isLiveResize: Bool = false,
                             deltaTime: Float,
                             speed: Float,
                             maxDistance: Float,
                             cellSize: SIMD2<Float>) -> CursorGlideStep {
        guard shouldDraw, smoothEnabled, !isLiveResize else {
            return CursorGlideStep(position: to, isAnimating: false)
        }
        return step(from: from, to: to, deltaTime: deltaTime,
                    speed: speed, maxDistance: maxDistance,
                    cellSize: cellSize)
    }

    static func step(from: SIMD2<Float>,
                     to: SIMD2<Float>,
                     deltaTime: Float,
                     speed: Float,
                     maxDistance: Float,
                     cellSize: SIMD2<Float>) -> CursorGlideStep {
        CursorGlideTrajectory(
            origin: from,
            destination: to,
            cellSize: cellSize,
            maximumCellDistance: maxDistance
        ).sample(elapsedTime: deltaTime, response: speed)
    }
}

struct ShaderScrollEnvelope: Sendable {
    private(set) var velocity: Float = 0
    private(set) var energy: Float = 0
    private var lastEventTime: Double = 0
    private var lastUpdateTime: Double = 0

    init() {}

    mutating func noteScroll(deltaPixels: CGFloat,
                                    at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard deltaPixels.isFinite, time.isFinite else { return }
        if lastUpdateTime > 0 { update(at: time) }
        let impulse = Float(deltaPixels)
        velocity = max(-1_600, min(1_600, velocity * 0.35 + impulse * 8))
        energy = max(0.15, min(1, energy + abs(impulse) / 48))
        lastEventTime = time
        lastUpdateTime = time
    }

    mutating func update(at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard time.isFinite else { return }
        guard lastUpdateTime > 0 else {
            velocity = 0
            energy = 0
            lastUpdateTime = time
            return
        }
        let elapsed = max(0, time - lastUpdateTime)
        let velocityDecay = Float(exp(-elapsed * 7.5))
        let energyDecay = Float(exp(-elapsed * 3.25))
        velocity *= velocityDecay
        energy *= energyDecay
        lastUpdateTime = time
        if time - lastEventTime > 1.5 || abs(velocity) < 0.01 || energy < 0.001 {
            velocity = 0
            energy = 0
        }
    }
}

/// Limits command-buffer construction without delaying the first frame of an
/// interaction. Requests that arrive inside the interval are represented by a
/// single deadline; the renderer owns the timer that services that deadline.
struct FrameBuildPacer: Sendable {
    private(set) var lastBuildTime: Double?

    func delay(at time: Double, targetFPS: Double) -> Double {
        guard time.isFinite, targetFPS.isFinite, targetFPS > 0,
              let lastBuildTime else { return 0 }
        let interval = 1 / targetFPS
        return max(0, lastBuildTime + interval - time)
    }

    mutating func markBuild(at time: Double) {
        guard time.isFinite else { return }
        lastBuildTime = time
    }

    mutating func reset() {
        lastBuildTime = nil
    }
}

@MainActor
extension MetalTerminalRenderer {
    /// Resolve a selected terminal-column span into the same device-pixel
    /// envelope used by cached cell backgrounds.
    static func selectionRect(
        columns: ClosedRange<Int>?, columnCount: Int,
        cellWidth: CGFloat, cellHeight: CGFloat
    ) -> CGRect? {
        guard let columns, columnCount > 0,
              cellWidth.isFinite, cellWidth > 0,
              cellHeight.isFinite, cellHeight > 0 else { return nil }
        let lower = max(0, columns.lowerBound)
        let upper = min(columnCount - 1, columns.upperBound)
        guard lower <= upper else { return nil }
        let x0 = (CGFloat(lower) * cellWidth).rounded(.down)
        let x1 = ((CGFloat(upper) + 1) * cellWidth).rounded(.up)
        return CGRect(x: x0, y: 0, width: max(0, x1 - x0),
                      height: cellHeight.rounded(.up))
    }

    /// Cached explicit backgrounds must not remain underneath selection: the
    /// shaping contract gives selection background precedence over them.
    static func backgroundFragments(
        _ rect: CGRect, excluding selection: CGRect?
    ) -> [CGRect] {
        guard let selection,
              rect.maxX > selection.minX,
              rect.minX < selection.maxX else { return [rect] }
        var result: [CGRect] = []
        if rect.minX < selection.minX {
            result.append(CGRect(
                x: rect.minX, y: rect.minY,
                width: selection.minX - rect.minX,
                height: rect.height))
        }
        if rect.maxX > selection.maxX {
            result.append(CGRect(
                x: selection.maxX, y: rect.minY,
                width: rect.maxX - selection.maxX,
                height: rect.height))
        }
        return result
    }

    /// User-driven motion must align with the view's 60 Hz presentation
    /// cadence. Reusing the 50 fps static-content budget creates an irregular
    /// 2/3-vsync beat that looks like load even when event handling is cheap.
    public static func interactiveContentTargetFPS(
        isKeyWindow: Bool,
        thermalState: ProcessInfo.ThermalState,
        lowPowerMode: Bool,
        maximumFramesPerSecond: Int
    ) -> Double {
        guard isKeyWindow else {
            return staticContentTargetFPS(
                isKeyWindow: false, thermalState: thermalState,
                lowPowerMode: lowPowerMode)
        }
        switch thermalState {
        case .critical: return 20
        case .serious: return 30
        default:
            if lowPowerMode { return 60 }
            return Double(min(120, max(60, maximumFramesPerSecond)))
        }
    }

    /// A selection drag gets a short self-ticking presentation window. AppKit
    /// can coalesce repeated `setNeedsDisplay` calls onto the same run-loop
    /// turn; without this deadline, a 120 Hz pointer stream can therefore
    /// present at half the intended 60 Hz low-power cadence even though all
    /// terminal rows are already cached.
    static func selectionInteractionShouldSelfAnimate(
        now: Double, activeUntil: Double
    ) -> Bool {
        now.isFinite && activeUntil.isFinite && now < activeUntil
    }

    static func builtInContinuouslyAnimates(mode: Int) -> Bool {
        mode > 0 && mode <= 67 && ![2, 5, 6, 9].contains(mode)
    }

    static func staticContentTargetFPS(isKeyWindow: Bool,
                                       thermalState: ProcessInfo.ThermalState,
                                       lowPowerMode: Bool) -> Double {
        switch thermalState {
        case .critical:
            return isKeyWindow ? 20 : 10
        case .serious:
            return isKeyWindow ? 30 : 15
        default:
            if isKeyWindow { return 50 }
            return lowPowerMode ? 20 : 30
        }
    }

    static func cursorBlinkEligible(snapshot: GridSnapshot,
                                    hostCursorHidden: Bool) -> Bool {
        guard snapshot.cursorStyle.blinks,
              !snapshot.cursorHidden,
              !hostCursorHidden,
              snapshot.cursorCol >= 0,
              snapshot.cursorCol < snapshot.cols else { return false }
        return snapshot.independentDisplayRow(
            forSourceRow: snapshot.cursorRow) != nil
    }

    static func cursorShouldInvertGlyph(style: RenderCursorStyle,
                                        caretFocused: Bool,
                                        cursorAnimating: Bool) -> Bool {
        style.isBlock && caretFocused && !cursorAnimating
    }

    static func cursorHeightPixels(cellHeight: CGFloat,
                                   font: CTFont,
                                   scale: CGFloat) -> CGFloat {
        guard cellHeight.isFinite, scale.isFinite, scale > 0 else { return 0 }
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font)
            + CTFontGetLeading(font)
        return min(ceil(cellHeight * scale), ceil(natural * scale))
    }

    static func cursorNaturalY(cellMinY: CGFloat,
                               cellHeight: CGFloat,
                               naturalHeight: CGFloat) -> CGFloat {
        cellMinY + max(0, cellHeight - naturalHeight)
    }

    static func cursorUnderlineThicknessPixels(underlineThickness: CGFloat,
                                               scale: CGFloat) -> CGFloat {
        max(1, underlineThickness * scale * 2)
    }

    static func cursorBarWidthPixels(scale: CGFloat) -> CGFloat {
        max(1, scale * 2)
    }

    static func lineModeRect(_ rect: CGRect,
                             displayIndex: Int,
                             mode: RenderLineMode,
                             xOrigin: CGFloat,
                             yOrigin: CGFloat,
                             cellHeight: CGFloat) -> CGRect {
        let rowMinY = yOrigin + CGFloat(displayIndex) * cellHeight
        let scaleX = mode.horizontalScale
        guard mode == .doubledTop || mode == .doubledDown else {
            return CGRect(x: xOrigin + rect.minX * scaleX,
                          y: rowMinY + rect.minY,
                          width: rect.width * scaleX,
                          height: rect.height)
        }

        var unboundedY = rowMinY + rect.minY * 2
        if mode == .doubledDown { unboundedY -= cellHeight }
        let clippedMinY = max(rowMinY, unboundedY)
        let clippedMaxY = min(rowMinY + cellHeight,
                              unboundedY + rect.height * 2)
        return CGRect(x: xOrigin + rect.minX * scaleX,
                      y: clippedMinY,
                      width: rect.width * scaleX,
                      height: max(0, clippedMaxY - clippedMinY))
    }

    static func shaderTargetFPS(isKeyWindow: Bool,
                                       thermalState: ProcessInfo.ThermalState,
                                       lowPowerMode: Bool) -> Double {
        switch thermalState {
        case .critical:
            return isKeyWindow ? 20 : 2
        case .serious:
            return isKeyWindow ? 30 : 3
        default:
            if isKeyWindow { return 60 }
            return lowPowerMode ? 2 : 5
        }
    }

    static func requiresOffscreenScene(shaderMode: Int,
                                              hasBuiltInPipeline: Bool,
                                              hasUserPipeline: Bool) -> Bool {
        if shaderMode == -1 { return hasUserPipeline }
        if shaderMode == 0 || shaderMode == 68 { return false }
        return hasBuiltInPipeline
    }
}
