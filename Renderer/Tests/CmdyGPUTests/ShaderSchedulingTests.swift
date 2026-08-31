import Foundation
import XCTest
@testable import CmdyGPU

@MainActor
final class ShaderSchedulingTests: XCTestCase {
    func testOnlyDocumentedBuiltInsContinuouslyAnimate() {
        let staticModes: Set<Int> = [2, 5, 6, 9, 68]
        for mode in 0...68 {
            XCTAssertEqual(
                MetalTerminalRenderer.builtInContinuouslyAnimates(mode: mode),
                mode > 0 && !staticModes.contains(mode),
                "unexpected continuous scheduling for mode \(mode)")
        }
        XCTAssertFalse(MetalTerminalRenderer.builtInContinuouslyAnimates(mode: -1))
        XCTAssertFalse(MetalTerminalRenderer.builtInContinuouslyAnimates(mode: 69))
    }

    func testBurstRequestsCoalesceBelowThePresentationBudget() {
        var pacer = FrameBuildPacer()
        var builds = 0

        // Two hundred publication requests arriving over one second. A first
        // frame is immediate; subsequent builds respect the 50 fps static
        // content interval and one final deferred request can add one frame.
        for request in 0..<200 {
            let time = Double(request) / 200
            if pacer.delay(at: time, targetFPS: 50) == 0 {
                pacer.markBuild(at: time)
                builds += 1
            }
        }

        XCTAssertLessThanOrEqual(builds + 1, 52)
        XCTAssertGreaterThanOrEqual(builds, 45)
        XCTAssertEqual(FrameBuildPacer().delay(at: 10, targetFPS: 50), 0)
    }

    func testStaticCoalescingDoesNotReduceAnimatedShaderCadence() {
        XCTAssertEqual(MetalTerminalRenderer.staticContentTargetFPS(
            isKeyWindow: true, thermalState: .nominal,
            lowPowerMode: false), 50)
        XCTAssertEqual(MetalTerminalRenderer.shaderTargetFPS(
            isKeyWindow: true, thermalState: .nominal,
            lowPowerMode: false), 60)

        var pacer = FrameBuildPacer()
        var builds = 0
        for frame in 0..<300 {
            let time = Double(frame) / 60
            if pacer.delay(at: time, targetFPS: 60) < 0.000_001 {
                pacer.markBuild(at: time)
                builds += 1
            }
        }
        XCTAssertGreaterThanOrEqual(builds, 295)
    }

    func testInteractiveScrollUsesDisplayAlignedCadence() {
        XCTAssertEqual(MetalTerminalRenderer.interactiveContentTargetFPS(
            isKeyWindow: true, thermalState: .nominal,
            lowPowerMode: false, maximumFramesPerSecond: 120), 120)
        XCTAssertEqual(MetalTerminalRenderer.interactiveContentTargetFPS(
            isKeyWindow: true, thermalState: .nominal,
            lowPowerMode: true, maximumFramesPerSecond: 120), 60)
        XCTAssertEqual(MetalTerminalRenderer.interactiveContentTargetFPS(
            isKeyWindow: false, thermalState: .nominal,
            lowPowerMode: false, maximumFramesPerSecond: 120), 30)
        XCTAssertEqual(MetalTerminalRenderer.interactiveContentTargetFPS(
            isKeyWindow: true, thermalState: .nominal,
            lowPowerMode: false, maximumFramesPerSecond: 60), 60)
        XCTAssertEqual(MetalTerminalRenderer.interactiveContentTargetFPS(
            isKeyWindow: true, thermalState: .serious,
            lowPowerMode: false, maximumFramesPerSecond: 120), 30)
        XCTAssertEqual(MetalTerminalRenderer.interactiveContentTargetFPS(
            isKeyWindow: true, thermalState: .critical,
            lowPowerMode: false, maximumFramesPerSecond: 120), 20)
    }

    func testSelectionInteractionKeepsDisplayCadenceUntilDeadline() {
        XCTAssertTrue(MetalTerminalRenderer.selectionInteractionShouldSelfAnimate(
            now: 10.0, activeUntil: 10.15))
        XCTAssertFalse(MetalTerminalRenderer.selectionInteractionShouldSelfAnimate(
            now: 10.15, activeUntil: 10.15))
        XCTAssertFalse(MetalTerminalRenderer.selectionInteractionShouldSelfAnimate(
            now: 10.2, activeUntil: 10.15))
        XCTAssertFalse(MetalTerminalRenderer.selectionInteractionShouldSelfAnimate(
            now: .nan, activeUntil: 10.15))
    }

    func testSelectionSpanClampsAndUsesDevicePixelEnvelope() {
        XCTAssertEqual(MetalTerminalRenderer.selectionRect(
            columns: 2...4, columnCount: 10,
            cellWidth: 7.5, cellHeight: 18.25),
            CGRect(x: 15, y: 0, width: 23, height: 19))
        XCTAssertEqual(MetalTerminalRenderer.selectionRect(
            columns: -3...2, columnCount: 10,
            cellWidth: 8, cellHeight: 18),
            CGRect(x: 0, y: 0, width: 24, height: 18))
        XCTAssertNil(MetalTerminalRenderer.selectionRect(
            columns: -4 ... -1, columnCount: 10,
            cellWidth: 8, cellHeight: 18))
        XCTAssertNil(MetalTerminalRenderer.selectionRect(
            columns: 10...14, columnCount: 10,
            cellWidth: 8, cellHeight: 18))
    }

    func testSelectionReplacesOnlyCoveredCachedBackgroundSpan() {
        XCTAssertEqual(MetalTerminalRenderer.backgroundFragments(
            CGRect(x: 0, y: 0, width: 50, height: 18),
            excluding: CGRect(x: 15, y: 0, width: 20, height: 18)), [
                CGRect(x: 0, y: 0, width: 15, height: 18),
                CGRect(x: 35, y: 0, width: 15, height: 18),
            ])
        XCTAssertEqual(MetalTerminalRenderer.backgroundFragments(
            CGRect(x: 20, y: 0, width: 10, height: 18),
            excluding: CGRect(x: 15, y: 0, width: 20, height: 18)), [])
        XCTAssertEqual(MetalTerminalRenderer.backgroundFragments(
            CGRect(x: 0, y: 0, width: 10, height: 18), excluding: nil), [
                CGRect(x: 0, y: 0, width: 10, height: 18),
            ])
    }

    func testDatabloomScrollEnvelopeRisesThenSettles() {
        var envelope = ShaderScrollEnvelope()
        envelope.noteScroll(deltaPixels: 24, at: 1.0)
        XCTAssertGreaterThan(envelope.energy, 0)
        XCTAssertGreaterThan(envelope.velocity, 0)

        envelope.update(at: 3.0)
        XCTAssertEqual(envelope.energy, 0, accuracy: 0.0001)
        XCTAssertEqual(envelope.velocity, 0, accuracy: 0.0001)
    }

    func testDatabloomScrollEnvelopePreservesDirection() {
        var envelope = ShaderScrollEnvelope()
        envelope.noteScroll(deltaPixels: -18, at: 2.0)
        XCTAssertLessThan(envelope.velocity, 0)
    }

    func testDatabloomSingleWheelNotchIsImmediatelyVisible() {
        var envelope = ShaderScrollEnvelope()
        envelope.noteScroll(deltaPixels: 3, at: 4.0)
        XCTAssertGreaterThanOrEqual(envelope.energy, 0.15)

        envelope.update(at: 4.12)
        XCTAssertGreaterThan(envelope.energy, 0.05)
    }

    func testDatabloomIdleEnvelopeIsExactZero() {
        var envelope = ShaderScrollEnvelope()
        envelope.update(at: 30)
        XCTAssertEqual(envelope.energy, 0)
        XCTAssertEqual(envelope.velocity, 0)
    }

    func testKeyWindowStaysFluidInLowPowerMode() {
        XCTAssertEqual(MetalTerminalRenderer.shaderTargetFPS(
            isKeyWindow: true, thermalState: .nominal, lowPowerMode: true), 60)
    }

    func testUnfocusedWindowsArePowerThrottled() {
        XCTAssertEqual(MetalTerminalRenderer.shaderTargetFPS(
            isKeyWindow: false, thermalState: .nominal, lowPowerMode: false), 5)
        XCTAssertEqual(MetalTerminalRenderer.shaderTargetFPS(
            isKeyWindow: false, thermalState: .nominal, lowPowerMode: true), 2)
    }

    func testThermalPressureStillProtectsTheSystem() {
        XCTAssertEqual(MetalTerminalRenderer.shaderTargetFPS(
            isKeyWindow: true, thermalState: .serious, lowPowerMode: false), 30)
        XCTAssertEqual(MetalTerminalRenderer.shaderTargetFPS(
            isKeyWindow: true, thermalState: .critical, lowPowerMode: false), 20)
    }

    func testOnlyPostProcessShadersRetainAnOffscreenScene() {
        XCTAssertFalse(MetalTerminalRenderer.requiresOffscreenScene(
            shaderMode: 0, hasBuiltInPipeline: true, hasUserPipeline: true))
        XCTAssertFalse(MetalTerminalRenderer.requiresOffscreenScene(
            shaderMode: 68, hasBuiltInPipeline: true, hasUserPipeline: true))
        XCTAssertTrue(MetalTerminalRenderer.requiresOffscreenScene(
            shaderMode: 1, hasBuiltInPipeline: true, hasUserPipeline: false))
        XCTAssertFalse(MetalTerminalRenderer.requiresOffscreenScene(
            shaderMode: 1, hasBuiltInPipeline: false, hasUserPipeline: false))
        XCTAssertTrue(MetalTerminalRenderer.requiresOffscreenScene(
            shaderMode: -1, hasBuiltInPipeline: false, hasUserPipeline: true))
        XCTAssertFalse(MetalTerminalRenderer.requiresOffscreenScene(
            shaderMode: -1, hasBuiltInPipeline: true, hasUserPipeline: false))
    }
}
