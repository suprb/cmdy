import Foundation

// Build-time compatibility oracle. The generated Zig engine never calls Swift
// for Unicode properties. Every valid scalar is captured and rechecked here.
var ranges: [[UInt32]] = []
var start: UInt32?
for value: UInt32 in 0...0x110000 {
    let isEmoji = Unicode.Scalar(value)?.properties.isEmoji ?? false
    if isEmoji {
        if start == nil { start = value }
    } else if let first = start {
        ranges.append([first, value - 1])
        start = nil
    }
}
let bytes = try JSONSerialization.data(withJSONObject: ranges)
FileHandle.standardOutput.write(bytes)
FileHandle.standardOutput.write(Data([10]))
