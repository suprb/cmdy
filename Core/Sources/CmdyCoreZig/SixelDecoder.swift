import CmdyNative

/// The streaming decoder and its limits are implemented by the Zig engine.
public final class SixelDecoder {
    private let native: OpaquePointer
    public init() {
        guard let native = cmdy_zig_sixel_create() else { preconditionFailure("Cannot allocate CMDY sixel decoder") }
        self.native = native
    }
    deinit { cmdy_zig_sixel_free(native) }
    public func feed(_ bytes: ArraySlice<UInt8>) {
        bytes.withUnsafeBufferPointer { checkedNative(cmdy_zig_sixel_feed(native, $0.baseAddress, $0.count)) }
    }
    public func finish() -> ([UInt8], Int, Int)? {
        guard let payload = cmdy_zig_sixel_finish(native) else { return nil }
        defer { cmdy_zig_payload_release(payload) }
        var info = CmdyZigPayloadInfo()
        checkedNative(cmdy_zig_payload_info(payload, &info))
        return (Array(UnsafeBufferPointer(start: info.bytes, count: info.count)), info.width, info.height)
    }
    static func hlsToRGB(h: Int, l: Int, s: Int) -> (UInt8, UInt8, UInt8) {
        var values: [UInt8] = [0, 0, 0]
        values.withUnsafeMutableBufferPointer { cmdy_zig_sixel_hls(h, l, s, $0.baseAddress) }
        return (values[0], values[1], values[2])
    }
}
