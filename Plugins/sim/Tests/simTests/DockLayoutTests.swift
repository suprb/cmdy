import AppKit
import XCTest
@testable import sim

final class DockLayoutTests: XCTestCase {
    private let host = NSRect(x: 100, y: 80, width: 1200, height: 900)

    func testDefaultSplitTracksHostWidth() {
        let compact = layout(hostWidth: 1000)
        let wide = layout(hostWidth: 1400)

        XCTAssertEqual(compact.stripWidth, 680, accuracy: 0.01)
        XCTAssertEqual(wide.stripWidth, 980, accuracy: 0.01)
    }

    func testSplitPreservesUsableTerminalWidth() {
        let layout = self.layout(hostWidth: 700,
                                 fraction: 0.9,
                                 simulatorSize: CGSize(width: 500, height: 700))

        XCTAssertEqual(layout.stripWidth, 380, accuracy: 0.01)
        XCTAssertEqual(700 - layout.stripWidth, SimDockLayout.minimumTerminalWidth,
                       accuracy: 0.01)
    }

    func testSimulatorIsHorizontallyCenteredInStrip() {
        let layout = SimDockLayout(host: host,
                                   dockSide: 25,
                                   trailingOffset: 0,
                                   fraction: 0.6,
                                   simulatorSize: CGSize(width: 400, height: 700),
                                   screenHeight: 1117,
                                   padding: 10)

        XCTAssertEqual(layout.simulatorFrame.midX, layout.cardFrame.midX, accuracy: 0.01)
    }

    func testCardAndSimulatorAreVerticallyCenteredInHost() {
        let layout = SimDockLayout(host: host,
                                   dockSide: 25,
                                   trailingOffset: 0,
                                   fraction: 0.5,
                                   simulatorSize: CGSize(width: 360, height: 700),
                                   screenHeight: 1117,
                                   padding: 10)

        XCTAssertEqual(layout.cardFrame.midY, host.midY, accuracy: 0.01)
        XCTAssertEqual(layout.simulatorFrame.midY, 1117 - host.midY, accuracy: 0.01)
        XCTAssertEqual(layout.cardFrame.minY - host.minY,
                       host.maxY - layout.cardFrame.maxY, accuracy: 0.01)
        XCTAssertEqual(layout.cardFrame.minY - host.minY, 25, accuracy: 0.01)
    }

    func testOversizedSimulatorRemainsCenteredAndReportsNoFit() {
        let layout = self.layout(hostWidth: 700,
                                 fraction: 0.5,
                                 simulatorSize: CGSize(width: 500, height: 1000))

        XCTAssertFalse(layout.simulatorFits)
        XCTAssertEqual(layout.simulatorFrame.midX, layout.cardFrame.midX, accuracy: 0.01)
        XCTAssertEqual(layout.simulatorFrame.midY, 1117 - layout.cardFrame.midY,
                       accuracy: 0.01)
    }

    func testStripStaysBeforeTrailingInspector() {
        let layout = SimDockLayout(
            host: host, dockSide: 0, trailingOffset: 280, fraction: 0.5,
            simulatorSize: CGSize(width: 360, height: 700),
            screenHeight: 1117, padding: 10)

        XCTAssertEqual(host.maxX - layout.cardFrame.maxX, 280, accuracy: 0.01)
    }

    func testUnfittableMinimumStopsOnlyForTheSameDeviceSize() {
        let layout = self.layout(hostWidth: 700,
                                 fraction: 0.5,
                                 simulatorSize: CGSize(width: 500, height: 1000))

        XCTAssertTrue(layout.isUnfittableMinimum(CGSize(width: 500, height: 1000)))
        XCTAssertFalse(layout.isUnfittableMinimum(CGSize(width: 376, height: 801)))
        XCTAssertFalse(layout.isUnfittableMinimum(nil))
    }

    private func layout(hostWidth: CGFloat,
                        fraction: CGFloat = SimDockLayout.defaultFraction,
                        simulatorSize: CGSize = CGSize(width: 360, height: 700)) -> SimDockLayout {
        SimDockLayout(host: NSRect(x: host.origin.x, y: host.origin.y,
                                   width: hostWidth, height: host.height),
                      dockSide: 25,
                      trailingOffset: 0,
                      fraction: fraction,
                      simulatorSize: simulatorSize,
                      screenHeight: 1117,
                      padding: 10)
    }
}
