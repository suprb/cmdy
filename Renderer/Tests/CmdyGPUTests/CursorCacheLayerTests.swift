import AppKit
import CmdyNative
import IOSurface
import Metal
import QuartzCore
import XCTest
@testable import CmdyGPU

// Real native pixels and copied IOSurfaces, with unattached layers only.
// No NSApplication, window, PTY, input, or on-screen presentation is created.
private final class CursorImageBuilder: @unchecked Sendable {
    let device: any MTLDevice
    let worker: OpaquePointer
    let input: OpaquePointer
    let finished: XCTestExpectation
    let activity: Double
    var images: CursorFrameImages?
    var expectedBacking = Data()
    var expectedPhases: [Data] = []
    var result: UInt32 = UInt32.max

    init(finished: XCTestExpectation) throws {
        self.finished = finished
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        worker = try XCTUnwrap(cmdy_render_worker_create_with_scope { body, context in
            autoreleasepool { body?(context) }
        })
        activity = ProcessInfo.processInfo.systemUptime
        var frame = CmdyRenderFrameInput()
        frame.identity = .init(surface: 91, epoch: cmdy_render_worker_epoch(worker), sequence: 1)
        frame.buffer_line_count = 3
        var p = CmdyGpuFrame()
        p.width = 720; p.height = 600; p.scale = 1; p.cell_width = 9; p.cell_height = 20
        p.grid_rows = 3; p.grid_cols = 8; p.cursor_source_row = 1; p.cursor_display_row = 1
        p.cursor_col = 2; p.cursor_style = 0; p.cursor_valid = 1; p.caret_focused = 1
        p.cursor_natural_height = 18; p.underline_thickness = 1; p.image_scale = 1
        p.background = .init(r: 0.06, g: 0.09, b: 0.14, a: 1)
        p.caret = .init(r: 0.2, g: 0.8, b: 0.5, a: 1)
        p.caret_text = .init(r: 0.9, g: 0.1, b: 0.3, a: 1); p.now = activity
        frame.parameters = p
        guard let input = cmdy_render_frame_input_capture(&frame, nil) else {
            _ = cmdy_render_worker_destroy(worker)
            throw NSError(domain: "CursorCacheLayerTests", code: 1)
        }
        self.input = input
    }

    func start() -> Bool {
        cmdy_render_worker_submit(worker, cmdy_render_worker_epoch(worker), Unmanaged.passUnretained(self).toOpaque(),
            { context, _, _ in
                let value = Unmanaged<CursorImageBuilder>.fromOpaque(context!).takeUnretainedValue()
                let job = cmdy_render_cursor_cache_begin_with_backing(value.worker,
                    Unmanaged.passUnretained(value.device as AnyObject).toOpaque(), value.input, 0,
                    value.activity, value.activity + 12, { context, result, frames in
                        XCTAssertFalse(Thread.isMainThread)
                        let value = Unmanaged<CursorImageBuilder>.fromOpaque(context!).takeUnretainedValue()
                        value.result = result
                        var update = CmdyRenderSessionUpdate()
                        update.kind = UInt32(CMDY_SESSION_CURSOR_CACHE)
                        update.identity = .init(surface: 91, epoch: 1, sequence: 0)
                        update.cursor_token = 77; update.cursor_generation = 3; update.source_revision = 9
                        update.cursor_frames = frames
                        if let frames, let view = cmdy_render_cursor_frames_view(frames)?.pointee {
                            value.expectedBacking = Data(bytes: view.backing_bytes!, count: view.backing_byte_count)
                            value.expectedPhases = (0..<view.count).map {
                                Data(bytes: view.bytes!.advanced(by: $0 * view.bytes_per_frame), count: view.bytes_per_frame)
                            }
                        }
                        value.images = CursorFrameImages(update)
                    }, context, { context in
                        Unmanaged<CursorImageBuilder>.fromOpaque(context!).takeUnretainedValue().finished.fulfill()
                    })
                if let job { cmdy_render_cursor_cache_release(job) }
                else { value.finished.fulfill() }
            }, { _, reason in
                XCTAssertEqual(reason, UInt32(CMDY_RENDER_WORKER_EXECUTED))
            }) != 0
    }

    func join() -> UInt8 { cmdy_render_worker_destroy(worker) }
    deinit { cmdy_render_frame_input_release(input) }
}

@MainActor
final class CursorCacheLayerTests: XCTestCase {
    private func pixels(_ surface: IOSurfaceRef) throws -> Data {
        XCTAssertEqual(IOSurfaceLock(surface, .readOnly, nil), 0)
        defer { XCTAssertEqual(IOSurfaceUnlock(surface, .readOnly, nil), 0) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let base = IOSurfaceGetBaseAddress(surface), stride = IOSurfaceGetBytesPerRow(surface)
        var result = Data()
        for row in 0..<height { result.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * 4) }
        return result
    }

    private func backingPixels(_ backing: CursorBackingSurfaces, width: Int, height: Int) throws -> Data {
        let background = try pixels(backing.background)
        var result = Data()
        if IOSurfaceGetWidth(backing.background) == 1 && IOSurfaceGetHeight(backing.background) == 1 {
            for _ in 0..<(width * height) { result.append(background) }
        } else {
            XCTAssertEqual(IOSurfaceGetWidth(backing.background), width)
            XCTAssertEqual(IOSurfaceGetHeight(backing.background), height)
            result = background
        }
        for region in backing.regions {
            let surface = region.surface
            let detail = try pixels(surface)
            let rect = region.rect
            XCTAssertEqual(IOSurfaceGetWidth(surface), Int(rect.width))
            XCTAssertEqual(IOSurfaceGetHeight(surface), Int(rect.height))
            let rowBytes = Int(rect.width) * 4
            for row in 0..<Int(rect.height) {
                let start = ((Int(rect.minY) + row) * width + Int(rect.minX)) * 4
                result.replaceSubrange(start..<(start + rowBytes), with: detail[(row * rowBytes)..<((row + 1) * rowBytes)])
            }
        }
        return result
    }

    func testSurfacesOutliveWorkerAndLayerRemovalDetachesBacking() async throws {
        XCTAssertNil(NSApp)
        let done = expectation(description: "native cache disposed")
        let builder = try CursorImageBuilder(finished: done)
        XCTAssertTrue(builder.start())
        await fulfillment(of: [done], timeout: 10)
        let joined = await Task.detached { builder.join() }.value
        XCTAssertEqual(joined, 1)
        XCTAssertEqual(builder.result, UInt32(CMDY_CURSOR_CACHE_READY))
        var images: CursorFrameImages? = try XCTUnwrap(builder.images)
        builder.images = nil
        weak let retainedImages = images
        let surfaces = CursorBackingSurfaces(background: images!.backing, regions: images!.backingRegions)
        XCTAssertEqual(surfaces.regions.count, 1)
        XCTAssertEqual(try backingPixels(surfaces, width: 720, height: 600), builder.expectedBacking)
        for (index, surface) in images!.phases.enumerated() {
            XCTAssertEqual(try pixels(surface), builder.expectedPhases[index])
            XCTAssertNotNil(IOSurfaceCopyValue(surface, kIOSurfaceColorSpace))
        }
        XCTAssertEqual(images?.phases.count, 60)
        XCTAssertEqual(images?.epoch, 1); XCTAssertEqual(images?.revision, 9); XCTAssertEqual(images?.generation, 3)
        XCTAssertNil(images?.geometry.bytes); XCTAssertNil(images?.geometry.backing_bytes)
        let backingBytes = surfaces.allocatedBytes
        var identities = Set<ObjectIdentifier>()
        let uniquePhases = images!.phases.filter { identities.insert(ObjectIdentifier($0)).inserted }
        XCTAssertEqual(uniquePhases.count, Set(builder.expectedPhases).count)
        XCTAssertLessThan(uniquePhases.count, 60)
        XCTAssertEqual(images!.allocatedBytes, backingBytes + uniquePhases.reduce(0) { $0 + IOSurfaceGetAllocSize($1) })
        XCTAssertLessThanOrEqual(backingBytes, CursorFrameImages.maximumBackingBytes)
        XCTAssertLessThanOrEqual(images!.allocatedBytes - backingBytes, CursorFrameImages.maximumPhaseBytes)

        let parent = CAMetalLayer()
        parent.drawableSize = CGSize(width: 720, height: 600)
        let layer = CursorCacheLayer()
        var expired: [UInt64] = []
        parent.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        XCTAssertFalse(layer.install(images!, in: parent) { _ in XCTFail("Mismatched colour space") })
        parent.colorspace = images!.colorSpace
        XCTAssertTrue(layer.install(images!, in: parent) { expired.append($0) })
        XCTAssertFalse(layer.install(images!, in: parent) { _ in XCTFail("Duplicate installation") })
        XCTAssertEqual(layer.token, 77)
        let stats = layer.statistics
        XCTAssertEqual(stats["active"] as? Bool, true)
        XCTAssertEqual(stats["token"] as? UInt64, 77)
        XCTAssertEqual(stats["epoch"] as? UInt64, 1)
        XCTAssertEqual(stats["revision"] as? UInt64, 9)
        XCTAssertEqual(stats["generation"] as? UInt64, 3)
        XCTAssertEqual(stats["activityUptime"] as? Double, builder.activity)
        XCTAssertEqual(stats["phaseSurfaceIDs"] as? [UInt32], images!.phases.map { IOSurfaceGetID($0) })
        XCTAssertLessThanOrEqual(try XCTUnwrap(stats["mediaTimeBefore"] as? Double),
                                 try XCTUnwrap(stats["mediaTimeAfter"] as? Double))
        XCTAssertLessThanOrEqual(try XCTUnwrap(stats["hostTicksBefore"] as? UInt64),
                                 try XCTUnwrap(stats["hostTicksAfter"] as? UInt64))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(stats))
        XCTAssertEqual(parent.sublayers?.count, 1)
        let backing = try XCTUnwrap(parent.sublayers?.first)
        let detail = try XCTUnwrap(backing.sublayers?.first)
        let patch = try XCTUnwrap(backing.sublayers?.last)
        XCTAssertEqual(backing.sublayers?.count, 2)
        let detailRect = try XCTUnwrap(surfaces.regions.first).rect
        XCTAssertEqual(detail.frame, CGRect(x: detailRect.minX, y: 600 - detailRect.maxY,
                                           width: detailRect.width, height: detailRect.height))
        // Core Animation discards even a basic opacity animation on flush for
        // an unattached tree. Animation/phase proof requires the separate live
        // window check; this test proves surface and model-layer ownership.
        XCTAssertNotNil(backing.contents)
        XCTAssertNotNil(patch.contents)
        XCTAssertTrue(backing.isOpaque)
        XCTAssertEqual(backing.frame, CGRect(x: 0, y: 0, width: 720, height: 600))
        XCTAssertEqual(patch.frame.origin.y, 600 - images!.geometry.y - Double(images!.geometry.height))
        images = nil
        XCTAssertNil(retainedImages) // layers retain surfaces, not the offer wrapper
        XCTAssertEqual(layer.clear(), 77)
        XCTAssertEqual(layer.statistics["active"] as? Bool, false)
        XCTAssertNil(layer.statistics["phaseSurfaceIDs"])
        XCTAssertEqual(layer.clear(), 0)
        XCTAssertTrue(parent.sublayers?.isEmpty ?? true)
        XCTAssertTrue(expired.isEmpty)
        XCTAssertNil(NSApp)
    }

    func testBackingPreservesUniformSparseAndDensePixelsWithIndependentLifetime() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let width = 641, height = 359
        for pattern in 0..<5 {
            var source = [UInt32](repeating: 0xff531f11, count: width * height)
            switch pattern {
            case 1:
                for y in 29..<86 { for x in 17..<118 { source[y * width + x] = 0xff000000 | UInt32(y * width + x) } }
            case 2:
                // Differences at the extreme edges require a full-size backing.
                source[width - 1] = 0xffabcdef; source[(height - 1) * width] = 0xff123456
            case 3:
                for index in source.indices { source[index] = 0xff000000 | UInt32(index) }
            case 4:
                // A pixel at the very bottom/right must not be trimmed away.
                source[source.count - 1] = 0xffabcdef
            default: break
            }
            let expected = source.withUnsafeBytes { Data($0) }
            let backing = try XCTUnwrap(source.withUnsafeBytes {
                CursorFrameImages.copyBacking($0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count,
                    width: width, height: height, colorSpace: space)
            })
            source = Array(repeating: 0, count: source.count)
            XCTAssertEqual(try backingPixels(backing, width: width, height: height), expected, "Pattern \(pattern)")
            XCTAssertNotNil(IOSurfaceCopyValue(backing.background, kIOSurfaceColorSpace))
            for region in backing.regions { XCTAssertNotNil(IOSurfaceCopyValue(region.surface, kIOSurfaceColorSpace)) }
            if pattern == 0 { XCTAssertEqual(IOSurfaceGetWidth(backing.background), 1); XCTAssertTrue(backing.regions.isEmpty) }
            if pattern == 1 { XCTAssertEqual(backing.regions.first?.rect, CGRect(x: 17, y: 29, width: 101, height: 57)) }
            if pattern == 2 || pattern == 3 {
                XCTAssertTrue(backing.regions.isEmpty); XCTAssertEqual(IOSurfaceGetWidth(backing.background), width)
            } else { XCTAssertLessThan(backing.allocatedBytes, expected.count / 4) }
        }
        XCTAssertNil(NSApp)
    }

    func testSeparatedTextBandsPreserveEveryPixelAtBothScalesAfterSourceRelease() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        for scale in [1, 2] {
            let width = 1040 * scale, height = 778 * scale
            var source = [UInt32](repeating: 0xff531f11, count: width * height)
            for line in 0..<36 {
                let top = (18 + line * 20) * scale
                let left = (17 + line % 3) * scale
                for y in top..<(top + 8 * scale) {
                    for x in left..<(left + 760 * scale) { source[y * width + x] = 0xff000000 | UInt32(y * width + x) }
                }
            }
            source[source.count - 1] = 0xffabcdef
            let expected = source.withUnsafeBytes { Data($0) }
            let backing = try XCTUnwrap(source.withUnsafeBytes {
                CursorFrameImages.copyBacking($0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count,
                    width: width, height: height, colorSpace: space)
            })
            source = []
            XCTAssertEqual(try backingPixels(backing, width: width, height: height), expected)
            XCTAssertGreaterThan(backing.regions.count, 1)
            XCTAssertLessThanOrEqual(backing.regions.count, CursorFrameImages.maximumBackingRegions)
            XCTAssertLessThan(backing.allocatedBytes, expected.count / 2)
            XCTAssertLessThanOrEqual(backing.allocatedBytes, CursorFrameImages.maximumBackingBytes)
            XCTAssertEqual(backing.allocatedBytes, IOSurfaceGetAllocSize(backing.background) +
                backing.regions.reduce(0) { $0 + IOSurfaceGetAllocSize($1.surface) })
            for region in backing.regions {
                XCTAssertEqual(region.rect.minX.rounded(), region.rect.minX)
                XCTAssertEqual(region.rect.minY.rounded(), region.rect.minY)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: width, height: height).contains(region.rect))
                XCTAssertNotNil(IOSurfaceCopyValue(region.surface, kIOSurfaceColorSpace))
            }
        }
        XCTAssertNil(NSApp)
    }

    func testBandCountOverflowKeepsExactBoundedFallback() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let width = 1040, height = 778
        for count in [CursorFrameImages.maximumBackingRegions, CursorFrameImages.maximumBackingRegions + 1] {
            var source = [UInt32](repeating: 0xff531f11, count: width * height)
            for line in 0..<count {
                let top = 2 + line * 11
                for y in top..<(top + 3) {
                    for x in 17..<717 { source[y * width + x] = 0xff000000 | UInt32(y * width + x) }
                }
            }
            let expected = source.withUnsafeBytes { Data($0) }
            let backing = try XCTUnwrap(source.withUnsafeBytes {
                CursorFrameImages.copyBacking($0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count,
                    width: width, height: height, colorSpace: space)
            })
            XCTAssertEqual(try backingPixels(backing, width: width, height: height), expected)
            XCTAssertLessThanOrEqual(backing.regions.count, CursorFrameImages.maximumBackingRegions)
            XCTAssertLessThanOrEqual(backing.allocatedBytes, CursorFrameImages.maximumBackingBytes)
            if count > CursorFrameImages.maximumBackingRegions { XCTAssertLessThanOrEqual(backing.regions.count, 1) }
            else { XCTAssertGreaterThan(backing.regions.count, 1) }
        }
        XCTAssertNil(NSApp)
    }

    func testRepeatedBandsShareOwnedTaggedSurfacesAtDifferentPlacements() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let width = 2080, height = 1556, bandWidth = 1501, bandHeight = 24
        var source = [UInt32](repeating: 0xff531f11, count: width * height)
        for line in 0..<24 {
            let left = 17 + line % 3, top = 12 + line * 60
            for y in 0..<bandHeight {
                for x in 0..<bandWidth { source[(top + y) * width + left + x] = 0xff000000 | UInt32(y * bandWidth + x) }
            }
        }
        let expected = source.withUnsafeBytes { Data($0) }
        let backing = try XCTUnwrap(source.withUnsafeBytes {
            CursorFrameImages.copyBacking($0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count,
                width: width, height: height, colorSpace: space)
        })
        source = []
        XCTAssertEqual(try backingPixels(backing, width: width, height: height), expected)
        XCTAssertEqual(backing.regions.count, 24)
        XCTAssertEqual(Set(backing.regions.map { IOSurfaceGetID($0.surface) }).count, 1)
        let detail = try XCTUnwrap(backing.regions.first?.surface)
        XCTAssertEqual(backing.allocatedBytes, IOSurfaceGetAllocSize(backing.background) + IOSurfaceGetAllocSize(detail))
        let separate = IOSurfaceGetAllocSize(backing.background) + 24 * IOSurfaceGetAllocSize(detail)
        XCTAssertGreaterThanOrEqual(separate - backing.allocatedBytes, CursorFrameImages.minimumBandSavingsBytes)
        for (line, region) in backing.regions.enumerated() {
            XCTAssertEqual(region.rect, CGRect(x: 17 + line % 3, y: 12 + line * 60, width: bandWidth, height: bandHeight))
            XCTAssertNotNil(IOSurfaceCopyValue(region.surface, kIOSurfaceColorSpace))
        }
        XCTAssertNil(NSApp)
    }

    func testOddMidpointSharingPreservesDistinctPixelsAndHonorsRegionCap() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let width = 1800, height = 1536, bandWidth = 1401, bandHeight = 24, bandCount = 36
        for sharedCount in [28, 29] {
            var source = [UInt32](repeating: 0xff531f11, count: width * height)
            for line in 0..<bandCount {
                let left = 17 + line % 3, top = 12 + line * 40
                let variant = line < sharedCount ? 0 : line
                for y in 0..<bandHeight {
                    for x in 0..<bandWidth {
                        let pixel = x < bandWidth / 2
                            ? 0x100000 + line * 30000 + y * 700 + x
                            : 0x300000 + variant * 40000 + y * 701 + x - 700
                        source[(top + y) * width + left + x] = 0xff000000 | UInt32(pixel)
                    }
                }
            }
            let expected = source.withUnsafeBytes { Data($0) }
            let backing = try XCTUnwrap(source.withUnsafeBytes {
                CursorFrameImages.copyBacking($0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count,
                    width: width, height: height, colorSpace: space)
            })
            source = []
            XCTAssertEqual(try backingPixels(backing, width: width, height: height), expected)
            var unique: [UInt32: IOSurfaceRef] = [IOSurfaceGetID(backing.background): backing.background]
            for region in backing.regions {
                unique[IOSurfaceGetID(region.surface)] = region.surface
                XCTAssertNotNil(IOSurfaceCopyValue(region.surface, kIOSurfaceColorSpace))
            }
            XCTAssertEqual(backing.allocatedBytes, unique.values.reduce(0) { $0 + IOSurfaceGetAllocSize($1) })
            XCTAssertLessThanOrEqual(backing.allocatedBytes, CursorFrameImages.maximumBackingBytes)
            if sharedCount == 28 {
                XCTAssertEqual(backing.regions.count, CursorFrameImages.maximumBackingRegions)
                let right = backing.regions.filter { $0.rect.width == 701 }
                XCTAssertEqual(right.count, sharedCount)
                XCTAssertEqual(Set(right.map { IOSurfaceGetID($0.surface) }).count, 1)
                XCTAssertEqual(backing.regions.filter { $0.rect.width == 700 }.count, sharedCount)
                XCTAssertEqual(backing.regions.filter { $0.rect.width == CGFloat(bandWidth) }.count, bandCount - sharedCount)
                let stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bandWidth * 4)
                let separate = IOSurfaceGetAllocSize(backing.background) + bandCount * IOSurfaceAlignProperty(kIOSurfaceAllocSize, stride * bandHeight)
                XCTAssertGreaterThanOrEqual(separate - backing.allocatedBytes, CursorFrameImages.minimumBandSavingsBytes)
            } else {
                // Splitting the repeated group would require 65 regions.
                XCTAssertEqual(backing.regions.count, bandCount)
                XCTAssertEqual(unique.count, bandCount + 1)
                XCTAssertTrue(backing.regions.allSatisfy { $0.rect.width == CGFloat(bandWidth) })
            }
        }
        XCTAssertNil(NSApp)
    }

    func testBackingRejectsMalformedAndOversizedSourceBeforeReadingPixels() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        [UInt8](repeating: 255, count: 4).withUnsafeBufferPointer { bytes in
            for (width, height, count) in [(0, 1, 4), (1, -1, 4), (Int.max, Int.max, 4),
                                          (4096, 4096, 4), (1, 1, 3)] {
                XCTAssertNil(CursorFrameImages.copyBacking(bytes.baseAddress!, count: count, width: width,
                                                           height: height, colorSpace: space))
            }
        }
        XCTAssertNil(NSApp)
    }

    func testSurfaceCopyOwnsPaddedBytesAndRejectsAllocationOverBudget() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var source = [UInt8](0..<36)
        let expected = Data(source)
        let surface = try XCTUnwrap(source.withUnsafeBufferPointer {
            CursorFrameImages.copySurface($0.baseAddress!, count: $0.count, width: 3, height: 3,
                colorSpace: space, maximumBytes: 1024 * 1024)
        })
        source = Array(repeating: 0, count: source.count)
        XCTAssertEqual(try pixels(surface), expected)
        let allocation = IOSurfaceGetAllocSize(surface)
        XCTAssertGreaterThan(allocation, expected.count)
        source.withUnsafeBufferPointer { bytes in
            XCTAssertNil(CursorFrameImages.copySurface(bytes.baseAddress!, count: bytes.count, width: 3, height: 3,
                colorSpace: space, maximumBytes: allocation - 1))
            XCTAssertNil(CursorFrameImages.copySurface(bytes.baseAddress!, count: bytes.count - 1, width: 3, height: 3,
                colorSpace: space, maximumBytes: allocation))
            XCTAssertNil(CursorFrameImages.copySurface(bytes.baseAddress!, count: bytes.count, width: Int.max, height: Int.max,
                colorSpace: space, maximumBytes: allocation))
        }
        XCTAssertNil(NSApp)
    }

    func testMailboxRetainsFailedOffersForReplyAndRearmsDuringDrain() {
        let mailbox = CursorCacheMailbox()
        var update = CmdyRenderSessionUpdate()
        update.cursor_token = 11 // failed image construction must still be declined
        XCTAssertTrue(mailbox.append(offer: CursorCacheOffer(update)))
        XCTAssertFalse(mailbox.append(retired: 7))
        let first = mailbox.take()
        XCTAssertEqual(first.0?.token, 11); XCTAssertNil(first.0?.images); XCTAssertEqual(first.1, 7)
        update.cursor_token = 12
        XCTAssertFalse(mailbox.append(offer: CursorCacheOffer(update)))
        XCTAssertTrue(mailbox.finishDrain())
        XCTAssertEqual(mailbox.take().0?.token, 12)
        XCTAssertFalse(mailbox.finishDrain())
        XCTAssertTrue(mailbox.append(retired: 12))
        mailbox.close()
        let closed = mailbox.take()
        XCTAssertNil(closed.0); XCTAssertNil(closed.1)
        XCTAssertFalse(mailbox.append(offer: CursorCacheOffer(update)))
        XCTAssertFalse(mailbox.finishDrain())
    }
}
