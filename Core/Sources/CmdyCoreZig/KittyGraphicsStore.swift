import Foundation
import CmdyNative

public final class KittyGraphicsStore {
    public struct Placement {
        public var imageId: UInt32
        public var placementId: UInt32
        public var col: Int
        public var row: Int
        public var cols: Int
        public var rows: Int
        public var zIndex: Int
        public var pixelOffsetX: Int
        public var pixelOffsetY: Int
        public var isVirtual: Bool
        public var isAlternateBuffer: Bool
    }

    public final class Image {
        let native: OpaquePointer
        private var ownsNative = false
        public let id: UInt32
        public let number: UInt32?
        public let payload: LineImage.Payload
        public let pixelWidth: Int
        public let pixelHeight: Int

        private static let lifetimeCallback: @convention(c) (UnsafeMutableRawPointer?, UInt8) -> Void = { context, event in
            guard let context else { return }
            let reference = Unmanaged<Image>.fromOpaque(context)
            let image = reference.takeUnretainedValue()
            if event == 0 { image.ownsNative = true; reference.release() }
            else { _ = reference.retain(); image.ownsNative = false }
        }
        private init(retained native: OpaquePointer, payload: LineImage.Payload? = nil) {
            self.native = native
            var info = CmdyZigStoredImageInfo()
            checkedNative(cmdy_zig_stored_image_info(native, &info))
            id = info.id; number = info.has_number == 0 ? nil : info.number
            pixelWidth = info.pixel_width; pixelHeight = info.pixel_height
            self.payload = payload ?? readNativePayload(cmdy_zig_stored_image_payload(native)!)
            let context = Unmanaged.passRetained(self).toOpaque()
            checkedNative(cmdy_zig_stored_image_associate(native, context, Self.lifetimeCallback))
            withExtendedLifetime(self) { cmdy_zig_stored_image_release(native) }
        }
        convenience init(id: UInt32, number: UInt32?, payload: LineImage.Payload, width: Int, height: Int) {
            let nativePayload = makeNativePayload(payload)
            defer { cmdy_zig_payload_release(nativePayload) }
            guard let native = cmdy_zig_stored_image_create(nativePayload, id, number ?? 0, number == nil ? 0 : 1, width, height) else {
                preconditionFailure("Cannot allocate CMDY stored image")
            }
            self.init(retained: native, payload: payload)
        }
        static func wrapping(retained native: OpaquePointer) -> Image {
            if let context = cmdy_zig_stored_image_swift_context(native) {
                let image = Unmanaged<Image>.fromOpaque(context).takeUnretainedValue()
                withExtendedLifetime(image) { cmdy_zig_stored_image_release(native) }
                return image
            }
            return Image(retained: native)
        }
        deinit {
            precondition(ownsNative)
            checkedNative(cmdy_zig_stored_image_disassociate(native, Unmanaged.passUnretained(self).toOpaque()))
            cmdy_zig_stored_image_release(native)
        }
    }

    let native: OpaquePointer
    private let owner: AnyObject?
    init() {
        guard let native = cmdy_zig_graphics_create() else { preconditionFailure("Cannot allocate CMDY graphics store") }
        self.native = native; owner = nil
    }
    init(native: OpaquePointer, owner: AnyObject) { self.native = native; self.owner = owner }
    deinit { if owner == nil { cmdy_zig_graphics_free(native) } }
    public var imagesById: [UInt32: Image] {
        var images: [UInt32: Image] = [:]
        for index in 0..<cmdy_zig_graphics_get(native, 3) {
            if let pointer = cmdy_zig_graphics_image_at(native, index) {
                let image = Image.wrapping(retained: pointer); images[image.id] = image
            }
        }
        return images
    }
    public var placementsByKey: [String: Placement] {
        var result: [String: Placement] = [:]
        for index in 0..<cmdy_zig_graphics_get(native, 4) {
            var value = CmdyZigPlacement()
            if cmdy_zig_graphics_placement_at(native, index, &value) == 1 {
                result["\(value.image_id):\(value.placement_id)"] = Placement(native: value)
            }
        }
        return result
    }
    public var nextImageId: UInt32 { UInt32(cmdy_zig_graphics_get(native, 0)) }
    public var nextPlacementId: UInt32 { UInt32(cmdy_zig_graphics_get(native, 1)) }
    public var payloadBytes: Int { cmdy_zig_graphics_get(native, 2) }
    @discardableResult
    func store(_ image: Image) -> Bool {
        withExtendedLifetime(image) { cmdy_zig_graphics_store(native, image.native) == 1 }
    }
    @discardableResult
    func place(_ placement: Placement) -> Bool {
        var value = placement.native; return cmdy_zig_graphics_place(native, &value) == 1
    }
    func deleteImage(id: UInt32) { cmdy_zig_graphics_delete_image(native, id) }
    func deletePlacements(imageId: UInt32) { cmdy_zig_graphics_delete_placements(native, imageId) }
    func deleteAll() { cmdy_zig_graphics_delete_all(native) }
    func newestImage(number: UInt32) -> Image? {
        cmdy_zig_graphics_newest(native, number).map { Image.wrapping(retained: $0) }
    }
    @discardableResult
    func removePlacements(where shouldRemove: (Placement) -> Bool) -> [Placement] {
        let candidates = placementsByKey.values.filter(shouldRemove)
        var removed: [Placement] = []
        removed.reserveCapacity(candidates.count)
        for placement in candidates {
            var value = CmdyZigPlacement()
            if cmdy_zig_graphics_remove_placement(native, placement.imageId, placement.placementId, &value) == 1 {
                removed.append(Placement(native: value))
            }
        }
        return removed
    }
    func hasPlacement(imageId: UInt32) -> Bool { cmdy_zig_graphics_has_placement(native, imageId) != 0 }
}

extension KittyGraphicsStore.Placement {
    fileprivate init(native value: CmdyZigPlacement) {
        imageId = value.image_id; placementId = value.placement_id
        col = value.col; row = value.row; cols = value.cols; rows = value.rows
        zIndex = value.z_index; pixelOffsetX = value.offset_x; pixelOffsetY = value.offset_y
        isVirtual = value.is_virtual != 0; isAlternateBuffer = value.is_alternate_buffer != 0
    }
    fileprivate var native: CmdyZigPlacement {
        var value = CmdyZigPlacement()
        value.image_id = imageId; value.placement_id = placementId
        value.col = col; value.row = row; value.cols = cols; value.rows = rows
        value.z_index = zIndex; value.offset_x = pixelOffsetX; value.offset_y = pixelOffsetY
        value.is_virtual = isVirtual ? 1 : 0; value.is_alternate_buffer = isAlternateBuffer ? 1 : 0
        return value
    }
}

extension Data {
    func zlibInflated(maxOutputSize: Int) -> Data? {
        let result = withUnsafeBytes {
            cmdy_zig_zlib_inflated($0.bindMemory(to: UInt8.self).baseAddress, $0.count, maxOutputSize)
        }
        guard let result else { return nil }
        defer { cmdy_zig_payload_release(result) }
        var info = CmdyZigPayloadInfo()
        checkedNative(cmdy_zig_payload_info(result, &info))
        return Data(buffer: UnsafeBufferPointer(start: info.bytes, count: info.count))
    }
}
