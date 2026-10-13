import Foundation
import CmdyNative

/// A shared native attachment. Live aliases share mutable placement metadata;
/// published snapshots detach metadata while retaining the immutable payload.
public final class LineImage: @unchecked Sendable {
    public enum Payload: Sendable {
        case png(Data)
        case rgba(bytes: [UInt8], width: Int, height: Int)
    }

    let native: OpaquePointer
    private var ownsNative = false
    public let payload: Payload
    public let renderIdentity: UUID
    public let pixelWidth: Int
    public let pixelHeight: Int

    private static let lifetimeCallback: @convention(c) (UnsafeMutableRawPointer?, UInt8) -> Void = { context, event in
        guard let context else { return }
        let reference = Unmanaged<LineImage>.fromOpaque(context)
        let image = reference.takeUnretainedValue()
        if event == 0 {
            image.ownsNative = true
            reference.release()
        } else {
            _ = reference.retain()
            image.ownsNative = false
        }
    }

    private init(retained native: OpaquePointer, payload: Payload? = nil) {
        self.native = native
        var info = CmdyZigImageInfo()
        checkedNative(cmdy_zig_image_info(native, &info))
        self.payload = payload ?? readNativePayload(cmdy_zig_image_payload(native)!)
        pixelWidth = info.pixel_width
        pixelHeight = info.pixel_height
        renderIdentity = nativeRenderIdentity(high: info.identity_high, low: info.identity_low)
        let context = Unmanaged.passRetained(self).toOpaque()
        checkedNative(cmdy_zig_image_associate(native, context, Self.lifetimeCallback))
        withExtendedLifetime(self) { cmdy_zig_image_release(native) }
    }

    static func wrapping(retained native: OpaquePointer) -> LineImage {
        if let context = cmdy_zig_image_swift_context(native) {
            let image = Unmanaged<LineImage>.fromOpaque(context).takeUnretainedValue()
            withExtendedLifetime(image) { cmdy_zig_image_release(native) }
            return image
        }
        return LineImage(retained: native)
    }

    deinit {
        precondition(ownsNative)
        checkedNative(cmdy_zig_image_disassociate(native, Unmanaged.passUnretained(self).toOpaque()))
        cmdy_zig_image_release(native)
    }

    public convenience init(payload: Payload, pixelWidth: Int, pixelHeight: Int, col: Int) {
        let nativePayload = makeNativePayload(payload)
        defer { cmdy_zig_payload_release(nativePayload) }
        guard let native = cmdy_zig_image_create_host(nativePayload, pixelWidth, pixelHeight, col) else {
            preconditionFailure("Cannot allocate CMDY native image")
        }
        self.init(retained: native, payload: payload)
    }

    private var info: CmdyZigImageInfo {
        get { var result = CmdyZigImageInfo(); checkedNative(cmdy_zig_image_info(native, &result)); return result }
        set { var value = newValue; checkedNative(cmdy_zig_image_set_info(native, &value)) }
    }
    public var col: Int {
        get { info.col }
        set { var value = info; value.col = newValue; info = value }
    }
    public var kittyIsKitty: Bool {
        get { info.is_kitty != 0 }
        set { var value = info; value.is_kitty = newValue ? 1 : 0; info = value }
    }
    public var kittyImageId: UInt32? {
        get { let value = info; return value.has_image_id == 0 ? nil : value.image_id }
        set { var value = info; value.image_id = newValue ?? 0; value.has_image_id = newValue == nil ? 0 : 1; info = value }
    }
    public var kittyPlacementId: UInt32? {
        get { let value = info; return value.has_placement_id == 0 ? nil : value.placement_id }
        set { var value = info; value.placement_id = newValue ?? 0; value.has_placement_id = newValue == nil ? 0 : 1; info = value }
    }
    public var kittyZIndex: Int {
        get { info.z_index }
        set { var value = info; value.z_index = newValue; info = value }
    }
    public var kittyPixelOffsetX: Int {
        get { info.offset_x }
        set { var value = info; value.offset_x = newValue; info = value }
    }
    public var kittyPixelOffsetY: Int {
        get { info.offset_y }
        set { var value = info; value.offset_y = newValue; info = value }
    }
    public var kittyDisplayBox: CoreKittyDisplayBox { CoreKittyDisplayBox(info) }
}

extension CoreKittyDisplayBox {
    init(_ info: CmdyZigImageInfo) {
        self.init(cellColumns: info.cell_cols, cellRows: info.cell_rows,
                  sourceX: info.source_x, sourceY: info.source_y,
                  sourceWidth: info.source_width, sourceHeight: info.source_height)
    }
}

private final class NativePayloadOwner {
    let payload: LineImage.Payload
    init(_ payload: LineImage.Payload) { self.payload = payload }
}
private let nativePayloadRelease: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    if let context { Unmanaged<NativePayloadOwner>.fromOpaque(context).release() }
}

/// The original Data/array stays alive through the native payload's final
/// reference, including snapshots that outlive the Swift producer object.
func makeNativePayload(_ payload: LineImage.Payload) -> OpaquePointer {
    let context = Unmanaged.passRetained(NativePayloadOwner(payload)).toOpaque()
    let native: OpaquePointer?
    switch payload {
    case .png(let data):
        native = data.withUnsafeBytes {
            cmdy_zig_payload_create_host(1, $0.bindMemory(to: UInt8.self).baseAddress, $0.count,
                                         0, 0, context, nativePayloadRelease)
        }
    case .rgba(let bytes, let width, let height):
        native = bytes.withUnsafeBufferPointer {
            cmdy_zig_payload_create_host(0, $0.baseAddress, $0.count, width, height,
                                         context, nativePayloadRelease)
        }
    }
    guard let native else {
        Unmanaged<NativePayloadOwner>.fromOpaque(context).release()
        preconditionFailure("Cannot allocate CMDY native image payload")
    }
    return native
}

func readNativePayload(_ native: OpaquePointer) -> LineImage.Payload {
    var value = CmdyZigPayloadInfo()
    checkedNative(cmdy_zig_payload_info(native, &value))
    let buffer = UnsafeBufferPointer(start: value.bytes, count: value.count)
    if value.format == 1 { return .png(Data(buffer: buffer)) }
    return .rgba(bytes: Array(buffer), width: value.width, height: value.height)
}

func nativeRenderIdentity(high: UInt64, low: UInt64) -> UUID {
    let bytes = (0..<16).map { index -> UInt8 in
        let word = index < 8 ? high : low
        return UInt8(truncatingIfNeeded: word >> (56 - (index % 8) * 8))
    }
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}
