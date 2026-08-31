import Metal
import XCTest
@testable import CmdyGPU

@MainActor
final class MetalSharedResourcesTests: XCTestCase {
    func testRepeatedLookupReusesOneImmutableResourceSet() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        MetalTerminalRenderer.resetSharedCoreResourcesForTesting()
        let constructionsBefore =
            MetalTerminalRenderer.sharedCoreResourceConstructionCount
        let first = try MetalTerminalRenderer.sharedCoreResourceIdentity(
            device: device)
        let constructionsAfterFirst =
            MetalTerminalRenderer.sharedCoreResourceConstructionCount
        let second = try MetalTerminalRenderer.sharedCoreResourceIdentity(
            device: device)
        let firstQueue = try MetalTerminalRenderer.sharedCommandQueueIdentity(
            device: device)
        let secondQueue = try MetalTerminalRenderer.sharedCommandQueueIdentity(
            device: device)

        XCTAssertEqual(first, second)
        XCTAssertEqual(firstQueue, secondQueue)
        XCTAssertEqual(
            MetalTerminalRenderer.sharedCoreResourceConstructionCount,
            constructionsAfterFirst)
        XCTAssertEqual(constructionsAfterFirst, constructionsBefore + 1)

        let alternateFormat = try MetalTerminalRenderer
            .sharedCoreResourceIdentity(
                device: device, pixelFormat: .rgba16Float)
        XCTAssertNotEqual(first, alternateFormat)
        XCTAssertEqual(
            MetalTerminalRenderer.sharedCoreResourceConstructionCount,
            constructionsAfterFirst + 1)

        if device.supportsTextureSampleCount(4) {
            let multisampled = try MetalTerminalRenderer
                .sharedCoreResourceIdentity(
                    device: device, pixelFormat: .rgba16Float,
                    sampleCount: 4)
            XCTAssertNotEqual(alternateFormat, multisampled)
            XCTAssertEqual(
                MetalTerminalRenderer.sharedCoreResourceConstructionCount,
                constructionsAfterFirst + 2)
        }
    }
}
