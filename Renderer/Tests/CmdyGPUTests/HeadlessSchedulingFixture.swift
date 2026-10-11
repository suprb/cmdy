import AppKit
import CmdyNative
import MetalKit
import XCTest
@_spi(CmdyApp) @testable import CmdyGPU

/// Exercise native policy and the real async adapter. Platform visibility is
/// supplied as copied values; timers and queued service are explicitly driven.
@MainActor
final class HeadlessSchedulingFixture {
    @MainActor final class Environment {
        var attached = true, visible = true, key = true
        let maximumFPS = 120
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState
    }
    @MainActor final class Services {
        var pending: [@MainActor @Sendable () -> Void] = []
    }
    let environment = Environment()
    let services = Services()
    let view: SchedulingView
    let source = MemoryRenderSource()
    var renderer: MetalTerminalRenderer?

    init() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        view = SchedulingView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        renderer = try MetalTerminalRenderer(view: view, source: source)
        renderer!.scheduler.environmentForTesting = { [environment, weak view, weak source] in
            .init(now: ProcessInfo.processInfo.systemUptime, cell_height_pixels: 16,
                maximum_fps: Int64(environment.maximumFPS), has_view: view != nil, has_source: source != nil,
                visible: environment.attached && environment.visible && view?.isHiddenOrHasHiddenAncestor == false,
                key_window: environment.attached && environment.key, caret_focused: false,
                low_power: environment.lowPower, thermal: UInt8(environment.thermal.rawValue))
        }
        renderer!.scheduler.timerInstallerForTesting = { _ in }
        renderer!.scheduler.serviceQueueForTesting = { [services] work in services.pending.append(work) }
        renderer!.onCaptureRequestedForTesting = { [weak view] in
            guard let view else { return }
            view.captureRequests += 1; view.onCapture?()
        }
        await flushOwner()
        view.drawRequests = 0
    }
    isolated deinit { renderer?.close() }

    /// A capture or a posted service may enqueue a response while a preceding
    /// barrier is in flight; the next FIFO barriers include that response.
    func flushOwner() async {
        for _ in 0..<3 { _ = await renderer?.synchronizeForTesting() }
    }
    func drainServices() async {
        for _ in 0..<8 {
            await flushOwner()
            if services.pending.isEmpty {
                guard let timer = renderer?.scheduler.pacingTimerForTesting, timer.isValid else { return }
                let delay = max(0, timer.fireDate.timeIntervalSinceNow) + 0.001
                try? await Task.sleep(for: .seconds(delay))
                if timer.isValid { timer.fire() }
                continue
            }
            let work = services.pending; services.pending.removeAll()
            for service in work { service() }
        }
        XCTFail("Interactive service failed to settle")
    }
    var interactiveFPS: Double {
        MetalTerminalRenderer.interactiveContentTargetFPS(isKeyWindow: environment.key,
            thermalState: environment.thermal, lowPowerMode: environment.lowPower,
            maximumFramesPerSecond: environment.maximumFPS)
    }
    var staticFPS: Double {
        MetalTerminalRenderer.staticContentTargetFPS(isKeyWindow: environment.key,
            thermalState: environment.thermal, lowPowerMode: environment.lowPower)
    }
    /// Animated-shader cadence: the display rate in an unthrottled focused
    /// window, otherwise the shader power budget.
    var shaderFPS: Double {
        if environment.key, !environment.lowPower, environment.thermal.rawValue < 2 {
            return Double(min(120, max(60, environment.maximumFPS)))
        }
        return MetalTerminalRenderer.shaderTargetFPS(isKeyWindow: environment.key,
            thermalState: environment.thermal, lowPowerMode: environment.lowPower)
    }
}
@MainActor
final class SchedulingView: MTKView {
    var drawRequests = 0, captureRequests = 0
    var onCapture: (() -> Void)?
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        // Observe AppKit invalidation without creating a drawable or window.
        drawRequests += 1
    }
}
