import XCTest
@testable import CmdyGPU

@MainActor
final class CursorGlideTests: XCTestCase {
    func testCursorUsesPaletteCosinePulseAndActivityRestartsAtFullOpacity() {
        let samples: [(elapsed: Double, opacity: Float)] = [
            (0, 1), (0.3, 0.5), (0.6, 0), (0.9, 0.5), (1.2, 1),
        ]
        for sample in samples {
            XCTAssertEqual(CursorPulse.opacity(
                blinks: true, caretFocused: true,
                now: 10 + sample.elapsed,
                lastActivityTime: 10, activeUntil: 22),
                sample.opacity, accuracy: 0.0001)
        }

        // New input during the old trough restarts at full opacity.
        XCTAssertEqual(CursorPulse.opacity(
            blinks: true, caretFocused: true, now: 10.6,
            lastActivityTime: 10.6, activeUntil: 22.6), 1)
    }

    func testCursorPulsePhaseIsRelativeToItsActivityEpoch() {
        let earlyEpoch = CursorPulse.opacity(
            blinks: true, caretFocused: true, now: 10.3,
            lastActivityTime: 10, activeUntil: 22)
        let lateEpoch = CursorPulse.opacity(
            blinks: true, caretFocused: true, now: 1_000.3,
            lastActivityTime: 1_000, activeUntil: 1_012)

        XCTAssertEqual(earlyEpoch, 0.5, accuracy: 0.0001)
        XCTAssertEqual(lateEpoch, earlyEpoch, accuracy: 0.0001)
    }

    func testCursorPulseRequiresFocusStyleAndActiveWindow() {
        XCTAssertEqual(CursorPulse.opacity(
            blinks: false, caretFocused: true, now: 10.75,
            lastActivityTime: 10, activeUntil: 22), 1)
        XCTAssertEqual(CursorPulse.opacity(
            blinks: true, caretFocused: false, now: 10.75,
            lastActivityTime: 10, activeUntil: 22), 1)
        XCTAssertEqual(CursorPulse.opacity(
            blinks: true, caretFocused: true, now: 23,
            lastActivityTime: 10, activeUntil: 22), 1)
    }

    func testPulseTroughDoesNotStopCursorGlide() {
        XCTAssertEqual(CursorPulse.opacity(
            blinks: true, caretFocused: true, now: 10.6,
            lastActivityTime: 10, activeUntil: 22), 0, accuracy: 0.0001)

        let step = CursorGlide.resolvedStep(
            from: .zero, to: SIMD2<Float>(80, 0), shouldDraw: true,
            smoothEnabled: true, deltaTime: 1 / 60, speed: 1,
            maxDistance: 0, cellSize: SIMD2(10, 20))

        XCTAssertGreaterThan(step.position.x, 0)
        XCTAssertLessThan(step.position.x, 80)
        XCTAssertTrue(step.isAnimating)
    }

    func testCursorPulsePresentsOneFullOpacityFrameAtActivityExpiry() {
        XCTAssertFalse(CursorPulse.shouldPresentFinalFrame(
            timerActive: true, blinkEligible: true, caretFocused: true,
            viewVisible: true, now: 21.99, activeUntil: 22))
        XCTAssertTrue(CursorPulse.shouldPresentFinalFrame(
            timerActive: true, blinkEligible: true, caretFocused: true,
            viewVisible: true, now: 22, activeUntil: 22))
        XCTAssertFalse(CursorPulse.shouldPresentFinalFrame(
            timerActive: false, blinkEligible: true, caretFocused: true,
            viewVisible: true, now: 22, activeUntil: 22))
        XCTAssertFalse(CursorPulse.shouldPresentFinalFrame(
            timerActive: true, blinkEligible: true, caretFocused: true,
            viewVisible: false, now: 22, activeUntil: 22))
    }

    func testHigherSpeedSettlesFartherInTheSameFrame() {
        let start = SIMD2<Float>(0, 0)
        let target = SIMD2<Float>(100, 0)
        let slow = CursorGlide.step(from: start, to: target, deltaTime: 1 / 60,
                                    speed: 0.45, maxDistance: 0,
                                    cellSize: SIMD2(10, 20))
        let fast = CursorGlide.step(from: start, to: target, deltaTime: 1 / 60,
                                    speed: 2.5, maxDistance: 0,
                                    cellSize: SIMD2(10, 20))
        XCTAssertGreaterThan(fast.position.x, slow.position.x)
        XCTAssertTrue(slow.isAnimating)
    }

    func testFrozenDefaultTrajectoryUsesRateForty() {
        let step = CursorGlide.step(
            from: .zero, to: SIMD2<Float>(100, 0), deltaTime: 1 / 60,
            speed: 1.6, maxDistance: 0, cellSize: SIMD2(10, 20))

        XCTAssertEqual(step.position.x, 65.58462, accuracy: 0.0001)
        XCTAssertTrue(step.isAnimating)
    }

    func testFrozenSpeedAndDeltaTimeClamps() {
        let arguments = (from: SIMD2<Float>.zero,
                         to: SIMD2<Float>(100, 0),
                         maxDistance: Float(0),
                         cellSize: SIMD2<Float>(10, 20))
        let belowSpeedFloor = CursorGlide.step(
            from: arguments.from, to: arguments.to, deltaTime: 1 / 60,
            speed: -10, maxDistance: arguments.maxDistance,
            cellSize: arguments.cellSize)
        let atSpeedFloor = CursorGlide.step(
            from: arguments.from, to: arguments.to, deltaTime: 1 / 60,
            speed: 0.1, maxDistance: arguments.maxDistance,
            cellSize: arguments.cellSize)
        XCTAssertEqual(belowSpeedFloor.position, atSpeedFloor.position)

        let aboveSpeedCeiling = CursorGlide.step(
            from: arguments.from, to: arguments.to, deltaTime: 1 / 60,
            speed: 10, maxDistance: arguments.maxDistance,
            cellSize: arguments.cellSize)
        let atSpeedCeiling = CursorGlide.step(
            from: arguments.from, to: arguments.to, deltaTime: 1 / 60,
            speed: 8, maxDistance: arguments.maxDistance,
            cellSize: arguments.cellSize)
        XCTAssertEqual(aboveSpeedCeiling.position, atSpeedCeiling.position)

        let belowDeltaFloor = CursorGlide.step(
            from: arguments.from, to: arguments.to, deltaTime: -1,
            speed: 1, maxDistance: arguments.maxDistance,
            cellSize: arguments.cellSize)
        let atDeltaFloor = CursorGlide.step(
            from: arguments.from, to: arguments.to, deltaTime: 0.001,
            speed: 1, maxDistance: arguments.maxDistance,
            cellSize: arguments.cellSize)
        XCTAssertEqual(belowDeltaFloor.position, atDeltaFloor.position)

        let aboveDeltaCeiling = CursorGlide.step(
            from: arguments.from, to: arguments.to, deltaTime: 1,
            speed: 1, maxDistance: arguments.maxDistance,
            cellSize: arguments.cellSize)
        let atDeltaCeiling = CursorGlide.step(
            from: arguments.from, to: arguments.to, deltaTime: 0.05,
            speed: 1, maxDistance: arguments.maxDistance,
            cellSize: arguments.cellSize)
        XCTAssertEqual(aboveDeltaCeiling.position, atDeltaCeiling.position)
    }

    func testDistanceLimitSnapsLargeJumps() {
        let step = CursorGlide.step(from: SIMD2(0, 0), to: SIMD2(90, 0),
                                    deltaTime: 1 / 60, speed: 1, maxDistance: 4,
                                    cellSize: SIMD2(10, 20))
        XCTAssertEqual(step.position, SIMD2<Float>(90, 0))
        XCTAssertFalse(step.isAnimating)
    }

    func testDistanceLimitUsesEuclideanCellDistance() {
        let step = CursorGlide.step(
            from: .zero, to: SIMD2<Float>(30, 60), deltaTime: 1 / 60,
            speed: 1, maxDistance: 4, cellSize: SIMD2(10, 20))

        // Three cells on each axis is sqrt(18) cells, so the frozen renderer
        // snaps even though neither individual axis exceeds four cells.
        XCTAssertEqual(step.position, SIMD2<Float>(30, 60))
        XCTAssertFalse(step.isAnimating)
    }

    func testHalfPixelDistanceSettlesExactly() {
        let step = CursorGlide.step(
            from: .zero, to: SIMD2<Float>(0.3, 0.4), deltaTime: 1 / 60,
            speed: 1, maxDistance: 0, cellSize: SIMD2(10, 20))

        XCTAssertEqual(step.position, SIMD2<Float>(0.3, 0.4))
        XCTAssertFalse(step.isAnimating)
    }

    func testInterpolationSnapsWhenNextSampleEntersHalfPixelRadius() {
        let target = SIMD2<Float>(10, 20)
        let step = CursorGlide.step(
            from: .zero, to: target, deltaTime: 0.05,
            speed: 8, maxDistance: 0, cellSize: SIMD2(10, 20))

        XCTAssertEqual(step.position, target)
        XCTAssertFalse(step.isAnimating)
    }

    func testUnlimitedDistanceKeepsLargeJumpsAnimated() {
        let step = CursorGlide.step(from: SIMD2(0, 0), to: SIMD2(90, 0),
                                    deltaTime: 1 / 60, speed: 1, maxDistance: 0,
                                    cellSize: SIMD2(10, 20))
        XCTAssertLessThan(step.position.x, 90)
        XCTAssertTrue(step.isAnimating)
    }

    func testStructurallyHiddenFrameSynchronizesBeforeCursorBecomesVisibleAgain() {
        let stale = SIMD2<Float>(0, 0)
        let hiddenTarget = SIMD2<Float>(70, 0)
        let hidden = CursorGlide.resolvedStep(
            from: stale, to: hiddenTarget, shouldDraw: false,
            smoothEnabled: true, deltaTime: 1 / 60, speed: 1,
            maxDistance: 0, cellSize: SIMD2(10, 20))

        XCTAssertEqual(hidden.position, hiddenTarget)
        XCTAssertFalse(hidden.isAnimating)

        let visibleTarget = SIMD2<Float>(80, 0)
        let visible = CursorGlide.resolvedStep(
            from: hidden.position, to: visibleTarget, shouldDraw: true,
            smoothEnabled: true, deltaTime: 1 / 60, speed: 1,
            maxDistance: 0, cellSize: SIMD2(10, 20))

        XCTAssertGreaterThan(visible.position.x, hiddenTarget.x)
        XCTAssertLessThan(visible.position.x, visibleTarget.x)
        XCTAssertTrue(visible.isAnimating)
    }

    func testDisabledGlideTracksTheNewestTargetExactly() {
        let target = SIMD2<Float>(80, 40)
        let step = CursorGlide.resolvedStep(
            from: .zero, to: target, shouldDraw: true,
            smoothEnabled: false, deltaTime: 1 / 60, speed: 1,
            maxDistance: 0, cellSize: SIMD2(10, 20))

        XCTAssertEqual(step.position, target)
        XCTAssertFalse(step.isAnimating)
    }

    func testLiveResizePinsGlideToNewestTarget() {
        let target = SIMD2<Float>(80, 40)
        let step = CursorGlide.resolvedStep(
            from: .zero, to: target, shouldDraw: true,
            smoothEnabled: true, isLiveResize: true,
            deltaTime: 1 / 60, speed: 1,
            maxDistance: 0, cellSize: SIMD2(10, 20))

        XCTAssertEqual(step.position, target)
        XCTAssertFalse(step.isAnimating)
    }

    func testBlockGlyphInversionWaitsForGlideToSettle() {
        XCTAssertFalse(MetalTerminalRenderer.cursorShouldInvertGlyph(
            style: .steadyBlock, caretFocused: true, cursorAnimating: true))
        XCTAssertTrue(MetalTerminalRenderer.cursorShouldInvertGlyph(
            style: .steadyBlock, caretFocused: true, cursorAnimating: false))
        XCTAssertFalse(MetalTerminalRenderer.cursorShouldInvertGlyph(
            style: .steadyBlock, caretFocused: false, cursorAnimating: false))
        XCTAssertFalse(MetalTerminalRenderer.cursorShouldInvertGlyph(
            style: .steadyBar, caretFocused: true, cursorAnimating: false))
    }

    func testRepeatedHiddenFramesKeepTheNextVisibleCursorAtTheLatestTarget() {
        var position = SIMD2<Float>(0, 0)
        for targetX: Float in [20, 50, 80] {
            position = CursorGlide.resolvedStep(
                from: position, to: SIMD2(targetX, 0), shouldDraw: false,
                smoothEnabled: true, deltaTime: 1 / 60, speed: 1,
                maxDistance: 0, cellSize: SIMD2(10, 20)).position
        }

        let visible = CursorGlide.resolvedStep(
            from: position, to: SIMD2(80, 0), shouldDraw: true,
            smoothEnabled: true, deltaTime: 1 / 60, speed: 1,
            maxDistance: 0, cellSize: SIMD2(10, 20))

        XCTAssertEqual(visible.position, SIMD2<Float>(80, 0))
        XCTAssertFalse(visible.isAnimating)
    }

    func testCursorUsesNaturalFontHeightInsideExpandedRows() {
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let scale: CGFloat = 2
        let naturalHeight = CTFontGetAscent(font)
            + CTFontGetDescent(font)
            + CTFontGetLeading(font)
        let expandedCellHeight = ceil(naturalHeight * 1.5)
        let height = MetalTerminalRenderer.cursorHeightPixels(
            cellHeight: expandedCellHeight,
            font: font,
            scale: scale)

        XCTAssertEqual(height, ceil(naturalHeight * scale))
        XCTAssertLessThan(height, expandedCellHeight * scale)
    }

    func testCursorGeometryMatchesBottomAlignedTwoPixelReferenceStrokes() {
        XCTAssertEqual(MetalTerminalRenderer.cursorNaturalY(
            cellMinY: 84, cellHeight: 24, naturalHeight: 17), 91)
        XCTAssertEqual(MetalTerminalRenderer.cursorNaturalY(
            cellMinY: 168, cellHeight: 48, naturalHeight: 33), 183)

        XCTAssertEqual(MetalTerminalRenderer.cursorUnderlineThicknessPixels(
            underlineThickness: 1, scale: 1), 2)
        XCTAssertEqual(MetalTerminalRenderer.cursorUnderlineThicknessPixels(
            underlineThickness: 1, scale: 2), 4)
        XCTAssertEqual(MetalTerminalRenderer.cursorBarWidthPixels(scale: 1), 2)
        XCTAssertEqual(MetalTerminalRenderer.cursorBarWidthPixels(scale: 2), 4)
    }
}
