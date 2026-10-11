import AppKit
import MetalKit
import XCTest
import CmdyNative
@testable import CmdyGPU

@MainActor
final class NativeRendererOwnershipTests: XCTestCase {
    func testRetainedFrameRowSurvivesSourceCallbackInvalidationWithoutCacheResidency() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = MemoryRenderSource()
        let renderer = try NativeRendererCacheHarness(view: MTKView(frame: .zero, device: device), source: source)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 12, height: 24, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let texturePointer = UnsafeRawPointer(Unmanaged.passUnretained(texture as AnyObject).toOpaque())
        var key = CmdyGpuRowKey()
        key.absolute_row = 7; key.version = 1; key.cols = 1; key.width = 12; key.height = 24
        var input = CmdyGpuRowView()
        input.coverage_texture = texturePointer; input.width = 12; input.height = 24; input.last_use = 19
        let borrowed = try XCTUnwrap(cmdy_gpu_row_import(renderer.gpu, &key, &input))
        let frameRow = try XCTUnwrap(cmdy_gpu_row_retain(borrowed))
        defer { cmdy_gpu_row_release(frameRow) }
        XCTAssertEqual(renderer.rowCacheAllocatedBytesForTesting, texture.allocatedSize)
        let laterSourceCallback = { renderer.invalidateRowCache() }
        laterSourceCallback()
        XCTAssertEqual(renderer.rowCacheAllocatedBytesForTesting, 0)
        XCTAssertEqual(renderer.rowCacheCountForTesting, 0)
        var output = CmdyGpuRowView()
        cmdy_gpu_row_view(frameRow, &output)
        XCTAssertEqual(output.coverage_texture, texturePointer)
        XCTAssertEqual(output.width, 12)
        XCTAssertEqual(output.height, 24)
        XCTAssertEqual(output.last_use, 19)
        // The frame reference also survives destruction of an unrelated cache
        // replacement at the same terminal row key.
        key.version = 2
        key.width = 6; key.height = 8
        input.width = 6; input.height = 8; input.last_use = 97
        _ = cmdy_gpu_row_import(renderer.gpu, &key, &input)
        renderer.invalidateRowCache()
        cmdy_gpu_row_view(frameRow, &output)
        XCTAssertEqual(output.coverage_texture, texturePointer)
        XCTAssertEqual(output.width, 12)
        XCTAssertEqual(output.height, 24)
        XCTAssertEqual(output.last_use, 19)
    }

    func testFailedImageDecodeStaysCoalescedForItsLiveOwner() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = MemoryRenderSource()
        let renderer = try NativeRendererCacheHarness(view: MTKView(frame: .zero, device: device), source: source)
        let image = NativeLifetimeImage()
        XCTAssertNil(renderer.textureForTesting(image))
        XCTAssertNil(renderer.textureForTesting(image))
        XCTAssertEqual(renderer.imageDecodeAttemptsForTesting, 1)
        for _ in 0..<100 where renderer.imageDecodePendingCountForTesting != 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(renderer.imageDecodePendingCountForTesting, 0)
        XCTAssertNil(renderer.textureForTesting(image))
        XCTAssertEqual(renderer.imageDecodeAttemptsForTesting, 1)
    }

    func testPendingDecodeDoesNotRetainRendererOrImageOwner() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = MemoryRenderSource()
        var renderer: NativeRendererCacheHarness? = try NativeRendererCacheHarness(view: MTKView(frame: .zero, device: device), source: source)
        var image: NativeLifetimeImage? = NativeLifetimeImage()
        weak var weakRenderer = renderer
        weak var weakImage = image
        XCTAssertNil(renderer?.textureForTesting(try XCTUnwrap(image)))
        XCTAssertEqual(renderer?.imageDecodePendingCountForTesting, 1)
        renderer = nil
        image = nil
        XCTAssertNil(weakRenderer)
        XCTAssertNil(weakImage)
        // Let the native completion return after both host objects disappear.
        // A newly constructed renderer must have its own untouched image cache.
        try await Task.sleep(nanoseconds: 100_000_000)
        let next = try NativeRendererCacheHarness(view: MTKView(frame: .zero, device: device), source: source)
        XCTAssertEqual(next.imageDecodeAttemptsForTesting, 0)
        XCTAssertEqual(next.imageDecodePendingCountForTesting, 0)
    }
}

private final class NativeLifetimeImage: RenderableCellImage {
    let image = NSImage(size: .zero)
    let pixelWidth = 0
    let pixelHeight = 0
    let col = 0
    let kittyIsKitty = false
    let kittyImageId: UInt32? = nil
    let kittyZIndex = 0
    let kittyPixelOffsetX = 0
    let kittyPixelOffsetY = 0
}
