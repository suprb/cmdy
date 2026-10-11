/// Find the first non-printable-ASCII byte without reading beyond the slice.
/// Every lane must be in 0x20...0x7E; the scalar tail locates the exact boundary.
@inline(__always)
func printableASCIIEnd(_ bytes: ArraySlice<UInt8>, from start: Int) -> Int {
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return start }
        var offset = start - bytes.startIndex
        let raw = UnsafeRawPointer(base)
        let highBits: UInt64 = 0x8080808080808080
        while buffer.count - offset >= 8 {
            let word = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            // Reject high-bit bytes first. The remaining byte lanes cannot
            // carry into one another when adding either bias below.
            if word & highBits != 0
                || (word &+ 0x6060606060606060) & highBits != highBits
                || (word &+ 0x0101010101010101) & highBits != 0 {
                break
            }
            offset += 8
        }
        while offset < buffer.count, buffer[offset] >= 0x20, buffer[offset] <= 0x7E {
            offset += 1
        }
        return bytes.startIndex + offset
    }
}
