import AppKit
import CmdyNative
import Darwin
import IOSurface
import QuartzCore

struct CursorBackingRegion {
    let surface: IOSurfaceRef
    let rect: CGRect
}

struct CursorBackingSurfaces {
    let background: IOSurfaceRef
    let regions: [CursorBackingRegion]
    var allocatedBytes: Int {
        var identities: Set<ObjectIdentifier> = [ObjectIdentifier(background)]
        return IOSurfaceGetAllocSize(background) + regions.reduce(0) {
            $0 + (identities.insert(ObjectIdentifier($1.surface)).inserted ? IOSurfaceGetAllocSize($1.surface) : 0)
        }
    }
}

/// Copies completed native pixels on their callback owner. Tagged IOSurfaces
/// preserve the Metal colour path; CGImage contents introduce a visible shift.
/// Surfaces are immutable after construction and independent of native lifetime.
final class CursorFrameImages: @unchecked Sendable {
    static let maximumBackingBytes = 32 * 1024 * 1024
    static let maximumPhaseBytes = 2 * 1024 * 1024
    static let maximumBackingRegions = 64
    static let minimumBandSavingsBytes = 1024 * 1024
    let token: UInt64
    let epoch: UInt64
    let revision: UInt64
    let generation: UInt64
    let geometry: CmdyRenderCursorFramesView
    let colorSpace: CGColorSpace
    let backing: IOSurfaceRef
    let backingRegions: [CursorBackingRegion]
    let phases: [IOSurfaceRef]
    let allocatedBytes: Int

    private static func surfaceLayout(width: Int, height: Int, maximumBytes: Int) -> (stride: Int, allocation: Int)? {
        guard width > 0, height > 0, maximumBytes > 0,
              height <= maximumBytes / 4, width <= maximumBytes / 4 / height else { return nil }
        let sourceStride = width * 4
        let stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, sourceStride)
        guard stride >= sourceStride, stride <= maximumBytes / height else { return nil }
        let allocation = IOSurfaceAlignProperty(kIOSurfaceAllocSize, stride * height)
        guard allocation >= stride * height, allocation <= maximumBytes else { return nil }
        return (stride, allocation)
    }

    /// Both alignment padding and page rounding count against the budget.
    /// Check before allocation and again against the actual returned surface.
    static func copySurface(_ bytes: UnsafePointer<UInt8>, count: Int, width: Int, height: Int,
                            colorSpace: CGColorSpace, maximumBytes: Int) -> IOSurfaceRef? {
        guard surfaceLayout(width: width, height: height, maximumBytes: maximumBytes) != nil,
              count == width * height * 4 else { return nil }
        return copyRegion(bytes, sourceStride: width * 4, width: width, height: height,
                          colorSpace: colorSpace, maximumBytes: maximumBytes)
    }

    // Callers validate the source buffer and rectangle before forming this pointer.
    private static func copyRegion(_ bytes: UnsafePointer<UInt8>, sourceStride: Int, width: Int, height: Int,
                                   colorSpace: CGColorSpace, maximumBytes: Int) -> IOSurfaceRef? {
        guard let (stride, allocation) = surfaceLayout(width: width, height: height, maximumBytes: maximumBytes),
              let colorTag = colorSpace.copyPropertyList() else { return nil }
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: width, kIOSurfaceHeight as String: height,
            kIOSurfaceBytesPerElement as String: 4, kIOSurfaceBytesPerRow as String: stride,
            kIOSurfaceAllocSize as String: allocation,
            kIOSurfacePixelFormat as String: UInt32(0x42475241), // BGRA
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary),
              IOSurfaceGetWidth(surface) == width, IOSurfaceGetHeight(surface) == height,
              IOSurfaceGetBytesPerRow(surface) == stride,
              IOSurfaceGetAllocSize(surface) >= stride * height,
              IOSurfaceGetAllocSize(surface) <= maximumBytes,
              IOSurfaceLock(surface, [], nil) == 0 else { return nil }
        let destination = IOSurfaceGetBaseAddress(surface)
        memset(destination, 0, IOSurfaceGetAllocSize(surface))
        for row in 0..<height {
            memcpy(destination.advanced(by: row * stride), bytes.advanced(by: row * sourceStride), width * 4)
        }
        guard IOSurfaceUnlock(surface, [], nil) == 0 else { return nil }
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorTag)
        return surface
    }

    private struct BackingFingerprint: Hashable {
        let width: Int
        let height: Int
        let hash: Int
    }

    private struct BackingClass {
        let rect: CGRect
        let allocation: Int
    }

    private struct BackingPlacement {
        let rect: CGRect
        let classIndex: Int
    }

    private struct BackingBand {
        let whole: BackingPlacement
        let halves: [BackingPlacement]
    }

    /// The catalog borrows source bytes only during this callback. Hashes narrow
    /// the search; dimensions and every row must match before any surface aliases.
    /// Each band has one fixed midpoint candidate, keeping work and geometry bounded.
    private static func copySharedBacking(_ bytes: UnsafePointer<UInt8>, sourceWidth: Int, bands: [CGRect],
                                          separateAllocation: Int, colorSpace: CGColorSpace) -> CursorBackingSurfaces? {
        guard bands.count <= maximumBackingRegions,
              let solid = surfaceLayout(width: 1, height: 1, maximumBytes: maximumBackingBytes) else { return nil }
        let stride = sourceWidth * 4
        var classes: [BackingClass] = []
        var fingerprints: [BackingFingerprint: [Int]] = [:]
        func register(_ rect: CGRect) -> BackingPlacement? {
            let width = Int(rect.width), height = Int(rect.height)
            guard let layout = surfaceLayout(width: width, height: height, maximumBytes: maximumBackingBytes) else { return nil }
            let start = bytes.advanced(by: Int(rect.minY) * stride + Int(rect.minX) * 4)
            var hasher = Hasher()
            for row in 0..<height {
                hasher.combine(bytes: UnsafeRawBufferPointer(start: start.advanced(by: row * stride), count: width * 4))
            }
            let key = BackingFingerprint(width: width, height: height, hash: hasher.finalize())
            for index in fingerprints[key] ?? [] {
                let prior = classes[index].rect
                let other = bytes.advanced(by: Int(prior.minY) * stride + Int(prior.minX) * 4)
                if (0..<height).allSatisfy({ memcmp(start.advanced(by: $0 * stride), other.advanced(by: $0 * stride), width * 4) == 0 }) {
                    return BackingPlacement(rect: rect, classIndex: index)
                }
            }
            let index = classes.count
            classes.append(BackingClass(rect: rect, allocation: layout.allocation))
            fingerprints[key, default: []].append(index)
            return BackingPlacement(rect: rect, classIndex: index)
        }
        var catalog: [BackingBand] = []
        catalog.reserveCapacity(bands.count)
        for rect in bands {
            guard let whole = register(rect) else { return nil }
            var halves: [BackingPlacement] = []
            if rect.width > 1 {
                let left = Int(rect.width) / 2
                guard let first = register(CGRect(x: rect.minX, y: rect.minY, width: CGFloat(left), height: rect.height)),
                      let second = register(CGRect(x: rect.minX + CGFloat(left), y: rect.minY,
                        width: rect.width - CGFloat(left), height: rect.height)) else { return nil }
                halves = [first, second]
            }
            catalog.append(BackingBand(whole: whole, halves: halves))
        }
        // Stable class order resolves equal savings, independent of hash seeding.
        var groups = [[Int]](repeating: [], count: classes.count)
        for (index, band) in catalog.enumerated() {
            for half in band.halves where groups[half.classIndex].last != index {
                groups[half.classIndex].append(index)
            }
        }
        func cost(_ splits: [Bool]) -> Int {
            var seen = [Bool](repeating: false, count: classes.count)
            var allocation = solid.allocation
            for (index, band) in catalog.enumerated() {
                for placement in splits[index] ? band.halves : [band.whole] where !seen[placement.classIndex] {
                    seen[placement.classIndex] = true
                    allocation += classes[placement.classIndex].allocation
                }
            }
            return allocation
        }
        var splits = [Bool](repeating: false, count: catalog.count)
        var allocation = cost(splits)
        while true {
            var best = allocation
            var choice: [Bool]?
            for members in groups where !members.isEmpty {
                var proposal = splits
                for index in members { proposal[index] = true }
                guard bands.count + proposal.filter({ $0 }).count <= maximumBackingRegions else { continue }
                let candidate = cost(proposal)
                if candidate < best { best = candidate; choice = proposal }
            }
            guard let choice else { break }
            splits = choice; allocation = best
        }
        guard allocation <= separateAllocation - minimumBandSavingsBytes,
              let background = copySurface(bytes, count: 4, width: 1, height: 1,
                colorSpace: colorSpace, maximumBytes: maximumBackingBytes) else { return nil }
        var surfaces = [IOSurfaceRef?](repeating: nil, count: classes.count)
        var regions: [CursorBackingRegion] = []
        regions.reserveCapacity(bands.count + splits.filter({ $0 }).count)
        var actualAllocation = IOSurfaceGetAllocSize(background)
        for (index, band) in catalog.enumerated() {
            for placement in splits[index] ? band.halves : [band.whole] {
                let classIndex = placement.classIndex
                if surfaces[classIndex] == nil {
                    let rect = classes[classIndex].rect
                    guard let surface = copyRegion(bytes.advanced(by: Int(rect.minY) * stride + Int(rect.minX) * 4),
                        sourceStride: stride, width: Int(rect.width), height: Int(rect.height), colorSpace: colorSpace,
                        maximumBytes: maximumBackingBytes - actualAllocation) else { return nil }
                    surfaces[classIndex] = surface
                    actualAllocation += IOSurfaceGetAllocSize(surface)
                }
                regions.append(CursorBackingRegion(surface: surfaces[classIndex]!, rect: placement.rect))
            }
        }
        guard actualAllocation <= separateAllocation - minimumBandSavingsBytes else { return nil }
        return CursorBackingSurfaces(background: background, regions: regions)
    }

    /// Preserve every pixel while avoiding a viewport-sized allocation for a
    /// uniform border. A one-pixel tagged surface supplies the opaque background;
    /// Exact row bands omit uniform gaps between text lines when their combined
    /// aligned allocations save at least one MiB. Exact repeated bands or midpoint
    /// sections share immutable surfaces only for another MiB of saving. The number of regions is bounded;
    /// other frames retain the single rectangle or original full surface.
    static func copyBacking(_ bytes: UnsafePointer<UInt8>, count: Int, width: Int, height: Int,
                            colorSpace: CGColorSpace) -> CursorBackingSurfaces? {
        guard let full = surfaceLayout(width: width, height: height, maximumBytes: maximumBackingBytes),
              count == width * height * 4,
              let solid = surfaceLayout(width: 1, height: 1, maximumBytes: maximumBackingBytes) else { return nil }
        let raw = UnsafeRawPointer(bytes)
        let color = raw.loadUnaligned(as: UInt32.self)
        var left = width, right = 0, top = height, bottom = 0
        var bands: [CGRect] = []
        bands.reserveCapacity(maximumBackingRegions)
        var activeBand: CGRect?
        var bandingAllowed = true
        func finishBand() {
            guard let band = activeBand else { return }
            if bands.count < maximumBackingRegions {
                bands.append(band)
            } else {
                bands.removeAll(keepingCapacity: false)
                bandingAllowed = false
            }
            activeBand = nil
        }
        for row in 0..<height {
            let offset = row * width * 4
            var first = 0
            while first < width && raw.loadUnaligned(fromByteOffset: offset + first * 4, as: UInt32.self) == color { first += 1 }
            if first == width {
                if bandingAllowed { finishBand() }
                continue
            }
            var last = width - 1
            while last > first && raw.loadUnaligned(fromByteOffset: offset + last * 4, as: UInt32.self) == color { last -= 1 }
            left = min(left, first); right = max(right, last + 1)
            top = min(top, row); bottom = row + 1
            if bandingAllowed {
                let span = CGRect(x: first, y: row, width: last - first + 1, height: 1)
                activeBand = activeBand.map { $0.union(span) } ?? span
            }
        }
        if bandingAllowed { finishBand() }
        let uniform = top == height
        let cropWidth = right - left, cropHeight = bottom - top
        let crop = uniform ? nil : surfaceLayout(width: cropWidth, height: cropHeight,
                                                 maximumBytes: maximumBackingBytes - solid.allocation)
        let previousAllocation = crop.map { min(full.allocation, solid.allocation + $0.allocation) } ?? full.allocation
        if bandingAllowed && bands.count > 1 {
            var allocation = solid.allocation
            for band in bands {
                guard let layout = surfaceLayout(width: Int(band.width), height: Int(band.height),
                    maximumBytes: maximumBackingBytes - allocation) else {
                    bandingAllowed = false
                    break
                }
                allocation += layout.allocation
            }
            if bandingAllowed && allocation <= previousAllocation - minimumBandSavingsBytes {
                if let shared = copySharedBacking(bytes, sourceWidth: width, bands: bands,
                    separateAllocation: allocation, colorSpace: colorSpace) { return shared }
                guard let background = copySurface(bytes, count: 4, width: 1, height: 1,
                    colorSpace: colorSpace, maximumBytes: maximumBackingBytes) else { return nil }
                var regions: [CursorBackingRegion] = []
                regions.reserveCapacity(bands.count)
                var actualAllocation = IOSurfaceGetAllocSize(background)
                for band in bands {
                    guard let surface = copyRegion(bytes.advanced(by: (Int(band.minY) * width + Int(band.minX)) * 4),
                        sourceStride: width * 4, width: Int(band.width), height: Int(band.height),
                        colorSpace: colorSpace, maximumBytes: maximumBackingBytes - actualAllocation) else { return nil }
                    actualAllocation += IOSurfaceGetAllocSize(surface)
                    regions.append(CursorBackingRegion(surface: surface, rect: band))
                }
                guard actualAllocation <= previousAllocation - minimumBandSavingsBytes else { return nil }
                return CursorBackingSurfaces(background: background, regions: regions)
            }
        }
        if uniform || (crop.map { $0.allocation < full.allocation - solid.allocation } ?? false) {
            guard let background = copySurface(bytes, count: 4, width: 1, height: 1,
                colorSpace: colorSpace, maximumBytes: maximumBackingBytes) else { return nil }
            if uniform { return CursorBackingSurfaces(background: background, regions: []) }
            guard let detail = copyRegion(bytes.advanced(by: (top * width + left) * 4), sourceStride: width * 4,
                width: cropWidth, height: cropHeight, colorSpace: colorSpace,
                maximumBytes: maximumBackingBytes - IOSurfaceGetAllocSize(background)) else { return nil }
            let result = CursorBackingSurfaces(background: background, regions: [CursorBackingRegion(surface: detail,
                rect: CGRect(x: left, y: top, width: cropWidth, height: cropHeight))])
            guard result.allocatedBytes < full.allocation else { return nil }
            return result
        }
        guard let surface = copySurface(bytes, count: count, width: width, height: height,
            colorSpace: colorSpace, maximumBytes: maximumBackingBytes) else { return nil }
        return CursorBackingSurfaces(background: surface, regions: [])
    }

    init?(_ update: CmdyRenderSessionUpdate) {
        guard let native = update.cursor_frames,
              let pointer = cmdy_render_cursor_frames_view(native) else { return nil }
        let view = pointer.pointee
        guard view.count == 60, view.width > 0, view.height > 0,
              view.backing_width > 0, view.backing_height > 0,
              view.height <= Self.maximumPhaseBytes / 60 / 4,
              view.width <= Self.maximumPhaseBytes / 60 / 4 / view.height,
              view.bytes_per_frame == view.width * view.height * 4,
              view.scale.isFinite, view.scale > 0, view.active_until > view.activity_time,
              let pixels = view.bytes, let base = view.backing_bytes,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let backing = Self.copyBacking(base, count: view.backing_byte_count,
            width: view.backing_width, height: view.backing_height, colorSpace: space) else { return nil }
        var phases: [IOSurfaceRef] = []
        phases.reserveCapacity(60)
        var representatives: [Int] = []
        representatives.reserveCapacity(60)
        var phaseBytes = 0
        for index in 0..<60 {
            let source = pixels.advanced(by: index * view.bytes_per_frame)
            // Symmetric blink phases often have identical final pixels. Compare
            // every byte while the native frame is borrowed; share only those
            // immutable surfaces, preserving all sixty animation positions.
            if let previous = representatives.first(where: {
                memcmp(source, pixels.advanced(by: $0 * view.bytes_per_frame), view.bytes_per_frame) == 0
            }) {
                phases.append(phases[previous])
                continue
            }
            guard let frame = Self.copySurface(source,
                count: view.bytes_per_frame, width: view.width, height: view.height, colorSpace: space,
                maximumBytes: Self.maximumPhaseBytes - phaseBytes) else { return nil }
            phaseBytes += IOSurfaceGetAllocSize(frame)
            phases.append(frame)
            representatives.append(index)
        }
        token = update.cursor_token; epoch = update.identity.epoch
        revision = update.source_revision; generation = update.cursor_generation
        var geometry = view
        // All borrowed bytes have been copied; never retain native pointers.
        geometry.bytes = nil; geometry.backing_bytes = nil
        self.geometry = geometry; self.backing = backing.background; self.phases = phases
        backingRegions = backing.regions
        colorSpace = space
        allocatedBytes = backing.allocatedBytes + phaseBytes
    }
}

struct CursorCacheOffer: @unchecked Sendable {
    let token: UInt64
    let images: CursorFrameImages?
    init(_ update: CmdyRenderSessionUpdate) {
        token = update.cursor_token
        images = CursorFrameImages(update)
    }
}

/// Separate from scalar update coalescing: at most one unanswered native offer
/// exists, plus one replaceable retirement token. Closed payloads release images.
final class CursorCacheMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var scheduled = false
    private var offer: CursorCacheOffer?
    private var retired: UInt64?
    func append(offer: CursorCacheOffer? = nil, retired: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        if let offer {
            precondition(self.offer == nil, "Native cursor offers require one response before replacement")
            self.offer = offer
        }
        if let retired { self.retired = retired }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }
    func take() -> (CursorCacheOffer?, UInt64?) {
        lock.lock(); defer { lock.unlock() }
        let result = (offer, retired)
        offer = nil; retired = nil
        return result
    }
    func finishDrain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !closed && (offer != nil || retired != nil) { return true }
        scheduled = false
        return false
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; offer = nil; retired = nil
    }
}

/// A complete opaque backing prevents a stale patch from covering newer Metal
/// content. Removing this single parent replaces backing and cursor together.
@MainActor
final class CursorCacheLayer {
    private var root: CALayer?
    private weak var patch: CALayer?
    private var installedMetadata: [String: Any] = [:]
    private var expiry: Timer?
    private(set) var token: UInt64 = 0

    /// Read only on demand through the authenticated debug API. The clocks
    /// bracket the presentation read; no layer or animation is changed here.
    /// Surface IDs describe aliases, not uniquely observable phase positions.
    var statistics: [String: Any] {
        guard root != nil, let patch, token != 0 else {
            return ["active": false, "token": 0]
        }
        let animation = patch.animation(forKey: "cmdy.cursor.phase") as? CAKeyframeAnimation
        let hostBefore = mach_absolute_time()
        let mediaBefore = CACurrentMediaTime()
        let localBefore = patch.convertTime(mediaBefore, from: nil)
        let presentation = patch.presentation()
        var surfaceID: UInt32?
        if let contents = presentation?.contents,
           CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            surfaceID = IOSurfaceGetID(contents as! IOSurfaceRef)
        }
        let mediaAfter = CACurrentMediaTime()
        let hostAfter = mach_absolute_time()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var result = installedMetadata
        result["active"] = true
        result["token"] = token
        result["animationPresent"] = animation != nil
        result["presentationExists"] = presentation != nil
        result["presentationSurfaceID"] = surfaceID as Any? ?? NSNull()
        result["hostTicksBefore"] = hostBefore
        result["hostTicksAfter"] = hostAfter
        result["timebaseNumer"] = timebase.numer
        result["timebaseDenom"] = timebase.denom
        result["mediaTimeBefore"] = mediaBefore
        result["mediaTimeAfter"] = mediaAfter
        result["layerLocalTimeBefore"] = localBefore
        result["layerLocalTimeAfter"] = patch.convertTime(mediaAfter, from: nil)
        result["layerSpeed"] = patch.speed
        result["layerTimeOffset"] = patch.timeOffset
        if let animation {
            result["animationBeginTime"] = animation.beginTime
            result["duration"] = animation.duration
            result["repeatDuration"] = animation.repeatDuration
            result["valueCount"] = animation.values?.count ?? 0
            result["keyTimes"] = animation.keyTimes ?? []
            result["calculationMode"] = animation.calculationMode.rawValue
            result["preferredFrameRateRange"] = [animation.preferredFrameRateRange.minimum,
                animation.preferredFrameRateRange.maximum, animation.preferredFrameRateRange.preferred]
        }
        return result
    }

    @discardableResult
    func clear() -> UInt64 {
        guard root != nil || token != 0 else { return 0 }
        let previous = token
        expiry?.invalidate(); expiry = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root?.removeFromSuperlayer(); root = nil; token = 0
        patch = nil; installedMetadata = [:]
        CATransaction.commit(); CATransaction.flush()
        return previous
    }

    func install(_ images: CursorFrameImages, in parent: CAMetalLayer,
                 onExpired: @escaping @MainActor (UInt64) -> Void) -> Bool {
        let data = images.geometry
        let now = ProcessInfo.processInfo.systemUptime
        guard root == nil, data.active_until > now,
              let space = parent.colorspace, CFEqual(space, images.colorSpace),
              parent.drawableSize.width == data.viewport_width,
              parent.drawableSize.height == data.viewport_height else { return false }
        let backing = CALayer()
        let patch = CALayer()
        let scale = data.scale
        backing.frame = CGRect(x: 0, y: 0, width: data.viewport_width / scale, height: data.viewport_height / scale)
        backing.isGeometryFlipped = false
        backing.masksToBounds = true
        backing.isOpaque = true
        backing.contentsScale = scale
        backing.contents = images.backing
        backing.minificationFilter = .nearest; backing.magnificationFilter = .nearest
        for region in images.backingRegions {
            let detail = CALayer()
            let rect = region.rect
            detail.frame = CGRect(x: rect.minX / scale, y: (data.viewport_height - rect.maxY) / scale,
                                  width: rect.width / scale, height: rect.height / scale)
            detail.contentsScale = scale; detail.isOpaque = true
            detail.contents = region.surface
            detail.minificationFilter = .nearest; detail.magnificationFilter = .nearest
            backing.addSublayer(detail)
        }
        patch.frame = CGRect(x: data.x / scale, y: (data.viewport_height - data.y - Double(data.height)) / scale,
                             width: Double(data.width) / scale, height: Double(data.height) / scale)
        patch.contentsScale = scale
        patch.contents = images.phases[0]
        patch.minificationFilter = .nearest; patch.magnificationFilter = .nearest
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images.phases
        animation.keyTimes = (0...60).map { NSNumber(value: Double($0) / 60) }
        animation.calculationMode = .discrete
        animation.duration = 1.2
        animation.repeatDuration = data.active_until - data.activity_time
        animation.isRemovedOnCompletion = true
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 50, maximum: 50, preferred: 50)
        // Map the renderer's uptime clock to this layer's local media clock.
        let mediaStart = CACurrentMediaTime() - (now - data.activity_time)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        parent.addSublayer(backing); backing.addSublayer(patch)
        animation.beginTime = patch.convertTime(mediaStart, from: nil)
        patch.add(animation, forKey: "cmdy.cursor.phase")
        root = backing; token = images.token
        self.patch = patch
        installedMetadata = ["epoch": images.epoch, "revision": images.revision,
            "generation": images.generation, "activityUptime": data.activity_time,
            "activeUntilUptime": data.active_until, "installedUptime": now,
            "phaseSurfaceIDs": images.phases.map { IOSurfaceGetID($0) },
            "patchPixels": [data.x, data.y, Double(data.width), Double(data.height)],
            "viewportPixels": [data.viewport_width, data.viewport_height], "scale": scale]
        CATransaction.commit(); CATransaction.flush()
        let token = images.token
        let timer = Timer(timeInterval: max(0.001, data.active_until - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.token == token else { return }
                onExpired(token)
            }
        }
        expiry = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }
}
